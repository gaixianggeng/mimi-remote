import { randomUUID } from "node:crypto";
import type { Catalog, SessionRecord } from "../claude/catalog.ts";
import type { Overlay } from "../claude/overlay.ts";
import type { ClaudeSessions } from "../claude/sdk.ts";
import type { UserInput } from "../protocol/codex/v2/UserInput.ts";
import { RpcError } from "../rpc/frames.ts";
import { liveThreadStatus, ownerSummary, type SessionHolder } from "../runtime/holders.ts";
import type { ThreadManager } from "../runtime/manager.ts";
import { runSettingsFor } from "../runtime/settings.ts";
import { TakeoverError } from "../runtime/takeover.ts";
import type { ThreadRuntime } from "../runtime/threadRuntime.ts";
import type { RequestContext } from "../server/router.ts";
import { toThread, type AdapterThread } from "./threads.ts";

type Params = Record<string, unknown>;

export interface TurnHandlerDeps {
  manager: ThreadManager;
  catalog: Catalog;
  sessions: ClaudeSessions;
  holders(): Promise<Map<string, SessionHolder>>;
  /** Claude Code 版本下限：起进程前确认，过旧时给出明确提示。 */
  claudeCode: { ensure(): Promise<void> };
  overlay: Pick<Overlay, "consumeTaskProposal">;
}

function asParams(value: unknown): Params {
  if (value && typeof value === "object" && !Array.isArray(value)) return value as Params;
  throw RpcError.invalidParams("params 必须是对象");
}

function requireString(params: Params, key: string, method: string): string {
  const value = params[key];
  if (typeof value !== "string" || !value.trim()) throw RpcError.invalidParams(`${method}.${key} 不能为空`);
  return value.trim();
}

function inputOf(params: Params, method: string): UserInput[] {
  if (!Array.isArray(params.input) || params.input.length === 0) throw RpcError.invalidParams(`${method}.input 不能为空`);
  return params.input as UserInput[];
}

function newRecord(threadId: string, cwd: string, spawnedFromId: string | null = null): SessionRecord {
  const now = Math.floor(Date.now() / 1000);
  return { id: threadId, cwd, name: null, preview: "", createdAt: now, updatedAt: now, gitBranch: null, path: null, archived: false, spawnedFromId };
}

function taskProposalOf(params: Params): { id: string; parentThreadId: string } | undefined {
  if (params.mimiTaskProposal === undefined) return undefined;
  const raw = params.mimiTaskProposal;
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    throw RpcError.invalidParams("thread/start.mimiTaskProposal 无效");
  }
  const proposal = raw as Record<string, unknown>;
  if (typeof proposal.id !== "string" || !proposal.id.trim() || typeof proposal.parentThreadId !== "string" || !proposal.parentThreadId.trim()) {
    throw RpcError.invalidParams("thread/start.mimiTaskProposal 缺少 id 或 parentThreadId");
  }
  return { id: proposal.id.trim(), parentThreadId: proposal.parentThreadId.trim() };
}

/** thread/start 与 thread/resume 共用的响应：会话本体 + 当前生效的运行设置。 */
function sessionResponse(thread: AdapterThread, runtime: ThreadRuntime, params: Params) {
  const settings = runtime.currentSettings;
  return {
    thread,
    model: settings.model ?? "",
    modelProvider: "anthropic",
    serviceTier: null,
    disabledPluginIds: [],
    cwd: runtime.cwd,
    instructionSources: [],
    approvalPolicy: params.approvalPolicy ?? "on-request",
    approvalsReviewer: params.approvalsReviewer ?? "user",
    sandbox: settings.executionPolicy,
    reasoningEffort: settings.effort ?? null,
    permissionProfile: { type: "disabled" },
    activePermissionProfile: null,
  };
}

export function createTurnHandlers(deps: TurnHandlerDeps) {
  const { manager, catalog } = deps;

  /** 已有会话：取 transcript 元数据并建立（或复用）运行时；复用时也按 transcript 对齐标题。 */
  async function openExisting(threadId: string, cwd: string | undefined, params: Params) {
    const runtime = manager.get(threadId);
    const record = (await catalog.get(threadId)) ?? (runtime ? newRecord(threadId, runtime.cwd) : undefined);
    if (!record) throw RpcError.invalidParams(`找不到 Claude 会话 ${threadId}`);
    return { record, runtime: manager.open(threadId, cwd ?? record.cwd, runSettingsFor(params), record.name) };
  }

  async function resume(threadId: string, params: Params, context: RequestContext) {
    const cwd = typeof params.cwd === "string" && params.cwd.trim() ? params.cwd.trim() : undefined;
    const { record, runtime } = await openExisting(threadId, cwd, params);
    manager.subscribe(threadId, context.session);
    const holder = (await deps.holders()).get(threadId);
    // 刚 resume 的会话至少算 idle（本连接已附着）；持有方正在执行时与列表一致报 active。
    const status = liveThreadStatus({ ownTurnActive: runtime.activeTurnId !== undefined, ownProcessLive: true, holder });
    const thread = toThread(record, [], {
      canAcceptDirectInput: !holder,
      status,
      ...(holder ? { claudeOwner: ownerSummary(holder) } : {}),
    });
    return { ...sessionResponse(thread, runtime, params), collaborationMode: null, turnsBackwardsCursor: null, itemsBackwardsCursor: null };
  }

  return {
    async threadStart(raw: unknown, context: RequestContext) {
      const params = asParams(raw);
      const cwd = requireString(params, "cwd", "thread/start");
      const taskProposal = taskProposalOf(params);
      let spawnedFromId: string | null = null;
      let threadId: string | undefined;
      let proposalInitialTurnStarted = false;
      let proposalExistingRecord: SessionRecord | undefined;
      if (taskProposal) {
        const proposal = await deps.overlay.consumeTaskProposal(
          taskProposal.id,
          taskProposal.parentThreadId,
          cwd,
          randomUUID(),
        );
        if (!proposal?.consumedByThreadId) {
          throw RpcError.invalidParams("任务提议无效或不属于当前 Claude 会话");
        }
        spawnedFromId = proposal.parentThreadId;
        threadId = proposal.consumedByThreadId;
        const existingRuntime = manager.get(threadId);
        // thread/start 与随后 turn/start 是两次 RPC。若首轮 ACK 丢失，重试仍会复用
        // 同一 child；活动 turn 或 Claude transcript 是首轮已经开始的后端证据。
        // 只有预先分配但仍为空的 child 才允许再次提交原 prompt。
        proposalExistingRecord = await catalog.get(threadId);
        proposalInitialTurnStarted = existingRuntime?.activeTurnId !== undefined
          || proposalExistingRecord !== undefined;
      }
      const runtime = threadId
        ? manager.get(threadId)
          ?? (proposalExistingRecord
            ? manager.open(threadId, cwd, runSettingsFor(params), proposalExistingRecord.name)
            : manager.create(cwd, runSettingsFor(params), threadId))
        : manager.create(cwd, runSettingsFor(params));
      manager.subscribe(runtime.threadId, context.session);
      const thread = toThread(newRecord(runtime.threadId, cwd, spawnedFromId), [], {
        canAcceptDirectInput: true,
        status: runtime.activeTurnId ? { type: "active", activeFlags: [] } : { type: "idle" },
      });
      return {
        ...sessionResponse(thread, runtime, params),
        ...(taskProposal ? { mimiTaskProposal: { initialTurnStarted: proposalInitialTurnStarted } } : {}),
      };
    },

    threadResume(raw: unknown, context: RequestContext) {
      const params = asParams(raw);
      return resume(requireString(params, "threadId", "thread/resume"), params, context);
    },

    /**
     * 结束本机别处空闲的持有方（终端、桌面端），然后以同一 ID 续聊。没有持有方时等价于
     * 普通 resume。响应与 thread/resume 同形状，多一个 takeover 摘要。
     */
    async threadTakeover(raw: unknown, context: RequestContext) {
      const params = asParams(raw);
      const threadId = requireString(params, "threadId", "thread/takeover");
      // 先确认会话存在，不为一个不存在的 ID 去动任何进程。
      if (!manager.get(threadId) && !(await catalog.get(threadId))) throw RpcError.invalidParams(`找不到 Claude 会话 ${threadId}`);
      let outcome;
      try {
        outcome = await manager.takeover(threadId);
      } catch (error) {
        if (!(error instanceof TakeoverError)) throw error;
        throw new RpcError(-32602, `takeover of thread \`${threadId}\` failed: ${error.message}`, {
          accepted: false,
          reason: error.reason,
          threadId,
          claudeOwner: ownerSummary(error.holder),
          retryable: error.retryable,
        });
      }
      const resumed = await resume(threadId, params, context);
      const first = outcome.released ? outcome.holders[0] : undefined;
      return {
        ...resumed,
        takeover: outcome.released
          ? { released: true, ...(first ? { holder: ownerSummary(first) } : {}), signal: outcome.signal }
          : { released: false },
      };
    },

    async turnStart(raw: unknown, context: RequestContext) {
      const params = asParams(raw);
      const threadId = requireString(params, "threadId", "turn/start");
      const input = inputOf(params, "turn/start");
      // 版本探测可能要几秒：放在占用检查之前，检查之后到起进程之间不留长等待，
      // 否则终端在这段时间接手会话，适配器仍会起第二个写入方。
      await deps.claudeCode.ensure();
      const holder = (await deps.holders()).get(threadId);
      if (holder) {
        throw new RpcError(-32602, `thread \`${threadId}\` is held by another local claude process`, {
          accepted: false,
          reason: "owned_elsewhere",
          threadId,
          claudeOwner: ownerSummary(holder),
          retryable: true,
        });
      }
      const cwd = typeof params.cwd === "string" && params.cwd.trim() ? params.cwd.trim() : undefined;
      const runtime = manager.get(threadId) ?? (await openExisting(threadId, cwd, params)).runtime;
      manager.subscribe(threadId, context.session);
      const settings = runSettingsFor(params);
      const turn = await runtime.startTurn({
        input,
        clientUserMessageId: typeof params.clientUserMessageId === "string" ? params.clientUserMessageId : null,
        settings: {
          ...(settings.model ? { model: settings.model } : {}),
          ...(settings.effort ? { effort: settings.effort } : {}),
          // turn 级权限只在客户端明确给出时覆盖（保留会话权限的请求不带这些字段）。
          ...("approvalPolicy" in params || "sandboxPolicy" in params || "sandbox" in params || "collaborationMode" in params
            ? { permissionMode: settings.permissionMode }
            : {}),
          ...("sandboxPolicy" in params || "sandbox" in params ? { executionPolicy: settings.executionPolicy } : {}),
        },
      });
      return { turn };
    },

    /**
     * 改名与 CLI `/rename` 相同：往 transcript 追加 custom-title，CLI、桌面端和 Mimi 看到同一个
     * 名字。Claude Code 不支持清除名称，空名称直接拒绝。agentd 的自动标题经匿名连接调用。
     */
    async threadSetName(raw: unknown) {
      const params = asParams(raw);
      const threadId = requireString(params, "threadId", "thread/name/set");
      const name = typeof params.name === "string" ? params.name.trim() : "";
      if (!name) throw RpcError.invalidParams("thread/name/set.name 不能为空：Claude Code 不支持清除会话名称");
      const record = await catalog.get(threadId);
      if (!record) throw RpcError.invalidParams(`找不到 Claude 会话 ${threadId}`);
      await deps.sessions.rename(threadId, name, record.cwd);
      manager.titleChanged(threadId, name);
      return {};
    },

    turnSteer(raw: unknown) {
      const params = asParams(raw);
      const threadId = requireString(params, "threadId", "turn/steer");
      const runtime = manager.get(threadId);
      if (!runtime) throw RpcError.invalidParams(`thread \`${threadId}\` is not loaded`);
      return runtime.steer(
        requireString(params, "expectedTurnId", "turn/steer"),
        inputOf(params, "turn/steer"),
        typeof params.clientUserMessageId === "string" ? params.clientUserMessageId : null,
      );
    },

    async turnInterrupt(raw: unknown) {
      const params = asParams(raw);
      const runtime = manager.get(requireString(params, "threadId", "turn/interrupt"));
      await runtime?.interrupt(requireString(params, "turnId", "turn/interrupt"));
      return {};
    },
  };
}
