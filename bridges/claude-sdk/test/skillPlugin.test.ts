// 受限档位的技能插件：只含 skills/ 与 commands/ 两个目录，条目软链接回原位置（#775）。
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { mkdir, mkdtemp, readdir, realpath, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { createSkillPlugin, SKILL_PLUGIN_NAME } from "../src/claude/skillPlugin.ts";

let root: string;
let cwd: string;
let user: string;
let parent: string;
beforeEach(async () => {
  root = await realpath(await mkdtemp(path.join(os.tmpdir(), "mimi-skill-plugin-")));
  cwd = path.join(root, "workspace");
  user = path.join(root, "config");
  parent = path.join(root, "plugins");
  await Promise.all([mkdir(cwd), mkdir(user), mkdir(parent)]);
});
afterEach(() => rm(root, { recursive: true, force: true }));

async function skill(base: string, name: string, body: string) {
  await mkdir(path.join(base, name), { recursive: true });
  await writeFile(path.join(base, name, "SKILL.md"), body);
}

describe("技能插件", () => {
  test("用户与项目都没有技能和命令时不生成目录", async () => {
    await mkdir(path.join(cwd, ".claude", "skills"), { recursive: true });
    expect(await createSkillPlugin(cwd, user, parent)).toBeUndefined();
    expect(await readdir(parent)).toEqual([]);
  });

  test("合并用户与项目技能，同名时用户级优先，命令目录整个链接，名字可用于改写", async () => {
    const projectSkills = path.join(cwd, ".claude", "skills");
    await skill(path.join(user, "skills"), "shared", "user");
    await skill(path.join(user, "skills"), "mine", "user");
    await skill(projectSkills, "shared", "project");
    await skill(projectSkills, "local", "project");
    // 不是技能目录、隐藏目录、名字里带冒号的条目都不收。
    await mkdir(path.join(projectSkills, "empty"));
    await skill(projectSkills, ".hidden", "project");
    await skill(projectSkills, "a:b", "project");
    await mkdir(path.join(cwd, ".claude", "commands"));
    await writeFile(path.join(cwd, ".claude", "commands", "deploy.md"), "deploy");
    await writeFile(path.join(cwd, ".claude", "commands", "notes.txt"), "not a command");

    const plugin = (await createSkillPlugin(cwd, user, parent))!;
    try {
      expect(path.dirname(plugin.path)).toBe(parent);
      expect(JSON.parse(readFileSync(path.join(plugin.path, ".claude-plugin", "plugin.json"), "utf8")).name).toBe(SKILL_PLUGIN_NAME);
      expect((await readdir(path.join(plugin.path, "skills"))).sort()).toEqual(["local", "mine", "shared"]);
      expect(readFileSync(path.join(plugin.path, "skills", "shared", "SKILL.md"), "utf8")).toBe("user");
      expect(realpathSync(path.join(plugin.path, "skills", "local"))).toBe(path.join(projectSkills, "local"));
      expect(realpathSync(path.join(plugin.path, "commands"))).toBe(path.join(cwd, ".claude", "commands"));
      expect([...plugin.names].sort()).toEqual(["deploy", "local", "mine", "shared"]);
      // 插件里没有 hooks、MCP、agents 与设置。
      expect((await readdir(plugin.path)).sort()).toEqual([".claude-plugin", "commands", "skills"]);
    } finally {
      await plugin.dispose();
    }
    expect(existsSync(plugin.path)).toBe(false);
    // 删除插件不碰原来的技能与命令。
    expect(readFileSync(path.join(projectSkills, "local", "SKILL.md"), "utf8")).toBe("project");
    expect(existsSync(path.join(cwd, ".claude", "commands", "deploy.md"))).toBe(true);
  });

  test("只有命令时同样生成，技能目录为空", async () => {
    await mkdir(path.join(cwd, ".claude", "commands"), { recursive: true });
    await writeFile(path.join(cwd, ".claude", "commands", "deploy.md"), "deploy");
    const plugin = (await createSkillPlugin(cwd, user, parent))!;
    try {
      expect(await readdir(path.join(plugin.path, "skills"))).toEqual([]);
      expect([...plugin.names]).toEqual(["deploy"]);
    } finally {
      await plugin.dispose();
    }
  });
});
