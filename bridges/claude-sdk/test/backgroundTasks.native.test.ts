// 真实 Claude Code + 本机脚本化模型端点：后台任务与它完成后的续写。默认跳过，与 sandboxPolicy.native.test.ts
// 同一开关；隔离配置目录，不调用付费模型、不读 ~/.claude。
//   #796 后台命令跑得比空闲时限久，仍照常完成并触发续写。
//   #797 续写进行中，历史与实时报告同一个回合 ID，按它停止、补充消息都生效。
import { describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import type { App } from "../src/app.ts";
import type { OutboundFrame } from "../src/rpc/frames.ts";
import { Session } from "../src/session/session.ts";
import { type Block, isolatedClaudeEnv, modelResponse } from "./support/model-endpoint.ts";

const executable = process.env.MIMI_CLAUDE_POLICY_TEST_BIN;
const native = executable ? describe : describe.skip;
type ModelRequest = { model: string; stream: boolean; messages?: unknown[]; tools?: Array<{ name?: string }> };
/** 模型端点的一次回复：内容与可选的首字后停顿。返回 undefined 时回一句无关的 "ok"（标题等旁路请求）。 */
type Reply = { kind: string; content: Block[]; pauseMs?: number };

/** 隔离的适配器 + 本机模型端点 + 一个已附着的客户端连接。 */
async function harness(name: string, idleCloseMs: number, respond: (request: ModelRequest) => Reply | undefined) {
  const root = realpathSync(mkdtempSync(path.join(os.tmpdir(), `mimi-native-${name}-`)));
  const cwd = path.join(root, "workspace");
  const config = path.join(root, "config");
  mkdirSync(cwd);
  mkdirSync(config);
  const requests: string[] = [];
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, async fetch(request) {
    if (new URL(request.url).pathname.includes("count_tokens")) return Response.json({ input_tokens: 20 });
    const body = await request.json() as ModelRequest;
    const reply = (body.tools?.some((tool) => tool.name === "Bash") ? respond(body) : undefined) ?? { kind: "other", content: [{ type: "text", text: "ok" }] };
    requests.push(reply.kind);
    return modelResponse(body.model, reply.content, body.stream, reply.pauseMs);
  } });
  const saved = { ...process.env };
  Object.assign(process.env, isolatedClaudeEnv(config, server.port!), { MIMI_CLAUDE_LEGACY_INDEX: "" });
  const { createApp } = await import("../src/app.ts");
  const app: App = createApp({ stateDir: path.join(root, "state"), log: () => {}, claudeExecutable: () => executable!, idleCloseMs });
  const frames: OutboundFrame[] = [];
  const session = new Session(`native-${name}`);
  const { generation } = session.attach(undefined, (frame) => frames.push(frame), false);
  let nextId = 1;
  const call = async (method: string, params: Record<string, unknown>): Promise<any> => {
    const response = await app.router.dispatch({ id: nextId++, method, params }, { session, generation });
    if ("error" in response) throw Object.assign(new Error(JSON.stringify(response.error)), { data: (response.error as { data?: unknown }).data });
    return response.result;
  };
  const waitFor = async (predicate: (frame: any) => boolean, timeoutMs: number): Promise<any> => {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const found = frames.find(predicate);
      if (found) return found;
      await Bun.sleep(50);
    }
    throw new Error(`timed out; requests: ${requests.join(",")}; methods: ${frames.map((frame) => frame.method).join(",")}`);
  };
  /** 完全访问、无需审批的一轮，背景命令无需人工批准。 */
  const startTurn = async (threadId: string, prompt: string) =>
    (await call("turn/start", { threadId, input: [{ type: "text", text: prompt, text_elements: [] }], approvalPolicy: "never", sandboxPolicy: { type: "dangerFullAccess" }, model: "claude-sonnet-4-6" })).turn.id as string;
  const turnStarted = (except: string[], timeoutMs = 30_000) =>
    waitFor((frame) => frame.method === "turn/started" && !except.includes(frame.params.turn.id), timeoutMs).then((frame) => frame.params.turn.id as string);
  const turnCompleted = (turnId: string, timeoutMs = 60_000) =>
    waitFor((frame) => frame.method === "turn/completed" && frame.params.turn.id === turnId, timeoutMs).then((frame) => frame.params.turn);
  const close = async () => {
    await app.manager.closeAll();
    server.stop(true);
    for (const key of Object.keys(process.env)) if (!(key in saved)) delete process.env[key];
    Object.assign(process.env, saved);
    rmSync(root, { recursive: true, force: true });
  };
  return { cwd, app, frames, requests, call, waitFor, startTurn, turnStarted, turnCompleted, close };
}

const backgroundBash = (id: string, command: string): Block => ({ type: "tool_use", id, name: "Bash", input: { command, description: "long job", run_in_background: true } });

native("Claude Code 后台任务续写", () => {
  test("#796 后台命令长于空闲时限时照常完成，完成通知触发的续写作为新的一轮到达客户端，之后照常空闲关闭", async () => {
    const IDLE_CLOSE_MS = 2_000;
    const TASK_SECONDS = 6;
    let marker = "";
    const h = await harness("background", IDLE_CLOSE_MS, (request) => {
      const transcript = JSON.stringify(request.messages ?? []);
      // 按对话内容决定回复：完成通知 → 续写；后台命令的结果 → 本轮收尾；用户的请求 → 后台命令。
      if (transcript.includes("task-notification")) return { kind: "continuation", content: [{ type: "text", text: "background finished" }] };
      if (transcript.includes("\"tool_use_id\":\"bg\"")) return { kind: "started", content: [{ type: "text", text: "started in the background" }] };
      return { kind: "command", content: [backgroundBash("bg", `sleep ${TASK_SECONDS} && printf done > '${marker}'`)] };
    });
    marker = path.join(h.cwd, "background-done");
    try {
      const { thread } = await h.call("thread/start", { cwd: h.cwd });
      const first = await h.startTurn(thread.id, "run the long job in the background");
      expect((await h.turnCompleted(first)).status).toBe("completed");
      expect(existsSync(marker)).toBe(false);

      // 回合结束后空闲时限早已过去，命令仍在跑：进程不能被关闭。
      const continuation = await h.turnStarted([first]);
      expect(readFileSync(marker, "utf8")).toBe("done");
      expect((await h.turnCompleted(continuation)).status).toBe("completed");
      const answer = h.frames.find((frame: any) => frame.method === "item/completed" && frame.params.turnId === continuation && frame.params.item.type === "agentMessage") as any;
      expect(answer?.params.item.text).toBe("background finished");

      // 任务全部结束后照常空闲关闭，不留常驻进程。
      const runtime = h.app.manager.get(thread.id)!;
      expect(runtime.hasLiveProcess()).toBe(true);
      const deadline = Date.now() + IDLE_CLOSE_MS + 10_000;
      while (runtime.hasLiveProcess() && Date.now() < deadline) await Bun.sleep(100);
      expect(runtime.hasLiveProcess()).toBe(false);
      console.log(`原生验收通过（#796）：后台任务 ${TASK_SECONDS}s > 空闲时限 ${IDLE_CLOSE_MS}ms；请求 ${h.requests.join(",")}`);
    } finally {
      await h.close();
    }
  }, 120_000);

  test("#797 续写进行中历史与实时是同一个回合，按这个 ID 停止与补充消息都生效，收尾后历史结构与实时一致", async () => {
    const PAUSE_MS = 8_000;
    const h = await harness("continuation", 60_000, (request) => {
      // CLI 发请求前会合并相邻的同角色消息（命令结果与通知、被停止的续写后的提问），按整段对话的进度认：
      // 这一段的后台命令发过没有、通知到了几条。
      const transcript = JSON.stringify(request.messages ?? []);
      if (transcript.includes("STEER-NOW")) return { kind: "steered", content: [{ type: "text", text: "steered reply" }] };
      const [job, notified] = transcript.includes("second job") ? ["bg2", 2] : ["bg1", 1];
      if (!transcript.includes(`"id":"${job}"`)) return { kind: "command", content: [backgroundBash(job, "sleep 3")] };
      if ((transcript.match(/<task-notification>/g) ?? []).length >= notified) {
        return { kind: "continuation", content: [{ type: "text", text: "partial continuation that keeps going" }], pauseMs: PAUSE_MS };
      }
      return { kind: "started", content: [{ type: "text", text: "started" }] };
    });
    const turnIds = (turns: Array<{ id: string }>) => turns.map((turn) => turn.id);
    /** 续写停在半路时，历史报告的进行中回合必须就是实时的那个。 */
    const expectHistoryMatches = async (threadId: string, live: string[], continuation: string) => {
      await h.waitFor((frame) => frame.method === "item/agentMessage/delta" && frame.params.turnId === continuation, 30_000);
      const read = await h.call("thread/read", { threadId, includeTurns: true });
      expect(turnIds(read.thread.turns)).toEqual(live);
      expect(read.thread.turns.at(-1).status).toBe("inProgress");
      const page = await h.call("thread/turns/list", { threadId, limit: 1 });
      expect(page.data[0]).toMatchObject({ id: continuation, status: "inProgress" });
    };
    try {
      const { thread } = await h.call("thread/start", { cwd: h.cwd });
      const live: string[] = [];

      // 第一段续写：按历史里的回合 ID 停止。
      live.push(await h.startTurn(thread.id, "first job"));
      expect((await h.turnCompleted(live[0]!)).status).toBe("completed");
      const stopped = await h.turnStarted(live);
      live.push(stopped);
      await expectHistoryMatches(thread.id, live, stopped);
      expect(await h.call("turn/interrupt", { threadId: thread.id, turnId: stopped })).toEqual({});
      expect((await h.turnCompleted(stopped, 5_000)).status).toBe("interrupted");
      const afterStop = await h.call("thread/read", { threadId: thread.id, includeTurns: true });
      expect(turnIds(afterStop.thread.turns)).toEqual(live);
      expect(afterStop.thread.turns.map((turn: { status: string }) => turn.status)).toEqual(["completed", "interrupted"]);

      // 第二段续写：向历史里的回合补充消息，并入同一回合收尾。
      live.push(await h.startTurn(thread.id, "second job"));
      expect((await h.turnCompleted(live[2]!)).status).toBe("completed");
      const steered = await h.turnStarted(live);
      live.push(steered);
      await expectHistoryMatches(thread.id, live, steered);
      const steer = await h.call("turn/steer", { threadId: thread.id, expectedTurnId: steered, input: [{ type: "text", text: "STEER-NOW please", text_elements: [] }], clientUserMessageId: null });
      expect(steer).toEqual({ turnId: steered });
      expect((await h.turnCompleted(steered, 30_000)).status).toBe("completed");
      const steeredReply = h.frames.find((frame: any) => frame.method === "item/completed" && frame.params.turnId === steered && frame.params.item.text === "steered reply");
      expect(steeredReply).toBeDefined();
      const startedIds = h.frames.filter((frame: any) => frame.method === "turn/started").map((frame: any) => frame.params.turn.id);
      expect(startedIds).toEqual(live);
      console.log(`原生验收通过（#797）：续写回合 ${live.length - 2} 段；请求 ${h.requests.join(",")}`);
    } finally {
      await h.close();
    }
  }, 180_000);
});
