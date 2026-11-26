#!/usr/bin/env bun
/**
 * PR 1a-1 性能硬阈值验收脚本：
 * 复用 PR 0 落地的固定种子基准脚本 `scripts/bench-agy-acp-list.ts`（默认 seed=20260410, 3 批 × 冷 5 / 热 20），
 * 默认在本机同一受控确定性 `ps` 环境下使用同脚本、同种子与同配置现测基线（merge-base）并与当前实现对照全部 3 项硬阈值：
 * - 并发冷查 git spawn：校验批数/轮数与 config 一致，逐轮次数及全轮均值均不超过唯一规范化 cwd 上限与基线 50% 降幅上限；
 * - 顺序热态 git spawn：校验各批热态轮数与 config 一致，各批与全批总计均为 0；
 * - 顺序热态延迟：校验各批热态 p95 的均值（`summary.sequentialWarmP95MsMean`，mean of batch p95 values）较同机受控基线改善 >= 30%。
 * 任一项未达标时输出明细并以非零退出码 1 退出。
 */
import { spawnSync } from "node:child_process";
import { chmodSync, copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";

const DEFAULT_MAX_UNIQUE_NORMALIZED_CWDS = 32;
const CONTROLLED_PS_OUTPUT_LINE = "1 /sbin/launchd";
const CONTROLLED_PS_SHIM = `#!/bin/sh
set -eu
printf '${CONTROLLED_PS_OUTPUT_LINE}\\n'
`;

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

function withControlledPsEnv<T>(fn: (controlledEnv: NodeJS.ProcessEnv) => T): T {
  const shimDir = mkdtempSync(path.join(os.tmpdir(), "mimi-agy-1a1-ps-shim-"));
  const psPath = path.join(shimDir, "ps");
  try {
    writeFileSync(psPath, CONTROLLED_PS_SHIM);
    chmodSync(psPath, 0o755);
    const controlledEnv: NodeJS.ProcessEnv = {
      ...process.env,
      PATH: `${shimDir}:${process.env.PATH ?? ""}`,
    };
    const selfTest = spawnSync("ps", ["-eo", "pid=,args="], {
      env: controlledEnv,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });
    if (selfTest.status !== 0 || selfTest.stdout.trim() !== CONTROLLED_PS_OUTPUT_LINE) {
      throw new Error(
        `受控 ps 垫片自检失败：status=${selfTest.status ?? "null"}, stdout=${JSON.stringify(selfTest.stdout)}`,
      );
    }
    return fn(controlledEnv);
  } finally {
    rmSync(shimDir, { recursive: true, force: true });
  }
}

function runBenchInRoot(
  workRoot: string,
  seed: number,
  config: BenchConfig,
  benchEnv: NodeJS.ProcessEnv,
): BenchReport {
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
        env: benchEnv,
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
  benchEnv: NodeJS.ProcessEnv,
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

    // 复用同一份基准脚本并在同一受控 ps 环境下对基线源码现测，确保脚本、种子、批数与进程扫描条件完全一致。
    copyFileSync(
      path.join(repoRoot, "scripts", "bench-agy-acp-list.ts"),
      path.join(baselineRoot, "scripts", "bench-agy-acp-list.ts"),
    );

    return runBenchInRoot(baselineRoot, seed, config, benchEnv);
  } finally {
    rmSync(tmpDir, { recursive: true, force: true });
  }
}

function isValidBenchConfig(cfg: BenchConfig | undefined): cfg is BenchConfig {
  return (
    cfg !== undefined &&
    Number.isInteger(cfg.batches) &&
    cfg.batches >= 1 &&
    Number.isInteger(cfg.cold) &&
    cfg.cold >= 1 &&
    Number.isInteger(cfg.warm) &&
    cfg.warm >= 1 &&
    Number.isInteger(cfg.concurrency) &&
    cfg.concurrency >= 1
  );
}

function validateBaselineMatchesCandidate(baselineReport: BenchReport, candidateReport: BenchReport): void {
  if (baselineReport.seed !== candidateReport.seed) {
    throw new Error(
      `基线与待测报告种子不一致：baseline.seed=${baselineReport.seed}, candidate.seed=${candidateReport.seed}`,
    );
  }
  if (!isValidBenchConfig(baselineReport.config) || !isValidBenchConfig(candidateReport.config)) {
    throw new Error("基线与待测报告均必须包含有效的 config（batches/cold/warm/concurrency）");
  }
  const keys: Array<keyof BenchConfig> = ["batches", "cold", "warm", "concurrency"];
  for (const key of keys) {
    if (baselineReport.config[key] !== candidateReport.config[key]) {
      throw new Error(
        `基线与待测报告配置不一致（${key}）：baseline=${baselineReport.config[key]}, candidate=${candidateReport.config[key]}`,
      );
    }
  }
}

function resolveBaseline(
  repoRoot: string,
  opts: CliOptions,
  candidateReport: BenchReport,
  controlledBenchEnv?: NodeJS.ProcessEnv,
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

  if (!controlledBenchEnv) {
    throw new Error("内部错误：缺少受控 ps 基准环境");
  }
  const effectiveSeed = Number.isInteger(candidateReport.seed) ? candidateReport.seed : opts.seed;
  const effectiveConfig: BenchConfig = isValidBenchConfig(candidateReport.config)
    ? candidateReport.config
    : {
        batches: opts.batches,
        cold: opts.cold,
        warm: opts.warm,
        concurrency: opts.concurrency,
      };
  const baselineCommit = resolveBaselineCommit(repoRoot, opts.baselineRef);
  const baselineReport = measureBaselineLocally(
    repoRoot,
    baselineCommit,
    effectiveSeed,
    effectiveConfig,
    controlledBenchEnv,
  );
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

  // 先核验 report.config 与 batches 数量、每批冷/热轮数完全一致，再逐轮校验每批每一次并发冷查的 git spawn，
  // 严禁接受删减批次或截断样本的不完整报告，也严禁仅靠均值掩盖单轮超标。
  const roundRecords: Array<{ batch: number; run: number; spawns: number }> = [];
  const cfg = report.config;
  const configValid = isValidBenchConfig(cfg);
  let coldStructureError: string | null = null;
  let warmStructureError: string | null = null;

  if (!configValid) {
    coldStructureError = "missing_or_invalid_config";
    warmStructureError = "missing_or_invalid_config";
  } else if (!Array.isArray(report.batches) || report.batches.length !== cfg.batches) {
    const actualBatches = Array.isArray(report.batches) ? report.batches.length : 0;
    const msg = `batch_count_mismatch(actual=${actualBatches},expected=${cfg.batches})`;
    coldStructureError = msg;
    warmStructureError = msg;
  } else {
    for (let bIdx = 0; bIdx < report.batches.length; bIdx += 1) {
      const batch = report.batches[bIdx]!;
      const batchNum = batch.batch ?? bIdx + 1;
      const cold = batch.concurrentCold;
      const perRun = cold?.gitSpawnsPerRun;
      if (!coldStructureError) {
        if (!Array.isArray(perRun) || perRun.length !== cfg.cold) {
          coldStructureError = `cold_round_count_mismatch(batch=${batchNum},actual=${Array.isArray(perRun) ? perRun.length : 0},expected=${cfg.cold})`;
        } else if (cold?.runs !== cfg.cold) {
          coldStructureError = `cold_runs_field_mismatch(batch=${batchNum},actual=${cold?.runs},expected=${cfg.cold})`;
        } else if (cold?.concurrency !== cfg.concurrency) {
          coldStructureError = `cold_concurrency_mismatch(batch=${batchNum},actual=${cold?.concurrency},expected=${cfg.concurrency})`;
        } else {
          for (let rIdx = 0; rIdx < perRun.length; rIdx += 1) {
            const spawns = perRun[rIdx];
            if (typeof spawns !== "number" || !Number.isFinite(spawns) || spawns < 0) {
              coldStructureError = `invalid_cold_spawn_value(batch=${batchNum},run=${rIdx + 1})`;
              break;
            }
            roundRecords.push({ batch: batchNum, run: rIdx + 1, spawns });
          }
        }
      }

      const warm = batch.sequentialWarm;
      if (warm?.runs !== cfg.warm) {
        warmStructureError ??= `warm_round_count_mismatch(batch=${batchNum},actual=${warm?.runs},expected=${cfg.warm})`;
      }
    }
    if (!coldStructureError && roundRecords.length !== cfg.batches * cfg.cold) {
      coldStructureError = `total_cold_rounds_mismatch(actual=${roundRecords.length},expected=${cfg.batches * cfg.cold})`;
    }
  }

  const roundsValid = coldStructureError === null;
  const violatingRounds = roundsValid
    ? roundRecords.filter((entry) => entry.spawns > uniqueCwdCap || entry.spawns > coldMaxByReduction)
    : [];
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
    warmStructureError === null &&
    Array.isArray(report.batches) &&
    report.batches.length > 0 &&
    report.batches.every((batch) => batch.sequentialWarm?.gitSpawnsAbsoluteTotal === 0);
  const warmSpawnsCheckPassed = warmSpawns === 0 && warmBatchesValid;

  const warmP95Max = Number((baseline.warmP95MsMean * 0.7).toFixed(3));
  const warmP95 = report.summary?.sequentialWarmP95MsMean;
  const warmImprovementPct = Number(
    (((baseline.warmP95MsMean - warmP95) / baseline.warmP95MsMean) * 100).toFixed(2),
  );
  const warmP95CheckPassed =
    warmStructureError === null && Number.isFinite(warmP95) && warmP95 >= 0 && warmP95 <= warmP95Max;

  const violationSuffix = coldStructureError
    ? `, error=${coldStructureError}`
    : violatingRounds.length > 0
      ? `, violating_rounds=[${violatingRounds.map((v) => `b${v.batch}#${v.run}:${v.spawns}`).join(",")}]`
      : "";
  const warmErrorSuffix = warmStructureError ? `, error=${warmStructureError}` : "";

  const checks = [
    {
      name: "concurrent_cold_git_spawns",
      passed: coldCheckPassed,
      detail: `max_per_run=${coldMaxPerRun ?? "invalid"}, mean=${coldMean}, rounds=${roundRecords.length}, cap_unique_cwds=${uniqueCwdCap}, cap_50pct_reduction=${coldMaxByReduction} (baseline=${baseline.coldGitSpawnsMeanPerRun}, reduction=${coldReductionPct}%${violationSuffix})`,
    },
    {
      name: "sequential_warm_git_spawns",
      passed: warmSpawnsCheckPassed,
      detail: `actual=${warmSpawns}, batches_all_zero=${warmBatchesValid}, expected=0${warmErrorSuffix}`,
    },
    {
      name: "sequential_warm_p95_ms",
      passed: warmP95CheckPassed,
      detail: `mean_of_batch_p95=${warmP95}ms, cap_30pct_improvement=${warmP95Max}ms (baseline_mean_of_batch_p95=${baseline.warmP95MsMean}ms, source=${baseline.source}, improvement=${warmImprovementPct}%${warmErrorSuffix})`,
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
  const needsLiveBaseline = !opts.baselineJson && opts.baselineColdSpawns === undefined;
  const needsLiveRun = !opts.checkJson || needsLiveBaseline;

  const runEvaluation = (controlledBenchEnv?: NodeJS.ProcessEnv) => {
    const report = opts.checkJson
      ? (JSON.parse(readFileSync(opts.checkJson, "utf8")) as BenchReport)
      : runBenchInRoot(
          repoRoot,
          opts.seed,
          {
            batches: opts.batches,
            cold: opts.cold,
            warm: opts.warm,
            concurrency: opts.concurrency,
          },
          controlledBenchEnv!,
        );

    const baseline = resolveBaseline(repoRoot, opts, report, controlledBenchEnv);
    const evaluation = evaluateReport(report, baseline);
    const output = {
      verifier: "agy-acp-phase1a1-perf",
      seed: report.seed,
      processScan: needsLiveRun
        ? { controlled: true, mode: "deterministic_ps_shim" }
        : { controlled: false, mode: "pre_recorded_json" },
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
  };

  if (needsLiveRun) {
    withControlledPsEnv((controlledEnv) => runEvaluation(controlledEnv));
  } else {
    runEvaluation();
  }
}

main();
