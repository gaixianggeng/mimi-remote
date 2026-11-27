import { expect, test } from "bun:test";
import { PassThrough } from "node:stream";
import { SharedReadonlyAcp } from "../src/agy/binary.ts";
import { FakeAgyWorld } from "./support/fake-agy.ts";

function gate() {
  let open!: () => void;
  const wait = new Promise<void>((resolve) => { open = resolve; });
  return { open, wait };
}

test("a list deadline releases its cold-start waiter while a turn still needs the same startup", async () => {
  const world = new FakeAgyWorld();
  const initialized = gate();
  const shared = new SharedReadonlyAcp(() => "fake-agy", (opts) => {
    const inner = world.spawnTransport(opts);
    const stdin = new PassThrough();
    initialized.wait.then(() => stdin.pipe(inner.stdin));
    return { ...inner, stdin };
  });
  const controller = new AbortController();
  try {
    const list = shared.use((client) => client.sessionList(100, controller.signal), { signal: controller.signal });
    const turnClient = shared.acquire();
    controller.abort();
    await expect(list).rejects.toThrow("aborted");
    initialized.open();
    const client = await turnClient;
    expect(await client.sessionList()).toEqual([]);
    expect(world.spawns).toHaveLength(1);
  } finally {
    initialized.open();
    await shared.close();
  }
});

test("an idle stalled list releases the process before another writer can open the directory", async () => {
  const listStarted = gate();
  const closing = gate();
  const exited = gate();
  const world = new FakeAgyWorld({
    beforeListReply: async () => {
      if (world.spawns.length === 1) {
        listStarted.open();
        await new Promise<void>(() => {});
      }
    },
  });
  const shared = new SharedReadonlyAcp(() => "fake-agy", (opts) => {
    const inner = world.spawnTransport(opts);
    if (world.spawns.length > 1) return inner;
    return {
      ...inner,
      async close() {
        closing.open();
        await exited.wait;
        await inner.close();
      },
    };
  });
  const controller = new AbortController();
  try {
    const first = await shared.acquire();
    const list = shared.use((client) => client.sessionList(15_000, controller.signal), { signal: controller.signal });
    await listStarted.wait;
    controller.abort();
    await closing.wait;
    const next = shared.acquire();
    expect(world.spawns).toHaveLength(1);
    exited.open();
    await expect(list).rejects.toThrow("aborted");
    const second = await next;
    expect(first.isClosed).toBe(true);
    expect(await second.sessionList()).toEqual([]);
    expect(world.spawns).toHaveLength(2);
  } finally {
    exited.open();
    await shared.close();
  }
});
