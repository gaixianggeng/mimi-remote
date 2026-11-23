import os from "node:os";
import path from "node:path";
import type { InitializeResponse } from "@mimi/appserver-kit/protocol/codex/InitializeResponse.ts";
import { Router, type Handler, type Logger } from "@mimi/appserver-kit/server/router.ts";
import {
  AgyVersionGate,
  defaultProbeAgy,
  defaultSpawnAgyTransport,
  SharedReadonlyAcp,
  type ProbeAgy,
  type SpawnAgyTransport,
} from "./agy/binary.ts";
import { AgyCatalog, AgyHistoryStore, createAcpSessionBackend, type AgySessionBackend, type OtherListDiagnostic } from "./agy/catalog.ts";
import { acpCommandDiscovery, CommandCatalog, type DiscoverAgyCommands } from "./agy/commands.ts";
import { appDataDirForOrigin, defaultAgyExecutable } from "./agy/env.ts";
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
  externalWritePollMs?: number;
  onOtherListDiagnostic?: (diag: OtherListDiagnostic) => void;
}

export interface App {
  router: Router;
  manager: ThreadManager;
  models: ModelCatalog;
  close(): Promise<void>;
}

export function createApp(options: AppOptions): App {
  const env = options.env ?? (() => process.env);
  const stateDir = options.stateDir ?? defaultStateDir(env());
  const agyExecutable = options.agyExecutable ?? (() => defaultAgyExecutable(env()));
  const spawnTransport = options.spawnTransport ?? defaultSpawnAgyTransport;
  const agyGate = new AgyVersionGate(agyExecutable, options.probeAgy ?? defaultProbeAgy, env);
  const overlay = new AgyOverlay(path.join(stateDir, "overlay.json"));
  const git = new GitRepoIndex();
  const cliSharedAcp = new SharedReadonlyAcp(agyExecutable, spawnTransport, env, appDataDirForOrigin("cli", env()));
  const otherSharedAcp = new SharedReadonlyAcp(agyExecutable, spawnTransport, env, appDataDirForOrigin("other", env()));
  let managerRef: ThreadManager | undefined;
  let catalogRef: AgyCatalog | undefined;
  let historyRef: AgyHistoryStore | undefined;
  const backend =
    options.sessionBackend ??
    createAcpSessionBackend(
      cliSharedAcp,
      otherSharedAcp,
      env,
      (sessionId) => managerRef?.get(sessionId)?.hasLiveProcess() ?? false,
      options.onOtherListDiagnostic,
    );

  const models = new ModelCatalog({
    discover: options.discoverModels ?? acpModelDiscovery(cliSharedAcp),
    log: options.log,
  });

  const commands = new CommandCatalog({
    discover: options.discoverCommands ?? acpCommandDiscovery(cliSharedAcp),
    live: (cwd) => managerRef?.liveCommands(cwd),
    log: options.log,
  });

  const otherAppDataDir = appDataDirForOrigin("other", env());
  const manager = new ThreadManager({
    acquireClient: (appDataDirName) => (appDataDirName === otherAppDataDir ? otherSharedAcp.acquire() : cliSharedAcp.acquire()),
    ...(options.idleCloseMs !== undefined ? { idleCloseMs: options.idleCloseMs } : {}),
    ...(options.externalWritePollMs !== undefined ? { externalWritePollMs: options.externalWritePollMs } : {}),
    onSessionOpen: (open) => models.observeSessionOpen(open),
    onAvailableCommands: (cwd, cmds) => commands.observeLiveCommands(cwd, cmds),
    onTurnPersisted: (threadId, patch) => {
      catalogRef?.invalidate();
      historyRef?.invalidate(threadId);
      void overlay.recordSession(threadId, patch);
    },
    reserveTurnAttempt: (threadId, info) => overlay.reserveTurnAttempt(threadId, info),
    existingTurnCount: (threadId) => historyRef?.persistedTurnCount(threadId) ?? Promise.resolve(0),
    existingTurnInfo: (threadId) =>
      historyRef?.persistedTurnInfo(threadId) ?? Promise.resolve({ nativeTurnCount: 0, maxTurnOrdinal: 0 }),
    hasCustomTitle: (threadId) => Boolean(overlay.get(threadId)?.customTitle?.trim()),
    inspectTranscriptState: (threadId) => catalogRef?.transcriptStateDetailed(threadId) ?? Promise.resolve({ kind: "missing" as const }),
    externalActivity: (threadId, opts) => catalogRef?.externalActivity(threadId, opts) ?? Promise.resolve(undefined),
  });
  managerRef = manager;

  const catalog = new AgyCatalog({
    backend,
    git,
    overlay,
    inMemorySessions: () => manager.inMemorySessionSnapshots(),
  });
  catalogRef = catalog;
  const history = new AgyHistoryStore(
    catalog,
    backend,
    (sessionId) => manager.liveTurns(sessionId),
    (turnId) => manager.clientIdForTurn(turnId),
    (sessionId, turnId) => overlay.getTurnOutcome(sessionId, turnId),
    (sessionId) => overlay.getTurnAttempts(sessionId),
    (sessionId, turnId) => overlay.getToolMappings(sessionId, turnId),
  );
  historyRef = history;

  const activeTurnId = (threadId: string) => manager.get(threadId)?.activeTurnId;
  const threads = createThreadHandlers(catalog, history, {
    activeTurnId,
    hasLiveProcess: (threadId) => manager.get(threadId)?.hasLiveProcess() ?? false,
    loadedThreadIds: () => manager.loadedThreadIds(),
  });
  const historyHandlers = createHistoryHandlers(
    history,
    (threadId) => activeTurnId(threadId) !== undefined,
    async (threadId) => Boolean((await catalog.externalActivity(threadId))?.externallyBusy),
  );
  const turns = createTurnHandlers({ manager, catalog, history, overlay, agyGate, env });
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
    async close() {
      await Promise.allSettled([manager.closeAll(), cliSharedAcp.close(), otherSharedAcp.close()]);
      await overlay.flush().catch(() => {});
    },
  };
}
