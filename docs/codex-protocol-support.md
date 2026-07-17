# Codex app-server 协议支持边界

## 目标

`agentd` 不是 Codex app-server 的无条件透传代理。它只开放移动端当前需要、且能在项目 allowlist 内安全约束的协议能力；Codex 新增方法时默认不自动获得远程权限。

当前协议基线固定为 Codex CLI `0.144.2`：

- Client Request：122 个
- Server Request：11 个
- Server Notification：68 个

方法快照位于 `internal/httpapi/testdata/codex-protocol/`，CI 会在 Codex 版本或方法集合漂移时失败。

## 当前开放能力

Go Gateway 当前开放 25 个 client frame method，其中 `initialized` 是 notification，其余是 request：

| 能力 | 方法 |
| --- | --- |
| 初始化 | `initialize`、`initialized` |
| 会话列表、搜索与生命周期 | `thread/list`、`thread/search`、`thread/start`、`thread/resume`、`thread/fork`、`thread/read`、`thread/turns/list`、`thread/archive`、`thread/unarchive` |
| 会话管理 | `thread/name/set`、`thread/compact/start`、`thread/unsubscribe` |
| 目标任务 | `thread/goal/get`、`thread/goal/set`、`thread/goal/clear` |
| Review | `review/start` |
| Turn | `turn/start`、`turn/steer`、`turn/interrupt` |
| 只读发现能力 | `model/list`、`skills/list`、`plugin/installed`、`account/rateLimits/read` |

所有带 `threadId` 的管理操作都要求该 thread 已由当前 Gateway 连接通过 allowlist cwd 授权。

Claude 实验通道使用更小的独立 allowlist。`alleycat-claude-bridge >= 0.2.0` 时额外开放 `account/rateLimits/read`，请求参数固定改写为 `{}`。Claude Code 2.1.92 headless `stream-json` 不执行 statusline sink，bridge 没有事件缓存时返回 `rateLimits.availability=unavailable`、`unavailableReason=headless_statusline_unavailable`；收到官方 `rate_limit_event` 后返回 `availability=partial`、`unavailableReason=usage_percentage_unavailable`，只映射真实存在的 `rateLimitReachedType`，以及对应 `primary`（5h）或 `secondary`（7d）的 `resetsAt/windowDurationMins`，不补 `usedPercent=0`。Gateway 不访问 Anthropic 私有接口或凭证文件。

Claude bridge 必须通过标准 `--version` 门禁才会被标记为可用；审批反向请求的响应和随后到达的 `serverRequest/resolved` notification 均透明透传。bridge 版本缺失、低于 `0.2.0` 或运行中退出时，Gateway 返回结构化错误并终止等待。发布安装固定到已审阅 revision `c50256dc9cc71f5130a176e32bb6fd33b1e06f74`：`cargo install --git https://github.com/gaixianggeng/alleycat.git --rev c50256dc9cc71f5130a176e32bb6fd33b1e06f74 --locked --force alleycat-claude-bridge`。

`thread/search` 是跨工作区全文搜索，额外执行以下边界：

- 请求只重建 Codex `0.144.2` 声明的搜索、分页、排序和来源字段，未知字段不透传；
- 响应中的每条 thread 必须携带绝对 cwd，并命中 project、`browse_roots` 或 managed Worktree；
- cwd 缺失、畸形、目录不存在或越权时，整条 thread 和 snippet 一并删除；
- 只有实际下发的 thread 才进入 Gateway 授权缓存，供后续 `thread/read` / `thread/resume` 使用；
- 搜索复用历史读取的请求频率、请求字节、响应字节和单帧大小预算。

`skills/list` 只用于只读发现：

- `cwds` 必须且只能包含一个 project、`browse_roots` 或 managed Worktree 内的授权目录；
- Gateway 只保留 `cwds` 与布尔型 `forceReload`，未知参数全部剔除；
- Skill 配置写入、启停、安装与插件管理仍不开放。

`plugin/installed` 只用于 Composer 的 `@ 插件`候选列表：

- `cwds` 必须且只能包含一个已授权工作区；
- 不允许 `installSuggestionPluginNames`，移动端不会借候选列表建议或安装插件；
- 只读取已安装插件的名称、启用状态和展示元数据，插件安装、卸载、授权与配置写入仍不开放。

`review/start` 额外收紧为：

- 只允许 `inline`，不允许创建未进入授权缓存的 detached review thread；
- 允许未提交改动、base branch、commit 三类 target；
- 不允许 custom target，避免自由提示词绕过 `turn/start` 的沙盒和审批策略改写。

## 反向 Server Request

反向 RPC 采用 fail-closed。当前允许移动端处理：

- `applyPatchApproval`
- `execCommandApproval`
- `item/commandExecution/requestApproval`
- `item/fileChange/requestApproval`
- `item/permissions/requestApproval`
- `item/tool/requestUserInput`
- `mcpServer/elicitation/request`

以下当前 Codex 方法不会下发到移动端，Gateway 会立即向 app-server 返回明确错误，避免请求永久悬挂：

- `account/chatgptAuthTokens/refresh`
- `attestation/generate`
- `currentTime/read`
- `item/tool/call`
- 未来新增但尚未评估的 Server Request

## 关键 Notification 投影

Gateway 保持 Notification 透明转发，移动客户端第一批明确消费：

- 计划：`item/plan/delta`、`turn/plan/updated`；
- 推理摘要：`item/reasoning/summaryPartAdded`、`item/reasoning/summaryTextDelta`；
- 用量与上下文：`thread/tokenUsage/updated`、`thread/compacted`；
- 会话元数据：`thread/name/updated`；
- MCP：`item/mcpToolCall/progress`、`mcpServer/startupStatus/updated`；
- 协议提醒：`deprecationNotice`。

未知 Notification 不会造成连接失败，但在移动客户端明确适配前不会被当作已支持的产品能力。

## 明确不开放

第一批不开放这些高风险或高维护能力：

- 任意 `command/exec`、文件写入、复制、删除和目录创建；
- Codex config 写入、MCP 配置修改、OAuth 登录；
- 账号登录、退出和 token 刷新；
- Skill 配置写入、Plugin 安装和 Marketplace；
- realtime voice、remote control；
- 已废弃的 `thread/rollback`。

这些能力不是“漏做”，而是当前远程安全边界的一部分。需要新增时，必须同时补 Go 参数清洗、thread/cwd 授权、客户端类型化处理和协议测试。

## 升级流程

日常检查当前固定基线：

```bash
bash ./scripts/check-codex-protocol.sh
```

明确升级 Codex 时，先安装目标版本，再更新并复核快照：

```bash
npm install --global @openai/codex@x.y.z
bash ./scripts/check-codex-protocol.sh --update
bash ./scripts/check-codex-protocol.sh
go test ./...
```

更新快照前必须人工确认新增方法不会扩大远程权限；不能把“让 CI 变绿”当作协议评估。
