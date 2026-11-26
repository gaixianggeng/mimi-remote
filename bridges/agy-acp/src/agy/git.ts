import { execFile } from "node:child_process";
import { realpath, stat } from "node:fs/promises";
import path from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const utf8FatalDecoder = new TextDecoder("utf-8", { fatal: true });

async function exactDirectoryExists(dir: string): Promise<boolean> {
  if (!dir) return false;
  try {
    const info = await stat(dir);
    return info.isDirectory();
  } catch {
    return false;
  }
}

export async function directoryExists(dir: string): Promise<boolean> {
  return exactDirectoryExists(dir.trim());
}

function decodePercentEncodedSegment(segment: string): { value: string; unsafe: boolean } {
  if (!/%[0-9A-Fa-f]{2}/.test(segment)) {
    return { value: segment, unsafe: false };
  }
  const decoded = segment.replace(/(?:%[0-9A-Fa-f]{2})+/g, (run) => {
    const bytes = new Uint8Array(run.length / 3);
    for (let i = 0; i < bytes.length; i += 1) {
      bytes[i] = Number.parseInt(run.slice(i * 3 + 1, i * 3 + 3), 16);
    }
    try {
      return utf8FatalDecoder.decode(bytes);
    } catch {
      return run;
    }
  });
  // 安全边界：单次按段解码绝不允许引入路径分隔符、NUL 字节或伪装 "." / ".." 穿越段（B23 round5）。
  if (
    decoded.includes("/")
    || decoded.includes("\\")
    || decoded.includes("\0")
    || ((decoded === "." || decoded === "..") && segment !== "." && segment !== "..")
  ) {
    return { value: segment, unsafe: true };
  }
  return { value: decoded, unsafe: false };
}

/**
 * 尝试对来自 `agy` 原生索引的百分号编码路径（或本地 `file://` URI）执行最多一次安全按段解码。
 * 若解码企图引入 `/`, `\`, `\0` 或伪装的 `.`/`..` 路径穿越段，返回 `undefined` 拒绝解码。
 */
export function decodePercentEncodedPath(rawPath: string): string | undefined {
  let candidate = rawPath.trim();
  if (!candidate) return undefined;
  let fromFileUrl = false;
  if (/^file:\/\//i.test(candidate)) {
    fromFileUrl = true;
    const withoutScheme = candidate.slice("file://".length);
    if (withoutScheme.startsWith("/")) {
      candidate = withoutScheme;
    } else if (/^localhost\//i.test(withoutScheme)) {
      candidate = withoutScheme.slice("localhost".length);
    } else {
      return undefined;
    }
  }
  const parts = candidate.split("/");
  let changed = fromFileUrl;
  const decodedParts: string[] = [];
  for (const part of parts) {
    const res = decodePercentEncodedSegment(part);
    if (res.unsafe) return undefined;
    if (res.value !== part) changed = true;
    decodedParts.push(res.value);
  }
  if (!changed) return undefined;
  return decodedParts.join("/");
}

/**
 * 规范化来自原生 `agy` `session/list` 索引的 `cwd`（B23 round5）：
 * 1) 若原始字面路径在磁盘上本身就存在（例如真实命名为 `foo%20bar` 或 `100% done` 的目录），原样保留不解码；
 * 2) 否则尝试最多一次安全按段百分号解码（含本地 `file://` URI），若解码后目录存在则采用真实路径；
 * 3) 两者皆不存在（目录真实移动/删除）时优先贴合 fallbackCwd（overlay/内存路径），否则采用安全解码路径以便匹配项目范围。
 */
export async function normalizeNativeCwd(rawPath: string, fallbackCwd?: string): Promise<string> {
  const trimmed = rawPath.trim();
  if (!trimmed) return "";
  const isFileUrl = /^file:\/\//i.test(trimmed);
  if (!isFileUrl && (await directoryExists(trimmed))) {
    return trimmed;
  }
  const decoded = decodePercentEncodedPath(trimmed);
  if (!decoded) {
    return trimmed;
  }
  if (await directoryExists(decoded)) {
    return decoded;
  }
  const cleanFallback = fallbackCwd?.trim();
  if (cleanFallback) {
    const normFallback = cleanFallback.replace(/\/+$/, "");
    if (normFallback === trimmed.replace(/\/+$/, "")) return trimmed;
    if (normFallback === decoded.replace(/\/+$/, "")) return decoded;
  }
  return decoded;
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

export const MAX_CONCURRENT_GIT_INSPECT = 4;

export interface GitDirectoryInfo {
  canonicalDir: string;
  repoKey: string;
  branch: string | null;
}

export interface GitRepoIndexOptions {
  ttlMs?: number;
  maxConcurrent?: number;
  runGitRevParse?: (canonicalDir: string) => Promise<string>;
}

async function defaultRunGitRevParse(canonicalDir: string): Promise<string> {
  const { stdout } = await execFileAsync(
    "git",
    ["-C", canonicalDir, "rev-parse", "--path-format=absolute", "--git-common-dir", "--abbrev-ref", "HEAD"],
    { timeout: 3_000 },
  );
  return stdout;
}

interface GitCacheEntry {
  expiresAt: number;
  info: GitDirectoryInfo;
}

/**
 * 解析目录所属的 Git common-dir 与当前分支，供 `thread/list({ cwd })` 把同一仓库下所有
 * Worktree 的会话归并展示（与 Claude SDK 和 Codex 的仓库分组语义一致）。
 */
export class GitRepoIndex {
  private readonly cache = new Map<string, GitCacheEntry>();
  private readonly inflight = new Map<string, Promise<GitDirectoryInfo>>();
  private readonly canonicalInflight = new Map<string, Promise<GitCacheEntry>>();
  private readonly ttlMs: number;
  private readonly maxConcurrent: number;
  private readonly runGitRevParse: (canonicalDir: string) => Promise<string>;
  private activeInspects = 0;
  private readonly waiters: Array<() => void> = [];

  constructor(ttlMsOrOptions: number | GitRepoIndexOptions = 30_000) {
    if (typeof ttlMsOrOptions === "number") {
      this.ttlMs = ttlMsOrOptions;
      this.maxConcurrent = MAX_CONCURRENT_GIT_INSPECT;
      this.runGitRevParse = defaultRunGitRevParse;
    } else {
      this.ttlMs = ttlMsOrOptions.ttlMs ?? 30_000;
      this.maxConcurrent = Math.max(1, ttlMsOrOptions.maxConcurrent ?? MAX_CONCURRENT_GIT_INSPECT);
      this.runGitRevParse = ttlMsOrOptions.runGitRevParse ?? defaultRunGitRevParse;
    }
  }

  private async withInspectSlot<T>(fn: () => Promise<T>): Promise<T> {
    if (this.activeInspects < this.maxConcurrent) {
      this.activeInspects += 1;
    } else {
      await new Promise<void>((resolve) => {
        this.waiters.push(resolve);
      });
    }
    try {
      return await fn();
    } finally {
      const next = this.waiters.shift();
      if (next) {
        next();
      } else {
        this.activeInspects -= 1;
      }
    }
  }

  private inspectCanonical(canonicalDir: string): Promise<GitCacheEntry> {
    const cached = this.cache.get(canonicalDir);
    if (cached && cached.expiresAt > Date.now()) {
      return Promise.resolve(cached);
    }
    const existing = this.canonicalInflight.get(canonicalDir);
    if (existing) {
      return existing;
    }

    const work = (async (): Promise<GitCacheEntry> => {
      let repoKey = canonicalDir;
      let branch: string | null = null;
      // 对 realpath 返回的精确规范路径直接 stat，不剥离合法的前导/尾部空白字符。
      if (await exactDirectoryExists(canonicalDir)) {
        try {
          const stdout = await this.withInspectSlot(() => this.runGitRevParse(canonicalDir));
          const lines = stdout.split(/\r?\n/).filter((line) => line.length > 0);
          if (lines[0]) {
            repoKey = await realpath(lines[0]).catch(() => path.resolve(lines[0]!));
          }
          const rawBranch = lines[1]?.trim();
          if (rawBranch && rawBranch !== "HEAD") {
            branch = rawBranch;
          }
        } catch {
          // 非 Git 目录或命令失败时退回规范化路径匹配。
        }
      }
      const info: GitDirectoryInfo = { canonicalDir, repoKey, branch };
      const entry: GitCacheEntry = { expiresAt: Date.now() + this.ttlMs, info };
      this.cache.set(canonicalDir, entry);
      return entry;
    })().finally(() => {
      if (this.canonicalInflight.get(canonicalDir) === work) {
        this.canonicalInflight.delete(canonicalDir);
      }
    });

    this.canonicalInflight.set(canonicalDir, work);
    return work;
  }

  async inspect(dir: string): Promise<GitDirectoryInfo> {
    const trimmed = dir.trim();
    if (!trimmed) {
      return { canonicalDir: "", repoKey: "", branch: null };
    }
    const cached = this.cache.get(trimmed);
    if (cached && cached.expiresAt > Date.now()) {
      return cached.info;
    }
    const existing = this.inflight.get(trimmed);
    if (existing) {
      return existing;
    }

    const work = (async (): Promise<GitDirectoryInfo> => {
      const canonicalDir = await canonicalPathPreservingMissing(trimmed);
      const entry = await this.inspectCanonical(canonicalDir);
      // 别名缓存沿用规范条目的剩余过期时间，避免新遇到的 symlink 把旧结果 TTL 续命近两倍。
      if (trimmed !== canonicalDir) {
        this.cache.set(trimmed, { expiresAt: entry.expiresAt, info: entry.info });
      }
      return entry.info;
    })().finally(() => {
      if (this.inflight.get(trimmed) === work) {
        this.inflight.delete(trimmed);
      }
    });

    this.inflight.set(trimmed, work);
    return work;
  }

  async matchesAnyRoot(sessionCwd: string, filterDirs: readonly string[]): Promise<boolean> {
    if (!sessionCwd.trim()) return false;
    const [sessionInfo, ...rootInfos] = await Promise.all([
      this.inspect(sessionCwd),
      ...filterDirs.map((dir) => this.inspect(dir)),
    ]);
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
