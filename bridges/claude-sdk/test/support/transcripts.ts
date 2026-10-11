// 合成 Claude transcript 夹具。字段只取 SDK 建链和显示所需的部分，不含任何真实会话内容。
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";

export type Record_ = Record<string, unknown>;

export class TranscriptBuilder {
  readonly records: Record_[] = [];
  private clock: number;
  private last: string | null = null;
  private counter = 0;

  constructor(
    readonly sessionId: string,
    readonly cwd: string,
    readonly gitBranch = "main",
    start = Date.parse("2026-09-01T00:00:00.000Z"),
  ) {
    this.clock = start;
  }

  private nextUuid(prefix: string): string {
    this.counter += 1;
    return `${prefix}-${this.sessionId.slice(0, 8)}-${String(this.counter).padStart(4, "0")}`;
  }

  private stamp(): string {
    this.clock += 1_000;
    return new Date(this.clock).toISOString();
  }

  private base(type: string, parentUuid: string | null, uuid: string): Record_ {
    return {
      type,
      uuid,
      parentUuid,
      sessionId: this.sessionId,
      cwd: this.cwd,
      gitBranch: this.gitBranch,
      isSidechain: false,
      userType: "external",
      version: "2.1.294",
      timestamp: this.stamp(),
    };
  }

  /** 追加一条记录；默认接在上一条之后，`parent` 可以显式指定以构造分叉。 */
  push(record: Record_, parent: string | null | undefined = undefined): string {
    const uuid = (record.uuid as string | undefined) ?? this.nextUuid(String(record.type));
    const full = { ...this.base(String(record.type), parent === undefined ? this.last : parent, uuid), ...record, uuid };
    this.records.push(full);
    this.last = uuid;
    return uuid;
  }

  user(content: unknown, extra: Record_ = {}, parent?: string | null): string {
    return this.push({ type: "user", message: { role: "user", content }, ...extra }, parent);
  }

  assistant(content: unknown[], messageId = this.nextUuid("msg"), parent?: string | null): string {
    return this.push(
      { type: "assistant", message: { id: messageId, role: "assistant", model: "claude-test", type: "message", content } },
      parent,
    );
  }

  toolResult(toolUseId: string, content: unknown, isError = false): string {
    return this.user([{ type: "tool_result", tool_use_id: toolUseId, content, is_error: isError }]);
  }

  /** 新版压缩：分界记录断开 parentUuid，用 logicalParentUuid 指回压缩前的末尾。 */
  compact(summary: string): string {
    const logicalParent = this.last;
    const boundary = this.push(
      {
        type: "system",
        subtype: "compact_boundary",
        content: "Conversation compacted",
        isMeta: false,
        level: "info",
        logicalParentUuid: logicalParent,
        compactMetadata: { trigger: "auto", preTokens: 100000 },
      },
      null,
    );
    return this.user(summary, { isCompactSummary: true, isVisibleInTranscriptOnly: true }, boundary);
  }

  title(customTitle: string): void {
    this.records.push({ type: "custom-title", customTitle, sessionId: this.sessionId });
  }

  write(configDir: string, encodedDir = encodeProjectDir(this.cwd)): string {
    const dir = path.join(configDir, "projects", encodedDir);
    mkdirSync(dir, { recursive: true });
    const file = path.join(dir, `${this.sessionId}.jsonl`);
    writeFileSync(file, `${this.records.map((record) => JSON.stringify(record)).join("\n")}\n`);
    return file;
  }
}

/** Claude 的项目目录名：绝对路径里非字母数字字符替换成 `-`。 */
export function encodeProjectDir(cwd: string): string {
  return cwd.replace(/[^a-zA-Z0-9]/g, "-");
}
