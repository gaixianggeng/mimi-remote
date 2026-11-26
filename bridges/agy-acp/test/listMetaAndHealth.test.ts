import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { chmod, lstat, mkdir, mkdtemp, readdir, rm, stat, symlink, writeFile, access } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { PassThrough } from "node:stream";
import { Session } from "@mimi/appserver-kit/session/session.ts";
import type { AcpSessionSummary } from "../src/acp/types.ts";
import {
  AgyCatalog,
  AgyHistoryStore,
  createAcpSessionBackend,
  type AgyListSummariesResult,
  type AgySessionBackend,
  type AgyThreadListMeta,
} from "../src/agy/catalog.ts";
import {
  createBatchSessionOriginResolver,
  probeOtherConversations,
  resolveSessionOrigin,
  type ProbeFsOps,
} from "../src/agy/env.ts";
import { GitRepoIndex, MAX_CONCURRENT_GIT_INSPECT } from "../src/agy/git.ts";
import { AgyOverlay } from "../src/agy/overlay.ts";
import { createApp } from "../src/app.ts";
import { createThreadHandlers, type AgyThreadListResponse } from "../src/handlers/threads.ts";
import { SharedReadonlyAcp } from "../src/agy/binary.ts";
import { FakeAgyWorld, type FakeStoredSession } from "./support/fake-agy.ts";

const silentLog = () => {};

function envForHome(homeDir: string, extra: Record<string, string> = {}): NodeJS.ProcessEnv {
  return {
    HOME: homeDir,
    AGY_ADAPTER_GEMINI_DIR: ".gemini",
    AGY_ADAPTER_APP_DATA_DIR: "antigravity-cli",
    AGY_ADAPTER_OTHER_APP_DATA_DIR: "antigravity",
    ...extra,
  };
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

function assertListMetaWhitelist(meta: AgyThreadListMeta): void {
  const keys = Object.keys(meta).sort();
  expect(meta).not.toHaveProperty("pageDisposition");
  expect(meta).not.toHaveProperty("retryReason");
  expect(meta.schemaVersion).toBe(1);
  if (meta.complete) {
    expect(keys).toEqual(["complete", "schemaVersion", "sources"]);
  } else {
    expect(keys).toEqual(["complete", "degradedReason", "degradedSources", "schemaVersion"]);
    expect(meta.degradedSources).toEqual(["other"]);
  }
}

describe("PR 1a-1: Agy listMeta, health probe, timestamps, git concurrency & pagination", () => {
  test("probeOtherConversations classifies all 4 states and distinguishes genuine missing dir from dangling symlinks", async () => {
    const tmp = await mkdtemp(path.join(os.tmpdir(), "agy-1a1-probe-"));
    const restoreModes: Array<{ target: string; mode: number }> = [];
    try {
      // 1) absent_or_empty: same root config
      const sameRootEnv = envForHome(path.join(tmp, "h-same"), {
        AGY_ADAPTER_OTHER_APP_DATA_DIR: "antigravity-cli",
      });
      expect(await probeOtherConversations(sameRootEnv)).toBe("absent_or_empty");

      // 2) absent_or_empty: genuinely missing otherAppDataRoot
      const missingRootHome = path.join(tmp, "h-missing-root");
      await mkdir(missingRootHome, { recursive: true });
      expect(await probeOtherConversations(envForHome(missingRootHome))).toBe("absent_or_empty");

      // 3) absent_or_empty: otherAppDataRoot exists, conversations subdir genuinely missing
      const missingSubHome = path.join(tmp, "h-missing-sub");
      await mkdir(path.join(missingSubHome, ".gemini", "antigravity"), { recursive: true });
      expect(await probeOtherConversations(envForHome(missingSubHome))).toBe("absent_or_empty");

      // 4) absent_or_empty: empty conversations dir or non-.db files only
      const emptyDirHome = path.join(tmp, "h-empty");
      const emptyConv = path.join(emptyDirHome, ".gemini", "antigravity", "conversations");
      await mkdir(emptyConv, { recursive: true });
      expect(await probeOtherConversations(envForHome(emptyDirHome))).toBe("absent_or_empty");
      await writeFile(path.join(emptyConv, "notes.txt"), "not a db");
      expect(await probeOtherConversations(envForHome(emptyDirHome))).toBe("absent_or_empty");

      // 5) present: readable dir with .db & valid symlink to readable dir with .db
      await writeFile(path.join(emptyConv, "s1.db"), "");
      expect(await probeOtherConversations(envForHome(emptyDirHome))).toBe("present");

      const validLinkHome = path.join(tmp, "h-valid-link");
      await mkdir(path.join(validLinkHome, ".gemini", "antigravity"), { recursive: true });
      await symlink(emptyConv, path.join(validLinkHome, ".gemini", "antigravity", "conversations"));
      expect(await probeOtherConversations(envForHome(validLinkHome))).toBe("present");

      // 6) io_error: dangling symlink at conversations (returns ENOENT on access/readdir!)
      const danglingConvHome = path.join(tmp, "h-dangling-conv");
      await mkdir(path.join(danglingConvHome, ".gemini", "antigravity"), { recursive: true });
      await symlink(
        path.join(tmp, "does-not-exist-target"),
        path.join(danglingConvHome, ".gemini", "antigravity", "conversations"),
      );
      expect(await probeOtherConversations(envForHome(danglingConvHome))).toBe("io_error");

      // 7) io_error: dangling symlink at otherAppDataRoot (lstat(conversations) returns ENOENT!)
      const danglingRootHome = path.join(tmp, "h-dangling-root");
      await mkdir(path.join(danglingRootHome, ".gemini"), { recursive: true });
      await symlink(
        path.join(tmp, "does-not-exist-root"),
        path.join(danglingRootHome, ".gemini", "antigravity"),
      );
      expect(await probeOtherConversations(envForHome(danglingRootHome))).toBe("io_error");

      // 8) io_error: conversations is a regular file (ENOTDIR), or symlink to a 0644 regular file
      const fileConvHome = path.join(tmp, "h-file-conv");
      await mkdir(path.join(fileConvHome, ".gemini", "antigravity"), { recursive: true });
      const regularFile = path.join(fileConvHome, ".gemini", "antigravity", "conversations");
      await writeFile(regularFile, "not a directory", { mode: 0o644 });
      expect(await probeOtherConversations(envForHome(fileConvHome))).toBe("io_error");

      const symlinkToFileHome = path.join(tmp, "h-symlink-to-file");
      await mkdir(path.join(symlinkToFileHome, ".gemini", "antigravity"), { recursive: true });
      await symlink(regularFile, path.join(symlinkToFileHome, ".gemini", "antigravity", "conversations"));
      expect(await probeOtherConversations(envForHome(symlinkToFileHome))).toBe("io_error");

      // 9) io_error: simulated EIO / EMFILE via ProbeFsOps
      const eioOps: ProbeFsOps = {
        access,
        lstat: async () => {
          const err = Object.assign(new Error("simulated EIO"), { code: "EIO" });
          throw err;
        },
        readdir,
        stat,
      };
      expect(await probeOtherConversations(envForHome(emptyDirHome), eioOps)).toBe("io_error");

      const emfileOps: ProbeFsOps = {
        access,
        lstat,
        stat,
        readdir: (async () => {
          const err = Object.assign(new Error("simulated EMFILE"), { code: "EMFILE" });
          throw err;
        }) as unknown as typeof readdir,
      };
      expect(await probeOtherConversations(envForHome(emptyDirHome), emfileOps)).toBe("io_error");

      // 10) permission_denied: 0111, 0444, 0000 on conversations & 0444 on otherAppDataRoot
      if (process.getuid?.() !== 0) {
        for (const mode of [0o111, 0o444, 0o000]) {
          const permHome = path.join(tmp, `h-perm-${mode.toString(8)}`);
          const permConv = path.join(permHome, ".gemini", "antigravity", "conversations");
          await mkdir(permConv, { recursive: true });
          await writeFile(path.join(permConv, "s1.db"), "");
          await chmod(permConv, mode);
          restoreModes.push({ target: permConv, mode: 0o755 });
          expect(await probeOtherConversations(envForHome(permHome))).toBe("permission_denied");
        }

        const parentPermHome = path.join(tmp, "h-parent-0444");
        const parentRoot = path.join(parentPermHome, ".gemini", "antigravity");
        await mkdir(path.join(parentRoot, "conversations"), { recursive: true });
        await chmod(parentRoot, 0o444);
        restoreModes.push({ target: parentRoot, mode: 0o755 });
        expect(await probeOtherConversations(envForHome(parentPermHome))).toBe("permission_denied");
      }
    } finally {
      for (const item of restoreModes.reverse()) {
        await chmod(item.target, item.mode).catch(() => {});
      }
      await rm(tmp, { recursive: true, force: true });
    }
  });

  test("batch session origin resolver matches per-file resolveSessionOrigin under 0444, 0111, 0000, and dangling symlinks", async () => {
    const tmp = await mkdtemp(path.join(os.tmpdir(), "agy-1a1-origin-"));
    const restoreModes: Array<{ target: string; mode: number }> = [];
    try {
      const checkEquivalence = async (env: NodeJS.ProcessEnv, ids: readonly string[]) => {
        const batchResolve = await createBatchSessionOriginResolver(env);
        for (const id of ids) {
          const expected = await resolveSessionOrigin(id, env);
          const actual = await batchResolve(id);
          expect(actual).toBe(expected);
        }
      };

      // Case A: normal files, valid symlink, dangling .db symlink, orphan
      const homeA = path.join(tmp, "home-a");
      const cliA = path.join(homeA, ".gemini", "antigravity-cli", "conversations");
      const otherA = path.join(homeA, ".gemini", "antigravity", "conversations");
      await mkdir(cliA, { recursive: true });
      await mkdir(otherA, { recursive: true });
      const realTarget = path.join(tmp, "real-target.db");
      await writeFile(realTarget, "");
      await writeFile(path.join(cliA, "cli-1.db"), "");
      await writeFile(path.join(otherA, "other-1.db"), "");
      await symlink(realTarget, path.join(cliA, "valid-link.db"));
      await symlink(path.join(tmp, "missing-target.db"), path.join(cliA, "dangling-link.db"));
      await symlink(path.join(tmp, "missing-other.db"), path.join(otherA, "dangling-other.db"));

      const envA = envForHome(homeA);
      await checkEquivalence(envA, ["cli-1", "other-1", "valid-link", "dangling-link", "dangling-other", "orphan-1"]);
      const batchA = await createBatchSessionOriginResolver(envA);
      expect(await batchA("cli-1")).toBe("cli");
      expect(await batchA("other-1")).toBe("other");
      expect(await batchA("valid-link")).toBe("cli");
      expect(await batchA("dangling-link")).toBeNull();
      expect(await batchA("dangling-other")).toBeNull();
      expect(await batchA("orphan-1")).toBeNull();

      // Case B: dangling conversations directory symlink
      const homeDanglingDir = path.join(tmp, "home-dangling-dir");
      await mkdir(path.join(homeDanglingDir, ".gemini", "antigravity-cli"), { recursive: true });
      await symlink(
        path.join(tmp, "no-such-dir"),
        path.join(homeDanglingDir, ".gemini", "antigravity-cli", "conversations"),
      );
      await checkEquivalence(envForHome(homeDanglingDir), ["cli-1", "other-1"]);

      // Case C: 0444 (no X_OK -> inaccessible), 0111 (X_OK ok, readdir denied -> fallback access), 0000
      if (process.getuid?.() !== 0) {
        for (const mode of [0o444, 0o111, 0o000]) {
          const homePerm = path.join(tmp, `home-perm-${mode.toString(8)}`);
          const cliPerm = path.join(homePerm, ".gemini", "antigravity-cli", "conversations");
          const otherPerm = path.join(homePerm, ".gemini", "antigravity", "conversations");
          await mkdir(cliPerm, { recursive: true });
          await mkdir(otherPerm, { recursive: true });
          await writeFile(path.join(cliPerm, "s-cli.db"), "");
          await writeFile(path.join(otherPerm, "s-other.db"), "");
          await chmod(cliPerm, mode);
          await chmod(otherPerm, mode);
          restoreModes.push({ target: cliPerm, mode: 0o755 }, { target: otherPerm, mode: 0o755 });

          const envPerm = envForHome(homePerm);
          await checkEquivalence(envPerm, ["s-cli", "s-other", "missing"]);
          const batchPerm = await createBatchSessionOriginResolver(envPerm);
          if (mode === 0o111) {
            expect(await batchPerm("s-cli")).toBe("cli");
            expect(await batchPerm("s-other")).toBe("other");
          } else {
            expect(await batchPerm("s-cli")).toBeNull();
            expect(await batchPerm("s-other")).toBeNull();
          }
        }
      }
    } finally {
      for (const item of restoreModes.reverse()) {
        await chmod(item.target, item.mode).catch(() => {});
      }
      await rm(tmp, { recursive: true, force: true });
    }
  });

  test("concurrent listSummaries calls keep independent listMeta without race pollution or whitewashing", async () => {
    const tmp = await mkdtemp(path.join(os.tmpdir(), "agy-1a1-race-"));
    try {
      const workspaceDir = path.join(tmp, "ws");
      await mkdir(workspaceDir, { recursive: true });

      const healthySummary: AcpSessionSummary = {
        sessionId: "s-healthy",
        cwd: workspaceDir,
        title: "Healthy",
        updatedAt: "2026-11-22T01:00:00Z",
      };
      const degradedSummary: AcpSessionSummary = {
        sessionId: "s-degraded",
        cwd: workspaceDir,
        title: "Degraded",
        updatedAt: "2026-11-22T01:00:00Z",
      };

      // Ordering 1: slow healthy call + fast degraded call concurrently -> degraded must NOT pollute cache.
      const gateHealthy1 = deferred<AgyListSummariesResult>();
      const gateDegraded1 = deferred<AgyListSummariesResult>();
      const bothEntered1 = deferred<void>();
      let calls1 = 0;
      const backend1: AgySessionBackend = {
        async listSummaries() {
          calls1 += 1;
          if (calls1 === 2) bothEntered1.resolve();
          if (calls1 === 1) return gateHealthy1.promise;
          if (calls1 === 2) return gateDegraded1.promise;
          return {
            summaries: [healthySummary],
            listMeta: { schemaVersion: 1, complete: true, sources: ["cli", "other"] },
          };
        },
        async loadReplay() {
          return [];
        },
        async resolveSessionOrigin() {
          return "cli";
        },
        conversationFilePath() {
          return null;
        },
      };

      const catalog1 = new AgyCatalog(
        { backend: backend1, git: new GitRepoIndex(), overlay: new AgyOverlay(path.join(tmp, "o1.json")) },
        60_000,
      );
      const pHealthy1 = catalog1.list();
      const pDegraded1 = catalog1.list();
      await bothEntered1.promise;

      gateDegraded1.resolve({
        summaries: [degradedSummary],
        listMeta: {
          schemaVersion: 1,
          complete: false,
          degradedReason: "other_timeout",
          degradedSources: ["other"],
        },
      });
      const resDegraded1 = await pDegraded1;
      expect(resDegraded1.listMeta).toEqual({
        schemaVersion: 1,
        complete: false,
        degradedReason: "other_timeout",
        degradedSources: ["other"],
      });
      expect(resDegraded1.records.map((r) => r.id)).toEqual(["s-degraded"]);

      gateHealthy1.resolve({
        summaries: [healthySummary],
        listMeta: { schemaVersion: 1, complete: true, sources: ["cli", "other"] },
      });
      const resHealthy1 = await pHealthy1;
      expect(resHealthy1.listMeta).toEqual({ schemaVersion: 1, complete: true, sources: ["cli", "other"] });
      expect(resHealthy1.records.map((r) => r.id)).toEqual(["s-healthy"]);

      // Subsequent call hits healthy cache (no 3rd backend call).
      const cached1 = await catalog1.list();
      expect(calls1).toBe(2);
      expect(cached1.listMeta).toEqual({ schemaVersion: 1, complete: true, sources: ["cli", "other"] });

      // Ordering 2: fast healthy call finishes first, in-flight degraded call finishes second ->
      // healthy must NOT whitewash degraded, and degraded must NOT overwrite healthy cache!
      const gateHealthy2 = deferred<AgyListSummariesResult>();
      const gateDegraded2 = deferred<AgyListSummariesResult>();
      const bothEntered2 = deferred<void>();
      let calls2 = 0;
      const backend2: AgySessionBackend = {
        async listSummaries() {
          calls2 += 1;
          if (calls2 === 2) bothEntered2.resolve();
          if (calls2 === 1) return gateHealthy2.promise;
          return gateDegraded2.promise;
        },
        async loadReplay() {
          return [];
        },
        async resolveSessionOrigin() {
          return "cli";
        },
        conversationFilePath() {
          return null;
        },
      };
      const catalog2 = new AgyCatalog(
        { backend: backend2, git: new GitRepoIndex(), overlay: new AgyOverlay(path.join(tmp, "o2.json")) },
        60_000,
      );
      const pHealthy2 = catalog2.list();
      const pDegraded2 = catalog2.list();
      await bothEntered2.promise;

      gateHealthy2.resolve({
        summaries: [healthySummary],
        listMeta: { schemaVersion: 1, complete: true, sources: ["cli", "other"] },
      });
      const resHealthy2 = await pHealthy2;
      expect(resHealthy2.listMeta).toEqual({ schemaVersion: 1, complete: true, sources: ["cli", "other"] });

      gateDegraded2.resolve({
        summaries: [degradedSummary],
        listMeta: {
          schemaVersion: 1,
          complete: false,
          degradedReason: "other_failed",
          degradedSources: ["other"],
        },
      });
      const resDegraded2 = await pDegraded2;
      expect(resDegraded2.listMeta).toEqual({
        schemaVersion: 1,
        complete: false,
        degradedReason: "other_failed",
        degradedSources: ["other"],
      });

      // Healthy cache remains intact and serves next call without re-querying backend.
      const cached2 = await catalog2.list();
      expect(calls2).toBe(2);
      expect(cached2.listMeta).toEqual({ schemaVersion: 1, complete: true, sources: ["cli", "other"] });
      expect(cached2.records.map((r) => r.id)).toEqual(["s-healthy"]);
    } finally {
      await rm(tmp, { recursive: true, force: true });
    }
  });

  test("missing timestamps stably produce updatedAt === 0 && createdAt === 0 across second boundary", async () => {
    const tmp = await mkdtemp(path.join(os.tmpdir(), "agy-1a1-ts-"));
    try {
      const workspaceDir = path.join(tmp, "ws");
      await mkdir(workspaceDir, { recursive: true });
      const backend: AgySessionBackend = {
        async listSummaries() {
          return {
            summaries: [
              { sessionId: "no-ts-a", cwd: workspaceDir, title: "No TS A", updatedAt: null },
              { sessionId: "no-ts-b", cwd: workspaceDir, title: "No TS B", updatedAt: "not-a-date" },
            ],
            listMeta: { schemaVersion: 1, complete: true, sources: ["cli"] },
          };
        },
        async loadReplay() {
          return [];
        },
        async resolveSessionOrigin() {
          return "cli";
        },
        conversationFilePath() {
          return null;
        },
      };
      const catalog = new AgyCatalog(
        { backend, git: new GitRepoIndex(), overlay: new AgyOverlay(path.join(tmp, "overlay.json")) },
        0,
      );
      const history = new AgyHistoryStore(catalog, backend);
      const handlers = createThreadHandlers(catalog, history);

      const first = await handlers.list({ sortKey: "updated_at", sortDirection: "desc", limit: 10 });
      expect(first.data).toHaveLength(2);
      for (const row of first.data) {
        expect(row.updatedAt).toBe(0);
        expect(row.createdAt).toBe(0);
      }
      assertListMetaWhitelist(first.listMeta);

      // Cross a Unix second boundary and re-query with cache disabled.
      await new Promise((r) => setTimeout(r, 1_100));
      const second = await handlers.list({ sortKey: "updated_at", sortDirection: "desc", limit: 10 });
      expect(second.data.map((r) => ({ id: r.id, createdAt: r.createdAt, updatedAt: r.updatedAt }))).toEqual(
        first.data.map((r) => ({ id: r.id, createdAt: r.createdAt, updatedAt: r.updatedAt })),
      );
    } finally {
      await rm(tmp, { recursive: true, force: true });
    }
  });

  test("GitRepoIndex deduplicates concurrent inflight queries, enforces max concurrency 4, and releases slots on error", async () => {
    const tmp = await mkdtemp(path.join(os.tmpdir(), "agy-1a1-git-"));
    try {
      const dirs: string[] = [];
      for (let i = 0; i < 12; i += 1) {
        const d = path.join(tmp, `dir-${i}`);
        await mkdir(d, { recursive: true });
        dirs.push(d);
      }
      const symlinkToDir0 = path.join(tmp, "link-to-dir-0");
      await symlink(dirs[0]!, symlinkToDir0);
      const missingDir = path.join(tmp, "does-not-exist");

      let active = 0;
      let maxObserved = 0;
      let spawnCount = 0;
      const seenDirs: string[] = [];

      const git = new GitRepoIndex({
        ttlMs: 30_000,
        maxConcurrent: MAX_CONCURRENT_GIT_INSPECT,
        runGitRevParse: async (canonicalDir) => {
          spawnCount += 1;
          seenDirs.push(canonicalDir);
          active += 1;
          if (active > maxObserved) maxObserved = active;
          try {
            await new Promise((r) => setTimeout(r, 25));
            if (canonicalDir.endsWith("dir-3") || canonicalDir.endsWith("dir-7")) {
              throw new Error("simulated non-git dir failure");
            }
            return `${canonicalDir}/.git\nmain\n`;
          } finally {
            active -= 1;
          }
        },
      });

      // Fire 3x duplicates of every dir + symlink + missing dir concurrently.
      const queries = [...dirs, ...dirs, ...dirs, symlinkToDir0, missingDir];
      const results = await Promise.all(queries.map((d) => git.inspect(d)));

      expect(results).toHaveLength(queries.length);
      expect(spawnCount).toBe(dirs.length); // <= unique existing canonical cwds (symlink deduped, missing skipped)
      expect(maxObserved).toBeGreaterThan(1);
      expect(maxObserved).toBeLessThanOrEqual(MAX_CONCURRENT_GIT_INSPECT);
      expect(active).toBe(0);

      // Failed dirs fall back to canonicalDir with branch === null.
      expect(results[3]?.branch).toBeNull();
      expect(results[7]?.branch).toBeNull();
      expect(results[0]?.branch).toBe("main");
      // Symlink shares identical repoKey/branch with target dir-0.
      expect(results[dirs.length * 3]?.repoKey).toBe(results[0]?.repoKey);
      // Missing dir never spawned git.
      expect(seenDirs.some((d) => d.endsWith("does-not-exist"))).toBe(false);
    } finally {
      await rm(tmp, { recursive: true, force: true });
    }
  });

  test("catalog.list returns unpaginated candidates + listMeta, handler sorts/paginates, and liveStateOf runs only for current page", async () => {
    const tmp = await mkdtemp(path.join(os.tmpdir(), "agy-1a1-page-"));
    try {
      const ws = path.join(tmp, "ws");
      await mkdir(ws, { recursive: true });
      const summaries: AcpSessionSummary[] = [
        { sessionId: "s-1", cwd: ws, title: "One", updatedAt: "2026-11-22T01:00:01Z" },
        { sessionId: "s-2", cwd: ws, title: "Two", updatedAt: "2026-11-22T01:00:05Z" },
        { sessionId: "s-3", cwd: ws, title: "Three", updatedAt: "2026-11-22T01:00:03Z" },
        { sessionId: "s-4", cwd: ws, title: "Four", updatedAt: "2026-11-22T01:00:04Z" },
        { sessionId: "s-5", cwd: ws, title: "Five", updatedAt: "2026-11-22T01:00:02Z" },
      ];
      const inspectedExternal: string[] = [];
      const expectedMeta: AgyThreadListMeta = { schemaVersion: 1, complete: true, sources: ["cli", "other"] };

      const backend: AgySessionBackend = {
        async listSummaries() {
          return { summaries, listMeta: expectedMeta };
        },
        async loadReplay() {
          return [];
        },
        async resolveSessionOrigin() {
          return "cli";
        },
        conversationFilePath() {
          return null;
        },
        async inspectExternalActivity(sessionId) {
          inspectedExternal.push(sessionId);
          return undefined;
        },
      };

      const catalog = new AgyCatalog(
        { backend, git: new GitRepoIndex(), overlay: new AgyOverlay(path.join(tmp, "overlay.json")) },
        60_000,
      );
      // 1) catalog.list returns ALL unpaginated candidates + same-query listMeta.
      const unpaginated = await catalog.list();
      expect(unpaginated.records).toHaveLength(5);
      expect(unpaginated.listMeta).toEqual(expectedMeta);
      expect(inspectedExternal).toEqual([]);

      // 2) handlers/threads.ts sorts desc, slices limit=2, and invokes liveStateOf ONLY on the 2 page records!
      const history = new AgyHistoryStore(catalog, backend);
      const handlers = createThreadHandlers(catalog, history);

      const page1 = await handlers.list({ sortKey: "updated_at", sortDirection: "desc", limit: 2 });
      expect(page1.data.map((t) => t.id)).toEqual(["s-2", "s-4"]);
      expect(page1.nextCursor).not.toBeNull();
      expect(page1.listMeta).toEqual(expectedMeta);
      assertListMetaWhitelist(page1.listMeta);
      expect(inspectedExternal).toEqual(["s-2", "s-4"]);

      inspectedExternal.length = 0;
      const page2 = await handlers.list({
        sortKey: "updated_at",
        sortDirection: "desc",
        limit: 2,
        cursor: page1.nextCursor,
      });
      expect(page2.data.map((t) => t.id)).toEqual(["s-3", "s-5"]);
      expect(page2.listMeta).toEqual(expectedMeta);
      assertListMetaWhitelist(page2.listMeta);
      expect(inspectedExternal).toEqual(["s-3", "s-5"]);
    } finally {
      await rm(tmp, { recursive: true, force: true });
    }
  });

  test("end-to-end thread/list emits accurate listMeta across healthy and all 4 degraded states", async () => {
    const tmp = await mkdtemp(path.join(os.tmpdir(), "agy-1a1-e2e-"));
    const restoreModes: Array<{ target: string; mode: number }> = [];
    try {
      const ws = path.join(tmp, "ws");
      await mkdir(ws, { recursive: true });
      const cliSession: FakeStoredSession = {
        sessionId: "cli-s1",
        cwd: ws,
        title: "CLI Session",
        updatedAt: "2026-11-22T01:00:00Z",
        modeId: "default",
        model: "gemini-4-carbon",
        thoughtLevel: "medium",
        replayUpdates: [],
        appDataDirName: "antigravity-cli",
      };
      const otherSession: FakeStoredSession = {
        sessionId: "other-s1",
        cwd: ws,
        title: "Other Session",
        updatedAt: "2026-11-22T01:01:00Z",
        modeId: "default",
        model: "gemini-4-carbon",
        thoughtLevel: "medium",
        replayUpdates: [],
        appDataDirName: "antigravity",
      };

      const runList = async (
        homeDir: string,
        world: FakeAgyWorld,
        opts: {
          extraEnv?: Record<string, string>;
          spawnTransport?: typeof world.spawnTransport;
        } = {},
      ): Promise<AgyThreadListResponse> => {
        const app = createApp({
          stateDir: path.join(tmp, `state-${Math.random().toString(36).slice(2)}`),
          log: silentLog,
          agyExecutable: () => "fake-agy",
          probeAgy: async () => ({ version: "1.5.14" }),
          spawnTransport: opts.spawnTransport ?? ((spawnOpts) => world.spawnTransport(spawnOpts)),
          env: () => envForHome(homeDir, opts.extraEnv),
        });
        try {
          const frame = await app.router.dispatch(
            { id: 1, method: "thread/list", params: { limit: 10 } },
            { session: new Session("test-session"), generation: 1 },
          );
          if ("error" in frame) {
            throw new Error(`RPC error: ${JSON.stringify(frame.error)}`);
          }
          return frame.result as AgyThreadListResponse;
        } finally {
          await app.close();
        }
      };

      // 1) Healthy CLI-only (Other dir genuinely missing) -> complete: true, sources: ["cli"]
      const homeCliOnly = path.join(tmp, "h-cli-only");
      await mkdir(path.join(homeCliOnly, ".gemini", "antigravity-cli", "conversations"), { recursive: true });
      await writeFile(path.join(homeCliOnly, ".gemini", "antigravity-cli", "conversations", "cli-s1.db"), "");
      const resCliOnly = await runList(homeCliOnly, new FakeAgyWorld({ sessions: [cliSession] }));
      expect(resCliOnly.listMeta).toEqual({ schemaVersion: 1, complete: true, sources: ["cli"] });
      assertListMetaWhitelist(resCliOnly.listMeta);

      // 2) Healthy CLI + Other -> complete: true, sources: ["cli", "other"]
      const homeBoth = path.join(tmp, "h-both");
      await mkdir(path.join(homeBoth, ".gemini", "antigravity-cli", "conversations"), { recursive: true });
      await mkdir(path.join(homeBoth, ".gemini", "antigravity", "conversations"), { recursive: true });
      await writeFile(path.join(homeBoth, ".gemini", "antigravity-cli", "conversations", "cli-s1.db"), "");
      await writeFile(path.join(homeBoth, ".gemini", "antigravity", "conversations", "other-s1.db"), "");
      const resBoth = await runList(homeBoth, new FakeAgyWorld({ sessions: [cliSession, otherSession] }));
      expect(resBoth.listMeta).toEqual({ schemaVersion: 1, complete: true, sources: ["cli", "other"] });
      assertListMetaWhitelist(resBoth.listMeta);
      expect(resBoth.data.map((t) => t.id).sort()).toEqual(["cli-s1", "other-s1"]);

      // 3) Degraded: other_failed
      const worldFail = new FakeAgyWorld({ sessions: [cliSession, otherSession] });
      const resFailed = await runList(homeBoth, worldFail, {
        spawnTransport: (spawnOpts) => {
          if (spawnOpts.appDataDirName === "antigravity") {
            throw new Error("simulated other crash");
          }
          return worldFail.spawnTransport(spawnOpts);
        },
      });
      expect(resFailed.listMeta).toEqual({
        schemaVersion: 1,
        complete: false,
        degradedReason: "other_failed",
        degradedSources: ["other"],
      });
      assertListMetaWhitelist(resFailed.listMeta);

      // 4) Degraded: other_timeout
      const worldTimeout = new FakeAgyWorld({ sessions: [cliSession, otherSession] });
      const resTimeout = await runList(homeBoth, worldTimeout, {
        extraEnv: { AGY_ADAPTER_OTHER_LIST_TIMEOUT_MS: "60" },
        spawnTransport: (spawnOpts) => {
          if (spawnOpts.appDataDirName === "antigravity") {
            const stdin = new PassThrough();
            const stdout = new PassThrough();
            return {
              stdin,
              stdout,
              pid: 99_123,
              async close() {
                stdin.end();
                stdout.end();
              },
            };
          }
          return worldTimeout.spawnTransport(spawnOpts);
        },
      });
      expect(resTimeout.listMeta).toEqual({
        schemaVersion: 1,
        complete: false,
        degradedReason: "other_timeout",
        degradedSources: ["other"],
      });
      assertListMetaWhitelist(resTimeout.listMeta);

      // 5) Degraded: other_probe_io_error (dangling symlink at conversations -> returns ENOENT!)
      const homeDangling = path.join(tmp, "h-dangling");
      await mkdir(path.join(homeDangling, ".gemini", "antigravity-cli", "conversations"), { recursive: true });
      await mkdir(path.join(homeDangling, ".gemini", "antigravity"), { recursive: true });
      await writeFile(path.join(homeDangling, ".gemini", "antigravity-cli", "conversations", "cli-s1.db"), "");
      await symlink(
        path.join(tmp, "missing-target-dir"),
        path.join(homeDangling, ".gemini", "antigravity", "conversations"),
      );
      const worldDangling = new FakeAgyWorld({ sessions: [cliSession, otherSession] });
      const resDangling = await runList(homeDangling, worldDangling);
      expect(resDangling.listMeta).toEqual({
        schemaVersion: 1,
        complete: false,
        degradedReason: "other_probe_io_error",
        degradedSources: ["other"],
      });
      assertListMetaWhitelist(resDangling.listMeta);
      expect(worldDangling.spawns.some((s) => s.appDataDirName === "antigravity")).toBe(false);

      // 6) Degraded: other_probe_permission_denied (0444 conversations dir)
      if (process.getuid?.() !== 0) {
        const homePerm = path.join(tmp, "h-perm-e2e");
        const cliConv = path.join(homePerm, ".gemini", "antigravity-cli", "conversations");
        const otherConv = path.join(homePerm, ".gemini", "antigravity", "conversations");
        await mkdir(cliConv, { recursive: true });
        await mkdir(otherConv, { recursive: true });
        await writeFile(path.join(cliConv, "cli-s1.db"), "");
        await writeFile(path.join(otherConv, "other-s1.db"), "");
        await chmod(otherConv, 0o444);
        restoreModes.push({ target: otherConv, mode: 0o755 });

        const worldPerm = new FakeAgyWorld({ sessions: [cliSession, otherSession] });
        const resPerm = await runList(homePerm, worldPerm);
        expect(resPerm.listMeta).toEqual({
          schemaVersion: 1,
          complete: false,
          degradedReason: "other_probe_permission_denied",
          degradedSources: ["other"],
        });
        assertListMetaWhitelist(resPerm.listMeta);
        expect(worldPerm.spawns.some((s) => s.appDataDirName === "antigravity")).toBe(false);
      }

      // 7) createAcpSessionBackend respects injected probeOther returning io_error
      const worldProbe = new FakeAgyWorld({ sessions: [cliSession] });
      const cliAcp = new SharedReadonlyAcp(
        () => "fake-agy",
        (o) => worldProbe.spawnTransport(o),
        () => envForHome(homeCliOnly),
        "antigravity-cli",
      );
      const otherAcp = new SharedReadonlyAcp(
        () => "fake-agy",
        (o) => worldProbe.spawnTransport(o),
        () => envForHome(homeCliOnly),
        "antigravity",
      );
      try {
        const backendIo = createAcpSessionBackend(
          cliAcp,
          otherAcp,
          () => envForHome(homeCliOnly),
          undefined,
          undefined,
          async () => "io_error",
        );
        const resIo = await backendIo.listSummaries();
        expect(resIo.listMeta).toEqual({
          schemaVersion: 1,
          complete: false,
          degradedReason: "other_probe_io_error",
          degradedSources: ["other"],
        });
      } finally {
        await Promise.all([cliAcp.close(), otherAcp.close()]);
      }
    } finally {
      for (const item of restoreModes.reverse()) {
        await chmod(item.target, item.mode).catch(() => {});
      }
      await rm(tmp, { recursive: true, force: true });
    }
  });

  test("verify-thread-list-perf.ts exits non-zero when any hard threshold fails and 0 when all pass", async () => {
    const tmp = await mkdtemp(path.join(os.tmpdir(), "agy-1a1-perf-cli-"));
    const scriptPath = path.resolve(import.meta.dir, "..", "scripts", "verify-thread-list-perf.ts");
    try {
      const runVerifier = async (name: string, payload: unknown) => {
        const jsonPath = path.join(tmp, `${name}.json`);
        await writeFile(jsonPath, JSON.stringify(payload));
        return spawnSync(process.execPath, [scriptPath, "--check-json", jsonPath], { encoding: "utf8" });
      };

      const base = {
        seed: 20260410,
        dataset: { uniqueNonOrphanRawCwds: 33 },
        summary: {
          concurrentColdGitSpawnsMeanPerRun: 27,
          sequentialWarmGitSpawnsAbsoluteAcrossAllBatches: 0,
          sequentialWarmP95MsMean: 12.5,
          sequentialWarmP95SpreadPct: 2.1,
        },
      };

      expect((await runVerifier("pass", base)).status).toBe(0);

      // Fail 1: cold git spawns > unique cwds cap
      const failCold = structuredClone(base);
      failCold.summary.concurrentColdGitSpawnsMeanPerRun = 65;
      const rCold = await runVerifier("fail-cold", failCold);
      expect(rCold.status).toBe(1);
      expect(rCold.stderr).toContain("concurrent_cold_git_spawns");

      // Fail 2: warm git spawns != 0
      const failWarmSpawns = structuredClone(base);
      failWarmSpawns.summary.sequentialWarmGitSpawnsAbsoluteAcrossAllBatches = 1;
      const rWarmSpawns = await runVerifier("fail-warm-spawns", failWarmSpawns);
      expect(rWarmSpawns.status).toBe(1);
      expect(rWarmSpawns.stderr).toContain("sequential_warm_git_spawns");

      // Fail 3: warm p95 fails >= 30% improvement threshold (> 123.470ms)
      const failWarmP95 = structuredClone(base);
      failWarmP95.summary.sequentialWarmP95MsMean = 140.0;
      const rWarmP95 = await runVerifier("fail-warm-p95", failWarmP95);
      expect(rWarmP95.status).toBe(1);
      expect(rWarmP95.stderr).toContain("sequential_warm_p95_ms");
    } finally {
      await rm(tmp, { recursive: true, force: true });
    }
  });
});
