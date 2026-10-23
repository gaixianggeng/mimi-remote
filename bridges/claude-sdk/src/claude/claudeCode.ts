// Claude Code 版本下限（#660）：适配器经 SDK 驱动用户自己安装的 claude，太旧的 CLI 缺少适配器
// 依赖的控制协议字段。agentd 预检时按 `--capabilities` 里声明的下限提示用户；起进程前这里再挡
// 一次，覆盖预检之后才换了 claude 的情况。
import { execFile } from "node:child_process";
import path from "node:path";
import { promisify } from "node:util";
import { ErrorCode, RpcError } from "../rpc/frames.ts";
import { MINIMUM_CLAUDE_CODE_VERSION } from "../version.ts";

const execFileAsync = promisify(execFile);

export type ClaudeCodeProbe = { status: "ok"; version: string } | { status: "missing" } | { status: "unknown" };

export async function probeClaudeCodeVersion(executable: string): Promise<ClaudeCodeProbe> {
  let stdout: string;
  try {
    ({ stdout } = await execFileAsync(executable, ["--version"], { timeout: 5_000 }));
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === "ENOENT" ? { status: "missing" } : { status: "unknown" };
  }
  const version = /(\d+)\.(\d+)\.(\d+)/.exec(stdout)?.[0];
  return version ? { status: "ok", version } : { status: "unknown" };
}

/** 三段式版本比较；调用方保证两边都是 x.y.z。 */
export function compareVersions(left: string, right: string): number {
  const a = left.split(".").map(Number);
  const b = right.split(".").map(Number);
  for (let index = 0; index < 3; index += 1) {
    if (a[index]! !== b[index]!) return a[index]! < b[index]! ? -1 : 1;
  }
  return 0;
}

export class ClaudeCodeVersionGate {
  private verified: string | undefined;
  private verifiedVersion: string | undefined;

  // 只从已核对选项和取消时序的版本开始启用。较旧但仍受支持的 CLI 继续正常对话。
  get supportsPromptSuggestions(): boolean {
    return this.verified === this.executable() && this.verifiedVersion !== undefined
      && compareVersions(this.verifiedVersion, "2.1.307") >= 0;
  }

  constructor(
    private readonly executable: () => string,
    private readonly probe: (executable: string) => Promise<ClaudeCodeProbe> = probeClaudeCodeVersion,
    private readonly minimum = MINIMUM_CLAUDE_CODE_VERSION,
  ) {}

  /** 通过后按可执行文件缓存；没通过不缓存，用户升级后下一次请求就能用。 */
  async ensure(): Promise<void> {
    const executable = this.executable();
    if (this.verified === executable) return;
    const probe = await this.probe(executable);
    const data = { reason: "", minimumVersion: this.minimum } as Record<string, unknown>;
    if (probe.status === "missing") {
      throw new RpcError(ErrorCode.internalError, `找不到 Claude Code（${path.basename(executable)}）。请先安装 Claude Code 并登录。`, {
        ...data,
        reason: "claude_missing",
      });
    }
    if (probe.status === "unknown") {
      throw new RpcError(ErrorCode.internalError, "无法确认 Claude Code 版本。请重新安装或升级 Claude Code 后重试。", {
        ...data,
        reason: "claude_version_unknown",
      });
    }
    if (compareVersions(probe.version, this.minimum) < 0) {
      throw new RpcError(
        ErrorCode.internalError,
        `Claude Code ${probe.version} 过旧，Mimi 需要 ${this.minimum} 或更新版本。请在终端运行 claude update 后重试。`,
        { ...data, reason: "claude_unsupported", version: probe.version },
      );
    }
    this.verified = executable;
    this.verifiedVersion = probe.version;
  }
}
