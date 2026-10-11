// 用真实 Agent SDK 读取合成夹具，验证列表与历史的语义：worktree 归属、分叉只取主线、
// 压缩后只显示压缩之后、排队消息、活动时间不受 mtime 影响。全程不碰真实 ~/.claude。
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { mkdtempSync, realpathSync, rmSync, utimesSync } from "node:fs";
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
    expect((byId.get(ids.root) as any).canAcceptDirectInput).toBe(false);
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
    const second = await call("thread/list", { cwd: repo, limit: 2, cursor: first.nextCursor });
    expect(second.data.map((thread: any) => thread.id)).toEqual([ids.root, ids.forked]);
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
    const page = await call("thread/turns/list", { threadId: ids.forked, limit: 1 });
    expect(prompts(page.data)).toEqual(["queued follow-up"]);
    const older = await call("thread/turns/list", { threadId: ids.forked, limit: 5, cursor: page.nextCursor });
    expect(prompts(older.data)).toEqual(["kept branch prompt", "fork base"]);
    const turnId = page.data[0].id;
    const items = await call("thread/items/list", { threadId: ids.forked, turnId, limit: 1 });
    expect(items.data[0].item.type).toBe("userMessage");
    const rest = await call("thread/items/list", { threadId: ids.forked, turnId, cursor: items.nextCursor });
    expect(rest.data.map((entry: any) => entry.item.type)).toEqual(["agentMessage"]);
    expect(rest.nextCursor).toBeNull();
  });

  test("thread/read returns metadata, optionally with turns", async () => {
    const plain = await call("thread/read", { threadId: ids.root });
    expect(plain.thread.turns).toEqual([]);
    const full = await call("thread/read", { threadId: ids.root, includeTurns: true });
    expect(prompts(full.thread.turns)).toEqual(["root prompt"]);
  });
});
