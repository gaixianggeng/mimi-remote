// 真实 Agent SDK + 假 Claude CLI（test/support/fake-claude.ts）驱动完整的对话链路：
// 事件序列、审批、提问、中断、引导、重连补发审批、占用检测、运行中切换模型。
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import type { App } from "../src/app.ts";
import type { OutboundFrame } from "../src/rpc/frames.ts";
import { Session } from "../src/session/session.ts";

const sandbox = realpathSync(mkdtempSync(path.join(os.tmpdir(), "mimi-adapter-runtime-")));
const configDir = path.join(sandbox, "claude");
const project = path.join(sandbox, "project");
const fakeClaude = path.join(sandbox, "claude-fake");
let app: App;
setDefaultTimeout(30_000);

beforeAll(async () => {
  mkdirSync(project, { recursive: true });
  writeFileSync(fakeClaude, `#!/bin/sh\nexec "${process.execPath}" "${path.join(import.meta.dir, "support", "fake-claude.ts")}" "$@"\n`);
  chmodSync(fakeClaude, 0o755);
  process.env.CLAUDE_CONFIG_DIR = configDir;
  process.env.MIMI_CLAUDE_LEGACY_INDEX = "";
  const { createApp } = await import("../src/app.ts");
  app = createApp({ stateDir: path.join(sandbox, "state"), log: () => {}, claudeExecutable: () => fakeClaude, idleCloseMs: 60_000 });
});

afterAll(async () => {
  await app?.manager.closeAll();
  delete process.env.CLAUDE_CONFIG_DIR;
  rmSync(sandbox, { recursive: true, force: true });
});

/** 模拟一个已 attach 的 iPad 连接：所有出站帧按顺序记录。 */
class Client {
  readonly frames: OutboundFrame[] = [];
  readonly session = new Session(`client-${Math.random()}`);
  private generation: number;
  private nextId = 1;

  constructor() {
    this.session.setBusyCheck(() => app.manager.isSessionBusy(this.session));
    this.generation = this.session.attach(undefined, (frame) => this.frames.push(frame), false).generation;
  }

  async call(method: string, params: Record<string, unknown>): Promise<any> {
    const response = await app.router.dispatch({ id: this.nextId++, method, params }, { session: this.session, generation: this.generation });
    this.session.respond(response, this.generation);
    if ("error" in response) {
      const error = new Error(String((response.error as { message: string }).message)) as Error & { data?: unknown; code?: number };
      error.data = (response.error as { data?: unknown }).data;
      error.code = (response.error as { code?: number }).code;
      throw error;
    }
    return response.result;
  }

  async waitFor(predicate: (frame: any) => boolean, timeoutMs = 10_000): Promise<any> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const found = this.frames.find(predicate);
      if (found) return found;
      await Bun.sleep(10);
    }
    throw new Error(`timed out; methods seen: ${this.frames.map((frame) => frame.method ?? `#${String(frame.id)}`).join(", ")}`);
  }

  methods(): string[] {
    return this.frames.map((frame) => String(frame.method ?? "response"));
  }

  turnCompleted(turnId: string) {
    return this.waitFor((frame) => frame.method === "turn/completed" && frame.params.turn.id === turnId);
  }

  answer(request: any, result: unknown) {
    app.manager.handleClientResponse({ id: request.id, result });
  }

  detach() {
    this.session.detach(this.generation);
  }

  reattach(lastSeen: number) {
    const sink: OutboundFrame[] = [];
    const outcome = this.session.attach(
      lastSeen,
      (frame) => {
        sink.push(frame);
        this.frames.push(frame);
      },
      true,
    );
    this.generation = outcome.generation;
    this.session.flushBacklog(outcome.backlog, outcome.generation);
    this.session.sendReplay(outcome.generation);
    return sink;
  }
}

const text = (value: string) => [{ type: "text", text: value, text_elements: [] }];

async function newThread(client: Client): Promise<string> {
  const started = await client.call("thread/start", { cwd: project, model: "fake-a", approvalPolicy: "on-request", sandbox: "workspace-write" });
  expect(started.thread.canAcceptDirectInput).toBe(true);
  return started.thread.id;
}

describe("turn lifecycle", () => {
  test("a turn emits the same event sequence as the old bridge and its ids survive into history", async () => {
    const client = new Client();
    const threadId = await newThread(client);
    const { turn } = await client.call("turn/start", { threadId, input: text("hello"), clientUserMessageId: "client-1" });
    expect(turn.status).toBe("inProgress");
    const completed = await client.turnCompleted(turn.id);
    expect(completed.params.turn.status).toBe("completed");

    // 去掉开头 thread/start 的响应；状态与额度通知穿插出现，不参与顺序比较。
    const sequence = client
      .methods()
      .slice(1)
      .filter((method) => !method.startsWith("thread/status") && method !== "account/rateLimits/updated");
    expect(sequence.slice(0, 5)).toEqual(["turn/started", "item/started", "item/completed", "response", "item/started"]);
    expect(sequence.slice(-2)).toEqual(["thread/tokenUsage/updated", "turn/completed"]);
    const user = client.frames.find((frame: any) => frame.method === "item/completed" && frame.params.item.type === "userMessage") as any;
    expect(user.params.item).toMatchObject({ id: turn.id, clientId: "client-1" });
    const reply = client.frames.find((frame: any) => frame.method === "item/completed" && frame.params.item.type === "agentMessage") as any;
    expect(reply.params.item.text).toBe("echo[fake-a]: hello");
    expect(client.frames.some((frame: any) => frame.method === "item/agentMessage/delta" && frame.params.itemId === reply.params.item.id)).toBe(true);
    const usage = client.frames.find((frame: any) => frame.method === "thread/tokenUsage/updated") as any;
    expect(usage.params.tokenUsage.last).toMatchObject({ inputTokens: 10, cachedInputTokens: 100, outputTokens: 5 });
    const limits = client.frames.find((frame: any) => frame.method === "account/rateLimits/updated") as any;
    expect(limits.params.rateLimits.primary).toMatchObject({ usedPercent: 25, windowDurationMins: 300 });

    // 实时与历史用同一套 ID：重新加载不会重复。
    const history = await client.call("thread/turns/list", { threadId, itemsView: "full", sortDirection: "asc" });
    expect(history.data.map((entry: any) => entry.id)).toEqual([turn.id]);
    expect(history.data[0].items.map((item: any) => item.id)).toEqual([turn.id, reply.params.item.id]);
  });

  test("a second turn switches the model on the running process", async () => {
    const client = new Client();
    const threadId = await newThread(client);
    const first = await client.call("turn/start", { threadId, input: text("one") });
    await client.turnCompleted(first.turn.id);
    const second = await client.call("turn/start", { threadId, input: text("two"), model: "fake-b" });
    await client.turnCompleted(second.turn.id);
    const replies = client.frames
      .filter((frame: any) => frame.method === "item/completed" && frame.params.item.type === "agentMessage")
      .map((frame: any) => frame.params.item.text);
    expect(replies).toEqual(["echo[fake-a]: one", "echo[fake-b]: two"]);
  });

  test("thinking streams as reasoning before the reply", async () => {
    const client = new Client();
    const threadId = await newThread(client);
    const { turn } = await client.call("turn/start", { threadId, input: text("THINK") });
    await client.turnCompleted(turn.id);
    const items = client.frames.filter((frame: any) => frame.method === "item/completed").map((frame: any) => frame.params.item);
    expect(items.map((item: any) => item.type)).toEqual(["userMessage", "reasoning", "agentMessage"]);
    expect(items[1].content).toEqual(["considering options"]);
    expect(client.frames.some((frame: any) => frame.method === "item/reasoning/textDelta")).toBe(true);
  });
});

describe("approvals", () => {
  test("an accepted command runs and the request is resolved for every subscriber", async () => {
    const client = new Client();
    const watcher = new Client();
    const threadId = await newThread(client);
    await watcher.call("thread/resume", { threadId });
    const { turn } = await client.call("turn/start", { threadId, input: text('TOOL Bash {"command":"touch x"}') });
    const request = await client.waitFor((frame) => frame.method === "item/commandExecution/requestApproval");
    expect(request.params).toMatchObject({ threadId, turnId: turn.id, command: "touch x", toolName: "Bash" });
    expect(request.params.availableDecisions).toEqual(["accept", "acceptWithPermissionUpdate", "decline"]);
    await watcher.waitFor((frame) => frame.method === "item/commandExecution/requestApproval" && frame.id === request.id);
    client.answer(request, { decision: "accept" });
    await watcher.waitFor((frame) => frame.method === "serverRequest/resolved" && frame.params.requestId === request.id);
    await client.turnCompleted(turn.id);
    const command = client.frames.find((frame: any) => frame.method === "item/completed" && frame.params.item.type === "commandExecution") as any;
    expect(command.params.item).toMatchObject({ status: "completed", command: "touch x" });
  });

  test("a declined command fails the tool call without failing the turn", async () => {
    const client = new Client();
    const threadId = await newThread(client);
    const { turn } = await client.call("turn/start", { threadId, input: text('TOOL Bash {"command":"rm -rf x"}') });
    const request = await client.waitFor((frame) => frame.method === "item/commandExecution/requestApproval");
    client.answer(request, { decision: "decline" });
    const completed = await client.turnCompleted(turn.id);
    expect(completed.params.turn.status).toBe("completed");
    const command = client.frames.find((frame: any) => frame.method === "item/completed" && frame.params.item.type === "commandExecution") as any;
    expect(command.params.item.status).toBe("failed");
    expect(command.params.item.aggregatedOutput).toContain("user declined this tool call");
  });

  test("file edits ask through the file change approval", async () => {
    const client = new Client();
    const threadId = await newThread(client);
    const { turn } = await client.call("turn/start", { threadId, input: text('TOOL Write {"file_path":"/tmp/a.txt","content":"hi"}') });
    const request = await client.waitFor((frame) => frame.method === "item/fileChange/requestApproval");
    expect(request.params).toMatchObject({ path: "/tmp/a.txt", toolName: "Write" });
    expect(request.params.diff).toContain("+hi");
    client.answer(request, { decision: "accept" });
    await client.turnCompleted(turn.id);
  });

  test("AskUserQuestion becomes a user input request and the answer reaches Claude", async () => {
    const client = new Client();
    const threadId = await newThread(client);
    const { turn } = await client.call("turn/start", { threadId, input: text("ASK") });
    const request = await client.waitFor((frame) => frame.method === "item/tool/requestUserInput");
    expect(request.params.questions[0]).toMatchObject({ id: "question-0", header: "Drink", question: "Tea or coffee?", isOther: true });
    client.answer(request, { answers: { "question-0": { answers: ["Tea"] } } });
    await client.turnCompleted(turn.id);
    const reply = client.frames.filter((frame: any) => frame.method === "item/completed" && frame.params.item.type === "agentMessage").at(-1) as any;
    expect(reply.params.item.text).toBe('picked {"Tea or coffee?":"Tea"}');
  });

  test("a reconnecting client gets pending approvals once through serverRequest/replay", async () => {
    const client = new Client();
    const threadId = await newThread(client);
    const { turn } = await client.call("turn/start", { threadId, input: text('TOOL Bash {"command":"ls"}') });
    const request = await client.waitFor((frame) => frame.method === "item/commandExecution/requestApproval");
    client.detach();
    const delivered = client.reattach(0);
    expect(delivered.filter((frame: any) => frame.method === "item/commandExecution/requestApproval")).toHaveLength(0);
    const replay = delivered.find((frame: any) => frame.method === "serverRequest/replay") as any;
    expect(replay.params.outstanding.map((entry: any) => entry.id)).toEqual([request.id]);
    client.answer(request, { decision: "accept" });
    await client.turnCompleted(turn.id);
  });
});

describe("interrupt and steer", () => {
  test("interrupt ends the turn as interrupted", async () => {
    const client = new Client();
    const threadId = await newThread(client);
    const { turn } = await client.call("turn/start", { threadId, input: text("SLOW") });
    await client.waitFor((frame) => frame.method === "item/agentMessage/delta");
    await client.call("turn/interrupt", { threadId, turnId: turn.id });
    const completed = await client.turnCompleted(turn.id);
    expect(completed.params.turn.status).toBe("interrupted");
  });

  test("steer adds the message to the running turn and starting another turn is rejected", async () => {
    const client = new Client();
    const threadId = await newThread(client);
    const { turn } = await client.call("turn/start", { threadId, input: text("SLOW") });
    await client.waitFor((frame) => frame.method === "item/agentMessage/delta");
    const rejected = await client.call("turn/start", { threadId, input: text("again") }).catch((error) => error);
    expect(rejected.data).toMatchObject({ reason: "active_turn", activeTurnId: turn.id });
    const steered = await client.call("turn/steer", { threadId, expectedTurnId: turn.id, input: text("change course"), clientUserMessageId: "client-steer" });
    expect(steered).toEqual({ turnId: turn.id });
    await client.turnCompleted(turn.id);
    const completedTurns = client.frames.filter((frame: any) => frame.method === "turn/completed");
    expect(completedTurns).toHaveLength(1);
    const items = client.frames.filter((frame: any) => frame.method === "item/completed").map((frame: any) => frame.params.item);
    expect(items.some((item: any) => item.type === "userMessage" && item.clientId === "client-steer")).toBe(true);
    expect(items.some((item: any) => item.type === "agentMessage" && item.text === "steered: change course")).toBe(true);
  });
});

describe("ownership", () => {
  test("a session held by another local Claude process is read-only", async () => {
    const client = new Client();
    const threadId = await newThread(client);
    const first = await client.call("turn/start", { threadId, input: text("seed") });
    await client.turnCompleted(first.turn.id);
    // 模拟终端里的 claude 正持有这个会话：登记一个活着但不属于适配器的进程。
    const registry = path.join(configDir, "sessions", "424242.json");
    writeFileSync(registry, JSON.stringify({ pid: process.pid, sessionId: threadId, cwd: project, entrypoint: "cli", kind: "interactive", status: "busy" }));
    try {
      const list = await client.call("thread/list", { cwd: project, limit: 50 });
      const listed = list.data.find((thread: any) => thread.id === threadId);
      expect(listed).toMatchObject({ canAcceptDirectInput: false, claudeOwner: { entrypoint: "cli", status: "busy" } });
      const rejected = await client.call("turn/start", { threadId, input: text("blocked") }).catch((error) => error);
      expect(rejected.data).toMatchObject({ reason: "owned_elsewhere", retryable: true });
    } finally {
      rmSync(registry, { force: true });
    }
  });
});
