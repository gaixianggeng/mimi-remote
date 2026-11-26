import { describe, expect, test } from "bun:test";
import { execFileSync, spawnSync } from "node:child_process";
import { chmod, lstat, mkdir, mkdtemp, readdir, realpath, rm, stat, symlink, writeFile, access } from "node:fs/promises";
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

      // 7b) io_error: dangling symlink higher up in a deeply nested Other path (above 2 ancestors)
      const deepDanglingHome = path.join(tmp, "h-deep-dangling");
      await mkdir(path.join(deepDanglingHome, ".gemini"), { recursive: true });
      await symlink(
        path.join(tmp, "does-not-exist-deep-target"),
        path.join(deepDanglingHome, ".gemini", "layer1"),
      );
      const deepNestedEnv = envForHome(deepDanglingHome, {
        AGY_ADAPTER_OTHER_APP_DATA_DIR: path.join("layer1", "layer2", "layer3", "antigravity"),
      });
      expect(await probeOtherConversations(deepNestedEnv)).toBe("io_error");

      // 7c) io_error: dangling symlink at HOME itself (above .gemini)
      const danglingHomeLink = path.join(tmp, "h-dangling-home-link");
      await symlink(path.join(tmp, "does-not-exist-home"), danglingHomeLink);
      expect(await probeOtherConversations(envForHome(danglingHomeLink))).toBe("io_error");

      // 7d) absent_or_empty: deeply nested Other path under a real existing ancestor directory
      const deepMissingHome = path.join(tmp, "h-deep-missing");
      await mkdir(path.join(deepMissingHome, ".gemini", "layer1"), { recursive: true });
      expect(
        await probeOtherConversations(
          envForHome(deepMissingHome, {
            AGY_ADAPTER_OTHER_APP_DATA_DIR: path.join("layer1", "layer2", "layer3", "antigravity"),
          }),
        ),
      ).toBe("absent_or_empty");

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

      // 10b) 64-bit APFS inode precision: numeric stat rounds distinct 64-bit inodes to identical Numbers,
      // so probeOtherConversations and createBatchSessionOriginResolver MUST compare with `{ bigint: true }`.
      const bigintHome = path.join(tmp, "h-bigint-inode");
      const bigintCliRoot = path.join(bigintHome, ".gemini", "antigravity-cli");
      const bigintOtherRoot = path.join(bigintHome, ".gemini", "antigravity");
      const bigintCliConv = path.join(bigintCliRoot, "conversations");
      const bigintOtherConv = path.join(bigintOtherRoot, "conversations");
      await mkdir(bigintCliConv, { recursive: true });
      await mkdir(bigintOtherConv, { recursive: true });
      await writeFile(path.join(bigintCliConv, "cli-big.db"), "");
      await writeFile(path.join(bigintOtherConv, "other-big.db"), "");

      const bigInoA = 9007199254740992n; // 2^53
      const bigInoB = 9007199254740993n; // 2^53 + 1 -> Number(bigInoA) === Number(bigInoB)
      expect(Number(bigInoA)).toBe(Number(bigInoB));
      const statCallsWithBigint: boolean[] = [];
      const makeBigintStat = (inoForCli: bigint, inoForOther: bigint): typeof stat =>
        (async (target: Parameters<typeof stat>[0], options?: Parameters<typeof stat>[1]) => {
          const targetStr = String(target);
          const wantsBigint = Boolean(options && typeof options === "object" && "bigint" in options && options.bigint);
          statCallsWithBigint.push(wantsBigint);
          const real = await stat(target, options as Parameters<typeof stat>[1]);
          if (targetStr === bigintCliRoot || targetStr === bigintOtherRoot) {
            const chosenIno = targetStr === bigintCliRoot ? inoForCli : inoForOther;
            const chosenDev = 16777233n;
            return Object.assign(Object.create(Object.getPrototypeOf(real)), real, {
              dev: wantsBigint ? chosenDev : Number(chosenDev),
              ino: wantsBigint ? chosenIno : Number(chosenIno),
              isDirectory: () => true,
            });
          }
          return real;
        }) as unknown as typeof stat;

      const distinctBigintOps: ProbeFsOps = {
        access,
        lstat,
        readdir,
        stat: makeBigintStat(bigInoA, bigInoB),
      };
      const bigintEnv = envForHome(bigintHome);
      expect(await probeOtherConversations(bigintEnv, distinctBigintOps)).toBe("present");
      expect(statCallsWithBigint.length).toBeGreaterThanOrEqual(2);
      expect(statCallsWithBigint.every(Boolean)).toBe(true);

      const batchBigintResolver = await createBatchSessionOriginResolver(bigintEnv, {
        stat: makeBigintStat(bigInoA, bigInoB),
      });
      expect(await batchBigintResolver("cli-big")).toBe("cli");
      expect(await batchBigintResolver("other-big")).toBe("other");

      // Matching 64-bit bigint inodes on the same device ARE recognized as the same directory.
      const sameBigintOps: ProbeFsOps = {
        access,
        lstat,
        readdir,
        stat: makeBigintStat(bigInoB, bigInoB),
      };
      expect(await probeOtherConversations(bigintEnv, sameBigintOps)).toBe("absent_or_empty");

      // Zero inode (0n) must never be treated as equal identity.
      const zeroInoOps: ProbeFsOps = {
        access,
        lstat,
        readdir,
        stat: makeBigintStat(0n, 0n),
      };
      expect(await probeOtherConversations(bigintEnv, zeroInoOps)).toBe("present");

      // End-to-end: distinct 64-bit APFS roots keep Other active instead of caching CLI-only as complete.
      const wsBigint = path.join(tmp, "ws-bigint");
      await mkdir(wsBigint, { recursive: true });
      const bigintWorld = new FakeAgyWorld({
        sessions: [
          {
            sessionId: "cli-big",
            cwd: wsBigint,
            title: "CLI Bigint",
            updatedAt: "2026-11-22T01:00:00Z",
            modeId: "default",
            model: "gemini-4-carbon",
            thoughtLevel: "medium",
            replayUpdates: [],
            appDataDirName: "antigravity-cli",
          },
          {
            sessionId: "other-big",
            cwd: wsBigint,
            title: "Other Bigint",
            updatedAt: "2026-11-22T01:01:00Z",
            modeId: "default",
            model: "gemini-4-carbon",
            thoughtLevel: "medium",
            replayUpdates: [],
            appDataDirName: "antigravity",
          },
        ],
      });
      const cliBigAcp = new SharedReadonlyAcp(() => "fake-agy", (o) => bigintWorld.spawnTransport(o), () => bigintEnv, "antigravity-cli");
      const otherBigAcp = new SharedReadonlyAcp(() => "fake-agy", (o) => bigintWorld.spawnTransport(o), () => bigintEnv, "antigravity");
      try {
        const backendBig = createAcpSessionBackend(
          cliBigAcp,
          otherBigAcp,
          () => bigintEnv,
          undefined,
          undefined,
          (e) => probeOtherConversations(e, distinctBigintOps),
        );
        const catalogBig = new AgyCatalog(
          { backend: backendBig, git: new GitRepoIndex(), overlay: new AgyOverlay(path.join(tmp, "overlay-big.json")) },
          60_000,
        );
        const listedBig = await catalogBig.list();
        expect(listedBig.listMeta).toEqual({ schemaVersion: 1, complete: true, sources: ["cli", "other"] });
        expect(listedBig.records.map((r) => r.id).sort()).toEqual(["cli-big", "other-big"]);
      } finally {
        await Promise.all([cliBigAcp.close(), otherBigAcp.close()]);
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
      // Case D: case-insensitive & Unicode-folded volume aliases (`abcd.db` -> `ABCD`, uppercase `.DB`,
      // `ſ-test.db` -> `s-test`, `K-test.db` -> `k-test`, `ẞ.db` -> `ss`, `ß-other.db` -> `ss-other`,
      // dangling alias, same-root case alias)
      const homeCase = path.join(tmp, "home-case");
      const cliCase = path.join(homeCase, ".gemini", "antigravity-cli", "conversations");
      const otherCase = path.join(homeCase, ".gemini", "antigravity", "conversations");
      await mkdir(cliCase, { recursive: true });
      await mkdir(otherCase, { recursive: true });
      await writeFile(path.join(cliCase, "abcd.db"), "");
      await writeFile(path.join(cliCase, "upper-ext.DB"), "");
      await writeFile(path.join(cliCase, "\u017f-test.db"), "");
      await writeFile(path.join(cliCase, "\u1e9e.db"), "");
      await writeFile(path.join(otherCase, "efgh.db"), "");
      await writeFile(path.join(otherCase, "\u212a-test.db"), "");
      await writeFile(path.join(otherCase, "\u00df-other.db"), "");
      await symlink(path.join(tmp, "missing-case-target.db"), path.join(cliCase, "dangling-case.db"));
      await symlink(path.join(tmp, "missing-longs-target.db"), path.join(cliCase, "\u017f-dangling.db"));

      const envCase = envForHome(homeCase);
      await checkEquivalence(envCase, [
        "abcd",
        "ABCD",
        "efgh",
        "EFGH",
        "upper-ext",
        "UPPER-EXT",
        "s-test",
        "S-TEST",
        "k-test",
        "K-TEST",
        "ss",
        "SS",
        "ss-other",
        "SS-OTHER",
        "dangling-case",
        "DANGLING-CASE",
        "s-dangling",
      ]);

      const isCaseInsensitiveVolume = await access(path.join(cliCase, "ABCD.db"))
        .then(() => true)
        .catch(() => false);
      const isUnicodeFoldedLongS = await access(path.join(cliCase, "s-test.db"))
        .then(() => true)
        .catch(() => false);
      const isUnicodeFoldedKelvin = await access(path.join(otherCase, "k-test.db"))
        .then(() => true)
        .catch(() => false);
      const isUnicodeFoldedCapitalSharpS = await access(path.join(cliCase, "ss.db"))
        .then(() => true)
        .catch(() => false);
      const isUnicodeFoldedSmallSharpS = await access(path.join(otherCase, "ss-other.db"))
        .then(() => true)
        .catch(() => false);
      if (isCaseInsensitiveVolume) {
        const batchCase = await createBatchSessionOriginResolver(envCase);
        expect(await batchCase("ABCD")).toBe("cli");
        expect(await batchCase("EFGH")).toBe("other");
        expect(await batchCase("upper-ext")).toBe("cli");
        expect(await batchCase("DANGLING-CASE")).toBeNull();
        expect(await batchCase("s-dangling")).toBeNull();
        if (isUnicodeFoldedLongS) {
          expect(await batchCase("s-test")).toBe("cli");
          expect(await batchCase("S-TEST")).toBe("cli");
          // probeOtherConversations also recognizes `ſ-only.DB` (Unicode folded stem + uppercase extension).
          const homeLongSProbe = path.join(tmp, "home-longs-probe");
          const otherLongSConv = path.join(homeLongSProbe, ".gemini", "antigravity", "conversations");
          await mkdir(otherLongSConv, { recursive: true });
          await writeFile(path.join(otherLongSConv, "\u017f-only.DB"), "");
          expect(await probeOtherConversations(envForHome(homeLongSProbe))).toBe("present");
        }
        if (isUnicodeFoldedKelvin) {
          expect(await batchCase("k-test")).toBe("other");
          expect(await batchCase("K-TEST")).toBe("other");
        }
        if (isUnicodeFoldedCapitalSharpS) {
          expect(await batchCase("ss")).toBe("cli");
          expect(await batchCase("SS")).toBe("cli");
        }
        if (isUnicodeFoldedSmallSharpS) {
          expect(await batchCase("ss-other")).toBe("other");
          expect(await batchCase("SS-OTHER")).toBe("other");
        }

        // Same-root with different casing on a case-insensitive volume must be recognized as same root.
        const sameRootDiffCaseEnv = envForHome(homeCase, {
          AGY_ADAPTER_OTHER_APP_DATA_DIR: "ANTIGRAVITY-CLI",
        });
        expect(await probeOtherConversations(sameRootDiffCaseEnv)).toBe("absent_or_empty");
        await checkEquivalence(sameRootDiffCaseEnv, ["ABCD", "abcd", "efgh", "s-test", "ss"]);

        // End-to-end catalog.list must keep `ABCD` and Unicode-folded `s-test`/`k-test`/`ss` sessions (matching thread/read).
        const wsCase = path.join(tmp, "ws-case");
        await mkdir(wsCase, { recursive: true });
        const caseSessions: FakeStoredSession[] = [
          {
            sessionId: "ABCD",
            cwd: wsCase,
            title: "Case Alias Session",
            updatedAt: "2026-11-22T01:00:00Z",
            modeId: "default",
            model: "gemini-4-carbon",
            thoughtLevel: "medium",
            replayUpdates: [],
            appDataDirName: "antigravity-cli",
          },
        ];
        if (isUnicodeFoldedLongS) {
          caseSessions.push({
            sessionId: "s-test",
            cwd: wsCase,
            title: "Long-S Folded Session",
            updatedAt: "2026-11-22T01:01:00Z",
            modeId: "default",
            model: "gemini-4-carbon",
            thoughtLevel: "medium",
            replayUpdates: [],
            appDataDirName: "antigravity-cli",
          });
        }
        if (isUnicodeFoldedKelvin) {
          caseSessions.push({
            sessionId: "k-test",
            cwd: wsCase,
            title: "Kelvin Folded Session",
            updatedAt: "2026-11-22T01:02:00Z",
            modeId: "default",
            model: "gemini-4-carbon",
            thoughtLevel: "medium",
            replayUpdates: [],
            appDataDirName: "antigravity",
          });
        }
        if (isUnicodeFoldedCapitalSharpS) {
          caseSessions.push({
            sessionId: "ss",
            cwd: wsCase,
            title: "Capital Sharp-S Folded Session",
            updatedAt: "2026-11-22T01:03:00Z",
            modeId: "default",
            model: "gemini-4-carbon",
            thoughtLevel: "medium",
            replayUpdates: [],
            appDataDirName: "antigravity-cli",
          });
        }
        const caseWorld = new FakeAgyWorld({ sessions: caseSessions });
        const cliAcpCase = new SharedReadonlyAcp(
          () => "fake-agy",
          (o) => caseWorld.spawnTransport(o),
          () => envCase,
          "antigravity-cli",
        );
        const otherAcpCase = new SharedReadonlyAcp(
          () => "fake-agy",
          (o) => caseWorld.spawnTransport(o),
          () => envCase,
          "antigravity",
        );
        try {
          const backendCase = createAcpSessionBackend(cliAcpCase, otherAcpCase, () => envCase);
          const catalogCase = new AgyCatalog({
            backend: backendCase,
            git: new GitRepoIndex(),
            overlay: new AgyOverlay(path.join(tmp, "overlay-case.json")),
          });
          const listed = await catalogCase.list();
          expect(listed.records.map((r) => r.id)).toContain("ABCD");
          const readRecord = await catalogCase.get("ABCD");
          expect(readRecord?.id).toBe("ABCD");
          if (isUnicodeFoldedLongS) {
            expect(listed.records.map((r) => r.id)).toContain("s-test");
            expect((await catalogCase.get("s-test"))?.id).toBe("s-test");
          }
          if (isUnicodeFoldedKelvin) {
            expect(listed.records.map((r) => r.id)).toContain("k-test");
            expect((await catalogCase.get("k-test"))?.id).toBe("k-test");
          }
          if (isUnicodeFoldedCapitalSharpS) {
            expect(listed.records.map((r) => r.id)).toContain("ss");
            expect((await catalogCase.get("ss"))?.id).toBe("ss");
          }
        } finally {
          await Promise.all([cliAcpCase.close(), otherAcpCase.close()]);
        }
      }

      // Case E: unrelated non-ASCII filenames (e.g. `日本語.db`) in CLI dir must NOT trigger per-miss access()
      // lookups when resolving unrelated Other or orphan ASCII session IDs.
      const homeNonAscii = path.join(tmp, "home-nonascii-no-fallback");
      const cliNonAscii = path.join(homeNonAscii, ".gemini", "antigravity-cli", "conversations");
      const otherNonAscii = path.join(homeNonAscii, ".gemini", "antigravity", "conversations");
      await mkdir(cliNonAscii, { recursive: true });
      await mkdir(otherNonAscii, { recursive: true });
      await writeFile(path.join(cliNonAscii, "日本語.db"), "");
      await writeFile(path.join(cliNonAscii, "笔记.txt"), "");
      await writeFile(path.join(otherNonAscii, "other-fast-1.db"), "");
      await writeFile(path.join(otherNonAscii, "other-fast-2.db"), "");

      const accessedPaths: string[] = [];
      const spyAccess: typeof access = (async (target: Parameters<typeof access>[0], mode?: number) => {
        accessedPaths.push(String(target));
        return access(target, mode);
      }) as typeof access;

      const resolverNonAscii = await createBatchSessionOriginResolver(envForHome(homeNonAscii), {
        access: spyAccess,
      });
      // Initial index build checks X_OK on cliDir and otherDir only.
      expect(accessedPaths).toEqual([cliNonAscii, otherNonAscii]);
      accessedPaths.length = 0;

      expect(await resolverNonAscii("other-fast-1")).toBe("other");
      expect(await resolverNonAscii("other-fast-2")).toBe("other");
      expect(await resolverNonAscii("orphan-unrelated-99")).toBeNull();
      // Zero per-session access() calls despite `日本語.db` in CLI dir!
      expect(accessedPaths).toEqual([]);
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
      const firstEntered1 = deferred<void>();
      const bothEntered1 = deferred<void>();
      let calls1 = 0;
      const backend1: AgySessionBackend = {
        async listSummaries() {
          calls1 += 1;
          if (calls1 === 1) {
            firstEntered1.resolve();
            return gateHealthy1.promise;
          }
          if (calls1 === 2) {
            bothEntered1.resolve();
            return gateDegraded1.promise;
          }
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
      await firstEntered1.promise;
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
      const firstEntered2 = deferred<void>();
      const bothEntered2 = deferred<void>();
      let calls2 = 0;
      const backend2: AgySessionBackend = {
        async listSummaries() {
          calls2 += 1;
          if (calls2 === 1) {
            firstEntered2.resolve();
            return gateHealthy2.promise;
          }
          if (calls2 === 2) {
            bothEntered2.resolve();
          }
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
      await firstEntered2.promise;
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

  test("catalog.list returns frozen isolated listMeta that callers or mock mutations cannot corrupt", async () => {
    const tmp = await mkdtemp(path.join(os.tmpdir(), "agy-1a1-immutable-meta-"));
    try {
      const ws = path.join(tmp, "ws");
      await mkdir(ws, { recursive: true });
      const mutableSources: ("cli" | "other")[] = ["cli", "other"];
      const mutableBackendMeta = {
        schemaVersion: 1 as const,
        complete: true as const,
        sources: mutableSources,
      };
      let listCalls = 0;
      const backend: AgySessionBackend = {
        async listSummaries() {
          listCalls += 1;
          return {
            summaries: [{ sessionId: "s-1", cwd: ws, title: "S1", updatedAt: "2026-11-22T01:00:00Z" }],
            listMeta: mutableBackendMeta,
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
        { backend, git: new GitRepoIndex(), overlay: new AgyOverlay(path.join(tmp, "o.json")) },
        60_000,
      );
      const first = await catalog.list();
      expect(listCalls).toBe(1);
      expect(Object.isFrozen(first.listMeta)).toBe(true);
      expect(first.listMeta.complete).toBe(true);
      if (first.listMeta.complete) {
        expect(Object.isFrozen(first.listMeta.sources)).toBe(true);
      }

      // Mutating the caller's returned object/array must throw in strict mode and never affect cached state.
      expect(() => {
        (first.listMeta as unknown as { complete: boolean }).complete = false;
      }).toThrow(TypeError);
      expect(() => {
        if (first.listMeta.complete) {
          (first.listMeta.sources as string[]).push("tampered");
        }
      }).toThrow(TypeError);

      // Even mutating the backend's original object after returning must not affect the cached snapshot.
      mutableSources.push("cli");
      (mutableBackendMeta as unknown as { complete: boolean }).complete = false;

      const second = await catalog.list();
      expect(listCalls).toBe(1);
      expect(second.listMeta).toEqual({ schemaVersion: 1, complete: true, sources: ["cli", "other"] });
      expect(second.listMeta).not.toBe(first.listMeta);
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

  test("GitRepoIndex stats exact canonical path with trailing whitespace and preserves canonical TTL for symlink aliases", async () => {
    const tmp = await mkdtemp(path.join(os.tmpdir(), "agy-1a1-git-space-ttl-"));
    try {
      // 1) Real git repo + linked worktree ending with a trailing space + symlink pointing to it.
      const mainRepo = path.join(tmp, "main-repo");
      await mkdir(mainRepo, { recursive: true });
      const gitEnv: NodeJS.ProcessEnv = {
        ...process.env,
        GIT_CONFIG_NOSYSTEM: "1",
        GIT_CONFIG_GLOBAL: "/dev/null",
        GIT_CONFIG_SYSTEM: "/dev/null",
        GIT_TERMINAL_PROMPT: "0",
      };
      for (const key of Object.keys(gitEnv)) {
        if (key.startsWith("GIT_") && !["GIT_CONFIG_NOSYSTEM", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_TERMINAL_PROMPT"].includes(key)) {
          delete gitEnv[key];
        }
      }
      execFileSync("git", ["init", "-q", "--template=", "-b", "main"], { cwd: mainRepo, env: gitEnv });
      execFileSync(
        "git",
        [
          "-c", "user.name=Test",
          "-c", "user.email=test@example.invalid",
          "-c", "core.hooksPath=/dev/null",
          "-c", "commit.gpgsign=false",
          "-c", "tag.gpgsign=false",
          "commit", "-q", "--allow-empty", "-m", "init",
        ],
        { cwd: mainRepo, env: gitEnv },
      );

      const trailingSpaceWt = path.join(tmp, "linked-wt ");
      execFileSync(
        "git",
        ["-c", "core.hooksPath=/dev/null", "worktree", "add", "-q", "-b", "feat-space", trailingSpaceWt],
        { cwd: mainRepo, env: gitEnv },
      );
      const wtSymlink = path.join(tmp, "wt-link");
      await symlink(trailingSpaceWt, wtSymlink);

      const gitReal = new GitRepoIndex(30_000);
      const wtInfo = await gitReal.inspect(wtSymlink);
      expect(wtInfo.canonicalDir).toBe(await realpath(trailingSpaceWt));
      expect(wtInfo.canonicalDir.endsWith(" ")).toBe(true);
      expect(wtInfo.branch).toBe("feat-space");
      expect(await gitReal.matchesAnyRoot(wtSymlink, [mainRepo])).toBe(true);

      // 2) Symlink alias must inherit canonical entry's expiration instead of resetting TTL.
      const ttlDir = path.join(tmp, "ttl-repo");
      await mkdir(ttlDir, { recursive: true });
      const ttlLink = path.join(tmp, "ttl-link");
      await symlink(ttlDir, ttlLink);

      let inspectCalls = 0;
      let currentBranch = "v1";
      const gitTtl = new GitRepoIndex({
        ttlMs: 120,
        runGitRevParse: async (canonicalDir) => {
          inspectCalls += 1;
          return `${canonicalDir}/.git\n${currentBranch}\n`;
        },
      });

      const first = await gitTtl.inspect(ttlDir);
      expect(first.branch).toBe("v1");
      expect(inspectCalls).toBe(1);

      // Mid-TTL: encounter symlink alias -> hits canonical cache without extending expiration.
      await new Promise((r) => setTimeout(r, 70));
      currentBranch = "v2";
      const viaAliasMid = await gitTtl.inspect(ttlLink);
      expect(viaAliasMid.branch).toBe("v1");
      expect(inspectCalls).toBe(1);

      // Past canonical TTL (70 + 70 = 140ms > 120ms), even though < 120ms since alias was cached.
      await new Promise((r) => setTimeout(r, 70));
      const viaAliasExpired = await gitTtl.inspect(ttlLink);
      expect(viaAliasExpired.branch).toBe("v2");
      expect(inspectCalls).toBe(2);
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

      // 5b) Degraded: higher-level dangling symlink in nested Other path does NOT cache CLI-only as complete
      const homeDeepDangling = path.join(tmp, "h-deep-dangling-e2e");
      await mkdir(path.join(homeDeepDangling, ".gemini", "antigravity-cli", "conversations"), { recursive: true });
      await writeFile(path.join(homeDeepDangling, ".gemini", "antigravity-cli", "conversations", "cli-s1.db"), "");
      const deepLinkPath = path.join(homeDeepDangling, ".gemini", "nested-root");
      const missingDeepTarget = path.join(tmp, "missing-deep-e2e");
      await symlink(missingDeepTarget, deepLinkPath);
      const deepEnvExtra = { AGY_ADAPTER_OTHER_APP_DATA_DIR: path.join("nested-root", "a", "b", "antigravity") };
      const deepWorld = new FakeAgyWorld({ sessions: [cliSession, otherSession] });
      const deepCliAcp = new SharedReadonlyAcp(
        () => "fake-agy",
        (o) => deepWorld.spawnTransport(o),
        () => envForHome(homeDeepDangling, deepEnvExtra),
        "antigravity-cli",
      );
      const deepOtherAcp = new SharedReadonlyAcp(
        () => "fake-agy",
        (o) => deepWorld.spawnTransport(o),
        () => envForHome(homeDeepDangling, deepEnvExtra),
        path.join("nested-root", "a", "b", "antigravity"),
      );
      try {
        const deepBackend = createAcpSessionBackend(
          deepCliAcp,
          deepOtherAcp,
          () => envForHome(homeDeepDangling, deepEnvExtra),
        );
        const deepCatalog = new AgyCatalog(
          { backend: deepBackend, git: new GitRepoIndex(), overlay: new AgyOverlay(path.join(tmp, "o-deep.json")) },
          60_000,
        );
        const firstDeep = await deepCatalog.list();
        expect(firstDeep.listMeta).toEqual({
          schemaVersion: 1,
          complete: false,
          degradedReason: "other_probe_io_error",
          degradedSources: ["other"],
        });
        // Fix the dangling link target; because degraded response was NOT cached as complete, next call recovers immediately!
        await mkdir(path.join(missingDeepTarget, "a", "b", "antigravity", "conversations"), { recursive: true });
        await writeFile(path.join(missingDeepTarget, "a", "b", "antigravity", "conversations", "other-s1.db"), "");
        const recoveredDeep = await deepCatalog.list();
        expect(recoveredDeep.listMeta).toEqual({
          schemaVersion: 1,
          complete: true,
          sources: ["cli", "other"],
        });
      } finally {
        await Promise.all([deepCliAcp.close(), deepOtherAcp.close()]);
      }

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

  test("verify-thread-list-perf.ts enforces per-round cold caps, baseline alignment, live baseline measurement, and non-zero exit", async () => {
    const tmp = await mkdtemp(path.join(os.tmpdir(), "agy-1a1-perf-cli-"));
    const scriptPath = path.resolve(import.meta.dir, "..", "scripts", "verify-thread-list-perf.ts");
    try {
      const controlledScan = { controlled: true, mode: "deterministic_ps_shim" };
      const baselinePayload = {
        seed: 20260410,
        config: { batches: 3, cold: 5, warm: 20, concurrency: 4 },
        processScan: controlledScan,
        dataset: { uniqueNonOrphanRawCwds: 33 },
        summary: {
          concurrentColdGitSpawnsMeanPerRun: 128,
          sequentialWarmGitSpawnsAbsoluteAcrossAllBatches: 0,
          sequentialWarmP95MsMean: 41.228,
        },
      };
      const baselinePath = path.join(tmp, "baseline.json");
      await writeFile(baselinePath, JSON.stringify(baselinePayload));

      const runVerifier = async (
        name: string,
        payload: unknown,
        extraArgs: string[] = ["--baseline-json", baselinePath],
        envOverride?: NodeJS.ProcessEnv,
      ) => {
        const jsonPath = path.join(tmp, `${name}.json`);
        await writeFile(jsonPath, JSON.stringify(payload));
        return spawnSync(process.execPath, [scriptPath, "--check-json", jsonPath, ...extraArgs], {
          encoding: "utf8",
          ...(envOverride ? { env: envOverride } : {}),
        });
      };

      const makeBatches = (
        coldPerBatch: number[][],
        warmTotals = [0, 0, 0],
        opts: { concurrency?: number; warmRuns?: number } = {},
      ) =>
        coldPerBatch.map((perRun, idx) => ({
          batch: idx + 1,
          concurrentCold: {
            runs: perRun.length,
            concurrency: opts.concurrency ?? 4,
            gitSpawnsPerRun: perRun,
            gitSpawnsMean: Number((perRun.reduce((a, b) => a + b, 0) / perRun.length).toFixed(3)),
            gitSpawnsTotal: perRun.reduce((a, b) => a + b, 0),
          },
          sequentialWarm: {
            runs: opts.warmRuns ?? 20,
            gitSpawnsAbsoluteTotal: warmTotals[idx] ?? 0,
          },
        }));

      const base = {
        seed: 20260410,
        config: { batches: 3, cold: 5, warm: 20, concurrency: 4 },
        processScan: controlledScan,
        dataset: { uniqueNonOrphanRawCwds: 33 },
        summary: {
          concurrentColdGitSpawnsMeanPerRun: 27,
          sequentialWarmGitSpawnsAbsoluteAcrossAllBatches: 0,
          sequentialWarmP95MsMean: 12.5,
          sequentialWarmP95SpreadPct: 2.1,
        },
        batches: makeBatches([
          [27, 27, 27, 27, 27],
          [27, 27, 27, 27, 27],
          [27, 27, 27, 27, 27],
        ]),
      };

      const rPass = await runVerifier("pass", base);
      expect(rPass.status).toBe(0);
      expect(rPass.stdout).toContain("mean_of_batch_p95");
      const passParsed = JSON.parse(rPass.stdout) as {
        processScan: { controlled: boolean; matched: boolean; candidate: string; baseline: string };
      };
      expect(passParsed.processScan).toEqual({
        controlled: true,
        matched: true,
        candidate: "deterministic_ps_shim",
        baseline: "deterministic_ps_shim",
      });

      // Fail 1: single cold round exceeds cap (52 > 32) even though overall mean (28.667) is <= 32!
      const failSingleRoundCold = structuredClone(base);
      failSingleRoundCold.batches = makeBatches([
        [52, 27, 27, 27, 27],
        [27, 27, 27, 27, 27],
        [27, 27, 27, 27, 27],
      ]);
      failSingleRoundCold.summary.concurrentColdGitSpawnsMeanPerRun = 28.667;
      const rSingleRound = await runVerifier("fail-single-round-cold", failSingleRoundCold);
      expect(rSingleRound.status).toBe(1);
      expect(rSingleRound.stderr).toContain("concurrent_cold_git_spawns");
      expect(rSingleRound.stderr).toContain("b1#1:52");

      // Fail 1b: missing batches / per-round counts must fail closed.
      const failMissingBatches = structuredClone(base) as Record<string, unknown>;
      delete failMissingBatches.batches;
      const rMissingBatches = await runVerifier("fail-missing-batches", failMissingBatches);
      expect(rMissingBatches.status).toBe(1);
      expect(rMissingBatches.stderr).toContain("concurrent_cold_git_spawns");

      // Fail 1c: incomplete batch data (deleting the 52-spawn sample so only 14/15 cold rounds remain) must fail closed!
      const failTruncatedRounds = structuredClone(base);
      failTruncatedRounds.batches = makeBatches([
        [27, 27, 27, 27],
        [27, 27, 27, 27, 27],
        [27, 27, 27, 27, 27],
      ]);
      const rTruncatedRounds = await runVerifier("fail-truncated-rounds", failTruncatedRounds);
      expect(rTruncatedRounds.status).toBe(1);
      expect(rTruncatedRounds.stderr).toContain("cold_round_count_mismatch");

      // Fail 1d: missing a batch (only 2 batches while config.batches === 3) must fail closed.
      const failMissingOneBatch = structuredClone(base);
      failMissingOneBatch.batches = failMissingOneBatch.batches.slice(0, 2);
      const rMissingOneBatch = await runVerifier("fail-missing-one-batch", failMissingOneBatch);
      expect(rMissingOneBatch.status).toBe(1);
      expect(rMissingOneBatch.stderr).toContain("batch_count_mismatch");

      // Fail 1e: warm round count mismatch vs config.warm must fail closed.
      const failWarmRunsMismatch = structuredClone(base);
      failWarmRunsMismatch.batches = makeBatches(
        [
          [27, 27, 27, 27, 27],
          [27, 27, 27, 27, 27],
          [27, 27, 27, 27, 27],
        ],
        [0, 0, 0],
        { warmRuns: 19 },
      );
      const rWarmRunsMismatch = await runVerifier("fail-warm-runs-mismatch", failWarmRunsMismatch);
      expect(rWarmRunsMismatch.status).toBe(1);
      expect(rWarmRunsMismatch.stderr).toContain("warm_round_count_mismatch");

      // Fail 1f: missing report.config must fail closed.
      const failMissingConfig = structuredClone(base) as Record<string, unknown>;
      delete failMissingConfig.config;
      const rMissingConfig = await runVerifier("fail-missing-config", failMissingConfig, [
        "--baseline-cold-spawns",
        "128",
        "--baseline-warm-p95-ms",
        "41.228",
      ]);
      expect(rMissingConfig.status).toBe(1);
      expect(rMissingConfig.stderr).toContain("missing_or_invalid_config");

      // Fail 2: warm git spawns != 0
      const failWarmSpawns = structuredClone(base);
      failWarmSpawns.summary.sequentialWarmGitSpawnsAbsoluteAcrossAllBatches = 1;
      failWarmSpawns.batches = makeBatches(
        [
          [27, 27, 27, 27, 27],
          [27, 27, 27, 27, 27],
          [27, 27, 27, 27, 27],
        ],
        [0, 1, 0],
      );
      const rWarmSpawns = await runVerifier("fail-warm-spawns", failWarmSpawns);
      expect(rWarmSpawns.status).toBe(1);
      expect(rWarmSpawns.stderr).toContain("sequential_warm_git_spawns");

      // Fail 3: warm p95 regression (50ms > 41.228ms * 0.7 = 28.860ms on this host baseline)
      const failWarmP95 = structuredClone(base);
      failWarmP95.summary.sequentialWarmP95MsMean = 50.0;
      const rWarmP95 = await runVerifier("fail-warm-p95", failWarmP95);
      expect(rWarmP95.status).toBe(1);
      expect(rWarmP95.stderr).toContain("sequential_warm_p95_ms");

      // Fail 4: baseline seed mismatch must fail.
      const mismatchSeed = structuredClone(base);
      mismatchSeed.seed = 999;
      const rMismatch = await runVerifier("fail-seed-mismatch", mismatchSeed);
      expect(rMismatch.status).not.toBe(0);

      // Fail 5: partial manual baseline override without the other side must fail (no hardcoded fallback).
      const rPartialCli = await runVerifier("fail-partial-cli", base, ["--baseline-cold-spawns", "128"]);
      expect(rPartialCli.status).not.toBe(0);

      // Fail 6: mismatched or uncontrolled processScan between candidate and baseline JSON must fail closed.
      const ambientBaselinePayload = {
        ...baselinePayload,
        processScan: { status: "unmeasured", note: "Phase 0 ambient" },
      };
      const ambientBaselinePath = path.join(tmp, "baseline-ambient.json");
      await writeFile(ambientBaselinePath, JSON.stringify(ambientBaselinePayload));
      const rMismatchedScan = await runVerifier("fail-mismatched-scan", base, ["--baseline-json", ambientBaselinePath]);
      expect(rMismatchedScan.status).toBe(1);
      const mismatchedScanParsed = JSON.parse(rMismatchedScan.stdout) as {
        processScan: { controlled: boolean; matched: boolean; candidate: string; baseline: string };
        checks: Array<{ name: string; passed: boolean; detail: string }>;
      };
      expect(mismatchedScanParsed.processScan).toEqual({
        controlled: false,
        matched: false,
        candidate: "deterministic_ps_shim",
        baseline: "ambient_unmeasured",
      });
      const mismatchedWarmCheck = mismatchedScanParsed.checks.find((c) => c.name === "sequential_warm_p95_ms");
      expect(mismatchedWarmCheck?.passed).toBe(false);
      expect(mismatchedWarmCheck?.detail).toContain("uncontrolled_or_mismatched_process_scan");

      // Numeric baseline flags require explicit `--baseline-process-scan deterministic_ps_shim` provenance to pass;
      // omitting it or passing `ambient_unmeasured` fails closed.
      const rNumericControlled = await runVerifier("numeric-controlled-pass", base, [
        "--baseline-cold-spawns",
        "128",
        "--baseline-warm-p95-ms",
        "41.228",
        "--baseline-process-scan",
        "deterministic_ps_shim",
      ]);
      expect(rNumericControlled.status).toBe(0);
      const numericControlledParsed = JSON.parse(rNumericControlled.stdout) as {
        processScan: { controlled: boolean; matched: boolean; candidate: string; baseline: string };
        passed: boolean;
      };
      expect(numericControlledParsed.passed).toBe(true);
      expect(numericControlledParsed.processScan).toEqual({
        controlled: true,
        matched: true,
        candidate: "deterministic_ps_shim",
        baseline: "deterministic_ps_shim",
      });

      const rNumericOmittedScan = await runVerifier("numeric-omitted-scan-fail", base, [
        "--baseline-cold-spawns",
        "128",
        "--baseline-warm-p95-ms",
        "41.228",
      ]);
      expect(rNumericOmittedScan.status).toBe(1);
      expect(rNumericOmittedScan.stderr).toContain("uncontrolled_or_mismatched_process_scan");

      const rNumericAmbientScan = await runVerifier("numeric-ambient-scan-fail", base, [
        "--baseline-cold-spawns",
        "128",
        "--baseline-warm-p95-ms",
        "41.228",
        "--baseline-process-scan",
        "ambient_unmeasured",
      ]);
      expect(rNumericAmbientScan.status).toBe(1);
      expect(rNumericAmbientScan.stderr).toContain("uncontrolled_or_mismatched_process_scan");
    } finally {
      await rm(tmp, { recursive: true, force: true });
    }
  });

  test("verify-thread-list-perf.ts --record-json records controlled reports and live baseline isolates ambient ps with clean temp cleanup", async () => {
    const tmp = await mkdtemp(path.join(os.tmpdir(), "agy-1a1-perf-live-"));
    const scriptPath = path.resolve(import.meta.dir, "..", "scripts", "verify-thread-list-perf.ts");
    try {
      const fakePsDir = path.join(tmp, "ambient-slow-ps");
      await mkdir(fakePsDir, { recursive: true });
      const fakePsMarker = path.join(tmp, "ambient-ps-was-invoked.log");
      const fakePsPath = path.join(fakePsDir, "ps");
      await writeFile(
        fakePsPath,
        `#!/bin/sh\nprintf 'invoked\\n' >> "${fakePsMarker}"\nsleep 0.25\nprintf '999999 agy\\n'\n`,
      );
      await chmod(fakePsPath, 0o755);

      const isolatedTmp = path.join(tmp, "isolated-tmpdir");
      await mkdir(isolatedTmp, { recursive: true });
      const testEnv: NodeJS.ProcessEnv = {
        ...process.env,
        TMPDIR: isolatedTmp,
        PATH: `${fakePsDir}:${process.env.PATH ?? ""}`,
      };

      // 1) Record a controlled report via `--record-json` (bypassing ambient slow `ps`) and verify `--check-json` + `--baseline-json`.
      const recordedCandPath = path.join(tmp, "recorded-candidate.json");
      const rRecord = spawnSync(
        process.execPath,
        [
          scriptPath,
          "--record-json",
          recordedCandPath,
          "--seed",
          "20260410",
          "--batches",
          "1",
          "--cold",
          "1",
          "--warm",
          "2",
          "--concurrency",
          "2",
        ],
        { encoding: "utf8", env: testEnv },
      );
      expect(rRecord.status).toBe(0);
      const recordedCand = JSON.parse(rRecord.stdout) as {
        processScan: { controlled: boolean; mode: string };
        summary: { sequentialWarmP95MsMean: number };
      };
      expect(recordedCand.processScan.controlled).toBe(true);
      expect(recordedCand.processScan.mode).toBe("deterministic_ps_shim");

      const recordedBasePath = path.join(tmp, "recorded-baseline.json");
      await writeFile(
        recordedBasePath,
        JSON.stringify({
          seed: 20260410,
          config: { batches: 1, cold: 1, warm: 2, concurrency: 2 },
          processScan: { controlled: true, mode: "deterministic_ps_shim" },
          dataset: { uniqueNonOrphanRawCwds: 33 },
          summary: {
            concurrentColdGitSpawnsMeanPerRun: 128,
            sequentialWarmGitSpawnsAbsoluteAcrossAllBatches: 0,
            sequentialWarmP95MsMean: Math.max(50, recordedCand.summary.sequentialWarmP95MsMean * 4),
          },
        }),
      );
      const rCompareRecorded = spawnSync(
        process.execPath,
        [scriptPath, "--check-json", recordedCandPath, "--baseline-json", recordedBasePath],
        { encoding: "utf8" },
      );
      expect(rCompareRecorded.status).toBe(0);
      const comparedParsed = JSON.parse(rCompareRecorded.stdout) as {
        passed: boolean;
        processScan: { controlled: boolean; matched: boolean; candidate: string; baseline: string };
      };
      expect(comparedParsed.passed).toBe(true);
      expect(comparedParsed.processScan).toEqual({
        controlled: true,
        matched: true,
        candidate: "deterministic_ps_shim",
        baseline: "deterministic_ps_shim",
      });

      // 2) Live local baseline measurement using `--baseline-ref HEAD` (works in shallow detached CI checkouts):
      // passing cold/warm spawn counts (10 <= 27*0.5=13.5, warm=0) so ONLY sequential_warm_p95_ms fails,
      // ambient slow `ps` is bypassed, and temp shim dirs are cleaned up on exit 1.
      const liveRegressedPath = path.join(tmp, "live-regressed.json");
      await writeFile(
        liveRegressedPath,
        JSON.stringify({
          seed: 20260410,
          config: { batches: 1, cold: 1, warm: 2, concurrency: 2 },
          processScan: { controlled: true, mode: "deterministic_ps_shim" },
          dataset: { uniqueNonOrphanRawCwds: 33 },
          summary: {
            concurrentColdGitSpawnsMeanPerRun: 10,
            sequentialWarmGitSpawnsAbsoluteAcrossAllBatches: 0,
            sequentialWarmP95MsMean: 999.0,
          },
          batches: [
            {
              batch: 1,
              concurrentCold: { runs: 1, concurrency: 2, gitSpawnsPerRun: [10], gitSpawnsMean: 10, gitSpawnsTotal: 10 },
              sequentialWarm: { runs: 2, gitSpawnsAbsoluteTotal: 0 },
            },
          ],
        }),
      );
      const rLiveFail = spawnSync(
        process.execPath,
        [scriptPath, "--check-json", liveRegressedPath, "--baseline-ref", "HEAD"],
        { encoding: "utf8", env: testEnv },
      );
      expect(rLiveFail.status).toBe(1);
      const liveParsed = JSON.parse(rLiveFail.stdout) as {
        processScan: { controlled: boolean; matched: boolean; candidate: string; baseline: string };
        baseline: { source: string; ref?: string; warmP95MsMean: number };
        passed: boolean;
        checks: Array<{ name: string; passed: boolean; detail: string }>;
      };
      expect(liveParsed.processScan).toEqual({
        controlled: true,
        matched: true,
        candidate: "deterministic_ps_shim",
        baseline: "deterministic_ps_shim",
      });
      expect(liveParsed.baseline.source).toBe("live_measured");
      expect(typeof liveParsed.baseline.ref).toBe("string");
      expect(liveParsed.passed).toBe(false);
      expect(liveParsed.checks.find((c) => c.name === "concurrent_cold_git_spawns")?.passed).toBe(true);
      expect(liveParsed.checks.find((c) => c.name === "sequential_warm_git_spawns")?.passed).toBe(true);
      const liveWarmCheck = liveParsed.checks.find((c) => c.name === "sequential_warm_p95_ms");
      expect(liveWarmCheck?.passed).toBe(false);
      expect(liveWarmCheck?.detail).not.toContain("uncontrolled_or_mismatched_process_scan");
      expect(await access(fakePsMarker).then(() => true, () => false)).toBe(false);
      expect(liveParsed.baseline.warmP95MsMean).toBeLessThan(200);
      const leftoverTmp = (await readdir(isolatedTmp)).filter((name) => name.startsWith("mimi-agy-1a1-"));
      expect(leftoverTmp).toEqual([]);
    } finally {
      await rm(tmp, { recursive: true, force: true });
    }
  }, 30_000);

  test("verify-thread-list-perf.ts fails closed without one-sided ps shim when live candidate compares against ambient --baseline-json", async () => {
    const tmp = await mkdtemp(path.join(os.tmpdir(), "agy-1a1-perf-ambient-"));
    const scriptPath = path.resolve(import.meta.dir, "..", "scripts", "verify-thread-list-perf.ts");
    try {
      const ambientLiveBaselinePath = path.join(tmp, "baseline-ambient-live.json");
      await writeFile(
        ambientLiveBaselinePath,
        JSON.stringify({
          seed: 20260410,
          config: { batches: 1, cold: 1, warm: 2, concurrency: 2 },
          processScan: { status: "unmeasured", note: "Phase 0 ambient" },
          dataset: { uniqueNonOrphanRawCwds: 33 },
          summary: {
            processScanStatus: "unmeasured",
            concurrentColdGitSpawnsMeanPerRun: 128,
            sequentialWarmGitSpawnsAbsoluteAcrossAllBatches: 0,
            sequentialWarmP95MsMean: 500.0,
          },
        }),
      );
      const ambientLivePsDir = path.join(tmp, "ambient-live-ps");
      await mkdir(ambientLivePsDir, { recursive: true });
      const ambientLivePsMarker = path.join(tmp, "ambient-live-ps-invoked.log");
      const ambientLivePsPath = path.join(ambientLivePsDir, "ps");
      await writeFile(
        ambientLivePsPath,
        `#!/bin/sh\nprintf 'ambient\\n' >> "${ambientLivePsMarker}"\nprintf '1 /sbin/launchd\\n'\n`,
      );
      await chmod(ambientLivePsPath, 0o755);

      const rAmbientLive = spawnSync(
        process.execPath,
        [
          scriptPath,
          "--seed",
          "20260410",
          "--batches",
          "1",
          "--cold",
          "1",
          "--warm",
          "2",
          "--concurrency",
          "2",
          "--baseline-json",
          ambientLiveBaselinePath,
        ],
        {
          encoding: "utf8",
          env: {
            ...process.env,
            PATH: `${ambientLivePsDir}:${process.env.PATH ?? ""}`,
          },
        },
      );
      expect(rAmbientLive.status).toBe(1);
      const ambientLiveParsed = JSON.parse(rAmbientLive.stdout) as {
        processScan: { controlled: boolean; matched: boolean; candidate: string; baseline: string };
        passed: boolean;
        checks: Array<{ name: string; passed: boolean; detail: string }>;
      };
      expect(ambientLiveParsed.passed).toBe(false);
      expect(ambientLiveParsed.processScan).toEqual({
        controlled: false,
        matched: false,
        candidate: "ambient_unmeasured",
        baseline: "ambient_unmeasured",
      });
      // Candidate ran under ambient PATH instead of silently applying a one-sided ps shim.
      expect(await access(ambientLivePsMarker).then(() => true, () => false)).toBe(true);
      const ambientLiveWarmCheck = ambientLiveParsed.checks.find((c) => c.name === "sequential_warm_p95_ms");
      expect(ambientLiveWarmCheck?.passed).toBe(false);
      expect(ambientLiveWarmCheck?.detail).toContain("uncontrolled_or_mismatched_process_scan");
    } finally {
      await rm(tmp, { recursive: true, force: true });
    }
  }, 30_000);
});
