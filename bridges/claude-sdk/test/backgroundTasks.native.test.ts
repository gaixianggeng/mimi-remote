// 真实 Claude Code + 本机脚本化模型端点：后台命令跑得比空闲时限久，仍照常完成并触发续写（#796）。
// 默认跳过，与 sandboxPolicy.native.test.ts 同一开关；隔离配置目录，不调用付费模型、不读 ~/.claude。
import { describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import type { OutboundFrame } from "../src/rpc/frames.ts";
import { Session } from "../src/session/session.ts";
import { isolatedClaudeEnv, modelResponse } from "./support/model-endpoint.ts";

const executable = process.env.MIMI_CLAUDE_POLICY_TEST_BIN;
const native = executable ? describe : describe.skip;
const IDLE_CLOSE_MS = 2_000;
const TASK_SECONDS = 6;

native("Claude Code 后台任务与空闲关闭", () => {
  test("后台命令长于空闲时限时照常完成，完成通知触发的续写作为新的一轮到达客户端，之后照常空闲关闭", async () => {
    const root = realpathSync(mkdtempSync(path.join(os.tmpdir(), "mimi-native-background-")));
    const cwd = path.join(root, "workspace");
    const config = path.join(root, "config");
    mkdirSync(cwd);
    mkdirSync(config);
    const marker = path.join(cwd, "background-done");
    const requests: string[] = [];
    const server = Bun.serve({ hostname: "127.0.0.1", port: 0, async fetch(request) {
      if (new URL(request.url).pathname.includes("count_tokens")) return Response.json({ input_tokens: 20 });
      const body = await request.json() as { model: string; stream: boolean; messages?: unknown[]; tools?: Array<{ name?: string }> };
      const transcript = JSON.stringify(body.messages ?? []);
      // 按对话内容决定回复：完成通知 → 续写；后台命令的结果 → 本轮收尾；用户的请求 → 后台命令。
      const [kind, content] = transcript.includes("task-notification")
        ? ["continuation", [{ type: "text", text: "background finished" }]]
        : transcript.includes("\"tool_use_id\":\"bg\"")
          ? ["started", [{ type: "text", text: "started in the background" }]]
          : body.tools?.some((tool) => tool.name === "Bash")
            ? ["command", [{ type: "tool_use", id: "bg", name: "Bash", input: { command: `sleep ${TASK_SECONDS} && printf done > '${marker}'`, description: "long job", run_in_background: true } }]]
            : ["other", [{ type: "text", text: "ok" }]];
      requests.push(kind as string);
      return modelResponse(body.model, content as never, body.stream);
    } });
    const saved = { ...process.env };
    Object.assign(process.env, isolatedClaudeEnv(config, server.port!), { MIMI_CLAUDE_LEGACY_INDEX: "" });
    const { createApp } = await import("../src/app.ts");
    const app = createApp({ stateDir: path.join(root, "state"), log: () => {}, claudeExecutable: () => executable!, idleCloseMs: IDLE_CLOSE_MS });
    const frames: OutboundFrame[] = [];
    const session = new Session("native-background");
    const { generation } = session.attach(undefined, (frame) => frames.push(frame), false);
    let nextId = 1;
    const call = async (method: string, params: Record<string, unknown>): Promise<any> => {
      const response = await app.router.dispatch({ id: nextId++, method, params }, { session, generation });
      if ("error" in response) throw new Error(JSON.stringify(response.error));
      return response.result;
    };
    const waitFor = async (predicate: (frame: any) => boolean, timeoutMs: number) => {
      const deadline = Date.now() + timeoutMs;
      while (Date.now() < deadline) {
        const found = frames.find(predicate);
        if (found) return found as any;
        await Bun.sleep(50);
      }
      throw new Error(`timed out; requests: ${requests.join(",")}; methods: ${frames.map((frame) => frame.method).join(",")}`);
    };
    try {
      const { thread } = await call("thread/start", { cwd });
      const { turn } = await call("turn/start", {
        threadId: thread.id,
        input: [{ type: "text", text: "run the long job in the background", text_elements: [] }],
        approvalPolicy: "never",
        sandboxPolicy: { type: "dangerFullAccess" },
        model: "claude-sonnet-4-6",
      });
      const first = await waitFor((frame) => frame.method === "turn/completed" && frame.params.turn.id === turn.id, 60_000);
      expect(first.params.turn.status).toBe("completed");
      expect(existsSync(marker)).toBe(false);

      // 回合结束后空闲时限早已过去，命令仍在跑：进程不能被关闭。
      const continuationStarted = await waitFor((frame) => frame.method === "turn/started" && frame.params.turn.id !== turn.id, 30_000);
      expect(readFileSync(marker, "utf8")).toBe("done");
      const continuation = continuationStarted.params.turn.id;
      const completed = await waitFor((frame) => frame.method === "turn/completed" && frame.params.turn.id === continuation, 60_000);
      expect(completed.params.turn.status).toBe("completed");
      const answer = frames.find((frame: any) => frame.method === "item/completed" && frame.params.turnId === continuation && frame.params.item.type === "agentMessage") as any;
      expect(answer?.params.item.text).toBe("background finished");
      expect(requests.filter((kind) => kind === "continuation").length).toBeGreaterThanOrEqual(1);

      // 任务全部结束后照常空闲关闭，不留常驻进程。
      const runtime = app.manager.get(thread.id)!;
      expect(runtime.hasLiveProcess()).toBe(true);
      const deadline = Date.now() + IDLE_CLOSE_MS + 10_000;
      while (runtime.hasLiveProcess() && Date.now() < deadline) await Bun.sleep(100);
      expect(runtime.hasLiveProcess()).toBe(false);
      console.log(`原生验收通过：后台任务 ${TASK_SECONDS}s > 空闲时限 ${IDLE_CLOSE_MS}ms；请求 ${requests.join(",")}`);
    } finally {
      await app.manager.closeAll();
      server.stop(true);
      for (const key of Object.keys(process.env)) if (!(key in saved)) delete process.env[key];
      Object.assign(process.env, saved);
      rmSync(root, { recursive: true, force: true });
    }
  }, 120_000);
});
