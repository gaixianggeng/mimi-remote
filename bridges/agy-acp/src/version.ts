import packageJson from "../package.json" with { type: "json" };

export const ADAPTER_NAME = "mimi-agy-adapter";

// agentd 从 `--version` 里解析三段式版本做能力门禁，必须是正式版号。
export const ADAPTER_VERSION: string = packageJson.version;

export const USER_AGENT = `${ADAPTER_NAME}/${ADAPTER_VERSION}`;

// 适配器要求的 Antigravity CLI 最低版本（内置完整 ACP v1 session/list、configOptions、usage_update）。
export const MINIMUM_AGY_VERSION = "1.5.0";
