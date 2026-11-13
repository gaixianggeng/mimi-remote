import { open, readdir, stat } from "node:fs/promises";
import { nextFreshnessMark } from "../util/freshness.ts";
import { isInternalUserContent } from "./history.ts";
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
  /** 最近一次完成的扫描开始时的先后标记；refreshSince 按它判断索引是否足够新。 */
  private lastScanMark = 0;
  private scanning: Promise<void> | undefined;
  private scanningMark = 0;

  constructor(
    private readonly root = () => path.join(claudeConfigDir(), "projects"),
    private readonly maxAgeMs = 1_000,
  ) {}

  async refresh(force = false): Promise<void> {
    if (!force && Date.now() - this.scannedAt < this.maxAgeMs) return;
    await this.startScan();
  }

  /**
   * 保证索引包含先后标记 `since`（nextFreshnessMark）之后的目录状态：已有一次在它之后开始的扫描
   * （完成或进行中）就复用，否则等进行中的旧扫描结束后重扫一次（#912）。
   */
  async refreshSince(since: number): Promise<void> {
    if (this.lastScanMark > since) return;
    if (this.scanning && this.scanningMark < since) await this.scanning;
    if (this.lastScanMark > since) return;
    await this.startScan();
  }

  get(sessionId: string): TranscriptFile | undefined {
    return this.files.get(sessionId);
  }

  private startScan(): Promise<void> {
    if (!this.scanning) {
      const mark = nextFreshnessMark();
      this.scanningMark = mark;
      this.scanning = this.scan(mark).finally(() => (this.scanning = undefined));
    }
    return this.scanning;
  }

  private async scan(mark: number): Promise<void> {
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
    this.lastScanMark = mark;
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

const CWD_SCAN_CHUNK_BYTES = 256 * 1024;
const CWD_SCAN_MAX_BYTES = 64 * 1024 * 1024;

/**
 * 会话工作目录的兜底来源。SDK 的 `getSessionInfo` 和不带 dir 的 `listSessions` 只在
 * transcript 头部 64 KB 里找 `cwd`；首条消息带截图时那一行有几百 KB，`cwd` 排在
 * `message` 之后落到窗口外，SDK 就返回空（#722）。这里按行读到第一条带 `cwd` 的记录
 * 为止。工作目录写定后不会再变：找到就按路径常驻缓存；没找到按文件大小缓存，文件长大再读。
 */
export class WorkingDirectories {
  private readonly cache = new Map<string, { size: number; cwd: string | undefined }>();

  async firstCwd(file: TranscriptFile): Promise<string | undefined> {
    const cached = this.cache.get(file.path);
    if (cached && (cached.cwd !== undefined || cached.size === file.size)) return cached.cwd;
    const cwd = await readFirstCwd(file.path);
    this.cache.set(file.path, { size: file.size, cwd });
    return cwd;
  }
}

async function readFirstCwd(file: string): Promise<string | undefined> {
  const handle = await open(file, "r").catch(() => undefined);
  if (!handle) return undefined;
  try {
    const chunk = Buffer.alloc(CWD_SCAN_CHUNK_BYTES);
    let partial: Buffer[] = [];
    let position = 0;
    while (position < CWD_SCAN_MAX_BYTES) {
      const { bytesRead } = await handle.read(chunk, 0, chunk.length, position);
      if (bytesRead === 0) break;
      position += bytesRead;
      let rest = chunk.subarray(0, bytesRead);
      for (let newline = rest.indexOf(0x0a); newline >= 0; newline = rest.indexOf(0x0a)) {
        const found = recordCwd(Buffer.concat([...partial, rest.subarray(0, newline)]));
        if (found !== undefined) return found;
        partial = [];
        rest = rest.subarray(newline + 1);
      }
      // chunk 下一轮会被覆盖，跨块的半行必须复制出来。
      if (rest.length > 0) partial.push(Buffer.from(rest));
    }
    // 读到文件末尾时，最后一行可能没有换行符。
    return partial.length > 0 ? recordCwd(Buffer.concat(partial)) : undefined;
  } finally {
    await handle.close();
  }
}

function recordCwd(line: Buffer): string | undefined {
  // 先按字节粗筛，绝大多数记录不用解析；嵌套在工具参数里的 cwd 不算，只认顶层字段。
  if (line.indexOf('"cwd"') < 0) return undefined;
  try {
    const record = JSON.parse(line.toString("utf8")) as Record<string, unknown>;
    return typeof record.cwd === "string" && path.isAbsolute(record.cwd) ? record.cwd : undefined;
  } catch {
    return undefined;
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
    if (record.isCompactSummary === true || record.isVisibleInTranscriptOnly === true) return undefined;
    // 本地命令输出、后台任务通知等内部记录不算对话活动，否则旧会话会因 CLI 空恢复被排到前面。
    if (record.type === "user" && isInternalUserContent((record.message as { content?: unknown } | undefined)?.content)) {
      return undefined;
    }
    const ms = Date.parse(String(record.timestamp));
    return Number.isFinite(ms) ? ms : undefined;
  } catch {
    return undefined;
  }
}
