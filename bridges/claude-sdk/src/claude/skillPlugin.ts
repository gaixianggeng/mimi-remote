// 受限档位不加载设置来源（#488），用户与项目技能、项目自定义命令改由适配器合成的本地插件加载
// （#775）。插件只含 skills/ 与 commands/，条目软链接回原位置，不带 hooks、MCP、agents 与设置；
// 技能 frontmatter 里的 hook 由 sandboxPolicy 的 disableAllHooks 关闭。实测（Claude Code
// 2.1.294 / 2.1.301）：这样加载后技能照常展开，越界写入、出网与软链接逃逸仍被拒绝。
import { mkdir, mkdtemp, readdir, rm, stat, symlink, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

/** 插件名即命令前缀：`/mimi:名称` 总能展开；裸 `/名称` 只在 SKILL.md 写了 name 时才展开（实测）。 */
export const SKILL_PLUGIN_NAME = "mimi";

export interface SkillPlugin {
  path: string;
  /** 可以写成 `/名称` 的技能与命令名，发送前改写成 `/mimi:名称`。 */
  names: ReadonlySet<string>;
  dispose(): Promise<void>;
}

/** 能作为 `/名称` 输入、又不会和插件前缀混淆的名字。 */
function typeable(name: string): boolean {
  return /^[^\s/:]+$/.test(name) && !name.startsWith(".");
}

async function isKind(target: string, kind: "file" | "directory"): Promise<boolean> {
  return stat(target).then(
    (entry) => (kind === "file" ? entry.isFile() : entry.isDirectory()),
    () => false,
  );
}

/**
 * 在 parent 下生成插件目录；用户与项目都没有技能和命令时不生成。同名技能用户级优先，与 CLI
 * 一致（实测）。只收带 SKILL.md 的目录（含指向目录的软链接）。CLI 不加载 commands/ 里逐个
 * 文件的软链接（实测），所以整个命令目录软链接过去。
 */
export async function createSkillPlugin(cwd: string, userDir: string, parent = os.tmpdir()): Promise<SkillPlugin | undefined> {
  const skills = new Map<string, string>();
  for (const base of [path.join(userDir, "skills"), path.join(cwd, ".claude", "skills")]) {
    for (const name of await readdir(base).catch(() => [] as string[])) {
      if (skills.has(name) || !typeable(name)) continue;
      if (await isKind(path.join(base, name, "SKILL.md"), "file")) skills.set(name, path.join(base, name));
    }
  }
  const commandDir = path.join(cwd, ".claude", "commands");
  const commands = (await isKind(commandDir, "directory"))
    ? (await readdir(commandDir)).filter((file) => file.endsWith(".md")).map((file) => file.slice(0, -3)).filter(typeable)
    : [];
  if (!skills.size && !commands.length) return undefined;

  const root = await mkdtemp(path.join(parent, "mimi-claude-skills-"));
  const dispose = () => rm(root, { recursive: true, force: true });
  // Windows 创建目录软链接需要开发者模式；junction 不需要，且目标都是绝对路径。
  const linkType = process.platform === "win32" ? "junction" : "dir";
  try {
    await mkdir(path.join(root, ".claude-plugin"));
    await writeFile(
      path.join(root, ".claude-plugin", "plugin.json"),
      JSON.stringify({ name: SKILL_PLUGIN_NAME, description: "Mimi Remote 受限档位的用户与项目技能", version: "1.0.0" }),
    );
    await mkdir(path.join(root, "skills"));
    for (const [name, target] of skills) await symlink(target, path.join(root, "skills", name), linkType);
    if (commands.length) await symlink(commandDir, path.join(root, "commands"), linkType);
  } catch (error) {
    await dispose();
    throw error;
  }
  return { path: root, names: new Set([...skills.keys(), ...commands]), dispose };
}
