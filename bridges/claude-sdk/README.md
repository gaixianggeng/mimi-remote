# Claude SDK 适配器

基于官方 [Claude Agent SDK](https://code.claude.com/docs/en/agent-sdk/typescript) 的 Claude 通道适配器，用来替换 `bridges/claude` 下的 Rust bridge。设计与拆分见 #655。

## 原则

- **会话数据只有一份，归 Claude Code。** 列表、历史、标题都通过 SDK 读取，不再自己解析 transcript，也不保存第二份会话目录。Mimi 里看到的历史与 `claude --resume` 一致：分叉只显示 CLI 继续的那条支线，被 Claude 压缩掉的历史与 CLI 一样不显示。
- **项目 = Git 仓库。** 按目录查询时，包含同仓库所有 worktree 的会话。
- **活动时间取最后一条对话消息的时间戳**，不用文件修改时间（#653）。
- **agentd 接口不变。** 启动参数（`--socket`，Windows 上 `--tcp-listen <回环IP>:<端口>`；`--version`）、`_alleycat/attach` 握手、`_alleycat_seq` 序号和断线重放与旧 bridge 一致，切换只需改 `claude.bridge_bin`。唯一差别：请求的响应不入重放环、不带序号（旧 bridge 会入环但从不补发，#910）。
- **不碰 Claude 的登录凭据。** 只驱动用户自己安装、未修改的 Claude Code，由用户用自己的账号登录；额度只来自 Claude Code 在会话里自己上报的事件（#660）。

## 当前阶段

- **只读（#656）**：`initialize`、`thread/list`、`thread/read`、`thread/loaded/list`、`thread/turns/list`、`thread/items/list`。
- **对话（#657）**：`thread/start`、`thread/resume`、`turn/start`、`turn/steer`、`turn/interrupt`。
  - 每个会话一个常驻的 SDK `query()`（流式输入），使用 Claude Code 自带的系统提示词。完全访问沿用 CLI 的设置来源；受限档位按下方执行边界隔离设置。
  - 模型、权限模式、思考强度在 turn 之间通过 SDK 控制接口切换；执行边界或完全访问状态变化时重启进程。
  - 空闲回收：turn 收尾后进程空闲 10 分钟即关闭，下一次 `turn/start` 以 resume 重新拉起。后台任务（Bash `run_in_background`、后台子代理等）属于这个进程，进程一关就随之结束、完成后的续写也不会发生，所以按 SDK 的 `background_tasks_changed`（不含 ambient 任务）判断：仍有任务在跑时不关闭，全部结束后重新计时（#796）。让出、执行边界变化重启、适配器退出或进程自己退出时仍有后台任务，记一条 warn 日志 `claude.background_tasks_dropped`（任务数与原因）。
  - 审批（`canUseTool`）映射为 `item/commandExecution/requestApproval`、`item/fileChange/requestApproval`；`AskUserQuestion` 映射为 `item/tool/requestUserInput`。请求发给订阅该会话的所有连接，先答复者生效，其余收到 `serverRequest/resolved`；重连时由 `serverRequest/replay` 补发未答复的请求。
  - 引导以人工输入的 `now` 优先级并入当前 turn。turn 要等名下所有消息（含引导）都被 Claude 的结果吸收才收尾；输出与结果按 `user_message_uuid` 归属，CLI 队列里还有未完成的消息时拒绝新的 `turn/start`。
  - 已知差异：引导消息在 transcript 里是普通的用户记录，重新加载历史时显示为单独一轮，实时显示时在同一轮里。
  - 后台任务完成后的续写（#797）：CLI 为完成通知单独跑一轮，输出不带 `user_message_uuid`，transcript 里通知那条记录的 uuid 实时侧也拿不到。两边都按会话 ID 与任务这次运行的 `run_id`（实时 `task_notification` 帧、通知记录的 `origin.runId`）生成同一个回合 ID（`src/claude/itemIds.ts` 的 `notificationTurnId`），客户端无论从实时事件还是历史得知这一轮，都能停止它、向它补充消息。通知触发的一轮在 `system/init` 时就开出续写回合（不等首帧输出），首帧前的排队、重试期间它就是活动回合，`turn/start` 被拒，输出不会挂到别的回合上。几条通知连着送达时只有一段回复，回合归最后一条（CLI 为前几条各跑一轮空的，它们的结果不收尾续写回合，CLI 回到 idle 时兜底收尾）；回合进行中送达的通知被 CLI 并进当前回合（SDK 标为排队消息），不另开回合。向续写补充的消息由 CLI 排在续写自己的结果之后单独回应，实时仍并进这个回合，重新加载历史时按上一条的已知差异单独显示。2.1.294 与 2.1.301 实测。
  - 输入转换（`src/runtime/userInput.ts`）：CLI 只在消息以 `/名称` 开头时执行命令，内容数组只检查最后一个块（2.1.294–2.1.301 实测）。CLI 只认名字：用户与项目技能会遮蔽同名的内置命令和自带技能，同名技能用户级优先、离 cwd 近的优先。所以只有附件的 path 是 CLI 加载的用户或项目技能、且这个名字在这些目录里（含 frontmatter 的 name 与自定义命令）只有它一处定义时，才把它提到开头、正文作为参数（`src/claude/skillCommand.ts`）；其余技能排在正文之后作为 `/名称` 文本，没有正文垫在前面时报参数错误。文本以 `/` 开头且带图片时，图片排在前面、文本合成最后一块（#773）。受限档位的用户与项目技能经合成插件加载、查找规则相同，所以按同一条规则提前，发送前改写成 `/mimi:名称`（见[受限执行边界](#受限执行边界488)）。
- **单一驱动方（#658）**：`thread/takeover`。同一会话同一时刻只有一个 Claude 进程在写。
  - 占用登记（`<配置目录>/sessions/<pid>.json`，Claude Code 为每个活进程写的文件）是唯一没有公开接口的依赖，只读。自己起的进程按 pid 排除；拿到 pid 之前，同一会话新出现的登记先不算别处，避免把自己当成别人。
  - 别处持有时会话只读：`thread/list`、`thread/resume` 带 `canAcceptDirectInput: false` 与 `claudeOwner` 摘要，`turn/start` 返回 `owned_elsewhere`。
  - **驱动中让出**：监听登记目录（目录事件 + 2 秒轮询兜底）。适配器握着进程时出现别的持有方（例如终端执行了 `claude --resume`），立即给自己的 CLI 发 SIGTERM，进行中的 turn 记为中断，不再写 transcript。实测终端进程启动后约 0.5 秒让出。
  - 持有方出现、退出或在空闲与执行之间切换时推送 `thread/status/changed`，附带与 Thread 同名的 `canAcceptDirectInput`、`claudeOwner`（含 `statusUpdatedAt`）和会话最后活动时间 `updatedAt`，客户端不用重新读取就能切换只读状态、刷新列表时间与未读水位。推送面向**全部已附着的连接**，不限该会话的订阅者：列表页不订阅任何会话，终端里的会话开始 / 结束处理也要能推到列表（#683）。常驻模式一启动就监听占用登记，不等第一个订阅。
  - 会话的 `status` 在 `thread/list`、`thread/read`、`thread/resume` 与 `thread/status/changed` 里同源：本适配器有进行中的 turn，或别处持有方正在执行（`busy` / `shell`）→ `active`；本适配器有常驻进程，或持有方空闲 → `idle`；都没有 → `notLoaded`。历史里的最后一轮只在本适配器自己有进行中的 turn 时标为进行中；别处持有方执行时不合成进行中的 turn，避免客户端把它记成自己的活跃 turn、错过空闲推送后一直显示处理中。
  - **接管**：规则沿用旧 bridge（#451）——只结束全部明确空闲、且进程启动时间与登记 `startedAt` 吻合的持有方；先 SIGINT，5 秒后重查状态再 SIGTERM；持有方退出后若有新进程认领同一会话，报 `holder_respawned` 且不再发信号。失败以 `-32602` 返回 `{accepted, reason, claudeOwner, retryable}`。
  - CLI 自身行为：恢复一个生成到一半被结束的会话时，CLI 会补一条 `No response requested.`，与被中断的那条回复成为兄弟节点。历史按 CLI 继续的支线显示，与 `claude --resume` 一致。
- **其余能力（#659）**：`model/list`、`account/rateLimits/read`、`thread/name/set`，见下面的对照表。
- **斜杠命令目录（#765）**：`slashCommand/list`（`cwd`、与下一次 `turn/start` 相同的 `sandboxPolicy`、可选 `forceReload`）返回 `{ data: [{ name, description, argumentHint, aliases }] }`，供 iPad 的 `/` 菜单展示。客户端只把 `/名称 ` 插进草稿、按普通文本发送，由 Claude Code 自己解析，适配器不执行命令。
  - 来源：同一工作区、同样设置来源的常驻进程的 `supportedCommands()`（含 MCP 命令与运行中发现的技能）；没有时另起一个不带工具、不启动 MCP、不跑 hooks、不保存会话的进程，只读 initialize 的目录，按（工作区, 是否加载本机设置）缓存 5 分钟，失败后冷却 15 秒。技能与命令的来源取自运行时同一个 `sandboxOptions`：完全访问不传 `settingSources`（SDK 缺省加载 user / project / local，与 CLI 相同）；受限档位不加载设置，用户与项目的技能和命令经运行时同一个合成插件加载（#775），目录里登记为 `mimi:名称`（原名作别名，说明前的 `(mimi) ` 去掉），与运行时改写后实际执行的 `/mimi:名称` 一致。
  - 隐藏：CLI 在 `system/init` 里标为终端专用的命令（`terminal_slash_commands`，适配器跑过回合后才知道）；`/clear`（实测会让 CLI 换一个新会话 ID，Mimi 里的会话不再更新）、`/model`、`/effort`（只改 CLI 进程，客户端的选择器不知道）；名字含空白或以 `__` 开头的条目。同名条目取 CLI 自己的那一行。
  - 实测（Claude Code 2.1.301，经 `ThreadRuntime` 的流式输入）：纯文本消息以 `/名称 参数` 开头时，自定义命令、技能、`/context`、`/compact` 都按命令执行，本地命令的输出以 assistant 消息返回；同一消息带图片时不解析；`.skill` 输入排在正文之后时转成 `正文\n/名称`，不在开头，不会被识别。
- **切换准备（#660）**：
  - Claude Code 最低 2.1.294（`src/version.ts`），在 `--capabilities` 的 `claudeCode.minimumVersion` 里声明，供 agentd 预检提示；起 Claude 进程前再检查一次，未安装、版本无法确认或过旧时 `turn/start` 以 `-32603` 返回 `claude_missing`、`claude_version_unknown` 或 `claude_unsupported`，附升级提示。
  - 首次常驻启动时迁移旧 bridge 里 Mimi 显示的名称：写成 custom-title（与 CLI `/rename` 相同），只补 Claude 侧没有标题或只有 AI 自动标题的会话，用户手动改过的保留；被别的进程占用的会话下次启动再补，全部完成后在覆盖层记下；旧索引暂时读不了或格式不对时（与文件不存在不同）不记完成，归档标记与名称都在下次启动重试。
  - Mac App 与 Windows 安装包随附适配器（`mimi-claude-adapter`），agentd 默认使用它；配置 `claude.legacy_bridge: true` 或环境变量 `AGENTD_CLAUDE_LEGACY_BRIDGE=1` 切回旧 Rust bridge，保留一个版本周期。Linux 与 Homebrew 发布包不随附适配器，继续使用单独安装的旧 bridge；旧通道从 #488 起明确拒绝受限轮次，详见 [旧通道执行边界](../claude/README.md#执行边界488)。

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
| `slashCommand/list` | iOS `/` 菜单 | 实现（#765）。适配器专有方法，规则见上 |
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

## 受限执行边界（#488）

`workspaceWrite` 把 `writableRoots` 映射为 Bash 沙箱可写根。根必须存在且包含 `cwd`，否则拒绝执行。`readOnly` 在 Bash 沙箱中拒绝所有文件写入，并在 `PreToolUse` 拒绝原生文件编辑。文件工具逐次解析真实路径，拒绝根外路径、指向根外的软链接（含悬空链接）与无法确认全部位置的硬链接。

`networkAccess=false` 同时禁止 Bash 出网、WebFetch 和 WebSearch。Bash 不允许脱离沙箱重试；沙箱不可用时 CLI 失败退出。原生 Windows 不支持 Bash 沙箱，因此受限档位禁用 shell，保留带路径检查的文件工具。未核实边界的 MCP、插件与子代理工具会被拒绝。审批只允许本次调用，不能通过权限建议扩大可写目录或网络范围。

受限子进程不加载 user / project / local 设置，不启动本地 MCP；这些设置内的 hook、额外目录、allow rule 与 CLAUDE.md 不会自动加载。适配器不修改这些文件。完全访问的行为保持不变。

受限档位的用户技能与命令（`~/.claude/skills`、`~/.claude/commands`）、项目技能与命令（从 `cwd` 向上到 git 根各级的 `.claude/skills`、`.claude/commands`）经适配器合成的本地插件加载（#775，`src/claude/skillPlugin.ts`）：每次起进程在临时目录生成只含 `skills/`、`commands/` 的插件，技能软链接回原位置、命令文件复制进来，同名时用户级优先、项目目录近的优先（与 CLI 实测一致），进程退出后删除。插件技能在 CLI 里登记为 `mimi:名称`，裸 `/名称` 只在 SKILL.md 写了 name 时才展开，所以适配器把命令位置的 `/名称`（目录名或 frontmatter 里的 name）改写成 `/mimi:名称`；历史里显示 CLI 实际执行的 `/mimi:名称`。技能只供用户主动调用：模型看不到技能列表（`skills: []`），Skill 工具被拒。技能 frontmatter 与插件里的命令 hook 在沙箱外执行，受限档位用 `disableAllHooks` 关闭（不影响适配器自己的 SDK 回调 hook）；技能内联的 `` !`命令` `` 在 Bash 沙箱内执行，原生 Windows 没有沙箱，换成占位文本。CLI 自身的登录、模型请求、transcript 和会话状态写入不属于工具沙箱；`networkAccess=false` 指工具出网，不是切断模型 API。

工作区模式仍使用 Claude 自带的临时目录。`excludeTmpdirEnv=true` 或 `excludeSlashTmp=true` 无法等价兑现，直接拒绝。历史环境变量 `CLAUDE_BRIDGE_SANDBOX_POLICY=guarded|inherit` 不会放宽 TS 适配器的边界；两种取值使用相同限制。

原生验收固定 Claude Code **2.1.294**、SDK **0.3.296**。测试使用隔离配置和本机脚本化模型端点，真实执行 CLI 工具，不消耗模型额度。以下命令从本目录运行：

```bash
MIMI_CLAUDE_POLICY_TEST_BIN="$(command -v claude)" bun test test/sandboxPolicy.native.test.ts
```

验收包含两种环境变量取值下的工作区 / 只读模式、内外写入、软链接外写、网络拒绝，本机配置试图放宽边界的情况，以及经合成插件加载的项目技能展开、用户技能加载、技能自带的命令 hook 不执行、模型看不到技能列表。命令目录发现的原生用例同样用这个开关：`bun test test/commands.native.test.ts`（只读 initialize，不调用模型），核对完全访问按原名、受限档位按 `mimi:名称` 列出用户与项目的命令和技能。后台任务的原生用例 `bun test test/backgroundTasks.native.test.ts` 让模型以 `run_in_background` 跑后台命令：比空闲时限长的命令照常完成、完成通知触发的续写作为新的一轮到达客户端、之后照常空闲关闭（#796）；续写输出到一半时，历史报告的进行中回合与实时相同，按这个 ID 停止与补充消息都生效（#797）。2.1.294 与 2.1.301 实测。普通 `bun test` 跳过这些用例；macOS 已实测，Linux 与原生 Windows 的运行态验收分别记录，不能用 macOS 结果替代。

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
