#!/usr/bin/env bun
/**
 * Phase 0 可复跑性能基准：Antigravity (bridges/agy-acp) 目录列表
 *
 * 严格不修改任何产品源码，通过临时 PATH 下的真实 git 包装器精确统计 OS 级 git spawn 次数，
 * 并通过确定性固定种子数据集（500 全局 / 30 目标仓，含 worktree、symlink、百分号编码路径、缺失目录、孤儿会话）
 * 按 3 批 ×（冷 5 次并发 + 热 20 次顺序）采集基线数据。
 */
import { execFileSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { performance } from "node:perf_hooks";
import type { AcpSessionSummary } from "../bridges/agy-acp/src/acp/types.ts";
import { AgyCatalog, AgyHistoryStore, type AgySessionBackend } from "../bridges/agy-acp/src/agy/catalog.ts";
import { conversationDbPath, resolveSessionOrigin, type AgySessionOrigin } from "../bridges/agy-acp/src/agy/env.ts";
import { GitRepoIndex } from "../bridges/agy-acp/src/agy/git.ts";
import { AgyOverlay } from "../bridges/agy-acp/src/agy/overlay.ts";
import { createThreadHandlers } from "../bridges/agy-acp/src/handlers/threads.ts";

interface CliOptions {
  seed: number;
  batches: number;
  cold: number;
  warm: number;
  concurrency: number;
  jsonOut?: string;
}

function parseArgs(argv: string[]): CliOptions {
  const opts: CliOptions = { seed: 20260410, batches: 3, cold: 5, warm: 20, concurrency: 4 };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = argv[i + 1];
    if (arg === "--seed" && next) { opts.seed = Number(next); i += 1; }
    else if (arg === "--batches" && next) { opts.batches = Number(next); i += 1; }
    else if (arg === "--cold" && next) { opts.cold = Number(next); i += 1; }
    else if (arg === "--warm" && next) { opts.warm = Number(next); i += 1; }
    else if (arg === "--concurrency" && next) { opts.concurrency = Number(next); i += 1; }
    else if (arg === "--json-out" && next) { opts.jsonOut = next; i += 1; }
  }
  return opts;
}

function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function percentile(values: number[], p: number): number {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const rank = Math.ceil((p / 100) * sorted.length) - 1;
  const idx = Math.max(0, Math.min(sorted.length - 1, rank));
  return Number(sorted[idx]!.toFixed(3));
}

function mean(values: number[]): number {
  if (values.length === 0) return 0;
  return Number((values.reduce((acc, v) => acc + v, 0) / values.length).toFixed(3));
}

function initGitRepo(realGit: string, dir: string): void {
  mkdirSync(dir, { recursive: true });
  const env = { ...process.env, GIT_CONFIG_GLOBAL: "/dev/null" };
  execFileSync(realGit, ["init", "-q", "-b", "main"], { cwd: dir, env });
  execFileSync(
    realGit,
    ["-c", "user.name=Demo", "-c", "user.email=demo@example.invalid", "commit", "-q", "--allow-empty", "-m", "init"],
    { cwd: dir, env },
  );
}

function addWorktree(realGit: string, repoDir: string, wtDir: string, branch: string): void {
  const env = { ...process.env, GIT_CONFIG_GLOBAL: "/dev/null" };
  execFileSync(realGit, ["worktree", "add", "-q", "-b", branch, wtDir], { cwd: repoDir, env });
}

function encodeFileUri(absPath: string): string {
  return `file://${absPath.split("/").map((seg) => encodeURIComponent(seg)).join("/")}`;
}

function readSpawnCount(counterFile: string): number {
  try {
    const content = readFileSync(counterFile, "utf8");
    return content ? content.trim().split("\n").filter(Boolean).length : 0;
  } catch {
    return 0;
  }
}

function resetSpawnCount(counterFile: string): void {
  writeFileSync(counterFile, "");
}

const opts = parseArgs(process.argv.slice(2));
const rand = mulberry32(opts.seed);
const realGit = execFileSync("which", ["git"], { encoding: "utf8" }).trim();
const sandbox = realpathSync(mkdtempSync(path.join(os.tmpdir(), "mimi-phase0-agy-bench-")));
const originalPath = process.env.PATH ?? "";

try {
  // 1. 构造真实 git 包装器（精确计数 OS 级 git spawn，无产品源码侵入）
  const binDir = path.join(sandbox, "bin");
  mkdirSync(binDir, { recursive: true });
  const gitCounterFile = path.join(sandbox, "git-spawns.log");
  resetSpawnCount(gitCounterFile);
  const gitWrapper = path.join(binDir, "git");
  writeFileSync(
    gitWrapper,
    `#!/bin/sh\nprintf '1\\n' >> "${gitCounterFile}"\nexec "${realGit}" "$@"\n`,
  );
  chmodSync(gitWrapper, 0o755);

  // 2. 构造固定种子数据集（500 全局 / 30 目标仓：含 worktree、symlink、百分号编码路径、缺失目录、孤儿）
  const workspacesRoot = path.join(sandbox, "workspaces");
  const targetRepo = path.join(workspacesRoot, "target repo");
  initGitRepo(realGit, targetRepo);
  const targetWt1 = path.join(workspacesRoot, "target-wt-1");
  const targetWt2 = path.join(workspacesRoot, "target-wt-2");
  addWorktree(realGit, targetRepo, targetWt1, "wt-1");
  addWorktree(realGit, targetRepo, targetWt2, "wt-2");
  const targetSymlink = path.join(workspacesRoot, "target-link");
  symlinkSync(targetRepo, targetSymlink);
  const targetEncodedUri = encodeFileUri(targetRepo);

  const otherRepos: string[] = [];
  for (let r = 0; r < 12; r += 1) {
    const repoDir = path.join(workspacesRoot, `other-repo-${String(r).padStart(2, "0")}`);
    initGitRepo(realGit, repoDir);
    otherRepos.push(repoDir);
    if (r < 6) {
      const wtDir = path.join(workspacesRoot, `other-repo-${String(r).padStart(2, "0")}-wt`);
      addWorktree(realGit, repoDir, wtDir, `other-wt-${r}`);
      otherRepos.push(wtDir);
    }
  }

  const nonGitDirs: string[] = [];
  for (let d = 0; d < 6; d += 1) {
    const dir = path.join(workspacesRoot, `plain dir ${d}`);
    mkdirSync(dir, { recursive: true });
    nonGitDirs.push(d % 2 === 0 ? encodeFileUri(dir) : dir);
  }

  const missingDirs = [
    path.join(workspacesRoot, "deleted-repo-0"),
    path.join(workspacesRoot, "deleted-repo-1"),
    path.join(workspacesRoot, "deleted-repo-2"),
    path.join(workspacesRoot, "deleted-repo-3"),
  ];

  const homeDir = path.join(sandbox, "home");
  const cliConvDir = path.join(homeDir, ".gemini", "antigravity-cli", "conversations");
  const otherConvDir = path.join(homeDir, ".gemini", "antigravity", "conversations");
  mkdirSync(cliConvDir, { recursive: true });
  mkdirSync(otherConvDir, { recursive: true });

  const summaries: AcpSessionSummary[] = [];
  const baseEpochSec = 1775800000;
  const targetPaths = [targetRepo, targetWt1, targetWt2, targetSymlink, targetEncodedUri];
  const uniqueCandidateCwds = new Set<string>();

  const addSession = (idx: number, cwd: string, origin: AgySessionOrigin | "orphan") => {
    const id = `agy-bench-${String(idx).padStart(4, "0")}`;
    const offsetSec = Math.floor(rand() * 86400 * 14);
    const updatedIso = new Date((baseEpochSec + offsetSec) * 1000).toISOString();
    summaries.push({
      sessionId: id,
      cwd,
      title: `Synthetic Agy Session ${idx}`,
      updatedAt: updatedIso,
    });
    if (origin === "cli") {
      writeFileSync(path.join(cliConvDir, `${id}.db`), "");
      uniqueCandidateCwds.add(cwd);
    } else if (origin === "other") {
      writeFileSync(path.join(otherConvDir, `${id}.db`), "");
      uniqueCandidateCwds.add(cwd);
    }
  };

  // 30 目标仓会话（分布在主仓、2 个 worktree、symlink、百分号编码 URI）
  for (let i = 0; i < 30; i += 1) {
    const cwd = targetPaths[i % targetPaths.length]!;
    addSession(i, cwd, i % 3 === 0 ? "other" : "cli");
  }
  // 360 其他 Git 仓及 worktree 会话
  for (let i = 30; i < 390; i += 1) {
    const cwd = otherRepos[(i - 30) % otherRepos.length]!;
    addSession(i, cwd, i % 4 === 0 ? "other" : "cli");
  }
  // 50 非 Git 目录会话（含编码 URI）
  for (let i = 390; i < 440; i += 1) {
    const cwd = nonGitDirs[(i - 390) % nonGitDirs.length]!;
    addSession(i, cwd, "cli");
  }
  // 30 缺失目录会话
  for (let i = 440; i < 470; i += 1) {
    const cwd = missingDirs[(i - 440) % missingDirs.length]!;
    addSession(i, cwd, i % 2 === 0 ? "other" : "cli");
  }
  // 30 孤儿会话（无 .db 文件）
  for (let i = 470; i < 500; i += 1) {
    const cwd = otherRepos[i % otherRepos.length]!;
    addSession(i, cwd, "orphan");
  }

  // 固定种子洗牌，模拟现网乱序摘要流
  for (let i = summaries.length - 1; i > 0; i -= 1) {
    const j = Math.floor(rand() * (i + 1));
    [summaries[i], summaries[j]] = [summaries[j]!, summaries[i]!];
  }

  const agyEnv: NodeJS.ProcessEnv = { ...process.env, HOME: homeDir };
  const stateDir = path.join(sandbox, "state");
  mkdirSync(stateDir, { recursive: true });

  const createStack = () => {
    let acpListCalls = 0;
    const backend: AgySessionBackend = {
      async listSummaries() {
        acpListCalls += 1;
        return summaries;
      },
      wasLastOtherListDegraded: () => false,
      async loadReplay() {
        return [];
      },
      resolveSessionOrigin: (sessionId) => resolveSessionOrigin(sessionId, agyEnv),
      conversationFilePath: (sessionId, origin) => conversationDbPath(sessionId, agyEnv, origin) ?? null,
    };
    const git = new GitRepoIndex(30_000);
    const overlay = new AgyOverlay(path.join(stateDir, "overlay.json"));
    const catalog = new AgyCatalog({ backend, git, overlay }, 1_500);
    const history = new AgyHistoryStore(catalog, backend);
    const handlers = createThreadHandlers(catalog, history);
    return { handlers, getAcpListCalls: () => acpListCalls };
  };

  // 开启 PATH 包装，开始 3 批实测
  process.env.PATH = `${binDir}:${originalPath}`;

  const batchResults: Array<{
    batch: number;
    concurrentCold: {
      runs: number;
      concurrency: number;
      latencyMs: { p50: number; p95: number; max: number; mean: number };
      gitSpawnsPerRun: number[];
      gitSpawnsMean: number;
      gitSpawnsTotal: number;
      acpListCallsPerRun: number[];
      returnedRowsPerCall: number;
    };
    sequentialWarm: {
      runs: number;
      latencyMs: { p50: number; p95: number; max: number; mean: number };
      gitSpawnsAbsoluteTotal: number;
      gitSpawnsPerRun: number;
      acpListCallsDelta: number;
      returnedRowsPerCall: number;
    };
  }> = [];

  for (let batch = 1; batch <= opts.batches; batch += 1) {
    // A. 并发冷查（清进程缓存 / 新建 GitRepoIndex 与 AgyCatalog，并发触发同仓查询）
    const coldLatencies: number[] = [];
    const coldGitSpawns: number[] = [];
    const coldAcpCalls: number[] = [];
    let coldReturned = 0;

    for (let run = 0; run < opts.cold; run += 1) {
      const { handlers, getAcpListCalls } = createStack();
      resetSpawnCount(gitCounterFile);
      const t0 = performance.now();
      const responses = await Promise.all(
        Array.from({ length: opts.concurrency }, () =>
          handlers.list({ cwd: targetRepo, limit: 20, sortKey: "updated_at", sortDirection: "desc" }),
        ),
      );
      const elapsed = performance.now() - t0;
      const spawns = readSpawnCount(gitCounterFile);
      coldLatencies.push(elapsed);
      coldGitSpawns.push(spawns);
      coldAcpCalls.push(getAcpListCalls());
      coldReturned = responses[0]!.data.length;
      for (const r of responses) {
        if (r.data.length !== 20 || r.nextCursor === null) {
          throw new Error(`Agy 并发冷查结果异常：len=${r.data.length}, nextCursor=${r.nextCursor}`);
        }
      }
    }

    // B. 顺序热态（预热 30s Git 缓存后连续 20 次顺序查询）
    const warmStack = createStack();
    await warmStack.handlers.list({ cwd: targetRepo, limit: 20, sortKey: "updated_at", sortDirection: "desc" });
    resetSpawnCount(gitCounterFile);
    const acpBeforeWarm = warmStack.getAcpListCalls();
    const warmLatencies: number[] = [];
    let warmReturned = 0;
    for (let run = 0; run < opts.warm; run += 1) {
      const t0 = performance.now();
      const resp = await warmStack.handlers.list({ cwd: targetRepo, limit: 20, sortKey: "updated_at", sortDirection: "desc" });
      warmLatencies.push(performance.now() - t0);
      warmReturned = resp.data.length;
      if (resp.data.length !== 20 || resp.nextCursor === null) {
        throw new Error(`Agy 顺序热态结果异常：len=${resp.data.length}, nextCursor=${resp.nextCursor}`);
      }
    }
    const warmSpawnsTotal = readSpawnCount(gitCounterFile);
    const warmAcpDelta = warmStack.getAcpListCalls() - acpBeforeWarm;

    batchResults.push({
      batch,
      concurrentCold: {
        runs: opts.cold,
        concurrency: opts.concurrency,
        latencyMs: {
          p50: percentile(coldLatencies, 50),
          p95: percentile(coldLatencies, 95),
          max: percentile(coldLatencies, 100),
          mean: mean(coldLatencies),
        },
        gitSpawnsPerRun: coldGitSpawns,
        gitSpawnsMean: mean(coldGitSpawns),
        gitSpawnsTotal: coldGitSpawns.reduce((a, b) => a + b, 0),
        acpListCallsPerRun: coldAcpCalls,
        returnedRowsPerCall: coldReturned,
      },
      sequentialWarm: {
        runs: opts.warm,
        latencyMs: {
          p50: percentile(warmLatencies, 50),
          p95: percentile(warmLatencies, 95),
          max: percentile(warmLatencies, 100),
          mean: mean(warmLatencies),
        },
        gitSpawnsAbsoluteTotal: warmSpawnsTotal,
        gitSpawnsPerRun: Number((warmSpawnsTotal / opts.warm).toFixed(3)),
        acpListCallsDelta: warmAcpDelta,
        returnedRowsPerCall: warmReturned,
      },
    });
  }

  const warmP95s = batchResults.map((b) => b.sequentialWarm.latencyMs.p95);
  const coldP95s = batchResults.map((b) => b.concurrentCold.latencyMs.p95);
  const variancePct = (vals: number[]) => {
    const mn = Math.min(...vals);
    const mx = Math.max(...vals);
    return mn > 0 ? Number((((mx - mn) / mn) * 100).toFixed(2)) : 0;
  };

  const report = {
    benchmark: "agy-acp-list-phase0",
    seed: opts.seed,
    config: { batches: opts.batches, cold: opts.cold, warm: opts.warm, concurrency: opts.concurrency },
    dataset: {
      totalSummaries: summaries.length,
      targetRepoSessions: 30,
      otherRepoSessions: 360,
      nonGitSessions: 50,
      missingDirSessions: 30,
      orphanSessions: 30,
      uniqueNonOrphanRawCwds: uniqueCandidateCwds.size,
      existingUniqueCwdsEligibleForGitInspect: uniqueCandidateCwds.size - missingDirs.length,
    },
    summary: {
      concurrentColdGitSpawnsMeanPerRun: mean(batchResults.map((b) => b.concurrentCold.gitSpawnsMean)),
      concurrentColdP95MsMean: mean(coldP95s),
      concurrentColdP95SpreadPct: variancePct(coldP95s),
      sequentialWarmGitSpawnsAbsoluteAcrossAllBatches: batchResults.reduce(
        (acc, b) => acc + b.sequentialWarm.gitSpawnsAbsoluteTotal,
        0,
      ),
      sequentialWarmAcpDeltaAcrossAllBatches: batchResults.reduce(
        (acc, b) => acc + b.sequentialWarm.acpListCallsDelta,
        0,
      ),
      sequentialWarmP95MsMean: mean(warmP95s),
      sequentialWarmP95SpreadPct: variancePct(warmP95s),
    },
    batches: batchResults,
  };

  if (opts.jsonOut) {
    writeFileSync(opts.jsonOut, `${JSON.stringify(report, null, 2)}\n`);
  }
  console.log(JSON.stringify(report, null, 2));
} finally {
  process.env.PATH = originalPath;
  rmSync(sandbox, { recursive: true, force: true });
}
