// 管理所有 Claude 会话运行时：订阅关系、事件扇出、服务端请求与客户端答复的配对，以及
// "同一会话同一时刻只有一个驱动方"：别处接手时让出、客户端要求时接管。
// 订阅了同一会话的每个连接（例如 iPad 与 iPhone）都收到事件和审批；谁先答复以谁为准，
// 其余连接收到 serverRequest/resolved。
import { randomUUID } from "node:crypto";
import type { RateLimitSnapshot } from "../protocol/codex/v2/RateLimitSnapshot.ts";
import { notificationFrame } from "../rpc/frames.ts";
import type { Session } from "../session/session.ts";
import { errorText, logger } from "../util/logging.ts";
import { holdersOf, ownerSummary, readHolders, sessionsDir, type OwnProcesses, type SessionHolder } from "./holders.ts";
import { OwnershipWatcher } from "./ownership.ts";
import { mergeObservedRateLimits } from "./rateLimits.ts";
import type { RunSettings } from "./settings.ts";
import {
  DEFAULT_TAKEOVER_TIMEOUTS,
  releaseForeignHolders,
  systemTakeoverDeps,
  type TakeoverDeps,
  type TakeoverOutcome,
  type TakeoverTimeouts,
} from "./takeover.ts";
import { ThreadRuntime, type RuntimeHost } from "./threadRuntime.ts";

interface PendingRequest {
  threadId: string;
  method: string;
  params: Record<string, unknown>;
  resolve(value: unknown): void;
  reject(error: Error): void;
}

export interface ManagerOptions {
  claudeExecutable(): string;
  log(message: string): void;
  idleCloseMs?: number;
  startQuery?: RuntimeHost["startQuery"];
  /** 占用登记的兜底轮询间隔（目录事件之外）。 */
  ownershipPollMs?: number;
  takeoverTimeouts?: TakeoverTimeouts;
  /** 测试可替换进程核对与信号。 */
  takeoverDeps?: Partial<TakeoverDeps>;
  /** 会话当前的标题（Claude Code 的 AI 标题或 /rename），用于把标题变化推给客户端。 */
  readTitle?: (threadId: string) => Promise<string | null>;
  /** turn 收尾后检查标题的时间点（毫秒）。 */
  titleCheckDelaysMs?: number[];
}

/** Claude Code 在第一轮前后异步生成 AI 标题，通常几秒内写入；稍后再看几次。 */
const TITLE_CHECK_DELAYS_MS = [0, 2_000, 8_000, 30_000];

export class ThreadManager {
  private readonly runtimes = new Map<string, ThreadRuntime>();
  private readonly subscribers = new Map<string, Set<Session>>();
  private readonly subscriptions = new Map<Session, Set<string>>();
  private readonly pending = new Map<string, PendingRequest>();
  private counter = 0;
  /** 已经推送给客户端（或客户端从会话快照里拿到）的标题。 */
  private readonly titles = new Map<string, string | null>();
  private lastRateLimits: RateLimitSnapshot | undefined;
  readonly ownPids = new Set<number>();
  /** 本适配器自己的 Claude 进程：已知 pid，以及还没拿到 pid 的启动窗口。 */
  readonly own: OwnProcesses = {
    pids: this.ownPids,
    startingSince: (threadId) => this.runtimes.get(threadId)?.startingSince,
  };
  private readonly host: RuntimeHost;
  private readonly ownership: OwnershipWatcher;
  private readonly takeoverDeps: TakeoverDeps;
  private readonly takeoverTimeouts: TakeoverTimeouts;

  constructor(private readonly options: ManagerOptions) {
    this.host = {
      publish: (threadId, method, params) => this.publish(threadId, method, params),
      request: (threadId, method, params, signal) => this.request(threadId, method, params, signal),
      claudeExecutable: options.claudeExecutable,
      log: options.log,
      ownPids: this.ownPids,
      processReady: () => void this.ownership.scanNow(),
      turnFinished: (threadId) => this.scheduleTitleChecks(threadId),
      idleCloseMs: options.idleCloseMs ?? 10 * 60_000,
      ...(options.startQuery ? { startQuery: options.startQuery } : {}),
    };
    this.ownership = new OwnershipWatcher({
      dir: sessionsDir(),
      tracked: () => this.trackedThreads(),
      read: () => this.holders(),
      onChange: (threadId, holder) => this.ownershipChanged(threadId, holder),
      log: options.log,
      ...(options.ownershipPollMs !== undefined ? { pollMs: options.ownershipPollMs } : {}),
    });
    this.takeoverDeps = { ...systemTakeoverDeps((threadId) => holdersOf(threadId, this.own)), ...options.takeoverDeps };
    this.takeoverTimeouts = options.takeoverTimeouts ?? DEFAULT_TAKEOVER_TIMEOUTS;
  }

  /** 会话 ID → 别处持有方（不含本适配器自己的进程）。 */
  holders(): Promise<Map<string, SessionHolder>> {
    return readHolders(this.own);
  }

  /** 结束空闲的别处持有方，之后由调用方以同一 ID 续聊。 */
  async takeover(threadId: string): Promise<TakeoverOutcome> {
    const started = Date.now();
    try {
      const outcome = await releaseForeignHolders(threadId, this.takeoverDeps, this.takeoverTimeouts);
      logger.debug("takeover", {
        thread: threadId,
        released: outcome.released,
        ...(outcome.released ? { pid: outcome.holders[0]?.pid, signal: outcome.signal } : {}),
        ms: Date.now() - started,
      });
      return outcome;
    } catch (error) {
      const reason = (error as { reason?: string }).reason;
      logger.debug("takeover.refused", { thread: threadId, reason: reason ?? errorText(error), ms: Date.now() - started });
      throw error;
    }
  }

  get(threadId: string): ThreadRuntime | undefined {
    return this.runtimes.get(threadId);
  }

  /** 新会话：ID 由适配器生成，第一次 turn 时以同一 ID 创建 Claude 会话。 */
  create(cwd: string, settings: RunSettings): ThreadRuntime {
    const runtime = new ThreadRuntime(randomUUID(), cwd, this.host, settings, false);
    this.runtimes.set(runtime.threadId, runtime);
    this.titles.set(runtime.threadId, null);
    return runtime;
  }

  /**
   * 已有 transcript 的会话：进程推迟到第一次 turn 再以 resume 拉起。title 是 transcript 里
   * 此刻的标题：复用运行时也据此对齐缓存（客户端都断开时 CLI 可能改过名），变了就推给其他
   * 订阅者；否则之后改回原名会被当成「没变」吞掉。读不到标题时保留已知的。
   */
  open(threadId: string, cwd: string, settings: RunSettings, title: string | null = null): ThreadRuntime {
    if (!this.titles.has(threadId)) this.titles.set(threadId, title);
    else if (title) this.titleChanged(threadId, title);
    const existing = this.runtimes.get(threadId);
    if (existing) return existing;
    const runtime = new ThreadRuntime(threadId, cwd, this.host, settings, true);
    this.runtimes.set(threadId, runtime);
    return runtime;
  }

  subscribe(threadId: string, session: Session): void {
    this.ownership.start();
    if (!this.subscribers.get(threadId)?.has(session)) logger.debug("thread.subscribe", { thread: threadId, session: session.key });
    const sessions = this.subscribers.get(threadId) ?? new Set<Session>();
    sessions.add(session);
    this.subscribers.set(threadId, sessions);
    const threads = this.subscriptions.get(session) ?? new Set<string>();
    threads.add(threadId);
    this.subscriptions.set(session, threads);
    // 新订阅的连接也要能答复已经悬着的审批。
    for (const [id, request] of this.pending) {
      if (request.threadId === threadId && !session.hasOutstanding(id)) {
        session.publishRequest(id, request.method, request.params);
      }
    }
  }

  unsubscribeSession(session: Session): void {
    logger.debug("session.unsubscribe", { session: session.key, threads: this.subscriptions.get(session)?.size ?? 0 });
    for (const threadId of this.subscriptions.get(session) ?? []) {
      const sessions = this.subscribers.get(threadId);
      sessions?.delete(session);
      if (!sessions?.size && !this.runtimes.get(threadId)?.hasLiveProcess()) this.ownership.forget(threadId);
    }
    this.subscriptions.delete(session);
  }

  private *trackedThreads(): Iterable<string> {
    for (const [threadId, sessions] of this.subscribers) if (sessions.size) yield threadId;
    for (const [threadId, runtime] of this.runtimes) {
      if (runtime.hasLiveProcess() && !this.subscribers.get(threadId)?.size) yield threadId;
    }
  }

  /**
   * 持有方变化：别处接手且自己还握着进程时先让出（停进程、turn 记为中断），再把新的
   * 可写状态与持有方摘要推给订阅者。字段与 Thread 上的扩展字段同名，客户端按同一套解析。
   */
  private async ownershipChanged(threadId: string, holder: SessionHolder | undefined): Promise<void> {
    const runtime = this.runtimes.get(threadId);
    logger.debug("ownership.changed", {
      thread: threadId,
      holder: holder?.pid ?? null,
      entrypoint: holder?.entrypoint ?? null,
      status: holder?.status ?? null,
      adapterProcess: runtime?.hasLiveProcess() ?? false,
    });
    if (holder && runtime?.hasLiveProcess()) {
      // 扫描结果可能已经过时：持有方刚退出、并发的 turn/start 又拉起了自己的进程。停进程前
      // 重读登记，确认同一个持有方（pid 与启动时间）仍在；不在就不让出，交给下一次扫描按最新
      // 状态重新判断并推送。
      const current = (await this.holders()).get(threadId);
      if (!current || current.pid !== holder.pid || current.startedAt !== holder.startedAt) {
        logger.debug("ownership.stale", { thread: threadId, holder: holder.pid, current: current?.pid ?? null });
        void this.ownership.scanNow();
        return;
      }
      // 让出的细节（会话 ID、pid）由 claude.yield 在 debug 级别记录，只在诊断窗口内落盘。
      await runtime.yieldToHolder();
    }
    const status = runtime?.activeTurnId
      ? { type: "active", activeFlags: [] }
      : runtime?.hasLiveProcess()
        ? { type: "idle" }
        : { type: "notLoaded" };
    this.publish(threadId, "thread/status/changed", {
      threadId,
      status,
      canAcceptDirectInput: !holder,
      claudeOwner: holder ? ownerSummary(holder) : null,
    });
  }

  /** 标题变了（agentd 改名、CLI /rename 或 Claude Code 的 AI 标题）：推给订阅者。 */
  titleChanged(threadId: string, title: string): void {
    if (this.titles.get(threadId) === title) return;
    this.titles.set(threadId, title);
    this.publish(threadId, "thread/name/updated", { threadId, threadName: title });
  }

  private scheduleTitleChecks(threadId: string): void {
    const readTitle = this.options.readTitle;
    if (!readTitle) return;
    for (const delay of this.options.titleCheckDelaysMs ?? TITLE_CHECK_DELAYS_MS) {
      const timer = setTimeout(() => {
        void readTitle(threadId)
          .then((title) => {
            if (title) this.titleChanged(threadId, title);
          })
          .catch(() => {});
      }, delay);
      timer.unref?.();
    }
  }

  /** thread/loaded/list：有常驻 Claude 进程或进行中 turn 的会话。 */
  loadedThreadIds(): string[] {
    return [...this.runtimes.values()].filter((runtime) => runtime.isLoaded()).map((runtime) => runtime.threadId).sort();
  }

  isSessionBusy(session: Session): boolean {
    for (const threadId of this.subscriptions.get(session) ?? []) {
      if (this.runtimes.get(threadId)?.isBusy()) return true;
    }
    return false;
  }

  /** 会话里最近一次观测到的额度（rate_limit_event），account/rateLimits/read 的降级来源。 */
  get observedRateLimits(): RateLimitSnapshot | undefined {
    return this.lastRateLimits;
  }

  publish(threadId: string, method: string, params: Record<string, unknown>): void {
    if (method === "account/rateLimits/updated") {
      this.lastRateLimits = mergeObservedRateLimits(this.lastRateLimits, params.rateLimits as RateLimitSnapshot);
    }
    const frame = notificationFrame(method, params);
    for (const session of this.subscribers.get(threadId) ?? []) session.publish(frame);
  }

  private request(threadId: string, method: string, params: Record<string, unknown>, signal: AbortSignal): Promise<unknown> {
    const id = `mimi-${++this.counter}`;
    logger.debug("approval.request", { id, method, thread: threadId, subscribers: this.subscribers.get(threadId)?.size ?? 0 });
    return new Promise((resolve, reject) => {
      this.pending.set(id, { threadId, method, params, resolve, reject });
      for (const session of this.subscribers.get(threadId) ?? []) session.publishRequest(id, method, params);
      // Claude 侧取消（中断、进程退出）时撤回请求，各连接同步收起卡片。
      signal.addEventListener("abort", () => this.settle(id, { error: new Error("request aborted") }), { once: true });
    });
  }

  /**
   * 请求 ID 可预测，只接受当前连接对自己收到过的请求的答复：别的会话或已被替换的旧连接
   * 不能代为批准或拒绝。
   */
  handleClientResponse(session: Session, generation: number, frame: Record<string, unknown>): void {
    const id = String(frame.id);
    if (!this.pending.has(id) || !session.isCurrent(generation) || !session.hasOutstanding(id)) {
      logger.debug("approval.response.ignored", {
        id,
        session: session.key,
        reason: !this.pending.has(id) ? "not_pending" : !session.isCurrent(generation) ? "stale_connection" : "not_delivered",
      });
      return;
    }
    if ("error" in frame) this.settle(id, { error: new Error(JSON.stringify(frame.error)) });
    else this.settle(id, { result: frame.result });
  }

  private settle(id: string, outcome: { result?: unknown; error?: Error }): void {
    const request = this.pending.get(id);
    if (!request) return;
    this.pending.delete(id);
    logger.debug("approval.settled", { id, thread: request.threadId, outcome: outcome.error ? "cancelled_or_error" : "answered" });
    for (const session of this.subscribers.get(request.threadId) ?? []) session.resolveRequest(id);
    if (outcome.error) request.reject(outcome.error);
    else request.resolve(outcome.result);
    this.publish(request.threadId, "serverRequest/resolved", { threadId: request.threadId, requestId: id });
  }

  async closeAll(): Promise<void> {
    this.ownership.stop();
    await Promise.all([...this.runtimes.values()].map((runtime) => runtime.close()));
  }
}
