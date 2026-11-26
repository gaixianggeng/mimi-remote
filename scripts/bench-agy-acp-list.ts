#!/usr/bin/env bun
/**
 * Phase 0 可复跑性能基准：Antigravity (bridges/agy-acp) 目录列表
 *
 * 严格不修改任何产品源码，通过临时 PATH 下的静态真实 git 包装器精确统计 OS 级 git spawn 次数，
 * 并使用生产 `createAcpSessionBackend` + `SharedReadonlyAcp` + 受控内存 ACP 传输（`FakeAgyWorld`）
 * 驱动完整 `listSummaries`、`diskRevision`、`resolveSessionOrigin`、`inspectExternalActivity`、
 * `AgyCatalog`、`GitRepoIndex` 与 `createThreadHandlers` 链路；
 * 在确定性固定种子数据集（500 全局 / 30 目标仓，含 worktree、symlink、百分号编码路径、缺失目录、孤儿会话）
 * 上按 3 批 ×（冷 5 次并发 + 热 20 次顺序）采集基线数据。
 */
import { execFileSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { performance } from "node:perf_hooks";
import type { AcpTransport } from "../bridges/agy-acp/src/acp/client.ts";
import { SharedReadonlyAcp, type SpawnAgyTransport } from "../bridges/agy-acp/src/agy/binary.ts";
import { AgyCatalog, AgyHistoryStore, createAcpSessionBackend } from "../bridges/agy-acp/src/agy/catalog.ts";
import { resolveAgyDataPaths, type AgySessionOrigin } from "../bridges/agy-acp/src/agy/env.ts";
import { GitRepoIndex } from "../bridges/agy-acp/src/agy/git.ts";
import { AgyOverlay } from "../bridges/agy-acp/src/agy/overlay.ts";
import { createThreadHandlers } from "../bridges/agy-acp/src/handlers/threads.ts";
import { FakeAgyWorld, type FakeStoredSession } from "../bridges/agy-acp/test/support/fake-agy.ts";

interface CliOptions {
  seed: number;
  batches: number;
  cold: number;
  warm: number;
  concurrency: number;
  jsonOut?: string;
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

function parseArgs(argv: string[]): CliOptions {
  const opts: CliOptions = { seed: 20260410, batches: 3, cold: 5, warm: 20, concurrency: 4 };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = argv[i + 1];
    if (arg === "--seed") { opts.seed = parseIntArg(arg, next, 0); i += 1; }
    else if (arg === "--batches") { opts.batches = parseIntArg(arg, next, 1); i += 1; }
    else if (arg === "--cold") { opts.cold = parseIntArg(arg, next, 1); i += 1; }
    else if (arg === "--warm") { opts.warm = parseIntArg(arg, next, 1); i += 1; }
    else if (arg === "--concurrency") { opts.concurrency = parseIntArg(arg, next, 1); i += 1; }
    else if (arg === "--json-out") {
      if (!next) throw new Error("参数 --json-out 缺少输出路径");
      opts.jsonOut = next;
      i += 1;
    } else {
      throw new Error(`未知参数：${arg}`);
    }
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

const BENCHMARK_AGY_GEMINI_DIR = ".gemini";
const BENCHMARK_AGY_APP_DATA_DIR = "antigravity-cli";
const BENCHMARK_AGY_OTHER_APP_DATA_DIR = "antigravity";
const BENCHMARK_AGY_OTHER_LIST_TIMEOUT_MS = "2500";
const BENCHMARK_AGY_OTHER_LIST_HARD_TIMEOUT_MS = "12000";

function buildBenchmarkAgyEnv(homeDir: string): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (value === undefined) continue;
    if (key.startsWith("AGY_ADAPTER_") || key.startsWith("ANTIGRAVITY_") || key === "__CFBundleIdentifier") {
      continue;
    }
    env[key] = value;
  }
  env.HOME = homeDir;
  env.AGY_ADAPTER_GEMINI_DIR = BENCHMARK_AGY_GEMINI_DIR;
  env.AGY_ADAPTER_APP_DATA_DIR = BENCHMARK_AGY_APP_DATA_DIR;
  env.AGY_ADAPTER_OTHER_APP_DATA_DIR = BENCHMARK_AGY_OTHER_APP_DATA_DIR;
  env.AGY_ADAPTER_OTHER_LIST_TIMEOUT_MS = BENCHMARK_AGY_OTHER_LIST_TIMEOUT_MS;
  env.AGY_ADAPTER_OTHER_LIST_HARD_TIMEOUT_MS = BENCHMARK_AGY_OTHER_LIST_HARD_TIMEOUT_MS;
  return env;
}

function isolateGitProcessEnv(): () => void {
  const saved = new Map<string, string | undefined>();
  for (const key of Object.keys(process.env)) {
    if (key.startsWith("GIT_")) {
      saved.set(key, process.env[key]);
      delete process.env[key];
    }
  }
  const overrides: Record<string, string> = {
    GIT_CONFIG_NOSYSTEM: "1",
    GIT_CONFIG_GLOBAL: "/dev/null",
    GIT_CONFIG_SYSTEM: "/dev/null",
    GIT_TERMINAL_PROMPT: "0",
  };
  for (const [key, value] of Object.entries(overrides)) {
    if (!saved.has(key)) saved.set(key, process.env[key]);
    process.env[key] = value;
  }
  return () => {
    for (const [key, value] of saved.entries()) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  };
}

function initGitRepo(realGit: string, dir: string): void {
  mkdirSync(dir, { recursive: true });
  execFileSync(realGit, ["init", "-q", "--template=", "-b", "main"], { cwd: dir, env: process.env });
  execFileSync(
    realGit,
    [
      "-c", "user.name=Demo",
      "-c", "user.email=demo@example.invalid",
      "-c", "core.hooksPath=/dev/null",
      "-c", "commit.gpgsign=false",
      "-c", "tag.gpgsign=false",
      "commit", "-q", "--allow-empty", "-m", "init",
    ],
    { cwd: dir, env: process.env },
  );
}

function addWorktree(realGit: string, repoDir: string, wtDir: string, branch: string): void {
  execFileSync(
    realGit,
    ["-c", "core.hooksPath=/dev/null", "worktree", "add", "-q", "-b", branch, wtDir],
    { cwd: repoDir, env: process.env },
  );
}

function encodeFileUri(absPath: string): string {
  return `file://${absPath.split("/").map((seg) => encodeURIComponent(seg)).join("/")}`;
}

const STATIC_GIT_WRAPPER = `#!/bin/sh
set -eu
if [ -z "\${MIMI_BENCH_GIT_COUNTER_FILE:-}" ] || [ -z "\${MIMI_BENCH_REAL_GIT:-}" ]; then
  echo "bench git wrapper: missing required env" >&2
  exit 125
fi
if [ ! -f "$MIMI_BENCH_GIT_COUNTER_FILE" ] || [ ! -w "$MIMI_BENCH_GIT_COUNTER_FILE" ]; then
  if [ -n "\${MIMI_BENCH_GIT_ERROR_FILE:-}" ]; then
    printf 'counter_not_writable\\n' > "$MIMI_BENCH_GIT_ERROR_FILE" 2>/dev/null || true
  fi
  echo "bench git wrapper: counter file not writable" >&2
  exit 125
fi
if ! printf '1\\n' >> "$MIMI_BENCH_GIT_COUNTER_FILE"; then
  if [ -n "\${MIMI_BENCH_GIT_ERROR_FILE:-}" ]; then
    printf 'counter_append_failed\\n' > "$MIMI_BENCH_GIT_ERROR_FILE" 2>/dev/null || true
  fi
  echo "bench git wrapper: failed to write counter file" >&2
  exit 125
fi
exec "$MIMI_BENCH_REAL_GIT" "$@"
`;

function assertNoWrapperError(errorFile: string): void {
  if (existsSync(errorFile)) {
    const detail = readFileSync(errorFile, "utf8").trim();
    throw new Error(`git 包装器计数写入失败：${detail || "unknown"}`);
  }
}

function readSpawnCount(counterFile: string, errorFile: string): number {
  assertNoWrapperError(errorFile);
  const content = readFileSync(counterFile, "utf8");
  if (!content) return 0;
  const lines = content.split("\n").filter((line) => line.length > 0);
  for (const line of lines) {
    if (line !== "1") {
      throw new Error(`git 计数文件内容异常：${JSON.stringify(line)}`);
    }
  }
  return lines.length;
}

function resetSpawnCount(counterFile: string, errorFile: string): void {
  rmSync(errorFile, { force: true });
  writeFileSync(counterFile, "");
}

const opts = parseArgs(process.argv.slice(2));
const rand = mulberry32(opts.seed);
const realGit = Bun.which("git");
if (!realGit) {
  throw new Error("未在 PATH 中找到 git 可执行文件");
}

const restoreGitEnv = isolateGitProcessEnv();
const sandbox = realpathSync(mkdtempSync(path.join(os.tmpdir(), "mimi-phase0-agy-bench-")));
const originalPath = process.env.PATH ?? "";
const prevCounterEnv = process.env.MIMI_BENCH_GIT_COUNTER_FILE;
const prevErrorEnv = process.env.MIMI_BENCH_GIT_ERROR_FILE;
const prevRealGitEnv = process.env.MIMI_BENCH_REAL_GIT;

try {
  // 1. 构造静态真实 git 包装器（路径仅通过环境变量按数据传递，避免 shell 展开特殊字符）
  //    ps 进程扫描在 Phase 0 未计量（留待后续 issue），不在计时路径中插入 ps 包装器或辅助进程。
  const binDir = path.join(sandbox, "bin");
  mkdirSync(binDir, { recursive: true });
  const gitCounterFile = path.join(sandbox, "git-spawns.log");
  const gitErrorFile = path.join(sandbox, "git-wrapper.err");
  resetSpawnCount(gitCounterFile, gitErrorFile);
  const gitWrapper = path.join(binDir, "git");
  writeFileSync(gitWrapper, STATIC_GIT_WRAPPER);
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
  const cliConvDir = path.join(homeDir, BENCHMARK_AGY_GEMINI_DIR, BENCHMARK_AGY_APP_DATA_DIR, "conversations");
  const otherConvDir = path.join(homeDir, BENCHMARK_AGY_GEMINI_DIR, BENCHMARK_AGY_OTHER_APP_DATA_DIR, "conversations");
  mkdirSync(cliConvDir, { recursive: true });
  mkdirSync(otherConvDir, { recursive: true });

  const fakeSessions: FakeStoredSession[] = [];
  const expectedTargetIds = new Set<string>();
  const baseEpochSec = 1775800000;
  const targetPaths = [targetRepo, targetWt1, targetWt2, targetSymlink, targetEncodedUri];
  const uniqueCandidateCwds = new Set<string>();

  const addSession = (idx: number, cwd: string, origin: AgySessionOrigin | "orphan", isTarget: boolean) => {
    const id = `agy-bench-${String(idx).padStart(4, "0")}`;
    const offsetSec = Math.floor(rand() * 86400 * 14);
    const updatedIso = new Date((baseEpochSec + offsetSec) * 1000).toISOString();
    fakeSessions.push({
      sessionId: id,
      cwd,
      title: `Synthetic Agy Session ${idx}`,
      updatedAt: updatedIso,
      modeId: "default",
      model: "gemini-4-carbon",
      thoughtLevel: "medium",
      replayUpdates: [],
      appDataDirName: origin === "other" ? "antigravity" : "antigravity-cli",
    });
    if (isTarget) {
      expectedTargetIds.add(id);
    }
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
    addSession(i, cwd, i % 3 === 0 ? "other" : "cli", true);
  }
  // 360 其他 Git 仓及 worktree 会话
  for (let i = 30; i < 390; i += 1) {
    const cwd = otherRepos[(i - 30) % otherRepos.length]!;
    addSession(i, cwd, i % 4 === 0 ? "other" : "cli", false);
  }
  // 50 非 Git 目录会话（含编码 URI）
  for (let i = 390; i < 440; i += 1) {
    const cwd = nonGitDirs[(i - 390) % nonGitDirs.length]!;
    addSession(i, cwd, "cli", false);
  }
  // 30 缺失目录会话
  for (let i = 440; i < 470; i += 1) {
    const cwd = missingDirs[(i - 440) % missingDirs.length]!;
    addSession(i, cwd, i % 2 === 0 ? "other" : "cli", false);
  }
  // 30 孤儿会话（无 .db 文件）
  for (let i = 470; i < 500; i += 1) {
    const cwd = otherRepos[i % otherRepos.length]!;
    addSession(i, cwd, "orphan", false);
  }

  // 固定种子洗牌，模拟现网乱序摘要流
  for (let i = fakeSessions.length - 1; i > 0; i -= 1) {
    const j = Math.floor(rand() * (i + 1));
    [fakeSessions[i], fakeSessions[j]] = [fakeSessions[j]!, fakeSessions[i]!];
  }

  const agyEnv = buildBenchmarkAgyEnv(homeDir);
  const resolvedAgyPaths = resolveAgyDataPaths(agyEnv);
  const expectedCliRoot = path.join(homeDir, BENCHMARK_AGY_GEMINI_DIR, BENCHMARK_AGY_APP_DATA_DIR);
  const expectedOtherRoot = path.join(homeDir, BENCHMARK_AGY_GEMINI_DIR, BENCHMARK_AGY_OTHER_APP_DATA_DIR);
  if (
    resolvedAgyPaths.appDataRoot !== expectedCliRoot ||
    resolvedAgyPaths.otherAppDataRoot !== expectedOtherRoot
  ) {
    throw new Error(
      `Agy 基准环境路径未隔离到合成 HOME：appDataRoot=${resolvedAgyPaths.appDataRoot}, otherAppDataRoot=${resolvedAgyPaths.otherAppDataRoot}`,
    );
  }
  const stateDir = path.join(sandbox, "state");
  mkdirSync(stateDir, { recursive: true });

  const createStack = () => {
    let acpCliListRpcs = 0;
    let acpOtherListRpcs = 0;
    const world = new FakeAgyWorld({ sessions: fakeSessions });
    const countingSpawnTransport: SpawnAgyTransport = (spawnOptions): AcpTransport => {
      const transport = world.spawnTransport(spawnOptions);
      const isOther = spawnOptions.appDataDirName === BENCHMARK_AGY_OTHER_APP_DATA_DIR;
      let buf = "";
      transport.stdin.on("data", (chunk: Buffer | string) => {
        buf += typeof chunk === "string" ? chunk : chunk.toString("utf8");
        let nl = buf.indexOf("\n");
        while (nl >= 0) {
          const line = buf.slice(0, nl).trim();
          buf = buf.slice(nl + 1);
          nl = buf.indexOf("\n");
          if (!line) continue;
          try {
            const msg = JSON.parse(line) as { method?: unknown };
            if (msg.method === "session/list") {
              if (isOther) acpOtherListRpcs += 1;
              else acpCliListRpcs += 1;
            }
          } catch {
            // 忽略非 JSON 行
          }
        }
      });
      return transport;
    };

    const cliSharedAcp = new SharedReadonlyAcp(
      () => "fake-agy",
      countingSpawnTransport,
      () => agyEnv,
      BENCHMARK_AGY_APP_DATA_DIR,
    );
    const otherSharedAcp = new SharedReadonlyAcp(
      () => "fake-agy",
      countingSpawnTransport,
      () => agyEnv,
      BENCHMARK_AGY_OTHER_APP_DATA_DIR,
    );
    const backend = createAcpSessionBackend(cliSharedAcp, otherSharedAcp, () => agyEnv);
    const git = new GitRepoIndex(30_000);
    const overlay = new AgyOverlay(path.join(stateDir, "overlay.json"));
    const catalog = new AgyCatalog({ backend, git, overlay }, 1_500);
    const history = new AgyHistoryStore(catalog, backend);
    const handlers = createThreadHandlers(catalog, history);
    return {
      handlers,
      getAcpListRpcCounts: () => ({
        cli: acpCliListRpcs,
        other: acpOtherListRpcs,
        total: acpCliListRpcs + acpOtherListRpcs,
      }),
      close: async () => {
        await Promise.all([cliSharedAcp.close(), otherSharedAcp.close()]);
      },
    };
  };

  // 开启 PATH 包装并自检 git 计数器，再开始实测
  process.env.MIMI_BENCH_GIT_COUNTER_FILE = gitCounterFile;
  process.env.MIMI_BENCH_GIT_ERROR_FILE = gitErrorFile;
  process.env.MIMI_BENCH_REAL_GIT = realGit;
  process.env.PATH = `${binDir}:${originalPath}`;

  execFileSync("git", ["--version"], { env: process.env });
  const selfTestSpawns = readSpawnCount(gitCounterFile, gitErrorFile);
  if (selfTestSpawns !== 1) {
    throw new Error(`git 包装器自检失败：期望 1 次计数，实际 ${selfTestSpawns}`);
  }
  resetSpawnCount(gitCounterFile, gitErrorFile);

  // 计时循环外验证完整目标仓集合（全部 30 条，覆盖主仓、2 个 worktree、symlink 与编码 URI）
  const sanityStack = createStack();
  try {
    const seenIds = new Set<string>();
    const seenCwds = new Set<string>();
    let cursor: string | undefined;
    for (let pageIdx = 0; pageIdx < 10; pageIdx += 1) {
      const resp = await sanityStack.handlers.list({
        cwd: targetRepo,
        limit: 20,
        sortKey: "updated_at",
        sortDirection: "desc",
        ...(cursor ? { cursor } : {}),
      });
      for (const row of resp.data) {
        if (seenIds.has(row.id)) {
          throw new Error(`Agy 全量完整性校验发现重复会话：${row.id}`);
        }
        if (!expectedTargetIds.has(row.id)) {
          throw new Error(`Agy 全量完整性校验返回非目标会话：${row.id} (cwd=${row.cwd})`);
        }
        seenIds.add(row.id);
        seenCwds.add(row.cwd);
      }
      if (!resp.nextCursor) break;
      cursor = resp.nextCursor;
    }
    if (seenIds.size !== expectedTargetIds.size) {
      throw new Error(`Agy 全量完整性校验失败：期望 ${expectedTargetIds.size} 条，实际 ${seenIds.size} 条`);
    }
    for (const requiredDir of [targetRepo, targetWt1, targetWt2, targetSymlink]) {
      if (!seenCwds.has(requiredDir)) {
        throw new Error(`Agy 全量完整性校验缺少预期目录会话：${requiredDir}`);
      }
    }
    const sanityRpcs = sanityStack.getAcpListRpcCounts();
    if (sanityRpcs.cli < 1 || sanityRpcs.other < 1) {
      throw new Error(`Agy 生产后端未发出预期 CLI+Other ACP session/list RPC：${JSON.stringify(sanityRpcs)}`);
    }
  } finally {
    await sanityStack.close();
  }

  const batchResults: Array<{
    batch: number;
    concurrentCold: {
      runs: number;
      concurrency: number;
      latencyMs: { p50: number; p95: number; max: number; mean: number };
      gitSpawnsPerRun: number[];
      gitSpawnsMean: number;
      gitSpawnsTotal: number;
      acpSessionListRpcsPerRun: number[];
      acpSessionListRpcsMean: number;
      returnedRowsPerCall: number;
    };
    sequentialWarm: {
      runs: number;
      latencyMs: { p50: number; p95: number; max: number; mean: number };
      gitSpawnsAbsoluteTotal: number;
      gitSpawnsPerRun: number;
      acpSessionListRpcsDelta: number;
      acpCliRpcsDelta: number;
      acpOtherRpcsDelta: number;
      returnedRowsPerCall: number;
    };
  }> = [];

  for (let batch = 1; batch <= opts.batches; batch += 1) {
    // A. 并发冷查（清进程缓存 / 新建 SharedReadonlyAcp、GitRepoIndex 与 AgyCatalog，并发触发同仓查询）
    const coldLatencies: number[] = [];
    const coldGitSpawns: number[] = [];
    const coldAcpRpcs: number[] = [];
    let coldReturned = 0;

    for (let run = 0; run < opts.cold; run += 1) {
      const stack = createStack();
      try {
        resetSpawnCount(gitCounterFile, gitErrorFile);
        const t0 = performance.now();
        const responses = await Promise.all(
          Array.from({ length: opts.concurrency }, () =>
            stack.handlers.list({ cwd: targetRepo, limit: 20, sortKey: "updated_at", sortDirection: "desc" }),
          ),
        );
        const elapsed = performance.now() - t0;
        const spawns = readSpawnCount(gitCounterFile, gitErrorFile);
        if (spawns <= 0) {
          throw new Error(`Agy 并发冷查未记录到任何 git spawn（spawns=${spawns}）`);
        }
        const rpcs = stack.getAcpListRpcCounts();
        if (rpcs.total <= 0) {
          throw new Error(`Agy 并发冷查未记录到任何 ACP session/list RPC`);
        }
        coldLatencies.push(elapsed);
        coldGitSpawns.push(spawns);
        coldAcpRpcs.push(rpcs.total);
        coldReturned = responses[0]!.data.length;
        for (const r of responses) {
          if (r.data.length !== 20 || r.nextCursor === null) {
            throw new Error(`Agy 并发冷查结果异常：len=${r.data.length}, nextCursor=${r.nextCursor}`);
          }
        }
      } finally {
        await stack.close();
      }
    }

    // B. 顺序热态（预热 30s Git 缓存与常驻 ACP 连接后连续顺序查询）
    const warmStack = createStack();
    try {
      await warmStack.handlers.list({ cwd: targetRepo, limit: 20, sortKey: "updated_at", sortDirection: "desc" });
      resetSpawnCount(gitCounterFile, gitErrorFile);
      const acpBeforeWarm = warmStack.getAcpListRpcCounts();
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
      const warmSpawnsTotal = readSpawnCount(gitCounterFile, gitErrorFile);
      const acpAfterWarm = warmStack.getAcpListRpcCounts();

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
          acpSessionListRpcsPerRun: coldAcpRpcs,
          acpSessionListRpcsMean: mean(coldAcpRpcs),
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
          acpSessionListRpcsDelta: acpAfterWarm.total - acpBeforeWarm.total,
          acpCliRpcsDelta: acpAfterWarm.cli - acpBeforeWarm.cli,
          acpOtherRpcsDelta: acpAfterWarm.other - acpBeforeWarm.other,
          returnedRowsPerCall: warmReturned,
        },
      });
    } finally {
      await warmStack.close();
    }
  }

  const variancePct = (vals: number[]) => {
    const mn = Math.min(...vals);
    const mx = Math.max(...vals);
    return mn > 0 ? Number((((mx - mn) / mn) * 100).toFixed(2)) : 0;
  };

  const coldP95s = batchResults.map((b) => b.concurrentCold.latencyMs.p95);
  const warmP95s = batchResults.map((b) => b.sequentialWarm.latencyMs.p95);
  const coldP95Mean = mean(coldP95s);
  const coldP95Spread = variancePct(coldP95s);
  const warmP95Mean = mean(warmP95s);
  const warmP95Spread = variancePct(warmP95s);
  const processScanNote = "Phase 0 未计量，留待后续 issue";

  const report = {
    benchmark: "agy-acp-list-phase0",
    backendScope: "production createAcpSessionBackend + SharedReadonlyAcp + AcpClient + AgyCatalog + GitRepoIndex + createThreadHandlers over controlled in-memory ACP transport (excludes upstream agy daemon SQLite/RPC I/O; process scan unmeasured in Phase 0)",
    seed: opts.seed,
    config: { batches: opts.batches, cold: opts.cold, warm: opts.warm, concurrency: opts.concurrency },
    dataset: {
      totalSummaries: fakeSessions.length,
      targetRepoSessions: 30,
      otherRepoSessions: 360,
      nonGitSessions: 50,
      missingDirSessions: 30,
      orphanSessions: 30,
      uniqueNonOrphanRawCwds: uniqueCandidateCwds.size,
      existingUniqueCwdsEligibleForGitInspect: uniqueCandidateCwds.size - missingDirs.length,
    },
    processScan: {
      status: "unmeasured",
      note: processScanNote,
      affectsPhase1Comparison: false,
    },
    summary: {
      processScanStatus: "unmeasured",
      concurrentColdGitSpawnsMeanPerRun: mean(batchResults.map((b) => b.concurrentCold.gitSpawnsMean)),
      concurrentColdAcpRpcsMeanPerRun: mean(batchResults.map((b) => b.concurrentCold.acpSessionListRpcsMean)),
      concurrentColdP95MsMean: coldP95Mean,
      concurrentColdP95SpreadPct: coldP95Spread,
      sequentialWarmGitSpawnsAbsoluteAcrossAllBatches: batchResults.reduce(
        (acc, b) => acc + b.sequentialWarm.gitSpawnsAbsoluteTotal,
        0,
      ),
      sequentialWarmAcpRpcsDeltaAcrossAllBatches: batchResults.reduce(
        (acc, b) => acc + b.sequentialWarm.acpSessionListRpcsDelta,
        0,
      ),
      sequentialWarmP95MsMean: warmP95Mean,
      sequentialWarmP95SpreadPct: warmP95Spread,
      phase1Comparison: {
        eligible: true,
        status: "valid",
        dependsOnProcessScan: false,
        processScanStatus: "unmeasured",
        processScanNote,
        concurrentColdP95MsMean: coldP95Mean,
        concurrentColdP95SpreadPct: coldP95Spread,
        sequentialWarmP95MsMean: warmP95Mean,
        sequentialWarmP95SpreadPct: warmP95Spread,
      },
    },
    batches: batchResults,
  };

  if (opts.jsonOut) {
    writeFileSync(opts.jsonOut, `${JSON.stringify(report, null, 2)}\n`);
  }
  console.log(JSON.stringify(report, null, 2));
} finally {
  process.env.PATH = originalPath;
  if (prevCounterEnv === undefined) delete process.env.MIMI_BENCH_GIT_COUNTER_FILE;
  else process.env.MIMI_BENCH_GIT_COUNTER_FILE = prevCounterEnv;
  if (prevErrorEnv === undefined) delete process.env.MIMI_BENCH_GIT_ERROR_FILE;
  else process.env.MIMI_BENCH_GIT_ERROR_FILE = prevErrorEnv;
  if (prevRealGitEnv === undefined) delete process.env.MIMI_BENCH_REAL_GIT;
  else process.env.MIMI_BENCH_REAL_GIT = prevRealGitEnv;
  restoreGitEnv();
  rmSync(sandbox, { recursive: true, force: true });
}
