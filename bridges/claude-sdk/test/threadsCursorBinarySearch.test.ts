import { describe, expect, test } from "bun:test";
import type { Catalog, HistoryStore, SessionRecord } from "../src/claude/catalog.ts";
import { createThreadHandlers } from "../src/handlers/threads.ts";
import { encodeCursor } from "../src/util/cursor.ts";

function makeRecord(id: string, createdAt: number, updatedAt: number): SessionRecord {
  return {
    id,
    cwd: "/Users/demo/project",
    name: `Title ${id}`,
    preview: `Preview ${id}`,
    createdAt,
    updatedAt,
    gitBranch: "main",
    path: `/Users/demo/.claude/projects/demo/${id}.jsonl`,
    archived: false,
    spawnedFromId: null,
  };
}

function linearCompare(a: [number, string], b: [number, string]): number {
  return a[0] - b[0] || (a[1] < b[1] ? -1 : a[1] > b[1] ? 1 : 0);
}

function linearExpectedIds(
  input: readonly SessionRecord[],
  sortKey: "created_at" | "updated_at",
  sortDirection: "asc" | "desc",
  cursorObj: Record<string, unknown>,
  limit: number,
): string[] {
  const byCreated = sortKey === "created_at";
  const sign = sortDirection === "desc" ? -1 : 1;
  const key = (r: SessionRecord): [number, string] => [byCreated ? r.createdAt : r.updatedAt, r.id];
  const sorted = [...input].sort((a, b) => sign * linearCompare(key(a), key(b)));
  const start = sorted.findIndex((record) => {
    const order = sign * linearCompare(key(record), [cursorObj.v as number, cursorObj.id as string]);
    return cursorObj.incl ? order >= 0 : order > 0;
  });
  return (start < 0 ? [] : sorted.slice(start, start + limit)).map((r) => r.id);
}

function makeHandlers(records: SessionRecord[]) {
  const catalog = {
    list: async () => records,
    get: async (id: string) => records.find((r) => r.id === id),
  } as unknown as Catalog;
  const history = {
    turns: async () => [],
  } as unknown as HistoryStore;
  return createThreadHandlers(catalog, history);
}

describe("thread/list binary search cursor parity", () => {
  test("matches linear scan across sortKey, direction, incl, ties, and missing anchors", async () => {
    const records: SessionRecord[] = [
      makeRecord("a", 100, 300),
      makeRecord("b", 100, 200),
      makeRecord("c", 100, 200),
      makeRecord("d", 150, 200),
      makeRecord("e", 200, 100),
      makeRecord("f", 200, 400),
      makeRecord("g", 300, 200),
    ];
    const handlers = makeHandlers(records);

    const cursors: Record<string, unknown>[] = [
      { v: 50, id: "0" },
      { v: 100, id: "a" },
      { v: 100, id: "a", incl: true },
      { v: 100, id: "b", incl: false },
      { v: 100, id: "b", incl: true },
      { v: 100, id: "bb" }, // deleted anchor between ties
      { v: 100, id: "bb", incl: true },
      { v: 125, id: "m" }, // deleted anchor between timestamps
      { v: 200, id: "e" },
      { v: 200, id: "e", incl: true },
      { v: 300, id: "g" },
      { v: 300, id: "g", incl: true },
      { v: 999, id: "z" },
      { v: 999, id: "z", incl: true },
    ];

    for (const sortKey of ["created_at", "updated_at"] as const) {
      for (const sortDirection of ["asc", "desc"] as const) {
        for (const cursorObj of cursors) {
          const expected = linearExpectedIds(records, sortKey, sortDirection, cursorObj, 3);
          const actual = await handlers.list({
            sortKey,
            sortDirection,
            limit: 3,
            cursor: encodeCursor(cursorObj),
          });
          expect(actual.data.map((t) => t.id)).toEqual(expected);
        }
      }
    }
  });

  test("preserves full pagination traversal with deleted anchor and backwardsCursor incl", async () => {
    const mutable = Array.from({ length: 25 }, (_, i) =>
      makeRecord(`s-${String(i).padStart(2, "0")}`, 1000 + Math.floor(i / 3), 2000 + Math.floor((24 - i) / 4)),
    );
    const handlers = makeHandlers(mutable);

    for (const sortKey of ["created_at", "updated_at"] as const) {
      for (const sortDirection of ["asc", "desc"] as const) {
        const seen: string[] = [];
        let cursor: string | null = null;
        while (true) {
          const page = await handlers.list({ sortKey, sortDirection, limit: 4, cursor });
          seen.push(...page.data.map((t) => t.id));
          if (!page.nextCursor) break;
          cursor = page.nextCursor;
        }
        expect(seen.length).toBe(mutable.length);
        expect(new Set(seen).size).toBe(mutable.length);

        const page1 = await handlers.list({ sortKey, sortDirection, limit: 4 });
        const page2 = await handlers.list({ sortKey, sortDirection, limit: 4, cursor: page1.nextCursor });
        const backFromPage2 = await handlers.list({
          sortKey,
          sortDirection,
          limit: 4,
          cursor: page2.backwardsCursor,
        });
        expect(backFromPage2.data.map((t) => t.id)).toEqual(page2.data.map((t) => t.id));
      }
    }
  });

  test("falls back to linear parity for non-monotonic malformed cursors and non-finite timestamps", async () => {
    const records: SessionRecord[] = [
      makeRecord("z", 1, 1),
      makeRecord("a", 2, 2),
      makeRecord("b", 3, 3),
    ];
    const handlers = makeHandlers(records);

    const weirdCursors: Record<string, unknown>[] = [
      { id: "m" }, // missing v -> non-monotonic predicate on asc [(1,"z"), (2,"a"), (3,"b")]
      { id: "m", incl: true },
      { v: 2, id: "a", incl: 1 }, // truthy non-boolean incl
      { v: 2, id: "a", incl: 0 }, // falsy non-boolean incl
      { v: "2", id: "a" }, // non-number v
      { v: 2, id: 123 }, // non-string id
      { v: null, id: "a" },
      {},
    ];

    for (const sortKey of ["created_at", "updated_at"] as const) {
      for (const sortDirection of ["asc", "desc"] as const) {
        for (const cursorObj of weirdCursors) {
          const expected = linearExpectedIds(records, sortKey, sortDirection, cursorObj, 10);
          const actual = await handlers.list({
            sortKey,
            sortDirection,
            limit: 10,
            cursor: encodeCursor(cursorObj),
          });
          expect(actual.data.map((t) => t.id)).toEqual(expected);
        }
      }
    }

    // Empty and single-element arrays
    for (const subset of [[], [makeRecord("only", 10, 20)]]) {
      const subHandlers = makeHandlers(subset);
      for (const cursorObj of [{ v: 10, id: "only" }, { v: 10, id: "only", incl: true }, { id: "m" }]) {
        const expected = linearExpectedIds(subset, "updated_at", "desc", cursorObj, 5);
        const actual = await subHandlers.list({
          sortKey: "updated_at",
          sortDirection: "desc",
          limit: 5,
          cursor: encodeCursor(cursorObj),
        });
        expect(actual.data.map((t) => t.id)).toEqual(expected);
      }
    }

    // Non-finite record timestamp falls back to linear without breaking parity
    const nonFiniteRecords: SessionRecord[] = [
      makeRecord("a", Number.NaN, 10),
      makeRecord("b", 10, Number.POSITIVE_INFINITY),
      makeRecord("c", 20, 20),
    ];
    const nonFiniteHandlers = makeHandlers(nonFiniteRecords);
    for (const sortKey of ["created_at", "updated_at"] as const) {
      for (const sortDirection of ["asc", "desc"] as const) {
        const cursorObj = { v: 10, id: "b", incl: true };
        const expected = linearExpectedIds(nonFiniteRecords, sortKey, sortDirection, cursorObj, 10);
        const actual = await nonFiniteHandlers.list({
          sortKey,
          sortDirection,
          limit: 10,
          cursor: encodeCursor(cursorObj),
        });
        expect(actual.data.map((t) => t.id)).toEqual(expected);
      }
    }
  });
});
