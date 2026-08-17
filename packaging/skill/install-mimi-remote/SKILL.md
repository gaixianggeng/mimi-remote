---
name: install-mimi-remote
description: 安装、配置、配对、迁移、升级、诊断、回滚或卸载 Mimi Remote；在 macOS 上安装和维护 Mimi Remote Mac 菜单栏 App / DMG，或通过 Homebrew、Linux user-systemd 部署 agentd；从源码构建 iPhone/iPad App；配置 Codex 主通道和可选 Claude Code 实验 Runtime。用户提出“安装 Mimi Remote”“安装或修复 Mac 菜单栏 App”“在 iPad/iPhone 上使用 Codex 或 Claude Code”“部署、迁移或修复 agentd”“升级、回滚、卸载 Mimi Remote”“构建 MimiRemote iOS App”或处理配对、私网连接、Runtime 故障时使用。
---

# 安装与维护 Mimi Remote

## 目标

把 Mimi Remote 安装成一个可验证、可恢复、权限最小化的本地闭环：

1. 在普通 macOS 用户场景中优先使用已签名、公证且内嵌 `agentd` 的 Mimi Remote Mac 菜单栏 App。
2. 通过 Tailscale 或同一局域网连接 iPhone / iPad，不部署公网中继。
3. 保持 Codex 为默认稳定 Runtime，仅在用户明确要求时启用 Claude Code 实验通道。
4. 保留现有配置、Token、Runtime 凭证、配对关系和源码改动。

Mimi Remote 是第三方开源客户端，不是 OpenAI、Anthropic 或 Tailscale 的官方产品。项目代码、Codex / Claude 凭证和完整会话继续留在用户自己的设备上。

## 执行原则

- 先执行只读检查，再安装或修改；复用已有安装，不重复初始化。
- 优先使用正式 Release，不把开发分支、未固定 commit、snapshot 或 `devel` 二进制当作稳定版本。
- macOS 普通用户默认安装 `Mimi-Remote-Mac.dmg`；Homebrew 只用于命令行、服务器、自动化、旧安装维护或故障恢复。
- 不假设本 Skill 所在目录或调用时的当前目录就是源码仓库。源码和正式产物统一从 `https://github.com/gaixianggeng/mimi-remote` 获取。
- 不覆盖有未提交改动的源码目录，不在现有脏工作树中切换 tag 或执行清理。
- 不使用 `agentd setup --force`，除非用户明确要求轮换凭据并接受现有配对失效。
- 不输出、转述、上传或写入任务总结中的长期 Token、Authorization header、连接链接、二维码内容、完整 Endpoint、Tailscale IP 或私有项目路径。
- 不把 `agentd` 暴露到公网，不自动配置端口转发、反向代理或公网 Tunnel。
- 不通过关闭审批、设置 `danger-full-access`、启用 `CLAUDE_BRIDGE_BYPASS_PERMISSIONS` 或自动重试写操作来解决 Runtime 问题。
- 不运行 `tccutil reset`。macOS 文件权限、登录项审批和签名信任必须由用户在系统界面确认。
- Linux 安装和服务操作使用普通登录用户，不使用 `sudo` 运行安装脚本。
- 只有用户明确要求 Claude Code 时才启用该 Runtime；Claude 失败不能破坏 Codex 主通道或轮换现有 Token。
- 升级、回滚或卸载前阅读 [安装、升级与回滚](https://github.com/gaixianggeng/mimi-remote/blob/main/docs/install-upgrade-rollback.md)。
- Claude 相关操作前阅读 [Claude bridge 架构](https://github.com/gaixianggeng/mimi-remote/blob/main/docs/claude-bridge-architecture.md)。
- iOS 构建、签名或真机部署前阅读 [iOS 开发说明](https://github.com/gaixianggeng/mimi-remote/blob/main/ios/MimiRemote/README.md)。

## 确定操作范围

选择能完成用户目标的最小路径：

- **macOS App 安装**：下载 DMG，在菜单栏 App 内完成设置、配对、诊断和服务管理。这是默认路径。
- **Homebrew 后端**：只维护命令行 `agentd`，用于服务器、自动化、旧安装或恢复。
- **Linux 后端**：安装 Release 归档中的 `agentd` 和 user-systemd service。
- **iOS 源码构建**：仅在用户需要安装当前未公开上架的 iPhone/iPad App 或开发客户端时执行。
- **Runtime 维护**：检查 Codex，或显式启用、升级、诊断 Claude Code。
- **维护操作**：对现有安装执行迁移、升级、回滚或卸载，不重新生成 Token。

只询问会改变结果的信息：

1. 要授权的最小项目扫描根目录。
2. 目标是 Mac App、CLI/Linux 后端、iOS 构建还是 Runtime 配置。
3. 是否明确需要 Claude Code；未说明时只配置 Codex。
4. 是否存在需要由 Mac App 接管的 Homebrew 服务。
5. 用户要求固定版本时使用哪个 tag；未指定时选择最新正式 Release，并在修改前告知版本。

## 执行预检

先执行不修改系统的检查：

```bash
uname -s
uname -m
id -u
command -v git
command -v codex
codex --version
codex app-server --help
```

确认 Codex CLI 已安装并登录。不要读取、复制或展示 Codex 凭证。若缺失，使用 OpenAI 当前官方安装说明，不凭记忆拼接安装命令。

确认 Mac 与移动设备位于同一私有网络。跨网络优先使用同一 Tailnet；同一局域网可以不安装 Tailscale。`tailscale` CLI 不在 `PATH` 时，允许用户通过 Tailscale App 确认状态。

macOS App 路径只要求 macOS 26 或更高版本和 Codex CLI；不要求 Homebrew、Go、Rust、Xcode 或 XcodeGen。仅在源码构建时检查相应工具链。

用户明确要求 Claude Code 时再检查：

```bash
command -v claude
claude --version
```

让用户在 Mac 本机确认 Claude Code 已登录。不要读取、复制或展示 Claude 凭证文件、Keychain 内容或 OAuth Token。

## 安装 Mimi Remote Mac

使用 `gaixianggeng/mimi-remote` 的最新正式 Release；用户指定版本时固定到对应 tag。下载：

```text
Mimi-Remote-Mac.dmg
Mimi-Remote-Mac.dmg.sha256
```

在同一目录严格校验：

```bash
shasum -a 256 -c Mimi-Remote-Mac.dmg.sha256
```

校验失败时停止，不打开 DMG。让用户完成必须的人机操作：

1. 打开 DMG，把 **Mimi Remote Mac** 拖到“应用程序”。
2. 首次打开 App，在菜单栏进入设置。
3. 选择最小代码扫描根目录并启动服务。
4. macOS 显示登录项或文件访问审批时，在系统设置中确认；不要绕过。

App 内已包含 `agentd` 和兼容的 `alleycat-claude-bridge`，普通安装不需要 Homebrew 或单独 `cargo install`。

若检测到 `homebrew.mxcl.mimi-remote`：

1. 保持旧服务运行，不要先手工停止。
2. 在 Mac App 中执行接管，让 App 先跑 Doctor、停止 Homebrew service、注册内嵌 LaunchAgent 并等待就绪。
3. 接管失败时确认 App 已尝试恢复 Homebrew；不要让两个服务同时抢占端口。
4. 迁移成功后保留原配置、Token 和配对关系。

macOS App 安装成功必须满足：

- 菜单栏显示服务就绪且 owner 为 `Mimi Remote Mac`。
- App 中的版本、Endpoint 和 Doctor 状态可读取。
- 登录启动状态符合用户选择。
- 配对页能生成短期二维码。

## 安装 Homebrew 后端

仅在用户选择 CLI、服务器、自动化、旧安装维护或恢复时使用：

```bash
brew update
brew install gaixianggeng/tap/mimi-remote
agentd version
```

普通修复不要无条件升级。首次初始化通过 Agent 或自动化执行时必须隐藏配对信息，并使用用户确认的最小目录：

```bash
agentd up --no-pair \
  --scan-root "/absolute/path/to/projects" \
  --browse-root "/absolute/path/to/projects"
agentd status --json | grep -E '"(process_ok|service_ok|doctor_ok)"'
agentd doctor
```

只以 `service_ok=true` 作为成功条件。`process_ok=true` 只表示 HTTP 进程存活。

从当前 `agentd` 托管的远程任务重启时使用：

```bash
agentd restart --no-pair
```

不要执行 `brew services restart mimi-remote`，避免旧服务退出后无法完成启动步骤。

## 安装 Linux 后端

使用 `gaixianggeng/mimi-remote` 的正式 Release，不从开发工作树安装 `devel` 二进制。根据架构选择归档：

```text
mimi-remote_VERSION_linux_amd64.tar.gz
mimi-remote_VERSION_linux_arm64.tar.gz
```

下载目标归档和同一 Release 的 `checksums.txt`，严格校验 SHA-256 后解压。在 Release 根目录执行：

```bash
bash ./scripts/install-linux.sh install
```

安装器会原子维护：

```text
~/.local/bin/agentd
~/.config/systemd/user/mimi-remote.service
~/.local/share/mimi-remote/install-linux.sh
~/.config/mimi-remote/
```

不设置非默认 `AGENTD_CONFIG`，不在自定义 `XDG_CONFIG_HOME` 下套用固定模板。使用绝对路径验收：

```bash
"$HOME/.local/bin/agentd" status --json | grep -E '"(process_ok|service_ok|doctor_ok)"'
"$HOME/.local/bin/agentd" doctor
```

## 构建 iOS/iPadOS App

仅在 macOS、Xcode 26 或更高版本、iOS 26 SDK 和 XcodeGen 可用时继续。确认当前目录是完整且干净的源码仓库；否则克隆到用户确认的新目录，并优先检出与后端匹配的正式 tag。

```bash
xcodegen generate \
  --spec ios/MimiRemote/project.yml \
  --project ios/MimiRemote

bash ./scripts/ios-dev.sh build-for-testing

open ios/MimiRemote/MimiRemote.xcodeproj
```

测试构建始终使用统一脚本固定的 M5 Simulator。需要人工安装到真机时，让用户在 Xcode 中选择自己的 Development Team、已信任真机和 `MimiRemote` scheme；不要替用户选择未知 Team，不导出或上传签名证书，不关闭代码签名。日常命令行部署必须使用 `bash ./scripts/ios-dev.sh run`。

## 完成配对与验收

Mac App 安装从菜单栏选择“配对设备…”。CLI/Linux 安装让用户在不会进入 Agent 日志的本机 Terminal 执行：

```bash
agentd pair --qr-only
```

Linux 使用 `"$HOME/.local/bin/agentd" pair --qr-only`。

短期 Pair 链接是单次兑换票据，不直接包含长期 Token。失败、过期或已使用时重新生成；扫码不可用时才使用高级手动连接，不让用户把 Token 粘贴到模型对话中。

至少验证：

1. iOS App 能显示当前 Mac 和 `agentd` 版本。
2. App 能加载已授权项目列表。
3. App 能打开已有 Codex 会话或创建最小测试会话。
4. 用户启用 Claude 时，Runtime 选择器能显示 Claude，并能创建最小只读测试会话。
5. 断网后不重复提交写操作；恢复连接后会话能通过事件 replay 或权威历史恢复。

前三项完成后才判定基础安装成功；Claude 验收失败不能推翻已通过的 Codex 主通道。

## 配置 Codex 与 Claude Runtime

Codex 是默认 Runtime。不要写死模型版本；未显式选择模型时交给本机 Codex rollout。保持现有 Codex 登录态、app-server Token 和审批策略。

Claude Code 属于实验通道。Mimi Remote Mac 启动时会在本机检测随包 bridge、Claude CLI 和登录态：三项都通过且用户没有明确关闭时自动启用，否则保持关闭；设置页中的明确开关会覆盖后续自动检测。Homebrew / Linux 不执行这项 App 启动策略。它使用一个由 `agentd` 监督的 resident bridge；每个 Claude thread 对应一个 headless 进程。移动端断线不会自动重试 `turn/start`，重连使用 sequence replay 或 `thread/read`，避免重复写文件或执行命令。

启用 Claude 前确认用户接受以下边界：

- 当前不支持 `goal`、`archive` 和 `fork`。
- 不提供 APNs 后台 push 或跨设备云同步。
- bridge、Mac 或 Claude Code 重启后的极短未落盘窗口仍可能无法恢复。
- 保持 `CLAUDE_BRIDGE_BYPASS_PERMISSIONS=false`，Claude 只声明 `read-only` 和 `workspace-write`。

按安装形态处理 bridge：

- **Mimi Remote Mac**：使用 App 内置 bridge，不执行 `cargo install`，不写入其他机器的 bridge 绝对路径。App 通过 `agentd runtime --claude=auto|enabled|disabled` 原子更新 `claude.enabled`、`claude.activation` 和检测到的本机 Claude CLI 路径，保留其他字段与 `0600` 权限；不要打印完整配置文件。
- **Homebrew / Linux**：安装 `alleycat-claude-bridge >= 0.2.1`，把实际绝对路径写入 `claude.bridge_bin`。

CLI 外置 bridge 安装命令：

```bash
cargo install --git https://github.com/gaixianggeng/mimi-remote.git \
  --locked --force --bin alleycat-claude-bridge alleycat-claude-bridge
command -v alleycat-claude-bridge
```

配置文件含长期 Token。修改前创建权限为用户私有的本地备份，使用 JSON 解析器原子修改，只更新 `claude` 字段，保持文件权限为 `0600`；不要用 `cat`、日志或聊天展示完整内容。Mac App 优先使用设置页开关；用户明确关闭后，不得在后续启动中重新自动启用。

修改后从当前 service owner 的入口重启：

- Mac App owner：从菜单栏选择“重新启动服务”。
- Homebrew owner：执行 `agentd restart --no-pair`。
- Linux owner：使用 user-systemd 安装器或 `systemctl --user restart mimi-remote.service`。

然后执行 Doctor，并在移动端确认 Claude channel、bridge 版本和模型列表可用。不要因为 Claude bridge 失败而修改 Codex 配置或轮换 Token。

## 诊断失败

先从当前 service owner 收集最小、去敏的诊断，不要一开始就重装：

- Mac App：查看菜单栏状态、Dashboard、Doctor 和 App 管理的日志。
- Homebrew：

```bash
agentd status --json | grep -E '"(process_ok|service_ok|doctor_ok)"'
agentd doctor
agentd logs -n 200
brew services list
```

- Linux：

```bash
"$HOME/.local/bin/agentd" status --json | grep -E '"(process_ok|service_ok|doctor_ok)"'
"$HOME/.local/bin/agentd" doctor
journalctl --user -u mimi-remote.service -n 200 --no-pager
```

重点区分：

- `process_ok=false`：服务未运行、端口不可达或 service manager 失败。
- `process_ok=true` 且 `service_ok=false`：配置、鉴权、版本或真实 Codex app-server 握手失败。
- `file-access-preflight` warning：服务可能已连接，但部分 macOS 目录权限尚未确认。
- Claude channel 不可用：单独检查 `claude.enabled`、Claude CLI 登录和 bridge probe，不破坏 Codex。
- 移动端无法连接而本机就绪：检查私网、Endpoint 和 App 内凭据，不开放公网端口。

只在 Doctor 明确给出安全可修复项时运行 `doctor --fix`。先对日志去敏，再引用到聊天或 Issue。

## 升级与回滚

升级前备份配置和 Token，备份目录保持用户私有，不上传到云盘、Issue、PR 或任务附件。

### Mimi Remote Mac

1. 下载目标正式 DMG 和 SHA-256 文件并校验。
2. 不先删除旧 App；用新 App 覆盖“应用程序”中的现有版本。
3. 打开新版本，让它复用 Application Support 中的配置和配对数据。
4. 验证 service owner、版本、Doctor、Codex 和已启用的 Claude channel。
5. 失败时安装上一个已签名、公证的 DMG，优先恢复旧二进制；除非确认配置 schema 不兼容，否则不回滚配置。

首个 DMG 没有自动更新。不要把 snapshot 或未公证构建作为稳定回滚版本。

### Homebrew

执行 `brew upgrade mimi-remote` 后使用 `agentd restart --no-pair`，验证 `service_ok=true`。失败时优先恢复旧 keg，不默认回滚配置。

### Linux

在校验后的新 Release 根目录执行 `bash ./scripts/install-linux.sh upgrade`。需要主动回滚时执行：

```bash
bash "$HOME/.local/share/mimi-remote/install-linux.sh" rollback
"$HOME/.local/bin/agentd" status --json | grep -E '"(process_ok|service_ok|doctor_ok)"'
```

## 卸载

默认只卸载程序并保留配置和 Token。永久删除凭据是独立破坏性操作，只有用户明确确认“接受现有配对永久失效”后才能执行。

- **Mimi Remote Mac**：先在菜单栏选择“退出并停止服务”。如果要回到 Homebrew，先在设置中执行“恢复 Homebrew”。确认服务停止或迁移完成后，再把 App 移到废纸篓。
- **Homebrew**：执行 `agentd stop` 和 `brew uninstall mimi-remote`。
- **Linux**：执行 `bash "$HOME/.local/share/mimi-remote/install-linux.sh" uninstall`。

不要自动删除：

```text
~/Library/Application Support/mimi-remote
~/.config/mimi-remote
```

不要因为卸载后端而删除 iOS Keychain 数据、Xcode 工程、源码仓库或用户项目。

## 报告结果

最终只报告：

- 主机平台、架构、安装版本和 service owner。
- 执行的是新装、复用、迁移、升级、修复还是回滚。
- `service_ok`、Doctor 和仍需用户处理的 warning。
- Codex 是否可用；Claude 是否启用、bridge 是否健康及其剩余实验边界。
- iOS 工程、无签名构建、真机安装、配对和项目加载状态。
- 仍需用户完成的登录、系统权限、Xcode Team、App 拖放或扫码步骤。

不要报告 Token、二维码内容、完整 Endpoint、Tailscale IP、私有项目路径或未去敏日志。

## 按需读取的参考资料

- 产品概览和快速开始：[README.zh-CN.md](https://github.com/gaixianggeng/mimi-remote/blob/main/README.zh-CN.md)
- Mac 菜单栏 App：[Mimi Remote Mac](https://github.com/gaixianggeng/mimi-remote/blob/main/macos/MimiRemoteMac/README.md)
- 安装、升级、停止和回滚：[install-upgrade-rollback.md](https://github.com/gaixianggeng/mimi-remote/blob/main/docs/install-upgrade-rollback.md)
- Claude Runtime 生命周期和权限：[claude-bridge-architecture.md](https://github.com/gaixianggeng/mimi-remote/blob/main/docs/claude-bridge-architecture.md)
- iOS 构建和验收：[iOS 开发说明](https://github.com/gaixianggeng/mimi-remote/blob/main/ios/MimiRemote/README.md)
- Codex 协议边界：[codex-protocol-support.md](https://github.com/gaixianggeng/mimi-remote/blob/main/docs/codex-protocol-support.md)
- Tailscale 运维：[tailscale-peer-relay-ops.md](https://github.com/gaixianggeng/mimi-remote/blob/main/docs/tailscale-peer-relay-ops.md)
- 支持和去敏：[support.md](https://github.com/gaixianggeng/mimi-remote/blob/main/docs/support.md)
- 安全问题报告：[SECURITY.md](https://github.com/gaixianggeng/mimi-remote/blob/main/SECURITY.md)
