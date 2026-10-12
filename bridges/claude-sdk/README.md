# Claude SDK 适配器

基于官方 [Claude Agent SDK](https://code.claude.com/docs/en/agent-sdk/typescript) 的 Claude 通道适配器，用来替换 `bridges/claude` 下的 Rust bridge。设计与拆分见 #655。

## 原则

- **会话数据只有一份，归 Claude Code。** 列表、历史、标题都通过 SDK 读取，不再自己解析 transcript，也不保存第二份会话目录。Mimi 里看到的历史与 `claude --resume` 一致：分叉只显示 CLI 继续的那条支线，被 Claude 压缩掉的历史与 CLI 一样不显示。
- **项目 = Git 仓库。** 按目录查询时，包含同仓库所有 worktree 的会话。
- **活动时间取最后一条对话消息的时间戳**，不用文件修改时间（#653）。
- **agentd 接口不变。** 启动参数（`--socket`、`--version`）、`_alleycat/attach` 握手、`_alleycat_seq` 序号和断线重放与旧 bridge 一致，切换只需改 `claude.bridge_bin`。

## 当前阶段

- **只读（#656）**：`initialize`、`thread/list`、`thread/read`、`thread/loaded/list`、`thread/turns/list`、`thread/items/list`。
- **对话（#657）**：`thread/start`、`thread/resume`、`turn/start`、`turn/steer`、`turn/interrupt`。
  - 每个会话一个常驻的 SDK `query()`（流式输入），使用 Claude Code 自带的系统提示词和全部设置来源，与 CLI 一致。
  - 模型、权限模式、思考强度在 turn 之间通过 SDK 控制接口切换；只有进出完全访问时重启进程。
  - 审批（`canUseTool`）映射为 `item/commandExecution/requestApproval`、`item/fileChange/requestApproval`；`AskUserQuestion` 映射为 `item/tool/requestUserInput`。请求发给订阅该会话的所有连接，先答复者生效，其余收到 `serverRequest/resolved`；重连时由 `serverRequest/replay` 补发未答复的请求。
  - 引导以人工输入的 `now` 优先级并入当前 turn。turn 要等名下所有消息（含引导）都被 Claude 的结果吸收才收尾；输出与结果按 `user_message_uuid` 归属，CLI 队列里还有未完成的消息时拒绝新的 `turn/start`。
  - 已知差异：引导消息在 transcript 里是普通的用户记录，重新加载历史时显示为单独一轮，实时显示时在同一轮里。
- **单一驱动方（#658）**：`thread/takeover`。同一会话同一时刻只有一个 Claude 进程在写。
  - 占用登记（`<配置目录>/sessions/<pid>.json`，Claude Code 为每个活进程写的文件）是唯一没有公开接口的依赖，只读。自己起的进程按 pid 排除；拿到 pid 之前，同一会话新出现的登记先不算别处，避免把自己当成别人。
  - 别处持有时会话只读：`thread/list`、`thread/resume` 带 `canAcceptDirectInput: false` 与 `claudeOwner` 摘要，`turn/start` 返回 `owned_elsewhere`。
  - **驱动中让出**：监听登记目录（目录事件 + 2 秒轮询兜底）。适配器握着进程时出现别的持有方（例如终端执行了 `claude --resume`），立即给自己的 CLI 发 SIGTERM，进行中的 turn 记为中断，不再写 transcript。实测终端进程启动后约 0.5 秒让出。
  - 持有方出现、退出或在空闲与执行之间切换时，向订阅者推送 `thread/status/changed`，附带与 Thread 同名的 `canAcceptDirectInput`、`claudeOwner`，客户端不用重新读取就能切换只读状态。
  - **接管**：规则沿用旧 bridge（#451）——只结束全部明确空闲、且进程启动时间与登记 `startedAt` 吻合的持有方；先 SIGINT，5 秒后重查状态再 SIGTERM；持有方退出后若有新进程认领同一会话，报 `holder_respawned` 且不再发信号。失败以 `-32602` 返回 `{accepted, reason, claudeOwner, retryable}`。
  - CLI 自身行为：恢复一个生成到一半被结束的会话时，CLI 会补一条 `No response requested.`，与被中断的那条回复成为兄弟节点。历史按 CLI 继续的支线显示，与 `claude --resume` 一致。
- **其余能力（#659）**：`model/list`、`account/rateLimits/read`、`thread/name/set`，见下面的对照表。默认配置仍使用 Rust bridge。

## 与旧 bridge 的逐方法对照

依据是实际调用方：iOS 只能经 agentd 网关调用 Claude 通道白名单里的方法（`internal/httpapi/appserver_gateway.go` 的 `appServerClaudeAllowedMethods`），agentd 内部经匿名连接调用 `initialize`、`thread/read`、`thread/name/set`（自动标题）和 `account/rateLimits/read`（菜单栏额度）。适配器以 `--capabilities` 声明已实现的方法，网关只开放声明过的。

| 方法 | 调用方 | 结论 |
| --- | --- | --- |
| `initialize` | iOS、agentd | 实现（#656） |
| `thread/list`、`thread/read`、`thread/loaded/list`、`thread/turns/list`、`thread/items/list` | iOS；agentd（`thread/read`） | 实现（#656）。列表含同仓库全部 worktree，历史与 `claude --resume` 一致 |
| `thread/start`、`thread/resume`、`turn/start`、`turn/steer`、`turn/interrupt` | iOS | 实现（#657） |
| `thread/takeover` | iOS | 实现（#658），规则同旧 bridge |
| `model/list` | iOS 模型选择 | 实现（#659）。读 Claude Code 自己的模型目录（initialize），整理规则同旧 bridge；缓存 10 分钟，失败退回别名 |
| `account/rateLimits/read` | iOS 额度、agentd 菜单栏 | 实现（#659）。只读复用 Claude Code 的 OAuth 凭据查询套餐额度，不刷新令牌；查不到时退回会话里观测到的 `rate_limit_event` |
| `thread/name/set` | agentd 自动标题 | 实现（#659）。与 CLI `/rename` 相同，往 transcript 追加 custom-title，CLI 与桌面端看到同一个名字（旧 bridge 只写自己的索引）；不支持清除名称 |
| `thread/archive`、`thread/unarchive` | 无（网关未开放） | 不实现。旧 bridge 的归档标记在首次启动时只读导入，列表照常过滤 |
| `thread/fork`、`thread/compact/start`、`thread/rollback` | 无（网关未开放） | 不实现。需要时可用 SDK 的 `forkSession` 与 CLI 的 `/compact` |
| `skills/list`、`skills/config/write`、`skills/remote/list`、`skills/remote/export` | 无（网关未开放） | 不实现 |
| `review/start`、`thread/backgroundTerminals/clean` | 无（网关未开放） | 不实现 |
| `command/exec`、`command/exec/write`、`command/exec/resize`、`command/exec/terminate` | 无（网关未开放） | 不实现 |
| `config/read`、`config/value/write`、`config/batchWrite`、`configRequirements/read`、`config/mcpServer/reload`、`mcpServerStatus/list`、`mcpServer/oauth/login` | 无（网关未开放） | 不实现 |
| `account/read`、`account/login/start`、`account/login/cancel`、`account/logout` | 无（agentd 只对 Codex 调用 `account/read`） | 不实现 |
| `feedback/upload`、`experimentalFeature/list`、`collaborationMode/list`、`mock/experimentalMethod` | 无（网关未开放） | 不实现 |

未实现的方法返回 `-32601`。旧 bridge 对 iPad 同样不开放这些方法，iPad 上 Claude 会话的改名、归档、分叉、压缩与技能列表在新旧实现下表现一致（都不提供）。

非公开依赖共两处：占用登记（#658）与额度查询用的 OAuth usage 接口（`src/claude/usage.ts`）。SDK 的额度接口目前标为实验性，且需要另起 Claude 进程（可能顺带刷新令牌），稳定后再改用。

## 开发

需要 Bun（版本见 `.bun-version`）。

```bash
cd bridges/claude-sdk
bun install --frozen-lockfile --omit optional
bun test
./node_modules/.bin/tsc --noEmit
bun run build   # 输出 dist/mimi-claude-adapter
```

`--omit optional` 跳过 SDK 附带的平台 CLI（约 240 MB）：适配器始终使用用户已安装的 `claude`。仓库统一检查入口是 `bash ./scripts/check-claude-sdk-adapter.sh`。

测试只读合成夹具（`CLAUDE_CONFIG_DIR` 指向临时目录），不接触真实的 `~/.claude`。对话测试用 `test/support/fake-claude.ts` 模拟 Claude CLI（按真实 CLI 的控制协议录制实现），不调用模型。

诊断：设置 `MIMI_CLAUDE_ADAPTER_TRACE=1` 时，每条 SDK 消息的类型与归属标记（不含正文）写到 stderr，agentd 会收进日志。

## 在开发机上试用

把 agentd 配置里的 `claude.bridge_bin` 指向 `dist/mimi-claude-adapter`。驱动对话使用 `claude.env.CLAUDE_BRIDGE_CLAUDE_BIN` 指定的 claude（与旧 bridge 同一个配置项），未设置时用 PATH 里的 `claude`。适配器只读 Claude 数据，自身状态（Mimi 覆盖层，目前只有归档标记）写在：

- macOS：`~/Library/Application Support/mimi-remote/claude-adapter/`
- 可用 `MIMI_CLAUDE_ADAPTER_STATE_DIR` 覆盖

首次启动时会只读导入旧 bridge 索引里的归档标记。

## 协议类型

`src/protocol/codex/` 由 `codex app-server generate-ts` 生成，只保留用到的类型闭包，请勿手改。Codex CLI 版本必须与 `internal/httpapi/testdata/codex-protocol/codex-version.txt` 一致：

```bash
bash scripts/sync-protocol.sh   # 可用 CODEX_BIN 指定 Codex CLI
```

## 依赖许可

- 协议类型生成自 [OpenAI Codex](https://github.com/openai/codex)（Apache-2.0）。
- `@anthropic-ai/claude-agent-sdk` 不是开源许可，使用受 Anthropic 法律协议约束。随 Mac App 分发前需确认许可（#660）。
