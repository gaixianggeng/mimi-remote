// 输出与结果的归属：CLI 有自己的输入队列，适配器按 user_message_uuid 认领，而不是假设
// "一次 turn/start 对应下一个结果"。用脚本化的 Query 精确控制消息到达顺序。
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import type { App } from "../src/app.ts";
import type { OutboundFrame } from "../src/rpc/frames.ts";
import { Session } from "../src/session/session.ts";
import { notificationTurnId } from "../src/claude/itemIds.ts";
import { ScriptedQuery } from "./support/scripted-query.ts";

const sandbox = realpathSync(mkdtempSync(path.join(os.tmpdir(), "mimi-adapter-attribution-")));

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
    // 脚本化的 SDK 查询不启动真实 CLI，版本门槛直接放行。
    probeClaudeCode: async () => ({ status: "ok", version: "9.9.9" }),
    startQuery: (({ prompt, options }: { prompt: AsyncIterable<unknown>; options: { canUseTool?: ScriptedQuery["canUseTool"] } }) => {
      script = new ScriptedQuery();
      script.canUseTool = options.canUseTool;
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

  test("a steer sent before Claude answers the previous steer joins the same turn", async () => {
    const started = await call("thread/start", { cwd: sandbox });
    const threadId = started.thread.id;
    const { turn } = await call("turn/start", { threadId, input: text("first") });
    await call("turn/steer", { threadId, expectedTurnId: turn.id, input: text("also this"), clientUserMessageId: "gap-1" });
    await settle();
    const firstSteer = script.sent.at(-1)!;

    // 引导打断了第一段输出，中间结果只吸收首条消息；引导那一轮还没开始输出。
    for (const message of reply(turn.id, "msg_g1", "partial")) script.emit(message);
    script.emit({ type: "user", message: { role: "user", content: [{ type: "text", text: "[Request interrupted by user]" }] } });
    script.emit({ type: "result", subtype: "error_during_execution", user_message_uuids: [turn.id] });
    await settle();

    // 这段空档里再补一句：并入同一个 turn，以 now 优先级送达 CLI。
    const accepted = await call("turn/steer", { threadId, expectedTurnId: turn.id, input: text("and that"), clientUserMessageId: "gap-2" });
    expect(accepted).toEqual({ turnId: turn.id });
    await settle();
    const secondSteer = script.sent.at(-1)!;
    expect(secondSteer).toMatchObject({ priority: "now", origin: { kind: "human" } });
    const echoed = frames.filter(
      (frame: any) => frame.method === "item/completed" && frame.params.item.type === "userMessage" && frame.params.item.clientId === "gap-2",
    ) as any[];
    expect(echoed.map((frame) => [frame.params.turnId, frame.params.item.id])).toEqual([[turn.id, secondSteer.uuid]]);
    // 期望的 turn 不符时仍按原规则拒绝，不发给 CLI。
    const mismatch = await call("turn/steer", { threadId, expectedTurnId: "stale", input: text("x"), clientUserMessageId: null }).catch(
      (error) => error,
    );
    expect(mismatch.data).toMatchObject({ reason: "turn_id_mismatch", activeTurnId: turn.id });

    // Claude 先回应第一条引导；第二条还没回应，turn 继续。
    for (const message of reply(firstSteer.uuid, "msg_g2", "answer to steer")) script.emit(message);
    script.emit({ type: "result", subtype: "success", user_message_uuids: [firstSteer.uuid] });
    await settle();
    expect(completedTurns()).not.toContain(turn.id);

    // 回应第二条时的审批同样归属这个 turn。
    script.emit({ type: "stream_event", event: { type: "message_start", message: { id: "msg_g3" } }, user_message_uuid: secondSteer.uuid });
    await settle();
    const cancel = new AbortController();
    const decision = script.canUseTool!("Bash", { command: "ls" }, { signal: cancel.signal, toolUseID: "toolu_gap" });
    const approval = frames.find((frame: any) => frame.method === "item/commandExecution/requestApproval") as any;
    expect(approval.params).toMatchObject({ threadId, turnId: turn.id });
    cancel.abort();
    await decision;
    script.emit({ type: "assistant", message: { id: "msg_g3", content: [{ type: "text", text: "answer to second steer" }] } });
    script.emit({ type: "result", subtype: "success", user_message_uuids: [secondSteer.uuid] });
    await settle();

    expect(completedTurns().filter((id) => id === turn.id)).toHaveLength(1);
    const completed = frames.find((frame: any) => frame.method === "turn/completed" && frame.params.turn.id === turn.id) as any;
    expect(completed.params.turn.status).toBe("completed");
    expect(agentTexts().filter(([turnId]) => turnId === turn.id)).toEqual([
      [turn.id, "partial"],
      [turn.id, "answer to steer"],
      [turn.id, "answer to second steer"],
    ]);
    // 每条消息只发给 CLI 一次。
    expect(script.sent.map((message) => message.uuid)).toEqual([turn.id, firstSteer.uuid, secondSteer.uuid]);
  });

  test("Claude answering both gap steers in one round completes the turn once", async () => {
    const started = await call("thread/start", { cwd: sandbox });
    const threadId = started.thread.id;
    const { turn } = await call("turn/start", { threadId, input: text("first") });
    await call("turn/steer", { threadId, expectedTurnId: turn.id, input: text("also this"), clientUserMessageId: null });
    for (const message of reply(turn.id, "msg_m1", "partial")) script.emit(message);
    script.emit({ type: "result", subtype: "error_during_execution", user_message_uuids: [turn.id] });
    await settle();
    await call("turn/steer", { threadId, expectedTurnId: turn.id, input: text("and that"), clientUserMessageId: null });
    await settle();
    const [, firstSteer, secondSteer] = script.sent;

    for (const message of reply(firstSteer!.uuid, "msg_m2", "both answered")) script.emit(message);
    script.emit({ type: "result", subtype: "success", user_message_uuids: [firstSteer!.uuid, secondSteer!.uuid] });
    await settle();
    expect(completedTurns().filter((id) => id === turn.id)).toHaveLength(1);
    expect(agentTexts().filter(([turnId]) => turnId === turn.id).map(([, body]) => body)).toEqual(["partial", "both answered"]);
    // 全部消息都已回应：可以开始新 turn。
    const next = await call("turn/start", { threadId, input: text("next") });
    for (const message of reply(next.turn.id, "msg_m3", "next answer")) script.emit(message);
    script.emit({ type: "result", subtype: "success", user_message_uuids: [next.turn.id] });
    await settle();
    expect(completedTurns()).toContain(next.turn.id);
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

  test("interrupting while a steer waits for its own round still reaches Claude", async () => {
    const started = await call("thread/start", { cwd: sandbox });
    const threadId = started.thread.id;
    const { turn } = await call("turn/start", { threadId, input: text("first") });
    await call("turn/steer", { threadId, expectedTurnId: turn.id, input: text("then this"), clientUserMessageId: null });
    await settle();
    const steer = script.sent.at(-1)!;
    // 首条消息的结果到了，引导还没开始输出：current 暂时为空，turn 仍未结束。
    for (const message of reply(turn.id, "msg_i", "first answer")) script.emit(message);
    script.emit({ type: "result", subtype: "success", user_message_uuids: [turn.id] });
    await settle();
    expect(completedTurns()).not.toContain(turn.id);

    await call("turn/interrupt", { threadId, turnId: turn.id });
    expect(script.interrupts).toBe(1);
    script.emit({ type: "result", subtype: "error_during_execution", user_message_uuids: [steer.uuid] });
    await settle();
    const completed = frames.filter((frame: any) => frame.method === "turn/completed").at(-1) as any;
    expect(completed.params.turn).toMatchObject({ id: turn.id, status: "interrupted" });
  });

  test("overlapping turn/start calls admit one turn while settings are switching", async () => {
    const started = await call("thread/start", { cwd: sandbox });
    const threadId = started.thread.id;
    const warm = await call("turn/start", { threadId, input: text("warm up") });
    for (const message of reply(warm.turn.id, "msg_w", "ready")) script.emit(message);
    script.emit({ type: "result", subtype: "success", user_message_uuids: [warm.turn.id] });
    await settle();
    const sentBefore = script.sent.length;

    let release!: () => void;
    script.settingsGate = new Promise<void>((resolve) => (release = resolve));
    const outcomes = ["one", "two"].map((body) =>
      call("turn/start", { threadId, input: text(body), model: "claude-other" }).then(
        (result) => ({ ok: true as const, result }),
        (error) => ({ ok: false as const, error }),
      ),
    );
    await settle();
    release();
    const settled = await Promise.all(outcomes);
    const accepted = settled.flatMap((outcome) => (outcome.ok ? [outcome.result] : []));
    const rejected = settled.flatMap((outcome) => (outcome.ok ? [] : [outcome.error]));
    expect(accepted).toHaveLength(1);
    expect(rejected).toHaveLength(1);
    expect(rejected[0].data).toMatchObject({ reason: "active_turn", activeTurnId: accepted[0].turn.id });
    await settle();
    expect(script.sent).toHaveLength(sentBefore + 1);

    const turnId = accepted[0].turn.id;
    for (const message of reply(turnId, "msg_o", "done")) script.emit(message);
    script.emit({ type: "result", subtype: "success", user_message_uuids: [turnId] });
    await settle();
    expect(completedTurns()).toContain(turnId);
  });

  test("a process exit finishes a turn that only owns a pending steer", async () => {
    const started = await call("thread/start", { cwd: sandbox });
    const threadId = started.thread.id;
    const { turn } = await call("turn/start", { threadId, input: text("first") });
    await call("turn/steer", { threadId, expectedTurnId: turn.id, input: text("and this"), clientUserMessageId: null });
    for (const message of reply(turn.id, "msg_x", "first answer")) script.emit(message);
    script.emit({ type: "result", subtype: "success", user_message_uuids: [turn.id] });
    await settle();
    expect(completedTurns()).not.toContain(turn.id);
    script.close();
    await settle();
    expect(completedTurns()).toContain(turn.id);
    // 不再有悬着的 turn：新 turn 照常开始（重新拉起进程）并收尾，不影响后面的用例。
    const next = await call("turn/start", { threadId, input: text("next") });
    for (const message of reply(next.turn.id, "msg_y", "next answer")) script.emit(message);
    script.emit({ type: "result", subtype: "success", user_message_uuids: [next.turn.id] });
    await settle();
    expect(completedTurns()).toContain(next.turn.id);
  });

  test("a turn/start waiting on a settings switch is refused when the session is continued elsewhere", async () => {
    const started = await call("thread/start", { cwd: sandbox });
    const threadId = started.thread.id;
    const warm = await call("turn/start", { threadId, input: text("warm up") });
    for (const message of reply(warm.turn.id, "msg_v", "ready")) script.emit(message);
    script.emit({ type: "result", subtype: "success", user_message_uuids: [warm.turn.id] });
    await settle();

    let release!: () => void;
    script.settingsGate = new Promise<void>((resolve) => (release = resolve));
    const pending = call("turn/start", { threadId, input: text("late"), model: "claude-other", approvalPolicy: "never" }).then(
      () => undefined,
      (error) => error,
    );
    await settle();
    // 切换模型途中终端接手：进程被关闭，后续的权限切换不能再发给旧进程。
    await app.manager.get(threadId)!.yieldToHolder();
    release();
    const rejected = await pending;
    expect(rejected?.data).toMatchObject({ reason: "owned_elsewhere", retryable: true });
    expect(app.manager.get(threadId)!.activeTurnId).toBeUndefined();

    // 持有方离开后照常续聊（重新拉起进程），也给后面的用例留下活着的进程。
    const next = await call("turn/start", { threadId, input: text("back") });
    for (const message of reply(next.turn.id, "msg_w2", "welcome back")) script.emit(message);
    script.emit({ type: "result", subtype: "success", user_message_uuids: [next.turn.id] });
    await settle();
    expect(completedTurns()).toContain(next.turn.id);
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

describe("continuation after a background task (#797)", () => {
  const notification = (runId: string) => ({ type: "system", subtype: "task_notification", task_id: `task-${runId}`, run_id: runId, status: "completed", output_file: "", summary: "done" });
  const round = (userMessageUuids: string[] = []) => ({ type: "system", subtype: "init", ...(userMessageUuids.length ? { user_message_uuids: userMessageUuids } : {}) });
  const startedTurns = () => frames.filter((frame: any) => frame.method === "turn/started").map((frame: any) => frame.params.turn.id);

  /** 一个跑完一轮、进程仍在的会话。 */
  async function idleThread() {
    const { thread } = await call("thread/start", { cwd: sandbox });
    const { turn } = await call("turn/start", { threadId: thread.id, input: text("run it in the background") });
    for (const message of reply(turn.id, `msg_${turn.id.slice(0, 6)}`, "started")) script.emit(message);
    script.emit({ type: "result", subtype: "success", user_message_uuids: [turn.id] });
    await settle();
    return thread.id as string;
  }

  test("the continuation carries the id history gives it, so stop and steer reach it", async () => {
    const threadId = await idleThread();
    script.emit(notification("run-a"));
    script.emit(round());
    for (const message of reply(undefined, "msg_cont_a", "background finished")) script.emit(message);
    await settle();
    const continuation = notificationTurnId(threadId, "run-a");
    expect(startedTurns().at(-1)).toBe(continuation);
    expect(app.manager.get(threadId)!.activeTurnId).toBe(continuation);

    const steered = await call("turn/steer", { threadId, expectedTurnId: continuation, input: text("also check the log"), clientUserMessageId: null });
    expect(steered).toEqual({ turnId: continuation });
    const steer = script.sent.at(-1)!;
    expect(steer).toMatchObject({ priority: "now", origin: { kind: "human" } });

    const interruptsBefore = script.interrupts;
    await call("turn/interrupt", { threadId, turnId: continuation });
    expect(script.interrupts).toBe(interruptsBefore + 1);
    script.emit({ type: "result", subtype: "error_during_execution", user_message_uuids: [steer.uuid], origin: { kind: "task-notification", runId: "run-a" } });
    await settle();
    const completed = frames.filter((frame: any) => frame.method === "turn/completed").at(-1) as any;
    expect(completed.params.turn).toMatchObject({ id: continuation, status: "interrupted" });
  });

  test("the continuation is the active turn from the moment its round begins, before any output", async () => {
    const threadId = await idleThread();
    script.emit(notification("run-w"));
    script.emit(round());
    await settle();
    // 首帧输出前（模型排队、重试）：新的 turn/start 不能被接受，否则续写的输出会挂到它名下。
    const continuation = notificationTurnId(threadId, "run-w");
    expect(startedTurns().at(-1)).toBe(continuation);
    expect(app.manager.get(threadId)!.activeTurnId).toBe(continuation);
    const rejected = await call("turn/start", { threadId, input: text("something new") }).catch((error) => error);
    expect(rejected.data).toMatchObject({ reason: "active_turn", activeTurnId: continuation });

    const interruptsBefore = script.interrupts;
    await call("turn/interrupt", { threadId, turnId: continuation });
    expect(script.interrupts).toBe(interruptsBefore + 1);
    script.emit({ type: "result", subtype: "error_during_execution", origin: { kind: "task-notification", runId: "run-w" } });
    await settle();
    const completed = frames.filter((frame: any) => frame.method === "turn/completed").at(-1) as any;
    expect(completed.params.turn).toMatchObject({ id: continuation, status: "interrupted" });
  });

  test("a continuation left waiting for a later round is closed when the CLI goes idle without one", async () => {
    const threadId = await idleThread();
    script.emit(notification("run-late"));
    script.emit(round());
    // 只有一轮属于更早的通知、没有输出，之后 CLI 直接回到 idle：续写不能一直挂着挡住新的 turn/start。
    script.emit({ type: "result", subtype: "success", origin: { kind: "task-notification", runId: "run-earlier" } });
    script.emit({ type: "system", subtype: "session_state_changed", state: "idle" });
    await settle();
    const continuation = notificationTurnId(threadId, "run-late");
    expect(completedTurns().at(-1)).toBe(continuation);
    expect(app.manager.get(threadId)!.activeTurnId).toBeUndefined();
  });

  test("a steer that Claude answers after the continuation's own result still completes the continuation", async () => {
    const threadId = await idleThread();
    script.emit(notification("run-s"));
    script.emit(round());
    for (const message of reply(undefined, "msg_cont_s", "background finished")) script.emit(message);
    await settle();
    const continuation = notificationTurnId(threadId, "run-s");
    await call("turn/steer", { threadId, expectedTurnId: continuation, input: text("and then this"), clientUserMessageId: null });
    const steer = script.sent.at(-1)!;
    // 实测：CLI 先以续写自己的结果收尾（没有用户消息可吸收），再单独一轮回应引导。
    script.emit({ type: "result", subtype: "success", origin: { kind: "task-notification", runId: "run-s" } });
    await settle();
    expect(completedTurns()).not.toContain(continuation);
    script.emit(round([steer.uuid]));
    for (const message of reply(steer.uuid, "msg_steer_s", "answer to steer")) script.emit(message);
    script.emit({ type: "result", subtype: "success", user_message_uuids: [steer.uuid] });
    await settle();
    expect(startedTurns().at(-1)).toBe(continuation);
    expect(completedTurns().at(-1)).toBe(continuation);
    expect(agentTexts().slice(-2)).toEqual([
      [continuation, "background finished"],
      [continuation, "answer to steer"],
    ]);
  });

  test("notifications arriving together continue under the last one; the empty round of the first does not take the id", async () => {
    const threadId = await idleThread();
    const startedBefore = startedTurns().length;
    script.emit(notification("run-1"));
    script.emit(notification("run-2"));
    // CLI 为第一条通知跑了一轮空的，回复出现在最后一条通知的那一轮。
    script.emit(round());
    script.emit({ type: "result", subtype: "success", origin: { kind: "task-notification", runId: "run-1" } });
    script.emit(round());
    for (const message of reply(undefined, "msg_both", "both finished")) script.emit(message);
    script.emit({ type: "result", subtype: "success", origin: { kind: "task-notification", runId: "run-2" } });
    await settle();
    expect(startedTurns().slice(startedBefore)).toEqual([notificationTurnId(threadId, "run-2")]);
    expect(completedTurns().at(-1)).toBe(notificationTurnId(threadId, "run-2"));
  });

  test("a notification arriving after a continuation began waits for its own round", async () => {
    const threadId = await idleThread();
    script.emit(notification("run-x"));
    script.emit(round());
    script.emit(notification("run-y"));
    for (const message of reply(undefined, "msg_x", "x finished")) script.emit(message);
    script.emit({ type: "result", subtype: "success", origin: { kind: "task-notification", runId: "run-x" } });
    script.emit(round());
    for (const message of reply(undefined, "msg_y", "y finished")) script.emit(message);
    script.emit({ type: "result", subtype: "success", origin: { kind: "task-notification", runId: "run-y" } });
    await settle();
    expect(startedTurns().slice(-2)).toEqual([notificationTurnId(threadId, "run-x"), notificationTurnId(threadId, "run-y")]);
  });

  test("a notification folded into a user's turn is not reused by a later continuation", async () => {
    const { thread } = await call("thread/start", { cwd: sandbox });
    const threadId = thread.id as string;
    const first = await call("turn/start", { threadId, input: text("work") });
    script.emit(round([first.turn.id]));
    for (const message of reply(first.turn.id, "msg_w1", "working")) script.emit(message);
    // 任务在这一轮进行中完成，CLI 把通知并进这一轮。
    script.emit(notification("run-folded"));
    script.emit({ type: "result", subtype: "success", user_message_uuids: [first.turn.id] });
    await settle();
    const second = await call("turn/start", { threadId, input: text("next") });
    script.emit(round([second.turn.id]));
    for (const message of reply(second.turn.id, "msg_w2", "next answer")) script.emit(message);
    script.emit({ type: "result", subtype: "success", user_message_uuids: [second.turn.id] });
    // 之后一段不是由通知触发的输出（没有 user_message_uuid）照常开新回合，不借用那条通知的 ID。
    script.emit(round());
    for (const message of reply(undefined, "msg_other", "something else")) script.emit(message);
    script.emit({ type: "result", subtype: "success" });
    await settle();
    expect(startedTurns().at(-1)).not.toBe(notificationTurnId(threadId, "run-folded"));
    expect(startedTurns().slice(-3, -1)).toEqual([first.turn.id, second.turn.id]);
  });
});
