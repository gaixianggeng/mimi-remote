import { readFile, readdir, stat } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

/**
 * Claude 桌面版保存会话元数据的目录。只有 macOS 上核实过格式，其他平台不读。
 * 测试和排查可以用环境变量改到别处。
 */
export function desktopSessionsDir(): string | undefined {
  const configured = process.env.MIMI_CLAUDE_DESKTOP_SESSIONS_DIR?.trim();
  if (configured) return configured;
  // 桌面版的会话对应默认的 ~/.claude。改了 CLAUDE_CONFIG_DIR 时两边的会话对不上，
  // 测试沙箱也靠这条不去读真实的桌面数据。
  if (process.env.CLAUDE_CONFIG_DIR) return undefined;
  if (process.platform !== "darwin") return undefined;
  return path.join(os.homedir(), "Library", "Application Support", "Claude", "claude-code-sessions");
}

interface DesktopSessionMeta {
  /** 桌面版自己的会话 ID（`local_…`）。 */
  localId: string;
  /** 对应的 Claude Code 会话 ID，也就是适配器的线程 ID。 */
  cliSessionId: string;
  /** 由哪个桌面会话派生（`spawnedFrom.sessionId`，同样是 `local_…`）。 */
  spawnedFromLocalId: string | undefined;
}

interface CachedFile {
  mtimeMs: number;
  size: number;
  meta: DesktopSessionMeta | undefined;
}

const MAX_FILE_BYTES = 4 * 1024 * 1024;

/**
 * Claude 桌面版"主会话派生会话"的关系：子会话线程 ID → 父会话线程 ID。
 *
 * 这是桌面版未公开的私有文件格式，可能随升级变化。所以只读三个字段，任何文件
 * 读不了或字段缺失都当作没有派生关系，列表退回平铺；其余内容（MCP 配置等）不外传。
 * 单个文件可达几百 KB，按 mtime + size 缓存，只重新解析变化过的文件。
 */
export class DesktopSpawnIndex {
  private readonly files = new Map<string, CachedFile>();
  private parents = new Map<string, string>();
  private scannedAt = 0;
  private scanning: Promise<void> | undefined;

  constructor(
    private readonly root: () => string | undefined = desktopSessionsDir,
    private readonly maxAgeMs = 1_000,
  ) {}

  async refresh(force = false): Promise<void> {
    if (!force && Date.now() - this.scannedAt < this.maxAgeMs) return;
    this.scanning ??= this.scan().finally(() => (this.scanning = undefined));
    await this.scanning;
  }

  parentOf(threadId: string): string | undefined {
    return this.parents.get(threadId);
  }

  private async scan(): Promise<void> {
    const root = this.root();
    const metas: DesktopSessionMeta[] = [];
    const seen = new Set<string>();
    if (root) {
      // 目录结构是 <账号>/<组织>/local_*.json，固定两层，不递归扫描整棵树。
      for (const account of await subdirectories(root)) {
        for (const org of await subdirectories(account)) {
          const names = await readdir(org).catch(() => [] as string[]);
          await Promise.all(
            names
              .filter((name) => name.startsWith("local_") && name.endsWith(".json"))
              .map(async (name) => {
                const file = path.join(org, name);
                seen.add(file);
                const meta = await this.read(file);
                if (meta) metas.push(meta);
              }),
          );
        }
      }
    }
    for (const file of this.files.keys()) if (!seen.has(file)) this.files.delete(file);

    const cliByLocal = new Map(metas.map((meta) => [meta.localId, meta.cliSessionId]));
    const next = new Map<string, string>();
    for (const meta of metas) {
      if (!meta.spawnedFromLocalId) continue;
      const parent = cliByLocal.get(meta.spawnedFromLocalId);
      if (parent && parent !== meta.cliSessionId) next.set(meta.cliSessionId, parent);
    }
    this.parents = next;
    this.scannedAt = Date.now();
  }

  private async read(file: string): Promise<DesktopSessionMeta | undefined> {
    const info = await stat(file).catch(() => undefined);
    if (!info?.isFile() || info.size > MAX_FILE_BYTES) return undefined;
    const cached = this.files.get(file);
    if (cached && cached.mtimeMs === info.mtimeMs && cached.size === info.size) return cached.meta;
    const raw = await readFile(file, "utf8").catch(() => undefined);
    const meta = raw === undefined ? undefined : parseMeta(raw);
    this.files.set(file, { mtimeMs: info.mtimeMs, size: info.size, meta });
    return meta;
  }
}

async function subdirectories(dir: string): Promise<string[]> {
  const entries = await readdir(dir, { withFileTypes: true }).catch(() => []);
  return entries.filter((entry) => entry.isDirectory()).map((entry) => path.join(dir, entry.name));
}

function parseMeta(raw: string): DesktopSessionMeta | undefined {
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    // 桌面版写到一半时可能读到不完整的 JSON，下次 mtime 变化会重读。
    return undefined;
  }
  if (!value || typeof value !== "object") return undefined;
  const record = value as Record<string, unknown>;
  const localId = text(record.sessionId);
  const cliSessionId = text(record.cliSessionId);
  if (!localId || !cliSessionId) return undefined;
  const spawnedFrom = record.spawnedFrom;
  const spawnedFromLocalId =
    spawnedFrom && typeof spawnedFrom === "object" ? text((spawnedFrom as Record<string, unknown>).sessionId) : undefined;
  return { localId, cliSessionId, spawnedFromLocalId };
}

function text(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() !== "" && value.trim() === value ? value : undefined;
}
