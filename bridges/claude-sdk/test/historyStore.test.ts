import { describe, expect, test } from "bun:test";
import { HistoryStore } from "../src/claude/catalog.ts";

// #913：同一会话、同一文件版本与状态的并发冷读取只读一次 transcript。
function harness() {
  let size = 100;
  let reads = 0;
  const gates: Array<{ open(): void; fail(error: Error): void }> = [];
  const store = new HistoryStore({
    sessions: {
      messages: () => {
        reads += 1;
        return new Promise((resolve, reject) => {
          gates.push({ open: () => resolve([]), fail: reject });
        });
      },
    } as never,
    transcripts: { refresh: async () => {}, get: () => ({ size }) } as never,
    overlay: { load: async () => {}, isTaskProposal: () => false } as never,
  });
  return {
    store,
    gates,
    reads: () => reads,
    grow(next: number) {
      size = next;
    },
  };
}

const settle = () => new Promise<void>((resolve) => setImmediate(resolve));

describe("HistoryStore", () => {
  test("concurrent cold reads of the same version share one SDK read", async () => {
    const h = harness();
    const calls = Array.from({ length: 8 }, () => h.store.turns("thread-a"));
    await settle();
    expect(h.reads()).toBe(1);
    h.gates[0]!.open();
    const results = await Promise.all(calls);
    expect(new Set(results).size).toBe(1);

    await h.store.turns("thread-a");
    expect(h.reads()).toBe(1);
  });

  test("a different state or a grown file reads again", async () => {
    const h = harness();
    const idle = h.store.turns("thread-a");
    const running = h.store.turns("thread-a", true);
    await settle();
    expect(h.reads()).toBe(2);
    for (const gate of h.gates) gate.open();
    await Promise.all([idle, running]);

    h.grow(200);
    const grown = h.store.turns("thread-a", true);
    await settle();
    expect(h.reads()).toBe(3);
    h.gates[2]!.open();
    await grown;
  });

  test("a failed read is not shared with later requests", async () => {
    const h = harness();
    const first = h.store.turns("thread-a");
    await settle();
    h.gates[0]!.fail(new Error("boom"));
    await expect(first).rejects.toThrow("boom");

    const retry = h.store.turns("thread-a");
    await settle();
    expect(h.reads()).toBe(2);
    h.gates[1]!.open();
    await retry;
  });

  test("an older version finishing last does not replace the newer cache", async () => {
    const h = harness();
    const older = h.store.turns("thread-a");
    await settle();
    h.grow(200);
    const newer = h.store.turns("thread-a");
    await settle();
    expect(h.reads()).toBe(2);
    h.gates[1]!.open();
    await newer;
    h.gates[0]!.open();
    await older;

    await h.store.turns("thread-a");
    expect(h.reads()).toBe(2);
  });
});
