// 管理所有 Claude 会话运行时：订阅关系、事件扇出、服务端请求与客户端答复的配对。
// 订阅了同一会话的每个连接（例如 iPad 与 iPhone）都收到事件和审批；谁先答复以谁为准，
// 其余连接收到 serverRequest/resolved。
import { randomUUID } from "node:crypto";
import { notificationFrame } from "../rpc/frames.ts";
import type { Session } from "../session/session.ts";
import type { RunSettings } from "./settings.ts";
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
}

export class ThreadManager {
  private readonly runtimes = new Map<string, ThreadRuntime>();
  private readonly subscribers = new Map<string, Set<Session>>();
  private readonly subscriptions = new Map<Session, Set<string>>();
  private readonly pending = new Map<string, PendingRequest>();
  private counter = 0;
  readonly ownPids = new Set<number>();
  private readonly host: RuntimeHost;

  constructor(options: ManagerOptions) {
    this.host = {
      publish: (threadId, method, params) => this.publish(threadId, method, params),
      request: (threadId, method, params, signal) => this.request(threadId, method, params, signal),
      claudeExecutable: options.claudeExecutable,
      log: options.log,
      ownPids: this.ownPids,
      idleCloseMs: options.idleCloseMs ?? 10 * 60_000,
      ...(options.startQuery ? { startQuery: options.startQuery } : {}),
    };
  }

  get(threadId: string): ThreadRuntime | undefined {
    return this.runtimes.get(threadId);
  }

  /** 新会话：ID 由适配器生成，第一次 turn 时以同一 ID 创建 Claude 会话。 */
  create(cwd: string, settings: RunSettings): ThreadRuntime {
    const runtime = new ThreadRuntime(randomUUID(), cwd, this.host, settings, false);
    this.runtimes.set(runtime.threadId, runtime);
    return runtime;
  }

  /** 已有 transcript 的会话：进程推迟到第一次 turn 再以 resume 拉起。 */
  open(threadId: string, cwd: string, settings: RunSettings): ThreadRuntime {
    const existing = this.runtimes.get(threadId);
    if (existing) return existing;
    const runtime = new ThreadRuntime(threadId, cwd, this.host, settings, true);
    this.runtimes.set(threadId, runtime);
    return runtime;
  }

  subscribe(threadId: string, session: Session): void {
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
    for (const threadId of this.subscriptions.get(session) ?? []) this.subscribers.get(threadId)?.delete(session);
    this.subscriptions.delete(session);
  }

  isSessionBusy(session: Session): boolean {
    for (const threadId of this.subscriptions.get(session) ?? []) {
      if (this.runtimes.get(threadId)?.isBusy()) return true;
    }
    return false;
  }

  publish(threadId: string, method: string, params: Record<string, unknown>): void {
    const frame = notificationFrame(method, params);
    for (const session of this.subscribers.get(threadId) ?? []) session.publish(frame);
  }

  private request(threadId: string, method: string, params: Record<string, unknown>, signal: AbortSignal): Promise<unknown> {
    const id = `mimi-${++this.counter}`;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { threadId, method, params, resolve, reject });
      for (const session of this.subscribers.get(threadId) ?? []) session.publishRequest(id, method, params);
      // Claude 侧取消（中断、进程退出）时撤回请求，各连接同步收起卡片。
      signal.addEventListener("abort", () => this.settle(id, { error: new Error("request aborted") }), { once: true });
    });
  }

  handleClientResponse(frame: Record<string, unknown>): void {
    const id = String(frame.id);
    if (!this.pending.has(id)) return;
    if ("error" in frame) this.settle(id, { error: new Error(JSON.stringify(frame.error)) });
    else this.settle(id, { result: frame.result });
  }

  private settle(id: string, outcome: { result?: unknown; error?: Error }): void {
    const request = this.pending.get(id);
    if (!request) return;
    this.pending.delete(id);
    for (const session of this.subscribers.get(request.threadId) ?? []) session.resolveRequest(id);
    if (outcome.error) request.reject(outcome.error);
    else request.resolve(outcome.result);
    this.publish(request.threadId, "serverRequest/resolved", { threadId: request.threadId, requestId: id });
  }

  async closeAll(): Promise<void> {
    await Promise.all([...this.runtimes.values()].map((runtime) => runtime.close()));
  }
}
