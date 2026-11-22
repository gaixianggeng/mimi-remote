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
  snapshotTranscriptStateDetailed,
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
      expect(turns[0]?.status).toBe("inProgress");
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

  test("B10: readTranscriptTurns preserves failed ERROR_MESSAGE and cancelled/interrupted turn status", async () => {
    const tempRoot = await mkdtemp(path.join(os.tmpdir(), "agy-transcript-b10-"));
    try {
      const transcriptPath = path.join(tempRoot, "transcript_full.jsonl");
      const lines = [
        JSON.stringify({
          step_index: 0,
          type: "USER_INPUT",
          status: "DONE",
          created_at: "2026-11-21T10:00:00Z",
          content: "<USER_REQUEST>\ntrigger error\n</USER_REQUEST>",
        }),
        JSON.stringify({
          step_index: 1,
          type: "ERROR_MESSAGE",
          status: "ERROR",
          created_at: "2026-11-21T10:00:01Z",
          content: "Error: EDGE_FIXTURE_E42: injected turn failure",
        }),
        JSON.stringify({
          step_index: 2,
          type: "USER_INPUT",
          status: "DONE",
          created_at: "2026-11-21T10:00:02Z",
          content: "<USER_REQUEST>\nstop me\n</USER_REQUEST>",
        }),
        JSON.stringify({
          step_index: 3,
          type: "PLANNER_RESPONSE",
          status: "CANCELLED",
          created_at: "2026-11-21T10:00:03Z",
          content: "partial output",
        }),
      ];
      await writeFile(transcriptPath, `${lines.join("\n")}\n`);

      const turns = await readTranscriptTurns("sess-b10", "/workspace", transcriptPath, false, false);
      expect(turns).toHaveLength(2);
      expect(turns[0]?.status).toBe("failed");
      expect(turns[0]?.error?.message).toBe("Error: EDGE_FIXTURE_E42: injected turn failure");
      expect(turns[1]?.status).toBe("interrupted");
      expect(turns[1]?.error).toBeNull();
    } finally {
      await rm(tempRoot, { recursive: true, force: true });
    }
  });

  test("B10 round2: readTranscriptTurns treats recoverable intermediate ERROR_MESSAGE followed by DONE planner reply as completed", async () => {
    const tempRoot = await mkdtemp(path.join(os.tmpdir(), "agy-transcript-b10-recover-"));
    try {
      const transcriptPath = path.join(tempRoot, "transcript_full.jsonl");
      const lines = [
        JSON.stringify({
          step_index: 0,
          type: "USER_INPUT",
          status: "DONE",
          created_at: "2026-11-21T10:00:00Z",
          content: "<USER_REQUEST>\nrun tool that fails once then recovers\n</USER_REQUEST>",
        }),
        JSON.stringify({
          step_index: 1,
          type: "PLANNER_RESPONSE",
          status: "DONE",
          created_at: "2026-11-21T10:00:01Z",
          tool_calls: [{ name: "run_command", args: { CommandLine: "\"false\"" } }],
        }),
        JSON.stringify({
          step_index: 2,
          type: "GENERIC",
          status: "ERROR",
          created_at: "2026-11-21T10:00:02Z",
          content: "command exited 1",
        }),
        JSON.stringify({
          step_index: 3,
          type: "ERROR_MESSAGE",
          status: "ERROR",
          created_at: "2026-11-21T10:00:02Z",
          content: "Transient tool failure",
        }),
        JSON.stringify({
          step_index: 4,
          type: "PLANNER_RESPONSE",
          status: "DONE",
          created_at: "2026-11-21T10:00:03Z",
          content: "Handled the command failure and finished cleanly.",
        }),
      ];
      await writeFile(transcriptPath, `${lines.join("\n")}\n`);

      const turns = await readTranscriptTurns("sess-b10-recover", "/workspace", transcriptPath, false, false);
      expect(turns).toHaveLength(1);
      expect(turns[0]?.status).toBe("completed");
      expect(turns[0]?.error).toBeNull();
      const cmdItem = turns[0]?.items.find((item) => item.type === "commandExecution");
      expect(cmdItem && cmdItem.type === "commandExecution" ? cmdItem.status : null).toBe("failed");
    } finally {
      await rm(tempRoot, { recursive: true, force: true });
    }
  });

  test("C11 round2: readTranscriptTurns marks the last turn inProgress while external Mac holder is busy and completed when idle", async () => {
    const tempRoot = await mkdtemp(path.join(os.tmpdir(), "agy-transcript-c11-"));
    try {
      const transcriptPath = path.join(tempRoot, "transcript_full.jsonl");
      const lines = [
        JSON.stringify({
          step_index: 0,
          type: "USER_INPUT",
          status: "DONE",
          created_at: "2026-11-22T01:00:00Z",
          content: "<USER_REQUEST>\nfirst completed turn\n</USER_REQUEST>",
        }),
        JSON.stringify({
          step_index: 1,
          type: "PLANNER_RESPONSE",
          status: "DONE",
          created_at: "2026-11-22T01:00:02Z",
          content: "first done",
        }),
        JSON.stringify({
          step_index: 2,
          type: "USER_INPUT",
          status: "DONE",
          created_at: "2026-11-22T01:01:00Z",
          content: "<USER_REQUEST>\nrun sleep 55\n</USER_REQUEST>",
        }),
        JSON.stringify({
          step_index: 3,
          type: "PLANNER_RESPONSE",
          status: "RUNNING",
          created_at: "2026-11-22T01:01:01Z",
          tool_calls: [{ name: "run_command", args: { CommandLine: "\"sleep 55\"" } }],
        }),
      ];
      await writeFile(transcriptPath, `${lines.join("\n")}\n`);

      const whileBusy = await readTranscriptTurns("sess-c11", "/workspace", transcriptPath, false, true);
      expect(whileBusy).toHaveLength(2);
      expect(whileBusy[0]?.status).toBe("completed");
      expect(whileBusy[1]?.status).toBe("inProgress");
      expect(whileBusy[1]?.completedAt).toBeNull();

      const afterIdle = await readTranscriptTurns("sess-c11", "/workspace", transcriptPath, false, false);
      expect(afterIdle).toHaveLength(2);
      expect(afterIdle[1]?.status).toBe("completed");
    } finally {
      await rm(tempRoot, { recursive: true, force: true });
    }
  });

  test("C12 round3: snapshotTranscriptStateDetailed distinguishes missing, present, malformed JSONL, and non-file/IO errors", async () => {
    const tempHome = await mkdtemp(path.join(os.tmpdir(), "agy-c12-inspect-"));
    try {
      const env = { HOME: tempHome };

      // 1) Truly missing transcript
      const missing = await snapshotTranscriptStateDetailed("sess-missing", "cli", env);
      expect(missing).toEqual({ kind: "missing" });

      // 2) Valid transcript -> present
      const validLogsDir = path.join(tempHome, ".gemini", "antigravity-cli", "brain", "sess-valid", ".system_generated", "logs");
      await mkdir(validLogsDir, { recursive: true });
      await writeFile(
        path.join(validLogsDir, "transcript_full.jsonl"),
        `${JSON.stringify({ step_index: 0, type: "USER_INPUT", content: "<USER_REQUEST>\nhi\n</USER_REQUEST>" })}\n`,
      );
      const present = await snapshotTranscriptStateDetailed("sess-valid", "cli", env);
      expect(present.kind).toBe("present");
      if (present.kind === "present") {
        expect(present.snapshot.userInputs).toEqual(["hi"]);
      }

      // 3) Malformed JSONL -> error (NOT missing)
      const corruptLogsDir = path.join(tempHome, ".gemini", "antigravity-cli", "brain", "sess-corrupt", ".system_generated", "logs");
      await mkdir(corruptLogsDir, { recursive: true });
      await writeFile(path.join(corruptLogsDir, "transcript_full.jsonl"), "{not-valid-json\n");
      const corrupt = await snapshotTranscriptStateDetailed("sess-corrupt", "cli", env);
      expect(corrupt.kind).toBe("error");
      if (corrupt.kind === "error") {
        expect(corrupt.reason).toBe("malformed_transcript");
      }

      // 4) Non-file (directory at transcript path) -> error (NOT missing)
      const dirLogsDir = path.join(tempHome, ".gemini", "antigravity-cli", "brain", "sess-dir", ".system_generated", "logs");
      await mkdir(path.join(dirLogsDir, "transcript_full.jsonl"), { recursive: true });
      const nonFile = await snapshotTranscriptStateDetailed("sess-dir", "cli", env);
      expect(nonFile.kind).toBe("error");
      if (nonFile.kind === "error") {
        expect(nonFile.reason).toBe("transcript_not_a_file");
      }
    } finally {
      await rm(tempHome, { recursive: true, force: true });
    }
  });

  test("B10 round3: non-terminal or tool-calling planner text after ERROR_MESSAGE does NOT clear failed turn status", async () => {
    const tempRoot = await mkdtemp(path.join(os.tmpdir(), "agy-transcript-b10-nonterminal-"));
    try {
      const transcriptPath = path.join(tempRoot, "transcript_full.jsonl");
      const lines = [
        // Turn 1: ERROR_MESSAGE followed by RUNNING planner text (non-terminal) -> MUST stay failed!
        JSON.stringify({
          step_index: 0,
          type: "USER_INPUT",
          status: "DONE",
          created_at: "2026-11-22T01:00:00Z",
          content: "<USER_REQUEST>\nturn with running partial text after error\n</USER_REQUEST>",
        }),
        JSON.stringify({
          step_index: 1,
          type: "ERROR_MESSAGE",
          status: "ERROR",
          created_at: "2026-11-22T01:00:01Z",
          content: "FATAL_UPSTREAM_ERR_1",
        }),
        JSON.stringify({
          step_index: 2,
          type: "PLANNER_RESPONSE",
          status: "RUNNING",
          created_at: "2026-11-22T01:00:02Z",
          content: "Trying to recover...",
        }),
        // Turn 2: ERROR_MESSAGE followed by DONE planner step that still invokes a tool (no final answer) -> MUST stay failed!
        JSON.stringify({
          step_index: 3,
          type: "USER_INPUT",
          status: "DONE",
          created_at: "2026-11-22T01:01:00Z",
          content: "<USER_REQUEST>\nturn with tool call after error\n</USER_REQUEST>",
        }),
        JSON.stringify({
          step_index: 4,
          type: "ERROR_MESSAGE",
          status: "ERROR",
          created_at: "2026-11-22T01:01:01Z",
          content: "FATAL_UPSTREAM_ERR_2",
        }),
        JSON.stringify({
          step_index: 5,
          type: "PLANNER_RESPONSE",
          status: "DONE",
          created_at: "2026-11-22T01:01:02Z",
          content: "Retrying tool",
          tool_calls: [{ name: "run_command", args: { CommandLine: "\"echo retry\"" } }],
        }),
      ];
      await writeFile(transcriptPath, `${lines.join("\n")}\n`);

      const turns = await readTranscriptTurns("sess-b10-nt", "/workspace", transcriptPath, false, false);
      expect(turns).toHaveLength(2);
      expect(turns[0]?.status).toBe("failed");
      expect(turns[0]?.error?.message).toBe("FATAL_UPSTREAM_ERR_1");
      expect(turns[1]?.status).toBe("failed");
      expect(turns[1]?.error?.message).toBe("FATAL_UPSTREAM_ERR_2");
    } finally {
      await rm(tempRoot, { recursive: true, force: true });
    }
  });

  test("C11 round3: interim DONE planner reply while native GENERIC tool is still RUNNING keeps externallyBusy true until completion signal + final reply", async () => {
    const tempHome = await mkdtemp(path.join(os.tmpdir(), "agy-c11-interim-"));
    try {
      const sessionId = "sess-c11-long-tool";
      const logsDir = path.join(tempHome, ".gemini", "antigravity-cli", "brain", sessionId, ".system_generated", "logs");
      await mkdir(logsDir, { recursive: true });
      const transcriptPath = path.join(logsDir, "transcript_full.jsonl");
      const env = { HOME: tempHome };

      const earlySteps = [
        { step_index: 0, type: "USER_INPUT", status: "DONE", created_at: "2026-11-22T02:28:00Z", content: "<USER_REQUEST>\nbase\n</USER_REQUEST>" },
        { step_index: 1, type: "PLANNER_RESPONSE", status: "DONE", created_at: "2026-11-22T02:28:01Z", content: "BASE OK" },
        { step_index: 2, type: "USER_INPUT", status: "DONE", created_at: "2026-11-22T02:28:57Z", content: "<USER_REQUEST>\nrun sleep 55\n</USER_REQUEST>" },
        { step_index: 3, type: "SYSTEM_MESSAGE", status: "DONE", created_at: "2026-11-22T02:28:57Z" },
        { step_index: 4, type: "PLANNER_RESPONSE", status: "DONE", created_at: "2026-11-22T02:28:57Z", tool_calls: [{ name: "run_command", args: { CommandLine: "\"sleep 55\"" } }] },
        { step_index: 5, type: "GENERIC", status: "RUNNING", created_at: "2026-11-22T02:29:04Z" },
      ];
      await writeFile(transcriptPath, `${earlySteps.map((s) => JSON.stringify(s)).join("\n")}\n`);

      // Stage 1 (early): GENERIC RUNNING -> externallyBusy === true
      const earlyInfo = await inspectTranscriptActivity(sessionId, "cli", env, {
        findExternalHolderPid: async () => null,
      });
      expect(earlyInfo?.externallyBusy).toBe(true);

      // Stage 2 (mid-flight): native CLI writes interim PLANNER_RESPONSE (DONE, "Waiting for sleep 55 to finish.") while step 5 is STILL RUNNING!
      const midFlightSteps = [
        ...earlySteps,
        { step_index: 6, type: "PLANNER_RESPONSE", status: "DONE", created_at: "2026-11-22T02:29:14Z", content: "Waiting for `sleep 55` to finish." },
      ];
      await writeFile(transcriptPath, `${midFlightSteps.map((s) => JSON.stringify(s)).join("\n")}\n`);
      const midFlightInfo = await inspectTranscriptActivity(sessionId, "cli", env, {
        findExternalHolderPid: async () => null,
      });
      expect(midFlightInfo?.externallyBusy).toBe(true);

      // Stage 3 (post-exit): command finishes -> SYSTEM_MESSAGE + final PLANNER_RESPONSE -> externallyBusy === false
      const finishedSteps = [
        ...midFlightSteps,
        { step_index: 7, type: "SYSTEM_MESSAGE", status: "DONE", created_at: "2026-11-22T02:29:59Z" },
        { step_index: 8, type: "PLANNER_RESPONSE", status: "DONE", created_at: "2026-11-22T02:29:59Z", content: "VERIFY C11 MAC BUSY FINISH" },
      ];
      await writeFile(transcriptPath, `${finishedSteps.map((s) => JSON.stringify(s)).join("\n")}\n`);
      const finishedInfo = await inspectTranscriptActivity(sessionId, "cli", env, {
        findExternalHolderPid: async () => null,
      });
      expect(finishedInfo?.externallyBusy).toBe(false);

      // Stage 4: Live external holder PID keeps externallyBusy true even before transcript updates!
      const pidHeldInfo = await inspectTranscriptActivity(sessionId, "cli", env, {
        findExternalHolderPid: async () => 55246,
      });
      expect(pidHeldInfo?.externallyBusy).toBe(true);
      expect(pidHeldInfo?.holderPid).toBe(55246);
    } finally {
      await rm(tempHome, { recursive: true, force: true });
    }
  });
});
