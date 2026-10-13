# Claude bridge

## 目标

这个目录包含 Mimi Remote 的 Claude Code 实验通道。`agentd` 启动 `alleycat-claude-bridge` 子进程，把 iOS 使用的 Codex app-server JSON-RPC 映射到 Claude Code headless `stream-json`。

只保留运行该通道需要的三个 Rust crate：

- `crates/claude-bridge`：Claude Code 进程、审批、会话和事件转换；
- `crates/bridge-core`：JSON-RPC framing、进程池和共享 bridge 基础设施；
- `crates/codex-proto`：移动端与 bridge 共用的 app-server wire types。

Amp、Pi、OpenCode、Droid、Hermes 和 Alleycat daemon 不属于 Mimi Remote 当前范围，因此没有一并导入。

## 执行边界（#488）

旧 Rust bridge 无法逐条兑现 `writableRoots` 与 `networkAccess`。`turn/start` 只接受明确的 `sandboxPolicy: {"type":"dangerFullAccess"}`，审批模式仍按原规则处理。省略策略、只读、工作区写入、附加限制或 `permissionProfile` 都会在取进程、修改运行时和发送用户消息前拒绝，不继承上一轮的完全访问。

拒绝使用 JSON-RPC `-32602`，附带 `accepted:false`、`reason:"sandbox_policy_unsupported"`、`retryable:false` 和 `requiredAdapter:"mimi-claude-adapter"`。错误提示用户改用 SDK 通道。`CLAUDE_BRIDGE_SANDBOX_POLICY=guarded|inherit` 均不豁免此检查。会话列表与历史读取不受影响。

Linux、Homebrew 安装及 `legacy_bridge` 回退仍使用此旧通道，因此无法继续执行受限轮次。需要受限执行时应使用 [SDK 适配器](../claude-sdk/README.md#受限执行边界488)；切换完全访问必须由用户明确选择，bridge 不自动提升权限。

## 构建与验证

从仓库根目录执行：

```bash
cargo test --locked \
  -p alleycat-codex-proto \
  -p alleycat-bridge-core \
  -p alleycat-claude-bridge

cargo install --locked \
  --path bridges/claude/crates/claude-bridge \
  --force \
  --bin alleycat-claude-bridge
```

安装完成后：

```bash
command -v alleycat-claude-bridge
alleycat-claude-bridge --version
```

macOS 上主动读取 Claude 用量时，bridge 会只读复用 Claude Code 的 Keychain 凭据。
用量查询不会启动隐藏的 Claude CLI，也不会驱动 OAuth 刷新，避免与真正的会话进程
竞争 refresh token。凭据过期或查询失败时会降级到已观测的 `rate_limit_event`；若其他
Claude 进程已经轮换凭据，HTTP 401 后只重新读取一次 Keychain 并用新凭据重试。

## 来源与协议

代码来源、导入 commit 和本地修改见 [UPSTREAM.md](UPSTREAM.md)。本目录保留上游 [GNU GPLv3-only](LICENSE)，不适用仓库根目录为自有 iOS / Mac / Go 代码提供的 App Store / Google Play 分发例外。
