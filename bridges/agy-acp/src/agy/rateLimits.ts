import { execFile } from "node:child_process";
import os from "node:os";
import { promisify } from "node:util";
import type { RateLimitSnapshot } from "@mimi/appserver-kit/protocol/codex/v2/RateLimitSnapshot.ts";
import type { RateLimitWindow } from "@mimi/appserver-kit/protocol/codex/v2/RateLimitWindow.ts";
import { errorText, logger } from "../util/logging.ts";
import { resolveAgyDataPaths, sanitizeAgyEnv } from "./env.ts";

const execFileAsync = promisify(execFile);

const DEFAULT_USAGE_COMMAND_TIMEOUT_MS = 25_000;
const DEFAULT_USAGE_PRINT_TIMEOUT = "20s";
const DEFAULT_TTL_MS = 60_000;
const DEFAULT_FAILURE_COOLDOWN_MS = 15_000;

interface RawAgyUsageBucket {
  id?: unknown;
  name?: unknown;
  window?: unknown;
  remaining_fraction?: unknown;
  reset_time?: unknown;
}

interface RawAgyUsageGroup {
  name?: unknown;
  description?: unknown;
  buckets?: unknown;
}

interface ParsedBucket {
  id: string;
  window: RateLimitWindow;
  durationMinutes: number | null;
}

export type FetchAgyRateLimits = () => Promise<RateLimitSnapshot | null>;

export function unavailableAgyRateLimits(): RateLimitSnapshot {
  return {
    limitId: "agy",
    limitName: "Gemini",
    normalModelSlug: null,
    primary: null,
    secondary: null,
    credits: null,
    individualLimit: null,
    spendControlReached: null,
    planType: null,
    rateLimitReachedType: null,
    availability: "unavailable",
    unavailableReason: "headless_statusline_unavailable",
  } as RateLimitSnapshot;
}

export function agyUsageCommandArgs(baseEnv: NodeJS.ProcessEnv = process.env): string[] {
  const paths = resolveAgyDataPaths(baseEnv);
  const args: string[] = [];
  if (paths.geminiDirName !== ".gemini") {
    args.push("--gemini_dir", paths.geminiDirName);
  }
  if (paths.appDataDirName !== "antigravity-cli") {
    args.push("--app_data_dir", paths.appDataDirName);
  }
  args.push("--print", "/usage", "--output-format", "json", "--print-timeout", DEFAULT_USAGE_PRINT_TIMEOUT);
  return args;
}

function parseJsonObjectFromOutput(stdout: string): Record<string, unknown> | null {
  const trimmed = stdout.trim();
  if (!trimmed) return null;
  try {
    const parsed = JSON.parse(trimmed);
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
      return parsed as Record<string, unknown>;
    }
  } catch {
    // 某些环境可能在 JSON 前后附带日志行；回退按行逆序查找最后一个 JSON 对象。
  }
  const lines = trimmed.split(/\r?\n/);
  for (let i = lines.length - 1; i >= 0; i -= 1) {
    const line = lines[i]?.trim();
    if (!line || !line.startsWith("{")) continue;
    try {
      const parsed = JSON.parse(line);
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
        return parsed as Record<string, unknown>;
      }
    } catch {
      continue;
    }
  }
  return null;
}

function parseWindowDurationMins(bucket: RawAgyUsageBucket): number | null {
  const candidates = [bucket.window, bucket.id, bucket.name].filter((v): v is string => typeof v === "string");
  for (const raw of candidates) {
    const value = raw.trim().toLowerCase();
    if (!value) continue;
    if (value === "weekly" || /\b(weekly|7d|week)\b/.test(value)) return 7 * 24 * 60;
    if (value === "5h" || /\b5h\b/.test(value) || /five[\s_-]*hour/.test(value)) return 5 * 60;
    const dayMatch = /(?:^|[\s_-])(\d+)\s*d(?:ays?)?(?:$|[\s_-])/.exec(value);
    if (dayMatch) {
      const days = Number(dayMatch[1]);
      if (Number.isFinite(days) && days > 0) return days * 24 * 60;
    }
    const hourMatch = /(?:^|[\s_-])(\d+)\s*h(?:ours?)?(?:$|[\s_-])/.exec(value);
    if (hourMatch) {
      const hours = Number(hourMatch[1]);
      if (Number.isFinite(hours) && hours > 0) return hours * 60;
    }
    const minMatch = /(?:^|[\s_-])(\d+)\s*m(?:ins?|inutes?)?(?:$|[\s_-])/.exec(value);
    if (minMatch) {
      const mins = Number(minMatch[1]);
      if (Number.isFinite(mins) && mins > 0) return mins;
    }
  }
  return null;
}

function parseResetEpochSeconds(raw: unknown): number | null {
  if (typeof raw === "number" && Number.isFinite(raw) && raw > 0) {
    return raw > 1e12 ? Math.floor(raw / 1000) : Math.floor(raw);
  }
  if (typeof raw !== "string" || !raw.trim()) return null;
  const ms = Date.parse(raw.trim());
  if (!Number.isFinite(ms) || ms <= 0) return null;
  return Math.floor(ms / 1000);
}

function parseBucket(raw: unknown): ParsedBucket | null {
  if (!raw || typeof raw !== "object") return null;
  const bucket = raw as RawAgyUsageBucket;
  if (typeof bucket.remaining_fraction !== "number" || !Number.isFinite(bucket.remaining_fraction)) {
    return null;
  }
  const clamped = Math.min(1, Math.max(0, bucket.remaining_fraction));
  // 保持与 `agy /usage` 文本输出一致的四舍五入剩余百分比；
  // 仅当 remaining_fraction 真正归零时才标记 100% 耗尽，避免极小余量被误判成已用尽。
  const usedPercent = clamped <= 0 ? 100 : Math.min(99, Math.max(0, 100 - Math.round(clamped * 100)));
  const durationMinutes = parseWindowDurationMins(bucket);
  return {
    id: typeof bucket.id === "string" ? bucket.id : "",
    durationMinutes,
    window: {
      usedPercent,
      windowDurationMins: durationMinutes,
      resetsAt: parseResetEpochSeconds(bucket.reset_time),
    },
  };
}

function extractGroups(payload: Record<string, unknown>): RawAgyUsageGroup[] {
  const command = payload.command;
  if (command && typeof command === "object") {
    const data = (command as Record<string, unknown>).data;
    if (data && typeof data === "object" && Array.isArray((data as Record<string, unknown>).groups)) {
      return (data as Record<string, unknown>).groups as RawAgyUsageGroup[];
    }
  }
  if (Array.isArray(payload.groups)) {
    return payload.groups as RawAgyUsageGroup[];
  }
  return [];
}

function isGeminiGroup(group: RawAgyUsageGroup): boolean {
  if (typeof group.name === "string" && /gemini/i.test(group.name)) {
    return true;
  }
  if (Array.isArray(group.buckets)) {
    return group.buckets.some(
      (entry) => entry && typeof entry === "object" && typeof (entry as RawAgyUsageBucket).id === "string" && /^gemini\b/i.test((entry as RawAgyUsageBucket).id as string),
    );
  }
  return false;
}

export function parseAgyUsageOutput(stdout: string, planType?: string | null): RateLimitSnapshot | null {
  const payload = parseJsonObjectFromOutput(stdout);
  if (!payload) return null;
  if (typeof payload.status === "string" && payload.status.toUpperCase() !== "SUCCESS") {
    return null;
  }
  const groups = extractGroups(payload);
  if (groups.length === 0) return null;

  const preferredGroup = groups.find(isGeminiGroup) ?? groups[0];
  if (!preferredGroup || !Array.isArray(preferredGroup.buckets)) return null;

  const parsed = preferredGroup.buckets.map(parseBucket).filter((entry): entry is ParsedBucket => entry !== null);
  if (parsed.length === 0) return null;

  // 短窗口放 primary（如 5h），日级/周级长窗口放 secondary（如 7d），与 Codex / Claude 槽位习惯一致。
  const sorted = [...parsed].sort((a, b) => (a.durationMinutes ?? Number.MAX_SAFE_INTEGER) - (b.durationMinutes ?? Number.MAX_SAFE_INTEGER));
  let primary: RateLimitWindow | null = null;
  let secondary: RateLimitWindow | null = null;

  const shortCandidate = sorted.find((entry) => entry.durationMinutes !== null && entry.durationMinutes < 24 * 60);
  const longCandidate = [...sorted].reverse().find((entry) => entry.durationMinutes !== null && entry.durationMinutes >= 24 * 60);

  if (shortCandidate || longCandidate) {
    primary = shortCandidate?.window ?? null;
    secondary = longCandidate?.window ?? null;
    if (!primary && sorted.length >= 2) {
      primary = sorted.find((entry) => entry.window !== secondary)?.window ?? null;
    } else if (!secondary && sorted.length >= 2) {
      secondary = [...sorted].reverse().find((entry) => entry.window !== primary)?.window ?? null;
    }
  } else {
    primary = sorted[0]?.window ?? null;
    secondary = sorted[1]?.window ?? null;
  }

  if (!primary && !secondary) return null;

  const primaryExhausted = (primary?.usedPercent ?? 0) >= 100;
  const secondaryExhausted = (secondary?.usedPercent ?? 0) >= 100;
  const rateLimitReachedType =
    primaryExhausted && secondaryExhausted
      ? "rejected"
      : primaryExhausted
        ? "primary"
        : secondaryExhausted
          ? "secondary"
          : null;

  return {
    limitId: "agy",
    limitName: "Gemini",
    normalModelSlug: null,
    primary,
    secondary,
    credits: null,
    individualLimit: null,
    spendControlReached: null,
    planType: planType?.trim() || null,
    rateLimitReachedType,
    availability: "available",
  } as RateLimitSnapshot;
}

export function createCliRateLimitsFetcher(
  executable: () => string,
  env: () => NodeJS.ProcessEnv = () => process.env,
  timeoutMs: number = DEFAULT_USAGE_COMMAND_TIMEOUT_MS,
): FetchAgyRateLimits {
  return async () => {
    const baseEnv = env();
    const { stdout } = await execFileAsync(executable(), agyUsageCommandArgs(baseEnv), {
      cwd: os.tmpdir(),
      env: sanitizeAgyEnv(baseEnv),
      timeout: timeoutMs,
      maxBuffer: 1024 * 1024,
    });
    return parseAgyUsageOutput(stdout);
  };
}

export interface AgyRateLimitCatalogOptions {
  fetch: FetchAgyRateLimits;
  ttlMs?: number;
  failureCooldownMs?: number;
  now?: () => number;
  log?: (message: string) => void;
  onUpdated?: (snapshot: RateLimitSnapshot) => void;
}

export class AgyRateLimitCatalog {
  private cached: RateLimitSnapshot | undefined;
  private observedPlanType: string | undefined;
  private fetchedAt = 0;
  private failedAt = 0;
  private backgroundRefreshEnabled = false;
  private inflight: Promise<RateLimitSnapshot> | undefined;

  constructor(private readonly options: AgyRateLimitCatalogOptions) {}

  observePlanType(tierName: string | undefined): void {
    const trimmed = tierName?.trim();
    if (!trimmed) return;
    this.observedPlanType = trimmed;
    if (this.cached && !this.cached.planType) {
      this.cached = this.withPlanType(this.cached);
    }
  }

  warm(): void {
    this.backgroundRefreshEnabled = true;
    void this.read().catch((error) => {
      logger.debug("agy.rateLimits.warm_failed", { error: errorText(error) });
    });
  }

  /** 回合完成后标记当前额度已过期；常驻服务开启预热时顺带异步刷新，不阻塞回合收尾。 */
  invalidateAfterTurn(): void {
    this.fetchedAt = 0;
    if (!this.backgroundRefreshEnabled) return;
    void this.read().catch((error) => {
      logger.debug("agy.rateLimits.refresh_failed", { error: errorText(error) });
    });
  }

  async read(forceReload = false): Promise<RateLimitSnapshot> {
    const now = this.options.now ?? Date.now;
    const ttlMs = this.options.ttlMs ?? DEFAULT_TTL_MS;
    const cooldownMs = this.options.failureCooldownMs ?? DEFAULT_FAILURE_COOLDOWN_MS;
    const currentTime = now();

    if (!forceReload && this.cached && this.fetchedAt > 0 && currentTime - this.fetchedAt < ttlMs) {
      return this.withPlanType(this.cached);
    }
    if (this.inflight) {
      return this.inflight;
    }
    if (!forceReload && !this.cached && this.failedAt > 0 && currentTime - this.failedAt < cooldownMs) {
      return unavailableAgyRateLimits();
    }

    const previousKey = this.cached ? JSON.stringify(this.cached) : undefined;
    const run = this.options
      .fetch()
      .then((fetched) => {
        const ts = now();
        if (fetched) {
          const enriched = this.withPlanType(fetched);
          this.cached = enriched;
          this.fetchedAt = ts;
          this.failedAt = 0;
          if (JSON.stringify(enriched) !== previousKey) {
            this.options.onUpdated?.(enriched);
          }
          return enriched;
        }
        this.failedAt = ts;
        return this.cached ? this.withPlanType(this.cached) : unavailableAgyRateLimits();
      })
      .catch((error) => {
        this.failedAt = now();
        logger.debug("agy.rateLimits.failed", { error: errorText(error) });
        this.options.log?.(`agy rate limits fetch failed: ${errorText(error)}`);
        return this.cached ? this.withPlanType(this.cached) : unavailableAgyRateLimits();
      })
      .finally(() => {
        if (this.inflight === run) this.inflight = undefined;
      });

    this.inflight = run;
    return run;
  }

  private withPlanType(snapshot: RateLimitSnapshot): RateLimitSnapshot {
    if (!this.observedPlanType || snapshot.planType) return snapshot;
    return { ...snapshot, planType: this.observedPlanType as RateLimitSnapshot["planType"] };
  }
}
