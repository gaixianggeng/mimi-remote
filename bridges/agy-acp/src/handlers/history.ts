import type { ThreadItemEntry } from "@mimi/appserver-kit/protocol/codex/v2/ThreadItemEntry.ts";
import type { ThreadItemsListResponse } from "@mimi/appserver-kit/protocol/codex/v2/ThreadItemsListResponse.ts";
import type { ThreadTurnsListResponse } from "@mimi/appserver-kit/protocol/codex/v2/ThreadTurnsListResponse.ts";
import type { Turn } from "@mimi/appserver-kit/protocol/codex/v2/Turn.ts";
import { RpcError } from "@mimi/appserver-kit/rpc/frames.ts";
import { decodeCursor, encodeCursor, readDirection, readLimit } from "@mimi/appserver-kit/util/cursor.ts";
import type { AgyHistoryStore } from "../agy/catalog.ts";
import { summarizeTurn } from "../agy/history.ts";

type Params = Record<string, unknown>;

function threadIdOf(raw: unknown, method: string): { params: Params; threadId: string } {
  const params = raw && typeof raw === "object" ? (raw as Params) : {};
  const threadId = params.threadId;
  if (typeof threadId !== "string" || !threadId) {
    throw RpcError.invalidParams(`${method}.threadId 不能为空`);
  }
  return { params, threadId };
}

interface PositionCursor extends Record<string, unknown> {
  id: string;
  pos?: number;
  incl?: boolean;
}

function startAfter<T>(ordered: readonly T[], idOf: (entry: T) => string, cursor: PositionCursor | undefined): number {
  if (!cursor) return 0;
  const pos = cursor.pos;
  const atPosition = typeof pos === "number" && Number.isInteger(pos) && pos >= 0 && pos < ordered.length;
  const index = atPosition && idOf(ordered[pos]!) === cursor.id ? pos : ordered.findIndex((entry) => idOf(entry) === cursor.id);
  if (index < 0) throw RpcError.invalidParams("分页游标已失效");
  return cursor.incl ? index : index + 1;
}

function viewOf(turn: Turn, view: unknown): Turn {
  if (view === "full") return turn;
  if (view === "notLoaded") return { ...turn, items: [], itemsView: "notLoaded" };
  return summarizeTurn(turn);
}

export function createHistoryHandlers(history: AgyHistoryStore, isRunning: (threadId: string) => boolean = () => false) {
  const turnsOf = (threadId: string) => history.turns(threadId, isRunning(threadId));

  return {
    async turns(raw: unknown): Promise<ThreadTurnsListResponse> {
      const { params, threadId } = threadIdOf(raw, "thread/turns/list");
      const limit = readLimit(params.limit, 10, 100);
      const direction = readDirection(params.sortDirection, "desc");
      const cursor = decodeCursor<PositionCursor>(params.cursor, "thread/turns/list.cursor");
      const all = await turnsOf(threadId);
      const ordered = direction === "desc" ? [...all].reverse() : all;
      const start = startAfter(ordered, (turn) => turn.id, cursor);
      const page = ordered.slice(start, start + limit);
      const last = page[page.length - 1];
      const first = page[0];
      return {
        data: page.map((turn) => viewOf(turn, params.itemsView)),
        nextCursor: last && start + limit < ordered.length ? encodeCursor({ id: last.id, pos: start + page.length - 1 }) : null,
        backwardsCursor: first ? encodeCursor({ id: first.id, pos: ordered.length - 1 - start, incl: true }) : null,
      };
    },

    async items(raw: unknown): Promise<ThreadItemsListResponse> {
      const { params, threadId } = threadIdOf(raw, "thread/items/list");
      const limit = readLimit(params.limit, 50, 200);
      const direction = readDirection(params.sortDirection, "asc");
      const turnId = typeof params.turnId === "string" && params.turnId ? params.turnId : undefined;
      const all = await turnsOf(threadId);
      const turns = turnId ? all.filter((turn) => turn.id === turnId) : all;
      if (turnId && turns.length === 0) throw RpcError.invalidParams(`找不到 turn ${turnId}`);
      const entries: ThreadItemEntry[] = turns.flatMap((turn) =>
        turn.items.map((item) => ({ turnId: turn.id, item, startedAtMs: null, completedAtMs: null })),
      );
      const ordered = direction === "desc" ? [...entries].reverse() : entries;

      let cursor: PositionCursor | undefined;
      const rawCursor = params.cursor;
      if (rawCursor && typeof rawCursor === "object") {
        const anchor = rawCursor as { type?: unknown; itemId?: unknown };
        if (anchor.type !== "item" || typeof anchor.itemId !== "string") throw RpcError.invalidParams("cursor 锚点无效");
        if (!turnId) throw RpcError.invalidParams("按 item 锚点翻页时必须指定 turnId");
        cursor = { id: anchor.itemId };
      } else {
        cursor = decodeCursor<PositionCursor>(rawCursor, "thread/items/list.cursor");
      }
      const start = startAfter(ordered, (entry) => entry.item.id, cursor);
      const page = ordered.slice(start, start + limit);
      const last = page[page.length - 1];
      const first = page[0];
      return {
        data: page,
        nextCursor: last && start + limit < ordered.length ? encodeCursor({ id: last.item.id, pos: start + page.length - 1 }) : null,
        backwardsCursor: first ? encodeCursor({ id: first.item.id, pos: ordered.length - 1 - start, incl: true }) : null,
      };
    },
  };
}
