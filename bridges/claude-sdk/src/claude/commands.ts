// slashCommand/list：Claude Code 自己的斜杠命令目录（内置命令、技能、自定义命令），供客户端
// 输入框的 `/` 菜单展示（#765）。客户端只把 `/名称 ` 插进草稿，按普通文本发送，由 Claude Code
// 自己解析，适配器不执行命令。实测（Claude Code 2.1.301）：只有纯文本消息以 `/名称` 开头时才会
// 被解析；带图片的消息、写在正文之后的 `/名称` 都按原文交给模型。
import { query as sdkQuery, type SlashCommand } from "@anthropic-ai/claude-agent-sdk";
import { RpcError } from "../rpc/frames.ts";
import { logger } from "../util/logging.ts";

export interface CommandEntry {
  name: string;
  description: string;
  argumentHint: string | null;
  aliases: string[];
}

/**
 * 与 Mimi 自己管理的会话状态冲突的命令，不进目录（实测）：`/clear` 让 CLI 换一个新会话 ID，
 * 之后的回合写进别的 transcript，Mimi 里的会话不再更新；`/model`、`/effort` 只改 CLI 进程，
 * 客户端的模型与思考强度选择器不知道，下一轮也不会改回。这几项由客户端自己的入口负责。
 */
const SESSION_MANAGED = new Set(["clear", "model", "effort"]);
const DESCRIPTION_LIMIT = 300;

/** 只有不含空白与斜杠的名字能作为 `/名称` 输入；`__` 开头的是 CLI 内部入口。 */
function typeable(name: string): boolean {
  return /^[^\s/]+$/.test(name) && !name.startsWith("__");
}

function shortened(text: string): string {
  const line = text.trim().replace(/\s+/g, " ");
  return line.length > DESCRIPTION_LIMIT ? `${line.slice(0, DESCRIPTION_LIMIT - 1)}…` : line;
}

/**
 * 整理成客户端目录：去掉终端专用（CLI 在 system/init 里标的 terminal_slash_commands）、
 * 与 Mimi 冲突、无法输入的条目；同名时取 CLI 自己的那一行（输入 `/名称` 时实际运行的那个）。
 * 顺序保持 CLI 给出的顺序。
 */
export function catalogCommands(commands: readonly SlashCommand[], terminal: ReadonlySet<string>): CommandEntry[] {
  const byName = new Map<string, { entry: CommandEntry; builtin: boolean }>();
  for (const command of commands) {
    const name = command.name?.trim() ?? "";
    if (!typeable(name) || terminal.has(name) || SESSION_MANAGED.has(name)) continue;
    const builtin = command.builtin === true;
    const existing = byName.get(name);
    if (existing && (existing.builtin || !builtin)) continue;
    const aliases = (command.aliases ?? []).map((alias) => alias.trim()).filter((alias) => typeable(alias) && alias !== name);
    const hint = command.argumentHint?.trim();
    byName.set(name, {
      builtin,
      entry: { name, description: shortened(command.description ?? ""), argumentHint: hint ? hint : null, aliases },
    });
  }
  return [...byName.values()].map((value) => value.entry);
}

/** loadsSettings：会话是否加载 user / project / local 设置。受限档位不加载（见 sandboxPolicy），目录也不同。 */
export type DiscoverCommands = (cwd: string, loadsSettings: boolean, timeoutMs: number) => Promise<SlashCommand[]>;

/**
 * 起一个不带工具、不启动 MCP、不跑 hooks、不保存会话的 Claude 进程，只读 initialize 返回的
 * 命令目录，不发送任何消息。MCP 提供的命令因此不在其中，有常驻进程时以它为准。
 */
export function sdkCommandDiscovery(claudeExecutable: () => string): DiscoverCommands {
  return async (cwd, loadsSettings, timeoutMs) => {
    const abortController = new AbortController();
    const idle: AsyncIterable<never> = {
      [Symbol.asyncIterator]: () => ({ next: () => new Promise<never>(() => {}) }),
    };
    const query = sdkQuery({
      prompt: idle,
      options: {
        abortController,
        cwd,
        pathToClaudeCodeExecutable: claudeExecutable(),
        tools: [],
        strictMcpConfig: true,
        persistSession: false,
        settings: { disableAllHooks: true },
        ...(loadsSettings ? {} : { settingSources: [] }),
      },
    });
    const timer = setTimeout(() => abortController.abort(), timeoutMs);
    try {
      return await query.supportedCommands();
    } finally {
      clearTimeout(timer);
      query.close();
    }
  };
}

export interface CommandCatalogOptions {
  discover: DiscoverCommands;
  /** 同一工作区、同一设置来源的常驻 Claude 进程的目录（含 MCP 命令与运行中发现的技能）。 */
  live?: (cwd: string, loadsSettings: boolean) => Promise<SlashCommand[]> | undefined;
  /** CLI 标为终端专用的命令名，取自最近一次 system/init；还没跑过回合时为空。 */
  terminal: () => ReadonlySet<string>;
  ttlMs?: number;
  failureCooldownMs?: number;
  timeoutMs?: number;
  maxEntries?: number;
  log(message: string): void;
}

interface Cached {
  commands?: SlashCommand[];
  fetchedAt: number;
  failedAt: number;
  inFlight?: Promise<SlashCommand[]>;
}

/**
 * 按（工作区, 是否加载设置）缓存 5 分钟；并发请求共用一次查询；失败后 15 秒内直接报错，
 * 不反复冷启动 CLI。forceReload 跳过缓存（新加的技能立即可见）。
 */
export class CommandCatalog {
  private readonly entries = new Map<string, Cached>();

  constructor(private readonly options: CommandCatalogOptions) {}

  async list(cwd: string, loadsSettings: boolean, forceReload = false): Promise<CommandEntry[]> {
    const live = this.options.live?.(cwd, loadsSettings);
    const commands = live ? await live.catch(() => this.load(cwd, loadsSettings, forceReload)) : await this.load(cwd, loadsSettings, forceReload);
    return catalogCommands(commands, this.options.terminal());
  }

  private load(cwd: string, loadsSettings: boolean, forceReload: boolean): Promise<SlashCommand[]> {
    const key = `${loadsSettings ? "settings" : "isolated"}\0${cwd}`;
    const now = Date.now();
    const cached = this.entries.get(key) ?? { fetchedAt: 0, failedAt: 0 };
    if (cached.inFlight) return cached.inFlight;
    if (!forceReload && cached.commands && now - cached.fetchedAt < (this.options.ttlMs ?? 5 * 60_000)) {
      return Promise.resolve(cached.commands);
    }
    if (!forceReload && now - cached.failedAt < (this.options.failureCooldownMs ?? 15_000)) {
      return Promise.reject(unavailable());
    }
    const started = Date.now();
    cached.inFlight = this.options
      .discover(cwd, loadsSettings, this.options.timeoutMs ?? 15_000)
      .then((commands) => {
        cached.commands = commands;
        cached.fetchedAt = Date.now();
        logger.debug("commands.discovered", { count: commands.length, settings: loadsSettings, ms: Date.now() - started });
        return commands;
      })
      .catch((error) => {
        // 不把 CLI 的初始化响应写进日志。
        this.options.log(`command catalog unavailable: ${error instanceof Error ? error.name : "error"}`);
        cached.failedAt = Date.now();
        throw unavailable();
      })
      .finally(() => {
        cached.inFlight = undefined;
      });
    this.remember(key, cached);
    return cached.inFlight;
  }

  /** 工作区数量有上限，超出时丢掉最久没用的一项。 */
  private remember(key: string, cached: Cached): void {
    this.entries.delete(key);
    this.entries.set(key, cached);
    const max = this.options.maxEntries ?? 32;
    while (this.entries.size > max) {
      const oldest = this.entries.keys().next().value;
      if (oldest === undefined) break;
      this.entries.delete(oldest);
    }
  }
}

function unavailable(): RpcError {
  return new RpcError(-32603, "Claude 命令目录暂不可用", { reason: "command_catalog_unavailable", retryable: true });
}
