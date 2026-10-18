// 受限档位的技能插件：只含 skills/ 与 commands/，技能软链接回原位置、命令复制进来（#775）。
// 查找范围与优先顺序按 Claude Code 2.1.294 / 2.1.301 实测：用户级优先，项目从 cwd 向上到 git 根，近的优先。
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { mkdir, mkdtemp, readdir, realpath, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { createSkillPlugin, SKILL_PLUGIN_NAME } from "../src/claude/skillPlugin.ts";

let root: string;
let repo: string;
let user: string;
let parent: string;
beforeEach(async () => {
  root = await realpath(await mkdtemp(path.join(os.tmpdir(), "mimi-skill-plugin-")));
  repo = path.join(root, "repo");
  user = path.join(root, "config");
  parent = path.join(root, "plugins");
  // git 根限定向上查找的范围，测试不受临时目录上级的影响。
  await Promise.all([mkdir(path.join(repo, ".git"), { recursive: true }), mkdir(user), mkdir(parent)]);
});
afterEach(() => rm(root, { recursive: true, force: true }));

async function skill(base: string, folder: string, body: string) {
  await mkdir(path.join(base, folder), { recursive: true });
  await writeFile(path.join(base, folder, "SKILL.md"), body);
}

async function command(dir: string, name: string, body: string) {
  await mkdir(dir, { recursive: true });
  await writeFile(path.join(dir, name), body);
}

describe("技能插件", () => {
  test("用户与项目都没有技能和命令时不生成目录", async () => {
    await mkdir(path.join(repo, ".claude", "skills"), { recursive: true });
    expect(await createSkillPlugin(repo, user, parent)).toBeUndefined();
    expect(await readdir(parent)).toEqual([]);
  });

  test("用户级优先，项目从 cwd 向上到 git 根、近的优先；技能链接回原位置，命令复制进来", async () => {
    const app = path.join(repo, "packages", "app");
    await skill(path.join(user, "skills"), "shared", "user");
    await skill(path.join(app, ".claude", "skills"), "shared", "app");
    await skill(path.join(app, ".claude", "skills"), "dup", "app");
    await skill(path.join(repo, ".claude", "skills"), "dup", "repo");
    await skill(path.join(repo, ".claude", "skills"), "repo-only", "repo");
    await skill(path.join(repo, "packages", ".claude", "skills"), "middle", "middle");
    // git 根之上的目录不再查找。
    await skill(path.join(root, ".claude", "skills"), "above", "above");
    // 不是技能目录、隐藏目录、名字里带冒号的条目都不收。
    await mkdir(path.join(app, ".claude", "skills", "empty"));
    await skill(path.join(app, ".claude", "skills"), ".hidden", "app");
    await skill(path.join(app, ".claude", "skills"), "a:b", "app");
    await command(path.join(user, "commands"), "mine.md", "user");
    await command(path.join(app, ".claude", "commands"), "mine.md", "app");
    await command(path.join(app, ".claude", "commands"), "deploy.md", "app");
    await command(path.join(app, ".claude", "commands"), "notes.txt", "not a command");
    await command(path.join(repo, ".claude", "commands"), "deploy.md", "repo");
    await command(path.join(repo, ".claude", "commands", "frontend"), "test.md", "nested");

    const plugin = (await createSkillPlugin(app, user, parent))!;
    try {
      expect(path.dirname(plugin.path)).toBe(parent);
      expect(JSON.parse(readFileSync(path.join(plugin.path, ".claude-plugin", "plugin.json"), "utf8")).name).toBe(SKILL_PLUGIN_NAME);
      expect((await readdir(path.join(plugin.path, "skills"))).sort()).toEqual(["dup", "middle", "repo-only", "shared"]);
      const body = (folder: string) => readFileSync(path.join(plugin.path, "skills", folder, "SKILL.md"), "utf8");
      expect([body("shared"), body("dup")]).toEqual(["user", "app"]);
      expect(realpathSync(path.join(plugin.path, "skills", "repo-only"))).toBe(path.join(repo, ".claude", "skills", "repo-only"));
      const commands = (await readdir(path.join(plugin.path, "commands"), { recursive: true })).map(String).sort();
      expect(commands).toEqual(["deploy.md", "frontend", path.join("frontend", "test.md"), "mine.md"]);
      const commandBody = (file: string) => readFileSync(path.join(plugin.path, "commands", file), "utf8");
      expect([commandBody("mine.md"), commandBody("deploy.md")]).toEqual(["user", "app"]);
      expect([...plugin.names].sort()).toEqual(["deploy", "dup", "middle", "mine", "repo-only", "shared"]);
      // 插件里没有 hooks、MCP、agents 与设置。
      expect((await readdir(plugin.path)).sort()).toEqual([".claude-plugin", "commands", "skills"]);
    } finally {
      await plugin.dispose();
    }
    expect(existsSync(plugin.path)).toBe(false);
    // 删除插件不碰原来的技能与命令。
    expect(readFileSync(path.join(repo, ".claude", "skills", "repo-only", "SKILL.md"), "utf8")).toBe("repo");
    expect(existsSync(path.join(app, ".claude", "commands", "deploy.md"))).toBe(true);
  });

  test("worktree 的 .git 文件同样是项目根；frontmatter 里的 name 也可以作为命令名", async () => {
    const worktree = path.join(repo, "worktree");
    await command(worktree, ".git", "gitdir: elsewhere");
    await skill(path.join(repo, ".claude", "skills"), "outside-worktree", "repo");
    await skill(path.join(worktree, ".claude", "skills"), "folder-name", "---\nname: \"public-name\"\ndescription: d\n---\nbody");
    const plugin = (await createSkillPlugin(worktree, user, parent))!;
    try {
      expect(await readdir(path.join(plugin.path, "skills"))).toEqual(["folder-name"]);
      expect([...plugin.names].sort()).toEqual(["folder-name", "public-name"]);
      expect(existsSync(path.join(plugin.path, "commands"))).toBe(false);
    } finally {
      await plugin.dispose();
    }
  });

  test("只有命令时同样生成，技能目录为空", async () => {
    await command(path.join(repo, ".claude", "commands"), "deploy.md", "deploy");
    const plugin = (await createSkillPlugin(repo, user, parent))!;
    try {
      expect(await readdir(path.join(plugin.path, "skills"))).toEqual([]);
      expect([...plugin.names]).toEqual(["deploy"]);
    } finally {
      await plugin.dispose();
    }
  });
});
