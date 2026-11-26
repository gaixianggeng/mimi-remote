#!/usr/bin/env bun
/**
 * PR 1a-1 性能硬阈值验收脚本：
 * 复用 PR 0 落地的固定种子基准脚本 `scripts/bench-agy-acp-list.ts`（默认 seed=20260410, 3 批 × 冷 5 / 热 20），
 * 对照同脚本同种子基线核验全部 3 项硬阈值；任一项未达标时输出明细并以非零退出码 1 退出。
 */
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";

// 同脚本（scripts/bench-agy-acp-list.ts）同种子（20260410, batches=3, cold=5, warm=20, concurrency=4）基线：
// - PR 0 报告基线（2c6342fb）：冷查 git spawn = 128，热态 p95 = 193.400ms
// - 本机 origin/main（02daaa23）实测基线：冷查 git spawn = 128，热态 p95 = 176.386ms（取较严值）
const DEFAULT_BASELINE_COLD_GIT_SPAWNS = 128;
const DEFAULT_BASELINE_WARM_P95_MS = 176.386;
const DEFAULT_MAX_UNIQUE_NORMALIZED_CWDS = 32;

interface CliOptions {
  seed: number;
  batches: number;
  cold: number;
  warm: number;
  concurrency: number;
  baselineColdSpawns: number;
  baselineWarmP95Ms: number;
  checkJson?: string;
}

interface BenchReport {
  seed: number;
  dataset: {
    uniqueNonOrphanRawCwds: number;
    existingUniqueCwdsEligibleForGitInspect?: number;
  };
  summary: {
    concurrentColdGitSpawnsMeanPerRun: number;
    sequentialWarmGitSpawnsAbsoluteAcrossAllBatches: number;
    sequentialWarmP95MsMean: number;
    sequentialWarmP95SpreadPct?: number;
  };
}

function parseIntArg(flag: string, raw: string | undefined, min: number): number {
  if (raw === undefined || raw.trim() === "") {
    throw new Error(`参数 ${flag} 缺少整数值`);
  }
  const value = Number(raw);
  if (!Number.isInteger(value) || value < min) {
    throw new Error(`参数 ${flag} 必须是 >= ${min} 的整数，收到：${raw}`);
  }
  return value;
}

function parseFloatArg(flag: string, raw: string | undefined, minExclusive: number): number {
  if (raw === undefined || raw.trim() === "") {
    throw new Error(`参数 ${flag} 缺少数值`);
  }
  const value = Number(raw);
  if (!Number.isFinite(value) || value <= minExclusive) {
    throw new Error(`参数 ${flag} 必须是 > ${minExclusive} 的有限数值，收到：${raw}`);
  }
  return value;
}

function parseArgs(argv: string[]): CliOptions {
  const opts: CliOptions = {
    seed: 20260410,
    batches: 3,
    cold: 5,
    warm: 20,
    concurrency: 4,
    baselineColdSpawns: DEFAULT_BASELINE_COLD_GIT_SPAWNS,
    baselineWarmP95Ms: DEFAULT_BASELINE_WARM_P95_MS,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = argv[i + 1];
    if (arg === "--seed") {
      opts.seed = parseIntArg(arg, next, 0);
      i += 1;
    } else if (arg === "--batches") {
      opts.batches = parseIntArg(arg, next, 1);
      i += 1;
    } else if (arg === "--cold") {
      opts.cold = parseIntArg(arg, next, 1);
      i += 1;
    } else if (arg === "--warm") {
      opts.warm = parseIntArg(arg, next, 1);
      i += 1;
    } else if (arg === "--concurrency") {
      opts.concurrency = parseIntArg(arg, next, 1);
      i += 1;
    } else if (arg === "--baseline-cold-spawns") {
      opts.baselineColdSpawns = parseFloatArg(arg, next, 0);
      i += 1;
    } else if (arg === "--baseline-warm-p95-ms") {
      opts.baselineWarmP95Ms = parseFloatArg(arg, next, 0);
      i += 1;
    } else if (arg === "--check-json") {
      if (!next) throw new Error("参数 --check-json 缺少 JSON 文件路径");
      opts.checkJson = next;
      i += 1;
    } else {
      throw new Error(`未知参数：${arg}`);
    }
  }
  return opts;
}

function evaluateReport(report: BenchReport, opts: CliOptions): {
  passed: boolean;
  checks: Array<{ name: string; passed: boolean; detail: string }>;
} {
  const uniqueCwdCap = Math.min(
    DEFAULT_MAX_UNIQUE_NORMALIZED_CWDS,
    report.dataset.uniqueNonOrphanRawCwds,
  );
  const coldMaxByReduction = Number((opts.baselineColdSpawns * 0.5).toFixed(3));
  const coldMean = report.summary.concurrentColdGitSpawnsMeanPerRun;
  const coldReductionPct = Number((((opts.baselineColdSpawns - coldMean) / opts.baselineColdSpawns) * 100).toFixed(2));
  const coldCheckPassed = Number.isFinite(coldMean) && coldMean <= uniqueCwdCap && coldMean <= coldMaxByReduction;

  const warmSpawns = report.summary.sequentialWarmGitSpawnsAbsoluteAcrossAllBatches;
  const warmSpawnsCheckPassed = warmSpawns === 0;

  const warmP95Max = Number((opts.baselineWarmP95Ms * 0.7).toFixed(3));
  const warmP95 = report.summary.sequentialWarmP95MsMean;
  const warmImprovementPct = Number((((opts.baselineWarmP95Ms - warmP95) / opts.baselineWarmP95Ms) * 100).toFixed(2));
  const warmP95CheckPassed = Number.isFinite(warmP95) && warmP95 <= warmP95Max;

  const checks = [
    {
      name: "concurrent_cold_git_spawns",
      passed: coldCheckPassed,
      detail: `actual=${coldMean}, cap_unique_cwds=${uniqueCwdCap}, cap_50pct_reduction=${coldMaxByReduction} (baseline=${opts.baselineColdSpawns}, reduction=${coldReductionPct}%)`,
    },
    {
      name: "sequential_warm_git_spawns",
      passed: warmSpawnsCheckPassed,
      detail: `actual=${warmSpawns}, expected=0`,
    },
    {
      name: "sequential_warm_p95_ms",
      passed: warmP95CheckPassed,
      detail: `actual=${warmP95}ms, cap_30pct_improvement=${warmP95Max}ms (baseline=${opts.baselineWarmP95Ms}ms, improvement=${warmImprovementPct}%)`,
    },
  ];
  return {
    passed: checks.every((item) => item.passed),
    checks,
  };
}

function main(): void {
  const opts = parseArgs(process.argv.slice(2));
  let report: BenchReport;

  if (opts.checkJson) {
    report = JSON.parse(readFileSync(opts.checkJson, "utf8")) as BenchReport;
  } else {
    const repoRoot = path.resolve(import.meta.dir, "..", "..", "..");
    const benchScript = path.join(repoRoot, "scripts", "bench-agy-acp-list.ts");
    const tmpDir = mkdtempSync(path.join(os.tmpdir(), "mimi-agy-1a1-perf-"));
    const jsonOut = path.join(tmpDir, "agy-acp-perf.json");
    try {
      const child = spawnSync(
        process.execPath,
        [
          benchScript,
          "--seed",
          String(opts.seed),
          "--batches",
          String(opts.batches),
          "--cold",
          String(opts.cold),
          "--warm",
          String(opts.warm),
          "--concurrency",
          String(opts.concurrency),
          "--json-out",
          jsonOut,
        ],
        {
          cwd: repoRoot,
          encoding: "utf8",
          stdio: ["ignore", "pipe", "pipe"],
        },
      );
      if (child.status !== 0) {
        if (child.stderr) process.stderr.write(child.stderr);
        throw new Error(`基准脚本执行失败，退出码：${child.status ?? "null"}`);
      }
      report = JSON.parse(readFileSync(jsonOut, "utf8")) as BenchReport;
    } finally {
      rmSync(tmpDir, { recursive: true, force: true });
    }
  }

  const evaluation = evaluateReport(report, opts);
  const output = {
    verifier: "agy-acp-phase1a1-perf",
    seed: report.seed,
    baseline: {
      coldGitSpawnsMeanPerRun: opts.baselineColdSpawns,
      warmP95MsMean: opts.baselineWarmP95Ms,
    },
    observed: {
      concurrentColdGitSpawnsMeanPerRun: report.summary.concurrentColdGitSpawnsMeanPerRun,
      sequentialWarmGitSpawnsAbsoluteAcrossAllBatches: report.summary.sequentialWarmGitSpawnsAbsoluteAcrossAllBatches,
      sequentialWarmP95MsMean: report.summary.sequentialWarmP95MsMean,
      sequentialWarmP95SpreadPct: report.summary.sequentialWarmP95SpreadPct ?? null,
    },
    passed: evaluation.passed,
    checks: evaluation.checks,
  };
  console.log(JSON.stringify(output, null, 2));
  if (!evaluation.passed) {
    for (const item of evaluation.checks) {
      if (!item.passed) {
        console.error(`[FAIL] ${item.name}: ${item.detail}`);
      }
    }
    process.exit(1);
  }
}

main();
