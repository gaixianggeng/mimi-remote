import type { JsonValue } from "@mimi/appserver-kit/protocol/codex/serde_json/JsonValue.ts";
import type { CommandAction } from "@mimi/appserver-kit/protocol/codex/v2/CommandAction.ts";
import type { FileUpdateChange } from "@mimi/appserver-kit/protocol/codex/v2/FileUpdateChange.ts";
import type { ThreadItem } from "@mimi/appserver-kit/protocol/codex/v2/ThreadItem.ts";
import type { AcpPlanEntry, AcpToolCallContent, AcpToolCallLocation, AcpToolCallStatus } from "../acp/types.ts";

export interface AcpToolState {
  toolCallId: string;
  title?: string;
  kind?: string;
  status?: AcpToolCallStatus;
  content?: AcpToolCallContent[];
  locations?: AcpToolCallLocation[];
  rawInput?: Record<string, unknown>;
  rawOutput?: unknown;
}

function baseName(filePath: string): string {
  return filePath.split(/[\\/]/).filter(Boolean).pop() ?? "file";
}

function unifiedHunk(oldText: string, newText: string): string {
  const removed = oldText === "" ? [] : oldText.split("\n");
  const added = newText === "" ? [] : newText.split("\n");
  const body = [...removed.map((line) => `-${line}`), ...added.map((line) => `+${line}`)].join("\n");
  return `@@ -1,${removed.length} +1,${added.length} @@\n${body}\n`;
}

function strField(input: Record<string, unknown> | undefined, ...keys: string[]): string | undefined {
  if (!input) return undefined;
  for (const key of keys) {
    const val = input[key];
    if (typeof val === "string" && val.trim()) return val.trim();
  }
  return undefined;
}

export function extractDiffChanges(state: AcpToolState): FileUpdateChange[] {
  const diffs: FileUpdateChange[] = [];
  for (const part of state.content ?? []) {
    if (part.type === "diff" && part.path) {
      const oldText = part.oldText ?? "";
      const newText = part.newText ?? "";
      diffs.push({
        path: part.path,
        kind: part.oldText === null || part.oldText === undefined ? { type: "add" } : { type: "update", move_path: null },
        diff: unifiedHunk(oldText, newText),
      });
    }
  }
  if (diffs.length > 0) return diffs;

  const pathFromInput =
    strField(state.rawInput, "Path", "path", "file_path", "TargetFile") ?? state.locations?.[0]?.path;
  if (!pathFromInput) return [];
  if (state.kind === "delete") {
    return [{ path: pathFromInput, kind: { type: "delete" }, diff: "" }];
  }
  const oldStr = strField(state.rawInput, "Target", "old_string", "oldText") ?? "";
  const newStr = strField(state.rawInput, "Replacement", "Content", "new_string", "newText") ?? "";
  return [
    {
      path: pathFromInput,
      kind: oldStr === "" && state.rawInput?.Content !== undefined ? { type: "add" } : { type: "update", move_path: null },
      diff: unifiedHunk(oldStr, newStr),
    },
  ];
}

function extractTextOutput(state: AcpToolState): string | null {
  const chunks: string[] = [];
  for (const part of state.content ?? []) {
    if (part.type === "content" && part.content?.type === "text" && typeof part.content.text === "string") {
      chunks.push(part.content.text);
    }
  }
  if (chunks.length > 0) return chunks.join("\n");
  if (typeof state.rawOutput === "string" && state.rawOutput.trim()) return state.rawOutput;
  if (state.rawOutput && typeof state.rawOutput === "object") {
    const out = (state.rawOutput as Record<string, unknown>).output;
    if (typeof out === "string" && out) return out;
  }
  return null;
}

function extractExitCode(state: AcpToolState): number | null {
  if (state.rawOutput && typeof state.rawOutput === "object") {
    const code = (state.rawOutput as Record<string, unknown>).exitCode;
    if (typeof code === "number" && Number.isInteger(code)) return code;
  }
  if (state.status === "completed") return 0;
  if (state.status === "failed") return 1;
  return null;
}

function commandStatusOf(status: AcpToolCallStatus | undefined, stillRunning: boolean) {
  if (status === "completed") return "completed" as const;
  if (status === "failed") return "failed" as const;
  return stillRunning ? ("inProgress" as const) : ("declined" as const);
}

function patchStatusOf(status: AcpToolCallStatus | undefined, stillRunning: boolean) {
  if (status === "completed") return "completed" as const;
  if (status === "failed") return "failed" as const;
  return stillRunning ? ("inProgress" as const) : ("declined" as const);
}

function dynamicStatusOf(status: AcpToolCallStatus | undefined, stillRunning: boolean) {
  if (status === "completed") return "completed" as const;
  if (status === "failed") return "failed" as const;
  return stillRunning ? ("inProgress" as const) : ("failed" as const);
}

export function mergeToolState(prev: AcpToolState | undefined, next: Partial<AcpToolState> & { toolCallId: string }): AcpToolState {
  if (!prev) {
    return { ...next };
  }
  return {
    toolCallId: next.toolCallId,
    title: next.title ?? prev.title,
    kind: next.kind ?? prev.kind,
    status: next.status ?? prev.status,
    content: next.content ?? prev.content,
    locations: next.locations ?? prev.locations,
    rawInput: next.rawInput ?? prev.rawInput,
    rawOutput: next.rawOutput ?? prev.rawOutput,
  };
}

export function acpToolToThreadItem(state: AcpToolState, cwd: string, stillRunning = true): ThreadItem {
  const kind = state.kind ?? "other";
  const hasDiff = (state.content ?? []).some((entry) => entry.type === "diff");

  if (kind === "edit" || kind === "delete" || kind === "move" || hasDiff) {
    return {
      type: "fileChange",
      id: state.toolCallId,
      changes: extractDiffChanges(state),
      status: patchStatusOf(state.status, stillRunning),
    };
  }

  if (kind === "execute" || kind === "read" || kind === "search") {
    const locPath = state.locations?.[0]?.path ?? strField(state.rawInput, "Path", "path", "file_path");
    const cmdLine =
      strField(state.rawInput, "CommandLine", "command")
      ?? state.title
      ?? (locPath ? `${kind} ${locPath}` : kind);
    const actions: CommandAction[] =
      kind === "read" && locPath
        ? [{ type: "read", command: cmdLine, name: baseName(locPath), path: locPath }]
        : kind === "search"
          ? [
              {
                type: "search",
                command: cmdLine,
                query: strField(state.rawInput, "query", "pattern", "Query") ?? cmdLine,
                path: locPath ?? null,
              },
            ]
          : [];
    return {
      type: "commandExecution",
      id: state.toolCallId,
      pluginId: null,
      scriptPath: null,
      command: cmdLine,
      cwd,
      processId: null,
      source: "agent",
      status: commandStatusOf(state.status, stillRunning),
      commandActions: actions,
      aggregatedOutput: extractTextOutput(state),
      exitCode: state.status === "completed" || state.status === "failed" ? extractExitCode(state) : null,
      durationMs: null,
    };
  }

  const output = extractTextOutput(state);
  const status = dynamicStatusOf(state.status, stillRunning);
  return {
    type: "dynamicToolCall",
    id: state.toolCallId,
    namespace: "antigravity",
    tool: state.title?.trim() || kind,
    arguments: ((state.rawInput ?? {}) as unknown) as JsonValue,
    status,
    contentItems: output ? [{ type: "inputText", text: output }] : null,
    success: status === "completed" ? true : status === "failed" ? false : null,
    durationMs: null,
  };
}

export function formatPlanMarkdown(entries: readonly AcpPlanEntry[]): string {
  return entries
    .map((entry) => {
      const mark = entry.status === "completed" ? "x" : entry.status === "in_progress" ? "-" : " ";
      return `- [${mark}] ${entry.content.trim()}`;
    })
    .filter((line) => line.length > 6)
    .join("\n");
}
