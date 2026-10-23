// 真实 SDK + 指定 CLI + 本机脚本化模型端点。默认跳过，不调用付费模型或使用用户配置。
import { describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { query } from "@anthropic-ai/claude-agent-sdk";
import { createSkillPlugin } from "../src/claude/skillPlugin.ts";
import { executionPolicyFor, sandboxOptions } from "../src/runtime/sandboxPolicy.ts";
import { qualifySkillCommand } from "../src/runtime/userInput.ts";
import { type Block, isolatedClaudeEnv, modelResponse as response } from "./support/model-endpoint.ts";

const executable = process.env.MIMI_CLAUDE_POLICY_TEST_BIN;
const native = executable ? describe : describe.skip;

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
      // 受限档位经合成插件加载技能（#775）：项目技能自带一个写到根外的命令 hook，必须不执行。
      mkdirSync(path.join(cwd, ".claude", "skills", "native-probe"), { recursive: true });
      writeFileSync(path.join(cwd, ".claude", "skills", "native-probe", "SKILL.md"), `---\ndescription: native probe skill listing\nhooks:\n  PreToolUse:\n    - matcher: "*"\n      hooks:\n        - type: command\n          command: "printf bad > ${path.join(root, "skill-hook-outside")}"\n---\nNATIVE_SKILL_BODY args=[$ARGUMENTS]\n`);
      mkdirSync(path.join(config, "skills", "native-user"), { recursive: true });
      writeFileSync(path.join(config, "skills", "native-user", "SKILL.md"), "---\ndescription: native user skill\n---\nuser\n");
      const plugin = (await createSkillPlugin(cwd, config, root))!;
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
      let first = "";
      let slashCommands: string[] = [];
      let results: Array<{ tool_use_id: string; content: unknown }> = [];
      const server = Bun.serve({ hostname: "127.0.0.1", port: 0, async fetch(request) {
        const body = await request.json() as { model: string; stream: boolean; messages?: Array<{ content: unknown }> };
        if (new URL(request.url).pathname.includes("count_tokens")) return Response.json({ input_tokens: 20 });
        if (calls === 0) first = JSON.stringify(body);
        results = (body.messages ?? []).flatMap((message) => Array.isArray(message.content) ? message.content.filter((block) => block.type === "tool_result") : []);
        return response(body.model, calls++ === 0 ? probes : [{ type: "text", text: "done" }], body.stream);
      } });
      let run: ReturnType<typeof query> | undefined;
      const timer = setTimeout(() => run?.close(), 55_000);
      try {
        const options = await sandboxOptions(executionPolicyFor({ type, writableRoots: [cwd], networkAccess: false }), cwd, process.platform, plugin.path);
        const prompt = qualifySkillCommand("/native-probe native-args", plugin.names);
        expect(prompt).toBe("/mimi:native-probe native-args");
        run = query({ prompt: prompt as string, options: {
          ...options, cwd, pathToClaudeCodeExecutable: executable!, model: "claude-sonnet-4-6", maxTurns: 3,
          // 有意用 default 和全部同意，证明拒绝不依赖 plan 或人工拒绝。
          permissionMode: "default", canUseTool: async (_name, input) => ({ behavior: "allow", updatedInput: input }),
          env: { ...process.env, ...isolatedClaudeEnv(config, server.port!), CLAUDE_BRIDGE_SANDBOX_POLICY: mode },
        } });
        let finished = false;
        for await (const message of run) {
          if (message.type === "system" && message.subtype === "init") slashCommands = message.slash_commands;
          if (message.type === "result") { expect(message.subtype).toBe("success"); finished = true; }
        }
        expect(finished).toBe(true);
        expect(results).toHaveLength(probes.length);
        for (const name of ["shell-outside", "write-outside", "write-symlink", "write-dangling", "skill-hook-outside"]) expect(existsSync(path.join(root, name))).toBe(false);
        // 技能展开、参数进入 $ARGUMENTS；用户级技能同样加载；模型看不到技能列表。
        expect(first).toContain("NATIVE_SKILL_BODY args=[native-args]");
        expect(slashCommands).toEqual(expect.arrayContaining(["mimi:native-probe", "mimi:native-user"]));
        expect(first).not.toContain("native probe skill listing");
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
