import { access } from "node:fs/promises";
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
}

export function resolveAgyDataPaths(env: NodeJS.ProcessEnv = process.env): AgyDataPaths {
  const homeDir = env.HOME?.trim() || os.homedir();
  const geminiDirName = env.AGY_ADAPTER_GEMINI_DIR?.trim() || ".gemini";
  const appDataDirName = env.AGY_ADAPTER_APP_DATA_DIR?.trim() || "antigravity-cli";
  const geminiRoot = path.isAbsolute(geminiDirName) ? geminiDirName : path.join(homeDir, geminiDirName);
  const appDataRoot = path.join(geminiRoot, appDataDirName);
  return { homeDir, geminiDirName, appDataDirName, appDataRoot };
}

const SAFE_SESSION_ID = /^[A-Za-z0-9._-]+$/;

export function conversationDbPath(sessionId: string, env: NodeJS.ProcessEnv = process.env): string | undefined {
  if (!SAFE_SESSION_ID.test(sessionId)) return undefined;
  return path.join(resolveAgyDataPaths(env).appDataRoot, "conversations", `${sessionId}.db`);
}

/**
 * `agy acp` 的 `session/list` 会读取共享摘要，可能包含仅存在于 `Antigravity.app` 桌面端
 * （`~/.gemini/antigravity/conversations`）的会话；在 `antigravity-cli` 下 `session/load`
 * 这些会话会得到 0 条历史（D1）。只放行 CLI 数据库实际存在的会话。
 */
export async function hasCliConversationDb(sessionId: string, env: NodeJS.ProcessEnv = process.env): Promise<boolean> {
  const dbPath = conversationDbPath(sessionId, env);
  if (!dbPath) return false;
  try {
    await access(dbPath);
    return true;
  } catch {
    return false;
  }
}
