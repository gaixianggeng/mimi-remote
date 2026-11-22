import type { Turn } from "@mimi/appserver-kit/protocol/codex/v2/Turn.ts";
import type { UserInput } from "@mimi/appserver-kit/protocol/codex/v2/UserInput.ts";
import { RpcError } from "@mimi/appserver-kit/rpc/frames.ts";
import { errorText, logger } from "../util/logging.ts";
import type { AcpClient } from "../acp/client.ts";
import type {
  AcpAvailableCommand,
  AcpRequestPermissionParams,
  AcpRequestPermissionResult,
  AcpSessionOpenResult,
  AcpSessionUpdate,
} from "../acp/types.ts";
import { updatesToTurns } from "../agy/history.ts";
import type { PersistedToolMapping } from "../agy/overlay.ts";
import {
  detectExternalConcurrentWrite,
  type ExternalWriteBaseline,
  type TranscriptActivityInfo,
  type TranscriptSnapshotResult,
  type TranscriptTurnSnapshot,
} from "../agy/transcript.ts";
import { desktopOwnerSummary } from "../handlers/threads.ts";
import { selectPermissionOption, serverApprovalFor } from "./approvals.ts";
import { LiveTurn, type TurnUsage } from "./liveTurn.ts";
import type { AgyRunSettings } from "./settings.ts";
import { toAcpPromptBlocks } from "./userInput.ts";

export const EXTERNAL_WRITE_CONFLICT_MESSAGE =
  "Another Antigravity process on this computer wrote to this session; this turn and any pending approval were stopped to avoid conflicting changes. Refresh to view the latest messages.";

export const EXTERNAL_WRITE_VERIFY_UNKNOWN_MESSAGE =
  "Could not verify whether another Antigravity process modified this session before applying your approval; the approval was cancelled to protect session state. Refresh to view the latest messages.";

type ExternalWriteCheckResult = "ok" | "conflict" | "unknown";

interface PendingApprovalState {
  requestKey: string;
  turn: LiveTurn | undefined;
  abortController: AbortController;
  baseline?: ExternalWriteBaseline;
}

function normalizeTranscriptInspection(
  raw: TranscriptSnapshotResult | TranscriptTurnSnapshot | undefined,
): TranscriptSnapshotResult {
  if (raw === undefined) {
    return { kind: "missing" };
  }
  if ("kind" in raw && (raw.kind === "present" || raw.kind === "missing" || raw.kind === "error")) {
    return raw;
  }
  return { kind: "present", snapshot: raw as TranscriptTurnSnapshot };
}

const DEFAULT_EXTERNAL_WRITE_POLL_MS = 500;

export interface RuntimeHost {
  publish(threadId: string, method: string, params: Record<string, unknown>): void;
  request(threadId: string, method: string, params: Record<string, unknown>, signal: AbortSignal): Promise<unknown>;
  acquireClient(appDataDirName?: string): Promise<AcpClient>;
  idleCloseMs: number;
  externalWritePollMs?: number;
  onSessionOpen?(openResult: AcpSessionOpenResult): void;
  onAvailableCommands?(cwd: string, commands: AcpAvailableCommand[]): void;
  onTitleUpdated?(threadId: string, title: string): void;
  onTurnPersisted?(
    threadId: string,
    patch: {
      preview?: string;
      updatedAt?: number;
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
      toolMappings?: { turnId: string; entries: PersistedToolMapping[] };
    },
  ): void;
  reserveTurnAttempt?(
    threadId: string,
    info: { minTurnOrdinal: number; afterPersistedTurnCount: number; promptText: string },
  ): Promise<{ turnId: string; attemptId: string }>;
  existingTurnCount?(threadId: string): Promise<number>;
  existingTurnInfo?(threadId: string): Promise<{ nativeTurnCount: number; maxTurnOrdinal: number }>;
  recordTurnClientId?(turnId: string, clientId: string): void;
  inspectTranscriptState?(threadId: string): Promise<TranscriptSnapshotResult | TranscriptTurnSnapshot | undefined>;
  externalActivity?(threadId: string): Promise<TranscriptActivityInfo | undefined>;
}

export interface TurnStartRequest {
  input: UserInput[];
  clientUserMessageId: string | null;
  settings: Partial<AgyRunSettings>;
}

export class ThreadRuntime {
  private client: AcpClient | undefined;
  private unsubSession: (() => void) | undefined;
  private unsubPermission: (() => void) | undefined;
  private appliedMode: string | undefined;
  private appliedModel: string | undefined;
  private appliedEffort: string | undefined;
  private currentTurn: LiveTurn | undefined;
  private currentAttempt: { attemptId: string; turnId: string; promptText: string; afterPersistedTurnCount: number } | undefined;
  private startingTurn = false;
  private totalUsage: TurnUsage | undefined;
  private idleTimer: ReturnType<typeof setTimeout> | undefined;
  private externalWriteTimer: ReturnType<typeof setInterval> | undefined;
  private externalWriteCheckInFlight: {
    turn: LiveTurn;
    seq: number;
    promise: Promise<ExternalWriteCheckResult>;
  } | undefined;
  private externalWriteCheckSeq = 0;
  private externalWriteBaseline: ExternalWriteBaseline | undefined;
  private externalWriteConflict: string | undefined;
  private readonly pendingApprovals = new Map<string, PendingApprovalState>();
  private approvalRequestSeq = 0;
  private historyTurns: Turn[] | undefined;
  private availableCommands: AcpAvailableCommand[] | undefined;
  readonly createdAt: number;
  updatedAt: number;
  title: string | null;

  constructor(
    public threadId: string,
    readonly cwd: string,
    private readonly host: RuntimeHost,
    private settings: AgyRunSettings,
    private persisted: boolean,
    initialTitle: string | null = null,
    private readonly appDataDirName?: string,
    initialTimestamps?: { createdAt?: number; updatedAt?: number },
  ) {
    const nowSec = Math.floor(Date.now() / 1000);
    this.createdAt = initialTimestamps?.createdAt ?? nowSec;
    this.updatedAt = initialTimestamps?.updatedAt ?? this.createdAt;
    this.title = initialTitle;
  }

  get activeTurnId(): string | undefined {
    return this.currentTurn?.id;
  }

  get currentSettings(): AgyRunSettings {
    return this.settings;
  }

  isBusy(): boolean {
    return this.currentTurn !== undefined || this.startingTurn;
  }

  isLoaded(): boolean {
    return this.client !== undefined || this.isBusy();
  }

  hasLiveProcess(): boolean {
    return this.client !== undefined && !this.client.isClosed;
  }

  liveCommands(): AcpAvailableCommand[] | undefined {
    return this.availableCommands;
  }

  liveHistoryTurns(): Turn[] | undefined {
    if (!this.historyTurns) return undefined;
    if (this.currentTurn) {
      return [...this.historyTurns, this.currentTurn.snapshot(true)];
    }
    // 已落盘的会话在空闲时优先走磁盘/transcript 读取，避免桌面端或终端追加的新消息被旧内存快照遮蔽。
    if (this.persisted) return undefined;
    return this.historyTurns;
  }

  /**
   * 为 `thread/start` 在常驻共享 `agy acp` 实例上创建新会话并取得原生分配的 `sessionId`。
   */
  async initializeNewSession(): Promise<string> {
    const client = await this.host.acquireClient(this.appDataDirName);
    const open = await client.sessionNew(this.cwd);
    this.threadId = open.sessionId;
    this.attachClient(client, this.threadId);
    this.historyTurns = [];
    this.recordSessionMeta(open, true);
    await this.applySessionControls(client, this.settings);
    this.scheduleIdleClose();
    return this.threadId;
  }

  async startTurn(req: TurnStartRequest): Promise<Turn> {
    if (this.isBusy()) {
      throw RpcError.invalidParams(`会话 ${this.threadId} 已有进行中的回合`);
    }
    this.startingTurn = true;
    this.cancelIdleClose();

    let turn: LiveTurn | undefined;
    try {
      this.settings = {
        model: req.settings.model ?? this.settings.model,
        effort: req.settings.effort ?? this.settings.effort,
        mode: req.settings.mode ?? this.settings.mode,
        executionPolicy: req.settings.executionPolicy ?? this.settings.executionPolicy,
      };
      const { blocks, preview } = await toAcpPromptBlocks(req.input);

      if (!this.client || this.client.isClosed) {
        this.detachSessionHandlers();
        const client = await this.host.acquireClient(this.appDataDirName);
        const { result, updates } = await client.sessionLoadWithReplay(this.threadId, this.cwd);
        this.attachClient(client, this.threadId);
        this.historyTurns = updatesToTurns(this.threadId, this.cwd, updates, false);
        this.recordSessionMeta(result, false);
      }

      const client = this.client!;
      await this.applySessionControls(client, this.settings);

      const diskInfo = this.persisted
        ? (await this.host.existingTurnInfo?.(this.threadId).catch(() => undefined))
          ?? {
            nativeTurnCount: (await this.host.existingTurnCount?.(this.threadId).catch(() => 0)) ?? 0,
            maxTurnOrdinal: 0,
          }
        : { nativeTurnCount: 0, maxTurnOrdinal: 0 };
      const historyCompletedCount = this.historyTurns?.filter((t) => t.status === "completed").length ?? 0;
      const persistedBefore = Math.max(historyCompletedCount, diskInfo.nativeTurnCount);
      const nextTurnIndex = Math.max(this.historyTurns?.length ?? 0, diskInfo.nativeTurnCount, diskInfo.maxTurnOrdinal) + 1;
      const reserved = await this.host.reserveTurnAttempt?.(this.threadId, {
        minTurnOrdinal: nextTurnIndex,
        afterPersistedTurnCount: persistedBefore,
        promptText: preview,
      });
      const turnId = reserved?.turnId ?? `${this.threadId}:turn:${nextTurnIndex}`;
      const attemptMeta = {
        attemptId: reserved?.attemptId ?? `${turnId}:attempt`,
        turnId,
        promptText: preview,
        afterPersistedTurnCount: persistedBefore,
      };
      if (req.clientUserMessageId) {
        this.host.recordTurnClientId?.(turnId, req.clientUserMessageId);
      }
      turn = new LiveTurn(turnId, this.threadId, this.cwd, (method, params) => {
        this.host.publish(this.threadId, method, params);
      });
      this.currentTurn = turn;
      this.currentAttempt = attemptMeta;
      this.startingTurn = false;

      this.host.publish(this.threadId, "thread/status/changed", {
        threadId: this.threadId,
        status: { type: "active", activeFlags: [] },
      });
      turn.begin(req.clientUserMessageId, req.input);
      this.updatedAt = Math.floor(Date.now() / 1000);
      this.host.onTurnPersisted?.(this.threadId, {
        ...(preview ? { preview } : {}),
        updatedAt: this.updatedAt,
      });

      const initialInspection = await this.inspectTranscript();
      const initialSnapshot = initialInspection.kind === "present" ? initialInspection.snapshot : undefined;
      this.externalWriteConflict = undefined;
      this.externalWriteCheckInFlight = undefined;
      this.externalWriteBaseline = {
        userInputCount: initialSnapshot?.userInputs.length ?? 0,
        expectedPromptText: preview,
        hasTranscript: initialInspection.kind === "present",
        ...(initialInspection.kind === "error" ? { initialReadFailed: true } : {}),
      };
      this.startExternalWriteMonitor(turn);

      void this.runPrompt(client, turn, blocks, attemptMeta, initialSnapshot);
      return turn.snapshot(false);
    } catch (error) {
      this.stopExternalWriteMonitor();
      this.externalWriteBaseline = undefined;
      this.externalWriteConflict = undefined;
      this.startingTurn = false;
      this.currentTurn = undefined;
      this.currentAttempt = undefined;
      this.scheduleIdleClose();
      throw error;
    }
  }

  interrupt(turnId?: string): Record<string, never> {
    const active = this.currentTurn;
    if (!active) return {};
    if (turnId && active.id !== turnId) {
      throw RpcError.invalidParams(`回合 ${turnId} 已不在运行`);
    }
    active.markInterrupted();
    this.client?.sessionCancel(this.threadId);
    return {};
  }

  async close(): Promise<void> {
    this.cancelIdleClose();
    this.stopExternalWriteMonitor();
    for (const entry of this.pendingApprovals.values()) {
      entry.abortController.abort();
    }
    this.pendingApprovals.clear();
    if (this.currentTurn && !this.currentTurn.finished) {
      this.currentTurn.markInterrupted();
      const { turn } = this.currentTurn.finish(undefined, "session closed", this.totalUsage);
      this.historyTurns = [...(this.historyTurns ?? []), turn];
      const attempt = this.currentAttempt;
      this.host.onTurnPersisted?.(this.threadId, {
        updatedAt: Math.floor(Date.now() / 1000),
        ...(attempt
          ? {
              turnAttemptUpdate: {
                attemptId: attempt.attemptId,
                turnId: turn.id,
                promptText: attempt.promptText,
                afterPersistedTurnCount: attempt.afterPersistedTurnCount,
                status: "interrupted",
                error: null,
                syntheticTurn: turn,
              },
            }
          : { turnOutcome: { turnId: turn.id, status: "interrupted" } }),
      });
      this.currentTurn = undefined;
      this.currentAttempt = undefined;
    }
    await this.closeClient();
  }

  private async runPrompt(
    client: AcpClient,
    turn: LiveTurn,
    blocks: Parameters<AcpClient["sessionPrompt"]>[1],
    attemptMeta: { attemptId: string; turnId: string; promptText: string; afterPersistedTurnCount: number },
    initialSnapshot: TranscriptTurnSnapshot | undefined,
  ): Promise<void> {
    let finishedTurn: Turn | undefined;
    try {
      const res = await client.sessionPrompt(this.threadId, blocks);
      this.persisted = true;
      const conflict = this.externalWriteConflict;
      const finished = turn.finish(res, conflict, this.totalUsage);
      finishedTurn = finished.turn;
      if (finished.usage) this.totalUsage = finished.usage;
      this.historyTurns = [...(this.historyTurns ?? []), finished.turn];
    } catch (error) {
      const conflict = this.externalWriteConflict;
      if (conflict) this.persisted = true;
      const finished = turn.finish(undefined, conflict ?? errorText(error), this.totalUsage);
      finishedTurn = finished.turn;
      this.historyTurns = [...(this.historyTurns ?? []), finished.turn];
    } finally {
      this.stopExternalWriteMonitor();
      if (this.currentTurn === turn) {
        this.externalWriteBaseline = undefined;
        this.externalWriteCheckInFlight = undefined;
      }
      const hadConflict = Boolean(this.externalWriteConflict);
      if (this.currentTurn === turn) {
        this.externalWriteConflict = undefined;
        this.currentTurn = undefined;
        this.currentAttempt = undefined;
      }
      this.updatedAt = Math.floor(Date.now() / 1000);
      const afterInspection = await this.inspectTranscript();
      const afterSnapshot = afterInspection.kind === "present" ? afterInspection.snapshot : undefined;
      let attemptPersisted: boolean | undefined;
      if (finishedTurn?.status === "completed") {
        attemptPersisted = true;
      } else if (initialSnapshot !== undefined && afterSnapshot !== undefined) {
        attemptPersisted = afterSnapshot.userInputs.length > initialSnapshot.userInputs.length;
      } else if (afterSnapshot !== undefined && afterSnapshot.userInputs.length > attemptMeta.afterPersistedTurnCount) {
        attemptPersisted = true;
      }
      const attemptStatus: "completed" | "failed" | "interrupted" =
        finishedTurn?.status === "failed"
          ? "failed"
          : finishedTurn?.status === "interrupted"
            ? "interrupted"
            : "completed";
      const toolEntries = turn.toolMappings();
      this.host.onTurnPersisted?.(this.threadId, {
        updatedAt: this.updatedAt,
        turnAttemptUpdate: {
          attemptId: attemptMeta.attemptId,
          turnId: finishedTurn?.id ?? attemptMeta.turnId,
          promptText: attemptMeta.promptText,
          afterPersistedTurnCount: attemptMeta.afterPersistedTurnCount,
          status: attemptStatus,
          error: finishedTurn?.error?.message ?? null,
          ...(attemptPersisted !== undefined ? { persisted: attemptPersisted } : {}),
          ...(attemptStatus !== "completed" && finishedTurn ? { syntheticTurn: finishedTurn } : {}),
        },
        ...(toolEntries.length > 0 ? { toolMappings: { turnId: finishedTurn?.id ?? attemptMeta.turnId, entries: toolEntries } } : {}),
      });
      const ext = hadConflict
        ? await this.host.externalActivity?.(this.threadId).catch(() => undefined)
        : undefined;
      if (ext?.externallyBusy) {
        this.host.publish(this.threadId, "thread/status/changed", {
          threadId: this.threadId,
          status: { type: "active", activeFlags: [] },
          canAcceptDirectInput: false,
          claudeOwner: desktopOwnerSummary(ext.mtimeMs, ext.holderPid ?? null),
        });
      } else {
        this.host.publish(this.threadId, "thread/status/changed", {
          threadId: this.threadId,
          status: { type: "idle" },
        });
      }
      this.scheduleIdleClose();
    }
  }

  private attachClient(client: AcpClient, sessionId: string): void {
    this.detachSessionHandlers();
    this.client = client;
    this.appliedMode = undefined;
    this.appliedModel = undefined;
    this.appliedEffort = undefined;
    this.unsubSession = client.onSession(sessionId, (update) => this.handleSessionUpdate(sessionId, update));
    this.unsubPermission = client.onPermission(sessionId, (params, signal) => this.handlePermissionRequest(params, signal));
  }

  private detachSessionHandlers(): void {
    this.unsubSession?.();
    this.unsubSession = undefined;
    this.unsubPermission?.();
    this.unsubPermission = undefined;
  }

  private async applySessionControls(client: AcpClient, settings: AgyRunSettings): Promise<void> {
    if (settings.mode && settings.mode !== this.appliedMode) {
      await client.sessionSetMode(this.threadId, settings.mode);
      this.appliedMode = settings.mode;
    }
    if (settings.model && settings.model !== this.appliedModel) {
      await client.sessionSetConfigOption(this.threadId, "model", settings.model);
      this.appliedModel = settings.model;
    }
    if (settings.effort && settings.effort !== this.appliedEffort) {
      await client
        .sessionSetConfigOption(this.threadId, "thought_level", settings.effort)
        .then(() => {
          this.appliedEffort = settings.effort;
        })
        .catch((error) => {
          // 诸如 `gemini-pro-orchestrator` 等不支持思考档位的模型拒绝 `thought_level` 时忽略并继续对话。
          logger.debug("agy.thought_level.skipped", { model: settings.model ?? null, effort: settings.effort, error: errorText(error) });
        });
    }
  }

  private recordSessionMeta(open: AcpSessionOpenResult, updateGlobalModelCatalog: boolean): void {
    // 仅 `session/new` 返回运行时全局默认模型；`session/load` 的 currentValue 是该历史会话固定的模型，
    // 不能覆写全局 ModelCatalog 的 isDefault（B20）。
    if (updateGlobalModelCatalog) {
      this.host.onSessionOpen?.(open);
    }
    if (open.modes?.currentModeId) {
      this.appliedMode = open.modes.currentModeId;
    }
    for (const opt of open.configOptions ?? []) {
      if (opt.id === "model") this.appliedModel = opt.currentValue;
      if (opt.id === "thought_level") this.appliedEffort = opt.currentValue;
    }
  }

  private handleSessionUpdate(sessionId: string, update: AcpSessionUpdate): void {
    if (this.threadId && sessionId !== this.threadId) return;
    if (update.sessionUpdate === "available_commands_update" && Array.isArray(update.availableCommands)) {
      this.availableCommands = update.availableCommands;
      this.host.onAvailableCommands?.(this.cwd, update.availableCommands);
      return;
    }
    if (update.sessionUpdate === "session_info_update") {
      const nextTitle = typeof update.title === "string" ? update.title.trim() : "";
      if (nextTitle && nextTitle !== this.title) {
        this.title = nextTitle;
        this.host.onTitleUpdated?.(this.threadId, nextTitle);
      }
      return;
    }
    if (update.sessionUpdate === "current_mode_update" && typeof update.currentModeId === "string") {
      this.appliedMode = update.currentModeId;
      return;
    }
    this.currentTurn?.onUpdate(update);
  }

  private async handlePermissionRequest(
    params: AcpRequestPermissionParams,
    signal: AbortSignal,
  ): Promise<AcpRequestPermissionResult> {
    if (this.settings.executionPolicy.type === "dangerFullAccess") {
      return selectPermissionOption(params.options, "allow_any");
    }
    if (this.settings.executionPolicy.type === "readOnly") {
      const kind = params.toolCall.kind ?? "";
      if (kind === "edit" || kind === "delete" || kind === "move" || kind === "execute") {
        return selectPermissionOption(params.options, "reject_once");
      }
    }
    const boundTurn = this.currentTurn;
    const boundTurnId = boundTurn?.id ?? `${this.threadId}:approval`;
    const approvalId = params.toolCall.toolCallId;
    if (signal.aborted || (boundTurn && boundTurn.finished)) {
      return { outcome: { outcome: "cancelled" } };
    }
    const itemId = boundTurn?.itemIdForToolCall(approvalId);
    const spec = serverApprovalFor(params, {
      threadId: this.threadId,
      turnId: boundTurnId,
      cwd: this.cwd,
      ...(itemId ? { itemId } : {}),
    });

    const requestKey = `${approvalId || "approval"}:${++this.approvalRequestSeq}`;
    const localAbort = new AbortController();
    const isStillOwned = (): boolean => {
      if (signal.aborted || localAbort.signal.aborted || this.externalWriteConflict) return false;
      if (boundTurn && (this.currentTurn !== boundTurn || boundTurn.finished)) return false;
      return true;
    };

    let approvalBaseline: ExternalWriteBaseline | undefined;
    if (boundTurn) {
      const preCheck = await this.checkExternalWriteConflict(boundTurn, { failClosedOnUnknown: true });
      if (preCheck !== "ok" || !isStillOwned()) {
        return { outcome: { outcome: "cancelled" } };
      }
      if (this.externalWriteBaseline && this.host.inspectTranscriptState) {
        const preInspection = await this.inspectTranscript();
        if (!isStillOwned()) {
          return { outcome: { outcome: "cancelled" } };
        }
        if (preInspection.kind === "error") {
          this.triggerExternalWriteFailure(boundTurn, boundTurnId, EXTERNAL_WRITE_VERIFY_UNKNOWN_MESSAGE, preInspection.reason);
          return { outcome: { outcome: "cancelled" } };
        }
        if (this.externalWriteBaseline.hasTranscript && preInspection.kind === "missing") {
          this.triggerExternalWriteFailure(boundTurn, boundTurnId, EXTERNAL_WRITE_VERIFY_UNKNOWN_MESSAGE, "pre_approval_transcript_missing");
          return { outcome: { outcome: "cancelled" } };
        }
        approvalBaseline = {
          userInputCount: this.externalWriteBaseline.userInputCount,
          expectedPromptText: this.externalWriteBaseline.expectedPromptText,
          hasTranscript: this.externalWriteBaseline.hasTranscript || preInspection.kind === "present",
          ...(this.externalWriteBaseline.initialReadFailed ? { initialReadFailed: true } : {}),
          ...(preInspection.kind === "present"
            ? {
                approvalUserInputCount: preInspection.snapshot.userInputs.length,
                approvalPlannerResponseCount: preInspection.snapshot.plannerResponseCount,
              }
            : {}),
        };
        if (preInspection.kind === "present") {
          this.externalWriteBaseline.hasTranscript = true;
        }
      }
    }

    const onUpstreamAbort = () => localAbort.abort();
    signal.addEventListener("abort", onUpstreamAbort, { once: true });
    this.pendingApprovals.set(requestKey, {
      requestKey,
      turn: boundTurn,
      abortController: localAbort,
      ...(approvalBaseline ? { baseline: approvalBaseline } : {}),
    });
    this.host.publish(this.threadId, "thread/status/changed", {
      threadId: this.threadId,
      status: { type: "active", activeFlags: ["waitingOnApproval"] },
    });
    try {
      const response = await this.host.request(this.threadId, spec.method, spec.params, localAbort.signal);
      if (!isStillOwned() || !this.pendingApprovals.has(requestKey)) {
        return { outcome: { outcome: "cancelled" } };
      }
      if (boundTurn) {
        const postCheck = await this.checkExternalWriteConflict(boundTurn, {
          requireFresh: true,
          failClosedOnUnknown: true,
          approvalBaseline,
        });
        if (postCheck !== "ok" || !isStillOwned() || !this.pendingApprovals.has(requestKey)) {
          return { outcome: { outcome: "cancelled" } };
        }
      }
      return spec.toAcpResult(response);
    } catch {
      return { outcome: { outcome: "cancelled" } };
    } finally {
      signal.removeEventListener("abort", onUpstreamAbort);
      this.pendingApprovals.delete(requestKey);
      const sameActiveTurn = !boundTurn || (this.currentTurn === boundTurn && !boundTurn.finished);
      const hasRemainingApprovalsForTurn = [...this.pendingApprovals.values()].some((entry) => entry.turn === boundTurn);
      if (
        sameActiveTurn
        && !hasRemainingApprovalsForTurn
        && this.currentTurn
        && !this.currentTurn.finished
        && !this.externalWriteConflict
      ) {
        this.host.publish(this.threadId, "thread/status/changed", {
          threadId: this.threadId,
          status: { type: "active", activeFlags: [] },
        });
      }
    }
  }

  private async inspectTranscript(): Promise<TranscriptSnapshotResult> {
    if (!this.host.inspectTranscriptState) {
      return { kind: "missing" };
    }
    try {
      const raw = await this.host.inspectTranscriptState(this.threadId);
      return normalizeTranscriptInspection(raw);
    } catch (error) {
      return {
        kind: "error",
        reason: "transcript_inspect_error",
        error: error instanceof Error ? error.message : String(error),
      };
    }
  }

  private startExternalWriteMonitor(boundTurn: LiveTurn): void {
    this.stopExternalWriteMonitor();
    if (!this.host.inspectTranscriptState) return;
    const pollMs = this.host.externalWritePollMs ?? DEFAULT_EXTERNAL_WRITE_POLL_MS;
    if (pollMs <= 0) return;
    this.externalWriteTimer = setInterval(() => {
      void this.checkExternalWriteConflict(boundTurn);
    }, pollMs);
    this.externalWriteTimer.unref?.();
  }

  private stopExternalWriteMonitor(): void {
    if (this.externalWriteTimer) {
      clearInterval(this.externalWriteTimer);
      this.externalWriteTimer = undefined;
    }
  }

  private triggerExternalWriteFailure(
    boundTurn: LiveTurn,
    boundTurnId: string,
    message: string,
    reason: string,
  ): void {
    if (this.currentTurn !== boundTurn || boundTurn.finished) return;
    if (!this.externalWriteConflict) {
      this.externalWriteConflict = message;
    }
    logger.info("agy.concurrent_write.detected", {
      thread: this.threadId,
      turn: boundTurnId,
      reason,
    });
    this.stopExternalWriteMonitor();
    for (const entry of [...this.pendingApprovals.values()]) {
      if (entry.turn === boundTurn) {
        entry.abortController.abort();
      }
    }
    this.client?.sessionCancel(this.threadId);
  }

  private async checkExternalWriteConflict(
    boundTurn: LiveTurn,
    options: { requireFresh?: boolean; failClosedOnUnknown?: boolean; approvalBaseline?: ExternalWriteBaseline } = {},
  ): Promise<ExternalWriteCheckResult> {
    if (this.currentTurn !== boundTurn || boundTurn.finished) {
      return "ok";
    }
    if (this.externalWriteConflict) return "conflict";
    const baseline = this.externalWriteBaseline;
    if (!baseline || !this.host.inspectTranscriptState) {
      return "ok";
    }

    const boundTurnId = boundTurn.id;
    if (baseline.initialReadFailed || options.approvalBaseline?.initialReadFailed) {
      if (options.failClosedOnUnknown) {
        this.triggerExternalWriteFailure(boundTurn, boundTurnId, EXTERNAL_WRITE_VERIFY_UNKNOWN_MESSAGE, "initial_transcript_inspect_error");
      }
      return "unknown";
    }

    // 用单调递增序号判定“本次检查是否严格晚于请求发起”，绝不依赖毫秒级墙钟（C12）。
    const requestedSeq = ++this.externalWriteCheckSeq;
    while (true) {
      const inFlight = this.externalWriteCheckInFlight;
      if (!inFlight || inFlight.turn !== boundTurn) {
        break;
      }
      const existingResult = await inFlight.promise;
      if (this.currentTurn !== boundTurn || boundTurn.finished) {
        return "ok";
      }
      if (existingResult === "conflict") {
        return "conflict";
      }
      if (existingResult === "unknown") {
        if (options.failClosedOnUnknown) {
          this.triggerExternalWriteFailure(boundTurn, boundTurnId, EXTERNAL_WRITE_VERIFY_UNKNOWN_MESSAGE, "transcript_inspect_unknown");
        }
        return "unknown";
      }
      if (!options.requireFresh || inFlight.seq > requestedSeq) {
        return "ok";
      }
    }

    const runSeq = ++this.externalWriteCheckSeq;
    const runCheck = async (): Promise<ExternalWriteCheckResult> => {
      const inspection = await this.inspectTranscript();
      if (this.currentTurn !== boundTurn || boundTurn.finished) {
        return "ok";
      }
      if (inspection.kind === "error") {
        if (options.failClosedOnUnknown) {
          this.triggerExternalWriteFailure(boundTurn, boundTurnId, EXTERNAL_WRITE_VERIFY_UNKNOWN_MESSAGE, inspection.reason);
        }
        return "unknown";
      }
      const currentBaseline = this.externalWriteBaseline ?? baseline;
      const expectedTranscript =
        currentBaseline.hasTranscript === true
        || options.approvalBaseline?.hasTranscript === true
        || [...this.pendingApprovals.values()].some((entry) => entry.turn === boundTurn && entry.baseline?.hasTranscript === true);
      if (expectedTranscript && inspection.kind === "missing") {
        if (options.failClosedOnUnknown) {
          this.triggerExternalWriteFailure(boundTurn, boundTurnId, EXTERNAL_WRITE_VERIFY_UNKNOWN_MESSAGE, "transcript_missing_unexpectedly");
        }
        return "unknown";
      }
      if (inspection.kind === "missing") {
        return "ok";
      }
      const current = inspection.snapshot;
      const baselinesToCheck: ExternalWriteBaseline[] = [currentBaseline];
      if (options.approvalBaseline) {
        baselinesToCheck.push(options.approvalBaseline);
      }
      for (const entry of this.pendingApprovals.values()) {
        if (entry.turn === boundTurn && entry.baseline) {
          baselinesToCheck.push(entry.baseline);
        }
      }
      for (const candidateBaseline of baselinesToCheck) {
        const detection = detectExternalConcurrentWrite(candidateBaseline, current);
        if (detection.detected) {
          this.triggerExternalWriteFailure(
            boundTurn,
            boundTurnId,
            EXTERNAL_WRITE_CONFLICT_MESSAGE,
            detection.reason ?? "external_write",
          );
          return "conflict";
        }
      }
      if (this.externalWriteBaseline) {
        this.externalWriteBaseline.hasTranscript = true;
      }
      return "ok";
    };

    const promise = runCheck();
    const entry = { turn: boundTurn, seq: runSeq, promise };
    this.externalWriteCheckInFlight = entry;
    try {
      return await promise;
    } finally {
      if (this.externalWriteCheckInFlight === entry) {
        this.externalWriteCheckInFlight = undefined;
      }
    }
  }

  private scheduleIdleClose(): void {
    this.cancelIdleClose();
    if (this.host.idleCloseMs <= 0) return;
    this.idleTimer = setTimeout(() => {
      if (!this.isBusy()) {
        void this.closeClient();
      }
    }, this.host.idleCloseMs);
    this.idleTimer.unref?.();
  }

  private cancelIdleClose(): void {
    if (this.idleTimer) {
      clearTimeout(this.idleTimer);
      this.idleTimer = undefined;
    }
  }

  private async closeClient(): Promise<void> {
    this.detachSessionHandlers();
    const client = this.client;
    this.client = undefined;
    this.appliedMode = undefined;
    this.appliedModel = undefined;
    this.appliedEffort = undefined;
    if (!client || client.isClosed) return;
    if (this.threadId) {
      await client.sessionClose(this.threadId).catch(() => {});
    }
  }
}
