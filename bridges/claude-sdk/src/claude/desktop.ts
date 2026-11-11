// 在这台 Mac 的 Claude 桌面版里打开一条 Claude Code 会话（#726）。只用公开入口：与 CLI `/desktop`
// 相同的 `claude://resume?session=<id>` 深链，桌面版收到后自己导入 transcript。不写桌面版的私有
// 索引，也不改 transcript 的 entrypoint。检查顺序与 CLI 2.1.301 一致：`/Applications/Claude.app`
// 是否存在、Info.plist 版本是否不低于 1.1.9669，然后 `open` 深链。
import { execFile } from "node:child_process";
import { open, stat } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { compareVersions } from "./claudeCode.ts";

const execFileAsync = promisify(execFile);

/** CLI 打开 resume 深链要求的最低桌面版版本。 */
export const MINIMUM_DESKTOP_VERSION = "1.1.9669";

/**
 * 桌面版导入时只在 transcript 末尾这么多字节里找 custom-title（桌面版 2.37337 的读取窗口），
 * 找不到就显示 Untitled；它不读 Claude 自动生成的 ai-title。
 */
export const DESKTOP_TITLE_WINDOW_BYTES = 256 * 1024;

const CUSTOM_TITLE = '"type":"custom-title"';

export interface DesktopApp {
  path: string;
  /** Info.plist 的 CFBundleShortVersionString；读不到时为 null，与 CLI 一样不拦。 */
  version: string | null;
}

export type OpenResult = { ok: true } | { ok: false; detail: string };

export interface DesktopSystem {
  platform: NodeJS.Platform;
  findApp(): Promise<DesktopApp | undefined>;
  openURL(url: string): Promise<OpenResult>;
  /** transcript 末尾的读取窗口里是否已有 custom-title。 */
  tailHasCustomTitle(file: string): Promise<boolean>;
}

export function resumeDeepLink(sessionId: string): string {
  return `claude://resume?session=${encodeURIComponent(sessionId)}`;
}

/** 版本号取前三段数字比较；无法解析时返回 undefined，调用方按"不拦"处理。 */
export function desktopVersionSupported(version: string): boolean | undefined {
  const match = /^(\d+)\.(\d+)\.(\d+)/.exec(version.trim());
  if (!match) return undefined;
  return compareVersions(`${match[1]}.${match[2]}.${match[3]}`, MINIMUM_DESKTOP_VERSION) >= 0;
}

/** 与 CLI 相同只认 `/Applications`，另加用户自己的 `~/Applications`。 */
function candidateAppPaths(): string[] {
  return ["/Applications/Claude.app", path.join(os.homedir(), "Applications", "Claude.app")];
}

async function isDirectory(target: string): Promise<boolean> {
  try {
    return (await stat(target)).isDirectory();
  } catch {
    return false;
  }
}

async function readBundleVersion(appPath: string): Promise<string | null> {
  try {
    const { stdout } = await execFileAsync(
      "defaults",
      ["read", path.join(appPath, "Contents", "Info.plist"), "CFBundleShortVersionString"],
      { timeout: 5_000 },
    );
    return stdout.trim() || null;
  } catch {
    return null;
  }
}

async function findDesktopApp(): Promise<DesktopApp | undefined> {
  for (const appPath of candidateAppPaths()) {
    if (await isDirectory(appPath)) return { path: appPath, version: await readBundleVersion(appPath) };
  }
  return undefined;
}

async function openDeepLink(url: string): Promise<OpenResult> {
  try {
    await execFileAsync("open", [url], { timeout: 10_000 });
    return { ok: true };
  } catch (error) {
    const failure = error as NodeJS.ErrnoException & { stderr?: string; killed?: boolean };
    if (failure.killed) return { ok: false, detail: "open timed out" };
    const detail = (failure.stderr ?? "").trim() || failure.message;
    return { ok: false, detail: detail.replace(/\s+/g, " ").slice(0, 200) };
  }
}

/**
 * 只看桌面版会读的那段末尾。窗口起点落在某一行中间时，那一行桌面版解析不了，跳过它，
 * 避免把半行 custom-title 当成已有标题。
 */
export async function tailHasCustomTitle(file: string, windowBytes = DESKTOP_TITLE_WINDOW_BYTES): Promise<boolean> {
  const handle = await open(file, "r");
  try {
    const { size } = await handle.stat();
    const start = Math.max(0, size - windowBytes);
    const buffer = Buffer.alloc(size - start);
    await handle.read(buffer, 0, buffer.length, start);
    let text = buffer.toString("utf8");
    if (start > 0) {
      const newline = text.indexOf("\n");
      text = newline < 0 ? "" : text.slice(newline + 1);
    }
    return text.includes(CUSTOM_TITLE);
  } finally {
    await handle.close();
  }
}

export const systemDesktop: DesktopSystem = {
  platform: process.platform,
  findApp: findDesktopApp,
  openURL: openDeepLink,
  tailHasCustomTitle,
};
