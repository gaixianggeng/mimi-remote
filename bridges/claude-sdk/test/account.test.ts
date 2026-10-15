// model/list 的目录整理与缓存、rate_limit_event 的映射，以及 account/rateLimits/read 只回答会话里
// 观测到的额度。目录样例按 Claude Code 2.1.294 实测的 initialize 结构编写。
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import type { ModelInfo } from "@anthropic-ai/claude-agent-sdk";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import type { App } from "../src/app.ts";
import { catalogModels, fallbackModels, ModelCatalog, modelVersionTitle } from "../src/claude/models.ts";
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

    // 预热的长查询还没完成时，前台请求按自己的时限先用别名回答，查询完成后再用目录。
    let release!: (models: ModelInfo[]) => void;
    const slow = new ModelCatalog({ discover: () => new Promise<ModelInfo[]>((resolve) => (release = resolve)), log: () => {} });
    slow.warm();
    const started = Date.now();
    expect((await slow.list(30)).map((model) => model.id)).toEqual(fallbackModels().map((model) => model.id));
    expect(Date.now() - started).toBeLessThan(1_000);
    release(CATALOG);
    await Bun.sleep(5);
    expect((await slow.list(30)).some((model) => model.id === "fable")).toBe(true);

    const empty = new ModelCatalog({ discover: async () => [], log: () => {} });
    expect((await empty.list()).map((model) => [model.id, model.isDefault])).toEqual(fallbackModels().map((model) => [model.id, model.isDefault]));
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

  test("single-window observations are merged instead of replacing each other", async () => {
    app.manager.publish("t", "account/rateLimits/updated", {
      rateLimits: rateLimitSnapshot({ status: "allowed", rateLimitType: "five_hour", utilization: 0.3, resetsAt: 1 })!,
    });
    app.manager.publish("t", "account/rateLimits/updated", {
      rateLimits: rateLimitSnapshot({ status: "allowed", rateLimitType: "seven_day", utilization: 0.6, resetsAt: 2 })!,
    });
    const merged = app.manager.observedRateLimits!;
    expect(merged.primary).toEqual({ usedPercent: 30, windowDurationMins: 300, resetsAt: 1 });
    expect(merged.secondary).toEqual({ usedPercent: 60, windowDurationMins: 10_080, resetsAt: 2 });
    expect((merged as any).unavailableReason).toBeUndefined();
  });

  test("account/rateLimits/read answers only with limits observed in a session", async () => {
    (app.manager as any).lastRateLimits = undefined;
    expect((await call("account/rateLimits/read")).rateLimits).toMatchObject({ availability: "unavailable" });
    const observed = rateLimitSnapshot({ status: "allowed", unifiedWindows: { seven_day: { utilization: 0.2, resetsAt: 9 } } })!;
    app.manager.publish("any-thread", "account/rateLimits/updated", { rateLimits: observed });
    const result = await call("account/rateLimits/read");
    expect(result.rateLimits.secondary).toEqual({ usedPercent: 20, windowDurationMins: 10_080, resetsAt: 9 });
    expect(result.rateLimitsByLimitId).toBeNull();
  });
});
