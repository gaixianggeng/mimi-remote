import { expect, test } from "bun:test";
import type { SessionHolder } from "../src/runtime/holders.ts";
import { OwnershipWatcher } from "../src/runtime/ownership.ts";

test("ownership broadcasts a new run timestamp without replaying identical snapshots", async () => {
  let holder: SessionHolder | undefined = {
    pid: 4242,
    entrypoint: "cli",
    kind: "interactive",
    status: "busy",
    version: "2",
    startedAt: 100,
    statusUpdatedAt: 1_000,
  };
  const observed: Array<SessionHolder | undefined> = [];
  const watcher = new OwnershipWatcher({
    dir: "unused",
    tracked: () => [],
    read: async () => new Map(holder ? [["thread", holder]] : []),
    onChange: (_, current) => { observed.push(current); },
    log: () => {},
  });

  await watcher.scanNow();
  await watcher.scanNow();
  expect(observed).toHaveLength(1);

  // 两次扫描间完成 idle → busy，原始状态相同但已经是新一轮。
  holder = { ...holder, statusUpdatedAt: 2_000 };
  await watcher.scanNow();
  expect(observed.map((item) => item?.statusUpdatedAt)).toEqual([1_000, 2_000]);

  holder = { ...holder, status: "shell" };
  await watcher.scanNow();
  expect(observed.at(-1)?.status).toBe("shell");

  holder = { ...holder, entrypoint: "claude-desktop" };
  await watcher.scanNow();
  expect(observed.at(-1)?.entrypoint).toBe("claude-desktop");

  holder = undefined;
  await watcher.scanNow();
  await watcher.scanNow();
  expect(observed).toHaveLength(5);
  expect(observed.at(-1)).toBeUndefined();
});
