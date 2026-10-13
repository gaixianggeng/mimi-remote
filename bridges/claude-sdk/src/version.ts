import packageJson from "../package.json" with { type: "json" };

export const ADAPTER_NAME = "mimi-claude-adapter";

// agentd 从 `--version` 里解析三段式版本做能力门禁，必须是正式版号。
export const ADAPTER_VERSION: string = packageJson.version;

export const USER_AGENT = `${ADAPTER_NAME}/${ADAPTER_VERSION}`;

// 适配器要求的 Claude Code 最低版本：实测通过验收的最旧版本（SDK 0.3.296 对应 2.1.296）。
// 升级 SDK 时一并复核。
export const MINIMUM_CLAUDE_CODE_VERSION = "2.1.294";
