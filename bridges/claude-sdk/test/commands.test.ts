// slashCommand/list 的整理规则与缓存（#765）。常驻进程与真实 SDK 链路见 runtime.e2e.test.ts。
import { describe, expect, test } from "bun:test";
import os from "node:os";
import type { SlashCommand } from "@anthropic-ai/claude-agent-sdk";
import { CommandCatalog, catalogCommands, sdkCommandDiscovery, type DiscoverCommands } from "../src/claude/commands.ts";
import { createCommandHandlers } from "../src/handlers/commands.ts";
import { sandboxOptions, type ExecutionPolicy } from "../src/runtime/sandboxPolicy.ts";

const FULL: ExecutionPolicy = { type: "dangerFullAccess" };
const RESTRICTED: ExecutionPolicy = { type: "workspaceWrite", networkAccess: false };

const command = (name: string, extra: Partial<SlashCommand> = {}): SlashCommand => ({ name, description: `${name} command`, argumentHint: "", ...extra });

describe("catalogCommands", () => {
  test("hides terminal-only, session-managed and untypeable commands", () => {
    const entries = catalogCommands(
      [
        command("compact", { argumentHint: " <instructions> ", builtin: true }),
        command("clear", { aliases: ["reset", "new"], builtin: true }),
        command("model", { builtin: true }),
        command("effort", { builtin: true }),
        command("color", { builtin: true }),
        command("__remote-workflow", { builtin: true }),
        command("claude.ai Notion:make-page (MCP)"),
        command("usage", { aliases: ["cost", "stats", "bad alias"], builtin: true }),
        command("my-skill"),
      ],
      new Set(["color"]),
    );
    expect(entries).toEqual([
      { name: "compact", description: "compact command", argumentHint: "<instructions>", aliases: [] },
      { name: "usage", description: "usage command", argumentHint: null, aliases: ["cost", "stats"] },
      { name: "my-skill", description: "my-skill command", argumentHint: null, aliases: [] },
    ]);
  });

  test("keeps Claude Code's own row when a name is shared and shortens long descriptions", () => {
    const entries = catalogCommands(
      [command("review", { description: "project review" }), command("review", { description: "built-in review", builtin: true }), command("review", { description: "plugin review" })],
      new Set(),
    );
    expect(entries.map((entry) => entry.description)).toEqual(["built-in review"]);
    const [long] = catalogCommands([command("long", { description: `first\n\n${"x".repeat(400)}` })], new Set());
    expect(long!.description.length).toBe(300);
    expect(long!.description.startsWith("first x")).toBe(true);
    expect(long!.description.endsWith("…")).toBe(true);
  });
});

function fakeDiscovery(results: Array<SlashCommand[] | Error>) {
  const calls: Array<{ cwd: string; loadsSettings: boolean }> = [];
  const discover: DiscoverCommands = async (cwd, policy) => {
    calls.push({ cwd, loadsSettings: policy.type === "dangerFullAccess" });
    const next = results.shift() ?? [];
    if (next instanceof Error) throw next;
    return next;
  };
  return { calls, discover };
}

describe("CommandCatalog", () => {
  test("caches per workspace and settings source, and forceReload reads again", async () => {
    const { calls, discover } = fakeDiscovery([[command("a")], [command("b")], [command("c")]]);
    const catalog = new CommandCatalog({ discover, terminal: () => new Set(), log: () => {} });
    expect((await catalog.list("/repo", FULL)).map((entry) => entry.name)).toEqual(["a"]);
    expect((await catalog.list("/repo", FULL)).map((entry) => entry.name)).toEqual(["a"]);
    expect((await catalog.list("/repo", RESTRICTED)).map((entry) => entry.name)).toEqual(["b"]);
    expect((await catalog.list("/repo", { type: "readOnly", networkAccess: false })).map((entry) => entry.name)).toEqual(["b"]);
    expect((await catalog.list("/repo", FULL, true)).map((entry) => entry.name)).toEqual(["c"]);
    expect(calls).toEqual([
      { cwd: "/repo", loadsSettings: true },
      { cwd: "/repo", loadsSettings: false },
      { cwd: "/repo", loadsSettings: true },
    ]);
  });

  test("concurrent requests share one discovery", async () => {
    let release: (commands: SlashCommand[]) => void = () => {};
    let count = 0;
    const discover: DiscoverCommands = () => {
      count += 1;
      return new Promise((resolve) => (release = resolve));
    };
    const catalog = new CommandCatalog({ discover, terminal: () => new Set(), log: () => {} });
    const both = Promise.all([catalog.list("/repo", FULL), catalog.list("/repo", FULL)]);
    release([command("a")]);
    expect((await both).map((entries) => entries.length)).toEqual([1, 1]);
    expect(count).toBe(1);
  });

  test("a failure is reported as retryable and not retried during the cooldown", async () => {
    const { calls, discover } = fakeDiscovery([new Error("boom"), [command("a")]]);
    const catalog = new CommandCatalog({ discover, terminal: () => new Set(), failureCooldownMs: 60_000, log: () => {} });
    const first = await catalog.list("/repo", FULL).catch((error) => error);
    expect(first.code).toBe(-32603);
    expect(first.data).toEqual({ reason: "command_catalog_unavailable", retryable: true });
    expect((await catalog.list("/repo", FULL).catch((error) => error)).code).toBe(-32603);
    expect(calls).toHaveLength(1);
    // 用户主动刷新不受冷却限制。
    expect((await catalog.list("/repo", FULL, true)).map((entry) => entry.name)).toEqual(["a"]);
  });

  test("prefers a live process and falls back to discovery when it fails", async () => {
    const { calls, discover } = fakeDiscovery([[command("discovered")]]);
    let live: Promise<SlashCommand[]> | undefined = Promise.resolve([command("live")]);
    const catalog = new CommandCatalog({ discover, live: () => live, terminal: () => new Set(["live-terminal"]), log: () => {} });
    expect((await catalog.list("/repo", FULL)).map((entry) => entry.name)).toEqual(["live"]);
    expect(calls).toHaveLength(0);
    live = Promise.reject(new Error("closed"));
    expect((await catalog.list("/repo", FULL)).map((entry) => entry.name)).toEqual(["discovered"]);
    live = Promise.resolve([command("live"), command("live-terminal")]);
    expect((await catalog.list("/repo", FULL)).map((entry) => entry.name)).toEqual(["live"]);
  });

  test("drops the least recently used workspace beyond the limit", async () => {
    const { calls, discover } = fakeDiscovery([]);
    const catalog = new CommandCatalog({ discover, terminal: () => new Set(), maxEntries: 2, log: () => {} });
    for (const cwd of ["/a", "/b", "/c", "/a"]) await catalog.list(cwd, RESTRICTED);
    expect(calls.map((call) => call.cwd)).toEqual(["/a", "/b", "/c", "/a"]);
  });
});

describe("sdkCommandDiscovery", () => {
  // 目录要与该档位下真正跑起来的会话一致：设置来源取自运行时同一个 sandboxOptions，
  // 完全访问不传（SDK 缺省加载 user / project / local，与 CLI 相同），受限档位传 []。
  test("uses the runtime's setting sources for each execution policy", async () => {
    const seen: Array<Record<string, unknown>> = [];
    const startQuery = ((args: { options: Record<string, unknown> }) => {
      seen.push(args.options);
      return { supportedCommands: async () => [command("compact")], close: () => {} };
    }) as unknown as Parameters<typeof sdkCommandDiscovery>[1];
    const discover = sdkCommandDiscovery(() => "claude", startQuery);
    const cwd = os.tmpdir();
    for (const policy of [FULL, RESTRICTED, { type: "readOnly", networkAccess: false } as ExecutionPolicy]) {
      expect((await discover(cwd, policy, 1_000)).map((entry) => entry.name)).toEqual(["compact"]);
      const options = seen.at(-1)!;
      const runtime = await sandboxOptions(policy, cwd);
      expect("settingSources" in options).toBe("settingSources" in runtime);
      expect(options.settingSources).toEqual(runtime.settingSources);
      expect(options).toMatchObject({ cwd, tools: [], strictMcpConfig: true, persistSession: false, settings: { disableAllHooks: true } });
    }
    expect("settingSources" in seen[0]!).toBe(false);
    expect(seen[1]!.settingSources).toEqual([]);
  });
});

describe("slashCommand/list params", () => {
  test("maps the sandbox policy to the settings source and validates input", async () => {
    const { calls, discover } = fakeDiscovery([]);
    const handlers = createCommandHandlers(new CommandCatalog({ discover, terminal: () => new Set(), log: () => {} }));
    const cwd = os.tmpdir();
    await handlers.list({ cwd });
    await handlers.list({ cwd, sandboxPolicy: { type: "dangerFullAccess" } });
    await handlers.list({ cwd, sandboxPolicy: { type: "readOnly" } });
    expect(calls.map((call) => call.loadsSettings)).toEqual([false, true]);

    for (const params of [{}, { cwd: "relative" }, { cwd: `${cwd}/mimi-missing-${Date.now()}` }, { cwd, forceReload: "yes" }, { cwd, sandboxPolicy: { type: "bogus" } }]) {
      expect((await handlers.list(params).catch((error) => error)).code).toBe(-32602);
    }
  });
});
