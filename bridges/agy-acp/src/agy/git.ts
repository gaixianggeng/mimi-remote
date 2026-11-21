import { execFile } from "node:child_process";
import { realpath, stat } from "node:fs/promises";
import path from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export async function directoryExists(dir: string): Promise<boolean> {
  const trimmed = dir.trim();
  if (!trimmed) return false;
  try {
    const info = await stat(trimmed);
    return info.isDirectory();
  } catch {
    return false;
  }
}

/**
 * 对已移动或删除的目录，沿父目录向上找到最近存在的祖先再做 `realpath` 并拼回尾段，
 * 避免 macOS 上 `/var/...` 与 `/private/var/...` 失配导致历史会话从过滤列表消失（C14/C15）。
 */
export async function canonicalPathPreservingMissing(dir: string): Promise<string> {
  const resolved = path.resolve(dir);
  try {
    return await realpath(resolved);
  } catch {
    const tail: string[] = [];
    let current = resolved;
    while (true) {
      const parent = path.dirname(current);
      if (parent === current) return resolved;
      tail.unshift(path.basename(current));
      current = parent;
      try {
        const realAncestor = await realpath(current);
        return path.join(realAncestor, ...tail);
      } catch {
        // 继续向上找最近存在的祖先目录。
      }
    }
  }
}

export interface GitDirectoryInfo {
  canonicalDir: string;
  repoKey: string;
  branch: string | null;
}

/**
 * 解析目录所属的 Git common-dir 与当前分支，供 `thread/list({ cwd })` 把同一仓库下所有
 * Worktree 的会话归并展示（与 Claude SDK 和 Codex 的仓库分组语义一致）。
 */
export class GitRepoIndex {
  private readonly cache = new Map<string, { expiresAt: number; info: GitDirectoryInfo }>();

  constructor(private readonly ttlMs = 30_000) {}

  async inspect(dir: string): Promise<GitDirectoryInfo> {
    const trimmed = dir.trim();
    if (!trimmed) {
      return { canonicalDir: "", repoKey: "", branch: null };
    }
    const now = Date.now();
    const cached = this.cache.get(trimmed);
    if (cached && cached.expiresAt > now) {
      return cached.info;
    }
    const canonicalDir = await canonicalPathPreservingMissing(trimmed);
    let repoKey = canonicalDir;
    let branch: string | null = null;
    try {
      const { stdout } = await execFileAsync(
        "git",
        ["-C", canonicalDir, "rev-parse", "--path-format=absolute", "--git-common-dir", "--abbrev-ref", "HEAD"],
        { timeout: 3_000 },
      );
      const lines = stdout
        .split(/\r?\n/)
        .map((line) => line.trim())
        .filter(Boolean);
      if (lines[0]) {
        repoKey = await realpath(lines[0]).catch(() => path.resolve(lines[0]!));
      }
      if (lines[1] && lines[1] !== "HEAD") {
        branch = lines[1];
      }
    } catch {
      // 非 Git 目录或目录已删除时退回规范化路径匹配。
    }
    const info: GitDirectoryInfo = { canonicalDir, repoKey, branch };
    this.cache.set(trimmed, { expiresAt: now + this.ttlMs, info });
    return info;
  }

  async matchesAnyRoot(sessionCwd: string, filterDirs: readonly string[]): Promise<boolean> {
    if (!sessionCwd.trim()) return false;
    const sessionInfo = await this.inspect(sessionCwd);
    const rootInfos = await Promise.all(filterDirs.map((dir) => this.inspect(dir)));
    for (const root of rootInfos) {
      if (!root.canonicalDir) continue;
      if (sessionInfo.repoKey && sessionInfo.repoKey === root.repoKey) {
        return true;
      }
      const rel = path.relative(root.canonicalDir, sessionInfo.canonicalDir);
      if (rel === "" || (!rel.startsWith(`..${path.sep}`) && rel !== ".." && !path.isAbsolute(rel))) {
        return true;
      }
    }
    return false;
  }
}
