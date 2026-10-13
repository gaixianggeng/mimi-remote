// 真实 SDK + 指定 CLI + 本机脚本化模型端点。默认跳过，不调用付费模型或使用用户配置。
import { describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { query } from "@anthropic-ai/claude-agent-sdk";
import { executionPolicyFor, sandboxOptions } from "../src/runtime/sandboxPolicy.ts";

const executable = process.env.MIMI_CLAUDE_POLICY_TEST_BIN;
const native = executable ? describe : describe.skip;
type Block = { type: string; id?: string; name?: string; input?: Record<string, unknown>; text?: string };

function response(model: string, content: Block[], stream: boolean): Response {
  const message = { id: "msg_policy", type: "message", role: "assistant", model, content, stop_reason: content[0]?.type === "tool_use" ? "tool_use" : "end_turn", stop_sequence: null, usage: { input_tokens: 10, output_tokens: 10 } };
  if (!stream) return Response.json(message);
  const events: [string, unknown][] = [["message_start", { type: "message_start", message: { ...message, content: [], stop_reason: null, usage: { input_tokens: 10, output_tokens: 0 } } }]];
  content.forEach((block, index) => {
    events.push(["content_block_start", { type: "content_block_start", index, content_block: block.type === "tool_use" ? { ...block, input: {} } : { ...block, text: "" } }]);
    events.push(["content_block_delta", { type: "content_block_delta", index, delta: block.type === "tool_use" ? { type: "input_json_delta", partial_json: JSON.stringify(block.input) } : { type: "text_delta", text: block.text } }]);
    events.push(["content_block_stop", { type: "content_block_stop", index }]);
  });
  events.push(["message_delta", { type: "message_delta", delta: { stop_reason: message.stop_reason, stop_sequence: null }, usage: { output_tokens: 10 } }], ["message_stop", { type: "message_stop" }]);
  return new Response(events.map(([event, data]) => `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`).join(""), { headers: { "content-type": "text/event-stream" } });
}

native("Claude Code 原生边界验收", () => {
  for (const mode of ["guarded", "inherit"]) for (const type of ["workspaceWrite", "readOnly"]) {
    test(`${mode}: ${type} 文件与网络拒绝`, async () => {
      const version = execFileSync(executable!, ["--version"], { encoding: "utf8" }).trim();
      expect(version).toContain("2.1.294");
      const root = realpathSync(mkdtempSync(path.join(os.tmpdir(), "mimi-native-policy-")));
      const cwd = path.join(root, "workspace");
      const config = path.join(root, "config");
      mkdirSync(cwd); mkdirSync(config);
      symlinkSync(root, path.join(cwd, "escape"), "dir");
      symlinkSync(path.join(root, "write-dangling"), path.join(cwd, "dangling"), "file");
      // 本机配置即使放开外写、命令脱离沙箱和出网，也不能扩大本次请求的声明。
      const loose = { sandbox: { enabled: false, excludedCommands: ["*"], filesystem: { allowWrite: [root] }, network: { allowedDomains: ["*"] } }, permissions: { allow: ["Bash(*)", "Write(*)", "WebFetch(*)"] } };
      writeFileSync(path.join(config, "settings.json"), JSON.stringify(loose));
      mkdirSync(path.join(cwd, ".claude"));
      writeFileSync(path.join(cwd, ".claude", "settings.json"), JSON.stringify(loose));
      const quote = (value: string) => `'${value.replace(/'/g, `'\\''`)}'`;
      const probes: Block[] = [
        { type: "tool_use", id: "shell", name: "Bash", input: { command: `printf ok > ${quote(path.join(cwd, "shell-inside"))}; printf bad > ${quote(path.join(root, "shell-outside"))}; curl -sS --max-time 3 https://example.com`, dangerouslyDisableSandbox: true } },
        { type: "tool_use", id: "write_inside", name: "Write", input: { file_path: path.join(cwd, "write-inside"), content: "ok" } },
        { type: "tool_use", id: "write_outside", name: "Write", input: { file_path: path.join(root, "write-outside"), content: "bad" } },
        { type: "tool_use", id: "write_symlink", name: "Write", input: { file_path: path.join(cwd, "escape", "write-symlink"), content: "bad" } },
        { type: "tool_use", id: "write_dangling", name: "Write", input: { file_path: path.join(cwd, "dangling"), content: "bad" } },
        { type: "tool_use", id: "web", name: "WebFetch", input: { url: "https://example.com", prompt: "read page" } },
      ];
      let calls = 0;
      let results: Array<{ tool_use_id: string; content: unknown }> = [];
      const server = Bun.serve({ hostname: "127.0.0.1", port: 0, async fetch(request) {
        const body = await request.json() as { model: string; stream: boolean; messages?: Array<{ content: unknown }> };
        if (new URL(request.url).pathname.includes("count_tokens")) return Response.json({ input_tokens: 20 });
        results = (body.messages ?? []).flatMap((message) => Array.isArray(message.content) ? message.content.filter((block) => block.type === "tool_result") : []);
        return response(body.model, calls++ === 0 ? probes : [{ type: "text", text: "done" }], body.stream);
      } });
      let run: ReturnType<typeof query> | undefined;
      const timer = setTimeout(() => run?.close(), 55_000);
      try {
        const options = await sandboxOptions(executionPolicyFor({ type, writableRoots: [cwd], networkAccess: false }), cwd);
        run = query({ prompt: "execute the probes", options: {
          ...options, cwd, pathToClaudeCodeExecutable: executable!, model: "claude-sonnet-4-6", maxTurns: 3,
          // 有意用 default 和全部同意，证明拒绝不依赖 plan 或人工拒绝。
          permissionMode: "default", canUseTool: async (_name, input) => ({ behavior: "allow", updatedInput: input }),
          env: { ...process.env, CLAUDE_CONFIG_DIR: config, CLAUDE_BRIDGE_SANDBOX_POLICY: mode, ANTHROPIC_API_KEY: "test-only", ANTHROPIC_AUTH_TOKEN: "", ANTHROPIC_BASE_URL: `http://127.0.0.1:${server.port}`, CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1" },
        } });
        let finished = false;
        for await (const message of run) if (message.type === "result") { expect(message.subtype).toBe("success"); finished = true; }
        expect(finished).toBe(true);
        expect(results).toHaveLength(probes.length);
        for (const name of ["shell-outside", "write-outside", "write-symlink", "write-dangling"]) expect(existsSync(path.join(root, name))).toBe(false);
        for (const name of ["shell-inside", "write-inside"]) expect(existsSync(path.join(cwd, name))).toBe(type === "workspaceWrite");
        expect(JSON.stringify(results.find((result) => result.tool_use_id === "shell"))).toContain("403");
        expect(JSON.stringify(results.find((result) => result.tool_use_id === "web"))).toContain("networkAccess=false");
        expect(readFileSync(path.join(config, "settings.json"), "utf8")).toBe(JSON.stringify(loose));
        console.log(`原生验收通过：${version}; ${mode}; ${type}`);
      } finally {
        clearTimeout(timer); run?.close(); server.stop(true); rmSync(root, { recursive: true, force: true });
      }
    }, 60_000);
  }
});
