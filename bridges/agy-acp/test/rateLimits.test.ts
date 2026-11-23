import { describe, expect, test } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { createApp } from "../src/app.ts";
import { AgyRateLimitCatalog, agyUsageCommandArgs, parseAgyUsageOutput } from "../src/agy/rateLimits.ts";

const SAMPLE_USAGE_JSON = JSON.stringify({
  conversation_id: "",
  status: "SUCCESS",
  duration_seconds: 0,
  num_turns: 0,
  usage: { input_tokens: 0, output_tokens: 0, thinking_tokens: 0, cache_read_tokens: 0, total_tokens: 0 },
  command: {
    name: "usage",
    data: {
      groups: [
        {
          name: "Gemini Models",
          buckets: [
            {
              id: "gemini-weekly",
              name: "Weekly Limit Remaining",
              window: "weekly",
              remaining_fraction: 0.7102206945419312,
              reset_time: "2026-11-28T08:53:44Z",
            },
            {
              id: "gemini-5h",
              name: "Five Hour Limit Remaining",
              window: "5h",
              remaining_fraction: 0.9764081835746765,
              reset_time: "2026-11-23T19:23:13Z",
            },
          ],
        },
        {
          name: "Claude and GPT models",
          buckets: [
            {
              id: "3p-weekly",
              name: "Weekly Limit Remaining",
              window: "weekly",
              remaining_fraction: 0.49824976921081543,
              reset_time: "2026-11-25T15:11:12Z",
            },
            {
              id: "3p-5h",
              name: "Five Hour Limit Remaining",
              window: "5h",
              remaining_fraction: 1,
              reset_time: "2026-11-23T21:29:01Z",
            },
          ],
        },
      ],
    },
  },
});

describe("agy rateLimits parsing", () => {
  test("extracts Gemini Models 5h primary and weekly secondary windows", () => {
    const snapshot = parseAgyUsageOutput(SAMPLE_USAGE_JSON, "Google AI Ultra");
    expect(snapshot).not.toBeNull();
    expect(snapshot?.limitId).toBe("agy");
    expect(snapshot?.limitName).toBe("Gemini");
    expect(String(snapshot?.planType)).toBe("Google AI Ultra");
    expect((snapshot as Record<string, unknown>)?.availability).toBe("available");
    expect(snapshot?.rateLimitReachedType).toBeNull();
    expect(snapshot?.primary).toEqual({
      usedPercent: 2,
      windowDurationMins: 300,
      resetsAt: Math.floor(Date.parse("2026-11-23T19:23:13Z") / 1000),
    });
    expect(snapshot?.secondary).toEqual({
      usedPercent: 29,
      windowDurationMins: 10080,
      resetsAt: Math.floor(Date.parse("2026-11-28T08:53:44Z") / 1000),
    });
  });

  test("does not mark tiny non-zero remaining fraction as exhausted, marks zero as exhausted", () => {
    const tiny = parseAgyUsageOutput(
      JSON.stringify({
        status: "SUCCESS",
        command: {
          name: "usage",
          data: {
            groups: [
              {
                name: "Gemini Models",
                buckets: [
                  { id: "gemini-5h", window: "5h", remaining_fraction: 0.002, reset_time: "2026-11-23T19:23:13Z" },
                  { id: "gemini-weekly", window: "weekly", remaining_fraction: 0, reset_time: "2026-11-28T08:53:44Z" },
                ],
              },
            ],
          },
        },
      }),
    );
    expect(tiny?.primary?.usedPercent).toBe(99);
    expect(tiny?.secondary?.usedPercent).toBe(100);
    expect(String(tiny?.rateLimitReachedType)).toBe("secondary");
  });

  test("handles preamble log lines and rejects non-success output", () => {
    const withPreamble = `Fetching usage...\n${SAMPLE_USAGE_JSON}\n`;
    expect(parseAgyUsageOutput(withPreamble)?.secondary?.usedPercent).toBe(29);
    expect(parseAgyUsageOutput(JSON.stringify({ status: "ERROR", command: { data: { groups: [] } } }))).toBeNull();
    expect(parseAgyUsageOutput("not json")).toBeNull();
  });

  test("prepends global gemini/app_data flags only when non-default", () => {
    expect(agyUsageCommandArgs({})).toEqual(["--print", "/usage", "--output-format", "json", "--print-timeout", "20s"]);
    expect(
      agyUsageCommandArgs({
        AGY_ADAPTER_GEMINI_DIR: ".gemini-isolated",
        AGY_ADAPTER_APP_DATA_DIR: "antigravity-custom",
      }),
    ).toEqual([
      "--gemini_dir",
      ".gemini-isolated",
      "--app_data_dir",
      "antigravity-custom",
      "--print",
      "/usage",
      "--output-format",
      "json",
      "--print-timeout",
      "20s",
    ]);
  });
});

describe("AgyRateLimitCatalog", () => {
  test("deduplicates concurrent reads, caches within TTL, enriches planType, and falls back to stale on failure", async () => {
    let clock = 1_000;
    let calls = 0;
    let shouldFail = false;
    const updates: unknown[] = [];

    const catalog = new AgyRateLimitCatalog({
      ttlMs: 60_000,
      failureCooldownMs: 15_000,
      now: () => clock,
      onUpdated: (snapshot) => updates.push(snapshot),
      fetch: async () => {
        calls += 1;
        await new Promise((resolve) => setTimeout(resolve, 10));
        if (shouldFail) throw new Error("network down");
        return parseAgyUsageOutput(SAMPLE_USAGE_JSON);
      },
    });
    catalog.observePlanType("Google AI Ultra");

    const [a, b] = await Promise.all([catalog.read(), catalog.read()]);
    expect(calls).toBe(1);
    expect(a.secondary?.usedPercent).toBe(29);
    expect(String(b.planType)).toBe("Google AI Ultra");
    expect(updates).toHaveLength(1);

    clock += 10_000;
    const cached = await catalog.read();
    expect(calls).toBe(1);
    expect(cached.secondary?.usedPercent).toBe(29);

    clock += 60_000;
    shouldFail = true;
    const stale = await catalog.read();
    expect(calls).toBe(2);
    expect(stale.secondary?.usedPercent).toBe(29);
    expect(updates).toHaveLength(1);
  });

  test("applies failure cooldown when no cached snapshot exists", async () => {
    let clock = 10_000;
    let calls = 0;
    const catalog = new AgyRateLimitCatalog({
      ttlMs: 60_000,
      failureCooldownMs: 15_000,
      now: () => clock,
      fetch: async () => {
        calls += 1;
        return null;
      },
    });

    const first = await catalog.read();
    expect((first as Record<string, unknown>).availability).toBe("unavailable");
    expect(calls).toBe(1);

    clock += 5_000;
    const cooled = await catalog.read();
    expect((cooled as Record<string, unknown>).availability).toBe("unavailable");
    expect(calls).toBe(1);

    clock += 15_000;
    await catalog.read();
    expect(calls).toBe(2);
  });

  test("wires account/rateLimits/read through app router", async () => {
    const stateDir = await mkdtemp(path.join(os.tmpdir(), "mimi-agy-ratelimits-"));
    try {
      const app = createApp({
        stateDir,
        log: () => {},
        fetchRateLimits: async () => parseAgyUsageOutput(SAMPLE_USAGE_JSON),
      });
      const response = (await app.router.dispatch(
        { id: 1, method: "account/rateLimits/read", params: {} },
        {} as never,
      )) as {
        result: { rateLimits: { limitId: string; limitName: string; secondary: { usedPercent: number } } };
      };
      expect(response.result.rateLimits.limitId).toBe("agy");
      expect(response.result.rateLimits.limitName).toBe("Gemini");
      expect(response.result.rateLimits.secondary.usedPercent).toBe(29);
      await app.close();
    } finally {
      await rm(stateDir, { recursive: true, force: true });
    }
  });
});
