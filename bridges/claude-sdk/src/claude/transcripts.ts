import { open, readdir, stat } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

export function claudeConfigDir(): string {
  return process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), ".claude");
}

export interface TranscriptFile {
  sessionId: string;
  path: string;
  size: number;
  mtimeMs: number;
}

/**
 * 会话 ID → transcript 文件。SDK 不返回文件路径，而活动时间和 `Thread.path`
 * 都需要它；这里只按文件名索引，不解析目录名的编码规则。
 */
export class TranscriptIndex {
  private files = new Map<string, TranscriptFile>();
  private scannedAt = 0;
  private scanning: Promise<void> | undefined;

  constructor(
    private readonly root = () => path.join(claudeConfigDir(), "projects"),
    private readonly maxAgeMs = 1_000,
  ) {}

  async refresh(force = false): Promise<void> {
    if (!force && Date.now() - this.scannedAt < this.maxAgeMs) return;
    this.scanning ??= this.scan().finally(() => (this.scanning = undefined));
    await this.scanning;
  }

  get(sessionId: string): TranscriptFile | undefined {
    return this.files.get(sessionId);
  }

  private async scan(): Promise<void> {
    const root = this.root();
    const next = new Map<string, TranscriptFile>();
    const projects = await readdir(root, { withFileTypes: true }).catch(() => []);
    await Promise.all(
      projects
        .filter((entry) => entry.isDirectory())
        .map(async (project) => {
          const dir = path.join(root, project.name);
          const entries = await readdir(dir).catch(() => [] as string[]);
          for (const name of entries) {
            if (!name.endsWith(".jsonl")) continue;
            const file = path.join(dir, name);
            const info = await stat(file).catch(() => undefined);
            if (!info?.isFile()) continue;
            const sessionId = name.slice(0, -".jsonl".length);
            const previous = next.get(sessionId);
            // 同一会话偶尔在多个项目目录短暂共存，取最近写入的那份。
            if (!previous || info.mtimeMs > previous.mtimeMs) {
              next.set(sessionId, { sessionId, path: file, size: info.size, mtimeMs: info.mtimeMs });
            }
          }
        }),
    );
    this.files = next;
    this.scannedAt = Date.now();
  }
}

const TAIL_START_BYTES = 64 * 1024;
const TAIL_MAX_BYTES = 4 * 1024 * 1024;

/**
 * 会话的活动时间 = 最后一条对话消息的时间戳。文件修改时间不可靠：Claude 桌面端
 * 读 transcript 时会改 mtime（#653）。结果按文件大小缓存——只改 mtime 不改内容的
 * touch 不会触发重算。
 */
export class ActivityClock {
  private readonly cache = new Map<string, { size: number; activityMs: number | undefined }>();

  async lastActivityMs(file: TranscriptFile): Promise<number | undefined> {
    const cached = this.cache.get(file.path);
    if (cached && cached.size === file.size) return cached.activityMs;
    const activityMs = await readLastActivity(file.path, file.size);
    this.cache.set(file.path, { size: file.size, activityMs });
    return activityMs;
  }
}

async function readLastActivity(file: string, size: number): Promise<number | undefined> {
  const handle = await open(file, "r").catch(() => undefined);
  if (!handle) return undefined;
  try {
    let window = Math.min(TAIL_START_BYTES, size);
    while (window > 0) {
      const start = size - window;
      const buffer = Buffer.alloc(window);
      await handle.read(buffer, 0, window, start);
      const lines = buffer.toString("utf8").split("\n");
      // 窗口起点通常落在一行中间，第一段不完整，除非已经读到文件开头。
      if (start > 0) lines.shift();
      for (let index = lines.length - 1; index >= 0; index -= 1) {
        const found = conversationTimestamp(lines[index]!);
        if (found !== undefined) return found;
      }
      if (window >= size || window >= TAIL_MAX_BYTES) return undefined;
      window = Math.min(size, window * 4, TAIL_MAX_BYTES);
    }
    return undefined;
  } finally {
    await handle.close();
  }
}

function conversationTimestamp(line: string): number | undefined {
  if (!line.includes('"timestamp"') || !(line.includes('"type":"user"') || line.includes('"type":"assistant"'))) {
    return undefined;
  }
  try {
    const record = JSON.parse(line) as Record<string, unknown>;
    if (record.type !== "user" && record.type !== "assistant") return undefined;
    if (record.isSidechain === true || record.isMeta === true) return undefined;
    const ms = Date.parse(String(record.timestamp));
    return Number.isFinite(ms) ? ms : undefined;
  } catch {
    return undefined;
  }
}
