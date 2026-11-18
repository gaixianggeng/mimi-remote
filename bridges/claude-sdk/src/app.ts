import os from "node:os";
import path from "node:path";
import { Catalog, HistoryStore } from "./claude/catalog.ts";
import { ClaudeCodeVersionGate, type ClaudeCodeProbe } from "./claude/claudeCode.ts";
import { DesktopSpawnIndex } from "./claude/desktopSpawns.ts";
import { legacyIndexPath, migrateLegacyNames, readLegacyIndex } from "./claude/legacy.ts";
import { Overlay } from "./claude/overlay.ts";
import { sdkSessions, type ClaudeSessions } from "./claude/sdk.ts";
import { ActivityClock, TranscriptIndex, WorkingDirectories } from "./claude/transcripts.ts";
import { CommandCatalog, sdkCommandDiscovery, type DiscoverCommands } from "./claude/commands.ts";
import { ModelCatalog, sdkModelDiscovery, type DiscoverModels } from "./claude/models.ts";
import { createAccountHandlers } from "./handlers/account.ts";
import { createCommandHandlers } from "./handlers/commands.ts";
import { createHistoryHandlers } from "./handlers/history.ts";
import { createThreadHandlers } from "./handlers/threads.ts";
import { createTurnHandlers } from "./handlers/turns.ts";
import { isHolderWorking } from "./runtime/holders.ts";
import { ThreadManager, type ManagerOptions } from "./runtime/manager.ts";
import { unavailableRateLimits } from "./runtime/rateLimits.ts";
import type { InitializeResponse } from "./protocol/codex/InitializeResponse.ts";
import { Router, type Handler, type Logger } from "./server/router.ts";
import { logger } from "./util/logging.ts";
import { ADAPTER_NAME, ADAPTER_VERSION, MINIMUM_CLAUDE_CODE_VERSION, USER_AGENT } from "./version.ts";

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
  /** agentd 预检按它提示用户升级 Claude Code。 */
  claudeCode: { minimumVersion: string };
}

/** 客户端发来、适配器接受但不应答的通知；网关按声明开放，漏声明会被当成不支持。 */
const ACCEPTED_NOTIFICATIONS = ["initialized"];

export function capabilityDeclaration(router: Router): CapabilityDeclaration {
  const methods = [...router.methods(), ...ACCEPTED_NOTIFICATIONS].sort();
  return { name: ADAPTER_NAME, version: ADAPTER_VERSION, methods, fullAccess: true, claudeCode: { minimumVersion: MINIMUM_CLAUDE_CODE_VERSION } };
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
  /** 测试用：turn 收尾后检查标题的时间点。 */
  titleCheckDelaysMs?: number[];
  /** 测试用：模型目录的来源。 */
  discoverModels?: DiscoverModels;
  /** 测试用：没有常驻进程时命令目录的来源。 */
  discoverCommands?: DiscoverCommands;
  /** 测试用：Claude Code 版本探测。 */
  probeClaudeCode?: (executable: string) => Promise<ClaudeCodeProbe>;
  /** 发给全部已附着连接的通知；常驻模式由 main 接到会话注册表。 */
  broadcast?: ManagerOptions["broadcast"];
  /** 缺省开启；agentd 的 Mac 配置关闭时用环境变量显式传 false。 */
  turnHintsEnabled?: boolean;
}

export interface App {
  router: Router;
  manager: ThreadManager;
  models: ModelCatalog;
  /** 把旧 bridge 里的 Mimi 名称写成 custom-title（#660）；全部处理完后不再执行。 */
  migrateLegacyNames(): Promise<void>;
}

export function createApp(options: AppOptions): App {
  const stateDir = options.stateDir ?? defaultStateDir();
  const sessions = options.sessions ?? sdkSessions;
  const transcripts = new TranscriptIndex();
  const activity = new ActivityClock();
  const directories = new WorkingDirectories();
  const legacyIndex = legacyIndexPath();
  const overlay = new Overlay(path.join(stateDir, "overlay.json"), legacyIndex);
  const desktopSpawns = new DesktopSpawnIndex();
  const catalog = new Catalog({ sessions, transcripts, activity, directories, overlay, desktopSpawns });
  const history = new HistoryStore({ sessions, transcripts, overlay });
  const claudeExecutable = options.claudeExecutable ?? defaultClaudeExecutable;
  const claudeCode = new ClaudeCodeVersionGate(claudeExecutable, options.probeClaudeCode);
  const manager = new ThreadManager({
    claudeExecutable,
    promptSuggestionsSupported: () => claudeCode.supportsPromptSuggestions,
    log: options.log,
    ...(options.startQuery ? { startQuery: options.startQuery } : {}),
    ...(options.idleCloseMs !== undefined ? { idleCloseMs: options.idleCloseMs } : {}),
    ...options.ownership,
    readTitle: async (threadId) => (await sessions.info(threadId))?.customTitle?.trim() || null,
    ...(options.titleCheckDelaysMs ? { titleCheckDelaysMs: options.titleCheckDelaysMs } : {}),
    ...(options.broadcast ? { broadcast: options.broadcast } : {}),
    ...(options.turnHintsEnabled ?? turnHintsEnabledFromEnvironment()
      ? { turnHints: { store: overlay } }
      : {}),
    // 与 thread/list 的 updatedAt 同源：最后一条对话消息的时间（秒）。不能沿用 1 秒缓存：一轮很短的
    // 回合在这个窗口里结束时，旧索引会把回合前的时间当成最新，列表就认不出这次完成。只复用这一轮
    // 持有方扫描开始之后才发起的索引扫描，同批多个变化共用一次（#912）。
    readActivity: async (threadId, freshSince) => {
      await transcripts.refreshSince(freshSince);
      const file = transcripts.get(threadId);
      const ms = file ? await activity.lastActivityMs(file) : undefined;
      return ms === undefined ? undefined : Math.floor(ms / 1000);
    },
  });
  const holders = () => manager.holders();
  const activeTurnId = (threadId: string) => manager.get(threadId)?.activeTurnId;
  const threads = createThreadHandlers(catalog, history, {
    holders,
    activeTurnId,
    hasLiveProcess: (threadId) => manager.get(threadId)?.hasLiveProcess() ?? false,
    loadedThreadIds: () => manager.loadedThreadIds(),
  });
  const historyHandlers = createHistoryHandlers(
    history,
    (threadId) => activeTurnId(threadId) !== undefined,
    async (threadId) => isHolderWorking((await holders()).get(threadId)),
  );
  const turns = createTurnHandlers({ manager, catalog, sessions, holders, claudeCode, overlay });
  const models = new ModelCatalog({ discover: options.discoverModels ?? sdkModelDiscovery(claudeExecutable), log: options.log });
  const account = createAccountHandlers(models, () => manager.observedRateLimits ?? unavailableRateLimits());
  const commands = createCommandHandlers(
    new CommandCatalog({
      discover: options.discoverCommands ?? sdkCommandDiscovery(claudeExecutable),
      live: (cwd, loadsSettings) => manager.liveCommands(cwd, loadsSettings),
      terminal: () => manager.terminalCommands,
      log: options.log,
    }),
  );

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
    ["slashCommand/list", (params) => commands.list(params)],
    ["account/rateLimits/read", () => account.rateLimitsRead()],
  ]);
  async function migrateNames(): Promise<void> {
    await overlay.load();
    if (overlay.legacyNamesMigrated()) return;
    const legacy = await readLegacyIndex(legacyIndex);
    // 旧索引暂时读不了：不迁移也不记完成，下次启动连同归档标记一起重试。
    if (legacy.status === "unreadable" || overlay.legacyImportPending()) {
      logger.warn("legacy.index.unreadable", {});
      return;
    }
    const result = await migrateLegacyNames({
      threads: legacy.status === "ok" ? legacy.threads : [],
      sessions,
      transcriptPath: async (sessionId) => {
        await transcripts.refresh();
        return transcripts.get(sessionId)?.path;
      },
      heldElsewhere: async () => new Set((await manager.holders()).keys()),
    });
    if (result.renamed || result.kept || result.deferred) logger.info("legacy.names", { ...result });
    // 有会话被占用或写入失败时不记完成，下次启动再试；已写过的会话因为有了 custom-title 不会重复写。
    if (result.deferred === 0) await overlay.markLegacyNamesMigrated();
  }

  return { router: new Router(handlers, options.log), manager, models, migrateLegacyNames: migrateNames };
}

export function turnHintsEnabledFromEnvironment(
  value = process.env.MIMI_CLAUDE_TURN_HINTS_ENABLED,
): boolean {
  if (value === undefined || value.trim() === "") return true;
  return !["0", "false", "off", "disabled"].includes(value.trim().toLowerCase());
}

/** 只需要方法分发的场景（只读测试等）。 */
export function createRouter(options: AppOptions): Router {
  return createApp(options).router;
}
