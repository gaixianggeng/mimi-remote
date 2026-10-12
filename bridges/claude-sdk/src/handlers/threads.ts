import type { Thread } from "../protocol/codex/v2/Thread.ts";
import type { ThreadListResponse } from "../protocol/codex/v2/ThreadListResponse.ts";
import type { ThreadLoadedListResponse } from "../protocol/codex/v2/ThreadLoadedListResponse.ts";
import type { Turn } from "../protocol/codex/v2/Turn.ts";
import { RpcError } from "../rpc/frames.ts";
import type { Catalog, HistoryStore, SessionRecord } from "../claude/catalog.ts";
import { decodeCursor, encodeCursor, readDirection, readLimit, type Direction } from "../util/cursor.ts";
import { ownerSummary, type SessionHolder } from "../runtime/holders.ts";
import { USER_AGENT } from "../version.ts";

/** 旧 bridge 在 Thread 上附带的扩展字段，iOS 与 gateway 依赖它判断能否直接发送。 */
export type AdapterThread = Thread & { canAcceptDirectInput: boolean; claudeOwner?: Record<string, unknown> };

export interface LiveState {
  canAcceptDirectInput: boolean;
  status?: Thread["status"];
  claudeOwner?: Record<string, unknown>;
}

export function toThread(
  record: SessionRecord,
  turns: Turn[] = [],
  live: LiveState = { canAcceptDirectInput: false },
): AdapterThread {
  return {
    id: record.id,
    sessionId: record.id,
    forkedFromId: null,
    parentThreadId: null,
    preview: record.preview,
    ephemeral: false,
    section: null,
    sectionEnteredAt: null,
    projectId: null,
    historyMode: "paginated",
    modelProvider: "anthropic",
    model: null,
    reasoningEffort: null,
    createdAt: record.createdAt,
    updatedAt: record.updatedAt,
    recencyAt: null,
    status: live.status ?? { type: "notLoaded" },
    path: record.path,
    cwd: record.cwd,
    cliVersion: USER_AGENT,
    originator: null,
    source: "appServer",
    threadSource: null,
    agentNickname: null,
    agentRole: null,
    gitInfo: record.gitBranch ? { sha: null, branch: record.gitBranch, originUrl: null } : null,
    name: record.name,
    turns,
    canAcceptDirectInput: live.canAcceptDirectInput,
    ...(live.claudeOwner ? { claudeOwner: live.claudeOwner } : {}),
  };
}

type Params = Record<string, unknown>;

function asParams(value: unknown): Params {
  if (value && typeof value === "object" && !Array.isArray(value)) return value as Params;
  throw RpcError.invalidParams("params 必须是对象");
}

function readDirs(value: unknown): string[] | undefined {
  if (value === undefined || value === null) return undefined;
  const list = Array.isArray(value) ? value : [value];
  if (!list.every((entry) => typeof entry === "string" && entry.trim() !== "")) {
    throw RpcError.invalidParams("cwd 必须是非空字符串或字符串数组");
  }
  return list.map((entry) => (entry as string).trim());
}

interface ListCursor extends Record<string, unknown> {
  v: number;
  id: string;
  incl?: boolean;
}

function compare(a: [number, string], b: [number, string]): number {
  return a[0] - b[0] || (a[1] < b[1] ? -1 : a[1] > b[1] ? 1 : 0);
}

/** 会话的实时状态来源：占用登记与本适配器的运行时。缺省（只读模式）一律不可直接发送。 */
export interface LiveSource {
  holders(): Promise<Map<string, SessionHolder>>;
  activeTurnId(threadId: string): string | undefined;
  loadedThreadIds(): string[];
}

export function createThreadHandlers(catalog: Catalog, history: HistoryStore, liveSource?: LiveSource) {
  const liveStates = async () => {
    const holders = liveSource ? await liveSource.holders() : new Map<string, SessionHolder>();
    return (threadId: string): LiveState => {
      if (!liveSource) return { canAcceptDirectInput: false };
      const holder = holders.get(threadId);
      return {
        canAcceptDirectInput: !holder,
        ...(liveSource.activeTurnId(threadId) ? { status: { type: "active", activeFlags: [] } } : {}),
        ...(holder ? { claudeOwner: ownerSummary(holder) } : {}),
      };
    };
  };
  return {
    async list(raw: unknown): Promise<ThreadListResponse> {
      const params = asParams(raw);
      const limit = readLimit(params.limit, 25, 200);
      const direction: Direction = readDirection(params.sortDirection, "desc");
      // 协议约定省略 sortKey 时按创建时间排序（旧 bridge 同样如此）。
      const byCreated = params.sortKey === undefined || params.sortKey === null || params.sortKey === "created_at";
      const cursor = decodeCursor<ListCursor>(params.cursor, "thread/list.cursor");
      const archived = params.archived === true;
      const search = typeof params.searchTerm === "string" ? params.searchTerm.trim().toLowerCase() : "";

      const key = (record: SessionRecord): [number, string] => [byCreated ? record.createdAt : record.updatedAt, record.id];
      const sign = direction === "desc" ? -1 : 1;
      const records = (await catalog.list(readDirs(params.cwd)))
        .filter((record) => record.archived === archived)
        .filter((record) => !search || `${record.name ?? ""}\n${record.preview}`.toLowerCase().includes(search))
        .sort((a, b) => sign * compare(key(a), key(b)));

      const start = cursor
        ? records.findIndex((record) => {
            const order = sign * compare(key(record), [cursor.v, cursor.id]);
            return cursor.incl ? order >= 0 : order > 0;
          })
        : 0;
      const page = start < 0 ? [] : records.slice(start, start + limit);
      const last = page[page.length - 1];
      const first = page[0];
      const hasMore = start >= 0 && start + limit < records.length;
      const stateOf = await liveStates();
      return {
        data: page.map((record) => toThread(record, [], stateOf(record.id))),
        nextCursor: hasMore && last ? encodeCursor({ v: key(last)[0], id: last.id }) : null,
        backwardsCursor: first ? encodeCursor({ v: key(first)[0], id: first.id, incl: true }) : null,
      };
    },

    async read(raw: unknown): Promise<{ thread: AdapterThread }> {
      const params = asParams(raw);
      const threadId = params.threadId;
      if (typeof threadId !== "string" || !threadId) throw RpcError.invalidParams("thread/read.threadId 不能为空");
      const record = await catalog.get(threadId);
      if (!record) throw RpcError.invalidParams(`找不到 Claude 会话 ${threadId}`);
      const running = liveSource?.activeTurnId(threadId) !== undefined;
      const turns = params.includeTurns === true ? await history.turns(threadId, running) : [];
      return { thread: toThread(record, turns, (await liveStates())(threadId)) };
    },

    loaded(): ThreadLoadedListResponse {
      return { data: liveSource?.loadedThreadIds() ?? [], nextCursor: null };
    },
  };
}
