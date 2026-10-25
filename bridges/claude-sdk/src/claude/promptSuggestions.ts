import { readFile } from "node:fs/promises";
import path from "node:path";

/**
 * 受限 query 不加载本机/项目设置，避免其中的工具与 hook 扩大执行权限。
 * 单独读取建议的关闭偏好，不加载任何其他配置；组织策略仍交由 CLI 强制执行。
 */
export async function promptSuggestionsAllowed(
  configDir: string,
  cwd: string,
  environment = process.env.CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION,
): Promise<boolean> {
  // 与 SDK 文档一致：显式环境变量优先，但从不替用户设置它。
  if (environment === "false" || environment === "0") return false;
  if (environment === "true" || environment === "1") return true;
  for (const file of [path.join(configDir, "settings.json"), path.join(cwd, ".claude/settings.json"), path.join(cwd, ".claude/settings.local.json")]) {
    try {
      const settings = JSON.parse(await readFile(file, "utf8")) as { promptSuggestionEnabled?: unknown };
      if (!settings || typeof settings !== "object" || Array.isArray(settings)) return false;
      if (settings.promptSuggestionEnabled !== undefined && settings.promptSuggestionEnabled !== true) return false;
    } catch (error) {
      // 读取或解析失败时只降级建议，正常会话照常启动。
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") return false;
    }
  }
  return true;
}
