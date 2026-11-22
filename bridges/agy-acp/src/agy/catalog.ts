import { stat } from "node:fs/promises";
import os from "node:os";
import type { Turn } from "@mimi/appserver-kit/protocol/codex/v2/Turn.ts";
import type { AcpSessionSummary, AcpSessionUpdate } from "../acp/types.ts";
import { errorText, logger } from "../util/logging.ts";
import { SharedReadonlyAcp } from "./binary.ts";
import { conversationDbPath, hasOtherConversations, resolveSessionOrigin, type AgySessionOrigin } from "./env.ts";
import { directoryExists, type GitRepoIndex } from "./git.ts";
import { updatesToTurns } from "./history.ts";
import { parseTurnOrdinal, type AgyOverlay, type PersistedToolMapping, type TurnAttemptRecord, type TurnOutcomeRecord } from "./overlay.ts";
import { toolItemFingerprint, toolItemOutputFingerprint } from "./tools.ts";
import {
  inspectTranscriptActivity,
  readTranscriptTurns,
  resolveTranscriptPath,
  snapshotTranscriptState,
  snapshotTranscriptStateDetailed,
  type TranscriptActivityInfo,
  type TranscriptSnapshotResult,
  type TranscriptTurnSnapshot,
} from "./transcript.ts";

export interface SessionRecord {
  id: string;
  cwd: string;
  cwdMissing: boolean;
  name: string | null;
  preview: string;
  createdAt: number;
  updatedAt: number;
  gitBranch: string | null;
  path: string | null;
  archived: boolean;
  origin: AgySessionOrigin;
}

export interface DiskRevisionInfo {
  signature: string;
  mtimeMs: number;
  transcriptPath?: string;
}

export type OtherListDiagnostic =
  | { status: "ok"; count: number; elapsedMs: number }
  | { status: "empty"; count: 0; elapsedMs: number }
  | { status: "timeout"; timeoutMs: number; elapsedMs: number }
  | { status: "failed"; error: string; elapsedMs: number };

export interface AgySessionBackend {
  listSummaries(): Promise<AcpSessionSummary[]>;
  wasLastOtherListDegraded?(): boolean;
  loadReplay(sessionId: string, cwd: string, origin: AgySessionOrigin): Promise<AcpSessionUpdate[]>;
  resolveSessionOrigin(sessionId: string): Promise<AgySessionOrigin | null>;
  conversationFilePath(sessionId: string, origin: AgySessionOrigin): string | null;
  diskRevision?(sessionId: string, origin: AgySessionOrigin): Promise<DiskRevisionInfo | undefined>;
  inspectExternalActivity?(sessionId: string, origin: AgySessionOrigin): Promise<TranscriptActivityInfo | undefined>;
  snapshotTranscriptState?(sessionId: string, origin: AgySessionOrigin): Promise<TranscriptTurnSnapshot | undefined>;
  snapshotTranscriptStateDetailed?(sessionId: string, origin: AgySessionOrigin): Promise<TranscriptSnapshotResult>;
  loadTranscriptTurns?(
    sessionId: string,
    cwd: string,
    transcriptPath: string,
    running: boolean,
    holderActive: boolean,
  ): Promise<Turn[]>;
}

async function statSizeAndMtime(targetPath: string | undefined): Promise<{ size: number; mtimeMs: number } | undefined> {
  if (!targetPath) return undefined;
  try {
    const info = await stat(targetPath);
    return { size: info.size, mtimeMs: info.mtimeMs };
  } catch {
    return undefined;
  }
}

const DEFAULT_OTHER_LIST_TIMEOUT_MS = 2_500;
const DEFAULT_OTHER_LIST_HARD_TIMEOUT_MS = 12_000;
const OTHER_WARM_SNAPSHOT_REUSE_MS = 1_500;

function parsePositiveMs(raw: string | undefined): number | undefined {
  const trimmed = raw?.trim();
  if (!trimmed) return undefined;
  const parsed = Number(trimmed);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : undefined;
}

function otherListBudgets(env: NodeJS.ProcessEnv): { foregroundMs: number; hardMs: number } {
  const explicitFg = parsePositiveMs(env.AGY_ADAPTER_OTHER_LIST_TIMEOUT_MS);
  const explicitHard = parsePositiveMs(env.AGY_ADAPTER_OTHER_LIST_HARD_TIMEOUT_MS);
  const foregroundMs = explicitFg ?? DEFAULT_OTHER_LIST_TIMEOUT_MS;
  // 默认分离前台等待（2.5s）与后台冷索引完成上限（12s），避免真实 4.5s 的 Other 冷索引被反复取消重启（C10 round4）。
  // 若调用方/测试显式覆盖单超时 AGY_ADAPTER_OTHER_LIST_TIMEOUT_MS 且未指定硬上限，则沿用同一上限保持确定性。
  const hardMs = explicitHard !== undefined
    ? Math.max(foregroundMs, explicitHard)
    : explicitFg !== undefined
      ? foregroundMs
      : Math.max(foregroundMs, DEFAULT_OTHER_LIST_HARD_TIMEOUT_MS);
  return { foregroundMs, hardMs };
}

export function createAcpSessionBackend(
  cliSharedAcp: SharedReadonlyAcp,
  otherSharedAcp: SharedReadonlyAcp,
  env: () => NodeJS.ProcessEnv = () => process.env,
  hasLiveSession?: (sessionId: string) => boolean,
  onOtherListDiagnostic?: (diag: OtherListDiagnostic) => void,
): AgySessionBackend {
  let lastOtherDegraded = false;
  let lastOtherSnapshot: { at: number; summaries: AcpSessionSummary[] } | undefined;
  let otherQueryInFlight:
    | {
        promise: Promise<{ ok: boolean; summaries: AcpSessionSummary[] }>;
        startedAt: number;
      }
    | undefined;

  const recordOtherDiag = (diag: OtherListDiagnostic) => {
    lastOtherDegraded = diag.status === "timeout" || diag.status === "failed";
    if (diag.status === "timeout") {
      logger.info("agy.other_list.timeout", { timeoutMs: diag.timeoutMs, elapsedMs: diag.elapsedMs });
    } else if (diag.status === "failed") {
      logger.info("agy.other_list.failed", { error: diag.error, elapsedMs: diag.elapsedMs });
    } else if (diag.status === "empty") {
      logger.debug("agy.other_list.empty", { elapsedMs: diag.elapsedMs });
    } else {
      logger.debug("agy.other_list.ok", { count: diag.count, elapsedMs: diag.elapsedMs });
    }
    onOtherListDiagnostic?.(diag);
  };

  const ensureOtherQueryInFlight = (hardMs: number) => {
    if (otherQueryInFlight) return otherQueryInFlight;
    const startedAt = Date.now();
    const controller = new AbortController();
    let hardTimedOut = false;
    const hardTimer = setTimeout(() => {
      hardTimedOut = true;
      controller.abort();
    }, hardMs);
    hardTimer.unref?.();

    const flight = {
      startedAt,
      promise: undefined as unknown as Promise<{ ok: boolean; summaries: AcpSessionSummary[] }>,
    };
    flight.promise = (async (): Promise<{ ok: boolean; summaries: AcpSessionSummary[] }> => {
      try {
        const list = await otherSharedAcp.use(
          (client) => client.sessionList(hardMs, controller.signal),
          { timeoutMs: hardMs, signal: controller.signal },
        );
        const elapsedMs = Date.now() - startedAt;
        lastOtherSnapshot = { at: Date.now(), summaries: list };
        if (list.length === 0) {
          recordOtherDiag({ status: "empty", count: 0, elapsedMs });
        } else {
          recordOtherDiag({ status: "ok", count: list.length, elapsedMs });
        }
        return { ok: true, summaries: list };
      } catch (error) {
        const elapsedMs = Date.now() - startedAt;
        if (hardTimedOut || controller.signal.aborted) {
          recordOtherDiag({ status: "timeout", timeoutMs: hardMs, elapsedMs });
        } else {
          recordOtherDiag({ status: "failed", error: errorText(error), elapsedMs });
        }
        return { ok: false, summaries: lastOtherSnapshot?.summaries ?? [] };
      } finally {
        clearTimeout(hardTimer);
        if (otherQueryInFlight === flight) {
          otherQueryInFlight = undefined;
        }
      }
    })();

    otherQueryInFlight = flight;
    return flight;
  };

  return {
    wasLastOtherListDegraded() {
      return lastOtherDegraded;
    },

    async listSummaries() {
      const currentEnv = env();
      const checkOther = await hasOtherConversations(currentEnv);
      if (!checkOther) {
        lastOtherDegraded = false;
        return cliSharedAcp.use((client) => client.sessionList());
      }
      const { foregroundMs, hardMs } = otherListBudgets(currentEnv);
      const queryOtherBounded = async (): Promise<AcpSessionSummary[]> => {
        // 后台预热刚刚成功时直接复用新鲜快照，避免立即二次重复拉取。
        if (!otherQueryInFlight && lastOtherSnapshot && Date.now() - lastOtherSnapshot.at < OTHER_WARM_SNAPSHOT_REUSE_MS) {
          lastOtherDegraded = false;
          return lastOtherSnapshot.summaries;
        }
        const flight = ensureOtherQueryInFlight(hardMs);
        if (hardMs <= foregroundMs) {
          const result = await flight.promise;
          return result.summaries;
        }
        let fgTimedOut = false;
        const fgStartedAt = Date.now();
        let fgTimer: ReturnType<typeof setTimeout> | undefined;
        const timeoutSentinel = new Promise<"fg_timeout">((resolve) => {
          fgTimer = setTimeout(() => {
            fgTimedOut = true;
            resolve("fg_timeout");
          }, foregroundMs);
          fgTimer.unref?.();
        });
        try {
          const raced = await Promise.race([flight.promise, timeoutSentinel]);
          if (raced === "fg_timeout") {
            // 前台不等死，但保留后台健康预热继续完成；若已有上次成功快照则先回退展示。
            recordOtherDiag({
              status: "timeout",
              timeoutMs: foregroundMs,
              elapsedMs: Date.now() - fgStartedAt,
            });
            return lastOtherSnapshot?.summaries ?? [];
          }
          return raced.summaries;
        } finally {
          if (fgTimer && !fgTimedOut) {
            clearTimeout(fgTimer);
          }
        }
      };

      const [cliList, otherList] = await Promise.all([
        cliSharedAcp.use((client) => client.sessionList()),
        queryOtherBounded(),
      ]);
      if (otherList.length === 0) return cliList;
      const merged = new Map<string, AcpSessionSummary>();
      for (const item of cliList) {
        if (item.sessionId) merged.set(item.sessionId, item);
      }
      for (const item of otherList) {
        if (item.sessionId && !merged.has(item.sessionId)) {
          merged.set(item.sessionId, item);
        }
      }
      return [...merged.values()];
    },

    async loadReplay(sessionId: string, cwd: string, origin: AgySessionOrigin) {
      const trimmed = cwd.trim();
      const effectiveCwd = trimmed && (await directoryExists(trimmed)) ? trimmed : os.tmpdir();
      const targetAcp = origin === "other" ? otherSharedAcp : cliSharedAcp;
      return targetAcp.use(async (client) => {
        const { updates } = await client.sessionLoadWithReplay(sessionId, effectiveCwd);
        if (!hasLiveSession?.(sessionId)) {
          await client.sessionClose(sessionId).catch(() => {});
        }
        return updates;
      });
    },

    resolveSessionOrigin(sessionId: string) {
      return resolveSessionOrigin(sessionId, env());
    },

    conversationFilePath(sessionId: string, origin: AgySessionOrigin) {
      return conversationDbPath(sessionId, env(), origin) ?? null;
    },

    async diskRevision(sessionId: string, origin: AgySessionOrigin): Promise<DiskRevisionInfo | undefined> {
      const transcriptPath = await resolveTranscriptPath(sessionId, origin, env());
      const transcriptStat = await statSizeAndMtime(transcriptPath);
      if (transcriptPath && transcriptStat) {
        return {
          signature: `t:${transcriptPath}:${transcriptStat.size}:${Math.floor(transcriptStat.mtimeMs)}`,
          mtimeMs: transcriptStat.mtimeMs,
          transcriptPath,
        };
      }
      const dbPath = conversationDbPath(sessionId, env(), origin);
      const [dbStat, walStat] = await Promise.all([
        statSizeAndMtime(dbPath),
        statSizeAndMtime(dbPath ? `${dbPath}-wal` : undefined),
      ]);
      if (!dbStat && !walStat) return undefined;
      const mtimeMs = Math.max(dbStat?.mtimeMs ?? 0, walStat?.mtimeMs ?? 0);
      return {
        signature: `db:${dbStat?.size ?? 0}:${Math.floor(dbStat?.mtimeMs ?? 0)}:${walStat?.size ?? 0}:${Math.floor(walStat?.mtimeMs ?? 0)}`,
        mtimeMs,
      };
    },

    inspectExternalActivity(sessionId: string, origin: AgySessionOrigin) {
      const ownPids = new Set<number>();
      if (cliSharedAcp.pid) ownPids.add(cliSharedAcp.pid);
      if (otherSharedAcp.pid) ownPids.add(otherSharedAcp.pid);
      return inspectTranscriptActivity(sessionId, origin, env(), { ownPids });
    },

    snapshotTranscriptState(sessionId: string, origin: AgySessionOrigin) {
      return snapshotTranscriptState(sessionId, origin, env());
    },

    snapshotTranscriptStateDetailed(sessionId: string, origin: AgySessionOrigin) {
      return snapshotTranscriptStateDetailed(sessionId, origin, env());
    },

    loadTranscriptTurns(sessionId: string, cwd: string, transcriptPath: string, running: boolean, holderActive: boolean) {
      return readTranscriptTurns(sessionId, cwd, transcriptPath, running, holderActive);
    },
  };
}

function parseIsoSeconds(raw: string | null | undefined, fallbackSeconds: number): number {
  if (!raw) return fallbackSeconds;
  const ms = Date.parse(raw);
  return Number.isFinite(ms) && ms > 0 ? Math.floor(ms / 1000) : fallbackSeconds;
}

export interface CatalogDeps {
  backend: AgySessionBackend;
  git: GitRepoIndex;
  overlay: AgyOverlay;
  /** 内存中尚未落盘 `.db` 的新建活跃会话，保证 `thread/start` 后立即能在 `thread/read` / `thread/list` 查到。 */
  inMemorySessions?: () => ReadonlyMap<string, { cwd: string; createdAt: number; updatedAt: number; title: string | null }>;
}

export class AgyCatalog {
  private cachedList: { at: number; degraded: boolean; summaries: AcpSessionSummary[] } | undefined;

  constructor(
    private readonly deps: CatalogDeps,
    private readonly listCacheMs = 1_500,
  ) {}

  invalidate(): void {
    this.cachedList = undefined;
  }

  async externalActivity(sessionId: string): Promise<TranscriptActivityInfo | undefined> {
    if (!this.deps.backend.inspectExternalActivity) return undefined;
    const origin = await this.deps.backend.resolveSessionOrigin(sessionId);
    if (!origin) return undefined;
    return this.deps.backend.inspectExternalActivity(sessionId, origin);
  }

  async transcriptState(sessionId: string): Promise<TranscriptTurnSnapshot | undefined> {
    if (!this.deps.backend.snapshotTranscriptState) return undefined;
    const origin = (await this.deps.backend.resolveSessionOrigin(sessionId)) ?? "cli";
    return this.deps.backend.snapshotTranscriptState(sessionId, origin);
  }

  async transcriptStateDetailed(sessionId: string): Promise<TranscriptSnapshotResult> {
    const origin = (await this.deps.backend.resolveSessionOrigin(sessionId)) ?? "cli";
    if (this.deps.backend.snapshotTranscriptStateDetailed) {
      return this.deps.backend.snapshotTranscriptStateDetailed(sessionId, origin);
    }
    if (!this.deps.backend.snapshotTranscriptState) {
      return { kind: "missing" };
    }
    try {
      const snapshot = await this.deps.backend.snapshotTranscriptState(sessionId, origin);
      return snapshot ? { kind: "present", snapshot } : { kind: "missing" };
    } catch (error) {
      return {
        kind: "error",
        reason: "transcript_inspect_failed",
        error: error instanceof Error ? error.message : String(error),
      };
    }
  }

  async list(dirs?: readonly string[]): Promise<SessionRecord[]> {
    await this.deps.overlay.load();
    const summaries = await this.fetchSummaries();
    const activeMap = this.deps.inMemorySessions?.() ?? new Map();
    const byId = new Map<string, { summary: AcpSessionSummary; origin: AgySessionOrigin }>();
    for (const item of summaries) {
      if (!item.sessionId) continue;
      if (activeMap.has(item.sessionId)) {
        const detected = await this.deps.backend.resolveSessionOrigin(item.sessionId);
        byId.set(item.sessionId, { summary: item, origin: detected ?? "cli" });
        continue;
      }
      const origin = await this.deps.backend.resolveSessionOrigin(item.sessionId);
      if (origin) {
        byId.set(item.sessionId, { summary: item, origin });
      }
    }
    for (const [sessionId, mem] of activeMap) {
      if (!byId.has(sessionId)) {
        byId.set(sessionId, {
          summary: {
            sessionId,
            cwd: mem.cwd,
            title: mem.title,
            updatedAt: new Date(mem.updatedAt * 1000).toISOString(),
          },
          origin: "cli",
        });
      }
    }

    const records: SessionRecord[] = [];
    for (const { summary, origin } of byId.values()) {
      const record = await this.toRecord(summary, origin, activeMap.get(summary.sessionId));
      if (dirs && dirs.length > 0) {
        if (!record.cwd || !(await this.deps.git.matchesAnyRoot(record.cwd, dirs))) {
          continue;
        }
      }
      records.push(record);
    }
    return records;
  }

  async get(sessionId: string): Promise<SessionRecord | undefined> {
    await this.deps.overlay.load();
    const activeMap = this.deps.inMemorySessions?.() ?? new Map();
    const mem = activeMap.get(sessionId);
    const summaries = await this.fetchSummaries();
    const found = summaries.find((entry) => entry.sessionId === sessionId);
    if (!found && !mem) return undefined;
    const detectedOrigin = await this.deps.backend.resolveSessionOrigin(sessionId);
    if (!mem && !detectedOrigin) {
      return undefined;
    }
    return this.toRecord(
      found ?? {
        sessionId,
        cwd: mem!.cwd,
        title: mem!.title,
        updatedAt: new Date(mem!.updatedAt * 1000).toISOString(),
      },
      detectedOrigin ?? "cli",
      mem,
    );
  }

  private async fetchSummaries(): Promise<AcpSessionSummary[]> {
    const now = Date.now();
    // 若上一次 Other 索引处于降级（超时/失败），不复用缓存，使分页翻页或下一次刷新能立即发现恢复后的 Other 会话（C10）。
    if (this.cachedList && !this.cachedList.degraded && now - this.cachedList.at < this.listCacheMs) {
      return this.cachedList.summaries;
    }
    const summaries = await this.deps.backend.listSummaries();
    const degraded = this.deps.backend.wasLastOtherListDegraded?.() ?? false;
    this.cachedList = { at: Date.now(), degraded, summaries };
    return summaries;
  }

  private async toRecord(
    summary: AcpSessionSummary,
    origin: AgySessionOrigin,
    mem: { cwd: string; createdAt: number; updatedAt: number; title: string | null } | undefined,
  ): Promise<SessionRecord> {
    const overlay = this.deps.overlay.get(summary.sessionId);
    const nowSec = Math.floor(Date.now() / 1000);
    const disk = await this.deps.backend.diskRevision?.(summary.sessionId, origin);
    const summaryUpdatedAt = parseIsoSeconds(summary.updatedAt, 0);
    // 仅 transcript.jsonl 反映真实对话写入时间；SQLite .db/.db-wal 可能在只读或 checkpoint 时
    // 刷新 mtime，仅在 summary 缺失有效时间戳时作为兜底，不覆盖已有历史会话的 updatedAt。
    const diskSec = disk?.transcriptPath ? Math.floor(disk.mtimeMs / 1000) : 0;
    const fallbackDiskSec = summaryUpdatedAt > 0 ? 0 : disk ? Math.floor(disk.mtimeMs / 1000) : 0;
    const updatedAt =
      Math.max(summaryUpdatedAt, diskSec, fallbackDiskSec, mem?.updatedAt ?? 0, overlay?.updatedAt ?? 0) || nowSec;
    const createdAt = overlay?.createdAt ?? mem?.createdAt ?? updatedAt;
    const rawSummaryCwd = summary.cwd?.trim() || "";
    const normalizedTmp = os.tmpdir().replace(/\/+$/, "");
    const summaryCwd = rawSummaryCwd && rawSummaryCwd.replace(/\/+$/, "") !== normalizedTmp ? rawSummaryCwd : "";
    const cwd = (summaryCwd || mem?.cwd || overlay?.cwd || rawSummaryCwd).trim();
    const cwdMissing = Boolean(cwd) && !(await directoryExists(cwd));
    const gitInfo = cwd && !cwdMissing ? await this.deps.git.inspect(cwd) : { branch: null };
    const title = overlay?.customTitle?.trim() || mem?.title?.trim() || summary.title?.trim() || null;
    const preview = overlay?.preview?.trim() || title || "";
    return {
      id: summary.sessionId,
      cwd,
      cwdMissing,
      name: title,
      preview,
      createdAt,
      updatedAt,
      gitBranch: gitInfo.branch,
      path: this.deps.backend.conversationFilePath(summary.sessionId, origin),
      archived: this.deps.overlay.isArchived(summary.sessionId),
      origin,
    };
  }
}

const HISTORY_CACHE_LIMIT = 8;

export class AgyHistoryStore {
  private readonly cache = new Map<
    string,
    { revision: string; running: boolean; holderActive: boolean; nativeTurnCount: number; maxTurnOrdinal: number; turns: Turn[] }
  >();

  constructor(
    private readonly catalog: AgyCatalog,
    private readonly backend: AgySessionBackend,
    /** 若当前会话正在本适配器执行活跃回合，优先直接读取内存流式快照。 */
    private readonly liveTurns?: (sessionId: string) => Turn[] | undefined,
    /** 为本进程发起的历史回合补回本地 clientId，确保 iOS 重开会话刷新时与本地回显精确对齐。 */
    private readonly clientIdForTurn?: (turnId: string) => string | undefined,
    /** 回填持久化在 overlay 中的失败/中断回合终态与结构化错误（B10）。 */
    private readonly turnOutcomeForTurn?: (sessionId: string, turnId: string) => TurnOutcomeRecord | undefined,
    /** 读取按不可复用尝试 ID 持久化的回合尝试记录，用于合并早失败与避免旧错误覆盖新回合（B10）。 */
    private readonly turnAttemptsForSession?: (sessionId: string) => TurnAttemptRecord[],
    /** 读取持久化的工具调用映射，让缺少原生 toolCallId 的 transcript 冷读复用实时/回放 ID（B15/C05）。 */
    private readonly toolMappingsForTurn?: (sessionId: string, turnId: string) => PersistedToolMapping[],
  ) {}

  invalidate(sessionId: string): void {
    this.cache.delete(sessionId);
  }

  /**
   * 查询已落盘历史的回合数，用于在发起新回合时生成与历史快照一致的确定性 `turnId`。
   * 仅优先读取内存缓存或 transcript 文件，避免在活跃会话上额外触发 `session/load`。
   */
  async persistedTurnCount(sessionId: string): Promise<number> {
    const info = await this.persistedTurnInfo(sessionId);
    return info.nativeTurnCount;
  }

  async persistedTurnInfo(sessionId: string): Promise<{ nativeTurnCount: number; maxTurnOrdinal: number }> {
    const cached = this.cache.get(sessionId);
    const record = await this.catalog.get(sessionId);
    if (!record) {
      return {
        nativeTurnCount: cached?.nativeTurnCount ?? 0,
        maxTurnOrdinal: cached?.maxTurnOrdinal ?? 0,
      };
    }
    const disk = await this.backend.diskRevision?.(sessionId, record.origin);
    if (disk?.transcriptPath && this.backend.loadTranscriptTurns) {
      const nativeTurns = await this.backend.loadTranscriptTurns(sessionId, record.cwd, disk.transcriptPath, false, false);
      const merged = this.applyKnownTurnOutcomes(sessionId, nativeTurns);
      let maxOrd = nativeTurns.length;
      for (const turn of merged) {
        maxOrd = Math.max(maxOrd, parseTurnOrdinal(sessionId, turn.id));
      }
      return { nativeTurnCount: nativeTurns.length, maxTurnOrdinal: maxOrd };
    }
    return {
      nativeTurnCount: cached?.nativeTurnCount ?? 0,
      maxTurnOrdinal: cached?.maxTurnOrdinal ?? 0,
    };
  }

  async turns(sessionId: string, running = false, holderActive = false): Promise<Turn[]> {
    const live = this.liveTurns?.(sessionId);
    if (live) return live;
    const record = await this.catalog.get(sessionId);
    if (!record) return [];
    const disk = await this.backend.diskRevision?.(sessionId, record.origin);
    const revision = disk?.signature ?? `u:${record.updatedAt}`;
    const cached = this.cache.get(sessionId);
    if (cached && cached.revision === revision && cached.running === running && cached.holderActive === holderActive) {
      return cached.turns;
    }

    let nativeTurns: Turn[];
    if (disk?.transcriptPath && this.backend.loadTranscriptTurns) {
      nativeTurns = await this.backend.loadTranscriptTurns(sessionId, record.cwd, disk.transcriptPath, running, holderActive);
    } else {
      const updates = await this.backend.loadReplay(sessionId, record.cwd, record.origin);
      nativeTurns = updatesToTurns(sessionId, record.cwd, updates, running || holderActive);
    }
    const nativeTurnCount = nativeTurns.length;
    let turns = this.applyKnownTurnOutcomes(sessionId, nativeTurns);
    turns = this.applyKnownToolMappings(sessionId, turns);
    turns = this.attachKnownClientIds(turns);

    let maxTurnOrdinal = nativeTurnCount;
    for (const turn of turns) {
      maxTurnOrdinal = Math.max(maxTurnOrdinal, parseTurnOrdinal(sessionId, turn.id));
    }

    this.cache.delete(sessionId);
    this.cache.set(sessionId, { revision, running, holderActive, nativeTurnCount, maxTurnOrdinal, turns });
    while (this.cache.size > HISTORY_CACHE_LIMIT) {
      const first = this.cache.keys().next().value;
      if (!first) break;
      this.cache.delete(first);
    }
    return turns;
  }

  private attachKnownClientIds(turns: Turn[]): Turn[] {
    if (!this.clientIdForTurn) return turns;
    return turns.map((turn) => {
      const knownClientId = this.clientIdForTurn!(turn.id);
      if (!knownClientId) return turn;
      let changed = false;
      const items = turn.items.map((item) => {
        if (item.type === "userMessage" && !item.clientId) {
          changed = true;
          return { ...item, clientId: knownClientId };
        }
        return item;
      });
      return changed ? { ...turn, items } : turn;
    });
  }

  private applyKnownTurnOutcomes(sessionId: string, turns: Turn[]): Turn[] {
    const attempts = this.turnAttemptsForSession?.(sessionId) ?? [];
    let resolvedTurns = turns;
    let attemptControlledIds = new Set<string>();
    if (attempts.length > 0) {
      const merged = mergeTurnsWithAttempts(sessionId, turns, attempts);
      resolvedTurns = merged.turns;
      attemptControlledIds = merged.attemptControlledIds;
    }
    if (!this.turnOutcomeForTurn) return resolvedTurns;
    return resolvedTurns.map((turn) => {
      if (turn.status === "inProgress" || attemptControlledIds.has(turn.id)) return turn;
      const outcome = this.turnOutcomeForTurn!(sessionId, turn.id);
      if (!outcome) return turn;
      if (outcome.status === "failed") {
        return {
          ...turn,
          status: "failed",
          error: turn.error ?? {
            message: outcome.error ?? "Antigravity turn failed",
            codexErrorInfo: null,
            additionalDetails: null,
            misalignment: null,
          },
        };
      }
      if (outcome.status === "interrupted" && turn.status === "completed") {
        return {
          ...turn,
          status: "interrupted",
          error: null,
        };
      }
      return turn;
    });
  }

  private applyKnownToolMappings(sessionId: string, turns: Turn[]): Turn[] {
    if (!this.toolMappingsForTurn) return turns;
    return turns.map((turn) => {
      const mappings = this.toolMappingsForTurn!(sessionId, turn.id);
      if (mappings.length === 0) return turn;
      const knownIds = new Set(mappings.map((m) => m.itemId));
      const usedMappingIdx = new Set<number>();
      const reassignedIds = new Map<number, string>();

      interface PendingTranscriptItem {
        itemIndex: number;
        item: Turn["items"][number];
        groupKey: string;
        outputFingerprint?: string;
      }

      const pendingByGroup = new Map<string, PendingTranscriptItem[]>();

      turn.items.forEach((item, itemIndex) => {
        if (item.type !== "commandExecution" && item.type !== "fileChange" && item.type !== "dynamicToolCall") {
          return;
        }
        if (knownIds.has(item.id)) {
          const exactIdx = mappings.findIndex((m, idx) => !usedMappingIdx.has(idx) && m.itemId === item.id);
          if (exactIdx >= 0) usedMappingIdx.add(exactIdx);
          return;
        }
        const fp = toolItemFingerprint(item);
        if (!fp) return;
        const groupKey = `${item.type}\x00${fp}`;
        const list = pendingByGroup.get(groupKey) ?? [];
        list.push({
          itemIndex,
          item,
          groupKey,
          outputFingerprint: toolItemOutputFingerprint(item),
        });
        pendingByGroup.set(groupKey, list);
      });

      for (const [groupKey, groupItems] of pendingByGroup) {
        const candidateIndices: number[] = [];
        mappings.forEach((m, idx) => {
          if (!usedMappingIdx.has(idx) && `${m.itemType}\x00${m.fingerprint}` === groupKey) {
            candidateIndices.push(idx);
          }
        });
        if (candidateIndices.length === 0) continue;

        const unmatchedItems = [...groupItems];

        // 1) 同签名多调用优先按规范化输出指纹 1-to-1 精确关联（防止逆序完成时冷读互换 ID，B15/C05）。
        const itemOutCounts = new Map<string, number>();
        for (const entry of unmatchedItems) {
          if (entry.outputFingerprint) {
            itemOutCounts.set(entry.outputFingerprint, (itemOutCounts.get(entry.outputFingerprint) ?? 0) + 1);
          }
        }
        const mapOutCounts = new Map<string, number>();
        for (const idx of candidateIndices) {
          const outFp = mappings[idx]?.outputFingerprint;
          if (outFp) {
            mapOutCounts.set(outFp, (mapOutCounts.get(outFp) ?? 0) + 1);
          }
        }
        const remainingItems: PendingTranscriptItem[] = [];
        for (const entry of unmatchedItems) {
          const outFp = entry.outputFingerprint;
          if (outFp && itemOutCounts.get(outFp) === 1 && mapOutCounts.get(outFp) === 1) {
            const matchIdx = candidateIndices.find(
              (idx) => !usedMappingIdx.has(idx) && mappings[idx]?.outputFingerprint === outFp,
            );
            if (matchIdx !== undefined) {
              usedMappingIdx.add(matchIdx);
              reassignedIds.set(entry.itemIndex, mappings[matchIdx]!.itemId);
              continue;
            }
          }
          remainingItems.push(entry);
        }

        const remainingMappingIndices = candidateIndices.filter((idx) => !usedMappingIdx.has(idx));
        if (remainingItems.length === 0 || remainingMappingIndices.length === 0) {
          continue;
        }

        // 2) 该签名只剩唯一一对候选时直接绑定。
        if (remainingItems.length === 1 && remainingMappingIndices.length === 1) {
          const onlyIdx = remainingMappingIndices[0]!;
          usedMappingIdx.add(onlyIdx);
          reassignedIds.set(remainingItems[0]!.itemIndex, mappings[onlyIdx]!.itemId);
          continue;
        }

        // 3) 多个同签名调用且输出指纹未命中时：
        // - 新格式：仅当串行无并发重叠（overlappedConcurrent !== true）且带 invocationIndex 时按启动顺序对齐；
        // - 旧版 overlay 兼容（B15 round4）：b36 等旧格式映射未写入 invocationIndex / outputFingerprint，
        //   且无 overlappedConcurrent 标记，保留原数组记录顺序对齐，避免升级后旧工具 ID 退化为序号；
        // - 并发重叠导致关联不唯一时仍保留确定性回退 ID，绝不误绑。
        const isNewSequential =
          remainingItems.length === remainingMappingIndices.length
          && remainingMappingIndices.every((idx) => {
            const m = mappings[idx]!;
            return m.invocationIndex !== undefined && m.overlappedConcurrent !== true;
          });
        const isLegacySequential =
          !isNewSequential
          && remainingItems.length === remainingMappingIndices.length
          && remainingMappingIndices.every((idx) => {
            const m = mappings[idx]!;
            return m.invocationIndex === undefined && m.overlappedConcurrent !== true;
          });
        if (isNewSequential || isLegacySequential) {
          const ordered = isNewSequential
            ? [...remainingMappingIndices].sort(
                (a, b) => (mappings[a]!.invocationIndex ?? 0) - (mappings[b]!.invocationIndex ?? 0),
              )
            : [...remainingMappingIndices];
          for (let i = 0; i < remainingItems.length; i += 1) {
            const mapIdx = ordered[i]!;
            usedMappingIdx.add(mapIdx);
            reassignedIds.set(remainingItems[i]!.itemIndex, mappings[mapIdx]!.itemId);
          }
        }
      }

      if (reassignedIds.size === 0) return turn;
      const items = turn.items.map((item, idx) => {
        const mappedId = reassignedIds.get(idx);
        return mappedId ? { ...item, id: mappedId } : item;
      });
      return { ...turn, items };
    });
  }
}

function normalizeTurnPrompt(text: string): string {
  return text.replace(/\s+/g, " ").trim();
}

function extractTurnUserPrompt(turn: Turn): string {
  for (const item of turn.items) {
    if (item.type !== "userMessage") continue;
    const parts: string[] = [];
    for (const part of item.content) {
      if (part.type === "text" && part.text) {
        parts.push(part.text);
      }
    }
    const joined = normalizeTurnPrompt(parts.join(" "));
    if (joined) return joined;
  }
  return "";
}

function rewriteTurnId(turn: Turn, targetTurnId: string): Turn {
  if (turn.id === targetTurnId) return turn;
  const oldPrefix = `${turn.id}:`;
  return {
    ...turn,
    id: targetTurnId,
    items: turn.items.map((item) =>
      item.id.startsWith(oldPrefix) ? { ...item, id: `${targetTurnId}:${item.id.slice(oldPrefix.length)}` } : item,
    ),
  };
}

function applyAttemptOutcome(turn: Turn, attempt: TurnAttemptRecord): Turn {
  const aligned = rewriteTurnId(turn, attempt.turnId);
  if (aligned.status === "inProgress") return aligned;
  if (attempt.status === "completed") {
    return aligned;
  }
  if (attempt.status === "failed") {
    return {
      ...aligned,
      status: "failed",
      error: aligned.error ?? {
        message: attempt.error ?? "Antigravity turn failed",
        codexErrorInfo: null,
        additionalDetails: null,
        misalignment: null,
      },
    };
  }
  if (attempt.status === "interrupted" && aligned.status === "completed") {
    return {
      ...aligned,
      status: "interrupted",
      error: null,
    };
  }
  return aligned;
}

function promptsMatchExact(attemptPrompt: string, candidatePrompt: string): boolean {
  if (attemptPrompt === "" && candidatePrompt === "") return true;
  if (attemptPrompt === "" || candidatePrompt === "") return false;
  if (candidatePrompt === attemptPrompt) return true;
  // `toAcpPromptBlocks` 将 preview 截断为 240 字符，仅在达到截断上限时允许精确前缀匹配。
  return attemptPrompt.length === 240 && candidatePrompt.startsWith(attemptPrompt);
}

function turnHasAssistantOrToolProgress(turn: Turn | undefined): boolean {
  if (!turn) return false;
  return turn.items.some((item) => item.type !== "userMessage");
}

function mergeTurnsWithAttempts(
  sessionId: string,
  nativeTurns: readonly Turn[],
  attempts: readonly TurnAttemptRecord[],
): { turns: Turn[]; attemptControlledIds: Set<string> } {
  const finishedAttempts = attempts.filter((entry) => entry.status !== "inProgress");
  if (finishedAttempts.length === 0) {
    return { turns: [...nativeTurns], attemptControlledIds: new Set() };
  }

  const out: Turn[] = [];
  const usedIds = new Set<string>();
  const attemptControlledIds = new Set<string>();
  const reservedAttemptIds = new Set(finishedAttempts.map((entry) => entry.turnId));
  let nextFallbackOrdinal = 1;

  const advanceOrdinalPast = (turnId: string) => {
    const ord = parseTurnOrdinal(sessionId, turnId);
    if (ord >= nextFallbackOrdinal) {
      nextFallbackOrdinal = ord + 1;
    }
  };

  const allocateUniqueTurnId = (): string => {
    while (
      usedIds.has(`${sessionId}:turn:${nextFallbackOrdinal}`)
      || reservedAttemptIds.has(`${sessionId}:turn:${nextFallbackOrdinal}`)
    ) {
      nextFallbackOrdinal += 1;
    }
    const id = `${sessionId}:turn:${nextFallbackOrdinal}`;
    nextFallbackOrdinal += 1;
    return id;
  };

  const emitNativeTurn = (turn: Turn) => {
    if (!usedIds.has(turn.id) && !reservedAttemptIds.has(turn.id)) {
      usedIds.add(turn.id);
      advanceOrdinalPast(turn.id);
      out.push(turn);
      return;
    }
    const uniqueId = allocateUniqueTurnId();
    usedIds.add(uniqueId);
    out.push(rewriteTurnId(turn, uniqueId));
  };

  let nativeIdx = 0;

  for (let i = 0; i < finishedAttempts.length; i += 1) {
    const attempt = finishedAttempts[i]!;
    while (nativeIdx < nativeTurns.length && nativeIdx < attempt.afterPersistedTurnCount) {
      emitNativeTurn(nativeTurns[nativeIdx]!);
      nativeIdx += 1;
    }

    const candidate = nativeTurns[nativeIdx];
    const attemptPrompt = normalizeTurnPrompt(attempt.promptText);
    const candidatePrompt = candidate ? extractTurnUserPrompt(candidate) : "";
    // 严格按规范化提示词精确匹配，禁止宽松子串包含把相近但独立的原生成功回合错合并到旧失败尝试（B10 round4）。
    const promptsCompatible = Boolean(candidate) && promptsMatchExact(attemptPrompt, candidatePrompt);

    let laterAttemptNeedsNative = false;
    if (promptsCompatible && attempt.status !== "completed" && attemptPrompt) {
      // 同提示词连续重试：前一次早失败未落盘、后一次成功落盘时，剩余原生回合数少于剩余同提示词尝试数，
      // 必须把原生回合留给后续成功尝试，不能把早失败错误贴到新成功回合上（B10）。
      let remainingSamePromptAttempts = 0;
      let hasLaterCompletedSamePrompt = false;
      for (let j = i; j < finishedAttempts.length; j += 1) {
        const other = finishedAttempts[j]!;
        if (j > i && other.persisted === false) continue;
        const otherPrompt = normalizeTurnPrompt(other.promptText);
        if (promptsMatchExact(otherPrompt, candidatePrompt)) {
          remainingSamePromptAttempts += 1;
          if (j > i && other.status === "completed") {
            hasLaterCompletedSamePrompt = true;
          }
        }
      }
      let remainingSamePromptNative = 0;
      for (let k = nativeIdx; k < nativeTurns.length; k += 1) {
        const p = extractTurnUserPrompt(nativeTurns[k]!);
        if (promptsMatchExact(attemptPrompt, p)) {
          remainingSamePromptNative += 1;
        }
      }
      if (hasLaterCompletedSamePrompt && remainingSamePromptNative < remainingSamePromptAttempts) {
        laterAttemptNeedsNative = true;
      }
    }

    let shouldTreatAsUnpersisted = !candidate || !promptsCompatible || laterAttemptNeedsNative;
    if (!shouldTreatAsUnpersisted && candidate && attempt.status !== "completed") {
      const candidateHasProgress = turnHasAssistantOrToolProgress(candidate);
      const attemptHasProgress = turnHasAssistantOrToolProgress(attempt.syntheticTurn);
      if (attempt.persisted === false) {
        // 兼容旧版或取消瞬间 transcript 延迟刷盘：若当前原生位置已落盘同一提示词且无完成回复（或终态一致），
        // 说明该中断/失败请求其实已落盘，应合并为单条记录，避免重复显示两份（B10 round4）。
        const isLatePersistedSameAttempt = !candidateHasProgress || candidate.status === attempt.status;
        if (!isLatePersistedSameAttempt) {
          shouldTreatAsUnpersisted = true;
        }
      } else if (
        attempt.persisted === undefined
        && !attemptHasProgress
        && candidate.status === "completed"
        && candidateHasProgress
      ) {
        // 未确认落盘且无任何助手/工具产出的早失败，不应吞并后续同提示词且完整回复的独立原生成功回合。
        shouldTreatAsUnpersisted = true;
      }
    }

    if (shouldTreatAsUnpersisted) {
      if (attempt.status !== "completed" && attempt.syntheticTurn) {
        const synth = usedIds.has(attempt.syntheticTurn.id)
          ? rewriteTurnId(attempt.syntheticTurn, allocateUniqueTurnId())
          : attempt.syntheticTurn;
        usedIds.add(synth.id);
        attemptControlledIds.add(synth.id);
        advanceOrdinalPast(synth.id);
        out.push(synth);
      }
      continue;
    }

    const applied = applyAttemptOutcome(candidate!, attempt);
    const uniqueApplied = usedIds.has(applied.id)
      ? rewriteTurnId(applied, allocateUniqueTurnId())
      : applied;
    usedIds.add(uniqueApplied.id);
    attemptControlledIds.add(uniqueApplied.id);
    advanceOrdinalPast(uniqueApplied.id);
    out.push(uniqueApplied);
    nativeIdx += 1;
  }

  while (nativeIdx < nativeTurns.length) {
    emitNativeTurn(nativeTurns[nativeIdx]!);
    nativeIdx += 1;
  }
  return { turns: out, attemptControlledIds };
}
