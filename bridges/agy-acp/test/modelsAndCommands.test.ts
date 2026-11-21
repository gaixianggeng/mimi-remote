import { describe, expect, test } from "bun:test";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { sanitizeAgyEnv } from "../src/agy/env.ts";
import { catalogAgyCommands } from "../src/agy/commands.ts";
import { catalogAgyModels } from "../src/agy/models.ts";
import {
  detectExternalConcurrentWrite,
  formatTranscriptUserText,
  inspectTranscriptActivity,
  readTranscriptTurns,
} from "../src/agy/transcript.ts";
import { agyModeFor, runSettingsFor } from "../src/runtime/settings.ts";

describe("agy env & settings & catalogs", () => {
  test("sanitizeAgyEnv strips ANTIGRAVITY_* and __CFBundleIdentifier while preserving PATH/HOME", () => {
    const clean = sanitizeAgyEnv({
      HOME: "/tmp/test-home",
      PATH: "/usr/bin:/bin",
      ANTIGRAVITY_APP_DATA_DIR: "antigravity",
      ANTIGRAVITY_CONVERSATION_ID: "desktop-1",
      __CFBundleIdentifier: "com.google.antigravity",
      AGY_ACCOUNT: "work",
    });
    expect(clean.HOME).toBe("/tmp/test-home");
    expect(clean.PATH).toBe("/usr/bin:/bin");
    expect(clean.AGY_ACCOUNT).toBe("work");
    expect(clean.ANTIGRAVITY_APP_DATA_DIR).toBeUndefined();
    expect(clean.ANTIGRAVITY_CONVERSATION_ID).toBeUndefined();
    expect(clean.__CFBundleIdentifier).toBeUndefined();
  });

  test("catalogAgyModels preserves model families and per-model thought_level support including Hydrogen xhigh", () => {
    const models = catalogAgyModels({
      sessionId: "s1",
      models: {
        currentModelId: "gemini-4-carbon-medium",
        availableModels: [
          { modelId: "gemini-4-carbon-low", name: "Gemini 4 Carbon (Low)" },
          { modelId: "gemini-4-carbon-medium", name: "Gemini 4 Carbon (Medium)" },
          { modelId: "gemini-4-carbon-high", name: "Gemini 4 Carbon (High)" },
          { modelId: "gemini-4-hydrogen-low", name: "Gemini 4 Hydrogen (Low)" },
          { modelId: "gemini-4-hydrogen-medium", name: "Gemini 4 Hydrogen (Medium)" },
          { modelId: "gemini-4-hydrogen-high", name: "Gemini 4 Hydrogen (High)" },
          { modelId: "gemini-4-hydrogen-xhigh", name: "Gemini 4 Hydrogen (XHigh)" },
          { modelId: "gemini-pro-orchestrator", name: "Orchestrator (Carbon)" },
          { modelId: "gpt-oss-120b-medium", name: "GPT-OSS 120B (Medium)" },
        ],
      },
      configOptions: [
        {
          id: "model",
          name: "Model",
          type: "select",
          currentValue: "gemini-4-carbon",
          options: [
            { value: "gemini-4-carbon", name: "Gemini 4 Carbon" },
            { value: "gemini-4-hydrogen", name: "Gemini 4 Hydrogen" },
            { value: "gemini-pro-orchestrator", name: "Orchestrator (Carbon)" },
            { value: "gpt-oss-120b-medium", name: "GPT-OSS 120B (Medium)" },
          ],
        },
        {
          id: "thought_level",
          name: "Thinking Level",
          type: "select",
          currentValue: "medium",
          options: [
            { value: "low", name: "Low" },
            { value: "medium", name: "Medium" },
            { value: "high", name: "High" },
          ],
        },
      ],
    });

    expect(models.map((m) => m.id)).toEqual([
      "gemini-4-carbon",
      "gemini-4-hydrogen",
      "gemini-pro-orchestrator",
      "gpt-oss-120b-medium",
    ]);
    expect(models[0]?.isDefault).toBe(true);
    expect(models[0]?.supportedReasoningEfforts.map((e) => e.reasoningEffort)).toEqual(["low", "medium", "high"]);
    expect(models[1]?.supportedReasoningEfforts.map((e) => e.reasoningEffort)).toEqual(["low", "medium", "high", "xhigh"]);
    expect(models[2]?.supportedReasoningEfforts).toEqual([]);
    expect(models[2]?.defaultReasoningEffort).toBe("none");
    expect(models[3]?.supportedReasoningEfforts.map((e) => e.reasoningEffort)).toEqual(["medium"]);
  });

  test("catalogAgyCommands keeps native slash commands & skills while filtering conflicting TUI commands", () => {
    const entries = catalogAgyCommands([
      { name: "goal", description: "Run until goal achieved" },
      { name: "grill-me", description: "Align on plan" },
      { name: "clear", description: "Clear session" },
      { name: "exit", description: "Quit CLI" },
      { name: "model", description: "Switch model" },
      { name: "custom-skill", description: "Project skill" },
    ]);
    expect(entries.map((c) => c.name)).toEqual(["goal", "grill-me", "custom-skill"]);
  });

  test("runSettingsFor maps Mimi permission modes & Plan toggle to Antigravity native modes (D2)", () => {
    expect(runSettingsFor({ approvalPolicy: "on-request", approvalsReviewer: "user", sandboxPolicy: { type: "workspaceWrite" } }).mode).toBe("default");
    expect(runSettingsFor({ approvalPolicy: "on-request", approvalsReviewer: "accept_edits", sandboxPolicy: { type: "workspaceWrite" } }).mode).toBe("accept-edits");
    expect(runSettingsFor({ approvalPolicy: "on-request", approvalsReviewer: "auto_review", sandboxPolicy: { type: "workspaceWrite" } }).mode).toBe("auto");
    expect(runSettingsFor({ approvalPolicy: "never", sandboxPolicy: { type: "dangerFullAccess" } }).mode).toBe("auto");
    expect(runSettingsFor({ collaborationMode: { mode: "plan" }, sandboxPolicy: { type: "workspaceWrite" } }).mode).toBe("plan");
    expect(agyModeFor({}, { type: "readOnly", networkAccess: false })).toBe("plan");
  });

  test("formatTranscriptUserText expands @[Quote] and @[ITEM] references into readable blockquotes", () => {
    const raw = `<USER_REQUEST>
@[Quote] 按照你推荐的方案来进行处理就可以
</USER_REQUEST>
<ADDITIONAL_METADATA>
The current local time is: 2026-11-18T11:59:15+08:00.

The user has mentioned some items in the form @[ITEM]. Here is extra information about the items that were mentioned by the user, in the order that they appear:

@[Quote] is a [Text Block]:
D1–D6 的倾向
</ADDITIONAL_METADATA>`;
    expect(formatTranscriptUserText(raw)).toBe("> D1–D6 的倾向\n\n按照你推荐的方案来进行处理就可以");
  });

  test("readTranscriptTurns and inspectTranscriptActivity decode quotes, media, tools, and live desktop busy state", async () => {
    const tempRoot = await mkdtemp(path.join(os.tmpdir(), "agy-transcript-test-"));
    try {
      const sessionId = "desktop-session-1";
      const logsDir = path.join(tempRoot, ".gemini", "antigravity", "brain", sessionId, ".system_generated", "logs");
      await mkdir(logsDir, { recursive: true });
      const imagePath = path.join(tempRoot, "shot.png");
      await writeFile(imagePath, Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]));
      const transcriptPath = path.join(logsDir, "transcript_full.jsonl");
      const lines = [
        JSON.stringify({
          step_index: 0,
          source: "USER_EXPLICIT",
          type: "USER_INPUT",
          status: "DONE",
          created_at: "2026-11-19T14:00:00Z",
          content: "<USER_REQUEST>\n看下这张图\n</USER_REQUEST>",
          media: [{ mime_type: "image/png", uri: imagePath }],
        }),
        JSON.stringify({
          step_index: 1,
          source: "MODEL",
          type: "PLANNER_RESPONSE",
          status: "DONE",
          created_at: "2026-11-19T14:00:02Z",
          thinking: "Let me check",
          tool_calls: [{ name: "run_command", args: { CommandLine: "\"echo ok\"" } }],
        }),
        JSON.stringify({
          step_index: 2,
          source: "MODEL",
          type: "GENERIC",
          status: "RUNNING",
          created_at: "2026-11-19T14:00:03Z",
          content: "running...",
        }),
      ];
      await writeFile(transcriptPath, `${lines.join("\n")}\n`);

      const activity = await inspectTranscriptActivity(sessionId, "other", { HOME: tempRoot });
      expect(activity?.externallyBusy).toBe(true);

      const turns = await readTranscriptTurns(sessionId, "/workspace", transcriptPath, false, true);
      expect(turns).toHaveLength(1);
      expect(turns[0]?.status).toBe("completed");
      const userItem = turns[0]?.items.find((item) => item.type === "userMessage");
      expect(userItem?.type === "userMessage" ? userItem.content.map((c) => c.type) : []).toEqual(["text", "image"]);
      const cmdItem = turns[0]?.items.find((item) => item.type === "commandExecution");
      expect(cmdItem?.type === "commandExecution" ? cmdItem.status : "").toBe("inProgress");
    } finally {
      await rm(tempRoot, { recursive: true, force: true });
    }
  });

  test("C12: detectExternalConcurrentWrite flags external USER_INPUT and approval-window writes without false positives", () => {
    const baseline = {
      userInputCount: 1,
      expectedPromptText: "Run pwd and wait for approval",
    };
    // Own USER_INPUT matching prompt is NOT a conflict.
    expect(
      detectExternalConcurrentWrite(baseline, {
        path: "/tmp/t.jsonl",
        size: 100,
        mtimeMs: Date.now(),
        userInputs: ["prior turn", "Run pwd and wait for approval"],
        plannerResponseCount: 1,
        stepCount: 3,
      }).detected,
    ).toBe(false);

    // Second new USER_INPUT during active turn IS a conflict.
    expect(
      detectExternalConcurrentWrite(baseline, {
        path: "/tmp/t.jsonl",
        size: 200,
        mtimeMs: Date.now(),
        userInputs: ["prior turn", "Run pwd and wait for approval", "CROSS MAC CONTENDING"],
        plannerResponseCount: 2,
        stepCount: 5,
      }),
    ).toEqual({ detected: true, reason: "multiple_user_inputs_during_active_turn" });

    // Any new PLANNER_RESPONSE during pending approval IS a conflict.
    expect(
      detectExternalConcurrentWrite(
        {
          ...baseline,
          approvalUserInputCount: 2,
          approvalPlannerResponseCount: 1,
        },
        {
          path: "/tmp/t.jsonl",
          size: 240,
          mtimeMs: Date.now(),
          userInputs: ["prior turn", "Run pwd and wait for approval"],
          plannerResponseCount: 2,
          stepCount: 4,
        },
      ),
    ).toEqual({ detected: true, reason: "external_planner_response_during_pending_approval" });
  });
});
