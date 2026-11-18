import type { UserInput } from "@mimi/appserver-kit/protocol/codex/v2/UserInput.ts";
import { RpcError } from "@mimi/appserver-kit/rpc/frames.ts";
import type { RequestContext } from "@mimi/appserver-kit/server/router.ts";
import type { AgyCatalog, AgyHistoryStore, SessionRecord } from "../agy/catalog.ts";
import type { AgyOverlay } from "../agy/overlay.ts";
import type { ThreadManager } from "../runtime/manager.ts";
import { runSettingsFor } from "../runtime/settings.ts";
import type { ThreadRuntime } from "../runtime/threadRuntime.ts";
import { toThread, type AdapterThread } from "./threads.ts";

type Params = Record<string, unknown>;

export interface TurnHandlerDeps {
  manager: ThreadManager;
  catalog: AgyCatalog;
  history: AgyHistoryStore;
  overlay: AgyOverlay;
  agyGate: { ensure(): Promise<string> };
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
  if (!Array.isArray(params.input) || params.input.length === 0) {
    throw RpcError.invalidParams(`${method}.input 不能为空`);
  }
  return params.input as UserInput[];
}

function newRecord(threadId: string, cwd: string): SessionRecord {
  const now = Math.floor(Date.now() / 1000);
  return { id: threadId, cwd, name: null, preview: "", createdAt: now, updatedAt: now, gitBranch: null, path: null, archived: false };
}

function sessionResponse(thread: AdapterThread, runtime: ThreadRuntime, params: Params) {
  const settings = runtime.currentSettings;
  return {
    thread,
    model: settings.model ?? "",
    modelProvider: "google",
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
  const { manager, catalog, history, overlay } = deps;

  async function openExisting(threadId: string, cwd: string | undefined, params: Params) {
    const existingRuntime = manager.get(threadId);
    const record = (await catalog.get(threadId)) ?? (existingRuntime ? newRecord(threadId, existingRuntime.cwd) : undefined);
    if (!record) {
      throw RpcError.invalidParams(`找不到 Antigravity 会话 ${threadId}`);
    }
    const runtime = manager.openExisting(threadId, cwd ?? record.cwd, runSettingsFor(params), record.name);
    return { record, runtime };
  }

  return {
    async threadStart(raw: unknown, context: RequestContext) {
      const params = asParams(raw);
      const cwd = requireString(params, "cwd", "thread/start");
      await deps.agyGate.ensure();
      const runtime = await manager.createNew(cwd, runSettingsFor(params));
      catalog.invalidate();
      await overlay.recordSession(runtime.threadId, {
        cwd,
        createdAt: runtime.createdAt,
        updatedAt: runtime.updatedAt,
      });
      manager.subscribe(runtime.threadId, context.session);
      const thread = toThread(newRecord(runtime.threadId, cwd), [], {
        canAcceptDirectInput: true,
        status: runtime.activeTurnId ? { type: "active", activeFlags: [] } : { type: "idle" },
      });
      return sessionResponse(thread, runtime, params);
    },

    async threadResume(raw: unknown, context: RequestContext) {
      const params = asParams(raw);
      const threadId = requireString(params, "threadId", "thread/resume");
      const cwd = typeof params.cwd === "string" && params.cwd.trim() ? params.cwd.trim() : undefined;
      const { record, runtime } = await openExisting(threadId, cwd, params);
      manager.subscribe(threadId, context.session);
      const thread = toThread(record, [], {
        canAcceptDirectInput: true,
        status: runtime.activeTurnId ? { type: "active", activeFlags: [] } : { type: "idle" },
      });
      return {
        ...sessionResponse(thread, runtime, params),
        collaborationMode: null,
        turnsBackwardsCursor: null,
        itemsBackwardsCursor: null,
      };
    },

    async turnStart(raw: unknown, context: RequestContext) {
      const params = asParams(raw);
      const threadId = requireString(params, "threadId", "turn/start");
      const input = inputOf(params, "turn/start");
      await deps.agyGate.ensure();
      const cwd = typeof params.cwd === "string" && params.cwd.trim() ? params.cwd.trim() : undefined;
      const runtime = manager.get(threadId) ?? (await openExisting(threadId, cwd, params)).runtime;
      manager.subscribe(threadId, context.session);
      const settings = runSettingsFor(params);
      history.invalidate(threadId);
      const turn = await runtime.startTurn({
        input,
        clientUserMessageId: typeof params.clientUserMessageId === "string" ? params.clientUserMessageId : null,
        settings: {
          ...(settings.model ? { model: settings.model } : {}),
          ...(settings.effort ? { effort: settings.effort } : {}),
          ...("approvalPolicy" in params || "sandboxPolicy" in params || "sandbox" in params || "collaborationMode" in params
            ? { mode: settings.mode }
            : {}),
          ...("sandboxPolicy" in params || "sandbox" in params ? { executionPolicy: settings.executionPolicy } : {}),
        },
      });
      return { turn };
    },

    turnInterrupt(raw: unknown) {
      const params = asParams(raw);
      const threadId = requireString(params, "threadId", "turn/interrupt");
      const runtime = manager.get(threadId);
      if (!runtime) return {};
      const turnId = typeof params.turnId === "string" && params.turnId.trim() ? params.turnId.trim() : undefined;
      return runtime.interrupt(turnId);
    },

    async threadSetName(raw: unknown) {
      const params = asParams(raw);
      const threadId = requireString(params, "threadId", "thread/name/set");
      const name = typeof params.name === "string" ? params.name.trim() : "";
      if (!name) {
        throw RpcError.invalidParams("thread/name/set.name 不能为空");
      }
      const record = await catalog.get(threadId);
      if (!record) {
        throw RpcError.invalidParams(`找不到 Antigravity 会话 ${threadId}`);
      }
      await overlay.setCustomTitle(threadId, name);
      catalog.invalidate();
      manager.titleChanged(threadId, name);
      return {};
    },
  };
}
