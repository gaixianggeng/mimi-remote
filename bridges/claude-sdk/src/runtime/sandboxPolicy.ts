// 沙箱是执行边界，审批模式只决定是否询问。两者必须独立，审批不能扩大这里的范围。
import { lstat, readlink, realpath, stat } from "node:fs/promises";
import path from "node:path";
import type { Options, PreToolUseHookInput } from "@anthropic-ai/claude-agent-sdk";
import { RpcError } from "../rpc/frames.ts";
import { MIMI_TURN_HINT_TOOL_NAMES } from "./turnHints.ts";

export type ExecutionPolicy =
  | { type: "dangerFullAccess" }
  | { type: "readOnly"; networkAccess: boolean }
  | { type: "workspaceWrite"; writableRoots?: string[]; networkAccess: boolean };

export function executionPolicyFor(raw: unknown): ExecutionPolicy {
  const value = typeof raw === "string" ? { type: raw } : (raw ?? { type: "workspaceWrite" });
  if (!value || typeof value !== "object" || Array.isArray(value)) throw RpcError.invalidParams("sandboxPolicy 无效");
  const policy = value as Record<string, unknown>;
  if (policy.type === "dangerFullAccess" || policy.type === "danger-full-access") return { type: "dangerFullAccess" };
  if (policy.networkAccess !== undefined && typeof policy.networkAccess !== "boolean") {
    throw RpcError.invalidParams("sandboxPolicy.networkAccess 必须为布尔值");
  }
  const networkAccess = policy.networkAccess === true;
  if (policy.type === "readOnly" || policy.type === "read-only") return { type: "readOnly", networkAccess };
  if (policy.type !== "workspaceWrite" && policy.type !== "workspace-write") throw RpcError.invalidParams("不支持此 sandboxPolicy");
  // Claude 的 Bash 沙箱固定保留自己的临时目录，不能声称支持 Codex 的禁用临时目录选项。
  if (policy.excludeTmpdirEnvVar === true || policy.excludeSlashTmp === true) {
    throw RpcError.invalidParams("Claude 不支持禁用沙箱临时目录；未启动执行");
  }
  const roots = policy.writableRoots;
  if (roots !== undefined && (!Array.isArray(roots) || !roots.every((root) => typeof root === "string" && path.isAbsolute(root) && !/[\x00*?\[\]{}]/.test(root)))) {
    throw RpcError.invalidParams("sandboxPolicy.writableRoots 必须为不含通配符的绝对路径数组");
  }
  return { type: "workspaceWrite", ...(roots !== undefined ? { writableRoots: [...roots as string[]] } : {}), networkAccess };
}

/** 新文件也检查最近存在的父目录，防止目录软链接把 Write / Edit 带出可写根。 */
async function canonicalTarget(target: string): Promise<string> {
  try {
    return await realpath(target);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    // realpath 对悬空链接返回 ENOENT，不能把它误当成普通新文件。
    const entry = await lstat(target).catch((failure: NodeJS.ErrnoException) => {
      if (failure.code !== "ENOENT") throw failure;
      return undefined;
    });
    if (entry?.isSymbolicLink()) return canonicalTarget(path.resolve(path.dirname(target), await readlink(target)));
    const parent = path.dirname(target);
    if (parent === target) throw error;
    return path.join(await canonicalTarget(parent), path.basename(target));
  }
}

function contains(root: string, target: string): boolean {
  const relative = path.relative(root, target);
  return relative === "" || (!relative.startsWith(`..${path.sep}`) && relative !== ".." && !path.isAbsolute(relative));
}

const FILE_WRITES: Record<string, string> = { Write: "file_path", Edit: "file_path", NotebookEdit: "notebook_path" };
const LOCAL_TOOLS = new Set(["Read", "Glob", "Grep", "Bash", "AskUserQuestion", "TodoWrite", "TaskCreate", "TaskGet", "TaskList", "TaskUpdate", "TaskOutput", "TaskStop", "EnterPlanMode", "ExitPlanMode"]);

/** skillPlugin：用户与项目技能的合成插件目录（见 claude/skillPlugin），只在受限档位使用。 */
export async function sandboxOptions(policy: ExecutionPolicy, cwd: string, platform: NodeJS.Platform = process.platform, skillPlugin?: string): Promise<Partial<Options>> {
  // 完全访问沿用原行为，不额外改变 bypass permissions。
  if (policy.type === "dangerFullAccess") return {};
  const directory = await realpath(cwd);
  const roots = policy.type === "workspaceWrite" ? await Promise.all((policy.writableRoots ?? [cwd]).map((root) => realpath(root))) : [];
  if (policy.type === "workspaceWrite" && !roots.some((root) => contains(root, directory))) {
    throw RpcError.invalidParams("Claude 沙箱总是允许写入 cwd；writableRoots 必须包含 cwd，未启动执行");
  }
  const deny = (reason: string) => ({ hookSpecificOutput: { hookEventName: "PreToolUse" as const, permissionDecision: "deny" as const, permissionDecisionReason: reason } });
  return {
    // 防止本机 / 项目 allowWrite、excludedCommands、MCP 或命令 hook 扩大本次声明。
    // 只覆盖子进程启动参数，不改用户文件。CLAUDE_BRIDGE_SANDBOX_POLICY 不参与边界选择。
    settingSources: [],
    // 用户与项目技能、项目命令只经合成插件加载，只供用户以 `/名称` 主动调用：模型看不到技能列表，
    // Skill 工具也不在下面的本地工具白名单里（#775）。
    ...(skillPlugin ? { plugins: [{ type: "local" as const, path: skillPlugin, skipMcpDiscovery: true }] } : {}),
    skills: [],
    // 技能 frontmatter 与插件里的命令 hook 在沙箱外执行（实测），受限档位一律不跑；下面的 SDK 回调
    // hook 不受影响。原生 Windows 没有 Bash 沙箱，技能里的 !`命令` 换成占位文本，其余照常展开。
    settings: { disableAllHooks: true, ...(platform === "win32" ? { disableSkillShellExecution: true } : {}) },
    strictMcpConfig: true,
    mcpServers: {},
    // 原生 Windows 没有 Claude Bash 沙箱；保留可核对路径的文件工具，明确禁用 shell。
    ...(platform === "win32" ? { disallowedTools: ["Bash", "PowerShell", "Monitor"] } : {}),
    sandbox: {
      enabled: platform !== "win32",
      failIfUnavailable: true,
      autoAllowBashIfSandboxed: false,
      allowUnsandboxedCommands: false,
      excludedCommands: [],
      filesystem: { disabled: false, allowWrite: roots, denyWrite: policy.type === "readOnly" ? ["/"] : [] },
      network: {
        allowedDomains: policy.networkAccess ? ["*"] : [],
        deniedDomains: policy.networkAccess ? [] : ["*"],
        strictAllowlist: true,
        allowAllUnixSockets: false,
        allowUnixSockets: [],
        allowLocalBinding: false,
      },
    },
    hooks: {
      PreToolUse: [{ hooks: [async (input) => {
        const call = input as PreToolUseHookInput;
        if (platform === "win32" && call.tool_name === "Bash") return deny("原生 Windows 无法兑现 Bash 沙箱边界，已禁用 shell");
        const field = FILE_WRITES[call.tool_name];
        if (field) {
          if (policy.type === "readOnly") return deny("Mimi readOnly 禁止文件写入");
          const raw = (call.tool_input as Record<string, unknown> | null)?.[field];
          if (typeof raw !== "string" || !raw) return deny("无法确认文件写入路径");
          try {
            const target = await canonicalTarget(path.resolve(directory, raw));
            if (!roots.some((root) => contains(root, target))) return deny("Mimi writableRoots 禁止工作区外写入");
            const entry = await stat(target).catch((error: NodeJS.ErrnoException) => {
              if (error.code !== "ENOENT") throw error;
              return undefined;
            });
            // 硬链接可能把同一文件内容暴露在根外，无法证明所有链接均在可写范围内。
            if (entry?.isFile() && entry.nlink > 1) return deny("无法确认硬链接文件的全部写入位置");
          } catch {
            return deny("无法确认文件写入路径，已拒绝执行");
          }
          return {};
        }
        if (call.tool_name === "WebFetch" || call.tool_name === "WebSearch") {
          return policy.networkAccess ? {} : deny("Mimi networkAccess=false 禁止网络工具");
        }
        // 未核实边界的 MCP、插件与子代理工具不放行，避免绕过 Bash / 文件检查。
        if (!LOCAL_TOOLS.has(call.tool_name) && !MIMI_TURN_HINT_TOOL_NAMES.has(call.tool_name)) {
          return deny("此工具无法在 Mimi 声明的沙箱边界内执行");
        }
        return {};
      }] }],
    },
  };
}
