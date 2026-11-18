import os from "node:os";
import path from "node:path";
import type { InitializeResponse } from "@mimi/appserver-kit/protocol/codex/InitializeResponse.ts";
import { Router, type Handler, type Logger } from "@mimi/appserver-kit/server/router.ts";
import { AgyVersionGate, defaultProbeAgy, defaultSpawnAgyTransport, type ProbeAgy, type SpawnAgyTransport } from "./agy/binary.ts";
import { AgyCatalog, AgyHistoryStore, createAcpSessionBackend, type AgySessionBackend } from "./agy/catalog.ts";
import { acpCommandDiscovery, CommandCatalog, type DiscoverAgyCommands } from "./agy/commands.ts";
import { defaultAgyExecutable } from "./agy/env.ts";
import { GitRepoIndex } from "./agy/git.ts";
import { acpModelDiscovery, ModelCatalog, type DiscoverAgyModels } from "./agy/models.ts";
import { AgyOverlay } from "./agy/overlay.ts";
import { createAccountHandlers } from "./handlers/account.ts";
import { createCommandHandlers } from "./handlers/commands.ts";
import { createHistoryHandlers } from "./handlers/history.ts";
import { createThreadHandlers } from "./handlers/threads.ts";
import { createTurnHandlers } from "./handlers/turns.ts";
import { ThreadManager, unavailableAgyRateLimits } from "./runtime/manager.ts";
import { ADAPTER_NAME, ADAPTER_VERSION, MINIMUM_AGY_VERSION, USER_AGENT } from "./version.ts";

export interface CapabilityDeclaration {
  name: string;
  version: string;
  methods: string[];
  fullAccess: boolean;
  agy: { minimumVersion: string };
}

const ACCEPTED_NOTIFICATIONS = ["initialized"];

export function capabilityDeclaration(router: Router): CapabilityDeclaration {
  const methods = [...router.methods(), ...ACCEPTED_NOTIFICATIONS].sort();
  return {
    name: ADAPTER_NAME,
    version: ADAPTER_VERSION,
    methods,
    fullAccess: true,
    agy: { minimumVersion: MINIMUM_AGY_VERSION },
  };
}

export function defaultStateDir(env: NodeJS.ProcessEnv = process.env): string {
  if (env.MIMI_AGY_ADAPTER_STATE_DIR) return env.MIMI_AGY_ADAPTER_STATE_DIR;
  if (process.platform === "darwin") {
    return path.join(os.homedir(), "Library", "Application Support", "mimi-remote", "agy-adapter");
  }
  if (process.platform === "win32") {
    return path.join(env.APPDATA ?? path.join(os.homedir(), "AppData", "Roaming"), "mimi-remote", "agy-adapter");
  }
  return path.join(env.XDG_STATE_HOME ?? path.join(os.homedir(), ".local", "state"), "mimi-remote", "agy-adapter");
}

export interface AppOptions {
  stateDir?: string;
  log: Logger;
  agyExecutable?: () => string;
  spawnTransport?: SpawnAgyTransport;
  probeAgy?: ProbeAgy;
  sessionBackend?: AgySessionBackend;
  discoverModels?: DiscoverAgyModels;
  discoverCommands?: DiscoverAgyCommands;
  env?: () => NodeJS.ProcessEnv;
  idleCloseMs?: number;
}

export interface App {
  router: Router;
  manager: ThreadManager;
  models: ModelCatalog;
}

export function createApp(options: AppOptions): App {
  const env = options.env ?? (() => process.env);
  const stateDir = options.stateDir ?? defaultStateDir(env());
  const agyExecutable = options.agyExecutable ?? (() => defaultAgyExecutable(env()));
  const spawnTransport = options.spawnTransport ?? defaultSpawnAgyTransport;
  const agyGate = new AgyVersionGate(agyExecutable, options.probeAgy ?? defaultProbeAgy, env);
  const overlay = new AgyOverlay(path.join(stateDir, "overlay.json"));
  const git = new GitRepoIndex();
  const backend = options.sessionBackend ?? createAcpSessionBackend(agyExecutable, spawnTransport, env);

  const models = new ModelCatalog({
    discover: options.discoverModels ?? acpModelDiscovery(agyExecutable, spawnTransport, env),
    log: options.log,
  });

  let managerRef: ThreadManager | undefined;
  const commands = new CommandCatalog({
    discover: options.discoverCommands ?? acpCommandDiscovery(agyExecutable, spawnTransport, env),
    live: (cwd) => managerRef?.liveCommands(cwd),
    log: options.log,
  });

  const manager = new ThreadManager({
    agyExecutable,
    spawnTransport,
    env,
    ...(options.idleCloseMs !== undefined ? { idleCloseMs: options.idleCloseMs } : {}),
    onSessionOpen: (open) => models.observeSessionOpen(open),
    onAvailableCommands: (cwd, cmds) => commands.observeLiveCommands(cwd, cmds),
    onTurnPersisted: (threadId, patch) => {
      void overlay.recordSession(threadId, patch);
    },
    hasCustomTitle: (threadId) => Boolean(overlay.get(threadId)?.customTitle?.trim()),
  });
  managerRef = manager;

  const catalog = new AgyCatalog({
    backend,
    git,
    overlay,
    inMemorySessions: () => manager.inMemorySessionSnapshots(),
  });
  const history = new AgyHistoryStore(catalog, backend, (sessionId) => manager.liveTurns(sessionId));

  const activeTurnId = (threadId: string) => manager.get(threadId)?.activeTurnId;
  const threads = createThreadHandlers(catalog, history, {
    activeTurnId,
    hasLiveProcess: (threadId) => manager.get(threadId)?.hasLiveProcess() ?? false,
    loadedThreadIds: () => manager.loadedThreadIds(),
  });
  const historyHandlers = createHistoryHandlers(history, (threadId) => activeTurnId(threadId) !== undefined);
  const turns = createTurnHandlers({ manager, catalog, history, overlay, agyGate });
  const account = createAccountHandlers(models, unavailableAgyRateLimits);
  const commandHandlers = createCommandHandlers(commands);

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
    ["turn/start", (params, context) => turns.turnStart(params, context)],
    ["turn/interrupt", (params) => turns.turnInterrupt(params)],
    ["thread/name/set", (params) => turns.threadSetName(params)],
    ["model/list", () => account.modelList()],
    ["slashCommand/list", (params) => commandHandlers.list(params)],
    ["account/rateLimits/read", () => account.rateLimitsRead()],
  ]);

  return {
    router: new Router(handlers, options.log),
    manager,
    models,
  };
}
