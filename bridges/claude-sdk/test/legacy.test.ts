// 旧 bridge 索引的位置、读取，以及 Mimi 名称迁移（#660）：只补 Claude 侧没有标题或只有 AI 标题的
// 会话，用户手动改过的保留；被占用的会话推迟到下次。迁移走真实 SDK 的 renameSession。
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { spawn, type ChildProcess } from "node:child_process";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, statSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import type { App } from "../src/app.ts";
import { hasCustomTitle, legacyIndexPathFor, readLegacyIndex } from "../src/claude/legacy.ts";
import { TranscriptBuilder } from "./support/transcripts.ts";

const sandbox = realpathSync(mkdtempSync(path.join(os.tmpdir(), "mimi-adapter-legacy-")));
const configDir = path.join(sandbox, "claude");
const project = path.join(sandbox, "project");
const legacyIndex = path.join(sandbox, "legacy", "threads.json");

describe("legacy index", () => {
  test("the path follows the old bridge's config directory on every platform", () => {
    expect(legacyIndexPathFor("darwin", {}, "/Users/a")).toBe("/Users/a/Library/Application Support/codex/claude-bridge/threads.json");
    expect(legacyIndexPathFor("win32", { APPDATA: "C:\\Users\\a\\AppData\\Roaming" }, "C:\\Users\\a")).toBe(
      "C:\\Users\\a\\AppData\\Roaming\\codex\\config\\claude-bridge\\threads.json",
    );
    expect(legacyIndexPathFor("linux", { XDG_CONFIG_HOME: "/x/config" }, "/home/a")).toBe("/x/config/codex/claude-bridge/threads.json");
    // 与 directories 相同：相对路径的 XDG_CONFIG_HOME 不算数。
    expect(legacyIndexPathFor("linux", { XDG_CONFIG_HOME: "relative" }, "/home/a")).toBe("/home/a/.config/codex/claude-bridge/threads.json");
  });

  test("rows without a thread id are skipped; a missing source differs from an unreadable one", async () => {
    const file = path.join(sandbox, "rows.json");
    writeFileSync(file, JSON.stringify({ threads: [{ threadId: "a", name: "  Named  ", archived: true }, { threadId: "b", name: "  " }, { name: "orphan" }, null] }));
    expect(await readLegacyIndex(file)).toEqual({
      status: "ok",
      threads: [
        { threadId: "a", name: "Named", archived: true },
        { threadId: "b", name: null, archived: false },
      ],
    });
    // 没有来源：可以当作迁移完成。
    expect(await readLegacyIndex(path.join(sandbox, "missing.json"))).toEqual({ status: "none" });
    expect(await readLegacyIndex(undefined)).toEqual({ status: "none" });
    // 暂时读不了或格式不对：不能当作完成。
    writeFileSync(file, "{");
    expect(await readLegacyIndex(file)).toEqual({ status: "unreadable" });
    writeFileSync(file, JSON.stringify({ threads: "nope" }));
    expect(await readLegacyIndex(file)).toEqual({ status: "unreadable" });
    expect(await readLegacyIndex(sandbox)).toEqual({ status: "unreadable" });
  });

  test("a custom-title record is found even when it straddles two read chunks", async () => {
    const file = path.join(sandbox, "straddle.jsonl");
    const record = JSON.stringify({ type: "custom-title", customTitle: "x", sessionId: "s" });
    writeFileSync(file, `${"x".repeat(65_536 - 10)}\n${record}\n`);
    expect(await hasCustomTitle(file)).toBe(true);
    writeFileSync(file, `${JSON.stringify({ type: "ai-title", aiTitle: "x", sessionId: "s" })}\n`);
    expect(await hasCustomTitle(file)).toBe(false);
  });
});

describe("name migration", () => {
  const ids = {
    untitled: "11111111-1111-4111-8111-111111111111",
    aiTitled: "22222222-2222-4222-8222-222222222222",
    renamedByUser: "33333333-3333-4333-8333-333333333333",
    alreadySame: "44444444-4444-4444-8444-444444444444",
    held: "55555555-5555-4555-8555-555555555555",
    gone: "66666666-6666-4666-8666-666666666666",
  };
  const files: Record<string, string> = {};
  let app: App;
  let holder: ChildProcess;
  const holderFile = () => path.join(configDir, "sessions", `${holder.pid}.json`);

  beforeAll(async () => {
    mkdirSync(path.join(configDir, "sessions"), { recursive: true });
    for (const [label, id] of Object.entries(ids)) {
      if (label === "gone") continue;
      const session = new TranscriptBuilder(id, project);
      session.user(`question for ${label}`);
      if (label === "aiTitled") session.aiTitle("Claude's guess");
      if (label === "renamedByUser") session.title("Named in the CLI");
      if (label === "alreadySame") session.aiTitle("Same everywhere");
      files[label] = session.write(configDir);
    }
    mkdirSync(path.dirname(legacyIndex), { recursive: true });
    writeFileSync(
      legacyIndex,
      JSON.stringify({
        threads: [
          { threadId: ids.untitled, name: "Mimi untitled" },
          { threadId: ids.aiTitled, name: "Mimi over AI" },
          { threadId: ids.renamedByUser, name: "Mimi loses" },
          { threadId: ids.alreadySame, name: "Same everywhere" },
          { threadId: ids.held, name: "Mimi later" },
          { threadId: ids.gone, name: "Nobody" },
        ],
      }),
    );
    holder = spawn("sleep", ["60"], { stdio: "ignore" });
    writeFileSync(holderFile(), JSON.stringify({ pid: holder.pid, sessionId: ids.held, cwd: project, entrypoint: "cli", kind: "interactive", status: "idle", startedAt: Date.now() }));
    process.env.CLAUDE_CONFIG_DIR = configDir;
    process.env.MIMI_CLAUDE_LEGACY_INDEX = legacyIndex;
    const { createApp } = await import("../src/app.ts");
    app = createApp({ stateDir: path.join(sandbox, "state"), log: () => {}, claudeExecutable: () => "unused" });
  });

  afterAll(async () => {
    holder?.kill();
    await app?.manager.closeAll();
    delete process.env.CLAUDE_CONFIG_DIR;
    delete process.env.MIMI_CLAUDE_LEGACY_INDEX;
    rmSync(sandbox, { recursive: true, force: true });
  });

  async function titleOf(sessionId: string): Promise<string | undefined> {
    const { getSessionInfo } = await import("@anthropic-ai/claude-agent-sdk");
    return (await getSessionInfo(sessionId))?.customTitle;
  }

  test("Mimi names fill missing and AI titles, never a user's own rename, and wait for held sessions", async () => {
    const sameSize = statSync(files.alreadySame!).size;
    await app.migrateLegacyNames();
    expect(await titleOf(ids.untitled)).toBe("Mimi untitled");
    expect(await titleOf(ids.aiTitled)).toBe("Mimi over AI");
    expect(await titleOf(ids.renamedByUser)).toBe("Named in the CLI");
    expect(statSync(files.alreadySame!).size).toBe(sameSize);
    // 被终端占用：这次不写，也不记完成。
    expect(await titleOf(ids.held)).toBeUndefined();
    const overlay = JSON.parse(await Bun.file(path.join(sandbox, "state", "overlay.json")).text());
    expect(overlay.legacyNamesMigratedAt).toBeUndefined();

    // 终端退出后再启动：补上被推迟的会话，记完成；已写过的不重复写。
    holder.kill();
    rmSync(holderFile(), { force: true });
    await Bun.sleep(100);
    const untitledSize = statSync(files.untitled!).size;
    await app.migrateLegacyNames();
    expect(await titleOf(ids.held)).toBe("Mimi later");
    expect(statSync(files.untitled!).size).toBe(untitledSize);
    const done = JSON.parse(await Bun.file(path.join(sandbox, "state", "overlay.json")).text());
    expect(typeof done.legacyNamesMigratedAt).toBe("number");
  });

  test("an index that cannot be read yet is retried on the next start, archive marks included", async () => {
    const lateId = "77777777-7777-4777-8777-777777777777";
    const late = new TranscriptBuilder(lateId, project);
    late.user("question for late");
    late.write(configDir);
    const lateIndex = path.join(sandbox, "legacy", "late.json");
    const stateDir = path.join(sandbox, "state-late");
    writeFileSync(lateIndex, "{ half written");
    process.env.MIMI_CLAUDE_LEGACY_INDEX = lateIndex;
    try {
      const { createApp } = await import("../src/app.ts");
      const first = createApp({ stateDir, log: () => {}, claudeExecutable: () => "unused" });
      await first.migrateLegacyNames();
      expect(await titleOf(lateId)).toBeUndefined();
      expect(await Bun.file(path.join(stateDir, "overlay.json")).exists()).toBe(false);

      writeFileSync(lateIndex, JSON.stringify({ threads: [{ threadId: lateId, name: "Mimi late", archived: true }] }));
      const second = createApp({ stateDir, log: () => {}, claudeExecutable: () => "unused" });
      await second.migrateLegacyNames();
      expect(await titleOf(lateId)).toBe("Mimi late");
      const overlay = JSON.parse(await Bun.file(path.join(stateDir, "overlay.json")).text());
      expect(Object.keys(overlay.archived)).toEqual([lateId]);
      expect(typeof overlay.legacyNamesMigratedAt).toBe("number");
      await Promise.all([first.manager.closeAll(), second.manager.closeAll()]);
    } finally {
      process.env.MIMI_CLAUDE_LEGACY_INDEX = legacyIndex;
    }
  });
});
