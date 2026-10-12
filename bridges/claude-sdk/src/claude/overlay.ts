import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import path from "node:path";
import { readLegacyIndex } from "./legacy.ts";

interface OverlayFile {
  version: 1;
  /** 会话 ID → 归档时间（Unix 秒）。 */
  archived: Record<string, number>;
  /** 旧 bridge 里的 Mimi 名称已全部写成 custom-title 的时间（Unix 秒），之后不再迁移。 */
  legacyNamesMigratedAt?: number;
}

/**
 * Mimi 独有、Claude Code 没有的会话状态。目前只有归档：Claude 的 transcript 里
 * 没有对应概念，只能由 Mimi 自己保存。标题等 Claude 已有的字段一律不在这里存。
 */
export class Overlay {
  private data: OverlayFile = { version: 1, archived: {} };
  private loaded: Promise<void> | undefined;
  /** 首次启动时旧索引读不了：归档标记还没导入，覆盖层先不落盘。 */
  private importPending = false;

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

  legacyNamesMigrated(): boolean {
    return this.data.legacyNamesMigratedAt !== undefined;
  }

  legacyImportPending(): boolean {
    return this.importPending;
  }

  async markLegacyNamesMigrated(): Promise<void> {
    await this.load();
    this.data.legacyNamesMigratedAt = Math.floor(Date.now() / 1000);
    await this.save();
  }

  private async read(): Promise<void> {
    const raw = await readFile(this.file, "utf8").catch(() => undefined);
    if (raw !== undefined) {
      const parsed = JSON.parse(raw) as Partial<OverlayFile>;
      this.data = {
        version: 1,
        archived: parsed.archived ?? {},
        ...(typeof parsed.legacyNamesMigratedAt === "number" ? { legacyNamesMigratedAt: parsed.legacyNamesMigratedAt } : {}),
      };
      return;
    }
    const legacy = await readLegacyIndex(this.legacyIndex);
    if (legacy.status === "unreadable") {
      // 先不落盘：下次启动覆盖层文件仍不存在，会重新导入。
      this.importPending = true;
      return;
    }
    const now = Math.floor(Date.now() / 1000);
    const archived: Record<string, number> = {};
    for (const thread of legacy.status === "ok" ? legacy.threads : []) {
      if (thread.archived) archived[thread.threadId] = now;
    }
    this.data = { version: 1, archived };
    await this.save();
  }

  private async save(): Promise<void> {
    await mkdir(path.dirname(this.file), { recursive: true });
    const temporary = `${this.file}.tmp`;
    await writeFile(temporary, `${JSON.stringify(this.data, null, 2)}\n`, { mode: 0o600 });
    await rename(temporary, this.file);
  }
}
