import os from "node:os";
import path from "node:path";
import { Catalog, HistoryStore } from "./claude/catalog.ts";
import { Overlay } from "./claude/overlay.ts";
import { sdkSessions, type ClaudeSessions } from "./claude/sdk.ts";
import { ActivityClock, TranscriptIndex } from "./claude/transcripts.ts";
import { ModelCatalog, sdkModelDiscovery, type DiscoverModels } from "./claude/models.ts";
import { RateLimitReader } from "./claude/usage.ts";
import { createAccountHandlers } from "./handlers/account.ts";
import { createHistoryHandlers } from "./handlers/history.ts";
import type { RateLimitSnapshot } from "./protocol/codex/v2/RateLimitSnapshot.ts";
import { createThreadHandlers } from "./handlers/threads.ts";
import { createTurnHandlers } from "./handlers/turns.ts";
import { ThreadManager, type ManagerOptions } from "./runtime/manager.ts";
import type { InitializeResponse } from "./protocol/codex/InitializeResponse.ts";
import { Router, type Handler, type Logger } from "./server/router.ts";
import { ADAPTER_NAME, ADAPTER_VERSION, USER_AGENT } from "./version.ts";

/**
 * `--capabilities` 的能力声明。agentd 读它决定向客户端声明哪些方法与权限档位，
 * 而不是按旧 bridge 的版本号门槛推断（两者版本号不在同一序列）。
 */
export interface CapabilityDeclaration {
  name: string;
  version: string;
  methods: string[];
  /** 是否支持完全访问（approvalPolicy never + dangerFullAccess → bypassPermissions）。 */
  fullAccess: boolean;
}

/** 客户端发来、适配器接受但不应答的通知；网关按声明开放，漏声明会被当成不支持。 */
const ACCEPTED_NOTIFICATIONS = ["initialized"];

export function capabilityDeclaration(router: Router): CapabilityDeclaration {
  const methods = [...router.methods(), ...ACCEPTED_NOTIFICATIONS].sort();
  return { name: ADAPTER_NAME, version: ADAPTER_VERSION, methods, fullAccess: true };
}

/** 适配器自己的状态目录（Mimi 覆盖层）。 */
export function defaultStateDir(): string {
  if (process.env.MIMI_CLAUDE_ADAPTER_STATE_DIR) return process.env.MIMI_CLAUDE_ADAPTER_STATE_DIR;
  if (process.platform === "darwin") {
    return path.join(os.homedir(), "Library", "Application Support", "mimi-remote", "claude-adapter");
  }
  if (process.platform === "win32") {
    return path.join(process.env.APPDATA ?? path.join(os.homedir(), "AppData", "Roaming"), "mimi-remote", "claude-adapter");
  }
  return path.join(process.env.XDG_STATE_HOME ?? path.join(os.homedir(), ".local", "state"), "mimi-remote", "claude-adapter");
}

/** 旧 Rust bridge 的会话索引位置，只用于首次启动时导入归档标记。 */
function legacyIndexPath(): string | undefined {
  if (process.env.MIMI_CLAUDE_LEGACY_INDEX !== undefined) return process.env.MIMI_CLAUDE_LEGACY_INDEX || undefined;
  if (process.platform === "darwin") {
    return path.join(os.homedir(), "Library", "Application Support", "codex", "claude-bridge", "threads.json");
  }
  return undefined;
}

/** 驱动对话用的 claude：优先 agentd 传入的路径（与旧 bridge 同一个环境变量），否则 PATH 里的。 */
export function defaultClaudeExecutable(): string {
  const configured = process.env.CLAUDE_BRIDGE_CLAUDE_BIN?.trim();
  if (configured) return configured;
  return Bun.which("claude") ?? "claude";
}

export interface AppOptions {
  sessions?: ClaudeSessions;
  stateDir?: string;
  log: Logger;
  claudeExecutable?: () => string;
  startQuery?: ManagerOptions["startQuery"];
  idleCloseMs?: number;
  /** 测试用：占用登记轮询与接管的时限、进程核对。 */
  ownership?: Pick<ManagerOptions, "ownershipPollMs" | "takeoverTimeouts" | "takeoverDeps">;
  /** 测试用：模型目录与额度的来源。 */
  discoverModels?: DiscoverModels;
  fetchUsage?: () => Promise<RateLimitSnapshot>;
}

export interface App {
  router: Router;
  manager: ThreadManager;
  models: ModelCatalog;
}

export function createApp(options: AppOptions): App {
  const stateDir = options.stateDir ?? defaultStateDir();
  const sessions = options.sessions ?? sdkSessions;
  const transcripts = new TranscriptIndex();
  const overlay = new Overlay(path.join(stateDir, "overlay.json"), legacyIndexPath());
  const catalog = new Catalog({ sessions, transcripts, activity: new ActivityClock(), overlay });
  const history = new HistoryStore({ sessions, transcripts });
  const claudeExecutable = options.claudeExecutable ?? defaultClaudeExecutable;
  const manager = new ThreadManager({
    claudeExecutable,
    log: options.log,
    ...(options.startQuery ? { startQuery: options.startQuery } : {}),
    ...(options.idleCloseMs !== undefined ? { idleCloseMs: options.idleCloseMs } : {}),
    ...options.ownership,
  });
  const holders = () => manager.holders();
  const activeTurnId = (threadId: string) => manager.get(threadId)?.activeTurnId;
  const threads = createThreadHandlers(catalog, history, {
    holders,
    activeTurnId,
    loadedThreadIds: () => manager.loadedThreadIds(),
  });
  const historyHandlers = createHistoryHandlers(history, (threadId) => activeTurnId(threadId) !== undefined);
  const turns = createTurnHandlers({ manager, catalog, sessions, holders });
  const models = new ModelCatalog({ discover: options.discoverModels ?? sdkModelDiscovery(claudeExecutable), log: options.log });
  const rateLimits = new RateLimitReader({
    ...(options.fetchUsage ? { fetch: options.fetchUsage } : {}),
    observed: () => manager.observedRateLimits,
    log: options.log,
  });
  const account = createAccountHandlers(models, rateLimits);

  const initialize: Handler = (): InitializeResponse => ({
    userAgent: USER_AGENT,
    codexHome: stateDir,
    platformFamily: process.platform === "win32" ? "windows" : "unix",
    platformOs: process.platform === "darwin" ? "macos" : process.platform,
  });

  const handlers = new Map<string, Handler>([
    ["initialize", initialize],
    ["thread/list", (params) => threads.list(params)],
    ["thread/read", (params) => threads.read(params)],
    ["thread/loaded/list", () => threads.loaded()],
    ["thread/turns/list", (params) => historyHandlers.turns(params)],
    ["thread/items/list", (params) => historyHandlers.items(params)],
    ["thread/start", (params, context) => turns.threadStart(params, context)],
    ["thread/resume", (params, context) => turns.threadResume(params, context)],
    ["thread/takeover", (params, context) => turns.threadTakeover(params, context)],
    ["turn/start", (params, context) => turns.turnStart(params, context)],
    ["turn/steer", (params) => turns.turnSteer(params)],
    ["turn/interrupt", (params) => turns.turnInterrupt(params)],
    ["thread/name/set", (params) => turns.threadSetName(params)],
    ["model/list", () => account.modelList()],
    ["account/rateLimits/read", () => account.rateLimitsRead()],
  ]);
  return { router: new Router(handlers, options.log), manager, models };
}

/** 只需要方法分发的场景（只读测试等）。 */
export function createRouter(options: AppOptions): Router {
  return createApp(options).router;
}
