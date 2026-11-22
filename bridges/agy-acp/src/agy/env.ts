import { access, readdir } from "node:fs/promises";
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

async function fileExists(targetPath: string | undefined): Promise<boolean> {
  if (!targetPath) return false;
  try {
    await access(targetPath);
    return true;
  } catch {
    return false;
  }
}

export async function hasCliConversationDb(sessionId: string, env: NodeJS.ProcessEnv = process.env): Promise<boolean> {
  return fileExists(conversationDbPath(sessionId, env, "cli"));
}

/**
 * 检查独立的 Other（桌面版 / 自定义 `AGY_ADAPTER_OTHER_APP_DATA_DIR`）目录下是否存在有效会话 `.db`，
 * 仅在存在时才按需查询 `otherSharedAcp` 的 `session/list`，避免无 Other 数据时多起子进程（C10）。
 */
export async function hasOtherConversations(env: NodeJS.ProcessEnv = process.env): Promise<boolean> {
  const paths = resolveAgyDataPaths(env);
  if (paths.otherAppDataRoot === paths.appDataRoot) return false;
  const dir = path.join(paths.otherAppDataRoot, "conversations");
  try {
    const entries = await readdir(dir);
    return entries.some((name) => name.endsWith(".db"));
  } catch {
    return false;
  }
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
