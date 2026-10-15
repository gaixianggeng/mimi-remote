// model/list：读取 Claude Code 自己的模型目录（initialize 返回的 models），整理成与 Claude
// 桌面版一致的主列表。整理规则与旧 bridge 相同：
// - `default` 别名不单独占一行，"默认"标记落到它解析出的那个模型上；
// - 每个家族只留最新版本，其余条目标 hidden；
// - 顺序为 Fable > Opus > Sonnet > Haiku，家族内版本降序，同版本优先 1M 上下文；
// - 目录拿不到时退回 opus / sonnet / haiku 三个别名，由 CLI 自己解析。
import { query as sdkQuery, type ModelInfo } from "@anthropic-ai/claude-agent-sdk";
import type { Model } from "../protocol/codex/v2/Model.ts";
import { logger } from "../util/logging.ts";

/** 协议认识的思考强度；CLI 给出的其他档位不转发，客户端不知道怎么展示。 */
const KNOWN_EFFORTS = ["none", "minimal", "low", "medium", "high", "xhigh", "max"] as const;
const FAMILY_RANK: Record<string, number> = { fable: 1, opus: 2, sonnet: 3, haiku: 4 };

function resolvedId(info: ModelInfo): string {
  const resolved = info.resolvedModel?.trim();
  return resolved ? resolved : info.value;
}

/** `claude-fable-5-1[1m]` → `fable`；识别不出家族返回 undefined。 */
export function modelFamily(id: string): string | undefined {
  const base = id.split("[")[0]!;
  if (!base.startsWith("claude-")) return undefined;
  const family = base.slice("claude-".length).split("-")[0] ?? "";
  if (!family || /^\d+$/.test(family)) return undefined;
  return family.toLowerCase();
}

/** `claude-fable-5-1[1m]` → `Claude Fable 5.1 (1M)`；非常规命名返回 undefined。 */
export function modelVersionTitle(id: string): string | undefined {
  const bracket = id.indexOf("[");
  let context: string | undefined;
  let base = id;
  if (bracket >= 0) {
    if (!id.endsWith("]")) return undefined;
    context = id.slice(bracket + 1, -1);
    base = id.slice(0, bracket);
  }
  if (!base.startsWith("claude-")) return undefined;
  const parts = base.slice("claude-".length).split("-");
  const versionStart = parts.findIndex((part) => /^\d+$/.test(part));
  if (versionStart <= 0) return undefined;
  const version: string[] = [];
  for (const part of parts.slice(versionStart)) {
    // 日期后缀（如 20250514）不进标题。
    if (/^\d{8}$/.test(part)) break;
    if (!/^\d+$/.test(part)) return undefined;
    version.push(part);
  }
  if (!version.length) return undefined;
  const name = parts
    .slice(0, versionStart)
    .map((part) => (part ? part[0]!.toUpperCase() + part.slice(1) : part))
    .join(" ");
  return `Claude ${name} ${version.join(".")}${context ? ` (${context.toUpperCase()})` : ""}`;
}

/** 排序键：Default 第一，其余按家族、版本降序、1M 上下文优先；未知家族保持 CLI 原顺序排最后。 */
function rank(info: ModelInfo): number[] {
  if (info.value === "default") return [0];
  const id = info.resolvedModel ?? info.value;
  const [rawBase, rawContext = ""] = id.split("[");
  const base = rawBase!.replace(/^claude-/, "");
  const family = (base.split("-")[0] ?? "").toLowerCase();
  const version = [0, 0, 0, 0];
  const parts = base.split("-").slice(1);
  for (let i = 0; i < parts.length && i < 4; i += 1) {
    const part = parts[i]!;
    if (!part || part.length >= 8 || !/^\d+$/.test(part)) break;
    version[i] = Number(part);
  }
  const context = rawContext.replace(/\]$/, "").toLowerCase() === "1m" ? 0 : 1;
  return [1, FAMILY_RANK[family] ?? 5, ...version.map((value) => -value), context];
}

function compareRank(a: number[], b: number[]): number {
  for (let i = 0; i < Math.max(a.length, b.length); i += 1) {
    const diff = (a[i] ?? 0) - (b[i] ?? 0);
    if (diff) return diff;
  }
  return 0;
}

function buildModel(id: string, displayName: string, description: string, isDefault: boolean, efforts: string[]): Model {
  const defaultEffort = efforts.includes("high") ? "high" : (efforts[0] ?? "none");
  return {
    id,
    model: id,
    upgrade: null,
    upgradeInfo: null,
    availabilityNux: null,
    displayName,
    description,
    modelSpecialty: null,
    hidden: false,
    supportedReasoningEfforts: efforts.map((reasoningEffort) => ({ reasoningEffort, description: "" })),
    defaultReasoningEffort: defaultEffort,
    inputModalities: ["text", "image"],
    supportsPersonality: false,
    multiAgentVersion: null,
    additionalSpeedTiers: [],
    serviceTiers: [{ id: "standard", name: "Standard", description: "Default bridge service tier" }],
    defaultServiceTier: null,
    availableAccessPrograms: null,
    isDefault,
  };
}

function effortsOf(info: ModelInfo): string[] {
  if (info.supportsEffort === false) return [];
  if (info.supportedEffortLevels) {
    return info.supportedEffortLevels.filter((level) => (KNOWN_EFFORTS as readonly string[]).includes(level));
  }
  // 旧 CLI 只声明支持 effort 时保留默认 high，不猜它支持 Max 等额外档位。
  return info.supportsEffort === true ? ["high"] : [];
}

export function convertModel(info: ModelInfo): Model | undefined {
  if (!info.value.trim()) return undefined;
  const title =
    info.value === "default"
      ? info.displayName
      : (modelVersionTitle(info.resolvedModel ?? info.value) ?? info.displayName);
  const model = buildModel(info.value, title, info.description, false, effortsOf(info));
  if (!model.displayName.trim()) model.displayName = info.value;
  return model;
}

export function catalogModels(models: ModelInfo[]): Model[] {
  const ordered = models
    .map((info, index) => ({ info, index, rank: rank(info) }))
    .sort((a, b) => compareRank(a.rank, b.rank) || a.index - b.index)
    .map((entry) => entry.info);
  const aliasDefault = ordered.find((info) => info.value === "default");
  const defaultResolved = aliasDefault ? resolvedId(aliasDefault) : undefined;
  const families = new Set<string>();
  let defaultMarked = false;
  const out: Model[] = [];
  for (const info of ordered) {
    if (info.value === "default") continue;
    const resolved = resolvedId(info);
    // 家族未知（第三方或未来命名）时按条目自身分组：不确定的不折叠。
    const family = modelFamily(resolved) ?? `id:${resolved}`;
    const primary = !families.has(family);
    families.add(family);
    const isDefault = !defaultMarked && primary && defaultResolved === resolved;
    if (isDefault) defaultMarked = true;
    const model = convertModel(info);
    if (!model) continue;
    model.hidden = !primary;
    model.isDefault = isDefault;
    out.push(model);
  }
  // 默认解析不到任何可见行（例如 CLI 只给了别名）时保留别名行，避免没有默认项。
  if (!defaultMarked && aliasDefault) {
    const model = convertModel(aliasDefault);
    if (model) {
      model.isDefault = true;
      out.unshift(model);
    }
  }
  return out;
}

export function fallbackModels(): Model[] {
  const efforts = ["medium", "high", "xhigh", "max"];
  return [
    buildModel("opus", "Claude Opus", "Claude CLI alias; model catalog unavailable.", true, efforts),
    buildModel("sonnet", "Claude Sonnet", "Claude CLI alias; model catalog unavailable.", false, efforts),
    buildModel("haiku", "Claude Haiku", "Claude CLI alias; model catalog unavailable.", false, []),
  ];
}

export type DiscoverModels = (timeoutMs: number) => Promise<ModelInfo[]>;

/**
 * 起一个不带工具、不加载 MCP 与 hooks、不保存会话的 Claude 进程，只读 initialize 返回的
 * 模型目录，不发送任何消息。
 */
export function sdkModelDiscovery(claudeExecutable: () => string): DiscoverModels {
  return async (timeoutMs) => {
    const abortController = new AbortController();
    const idle: AsyncIterable<never> = {
      [Symbol.asyncIterator]: () => ({ next: () => new Promise<never>(() => {}) }),
    };
    const query = sdkQuery({
      prompt: idle,
      options: {
        abortController,
        pathToClaudeCodeExecutable: claudeExecutable(),
        tools: [],
        strictMcpConfig: true,
        persistSession: false,
        settings: { disableAllHooks: true },
      },
    });
    const timer = setTimeout(() => abortController.abort(), timeoutMs);
    try {
      return await query.supportedModels();
    } finally {
      clearTimeout(timer);
      query.close();
    }
  };
}

export interface ModelCatalogOptions {
  discover: DiscoverModels;
  ttlMs?: number;
  failureCooldownMs?: number;
  log(message: string): void;
}

/** 目录缓存 10 分钟；失败后 15 秒内直接用别名回退，不反复冷启动 CLI；并发请求共用一次查询。 */
export class ModelCatalog {
  private models: ModelInfo[] | undefined;
  private fetchedAt = 0;
  private failedAt = 0;
  private inFlight: Promise<ModelInfo[] | undefined> | undefined;

  constructor(private readonly options: ModelCatalogOptions) {}

  /**
   * 每个请求按自己的时限等待：并发请求共用一次查询（例如启动预热给了 30 秒），超时就先用缓存
   * 或别名回答，查询在后台继续完成并填充缓存。
   */
  async list(timeoutMs = 10_000): Promise<Model[]> {
    let timer: ReturnType<typeof setTimeout> | undefined;
    const deadline = new Promise<ModelInfo[] | undefined>((resolve) => {
      timer = setTimeout(() => resolve(this.models), timeoutMs);
      timer.unref?.();
    });
    const models = await Promise.race([this.load(timeoutMs), deadline]).finally(() => clearTimeout(timer));
    const data = models ? catalogModels(models) : [];
    return data.length ? data : fallbackModels();
  }

  /** 启动时预热，让首个 model/list 命中缓存而不是在 CLI 冷启动期间超时回退。 */
  warm(): void {
    void this.load(30_000);
  }

  private load(timeoutMs: number): Promise<ModelInfo[] | undefined> {
    const now = Date.now();
    if (this.models && now - this.fetchedAt < (this.options.ttlMs ?? 10 * 60_000)) return Promise.resolve(this.models);
    if (this.inFlight) return this.inFlight;
    if (now - this.failedAt < (this.options.failureCooldownMs ?? 15_000)) return Promise.resolve(this.models);
    const started = Date.now();
    this.inFlight = this.options
      .discover(timeoutMs)
      .then((models) => {
        this.models = models;
        this.fetchedAt = Date.now();
        logger.debug("models.discovered", { count: models.length, ms: Date.now() - started });
        return models;
      })
      .catch((error) => {
        // 不把 CLI 初始化响应或账号信息写进日志。
        this.options.log(`model catalog unavailable: ${error instanceof Error ? error.name : "error"}`);
        this.failedAt = Date.now();
        return this.models;
      })
      .finally(() => {
        this.inFlight = undefined;
      });
    return this.inFlight;
  }
}
