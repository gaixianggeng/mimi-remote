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
import {
  detectExternalConcurrentWrite,
  type ExternalWriteBaseline,
  type TranscriptActivityInfo,
  type TranscriptTurnSnapshot,
} from "../agy/transcript.ts";
import { desktopOwnerSummary } from "../handlers/threads.ts";
import { selectPermissionOption, serverApprovalFor } from "./approvals.ts";
import { LiveTurn, type TurnUsage } from "./liveTurn.ts";
import type { AgyRunSettings } from "./settings.ts";
import { toAcpPromptBlocks } from "./userInput.ts";

export const EXTERNAL_WRITE_CONFLICT_MESSAGE =
  "Another Antigravity process on this computer wrote to this session; this turn and any pending approval were stopped to avoid conflicting changes. Refresh to view the latest messages.";

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
  onTurnPersisted?(threadId: string, patch: { preview?: string; updatedAt?: number }): void;
  existingTurnCount?(threadId: string): Promise<number>;
  recordTurnClientId?(turnId: string, clientId: string): void;
  inspectTranscriptState?(threadId: string): Promise<TranscriptTurnSnapshot | undefined>;
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
  private startingTurn = false;
  private totalUsage: TurnUsage | undefined;
  private idleTimer: ReturnType<typeof setTimeout> | undefined;
  private externalWriteTimer: ReturnType<typeof setInterval> | undefined;
  private externalWriteChecking = false;
  private externalWriteBaseline: ExternalWriteBaseline | undefined;
  private externalWriteConflict: string | undefined;
  private approvalAbortController: AbortController | undefined;
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
    this.recordSessionMeta(open);
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
        this.recordSessionMeta(result);
      }

      const client = this.client!;
      await this.applySessionControls(client, this.settings);

      const diskTurnCount = this.persisted ? ((await this.host.existingTurnCount?.(this.threadId).catch(() => 0)) ?? 0) : 0;
      const nextTurnIndex = Math.max(this.historyTurns?.length ?? 0, diskTurnCount) + 1;
      const turnId = `${this.threadId}:turn:${nextTurnIndex}`;
      if (req.clientUserMessageId) {
        this.host.recordTurnClientId?.(turnId, req.clientUserMessageId);
      }
      turn = new LiveTurn(turnId, this.threadId, this.cwd, (method, params) => {
        this.host.publish(this.threadId, method, params);
      });
      this.currentTurn = turn;
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

      const initialSnapshot = await this.host.inspectTranscriptState?.(this.threadId).catch(() => undefined);
      this.externalWriteConflict = undefined;
      this.externalWriteBaseline = {
        userInputCount: initialSnapshot?.userInputs.length ?? 0,
        expectedPromptText: preview,
      };
      this.startExternalWriteMonitor();

      void this.runPrompt(client, turn, blocks);
      return turn.snapshot(false);
    } catch (error) {
      this.stopExternalWriteMonitor();
      this.externalWriteBaseline = undefined;
      this.externalWriteConflict = undefined;
      this.startingTurn = false;
      this.currentTurn = undefined;
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
    this.approvalAbortController?.abort();
    this.approvalAbortController = undefined;
    if (this.currentTurn && !this.currentTurn.finished) {
      this.currentTurn.markInterrupted();
      const { turn } = this.currentTurn.finish(undefined, "session closed", this.totalUsage);
      this.historyTurns = [...(this.historyTurns ?? []), turn];
      this.currentTurn = undefined;
    }
    await this.closeClient();
  }

  private async runPrompt(
    client: AcpClient,
    turn: LiveTurn,
    blocks: Parameters<AcpClient["sessionPrompt"]>[1],
  ): Promise<void> {
    try {
      const res = await client.sessionPrompt(this.threadId, blocks);
      this.persisted = true;
      const conflict = this.externalWriteConflict;
      const finished = turn.finish(res, conflict, this.totalUsage);
      if (finished.usage) this.totalUsage = finished.usage;
      this.historyTurns = [...(this.historyTurns ?? []), finished.turn];
    } catch (error) {
      const conflict = this.externalWriteConflict;
      if (conflict) this.persisted = true;
      const finished = turn.finish(undefined, conflict ?? errorText(error), this.totalUsage);
      this.historyTurns = [...(this.historyTurns ?? []), finished.turn];
    } finally {
      this.stopExternalWriteMonitor();
      this.externalWriteBaseline = undefined;
      const hadConflict = Boolean(this.externalWriteConflict);
      this.externalWriteConflict = undefined;
      if (this.currentTurn === turn) {
        this.currentTurn = undefined;
      }
      this.updatedAt = Math.floor(Date.now() / 1000);
      this.host.onTurnPersisted?.(this.threadId, { updatedAt: this.updatedAt });
      const ext = hadConflict
        ? await this.host.externalActivity?.(this.threadId).catch(() => undefined)
        : undefined;
      if (ext?.externallyBusy) {
        this.host.publish(this.threadId, "thread/status/changed", {
          threadId: this.threadId,
          status: { type: "active", activeFlags: [] },
          canAcceptDirectInput: false,
          claudeOwner: desktopOwnerSummary(ext.mtimeMs),
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

  private recordSessionMeta(open: AcpSessionOpenResult): void {
    this.host.onSessionOpen?.(open);
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
    const turnId = this.currentTurn?.id ?? `${this.threadId}:approval`;
    const spec = serverApprovalFor(params, { threadId: this.threadId, turnId, cwd: this.cwd });
    if (await this.checkExternalWriteConflict()) {
      return { outcome: { outcome: "cancelled" } };
    }
    if (this.externalWriteBaseline) {
      const preApproval = await this.host.inspectTranscriptState?.(this.threadId).catch(() => undefined);
      if (preApproval) {
        this.externalWriteBaseline = {
          ...this.externalWriteBaseline,
          approvalUserInputCount: preApproval.userInputs.length,
          approvalPlannerResponseCount: preApproval.plannerResponseCount,
        };
      }
    }
    const localAbort = new AbortController();
    const onUpstreamAbort = () => localAbort.abort();
    signal.addEventListener("abort", onUpstreamAbort, { once: true });
    this.approvalAbortController = localAbort;
    this.host.publish(this.threadId, "thread/status/changed", {
      threadId: this.threadId,
      status: { type: "active", activeFlags: ["waitingOnApproval"] },
    });
    try {
      const response = await this.host.request(this.threadId, spec.method, spec.params, localAbort.signal);
      if (await this.checkExternalWriteConflict()) {
        return { outcome: { outcome: "cancelled" } };
      }
      return spec.toAcpResult(response);
    } catch {
      return { outcome: { outcome: "cancelled" } };
    } finally {
      signal.removeEventListener("abort", onUpstreamAbort);
      if (this.approvalAbortController === localAbort) {
        this.approvalAbortController = undefined;
      }
      if (this.externalWriteBaseline) {
        this.externalWriteBaseline = {
          userInputCount: this.externalWriteBaseline.userInputCount,
          expectedPromptText: this.externalWriteBaseline.expectedPromptText,
        };
      }
      if (this.currentTurn && !this.currentTurn.finished && !this.externalWriteConflict) {
        this.host.publish(this.threadId, "thread/status/changed", {
          threadId: this.threadId,
          status: { type: "active", activeFlags: [] },
        });
      }
    }
  }

  private startExternalWriteMonitor(): void {
    this.stopExternalWriteMonitor();
    if (!this.host.inspectTranscriptState) return;
    const pollMs = this.host.externalWritePollMs ?? DEFAULT_EXTERNAL_WRITE_POLL_MS;
    if (pollMs <= 0) return;
    this.externalWriteTimer = setInterval(() => {
      void this.checkExternalWriteConflict();
    }, pollMs);
    this.externalWriteTimer.unref?.();
  }

  private stopExternalWriteMonitor(): void {
    if (this.externalWriteTimer) {
      clearInterval(this.externalWriteTimer);
      this.externalWriteTimer = undefined;
    }
  }

  private async checkExternalWriteConflict(): Promise<boolean> {
    if (this.externalWriteConflict) return true;
    const baseline = this.externalWriteBaseline;
    if (!baseline || !this.currentTurn || this.currentTurn.finished || !this.host.inspectTranscriptState) {
      return false;
    }
    if (this.externalWriteChecking) return false;
    this.externalWriteChecking = true;
    try {
      const current = await this.host.inspectTranscriptState(this.threadId).catch(() => undefined);
      const detection = detectExternalConcurrentWrite(baseline, current);
      if (!detection.detected) return false;
      this.externalWriteConflict = EXTERNAL_WRITE_CONFLICT_MESSAGE;
      logger.info("agy.concurrent_write.detected", {
        thread: this.threadId,
        turn: this.currentTurn.id,
        reason: detection.reason ?? "external_write",
      });
      this.stopExternalWriteMonitor();
      this.approvalAbortController?.abort();
      this.client?.sessionCancel(this.threadId);
      return true;
    } finally {
      this.externalWriteChecking = false;
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
