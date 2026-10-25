import { randomUUID } from "node:crypto";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import path from "node:path";
import { readLegacyIndex } from "./legacy.ts";
import type { MimiTaskProposalInput } from "../runtime/turnHints.ts";

export interface MimiTaskProposal extends MimiTaskProposalInput {
  id: string;
  parentThreadId: string;
  cwd: string;
  consumedByThreadId?: string;
}

interface OverlayFile {
  version: 1;
  /** 会话 ID → 归档时间（Unix 秒）。 */
  archived: Record<string, number>;
  /** Mimi 卡片提议。随机 ID 是卡片可执行来源，成功创建后保留 child ID 供重试复用。 */
  taskProposals?: Record<string, MimiTaskProposal>;
  /** Mimi 创建的普通子会话关系；不用 parentThreadId，避免被网关判成只读子 Agent。 */
  spawnedFrom?: Record<string, string>;
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
  /** 同一进程里的写操作串行执行，保证 proposal 的首次消费和失败回滚不会互相覆盖。 */
  private mutations: Promise<void> = Promise.resolve();
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

  spawnedFrom(sessionId: string): string | null {
    return this.data.spawnedFrom?.[sessionId] ?? null;
  }

  isTaskProposal(parentThreadId: string, proposalId: string): boolean {
    return this.data.taskProposals?.[proposalId]?.parentThreadId === parentThreadId;
  }

  async recordTaskProposal(parentThreadId: string, cwd: string, input: MimiTaskProposalInput): Promise<string> {
    await this.load();
    return this.mutate(async () => {
      const id = randomUUID();
      this.data.taskProposals ??= {};
      this.data.taskProposals[id] = { id, parentThreadId, cwd, ...input };
      await this.save();
      return id;
    });
  }

  /**
   * 首次调用把 proposal 原子绑定到新 child；响应丢失后的重复调用返回同一个 child，
   * 不会重复建会话。落盘失败会回滚内存状态，因此用户仍可重试。
   */
  async consumeTaskProposal(
    proposalId: string,
    parentThreadId: string,
    cwd: string,
    childThreadId: string,
  ): Promise<MimiTaskProposal | undefined> {
    await this.load();
    return this.mutate(async () => {
      const proposal = this.data.taskProposals?.[proposalId];
      if (!proposal || proposal.parentThreadId !== parentThreadId || proposal.cwd !== cwd) return undefined;
      if (proposal.consumedByThreadId) return proposal;
      this.data.spawnedFrom ??= {};
      proposal.consumedByThreadId = childThreadId;
      this.data.spawnedFrom[childThreadId] = parentThreadId;
      try {
        await this.save();
        return proposal;
      } catch (error) {
        delete proposal.consumedByThreadId;
        delete this.data.spawnedFrom[childThreadId];
        throw error;
      }
    });
  }

  legacyNamesMigrated(): boolean {
    return this.data.legacyNamesMigratedAt !== undefined;
  }

  legacyImportPending(): boolean {
    return this.importPending;
  }

  async markLegacyNamesMigrated(): Promise<void> {
    await this.load();
    await this.mutate(async () => {
      this.data.legacyNamesMigratedAt = Math.floor(Date.now() / 1000);
      await this.save();
    });
  }

  private mutate<T>(operation: () => Promise<T>): Promise<T> {
    const result = this.mutations.then(operation, operation);
    this.mutations = result.then(() => undefined, () => undefined);
    return result;
  }

  private async read(): Promise<void> {
    const raw = await readFile(this.file, "utf8").catch(() => undefined);
    if (raw !== undefined) {
      const parsed = JSON.parse(raw) as Partial<OverlayFile>;
      this.data = {
        version: 1,
        archived: parsed.archived ?? {},
        ...(parsed.taskProposals ? { taskProposals: parsed.taskProposals } : {}),
        ...(parsed.spawnedFrom ? { spawnedFrom: parsed.spawnedFrom } : {}),
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
