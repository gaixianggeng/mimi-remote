import { access, constants, lstat, readdir, stat } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

/**
 * 清理宿主可能泄漏给 `agy` 的环境变量：
 * 在 Antigravity.app 或 IDE 集成终端内启动时，`ANTIGRAVITY_*` 与 `__CFBundleIdentifier`
 * 会把 `agy` 重定向到桌面版目录（`~/.gemini/antigravity`），导致与终端 `agy` / Herdr 账本分裂。
 */
export function sanitizeAgyEnv(baseEnv: NodeJS.ProcessEnv = process.env): NodeJS.ProcessEnv {
  const clean: NodeJS.ProcessEnv = {};
  for (const [key, value] of Object.entries(baseEnv)) {
    if (value === undefined) continue;
    if (key === "__CFBundleIdentifier" || key.startsWith("ANTIGRAVITY_")) continue;
    clean[key] = value;
  }
  return clean;
}

export function defaultAgyExecutable(env: NodeJS.ProcessEnv = process.env): string {
  const configured = env.AGY_ADAPTER_AGY_BIN?.trim();
  if (configured) return configured;
  return Bun.which("agy") ?? "agy";
}

export interface AgyDataPaths {
  homeDir: string;
  geminiDirName: string;
  appDataDirName: string;
  appDataRoot: string;
  otherAppDataDirName: string;
  otherAppDataRoot: string;
}

export type AgySessionOrigin = "cli" | "other";

export function resolveAgyDataPaths(env: NodeJS.ProcessEnv = process.env): AgyDataPaths {
  const homeDir = env.HOME?.trim() || os.homedir();
  const geminiDirName = env.AGY_ADAPTER_GEMINI_DIR?.trim() || ".gemini";
  const appDataDirName = env.AGY_ADAPTER_APP_DATA_DIR?.trim() || "antigravity-cli";
  const otherAppDataDirName = env.AGY_ADAPTER_OTHER_APP_DATA_DIR?.trim() || "antigravity";
  const geminiRoot = path.isAbsolute(geminiDirName) ? geminiDirName : path.join(homeDir, geminiDirName);
  const appDataRoot = path.join(geminiRoot, appDataDirName);
  const otherAppDataRoot = path.join(geminiRoot, otherAppDataDirName);
  return { homeDir, geminiDirName, appDataDirName, appDataRoot, otherAppDataDirName, otherAppDataRoot };
}

const SAFE_SESSION_ID = /^[A-Za-z0-9._-]+$/;
const ASCII_ONLY = /^[\x00-\x7f]*$/;
const DEFAULT_IGNORABLE_RE = /\p{Default_Ignorable_Code_Point}/gu;

function candidateFoldedDbStems(name: string): string[] {
  if (ASCII_ONLY.test(name)) {
    const lower = name.toLowerCase();
    if (!lower.endsWith(".db")) return [];
    const stem = lower.slice(0, -3);
    return SAFE_SESSION_ID.test(stem) ? [stem] : [];
  }
  // 仅索引可能经 Unicode simple case-folding / NFKC / HFS+ 默认可忽略字符剥离后
  // 映射到合法 ASCII SAFE_SESSION_ID + `.db` 的条目（如 `ſ-test.db`、`K-test.db`、`s\u200b-test.db`），
  // 避免无关非 ASCII 文件名（如 `日本語.db`）对所有未命中会话触发逐条 access() 退化。
  const candidates = new Set<string>();
  const variants = [
    name.toUpperCase().toLowerCase(),
    name.normalize("NFKC").toUpperCase().toLowerCase(),
    name.replace(DEFAULT_IGNORABLE_RE, "").toUpperCase().toLowerCase(),
    name.normalize("NFKC").replace(DEFAULT_IGNORABLE_RE, "").toUpperCase().toLowerCase(),
  ];
  for (const folded of variants) {
    if (!folded.endsWith(".db")) continue;
    const stem = folded.slice(0, -3);
    if (SAFE_SESSION_ID.test(stem)) {
      candidates.add(stem);
    }
  }
  return [...candidates];
}

export function conversationDbPath(
  sessionId: string,
  env: NodeJS.ProcessEnv = process.env,
  origin: AgySessionOrigin = "cli",
): string | undefined {
  if (!SAFE_SESSION_ID.test(sessionId)) return undefined;
  const paths = resolveAgyDataPaths(env);
  const root = origin === "other" ? paths.otherAppDataRoot : paths.appDataRoot;
  return path.join(root, "conversations", `${sessionId}.db`);
}

export function appDataDirForOrigin(origin: AgySessionOrigin, env: NodeJS.ProcessEnv = process.env): string {
  const paths = resolveAgyDataPaths(env);
  return origin === "other" ? paths.otherAppDataDirName : paths.appDataDirName;
}

async function fileExists(
  targetPath: string | undefined,
  accessFn: typeof access = access,
): Promise<boolean> {
  if (!targetPath) return false;
  try {
    await accessFn(targetPath);
    return true;
  } catch {
    return false;
  }
}

async function isSameDirectoryIdentity(
  pathA: string,
  pathB: string,
  statFn: typeof stat = stat,
): Promise<boolean> {
  if (path.resolve(pathA) === path.resolve(pathB)) return true;
  try {
    // 必须使用 `{ bigint: true }` 比较 64 位 APFS inode/dev，避免 JS Number 精度舍入导致两个不同目录误判相同。
    const [statA, statB] = await Promise.all([
      statFn(pathA, { bigint: true }),
      statFn(pathB, { bigint: true }),
    ]);
    if (!statA.isDirectory() || !statB.isDirectory()) return false;
    if (
      typeof statA.dev !== "bigint"
      || typeof statB.dev !== "bigint"
      || typeof statA.ino !== "bigint"
      || typeof statB.ino !== "bigint"
    ) {
      return false;
    }
    return statA.dev === statB.dev && statA.ino === statB.ino && statA.ino !== 0n;
  } catch {
    return false;
  }
}

export async function hasCliConversationDb(sessionId: string, env: NodeJS.ProcessEnv = process.env): Promise<boolean> {
  return fileExists(conversationDbPath(sessionId, env, "cli"));
}

export type OtherConversationsProbeStatus =
  | "present"
  | "absent_or_empty"
  | "permission_denied"
  | "io_error";

export interface ProbeFsOps {
  access: typeof access;
  lstat: typeof lstat;
  readdir: typeof readdir;
  stat: typeof stat;
}

const defaultProbeFsOps: ProbeFsOps = { access, lstat, readdir, stat };

function errorCode(error: unknown): string | undefined {
  const code = (error as { code?: unknown } | null)?.code;
  return typeof code === "string" ? code : undefined;
}

function isPermissionError(code: string | undefined): boolean {
  return code === "EACCES" || code === "EPERM";
}

async function classifyMissingAncestor(
  ancestorPath: string,
  ops: ProbeFsOps,
): Promise<"absent" | "present_dir" | "permission_denied" | "io_error"> {
  try {
    const ancestorLstat = await ops.lstat(ancestorPath);
    if (ancestorLstat.isSymbolicLink()) {
      try {
        const targetStat = await ops.stat(ancestorPath);
        return targetStat.isDirectory() ? "present_dir" : "io_error";
      } catch (statError) {
        return isPermissionError(errorCode(statError)) ? "permission_denied" : "io_error";
      }
    }
    return ancestorLstat.isDirectory() ? "present_dir" : "io_error";
  } catch (ancestorError) {
    const code = errorCode(ancestorError);
    if (isPermissionError(code)) return "permission_denied";
    if (code === "ENOENT") return "absent";
    return "io_error";
  }
}

/**
 * 4 状态 fail-closed 探测独立的 Other（桌面版 / 自定义 `AGY_ADAPTER_OTHER_APP_DATA_DIR`）目录：
 * - `present`：目录可穿越且可读，且存在至少一个 `.db`；
 * - `absent_or_empty`：与 CLI 同目录、真正缺目录，或目录可读但为空/无 `.db`；
 * - `permission_denied`：`lstat` / `access(X_OK)` / `readdir` 遇到 `EACCES`/`EPERM`（含 `0111`/`0444`/`0000`）；
 * - `io_error`：`EIO`/`EMFILE`/`ENOTDIR`/`ELOOP`、非目录，以及同样返回 `ENOENT` 的悬空符号链接。
 */
export async function probeOtherConversations(
  env: NodeJS.ProcessEnv = process.env,
  ops: ProbeFsOps = defaultProbeFsOps,
): Promise<OtherConversationsProbeStatus> {
  const paths = resolveAgyDataPaths(env);
  if (await isSameDirectoryIdentity(paths.otherAppDataRoot, paths.appDataRoot, ops.stat)) {
    return "absent_or_empty";
  }
  const dir = path.join(paths.otherAppDataRoot, "conversations");

  let isSymlink = false;
  try {
    const dirLstat = await ops.lstat(dir);
    isSymlink = dirLstat.isSymbolicLink();
    if (!isSymlink && !dirLstat.isDirectory()) {
      return "io_error";
    }
  } catch (error) {
    const code = errorCode(error);
    if (isPermissionError(code)) return "permission_denied";
    if (code !== "ENOENT") return "io_error";

    // `lstat(dir)` 返回 ENOENT 时，沿祖先链一直向上检查到首个存在的祖先，
    // 防止更高层祖先存在悬空符号链接、非目录或权限错误时被误判为健康缺目录。
    let current = path.dirname(dir);
    while (true) {
      const ancestorState = await classifyMissingAncestor(current, ops);
      if (ancestorState === "permission_denied") return "permission_denied";
      if (ancestorState === "io_error") return "io_error";
      if (ancestorState === "present_dir") break;
      const parent = path.dirname(current);
      if (parent === current) break;
      current = parent;
    }
    return "absent_or_empty";
  }

  if (isSymlink) {
    try {
      const targetStat = await ops.stat(dir);
      if (!targetStat.isDirectory()) {
        return "io_error";
      }
    } catch (error) {
      const code = errorCode(error);
      if (isPermissionError(code)) return "permission_denied";
      // 悬空符号链接（stat 返回 ENOENT）、ELOOP、EIO 等均 fail-closed 判为 io_error。
      return "io_error";
    }
  }

  try {
    await ops.access(dir, constants.X_OK);
    const entries = await ops.readdir(dir);
    if (entries.some((name) => name.endsWith(".db"))) {
      return "present";
    }
    for (const name of entries) {
      for (const foldedStem of candidateFoldedDbStems(name)) {
        if (await fileExists(path.join(dir, `${foldedStem}.db`), ops.access)) {
          return "present";
        }
      }
    }
    return "absent_or_empty";
  } catch (error) {
    const code = errorCode(error);
    if (isPermissionError(code)) return "permission_denied";
    if (!isSymlink && code === "ENOENT") return "absent_or_empty";
    return "io_error";
  }
}

/**
 * 检查独立的 Other（桌面版 / 自定义 `AGY_ADAPTER_OTHER_APP_DATA_DIR`）目录下是否存在有效会话 `.db`，
 * 仅在存在时才按需查询 `otherSharedAcp` 的 `session/list`，避免无 Other 数据时多起子进程（C10）。
 */
export async function hasOtherConversations(env: NodeJS.ProcessEnv = process.env): Promise<boolean> {
  return (await probeOtherConversations(env)) === "present";
}

type DirOriginIndex =
  | { kind: "inaccessible" }
  | { kind: "fallback_access"; dir: string }
  | {
      kind: "indexed";
      dir: string;
      directDbIds: Set<string>;
      verifyAccessDbIds: Set<string>;
      caseAliasLowerIds: Set<string>;
    };

async function buildDirOriginIndex(dir: string, accessFn: typeof access = access): Promise<DirOriginIndex> {
  try {
    // 先校验目录可穿越（X_OK），确保 0444 / 0000 / 悬空目录链接与逐文件 access(path) 完全等价。
    await accessFn(dir, constants.X_OK);
  } catch {
    return { kind: "inaccessible" };
  }

  try {
    const entries = await readdir(dir, { withFileTypes: true });
    const directDbIds = new Set<string>();
    const verifyAccessDbIds = new Set<string>();
    const caseAliasLowerIds = new Set<string>();
    for (const entry of entries) {
      const foldedStems = candidateFoldedDbStems(entry.name);
      if (foldedStems.length === 0) continue;
      // 索引大小写与 Unicode 折叠/规范化后的别名（含 `abcd.db`/`upper.DB`/`ſ-test.db`/`K-test.db`），
      // 命中时由 access(path) 按底层卷规则实时核验，保持与逐文件 lookup 完全一致；
      // 无关非 ASCII 文件名（如 `日本語.db`）不会进入索引，也不触发全量 miss 回退。
      for (const foldedStem of foldedStems) {
        caseAliasLowerIds.add(foldedStem);
      }
      if (!entry.name.endsWith(".db")) continue;
      const exactStem = entry.name.slice(0, -3);
      if (!SAFE_SESSION_ID.test(exactStem)) continue;
      if (entry.isSymbolicLink()) {
        // 符号链接条目需由 access(path) 核验目标可达，避免将悬空 .db 链接误认存在。
        verifyAccessDbIds.add(exactStem);
      } else if (entry.isFile() || entry.isDirectory()) {
        directDbIds.add(exactStem);
      } else {
        verifyAccessDbIds.add(exactStem);
      }
    }
    return { kind: "indexed", dir, directDbIds, verifyAccessDbIds, caseAliasLowerIds };
  } catch {
    // 例如 0111 目录允许穿越（X_OK 成功）但禁止 readdir，回退逐文件 access(path) 保持等价。
    return { kind: "fallback_access", dir };
  }
}

async function hasIndexedConversationDb(
  index: DirOriginIndex,
  sessionId: string,
  accessFn: typeof access = access,
): Promise<boolean> {
  if (!SAFE_SESSION_ID.test(sessionId)) return false;
  if (index.kind === "inaccessible") return false;
  if (index.kind === "fallback_access") {
    return fileExists(path.join(index.dir, `${sessionId}.db`), accessFn);
  }
  if (index.directDbIds.has(sessionId)) return true;
  if (index.verifyAccessDbIds.has(sessionId)) {
    return fileExists(path.join(index.dir, `${sessionId}.db`), accessFn);
  }
  if (index.caseAliasLowerIds.has(sessionId.toLowerCase())) {
    return fileExists(path.join(index.dir, `${sessionId}.db`), accessFn);
  }
  return false;
}

/**
 * 批量识别会话来源（与逐条 `resolveSessionOrigin` 在 `0444`/`0111`/`0000`/悬空符号链接/大小写与 Unicode 折叠卷下完全等价）。
 */
export async function createBatchSessionOriginResolver(
  env: NodeJS.ProcessEnv = process.env,
  ops: Partial<Pick<ProbeFsOps, "stat" | "access">> = defaultProbeFsOps,
): Promise<(sessionId: string) => Promise<AgySessionOrigin | null>> {
  const statFn = ops.stat ?? stat;
  const accessFn = ops.access ?? access;
  const paths = resolveAgyDataPaths(env);
  const cliDir = path.join(paths.appDataRoot, "conversations");
  const otherDir = path.join(paths.otherAppDataRoot, "conversations");
  const sameRoot = await isSameDirectoryIdentity(paths.otherAppDataRoot, paths.appDataRoot, statFn);

  const [cliIndex, otherIndex] = sameRoot
    ? [await buildDirOriginIndex(cliDir, accessFn), { kind: "inaccessible" } as const]
    : await Promise.all([buildDirOriginIndex(cliDir, accessFn), buildDirOriginIndex(otherDir, accessFn)]);

  return async (sessionId: string): Promise<AgySessionOrigin | null> => {
    if (await hasIndexedConversationDb(cliIndex, sessionId, accessFn)) {
      return "cli";
    }
    if (!sameRoot && (await hasIndexedConversationDb(otherIndex, sessionId, accessFn))) {
      return "other";
    }
    return null;
  };
}

/**
 * 识别 `agy acp` `session/list` 返回的会话来源：
 * - `cli`：落盘在 `~/.gemini/antigravity-cli/conversations/<id>.db`（CLI / Herdr / Mimi 新建）；
 * - `other`：落盘在 `~/.gemini/antigravity/conversations/<id>.db`（Antigravity Desktop / IDE，通过 `--app-data-dir antigravity` 完整读取和续聊）；
 * - `null`：两边都不存在 `.db` 的孤儿摘要，忽略避免打开空白页。
 */
export async function resolveSessionOrigin(
  sessionId: string,
  env: NodeJS.ProcessEnv = process.env,
): Promise<AgySessionOrigin | null> {
  if (await fileExists(conversationDbPath(sessionId, env, "cli"))) {
    return "cli";
  }
  if (await fileExists(conversationDbPath(sessionId, env, "other"))) {
    return "other";
  }
  return null;
}
