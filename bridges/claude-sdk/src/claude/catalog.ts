import type { Turn } from "../protocol/codex/v2/Turn.ts";
import { messagesToTurns } from "./history.ts";
import type { Overlay } from "./overlay.ts";
import type { ClaudeSessions, SessionInfo } from "./sdk.ts";
import type { ActivityClock, TranscriptIndex } from "./transcripts.ts";

export interface SessionRecord {
  id: string;
  cwd: string;
  name: string | null;
  preview: string;
  /** Unix 秒。 */
  createdAt: number;
  /** Unix 秒；最后一条对话消息的时间，不是文件修改时间。 */
  updatedAt: number;
  gitBranch: string | null;
  path: string | null;
  archived: boolean;
}

export interface CatalogDeps {
  sessions: ClaudeSessions;
  transcripts: TranscriptIndex;
  activity: ActivityClock;
  overlay: Overlay;
}

const toSeconds = (ms: number) => Math.floor(ms / 1000);

/** 会话目录：每次都从 Claude Code 自己的数据读取，不保存第二份目录。 */
export class Catalog {
  constructor(private readonly deps: CatalogDeps) {}

  /**
   * `dirs` 为空时列出全部会话；否则按仓库列出——目录在 Git 仓库内时包含同仓
   * 所有 worktree 的会话（与 SDK `listSessions({ dir })` 的语义一致）。
   */
  async list(dirs: readonly string[] | undefined): Promise<SessionRecord[]> {
    await this.prepare();
    const infos = dirs?.length
      ? (await Promise.all(dirs.map((dir) => this.deps.sessions.list({ dir })))).flat()
      : await this.deps.sessions.list({});
    const unique = new Map<string, SessionInfo>();
    for (const info of infos) if (!unique.has(info.sessionId)) unique.set(info.sessionId, info);
    return Promise.all([...unique.values()].map((info) => this.toRecord(info)));
  }

  async get(sessionId: string): Promise<SessionRecord | undefined> {
    await this.prepare();
    const info = await this.deps.sessions.info(sessionId);
    return info ? this.toRecord(info) : undefined;
  }

  private async prepare(): Promise<void> {
    await Promise.all([this.deps.overlay.load(), this.deps.transcripts.refresh()]);
  }

  private async toRecord(info: SessionInfo): Promise<SessionRecord> {
    const file = this.deps.transcripts.get(info.sessionId);
    const activityMs = file ? await this.deps.activity.lastActivityMs(file) : undefined;
    const updatedMs = activityMs ?? info.lastModified;
    return {
      id: info.sessionId,
      cwd: info.cwd ?? "",
      // customTitle 同时涵盖 /rename 与 Claude 自动生成的标题；没有标题时 summary
      // 退化为提问原文，只能当 preview，不能冒充标题。
      name: info.customTitle?.trim() || null,
      preview: info.firstPrompt?.trim() || info.summary?.trim() || "",
      createdAt: toSeconds(info.createdAt ?? updatedMs),
      updatedAt: toSeconds(updatedMs),
      gitBranch: info.gitBranch ?? null,
      path: file?.path ?? null,
      archived: this.deps.overlay.isArchived(info.sessionId),
    };
  }
}

const HISTORY_CACHE_SIZE = 8;

/** 历史按 transcript 大小缓存：文件没变就不重新解析，分页请求不会反复读大文件。 */
export class HistoryStore {
  private readonly cache = new Map<string, { size: number; running: boolean; turns: Turn[] }>();

  constructor(private readonly deps: Pick<CatalogDeps, "sessions" | "transcripts">) {}

  /** `running`：会话仍有 turn 在运行，最后一轮没有结果的工具调用显示为进行中。 */
  async turns(sessionId: string, running = false): Promise<Turn[]> {
    await this.deps.transcripts.refresh();
    const size = this.deps.transcripts.get(sessionId)?.size ?? -1;
    const cached = this.cache.get(sessionId);
    if (cached && cached.size === size && cached.running === running && size >= 0) {
      this.cache.delete(sessionId);
      this.cache.set(sessionId, cached);
      return cached.turns;
    }
    const messages = await this.deps.sessions.messages(sessionId);
    const turns = messagesToTurns(messages, { sessionId, running });
    this.cache.set(sessionId, { size, running, turns });
    while (this.cache.size > HISTORY_CACHE_SIZE) {
      const oldest = this.cache.keys().next().value;
      if (oldest === undefined) break;
      this.cache.delete(oldest);
    }
    return turns;
  }
}
