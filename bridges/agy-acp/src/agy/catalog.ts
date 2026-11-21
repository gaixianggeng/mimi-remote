import { stat } from "node:fs/promises";
import os from "node:os";
import type { Turn } from "@mimi/appserver-kit/protocol/codex/v2/Turn.ts";
import type { AcpSessionSummary, AcpSessionUpdate } from "../acp/types.ts";
import { SharedReadonlyAcp } from "./binary.ts";
import { conversationDbPath, resolveSessionOrigin, type AgySessionOrigin } from "./env.ts";
import type { GitRepoIndex } from "./git.ts";
import { updatesToTurns } from "./history.ts";
import type { AgyOverlay } from "./overlay.ts";
import {
  inspectTranscriptActivity,
  readTranscriptTurns,
  resolveTranscriptPath,
  snapshotTranscriptState,
  type TranscriptActivityInfo,
  type TranscriptTurnSnapshot,
} from "./transcript.ts";

export interface SessionRecord {
  id: string;
  cwd: string;
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

export interface AgySessionBackend {
  listSummaries(): Promise<AcpSessionSummary[]>;
  loadReplay(sessionId: string, cwd: string, origin: AgySessionOrigin): Promise<AcpSessionUpdate[]>;
  resolveSessionOrigin(sessionId: string): Promise<AgySessionOrigin | null>;
  conversationFilePath(sessionId: string, origin: AgySessionOrigin): string | null;
  diskRevision?(sessionId: string, origin: AgySessionOrigin): Promise<DiskRevisionInfo | undefined>;
  inspectExternalActivity?(sessionId: string, origin: AgySessionOrigin): Promise<TranscriptActivityInfo | undefined>;
  snapshotTranscriptState?(sessionId: string, origin: AgySessionOrigin): Promise<TranscriptTurnSnapshot | undefined>;
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

export function createAcpSessionBackend(
  cliSharedAcp: SharedReadonlyAcp,
  otherSharedAcp: SharedReadonlyAcp,
  env: () => NodeJS.ProcessEnv = () => process.env,
  hasLiveSession?: (sessionId: string) => boolean,
): AgySessionBackend {
  return {
    async listSummaries() {
      return cliSharedAcp.use((client) => client.sessionList());
    },

    async loadReplay(sessionId: string, cwd: string, origin: AgySessionOrigin) {
      const effectiveCwd = cwd.trim() || os.tmpdir();
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
      return inspectTranscriptActivity(sessionId, origin, env());
    },

    snapshotTranscriptState(sessionId: string, origin: AgySessionOrigin) {
      return snapshotTranscriptState(sessionId, origin, env());
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
  private cachedList: { at: number; summaries: AcpSessionSummary[] } | undefined;

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
    if (this.cachedList && now - this.cachedList.at < this.listCacheMs) {
      return this.cachedList.summaries;
    }
    const summaries = await this.deps.backend.listSummaries();
    this.cachedList = { at: Date.now(), summaries };
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
    const gitInfo = cwd ? await this.deps.git.inspect(cwd) : { branch: null };
    const title = overlay?.customTitle?.trim() || mem?.title?.trim() || summary.title?.trim() || null;
    const preview = overlay?.preview?.trim() || title || "";
    return {
      id: summary.sessionId,
      cwd,
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
  private readonly cache = new Map<string, { revision: string; running: boolean; holderActive: boolean; turns: Turn[] }>();

  constructor(
    private readonly catalog: AgyCatalog,
    private readonly backend: AgySessionBackend,
    /** 若当前会话正在本适配器执行活跃回合，优先直接读取内存流式快照。 */
    private readonly liveTurns?: (sessionId: string) => Turn[] | undefined,
    /** 为本进程发起的历史回合补回本地 clientId，确保 iOS 重开会话刷新时与本地回显精确对齐。 */
    private readonly clientIdForTurn?: (turnId: string) => string | undefined,
  ) {}

  invalidate(sessionId: string): void {
    this.cache.delete(sessionId);
  }

  /**
   * 查询已落盘历史的回合数，用于在发起新回合时生成与历史快照一致的确定性 `turnId`。
   * 仅优先读取内存缓存或 transcript 文件，避免在活跃会话上额外触发 `session/load`。
   */
  async persistedTurnCount(sessionId: string): Promise<number> {
    const cached = this.cache.get(sessionId);
    const record = await this.catalog.get(sessionId);
    if (!record) return cached?.turns.length ?? 0;
    const disk = await this.backend.diskRevision?.(sessionId, record.origin);
    if (disk?.transcriptPath && this.backend.loadTranscriptTurns) {
      const turns = await this.backend.loadTranscriptTurns(sessionId, record.cwd, disk.transcriptPath, false, false);
      return turns.length;
    }
    return cached?.turns.length ?? 0;
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

    let turns: Turn[];
    if (disk?.transcriptPath && this.backend.loadTranscriptTurns) {
      turns = await this.backend.loadTranscriptTurns(sessionId, record.cwd, disk.transcriptPath, running, holderActive);
    } else {
      const updates = await this.backend.loadReplay(sessionId, record.cwd, record.origin);
      turns = updatesToTurns(sessionId, record.cwd, updates, running);
    }
    turns = this.attachKnownClientIds(turns);

    this.cache.delete(sessionId);
    this.cache.set(sessionId, { revision, running, holderActive, turns });
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
}
