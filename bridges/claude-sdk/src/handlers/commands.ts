// slashCommand/list：客户端 `/` 菜单的命令目录。cwd 由 agentd 网关限定在授权工作区内；
// sandboxPolicy 与下一次 turn/start 相同，用来选出这个执行边界下 Claude Code 实际认识的命令。
import { realpath } from "node:fs/promises";
import path from "node:path";
import type { CommandCatalog, CommandEntry } from "../claude/commands.ts";
import { RpcError } from "../rpc/frames.ts";
import { executionPolicyFor } from "../runtime/sandboxPolicy.ts";

type Params = Record<string, unknown>;

export function createCommandHandlers(catalog: CommandCatalog) {
  return {
    async list(raw: unknown): Promise<{ data: CommandEntry[] }> {
      const params = (raw && typeof raw === "object" ? raw : {}) as Params;
      const cwd = typeof params.cwd === "string" ? params.cwd.trim() : "";
      if (!cwd || !path.isAbsolute(cwd)) throw RpcError.invalidParams("cwd 必须是绝对路径");
      if (params.forceReload !== undefined && typeof params.forceReload !== "boolean") {
        throw RpcError.invalidParams("forceReload 必须为布尔值");
      }
      try {
        await realpath(cwd);
      } catch {
        throw RpcError.invalidParams("cwd 不存在");
      }
      // 缺省与 turn/start 相同按 workspaceWrite 处理：受限档位不加载本机设置，目录只有内置命令。
      const policy = executionPolicyFor(params.sandboxPolicy);
      const data = await catalog.list(cwd, policy, params.forceReload === true);
      return { data };
    },
  };
}
