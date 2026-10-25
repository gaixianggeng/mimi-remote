// 一个 Claude 会话的运行时：常驻的 SDK query（流式输入）+ 当前 turn。模型、权限模式、
// 思考强度在 turn 之间通过 SDK 控制接口切换，不重启进程；执行边界变化时重启。
import { randomUUID, type UUID } from "node:crypto";
import {
  query as sdkQuery,
  type Options,
  type PermissionResult,
  type Query,
  type SDKMessage,
  type SlashCommand,
} from "@anthropic-ai/claude-agent-sdk";
import type { Turn } from "../protocol/codex/v2/Turn.ts";
import type { UserInput } from "../protocol/codex/v2/UserInput.ts";
import { notificationTurnId } from "../claude/itemIds.ts";
import { runsAsClaudeCommand } from "../claude/skillCommand.ts";
import { claudeConfigDir } from "../claude/transcripts.ts";
import { promptSuggestionsAllowed } from "../claude/promptSuggestions.ts";
import { RpcError } from "../rpc/frames.ts";
import { serverRequestFor } from "./approvals.ts";
import { InputQueue } from "./inputQueue.ts";
import { LiveTurn, type TurnUsage } from "./liveTurn.ts";
import { rateLimitSnapshot } from "./rateLimits.ts";
import { createSkillPlugin, type SkillPlugin } from "../claude/skillPlugin.ts";
import { type ExecutionPolicy, sandboxOptions } from "./sandboxPolicy.ts";
import type { RunSettings } from "./settings.ts";
import { qualifySkillCommand, type SkillCheck, toClaudeContent } from "./userInput.ts";
import { errorText, logEnabled, logger } from "../util/logging.ts";
import {
  MIMI_TURN_HINT_SYSTEM_PROMPT,
  mimiTurnHintServers,
  type MimiTaskProposalStore,
} from "./turnHints.ts";

export interface RuntimeHost {
  publish(threadId: string, method: string, params: Record<string, unknown>): void;
  request(threadId: string, method: string, params: Record<string, unknown>, signal: AbortSignal): Promise<unknown>;
  claudeExecutable(): string;
  promptSuggestionsSupported?(): boolean;
  log(message: string): void;
  ownPids: Set<number>;
  /** 自己的 Claude 进程拿到 pid：此前被当作"可能是自己"的登记需要重新判断。 */
  processReady(threadId: string): void;
  /** 一个 turn 收尾：Claude Code 会异步生成 AI 标题，由管理器检查并推送。 */
  turnFinished(threadId: string): void;
  /** system/init 里 CLI 标为终端专用的命令名，命令目录据此隐藏。 */
  terminalCommands?(names: string[]): void;
  idleCloseMs: number;
  turnHints?: {
    store: MimiTaskProposalStore & { isTaskProposal(parentThreadId: string, proposalId: string): boolean };
  };
  /** 测试可替换；默认用 SDK 的 query。 */
  startQuery?: typeof sdkQuery;
}

export interface TurnRequest {
  input: UserInput[];
  clientUserMessageId: string | null;
  settings: Partial<RunSettings>;
}

const INVALID_PARAMS = -32602;

/** 主动结束进程的原因：空闲回收、让出给别处持有方、执行边界变化重启、适配器退出。 */
type StopReason = "idle" | "yield" | "restart" | "close";

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
  /** 原生建议不带 turn ID；只承接本进程最后一个成功结果，任何新输入或续写都会作废。 */
  private suggestionTurnId: string | undefined;
  private promptSuggestionsEnabled = false;
  /**
   * 已发给 Claude、尚未被某个结果吸收的用户消息（uuid → 所属 turn）。CLI 有自己的输入队列，
   * 输出与结果按消息 uuid 归属，而不是假设"一次 turn/start 对应下一个结果"。
   */
  private readonly commands = new Map<string, LiveTurn>();
  /** turn/start 等待进程就绪、切换设置期间预占的 turn ID，让并发的 turn/start 同样被拒。 */
  private reserved: string | undefined;
  private totalUsage: TurnUsage | undefined;
  private idleTimer: ReturnType<typeof setTimeout> | undefined;
  /**
   * 进程里仍在运行的后台任务（Bash run_in_background、后台子代理等），取自 background_tasks_changed，
   * 不含 ambient 任务。任务属于这个进程：进程一关就随之结束，完成通知触发的续写也不会发生（#796）。
   * 按进程计，进程起停时清空。
   */
  private backgroundTasks: ReadonlySet<string> = new Set();
  /**
   * CLI 自己报告的会话状态（session_state_changed）是否为执行中。完成通知触发的续写在第一帧输出前还没有
   * turn，排队、重试时这段可能很长；CLI 报 running 期间同样不做空闲关闭。按进程计。
   */
  private cliActive = false;
  /**
   * 最近送达、还没有续写认领的后台任务完成通知的 run_id（#797）。续写的输出不带 user_message_uuid，
   * 回合 ID 按 notificationTurnId 由它生成，与历史切分规则一致。按进程计。
   */
  private notificationRunId: string | undefined;
  /** 由完成通知开出、还没收尾的续写回合，以及它认领的 run_id。 */
  private continuation: { turn: LiveTurn; runId: string } | undefined;
  private pid: number | undefined;
  private queryStartedAt = 0;
  private settings: RunSettings;
  /** 当前受限进程加载的技能插件；进程退出后删除。 */
  private skillPlugin: SkillPlugin | undefined;

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

  /** 已有 transcript（resume 打开，或已经起过进程）：移除后 resume 能按同一 ID 重建。 */
  get persisted(): boolean {
    return this.transcriptExists;
  }

  /** 没有进程、也没有进行中或预占的 turn：管理器可以移除它，之后 resume 会重建（#911）。 */
  isReclaimable(): boolean {
    return this.query === undefined && !this.isBusy();
  }

  /**
   * 常驻进程的命令目录（含 MCP 命令与运行中发现的技能）。只在进程的设置来源与请求一致时可用：
   * 受限档位不加载本机设置，两种进程认识的命令不同。
   */
  liveCommands(loadsSettings: boolean): Promise<SlashCommand[]> | undefined {
    if (!this.query || !this.applied) return undefined;
    if ((this.applied.executionPolicy.type === "dangerFullAccess") !== loadsSettings) return undefined;
    return this.query.supportedCommands();
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
    logger.debug("claude.yield", { thread: this.threadId, pid: this.pid ?? null, openTurns: this.openTurns().length });
    this.cancelIdleClose();
    for (const turn of this.openTurns()) turn.markInterrupted();
    if (this.pid !== undefined) {
      try {
        process.kill(this.pid, "SIGTERM");
      } catch {
        // 进程已经退出。
      }
    }
    await this.stopQuery("yield");
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
    const promoted = new Set<string>();
    const content = toClaudeContent(request.input, this.skillCheck(promoted));
    // 检查与预占之间没有 await：第一个异步操作之前就占住，后来的 turn/start 看到的是 active_turn。
    const turnId = randomUUID();
    this.suggestionTurnId = undefined;
    this.reserved = turnId;
    const previousSettings = this.settings;
    try {
      this.settings = {
        model: request.settings.model ?? this.settings.model,
        effort: request.settings.effort ?? this.settings.effort,
        permissionMode: request.settings.permissionMode ?? this.settings.permissionMode,
        executionPolicy: request.settings.executionPolicy ?? this.settings.executionPolicy,
      };
      await this.ensureQuery();
    } catch (error) {
      this.settings = previousSettings;
      throw error;
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
    // 进程可能刚按新的执行边界重启，按它的档位与实际加载的技能改写命令。
    const message = this.commandFor(content, promoted);
    const turn = this.makeLiveTurn(turnId);
    this.current = turn;
    this.commands.set(turnId, turn);
    logger.debug("turn.start", { thread: this.threadId, turn: turnId, model: this.settings.model ?? null });
    this.cancelIdleClose();
    turn.begin();
    turn.userMessage(turnId, request.clientUserMessageId, request.input);
    // 用户消息的 uuid 取 turn ID：transcript 里这条记录就是历史 turn 的锚点，实时与历史 ID 一致。
    this.input!.push({ type: "user", message: { role: "user", content: message }, parent_tool_use_id: null, uuid: turnId as UUID });
    return turn.snapshot();
  }

  /**
   * 运行中补充输入：以人工输入的 now 优先级并入当前 turn（同一个结果收尾）。next 优先级在
   * 没有工具调用时会被推迟成下一轮，与"引导当前 turn"的语义不符。
   */
  steer(expectedTurnId: string, input: UserInput[], clientUserMessageId: string | null): { turnId: string } {
    // 引导打断输出后，结果只吸收了首条消息、引导还没开始输出：current 暂时为空，turn 仍挂在
    // commands 名下，turn/start 也以它拒绝。这时的引导同样并入它（#798）。
    const turn = this.current ?? [...this.commands.values()].find((owner) => !owner.finished);
    if (!turn || !this.input) throw new RpcError(INVALID_PARAMS, `thread \`${this.threadId}\` has no active turn`);
    if (turn.id !== expectedTurnId) {
      throw new RpcError(INVALID_PARAMS, `active turn is \`${turn.id}\`, not \`${expectedTurnId}\``, {
        reason: "turn_id_mismatch",
        activeTurnId: turn.id,
      });
    }
    const promoted = new Set<string>();
    const content = this.commandFor(toClaudeContent(input, this.skillCheck(promoted)), promoted);
    const id = randomUUID();
    this.suggestionTurnId = undefined;
    logger.debug("turn.steer", { thread: this.threadId, turn: turn.id, message: id });
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

  /**
   * 技能附件能否写成开头的 `/名称`。受限档位不加载用户与项目设置，这些技能改经合成插件加载，查找范围与
   * 优先顺序和完全访问档相同（见 claude/skillPlugin），所以两档用同一条规则；promoted 记下提前的技能名。
   */
  private skillCheck(promoted: Set<string>): SkillCheck {
    const configDir = claudeConfigDir();
    return (skill) => {
      const runs = runsAsClaudeCommand(skill, this.cwd, configDir);
      if (runs) promoted.add(skill.name);
      return runs;
    };
  }

  /**
   * 受限档位的技能在 CLI 里登记为 `mimi:名称`，开头的 `/名称` 改写成带前缀的形式。提前的技能即使插件没能
   * 生成也带前缀：CLI 找不到时按原文交给模型（实测），不会落到同名的内置命令或自带技能上。
   */
  private commandFor(content: ReturnType<typeof toClaudeContent>, promoted: ReadonlySet<string>): ReturnType<typeof toClaudeContent> {
    if (this.settings.executionPolicy.type === "dangerFullAccess") return content;
    return qualifySkillCommand(content, new Set([...promoted, ...(this.skillPlugin?.names ?? [])]));
  }

  async interrupt(turnId: string): Promise<void> {
    this.suggestionTurnId = undefined;
    // 结果已吸收首条消息、引导还没开始输出时 current 暂时为空，turn 仍挂在 commands 名下。
    const turn =
      this.current?.id === turnId ? this.current : [...this.commands.values()].find((owner) => owner.id === turnId);
    logger.debug("turn.interrupt", { thread: this.threadId, turn: turnId, found: Boolean(turn && !turn.finished), process: Boolean(this.query) });
    if (!turn || turn.finished || !this.query) return;
    turn.markInterrupted();
    // 中断产生的结果要落到这个 turn 上收尾。
    this.current ??= turn;
    await this.query.interrupt();
  }

  async close(): Promise<void> {
    this.cancelIdleClose();
    await this.stopQuery("close");
  }

  private readonly emit = (method: string, params: Record<string, unknown>) =>
    this.host.publish(this.threadId, method, params);

  private async ensureQuery(): Promise<void> {
    const wanted = this.settings;
    const applied = this.applied;
    const fullAccessChanged =
      applied !== undefined && (applied.permissionMode === "bypassPermissions") !== (wanted.permissionMode === "bypassPermissions");
    const policyChanged = applied !== undefined && JSON.stringify(applied.executionPolicy) !== JSON.stringify(wanted.executionPolicy);
    if (this.query && (fullAccessChanged || policyChanged)) await this.stopQuery("restart");
    const query = this.query;
    if (!query) {
      await this.startQuery(wanted);
      return;
    }
    const steps: Array<() => Promise<unknown>> = [];
    logger.debug("claude.settings", {
      thread: this.threadId,
      model: wanted.model && wanted.model !== applied?.model ? wanted.model : undefined,
      permission: wanted.permissionMode !== applied?.permissionMode ? wanted.permissionMode : undefined,
      effort: wanted.effort && wanted.effort !== applied?.effort ? wanted.effort : undefined,
    });
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

  private async startQuery(settings: RunSettings): Promise<void> {
    const skillPlugin = await this.skillPluginFor(settings.executionPolicy);
    let policyOptions: Partial<Options>;
    try {
      policyOptions = await sandboxOptions(settings.executionPolicy, this.cwd, process.platform, skillPlugin?.path);
    } catch (error) {
      await skillPlugin?.dispose().catch(() => {});
      throw error;
    }
    const input = new InputQueue();
    const turnHintServers = this.host.turnHints
      ? mimiTurnHintServers(this.threadId, this.cwd, this.host.turnHints.store)
      : undefined;
    const promptSuggestions = this.host.promptSuggestionsSupported?.()
      && await promptSuggestionsAllowed(claudeConfigDir(), this.cwd);
    const options: Options = {
      ...policyOptions,
      cwd: this.cwd,
      includePartialMessages: true,
      // 不覆盖用户/组织的关闭配置，也不设置强制启用建议的环境变量。
      ...(promptSuggestions ? { promptSuggestions: true } : {}),
      pathToClaudeCodeExecutable: this.host.claudeExecutable(),
      // 与 CLI 相同的系统提示词；SDK 省略时发的是空的自定义提示词。
      systemPrompt: {
        type: "preset",
        preset: "claude_code",
        ...(turnHintServers ? { append: MIMI_TURN_HINT_SYSTEM_PROMPT } : {}),
      },
      ...(turnHintServers ? { mcpServers: turnHintServers } : {}),
      permissionMode: settings.permissionMode,
      ...(settings.permissionMode === "bypassPermissions" ? { allowDangerouslySkipPermissions: true } : {}),
      ...(settings.model ? { model: settings.model } : {}),
      ...(settings.effort ? { effort: settings.effort } : {}),
      ...(this.transcriptExists ? { resume: this.threadId } : { sessionId: this.threadId }),
      canUseTool: (toolName, toolInput, context) => this.canUseTool(toolName, toolInput, context),
      env: { ...process.env, CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS: "1" },
      stderr: (data) => logger.debug("claude.stderr", { thread: this.threadId, text: data.trimEnd().slice(0, 500) }),
    };
    logger.debug("claude.start", {
      thread: this.threadId,
      mode: this.transcriptExists ? "resume" : "new",
      cwd: this.cwd,
      model: settings.model ?? null,
      permission: settings.permissionMode,
      effort: settings.effort ?? null,
    });
    const query = (this.host.startQuery ?? sdkQuery)({ prompt: input, options });
    this.query = query;
    this.promptSuggestionsEnabled = promptSuggestions === true;
    this.input = input;
    this.skillPlugin = skillPlugin;
    this.queryStartedAt = Date.now();
    this.backgroundTasks = new Set();
    this.cliActive = false;
    this.notificationRunId = undefined;
    this.continuation = undefined;
    this.applied = { ...settings };
    this.transcriptExists = true;
    void query
      .initializationResult()
      .then((result) => {
        const pid = (result as { pid?: unknown }).pid;
        if (typeof pid === "number" && this.query === query) {
          this.pid = pid;
          this.host.ownPids.add(pid);
          logger.debug("claude.ready", { thread: this.threadId, pid, ms: Date.now() - this.queryStartedAt });
          this.host.processReady(this.threadId);
        }
      })
      .catch(() => {});
    this.pump = this.runPump(query, skillPlugin);
  }

  /**
   * 受限档位不加载设置来源，用户与项目技能改经合成插件加载（#775）。生成失败只是少了技能，
   * 不影响执行边界，记日志后照常启动。
   */
  private async skillPluginFor(policy: ExecutionPolicy): Promise<SkillPlugin | undefined> {
    if (policy.type === "dangerFullAccess") return undefined;
    try {
      return await createSkillPlugin(this.cwd, claudeConfigDir());
    } catch (error) {
      logger.warn("claude.skills_unavailable", { thread: this.threadId, error: errorText(error) });
      return undefined;
    }
  }

  private async runPump(query: Query, skillPlugin: SkillPlugin | undefined): Promise<void> {
    try {
      for await (const message of query) {
        if (message.type === "prompt_suggestion" && this.query !== query) continue;
        this.onMessage(message);
      }
    } catch (error) {
      this.host.log(`thread ${this.threadId} query failed: ${error instanceof Error ? error.message : String(error)}`);
      logger.warn("claude.failed", { thread: this.threadId, pid: this.pid ?? null, error: errorText(error) });
    } finally {
      if (this.query === query) {
        logger.debug("claude.exit", { thread: this.threadId, pid: this.pid ?? null, openTurns: this.openTurns().length });
        // 主动关闭时已按原因记过；剩下的是进程自己退出（崩溃或被结束）。
        this.dropBackgroundTasks("exited");
        this.cliActive = false;
        this.continuation = undefined;
        this.query = undefined;
        this.suggestionTurnId = undefined;
        this.promptSuggestionsEnabled = false;
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
        // 退出前 Claude 可能已经写好了标题，同样要推给订阅者。
        if (turns.length) this.host.turnFinished(this.threadId);
      }
      // 进程已退出，插件目录不再被读取。
      if (this.skillPlugin === skillPlugin) this.skillPlugin = undefined;
      await skillPlugin?.dispose().catch(() => {});
    }
  }

  private async stopQuery(reason: StopReason): Promise<void> {
    this.suggestionTurnId = undefined;
    this.promptSuggestionsEnabled = false;
    const query = this.query;
    if (!query) return;
    this.dropBackgroundTasks(reason);
    this.input?.close();
    query.close();
    await this.pump;
  }

  /**
   * 输出归属：每一轮输出的第一帧带 user_message_uuid，指明它回应的是哪条消息。
   * 没有 uuid 的输出（后台任务完成后 Claude 自己继续）开一个没有用户消息的 turn；由完成通知触发时，
   * 回合 ID 与历史里这段续写的回合相同，客户端按任一来源都能停止它、向它补充消息。
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
    return this.current ?? (uuid ? this.openTurn() : this.openContinuation());
  }

  /**
   * 开出续写回合：认领最近送达的通知（没有时与普通的无 uuid 输出一样用随机 ID）。几条通知连着送达时
   * CLI 只给最后一条的那一轮输出，所以认领最近的一个；历史侧同样把回合归给最后一条通知。
   */
  private openContinuation(): LiveTurn {
    const runId = this.notificationRunId;
    this.notificationRunId = undefined;
    const turn = this.openTurn(runId ? notificationTurnId(this.threadId, runId) : undefined);
    this.continuation = runId ? { turn, runId } : undefined;
    return turn;
  }

  /**
   * 一轮开始（system/init）。回应用户消息的一轮开始时，之前送达的通知要么已并进前面的回合、要么已单独
   * 回复过（CLI 按顺序处理排队的输入），不会再触发续写。由通知触发的一轮现在就开出续写回合：首帧输出前
   * 模型可能排队、重试很久，这期间它就是活动回合，turn/start 被拒、turn/interrupt 与 turn/steer 能找到它，
   * 输出也不会挂到期间新开的回合上。
   */
  private roundStarted(record: Record<string, unknown>): void {
    this.suggestionTurnId = undefined;
    const answersUser = Array.isArray(record.user_message_uuids) && record.user_message_uuids.length > 0;
    if (answersUser) this.notificationRunId = undefined;
    else if (this.notificationRunId && !this.current) this.openContinuation();
  }

  private openTurns(): LiveTurn[] {
    const turns = new Set<LiveTurn>(this.commands.values());
    if (this.current) turns.add(this.current);
    return [...turns].filter((turn) => !turn.finished);
  }

  private openTurn(id: string = randomUUID()): LiveTurn {
    this.suggestionTurnId = undefined;
    const turn = this.makeLiveTurn(id);
    this.current = turn;
    this.cancelIdleClose();
    turn.begin();
    return turn;
  }

  private makeLiveTurn(id: string): LiveTurn {
    const store = this.host.turnHints?.store;
    return new LiveTurn(
      id,
      this.threadId,
      this.emit,
      store ? (proposalId) => store.isTaskProposal(this.threadId, proposalId) : undefined,
    );
  }

  private onMessage(message: SDKMessage): void {
    const record = message as unknown as Record<string, unknown>;
    this.trace(record);
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
        this.suggestionTurnId = undefined;
        const consumed = Array.isArray(record.user_message_uuids)
          ? record.user_message_uuids.map(String)
          : typeof record.user_message_uuid === "string"
            ? [record.user_message_uuid]
            : [];
        for (const uuid of consumed) this.commands.delete(uuid);
        const origin = record.origin as { kind?: unknown; runId?: unknown } | undefined;
        const fromNotification = origin?.kind === "task-notification";
        if (fromNotification && origin.runId === this.notificationRunId) this.notificationRunId = undefined;
        const turn = this.current;
        // 几条通知连着送达时，CLI 先为前几条各跑一轮（没有输出），结果带更早的 run_id，回复在最后一条那一轮：
        // 续写回合在 init 时已为最后一条开出，留给那一轮收尾。
        const earlierRound =
          fromNotification &&
          typeof origin.runId === "string" &&
          turn !== undefined &&
          this.continuation?.turn === turn &&
          origin.runId !== this.continuation.runId &&
          !turn.explicitlyInterrupted;
        if (!earlierRound) this.current = undefined;
        logger.debug("claude.result", {
          thread: this.threadId,
          subtype: String(record.subtype),
          consumed: consumed.length,
          turn: turn?.id ?? null,
          pendingMessages: this.commands.size,
          ...(earlierRound ? { earlierRound } : {}),
        });
        if (!turn || earlierRound) return;
        const usage = usageOf(record.usage);
        if (usage) this.totalUsage = addUsage(this.totalUsage, usage);
        // 这个 turn 名下还有没被回应的引导消息：Claude 会接着处理它们，turn 不收尾。
        // 用户明确中断时例外，立即收尾。续写那一轮的结果本来就没有用户消息可吸收，带着通知来源，
        // 同样说明 CLI 会回报 uuid：引导排在它之后单独一轮，回应完再收尾（#797）。
        const pendingSteer = [...this.commands.values()].some((owner) => owner === turn);
        if ((consumed.length || fromNotification) && pendingSteer && !turn.explicitlyInterrupted) {
          turn.continueAfterSteer();
          return;
        }
        // 旧版 CLI 不回报 uuid，或用户已中断：结束当前 turn 名下的全部消息。
        for (const [uuid, owner] of this.commands) if (owner === turn) this.commands.delete(uuid);
        const errors = Array.isArray(record.errors) ? record.errors.map(String) : [];
        turn.finish({ subtype: String(record.subtype), errors, usage, contextWindow: contextWindowOf(record.modelUsage) }, this.totalUsage);
        if (record.subtype === "success" && record.is_error !== true && !turn.explicitlyInterrupted && !this.isBusy() && !errors.length) {
          this.suggestionTurnId = turn.id;
        }
        if (this.continuation?.turn === turn) this.continuation = undefined;
        this.host.turnFinished(this.threadId);
        this.scheduleIdleClose();
        return;
      }
      case "prompt_suggestion": {
        const turnId = this.suggestionTurnId;
        if (!turnId || this.isBusy() || !this.promptSuggestionsEnabled
          || record.session_id !== this.threadId || typeof record.uuid !== "string" || !record.uuid
          || record.uuid.length > 128 || typeof record.suggestion !== "string") return;
        const text = record.suggestion.trim();
        if (!text || text.length > 4_096) return;
        // CLI 在新命令到达时取消旧生成；这里再以本地轮次边界限制迟到和重复事件。
        this.suggestionTurnId = undefined;
        this.emit("_mimi/turn/promptSuggestion", { threadId: this.threadId, turnId, id: record.uuid, text });
        return;
      }
      case "system":
        if (record.subtype === "compact_boundary") this.turnFor(record).onCompactBoundary(String(record.uuid));
        else if (record.subtype === "init") {
          // 字段只在有终端专用命令时出现，缺省即为空。
          const terminal = Array.isArray(record.terminal_slash_commands) ? record.terminal_slash_commands.map(String) : [];
          this.host.terminalCommands?.(terminal);
          this.roundStarted(record);
        }
        else if (record.subtype === "background_tasks_changed") this.backgroundTasksChanged(record.tasks);
        else if (record.subtype === "task_notification") {
          // skip_transcript 的任务不写进 transcript，也不会触发续写。
          if (typeof record.run_id === "string" && record.run_id && record.skip_transcript !== true) this.notificationRunId = record.run_id;
        }
        else if (record.subtype === "session_state_changed") {
          this.cliStateChanged(record.state);
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

  /** 每条 SDK 消息的类型与归属标记（不含正文），只在 trace 级别输出。 */
  private trace(record: Record<string, unknown>): void {
    if (!logEnabled("trace")) return;
    const event = record.event as { type?: unknown } | undefined;
    const fields = [
      String(record.type),
      record.subtype ?? event?.type ?? "",
      record.user_message_uuid ? `uuid=${String(record.user_message_uuid).slice(0, 8)}` : "",
      Array.isArray(record.user_message_uuids) ? `uuids=${record.user_message_uuids.map((id) => String(id).slice(0, 8)).join(",")}` : "",
      `current=${this.current?.id.slice(0, 8) ?? "-"}`,
    ];
    logger.trace("sdk.message", { thread: this.threadId, detail: fields.filter(Boolean).join(" ") });
  }

  private async canUseTool(
    toolName: string,
    input: Record<string, unknown>,
    context: Parameters<NonNullable<Options["canUseTool"]>>[2],
  ): Promise<PermissionResult> {
    const turn = this.current;
    logger.debug("approval.ask", { thread: this.threadId, turn: turn?.id ?? null, tool: toolName });
    if (!turn) return { behavior: "deny", message: "no active turn to approve this tool call" };
    const spec = serverRequestFor(
      {
        toolName,
        input,
        toolUseID: context.toolUseID,
        // 会话授权建议可能增加可写目录或网络范围，受限档位只能批准本次调用。
        ...(this.settings.executionPolicy.type === "dangerFullAccess" && context.suggestions ? { suggestions: context.suggestions } : {}),
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

  /**
   * background_tasks_changed 是全量的电平信号：每次用新集合替换旧的。ambient 任务（内部监视等）
   * 不算活动，与 SDK 的建议一致。全部结束且没有进行中的 turn 时重新计时空闲关闭；续写的 turn
   * 收尾时会自己计时。
   */
  private backgroundTasksChanged(tasks: unknown): void {
    const live = Array.isArray(tasks)
      ? tasks.flatMap((task) => {
          const entry = task as { task_id?: unknown; ambient?: unknown } | null;
          return entry && typeof entry.task_id === "string" && entry.ambient !== true ? [entry.task_id] : [];
        })
      : [];
    const hadTasks = this.backgroundTasks.size > 0;
    this.backgroundTasks = new Set(live);
    logger.debug("claude.background_tasks", { thread: this.threadId, count: live.length });
    if (hadTasks && !live.length && this.query && !this.isBusy()) this.scheduleIdleClose();
  }

  /**
   * CLI 从执行中回到 idle：这时才算真的空闲，重新计时。通知触发的一轮可能没有任何输出就结束（没有
   * turn 可收尾，结果帧不会计时），只能靠这里。
   */
  private cliStateChanged(state: unknown): void {
    const wasActive = this.cliActive;
    this.cliActive = state === "running" || state === "requires_action";
    if (state === "idle") this.finishAbandonedContinuation();
    if (wasActive && state === "idle" && this.query && !this.isBusy() && !this.backgroundTasks.size) this.scheduleIdleClose();
  }

  /**
   * 兜底：续写回合在等的那一轮没有来（只跑了更早通知的空轮），CLI 却已回到 idle。照常收尾，不让它一直
   * 作为活动回合挡住新的 turn/start。名下还有引导没回应时不动，引导那一轮会收尾它。
   */
  private finishAbandonedContinuation(): void {
    const turn = this.continuation?.turn;
    if (!turn || turn.finished || this.current !== turn || [...this.commands.values()].includes(turn)) return;
    logger.debug("claude.continuation_abandoned", { thread: this.threadId, turn: turn.id });
    this.current = undefined;
    this.continuation = undefined;
    turn.finish({ subtype: "success", errors: [], usage: undefined, contextWindow: null }, this.totalUsage);
    this.host.turnFinished(this.threadId);
  }

  /** 进程即将结束：仍在运行的后台任务会随之中止，记下原因，便于解释之后没有出现的续写。 */
  private dropBackgroundTasks(reason: StopReason | "exited"): void {
    if (this.backgroundTasks.size) {
      logger.warn("claude.background_tasks_dropped", { thread: this.threadId, count: this.backgroundTasks.size, reason });
    }
    this.backgroundTasks = new Set();
  }

  /** 后台任务还在运行、CLI 仍在执行时不关闭：到点时跳过，任务全部结束或 CLI 回到 idle 后再重新计时。 */
  private scheduleIdleClose(): void {
    this.cancelIdleClose();
    this.idleTimer = setTimeout(() => {
      if (!this.isBusy() && !this.backgroundTasks.size && !this.cliActive) void this.stopQuery("idle");
    }, this.host.idleCloseMs);
    this.idleTimer.unref?.();
  }

  private cancelIdleClose(): void {
    if (this.idleTimer) clearTimeout(this.idleTimer);
    this.idleTimer = undefined;
  }
}
