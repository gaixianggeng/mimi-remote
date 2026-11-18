import { randomUUID } from "node:crypto";
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
import { startAgyAcpClient, type SpawnAgyTransport } from "../agy/binary.ts";
import { updatesToTurns } from "../agy/history.ts";
import { selectPermissionOption, serverApprovalFor } from "./approvals.ts";
import { LiveTurn, type TurnUsage } from "./liveTurn.ts";
import { sameProcessBoundary, type AgyRunSettings, type ExecutionPolicy } from "./settings.ts";
import { toAcpPromptBlocks } from "./userInput.ts";

export interface RuntimeHost {
  publish(threadId: string, method: string, params: Record<string, unknown>): void;
  request(threadId: string, method: string, params: Record<string, unknown>, signal: AbortSignal): Promise<unknown>;
  agyExecutable(): string;
  spawnTransport: SpawnAgyTransport;
  env(): NodeJS.ProcessEnv;
  idleCloseMs: number;
  onSessionOpen?(openResult: AcpSessionOpenResult): void;
  onAvailableCommands?(cwd: string, commands: AcpAvailableCommand[]): void;
  onTitleUpdated?(threadId: string, title: string): void;
  onTurnPersisted?(threadId: string, patch: { preview?: string; updatedAt?: number }): void;
}

export interface TurnStartRequest {
  input: UserInput[];
  clientUserMessageId: string | null;
  settings: Partial<AgyRunSettings>;
}

export class ThreadRuntime {
  private client: AcpClient | undefined;
  private appliedBoundary: ExecutionPolicy | undefined;
  private appliedMode: string | undefined;
  private appliedModel: string | undefined;
  private appliedEffort: string | undefined;
  private currentTurn: LiveTurn | undefined;
  private startingTurn = false;
  private totalUsage: TurnUsage | undefined;
  private idleTimer: ReturnType<typeof setTimeout> | undefined;
  private historyTurns: Turn[] | undefined;
  private availableCommands: AcpAvailableCommand[] | undefined;
  readonly createdAt = Math.floor(Date.now() / 1000);
  updatedAt = this.createdAt;
  title: string | null;

  constructor(
    public threadId: string,
    readonly cwd: string,
    private readonly host: RuntimeHost,
    private settings: AgyRunSettings,
    private persisted: boolean,
    initialTitle: string | null = null,
  ) {
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
    return this.historyTurns;
  }

  /**
   * 为 `thread/start` 启动新 ACP 会话并取得 `agy` 原生分配的 `sessionId`。
   */
  async initializeNewSession(): Promise<string> {
    const client = await this.ensureClient(this.settings.executionPolicy);
    const open = await client.sessionNew(this.cwd);
    this.threadId = open.sessionId;
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

      const needRestart =
        !this.client
        || this.client.isClosed
        || !this.appliedBoundary
        || !sameProcessBoundary(this.appliedBoundary, this.settings.executionPolicy);

      if (needRestart) {
        await this.closeClient();
        const client = await this.ensureClient(this.settings.executionPolicy);
        if (this.persisted) {
          const { result, updates } = await client.sessionLoadWithReplay(this.threadId, this.cwd);
          this.historyTurns = updatesToTurns(this.threadId, this.cwd, updates, false);
          this.recordSessionMeta(result);
        } else {
          // 若此前 `initializeNewSession` 的子进程因边界切换重启且还未落盘，重新 load（若已落盘）或报错。
          const { result, updates } = await client.sessionLoadWithReplay(this.threadId, this.cwd);
          this.historyTurns = updatesToTurns(this.threadId, this.cwd, updates, false);
          this.recordSessionMeta(result);
        }
      }

      const client = this.client!;
      await this.applySessionControls(client, this.settings);

      const turnId = randomUUID();
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

      void this.runPrompt(client, turn, blocks);
      return turn.snapshot(false);
    } catch (error) {
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
      const finished = turn.finish(res, undefined, this.totalUsage);
      if (finished.usage) this.totalUsage = finished.usage;
      this.historyTurns = [...(this.historyTurns ?? []), finished.turn];
    } catch (error) {
      const finished = turn.finish(undefined, errorText(error), this.totalUsage);
      this.historyTurns = [...(this.historyTurns ?? []), finished.turn];
    } finally {
      if (this.currentTurn === turn) {
        this.currentTurn = undefined;
      }
      this.updatedAt = Math.floor(Date.now() / 1000);
      this.host.onTurnPersisted?.(this.threadId, { updatedAt: this.updatedAt });
      this.host.publish(this.threadId, "thread/status/changed", {
        threadId: this.threadId,
        status: { type: "idle" },
      });
      this.scheduleIdleClose();
    }
  }

  private async ensureClient(policy: ExecutionPolicy): Promise<AcpClient> {
    if (this.client && !this.client.isClosed && this.appliedBoundary && sameProcessBoundary(this.appliedBoundary, policy)) {
      return this.client;
    }
    const addDirs = policy.type === "workspaceWrite" ? (policy.writableRoots ?? []) : [];
    const client = await startAgyAcpClient(
      this.host.spawnTransport,
      {
        executable: this.host.agyExecutable(),
        cwd: this.cwd,
        sandbox: policy.type !== "dangerFullAccess",
        skipPermissions: policy.type === "dangerFullAccess",
        addDirs,
        env: this.host.env(),
      },
      {
        onSessionUpdate: (sessionId, update) => this.handleSessionUpdate(sessionId, update),
        onRequestPermission: (params, signal) => this.handlePermissionRequest(params, signal),
        onClose: () => {
          if (this.client === client) {
            this.client = undefined;
            this.appliedBoundary = undefined;
            this.appliedMode = undefined;
            this.appliedModel = undefined;
            this.appliedEffort = undefined;
          }
        },
      },
    );
    this.client = client;
    this.appliedBoundary = policy;
    this.appliedMode = undefined;
    this.appliedModel = undefined;
    this.appliedEffort = undefined;
    return client;
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
      return selectPermissionOption(params.options, "allow_always");
    }
    if (this.settings.executionPolicy.type === "readOnly") {
      const kind = params.toolCall.kind ?? "";
      if (kind === "edit" || kind === "delete" || kind === "move" || kind === "execute") {
        return selectPermissionOption(params.options, "reject_once");
      }
    }
    const turnId = this.currentTurn?.id ?? `${this.threadId}:approval`;
    const spec = serverApprovalFor(params, { threadId: this.threadId, turnId, cwd: this.cwd });
    this.host.publish(this.threadId, "thread/status/changed", {
      threadId: this.threadId,
      status: { type: "active", activeFlags: ["waitingOnApproval"] },
    });
    try {
      const response = await this.host.request(this.threadId, spec.method, spec.params, signal);
      return spec.toAcpResult(response);
    } catch {
      return { outcome: { outcome: "cancelled" } };
    } finally {
      if (this.currentTurn && !this.currentTurn.finished) {
        this.host.publish(this.threadId, "thread/status/changed", {
          threadId: this.threadId,
          status: { type: "active", activeFlags: [] },
        });
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
    const client = this.client;
    this.client = undefined;
    this.appliedBoundary = undefined;
    this.appliedMode = undefined;
    this.appliedModel = undefined;
    this.appliedEffort = undefined;
    if (!client) return;
    if (this.threadId) {
      await client.sessionClose(this.threadId).catch(() => {});
    }
    await client.close().catch(() => {});
  }
}
