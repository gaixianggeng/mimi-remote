import os from "node:os";
import type { Turn } from "@mimi/appserver-kit/protocol/codex/v2/Turn.ts";
import type { AcpSessionSummary, AcpSessionUpdate } from "../acp/types.ts";
import { SharedReadonlyAcp } from "./binary.ts";
import { conversationDbPath, hasCliConversationDb } from "./env.ts";
import type { GitRepoIndex } from "./git.ts";
import { updatesToTurns } from "./history.ts";
import type { AgyOverlay } from "./overlay.ts";

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
}

export interface AgySessionBackend {
  listSummaries(): Promise<AcpSessionSummary[]>;
  loadReplay(sessionId: string, cwd: string): Promise<AcpSessionUpdate[]>;
  hasLocalConversation(sessionId: string): Promise<boolean>;
  conversationFilePath(sessionId: string): string | null;
}

export function createAcpSessionBackend(
  sharedAcp: SharedReadonlyAcp,
  env: () => NodeJS.ProcessEnv = () => process.env,
): AgySessionBackend {
  return {
    async listSummaries() {
      return sharedAcp.use((client) => client.sessionList());
    },

    async loadReplay(sessionId: string, cwd: string) {
      const effectiveCwd = cwd.trim() || os.tmpdir();
      return sharedAcp.use(async (client) => {
        const { updates } = await client.sessionLoadWithReplay(sessionId, effectiveCwd);
        await client.sessionClose(sessionId).catch(() => {});
        return updates;
      });
    },

    hasLocalConversation(sessionId: string) {
      return hasCliConversationDb(sessionId, env());
    },

    conversationFilePath(sessionId: string) {
      return conversationDbPath(sessionId, env()) ?? null;
    },
  };
}

function parseIsoSeconds(raw: string | null | undefined, fallbackSeconds: number): number {
  if (!raw) return fallbackSeconds;
  const ms = Date.parse(raw);
  return Number.isFinite(ms) ? Math.floor(ms / 1000) : fallbackSeconds;
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

  async list(dirs?: readonly string[]): Promise<SessionRecord[]> {
    await this.deps.overlay.load();
    const summaries = await this.fetchSummaries();
    const activeMap = this.deps.inMemorySessions?.() ?? new Map();
    const byId = new Map<string, AcpSessionSummary>();
    for (const item of summaries) {
      if (!item.sessionId) continue;
      if (activeMap.has(item.sessionId) || (await this.deps.backend.hasLocalConversation(item.sessionId))) {
        byId.set(item.sessionId, item);
      }
    }
    for (const [sessionId, mem] of activeMap) {
      if (!byId.has(sessionId)) {
        byId.set(sessionId, {
          sessionId,
          cwd: mem.cwd,
          title: mem.title,
          updatedAt: new Date(mem.updatedAt * 1000).toISOString(),
        });
      }
    }

    const records: SessionRecord[] = [];
    for (const summary of byId.values()) {
      const record = await this.toRecord(summary, activeMap.get(summary.sessionId));
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
    if (!mem && !(await this.deps.backend.hasLocalConversation(sessionId))) {
      return undefined;
    }
    return this.toRecord(
      found ?? {
        sessionId,
        cwd: mem!.cwd,
        title: mem!.title,
        updatedAt: new Date(mem!.updatedAt * 1000).toISOString(),
      },
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
    mem: { cwd: string; createdAt: number; updatedAt: number; title: string | null } | undefined,
  ): Promise<SessionRecord> {
    const overlay = this.deps.overlay.get(summary.sessionId);
    const nowSec = Math.floor(Date.now() / 1000);
    const updatedAt = Math.max(
      parseIsoSeconds(summary.updatedAt, mem?.updatedAt ?? nowSec),
      mem?.updatedAt ?? 0,
      overlay?.updatedAt ?? 0,
    );
    const createdAt = overlay?.createdAt ?? mem?.createdAt ?? updatedAt;
    const cwd = (summary.cwd?.trim() || mem?.cwd || overlay?.cwd || "").trim();
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
      path: this.deps.backend.conversationFilePath(summary.sessionId),
      archived: this.deps.overlay.isArchived(summary.sessionId),
    };
  }
}

const HISTORY_CACHE_LIMIT = 8;

export class AgyHistoryStore {
  private readonly cache = new Map<string, { updatedAt: number; running: boolean; turns: Turn[] }>();

  constructor(
    private readonly catalog: AgyCatalog,
    private readonly backend: AgySessionBackend,
    /** 若当前会话已有常驻进程并记录了最新回合列表，优先直接读取内存，无需冷启动第二个 `agy acp`。 */
    private readonly liveTurns?: (sessionId: string) => Turn[] | undefined,
  ) {}

  invalidate(sessionId: string): void {
    this.cache.delete(sessionId);
  }

  async turns(sessionId: string, running = false): Promise<Turn[]> {
    const live = this.liveTurns?.(sessionId);
    if (live) return live;
    const record = await this.catalog.get(sessionId);
    if (!record) return [];
    const cached = this.cache.get(sessionId);
    if (cached && cached.updatedAt === record.updatedAt && cached.running === running) {
      return cached.turns;
    }
    const updates = await this.backend.loadReplay(sessionId, record.cwd);
    const turns = updatesToTurns(sessionId, record.cwd, updates, running);
    this.cache.set(sessionId, { updatedAt: record.updatedAt, running, turns });
    while (this.cache.size > HISTORY_CACHE_LIMIT) {
      const first = this.cache.keys().next().value;
      if (!first) break;
      this.cache.delete(first);
    }
    return turns;
  }
}
