import { expect, test } from "bun:test";
import type { SessionHolder } from "../src/runtime/holders.ts";
import { OwnershipWatcher } from "../src/runtime/ownership.ts";

test("ownership broadcasts public waiting changes without replaying identical snapshots", async () => {
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

  holder = { ...holder, status: "waiting", waitingFor: "permission prompt", statusUpdatedAt: 2_000 };
  await watcher.scanNow();
  await watcher.scanNow();
  expect(observed).toHaveLength(2);

  // waiting 状态不变时，公开类别变化也必须推送。
  holder = { ...holder, waitingFor: "input needed" };
  await watcher.scanNow();
  expect(observed).toHaveLength(3);

  // 两次扫描间开始了新的等待轮次，状态与类别相同但时间戳代表新一轮。
  holder = { ...holder, statusUpdatedAt: 3_000 };
  await watcher.scanNow();
  expect(observed.map((item) => item?.statusUpdatedAt)).toEqual([1_000, 2_000, 2_000, 3_000]);

  holder = { ...holder, status: "shell" };
  await watcher.scanNow();
  expect(observed.at(-1)?.status).toBe("shell");

  holder = { ...holder, entrypoint: "claude-desktop" };
  await watcher.scanNow();
  expect(observed.at(-1)?.entrypoint).toBe("claude-desktop");

  holder = undefined;
  await watcher.scanNow();
  await watcher.scanNow();
  expect(observed).toHaveLength(7);
  expect(observed.at(-1)).toBeUndefined();
});
