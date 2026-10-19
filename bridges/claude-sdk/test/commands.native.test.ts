// 真实 Claude Code 的命令目录发现（#765）。默认跳过；与 sandboxPolicy.native.test.ts 同一开关。
// 只读 initialize，不发消息、不调用模型；隔离配置目录，不读用户的 ~/.claude。
import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { sdkCommandDiscovery } from "../src/claude/commands.ts";

const executable = process.env.MIMI_CLAUDE_POLICY_TEST_BIN;
const native = executable ? describe : describe.skip;

native("Claude Code 命令目录发现", () => {
  test("完全访问按原名、受限档位按合成插件的 mimi: 名称列出用户与项目的命令和技能", async () => {
    const root = realpathSync(mkdtempSync(path.join(os.tmpdir(), "mimi-native-commands-")));
    const config = path.join(root, "config");
    const cwd = path.join(root, "workspace");
    mkdirSync(path.join(config, "commands"), { recursive: true });
    mkdirSync(path.join(cwd, ".claude", "commands"), { recursive: true });
    mkdirSync(path.join(cwd, ".claude", "skills", "mimi-skill-probe"), { recursive: true });
    writeFileSync(path.join(config, "commands", "mimi-user-probe.md"), "---\ndescription: user probe\n---\nuser probe\n");
    writeFileSync(path.join(cwd, ".claude", "commands", "mimi-project-probe.md"), "---\ndescription: project probe\n---\nproject probe\n");
    writeFileSync(
      path.join(cwd, ".claude", "skills", "mimi-skill-probe", "SKILL.md"),
      "---\nname: mimi-skill-probe\ndescription: skill probe\n---\nskill probe\n",
    );
    const keys = ["CLAUDE_CONFIG_DIR", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] as const;
    const saved = Object.fromEntries(keys.map((key) => [key, process.env[key]]));
    // 目录发现不请求模型；端点指向本机不存在的端口，万一请求也不会出网。
    Object.assign(process.env, { CLAUDE_CONFIG_DIR: config, ANTHROPIC_API_KEY: "test-only", ANTHROPIC_AUTH_TOKEN: "", ANTHROPIC_BASE_URL: "http://127.0.0.1:9", CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1" });
    try {
      const discover = sdkCommandDiscovery(() => executable!);
      const probes = ["mimi-user-probe", "mimi-project-probe", "mimi-skill-probe"];
      const qualified = probes.map((probe) => `mimi:${probe}`);
      const full = (await discover(cwd, { type: "dangerFullAccess" }, 30_000)).map((command) => command.name);
      expect(full).toEqual(expect.arrayContaining([...probes, "compact"]));
      for (const name of qualified) expect(full).not.toContain(name);
      // 受限档位不加载设置，经运行时同一个合成插件加载，名字与运行时改写后执行的 `/mimi:名称` 一致。
      const restricted = await discover(cwd, { type: "workspaceWrite", networkAccess: false }, 30_000);
      const names = restricted.map((command) => command.name);
      expect(names).toEqual(expect.arrayContaining([...qualified, "compact"]));
      for (const probe of probes) expect(names).not.toContain(probe);
      expect(restricted.find((command) => command.name === "mimi:mimi-skill-probe")?.aliases).toContain("mimi-skill-probe");
    } finally {
      for (const key of keys) {
        if (saved[key] === undefined) delete process.env[key];
        else process.env[key] = saved[key];
      }
      rmSync(root, { recursive: true, force: true });
    }
  }, 90_000);
});
