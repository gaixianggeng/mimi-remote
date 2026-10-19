// 后台任务与空闲关闭（#796）：后台任务属于 Claude 进程，进程一关任务就随之结束、续写也不会发生。
// 用脚本化的 Query 控制 background_tasks_changed 与续写的到达顺序，空闲时限压到几百毫秒。
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import type { App } from "../src/app.ts";
import type { OutboundFrame } from "../src/rpc/frames.ts";
import { Session } from "../src/session/session.ts";
import { configureLogging } from "../src/util/logging.ts";
import { ScriptedQuery } from "./support/scripted-query.ts";

const sandbox = realpathSync(mkdtempSync(path.join(os.tmpdir(), "mimi-adapter-background-")));
// 留出余量：Windows 计时器精度约 15 ms，settle() 在那里接近 80 ms。
const IDLE_CLOSE_MS = 250;

let app: App;
let script: ScriptedQuery;
let starts = 0;

beforeAll(async () => {
  process.env.CLAUDE_CONFIG_DIR = path.join(sandbox, "claude");
  process.env.MIMI_CLAUDE_LEGACY_INDEX = "";
  const { createApp } = await import("../src/app.ts");
  app = createApp({
    stateDir: path.join(sandbox, "state"),
    log: () => {},
    claudeExecutable: () => "unused",
    probeClaudeCode: async () => ({ status: "ok", version: "9.9.9" }),
    idleCloseMs: IDLE_CLOSE_MS,
    startQuery: (({ prompt }: { prompt: AsyncIterable<unknown> }) => {
      starts += 1;
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
const session = new Session("background");
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

/** 等过空闲时限：到点的关闭也要来得及走完。 */
const pastIdleClose = () => Bun.sleep(IDLE_CLOSE_MS * 2.5);

const text = (value: string) => [{ type: "text", text: value, text_elements: [] }];

function reply(uuid: string | undefined, messageId: string, body: string): Array<Record<string, unknown>> {
  return [
    { type: "stream_event", event: { type: "message_start", message: { id: messageId } }, ...(uuid ? { user_message_uuid: uuid } : {}) },
    { type: "assistant", message: { id: messageId, content: [{ type: "text", text: body }] } },
  ];
}

const backgroundTasks = (tasks: Array<Record<string, unknown>>) => ({ type: "system", subtype: "background_tasks_changed", tasks });
const bashTask = { task_id: "bash_1", task_type: "local_bash", description: "sleep 900 && echo done" };

/** 开一个会话，跑一轮在后台启动任务的 turn；返回会话 ID 与该轮 turn ID。 */
async function startBackgroundTurn(tasks: Array<Record<string, unknown>>) {
  const started = await call("thread/start", { cwd: sandbox });
  const threadId: string = started.thread.id;
  const { turn } = await call("turn/start", { threadId, input: text("run the long job in the background") });
  for (const message of reply(turn.id, `msg_${turn.id.slice(0, 6)}`, "started in the background")) script.emit(message);
  script.emit(backgroundTasks(tasks));
  script.emit({ type: "result", subtype: "success", user_message_uuids: [turn.id] });
  await settle();
  return { threadId, turnId: turn.id as string, runtime: app.manager.get(threadId)! };
}

const methodsFor = (turnId: string) =>
  frames.filter((frame: any) => frame.params?.turn?.id === turnId).map((frame: any) => frame.method);

describe("background tasks and idle close", () => {
  test("a background task outlives the idle timeout and its completion still continues the session", async () => {
    const { turnId, runtime } = await startBackgroundTurn([bashTask]);
    expect(methodsFor(turnId)).toEqual(["turn/started", "turn/completed"]);
    await pastIdleClose();
    expect(runtime.hasLiveProcess()).toBe(true);

    // 任务完成：先离开电平集合，Claude 再按完成通知自己接着回复（没有用户消息的 uuid）。
    const startedBefore = frames.filter((frame: any) => frame.method === "turn/started").length;
    script.emit({ type: "system", subtype: "task_notification", task_id: "bash_1", status: "completed", output_file: "", summary: "done" });
    script.emit(backgroundTasks([]));
    for (const message of reply(undefined, "msg_auto", "background finished")) script.emit(message);
    script.emit({ type: "result", subtype: "success" });
    await settle();
    const started = frames.filter((frame: any) => frame.method === "turn/started");
    expect(started).toHaveLength(startedBefore + 1);
    const continuation = (started.at(-1) as any).params.turn.id;
    expect(methodsFor(continuation)).toEqual(["turn/started", "turn/completed"]);
    const answer = frames.find((frame: any) => frame.method === "item/completed" && frame.params.turnId === continuation) as any;
    expect(answer.params.item).toMatchObject({ type: "agentMessage", text: "background finished" });

    // 任务全部结束后空闲关闭照常生效，不留常驻进程。
    await pastIdleClose();
    expect(runtime.hasLiveProcess()).toBe(false);
  });

  test("once the last background task ends without a reply, the idle timer starts over", async () => {
    const { runtime } = await startBackgroundTurn([bashTask, { ...bashTask, task_id: "agent_1", task_type: "local_agent" }]);
    await pastIdleClose();
    script.emit(backgroundTasks([bashTask]));
    await pastIdleClose();
    expect(runtime.hasLiveProcess()).toBe(true);
    script.emit(backgroundTasks([]));
    await settle();
    // 刚结束时还在宽限里：从这一刻重新计时，而不是沿用回合结束时的计时。
    expect(runtime.hasLiveProcess()).toBe(true);
    await pastIdleClose();
    expect(runtime.hasLiveProcess()).toBe(false);
  });

  test("ambient tasks do not keep the process open", async () => {
    const { runtime } = await startBackgroundTurn([{ task_id: "watch_1", task_type: "monitor", description: "watcher", ambient: true }]);
    await pastIdleClose();
    expect(runtime.hasLiveProcess()).toBe(false);
  });

  test("ending the process while background tasks run is logged with the reason, and the next process starts clean", async () => {
    const lines: string[] = [];
    const restore = configureLogging({ level: "info", sink: (line) => lines.push(line) });
    try {
      const { threadId, runtime } = await startBackgroundTurn([bashTask]);
      await runtime.yieldToHolder();
      expect(runtime.hasLiveProcess()).toBe(false);
      const dropped = lines.filter((line) => line.includes("claude.background_tasks_dropped"));
      expect(dropped).toHaveLength(1);
      expect(dropped[0]).toContain(" warn ");
      expect(dropped[0]).toContain("count=1");
      expect(dropped[0]).toContain("reason=yield");

      // 重新拉起的进程没有继承旧进程的任务：这一轮结束后照常空闲关闭。
      const before = starts;
      const next = await call("turn/start", { threadId, input: text("next") });
      expect(starts).toBe(before + 1);
      for (const message of reply(next.turn.id, "msg_next", "next answer")) script.emit(message);
      script.emit({ type: "result", subtype: "success", user_message_uuids: [next.turn.id] });
      await settle();
      await pastIdleClose();
      expect(runtime.hasLiveProcess()).toBe(false);
      expect(lines.filter((line) => line.includes("claude.background_tasks_dropped"))).toHaveLength(1);
    } finally {
      restore();
    }
  });

  test("a process that exits on its own with background tasks running is logged as exited", async () => {
    const lines: string[] = [];
    const restore = configureLogging({ level: "info", sink: (line) => lines.push(line) });
    try {
      const { runtime } = await startBackgroundTurn([bashTask]);
      script.close();
      await settle();
      expect(runtime.hasLiveProcess()).toBe(false);
      expect(lines.filter((line) => line.includes("claude.background_tasks_dropped") && line.includes("reason=exited"))).toHaveLength(1);
    } finally {
      restore();
    }
  });
});
