// 管理所有 Claude 会话运行时：订阅关系、事件扇出、服务端请求与客户端答复的配对，以及
// "同一会话同一时刻只有一个驱动方"：别处接手时让出、客户端要求时接管。
// 订阅了同一会话的每个连接（例如 iPad 与 iPhone）都收到事件和审批；谁先答复以谁为准，
// 其余连接收到 serverRequest/resolved。
import { randomUUID } from "node:crypto";
import type { RateLimitSnapshot } from "../protocol/codex/v2/RateLimitSnapshot.ts";
import { notificationFrame, type OutboundFrame } from "../rpc/frames.ts";
import type { Session } from "../session/session.ts";
import { errorText, logger } from "../util/logging.ts";
import { holdersOf, liveThreadStatus, ownerSummary, readHolders, sessionsDir, type OwnProcesses, type SessionHolder } from "./holders.ts";
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
import type { SlashCommand } from "@anthropic-ai/claude-agent-sdk";
import { ThreadRuntime, type RuntimeHost } from "./threadRuntime.ts";
import type { MimiTaskProposalStore } from "./turnHints.ts";

interface PendingRequest {
  threadId: string;
  method: string;
  params: Record<string, unknown>;
  resolve(value: unknown): void;
  reject(error: Error): void;
}

export interface ManagerOptions {
  claudeExecutable(): string;
  promptSuggestionsSupported?(): boolean;
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
  /** 会话失去最后一个订阅者后，空闲运行时等多久从管理器移除（#911）。 */
  reclaimDelayMs?: number;
  /**
   * 发给全部已附着连接的通知（持有方变化）。列表页不订阅任何会话，只有这样它才能知道终端里的
   * 会话开始 / 结束处理。`subscribers` 是该会话的订阅者：其中不在注册表里的匿名连接也要收到，
   * 实现方负责去重。缺省时退回只发给订阅者。
   */
  broadcast?: (frame: OutboundFrame, subscribers: Iterable<Session>) => void;
  /**
   * 会话最后一条对话消息的时间（Unix 秒），随持有方变化一起推送，客户端据此刷新列表时间与未读。
   * 结果必须反映 `freshSince` 之后的 transcript（见 OwnershipWatcherOptions.onChange）。
   */
  readActivity?: (threadId: string, freshSince: number) => Promise<number | undefined>;
  turnHints?: {
    store: MimiTaskProposalStore & { isTaskProposal(parentThreadId: string, proposalId: string): boolean };
  };
}

/** Claude Code 在第一轮前后异步生成 AI 标题，通常几秒内写入；稍后再看几次。 */
const TITLE_CHECK_DELAYS_MS = [0, 2_000, 8_000, 30_000];

/** 断线重连通常在一分钟内完成，期间保留运行时，重连后不必重建。 */
const RECLAIM_DELAY_MS = 60_000;

export class ThreadManager {
  private readonly runtimes = new Map<string, ThreadRuntime>();
  private readonly subscribers = new Map<string, Set<Session>>();
  private readonly subscriptions = new Map<Session, Set<string>>();
  private readonly suggestionRecipients = new Map<string, { turnId: string; sessions: Map<Session, number> }>();
  private readonly pending = new Map<string, PendingRequest>();
  private counter = 0;
  /** 已经推送给客户端（或客户端从会话快照里拿到）的标题。 */
  private readonly titles = new Map<string, string | null>();
  /** 没有订阅者的会话 → 回收检查的计时器；订阅时取消，到点时重新核对。 */
  private readonly reclaimTimers = new Map<string, ReturnType<typeof setTimeout>>();
  private lastRateLimits: RateLimitSnapshot | undefined;
  private terminal: ReadonlySet<string> = new Set();
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
      ...(options.promptSuggestionsSupported ? { promptSuggestionsSupported: options.promptSuggestionsSupported } : {}),
      log: options.log,
      ownPids: this.ownPids,
      processReady: () => void this.ownership.scanNow(),
      turnFinished: (threadId) => this.scheduleTitleChecks(threadId),
      terminalCommands: (names) => {
        this.terminal = new Set(names);
      },
      idleCloseMs: options.idleCloseMs ?? 10 * 60_000,
      ...(options.turnHints ? { turnHints: options.turnHints } : {}),
      ...(options.startQuery ? { startQuery: options.startQuery } : {}),
    };
    this.ownership = new OwnershipWatcher({
      dir: sessionsDir(),
      tracked: () => this.trackedThreads(),
      read: () => this.holders(),
      onChange: (threadId, holder, freshSince) => this.ownershipChanged(threadId, holder, freshSince),
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

  /** CLI 最近一次声明的终端专用命令；终端命令都是内置的，各会话相同。 */
  get terminalCommands(): ReadonlySet<string> {
    return this.terminal;
  }

  /** 同一工作区、同样设置来源的常驻进程的命令目录；没有时返回 undefined，由调用方另起进程读取。 */
  liveCommands(cwd: string, loadsSettings: boolean): Promise<SlashCommand[]> | undefined {
    for (const runtime of this.runtimes.values()) {
      if (runtime.cwd !== cwd) continue;
      const commands = runtime.liveCommands(loadsSettings);
      if (commands) return commands;
    }
    return undefined;
  }

  /** 新会话：ID 由适配器生成，第一次 turn 时以同一 ID 创建 Claude 会话。 */
  create(cwd: string, settings: RunSettings, threadId: string = randomUUID()): ThreadRuntime {
    const runtime = new ThreadRuntime(threadId, cwd, this.host, settings, false);
    this.runtimes.set(runtime.threadId, runtime);
    this.titles.set(runtime.threadId, null);
    this.scheduleReclaim(runtime.threadId);
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
    this.scheduleReclaim(threadId);
    return runtime;
  }

  /** 常驻模式一启动就盯住占用登记，列表级的持有方变化不必等到有人订阅。 */
  startOwnershipWatcher(): void {
    this.ownership.start();
  }

  subscribe(threadId: string, session: Session): void {
    this.ownership.start();
    this.cancelReclaim(threadId);
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
      this.subscribers.get(threadId)?.delete(session);
      this.suggestionRecipients.get(threadId)?.sessions.delete(session);
      if (!this.subscribers.get(threadId)?.size) this.scheduleReclaim(threadId);
    }
    this.subscriptions.delete(session);
  }

  /**
   * 运行时、标题缓存和空订阅集合只在会话还有订阅者或还在工作时保留（#911）。最后一个订阅者离开后
   * 稍等再核对：有进程（含后台任务）、进行中或预占的 turn、未答复的审批时不回收，稍后再看；
   * 进程由空闲关闭负责结束。回收后再次 resume 会按 transcript 重建；还没有 transcript 的新会话
   * （thread/start 之后尚未发出第一轮）只存在于运行时里，不回收，等它第一轮之后再退订时才重新安排。
   * 计时器回调是宏任务，handler 在 open 与 subscribe 之间只隔微任务，不会被它插进来。
   */
  private scheduleReclaim(threadId: string): void {
    if (this.reclaimTimers.has(threadId)) return;
    const timer = setTimeout(() => {
      this.reclaimTimers.delete(threadId);
      this.reclaimIfIdle(threadId);
    }, this.options.reclaimDelayMs ?? RECLAIM_DELAY_MS);
    timer.unref?.();
    this.reclaimTimers.set(threadId, timer);
  }

  private cancelReclaim(threadId: string): void {
    const timer = this.reclaimTimers.get(threadId);
    if (timer) clearTimeout(timer);
    this.reclaimTimers.delete(threadId);
  }

  private reclaimIfIdle(threadId: string): void {
    if (this.subscribers.get(threadId)?.size) return;
    this.subscribers.delete(threadId);
    const runtime = this.runtimes.get(threadId);
    if (runtime && !runtime.persisted) return;
    const hasPending = [...this.pending.values()].some((request) => request.threadId === threadId);
    if ((runtime && !runtime.isReclaimable()) || hasPending) {
      this.scheduleReclaim(threadId);
      return;
    }
    this.runtimes.delete(threadId);
    this.titles.delete(threadId);
    this.suggestionRecipients.delete(threadId);
    logger.debug("thread.reclaimed", { thread: threadId });
  }

  private *trackedThreads(): Iterable<string> {
    for (const [threadId, sessions] of this.subscribers) if (sessions.size) yield threadId;
    for (const [threadId, runtime] of this.runtimes) {
      if (runtime.hasLiveProcess() && !this.subscribers.get(threadId)?.size) yield threadId;
    }
  }

  /**
   * 持有方变化：别处接手且自己还握着进程时先让出（停进程、turn 记为中断），再把新的运行状态、
   * 可写状态与持有方摘要推给全部连接（没有广播通道时只推给订阅者）。字段与 Thread 上的扩展
   * 字段同名，客户端按同一套解析；`status` 与 thread/list 同源，持有方正在执行就是 active。
   */
  private async ownershipChanged(threadId: string, holder: SessionHolder | undefined, freshSince: number): Promise<void> {
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
    const status = liveThreadStatus({
      ownTurnActive: runtime?.activeTurnId !== undefined,
      ownProcessLive: runtime?.hasLiveProcess() ?? false,
      holder,
    });
    const updatedAt = await this.options.readActivity?.(threadId, freshSince).catch(() => undefined);
    const frame = notificationFrame("thread/status/changed", {
      threadId,
      status,
      canAcceptDirectInput: !holder,
      claudeOwner: holder ? ownerSummary(holder) : null,
      ...(updatedAt !== undefined ? { updatedAt } : {}),
    });
    const subscribers = this.subscribers.get(threadId) ?? new Set<Session>();
    if (this.options.broadcast) this.options.broadcast(frame, subscribers);
    else for (const session of subscribers) session.publish(frame);
  }

  /** 标题变了（agentd 改名、CLI /rename 或 Claude Code 的 AI 标题）：推给订阅者。 */
  titleChanged(threadId: string, title: string): void {
    if (this.titles.get(threadId) === title) return;
    // 没有运行时就没有订阅者，也就不必记住推过什么；下次 open 从 transcript 读标题。
    if (this.runtimes.has(threadId)) this.titles.set(threadId, title);
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
    if (method === "_mimi/turn/promptSuggestion") {
      const recipients = this.suggestionRecipients.get(threadId);
      this.suggestionRecipients.delete(threadId);
      if (!recipients || recipients.turnId !== params.turnId) return;
      for (const [session, generation] of recipients.sessions) {
        if (this.subscribers.get(threadId)?.has(session)) session.publishTransient(frame, generation);
      }
      return;
    }
    if (method === "turn/started") this.suggestionRecipients.delete(threadId);
    if (method === "turn/completed") {
      const turn = params.turn as { id?: string; status?: string } | undefined;
      this.suggestionRecipients.delete(threadId);
      if (turn?.id && turn.status === "completed") {
        const sessions = new Map<Session, number>();
        for (const session of this.subscribers.get(threadId) ?? []) {
          const generation = session.connectedGeneration;
          if (generation !== undefined) sessions.set(session, generation);
        }
        this.suggestionRecipients.set(threadId, { turnId: turn.id, sessions });
      }
    }
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
    for (const timer of this.reclaimTimers.values()) clearTimeout(timer);
    this.reclaimTimers.clear();
    await Promise.all([...this.runtimes.values()].map((runtime) => runtime.close()));
    this.suggestionRecipients.clear();
  }
}
