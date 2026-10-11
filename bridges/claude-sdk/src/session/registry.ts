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

  get size(): number {
    return this.sessions.size;
  }
}
