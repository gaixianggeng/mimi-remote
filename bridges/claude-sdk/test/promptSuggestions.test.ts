import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import type { Options } from "@anthropic-ai/claude-agent-sdk";
import { ClaudeCodeVersionGate } from "../src/claude/claudeCode.ts";
import { promptSuggestionsAllowed } from "../src/claude/promptSuggestions.ts";
import type { OutboundFrame } from "../src/rpc/frames.ts";
import { ThreadManager } from "../src/runtime/manager.ts";
import { Session } from "../src/session/session.ts";
import { ScriptedQuery } from "./support/scripted-query.ts";

const managers: ThreadManager[] = [];
const sandbox = realpathSync(mkdtempSync(path.join(os.tmpdir(), "mimi-prompt-suggestions-")));
let previousConfig: string | undefined;
let previousSuggestionEnvironment: string | undefined;
beforeAll(() => {
  previousConfig = process.env.CLAUDE_CONFIG_DIR;
  previousSuggestionEnvironment = process.env.CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION;
  process.env.CLAUDE_CONFIG_DIR = path.join(sandbox, "runtime-settings");
  delete process.env.CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION;
});
afterAll(() => {
  if (previousConfig === undefined) delete process.env.CLAUDE_CONFIG_DIR;
  else process.env.CLAUDE_CONFIG_DIR = previousConfig;
  if (previousSuggestionEnvironment === undefined) delete process.env.CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION;
  else process.env.CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION = previousSuggestionEnvironment;
  rmSync(sandbox, { recursive: true, force: true });
});
afterEach(async () => { await Promise.all(managers.splice(0).map((manager) => manager.closeAll())); });
const method = "_mimi/turn/promptSuggestion";
const settle = () => new Promise<void>((resolve) => setImmediate(resolve));

function harness(supported = true) {
  let query!: ScriptedQuery;
  let options!: Options;
  const manager = new ThreadManager({
    claudeExecutable: () => "unused",
    promptSuggestionsSupported: () => supported,
    log: () => {},
    startQuery: ((args: { prompt: AsyncIterable<unknown>; options: Options }) => {
      query = new ScriptedQuery();
      query.attach(args.prompt);
      options = args.options;
      return query;
    }) as never,
  });
  managers.push(manager);
  const runtime = manager.create(sandbox, {
    model: undefined, effort: undefined, permissionMode: "default",
    executionPolicy: { type: "dangerFullAccess" },
  });
  const frames: OutboundFrame[] = [];
  const session = new Session("suggestions");
  let generation = session.attach(undefined, (frame) => frames.push(frame), false).generation;
  manager.subscribe(runtime.threadId, session);
  return {
    manager, runtime, session, frames,
    options: () => options,
    start: () => runtime.startTurn({ input: [{ type: "text", text: "next", text_elements: [] }], clientUserMessageId: null, settings: {} }),
    async result(turnId: string, subtype = "success") {
      query.emit({ type: "result", subtype, user_message_uuids: [turnId], session_id: runtime.threadId });
      await settle();
    },
    async suggest(extra: Record<string, unknown> = {}) {
      query.emit({ type: "prompt_suggestion", uuid: "suggestion-1", session_id: runtime.threadId, suggestion: "  补上回归测试  ", ...extra });
      await settle();
    },
    suggestions: () => frames.filter((frame) => frame.method === method),
    reconnect() {
      session.detach(generation);
      const attached = session.attach(0, (frame) => frames.push(frame), true);
      generation = attached.generation;
      session.flushBacklog(attached.backlog, generation);
      return attached;
    },
  };
}

describe("native prompt suggestions", () => {
  test("preserves explicit disable preferences without loading hooks or other settings", async () => {
    const config = path.join(sandbox, "preferences");
    const project = path.join(sandbox, "preferences-project");
    mkdirSync(config, { recursive: true });
    mkdirSync(path.join(project, ".claude"), { recursive: true });
    expect(await promptSuggestionsAllowed(config, project, "")).toBe(true);
    writeFileSync(path.join(config, "settings.json"), JSON.stringify({ promptSuggestionEnabled: false, hooks: { ignored: true } }));
    expect(await promptSuggestionsAllowed(config, project, "")).toBe(false);
    expect(await promptSuggestionsAllowed(config, project, "true")).toBe(true);
    expect(await promptSuggestionsAllowed(config, project, "false")).toBe(false);
    writeFileSync(path.join(config, "settings.json"), "{}");
    writeFileSync(path.join(project, ".claude/settings.local.json"), JSON.stringify({ promptSuggestionEnabled: false }));
    expect(await promptSuggestionsAllowed(config, project, "")).toBe(false);
    writeFileSync(path.join(project, ".claude/settings.local.json"), "invalid json");
    expect(await promptSuggestionsAllowed(config, project, "")).toBe(false);
  });

  test("disabled settings omit the option and ignore unsolicited suggestion events", async () => {
    const config = process.env.CLAUDE_CONFIG_DIR!;
    mkdirSync(config, { recursive: true });
    const settings = path.join(config, "settings.json");
    writeFileSync(settings, JSON.stringify({ promptSuggestionEnabled: false }));
    const previous = process.env.CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION;
    delete process.env.CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION;
    try {
      const h = harness();
      const turn = await h.start();
      expect(h.options().promptSuggestions).toBeUndefined();
      await h.result(turn.id);
      await h.suggest();
      expect(h.suggestions()).toHaveLength(0);
    } finally {
      rmSync(settings);
      if (previous !== undefined) process.env.CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION = previous;
    }
  });

  test("only enables the option on a verified supported CLI; unknown and older CLIs degrade", async () => {
    for (const [version, supported] of [["2.1.294", false], ["2.1.307", true]] as const) {
      const gate = new ClaudeCodeVersionGate(() => "claude", async () => ({ status: "ok", version }));
      expect(gate.supportsPromptSuggestions).toBe(false);
      await gate.ensure();
      expect(gate.supportsPromptSuggestions).toBe(supported);
    }
    const h = harness(false);
    const turn = await h.start();
    expect(h.options().promptSuggestions).toBeUndefined();
    await h.result(turn.id);
    await h.suggest();
    expect(h.suggestions()).toHaveLength(0);
  });

  test("binds the post-result suggestion, drops duplicates and never queues another user message", async () => {
    const h = harness();
    const turn = await h.start();
    expect(h.options().promptSuggestions).toBe(true);
    expect(h.options().env?.CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION).toBe(process.env.CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION);
    await h.suggest();
    expect(h.suggestions()).toHaveLength(0);
    await h.result(turn.id);
    await h.suggest();
    await h.suggest();
    expect(h.suggestions()).toEqual([{ jsonrpc: "2.0", method, params: {
      threadId: h.runtime.threadId, turnId: turn.id, id: "suggestion-1", text: "补上回归测试",
    } }]);
    expect(h.runtime.activeTurnId).toBeUndefined();
    expect(h.frames.filter((frame) => frame.method === "turn/started")).toHaveLength(1);
    expect(h.reconnect().backlog.some((entry) => entry.frame.method === method)).toBe(false);
  });

  test("does not deliver a late suggestion after reconnect or to a new subscriber", async () => {
    const h = harness();
    const turn = await h.start();
    await h.result(turn.id);
    h.reconnect();
    const newcomer = new Session("newcomer");
    const received: OutboundFrame[] = [];
    newcomer.attach(undefined, (frame) => received.push(frame), false);
    h.manager.subscribe(h.runtime.threadId, newcomer);
    await h.suggest();
    expect(h.suggestions()).toHaveLength(0);
    expect(received.some((frame) => frame.method === method)).toBe(false);
  });

  test("a new turn and an interrupted or failed turn invalidate suggestions", async () => {
    const h = harness();
    const first = await h.start();
    await h.result(first.id);
    const second = await h.start();
    await h.suggest();
    await h.runtime.interrupt(second.id);
    await h.result(second.id);
    await h.suggest();
    const third = await h.start();
    await h.result(third.id, "error_during_execution");
    await h.suggest();
    expect(h.suggestions()).toHaveLength(0);
  });

  test("ignores wrong sessions and malformed or oversized suggestions", async () => {
    const h = harness();
    const turn = await h.start();
    await h.result(turn.id);
    for (const extra of [{ session_id: "different" }, { uuid: "" }, { suggestion: null }, { suggestion: "  " }, { suggestion: "x".repeat(4_097) }]) {
      await h.suggest(extra);
    }
    expect(h.suggestions()).toHaveLength(0);
    await h.suggest();
    expect(h.suggestions()).toHaveLength(1);
  });
});
