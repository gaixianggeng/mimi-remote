// 受限档位不加载设置来源（#488），用户与项目技能、项目自定义命令改由适配器合成的本地插件加载
// （#775）。插件只含 skills/ 与 commands/，不带 hooks、MCP、agents 与设置；技能 frontmatter 里的
// hook 由 sandboxPolicy 的 disableAllHooks 关闭。实测（Claude Code 2.1.294 / 2.1.301）：这样加载后
// 技能照常展开，越界写入、出网与软链接逃逸仍被拒绝。
import { cp, mkdir, mkdtemp, readdir, readFile, rm, stat, symlink, writeFile } from "node:fs/promises";
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
 * 与 CLI 相同的项目目录：从 cwd 逐级向上直到 git 根（含 worktree 的 `.git` 文件）；不在 git 仓库里
 * 时一直到文件系统根（实测）。离 cwd 越近越靠前，同名时近的优先。
 */
async function projectDirs(cwd: string): Promise<string[]> {
  const dirs: string[] = [];
  for (let dir = path.resolve(cwd); ; dir = path.dirname(dir)) {
    dirs.push(dir);
    const parent = path.dirname(dir);
    if (parent === dir || (await stat(path.join(dir, ".git")).then(() => true, () => false))) return dirs;
  }
}

/** SKILL.md frontmatter 里的 name：写了 name 时 CLI 也接受 `/name`（实测）。 */
async function frontmatterName(file: string): Promise<string | undefined> {
  const text = await readFile(file, "utf8").catch(() => "");
  const front = /^---\r?\n([\s\S]*?)\r?\n---/.exec(text)?.[1];
  const raw = front && /^name:[ \t]*(.*)$/m.exec(front)?.[1]?.trim();
  return raw ? raw.replace(/^(["'])(.*)\1$/, "$2") : undefined;
}

/**
 * 在 parent 下生成插件目录；用户与项目都没有技能和命令时不生成。用户级优先、项目目录近的优先，
 * 与 CLI 一致（实测）。技能只收带 SKILL.md 的目录（含指向目录的软链接），条目软链接回原位置；CLI
 * 不加载 commands/ 里逐个文件的软链接（实测），命令文件按同样的优先顺序复制进来。
 */
export async function createSkillPlugin(cwd: string, userDir: string, parent = os.tmpdir()): Promise<SkillPlugin | undefined> {
  const projects = await projectDirs(cwd);
  const skills = new Map<string, string>();
  const names = new Set<string>();
  for (const base of [path.join(userDir, "skills"), ...projects.map((dir) => path.join(dir, ".claude", "skills"))]) {
    for (const folder of await readdir(base).catch(() => [] as string[])) {
      const file = path.join(base, folder, "SKILL.md");
      if (skills.has(folder) || !typeable(folder) || !(await isKind(file, "file"))) continue;
      skills.set(folder, path.join(base, folder));
      names.add(folder);
      const declared = await frontmatterName(file);
      if (declared && typeable(declared)) names.add(declared);
    }
  }
  const commandDirs: string[] = [];
  for (const commands of [path.join(userDir, "commands"), ...projects.map((dir) => path.join(dir, ".claude", "commands"))]) {
    if (!(await isKind(commands, "directory"))) continue;
    commandDirs.push(commands);
    for (const file of await readdir(commands)) {
      if (file.endsWith(".md") && typeable(file.slice(0, -3))) names.add(file.slice(0, -3));
    }
  }
  if (!skills.size && !commandDirs.length) return undefined;

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
    for (const [folder, target] of skills) await symlink(target, path.join(root, "skills", folder), linkType);
    for (const commands of commandDirs) {
      // 先复制的优先：已有的同名文件不覆盖。只复制 .md 与子目录，软链接取其内容。
      await cp(commands, path.join(root, "commands"), {
        recursive: true,
        force: false,
        errorOnExist: false,
        dereference: true,
        filter: (source) => stat(source).then((entry) => entry.isDirectory() || source.endsWith(".md"), () => false),
      });
    }
  } catch (error) {
    await dispose();
    throw error;
  }
  return { path: root, names, dispose };
}
