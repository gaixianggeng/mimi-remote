import { stat } from "node:fs/promises";
import os from "node:os";
import type { Turn } from "@mimi/appserver-kit/protocol/codex/v2/Turn.ts";
import type { AcpSessionSummary, AcpSessionUpdate } from "../acp/types.ts";
import { errorText, logger } from "../util/logging.ts";
import { SharedReadonlyAcp } from "./binary.ts";
import {
  conversationDbPath,
  createBatchSessionOriginResolver,
  probeOtherConversations,
  resolveSessionOrigin,
  type AgySessionOrigin,
  type OtherConversationsProbeStatus,
} from "./env.ts";
import { directoryExists, normalizeNativeCwd, type GitRepoIndex } from "./git.ts";
import { updatesToTurns } from "./history.ts";
import { parseTurnOrdinal, type AgyOverlay, type PersistedToolMapping, type TurnAttemptRecord, type TurnOutcomeRecord } from "./overlay.ts";
import { toolItemFingerprint, toolItemOutputFingerprint } from "./tools.ts";
import {
  areNativeToolsProvablySerial,
  copyNativeToolStepLifecycle,
  copyNativeTranscriptTurnMeta,
  getNativeTranscriptTurnMeta,
  inspectTranscriptActivity,
  readTranscriptTurns,
  resolveTranscriptPath,
  snapshotTranscriptState,
  snapshotTranscriptStateDetailed,
  type OwnTurnTranscriptWatermark,
  type TranscriptActivityInfo,
  type TranscriptSnapshotResult,
  type TranscriptTurnSnapshot,
} from "./transcript.ts";
import { hashNormalizedPrompt, PROMPT_PREVIEW_MAX_CHARS } from "../runtime/userInput.ts";

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

export type AgyListDegradedReason =
  | "other_timeout"
  | "other_failed"
  | "other_probe_permission_denied"
  | "other_probe_io_error";

export type AgyThreadListMeta =
  | {
      readonly schemaVersion: 1;
      readonly complete: true;
      readonly sources: readonly ("cli" | "other")[];
    }
  | {
      readonly schemaVersion: 1;
      readonly complete: false;
      readonly degradedReason: AgyListDegradedReason;
      readonly degradedSources: readonly ["other"];
    };

function freezeListMeta(meta: AgyThreadListMeta): AgyThreadListMeta {
  if (meta.complete) {
    return Object.freeze({
      schemaVersion: 1 as const,
      complete: true as const,
      sources: Object.freeze([...meta.sources]),
    });
  }
  return Object.freeze({
    schemaVersion: 1 as const,
    complete: false as const,
    degradedReason: meta.degradedReason,
    degradedSources: Object.freeze(["other"] as const),
  });
}

export interface AgyListSummariesResult {
  readonly summaries: AcpSessionSummary[];
  readonly listMeta: AgyThreadListMeta;
}

export interface AgyCatalogListResult {
  readonly records: SessionRecord[];
  readonly listMeta: AgyThreadListMeta;
}

export type OtherListDiagnostic =
  | { status: "ok"; count: number; elapsedMs: number }
  | { status: "empty"; count: 0; elapsedMs: number }
  | { status: "timeout"; timeoutMs: number; elapsedMs: number }
  | { status: "failed"; error: string; elapsedMs: number };

export interface AgySessionBackend {
  listSummaries(): Promise<AgyListSummariesResult>;
  loadReplay(sessionId: string, cwd: string, origin: AgySessionOrigin): Promise<AcpSessionUpdate[]>;
  resolveSessionOrigin(sessionId: string): Promise<AgySessionOrigin | null>;
  createSessionOriginResolver?(): Promise<(sessionId: string) => Promise<AgySessionOrigin | null>>;
  conversationFilePath(sessionId: string, origin: AgySessionOrigin): string | null;
  diskRevision?(sessionId: string, origin: AgySessionOrigin): Promise<DiskRevisionInfo | undefined>;
  inspectExternalActivity?(
    sessionId: string,
    origin: AgySessionOrigin,
    options?: { bypassProcessCache?: boolean; ownSettledWatermark?: OwnTurnTranscriptWatermark },
  ): Promise<TranscriptActivityInfo | undefined>;
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

type OtherQueryOutcome =
  | { readonly ok: true; readonly summaries: AcpSessionSummary[] }
  | { readonly ok: false; readonly reason: "other_timeout" | "other_failed"; readonly summaries: AcpSessionSummary[] };

function mergeSessionSummaries(
  cliList: readonly AcpSessionSummary[],
  otherList: readonly AcpSessionSummary[],
): AcpSessionSummary[] {
  if (otherList.length === 0) return [...cliList];
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
}

export function createAcpSessionBackend(
  cliSharedAcp: SharedReadonlyAcp,
  otherSharedAcp: SharedReadonlyAcp,
  env: () => NodeJS.ProcessEnv = () => process.env,
  hasLiveSession?: (sessionId: string) => boolean,
  onOtherListDiagnostic?: (diag: OtherListDiagnostic) => void,
  probeOther: (currentEnv: NodeJS.ProcessEnv) => Promise<OtherConversationsProbeStatus> = probeOtherConversations,
): AgySessionBackend {
  let lastOtherSnapshot: { at: number; summaries: AcpSessionSummary[] } | undefined;
  let otherQueryInFlight:
    | {
        promise: Promise<OtherQueryOutcome>;
        startedAt: number;
      }
    | undefined;

  const recordOtherDiag = (diag: OtherListDiagnostic) => {
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
      promise: undefined as unknown as Promise<OtherQueryOutcome>,
    };
    flight.promise = (async (): Promise<OtherQueryOutcome> => {
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
        const isTimeout = hardTimedOut || controller.signal.aborted;
        if (isTimeout) {
          recordOtherDiag({ status: "timeout", timeoutMs: hardMs, elapsedMs });
        } else {
          recordOtherDiag({ status: "failed", error: errorText(error), elapsedMs });
        }
        return {
          ok: false,
          reason: isTimeout ? "other_timeout" : "other_failed",
          summaries: lastOtherSnapshot?.summaries ?? [],
        };
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
    async listSummaries(): Promise<AgyListSummariesResult> {
      const currentEnv = env();
      const probeStatus = await probeOther(currentEnv);
      if (probeStatus === "absent_or_empty") {
        const cliList = await cliSharedAcp.use((client) => client.sessionList());
        return {
          summaries: cliList,
          listMeta: freezeListMeta({ schemaVersion: 1, complete: true, sources: ["cli"] }),
        };
      }
      if (probeStatus === "permission_denied" || probeStatus === "io_error") {
        const degradedReason: AgyListDegradedReason =
          probeStatus === "permission_denied" ? "other_probe_permission_denied" : "other_probe_io_error";
        logger.info("agy.other_probe.degraded", { status: probeStatus, degradedReason });
        const cliList = await cliSharedAcp.use((client) => client.sessionList());
        return {
          summaries: cliList,
          listMeta: freezeListMeta({
            schemaVersion: 1,
            complete: false,
            degradedReason,
            degradedSources: ["other"],
          }),
        };
      }

      const { foregroundMs, hardMs } = otherListBudgets(currentEnv);
      const queryOtherBounded = async (): Promise<OtherQueryOutcome> => {
        // 后台预热刚刚成功时直接复用新鲜快照，避免立即二次重复拉取。
        if (!otherQueryInFlight && lastOtherSnapshot && Date.now() - lastOtherSnapshot.at < OTHER_WARM_SNAPSHOT_REUSE_MS) {
          return { ok: true, summaries: lastOtherSnapshot.summaries };
        }
        const flight = ensureOtherQueryInFlight(hardMs);
        if (hardMs <= foregroundMs) {
          return flight.promise;
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
            // 前台不等死，但保留后台健康预热继续完成；若已有上次成功快照则先回退展示，同时明确标记降级。
            recordOtherDiag({
              status: "timeout",
              timeoutMs: foregroundMs,
              elapsedMs: Date.now() - fgStartedAt,
            });
            return {
              ok: false,
              reason: "other_timeout",
              summaries: lastOtherSnapshot?.summaries ?? [],
            };
          }
          return raced;
        } finally {
          if (fgTimer && !fgTimedOut) {
            clearTimeout(fgTimer);
          }
        }
      };

      const [cliList, otherOutcome] = await Promise.all([
        cliSharedAcp.use((client) => client.sessionList()),
        queryOtherBounded(),
      ]);
      const summaries = mergeSessionSummaries(cliList, otherOutcome.summaries);
      const listMeta: AgyThreadListMeta = freezeListMeta(
        otherOutcome.ok
          ? { schemaVersion: 1, complete: true, sources: ["cli", "other"] }
          : {
              schemaVersion: 1,
              complete: false,
              degradedReason: otherOutcome.reason,
              degradedSources: ["other"],
            },
      );
      return { summaries, listMeta };
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

    createSessionOriginResolver() {
      return createBatchSessionOriginResolver(env());
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

    inspectExternalActivity(
      sessionId: string,
      origin: AgySessionOrigin,
      options?: { bypassProcessCache?: boolean; ownSettledWatermark?: OwnTurnTranscriptWatermark },
    ) {
      const ownPids = new Set<number>();
      if (cliSharedAcp.pid) ownPids.add(cliSharedAcp.pid);
      if (otherSharedAcp.pid) ownPids.add(otherSharedAcp.pid);
      return inspectTranscriptActivity(sessionId, origin, env(), {
        ownPids,
        ...(options?.bypassProcessCache ? { bypassProcessCache: true } : {}),
        ...(options?.ownSettledWatermark ? { ownSettledWatermark: options.ownSettledWatermark } : {}),
      });
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
  private cachedList: { at: number; result: AgyListSummariesResult } | undefined;

  constructor(
    private readonly deps: CatalogDeps,
    private readonly listCacheMs = 1_500,
  ) {}

  invalidate(): void {
    this.cachedList = undefined;
  }

  async externalActivity(
    sessionId: string,
    options?: { bypassProcessCache?: boolean },
  ): Promise<TranscriptActivityInfo | undefined> {
    if (!this.deps.backend.inspectExternalActivity) return undefined;
    await this.deps.overlay.load();
    const ownSettledWatermark = this.deps.overlay.getOwnTurnWatermark(sessionId);
    const mergedOptions = {
      ...(options?.bypassProcessCache ? { bypassProcessCache: true } : {}),
      ...(ownSettledWatermark ? { ownSettledWatermark } : {}),
    };
    const origin = await this.deps.backend.resolveSessionOrigin(sessionId);
    if (!origin) {
      // 写路径新鲜复核时，即使会话尚无 .db/transcript 落盘，仍按默认 cli 路径执行实时进程持有检测（C11 round5）。
      if (options?.bypassProcessCache) {
        return this.deps.backend.inspectExternalActivity(sessionId, "cli", mergedOptions);
      }
      return undefined;
    }
    return this.deps.backend.inspectExternalActivity(sessionId, origin, mergedOptions);
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

  /**
   * 返回按 `dirs` 过滤后的未分页候选记录及同一次查询的不可变 `listMeta`；
   * 过滤、排序与游标切页统一由 `handlers/threads.ts` 负责。
   */
  async list(dirs?: readonly string[]): Promise<AgyCatalogListResult> {
    await this.deps.overlay.load();
    const { summaries, listMeta } = await this.fetchSummaries();
    const activeMap = this.deps.inMemorySessions?.() ?? new Map();
    const resolveOrigin = this.deps.backend.createSessionOriginResolver
      ? await this.deps.backend.createSessionOriginResolver()
      : (sessionId: string) => this.deps.backend.resolveSessionOrigin(sessionId);

    const byId = new Map<string, { summary: AcpSessionSummary; origin: AgySessionOrigin }>();
    for (const item of summaries) {
      if (!item.sessionId) continue;
      const origin = await resolveOrigin(item.sessionId);
      if (activeMap.has(item.sessionId)) {
        byId.set(item.sessionId, { summary: item, origin: origin ?? "cli" });
        continue;
      }
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

    const normalizedTmp = os.tmpdir().replace(/\/+$/, "");
    const normalizedCwdCache = new Map<string, Promise<string>>();
    const dirExistsCache = new Map<string, Promise<boolean>>();
    const cachedDirExists = (dir: string): Promise<boolean> => {
      let pending = dirExistsCache.get(dir);
      if (!pending) {
        pending = directoryExists(dir);
        dirExistsCache.set(dir, pending);
      }
      return pending;
    };

    const resolveEffectiveCwd = async (
      summary: AcpSessionSummary,
      mem: { cwd: string } | undefined,
    ): Promise<string> => {
      const overlay = this.deps.overlay.get(summary.sessionId);
      const fallbackCwd = (mem?.cwd || overlay?.cwd || "").trim() || undefined;
      const raw = summary.cwd?.trim() ?? "";
      let rawSummaryCwd = "";
      if (raw) {
        const cacheKey = `${raw}\x00${fallbackCwd ?? ""}`;
        let pending = normalizedCwdCache.get(cacheKey);
        if (!pending) {
          pending = normalizeNativeCwd(raw, fallbackCwd);
          normalizedCwdCache.set(cacheKey, pending);
        }
        rawSummaryCwd = await pending;
      }
      const summaryCwd = rawSummaryCwd && rawSummaryCwd.replace(/\/+$/, "") !== normalizedTmp ? rawSummaryCwd : "";
      return (summaryCwd || mem?.cwd || overlay?.cwd || rawSummaryCwd).trim();
    };

    const candidates = await Promise.all(
      [...byId.values()].map(async ({ summary, origin }) => {
        const mem = activeMap.get(summary.sessionId);
        const cwd = await resolveEffectiveCwd(summary, mem);
        return { summary, origin, mem, cwd };
      }),
    );

    let filtered = candidates;
    if (dirs && dirs.length > 0) {
      const uniqueCwds = new Set<string>();
      for (const candidate of candidates) {
        if (candidate.cwd) uniqueCwds.add(candidate.cwd);
      }
      const matchedCwds = new Set<string>();
      await Promise.all(
        [...uniqueCwds].map(async (cwd) => {
          if (await this.deps.git.matchesAnyRoot(cwd, dirs)) {
            matchedCwds.add(cwd);
          }
        }),
      );
      filtered = candidates.filter((candidate) => Boolean(candidate.cwd) && matchedCwds.has(candidate.cwd));
    }

    const records = await Promise.all(
      filtered.map(({ summary, origin, mem, cwd }) =>
        this.toRecord(summary, origin, mem, {
          resolvedCwd: cwd,
          checkDirectoryExists: cachedDirExists,
        }),
      ),
    );
    return { records, listMeta: freezeListMeta(listMeta) };
  }

  async get(sessionId: string): Promise<SessionRecord | undefined> {
    await this.deps.overlay.load();
    const activeMap = this.deps.inMemorySessions?.() ?? new Map();
    const mem = activeMap.get(sessionId);
    const { summaries } = await this.fetchSummaries();
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

  private async fetchSummaries(): Promise<AgyListSummariesResult> {
    const now = Date.now();
    // 仅复用完整健康快照；任何降级或探测失败均不写入健康缓存，保证下一次查询立即重试恢复（C10 / C3）。
    if (this.cachedList && this.cachedList.result.listMeta.complete && now - this.cachedList.at < this.listCacheMs) {
      return {
        summaries: this.cachedList.result.summaries,
        listMeta: freezeListMeta(this.cachedList.result.listMeta),
      };
    }
    const raw = await this.deps.backend.listSummaries();
    const result: AgyListSummariesResult = {
      summaries: raw.summaries,
      listMeta: freezeListMeta(raw.listMeta),
    };
    if (result.listMeta.complete) {
      this.cachedList = { at: Date.now(), result };
    }
    return {
      summaries: result.summaries,
      listMeta: freezeListMeta(result.listMeta),
    };
  }

  private async toRecord(
    summary: AcpSessionSummary,
    origin: AgySessionOrigin,
    mem: { cwd: string; createdAt: number; updatedAt: number; title: string | null } | undefined,
    precomputed?: {
      resolvedCwd?: string;
      checkDirectoryExists?: (dir: string) => Promise<boolean>;
    },
  ): Promise<SessionRecord> {
    const overlay = this.deps.overlay.get(summary.sessionId);
    const disk = await this.deps.backend.diskRevision?.(summary.sessionId, origin);
    const summaryUpdatedAt = parseIsoSeconds(summary.updatedAt, 0);
    // 仅 transcript.jsonl 反映真实对话写入时间；SQLite .db/.db-wal 可能在只读或 checkpoint 时
    // 刷新 mtime，仅在 summary 缺失有效时间戳时作为兜底，不覆盖已有历史会话的 updatedAt。
    const diskSec = disk?.transcriptPath ? Math.floor(disk.mtimeMs / 1000) : 0;
    const fallbackDiskSec = summaryUpdatedAt > 0 ? 0 : disk ? Math.floor(disk.mtimeMs / 1000) : 0;
    // 缺失全部有效时间戳时输出稳定 0（去掉 `|| nowSec` 兜底，避免跨页查询时排序漂移）。
    const updatedAt = Math.max(
      summaryUpdatedAt,
      diskSec,
      fallbackDiskSec,
      mem?.updatedAt ?? 0,
      overlay?.updatedAt ?? 0,
    );
    const createdAt = overlay?.createdAt ?? mem?.createdAt ?? updatedAt;

    let cwd: string;
    if (precomputed?.resolvedCwd !== undefined) {
      cwd = precomputed.resolvedCwd;
    } else {
      const fallbackCwd = (mem?.cwd || overlay?.cwd || "").trim() || undefined;
      const rawSummaryCwd = summary.cwd?.trim() ? await normalizeNativeCwd(summary.cwd, fallbackCwd) : "";
      const normalizedTmp = os.tmpdir().replace(/\/+$/, "");
      const summaryCwd = rawSummaryCwd && rawSummaryCwd.replace(/\/+$/, "") !== normalizedTmp ? rawSummaryCwd : "";
      cwd = (summaryCwd || mem?.cwd || overlay?.cwd || rawSummaryCwd).trim();
    }
    const checkDirExists = precomputed?.checkDirectoryExists ?? directoryExists;
    const cwdMissing = Boolean(cwd) && !(await checkDirExists(cwd));
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
        // - 旧版 overlay 兼容（B15 round5）：b36 等旧格式映射按工具完成顺序存储且缺少 invocationIndex/outputFingerprint，
        //   仅当原生 transcript 步骤结构证明它们严格串行（单工具步、发起时无在途工具、前一步已终态完成后才发起后一步）时，
        //   才按原数组顺序恢复原稳定 ID；若原生步骤存在并发重叠则绝不猜测绑定，安全保留确定性回退 ID（:tool:seq）。
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
          })
          && areNativeToolsProvablySerial(remainingItems.map((entry) => entry.item));
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
  const rewritten: Turn = {
    ...turn,
    id: targetTurnId,
    items: turn.items.map((item) => {
      if (!item.id.startsWith(oldPrefix)) return item;
      const cloned = { ...item, id: `${targetTurnId}:${item.id.slice(oldPrefix.length)}` };
      copyNativeToolStepLifecycle(item, cloned);
      return cloned;
    }),
  };
  copyNativeTranscriptTurnMeta(turn, rewritten);
  return rewritten;
}

function visibleItemDedupKey(item: Turn["items"][number]): string {
  if (item.type === "agentMessage") {
    return `agent:${item.text.replace(/\s+/g, " ").trim()}`;
  }
  if (item.type === "reasoning") {
    return `reasoning:${item.content.join("\n").replace(/\s+/g, " ").trim()}`;
  }
  if (item.type === "plan") {
    return `plan:${item.text.replace(/\s+/g, " ").trim()}`;
  }
  if (item.type === "commandExecution" || item.type === "fileChange" || item.type === "dynamicToolCall") {
    const fp = toolItemFingerprint(item) ?? item.id;
    const outFp = toolItemOutputFingerprint(item) ?? "";
    return `${item.type}:${fp}:${outFp}`;
  }
  return `${item.type}:${item.id}`;
}

function normalizeComparableText(text: string): string {
  return text.replace(/\s+/g, " ").trim();
}

function preferFullerStreamedText(nativeText: string, synthText: string): string | undefined {
  const normSynth = normalizeComparableText(synthText);
  if (!normSynth) return undefined;
  const normNative = normalizeComparableText(nativeText);
  if (!normNative) return synthText;
  if (synthText.startsWith(nativeText) && synthText.length > nativeText.length) {
    return synthText;
  }
  const trimmedNative = nativeText.trim();
  const trimmedSynth = synthText.trim();
  if (trimmedSynth.startsWith(trimmedNative) && trimmedSynth.length > trimmedNative.length) {
    return synthText;
  }
  if (normSynth.startsWith(normNative) && normSynth.length > normNative.length) {
    return synthText;
  }
  return undefined;
}

function mergeSameIdVisibleItem(
  nativeItem: Turn["items"][number],
  synthItem: Turn["items"][number],
): Turn["items"][number] {
  if (nativeItem.type === "agentMessage" && synthItem.type === "agentMessage") {
    const fuller = preferFullerStreamedText(nativeItem.text, synthItem.text);
    if (fuller !== undefined) {
      return {
        ...nativeItem,
        text: fuller,
        phase: nativeItem.phase ?? synthItem.phase,
        memoryCitation: nativeItem.memoryCitation ?? synthItem.memoryCitation,
        delivery: nativeItem.delivery ?? synthItem.delivery,
        questions: nativeItem.questions ?? synthItem.questions,
      };
    }
    return nativeItem;
  }
  if (nativeItem.type === "plan" && synthItem.type === "plan") {
    const fuller = preferFullerStreamedText(nativeItem.text, synthItem.text);
    if (fuller !== undefined) {
      return { ...nativeItem, text: fuller };
    }
    return nativeItem;
  }
  if (nativeItem.type === "reasoning" && synthItem.type === "reasoning") {
    const fuller = preferFullerStreamedText(nativeItem.content.join("\n"), synthItem.content.join("\n"));
    if (fuller !== undefined) {
      return {
        ...nativeItem,
        content: synthItem.content,
        summary: nativeItem.summary.length > 0 ? nativeItem.summary : synthItem.summary,
      };
    }
    return nativeItem;
  }
  return nativeItem;
}

function applyUserMessageClientId(turn: Turn, clientId: string | undefined): Turn {
  if (!clientId) return turn;
  let changed = false;
  const items = turn.items.map((item) => {
    if (item.type === "userMessage" && !item.clientId) {
      changed = true;
      return { ...item, clientId };
    }
    return item;
  });
  if (!changed) return turn;
  const updated: Turn = { ...turn, items };
  copyNativeTranscriptTurnMeta(turn, updated);
  return updated;
}

function mergeVisibleTurnItems(aligned: Turn, synthetic: Turn, attemptClientId?: string): Turn["items"] {
  const synthUser = synthetic.items.find((item) => item.type === "userMessage");
  const synthNonUsers = synthetic.items.filter((item) => item.type !== "userMessage");
  const alignedHasNonUser = aligned.items.some((item) => item.type !== "userMessage");
  const resolvedClientId =
    (synthUser?.type === "userMessage" && synthUser.clientId) || attemptClientId || undefined;

  const mergedItems: Turn["items"] = aligned.items.map((item) => {
    if (item.type === "userMessage" && !item.clientId && resolvedClientId) {
      return { ...item, clientId: resolvedClientId };
    }
    return item;
  });

  if (!mergedItems.some((item) => item.type === "userMessage") && synthUser) {
    mergedItems.unshift(
      synthUser.type === "userMessage" && !synthUser.clientId && resolvedClientId
        ? { ...synthUser, clientId: resolvedClientId }
        : synthUser,
    );
  }

  if (synthNonUsers.length === 0) {
    return mergedItems;
  }

  if (!alignedHasNonUser) {
    // 原生延迟落盘仅含 USER_INPUT 时，完整保留 syntheticTurn 中已向用户展示的局部输出与原始消息 ID（B10 round5）。
    return [...mergedItems, ...synthNonUsers];
  }

  const existingKeys = new Set(mergedItems.filter((item) => item.type !== "userMessage").map(visibleItemDedupKey));
  const existingIdIndex = new Map<string, number>();
  mergedItems.forEach((item, idx) => {
    existingIdIndex.set(item.id, idx);
  });
  for (const item of synthNonUsers) {
    const existingIdx = existingIdIndex.get(item.id);
    if (existingIdx !== undefined) {
      // 同 ID 项（如助手回复仅落盘前半段）合并时保留本地已展示的更完整内容后缀（B10 round6）。
      const existing = mergedItems[existingIdx]!;
      const merged = mergeSameIdVisibleItem(existing, item);
      if (merged !== existing) {
        mergedItems[existingIdx] = merged;
        existingKeys.add(visibleItemDedupKey(merged));
      }
      continue;
    }
    const key = visibleItemDedupKey(item);
    if (existingKeys.has(key)) continue;
    existingIdIndex.set(item.id, mergedItems.length);
    existingKeys.add(key);
    mergedItems.push(item);
  }
  return mergedItems;
}

function applyAttemptOutcome(turn: Turn, attempt: TurnAttemptRecord): Turn {
  const aligned = rewriteTurnId(turn, attempt.turnId);
  if (aligned.status === "inProgress") return aligned;

  let mergedBase = aligned;
  if (attempt.syntheticTurn) {
    const synthAligned = rewriteTurnId(attempt.syntheticTurn, attempt.turnId);
    const mergedItems = mergeVisibleTurnItems(aligned, synthAligned, attempt.clientId);
    if (
      mergedItems !== aligned.items
      || (aligned.startedAt === null && synthAligned.startedAt !== null)
      || (aligned.completedAt === null && synthAligned.completedAt !== null)
    ) {
      mergedBase = {
        ...aligned,
        items: mergedItems,
        startedAt: aligned.startedAt ?? synthAligned.startedAt,
        completedAt: aligned.completedAt ?? synthAligned.completedAt,
        durationMs: aligned.durationMs ?? synthAligned.durationMs,
      };
      copyNativeTranscriptTurnMeta(aligned, mergedBase);
    }
  } else if (attempt.clientId) {
    mergedBase = applyUserMessageClientId(aligned, attempt.clientId);
  }

  if (attempt.status === "completed") {
    return mergedBase;
  }
  if (attempt.status === "failed") {
    const failedTurn: Turn = {
      ...mergedBase,
      status: "failed",
      error: mergedBase.error ?? {
        message: attempt.error ?? "Antigravity turn failed",
        codexErrorInfo: null,
        additionalDetails: null,
        misalignment: null,
      },
    };
    copyNativeTranscriptTurnMeta(mergedBase, failedTurn);
    return failedTurn;
  }
  if (attempt.status === "interrupted" && mergedBase.status === "completed") {
    const interruptedTurn: Turn = {
      ...mergedBase,
      status: "interrupted",
      error: null,
    };
    copyNativeTranscriptTurnMeta(mergedBase, interruptedTurn);
    return interruptedTurn;
  }
  return mergedBase;
}

function promptsMatchAttempt(attempt: TurnAttemptRecord, candidatePrompt: string): boolean {
  if (attempt.promptHash) {
    if (!candidatePrompt) return false;
    return hashNormalizedPrompt(candidatePrompt) === attempt.promptHash;
  }
  const attemptPrompt = normalizeTurnPrompt(attempt.promptText);
  if (attemptPrompt === "" && candidatePrompt === "") return true;
  if (attemptPrompt === "" || candidatePrompt === "") return false;
  if (candidatePrompt === attemptPrompt) return true;
  if (attempt.promptTruncated) {
    return candidatePrompt.startsWith(attemptPrompt);
  }
  // 兼容旧版未保存 promptHash/promptTruncated 的 240 字符截断：
  // 保留截断边界尾空格（仅 trimStart），避免第 240 字符为空格时 trim 后缩成 239 字符导致冷读改写 ID（B10 round5）。
  const rawLeadingTrimmed = attempt.promptText.replace(/\s+/g, " ").trimStart();
  if (rawLeadingTrimmed.length === PROMPT_PREVIEW_MAX_CHARS && candidatePrompt.startsWith(rawLeadingTrimmed)) {
    return true;
  }
  return attemptPrompt.length === PROMPT_PREVIEW_MAX_CHARS && candidatePrompt.startsWith(attemptPrompt);
}

function turnHasAssistantOrToolProgress(turn: Turn | undefined): boolean {
  if (!turn) return false;
  return turn.items.some((item) => item.type !== "userMessage");
}

function isCandidateVisiblePrefixOfAttempt(candidate: Turn, attempt: TurnAttemptRecord): boolean {
  if (!attempt.syntheticTurn) return false;
  const aligned = rewriteTurnId(candidate, attempt.turnId);
  const synthAligned = rewriteTurnId(attempt.syntheticTurn, attempt.turnId);
  const candidateNonUsers = aligned.items.filter((item) => item.type !== "userMessage");
  if (candidateNonUsers.length === 0) return false;

  const synthById = new Map<string, Turn["items"][number]>();
  for (const item of synthAligned.items) {
    if (item.type !== "userMessage") {
      synthById.set(item.id, item);
    }
  }

  let matchedAnyTextPrefix = false;
  for (const item of candidateNonUsers) {
    const synthItem = synthById.get(item.id);
    if (!synthItem || synthItem.type !== item.type) return false;
    if (item.type === "agentMessage" && synthItem.type === "agentMessage") {
      const normNative = normalizeComparableText(item.text);
      const normSynth = normalizeComparableText(synthItem.text);
      if (!normNative || !normSynth.startsWith(normNative)) return false;
      matchedAnyTextPrefix = true;
    } else if (item.type === "plan" && synthItem.type === "plan") {
      const normNative = normalizeComparableText(item.text);
      const normSynth = normalizeComparableText(synthItem.text);
      if (!normNative || !normSynth.startsWith(normNative)) return false;
      matchedAnyTextPrefix = true;
    } else if (item.type === "reasoning" && synthItem.type === "reasoning") {
      const normNative = normalizeComparableText(item.content.join("\n"));
      const normSynth = normalizeComparableText(synthItem.content.join("\n"));
      if (!normNative || !normSynth.startsWith(normNative)) return false;
      matchedAnyTextPrefix = true;
    } else if (visibleItemDedupKey(item) !== visibleItemDedupKey(synthItem)) {
      return false;
    }
  }
  return matchedAnyTextPrefix;
}

function isLatePersistedTimingCompatible(attempt: TurnAttemptRecord, candidate: Turn): boolean {
  const meta = getNativeTranscriptTurnMeta(candidate);
  if (
    attempt.startedAtMs !== undefined
    && attempt.completedAtMs !== undefined
    && meta?.userCreatedAtMs !== undefined
  ) {
    // 原生 USER_INPUT.created_at 在上游收到请求时记录，同一次尝试的延迟刷盘必然落在该尝试窗口内（允许 2s 秒级截断误差）。
    return (
      meta.userCreatedAtMs >= attempt.startedAtMs - 2_000
      && meta.userCreatedAtMs <= attempt.completedAtMs + 2_000
    );
  }
  return true;
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
    const candidateMeta = candidate ? getNativeTranscriptTurnMeta(candidate) : undefined;
    const candidatePrompt = candidate ? extractTurnUserPrompt(candidate) : "";
    const stepIndexMismatch =
      attempt.nativeUserStepIndex !== undefined
      && candidateMeta?.userStepIndex !== undefined
      && attempt.nativeUserStepIndex !== candidateMeta.userStepIndex;
    // 严格按完整提示词哈希（或旧版截断边界）精确匹配，并校验已确认落盘的原生 step_index（B10 round5）。
    const promptsCompatible = Boolean(candidate) && !stepIndexMismatch && promptsMatchAttempt(attempt, candidatePrompt);

    let laterAttemptNeedsNative = false;
    if (promptsCompatible && attempt.status !== "completed" && attempt.persisted !== true && candidatePrompt) {
      // 同提示词连续重试：若后续存在同提示词且需要原生槽位的尝试（不仅是 completed，也包括后续已落盘或未标
      // persisted:false 的 interrupted/failed 重试），且剩余原生回合不足以同时覆盖，必须留给后续尝试（B10 round5）。
      let laterCommittedSamePrompt = 0;
      let laterNonUnpersistedSamePrompt = 0;
      for (let j = i + 1; j < finishedAttempts.length; j += 1) {
        const other = finishedAttempts[j]!;
        if (!promptsMatchAttempt(other, candidatePrompt)) continue;
        if (other.status === "completed" || other.persisted === true) {
          laterCommittedSamePrompt += 1;
        }
        if (other.persisted !== false) {
          laterNonUnpersistedSamePrompt += 1;
        }
      }
      let remainingSamePromptNative = 0;
      for (let k = nativeIdx; k < nativeTurns.length; k += 1) {
        const p = extractTurnUserPrompt(nativeTurns[k]!);
        if (promptsMatchAttempt(attempt, p)) {
          remainingSamePromptNative += 1;
        }
      }
      if (attempt.persisted === false && laterNonUnpersistedSamePrompt > 0 && remainingSamePromptNative <= laterNonUnpersistedSamePrompt) {
        laterAttemptNeedsNative = true;
      } else if (laterCommittedSamePrompt > 0 && remainingSamePromptNative <= laterCommittedSamePrompt) {
        laterAttemptNeedsNative = true;
      }
    }

    let shouldTreatAsUnpersisted = !candidate || !promptsCompatible || laterAttemptNeedsNative;
    if (!shouldTreatAsUnpersisted && candidate && attempt.status !== "completed") {
      const candidateHasProgress = turnHasAssistantOrToolProgress(candidate);
      const attemptHasProgress = turnHasAssistantOrToolProgress(attempt.syntheticTurn);
      if (attempt.persisted === false) {
        // 兼容旧版 b36 或取消/报错瞬间 transcript 延迟刷盘：
        // - 必须符合尝试时间窗（避免吞并更晚发起的独立同文本重试）；
        // - 仅当原生终态一致，或原生仅落盘 USER_INPUT 且本次尝试为 interrupted / 已有流式进展的 failed 时归并；
        // - 无任何产出的早失败（persisted:false, !attemptHasProgress）绝不吞并独立落盘的无回复同文本重试（B10 round5）。
        const timingOk = isLatePersistedTimingCompatible(attempt, candidate);
        const isLatePersistedSameAttempt =
          timingOk
          && (
            candidate.status === attempt.status
            || (!candidateHasProgress && (attempt.status === "interrupted" || attemptHasProgress))
            || (attemptHasProgress && isCandidateVisiblePrefixOfAttempt(candidate, attempt))
          );
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
