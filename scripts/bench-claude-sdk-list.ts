#!/usr/bin/env bun
/**
 * Phase 0 可复跑性能基准：Claude SDK (bridges/claude-sdk) 200+ 会话分页
 *
 * 严格不修改任何产品源码，使用真实 @anthropic-ai/claude-agent-sdk listSessions、
 * TranscriptIndex、ActivityClock、WorkingDirectories、Overlay 与 createThreadHandlers，
 * 在隔离临时 CLAUDE_CONFIG_DIR 上构造固定种子 240 目标仓会话（+ 40 其他项目会话），
 * 按 3 批 ×（冷 5 次 + 热 20 次）测量热态次页合并（pooled）p95 及目录处理（sessions.list + toRecord + sort）耗时占比。
 */
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { performance } from "node:perf_hooks";
import { Catalog, HistoryStore, type CatalogDeps, type SessionRecord } from "../bridges/claude-sdk/src/claude/catalog.ts";
import { Overlay } from "../bridges/claude-sdk/src/claude/overlay.ts";
import { sdkSessions, type ClaudeSessions } from "../bridges/claude-sdk/src/claude/sdk.ts";
import { ActivityClock, TranscriptIndex, WorkingDirectories } from "../bridges/claude-sdk/src/claude/transcripts.ts";
import { createThreadHandlers, type LiveSource } from "../bridges/claude-sdk/src/handlers/threads.ts";
import { TranscriptBuilder } from "../bridges/claude-sdk/test/support/transcripts.ts";

interface CliOptions {
  seed: number;
  batches: number;
  cold: number;
  warm: number;
  targetSessions: number;
  otherSessions: number;
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
  const opts: CliOptions = {
    seed: 20260410,
    batches: 3,
    cold: 5,
    warm: 20,
    targetSessions: 240,
    otherSessions: 40,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = argv[i + 1];
    if (arg === "--seed") { opts.seed = parseIntArg(arg, next, 0); i += 1; }
    else if (arg === "--batches") { opts.batches = parseIntArg(arg, next, 1); i += 1; }
    else if (arg === "--cold") { opts.cold = parseIntArg(arg, next, 1); i += 1; }
    else if (arg === "--warm") { opts.warm = parseIntArg(arg, next, 1); i += 1; }
    else if (arg === "--target-sessions") { opts.targetSessions = parseIntArg(arg, next, 200); i += 1; }
    else if (arg === "--other-sessions") { opts.otherSessions = parseIntArg(arg, next, 0); i += 1; }
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

function deterministicUuid(index: number): string {
  const hex = index.toString(16).padStart(12, "0");
  return `10000000-0000-4000-8000-${hex}`;
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

function initGitRepo(dir: string): void {
  mkdirSync(dir, { recursive: true });
  execFileSync("git", ["init", "-q", "--template=", "-b", "main"], { cwd: dir, env: process.env });
  execFileSync(
    "git",
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

interface PhaseTiming {
  totalMs: number;
  prepareMs: number;
  sessionsListMs: number;
  toRecordMs: number;
  filterSortCursorMs: number;
  liveAndToThreadMs: number;
  catalogProcessingMs: number; // sessions.list + toRecord + filter/sort
  catalogProcessingSharePct: number;
}

const opts = parseArgs(process.argv.slice(2));
const rand = mulberry32(opts.seed);
const restoreGitEnv = isolateGitProcessEnv();
const sandbox = realpathSync(mkdtempSync(path.join(os.tmpdir(), "mimi-phase0-claude-bench-")));
const prevClaudeConfigDir = process.env.CLAUDE_CONFIG_DIR;
const prevLegacyIndex = process.env.MIMI_CLAUDE_LEGACY_INDEX;

try {
  const configDir = path.join(sandbox, "claude");
  const stateDir = path.join(sandbox, "state");
  mkdirSync(configDir, { recursive: true });
  mkdirSync(stateDir, { recursive: true });

  const targetRepo = path.join(sandbox, "target-repo");
  const targetWt1 = path.join(sandbox, "target-wt-1");
  const targetWt2 = path.join(sandbox, "target-wt-2");
  const otherRepo = path.join(sandbox, "other-repo");
  initGitRepo(targetRepo);
  execFileSync("git", ["-c", "core.hooksPath=/dev/null", "worktree", "add", "-q", "-b", "wt-1", targetWt1], {
    cwd: targetRepo,
    env: process.env,
  });
  execFileSync("git", ["-c", "core.hooksPath=/dev/null", "worktree", "add", "-q", "-b", "wt-2", targetWt2], {
    cwd: targetRepo,
    env: process.env,
  });
  initGitRepo(otherRepo);

  const baseMs = Date.parse("2026-04-01T00:00:00.000Z");
  const targetCwds = [targetRepo, targetRepo, targetRepo, targetRepo, targetWt1, targetWt2];
  const expectedTargetIds = new Set<string>();
  const expectedTargetCountsByCwd = new Map<string, number>([
    [targetRepo, 0],
    [targetWt1, 0],
    [targetWt2, 0],
  ]);

  const writeSyntheticSession = (idx: number, cwd: string, branch: string): string => {
    const sid = deterministicUuid(idx + 1);
    const startMs = baseMs + Math.floor(rand() * 86400 * 20) * 1000;
    const turns = 2 + Math.floor(rand() * 6);
    const b = new TranscriptBuilder(sid, cwd, branch, startMs);
    for (let t = 0; t < turns; t += 1) {
      b.user(`Synthetic benchmark prompt ${idx} turn ${t}`);
      b.assistant([{ type: "text", text: `Synthetic benchmark reply ${idx} turn ${t}` }]);
    }
    if (idx % 3 === 0) {
      b.title(`Demo Session ${idx}`);
    }
    b.write(configDir);
    return sid;
  };

  for (let i = 0; i < opts.targetSessions; i += 1) {
    const cwd = targetCwds[i % targetCwds.length]!;
    const branch = cwd === targetWt1 ? "wt-1" : cwd === targetWt2 ? "wt-2" : "main";
    const sid = writeSyntheticSession(i, cwd, branch);
    expectedTargetIds.add(sid);
    expectedTargetCountsByCwd.set(cwd, (expectedTargetCountsByCwd.get(cwd) ?? 0) + 1);
  }
  for (let i = 0; i < opts.otherSessions; i += 1) {
    writeSyntheticSession(opts.targetSessions + i, otherRepo, "main");
  }

  process.env.CLAUDE_CONFIG_DIR = configDir;
  process.env.MIMI_CLAUDE_LEGACY_INDEX = "";

  const createInstrumentedStack = () => {
    const transcripts = new TranscriptIndex();
    const activity = new ActivityClock();
    const directories = new WorkingDirectories();
    const overlay = new Overlay(path.join(stateDir, "overlay.json"));

    let lastCatalogStart = 0;
    let lastPrepareEnd = 0;
    let lastSessionsListMs = 0;
    let lastCatalogEnd = 0;
    let lastHoldersStart = 0;

    // 包装 TranscriptIndex.refresh 以精确记录 prepare 结束时刻（不改源码）
    const origRefresh = transcripts.refresh.bind(transcripts);
    transcripts.refresh = async (force?: boolean) => {
      await origRefresh(force);
    };

    const timedSessions: ClaudeSessions = {
      async list(options) {
        lastPrepareEnd = performance.now();
        const t0 = performance.now();
        const res = await sdkSessions.list(options);
        lastSessionsListMs += performance.now() - t0;
        return res;
      },
      info: (sid) => sdkSessions.info(sid),
      messages: (sid) => sdkSessions.messages(sid),
      rename: (sid, title, dir) => sdkSessions.rename(sid, title, dir),
    };

    const deps: CatalogDeps = {
      sessions: timedSessions,
      transcripts,
      activity,
      directories,
      overlay,
    };
    const rawCatalog = new Catalog(deps);
    const timedCatalog = Object.create(rawCatalog) as Catalog;
    timedCatalog.list = async (dirs?: readonly string[]): Promise<SessionRecord[]> => {
      lastCatalogStart = performance.now();
      lastPrepareEnd = lastCatalogStart;
      lastSessionsListMs = 0;
      const res = await rawCatalog.list(dirs);
      lastCatalogEnd = performance.now();
      return res;
    };

    const liveSource: LiveSource = {
      async holders() {
        lastHoldersStart = performance.now();
        return new Map();
      },
      activeTurnId: () => undefined,
      hasLiveProcess: () => false,
      loadedThreadIds: () => [],
    };

    const history = new HistoryStore({ sessions: sdkSessions, transcripts, overlay });
    const handlers = createThreadHandlers(timedCatalog, history, liveSource);

    const runTimedList = async (params: Record<string, unknown>) => {
      lastCatalogStart = 0;
      lastPrepareEnd = 0;
      lastSessionsListMs = 0;
      lastCatalogEnd = 0;
      lastHoldersStart = 0;
      const t0 = performance.now();
      const response = await handlers.list(params);
      const tEnd = performance.now();

      const totalMs = tEnd - t0;
      const prepareMs = Math.max(0, lastPrepareEnd - lastCatalogStart);
      const sessionsListMs = Math.max(0, lastSessionsListMs);
      const catalogTotalMs = Math.max(0, lastCatalogEnd - lastCatalogStart);
      const toRecordMs = Math.max(0, catalogTotalMs - prepareMs - sessionsListMs);
      const filterSortCursorMs = Math.max(0, lastHoldersStart - lastCatalogEnd);
      const liveAndToThreadMs = Math.max(0, tEnd - lastHoldersStart);
      const catalogProcessingMs = sessionsListMs + toRecordMs + filterSortCursorMs;
      const catalogProcessingSharePct = totalMs > 0 ? (catalogProcessingMs / totalMs) * 100 : 0;

      const timing: PhaseTiming = {
        totalMs,
        prepareMs,
        sessionsListMs,
        toRecordMs,
        filterSortCursorMs,
        liveAndToThreadMs,
        catalogProcessingMs,
        catalogProcessingSharePct,
      };
      return { response, timing };
    };

    return { runTimedList };
  };

  // 计时循环外翻完全部页面，验证完整预期会话集（>= 200 且精确包含主仓与全部 worktree 会话）
  const sanity = createInstrumentedStack();
  const seenIds = new Set<string>();
  const actualCountsByCwd = new Map<string, number>();
  let page2Cursor: string | null = null;
  let cursor: string | undefined;
  const maxPages = Math.ceil(opts.targetSessions / 20) + 5;
  for (let page = 1; page <= maxPages; page += 1) {
    const res = await sanity.runTimedList({
      cwd: targetRepo,
      limit: 20,
      sortKey: "updated_at",
      sortDirection: "desc",
      ...(cursor ? { cursor } : {}),
    });
    if (page === 1) {
      if (res.response.data.length !== 20 || !res.response.nextCursor) {
        throw new Error(`Claude SDK 首页夹具异常：len=${res.response.data.length}, nextCursor=${res.response.nextCursor}`);
      }
      page2Cursor = res.response.nextCursor;
    }
    for (const row of res.response.data) {
      if (seenIds.has(row.id)) {
        throw new Error(`Claude SDK 全量分页校验发现重复会话：${row.id}`);
      }
      if (!expectedTargetIds.has(row.id)) {
        throw new Error(`Claude SDK 全量分页校验返回非目标会话：${row.id} (cwd=${row.cwd})`);
      }
      seenIds.add(row.id);
      actualCountsByCwd.set(row.cwd, (actualCountsByCwd.get(row.cwd) ?? 0) + 1);
    }
    if (!res.response.nextCursor) break;
    cursor = res.response.nextCursor;
  }
  if (seenIds.size !== opts.targetSessions || seenIds.size < 200) {
    throw new Error(
      `Claude SDK 目标会话全集校验失败：期望 ${opts.targetSessions}（>= 200），实际仅匹配 ${seenIds.size}`,
    );
  }
  for (const [cwd, expectedCount] of expectedTargetCountsByCwd.entries()) {
    const actualCount = actualCountsByCwd.get(cwd) ?? 0;
    if (actualCount !== expectedCount) {
      throw new Error(`Claude SDK 目录归并校验失败（${cwd}）：期望 ${expectedCount}，实际 ${actualCount}`);
    }
  }
  if (!page2Cursor) {
    throw new Error("Claude SDK 未产出第 2 页游标");
  }

  const summarizeTimings = (items: PhaseTiming[]) => {
    const totals = items.map((x) => x.totalMs);
    const prep = items.map((x) => x.prepareMs);
    const sList = items.map((x) => x.sessionsListMs);
    const toRec = items.map((x) => x.toRecordMs);
    const sort = items.map((x) => x.filterSortCursorMs);
    const live = items.map((x) => x.liveAndToThreadMs);
    const proc = items.map((x) => x.catalogProcessingMs);
    const sumTotal = totals.reduce((a, b) => a + b, 0);
    const sumProc = proc.reduce((a, b) => a + b, 0);
    const sumPrepAndProc = items.reduce((a, x) => a + x.prepareMs + x.catalogProcessingMs, 0);
    return {
      runs: items.length,
      totalMs: { p50: percentile(totals, 50), p95: percentile(totals, 95), max: percentile(totals, 100), mean: mean(totals) },
      breakdownMeanMs: {
        prepare: mean(prep),
        sessionsList: mean(sList),
        toRecord: mean(toRec),
        filterSortCursor: mean(sort),
        liveAndToThread: mean(live),
        catalogProcessing: mean(proc),
      },
      catalogProcessingSharePct: sumTotal > 0 ? Number(((sumProc / sumTotal) * 100).toFixed(2)) : 0,
      preparePlusCatalogSharePct: sumTotal > 0 ? Number(((sumPrepAndProc / sumTotal) * 100).toFixed(2)) : 0,
    };
  };

  const batchResults: Array<{
    batch: number;
    coldPage1: ReturnType<typeof summarizeTimings>;
    coldPage2: ReturnType<typeof summarizeTimings>;
    warmPage2: ReturnType<typeof summarizeTimings>;
  }> = [];
  const allWarmP2Timings: PhaseTiming[] = [];

  for (let batch = 1; batch <= opts.batches; batch += 1) {
    const coldP1: PhaseTiming[] = [];
    const coldP2: PhaseTiming[] = [];
    for (let run = 0; run < opts.cold; run += 1) {
      const stack = createInstrumentedStack();
      const r1 = await stack.runTimedList({ cwd: targetRepo, limit: 20, sortKey: "updated_at", sortDirection: "desc" });
      if (r1.response.data.length !== 20 || !r1.response.nextCursor) {
        throw new Error(`冷态第 1 页返回异常：len=${r1.response.data.length}`);
      }
      coldP1.push(r1.timing);
      const r2 = await stack.runTimedList({
        cwd: targetRepo,
        limit: 20,
        sortKey: "updated_at",
        sortDirection: "desc",
        cursor: r1.response.nextCursor,
      });
      if (r2.response.data.length !== 20 || !r2.response.nextCursor) {
        throw new Error(`冷态第 2 页返回异常：len=${r2.response.data.length}`);
      }
      coldP2.push(r2.timing);
    }

    // 热态：先预热首页与次页，再连续执行 opts.warm 次热态第 2 页查询
    const warmStack = createInstrumentedStack();
    const warmP1 = await warmStack.runTimedList({ cwd: targetRepo, limit: 20, sortKey: "updated_at", sortDirection: "desc" });
    const warmCursor = warmP1.response.nextCursor ?? page2Cursor;
    await warmStack.runTimedList({ cwd: targetRepo, limit: 20, sortKey: "updated_at", sortDirection: "desc", cursor: warmCursor });

    const warmP2: PhaseTiming[] = [];
    for (let run = 0; run < opts.warm; run += 1) {
      const r2 = await warmStack.runTimedList({
        cwd: targetRepo,
        limit: 20,
        sortKey: "updated_at",
        sortDirection: "desc",
        cursor: warmCursor,
      });
      if (r2.response.data.length !== 20 || !r2.response.nextCursor) {
        throw new Error(`热态第 2 页返回异常：len=${r2.response.data.length}`);
      }
      warmP2.push(r2.timing);
      allWarmP2Timings.push(r2.timing);
    }

    batchResults.push({
      batch,
      coldPage1: summarizeTimings(coldP1),
      coldPage2: summarizeTimings(coldP2),
      warmPage2: summarizeTimings(warmP2),
    });
  }

  const pooledWarm = summarizeTimings(allWarmP2Timings);
  const warmP95s = batchResults.map((b) => b.warmPage2.totalMs.p95);
  const warmShares = batchResults.map((b) => b.warmPage2.catalogProcessingSharePct);
  const warmP95BatchMean = mean(warmP95s);
  const warmShareBatchMean = mean(warmShares);
  const spreadPct = (() => {
    const mn = Math.min(...warmP95s);
    const mx = Math.max(...warmP95s);
    return mn > 0 ? Number((((mx - mn) / mn) * 100).toFixed(2)) : 0;
  })();

  const report = {
    benchmark: "claude-sdk-list-phase0",
    seed: opts.seed,
    config: { batches: opts.batches, cold: opts.cold, warm: opts.warm },
    dataset: {
      targetRepoSessions: opts.targetSessions,
      verifiedTargetRepoSessions: seenIds.size,
      verifiedByDirectory: Object.fromEntries(
        [...expectedTargetCountsByCwd.keys()].map((dir) => [path.basename(dir), actualCountsByCwd.get(dir) ?? 0]),
      ),
      otherRepoSessions: opts.otherSessions,
      totalTranscriptFiles: opts.targetSessions + opts.otherSessions,
      pageSize: 20,
    },
    thresholdEvaluation: {
      rule: "pooled warmPage2.p95 (across all warm runs) > 30ms AND pooled catalogProcessingSharePct (sessions.list + toRecord + sort) > 50%",
      warmPage2RunsPooled: pooledWarm.runs,
      warmPage2P95MsPooled: pooledWarm.totalMs.p95,
      warmPage2P95MsBatchMean: warmP95BatchMean,
      warmPage2P95MsMaxAcrossBatches: Math.max(...warmP95s),
      warmPage2P95SpreadPct: spreadPct,
      catalogProcessingSharePctPooled: pooledWarm.catalogProcessingSharePct,
      catalogProcessingSharePctBatchMean: warmShareBatchMean,
      triggered: pooledWarm.totalMs.p95 > 30 && pooledWarm.catalogProcessingSharePct > 50,
    },
    batches: batchResults,
  };

  if (opts.jsonOut) {
    writeFileSync(opts.jsonOut, `${JSON.stringify(report, null, 2)}\n`);
  }
  console.log(JSON.stringify(report, null, 2));
} finally {
  if (prevClaudeConfigDir === undefined) delete process.env.CLAUDE_CONFIG_DIR;
  else process.env.CLAUDE_CONFIG_DIR = prevClaudeConfigDir;
  if (prevLegacyIndex === undefined) delete process.env.MIMI_CLAUDE_LEGACY_INDEX;
  else process.env.MIMI_CLAUDE_LEGACY_INDEX = prevLegacyIndex;
  restoreGitEnv();
  rmSync(sandbox, { recursive: true, force: true });
}
