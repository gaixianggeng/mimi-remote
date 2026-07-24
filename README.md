# Mimi Remote Agent

## 目标

Mimi Remote Agent 是运行在用户自己 Mac 或 Linux 开发机上的 Go 服务。它通过受控的 HTTP/WebSocket 接口，把移动端请求转发到本机 Codex app-server，同时负责鉴权、目录授权、协议白名单、服务诊断和资源边界。

这个公开发布镜像包含后端、Mac 菜单栏宿主、安装脚本和发布配置。Mimi Remote 的 iPhone / iPad 客户端源码位于完整开源仓库 [gaixianggeng/codex-ipad-agent](https://github.com/gaixianggeng/codex-ipad-agent)。

本项目是独立开发的第三方工具，不隶属于 OpenAI，也不代表 OpenAI 官方产品。

## 方案

```text
iPhone / iPad App
  -> Tailscale 或同一局域网 Endpoint:8787
  -> agentd Bearer 鉴权、工作区授权和 JSON-RPC 安全校验
  -> loopback codex app-server WebSocket:4222
  -> 用户本机的 Codex 凭证、线程和项目目录
```

默认安全边界：

- `agentd` 运行在用户自己的开发机上，不托管代码和 Codex 凭证。
- 移动端只持有外侧 `agentd` Token，不接触 app-server capability token。
- 项目、目录和 Worktree 必须位于配置允许的根目录。
- Gateway 只放行移动端需要的 Codex JSON-RPC 方法，并对请求和响应重新校验。
- 跨网络默认推荐 Tailscale；未安装时可在同一局域网直连。两种方式都不应把 `agentd` 暴露到公网。
- 远程命令只执行配置中的 allowlist action，不开放任意 Shell。

## 实现

### macOS App（推荐）

从 [GitHub Releases](https://github.com/gaixianggeng/mimi-remote/releases/latest) 下载 `Mimi-Remote-Mac.dmg`，打开后把 **Mimi Remote Mac** 拖到 Applications。安装包同时支持 Apple Silicon 和 Intel，App 内已经包含 `agentd`，不要求用户安装 Go 或 Xcode。

首次打开 App 后，在菜单栏完成设置或接管已有 Homebrew 服务；检测到 Tailscale 时优先使用，否则自动启用同一局域网连接。现有配置、Token 和配对关系会保留。安装包使用 Developer ID 签名并经过 Apple Notarization，仍建议下载后核对同一 Release 中的 `Mimi-Remote-Mac.dmg.sha256`。

### Codex Skill

让 `$skill-installer` 安装以下 GitHub 路径，即可由 Codex 按仓库维护的安全流程执行安装、升级、诊断和回滚：

```text
https://github.com/gaixianggeng/mimi-remote/tree/main/packaging/skill/install-mimi-remote
```

每个 Release 同时提供 `install-mimi-remote.zip` 与对应 SHA-256 文件，作为可固定版本、可校验的独立发布包。Skill 只包含操作指引，不包含应用二进制、Token 或用户配置。

### Homebrew 后端

前置条件：

- 已安装并登录 Codex CLI。
- Mac 和移动设备位于同一私有网络；跨网络使用时建议加入同一个 Tailscale 网络。
- 已安装 Homebrew。

```bash
brew update
brew install gaixianggeng/tap/mimi-remote

codex --version
codex app-server --help
agentd up
agentd status
```

`agentd up` 会生成用户私有配置和独立 Token、启动 Homebrew 后台服务、等待 Codex app-server 真正就绪，然后输出短期配对二维码。检测到 Tailscale 时优先使用；否则自动启用 LAN 监听并生成当前局域网地址。重复执行会复用现有配置，不会覆盖已经配对的长期 Token。

Agent 或自动化安装使用 `agentd up --no-pair`；它执行相同初始化与就绪检查，但不输出二维码、Endpoint 和长期访问码。`agentd up --no-pair --json` 只返回版本、就绪状态和安全警告。需要配对时再由用户在本机终端执行 `agentd pair --qr-only`。

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

上面的命令用于前台调试。反复替换 macOS Homebrew 服务时，应使用稳定签名和可回滚的交接流水线，避免每次编译改变 `cdhash` 后丢失系统文件授权：

```bash
bash ./scripts/restart-agentd-dev-macos.sh

# 从当前 agentd 托管的远程任务发起
bash ./scripts/restart-agentd-dev-macos.sh --no-wait
bash ./scripts/restart-agentd-dev-macos.sh --status
```

常用命令：

```bash
agentd up
agentd up --no-pair
agentd status
agentd pair --qr-only
agentd doctor --fix
agentd logs -n 200
agentd restart
agentd restart --no-pair
agentd stop
```

macOS 上的 `agentd restart` 使用 launchd 单次原子重启，可以从当前服务托管的远程任务安全触发；不要在这类任务中直接运行 `brew services restart mimi-remote`。
`up --no-pair` 和 `restart --no-pair` 用于自动化，避免在日志中输出二维码、Endpoint 和长期访问码。

每次服务启动时，`agentd` 都会优先异步预检 projects、`scan_roots`、`browse_roots`；当浏览根覆盖当前 Home 时，还会探测 Desktop、Documents、Downloads，尽早触发 macOS“文件与文件夹”提示。预检不递归读取内容，也不会因弹窗未处理而阻塞服务上线，结果可在 `agentd status --json`、Doctor 和日志中查看。

授权 Home 顶层不等于授权 Home 内所有受保护位置。macOS 分别管理 Desktop、Documents、Downloads，“完全磁盘访问”还覆盖其他 App 数据、备份等。需要无人值守访问整个 Home 时，在“系统设置 → 隐私与安全性 → 完全磁盘访问”中一次性添加 `/opt/homebrew/opt/mimi-remote/bin/agentd`。

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

- Tailscale 断开时不会回退公网；Mac 与移动设备在同一局域网时可重新生成 LAN 配对信息，否则需要恢复 Tailnet。
- Codex app-server 协议可能变化，升级 Codex CLI 后应先运行协议漂移检查。
- `danger-full-access` 只适合用户自己的受信开发机；审批策略仍应保持 `on-request`。
- 多用户、云同步、任意 Shell 和公网 SaaS 不属于当前范围。

安全问题请按 [安全政策](SECURITY.md) 私下报告。项目使用 [GNU GPLv3](LICENSE)，并附 App Store / Google Play 分发例外；第三方归属和许可证正文见 [NOTICE.md](NOTICE.md) 与 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

Mimi Remote App 用户可查看双语[隐私政策](docs/privacy-policy.md)、[使用条款](docs/terms-of-use.md)与[支持说明](docs/support.md)。
