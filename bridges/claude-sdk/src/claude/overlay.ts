import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import path from "node:path";

interface OverlayFile {
  version: 1;
  /** 会话 ID → 归档时间（Unix 秒）。 */
  archived: Record<string, number>;
}

/**
 * Mimi 独有、Claude Code 没有的会话状态。目前只有归档：Claude 的 transcript 里
 * 没有对应概念，只能由 Mimi 自己保存。标题等 Claude 已有的字段一律不在这里存。
 */
export class Overlay {
  private data: OverlayFile = { version: 1, archived: {} };
  private loaded: Promise<void> | undefined;

  constructor(
    private readonly file: string,
    /** 旧 Rust bridge 的会话索引；首次启动时只读导入其中的归档标记。 */
    private readonly legacyIndex: string | undefined,
  ) {}

  load(): Promise<void> {
    this.loaded ??= this.read();
    return this.loaded;
  }

  isArchived(sessionId: string): boolean {
    return sessionId in this.data.archived;
  }

  private async read(): Promise<void> {
    const raw = await readFile(this.file, "utf8").catch(() => undefined);
    if (raw !== undefined) {
      const parsed = JSON.parse(raw) as Partial<OverlayFile>;
      this.data = { version: 1, archived: parsed.archived ?? {} };
      return;
    }
    this.data = { version: 1, archived: await this.importLegacyArchived() };
    await this.save();
  }

  private async importLegacyArchived(): Promise<Record<string, number>> {
    if (!this.legacyIndex) return {};
    const raw = await readFile(this.legacyIndex, "utf8").catch(() => undefined);
    if (raw === undefined) return {};
    try {
      const threads = (JSON.parse(raw) as { threads?: unknown }).threads;
      if (!Array.isArray(threads)) return {};
      const now = Math.floor(Date.now() / 1000);
      const archived: Record<string, number> = {};
      for (const row of threads as Array<Record<string, unknown>>) {
        if (row.archived === true && typeof row.threadId === "string") archived[row.threadId] = now;
      }
      return archived;
    } catch {
      return {};
    }
  }

  private async save(): Promise<void> {
    await mkdir(path.dirname(this.file), { recursive: true });
    const temporary = `${this.file}.tmp`;
    await writeFile(temporary, `${JSON.stringify(this.data, null, 2)}\n`, { mode: 0o600 });
    await rename(temporary, this.file);
  }
}
