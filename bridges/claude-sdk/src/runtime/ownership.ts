// 盯着占用登记目录，发现被关注的会话换了持有方（终端 `claude --resume` 接手、持有方退出、
// 空闲与执行切换）就回调。目录事件让反应在毫秒级；轮询兜底，防止事件丢失或目录稍后才出现。
import { watch, type FSWatcher } from "node:fs";
import { isBusyHolder, type SessionHolder } from "./holders.ts";

export interface OwnershipWatcherOptions {
  dir: string;
  /** 需要关注的会话（有订阅或有常驻进程）。 */
  tracked(): Iterable<string>;
  read(): Promise<Map<string, SessionHolder>>;
  onChange(threadId: string, holder: SessionHolder | undefined): Promise<void> | void;
  log(message: string): void;
  pollMs?: number;
}

/** 客户端关心的只有"谁在持有、是否在执行"。 */
function stateKey(holder: SessionHolder | undefined): string {
  return holder ? `${holder.pid}:${isBusyHolder(holder) ? "busy" : (holder.status ?? "")}` : "";
}

export class OwnershipWatcher {
  private readonly known = new Map<string, string>();
  private watcher: FSWatcher | undefined;
  private timer: ReturnType<typeof setInterval> | undefined;
  private debounce: ReturnType<typeof setTimeout> | undefined;
  private scanning: Promise<void> | undefined;
  private rescan = false;

  constructor(private readonly options: OwnershipWatcherOptions) {}

  start(): void {
    if (this.timer) return;
    this.timer = setInterval(() => this.schedule(), this.options.pollMs ?? 2_000);
    this.timer.unref?.();
    this.watchDir();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    if (this.debounce) clearTimeout(this.debounce);
    this.watcher?.close();
    this.timer = undefined;
    this.debounce = undefined;
    this.watcher = undefined;
  }

  /** 不再关注的会话下次重新关注时，按客户端拿到的最新状态重新起算。 */
  forget(threadId: string): void {
    this.known.delete(threadId);
  }

  /** 立即扫一次（例如自己的进程刚拿到 pid）；返回本次扫描完成的 Promise。 */
  scanNow(): Promise<void> {
    if (this.scanning) {
      this.rescan = true;
      return this.scanning;
    }
    this.scanning = this.scan().finally(() => {
      this.scanning = undefined;
      if (this.rescan) {
        this.rescan = false;
        void this.scanNow();
      }
    });
    return this.scanning;
  }

  private schedule(): void {
    if (!this.watcher) this.watchDir();
    if (this.debounce) return;
    this.debounce = setTimeout(() => {
      this.debounce = undefined;
      void this.scanNow();
    }, 20);
    this.debounce.unref?.();
  }

  private watchDir(): void {
    try {
      this.watcher = watch(this.options.dir, () => this.schedule());
      this.watcher.on("error", () => {
        this.watcher?.close();
        this.watcher = undefined;
      });
    } catch {
      // 目录还不存在：靠轮询，下次 schedule 再试。
      this.watcher = undefined;
    }
  }

  private async scan(): Promise<void> {
    const tracked = [...this.options.tracked()];
    if (!tracked.length) return;
    let holders: Map<string, SessionHolder>;
    try {
      holders = await this.options.read();
    } catch (error) {
      this.options.log(`ownership scan failed: ${error instanceof Error ? error.message : String(error)}`);
      return;
    }
    for (const threadId of tracked) {
      const holder = holders.get(threadId);
      const key = stateKey(holder);
      if ((this.known.get(threadId) ?? "") === key) continue;
      this.known.set(threadId, key);
      try {
        await this.options.onChange(threadId, holder);
      } catch (error) {
        this.options.log(`ownership change for ${threadId.slice(0, 8)} failed: ${error instanceof Error ? error.message : String(error)}`);
      }
    }
  }
}
