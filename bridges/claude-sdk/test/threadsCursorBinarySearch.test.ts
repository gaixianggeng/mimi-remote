import { describe, expect, test } from "bun:test";
import type { Catalog, HistoryStore, SessionRecord } from "../src/claude/catalog.ts";
import { createThreadHandlers, findCursorStartIndex } from "../src/handlers/threads.ts";
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
      { v: 100, id: "bb" },
      { v: 100, id: "bb", incl: true },
      { v: 125, id: "m" },
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

  test("performs O(log N) key evaluations without scanning all records", () => {
    const records = Array.from({ length: 240 }, (_, i) =>
      makeRecord(`s-${String(i).padStart(3, "0")}`, 1000 + i, 2000 + i),
    ).reverse();
    let reads = 0;
    const key = (r: SessionRecord): [number, string] => {
      reads += 1;
      return [r.updatedAt, r.id];
    };
    const anchor = records[19]!;
    const idx = findCursorStartIndex(records, key, -1, { v: anchor.updatedAt, id: anchor.id }, true);
    expect(idx).toBe(20);
    // ceil(log2(240)) === 8; must stay strictly O(log N), never O(N)
    expect(reads).toBeLessThanOrEqual(10);
  });

  test("preserves full pagination traversal, deleted anchor continuation, and backwardsCursor incl", async () => {
    const base = Array.from({ length: 25 }, (_, i) =>
      makeRecord(`s-${String(i).padStart(2, "0")}`, 1000 + Math.floor(i / 3), 2000 + Math.floor((24 - i) / 4)),
    );

    for (const sortKey of ["created_at", "updated_at"] as const) {
      for (const sortDirection of ["asc", "desc"] as const) {
        const mutable = [...base];
        const handlers = makeHandlers(mutable);
        const seen: string[] = [];
        let cursor: string | null = null;
        while (true) {
          const page = await handlers.list({ sortKey, sortDirection, limit: 4, cursor });
          seen.push(...page.data.map((t) => t.id));
          if (!page.nextCursor) break;
          cursor = page.nextCursor;
        }
        expect(seen.length).toBe(base.length);
        expect(new Set(seen).size).toBe(base.length);

        const page1 = await handlers.list({ sortKey, sortDirection, limit: 4 });
        const page2BeforeDelete = await handlers.list({ sortKey, sortDirection, limit: 4, cursor: page1.nextCursor });
        const backFromPage2 = await handlers.list({
          sortKey,
          sortDirection,
          limit: 4,
          cursor: page2BeforeDelete.backwardsCursor,
        });
        expect(backFromPage2.data.map((t) => t.id)).toEqual(page2BeforeDelete.data.map((t) => t.id));

        // Delete the anchor record (last item of page1) after obtaining nextCursor
        const deletedAnchorId = page1.data[page1.data.length - 1]!.id;
        const removeIdx = mutable.findIndex((r) => r.id === deletedAnchorId);
        expect(removeIdx).toBeGreaterThanOrEqual(0);
        mutable.splice(removeIdx, 1);

        const page2AfterDelete = await handlers.list({ sortKey, sortDirection, limit: 4, cursor: page1.nextCursor });
        expect(page2AfterDelete.data.map((t) => t.id)).toEqual(page2BeforeDelete.data.map((t) => t.id));
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
      { v: 2, id: "a", incl: 1 }, // finite v + string id -> takes binary path and preserves truthiness
      { v: 2, id: "a", incl: 0 },
      { v: "2", id: "a" },
      { v: 2, id: 123 },
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

    // Non-finite record timestamp: ascending created_at with { v: 21, id: "0", incl: true }
    // produces a non-monotonic predicate [true, false, false] that fails if binary search runs without finiteness guard.
    const nonFiniteRecords: SessionRecord[] = [
      makeRecord("a", Number.NaN, 10),
      makeRecord("b", 10, Number.POSITIVE_INFINITY),
      makeRecord("c", 20, 20),
    ];
    const nonFiniteHandlers = makeHandlers(nonFiniteRecords);
    const nonFiniteCursors: Record<string, unknown>[] = [
      { v: 21, id: "0", incl: true },
      { v: 10, id: "b", incl: true },
    ];
    for (const sortKey of ["created_at", "updated_at"] as const) {
      for (const sortDirection of ["asc", "desc"] as const) {
        for (const cursorObj of nonFiniteCursors) {
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
    }
  });
});
