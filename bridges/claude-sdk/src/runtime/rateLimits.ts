// Claude 的 rate_limit_event → app-server 的额度快照。语义与旧 bridge 一致：
// - 实测事件除了文档里的单窗口字段（rateLimitType / utilization / resetsAt），还带
//   `unifiedWindows`（5 小时与 7 天窗口的使用率）。优先用它，缺失时退回单窗口字段。
// - utilization 是 0...1 的比例，按 Claude Code `/usage` 的规则换成向下取整的百分比。
// - 观测值只是部分信息（availability: partial）；只有 Claude 明确拒绝请求时才标记额度耗尽，
//   allowed_warning 只是接近阈值。
// - 额度只来自 Claude Code 在会话里自己上报的事件：不读取 Claude 的登录凭据，也不另外查询
//   额度接口（#660）。适配器启动后、还没跑过回合时没有数据。
import type { RateLimitSnapshot } from "../protocol/codex/v2/RateLimitSnapshot.ts";
import type { RateLimitWindow } from "../protocol/codex/v2/RateLimitWindow.ts";

const WINDOW_MINUTES: Record<string, number> = {
  five_hour: 300,
  seven_day: 10_080,
  seven_day_sonnet: 10_080,
  seven_day_opus: 10_080,
};
const WEEKLY = ["seven_day", "seven_day_sonnet", "seven_day_opus"];

function windowOf(name: string, raw: unknown): RateLimitWindow | null {
  if (!raw || typeof raw !== "object") return null;
  const entry = raw as Record<string, unknown>;
  // 没有使用率的窗口不展示：协议要求 usedPercent。
  if (typeof entry.utilization !== "number" || !Number.isFinite(entry.utilization)) return null;
  return {
    // 0.57 * 100 在浮点下可能是 56.999…，加极小容差再取整，避免少显示 1%。
    usedPercent: Math.floor(Math.min(1, Math.max(0, entry.utilization)) * 100 + 1e-9),
    windowDurationMins: WINDOW_MINUTES[name] ?? null,
    resetsAt: typeof entry.resetsAt === "number" ? entry.resetsAt : null,
  };
}

/**
 * 合并先后观测到的额度：单窗口形式的事件每次只带一个窗口，后一个不能把前一个已知的窗口
 * 覆盖成空。每个窗口保留最近一次的值，额度耗尽状态以最新事件为准。
 */
export function mergeObservedRateLimits(previous: RateLimitSnapshot | undefined, next: RateLimitSnapshot): RateLimitSnapshot {
  if (!previous) return next;
  const primary = next.primary ?? previous.primary;
  const secondary = next.secondary ?? previous.secondary;
  const { unavailableReason: _, ...rest } = next as RateLimitSnapshot & { unavailableReason?: string };
  return {
    ...rest,
    primary,
    secondary,
    ...(primary || secondary ? {} : { unavailableReason: "usage_percentage_unavailable" }),
  } as RateLimitSnapshot;
}

export function rateLimitSnapshot(info: unknown): RateLimitSnapshot | undefined {
  if (!info || typeof info !== "object") return undefined;
  const record = info as Record<string, unknown>;
  const windows: Record<string, unknown> = { ...((record.unifiedWindows ?? {}) as Record<string, unknown>) };
  if (typeof record.rateLimitType === "string" && !(record.rateLimitType in windows)) {
    windows[record.rateLimitType] = { utilization: record.utilization, resetsAt: record.resetsAt };
  }
  const primary = windowOf("five_hour", windows.five_hour);
  // 协议只有一个 secondary 槽位：优先账号总周窗口，模型专属周窗口只作降级。
  const secondary = WEEKLY.map((name) => windowOf(name, windows[name])).find((window) => window !== null) ?? null;
  const rejected = record.status === "rejected";
  if (!primary && !secondary && !rejected) return undefined;
  const hasPercent = primary !== null || secondary !== null;
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
    rateLimitReachedType: rejected ? "rejected" : null,
    availability: "partial",
    ...(hasPercent ? {} : { unavailableReason: "usage_percentage_unavailable" }),
  } as RateLimitSnapshot;
}

/** 还没观测到额度时的回答：可用性未知，不是零额度。字段与旧 bridge 相同。 */
export function unavailableRateLimits(): RateLimitSnapshot {
  return {
    limitId: "claude",
    limitName: "Claude",
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
