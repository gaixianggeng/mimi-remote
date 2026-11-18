import type { RateLimitSnapshot } from "@mimi/appserver-kit/protocol/codex/v2/RateLimitSnapshot.ts";
import type { Turn } from "@mimi/appserver-kit/protocol/codex/v2/Turn.ts";
import { notificationFrame } from "@mimi/appserver-kit/rpc/frames.ts";
import type { Session } from "@mimi/appserver-kit/session/session.ts";
import { logger } from "../util/logging.ts";
import type { AcpAvailableCommand, AcpSessionOpenResult } from "../acp/types.ts";
import type { SpawnAgyTransport } from "../agy/binary.ts";
import type { AgyRunSettings } from "./settings.ts";
import { ThreadRuntime, type RuntimeHost } from "./threadRuntime.ts";

interface PendingRequest {
  threadId: string;
  method: string;
  params: Record<string, unknown>;
  resolve(value: unknown): void;
  reject(error: Error): void;
}

export interface ManagerOptions {
  agyExecutable(): string;
  spawnTransport: SpawnAgyTransport;
  env?: () => NodeJS.ProcessEnv;
  idleCloseMs?: number;
  onSessionOpen?: (openResult: AcpSessionOpenResult) => void;
  onAvailableCommands?: (cwd: string, commands: AcpAvailableCommand[]) => void;
  onTurnPersisted?: (threadId: string, patch: { preview?: string; updatedAt?: number }) => void;
  hasCustomTitle?: (threadId: string) => boolean;
}

export function unavailableAgyRateLimits(): RateLimitSnapshot {
  return {
    limitId: "agy",
    limitName: "Antigravity",
    normalModelSlug: null,
    primary: null,
    secondary: null,
    credits: null,
    individualLimit: null,
    spendControlReached: null,
    planType: null,
    rateLimitReachedType: null,
    availability: "unavailable",
    unavailableReason: "headless_statusline_unavailable",
  } as RateLimitSnapshot;
}

export class ThreadManager {
  private readonly runtimes = new Map<string, ThreadRuntime>();
  private readonly subscribers = new Map<string, Set<Session>>();
  private readonly subscriptions = new Map<Session, Set<string>>();
  private readonly pending = new Map<string, PendingRequest>();
  private counter = 0;
  private readonly host: RuntimeHost;

  constructor(private readonly options: ManagerOptions) {
    this.host = {
      publish: (threadId, method, params) => this.publish(threadId, method, params),
      request: (threadId, method, params, signal) => this.request(threadId, method, params, signal),
      agyExecutable: options.agyExecutable,
      spawnTransport: options.spawnTransport,
      env: options.env ?? (() => process.env),
      idleCloseMs: options.idleCloseMs ?? 10 * 60_000,
      onSessionOpen: options.onSessionOpen,
      onAvailableCommands: options.onAvailableCommands,
      onTitleUpdated: (threadId, title) => {
        if (!this.options.hasCustomTitle?.(threadId)) {
          this.titleChanged(threadId, title);
        }
      },
      onTurnPersisted: options.onTurnPersisted,
    };
  }

  get(threadId: string): ThreadRuntime | undefined {
    return this.runtimes.get(threadId);
  }

  inMemorySessionSnapshots(): ReadonlyMap<string, { cwd: string; createdAt: number; updatedAt: number; title: string | null }> {
    const out = new Map<string, { cwd: string; createdAt: number; updatedAt: number; title: string | null }>();
    for (const [id, runtime] of this.runtimes) {
      out.set(id, {
        cwd: runtime.cwd,
        createdAt: runtime.createdAt,
        updatedAt: runtime.updatedAt,
        title: runtime.title,
      });
    }
    return out;
  }

  liveTurns(threadId: string): Turn[] | undefined {
    return this.runtimes.get(threadId)?.liveHistoryTurns();
  }

  liveCommands(cwd: string): AcpAvailableCommand[] | undefined {
    for (const runtime of this.runtimes.values()) {
      if (runtime.cwd === cwd) {
        const cmds = runtime.liveCommands();
        if (cmds && cmds.length > 0) return cmds;
      }
    }
    return undefined;
  }

  async createNew(cwd: string, settings: AgyRunSettings): Promise<ThreadRuntime> {
    const runtime = new ThreadRuntime("", cwd, this.host, settings, false, null);
    const sessionId = await runtime.initializeNewSession();
    this.runtimes.set(sessionId, runtime);
    return runtime;
  }

  openExisting(threadId: string, cwd: string, settings: AgyRunSettings, title: string | null): ThreadRuntime {
    const existing = this.runtimes.get(threadId);
    if (existing) {
      if (title && !existing.title) existing.title = title;
      return existing;
    }
    const created = new ThreadRuntime(threadId, cwd, this.host, settings, true, title);
    this.runtimes.set(threadId, created);
    return created;
  }

  subscribe(threadId: string, session: Session): void {
    let subs = this.subscribers.get(threadId);
    if (!subs) {
      subs = new Set();
      this.subscribers.set(threadId, subs);
    }
    const alreadySubscribed = subs.has(session);
    subs.add(session);
    let threads = this.subscriptions.get(session);
    if (!threads) {
      threads = new Set();
      this.subscriptions.set(session, threads);
    }
    threads.add(threadId);

    if (!alreadySubscribed) {
      for (const [id, pending] of this.pending) {
        if (pending.threadId === threadId) {
          session.publishRequest(id, pending.method, pending.params);
        }
      }
    }
  }

  unsubscribeSession(session: Session): void {
    const threads = this.subscriptions.get(session);
    if (!threads) return;
    this.subscriptions.delete(session);
    for (const threadId of threads) {
      const subs = this.subscribers.get(threadId);
      if (!subs) continue;
      subs.delete(session);
      if (subs.size === 0) this.subscribers.delete(threadId);
    }
  }

  titleChanged(threadId: string, title: string): void {
    const runtime = this.runtimes.get(threadId);
    if (runtime) runtime.title = title;
    this.publish(threadId, "thread/name/updated", { threadId, threadName: title });
  }

  loadedThreadIds(): string[] {
    return [...this.runtimes.values()]
      .filter((runtime) => runtime.isLoaded())
      .map((runtime) => runtime.threadId)
      .sort();
  }

  isSessionBusy(session: Session): boolean {
    for (const threadId of this.subscriptions.get(session) ?? []) {
      if (this.runtimes.get(threadId)?.isBusy()) return true;
    }
    return false;
  }

  publish(threadId: string, method: string, params: Record<string, unknown>): void {
    const frame = notificationFrame(method, params);
    for (const session of this.subscribers.get(threadId) ?? []) {
      session.publish(frame);
    }
  }

  private request(threadId: string, method: string, params: Record<string, unknown>, signal: AbortSignal): Promise<unknown> {
    const id = `mimi-agy-${++this.counter}`;
    logger.debug("agy.approval.request", { id, method, thread: threadId });
    return new Promise((resolve, reject) => {
      this.pending.set(id, { threadId, method, params, resolve, reject });
      for (const session of this.subscribers.get(threadId) ?? []) {
        session.publishRequest(id, method, params);
      }
      signal.addEventListener("abort", () => this.settle(id, { error: new Error("request aborted") }), { once: true });
    });
  }

  handleClientResponse(session: Session, generation: number, frame: Record<string, unknown>): void {
    const id = String(frame.id);
    if (!this.pending.has(id) || !session.isCurrent(generation) || !session.hasOutstanding(id)) {
      return;
    }
    if ("error" in frame) this.settle(id, { error: new Error(JSON.stringify(frame.error)) });
    else this.settle(id, { result: frame.result });
  }

  private settle(id: string, outcome: { result?: unknown; error?: Error }): void {
    const req = this.pending.get(id);
    if (!req) return;
    this.pending.delete(id);
    for (const session of this.subscribers.get(req.threadId) ?? []) {
      session.resolveRequest(id);
    }
    if (outcome.error) req.reject(outcome.error);
    else req.resolve(outcome.result);
    this.publish(req.threadId, "serverRequest/resolved", { threadId: req.threadId, requestId: id });
  }

  async closeAll(): Promise<void> {
    await Promise.all([...this.runtimes.values()].map((runtime) => runtime.close()));
    this.runtimes.clear();
  }
}
