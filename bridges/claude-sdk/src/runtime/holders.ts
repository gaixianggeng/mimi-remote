// Claude Code 在 `<配置目录>/sessions/<pid>.json` 登记每个活进程持有的会话，进程退出时删除。
// 这是唯一没有公开接口的依赖：只读，用于判断会话是否被终端或桌面端占用、接管与让出。
import { readFile, readdir } from "node:fs/promises";
import path from "node:path";
import { claudeConfigDir } from "../claude/transcripts.ts";
import type { ThreadStatus } from "../protocol/codex/v2/ThreadStatus.ts";

export interface SessionHolder {
  pid: number;
  entrypoint: string | null;
  kind: string | null;
  status: string | null;
  version: string | null;
  /** CLI 自身启动时刻（epoch 毫秒）；接管前用它核对 pid 没有被别的进程复用。 */
  startedAt: number | null;
  /** `status` 最近一次变化的时刻（epoch 毫秒）；客户端据此显示"已处理多久"。 */
  statusUpdatedAt: number | null;
}

export interface HolderRecord extends SessionHolder {
  sessionId: string;
}

/** 哪些登记属于本适配器自己。 */
export interface OwnProcesses {
  /** 本适配器起的 Claude 进程。 */
  pids: ReadonlySet<number>;
  /**
   * 进程已起、pid 还没拿到的会话 → 起进程的时刻。这段时间里该会话新出现的登记可能就是
   * 自己的进程，先不算别处持有，拿到 pid 后再判断。
   */
  startingSince(sessionId: string): number | undefined;
}

/** 登记写在 CLI 初始化之后，比起进程的时刻晚；留出余量，宁可推迟判断也不误认。 */
const STARTING_SLACK_MS = 1_000;

export function sessionsDir(): string {
  return path.join(claudeConfigDir(), "sessions");
}

export function pidAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === "EPERM";
  }
}

/** 回给客户端的摘要：不带 cwd、启动时间，客户端只需要知道谁在持有、是否在执行、执行了多久。 */
export function ownerSummary(holder: SessionHolder): Record<string, unknown> {
  return {
    pid: holder.pid,
    entrypoint: holder.entrypoint,
    kind: holder.kind,
    status: holder.status,
    version: holder.version,
    statusUpdatedAt: holder.statusUpdatedAt,
  };
}

export function isBusyHolder(holder: SessionHolder): boolean {
  return holder.status === "busy" || holder.status === "shell";
}

/**
 * 会话此刻的运行状态，三方来源合成一个答案：本适配器的 turn、本适配器的常驻进程、别处的持有方。
 * 持有方正在执行（终端 / 桌面端里 Claude 在跑）同样是 `active`——客户端据此把它排进"进行中"，
 * 而不是当成一条已经结束的历史；持有方空闲算 `idle`（已加载、没在跑）。
 */
export function liveThreadStatus(input: {
  ownTurnActive: boolean;
  ownProcessLive: boolean;
  holder: SessionHolder | undefined;
}): ThreadStatus {
  if (input.ownTurnActive) return { type: "active", activeFlags: [] };
  if (input.holder && isBusyHolder(input.holder)) return { type: "active", activeFlags: [] };
  if (input.ownProcessLive || input.holder) return { type: "idle" };
  return { type: "notLoaded" };
}

const text = (value: unknown) => (typeof value === "string" && value ? value : null);

function parseRecord(raw: string): HolderRecord | undefined {
  let record: Record<string, unknown>;
  try {
    record = JSON.parse(raw) as Record<string, unknown>;
  } catch {
    return undefined;
  }
  const pid = Number(record.pid);
  const sessionId = record.sessionId;
  if (!Number.isInteger(pid) || pid <= 0 || typeof sessionId !== "string" || !sessionId) return undefined;
  const startedAt = Number(record.startedAt);
  const statusUpdatedAt = Number(record.statusUpdatedAt);
  return {
    sessionId,
    pid,
    entrypoint: text(record.entrypoint),
    kind: text(record.kind),
    status: text(record.status),
    version: text(record.version),
    startedAt: Number.isFinite(startedAt) && startedAt > 0 ? startedAt : null,
    statusUpdatedAt: Number.isFinite(statusUpdatedAt) && statusUpdatedAt > 0 ? statusUpdatedAt : null,
  };
}

/**
 * 全部活着、不属于本适配器的登记。目录不存在、单个文件损坏都按"无持有方"处理：
 * 探测失败不能变成拒绝服务。进程崩溃会留下残余文件，所以必须核对 pid 是否还活着。
 */
export async function readHolderRecords(own: OwnProcesses): Promise<HolderRecord[]> {
  const dir = sessionsDir();
  const names = await readdir(dir).catch(() => [] as string[]);
  const records = await Promise.all(
    names
      .filter((name) => name.endsWith(".json"))
      .map(async (name) => {
        const raw = await readFile(path.join(dir, name), "utf8").catch(() => undefined);
        return raw ? parseRecord(raw) : undefined;
      }),
  );
  const seen = new Set<number>();
  return records.filter((record): record is HolderRecord => {
    if (!record || seen.has(record.pid) || own.pids.has(record.pid) || !pidAlive(record.pid)) return false;
    const starting = own.startingSince(record.sessionId);
    if (starting !== undefined && (record.startedAt === null || record.startedAt >= starting - STARTING_SLACK_MS)) return false;
    seen.add(record.pid);
    return true;
  });
}

/** 会话 ID → 别处持有方。同一会话有多个进程时取正在执行的那个，客户端提示更准确。 */
export async function readHolders(own: OwnProcesses): Promise<Map<string, SessionHolder>> {
  const holders = new Map<string, SessionHolder>();
  for (const { sessionId, ...holder } of await readHolderRecords(own)) {
    const existing = holders.get(sessionId);
    if (existing && isBusyHolder(existing) && !isBusyHolder(holder)) continue;
    holders.set(sessionId, holder);
  }
  return holders;
}

/** 某个会话的全部别处持有方，不去重：接管必须把每一个都结束，否则剩下的仍会分叉。 */
export async function holdersOf(sessionId: string, own: OwnProcesses): Promise<SessionHolder[]> {
  return (await readHolderRecords(own))
    .filter((record) => record.sessionId === sessionId)
    .map(({ sessionId: _, ...holder }) => holder);
}
