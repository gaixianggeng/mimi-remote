// #912: exercise createApp's real readActivity wiring, including the status notification.
// All transcripts and holder snapshots are synthetic; no real Claude process is started.
import { expect, spyOn, test } from "bun:test";
import { appendFileSync, mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { TranscriptIndex } from "../src/claude/transcripts.ts";
import type { OutboundFrame } from "../src/rpc/frames.ts";
import type { SessionHolder } from "../src/runtime/holders.ts";

test("application batches ownership scans and publishes fresh short-turn activity", async () => {
  const root = realpathSync(mkdtempSync(path.join(os.tmpdir(), "mimi-ownership-app-")));
  const previousConfig = process.env.CLAUDE_CONFIG_DIR;
  const previousLegacy = process.env.MIMI_CLAUDE_LEGACY_INDEX;
  process.env.CLAUDE_CONFIG_DIR = root;
  process.env.MIMI_CLAUDE_LEGACY_INDEX = "";
  const now = 1_800_000_000_000;
  const time = spyOn(Date, "now").mockReturnValue(now);
  const scans = spyOn(TranscriptIndex.prototype as unknown as { scan(mark: number): Promise<void> }, "scan");
  const dir = path.join(root, "projects", "synthetic");
  mkdirSync(dir, { recursive: true });
  const record = (offset: number) => JSON.stringify({
    type: "assistant", timestamp: new Date(now + offset).toISOString(), message: { content: "synthetic reply" },
  }) + "\n";
  const files = Array.from({ length: 10 }, (_, n) => path.join(dir, `thread-${n}.jsonl`));
  for (const file of files) writeFileSync(file, record(0));
  let holders = new Map<string, SessionHolder>(files.map((_, n) => [`thread-${n}`, {
    pid: 1000 + n, entrypoint: "cli", kind: "interactive", status: "busy", version: "2",
    startedAt: now, statusUpdatedAt: now,
  }]));
  const frames: OutboundFrame[] = [];
  const errors: string[] = [];
  const { createApp } = await import("../src/app.ts");
  const app = createApp({ stateDir: path.join(root, "state"), log: m => errors.push(m), broadcast: f => frames.push(f) });
  // Replace OS discovery only. Keep the real watcher -> manager -> readActivity -> notification path.
  app.manager.holders = async () => holders;
  const watcher = (app.manager as unknown as { ownership: { scanNow(): Promise<void> } }).ownership;
  try {
    await watcher.scanNow();
    expect(scans).toHaveBeenCalledTimes(1);
    expect(frames).toHaveLength(10);
    expect(frames.every(f => f.method === "thread/status/changed"
      && (f.params as { updatedAt: number }).updatedAt === now / 1000)).toBe(true);

    frames.length = 0;
    await watcher.scanNow();
    expect(scans).toHaveBeenCalledTimes(1);
    expect(frames).toHaveLength(0);

    // Keep Date.now fixed: the finish and fresh transcript must not reuse the one-second cache.
    for (const file of files) appendFileSync(file, record(2000));
    holders = new Map([...holders].map(([id, holder]) => [id, { ...holder, status: "idle" }]));
    await watcher.scanNow();
    expect(scans).toHaveBeenCalledTimes(2);
    expect(frames).toHaveLength(10);
    expect(frames.every(f => (f.params as { updatedAt: number }).updatedAt === now / 1000 + 2)).toBe(true);

    frames.length = 0;
    holders = new Map();
    await watcher.scanNow();
    expect(scans).toHaveBeenCalledTimes(3);
    expect(frames).toHaveLength(10);
    expect(frames.every(f => {
      const params = f.params as { claudeOwner: unknown; canAcceptDirectInput: boolean };
      return params.claudeOwner === null && params.canAcceptDirectInput;
    })).toBe(true);
    expect(errors).toEqual([]);
  } finally {
    await app.manager.closeAll();
    scans.mockRestore();
    time.mockRestore();
    if (previousConfig === undefined) delete process.env.CLAUDE_CONFIG_DIR;
    else process.env.CLAUDE_CONFIG_DIR = previousConfig;
    if (previousLegacy === undefined) delete process.env.MIMI_CLAUDE_LEGACY_INDEX;
    else process.env.MIMI_CLAUDE_LEGACY_INDEX = previousLegacy;
    rmSync(root, { recursive: true, force: true });
  }
});
