import { Session } from "./session.ts";

export interface RegistryOptions {
  /** 未连接且没有进行中工作的会话保留多久。 */
  idleTtlMs: number;
}

const DEFAULT_OPTIONS: RegistryOptions = { idleTtlMs: 600_000 };

/** 按 sessionKey 保存会话，定期回收长期断开且空闲的会话。 */
export class SessionRegistry {
  private readonly sessions = new Map<string, Session>();
  private timer: ReturnType<typeof setInterval> | undefined;

  constructor(private readonly options: RegistryOptions = DEFAULT_OPTIONS) {}

  resolve(key: string): { session: Session; existed: boolean } {
    const existing = this.sessions.get(key);
    if (existing) return { session: existing, existed: true };
    const session = new Session(key);
    this.sessions.set(key, session);
    return { session, existed: false };
  }

  sweep(now = Date.now()): void {
    for (const [key, session] of this.sessions) {
      if (!session.isBusy() && session.detachedLongerThan(this.options.idleTtlMs, now)) {
        this.sessions.delete(key);
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
