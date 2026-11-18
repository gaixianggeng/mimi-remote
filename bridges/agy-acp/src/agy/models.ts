import os from "node:os";
import type { Model } from "@mimi/appserver-kit/protocol/codex/v2/Model.ts";
import { errorText, logger } from "../util/logging.ts";
import type { AcpSessionOpenResult } from "../acp/types.ts";
import { startAgyAcpClient, type SpawnAgyTransport } from "./binary.ts";

const KNOWN_EFFORTS = ["low", "medium", "high", "xhigh"] as const;

function buildModel(
  id: string,
  displayName: string,
  description: string,
  isDefault: boolean,
  efforts: string[],
  preferredDefaultEffort: string | undefined,
): Model {
  const defaultEffort =
    preferredDefaultEffort && efforts.includes(preferredDefaultEffort)
      ? preferredDefaultEffort
      : efforts.includes("medium")
        ? "medium"
        : efforts.includes("high")
          ? "high"
          : (efforts[0] ?? "none");
  return {
    id,
    model: id,
    upgrade: null,
    upgradeInfo: null,
    availabilityNux: null,
    displayName: displayName.trim() || id,
    description,
    modelSpecialty: null,
    hidden: false,
    supportedReasoningEfforts: efforts.map((reasoningEffort) => ({ reasoningEffort, description: "" })),
    defaultReasoningEffort: defaultEffort,
    inputModalities: ["text", "image"],
    supportsPersonality: false,
    multiAgentVersion: null,
    additionalSpeedTiers: [],
    serviceTiers: [{ id: "standard", name: "Standard", description: "Default Antigravity service tier" }],
    defaultServiceTier: null,
    availableAccessPrograms: null,
    isDefault,
  };
}

function effortsForBaseModel(
  baseId: string,
  availableIds: ReadonlySet<string>,
  fallbackEfforts: readonly string[],
): string[] {
  if (availableIds.size === 0) {
    return [...fallbackEfforts];
  }
  const suffixed = KNOWN_EFFORTS.filter((effort) => availableIds.has(`${baseId}-${effort}`));
  if (suffixed.length > 0) {
    return [...suffixed];
  }
  for (const effort of KNOWN_EFFORTS) {
    if (baseId.endsWith(`-${effort}`) && availableIds.has(baseId)) {
      return [effort];
    }
  }
  return [];
}

/**
 * 把 `agy acp` `session/new` 返回的 `configOptions`（`model` + `thought_level`）与
 * `models.availableModels` 组合为标准 `model/list` 条目。
 */
export function catalogAgyModels(openResult: AcpSessionOpenResult): Model[] {
  const configOptions = openResult.configOptions ?? [];
  const modelOpt = configOptions.find((opt) => opt.id === "model" || opt.category === "model");
  const thoughtOpt = configOptions.find((opt) => opt.id === "thought_level" || opt.category === "thought_level");
  const availableModels = openResult.models?.availableModels ?? [];
  const availableIds = new Set(availableModels.map((entry) => entry.modelId));
  const fallbackEfforts = (thoughtOpt?.options ?? [])
    .map((entry) => entry.value)
    .filter((value) => (KNOWN_EFFORTS as readonly string[]).includes(value));
  const preferredEffort = thoughtOpt?.currentValue;

  if (modelOpt?.options?.length) {
    const out: Model[] = [];
    let defaultMarked = false;
    for (const option of modelOpt.options) {
      const id = option.value.trim();
      if (!id) continue;
      const isDefault = !defaultMarked && id === modelOpt.currentValue;
      if (isDefault) defaultMarked = true;
      const efforts = effortsForBaseModel(id, availableIds, fallbackEfforts);
      out.push(buildModel(id, option.name || id, option.description ?? "", isDefault, efforts, preferredEffort));
    }
    if (!defaultMarked && out[0]) {
      out[0].isDefault = true;
    }
    return out;
  }

  // 兜底：若某版 ACP 仅返回扁平 `models.availableModels`，原样导出。
  if (availableModels.length > 0) {
    const currentId = openResult.models?.currentModelId;
    let defaultMarked = false;
    const out = availableModels.map((entry) => {
      const isDefault = !defaultMarked && entry.modelId === currentId;
      if (isDefault) defaultMarked = true;
      return buildModel(entry.modelId, entry.name || entry.modelId, entry.description ?? "", isDefault, [], undefined);
    });
    if (!defaultMarked && out[0]) out[0].isDefault = true;
    return out;
  }

  return [];
}

export type DiscoverAgyModels = () => Promise<Model[]>;

export function acpModelDiscovery(
  agyExecutable: () => string,
  spawnTransport: SpawnAgyTransport,
  env: () => NodeJS.ProcessEnv = () => process.env,
): DiscoverAgyModels {
  return async () => {
    const client = await startAgyAcpClient(spawnTransport, {
      executable: agyExecutable(),
      cwd: os.tmpdir(),
      sandbox: true,
      env: env(),
    });
    try {
      const open = await client.sessionNew(os.tmpdir());
      await client.sessionClose(open.sessionId).catch(() => {});
      return catalogAgyModels(open);
    } finally {
      await client.close().catch(() => {});
    }
  };
}

export interface ModelCatalogOptions {
  discover: DiscoverAgyModels;
  ttlMs?: number;
  failureCooldownMs?: number;
  log?: (message: string) => void;
}

export class ModelCatalog {
  private cached: Model[] | undefined;
  private fetchedAt = 0;
  private failedAt = 0;
  private inflight: Promise<Model[]> | undefined;

  constructor(private readonly options: ModelCatalogOptions) {}

  /** 收到活跃会话的 `session/new` / `session/load` 结果时顺带刷新缓存，省去额外探测子进程。 */
  observeSessionOpen(openResult: AcpSessionOpenResult): void {
    const parsed = catalogAgyModels(openResult);
    if (parsed.length > 0) {
      this.cached = parsed;
      this.fetchedAt = Date.now();
      this.failedAt = 0;
    }
  }

  warm(): void {
    void this.list().catch((error) => {
      logger.debug("agy.models.warm_failed", { error: errorText(error) });
    });
  }

  async list(forceReload = false): Promise<Model[]> {
    const ttlMs = this.options.ttlMs ?? 300_000;
    const cooldownMs = this.options.failureCooldownMs ?? 15_000;
    const now = Date.now();
    if (!forceReload && this.cached && now - this.fetchedAt < ttlMs) {
      return this.cached;
    }
    if (this.inflight) return this.inflight;
    if (!forceReload && !this.cached && this.failedAt > 0 && now - this.failedAt < cooldownMs) {
      return [];
    }
    const run = this.options
      .discover()
      .then((models) => {
        if (models.length > 0) {
          this.cached = models;
          this.fetchedAt = Date.now();
          this.failedAt = 0;
        }
        return models.length > 0 ? models : (this.cached ?? []);
      })
      .catch((error) => {
        this.failedAt = Date.now();
        this.options.log?.(`agy model discovery failed: ${errorText(error)}`);
        if (this.cached) return this.cached;
        throw error;
      })
      .finally(() => {
        if (this.inflight === run) this.inflight = undefined;
      });
    this.inflight = run;
    return run;
  }
}
