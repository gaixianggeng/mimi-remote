// 技能附件能否写成 `/名称` 交给 CLI 当命令执行。CLI 只认名字，不认附件里的 path：名字落到别的技能、
// 内置命令（compact、clear 等）或 CLI 自带技能上时，执行的就不是用户选的那个。
// 实测（Claude Code 2.1.294 / 2.1.301）：用户与项目技能会遮蔽同名的内置命令和自带技能；同名技能
// 用户级优先、离 cwd 近的项目目录优先；目录名与 frontmatter 里的 name 都能调用。
import { existsSync, readdirSync, readFileSync, realpathSync } from "node:fs";
import path from "node:path";

type SkillInput = { name: string; path: string };

/** 能作为 `/名称` 输入的名字：不含空白、`/`、插件前缀用的 `:`。 */
function typeable(name: string): boolean {
  return /^[^\s/:]+$/.test(name) && !name.startsWith(".");
}

function real(target: string): string | undefined {
  try {
    return realpathSync(target);
  } catch {
    return undefined;
  }
}

/** 与 CLI 相同的项目目录：从 cwd 逐级向上直到 git 根（含 worktree 的 `.git` 文件），不在仓库里时到文件系统根。 */
function projectDirs(cwd: string): string[] {
  const dirs: string[] = [];
  for (let dir = path.resolve(cwd); ; dir = path.dirname(dir)) {
    dirs.push(dir);
    if (path.dirname(dir) === dir || existsSync(path.join(dir, ".git"))) return dirs;
  }
}

function entries(dir: string): string[] {
  try {
    return readdirSync(dir);
  } catch {
    return [];
  }
}

function frontmatterName(file: string): string | undefined {
  let text: string;
  try {
    text = readFileSync(file, "utf8");
  } catch {
    return undefined;
  }
  const front = /^---\r?\n([\s\S]*?)\r?\n---/.exec(text)?.[1];
  const raw = front && /^name:[ \t]*(.*)$/m.exec(front)?.[1]?.trim();
  return raw ? raw.replace(/^(["'])(.*)\1$/, "$2") : undefined;
}

/**
 * 只有附件的 path 就是 CLI 加载的用户或项目技能、且这个名字在这些目录里只有它一处定义时才返回 true。
 * 不复现 CLI 的优先级：同名定义（其他技能目录、其他技能 frontmatter 里的 name、自定义命令）只要不止一处
 * 就不当命令。path 不在 CLI 加载的目录里（例如 Codex 的技能，#370）同样不当命令。插件与托管策略里的
 * 技能不核对。只适用于加载用户与项目设置的完全访问档。
 */
export function runsAsClaudeCommand(skill: SkillInput, cwd: string, configDir: string): boolean {
  const { name } = skill;
  if (!typeable(name) || path.basename(skill.path) !== "SKILL.md" || path.basename(path.dirname(skill.path)) !== name) return false;
  const selected = real(path.dirname(skill.path));
  if (!selected) return false;
  const projects = projectDirs(cwd);
  let loaded = false;
  for (const root of [path.join(configDir, "skills"), ...projects.map((dir) => path.join(dir, ".claude", "skills"))]) {
    for (const folder of entries(root)) {
      const file = path.join(root, folder, "SKILL.md");
      if (!existsSync(file)) continue;
      // 同一个技能可能经软链接出现在几处，按真实路径算作一处。
      if (real(path.join(root, folder)) === selected) {
        loaded ||= folder === name;
        continue;
      }
      if (folder === name || frontmatterName(file) === name) return false;
    }
  }
  if (!loaded) return false;
  return ![path.join(configDir, "commands"), ...projects.map((dir) => path.join(dir, ".claude", "commands"))].some((dir) =>
    existsSync(path.join(dir, `${name}.md`)),
  );
}
