import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import path from "node:path";
import type { Turn } from "@mimi/appserver-kit/protocol/codex/v2/Turn.ts";

export interface TurnOutcomeRecord {
  status: "completed" | "failed" | "interrupted";
  error?: string | null;
}

export interface TurnAttemptRecord {
  attemptId: string;
  turnId: string;
  promptText: string;
  afterPersistedTurnCount: number;
  status: "inProgress" | "completed" | "failed" | "interrupted";
  error?: string | null;
  /** 若明确确认未落盘（如写用户消息前早失败），为 false；成功落盘为 true；未知（如无 transcript 文件）为 undefined。 */
  persisted?: boolean;
  /** 仅针对未落盘的失败/中断尝试保存完整快照，以便冷读历史时保留（B10）。 */
  syntheticTurn?: Turn;
  createdAt: number;
}

interface OverlayEntry {
  customTitle?: string;
  preview?: string;
  createdAt?: number;
  updatedAt?: number;
  cwd?: string;
  archived?: boolean;
  nextTurnOrdinal?: number;
  nextAttemptSeq?: number;
  turnOutcomes?: Record<string, TurnOutcomeRecord>;
  turnAttempts?: TurnAttemptRecord[];
}

const MAX_TURN_OUTCOMES_PER_SESSION = 200;
const MAX_TURN_ATTEMPTS_PER_SESSION = 200;

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

  getTurnOutcome(sessionId: string, turnId: string): TurnOutcomeRecord | undefined {
    return this.data.sessions[sessionId]?.turnOutcomes?.[turnId];
  }

  getTurnAttempts(sessionId: string): TurnAttemptRecord[] {
    return this.data.sessions[sessionId]?.turnAttempts ?? [];
  }

  /**
   * 发布回合前预留不可复用的回合序号与尝试 ID（B10）：
   * 即使本次尝试在用户消息落盘前失败，下一次成功尝试也不会复用同一 turnId。
   */
  async reserveTurnAttempt(
    sessionId: string,
    info: { minTurnOrdinal: number; afterPersistedTurnCount: number; promptText: string },
  ): Promise<{ turnId: string; attemptId: string }> {
    await this.load();
    const current = this.data.sessions[sessionId] ?? {};
    const ordinal = Math.max(info.minTurnOrdinal, (current.nextTurnOrdinal ?? 0) + 1);
    const attemptSeq = (current.nextAttemptSeq ?? 0) + 1;
    const turnId = `${sessionId}:turn:${ordinal}`;
    const attemptId = `${sessionId}:attempt:${attemptSeq}`;
    const attempts = [...(current.turnAttempts ?? [])];
    attempts.push({
      attemptId,
      turnId,
      promptText: info.promptText,
      afterPersistedTurnCount: info.afterPersistedTurnCount,
      status: "inProgress",
      createdAt: Math.floor(Date.now() / 1000),
    });
    while (attempts.length > MAX_TURN_ATTEMPTS_PER_SESSION) {
      attempts.shift();
    }
    this.data.sessions[sessionId] = {
      ...current,
      nextTurnOrdinal: ordinal,
      nextAttemptSeq: attemptSeq,
      turnAttempts: attempts,
    };
    await this.persist();
    return { turnId, attemptId };
  }

  async recordSession(
    sessionId: string,
    patch: {
      cwd?: string;
      preview?: string;
      createdAt?: number;
      updatedAt?: number;
      customTitle?: string;
      turnOutcome?: { turnId: string; status: "failed" | "interrupted"; error?: string | null };
      turnAttemptUpdate?: {
        attemptId: string;
        turnId: string;
        promptText?: string;
        afterPersistedTurnCount?: number;
        status: "completed" | "failed" | "interrupted";
        error?: string | null;
        persisted?: boolean;
        syntheticTurn?: Turn;
      };
    },
  ): Promise<void> {
    await this.load();
    const current = this.data.sessions[sessionId] ?? {};
    let turnOutcomes = current.turnOutcomes;
    if (patch.turnOutcome) {
      const nextOutcomes: Record<string, TurnOutcomeRecord> = { ...(current.turnOutcomes ?? {}) };
      delete nextOutcomes[patch.turnOutcome.turnId];
      nextOutcomes[patch.turnOutcome.turnId] = {
        status: patch.turnOutcome.status,
        ...(patch.turnOutcome.error ? { error: patch.turnOutcome.error } : {}),
      };
      const keys = Object.keys(nextOutcomes);
      while (keys.length > MAX_TURN_OUTCOMES_PER_SESSION) {
        const oldest = keys.shift();
        if (oldest) delete nextOutcomes[oldest];
      }
      turnOutcomes = nextOutcomes;
    }
    let turnAttempts = current.turnAttempts;
    if (patch.turnAttemptUpdate) {
      const update = patch.turnAttemptUpdate;
      const nextAttempts = [...(current.turnAttempts ?? [])];
      const idx = nextAttempts.findIndex((entry) => entry.attemptId === update.attemptId);
      if (idx >= 0) {
        const existing = nextAttempts[idx]!;
        nextAttempts[idx] = {
          ...existing,
          status: update.status,
          ...(update.error !== undefined ? { error: update.error } : {}),
          ...(update.persisted !== undefined ? { persisted: update.persisted } : {}),
          ...(update.syntheticTurn ? { syntheticTurn: update.syntheticTurn } : {}),
        };
      } else {
        nextAttempts.push({
          attemptId: update.attemptId,
          turnId: update.turnId,
          promptText: update.promptText ?? "",
          afterPersistedTurnCount: update.afterPersistedTurnCount ?? 0,
          status: update.status,
          ...(update.error !== undefined ? { error: update.error } : {}),
          ...(update.persisted !== undefined ? { persisted: update.persisted } : {}),
          ...(update.syntheticTurn ? { syntheticTurn: update.syntheticTurn } : {}),
          createdAt: Math.floor(Date.now() / 1000),
        });
      }
      while (nextAttempts.length > MAX_TURN_ATTEMPTS_PER_SESSION) {
        nextAttempts.shift();
      }
      turnAttempts = nextAttempts;
    }
    const next: OverlayEntry = {
      ...current,
      ...(patch.cwd ? { cwd: patch.cwd } : {}),
      ...(patch.preview && !current.preview ? { preview: patch.preview } : {}),
      ...(patch.createdAt !== undefined && current.createdAt === undefined ? { createdAt: patch.createdAt } : {}),
      ...(patch.updatedAt !== undefined ? { updatedAt: Math.max(current.updatedAt ?? 0, patch.updatedAt) } : {}),
      ...(patch.customTitle !== undefined ? { customTitle: patch.customTitle } : {}),
      ...(turnOutcomes ? { turnOutcomes } : {}),
      ...(turnAttempts ? { turnAttempts } : {}),
    };
    this.data.sessions[sessionId] = next;
    await this.persist();
  }

  async setCustomTitle(sessionId: string, title: string): Promise<void> {
    await this.recordSession(sessionId, { customTitle: title });
  }

  flush(): Promise<void> {
    return this.writeChain;
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
