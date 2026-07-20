# Mimi Remote Agent

## 目标

Mimi Remote Agent 是运行在用户自己 Mac 或 Linux 开发机上的 Go 服务。它通过受控的 HTTP/WebSocket 接口，把移动端请求转发到本机 Codex app-server，同时负责鉴权、目录授权、协议白名单、服务诊断和资源边界。

这个公开发布镜像只包含后端、安装脚本和发布配置。Mimi Remote 的 iPhone / iPad 客户端源码位于完整开源仓库 [gaixianggeng/codex-ipad-agent](https://github.com/gaixianggeng/codex-ipad-agent)。

本项目是独立开发的第三方工具，不隶属于 OpenAI，也不代表 OpenAI 官方产品。

## 方案

```text
iPhone / iPad App
  -> Tailscale Endpoint:8787
  -> agentd Bearer 鉴权、工作区授权和 JSON-RPC 安全校验
  -> loopback codex app-server WebSocket:4222
  -> 用户本机的 Codex 凭证、线程和项目目录
```

默认安全边界：

- `agentd` 运行在用户自己的开发机上，不托管代码和 Codex 凭证。
- 移动端只持有外侧 `agentd` Token，不接触 app-server capability token。
- 项目、目录和 Worktree 必须位于配置允许的根目录。
- Gateway 只放行移动端需要的 Codex JSON-RPC 方法，并对请求和响应重新校验。
- 默认通过 Tailscale 私有网络访问，不建议把 `agentd` 直接暴露到公网。
- 远程命令只执行配置中的 allowlist action，不开放任意 Shell。

## 实现

### macOS

前置条件：

- 已安装并登录 Codex CLI。
- Mac 和移动设备已加入同一个 Tailscale 网络。
- 已安装 Homebrew。

```bash
brew update
brew install gaixianggeng/tap/mimi-remote

codex --version
codex app-server --help
agentd up
agentd status
```

`agentd up` 会生成用户私有配置和独立 Token、启动 Homebrew 后台服务、等待 Codex app-server 真正就绪，然后输出短期配对二维码。重复执行会复用现有配置，不会覆盖已经配对的长期 Token。

### Linux

Linux Release 归档包含 user-systemd unit 和安装脚本。下载目标版本和 `checksums.txt`，校验后执行：

```bash
bash ./scripts/install-linux.sh install
```

安装、升级、回滚和卸载的完整命令见 [安装、升级与回滚](docs/install-upgrade-rollback.md)。

### 从源码构建

要求 Go `1.25.0`：

```bash
go test ./...
go build -trimpath -o bin/agentd ./cmd/agentd

./bin/agentd setup --scan-root "$HOME/code" --browse-root "$HOME"
./bin/agentd serve
```

常用命令：

```bash
agentd up
agentd status
agentd pair --qr-only
agentd doctor --fix
agentd logs -n 200
agentd restart
agentd stop
```

macOS 上的 `agentd restart` 使用 launchd 单次原子重启，可以从当前服务托管的远程任务安全触发；不要在这类任务中直接运行 `brew services restart mimi-remote`。

### Claude Code 可选通道

Claude 通道需要 `alleycat-claude-bridge >= 0.2.1`。bridge 与完整 Mimi Remote 源码同仓维护：

```bash
cargo install --git https://github.com/gaixianggeng/codex-ipad-agent.git \
  --locked --force --bin alleycat-claude-bridge alleycat-claude-bridge

command -v alleycat-claude-bridge
```

把最后一条命令返回的绝对路径写入配置的 `claude.bridge_bin`，设置 `claude.enabled=true`，然后执行：

```bash
agentd restart
agentd doctor
```

核心入口：

- `GET /healthz`：仅检查进程存活。
- `GET /api/readyz`：检查配置、鉴权和真实 Codex app-server WebSocket 握手。
- `GET /api/projects`：返回已授权项目。
- `GET /api/app-server/config`：返回客户端可用的运行时配置。
- `GET /api/app-server/ws`：受鉴权和协议白名单保护的 JSON-RPC WebSocket。

示例配置见 [config.example.json](config.example.json)。完整协议边界见 [Codex app-server 协议支持](docs/codex-protocol-support.md)。

### 发布验证

```bash
go test ./... -count=1
go vet ./...
bash ./scripts/check-codex-protocol.sh
bash ./scripts/check-public-repo-safety.sh
bash ./scripts/check-packaging.sh
bash ./scripts/test-install-linux.sh
bash ./scripts/verify-release.sh
```

## 风险与优化

- Tailscale 断开时移动端无法访问服务；项目不提供应用层公网中继。
- Codex app-server 协议可能变化，升级 Codex CLI 后应先运行协议漂移检查。
- `danger-full-access` 只适合用户自己的受信开发机；审批策略仍应保持 `on-request`。
- 多用户、云同步、任意 Shell 和公网 SaaS 不属于当前范围。

安全问题请按 [安全政策](SECURITY.md) 私下报告。项目使用 [GNU GPLv3](LICENSE)，并附 App Store / Google Play 分发例外；第三方归属和许可证正文见 [NOTICE.md](NOTICE.md) 与 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
