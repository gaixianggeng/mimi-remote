import type { OutboundFrame } from "../rpc/frames.ts";
import { Session } from "./session.ts";

export interface RegistryOptions {
  /** 未连接且没有进行中工作的会话保留多久。 */
  idleTtlMs: number;
  /** 会话被回收时通知（取消它对会话的订阅等）。 */
  onExpire?: (session: Session) => void;
}

const DEFAULT_OPTIONS: RegistryOptions = { idleTtlMs: 600_000 };

/** 按 sessionKey 保存会话，定期回收长期断开且空闲的会话。 */
export class SessionRegistry {
  private readonly sessions = new Map<string, Session>();
  private timer: ReturnType<typeof setInterval> | undefined;

  /** 新建会话时的钩子（挂上忙碌判断等）。 */
  onCreate: ((session: Session) => void) | undefined;

  constructor(private readonly options: RegistryOptions = DEFAULT_OPTIONS) {}

  resolve(key: string): { session: Session; existed: boolean } {
    const existing = this.sessions.get(key);
    if (existing) return { session: existing, existed: true };
    const session = new Session(key);
    this.onCreate?.(session);
    this.sessions.set(key, session);
    return { session, existed: false };
  }

  sweep(now = Date.now()): void {
    for (const [key, session] of this.sessions) {
      if (!session.isBusy() && session.detachedLongerThan(this.options.idleTtlMs, now)) {
        this.sessions.delete(key);
        this.options.onExpire?.(session);
      }
    }
  }

  startReaper(): void {
    if (this.timer) return;
    const interval = Math.max(1_000, Math.min(30_000, this.options.idleTtlMs / 4));
    this.timer = setInterval(() => this.sweep(), interval);
    this.timer.unref?.();
  }

  stopReaper(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
  }

  /**
   * 面向全部具名会话的通知（例如列表级的持有方变化），不区分谁订阅了哪个会话。`alsoTo` 是
   * 不在注册表里、但订阅了相关会话的连接（stdio 模式或没有 attach 的匿名连接）：同样要收到，
   * 每个连接只发一次。
   */
  publishAll(frame: OutboundFrame, alsoTo: Iterable<Session> = []): void {
    const delivered = new Set<Session>();
    for (const session of this.sessions.values()) {
      delivered.add(session);
      session.publish(frame);
    }
    for (const session of alsoTo) {
      if (delivered.has(session)) continue;
      delivered.add(session);
      session.publish(frame);
    }
  }

  get size(): number {
    return this.sessions.size;
  }
}
