// 一个 Claude 会话的运行时：常驻的 SDK query（流式输入）+ 当前 turn。模型、权限模式、
// 思考强度在 turn 之间通过 SDK 控制接口切换，不重启进程；只有进出完全访问时重启。
import { randomUUID, type UUID } from "node:crypto";
import {
  query as sdkQuery,
  type Options,
  type PermissionResult,
  type Query,
  type SDKMessage,
} from "@anthropic-ai/claude-agent-sdk";
import type { Turn } from "../protocol/codex/v2/Turn.ts";
import type { UserInput } from "../protocol/codex/v2/UserInput.ts";
import { RpcError } from "../rpc/frames.ts";
import { serverRequestFor } from "./approvals.ts";
import { InputQueue } from "./inputQueue.ts";
import { LiveTurn, type TurnUsage } from "./liveTurn.ts";
import { rateLimitSnapshot } from "./rateLimits.ts";
import type { RunSettings } from "./settings.ts";
import { toClaudeContent } from "./userInput.ts";

export interface RuntimeHost {
  publish(threadId: string, method: string, params: Record<string, unknown>): void;
  request(threadId: string, method: string, params: Record<string, unknown>, signal: AbortSignal): Promise<unknown>;
  claudeExecutable(): string;
  log(message: string): void;
  ownPids: Set<number>;
  /** 自己的 Claude 进程拿到 pid：此前被当作"可能是自己"的登记需要重新判断。 */
  processReady(threadId: string): void;
  /** 一个 turn 收尾：Claude Code 会异步生成 AI 标题，由管理器检查并推送。 */
  turnFinished(threadId: string): void;
  idleCloseMs: number;
  /** 测试可替换；默认用 SDK 的 query。 */
  startQuery?: typeof sdkQuery;
}

export interface TurnRequest {
  input: UserInput[];
  clientUserMessageId: string | null;
  settings: Partial<RunSettings>;
}

const INVALID_PARAMS = -32602;
/** 诊断：把每条 SDK 消息的类型与归属标记写到 stderr（不含正文）。 */
const TRACE = process.env.MIMI_CLAUDE_ADAPTER_TRACE === "1";

function usageOf(raw: unknown): TurnUsage | undefined {
  if (!raw || typeof raw !== "object") return undefined;
  const usage = raw as Record<string, unknown>;
  const num = (value: unknown) => (typeof value === "number" && Number.isFinite(value) ? value : 0);
  const inputTokens = num(usage.input_tokens);
  const cachedInputTokens = num(usage.cache_read_input_tokens);
  const cacheWriteInputTokens = num(usage.cache_creation_input_tokens);
  const outputTokens = num(usage.output_tokens);
  const details = usage.output_tokens_details as Record<string, unknown> | undefined;
  return {
    inputTokens,
    cachedInputTokens,
    cacheWriteInputTokens,
    outputTokens,
    reasoningOutputTokens: num(details?.thinking_tokens),
    totalTokens: inputTokens + cachedInputTokens + cacheWriteInputTokens + outputTokens,
  };
}

function addUsage(total: TurnUsage | undefined, last: TurnUsage): TurnUsage {
  if (!total) return { ...last };
  return Object.fromEntries(
    Object.entries(last).map(([key, value]) => [key, (total[key as keyof TurnUsage] ?? 0) + value]),
  ) as unknown as TurnUsage;
}

function contextWindowOf(modelUsage: unknown): number | null {
  if (!modelUsage || typeof modelUsage !== "object") return null;
  const windows = Object.values(modelUsage as Record<string, { contextWindow?: unknown }>)
    .map((entry) => entry?.contextWindow)
    .filter((value): value is number => typeof value === "number");
  return windows.length ? Math.max(...windows) : null;
}

function threadStatus(state: unknown): Record<string, unknown> | undefined {
  if (state === "idle") return { type: "idle" };
  if (state === "running") return { type: "active", activeFlags: [] };
  if (state === "requires_action") return { type: "active", activeFlags: ["waitingOnApproval"] };
  return undefined;
}

export class ThreadRuntime {
  private query: Query | undefined;
  private input: InputQueue | undefined;
  private pump: Promise<void> | undefined;
  private applied: RunSettings | undefined;
  /** 正在接收 Claude 输出的 turn。 */
  private current: LiveTurn | undefined;
  /**
   * 已发给 Claude、尚未被某个结果吸收的用户消息（uuid → 所属 turn）。CLI 有自己的输入队列，
   * 输出与结果按消息 uuid 归属，而不是假设"一次 turn/start 对应下一个结果"。
   */
  private readonly commands = new Map<string, LiveTurn>();
  /** turn/start 等待进程就绪、切换设置期间预占的 turn ID，让并发的 turn/start 同样被拒。 */
  private reserved: string | undefined;
  private totalUsage: TurnUsage | undefined;
  private idleTimer: ReturnType<typeof setTimeout> | undefined;
  private pid: number | undefined;
  private queryStartedAt = 0;
  private settings: RunSettings;

  constructor(
    readonly threadId: string,
    readonly cwd: string,
    private readonly host: RuntimeHost,
    initial: RunSettings,
    /** transcript 是否已存在：存在就 resume，否则用 sessionId 新建同 ID 的会话。 */
    private transcriptExists: boolean,
  ) {
    this.settings = initial;
  }

  get activeTurnId(): string | undefined {
    return this.current?.id ?? this.commands.values().next().value?.id ?? this.reserved;
  }

  get currentSettings(): RunSettings {
    return this.settings;
  }

  isBusy(): boolean {
    return this.current !== undefined || this.commands.size > 0 || this.reserved !== undefined;
  }

  isLoaded(): boolean {
    return this.query !== undefined || this.isBusy();
  }

  hasLiveProcess(): boolean {
    return this.query !== undefined;
  }

  /** 进程已起、还不知道 pid 时返回起进程的时刻，见 OwnProcesses.startingSince。 */
  get startingSince(): number | undefined {
    return this.query && this.pid === undefined ? this.queryStartedAt : undefined;
  }

  /**
   * 别的进程（终端 `claude --resume`、桌面端）接手了这个会话：立即停掉自己的进程，进行中的
   * turn 记为中断。直接给 CLI 发 SIGTERM，不等 SDK 关闭输入后的宽限期，尽量不再写 transcript。
   */
  async yieldToHolder(): Promise<void> {
    if (!this.query) return;
    this.cancelIdleClose();
    for (const turn of this.openTurns()) turn.markInterrupted();
    if (this.pid !== undefined) {
      try {
        process.kill(this.pid, "SIGTERM");
      } catch {
        // 进程已经退出。
      }
    }
    await this.stopQuery();
  }

  async startTurn(request: TurnRequest): Promise<Turn> {
    // Claude 还在处理之前的消息（包括排队中的）时不接新 turn，客户端改用 turn/steer。
    const active = this.activeTurnId;
    if (active) {
      throw new RpcError(INVALID_PARAMS, `thread \`${this.threadId}\` already has active turn \`${active}\``, {
        accepted: false,
        reason: "active_turn",
        threadId: this.threadId,
        activeTurnId: active,
        retryable: false,
      });
    }
    const content = toClaudeContent(request.input);
    // 检查与预占之间没有 await：第一个异步操作之前就占住，后来的 turn/start 看到的是 active_turn。
    const turnId = randomUUID();
    this.reserved = turnId;
    try {
      this.settings = {
        model: request.settings.model ?? this.settings.model,
        effort: request.settings.effort ?? this.settings.effort,
        permissionMode: request.settings.permissionMode ?? this.settings.permissionMode,
      };
      await this.ensureQuery();
    } finally {
      this.reserved = undefined;
    }
    // 等待切换设置期间别处接手、进程已让出：不开 turn，客户端按持有方提示处理。
    if (!this.input) {
      throw new RpcError(INVALID_PARAMS, `thread \`${this.threadId}\` was continued by another local claude process`, {
        accepted: false,
        reason: "owned_elsewhere",
        threadId: this.threadId,
        retryable: true,
      });
    }
    const turn = new LiveTurn(turnId, this.threadId, this.emit);
    this.current = turn;
    this.commands.set(turnId, turn);
    this.cancelIdleClose();
    turn.begin();
    turn.userMessage(turnId, request.clientUserMessageId, request.input);
    // 用户消息的 uuid 取 turn ID：transcript 里这条记录就是历史 turn 的锚点，实时与历史 ID 一致。
    this.input!.push({ type: "user", message: { role: "user", content }, parent_tool_use_id: null, uuid: turnId as UUID });
    return turn.snapshot();
  }

  /**
   * 运行中补充输入：以人工输入的 now 优先级并入当前 turn（同一个结果收尾）。next 优先级在
   * 没有工具调用时会被推迟成下一轮，与"引导当前 turn"的语义不符。
   */
  steer(expectedTurnId: string, input: UserInput[], clientUserMessageId: string | null): { turnId: string } {
    const turn = this.current;
    if (!turn || !this.input) throw new RpcError(INVALID_PARAMS, `thread \`${this.threadId}\` has no active turn`);
    if (turn.id !== expectedTurnId) {
      throw new RpcError(INVALID_PARAMS, `active turn is \`${turn.id}\`, not \`${expectedTurnId}\``, {
        reason: "turn_id_mismatch",
        activeTurnId: turn.id,
      });
    }
    const content = toClaudeContent(input);
    const id = randomUUID();
    turn.userMessage(id, clientUserMessageId, input);
    this.commands.set(id, turn);
    this.input.push({
      type: "user",
      message: { role: "user", content },
      parent_tool_use_id: null,
      uuid: id as UUID,
      priority: "now",
      origin: { kind: "human" },
    });
    return { turnId: turn.id };
  }

  async interrupt(turnId: string): Promise<void> {
    // 结果已吸收首条消息、引导还没开始输出时 current 暂时为空，turn 仍挂在 commands 名下。
    const turn =
      this.current?.id === turnId ? this.current : [...this.commands.values()].find((owner) => owner.id === turnId);
    if (!turn || turn.finished || !this.query) return;
    turn.markInterrupted();
    // 中断产生的结果要落到这个 turn 上收尾。
    this.current ??= turn;
    await this.query.interrupt();
  }

  async close(): Promise<void> {
    this.cancelIdleClose();
    await this.stopQuery();
  }

  private readonly emit = (method: string, params: Record<string, unknown>) =>
    this.host.publish(this.threadId, method, params);

  private async ensureQuery(): Promise<void> {
    const wanted = this.settings;
    const applied = this.applied;
    const fullAccessChanged =
      applied !== undefined && (applied.permissionMode === "bypassPermissions") !== (wanted.permissionMode === "bypassPermissions");
    if (this.query && fullAccessChanged) await this.stopQuery();
    const query = this.query;
    if (!query) {
      this.startQuery(wanted);
      return;
    }
    const steps: Array<() => Promise<unknown>> = [];
    if (wanted.model && wanted.model !== applied?.model) steps.push(() => query.setModel(wanted.model));
    if (wanted.permissionMode !== applied?.permissionMode) steps.push(() => query.setPermissionMode(wanted.permissionMode));
    if (wanted.effort && wanted.effort !== applied?.effort) steps.push(() => query.applyFlagSettings({ effortLevel: wanted.effort }));
    try {
      for (const step of steps) {
        // 切换途中进程被关闭（让出给别处）：不再对旧进程发控制请求，由调用方处理。
        if (this.query !== query) return;
        await step();
      }
    } catch (error) {
      if (this.query === query) throw error;
      return;
    }
    if (this.query === query) this.applied = { ...wanted };
  }

  private startQuery(settings: RunSettings): void {
    const input = new InputQueue();
    const options: Options = {
      cwd: this.cwd,
      includePartialMessages: true,
      pathToClaudeCodeExecutable: this.host.claudeExecutable(),
      // 与 CLI 相同的系统提示词；SDK 省略时发的是空的自定义提示词。
      systemPrompt: { type: "preset", preset: "claude_code" },
      permissionMode: settings.permissionMode,
      ...(settings.permissionMode === "bypassPermissions" ? { allowDangerouslySkipPermissions: true } : {}),
      ...(settings.model ? { model: settings.model } : {}),
      ...(settings.effort ? { effort: settings.effort } : {}),
      ...(this.transcriptExists ? { resume: this.threadId } : { sessionId: this.threadId }),
      canUseTool: (toolName, toolInput, context) => this.canUseTool(toolName, toolInput, context),
      env: { ...process.env, CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS: "1" },
      stderr: (data) => this.host.log(`claude[${this.threadId.slice(0, 8)}]: ${data.trimEnd()}`),
    };
    const query = (this.host.startQuery ?? sdkQuery)({ prompt: input, options });
    this.query = query;
    this.input = input;
    this.queryStartedAt = Date.now();
    this.applied = { ...settings };
    this.transcriptExists = true;
    void query
      .initializationResult()
      .then((result) => {
        const pid = (result as { pid?: unknown }).pid;
        if (typeof pid === "number" && this.query === query) {
          this.pid = pid;
          this.host.ownPids.add(pid);
          this.host.processReady(this.threadId);
        }
      })
      .catch(() => {});
    this.pump = this.runPump(query);
  }

  private async runPump(query: Query): Promise<void> {
    try {
      for await (const message of query) this.onMessage(message);
    } catch (error) {
      this.host.log(`thread ${this.threadId} query failed: ${error instanceof Error ? error.message : String(error)}`);
    } finally {
      if (this.query === query) {
        this.query = undefined;
        this.input = undefined;
        this.applied = undefined;
        if (this.pid !== undefined) this.host.ownPids.delete(this.pid);
        this.pid = undefined;
        // 进程退出（意外或让出）：结束悬着的 turn，包括只挂着排队引导的 turn。下一次
        // turn/start 会以 resume 重新拉起。
        const turns = this.openTurns();
        this.current = undefined;
        this.commands.clear();
        for (const turn of turns) {
          turn.finish({ subtype: "error_process_exited", errors: ["Claude 进程已退出"], usage: undefined, contextWindow: null }, this.totalUsage);
        }
      }
    }
  }

  private async stopQuery(): Promise<void> {
    const query = this.query;
    if (!query) return;
    this.input?.close();
    query.close();
    await this.pump;
  }

  /**
   * 输出归属：每一轮输出的第一帧带 user_message_uuid，指明它回应的是哪条消息。
   * 没有 uuid 的输出（后台任务完成后 Claude 自己继续）开一个没有用户消息的 turn。
   */
  private turnFor(record: Record<string, unknown>): LiveTurn {
    const uuid = typeof record.user_message_uuid === "string" ? record.user_message_uuid : undefined;
    const owner = uuid ? this.commands.get(uuid) : undefined;
    if (owner && owner !== this.current) {
      if (owner.finished) {
        // 该消息所属的 turn 已结束（例如引导被推迟成单独一轮）：开一个延续 turn 承接输出。
        const continuation = this.openTurn();
        this.commands.set(uuid!, continuation);
        return continuation;
      }
      this.current = owner;
    }
    return this.current ?? this.openTurn();
  }

  private openTurns(): LiveTurn[] {
    const turns = new Set<LiveTurn>(this.commands.values());
    if (this.current) turns.add(this.current);
    return [...turns].filter((turn) => !turn.finished);
  }

  private openTurn(): LiveTurn {
    const turn = new LiveTurn(randomUUID(), this.threadId, this.emit);
    this.current = turn;
    this.cancelIdleClose();
    turn.begin();
    return turn;
  }

  private onMessage(message: SDKMessage): void {
    const record = message as unknown as Record<string, unknown>;
    if (TRACE) this.trace(record);
    // 子代理内部的消息不进主时间线（历史侧同样只取主链）。
    if (record.parent_tool_use_id) return;
    switch (message.type) {
      case "stream_event":
        this.turnFor(record).onStreamEvent(record.event as Record<string, unknown>);
        return;
      case "assistant":
        this.turnFor(record).onAssistant(record.message as Record<string, unknown>, this.threadId);
        return;
      case "user":
        if (!record.isReplay) this.current?.onUserMessage(record.message as Record<string, unknown>);
        return;
      case "result": {
        const consumed = Array.isArray(record.user_message_uuids)
          ? record.user_message_uuids.map(String)
          : typeof record.user_message_uuid === "string"
            ? [record.user_message_uuid]
            : [];
        for (const uuid of consumed) this.commands.delete(uuid);
        const turn = this.current;
        this.current = undefined;
        if (!turn) return;
        const usage = usageOf(record.usage);
        if (usage) this.totalUsage = addUsage(this.totalUsage, usage);
        // 这个 turn 名下还有没被回应的引导消息：Claude 会接着处理它们，turn 不收尾。
        // 用户明确中断时例外，立即收尾。
        const pendingSteer = [...this.commands.values()].some((owner) => owner === turn);
        if (consumed.length && pendingSteer && !turn.explicitlyInterrupted) {
          turn.continueAfterSteer();
          return;
        }
        // 旧版 CLI 不回报 uuid，或用户已中断：结束当前 turn 名下的全部消息。
        for (const [uuid, owner] of this.commands) if (owner === turn) this.commands.delete(uuid);
        const errors = Array.isArray(record.errors) ? record.errors.map(String) : [];
        turn.finish({ subtype: String(record.subtype), errors, usage, contextWindow: contextWindowOf(record.modelUsage) }, this.totalUsage);
        this.host.turnFinished(this.threadId);
        this.scheduleIdleClose();
        return;
      }
      case "system":
        if (record.subtype === "compact_boundary") this.turnFor(record).onCompactBoundary(String(record.uuid));
        else if (record.subtype === "session_state_changed") {
          const status = threadStatus(record.state);
          if (status) this.emit("thread/status/changed", { threadId: this.threadId, status });
        }
        return;
      case "rate_limit_event": {
        const snapshot = rateLimitSnapshot(record.rate_limit_info);
        if (snapshot) this.emit("account/rateLimits/updated", { rateLimits: snapshot });
        return;
      }
      default:
        return;
    }
  }

  private trace(record: Record<string, unknown>): void {
    const event = record.event as { type?: unknown } | undefined;
    const fields = [
      String(record.type),
      record.subtype ?? event?.type ?? "",
      record.user_message_uuid ? `uuid=${String(record.user_message_uuid).slice(0, 8)}` : "",
      Array.isArray(record.user_message_uuids) ? `uuids=${record.user_message_uuids.map((id) => String(id).slice(0, 8)).join(",")}` : "",
      `current=${this.current?.id.slice(0, 8) ?? "-"}`,
    ];
    this.host.log(`trace ${this.threadId.slice(0, 8)} ${fields.filter(Boolean).join(" ")}`);
  }

  private async canUseTool(
    toolName: string,
    input: Record<string, unknown>,
    context: Parameters<NonNullable<Options["canUseTool"]>>[2],
  ): Promise<PermissionResult> {
    const turn = this.current;
    if (!turn) return { behavior: "deny", message: "no active turn to approve this tool call" };
    const spec = serverRequestFor(
      {
        toolName,
        input,
        toolUseID: context.toolUseID,
        ...(context.suggestions ? { suggestions: context.suggestions } : {}),
        ...(context.decisionReason ? { decisionReason: context.decisionReason } : {}),
        ...(context.blockedPath ? { blockedPath: context.blockedPath } : {}),
      },
      { threadId: this.threadId, turnId: turn.id, cwd: this.cwd },
    );
    try {
      return spec.toResult(await this.host.request(this.threadId, spec.method, spec.params, context.signal));
    } catch {
      return { behavior: "deny", message: "approval request was cancelled" };
    }
  }

  private scheduleIdleClose(): void {
    this.cancelIdleClose();
    this.idleTimer = setTimeout(() => {
      if (!this.isBusy()) void this.stopQuery();
    }, this.host.idleCloseMs);
    this.idleTimer.unref?.();
  }

  private cancelIdleClose(): void {
    if (this.idleTimer) clearTimeout(this.idleTimer);
    this.idleTimer = undefined;
  }
}
