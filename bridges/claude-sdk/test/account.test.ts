// model/list 的目录整理与缓存、account/rateLimits/read 的凭据读取、401 重读、缓存与降级，
// 以及 rate_limit_event 的映射。目录样例按 Claude Code 2.1.294 实测的 initialize 结构编写。
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import type { ModelInfo } from "@anthropic-ai/claude-agent-sdk";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import type { App } from "../src/app.ts";
import { catalogModels, fallbackModels, ModelCatalog, modelVersionTitle } from "../src/claude/models.ts";
import {
  fetchUsageSnapshot,
  parseCredentials,
  RateLimitReader,
  snapshotFromUsage,
  UsageError,
  validateCredentials,
  type CredentialSources,
  type OAuthCredentials,
} from "../src/claude/usage.ts";
import type { RateLimitSnapshot } from "../src/protocol/codex/v2/RateLimitSnapshot.ts";
import { rateLimitSnapshot } from "../src/runtime/rateLimits.ts";
import { Session } from "../src/session/session.ts";

const efforts = ["low", "medium", "high", "xhigh", "max"] as ModelInfo["supportedEffortLevels"];
const info = (value: string, resolvedModel: string, displayName: string, extra: Partial<ModelInfo> = {}): ModelInfo => ({
  value,
  resolvedModel,
  displayName,
  description: `${displayName} description`,
  supportsEffort: true,
  supportedEffortLevels: efforts,
  ...extra,
});

const CATALOG: ModelInfo[] = [
  info("default", "claude-opus-5-5", "Default (recommended)"),
  info("opus", "claude-opus-5-5", "Opus 5.5"),
  info("fable", "claude-fable-5-1", "Fable 5.1"),
  info("sonnet", "claude-sonnet-5-5", "Sonnet 5.5"),
  info("haiku", "claude-haiku-5-5", "Haiku 5.5"),
  info("claude-haiku-4-5-20251001", "claude-haiku-4-5-20251001", "Haiku 4.5", { supportsEffort: undefined, supportedEffortLevels: undefined }),
  info("claude-opus-5", "claude-opus-5", "Opus 5"),
  info("claude-fable-5", "claude-fable-5", "Fable 5"),
  info("claude-opus-4-6", "claude-opus-4-6", "Opus 4.6", { supportedEffortLevels: ["low", "medium", "high", "max"] }),
  info("opus[1m]", "claude-opus-5-5[1m]", "Opus 5.5 (1M)"),
  info("acme-large", "acme-large", "Acme Large", { supportsEffort: false }),
];

describe("model catalog", () => {
  test("one visible row per family, strongest first, default on the model the alias resolves to", () => {
    const models = catalogModels(CATALOG);
    const visible = models.filter((model) => !model.hidden);
    // 同版本优先 1M 上下文：opus[1m] 占了 Opus 家族的主行。默认解析出的 claude-opus-5-5 不在任何
    // 可见行上，于是保留 default 别名行作为默认项，排在最前。
    expect(visible.map((model) => [model.id, model.displayName, model.isDefault])).toEqual([
      ["default", "Default (recommended)", true],
      ["fable", "Claude Fable 5.1", false],
      ["opus[1m]", "Claude Opus 5.5 (1M)", false],
      ["sonnet", "Claude Sonnet 5.5", false],
      ["haiku", "Claude Haiku 5.5", false],
      ["acme-large", "Acme Large", false],
    ]);
    expect(models.find((model) => model.id === "opus")).toMatchObject({ hidden: true, isDefault: false });
    expect(models.filter((model) => model.isDefault)).toHaveLength(1);
  });

  test("the default marker lands on the visible row when the alias resolves to it", () => {
    const models = catalogModels(CATALOG.filter((entry) => entry.value !== "opus[1m]"));
    expect(models.find((model) => model.isDefault)).toMatchObject({ id: "opus", hidden: false, displayName: "Claude Opus 5.5" });
    expect(models.some((model) => model.id === "default")).toBe(false);
    expect(models.find((model) => model.id === "claude-opus-4-6")).toMatchObject({ hidden: true });
  });

  test("efforts come from the CLI; models without effort support offer none", () => {
    const models = catalogModels(CATALOG);
    expect(models.find((model) => model.id === "sonnet")!.supportedReasoningEfforts.map((entry) => entry.reasoningEffort)).toEqual([
      "low",
      "medium",
      "high",
      "xhigh",
      "max",
    ]);
    expect(models.find((model) => model.id === "sonnet")!.defaultReasoningEffort).toBe("high");
    expect(models.find((model) => model.id === "acme-large")!.supportedReasoningEfforts).toEqual([]);
    expect(models.find((model) => model.id === "claude-haiku-4-5-20251001")!.supportedReasoningEfforts).toEqual([]);
  });

  test("version titles follow the CLI ids, dates and context markers", () => {
    expect(modelVersionTitle("claude-fable-9-2")).toBe("Claude Fable 9.2");
    expect(modelVersionTitle("claude-haiku-4-5-20251001")).toBe("Claude Haiku 4.5");
    expect(modelVersionTitle("claude-opus-5-5[1m]")).toBe("Claude Opus 5.5 (1M)");
    expect(modelVersionTitle("acme-large")).toBeUndefined();
    expect(modelVersionTitle("claude-5")).toBeUndefined();
  });

  test("the catalog is cached, shared by concurrent requests and falls back to aliases on failure", async () => {
    let calls = 0;
    let fail = false;
    const catalog = new ModelCatalog({
      discover: async () => {
        calls += 1;
        await Bun.sleep(10);
        if (fail) throw new Error("boom");
        return CATALOG;
      },
      ttlMs: 50,
      failureCooldownMs: 1_000,
      log: () => {},
    });
    const [first, second] = await Promise.all([catalog.list(), catalog.list()]);
    expect(calls).toBe(1);
    expect(first).toEqual(second);
    await catalog.list();
    expect(calls).toBe(1);
    await Bun.sleep(60);
    fail = true;
    // 过期后刷新失败：继续用上一次的目录。
    expect((await catalog.list()).map((model) => model.id)).toEqual(first.map((model) => model.id));
    expect(calls).toBe(2);
    // 冷却期内不再冷启动 CLI。
    await catalog.list();
    expect(calls).toBe(2);

    const empty = new ModelCatalog({ discover: async () => [], log: () => {} });
    expect((await empty.list()).map((model) => [model.id, model.isDefault])).toEqual(fallbackModels().map((model) => [model.id, model.isDefault]));
  });
});

const credentials = (overrides: Partial<OAuthCredentials> = {}): OAuthCredentials => ({
  accessToken: "token-a",
  scopes: ["user:inference", "user:profile"],
  expiresAt: Date.now() + 3_600_000,
  subscriptionType: "max",
  ...overrides,
});

const usageBody = { five_hour: { utilization: 5.9, resets_at: "2026-10-12T04:40:00Z" }, seven_day: { utilization: 11, resets_at: null } };

describe("OAuth usage", () => {
  test("credentials parse without the refresh token and must be usable before any request", () => {
    const parsed = parseCredentials(JSON.stringify({ claudeAiOauth: { accessToken: " tok ", refreshToken: "secret", scopes: ["user:profile"], expiresAt: 1 } }));
    expect(parsed).toEqual({ accessToken: "tok", scopes: ["user:profile"], expiresAt: 1, subscriptionType: null });
    expect(parseCredentials(JSON.stringify({ other: {} }))).toBeUndefined();
    expect(() => parseCredentials("{")).toThrow(UsageError);
    expect(() => validateCredentials(credentials({ scopes: ["user:inference"] }))).toThrow("missing_profile_scope");
    expect(() => validateCredentials(credentials({ expiresAt: Date.now() + 10_000 }))).toThrow("credentials_expired");
    expect(() => validateCredentials(credentials({ accessToken: 'bad"token' }))).toThrow("credential_read_failed");
  });

  test("percentages are floored like /usage and the weekly slot falls back to model windows", () => {
    const snapshot = snapshotFromUsage(usageBody, "max") as RateLimitSnapshot & { availability?: string };
    expect(snapshot.primary).toEqual({ usedPercent: 5, windowDurationMins: 300, resetsAt: Date.parse("2026-10-12T04:40:00Z") / 1000 });
    expect(snapshot.secondary).toMatchObject({ usedPercent: 11, windowDurationMins: 10_080, resetsAt: null });
    expect(snapshot).toMatchObject({ planType: "max", availability: "available" });
    expect(snapshotFromUsage({ seven_day_opus: { utilization: 40 } }, null).secondary?.usedPercent).toBe(40);
    expect(() => snapshotFromUsage({}, null)).toThrow("invalid_response");
  });

  test("a 401 re-reads the keychain once and retries only with changed credentials", async () => {
    let keychain: OAuthCredentials | undefined = credentials({ accessToken: "token-b" });
    const sources: CredentialSources = { file: async () => credentials(), keychain: async () => keychain };
    const tokens: string[] = [];
    const fetchUsage = async (token: string) => {
      tokens.push(token);
      return token === "token-b" ? { status: 200, body: usageBody } : { status: 401, body: undefined };
    };
    expect((await fetchUsageSnapshot(sources, fetchUsage)).primary?.usedPercent).toBe(5);
    expect(tokens).toEqual(["token-a", "token-b"]);

    keychain = credentials();
    tokens.length = 0;
    const error = await fetchUsageSnapshot(sources, fetchUsage).catch((caught) => caught);
    expect(error).toMatchObject({ reason: "http_401" });
    expect(tokens).toEqual(["token-a"]);

    const none: CredentialSources = { file: async () => undefined, keychain: async () => undefined };
    expect(await fetchUsageSnapshot(none, fetchUsage).catch((caught) => caught.reason)).toBe("credentials_unavailable");
  });

  test("the reader caches, backs off after failures and falls back to observed limits", async () => {
    let calls = 0;
    let fail = false;
    let observed: RateLimitSnapshot | undefined;
    const reader = new RateLimitReader({
      fetch: async () => {
        calls += 1;
        if (fail) throw new UsageError("query_failed");
        return snapshotFromUsage(usageBody, "max");
      },
      observed: () => observed,
      cacheMs: 50,
      retryMs: 1_000,
      log: () => {},
    });
    expect((await reader.read()).primary?.usedPercent).toBe(5);
    await reader.read();
    expect(calls).toBe(1);
    await Bun.sleep(60);
    fail = true;
    // 查询失败且没有观测值：可用性未知，不是零额度。
    expect(await reader.read()).toMatchObject({ primary: null, availability: "unavailable", unavailableReason: "headless_statusline_unavailable" });
    observed = rateLimitSnapshot({ status: "allowed", unifiedWindows: { five_hour: { utilization: 0.33, resetsAt: 1 } } });
    expect((await reader.read()).primary?.usedPercent).toBe(33);
    // 失败冷却期内不再发请求。
    expect(calls).toBe(2);
  });

  test("a slow usage query is bounded by the budget", async () => {
    const reader = new RateLimitReader({
      fetch: () => new Promise(() => {}),
      observed: () => undefined,
      budgetMs: 20,
      log: () => {},
    });
    const started = Date.now();
    expect(await reader.read()).toMatchObject({ availability: "unavailable" });
    expect(Date.now() - started).toBeLessThan(1_000);
  });
});

describe("rate_limit_event", () => {
  test("unified windows map to floored percentages; a rejection marks the limit as reached", () => {
    const snapshot = rateLimitSnapshot({
      status: "rejected",
      rateLimitType: "five_hour",
      unifiedWindows: { five_hour: { utilization: 0.57, resetsAt: 100 }, seven_day: { utilization: 0.1, resetsAt: 200 } },
    }) as RateLimitSnapshot & { availability?: string };
    expect(snapshot.primary).toEqual({ usedPercent: 57, windowDurationMins: 300, resetsAt: 100 });
    expect(snapshot.secondary).toEqual({ usedPercent: 10, windowDurationMins: 10_080, resetsAt: 200 });
    expect(snapshot).toMatchObject({ rateLimitReachedType: "rejected", availability: "partial" });
  });

  test("without unified windows the documented single-window fields are used", () => {
    const snapshot = rateLimitSnapshot({ status: "allowed_warning", rateLimitType: "seven_day_sonnet", utilization: 0.81, resetsAt: 5 });
    expect(snapshot?.secondary).toEqual({ usedPercent: 81, windowDurationMins: 10_080, resetsAt: 5 });
    expect(snapshot?.rateLimitReachedType).toBeNull();
    expect(rateLimitSnapshot({ status: "allowed", rateLimitType: "five_hour", resetsAt: 5 })).toBeUndefined();
  });
});

describe("handlers", () => {
  const sandbox = realpathSync(mkdtempSync(path.join(os.tmpdir(), "mimi-adapter-account-")));
  let app: App;

  beforeAll(async () => {
    process.env.CLAUDE_CONFIG_DIR = path.join(sandbox, "claude");
    process.env.MIMI_CLAUDE_LEGACY_INDEX = "";
    const { createApp } = await import("../src/app.ts");
    app = createApp({
      stateDir: path.join(sandbox, "state"),
      log: () => {},
      claudeExecutable: () => "unused",
      discoverModels: async () => CATALOG,
      fetchUsage: async () => {
        throw new UsageError("credentials_unavailable");
      },
    });
  });

  afterAll(async () => {
    await app.manager.closeAll();
    delete process.env.CLAUDE_CONFIG_DIR;
    rmSync(sandbox, { recursive: true, force: true });
  });

  async function call(method: string, params: unknown = {}): Promise<any> {
    const session = new Session("account");
    const { generation } = session.attach(undefined, () => {}, false);
    const response = await app.router.dispatch({ id: 1, method, params }, { session, generation });
    if ("error" in response) throw new Error(JSON.stringify(response.error));
    return response.result;
  }

  test("model/list returns the organized catalog", async () => {
    const result = await call("model/list");
    expect(result.nextCursor).toBeNull();
    expect(result.data.filter((model: any) => !model.hidden).map((model: any) => model.id)).toEqual([
      "default",
      "fable",
      "opus[1m]",
      "sonnet",
      "haiku",
      "acme-large",
    ]);
  });

  test("account/rateLimits/read falls back to the last limits observed in a session", async () => {
    expect((await call("account/rateLimits/read")).rateLimits).toMatchObject({ availability: "unavailable" });
    const observed = rateLimitSnapshot({ status: "allowed", unifiedWindows: { seven_day: { utilization: 0.2, resetsAt: 9 } } })!;
    app.manager.publish("any-thread", "account/rateLimits/updated", { rateLimits: observed });
    const result = await call("account/rateLimits/read");
    expect(result.rateLimits.secondary).toEqual({ usedPercent: 20, windowDurationMins: 10_080, resetsAt: 9 });
    expect(result.rateLimitsByLimitId).toBeNull();
  });
});
