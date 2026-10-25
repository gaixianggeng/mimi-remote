// 盯着占用登记目录，发现会话换了持有方（终端 `claude --resume` 接手、持有方退出、空闲与执行
// 切换）就回调。关注范围是"有订阅或有常驻进程的会话"加上"登记里出现过的每个会话"：列表页没有
// 订阅任何会话，终端里开着的会话开始 / 结束处理也要能推到列表。目录事件让反应在毫秒级；
// 轮询兜底，防止事件丢失或目录稍后才出现。
import { watch, type FSWatcher } from "node:fs";
import { nextFreshnessMark } from "../util/freshness.ts";
import { ownerSummary, type SessionHolder } from "./holders.ts";

export interface OwnershipWatcherOptions {
  dir: string;
  /** 需要关注的会话（有订阅或有常驻进程）。 */
  tracked(): Iterable<string>;
  read(): Promise<Map<string, SessionHolder>>;
  /**
   * `freshSince`：本轮读完登记时取的先后标记（nextFreshnessMark）。同一轮里的各个变化共用它：
   * 晚于它开始的 transcript 索引扫描已包含持有方报告空闲前写下的内容，不必每个变化各扫一次（#912）。
   */
  onChange(threadId: string, holder: SessionHolder | undefined, freshSince: number): Promise<void> | void;
  log(message: string): void;
  pollMs?: number;
}

/** 去重覆盖客户端收到的整份摘要，避免同一进程的新一轮执行沿用旧起点。 */
function stateKey(holder: SessionHolder | undefined): string {
  return holder ? JSON.stringify(ownerSummary(holder)) : "";
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
    const tracked = new Set(this.options.tracked());
    let holders: Map<string, SessionHolder>;
    try {
      holders = await this.options.read();
    } catch (error) {
      this.options.log(`ownership scan failed: ${error instanceof Error ? error.message : String(error)}`);
      return;
    }
    const freshSince = nextFreshnessMark();
    // 上次见过持有方、这次登记里没有了的会话也要扫到，否则"持有方退出"推不出去。
    const candidates = new Set([...tracked, ...holders.keys(), ...this.known.keys()]);
    for (const threadId of candidates) {
      const holder = holders.get(threadId);
      const key = stateKey(holder);
      if ((this.known.get(threadId) ?? "") === key) continue;
      // 不再被关注、也没有持有方的会话不留记录，known 只随登记与订阅增长。
      if (key === "" && !tracked.has(threadId)) this.known.delete(threadId);
      else this.known.set(threadId, key);
      try {
        await this.options.onChange(threadId, holder, freshSince);
      } catch (error) {
        this.options.log(`ownership change for ${threadId.slice(0, 8)} failed: ${error instanceof Error ? error.message : String(error)}`);
      }
    }
  }
}
