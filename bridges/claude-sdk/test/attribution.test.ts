// 输出与结果的归属：CLI 有自己的输入队列，适配器按 user_message_uuid 认领，而不是假设
// "一次 turn/start 对应下一个结果"。用脚本化的 Query 精确控制消息到达顺序。
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import type { App } from "../src/app.ts";
import type { OutboundFrame } from "../src/rpc/frames.ts";
import { Session } from "../src/session/session.ts";

const sandbox = realpathSync(mkdtempSync(path.join(os.tmpdir(), "mimi-adapter-attribution-")));

/** 只实现运行时用到的 Query 接口；emit 的消息按顺序交给适配器。 */
class ScriptedQuery {
  readonly sent: Array<Record<string, any>> = [];
  private readonly outbox: unknown[] = [];
  private wake: (() => void) | undefined;
  private closed = false;

  attach(prompt: AsyncIterable<unknown>) {
    void (async () => {
      for await (const message of prompt) this.sent.push(message as Record<string, any>);
    })();
  }

  emit(message: Record<string, unknown>) {
    this.outbox.push(message);
    this.wake?.();
  }

  async *[Symbol.asyncIterator]() {
    while (true) {
      if (this.outbox.length) {
        yield this.outbox.shift();
        continue;
      }
      if (this.closed) return;
      await new Promise<void>((resolve) => (this.wake = resolve));
    }
  }

  async initializationResult() {
    return { pid: 1 };
  }
  async interrupt() {}
  async setModel() {}
  async setPermissionMode() {}
  async applyFlagSettings() {}
  close() {
    this.closed = true;
    this.wake?.();
  }
}

let app: App;
let script: ScriptedQuery;

beforeAll(async () => {
  process.env.CLAUDE_CONFIG_DIR = path.join(sandbox, "claude");
  process.env.MIMI_CLAUDE_LEGACY_INDEX = "";
  const { createApp } = await import("../src/app.ts");
  app = createApp({
    stateDir: path.join(sandbox, "state"),
    log: () => {},
    claudeExecutable: () => "unused",
    startQuery: (({ prompt }: { prompt: AsyncIterable<unknown> }) => {
      script = new ScriptedQuery();
      script.attach(prompt);
      return script;
    }) as never,
  });
});

afterAll(async () => {
  await app.manager.closeAll();
  delete process.env.CLAUDE_CONFIG_DIR;
  rmSync(sandbox, { recursive: true, force: true });
});

const frames: OutboundFrame[] = [];
const session = new Session("attribution");
const { generation } = session.attach(undefined, (frame) => frames.push(frame), false);
let nextId = 1;

async function call(method: string, params: Record<string, unknown>): Promise<any> {
  const response = await app.router.dispatch({ id: nextId++, method, params }, { session, generation });
  if ("error" in response) throw Object.assign(new Error("rpc error"), { data: (response.error as { data?: unknown }).data });
  return response.result;
}

async function settle() {
  for (let i = 0; i < 5; i += 1) await Bun.sleep(5);
}

const text = (value: string) => [{ type: "text", text: value, text_elements: [] }];

function reply(uuid: string | undefined, messageId: string, body: string): Array<Record<string, unknown>> {
  return [
    { type: "stream_event", event: { type: "message_start", message: { id: messageId } }, ...(uuid ? { user_message_uuid: uuid } : {}) },
    { type: "assistant", message: { id: messageId, content: [{ type: "text", text: body }] } },
  ];
}

const completedTurns = () => frames.filter((frame: any) => frame.method === "turn/completed").map((frame: any) => frame.params.turn.id);
const agentTexts = () =>
  frames
    .filter((frame: any) => frame.method === "item/completed" && frame.params.item.type === "agentMessage")
    .map((frame: any) => [frame.params.turnId, frame.params.item.text]);

describe("output attribution", () => {
  test("a steer that Claude answers in a separate round still completes the same turn", async () => {
    const started = await call("thread/start", { cwd: sandbox });
    const threadId = started.thread.id;
    const { turn } = await call("turn/start", { threadId, input: text("first") });
    await call("turn/steer", { threadId, expectedTurnId: turn.id, input: text("also this"), clientUserMessageId: "steer-1" });
    await settle();
    const [prompt, steer] = script.sent;
    expect(prompt!.uuid).toBe(turn.id);
    expect(steer).toMatchObject({ priority: "now", origin: { kind: "human" } });

    // 引导打断了第一段输出：中间结果不收尾 turn，也不算失败。
    for (const message of reply(turn.id, "msg_a", "partial answer")) script.emit(message);
    script.emit({ type: "user", message: { role: "user", content: [{ type: "text", text: "[Request interrupted by user]" }] } });
    script.emit({ type: "result", subtype: "error_during_execution", user_message_uuids: [turn.id] });
    await settle();
    expect(completedTurns()).toEqual([]);

    // 引导消息还没被回应：新的 turn/start 必须被拒，不能把后续输出错算给它。
    const rejected = await call("turn/start", { threadId, input: text("second") }).catch((error) => error);
    expect(rejected.data).toMatchObject({ reason: "active_turn", activeTurnId: turn.id });

    for (const message of reply(steer!.uuid, "msg_b", "answer to steer")) script.emit(message);
    script.emit({ type: "result", subtype: "success", user_message_uuids: [steer!.uuid] });
    await settle();
    expect(completedTurns()).toEqual([turn.id]);
    const completed = frames.find((frame: any) => frame.method === "turn/completed") as any;
    expect(completed.params.turn.status).toBe("completed");
    expect(agentTexts()).toEqual([
      [turn.id, "partial answer"],
      [turn.id, "answer to steer"],
    ]);

    // 全部消息都已回应，可以开始新 turn。
    const next = await call("turn/start", { threadId, input: text("second") });
    for (const message of reply(next.turn.id, "msg_c", "answer to second")) script.emit(message);
    script.emit({ type: "result", subtype: "success", user_message_uuids: [next.turn.id] });
    await settle();
    expect(completedTurns()).toEqual([turn.id, next.turn.id]);
  });

  test("an explicit interrupt ends the turn even with a steer pending", async () => {
    const started = await call("thread/start", { cwd: sandbox });
    const threadId = started.thread.id;
    const { turn } = await call("turn/start", { threadId, input: text("long") });
    await call("turn/steer", { threadId, expectedTurnId: turn.id, input: text("hmm"), clientUserMessageId: null });
    await call("turn/interrupt", { threadId, turnId: turn.id });
    script.emit({ type: "result", subtype: "error_during_execution", user_message_uuids: [turn.id] });
    await settle();
    const completed = frames.filter((frame: any) => frame.method === "turn/completed").at(-1) as any;
    expect(completed.params.turn).toMatchObject({ id: turn.id, status: "interrupted" });
  });

  test("output without a user message uuid opens its own turn", async () => {
    const before = completedTurns().length;
    for (const message of reply(undefined, "msg_auto", "background task finished")) script.emit(message);
    script.emit({ type: "result", subtype: "success" });
    await settle();
    const turns = completedTurns();
    expect(turns).toHaveLength(before + 1);
    expect(agentTexts().at(-1)).toEqual([turns.at(-1), "background task finished"]);
    const started = frames.filter((frame: any) => frame.method === "turn/started").at(-1) as any;
    expect(started.params.turn.id).toBe(turns.at(-1));
  });
});
