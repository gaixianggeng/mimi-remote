import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import path from "node:path";

interface OverlayEntry {
  customTitle?: string;
  preview?: string;
  createdAt?: number;
  updatedAt?: number;
  cwd?: string;
  archived?: boolean;
}

interface OverlayData {
  version: 1;
  sessions: Record<string, OverlayEntry>;
}

/**
 * Mimi 本地的轻量元数据覆盖层（存放在 `stateDir/overlay.json`）：
 * - 保存 `thread/name/set` 自定义标题（优先于 `agy` 自动标题）；
 * - 记录首次观测到的 `createdAt` 与首条用户提问 `preview`（ACP `session/list` 只给 `title` 和 `updatedAt`）；
 * - 保存归档标记 `archived`。
 */
export class AgyOverlay {
  private loaded = false;
  private data: OverlayData = { version: 1, sessions: {} };
  private writeChain: Promise<void> = Promise.resolve();

  constructor(private readonly filePath: string) {}

  async load(): Promise<void> {
    if (this.loaded) return;
    try {
      const raw = await readFile(this.filePath, "utf8");
      const parsed = JSON.parse(raw) as Partial<OverlayData>;
      if (parsed && typeof parsed === "object" && parsed.sessions && typeof parsed.sessions === "object") {
        this.data = { version: 1, sessions: { ...parsed.sessions } };
      }
    } catch {
      // 文件尚未创建或为空时使用空表。
    }
    this.loaded = true;
  }

  get(sessionId: string): OverlayEntry | undefined {
    return this.data.sessions[sessionId];
  }

  isArchived(sessionId: string): boolean {
    return this.data.sessions[sessionId]?.archived === true;
  }

  async recordSession(
    sessionId: string,
    patch: { cwd?: string; preview?: string; createdAt?: number; updatedAt?: number; customTitle?: string },
  ): Promise<void> {
    await this.load();
    const current = this.data.sessions[sessionId] ?? {};
    const next: OverlayEntry = {
      ...current,
      ...(patch.cwd ? { cwd: patch.cwd } : {}),
      ...(patch.preview && !current.preview ? { preview: patch.preview } : {}),
      ...(patch.createdAt !== undefined && current.createdAt === undefined ? { createdAt: patch.createdAt } : {}),
      ...(patch.updatedAt !== undefined ? { updatedAt: Math.max(current.updatedAt ?? 0, patch.updatedAt) } : {}),
      ...(patch.customTitle !== undefined ? { customTitle: patch.customTitle } : {}),
    };
    this.data.sessions[sessionId] = next;
    await this.persist();
  }

  async setCustomTitle(sessionId: string, title: string): Promise<void> {
    await this.recordSession(sessionId, { customTitle: title });
  }

  private persist(): Promise<void> {
    const snapshot = JSON.stringify(this.data, null, 2);
    this.writeChain = this.writeChain.then(async () => {
      await mkdir(path.dirname(this.filePath), { recursive: true });
      const tmp = `${this.filePath}.tmp.${process.pid}`;
      await writeFile(tmp, snapshot, "utf8");
      await rename(tmp, this.filePath);
    });
    return this.writeChain;
  }
}
