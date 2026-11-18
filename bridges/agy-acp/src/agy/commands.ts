import { errorText, logger } from "../util/logging.ts";
import type { AcpAvailableCommand } from "../acp/types.ts";
import { startAgyAcpClient, type SpawnAgyTransport } from "./binary.ts";

export interface CommandEntry {
  name: string;
  description: string;
  argumentHint: string | null;
  aliases: string[];
}

/**
 * 与 Mimi 自身会话生命周期或 TUI 退出冲突的命令不暴露在 `/` 菜单中：
 * - `exit` / `quit` / `logout` / `login`：终端交互式退出或登录；
 * - `clear` / `new`：会在同一通道内切换会话 ID；
 * - `model` / `mode`：由 Mimi 输入框的模型网格与权限菜单统一管理。
 */
const FILTERED_COMMANDS = new Set(["exit", "quit", "clear", "new", "login", "logout", "model", "mode"]);
const DESCRIPTION_LIMIT = 300;

function typeable(name: string): boolean {
  return /^[^\s/]+$/.test(name) && !name.startsWith("__");
}

function shorten(text: string): string {
  const normalized = text.trim().replace(/\s+/g, " ");
  return normalized.length > DESCRIPTION_LIMIT ? `${normalized.slice(0, DESCRIPTION_LIMIT - 1)}…` : normalized;
}

export function catalogAgyCommands(commands: readonly AcpAvailableCommand[]): CommandEntry[] {
  const seen = new Set<string>();
  const out: CommandEntry[] = [];
  for (const cmd of commands) {
    const rawName = (cmd.name ?? "").trim().replace(/^\/+/, "");
    if (!typeable(rawName) || FILTERED_COMMANDS.has(rawName.toLowerCase()) || seen.has(rawName)) {
      continue;
    }
    seen.add(rawName);
    const hint = cmd.input?.hint?.trim();
    out.push({
      name: rawName,
      description: shorten(cmd.description ?? ""),
      argumentHint: hint ? hint : null,
      aliases: [],
    });
  }
  return out;
}

export type DiscoverAgyCommands = (cwd: string, sandbox: boolean) => Promise<AcpAvailableCommand[]>;

export function acpCommandDiscovery(
  agyExecutable: () => string,
  spawnTransport: SpawnAgyTransport,
  env: () => NodeJS.ProcessEnv = () => process.env,
): DiscoverAgyCommands {
  return async (cwd, sandbox) => {
    let observed: AcpAvailableCommand[] = [];
    let notifyCommands: (() => void) | undefined;
    const waitForCommands = new Promise<void>((resolve) => {
      notifyCommands = resolve;
    });
    const client = await startAgyAcpClient(
      spawnTransport,
      {
        executable: agyExecutable(),
        cwd,
        sandbox,
        env: env(),
      },
      {
        onSessionUpdate: (_sessionId, update) => {
          if (update.sessionUpdate === "available_commands_update" && Array.isArray(update.availableCommands)) {
            observed = update.availableCommands;
            notifyCommands?.();
          }
        },
      },
    );
    try {
      const open = await client.sessionNew(cwd);
      // `agy acp` 在 `session/new` 后异步推送 `available_commands_update`，通常 <150ms 到达。
      await Promise.race([waitForCommands, new Promise<void>((resolve) => setTimeout(resolve, 800))]);
      await client.sessionClose(open.sessionId).catch(() => {});
      return observed;
    } finally {
      await client.close().catch(() => {});
    }
  };
}

export interface CommandCatalogOptions {
  discover: DiscoverAgyCommands;
  live?: (cwd: string) => AcpAvailableCommand[] | undefined;
  ttlMs?: number;
  log?: (message: string) => void;
}

export class CommandCatalog {
  private readonly cache = new Map<string, { commands: AcpAvailableCommand[]; fetchedAt: number; inflight?: Promise<AcpAvailableCommand[]> }>();

  constructor(private readonly options: CommandCatalogOptions) {}

  observeLiveCommands(cwd: string, commands: AcpAvailableCommand[]): void {
    this.cache.set(cwd, { commands, fetchedAt: Date.now() });
  }

  async list(cwd: string, sandbox: boolean, forceReload = false): Promise<CommandEntry[]> {
    if (!forceReload) {
      const live = this.options.live?.(cwd);
      if (live && live.length > 0) {
        return catalogAgyCommands(live);
      }
    }
    const ttlMs = this.options.ttlMs ?? 300_000;
    const key = `${sandbox ? "sandbox" : "full"}:${cwd}`;
    const existing = this.cache.get(key);
    const now = Date.now();
    if (!forceReload && existing && now - existing.fetchedAt < ttlMs && existing.commands.length > 0) {
      return catalogAgyCommands(existing.commands);
    }
    if (existing?.inflight) {
      return catalogAgyCommands(await existing.inflight);
    }
    const inflight = this.options
      .discover(cwd, sandbox)
      .then((commands) => {
        this.cache.set(key, { commands, fetchedAt: Date.now() });
        return commands;
      })
      .catch((error) => {
        logger.debug("agy.commands.failed", { error: errorText(error) });
        this.options.log?.(`agy command discovery failed: ${errorText(error)}`);
        return existing?.commands ?? [];
      });
    this.cache.set(key, { commands: existing?.commands ?? [], fetchedAt: existing?.fetchedAt ?? 0, inflight });
    return catalogAgyCommands(await inflight);
  }
}
