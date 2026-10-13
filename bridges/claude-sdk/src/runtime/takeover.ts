// thread/takeover：结束正持有某会话的本机 Claude 进程（终端 `claude`、Claude 桌面内置的
// Claude Code），让适配器以同一个会话 ID 续聊。规则沿用旧 bridge（#451 实测）：
// - 只在所有别处持有方明确 idle 时接管；busy / shell / 未知状态一律不发信号。
// - 发信号前核对 pid 存活、进程启动时间与登记 startedAt 吻合（防 pid 被别的进程复用）。
//   任一持有方核实不了就整体拒绝，一个信号都不发。
// - 交互式 claude 收到 SIGINT 即干净退出；SIGTERM 只是兜底，发之前重读登记，不用旧状态强杀。
// - 持有方退出后再扫一次：新 pid 认领同一会话（宿主自动重启）时报 holder_respawned 且不再
//   发信号，杜绝杀进程循环。
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { isBusyHolder, pidAlive, type SessionHolder } from "./holders.ts";

const execFileAsync = promisify(execFile);

export interface TakeoverTimeouts {
  /** SIGINT 后等待持有方退出。 */
  interruptGraceMs: number;
  /** SIGTERM 后等待持有方退出。 */
  terminateGraceMs: number;
  /** 持有方退出后观察是否有新进程认领同一会话。 */
  respawnGraceMs: number;
}

export const DEFAULT_TAKEOVER_TIMEOUTS: TakeoverTimeouts = {
  interruptGraceMs: 5_000,
  terminateGraceMs: 5_000,
  respawnGraceMs: 1_000,
};

/** 进程启动时间与登记 startedAt 允许的偏差。CLI 初始化后才写登记，实测相差约 2 秒。 */
const START_TIME_TOLERANCE_MS = 10_000;
const POLL_INTERVAL_MS = 200;

export type TakeoverReason =
  | "holder_busy"
  | "holder_state_unknown"
  | "holder_unverified"
  | "signal_failed"
  | "takeover_timeout"
  | "holder_respawned";

export class TakeoverError extends Error {
  constructor(
    readonly reason: TakeoverReason,
    readonly holder: SessionHolder,
    message: string,
  ) {
    super(message);
  }

  /** 等当前轮完成、状态更新或进程退出后可以手动重试；不自动排队接管。 */
  get retryable(): boolean {
    return this.reason === "takeover_timeout" || this.reason === "holder_busy" || this.reason === "holder_state_unknown";
  }
}

export type TakeoverOutcome =
  | { released: false }
  | { released: true; holders: SessionHolder[]; signal: "SIGINT" | "SIGTERM" };

export interface TakeoverDeps {
  /** 该会话当前全部别处持有方（已排除本适配器自己的进程与死进程）。 */
  holdersOf(sessionId: string): Promise<SessionHolder[]>;
  /** 内核记录的进程启动时间（epoch 毫秒）；查不到返回 undefined。 */
  processStartedAt(pid: number): Promise<number | undefined>;
  signal(pid: number, signal: "SIGINT" | "SIGTERM"): void;
  alive(pid: number): boolean;
  sleep(ms: number): Promise<void>;
}

/** `ps -o etime=` 的 `[[dd-]hh:]mm:ss` → 秒。 */
export function parseElapsed(value: string): number | undefined {
  const match = /^\s*(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+)\s*$/.exec(value);
  if (!match) return undefined;
  const [, days, hours, minutes, seconds] = match;
  return ((Number(days ?? 0) * 24 + Number(hours ?? 0)) * 60 + Number(minutes)) * 60 + Number(seconds);
}

/** 用已运行时长反推启动时刻：etime 在 macOS 与 Linux 上格式一致，不受时区影响。 */
export async function processStartedAt(pid: number): Promise<number | undefined> {
  if (process.platform === "win32") return undefined;
  try {
    const { stdout } = await execFileAsync("ps", ["-o", "etime=", "-p", String(pid)], { timeout: 2_000 });
    const elapsed = parseElapsed(stdout);
    return elapsed === undefined ? undefined : Date.now() - elapsed * 1_000;
  } catch {
    return undefined;
  }
}

export function systemTakeoverDeps(holdersOf: TakeoverDeps["holdersOf"]): TakeoverDeps {
  return {
    holdersOf,
    processStartedAt,
    signal: (pid, signal) => process.kill(pid, signal),
    alive: pidAlive,
    sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  };
}

async function verifyIdle(holders: SessionHolder[], deps: TakeoverDeps): Promise<void> {
  for (const holder of holders) {
    if (isBusyHolder(holder)) throw new TakeoverError("holder_busy", holder, `holder pid ${holder.pid} is still processing a turn`);
    if (holder.status !== "idle") {
      throw new TakeoverError("holder_state_unknown", holder, `holder pid ${holder.pid} has no confirmed idle state`);
    }
    await verifyIdentity(holder, deps);
  }
}

/** 登记文件可能是崩溃残留，pid 之后被别的程序复用就会误杀无关进程。 */
async function verifyIdentity(holder: SessionHolder, deps: TakeoverDeps): Promise<void> {
  const unverified = () =>
    new TakeoverError("holder_unverified", holder, `holder pid ${holder.pid} cannot be verified against its session registration`);
  if (holder.pid <= 1 || holder.pid === process.pid || holder.startedAt === null) throw unverified();
  const actual = await deps.processStartedAt(holder.pid);
  if (actual === undefined || Math.abs(actual - holder.startedAt) > START_TIME_TOLERANCE_MS) throw unverified();
}

function send(holder: SessionHolder, signal: "SIGINT" | "SIGTERM", deps: TakeoverDeps): void {
  try {
    deps.signal(holder.pid, signal);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new TakeoverError("signal_failed", holder, `failed to signal holder pid ${holder.pid}: ${message}`);
  }
}

async function waitForExit(holders: SessionHolder[], graceMs: number, deps: TakeoverDeps): Promise<SessionHolder[]> {
  const deadline = Date.now() + graceMs;
  while (true) {
    const alive = holders.filter((holder) => deps.alive(holder.pid));
    const now = Date.now();
    if (!alive.length || now >= deadline) return alive;
    await deps.sleep(Math.min(POLL_INTERVAL_MS, deadline - now));
  }
}

export async function releaseForeignHolders(
  sessionId: string,
  deps: TakeoverDeps,
  timeouts: TakeoverTimeouts = DEFAULT_TAKEOVER_TIMEOUTS,
): Promise<TakeoverOutcome> {
  const holders = await deps.holdersOf(sessionId);
  if (!holders.length) return { released: false };
  // 多个持有方必须全部空闲并通过核对，不能先结束空闲的、再发现另一个仍在忙。
  await verifyIdle(holders, deps);

  let signal: "SIGINT" | "SIGTERM" = "SIGINT";
  for (const holder of holders) send(holder, signal, deps);
  let survivors = await waitForExit(holders, timeouts.interruptGraceMs, deps);
  if (survivors.length) {
    // SIGINT 等待期间可能开始了新一轮；SIGTERM 前重查全部持有方。
    const current = await deps.holdersOf(sessionId);
    await verifyIdle(current, deps);
    signal = "SIGTERM";
    for (const holder of survivors) {
      if (!current.some((owner) => owner.pid === holder.pid && owner.startedAt === holder.startedAt)) {
        throw new TakeoverError("holder_unverified", holder, `holder pid ${holder.pid} changed while waiting for it to exit`);
      }
      send(holder, signal, deps);
    }
    survivors = await waitForExit(survivors, timeouts.terminateGraceMs, deps);
  }
  const stuck = survivors[0];
  if (stuck) throw new TakeoverError("takeover_timeout", stuck, `holder pid ${stuck.pid} did not exit after SIGINT and SIGTERM`);

  await deps.sleep(timeouts.respawnGraceMs);
  const known = new Set(holders.map((holder) => holder.pid));
  const newcomer = (await deps.holdersOf(sessionId)).find((holder) => !known.has(holder.pid));
  if (newcomer) {
    throw new TakeoverError("holder_respawned", newcomer, `a new process (pid ${newcomer.pid}) claimed the session after the holder exited`);
  }
  return { released: true, holders, signal };
}
