// 用真实 Agent SDK 读取合成夹具，验证列表与历史的语义：worktree 归属、分叉只取主线、
// 压缩后只显示压缩之后、排队消息、活动时间不受 mtime 影响。全程不碰真实 ~/.claude。
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import type { Router } from "../src/server/router.ts";
import { Session } from "../src/session/session.ts";
import { TranscriptBuilder } from "./support/transcripts.ts";

const sandbox = realpathSync(mkdtempSync(path.join(os.tmpdir(), "mimi-claude-adapter-")));
const configDir = path.join(sandbox, "claude");
const repo = path.join(sandbox, "repo");
const nestedWorktree = path.join(repo, ".claude", "worktrees", "feature");
const siblingWorktree = path.join(sandbox, "repo-sibling");
const otherProject = path.join(sandbox, "other");

const ids = {
  root: "11111111-1111-4111-8111-111111111111",
  nested: "22222222-2222-4222-8222-222222222222",
  sibling: "33333333-3333-4333-8333-333333333333",
  other: "44444444-4444-4444-8444-444444444444",
  forked: "55555555-5555-4555-8555-555555555555",
  compacted: "66666666-6666-4666-8666-666666666666",
  multiBlock: "77777777-7777-4777-8777-777777777777",
};

let router: Router;
let rootFile = "";

function git(cwd: string, ...args: string[]) {
  execFileSync("git", args, { cwd, stdio: "ignore", env: { ...process.env, GIT_CONFIG_GLOBAL: "/dev/null" } });
}

async function call(method: string, params: unknown): Promise<any> {
  const session = new Session("test");
  const { generation } = session.attach(undefined, () => {}, false);
  const response = await router.dispatch({ id: 1, method, params }, { session, generation });
  if ("error" in response) throw new Error(JSON.stringify(response.error));
  return response.result;
}

beforeAll(async () => {
  for (const dir of [repo, otherProject]) execFileSync("mkdir", ["-p", dir]);
  git(repo, "init", "-q", "-b", "main");
  git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init");
  git(repo, "worktree", "add", "-q", "-b", "feature", nestedWorktree);
  git(repo, "worktree", "add", "-q", "-b", "sibling", siblingWorktree);

  const root = new TranscriptBuilder(ids.root, repo, "main", Date.parse("2026-09-05T00:00:00Z"));
  root.user("root prompt");
  root.assistant([{ type: "text", text: "root reply" }]);
  root.title("Root session");
  rootFile = root.write(configDir);

  const nested = new TranscriptBuilder(ids.nested, nestedWorktree, "feature", Date.parse("2026-09-06T00:00:00Z"));
  nested.user([
    { type: "text", text: "<system-reminder>\nYou are operating in a git worktree.\n</system-reminder>\n" },
    { type: "text", text: "nested worktree task" },
  ]);
  nested.assistant([{ type: "text", text: "on it" }]);
  nested.write(configDir);

  const sibling = new TranscriptBuilder(ids.sibling, siblingWorktree, "sibling", Date.parse("2026-09-07T00:00:00Z"));
  sibling.user("sibling worktree task");
  sibling.assistant([{ type: "text", text: "ok" }]);
  sibling.write(configDir);

  const other = new TranscriptBuilder(ids.other, otherProject, "main", Date.parse("2026-09-08T00:00:00Z"));
  other.user("other project");
  other.write(configDir);

  // 分叉：同一父节点下两条支线，较新的支线是 CLI 继续的那条。
  const forked = new TranscriptBuilder(ids.forked, repo, "main", Date.parse("2026-09-03T00:00:00Z"));
  forked.user("fork base");
  const base = forked.assistant([{ type: "text", text: "base reply" }]);
  forked.user("abandoned branch prompt", {}, base);
  forked.assistant([{ type: "text", text: "abandoned reply" }]);
  forked.user("kept branch prompt", {}, base);
  forked.assistant([{ type: "text", text: "kept reply" }]);
  const kept = forked.records[forked.records.length - 1]!.uuid as string;
  forked.push({
    type: "attachment",
    attachment: { type: "queued_command", prompt: "queued follow-up", commandMode: "prompt", humanTurn: true },
  }, kept);
  forked.assistant([{ type: "text", text: "follow-up reply" }]);
  forked.write(configDir);

  // 新版压缩：压缩前的提问在 CLI 里不显示。
  const compacted = new TranscriptBuilder(ids.compacted, repo, "main", Date.parse("2026-09-02T00:00:00Z"));
  compacted.user("before compaction prompt");
  compacted.assistant([{ type: "text", text: "before reply" }]);
  compacted.compact("This session is being continued from a previous conversation. Summary: ...");
  compacted.user("after compaction prompt");
  compacted.assistant([{ type: "text", text: "after reply" }]);
  compacted.write(configDir);

  // 一条记录里有多个文本块，结尾还有 CLI 空恢复留下的本地命令输出（不算活动）。
  const multiBlock = new TranscriptBuilder(ids.multiBlock, otherProject, "main", Date.parse("2026-09-09T00:00:00Z"));
  multiBlock.user("multi block prompt");
  multiBlock.push({
    type: "assistant",
    message: {
      id: "msg_multi",
      role: "assistant",
      content: [
        { type: "text", text: "part one" },
        { type: "tool_use", id: "toolu_multi", name: "Bash", input: { command: "ls" } },
        { type: "text", text: "part two" },
      ],
    },
  });
  multiBlock.toolResult("toolu_multi", "listing");
  multiBlock.user("<local-command-caveat>Caveat: generated by local commands</local-command-caveat>", { isMeta: true });
  multiBlock.user("<local-command-stdout>Set model to haiku</local-command-stdout>");
  multiBlock.write(configDir);

  process.env.CLAUDE_CONFIG_DIR = configDir;
  process.env.MIMI_CLAUDE_LEGACY_INDEX = "";
  const { createRouter } = await import("../src/app.ts");
  router = createRouter({ stateDir: path.join(sandbox, "state"), log: () => {} });
});

afterAll(() => {
  delete process.env.CLAUDE_CONFIG_DIR;
  rmSync(sandbox, { recursive: true, force: true });
});

describe("thread/list", () => {
  test("a repository listing includes sessions from all of its worktrees", async () => {
    const result = await call("thread/list", { cwd: repo, limit: 50 });
    const byId = new Map(result.data.map((thread: any) => [thread.id, thread]));
    expect([...byId.keys()].sort()).toEqual([ids.root, ids.nested, ids.sibling, ids.forked, ids.compacted].sort());
    expect((byId.get(ids.nested) as any).gitInfo.branch).toBe("feature");
    expect((byId.get(ids.nested) as any).cwd).toBe(nestedWorktree);
    // 首条提问前的 worktree 提示不能变成预览。
    expect((byId.get(ids.nested) as any).preview).toBe("nested worktree task");
    expect((byId.get(ids.root) as any).name).toBe("Root session");
    // 没有别的进程占用时可以直接发送。
    expect((byId.get(ids.root) as any).canAcceptDirectInput).toBe(true);
  });

  test("activity time comes from the last message, not the file modification time", async () => {
    const before = await call("thread/list", { cwd: repo, limit: 50 });
    const updatedAt = before.data.find((thread: any) => thread.id === ids.root).updatedAt;
    utimesSync(rootFile, new Date(), new Date());
    const after = await call("thread/list", { cwd: repo, limit: 50 });
    expect(after.data.find((thread: any) => thread.id === ids.root).updatedAt).toBe(updatedAt);
    expect(updatedAt).toBe(Math.floor(Date.parse("2026-09-05T00:00:02Z") / 1000));
  });

  test("pages are ordered by activity and continue from the cursor", async () => {
    const first = await call("thread/list", { cwd: repo, limit: 2, sortKey: "updated_at" });
    expect(first.data.map((thread: any) => thread.id)).toEqual([ids.sibling, ids.nested]);
    const second = await call("thread/list", { cwd: repo, limit: 2, sortKey: "updated_at", cursor: first.nextCursor });
    expect(second.data.map((thread: any) => thread.id)).toEqual([ids.root, ids.forked]);
  });

  test("internal records at the end of a transcript do not count as activity", async () => {
    const result = await call("thread/list", { cwd: otherProject, limit: 50, sortKey: "updated_at" });
    const thread = result.data.find((entry: any) => entry.id === ids.multiBlock);
    // 最后一条真实消息是工具结果（第 3 条记录），之后的本地命令输出不推进活动时间。
    expect(thread.updatedAt).toBe(Math.floor(Date.parse("2026-09-09T00:00:03Z") / 1000));
  });

  test("an omitted sortKey orders by creation time like the protocol default", async () => {
    const byDefault = await call("thread/list", { cwd: repo, limit: 50 });
    const byCreated = await call("thread/list", { cwd: repo, limit: 50, sortKey: "created_at" });
    expect(byDefault.data.map((thread: any) => thread.id)).toEqual(byCreated.data.map((thread: any) => thread.id));
    const created = byDefault.data.map((thread: any) => thread.createdAt);
    expect([...created].sort((a, b) => b - a)).toEqual(created);
  });

  test("a holder elsewhere turns the listed status into active or idle and carries its timing", async () => {
    const sessions = path.join(configDir, "sessions");
    mkdirSync(sessions, { recursive: true });
    const registry = path.join(sessions, `${process.pid}.json`);
    const since = 1_757_000_000_000;
    const record = (status: string) => JSON.stringify({ pid: process.pid, sessionId: ids.root, cwd: repo, entrypoint: "claude-desktop", kind: "interactive", status, startedAt: since - 60_000, statusUpdatedAt: since });
    const listed = async () => (await call("thread/list", { cwd: repo, limit: 50 })).data.find((thread: any) => thread.id === ids.root);
    try {
      writeFileSync(registry, record("busy"));
      expect(await listed()).toMatchObject({
        status: { type: "active", activeFlags: [] },
        canAcceptDirectInput: false,
        claudeOwner: { entrypoint: "claude-desktop", status: "busy", statusUpdatedAt: since },
      });
      writeFileSync(registry, record("idle"));
      expect(await listed()).toMatchObject({ status: { type: "idle" }, canAcceptDirectInput: false, claudeOwner: { status: "idle" } });
    } finally {
      rmSync(registry, { force: true });
    }
    const released = await listed();
    expect(released.status).toEqual({ type: "notLoaded" });
    expect(released.canAcceptDirectInput).toBe(true);
    expect(released.claudeOwner).toBeUndefined();
  });

  test("search matches titles and previews", async () => {
    const result = await call("thread/list", { searchTerm: "SIBLING" });
    expect(result.data.map((thread: any) => thread.id)).toEqual([ids.sibling]);
  });
});

describe("history", () => {
  const prompts = (turns: any[]) =>
    turns.flatMap((turn) => turn.items.filter((item: any) => item.type === "userMessage").map((item: any) => item.content[0].text));

  test("a forked session shows only the branch the CLI continued, plus queued messages", async () => {
    const result = await call("thread/turns/list", { threadId: ids.forked, sortDirection: "asc", itemsView: "full" });
    expect(prompts(result.data)).toEqual(["fork base", "kept branch prompt", "queued follow-up"]);
  });

  test("a compacted session starts at the compaction like the CLI", async () => {
    const result = await call("thread/turns/list", { threadId: ids.compacted, sortDirection: "asc", itemsView: "full" });
    expect(prompts(result.data)).toEqual(["after compaction prompt"]);
    expect(result.data[0].items[0].type).toBe("contextCompaction");
  });

  test("turns page newest first and items page within a turn", async () => {
    // 运行中排队发出的消息归入当前 turn（与实时的 turn/steer 一致）。
    const page = await call("thread/turns/list", { threadId: ids.forked, limit: 1 });
    expect(prompts(page.data)).toEqual(["kept branch prompt", "queued follow-up"]);
    const older = await call("thread/turns/list", { threadId: ids.forked, limit: 5, cursor: page.nextCursor });
    expect(prompts(older.data)).toEqual(["fork base"]);
    const turnId = page.data[0].id;
    const items = await call("thread/items/list", { threadId: ids.forked, turnId, limit: 1 });
    expect(items.data[0].item.type).toBe("userMessage");
    const rest = await call("thread/items/list", { threadId: ids.forked, turnId, cursor: items.nextCursor });
    expect(rest.data.map((entry: any) => entry.item.type)).toEqual(["agentMessage", "userMessage", "agentMessage"]);
    expect(rest.nextCursor).toBeNull();
  });

  test("item pages walk every item exactly once even when one record holds several text blocks", async () => {
    const seen: string[] = [];
    let cursor: string | null | undefined;
    do {
      const page = await call("thread/items/list", { threadId: ids.multiBlock, limit: 1, ...(cursor ? { cursor } : {}) });
      seen.push(...page.data.map((entry: any) => entry.item.id));
      cursor = page.nextCursor;
    } while (cursor && seen.length < 20);
    expect(seen).toHaveLength(4);
    expect(new Set(seen).size).toBe(4);
  });

  test("thread/read returns metadata, optionally with turns", async () => {
    const plain = await call("thread/read", { threadId: ids.root });
    expect(plain.thread.turns).toEqual([]);
    const full = await call("thread/read", { threadId: ids.root, includeTurns: true });
    expect(prompts(full.thread.turns)).toEqual(["root prompt"]);
  });
});
