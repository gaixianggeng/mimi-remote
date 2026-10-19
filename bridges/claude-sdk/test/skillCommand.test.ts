// 技能附件的身份核对：path 必须是 CLI 加载的用户或项目技能，且这个名字只有它一处定义。
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { runsAsClaudeCommand } from "../src/claude/skillCommand.ts";

let root: string;
let repo: string;
let cwd: string;
let config: string;
beforeEach(() => {
  root = realpathSync(mkdtempSync(path.join(os.tmpdir(), "mimi-skill-command-")));
  repo = path.join(root, "repo");
  cwd = path.join(repo, "sub");
  config = path.join(root, "config");
  mkdirSync(path.join(repo, ".git"), { recursive: true });
  mkdirSync(cwd, { recursive: true });
});
afterEach(() => rmSync(root, { recursive: true, force: true }));

function skill(base: string, folder: string, name?: string): string {
  const file = path.join(base, folder, "SKILL.md");
  mkdirSync(path.dirname(file), { recursive: true });
  writeFileSync(file, `---\n${name ? `name: ${name}\n` : ""}description: test\n---\n\nbody\n`);
  return file;
}
const userSkills = () => path.join(config, "skills");
const projectSkills = (dir: string) => path.join(dir, ".claude", "skills");
const runs = (name: string, file: string) => runsAsClaudeCommand({ name, path: file }, cwd, config);

describe("CLI 加载的唯一定义才当命令", () => {
  test("用户技能、cwd 与 git 根之间各级的项目技能", () => {
    expect(runs("mine", skill(userSkills(), "mine"))).toBe(true);
    expect(runs("here", skill(projectSkills(cwd), "here"))).toBe(true);
    expect(runs("root", skill(projectSkills(repo), "root"))).toBe(true);
  });

  test("与内置命令同名的技能照常当命令（CLI 里技能遮蔽内置命令）", () => {
    expect(runs("compact", skill(userSkills(), "compact"))).toBe(true);
  });

  test("经软链接出现在两处的同一个技能算一处", () => {
    const file = skill(userSkills(), "shared");
    mkdirSync(projectSkills(cwd), { recursive: true });
    symlinkSync(path.dirname(file), path.join(projectSkills(cwd), "shared"), process.platform === "win32" ? "junction" : "dir");
    expect(runs("shared", path.join(projectSkills(cwd), "shared", "SKILL.md"))).toBe(true);
  });
});

describe("CLI 可能执行别的东西时不当命令", () => {
  test("path 不在 CLI 加载的目录里：Codex 技能、git 根之外", () => {
    expect(runs("compact", skill(path.join(root, "codex", "skills"), "compact"))).toBe(false);
    expect(runs("outside", skill(projectSkills(root), "outside"))).toBe(false);
  });

  test("名字与目录不符、不是 SKILL.md、文件不存在或名字不能当命令", () => {
    expect(runs("other", skill(userSkills(), "mine"))).toBe(false);
    expect(runs("mine", path.join(userSkills(), "mine", "README.md"))).toBe(false);
    expect(runs("ghost", path.join(userSkills(), "ghost", "SKILL.md"))).toBe(false);
    expect(runs("two words", skill(userSkills(), "two words"))).toBe(false);
  });

  test("用户与项目、项目各级之间有同名技能时两边都不当命令", () => {
    const user = skill(userSkills(), "dup");
    const project = skill(projectSkills(cwd), "dup");
    expect(runs("dup", user)).toBe(false);
    expect(runs("dup", project)).toBe(false);
    skill(projectSkills(repo), "near");
    expect(runs("near", skill(projectSkills(cwd), "near"))).toBe(false);
  });

  test("别的技能在 frontmatter 里用了这个名字", () => {
    skill(projectSkills(cwd), "other", "alias");
    expect(runs("alias", skill(userSkills(), "alias"))).toBe(false);
  });

  test("有同名的自定义命令", () => {
    const file = skill(projectSkills(cwd), "deploy");
    mkdirSync(path.join(config, "commands"), { recursive: true });
    writeFileSync(path.join(config, "commands", "deploy.md"), "deploy");
    expect(runs("deploy", file)).toBe(false);
  });
});
