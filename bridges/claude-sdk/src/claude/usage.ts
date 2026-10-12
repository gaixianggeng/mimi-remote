// account/rateLimits/read：已登录账号的套餐额度（5 小时 / 7 天窗口）。
//
// 这是继占用登记之后第二个非公开依赖：Claude Code 自己查询额度用的 OAuth usage 接口。SDK 的
// 额度接口仍标为实验性，且要另起一个 Claude 进程（可能顺带刷新 OAuth 令牌，与桌面端争抢
// 刷新）。这里沿用旧 bridge 0.2.8 起的约束：
// - 只读复用 Claude Code 的凭据（macOS 钥匙串，或权限为 600 的 ~/.claude/.credentials.json），
//   从不刷新、不写回；令牌只出现在请求头里，不进日志、参数或磁盘。
// - 只在客户端明确请求时查询，结果缓存 5 分钟；查不到时退回会话里观测到的 rate_limit_event。
import { execFile } from "node:child_process";
import { readFile, stat } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import type { RateLimitSnapshot } from "../protocol/codex/v2/RateLimitSnapshot.ts";
import type { RateLimitWindow } from "../protocol/codex/v2/RateLimitWindow.ts";

const execFileAsync = promisify(execFile);

const USAGE_ENDPOINT = "https://api.anthropic.com/api/oauth/usage";
const OAUTH_BETA = "oauth-2025-04-20";
const KEYCHAIN_SERVICE = "Claude Code-credentials";

export interface OAuthCredentials {
  accessToken: string;
  scopes: string[];
  expiresAt: number | null;
  subscriptionType: string | null;
}

export type UsageFailure =
  | "credentials_unavailable"
  | "missing_profile_scope"
  | "credentials_expired"
  | "credential_read_failed"
  | "query_failed"
  | "invalid_response"
  | `http_${number}`;

export class UsageError extends Error {
  constructor(readonly reason: UsageFailure) {
    super(reason);
  }
}

export function parseCredentials(raw: string): OAuthCredentials | undefined {
  let root: { claudeAiOauth?: Record<string, unknown> };
  try {
    root = JSON.parse(raw);
  } catch {
    throw new UsageError("credential_read_failed");
  }
  const payload = root?.claudeAiOauth;
  const accessToken = typeof payload?.accessToken === "string" ? payload.accessToken.trim() : "";
  if (!accessToken) return undefined;
  return {
    accessToken,
    scopes: Array.isArray(payload!.scopes) ? payload!.scopes.map(String) : [],
    expiresAt: typeof payload!.expiresAt === "number" ? payload!.expiresAt : null,
    subscriptionType: typeof payload!.subscriptionType === "string" ? payload!.subscriptionType : null,
  };
}

/** 令牌只放进 Authorization 头，必须是可打印 ASCII、不含引号和反斜杠。 */
function safeHeaderToken(token: string): boolean {
  return /^[\x21-\x7e]+$/.test(token) && !/["\\]/.test(token);
}

export function validateCredentials(credentials: OAuthCredentials, now = Date.now()): void {
  if (!credentials.scopes.includes("user:profile")) throw new UsageError("missing_profile_scope");
  if (credentials.expiresAt && credentials.expiresAt > 0 && credentials.expiresAt <= now + 30_000) {
    throw new UsageError("credentials_expired");
  }
  if (!safeHeaderToken(credentials.accessToken)) throw new UsageError("credential_read_failed");
}

export interface CredentialSources {
  file(): Promise<OAuthCredentials | undefined>;
  keychain(): Promise<OAuthCredentials | undefined>;
}

async function readCredentialsFile(): Promise<OAuthCredentials | undefined> {
  const file = path.join(os.homedir(), ".claude", ".credentials.json");
  let raw: string;
  try {
    raw = await readFile(file, "utf8");
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
    throw new UsageError("credential_read_failed");
  }
  // 凭据文件若对组或其他用户可读，宁可不用，也不扩大既有的安全问题。
  if (process.platform !== "win32" && ((await stat(file)).mode & 0o077) !== 0) throw new UsageError("credential_read_failed");
  return parseCredentials(raw);
}

async function readKeychainCredentials(): Promise<OAuthCredentials | undefined> {
  if (process.platform !== "darwin") return undefined;
  try {
    const { stdout } = await execFileAsync("/usr/bin/security", ["find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"], {
      timeout: 4_000,
    });
    return parseCredentials(stdout);
  } catch (error) {
    if (error instanceof UsageError) throw error;
    // 没有这一项（或用户拒绝访问）：当作没有凭据。
    return undefined;
  }
}

export const systemCredentialSources: CredentialSources = { file: readCredentialsFile, keychain: readKeychainCredentials };

interface UsageWindow {
  utilization?: unknown;
  resets_at?: unknown;
}

function usageWindow(raw: UsageWindow | null | undefined, durationMins: number): RateLimitWindow | null {
  // 没有使用率的窗口不展示：协议要求 usedPercent。
  if (!raw || typeof raw.utilization !== "number" || !Number.isFinite(raw.utilization)) return null;
  // usage 接口已经返回 0...100 的百分比；按 Claude Code /usage 的规则向下取整。
  const usedPercent = Math.floor(Math.min(100, Math.max(0, raw.utilization)) + 1e-9);
  const resetsAt = typeof raw.resets_at === "string" && !Number.isNaN(Date.parse(raw.resets_at)) ? Math.floor(Date.parse(raw.resets_at) / 1000) : null;
  return { usedPercent, windowDurationMins: durationMins, resetsAt };
}

export function snapshotFromUsage(body: Record<string, UsageWindow | null | undefined>, planType: string | null): RateLimitSnapshot {
  const primary = usageWindow(body.five_hour, 300);
  // 协议只有一个 secondary 槽位：优先账号总周窗口，模型专属周窗口只作降级。
  const secondary =
    usageWindow(body.seven_day, 10_080) ?? usageWindow(body.seven_day_sonnet, 10_080) ?? usageWindow(body.seven_day_opus, 10_080);
  if (!primary && !secondary) throw new UsageError("invalid_response");
  return {
    limitId: "claude",
    limitName: "Claude",
    normalModelSlug: null,
    primary,
    secondary,
    credits: null,
    individualLimit: null,
    spendControlReached: null,
    planType: planType as RateLimitSnapshot["planType"],
    rateLimitReachedType: null,
    availability: "available",
  } as RateLimitSnapshot;
}

export type FetchUsage = (accessToken: string) => Promise<{ status: number; body: unknown }>;

const systemFetchUsage: FetchUsage = async (accessToken) => {
  try {
    const response = await fetch(USAGE_ENDPOINT, {
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
        "anthropic-beta": OAUTH_BETA,
        "User-Agent": "claude-code/2.1.0",
        Authorization: `Bearer ${accessToken}`,
      },
      signal: AbortSignal.timeout(10_000),
    });
    return { status: response.status, body: response.ok ? await response.json() : undefined };
  } catch (error) {
    if (error instanceof SyntaxError) throw new UsageError("invalid_response");
    throw new UsageError("query_failed");
  }
};

function changed(previous: OAuthCredentials, latest: OAuthCredentials): boolean {
  return previous.accessToken !== latest.accessToken || (latest.expiresAt ?? 0) > (previous.expiresAt ?? 0);
}

function usable(credentials: OAuthCredentials): boolean {
  try {
    validateCredentials(credentials);
    return true;
  } catch {
    return false;
  }
}

/**
 * 查一次额度。401 时只读地重读一次凭据：macOS 上钥匙串才是 Claude Code 的事实来源，先看
 * 钥匙串，避免旧凭据文件遮住别的 Claude 进程刚完成的轮换；凭据没变就不重试。
 */
export async function fetchUsageSnapshot(
  sources: CredentialSources = systemCredentialSources,
  fetchUsage: FetchUsage = systemFetchUsage,
): Promise<RateLimitSnapshot> {
  let credentials = (await sources.file()) ?? (await sources.keychain());
  if (!credentials) throw new UsageError("credentials_unavailable");
  validateCredentials(credentials);
  let response = await fetchUsage(credentials.accessToken);
  if (response.status === 401) {
    const previous = credentials;
    const reloaded = [await sources.keychain(), await sources.file()].find(
      (latest): latest is OAuthCredentials => latest !== undefined && changed(previous, latest) && usable(latest),
    );
    if (!reloaded) throw new UsageError("http_401");
    credentials = reloaded;
    response = await fetchUsage(credentials.accessToken);
  }
  if (response.status !== 200) throw new UsageError(`http_${response.status}`);
  if (!response.body || typeof response.body !== "object") throw new UsageError("invalid_response");
  return snapshotFromUsage(response.body as Record<string, UsageWindow>, credentials.subscriptionType);
}

export interface RateLimitReaderOptions {
  fetch?: () => Promise<RateLimitSnapshot>;
  /** 会话里最近一次观测到的额度（rate_limit_event）。 */
  observed(): RateLimitSnapshot | undefined;
  cacheMs?: number;
  retryMs?: number;
  budgetMs?: number;
  log(message: string): void;
}

/** 都拿不到时的回答：可用性未知，不是零额度。字段与旧 bridge 相同。 */
function unavailableSnapshot(): RateLimitSnapshot {
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

/**
 * 设置页和菜单栏可能同时请求：缓存 5 分钟、并发共用一次查询、失败后 15 秒内不再查，整条
 * 查询最多占用 12 秒（超时按观测值回答）。
 */
export class RateLimitReader {
  private cached: { snapshot: RateLimitSnapshot; at: number } | undefined;
  private failedAt = 0;
  private inFlight: Promise<RateLimitSnapshot | undefined> | undefined;

  constructor(private readonly options: RateLimitReaderOptions) {}

  async read(): Promise<RateLimitSnapshot> {
    const now = Date.now();
    if (this.cached && now - this.cached.at < (this.options.cacheMs ?? 5 * 60_000)) return this.cached.snapshot;
    const fresh = await Promise.race([
      this.refresh(now),
      new Promise<undefined>((resolve) => setTimeout(resolve, this.options.budgetMs ?? 12_000).unref?.()),
    ]);
    return fresh ?? this.options.observed() ?? unavailableSnapshot();
  }

  private refresh(now: number): Promise<RateLimitSnapshot | undefined> {
    if (this.inFlight) return this.inFlight;
    if (now - this.failedAt < (this.options.retryMs ?? 15_000)) return Promise.resolve(undefined);
    this.inFlight = (this.options.fetch ?? (() => fetchUsageSnapshot()))()
      .then((snapshot) => {
        this.cached = { snapshot, at: Date.now() };
        return snapshot;
      })
      .catch((error) => {
        this.failedAt = Date.now();
        // 只记失败原因，不记凭据或响应内容。
        this.options.log(`Claude usage unavailable (${error instanceof UsageError ? error.reason : "error"}); using observed rate limits`);
        return undefined;
      })
      .finally(() => {
        this.inFlight = undefined;
      });
    return this.inFlight;
  }
}
