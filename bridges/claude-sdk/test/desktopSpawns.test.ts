// Claude 桌面版派生关系的读取：只认能解析出父会话的记录，文件变化后重新读取。
import { afterAll, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { DesktopSpawnIndex } from "../src/claude/desktopSpawns.ts";

const root = mkdtempSync(path.join(os.tmpdir(), "mimi-desktop-spawns-"));
const org = path.join(root, "account", "org");
mkdirSync(org, { recursive: true });

function meta(local: string, cli: string, extra: Record<string, unknown> = {}) {
  writeFileSync(path.join(org, `local_${local}.json`), JSON.stringify({ sessionId: `local_${local}`, cliSessionId: cli, ...extra }));
}

afterAll(() => rmSync(root, { recursive: true, force: true }));

describe("DesktopSpawnIndex", () => {
  test("maps a spawned session to its parent's Claude Code session id", async () => {
    meta("parent", "cli-parent");
    meta("child", "cli-child", { spawnedFrom: { sessionId: "local_parent", taskId: "task_1" } });
    meta("self", "cli-self", { spawnedFrom: { sessionId: "local_self" } });
    meta("orphan", "cli-orphan", { spawnedFrom: { sessionId: "local_gone" } });
    writeFileSync(path.join(org, "local_broken.json"), "{");
    writeFileSync(path.join(org, "notes.json"), JSON.stringify({ sessionId: "local_x", cliSessionId: "cli-x" }));

    const index = new DesktopSpawnIndex(() => root, 0);
    await index.refresh();
    expect(index.parentOf("cli-child")).toBe("cli-parent");
    expect(index.parentOf("cli-parent")).toBeUndefined();
    expect(index.parentOf("cli-self")).toBeUndefined();
    expect(index.parentOf("cli-orphan")).toBeUndefined();
  });

  test("rereads changed files and forgets deleted ones", async () => {
    const index = new DesktopSpawnIndex(() => root, 0);
    await index.refresh();
    expect(index.parentOf("cli-orphan")).toBeUndefined();

    meta("gone", "cli-gone");
    await index.refresh(true);
    expect(index.parentOf("cli-orphan")).toBe("cli-gone");

    rmSync(path.join(org, "local_gone.json"));
    await index.refresh(true);
    expect(index.parentOf("cli-orphan")).toBeUndefined();
  });

  test("a missing directory means no spawned sessions", async () => {
    const index = new DesktopSpawnIndex(() => path.join(root, "missing"), 0);
    await index.refresh();
    expect(index.parentOf("cli-child")).toBeUndefined();
    const disabled = new DesktopSpawnIndex(() => undefined, 0);
    await disabled.refresh();
    expect(disabled.parentOf("cli-child")).toBeUndefined();
  });
});
