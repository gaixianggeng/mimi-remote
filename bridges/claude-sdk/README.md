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
  - 会话被终端或桌面端占用时只读（读取 Claude 的占用登记），`turn/start` 返回 `owned_elsewhere`。接管与"驱动中让出"在 #658。
  - 已知差异：引导消息在 transcript 里是普通的用户记录，重新加载历史时显示为单独一轮，实时显示时在同一轮里。
- 其余方法（模型、技能、额度、改名、归档等）返回 `-32601`，在 #659 补齐。默认配置仍使用 Rust bridge。

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
