import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { existsSync } from "node:fs";
import { link, mkdir, mkdtemp, realpath, rm, symlink, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import type { Options, Query, SDKMessage, SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";
import type { UserInput } from "../src/protocol/codex/v2/UserInput.ts";
import { executionPolicyFor, sandboxOptions } from "../src/runtime/sandboxPolicy.ts";
import { runSettingsFor } from "../src/runtime/settings.ts";
import { ThreadRuntime, type RuntimeHost } from "../src/runtime/threadRuntime.ts";

let root: string;
let cwd: string;
beforeAll(async () => {
  root = await realpath(await mkdtemp(path.join(os.tmpdir(), "mimi-policy-")));
  cwd = path.join(root, "workspace");
  await mkdir(cwd);
  await mkdir(path.join(root, "outside"));
  await writeFile(path.join(root, "outside", "existing"), "original");
  await symlink(path.join(root, "outside"), path.join(cwd, "link"), "dir");
  await symlink(path.join(root, "outside", "missing"), path.join(cwd, "dangling"), "file");
  await link(path.join(root, "outside", "existing"), path.join(cwd, "hardlink"));
});
afterAll(() => rm(root, { recursive: true, force: true }));

async function decision(options: Partial<Options>, tool_name: string, tool_input: unknown) {
  const hook = options.hooks!.PreToolUse![0]!.hooks[0]!;
  const result: any = await hook({ hook_event_name: "PreToolUse", tool_name, tool_input, tool_use_id: "tool", session_id: "test", transcript_path: "", cwd }, "tool", { signal: new AbortController().signal });
  return result.hookSpecificOutput?.permissionDecision;
}

const workspace = () => executionPolicyFor({ type: "workspaceWrite", writableRoots: [cwd], networkAccess: false });

describe("执行策略", () => {
  test("缺省与两种协议拼写保留严格边界，错误参数拒绝", () => {
    expect(executionPolicyFor(undefined)).toEqual({ type: "workspaceWrite", networkAccess: false });
    expect(executionPolicyFor("read-only")).toEqual({ type: "readOnly", networkAccess: false });
    expect(executionPolicyFor("danger-full-access")).toEqual({ type: "dangerFullAccess" });
    for (const raw of [{ type: "externalSandbox" }, { type: "workspaceWrite", networkAccess: "false" }, { type: "workspaceWrite", writableRoots: ["relative"] }, { type: "workspaceWrite", writableRoots: ["/tmp/*"] }, { type: "workspaceWrite", excludeSlashTmp: true }, { type: "workspaceWrite", excludeTmpdirEnvVar: true }]) {
      expect(() => executionPolicyFor(raw)).toThrow();
    }
    // App 按协议总会带上两个临时目录开关；显式为 false 时照常接受。
    expect(executionPolicyFor({ type: "workspaceWrite", networkAccess: false, excludeTmpdirEnvVar: false, excludeSlashTmp: false })).toEqual({ type: "workspaceWrite", networkAccess: false });
  });

  test("Bash 显式设置可写根、禁止出网、禁止脱离沙箱，不加载会扩大边界的本机配置", async () => {
    const options = await sandboxOptions(workspace(), cwd, "darwin");
    expect(options.settingSources).toEqual([]);
    expect(options.strictMcpConfig).toBe(true);
    expect(options.sandbox).toMatchObject({ enabled: true, failIfUnavailable: true, allowUnsandboxedCommands: false, excludedCommands: [], filesystem: { allowWrite: [cwd], denyWrite: [], disabled: false }, network: { allowedDomains: [], deniedDomains: ["*"], strictAllowlist: true, allowAllUnixSockets: false } });
    expect(await decision(options, "Bash", { command: "echo ok" })).toBeUndefined();
    expect(await decision(options, "WebFetch", { url: "https://example.com" })).toBe("deny");
    expect(await decision(options, "WebSearch", { query: "query" })).toBe("deny");
    expect(await decision(options, "mcp__server__write", {})).toBe("deny");
    expect(await decision(options, "mcp__ccd_turn__wrap_up", {})).toBeUndefined();
    expect(await decision(options, "mcp__ccd_session__start_session", {})).toBeUndefined();
    expect(await decision(options, "mcp__ccd_session__start_session_extra", {})).toBe("deny");
    expect(await decision(options, "Agent", {})).toBe("deny");
    // 技能只供用户主动调用：模型看不到技能列表，Skill 工具被拒；技能与插件里的命令 hook 不执行。
    expect(options.skills).toEqual([]);
    expect(options.settings).toEqual({ disableAllHooks: true });
    expect(options.plugins).toBeUndefined();
    expect(await decision(options, "Skill", { skill: "review" })).toBe("deny");
  });

  test("用户与项目技能经合成插件加载，不读插件里的 MCP；原生 Windows 不执行技能内联命令", async () => {
    const options = await sandboxOptions(workspace(), cwd, "darwin", "/plugins/mimi");
    expect(options.plugins).toEqual([{ type: "local", path: "/plugins/mimi", skipMcpDiscovery: true }]);
    expect(options.settingSources).toEqual([]);
    const windows = await sandboxOptions(executionPolicyFor("read-only"), cwd, "win32", "/plugins/mimi");
    expect(windows.settings).toEqual({ disableAllHooks: true, disableSkillShellExecution: true });
  });

  test("文件工具允许根内新文件，拒绝穿越、兄弟目录和软链接外写", async () => {
    const options = await sandboxOptions(workspace(), cwd, "darwin");
    for (const name of ["Write", "Edit", "NotebookEdit"]) {
      const field = name === "NotebookEdit" ? "notebook_path" : "file_path";
      expect(await decision(options, name, { [field]: "nested/new-file" })).toBeUndefined();
      for (const target of ["../outside/existing", "link/existing", "link/new-file", "dangling", "hardlink", `${cwd}-sibling/new-file`]) {
        expect(await decision(options, name, { [field]: target })).toBe("deny");
      }
      expect(await decision(options, name, {})).toBe("deny");
    }
  });

  test("readOnly 同时拒绝 Bash 写入和原生文件工具，不依赖 plan", async () => {
    const options = await sandboxOptions(executionPolicyFor("read-only"), cwd);
    expect(options.sandbox?.filesystem?.denyWrite).toEqual(["/"]);
    for (const name of ["Write", "Edit", "NotebookEdit"]) expect(await decision(options, name, { file_path: path.join(cwd, "file") })).toBe("deny");
    expect(await decision(options, "Read", { file_path: path.join(cwd, "file") })).toBeUndefined();
  });

  test("可写根未包含 cwd 或不存在时 fail closed", async () => {
    await expect(sandboxOptions(executionPolicyFor({ type: "workspaceWrite", writableRoots: [] }), cwd)).rejects.toThrow("cwd");
    await expect(sandboxOptions(executionPolicyFor({ type: "workspaceWrite", writableRoots: [path.join(root, "missing")] }), cwd)).rejects.toThrow();
  });

  test("原生 Windows 保留文件边界，拒绝无沙箱 shell", async () => {
    const options = await sandboxOptions(workspace(), cwd, "win32");
    expect(options.disallowedTools).toEqual(["Bash", "PowerShell", "Monitor"]);
    expect(options.sandbox?.enabled).toBe(false);
    expect(await decision(options, "Bash", { command: "echo test" })).toBe("deny");
    expect(await decision(options, "Write", { file_path: "file" })).toBeUndefined();
    expect(await decision(options, "Write", { file_path: "../outside/file" })).toBe("deny");
  });

  test("完全访问不改变原有执行选项与 bypass 映射", async () => {
    expect(await sandboxOptions(executionPolicyFor("danger-full-access"), cwd)).toEqual({});
    expect(runSettingsFor({ sandbox: "danger-full-access", approvalPolicy: "never" }).permissionMode).toBe("bypassPermissions");
    expect(runSettingsFor({ approvalPolicy: "never" }).permissionMode).toBe("default");
  });
});

/** 最小 Query 双向流：验证真实运行时是否在下一条输入前切换执行边界。 */
function runtimeHarness() {
  const calls: Options[] = [];
  const sent: unknown[] = [];
  const completed: string[] = [];
  let closed = 0;
  const host: RuntimeHost = {
    publish: (_id, method, params) => { if (method === "turn/completed") completed.push((params.turn as { id: string }).id); },
    request: async () => ({ decision: "acceptWithPermissionUpdate" }),
    claudeExecutable: () => "unused",
    log: () => {}, ownPids: new Set(), processReady: () => {}, turnFinished: () => {}, idleCloseMs: 60_000,
    startQuery: ({ prompt, options }) => {
      calls.push(options!);
      const input = prompt as AsyncIterable<SDKUserMessage> & { close(): void };
      return {
        async *[Symbol.asyncIterator]() {
          for await (const message of input) {
            sent.push(message.message.content);
            yield { type: "result", subtype: "success", user_message_uuids: [message.uuid], usage: {} } as unknown as SDKMessage;
          }
        },
        initializationResult: async () => ({}),
        close: () => { closed++; input.close(); },
        setModel: async () => {}, setPermissionMode: async () => {}, applyFlagSettings: async () => {},
      } as unknown as Query;
    },
  };
  return { host, calls, sent, completed, closed: () => closed };
}

async function complete(runtime: ThreadRuntime, harness: ReturnType<typeof runtimeHarness>, settings = {}, input: UserInput[] = [{ type: "text", text: "test", text_elements: [] }]) {
  const turn = await runtime.startTurn({ input, clientUserMessageId: null, settings });
  for (let attempt = 0; attempt < 100 && !harness.completed.includes(turn.id); attempt++) await Bun.sleep(1);
  expect(harness.completed).toContain(turn.id);
}

test("跨 turn 继承边界，同权限模式的根/网络改变也重启，回到受限模式重新加锁", async () => {
  const harness = runtimeHarness();
  const runtime = new ThreadRuntime("test", cwd, harness.host, runSettingsFor({ sandboxPolicy: { type: "workspaceWrite", writableRoots: [cwd] } }), false);
  try {
    await complete(runtime, harness);
    await complete(runtime, harness, { model: "test-model" });
    expect(harness.calls).toHaveLength(1);
    await complete(runtime, harness, { executionPolicy: executionPolicyFor({ type: "workspaceWrite", writableRoots: [cwd], networkAccess: true }) });
    expect(harness.calls).toHaveLength(2);
    expect(harness.calls[1]!.sandbox?.network?.allowedDomains).toEqual(["*"]);
    await complete(runtime, harness, runSettingsFor({ sandbox: "danger-full-access", approvalPolicy: "never" }));
    expect(harness.calls[2]!.sandbox).toBeUndefined();
    await complete(runtime, harness, runSettingsFor({ sandbox: "read-only" }));
    expect(harness.calls[3]!.sandbox?.filesystem?.denyWrite).toEqual(["/"]);
    expect(harness.closed()).toBe(3);
  } finally {
    await runtime.close();
  }
});


test("无效边界不会污染下一轮继承的设置", async () => {
  const harness = runtimeHarness();
  const initial = runSettingsFor({ sandboxPolicy: { type: "workspaceWrite", writableRoots: [cwd] } });
  const runtime = new ThreadRuntime("invalid", cwd, harness.host, initial, false);
  try {
    await complete(runtime, harness);
    await expect(runtime.startTurn({ input: [{ type: "text", text: "test", text_elements: [] }], clientUserMessageId: null, settings: { executionPolicy: executionPolicyFor({ type: "workspaceWrite", writableRoots: [] }) } })).rejects.toThrow("cwd");
    expect(runtime.currentSettings).toEqual(initial);
    await complete(runtime, harness);
    expect(harness.calls.at(-1)!.sandbox?.filesystem?.allowWrite).toEqual([cwd]);
  } finally {
    await runtime.close();
  }
});

test("受限档位提前合成插件里的技能并改写成插件前缀，插件外的技能不提前；完全访问不用插件，进程退出后删除插件目录", async () => {
  const workspaceWithSkills = path.join(root, "skills-workspace");
  // git 根限定技能查找范围，不受临时目录上级的影响。
  await mkdir(path.join(workspaceWithSkills, ".git"), { recursive: true });
  const skillFile = path.join(workspaceWithSkills, ".claude", "skills", "probe-review", "SKILL.md");
  await mkdir(path.dirname(skillFile), { recursive: true });
  await writeFile(skillFile, "review");
  // 不在 Claude Code 查找范围里的技能（例如 Codex 的技能，#370）。
  const foreignFile = path.join(root, "codex-skills", "probe-foreign", "SKILL.md");
  await mkdir(path.dirname(foreignFile), { recursive: true });
  await writeFile(foreignFile, "foreign");
  const harness = runtimeHarness();
  const restricted = runSettingsFor({ sandboxPolicy: { type: "workspaceWrite", writableRoots: [workspaceWithSkills] } });
  const runtime = new ThreadRuntime("skills", workspaceWithSkills, harness.host, restricted, false);
  const body: UserInput = { type: "text", text: "看看这次改动", text_elements: [] };
  const skillInput: UserInput[] = [body, { type: "skill", name: "probe-review", path: skillFile }];
  try {
    await complete(runtime, harness, {}, skillInput);
    const plugin = harness.calls[0]!.plugins![0]!;
    expect(plugin).toMatchObject({ type: "local", skipMcpDiscovery: true });
    expect(existsSync(path.join(plugin.path, "skills", "probe-review", "SKILL.md"))).toBe(true);
    expect(harness.sent[0]).toBe("/mimi:probe-review\n看看这次改动");
    await complete(runtime, harness, {}, [body, { type: "skill", name: "probe-foreign", path: foreignFile }]);
    expect(harness.sent[1]).toBe("看看这次改动\n/probe-foreign");
    // 内置命令与普通文本不改写。
    await complete(runtime, harness, {}, [{ type: "text", text: "/compact", text_elements: [] }]);
    expect(harness.sent[2]).toBe("/compact");

    await complete(runtime, harness, runSettingsFor({ sandbox: "danger-full-access", approvalPolicy: "never" }), skillInput);
    expect(harness.calls[1]!.plugins).toBeUndefined();
    expect(harness.sent[3]).toBe("/probe-review\n看看这次改动");
    expect(existsSync(plugin.path)).toBe(false);
  } finally {
    await runtime.close();
  }

  // 插件没能生成时，提前的技能照样带前缀：CLI 找不到就按原文交给模型，不会落到同名的内置命令上。
  const failing = runtimeHarness();
  const fallback = new ThreadRuntime("skills-fallback", workspaceWithSkills, failing.host, restricted, false);
  // os.tmpdir() 在 macOS / Linux 读 TMPDIR，在 Windows 读 TEMP / TMP。
  const saved = Object.fromEntries(["TMPDIR", "TEMP", "TMP"].map((key) => [key, process.env[key]]));
  for (const key of Object.keys(saved)) process.env[key] = path.join(root, "missing-tmp");
  try {
    await complete(fallback, failing, {}, skillInput);
    expect(failing.calls[0]!.plugins).toBeUndefined();
    expect(failing.sent[0]).toBe("/mimi:probe-review\n看看这次改动");
  } finally {
    for (const [key, value] of Object.entries(saved)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
    await fallback.close();
  }
});
