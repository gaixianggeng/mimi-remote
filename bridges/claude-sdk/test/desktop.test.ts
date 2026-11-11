// thread/desktop/open（#726、#991）：拒绝条件、标题补写、让出常驻进程与深链打开的顺序，以及只在 macOS 上声明。
import { afterAll, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import type { SessionRecord } from "../src/claude/catalog.ts";
import {
  desktopVersionSupported,
  resumeDeepLink,
  tailHasCustomTitle,
  type DesktopApp,
  type DesktopSystem,
  type OpenResult,
} from "../src/claude/desktop.ts";
import { createDesktopHandlers, isDesktopEntrypoint } from "../src/handlers/desktop.ts";
import type { SessionHolder } from "../src/runtime/holders.ts";

const sandbox = mkdtempSync(path.join(os.tmpdir(), "mimi-desktop-"));
afterAll(() => rmSync(sandbox, { recursive: true, force: true }));

const THREAD = "11111111-1111-4111-8111-111111111111";

function record(overrides: Partial<SessionRecord> = {}): SessionRecord {
  return {
    id: THREAD,
    cwd: "/work/repo",
    name: "示例会话标题",
    preview: "",
    createdAt: 1,
    updatedAt: 1,
    gitBranch: null,
    path: "/work/transcript.jsonl",
    archived: false,
    spawnedFromId: null,
    ...overrides,
  };
}

function holder(entrypoint: string, status = "idle"): SessionHolder {
  return { pid: 4242, entrypoint, kind: "interactive", status, version: "2.1.301", startedAt: 1, statusUpdatedAt: null };
}

interface Setup {
  platform?: NodeJS.Platform;
  record?: SessionRecord | undefined;
  holder?: SessionHolder;
  app?: DesktopApp | undefined;
  hasTitle?: boolean;
  busy?: boolean | (() => boolean);
  liveProcess?: boolean;
  open?: OpenResult;
  renameFails?: boolean;
}

function harness(setup: Setup = {}) {
  const calls: string[] = [];
  const busy = setup.busy ?? false;
  const runtime = {
    isBusy: () => (typeof busy === "function" ? busy() : busy),
    hasLiveProcess: () => setup.liveProcess ?? false,
    close: async () => {
      calls.push("close");
    },
  };
  const desktop: DesktopSystem = {
    platform: setup.platform ?? "darwin",
    findApp: async () => ("app" in setup ? setup.app : { path: "/Applications/Claude.app", version: "2.37337.1" }),
    openURL: async (url) => {
      calls.push(`open ${url}`);
      return setup.open ?? { ok: true };
    },
    tailHasCustomTitle: async () => setup.hasTitle ?? false,
  };
  const handlers = createDesktopHandlers({
    manager: { get: () => runtime as never },
    catalog: { get: async () => ("record" in setup ? setup.record : record()) },
    sessions: {
      rename: async (sessionId, title, dir) => {
        calls.push(`rename ${sessionId} ${title} ${dir}`);
        if (setup.renameFails) throw new Error("disk full");
      },
    },
    holders: async () => new Map(setup.holder ? [[THREAD, setup.holder]] : []),
    desktop,
  });
  return { calls, open: (params: unknown = { threadId: THREAD }) => handlers.open(params) };
}

async function rejection(promise: Promise<unknown>): Promise<{ code: number; data: Record<string, unknown> }> {
  const error = await promise.then(
    () => undefined,
    (caught) => caught,
  );
  expect(error).toBeDefined();
  return error as { code: number; data: Record<string, unknown> };
}

describe("thread/desktop/open", () => {
  test("writes the title Mimi shows, releases the idle process, then opens the resume deep link", async () => {
    const { calls, open } = harness({ liveProcess: true });
    expect(await open()).toEqual({ opened: true, titleWritten: true, alreadyInDesktop: false, desktopVersion: "2.37337.1" });
    expect(calls).toEqual([`rename ${THREAD} 示例会话标题 /work/repo`, "close", `open claude://resume?session=${THREAD}`]);
  });

  test("keeps an existing custom-title and does not touch a session without a name", async () => {
    const titled = harness({ hasTitle: true });
    expect((await titled.open()) as { titleWritten: boolean }).toMatchObject({ titleWritten: false });
    expect(titled.calls).toEqual([`open claude://resume?session=${THREAD}`]);

    const untitled = harness({ record: record({ name: null }) });
    await untitled.open();
    expect(untitled.calls).toEqual([`open claude://resume?session=${THREAD}`]);
  });

  test("a failed title write still opens the desktop", async () => {
    const { calls, open } = harness({ renameFails: true });
    expect((await open()) as { titleWritten: boolean }).toMatchObject({ opened: true, titleWritten: false });
    expect(calls.at(-1)).toBe(`open claude://resume?session=${THREAD}`);
  });

  test("a session the desktop already holds is only brought to front", async () => {
    const { calls, open } = harness({ holder: holder("claude-desktop") });
    expect((await open()) as { alreadyInDesktop: boolean }).toMatchObject({ alreadyInDesktop: true, titleWritten: false });
    expect(calls).toEqual([`open claude://resume?session=${THREAD}`]);
  });

  test("a desktop configured with a third-party gateway is recognised by prefix (#991)", async () => {
    const { calls, open } = harness({ holder: holder("claude-desktop-3p") });
    expect((await open()) as { alreadyInDesktop: boolean }).toMatchObject({ alreadyInDesktop: true });
    expect(calls).toEqual([`open claude://resume?session=${THREAD}`]);
    expect(isDesktopEntrypoint("claude-desktop")).toBe(true);
    expect(isDesktopEntrypoint("cli")).toBe(false);
    expect(isDesktopEntrypoint(null)).toBe(false);
  });

  test("refuses while a terminal claude holds the session", async () => {
    const { calls, open } = harness({ holder: holder("cli") });
    const error = await rejection(open());
    expect(error.data).toMatchObject({ accepted: false, reason: "held_elsewhere", retryable: true, claudeOwner: { pid: 4242, entrypoint: "cli" } });
    expect(calls).toEqual([]);
  });

  test("refuses while this adapter is still running a turn, including one that starts during the title write", async () => {
    expect((await rejection(harness({ busy: true }).open())).data).toMatchObject({ reason: "turn_active", retryable: true });

    let checks = 0;
    const late = harness({ busy: () => ++checks > 1, liveProcess: true });
    expect((await rejection(late.open())).data).toMatchObject({ reason: "turn_active" });
    expect(late.calls).toEqual([`rename ${THREAD} 示例会话标题 /work/repo`]);
  });

  test("reports a missing, outdated or unopenable desktop app", async () => {
    expect((await rejection(harness({ app: undefined }).open())).data).toMatchObject({ reason: "not_installed" });
    expect((await rejection(harness({ app: { path: "/Applications/Claude.app", version: "1.0.5" } }).open())).data).toMatchObject({
      reason: "outdated",
      version: "1.0.5",
      minimumVersion: "1.1.9669",
    });
    const failed = await rejection(harness({ open: { ok: false, detail: "no application can open the URL" } }).open());
    expect(failed.data).toMatchObject({ reason: "open_failed", detail: "no application can open the URL", retryable: true });
  });

  test("an unreadable app version is not a reason to refuse", async () => {
    expect(await harness({ app: { path: "/Applications/Claude.app", version: null } }).open()).toMatchObject({ opened: true });
  });

  test("validates the request before looking at anything else", async () => {
    expect((await rejection(harness().open({}))).code).toBe(-32602);
    expect((await rejection(harness({ record: undefined }).open())).code).toBe(-32602);
    const windows = await rejection(harness({ platform: "win32" }).open());
    expect(windows.data).toMatchObject({ reason: "unsupported_platform", retryable: false });
  });
});

describe("desktop helpers", () => {
  test("version gate follows the CLI minimum", () => {
    expect(desktopVersionSupported("1.1.9669")).toBe(true);
    expect(desktopVersionSupported("2.37337.1")).toBe(true);
    expect(desktopVersionSupported("1.1.9668")).toBe(false);
    expect(desktopVersionSupported("beta")).toBeUndefined();
  });

  test("the deep link carries only the session id", () => {
    expect(resumeDeepLink(THREAD)).toBe(`claude://resume?session=${THREAD}`);
  });

  test("only a custom-title inside the desktop's tail window counts", async () => {
    const file = path.join(sandbox, "tail.jsonl");
    const title = `{"type":"custom-title","customTitle":"旧标题","sessionId":"${THREAD}"}\n`;
    const filler = `${JSON.stringify({ type: "user", message: { content: "x".repeat(200) } })}\n`;
    writeFileSync(file, title + filler.repeat(10));
    expect(await tailHasCustomTitle(file, 64 * 1024)).toBe(true);
    // 标题被挤出窗口：桌面版读不到，需要补写。
    expect(await tailHasCustomTitle(file, filler.length * 3)).toBe(false);
    // 窗口起点落在标题那一行中间：半行不算。
    writeFileSync(file, filler + title);
    expect(await tailHasCustomTitle(file, title.length - 5)).toBe(false);
    // 只有 ai-title 不算。
    writeFileSync(file, `{"type":"ai-title","aiTitle":"自动标题","sessionId":"${THREAD}"}\n`);
    expect(await tailHasCustomTitle(file)).toBe(false);
  });
});

describe("capability declaration", () => {
  test("thread/desktop/open is declared only where the desktop deep link exists", async () => {
    process.env.CLAUDE_CONFIG_DIR = path.join(sandbox, "claude");
    process.env.MIMI_CLAUDE_LEGACY_INDEX = "";
    const { createApp, capabilityDeclaration } = await import("../src/app.ts");
    const declared = (platform: NodeJS.Platform) => {
      const app = createApp({
        stateDir: path.join(sandbox, `state-${platform}`),
        log: () => {},
        desktop: { platform, findApp: async () => undefined, openURL: async () => ({ ok: true }), tailHasCustomTitle: async () => false },
      });
      return capabilityDeclaration(app.router).methods;
    };
    try {
      expect(declared("darwin")).toContain("thread/desktop/open");
      expect(declared("win32")).not.toContain("thread/desktop/open");
      expect(declared("linux")).not.toContain("thread/desktop/open");
    } finally {
      delete process.env.CLAUDE_CONFIG_DIR;
      delete process.env.MIMI_CLAUDE_LEGACY_INDEX;
    }
  });
});
