---
name: install-mimi-remote
description: 安装、配置、配对、升级、诊断、回滚或卸载 Mimi Remote，包括在 macOS 或 Linux 上部署 agentd、通过 Tailscale 建立私网连接、从源码构建 iPhone/iPad App，以及按需启用 Claude Code 实验通道。用户提出“安装 Mimi Remote”“在 iPad/iPhone 上使用 Codex”“部署或修复 agentd”“升级、回滚、卸载 Mimi Remote”“构建 MimiRemote iOS App”或处理相关连接故障时使用。
---

# 安装与维护 Mimi Remote

## 目标

把 Mimi Remote 安装成一个可验证、可恢复、权限最小化的本地闭环：

1. 在用户自己的 Mac 或 Linux 开发机上运行 `agentd`。
2. 通过 Tailscale 私网连接 iPhone 或 iPad，不部署公网中继。
3. 在需要时从源码构建并安装原生 iOS/iPadOS App。
4. 保留用户现有配置、Token、Codex 凭证和项目改动。

Mimi Remote 是第三方开源客户端，不是 OpenAI、Anthropic 或 Tailscale 的官方产品。Codex、项目代码和完整会话继续留在用户自己的设备上。

## 执行原则

- 先执行只读检查，再执行安装或修改；复用已有安装，不重复初始化。
- 优先安装正式 Release。不要把开发分支、未固定 commit 或 `devel` 二进制当作稳定版本安装。
- 本 Skill 发布包只包含操作指引，不包含应用源码或二进制。需要源码时从 `https://github.com/gaixianggeng/codex-ipad-agent.git` 获取，需要后端 Release 时从 `https://github.com/gaixianggeng/mimi-remote/releases` 获取。
- 只有同时存在 `ios/MimiRemote/project.yml` 且 Git remote 指向上述源码仓库时，才把现有目录视为完整源码仓库；不要假设本文件所在目录或调用时的当前目录就是仓库根目录。
- 不要覆盖有未提交改动的源码目录。需要独立安装副本时，克隆到用户确认的目录。
- 不要使用 `agentd setup --force`，除非用户明确要求轮换凭据并接受现有配对失效。
- 不要输出、转述、上传或写入任务总结中的长期 Token、Authorization header、connect link、Tailscale IP、二维码内容或私有项目路径。
- 不要把 `agentd` 暴露到公网，不要自动配置端口转发、反向代理或公网 Tunnel。
- 不要通过关闭审批、设置 `danger-full-access` 或启用 `CLAUDE_BRIDGE_BYPASS_PERMISSIONS` 解决文件权限问题。
- 不要运行 `tccutil reset`。macOS 文件权限需要用户在系统设置中确认。
- Linux 安装和服务操作使用普通登录用户。不要使用 `sudo` 运行安装脚本。
- 只有用户明确要求 Claude Code 时才安装 bridge；Codex 是默认稳定主通道。
- 涉及升级、回滚或卸载时，先阅读 [安装、升级与回滚](https://github.com/gaixianggeng/codex-ipad-agent/blob/main/docs/install-upgrade-rollback.md)。
- 涉及 iOS 构建、签名或真机部署时，先阅读 [iOS 开发说明](https://github.com/gaixianggeng/codex-ipad-agent/blob/main/ios/MimiRemote/README.md)。

## 确定安装范围

先根据主机和用户目标选择最小闭环：

- macOS 完整安装：安装 `agentd`，准备 iOS 工程，完成真机签名后配对。这是默认用户路径。
- macOS 后端安装：只安装 `agentd`，适合 App 已经装好或只修复 Mac 服务。
- Linux 后端安装：只安装 `agentd`；iOS App 仍需要在一台 Mac 上构建。
- 源码开发：只在用户明确要开发或修改项目时使用源码构建，不替代稳定安装。
- 维护操作：已有安装时按升级、诊断、回滚或卸载流程处理，不重新生成 Token。

只询问会改变结果的必要信息：

1. 要授权给 Mimi Remote 的最小项目根目录。
2. 是否同时构建 iPhone/iPad App。
3. 是否有可用的 Apple Development Team 和已信任的真机。
4. 用户要求固定版本时使用哪个 tag；未指定时选择当前最新正式 Release，并在修改前告知版本。

## 执行预检

先执行以下不修改系统的检查：

```bash
uname -s
uname -m
id -u
command -v git
command -v codex
codex --version
codex app-server --help
```

确认 Codex CLI 已登录。不要读取、复制或展示 Codex 凭证。若 Codex CLI 缺失，使用 OpenAI 当前官方安装说明完成安装和登录，不要凭记忆拼接过时命令。

确认开发机和移动设备属于同一个 Tailscale 网络。`tailscale` CLI 不在 `PATH` 时，不要直接判定 Tailscale 未安装；允许用户通过 Tailscale App 确认在线状态。发现未安装或未登录时，先完成官方客户端安装和交互式登录。

在 macOS 上继续检查：

```bash
command -v brew
xcodebuild -version
xcode-select -p
xcrun --sdk iphoneos --show-sdk-version
command -v xcodegen
```

只有构建 iOS App 时才要求 Xcode 26 或更高版本、iOS 26 SDK 和 XcodeGen。缺少 Homebrew、Xcode 或 Apple 登录时，让用户通过官方安装界面完成必要步骤；不要绕过系统许可或签名。

在 Linux 上继续检查：

```bash
command -v curl
command -v tar
command -v sha256sum
command -v systemctl
systemctl --user show-environment
```

要求 Linux 使用 systemd user service，架构为 `amd64` 或 `arm64`，且当前用户不是 root。若用户需要退出 SSH 后继续运行服务，把 user lingering 作为可选管理员操作单独说明，不要默认执行 `sudo loginctl enable-linger`。

## 安装 macOS 后端

确认 Homebrew 和 Codex CLI 可用后，安装正式版本：

```bash
brew update
brew install gaixianggeng/tap/mimi-remote
agentd version
```

若 Formula 已安装：

- 普通安装或修复任务不要无条件升级。
- 用户明确要求升级时，先备份配置，再执行 `brew upgrade mimi-remote`。
- 检测到服务已经就绪时，跳过首次初始化。

首次初始化通过 Agent 或自动化执行时必须启用安全模式。把授权范围替换为用户确认的最小目录：

```bash
agentd up --no-pair \
  --scan-root "/absolute/path/to/projects" \
  --browse-root "/absolute/path/to/projects"
```

`--no-pair` 保留完整的初始化、启动和就绪检查，但不输出二维码、Endpoint 或长期访问码。需要结构化结果时使用 `agentd up --no-pair --json`；安全 JSON 只包含版本、`service_ok` 和可选 warning，不包含完整 setup `result`。不要通过 Agent 工具执行不带 `--no-pair` 的首次启动。

初始化完成后执行去敏验收。通过会保留输出的 Agent 工具执行时，只保留非敏感状态字段：

```bash
agentd status --json | grep -E '"(process_ok|service_ok|doctor_ok)"'
agentd doctor
```

只在 `status --json` 中的 `service_ok` 为 `true` 时判定后端安装成功。`process_ok=true` 只表示 HTTP 进程存活，不代表 Codex app-server 已经可用。

若需要自动化重启，使用：

```bash
agentd restart --no-pair
agentd status --json | grep -E '"(process_ok|service_ok|doctor_ok)"'
```

不要从 `agentd` 托管的远程任务中执行 `brew services restart mimi-remote`；使用 `agentd restart --no-pair`，让 launchd 原子重启服务。

## 安装 Linux 后端

使用后端发布仓库 `gaixianggeng/mimi-remote` 的正式 Release，不要直接从源码仓库的工作区安装 `devel` 二进制。

用户指定版本时使用该 tag。用户要求最新版时，先查询当前 latest Release，展示将安装的 tag，并确认它不是 prerelease。根据架构选择归档：

```text
mimi-remote_VERSION_linux_amd64.tar.gz
mimi-remote_VERSION_linux_arm64.tar.gz
```

在新建的临时目录中下载目标归档和同一 Release 的 `checksums.txt`，严格校验 SHA-256 后再解压。使用 [安装、升级与回滚](https://github.com/gaixianggeng/codex-ipad-agent/blob/main/docs/install-upgrade-rollback.md) 中的完整下载命令，不要跳过校验。

在解压后的 Release 根目录执行：

```bash
bash ./scripts/install-linux.sh install
```

脚本会原子安装以下内容并保留已有配置和 Token：

```text
~/.local/bin/agentd
~/.config/systemd/user/mimi-remote.service
~/.local/share/mimi-remote/install-linux.sh
~/.config/mimi-remote/
```

不要设置非默认 `AGENTD_CONFIG`，也不要在 `XDG_CONFIG_HOME` 指向其他目录时继续使用固定模板。安装器不会修改 shell rc；当前 shell 找不到命令时使用绝对路径：

```bash
"$HOME/.local/bin/agentd" status --json | grep -E '"(process_ok|service_ok|doctor_ok)"'
"$HOME/.local/bin/agentd" doctor
```

同样只以 `service_ok=true` 作为安装成功条件。安装失败时保留安装器输出的去敏诊断；脚本会尝试恢复安装前的二进制、unit 和服务状态。

## 构建并安装 iOS/iPadOS App

仅在 macOS、Xcode 26 或更高版本、iOS 26 SDK 和 XcodeGen 可用时继续。当前没有公开 App Store 版本，必须从完整源码仓库构建。

先检查当前目录是否为完整且干净的源码仓库。若只有本 Skill、仓库来源不符或缺少 iOS 工程：

1. 从 `https://github.com/gaixianggeng/codex-ipad-agent.git` 克隆到用户确认的目录。
2. 优先检出与后端版本匹配的正式 tag。
3. 没有可用 tag 时，说明只能基于默认分支构建，并在用户接受后继续。
4. 不要在有未提交改动的现有工作树中切换 tag 或执行清理。

安装 XcodeGen 并生成工程：

```bash
brew install xcodegen
xcodegen generate \
  --spec ios/MimiRemote/project.yml \
  --project ios/MimiRemote
```

先执行不需要签名的编译验收：

```bash
xcodebuild \
  -project ios/MimiRemote/MimiRemote.xcodeproj \
  -scheme MimiRemote \
  -configuration Debug \
  -sdk iphoneos \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing
```

编译通过后打开工程：

```bash
open ios/MimiRemote/MimiRemote.xcodeproj
```

让用户在 Xcode 中完成必须的人机交互：

1. 选择 `MimiRemote` scheme。
2. 选择自己的 Development Team。
3. 连接、解锁并信任目标 iPhone 或 iPad。
4. 选择真机并运行。

不要替用户选择未知 Team，不要导出或上传签名证书，不要关闭代码签名。默认复用现有模拟器；不要为安装任务持续创建新模拟器。产品验收优先使用真机。

## 完成配对

先确认后端 `service_ok=true`，再配对移动端。需要刷新二维码时，让用户在开发机的本机 Terminal 执行：

```bash
agentd pair --qr-only
```

Linux 使用：

```bash
"$HOME/.local/bin/agentd" pair --qr-only
```

让用户在 Mimi Remote 首次启动页扫描二维码。短期 Pair 链接是单次兑换票据，不直接包含长期 Token；失败、过期或已使用时重新生成。扫码不可用时才使用 App 的高级手动连接，并且不要让用户把 Token 粘贴到模型对话中。

配对成功后至少验证：

1. App 能显示当前 Mac 和 `agentd` 版本。
2. App 能加载已授权项目列表。
3. App 能打开一个已有 Codex 会话或创建一个最小测试会话。
4. Tailscale 断开时不可访问，恢复后能够重新连接。

完成前三项后，才把“完整安装与配对”标记为成功。

## 诊断失败

按以下顺序收集最小诊断，不要一开始就重装：

```bash
agentd status --json | grep -E '"(process_ok|service_ok|doctor_ok)"'
agentd doctor
agentd logs -n 200
codex --version
codex app-server --help
```

Linux 使用 `~/.local/bin/agentd` 的绝对路径。必要时再执行底层检查：

```bash
# macOS
brew services list

# Linux
systemctl --user status mimi-remote.service
journalctl --user -u mimi-remote.service -n 200 --no-pager
```

先对输出去敏，再引用到对话或 Issue。重点区分：

- `process_ok=false`：服务未运行、端口不可达或服务管理器失败。
- `process_ok=true` 且 `service_ok=false`：配置、鉴权、版本或真实 Codex app-server 握手失败。
- `file-access-preflight` warning：服务可能已经可连接，但部分 macOS 目录权限尚未确认。
- 移动端无法连接而本机就绪：检查两台设备的 Tailscale 登录、Endpoint 和 App 内凭据，不要开放公网端口绕过问题。

只在 Doctor 明确给出安全可修复项时执行：

```bash
agentd doctor --fix
agentd restart --no-pair
agentd status --json | grep -E '"(process_ok|service_ok|doctor_ok)"'
```

## 升级与回滚

升级前保存用户配置和 Token，但不要把备份上传到云盘、Issue、PR 或任务附件。

macOS 升级：

1. 按 [安装、升级与回滚](https://github.com/gaixianggeng/codex-ipad-agent/blob/main/docs/install-upgrade-rollback.md) 创建权限为用户私有的配置备份。
2. 执行 `brew update` 和 `brew upgrade mimi-remote`。
3. 执行 `agentd restart --no-pair`。
4. 验证 `agentd status --json` 中 `service_ok=true`。
5. 失败时优先恢复旧 keg，除非确认新版破坏了配置，否则不要回滚配置文件。

Linux 升级：

1. 下载并校验目标正式 Release。
2. 在新 Release 解压目录执行 `bash ./scripts/install-linux.sh upgrade`。
3. 让安装器完成健康检查和失败自动恢复。
4. 需要主动回滚时执行：

```bash
bash "$HOME/.local/share/mimi-remote/install-linux.sh" rollback
"$HOME/.local/bin/agentd" status --json | grep -E '"(process_ok|service_ok|doctor_ok)"'
```

iOS 升级只在干净源码副本中检出目标 tag，重新生成 Xcode 工程并构建。不要覆盖用户的开发改动。

## 卸载

默认卸载程序但保留配置和 Token，以便重新安装后继续配对。永久删除凭据是独立的破坏性操作，只有用户明确确认“接受现有配对永久失效”后才能执行。

macOS：

```bash
agentd stop
brew uninstall mimi-remote
```

Linux：

```bash
bash "$HOME/.local/share/mimi-remote/install-linux.sh" uninstall
```

不要自动删除以下目录：

```text
~/Library/Application Support/mimi-remote
~/.config/mimi-remote
```

iOS App 的卸载、App 数据删除和源码目录删除分别处理；不要因为卸载后端就删除 Xcode 工程、源码仓库或移动端 Keychain 数据。

## 可选启用 Claude Code

仅在用户明确要求后阅读 [Claude bridge 架构](https://github.com/gaixianggeng/codex-ipad-agent/blob/main/docs/claude-bridge-architecture.md)，确认用户理解该通道仍是实验功能。要求 Rust/Cargo、Claude Code headless 环境和 `alleycat-claude-bridge >= 0.2.1`。

从完整源码仓库安装 bridge：

```bash
cargo install --git https://github.com/gaixianggeng/codex-ipad-agent.git \
  --locked --force --bin alleycat-claude-bridge alleycat-claude-bridge
command -v alleycat-claude-bridge
```

把实际绝对路径写入配置的 `claude.bridge_bin`，设置 `claude.enabled=true`，保留 `CLAUDE_BRIDGE_BYPASS_PERMISSIONS=false`，然后执行：

```bash
agentd restart --no-pair
agentd doctor
agentd status --json | grep -E '"(process_ok|service_ok|doctor_ok)"'
```

不要因为 Claude bridge 失败而改变 Codex 主通道或轮换现有 Token。

## 报告结果

最终只报告以下信息：

- 主机平台、架构和安装版本。
- 后端是新装、复用、升级、修复还是回滚。
- `service_ok` 是否为 `true`，Doctor 是否仍有需要用户处理的 warning。
- iOS 工程是否生成、无签名构建是否通过、真机安装是否完成。
- 配对与项目加载是否完成。
- 仍需用户执行的人机步骤，例如登录、系统权限、Xcode Team 或扫码。

不要在最终报告中包含 Token、二维码内容、完整 Endpoint、Tailscale IP、私有项目绝对路径或未去敏日志。

## 按需读取的参考资料

- 产品概览和快速开始：[README.zh-CN.md](https://github.com/gaixianggeng/codex-ipad-agent/blob/main/README.zh-CN.md)
- 安装、升级、停止、回滚和 Linux 细节：[install-upgrade-rollback.md](https://github.com/gaixianggeng/codex-ipad-agent/blob/main/docs/install-upgrade-rollback.md)
- iOS 构建、真机部署和验收：[iOS 开发说明](https://github.com/gaixianggeng/codex-ipad-agent/blob/main/ios/MimiRemote/README.md)
- Codex app-server 协议边界：[codex-protocol-support.md](https://github.com/gaixianggeng/codex-ipad-agent/blob/main/docs/codex-protocol-support.md)
- Tailscale 运维：[tailscale-peer-relay-ops.md](https://github.com/gaixianggeng/codex-ipad-agent/blob/main/docs/tailscale-peer-relay-ops.md)
- 支持与去敏要求：[support.md](https://github.com/gaixianggeng/codex-ipad-agent/blob/main/docs/support.md)
- 安全问题报告：[SECURITY.md](https://github.com/gaixianggeng/codex-ipad-agent/blob/main/SECURITY.md)
