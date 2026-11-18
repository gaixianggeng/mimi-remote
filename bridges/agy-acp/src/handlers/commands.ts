import { realpath } from "node:fs/promises";
import path from "node:path";
import { RpcError } from "@mimi/appserver-kit/rpc/frames.ts";
import type { CommandCatalog, CommandEntry } from "../agy/commands.ts";
import { executionPolicyFor } from "../runtime/settings.ts";

type Params = Record<string, unknown>;

export function createCommandHandlers(catalog: CommandCatalog) {
  return {
    async list(raw: unknown): Promise<{ data: CommandEntry[] }> {
      const params = (raw && typeof raw === "object" ? raw : {}) as Params;
      const cwd = typeof params.cwd === "string" ? params.cwd.trim() : "";
      if (!cwd || !path.isAbsolute(cwd)) {
        throw RpcError.invalidParams("cwd 必须是绝对路径");
      }
      if (params.forceReload !== undefined && typeof params.forceReload !== "boolean") {
        throw RpcError.invalidParams("forceReload 必须为布尔值");
      }
      try {
        await realpath(cwd);
      } catch {
        throw RpcError.invalidParams("cwd 不存在");
      }
      const policy = executionPolicyFor(params.sandboxPolicy);
      const data = await catalog.list(cwd, policy.type !== "dangerFullAccess", params.forceReload === true);
      return { data };
    },
  };
}
