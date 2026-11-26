#!/usr/bin/env bun
/**
 * PR 1a-1 性能硬阈值验收脚本：
 * 复用 PR 0 落地的固定种子基准脚本 `scripts/bench-agy-acp-list.ts`（默认 seed=20260410, 3 批 × 冷 5 / 热 20），
 * 默认在本机使用同脚本、同种子与同配置现测基线（merge-base）并与当前实现逐轮对照全部 3 项硬阈值；
 * 任一项未达标时输出明细并以非零退出码 1 退出。
 */
import { spawnSync } from "node:child_process";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";

const DEFAULT_MAX_UNIQUE_NORMALIZED_CWDS = 32;

interface BenchConfig {
  batches: number;
  cold: number;
  warm: number;
  concurrency: number;
}

interface CliOptions extends BenchConfig {
  seed: number;
  baselineRef?: string;
  baselineJson?: string;
  baselineColdSpawns?: number;
  baselineWarmP95Ms?: number;
  checkJson?: string;
}

interface BenchBatch {
  batch?: number;
  concurrentCold?: {
    runs?: number;
    concurrency?: number;
    gitSpawnsPerRun?: number[];
    gitSpawnsMean?: number;
    gitSpawnsTotal?: number;
  };
  sequentialWarm?: {
    runs?: number;
    gitSpawnsAbsoluteTotal?: number;
  };
}

interface BenchReport {
  seed: number;
  config?: BenchConfig;
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
  batches?: BenchBatch[];
}

interface ResolvedBaseline {
  source: "live_measured" | "baseline_json" | "explicit_cli";
  ref?: string;
  coldGitSpawnsMeanPerRun: number;
  warmP95MsMean: number;
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
    } else if (arg === "--baseline-ref") {
      if (!next) throw new Error("参数 --baseline-ref 缺少 Git ref");
      opts.baselineRef = next;
      i += 1;
    } else if (arg === "--baseline-json") {
      if (!next) throw new Error("参数 --baseline-json 缺少 JSON 文件路径");
      opts.baselineJson = next;
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

  const hasExplicitCold = opts.baselineColdSpawns !== undefined;
  const hasExplicitWarm = opts.baselineWarmP95Ms !== undefined;
  if (hasExplicitCold !== hasExplicitWarm) {
    throw new Error("参数 --baseline-cold-spawns 与 --baseline-warm-p95-ms 必须同时提供，不能仅覆盖单侧基线");
  }
  if (opts.baselineJson && (hasExplicitCold || opts.baselineRef)) {
    throw new Error("参数 --baseline-json 不能与 --baseline-ref 或手动基线参数混用");
  }
  if (opts.baselineRef && hasExplicitCold) {
    throw new Error("参数 --baseline-ref 不能与 --baseline-cold-spawns/--baseline-warm-p95-ms 混用");
  }

  return opts;
}

function runBenchInRoot(workRoot: string, seed: number, config: BenchConfig): BenchReport {
  const benchScript = path.join(workRoot, "scripts", "bench-agy-acp-list.ts");
  const tmpDir = mkdtempSync(path.join(os.tmpdir(), "mimi-agy-1a1-perf-out-"));
  const jsonOut = path.join(tmpDir, "agy-acp-perf.json");
  try {
    const child = spawnSync(
      process.execPath,
      [
        benchScript,
        "--seed",
        String(seed),
        "--batches",
        String(config.batches),
        "--cold",
        String(config.cold),
        "--warm",
        String(config.warm),
        "--concurrency",
        String(config.concurrency),
        "--json-out",
        jsonOut,
      ],
      {
        cwd: workRoot,
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
      },
    );
    if (child.status !== 0) {
      if (child.stderr) process.stderr.write(child.stderr);
      throw new Error(`基准脚本执行失败（cwd=${workRoot}），退出码：${child.status ?? "null"}`);
    }
    return JSON.parse(readFileSync(jsonOut, "utf8")) as BenchReport;
  } finally {
    rmSync(tmpDir, { recursive: true, force: true });
  }
}

function resolveBaselineCommit(repoRoot: string, explicitRef?: string): string {
  if (explicitRef) {
    const rev = spawnSync("git", ["rev-parse", "--verify", `${explicitRef}^{commit}`], {
      cwd: repoRoot,
      encoding: "utf8",
    });
    if (rev.status === 0 && rev.stdout.trim()) {
      return rev.stdout.trim();
    }
    throw new Error(`无法解析 --baseline-ref 指定的提交：${explicitRef}`);
  }

  for (const candidate of ["origin/main", "main", "refs/remotes/origin/main"]) {
    const mb = spawnSync("git", ["merge-base", "HEAD", candidate], {
      cwd: repoRoot,
      encoding: "utf8",
    });
    if (mb.status === 0 && mb.stdout.trim()) {
      return mb.stdout.trim();
    }
  }
  throw new Error("无法自动解析基线 merge-base（未找到 origin/main 或 main）；请通过 --baseline-ref 或 --baseline-json 指定同机基线");
}

function measureBaselineLocally(
  repoRoot: string,
  baselineCommit: string,
  seed: number,
  config: BenchConfig,
): BenchReport {
  const tmpDir = mkdtempSync(path.join(os.tmpdir(), "mimi-agy-1a1-baseline-"));
  const baselineRoot = path.join(tmpDir, "work");
  const tarPath = path.join(tmpDir, "baseline.tar");
  try {
    mkdirSync(path.join(baselineRoot, "scripts"), { recursive: true });
    const archive = spawnSync(
      "git",
      ["archive", "--format=tar", "--output", tarPath, baselineCommit, "bridges/agy-acp", "bridges/appserver-kit"],
      { cwd: repoRoot, encoding: "utf8" },
    );
    if (archive.status !== 0) {
      if (archive.stderr) process.stderr.write(archive.stderr);
      throw new Error(`导出基线提交 ${baselineCommit} 源码失败，退出码：${archive.status ?? "null"}`);
    }

    const extract = spawnSync("tar", ["-xf", tarPath, "-C", baselineRoot], {
      encoding: "utf8",
    });
    if (extract.status !== 0) {
      if (extract.stderr) process.stderr.write(extract.stderr);
      throw new Error(`解压基线源码失败，退出码：${extract.status ?? "null"}`);
    }

    // 复用同一份基准脚本在基线源码上现测，确保脚本、种子、批数与本机扫描条件完全一致。
    copyFileSync(
      path.join(repoRoot, "scripts", "bench-agy-acp-list.ts"),
      path.join(baselineRoot, "scripts", "bench-agy-acp-list.ts"),
    );

    return runBenchInRoot(baselineRoot, seed, config);
  } finally {
    rmSync(tmpDir, { recursive: true, force: true });
  }
}

function validateBaselineMatchesCandidate(baselineReport: BenchReport, candidateReport: BenchReport): void {
  if (baselineReport.seed !== candidateReport.seed) {
    throw new Error(
      `基线与待测报告种子不一致：baseline.seed=${baselineReport.seed}, candidate.seed=${candidateReport.seed}`,
    );
  }
  if (baselineReport.config && candidateReport.config) {
    const keys: Array<keyof BenchConfig> = ["batches", "cold", "warm", "concurrency"];
    for (const key of keys) {
      if (baselineReport.config[key] !== candidateReport.config[key]) {
        throw new Error(
          `基线与待测报告配置不一致（${key}）：baseline=${baselineReport.config[key]}, candidate=${candidateReport.config[key]}`,
        );
      }
    }
  }
}

function resolveBaseline(
  repoRoot: string,
  opts: CliOptions,
  candidateReport: BenchReport,
): ResolvedBaseline {
  if (opts.baselineJson) {
    const baselineReport = JSON.parse(readFileSync(opts.baselineJson, "utf8")) as BenchReport;
    validateBaselineMatchesCandidate(baselineReport, candidateReport);
    const cold = baselineReport.summary?.concurrentColdGitSpawnsMeanPerRun;
    const warm = baselineReport.summary?.sequentialWarmP95MsMean;
    if (!Number.isFinite(cold) || cold <= 0 || !Number.isFinite(warm) || warm <= 0) {
      throw new Error(`--baseline-json 缺少有效的冷/热基线指标：cold=${cold}, warmP95=${warm}`);
    }
    return {
      source: "baseline_json",
      coldGitSpawnsMeanPerRun: cold,
      warmP95MsMean: warm,
    };
  }

  if (opts.baselineColdSpawns !== undefined && opts.baselineWarmP95Ms !== undefined) {
    return {
      source: "explicit_cli",
      coldGitSpawnsMeanPerRun: opts.baselineColdSpawns,
      warmP95MsMean: opts.baselineWarmP95Ms,
    };
  }

  const effectiveSeed = Number.isInteger(candidateReport.seed) ? candidateReport.seed : opts.seed;
  const effectiveConfig: BenchConfig = {
    batches: candidateReport.config?.batches ?? opts.batches,
    cold: candidateReport.config?.cold ?? opts.cold,
    warm: candidateReport.config?.warm ?? opts.warm,
    concurrency: candidateReport.config?.concurrency ?? opts.concurrency,
  };
  const baselineCommit = resolveBaselineCommit(repoRoot, opts.baselineRef);
  const baselineReport = measureBaselineLocally(repoRoot, baselineCommit, effectiveSeed, effectiveConfig);
  const cold = baselineReport.summary?.concurrentColdGitSpawnsMeanPerRun;
  const warm = baselineReport.summary?.sequentialWarmP95MsMean;
  if (!Number.isFinite(cold) || cold <= 0 || !Number.isFinite(warm) || warm <= 0) {
    throw new Error(`本机现测基线（${baselineCommit}）指标无效：cold=${cold}, warmP95=${warm}`);
  }
  return {
    source: "live_measured",
    ref: baselineCommit,
    coldGitSpawnsMeanPerRun: cold,
    warmP95MsMean: warm,
  };
}

function evaluateReport(
  report: BenchReport,
  baseline: ResolvedBaseline,
): {
  passed: boolean;
  coldMaxPerRun: number | null;
  coldRoundCount: number;
  checks: Array<{ name: string; passed: boolean; detail: string }>;
} {
  const uniqueRaw = report.dataset?.uniqueNonOrphanRawCwds;
  const uniqueCwdCap =
    Number.isInteger(uniqueRaw) && uniqueRaw > 0
      ? Math.min(DEFAULT_MAX_UNIQUE_NORMALIZED_CWDS, uniqueRaw)
      : 0;
  const coldMaxByReduction = Number((baseline.coldGitSpawnsMeanPerRun * 0.5).toFixed(3));
  const coldMean = report.summary?.concurrentColdGitSpawnsMeanPerRun;
  const coldReductionPct = Number(
    (((baseline.coldGitSpawnsMeanPerRun - coldMean) / baseline.coldGitSpawnsMeanPerRun) * 100).toFixed(2),
  );

  // 逐轮校验每一批每一次并发冷查的 git spawn 次数，严禁仅靠均值掩盖单轮超标。
  const roundRecords: Array<{ batch: number; run: number; spawns: number }> = [];
  let roundsValid = Array.isArray(report.batches) && report.batches.length > 0;
  if (roundsValid) {
    for (let bIdx = 0; bIdx < report.batches!.length; bIdx += 1) {
      const batch = report.batches![bIdx]!;
      const perRun = batch.concurrentCold?.gitSpawnsPerRun;
      if (!Array.isArray(perRun) || perRun.length === 0) {
        roundsValid = false;
        break;
      }
      for (let rIdx = 0; rIdx < perRun.length; rIdx += 1) {
        const spawns = perRun[rIdx];
        if (typeof spawns !== "number" || !Number.isFinite(spawns) || spawns < 0) {
          roundsValid = false;
          break;
        }
        roundRecords.push({ batch: batch.batch ?? bIdx + 1, run: rIdx + 1, spawns });
      }
      if (!roundsValid) break;
    }
  }

  const violatingRounds = roundRecords.filter(
    (entry) => entry.spawns > uniqueCwdCap || entry.spawns > coldMaxByReduction,
  );
  const coldMaxPerRun =
    roundsValid && roundRecords.length > 0 ? Math.max(...roundRecords.map((entry) => entry.spawns)) : null;
  const coldCheckPassed =
    uniqueCwdCap > 0 &&
    roundsValid &&
    violatingRounds.length === 0 &&
    Number.isFinite(coldMean) &&
    coldMean >= 0 &&
    coldMean <= uniqueCwdCap &&
    coldMean <= coldMaxByReduction;

  const warmSpawns = report.summary?.sequentialWarmGitSpawnsAbsoluteAcrossAllBatches;
  const warmBatchesValid =
    Array.isArray(report.batches) &&
    report.batches.length > 0 &&
    report.batches.every((batch) => batch.sequentialWarm?.gitSpawnsAbsoluteTotal === 0);
  const warmSpawnsCheckPassed = warmSpawns === 0 && warmBatchesValid;

  const warmP95Max = Number((baseline.warmP95MsMean * 0.7).toFixed(3));
  const warmP95 = report.summary?.sequentialWarmP95MsMean;
  const warmImprovementPct = Number(
    (((baseline.warmP95MsMean - warmP95) / baseline.warmP95MsMean) * 100).toFixed(2),
  );
  const warmP95CheckPassed = Number.isFinite(warmP95) && warmP95 >= 0 && warmP95 <= warmP95Max;

  const violationSuffix = !roundsValid
    ? ", error=missing_or_invalid_per_run_batches"
    : violatingRounds.length > 0
      ? `, violating_rounds=[${violatingRounds.map((v) => `b${v.batch}#${v.run}:${v.spawns}`).join(",")}]`
      : "";

  const checks = [
    {
      name: "concurrent_cold_git_spawns",
      passed: coldCheckPassed,
      detail: `max_per_run=${coldMaxPerRun ?? "invalid"}, mean=${coldMean}, rounds=${roundRecords.length}, cap_unique_cwds=${uniqueCwdCap}, cap_50pct_reduction=${coldMaxByReduction} (baseline=${baseline.coldGitSpawnsMeanPerRun}, reduction=${coldReductionPct}%${violationSuffix})`,
    },
    {
      name: "sequential_warm_git_spawns",
      passed: warmSpawnsCheckPassed,
      detail: `actual=${warmSpawns}, batches_all_zero=${warmBatchesValid}, expected=0`,
    },
    {
      name: "sequential_warm_p95_ms",
      passed: warmP95CheckPassed,
      detail: `actual=${warmP95}ms, cap_30pct_improvement=${warmP95Max}ms (baseline=${baseline.warmP95MsMean}ms, source=${baseline.source}, improvement=${warmImprovementPct}%)`,
    },
  ];
  return {
    passed: checks.every((item) => item.passed),
    coldMaxPerRun,
    coldRoundCount: roundRecords.length,
    checks,
  };
}

function main(): void {
  const opts = parseArgs(process.argv.slice(2));
  const repoRoot = path.resolve(import.meta.dir, "..", "..", "..");
  const report = opts.checkJson
    ? (JSON.parse(readFileSync(opts.checkJson, "utf8")) as BenchReport)
    : runBenchInRoot(repoRoot, opts.seed, {
        batches: opts.batches,
        cold: opts.cold,
        warm: opts.warm,
        concurrency: opts.concurrency,
      });

  const baseline = resolveBaseline(repoRoot, opts, report);
  const evaluation = evaluateReport(report, baseline);
  const output = {
    verifier: "agy-acp-phase1a1-perf",
    seed: report.seed,
    baseline: {
      source: baseline.source,
      ...(baseline.ref ? { ref: baseline.ref } : {}),
      coldGitSpawnsMeanPerRun: baseline.coldGitSpawnsMeanPerRun,
      warmP95MsMean: baseline.warmP95MsMean,
    },
    observed: {
      concurrentColdGitSpawnsMaxPerRun: evaluation.coldMaxPerRun,
      concurrentColdGitSpawnsMeanPerRun: report.summary.concurrentColdGitSpawnsMeanPerRun,
      concurrentColdRounds: evaluation.coldRoundCount,
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
