// Claude 的 rate_limit_event → app-server 的额度快照。Claude 直接给出 5 小时与 7 天窗口的
// 使用率，比旧 bridge 只能报"可用性"更完整。
import type { RateLimitSnapshot } from "../protocol/codex/v2/RateLimitSnapshot.ts";
import type { RateLimitWindow } from "../protocol/codex/v2/RateLimitWindow.ts";

const WINDOW_MINUTES: Record<string, number> = { five_hour: 300, seven_day: 10_080 };

function windowOf(name: string, raw: unknown): RateLimitWindow | null {
  if (!raw || typeof raw !== "object") return null;
  const entry = raw as Record<string, unknown>;
  const utilization = typeof entry.utilization === "number" ? entry.utilization : undefined;
  if (utilization === undefined) return null;
  return {
    usedPercent: Math.round(utilization * 1000) / 10,
    windowDurationMins: WINDOW_MINUTES[name] ?? null,
    resetsAt: typeof entry.resetsAt === "number" ? entry.resetsAt : null,
  };
}

export function rateLimitSnapshot(info: unknown): RateLimitSnapshot | undefined {
  if (!info || typeof info !== "object") return undefined;
  const windows = ((info as Record<string, unknown>).unifiedWindows ?? {}) as Record<string, unknown>;
  const primary = windowOf("five_hour", windows.five_hour);
  const secondary = windowOf("seven_day", windows.seven_day);
  if (!primary && !secondary) return undefined;
  return {
    limitId: "claude",
    limitName: "Claude",
    normalModelSlug: null,
    primary,
    secondary,
    credits: null,
    individualLimit: null,
    spendControlReached: null,
    planType: null,
  } as RateLimitSnapshot;
}
