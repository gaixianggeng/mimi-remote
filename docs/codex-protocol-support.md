# Codex app-server 协议支持边界

## 目标

`agentd` 不是 Codex app-server 的无条件透传代理。它只开放移动端当前需要、且能在项目 allowlist 内安全约束的协议能力；Codex 新增方法时默认不自动获得远程权限。

当前协议基线固定为 Codex CLI `0.149.1`：

- Client Request：150 个
- Server Request：11 个
- Server Notification：75 个

方法快照位于 `internal/httpapi/testdata/codex-protocol/`，CI 会在 Codex 版本或方法集合漂移时失败。

本文件只描述 Codex app-server 上游协议。Mimi iOS 与 `agentd` 自身 REST /
WebSocket 的修订窗口、共享 fixtures 和更新命令见
[Mimi iOS / agentd 版本化契约](mimi-protocol-contracts.md)。

## 当前开放能力

Go Gateway 当前开放 31 个 client frame method，其中 `initialized` 是 notification，其余是 request：

| 能力 | 方法 |
| --- | --- |
| 初始化 | `initialize`、`initialized` |
| 会话列表、搜索与生命周期 | `thread/list`、`thread/search`、`thread/start`、`thread/resume`、`thread/fork`、`thread/archive`、`thread/unarchive` |
| 分页历史 | `thread/read`、`thread/turns/list`、`thread/items/list` |
| 官方队列 | `thread/queue/add`、`thread/queue/list` |
| 会话管理 | `thread/name/set`、`thread/compact/start`、`thread/unsubscribe`、`thread/settings/update` |
| 目标任务 | `thread/goal/get`、`thread/goal/set`、`thread/goal/clear` |
| Review | `review/start` |
| Turn | `turn/start`、`turn/steer`、`turn/interrupt` |
| 只读发现能力 | `model/list`、`permissionProfile/list`、`skills/list`、`plugin/installed`、`account/rateLimits/read`、`account/usage/read` |

所有带 `threadId` 的管理操作都要求该 thread 已由当前 Gateway 连接通过 allowlist cwd 授权。

共享 SSH 模式的普通用户消息只使用 `thread/queue/add`。客户端初始化时必须声明 `experimentalApi: true`。发送结果不确定时，客户端用同一个 `clientUserMessageId` 依次查询 `thread/queue/list` 和 `thread/items/list`，不能盲目重发。`turn/start` 只保留给非共享旧链路和内部标题任务。

历史读取固定使用 `thread/read(includeTurns:false)`，随后分页调用 `thread/turns/list` 和 `thread/items/list`。线程模型、工作目录和权限是共享状态；`thread/queue/add` 不隐式修改它们。移动端提交共享队列消息时，会先用独立的 `thread/settings/update` 应用 Composer 为下一回合明确选择的模型、推理强度和协作模式，确认成功后才调用 `thread/queue/add`；权限继续走独立的受控链路。

Claude 实验通道使用更小的独立 allowlist，当前要求 `alleycat-claude-bridge >= 0.2.7`。`0.2.1` 首次开放 `account/rateLimits/read`，请求参数固定改写为 `{}`；`0.2.3` 起补齐事件百分比映射。`0.2.5` 起优先复用 Claude Code 已登录凭据主动读取 OAuth usage：macOS 从登录 Keychain 的 `Claude Code-credentials` 获取短期 access token，其他平台可使用权限收紧的 `~/.claude/.credentials.json`，随后请求固定的 Anthropic OAuth usage beta endpoint，将 5h/7d 窗口映射为现有协议。`0.2.6` 起，macOS token 过期或接口返回 401 时通过系统 PTY 执行 Claude CLI `/status` 认证路径，等待 Keychain 更新后只重试一次；`0.2.7` 起支持受控的运行期 `thread/list.refreshHistory`。bridge 不直接读取、消费或覆盖 refresh token。access token 只通过子进程 stdin 传给禁用 `.curlrc` 的系统 `curl`，不进入命令参数、日志或磁盘缓存；成功快照缓存 60 秒，Keychain、scope、续期、网络、HTTP 或解析失败均不影响会话链路。

OAuth usage endpoint 不是稳定公开 API，可能被 Anthropic 调整。主动查询失败时 bridge 继续降级到官方 `rate_limit_event`：按 `rateLimitType` 合并缓存 5h/7d 窗口，把事件中的 0...1 `utilization` 映射为 `usedPercent`。未观测到 utilization 的窗口保留 `unavailableReason=usage_percentage_unavailable`，不会伪造为 `0%`；只有 `rejected` 会映射为额度耗尽，`allowed_warning` 不阻断发送。主动查询和事件缓存都不可用时返回 `rateLimits.availability=unavailable`、`unavailableReason=headless_statusline_unavailable`。

Claude bridge 必须通过标准 `--version` 门禁才会被标记为可用；审批反向请求的响应和随后到达的 `serverRequest/resolved` notification 均透明透传。bridge 版本缺失、低于 `0.2.7` 或运行中退出时，Gateway 返回结构化错误并终止等待。正式 Mimi Remote Mac 已内置并签名兼容 bridge；Homebrew、Linux 和独立开发环境可执行 `cargo install --git https://github.com/gaixianggeng/mimi-remote.git --locked --force --bin alleycat-claude-bridge alleycat-claude-bridge` 安装外置版本。导入来源固定记录在 `bridges/claude/UPSTREAM.md`。

`thread/search` 是跨工作区全文搜索，额外执行以下边界：

- 请求只重建 Codex `0.149.1` 声明的搜索、分页、排序和来源字段，未知字段不透传；
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

反向 RPC 使用显式 allowlist。当前允许移动端按标准 app-server 请求/响应流程处理：

- `applyPatchApproval`
- `execCommandApproval`
- `item/commandExecution/requestApproval`
- `item/fileChange/requestApproval`
- `item/fileRead/requestApproval`
- `item/permissions/requestApproval`
- `item/tool/requestUserInput`
- `mcpServer/elicitation/request`

已知请求会登记请求 ID 并下发到移动端。任一共享入口先响应后，`serverRequest/resolved` 会关闭其他入口上的同一请求卡片。

以下请求和未来新增但尚未评估的 Desktop 私有请求不会下发到移动端。Gateway 保持沉默，让其他共享入口处理，不会由 Mimi 代替用户拒绝：

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
- 会话元数据：`thread/name/updated`、`thread/settings/updated`；
- 官方队列：`thread/queue/changed`；
- MCP：`item/mcpToolCall/progress`、`mcpServer/startupStatus/updated`；
- 协议提醒：`deprecationNotice`。

未知 Notification 不会造成连接失败，但在移动客户端明确适配前不会被当作已支持的产品能力。

新建 Codex 会话的自动标题使用一条独立的 App Server 连接（macOS 为 SSH proxy，Linux 为共享本机 control socket，Windows 为本机受管 WebSocket），不扩大移动端 allowlist。`agentd` 只在同一 Gateway 连接完成 `thread/start` 后消费首个成功转发的普通 `thread/queue/add`，用临时只读线程生成结构化标题，再通过 `thread/name/set` 写回目标线程。由于 app-server 只把该写操作的通知返回给内部连接，Gateway 会向发起会话的移动端补发同形的 `thread/name/updated`；完整边界见 [自动会话标题设计](auto-thread-titles.md)。

## 明确不开放

第一批不开放这些高风险或高维护能力：

- 任意 `command/exec`、文件写入、复制、删除和目录创建；
- Codex config 写入、MCP 配置修改、OAuth 登录；
- 账号登录、退出和 token 刷新；
- Skill 配置写入、Plugin 安装和 Marketplace；
- realtime voice、remote control；
- `thread/queue/delete`、`thread/queue/reorder`、`thread/queue/start`、`thread/queue/update`；
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
