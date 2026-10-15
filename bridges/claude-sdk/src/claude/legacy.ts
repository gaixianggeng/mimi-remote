// 旧 Rust bridge 的会话索引：只读，用来接过 Mimi 独有的状态（归档标记与 Mimi 里的名称，#660）。
// 位置与旧 bridge 相同：Rust `directories` 的 ProjectDirs("", "", "codex") 配置目录下的
// claude-bridge/threads.json。旧索引的 threadId 就是 Claude 的会话 ID。
import { createReadStream } from "node:fs";
import { readFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import type { ClaudeSessions } from "./sdk.ts";

export interface LegacyThread {
  threadId: string;
  /** Mimi 里显示过的名称（用户改名或 agentd 自动标题）；没有时为 null。 */
  name: string | null;
  archived: boolean;
}

export function legacyIndexPath(): string | undefined {
  if (process.env.MIMI_CLAUDE_LEGACY_INDEX !== undefined) return process.env.MIMI_CLAUDE_LEGACY_INDEX || undefined;
  return legacyIndexPathFor(process.platform, process.env, os.homedir());
}

export function legacyIndexPathFor(platform: NodeJS.Platform, env: NodeJS.ProcessEnv, home: string): string {
  const pathApi = platform === "win32" ? path.win32 : path.posix;
  let configDir: string;
  if (platform === "darwin") {
    configDir = pathApi.join(home, "Library", "Application Support", "codex");
  } else if (platform === "win32") {
    configDir = pathApi.join(env.APPDATA || pathApi.join(home, "AppData", "Roaming"), "codex", "config");
  } else {
    // 与 directories 相同：XDG_CONFIG_HOME 只认绝对路径。
    const xdg = env.XDG_CONFIG_HOME && pathApi.isAbsolute(env.XDG_CONFIG_HOME) ? env.XDG_CONFIG_HOME : undefined;
    configDir = pathApi.join(xdg ?? pathApi.join(home, ".config"), "codex");
  }
  return pathApi.join(configDir, "claude-bridge", "threads.json");
}

/**
 * 旧索引的读取结果。none：没有可迁移的来源（未配置或文件不存在），可以当作迁移完成；
 * unreadable：暂时读不了或格式不对，不能当作完成，下次启动再试。
 */
export type LegacyIndex = { status: "ok"; threads: LegacyThread[] } | { status: "none" } | { status: "unreadable" };

export async function readLegacyIndex(file: string | undefined): Promise<LegacyIndex> {
  if (!file) return { status: "none" };
  let raw: string;
  try {
    raw = await readFile(file, "utf8");
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === "ENOENT" ? { status: "none" } : { status: "unreadable" };
  }
  let threads: unknown;
  try {
    threads = (JSON.parse(raw) as { threads?: unknown }).threads;
  } catch {
    return { status: "unreadable" };
  }
  if (!Array.isArray(threads)) return { status: "unreadable" };
  return {
    status: "ok",
    threads: threads.flatMap((row: Record<string, unknown> | null) => {
      if (!row || typeof row !== "object" || typeof row.threadId !== "string") return [];
      const name = typeof row.name === "string" && row.name.trim() ? row.name.trim() : null;
      return [{ threadId: row.threadId, name, archived: row.archived === true }];
    }),
  };
}

export interface NameMigrationDeps {
  threads: LegacyThread[];
  sessions: Pick<ClaudeSessions, "info" | "rename">;
  transcriptPath(sessionId: string): Promise<string | undefined>;
  /** 正被本机其他 Claude 进程持有的会话。 */
  heldElsewhere(): Promise<ReadonlySet<string>>;
}

export interface NameMigrationResult {
  renamed: number;
  /** 用户手动改过标题，保留。 */
  kept: number;
  /** 被占用或写入失败，下次启动再试。 */
  deferred: number;
}

/**
 * 旧 bridge 里 Mimi 显示的名称写成 custom-title（与 CLI `/rename` 相同，只追加一条记录），切换后
 * Mimi、CLI 与桌面端看到同一个名字。只补 Claude 侧没有标题或只有 AI 自动标题的会话；transcript
 * 里已有 custom-title（用户手动改过）的保留。已经一致或 transcript 已不在的会话跳过。
 */
export async function migrateLegacyNames(deps: NameMigrationDeps): Promise<NameMigrationResult> {
  const result: NameMigrationResult = { renamed: 0, kept: 0, deferred: 0 };
  const held = await deps.heldElsewhere();
  for (const thread of deps.threads) {
    if (!thread.name) continue;
    const info = await deps.sessions.info(thread.threadId).catch(() => undefined);
    if (!info) continue;
    const current = info.customTitle?.trim() ?? "";
    if (current === thread.name) continue;
    if (current) {
      const file = await deps.transcriptPath(thread.threadId);
      // 找不到 transcript 时无法判断标题来源，宁可保留。
      if (!file || (await hasCustomTitle(file).catch(() => true))) {
        result.kept += 1;
        continue;
      }
    }
    if (held.has(thread.threadId)) {
      result.deferred += 1;
      continue;
    }
    try {
      await deps.sessions.rename(thread.threadId, thread.name, info.cwd);
      result.renamed += 1;
    } catch {
      result.deferred += 1;
    }
  }
  return result;
}

const CUSTOM_TITLE = '"type":"custom-title"';

/** transcript 里有没有 custom-title 记录（CLI `/rename` 或 SDK renameSession 写的明确命名）。 */
export async function hasCustomTitle(file: string): Promise<boolean> {
  let tail = "";
  for await (const chunk of createReadStream(file, { encoding: "utf8" })) {
    const text = tail + (chunk as string);
    if (text.includes(CUSTOM_TITLE)) return true;
    tail = text.slice(-CUSTOM_TITLE.length);
  }
  return false;
}
