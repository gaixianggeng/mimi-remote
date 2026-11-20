import type { Thread } from "@mimi/appserver-kit/protocol/codex/v2/Thread.ts";
import type { ThreadListResponse } from "@mimi/appserver-kit/protocol/codex/v2/ThreadListResponse.ts";
import type { ThreadLoadedListResponse } from "@mimi/appserver-kit/protocol/codex/v2/ThreadLoadedListResponse.ts";
import type { Turn } from "@mimi/appserver-kit/protocol/codex/v2/Turn.ts";
import { RpcError } from "@mimi/appserver-kit/rpc/frames.ts";
import { decodeCursor, encodeCursor, readDirection, readLimit, type Direction } from "@mimi/appserver-kit/util/cursor.ts";
import type { AgyCatalog, AgyHistoryStore, SessionRecord } from "../agy/catalog.ts";
import { USER_AGENT } from "../version.ts";

export type AdapterThread = Thread & {
  canAcceptDirectInput: boolean;
  claudeOwner?: Record<string, unknown>;
};

export interface LiveState {
  canAcceptDirectInput: boolean;
  status?: Thread["status"];
  claudeOwner?: Record<string, unknown>;
}

export function desktopOwnerSummary(mtimeMs: number): Record<string, unknown> {
  return {
    entrypoint: "desktop",
    kind: "desktop",
    status: "busy",
    pid: null,
    statusUpdatedAt: new Date(mtimeMs).toISOString(),
    waitingKind: null,
  };
}

export function toThread(
  record: SessionRecord,
  turns: Turn[] = [],
  live: LiveState = { canAcceptDirectInput: true },
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
    modelProvider: "google",
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
    source: record.origin === "other" ? { custom: "other" } : "cli",
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

export interface LiveSource {
  activeTurnId(threadId: string): string | undefined;
  hasLiveProcess(threadId: string): boolean;
  loadedThreadIds(): string[];
}

export function createThreadHandlers(catalog: AgyCatalog, history: AgyHistoryStore, liveSource?: LiveSource) {
  const liveStateOf = async (threadId: string): Promise<{ live: LiveState; holderActive: boolean }> => {
    if (liveSource?.activeTurnId(threadId) !== undefined) {
      return {
        live: { canAcceptDirectInput: true, status: { type: "active", activeFlags: [] } },
        holderActive: false,
      };
    }
    const ext = await catalog.externalActivity(threadId);
    if (ext?.externallyBusy) {
      return {
        live: {
          canAcceptDirectInput: false,
          status: { type: "active", activeFlags: [] },
          claudeOwner: desktopOwnerSummary(ext.mtimeMs),
        },
        holderActive: true,
      };
    }
    if (liveSource?.hasLiveProcess(threadId)) {
      return {
        live: { canAcceptDirectInput: true, status: { type: "idle" } },
        holderActive: false,
      };
    }
    return {
      live: { canAcceptDirectInput: true, status: { type: "notLoaded" } },
      holderActive: false,
    };
  };

  return {
    async list(raw: unknown): Promise<ThreadListResponse> {
      const params = asParams(raw);
      const limit = readLimit(params.limit, 25, 200);
      const direction: Direction = readDirection(params.sortDirection, "desc");
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

      const data = await Promise.all(
        page.map(async (record) => {
          const { live } = await liveStateOf(record.id);
          return toThread(record, [], live);
        }),
      );

      return {
        data,
        nextCursor: hasMore && last ? encodeCursor({ v: key(last)[0], id: last.id }) : null,
        backwardsCursor: first ? encodeCursor({ v: key(first)[0], id: first.id, incl: true }) : null,
      };
    },

    async read(raw: unknown): Promise<{ thread: AdapterThread }> {
      const params = asParams(raw);
      const threadId = params.threadId;
      if (typeof threadId !== "string" || !threadId) {
        throw RpcError.invalidParams("thread/read.threadId 不能为空");
      }
      const record = await catalog.get(threadId);
      if (!record) {
        throw RpcError.invalidParams(`找不到 Antigravity 会话 ${threadId}`);
      }
      const running = liveSource?.activeTurnId(threadId) !== undefined;
      const { live, holderActive } = await liveStateOf(threadId);
      const turns = params.includeTurns === true ? await history.turns(threadId, running, holderActive) : [];
      return { thread: toThread(record, turns, live) };
    },

    loaded(): ThreadLoadedListResponse {
      return { data: liveSource?.loadedThreadIds() ?? [], nextCursor: null };
    },
  };
}
