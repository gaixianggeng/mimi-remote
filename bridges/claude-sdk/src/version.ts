import packageJson from "../package.json" with { type: "json" };

export const ADAPTER_NAME = "mimi-claude-adapter";

// agentd 从 `--version` 里解析三段式版本做能力门禁，必须是正式版号。
export const ADAPTER_VERSION: string = packageJson.version;

export const USER_AGENT = `${ADAPTER_NAME}/${ADAPTER_VERSION}`;
