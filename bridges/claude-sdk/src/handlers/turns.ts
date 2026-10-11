import type { Catalog, SessionRecord } from "../claude/catalog.ts";
import type { UserInput } from "../protocol/codex/v2/UserInput.ts";
import { RpcError } from "../rpc/frames.ts";
import type { SessionHolder } from "../runtime/holders.ts";
import type { ThreadManager } from "../runtime/manager.ts";
import { runSettingsFor } from "../runtime/settings.ts";
import type { ThreadRuntime } from "../runtime/threadRuntime.ts";
import type { RequestContext } from "../server/router.ts";
import { toThread, type AdapterThread } from "./threads.ts";

type Params = Record<string, unknown>;

export interface TurnHandlerDeps {
  manager: ThreadManager;
  catalog: Catalog;
  holders(): Promise<Map<string, SessionHolder>>;
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

function sandboxPolicyOf(params: Params): Record<string, unknown> {
  const raw = params.sandboxPolicy ?? params.sandbox;
  if (raw && typeof raw === "object") return raw as Record<string, unknown>;
  switch (raw) {
    case "read-only":
      return { type: "readOnly" };
    case "danger-full-access":
      return { type: "dangerFullAccess" };
    default:
      return { type: "workspaceWrite" };
  }
}

export function ownerSummary(holder: SessionHolder): Record<string, unknown> {
  return { pid: holder.pid, entrypoint: holder.entrypoint, kind: holder.kind, status: holder.status, version: holder.version };
}

function newRecord(threadId: string, cwd: string): SessionRecord {
  const now = Math.floor(Date.now() / 1000);
  return { id: threadId, cwd, name: null, preview: "", createdAt: now, updatedAt: now, gitBranch: null, path: null, archived: false };
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
    sandbox: sandboxPolicyOf(params),
    reasoningEffort: settings.effort ?? null,
    permissionProfile: { type: "disabled" },
    activePermissionProfile: null,
  };
}

export function createTurnHandlers(deps: TurnHandlerDeps) {
  const { manager, catalog } = deps;

  /** 已有会话：取 transcript 元数据并建立（或复用）运行时。 */
  async function openExisting(threadId: string, cwd: string | undefined, params: Params) {
    const runtime = manager.get(threadId);
    const record = (await catalog.get(threadId)) ?? (runtime ? newRecord(threadId, runtime.cwd) : undefined);
    if (!record) throw RpcError.invalidParams(`找不到 Claude 会话 ${threadId}`);
    return { record, runtime: runtime ?? manager.open(threadId, cwd ?? record.cwd, runSettingsFor(params)) };
  }

  return {
    threadStart(raw: unknown, context: RequestContext) {
      const params = asParams(raw);
      const cwd = requireString(params, "cwd", "thread/start");
      const runtime = manager.create(cwd, runSettingsFor(params));
      manager.subscribe(runtime.threadId, context.session);
      const thread = toThread(newRecord(runtime.threadId, cwd), [], { canAcceptDirectInput: true, status: { type: "idle" } });
      return sessionResponse(thread, runtime, params);
    },

    async threadResume(raw: unknown, context: RequestContext) {
      const params = asParams(raw);
      const threadId = requireString(params, "threadId", "thread/resume");
      const cwd = typeof params.cwd === "string" && params.cwd.trim() ? params.cwd.trim() : undefined;
      const { record, runtime } = await openExisting(threadId, cwd, params);
      manager.subscribe(threadId, context.session);
      const holder = (await deps.holders()).get(threadId);
      const thread = toThread(record, [], {
        canAcceptDirectInput: !holder,
        status: runtime.activeTurnId ? { type: "active", activeFlags: [] } : { type: "idle" },
        ...(holder ? { claudeOwner: ownerSummary(holder) } : {}),
      });
      return { ...sessionResponse(thread, runtime, params), collaborationMode: null, turnsBackwardsCursor: null, itemsBackwardsCursor: null };
    },

    async turnStart(raw: unknown, context: RequestContext) {
      const params = asParams(raw);
      const threadId = requireString(params, "threadId", "turn/start");
      const input = inputOf(params, "turn/start");
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
          ...("approvalPolicy" in params || "sandboxPolicy" in params || "collaborationMode" in params
            ? { permissionMode: settings.permissionMode }
            : {}),
        },
      });
      return { turn };
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
