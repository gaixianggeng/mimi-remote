import { afterAll, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { TranscriptIndex } from "../src/claude/transcripts.ts";
import { nextFreshnessMark } from "../src/util/freshness.ts";
import type { SessionHolder } from "../src/runtime/holders.ts";
import { OwnershipWatcher } from "../src/runtime/ownership.ts";

// #912：同一轮持有方扫描里的多个变化共用一次 transcript 索引扫描，且仍包含扫描开始后写下的内容。
const root = realpathSync(mkdtempSync(path.join(os.tmpdir(), "mimi-ownership-activity-")));
afterAll(() => rmSync(root, { recursive: true, force: true }));

function transcriptRoot(name: string, sessions: number) {
  const dir = path.join(root, name);
  mkdirSync(path.join(dir, "project"), { recursive: true });
  for (let n = 0; n < sessions; n += 1) writeFileSync(path.join(dir, "project", `thread-${n}.jsonl`), "{}\n");
  let scans = 0;
  const index = new TranscriptIndex(() => {
    scans += 1;
    return dir;
  });
  return { dir, index, scans: () => scans };
}

const holder = (pid: number): SessionHolder => ({
  pid, entrypoint: "cli", kind: "interactive", status: "busy", version: "2", startedAt: pid, statusUpdatedAt: 1_000,
});

test("a batch of holder changes shares one transcript scan", async () => {
  const t = transcriptRoot("batch", 200);
  let holders = new Map<string, SessionHolder>();
  const seen: string[] = [];
  const watcher = new OwnershipWatcher({
    dir: "unused",
    tracked: () => [],
    read: async () => holders,
    onChange: async (threadId, _, freshSince) => {
      await t.index.refreshSince(freshSince);
      if (t.index.get(threadId)) seen.push(threadId);
    },
    log: () => {},
  });

  holders = new Map(Array.from({ length: 12 }, (_, n) => [`thread-${n}`, holder(1000 + n)]));
  await watcher.scanNow();
  expect(seen).toHaveLength(12);
  expect(t.scans()).toBe(1);

  await watcher.scanNow();
  expect(t.scans()).toBe(1);
});

test("an index scan that began before the holder snapshot is not reused", async () => {
  const t = transcriptRoot("stale", 1);
  const inFlight = t.index.refresh(true);
  const since = nextFreshnessMark();
  writeFileSync(path.join(t.dir, "project", "thread-new.jsonl"), "{}\n");
  await t.index.refreshSince(since);
  await inFlight;

  expect(t.index.get("thread-new")).toBeDefined();
  expect(t.scans()).toBe(2);
  await t.index.refreshSince(since);
  expect(t.scans()).toBe(2);
});

test("a finished scan from the same millisecond as the snapshot is not trusted", async () => {
  const t = transcriptRoot("same-tick", 1);
  const file = path.join(t.dir, "project", "thread-0.jsonl");
  await t.index.refresh(true);
  writeFileSync(file, "{}\n{}\n");
  const since = nextFreshnessMark();
  await t.index.refreshSince(since);

  expect(t.index.get("thread-0")?.size).toBe(6);
  expect(t.scans()).toBe(2);
});
