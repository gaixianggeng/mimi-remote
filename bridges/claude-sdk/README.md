# Claude SDK 适配器

基于官方 [Claude Agent SDK](https://code.claude.com/docs/en/agent-sdk/typescript) 的 Claude 通道适配器，用来替换 `bridges/claude` 下的 Rust bridge。设计与拆分见 #655。

## 原则

- **会话数据只有一份，归 Claude Code。** 列表、历史、标题都通过 SDK 读取，不再自己解析 transcript，也不保存第二份会话目录。Mimi 里看到的历史与 `claude --resume` 一致：分叉只显示 CLI 继续的那条支线，被 Claude 压缩掉的历史与 CLI 一样不显示。
- **项目 = Git 仓库。** 按目录查询时，包含同仓库所有 worktree 的会话。
- **活动时间取最后一条对话消息的时间戳**，不用文件修改时间（#653）。
- **agentd 接口不变。** 启动参数（`--socket`，Windows 上 `--tcp-listen <回环IP>:<端口>`；`--version`）、`_alleycat/attach` 握手、`_alleycat_seq` 序号和断线重放与旧 bridge 一致，切换只需改 `claude.bridge_bin`。
- **不碰 Claude 的登录凭据。** 只驱动用户自己安装、未修改的 Claude Code，由用户用自己的账号登录；额度只来自 Claude Code 在会话里自己上报的事件（#660）。

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
  - 持有方出现、退出或在空闲与执行之间切换时推送 `thread/status/changed`，附带与 Thread 同名的 `canAcceptDirectInput`、`claudeOwner`（含 `statusUpdatedAt`）和会话最后活动时间 `updatedAt`，客户端不用重新读取就能切换只读状态、刷新列表时间与未读水位。推送面向**全部已附着的连接**，不限该会话的订阅者：列表页不订阅任何会话，终端里的会话开始 / 结束处理也要能推到列表（#683）。常驻模式一启动就监听占用登记，不等第一个订阅。
  - 会话的 `status` 在 `thread/list`、`thread/read`、`thread/resume` 与 `thread/status/changed` 里同源：本适配器有进行中的 turn，或别处持有方正在执行（`busy` / `shell`）→ `active`；本适配器有常驻进程，或持有方空闲 → `idle`；都没有 → `notLoaded`。持有方执行中时 `thread/read` 的最后一轮也按进行中呈现（没有结果的工具调用显示为进行中）。
  - **接管**：规则沿用旧 bridge（#451）——只结束全部明确空闲、且进程启动时间与登记 `startedAt` 吻合的持有方；先 SIGINT，5 秒后重查状态再 SIGTERM；持有方退出后若有新进程认领同一会话，报 `holder_respawned` 且不再发信号。失败以 `-32602` 返回 `{accepted, reason, claudeOwner, retryable}`。
  - CLI 自身行为：恢复一个生成到一半被结束的会话时，CLI 会补一条 `No response requested.`，与被中断的那条回复成为兄弟节点。历史按 CLI 继续的支线显示，与 `claude --resume` 一致。
- **其余能力（#659）**：`model/list`、`account/rateLimits/read`、`thread/name/set`，见下面的对照表。
- **切换准备（#660）**：
  - Claude Code 最低 2.1.294（`src/version.ts`），在 `--capabilities` 的 `claudeCode.minimumVersion` 里声明，供 agentd 预检提示；起 Claude 进程前再检查一次，未安装、版本无法确认或过旧时 `turn/start` 以 `-32603` 返回 `claude_missing`、`claude_version_unknown` 或 `claude_unsupported`，附升级提示。
  - 首次常驻启动时迁移旧 bridge 里 Mimi 显示的名称：写成 custom-title（与 CLI `/rename` 相同），只补 Claude 侧没有标题或只有 AI 自动标题的会话，用户手动改过的保留；被别的进程占用的会话下次启动再补，全部完成后在覆盖层记下；旧索引暂时读不了或格式不对时（与文件不存在不同）不记完成，归档标记与名称都在下次启动重试。
  - Mac App 与 Windows 安装包随附适配器（`mimi-claude-adapter`），agentd 默认使用它；配置 `claude.legacy_bridge: true` 或环境变量 `AGENTD_CLAUDE_LEGACY_BRIDGE=1` 切回旧 Rust bridge，保留一个版本周期。Linux 与 Homebrew 发布包不随附适配器，继续使用单独安装的旧 bridge。

## 与旧 bridge 的逐方法对照

依据是实际调用方：iOS 只能经 agentd 网关调用 Claude 通道白名单里的方法（`internal/httpapi/appserver_gateway.go` 的 `appServerClaudeAllowedMethods`），agentd 内部经匿名连接调用 `initialize`、`thread/read`、`thread/name/set`（自动标题）和 `account/rateLimits/read`（菜单栏额度）。适配器以 `--capabilities` 声明已实现的方法，网关只开放声明过的。

| 方法 | 调用方 | 结论 |
| --- | --- | --- |
| `initialize` | iOS、agentd | 实现（#656） |
| `thread/list`、`thread/read`、`thread/loaded/list`、`thread/turns/list`、`thread/items/list` | iOS；agentd（`thread/read`） | 实现（#656）。列表含同仓库全部 worktree，历史与 `claude --resume` 一致 |
| `thread/start`、`thread/resume`、`turn/start`、`turn/steer`、`turn/interrupt` | iOS | 实现（#657） |
| `thread/takeover` | iOS | 实现（#658），规则同旧 bridge |
| `model/list` | iOS 模型选择 | 实现（#659）。读 Claude Code 自己的模型目录（initialize），整理规则同旧 bridge；缓存 10 分钟，失败退回别名 |
| `account/rateLimits/read` | iOS 额度、agentd 菜单栏 | 实现（#659）。只用 Claude Code 在会话里上报的 `rate_limit_event`（5 小时与 7 天窗口），不读取 Claude 的登录凭据（#660）；适配器启动后还没跑过回合时返回不可用 |
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

非公开依赖只有一处：占用登记（#658）。额度不再查询 OAuth usage 接口（#660）；SDK 的额度接口仍标为实验性，且要另起 Claude 进程，稳定后再评估。

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

诊断（#666）：日志只写 stderr，格式固定为 `[mimi-claude-adapter] <级别> <事件> key=value …`，级别由 `MIMI_CLAUDE_ADAPTER_LOG`（`error`/`warn`/`info`/`debug`/`trace`，默认 `info`）控制；`MIMI_CLAUDE_ADAPTER_TRACE=1` 额外输出每条 SDK 消息的类型与归属标记（`trace`）。关键处的 `debug` 打点覆盖：连接附着与断开、每个 RPC 的方法/耗时/错误码、会话列表的匹配数、turn 的开始/引导/中断/收尾、审批的发出/答复/撤回、占用变化/让出/接管、Claude 进程的启动/就绪/退出与设置切换、模型目录与额度查询。只记 ID、方法名、耗时与状态，不记消息正文、提示词、工具输入输出与凭据，用户主目录写成 `~`。

agentd 托管时默认把适配器设为 `debug`（`claude.env` 里显式设置的级别优先），再按级别分流：`debug`/`trace` 行只在 Mac App「诊断 → 详细记录（15 分钟）」窗口内写进本机调试日志 `~/Library/Logs/mimi-remote/agentd-debug.log`，其余行照旧进 agentd 的标准日志。同一个窗口内，网关拒绝请求时的方法名、规则代码与说明也写进这份调试日志。调试日志只按大小轮转，「清除…」会一起清掉，不进入「导出安全日志」。命令行也可以控制同一个窗口：`agentd diagnostics start|stop|status --json`。

## 实机验收

`bun run acceptance`（即 `bun scripts/acceptance/main.ts`）经本机 agentd 网关——与 iPhone 同一个入口、同一个令牌——对接真实的 Claude CLI 与 `~/.claude`，逐项检查：通道与能力声明、模型列表、收发消息、会话上报的额度、新会话标题推送、worktree 会话（含 CLI 建的）出现在所属仓库、运行中补充与中断、命令审批、Claude 提问、终端 `claude --resume` 接手时让出/恢复/接管（用 tmux 模拟终端），以及历史与 CLI 视图逐条一致。

- 会在 agentd 扫描根目录下临时建一个 `mimi-acceptance-<时间>` 仓库（含两种 worktree），每项只发很短的 Haiku 请求；结束时结束沙盒里的 Claude 进程，删除仓库与它产生的会话文件。`--keep` 保留现场，`--only turn,ownership` 只跑部分用例。
- `--parity-repo <仓库目录> [--parity-limit N]` 额外只读对照该仓库最近 N 个已有会话（默认 5 个）。完整历史与 iPhone 共用网关的下行预算，被限流时会等待重试。
- 运行期间测试会话的回合结束、审批请求会照常触发手机推送；沙盒清理后点开推送找不到会话。
- 报告写到临时目录（`--report` 指定路径），有失败项时退出码为 1。

## 在开发机上试用

把 agentd 配置里的 `claude.bridge_bin` 指向 `dist/mimi-claude-adapter`（命令行运行的 agentd 照用明确指向的程序；Mac App 内的 agentd 固定使用随包文件）。驱动对话使用 `claude.env.CLAUDE_BRIDGE_CLAUDE_BIN` 指定的 claude（与旧 bridge 同一个配置项），未设置时用 PATH 里的 `claude`。适配器只读 Claude 数据，自身状态（Mimi 覆盖层，目前只有归档标记）写在：

- macOS：`~/Library/Application Support/mimi-remote/claude-adapter/`
- 可用 `MIMI_CLAUDE_ADAPTER_STATE_DIR` 覆盖

首次启动时只读导入旧 bridge 索引里的归档标记，并按上面的规则迁移 Mimi 里的名称。旧索引位置与旧 bridge 相同：macOS `~/Library/Application Support/codex/claude-bridge/threads.json`，Windows `%APPDATA%\codex\config\claude-bridge\threads.json`，Linux `$XDG_CONFIG_HOME/codex/claude-bridge/threads.json`（默认 `~/.config`）；可用 `MIMI_CLAUDE_LEGACY_INDEX` 覆盖，设为空字符串则不读。

## 协议类型

`src/protocol/codex/` 由 `codex app-server generate-ts` 生成，只保留用到的类型闭包，请勿手改。Codex CLI 版本必须与 `internal/httpapi/testdata/codex-protocol/codex-version.txt` 一致：

```bash
bash scripts/sync-protocol.sh   # 可用 CODEX_BIN 指定 Codex CLI
```

## 依赖许可

- 协议类型生成自 [OpenAI Codex](https://github.com/openai/codex)（Apache-2.0）。
- `@anthropic-ai/claude-agent-sdk` 为 Anthropic 专有许可（保留所有权利，使用受 Anthropic 法律协议约束）。适配器只驱动用户自己安装、未修改的 Claude Code，由用户用自己的账号登录，不读取 Claude 的登录凭据。随安装包正式发布前由负责人确认许可（#660）。
