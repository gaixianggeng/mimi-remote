import { describe, expect, test } from "bun:test";
import { sanitizeAgyEnv } from "../src/agy/env.ts";
import { catalogAgyCommands } from "../src/agy/commands.ts";
import { catalogAgyModels } from "../src/agy/models.ts";
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
});
