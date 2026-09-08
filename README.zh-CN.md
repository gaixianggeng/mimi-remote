<p align="center">
  <img src="ios/MimiRemote/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-ios-marketing-1024x1024@1x.png" alt="Mimi Remote App 图标" width="112" />
</p>

<h1 align="center">Mimi Remote</h1>

<p align="center">
  <strong>电脑上的 Agent 会话，接着在 iPhone 和 iPad 上用。</strong>
</p>

<p align="center">
  面向 Codex 与 Claude Code 的开源原生移动工作台。<br />
  直连你的电脑，让会话在设备间无缝接力，实时跟进任务、继续对话和处理审批。
</p>

<p align="center">
  <a href="README.md">English README</a>
  &nbsp;·&nbsp;
  <a href="#快速开始">快速开始</a>
  &nbsp;·&nbsp;
  <a href="#架构">工作原理</a>
  &nbsp;·&nbsp;
  <a href="#常见问题faq">常见问题</a>
</p>

<p align="center">
  <a href="ios/MimiRemote/README.md"><img src="https://img.shields.io/badge/iOS%20%2F%20iPadOS-18%2B-black?logo=apple" alt="要求 iOS 或 iPadOS 18 及以上版本" /></a>
  <a href="ios/MimiRemote"><img src="https://img.shields.io/badge/SwiftUI-native-F05138?logo=swift&amp;logoColor=white" alt="原生 SwiftUI App" /></a>
  <a href="https://github.com/gaixianggeng/mimi-remote/actions/workflows/go-ci.yml"><img src="https://github.com/gaixianggeng/mimi-remote/actions/workflows/go-ci.yml/badge.svg" alt="Go CI 状态" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPLv3%20%2B%20Store%20Exception-blue.svg" alt="GPLv3 与商店分发例外" /></a>
</p>

<p align="center">
  <img src="web/assets/promo-iphone-current.jpg" alt="Mimi Remote 四张 iPhone 推广图：会话接力、多设备控制、Codex 与 Claude Code 无缝接力、优雅设计" width="100%" />
</p>

<p align="center">
  <sub>在移动端继续电脑会话、控制多台设备，并无缝接力 Codex 与 Claude Code。</sub>
</p>

Mimi Remote 通过 Tailscale 或同一局域网直连用户自己的 macOS、Windows 或 Linux 电脑。项目不运营中转服务、云账号或会话托管服务，电脑始终是控制平面；用户主动发送给 Codex、Claude Code、GitHub、语音转写或 MCP 的数据，仍会按对应第三方服务的处理方式与条款处理。

Mimi Remote 是独立开发的第三方项目，不隶属于 OpenAI、Anthropic 或 Tailscale，也不代表这些公司的官方产品。Codex 是主要支持的 Runtime；可选的 Claude Code bridge 仍处于实验阶段。

> Mimi Remote 已在部分地区的 [App Store](https://apps.apple.com/us/app/mimi-remote/id6778076511) 上架。[TestFlight](https://testflight.apple.com/join/jhGPbSk6) 继续提供 Beta 构建，开发者也可以从源码构建。

<p align="center">
  <img src="web/assets/iphone-sessions-light.png" alt="Mimi Remote 在 iPhone 浅色模式下的会话列表" width="24%" />
  &nbsp;&nbsp;&nbsp;
  <img src="web/assets/ipad-sessions-light.png" alt="Mimi Remote 在 iPad 上同时展示侧栏与会话列表" width="70%" />
</p>

<p align="center">
  <sub><strong>iPhone · 完整能力，紧凑布局</strong> — 在单列界面中继续会话、跟进进度、处理审批和控制任务。<br />
  <strong>iPad · 完整能力，展开布局</strong> — 同样的会话与控制在多栏工作台中展开，保留更多上下文。</sub>
</p>

两端共用完整的会话、审批与任务控制能力，区别只在布局、信息密度和输入方式。原生 SwiftUI 界面分别打磨了紧凑导航、宽屏分栏、触控反馈与过渡动画；开启 Reduce Motion 后，动态效果会降级为克制的淡化或静态反馈。这些图片直接复用 [`web/assets`](web/assets) 中的当前官网截图，全部来自 Debug 专用种子界面，其中的主机、项目、会话、路径和用量均为演示数据，不使用维护者的真实工作区或凭据。截图展示简体中文界面，App 同时支持英文。

## 从电脑到移动端，会话继续

真正高频的需求通常不是“在手机上开一个终端”，而是离开电脑后仍能接着同一段 Agent 会话，不必重新解释上下文。

- **接着做：**在电脑、iPhone 与 iPad 之间继续已有会话，离开工位也不用重新开始。
- **实时跟进：**查看任务正在思考、等待、失败还是已经完成，并持续读取结构化回复和执行过程。
- **随时控制：**追加上下文、排队下一条指令、切换模型或推理强度、回答问题、批准操作或中断当前 Turn。

需要完成更深入的开发收尾时，进阶工具还支持检查 Diff、管理 Worktree、按文件或 Hunk 暂存、Commit、Push 和创建 Draft PR；这些能力不是使用 Mimi Remote 的前提。

## 它不是口袋里的终端

- Codex 与 Claude Code 的消息、推理、命令、Tool 调用、审批和执行过程会组成结构化时间线，不是一整屏终端日志。
- 新建 Codex 会话由宿主电脑异步生成简短标题；生成失败不会阻塞对话，可通过 `app_server.auto_title` 关闭。
- 模型、推理强度、Skill、速度、权限模式和待发送队列都留在 Composer 附近。
- Markdown、图片、文件引用、语音输入和安全的 Quick Look 读取都按移动端内容呈现。
- iPhone 与 iPad 的间距、层级、触控反馈和转场动画分别调校；Reduce Motion 下仍保留清晰的静态状态反馈。
- 多个宿主 Profile 使用独立 Keychain Token；同一时间只保持一个活动连接，心智模型更简单。
- 就绪检查、断线恢复、Doctor 和有上限的日志导出，让多数故障不必回到电脑前处理。

当前不做云端账号、代码托管、公网中继、任意远程 Shell、后台无人值守删除或多用户共享。完整边界见 [项目现状](docs/project-status.md)。

## 设计围绕上下文，不围绕屏幕尺寸

Mimi Remote 在不同设备上沿用同一套项目与会话模型，但界面会顺着设备的真实使用方式变化：iPhone 用紧凑层级保持单手操作，iPad 展开为保留上下文的多栏工作台，宿主电脑则继续运行 Agent。设备改变的是呈现方式，不是可用能力。

<p align="center">
  <img src="web/assets/iphone-appearance-light.png" alt="Mimi Remote 在 iPhone 浅色模式下的外观与工作区图标设置" width="30%" />
  &nbsp;&nbsp;&nbsp;
  <img src="web/assets/iphone-me-dark.png" alt="Mimi Remote 在 iPhone 深色模式下的 Token 用量、已连接宿主与偏好设置" width="30%" />
</p>

<p align="center">
  <sub><strong>外观与个性化是一等能力</strong> — 深浅色、工作区图标套装与编辑器风格主题。<br />
  <strong>用量与宿主状态集中可见</strong> — Token 周期、已连接宿主、语言、模型和权限集中在「我的」。</sub>
</p>

<p align="center">
  <img src="artifacts/app-screenshots/mac-menu-bar-debug-2026-07-28.png" alt="同时展示服务、运行时与额度状态的 Mimi Remote Mac 菜单栏控制面" width="340" />
</p>

<p align="center">
  <sub>340pt 的 Mac 菜单栏窗口把宿主健康状态、Codex / Claude 运行时、额度环、配对、诊断和恢复动作放在一次点击内。</sub>
</p>

这套层级有几个明确原则：

- **保留上下文：**iPhone 用紧凑层级把当前任务放在手边；iPad 侧栏持续展示项目和会话，右侧内容按任务变化；两端切换布局但不削减会话能力。
- **渐进披露复杂度：**高频状态和动作靠近任务，首次设置、配对、诊断和深层偏好进入独立界面。
- **先看状态，再做动作：**连接健康度、Runtime 就绪状态、剩余额度和权限模式会先于可能改变或中断任务的控制项出现。
- **遵循各平台习惯：**iPhone 是紧凑触屏层级，iPad 是多栏工作台，Mac 是高密度菜单栏工具，而不是把一套布局拉伸到三块屏幕。

上面的移动端图片与当前 Mimi Remote 官网共用同一套素材，并且全部来自 Debug 专用种子界面。Mac 菜单图使用公开演示域名 `mimi-demo.local`；采集过程没有重启或替换已安装的 Mac 服务。这些公开截图均不包含真实 Token、私有地址、个人路径或线上项目内容。

## 架构

```mermaid
flowchart LR
    Mobile["iPhone / iPad<br/>Mimi Remote"]
    Gateway["你的电脑<br/>agentd 安全网关"]
    Codex["Codex<br/>共享 App Server"]
    Desktop["Codex Desktop<br/>本机或 SSH"]
    Claude["Claude Code<br/>实验 bridge"]

    Mobile <-->|"局域网或 Tailscale<br/>实时会话与审批"| Gateway
    Gateway <--> Codex
    Desktop <-->|"SSH app-server proxy"| Codex
    Gateway <--> Claude
```

这个仓库包含完整链路：iPhone / iPad 原生 App、支持 macOS、Windows 与 Linux 的 Go `agentd` 网关、Mac 菜单栏 App、Windows 托盘 App，以及 Claude Code 兼容 bridge。移动端只连接你自己的宿主电脑，项目文件、会话历史和 Runtime 凭证都留在这台电脑上。

- **直连、响应快：**通过私有网络上的 REST 与 WebSocket 实时传递输出、追问、任务控制和审批，不经过 Mimi 运营的应用层中转。
- **按平台选择 Codex transport：**Linux 与 Windows 由 `agentd` 托管只监听 loopback 的 Codex App Server；macOS 通过 SSH 接入共享 Unix App Server。两条链路都不依赖 Desktop 私有 IPC。
- **双 Runtime、统一体验：**Codex 是主 Runtime；可选的 Claude Code bridge 把会话与审批适配到同一套结构化移动界面。
- **边界小而明确：**`agentd` 在宿主电脑上完成认证、工作区授权和 Runtime 路由。宿主电脑需要保持唤醒并能从私有网络访问。

协议细节与准确能力边界见[项目现状](docs/project-status.md)和 [Claude bridge 架构](docs/claude-bridge-architecture.md)。

## 开始前检查

安装前先确认：

- **必需：**一台运行 iOS / iPadOS 18 或更高版本的 iPhone / iPad、一台可持续运行宿主服务的 macOS、Windows 或 Linux 电脑，以及已在这台电脑安装并可用的 Codex CLI。Runtime 自身的认证只需在宿主完成；Mimi Remote 只连接 `agentd` 网关，不接收或管理 Runtime 凭证与计费。认证方式见 [Codex 官方认证文档](https://learn.chatgpt.com/docs/auth)。iOS 26+ 保留完整的 Liquid Glass 与 Apple 设备端实时语音体验；iOS 18–25 使用更普通的系统材质，并回退到 Codex 录音转写。
- **网络：**设备位于同一可信局域网时可以直连，不要求安装 Tailscale；跨网络时使用同一 Tailnet，或使用用户自行管理的安全 HTTPS 入口。不要把 `agentd` 的明文 HTTP 端口直接暴露到公网。
- **可选 Runtime：**Claude Code 是默认关闭的实验通道，不能替代 Codex。启用时需按 [Claude Code 官方安装与认证文档](https://docs.anthropic.com/en/docs/claude-code/getting-started)单独安装和认证，Codex CLI 仍然必需。
- **当前 iOS 安装方式：**在已上架地区从 [App Store](https://apps.apple.com/us/app/mimi-remote/id6778076511) 安装公开版本；Beta 构建继续通过 [TestFlight](https://testflight.apple.com/join/jhGPbSk6) 提供。也可以使用 Mac、带 iOS 26 SDK 的 Xcode 26 或更高版本和 XcodeGen 从源码构建，详见 [iOS 构建说明](ios/MimiRemote/README.md)。
- **仅开发者需要：**普通用户通过平台安装包安装宿主时不需要 Go 或 Rust；只有从源码开发后端或 bridge 时才需要。各平台细节与当前安装包可用范围见 [完整安装、升级与回滚文档](docs/install-upgrade-rollback.md)。

## 快速开始

### 首次安装只需四步

1. **准备 Codex：**在宿主电脑安装 Codex CLI，完成 Runtime 自身认证并确认已经就绪；Mimi Remote 不配置 Provider 凭证或计费。
2. **安装并启动宿主：**按[各平台安装说明](docs/install-upgrade-rollback.md)完成首次设置，并确认服务已就绪。
3. **安装 iOS App：**在已上架地区从 [App Store](https://apps.apple.com/us/app/mimi-remote/id6778076511) 下载 Mimi Remote，或加入 [Mimi Remote TestFlight](https://testflight.apple.com/join/jhGPbSk6) 获取 Beta 构建；开发者也可以按 [iOS 构建说明](ios/MimiRemote/README.md)从源码运行。
4. **扫码配对：**打开宿主的配对入口（或运行 `agentd pair --qr-only`），在 Mimi Remote 中扫描短期二维码。

macOS 使用 Developer ID 签名并经过 Apple 公证的菜单栏宿主 App。App 内置 Go 后端和兼容 Claude bridge；Homebrew 保留给 macOS 命令行、服务器、自动化和故障恢复。

### Windows 宿主

Windows 可以运行 `agentd` 并托管 Mimi Remote 会话。Windows 版本使用当前用户的计划任务运行后台服务，并通过托盘 App 提供状态、配对和恢复入口。局域网访问需要显式开启，并且只允许 Private 网络和 `LocalSubnet`；跨网络时优先使用 Tailscale。

MIM-207 暂停的是 Windows 公开安装包发布，不是 Windows Runtime 支持。安装包是否可用以当前 [GitHub Release](https://github.com/gaixianggeng/mimi-remote/releases/latest) 为准。当前 Windows 分发边界见[各平台安装说明](docs/install-upgrade-rollback.md)。

### Linux 宿主

Linux 使用 Release 归档中的安装脚本和当前用户的 systemd 服务。以运行服务的同一用户安装并登录 Codex CLI 0.149.1 或更高版本，校验 Release 摘要、解压后运行 `bash ./scripts/install-linux.sh install`。

Linux 默认不要求 `sshd`、SSH 密钥，也不会修改 `authorized_keys`。`agentd` 会用私有 capability token 在 `ws://127.0.0.1:4222` 托管一个本机 Codex App Server，完成真实协议初始化后才报告就绪，并在服务停止时回收子进程。只有高级远端部署显式设置 `AGENTD_APP_SERVER_SSH_TARGET` 时才使用 SSH。

### Mac 安装

要求：

- macOS 15 或更高版本；
- 已安装并登录 Codex CLI；
- Mac 与 iPhone / iPad 位于同一私有网络；跨网络使用时建议加入同一个 Tailscale 网络。

普通用户从 [GitHub Releases](https://github.com/gaixianggeng/mimi-remote/releases/latest) 下载 `Mimi-Remote-Mac.dmg` 和对应 SHA-256 文件，校验后打开 DMG，把 **Mimi Remote Mac** 拖到“应用程序”，再从菜单栏完成首次设置。App 已内置 `agentd` 和兼容的 Claude bridge，不要求 Homebrew、Go、Rust 或 Xcode。

已有 Homebrew 服务时，让 Mac App 执行接管；迁移过程会先跑 Doctor，失败时尝试恢复旧服务，并保留现有配置、Token 和配对关系。

命令行、服务器或恢复场景才使用 Homebrew：

```bash
brew update
brew install gaixianggeng/tap/mimi-remote

codex --version
codex app-server --help
agentd up
```

首次启动前先启用“远程登录”，并确认 `ssh 127.0.0.1 true` 无需输入登录密码即可成功。`agentd` 通过非交互 SSH 检查 Codex 时会补齐 Homebrew、npm 与 mise 的常见安装路径；仍有运行时路径问题时由 `agentd doctor` 给出诊断。`agentd up` 会生成用户私有配置，通过 localhost SSH 接入共享 Unix App Server，完成真实协议初始化后再显示短期配对二维码。检测到 Tailscale 时优先使用 Tailscale；否则自动启用局域网，并把当前私有局域网地址写入配对信息。Desktop 接入与运行时边界见[共享 SSH App Server](docs/shared-ssh-app-server.md)。

Homebrew / CLI 常用命令：

```bash
agentd status
agentd pair
agentd doctor --fix
agentd logs -n 200
agentd up --no-pair
agentd restart
agentd restart --no-pair
agentd stop
```

`agentd restart` 在 macOS 上使用 launchd 原子重启，允许从当前服务托管的远程任务安全触发；不要在这类任务中直接运行 `brew services restart mimi-remote`。
Agent、自动化或远程日志场景使用 `agentd up --no-pair` / `agentd restart --no-pair`，避免把二维码、Endpoint 和长期访问码写入任务输出。`agentd up --no-pair --json` 只返回版本、就绪状态和安全警告，不包含完整 setup 结果；需要配对时再由用户在本机终端运行 `agentd pair --qr-only`。

macOS、Windows 与 Linux 的完整升级和恢复步骤见 [安装、升级与回滚](docs/install-upgrade-rollback.md)。

如果希望由 Codex 按同一套权限最小化、可恢复流程完成安装、升级和诊断，可以让 `$skill-installer` 安装下面的 GitHub Skill 路径：

```text
https://github.com/gaixianggeng/mimi-remote/tree/main/packaging/skill/install-mimi-remote
```

每个 GitHub Release 也会附带 `install-mimi-remote.zip` 和对应 SHA-256 文件，便于固定版本下载与审计。

### 安装 iOS App

当前源码支持 iOS / iPadOS 18 或更高版本；App Store 的地区可用性和最低系统要求以各地区当前商店页面为准。在已上架地区从 [App Store](https://apps.apple.com/us/app/mimi-remote/id6778076511) 安装公开版本，或加入 [Mimi Remote TestFlight](https://testflight.apple.com/join/jhGPbSk6) 获取 Beta 构建。iOS 26+ 提供完整高级视觉与设备端语音体验；较早的受支持系统会对不可用能力进行明确降级。

如需从源码构建，请使用安装了 Xcode 26 或更高版本和 XcodeGen 的 Mac：

```bash
xcodegen generate \
  --spec ios/MimiRemote/project.yml \
  --project ios/MimiRemote

open ios/MimiRemote/MimiRemote.xcodeproj
```

在 Xcode 中选择 `MimiRemote` scheme、开发者 Team 和目标 iPhone / iPad 后运行。工程支持 iOS / iPadOS 18 或更高版本；仍需使用带 iOS 26 SDK 的现代 Xcode 编译，以便同时保留新系统高级能力。

Mac App 用户从菜单栏选择“配对设备…”，CLI 用户扫描 `agentd up` 或 `agentd pair` 显示的二维码。二维码使用 10 分钟有效的签名票据，同一二维码或复制链接可在有效期内重复兑换，且不直接包含长期 Token；扫码不可用时可以展开高级手动连接。

## Claude Code 实验通道

Claude Runtime 默认关闭，当前要求 `alleycat-claude-bridge >= 0.2.1`。正式 Mac DMG 已内置兼容 bridge，并保留平台代码身份；不要为这种安装方式重复执行 `cargo install`。

只有 Homebrew、Linux 或独立开发环境需要从源码安装外置 bridge：

```bash
cargo install --git https://github.com/gaixianggeng/mimi-remote.git \
  --locked --force --bin alleycat-claude-bridge alleycat-claude-bridge

command -v alleycat-claude-bridge
```

在用户配置中显式启用：

```json
{
  "claude": {
    "enabled": true,
    "bridge_bin": "",
    "args": [],
    "max_concurrent_bridges": 3,
    "env": {
      "TERM": "xterm-256color"
    }
  }
}
```

空 `bridge_bin` 表示使用 Mimi Remote Mac 随包 bridge；Homebrew 和 Linux 必须改成 `command -v alleycat-claude-bridge` 返回的绝对路径。配置文件含长期 Token，修改前必须创建用户私有备份，只用 JSON 解析器修改 `claude` 字段，保持平台对应的用户私有权限，不要把完整文件打印到日志或聊天中。

然后验证：

```bash
go run ./scripts/ipad-ws-probe.go \
  -endpoint http://127.0.0.1:8787 \
  -token "$AGENTD_TOKEN" \
  -cwd "$PWD" \
  -runtime claude \
  -models-only
```

修改配置后必须从当前 service owner 重启：Mimi Remote Mac 使用菜单栏“重新启动服务”，Homebrew 使用 `agentd restart --no-pair`，Linux 使用 user-systemd。随后运行 Doctor，并在移动端确认 Runtime 选择器出现 Claude，且 Codex 主通道仍可用。上面的源码探针只用于开发仓库中的本机调试，不要把 Token 写进聊天或持久日志。

Claude 通道仍是实验能力：不支持 `goal`、`archive`、`fork`、APNs 后台推送和跨设备云同步。普通断线通过事件 replay 或 `thread/read` 恢复，不自动重试写操作；bridge/Mac 重启后的极短未落盘窗口仍可能无法恢复。

## 从源码开发

### Go 后端

要求 Go `1.25.0`：

```bash
go test ./...
go vet ./...

# 前台调试，不替换 Homebrew 服务
go build -trimpath -o bin/agentd ./cmd/agentd
./bin/agentd setup --scan-root "$HOME/code" --browse-root "$HOME"
./bin/agentd serve
```

已经通过 Homebrew 运行 `agentd` 时，不要把未签名的 `go build` 产物直接覆盖到 Cellar。macOS 会把 Go 的 ad-hoc 签名绑定到本次构建的 `cdhash`，下一次编译后可能重新请求“文件与文件夹”或“完全磁盘访问”授权。使用仓库内的完整开发重启入口：

```bash
# 本机终端：等待新服务通过 readyz
bash ./scripts/restart-agentd-dev-macos.sh

# 从 iPad/Codex 远程发起：先交给独立 launchd job，再让旧连接退出
bash ./scripts/restart-agentd-dev-macos.sh --no-wait

# 重连后查看结果；失败会自动恢复旧二进制
bash ./scripts/restart-agentd-dev-macos.sh --status
```

脚本使用本机 `Apple Development` 证书和固定 identifier 签名，原子替换 Homebrew 二进制，通过独立 launchd job 执行 kickstart、`readyz` 验证和失败回滚。新进程会在启动最前面异步预检项目、`scan_roots`、`browse_roots`；当 `browse_roots` 覆盖当前 Home 时，还会主动探测 Desktop、Documents、Downloads，尽早触发 macOS 的“文件与文件夹”提示。预检不会递归读取文件，也不会因等待人工点击而阻塞远程服务恢复；结果显示在 `agentd status --json` / Doctor 和服务日志中。

macOS 没有可由后台服务自动申请的“整个当前用户目录”单一授权：Desktop、Documents、Downloads 是分开的保护位置，其他 App 数据等还需要“完全磁盘访问”。第一次从旧 ad-hoc 版本切换到稳定签名时仍可能要求最后一次人工确认；真正需要无人值守访问整个 Home 时，请在“系统设置 → 隐私与安全性 → 完全磁盘访问”中一次性添加 `/opt/homebrew/opt/mimi-remote/bin/agentd`。同一证书和 identifier 下的后续本地构建可以复用授权。详细设计和排障见 [安装、升级与回滚](docs/install-upgrade-rollback.md)。

### iOS

```bash
xcodegen generate \
  --spec ios/MimiRemote/project.yml \
  --project ios/MimiRemote

bash ./scripts/ios-dev.sh build-for-testing
```

日常编译与部署统一通过 `bash ./scripts/ios-dev.sh build|run`：按 available、paired 且未占用的 USB 真机 → 当前本地网络可达的真机选择；只有完全没有可达真机时才回退固定 iPad Simulator。检测到真机但全部忙时明确失败，不静默切换设备类型。显式 `IOS_DEVICE_ID` / `IOS_DEVICE_NAME` 同时支持有线与无线真机，设备不可达时会明确失败；同一 UDID 切换连接方式时仍共用租约和 DerivedData。测试、视觉快照与 CI 精确固定 `iPad Pro 13-inch (M5)`，不会回退 iPad mini。XcodeBuildMCP 仓库默认值不保存设备目标，其 Simulator workflow 只用于这些固定 Simulator 场景。目标原因、连接方式和占用可通过 `bash ./scripts/ios-dev.sh target` 与 `bash ./scripts/ios-dev.sh leases` 查看。iOS 工程结构、运行命令、Catalyst 和真机验收见 [iOS 开发说明](ios/MimiRemote/README.md)。

### Claude bridge

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

bridge 只保留 Mimi Remote 需要的三个 crate；上游来源和 GPLv3-only 边界见 [Claude bridge 说明](bridges/claude/README.md)。

## 验证

先预览 committed、staged、unstaged 和未跟踪变更对应的验证计划；准备推送前只执行
一次 quick：

```bash
bash ./scripts/verify-change.sh --plan
bash ./scripts/verify-change.sh
```

纯文档和控制面改动不会启动语言构建；产品代码只验证直接受影响的栈，完整回归默认交给
PR Gate。跨模块、协议、发布或明确高风险改动再运行
`bash ./scripts/verify-change.sh --full`。相机、通知、Keychain、Tailscale/弱网、性能和
发布前验收才需要真机。分层规则和专项排障命令见[贡献指南](CONTRIBUTING.md)。

正式发布校验仍需独立于上述分层验证执行：

```bash
bash ./scripts/verify-release.sh
```

正式 macOS Release 必须通过 Developer ID 签名和 Apple notarization；发布链路另外包含签名凭据预检、Darwin 归档身份校验、打包、Linux 安装、Git 历史凭据扫描、Action SHA 固定和协议漂移门禁，详见 [P0 / P1 发布清单](docs/p0-p1-roadmap.md)。

## 仓库说明

- `gaixianggeng/mimi-remote` 是唯一的完整开源源码与新版本发布仓库，包括 iOS App、Mac App、Go `agentd`、Claude bridge、测试、文档和发布脚本。
- 原完整源码仓库与同名历史归档的一次性切换按[仓库改名 runbook](docs/operations/github-repository-rename-runbook.zh-CN.md)执行；历史 `v0.1.0`–`v0.2.2` 产物离线备份，不再维护第二个在线镜像。

源码目录保持语言和职责清晰，同时避免为目录整齐大规模改写稳定构建路径：

```text
ios/MimiRemote/          SwiftUI iPhone / iPad App
cmd/agentd/ + internal/  Go 安全网关与 Codex / Claude 控制面
bridges/claude/          Rust Claude Code 协议 bridge
```

新的 Mac、Go、Linux、Homebrew 和 Skill 产物统一由 `gaixianggeng/mimi-remote` Release 发布。

## 常见问题（FAQ）

### Can I use Codex on an iPad or iPhone? / 可以在 iPad 或 iPhone 上使用 Codex 吗？

可以。Codex CLI 和工作区仍运行在你的 macOS、Windows 或 Linux 宿主电脑上，Mimi Remote 通过 `agentd` 提供原生移动端界面。它是 Codex 的 iPhone / iPad 远程客户端，不是在 iOS 沙盒内直接运行完整 CLI。

### Is Mimi Remote self-hosted and local-first? / 这是自托管、本地优先的吗？

是。移动端通过 Tailscale 或同一局域网访问你自己的 `agentd`，项目维护者不运营中转服务。源代码、会话、日志以及 Codex / Claude 凭证留在你的设备上。

### Does it support Claude Code? / 支持 Claude Code 吗？

支持实验通道。`agentd` 可以调用仓库内的 [Claude bridge](bridges/claude)，把同一套移动端会话与审批界面连接到 Claude Code headless。该能力默认关闭，功能边界见 [Claude bridge 架构](docs/claude-bridge-architecture.md)。

### Is this an official OpenAI or Anthropic app? / 这是官方 App 吗？

不是。Mimi Remote 是采用 GNU GPLv3 并附 App Store / Google Play 分发例外的第三方开源项目，与 OpenAI、Anthropic 和 Tailscale 均无隶属或背书关系。

### How does the app differ before iOS / iPadOS 26? / iOS 26 之前有什么区别？

Mimi Remote 支持 iOS / iPadOS 18 及以上版本。iOS 26+ 继续使用 Liquid Glass、系统共享玻璃背景和 Apple 设备端实时语音；iOS 18–25 保留核心会话、工作区、附件与连接能力，但使用普通系统材质，并把不支持的 Apple 实时语音入口回退到 Codex 录音转写。兼容层只处理系统能力差异，不复制业务逻辑。

## 参与项目

- 遇到 Bug 或有功能建议，请创建 [GitHub Issue](https://github.com/gaixianggeng/mimi-remote/issues/new)。
- 提交代码前请阅读 [贡献指南](CONTRIBUTING.md)，并尽量附上可复现步骤或验证结果。
- 如果 Mimi Remote 确实解决了你的问题，可以给仓库一个 Star；它会帮助更多正在搜索 Codex iPad client、Codex remote 或 Claude Code iOS client 的开发者找到这个项目。

## 文档

- [项目现状与关键决策](docs/project-status.md)
- [P0 / P1 发布清单](docs/p0-p1-roadmap.md)
- [Nightly 与正式发布](docs/nightly-release.md)
- [安装、升级与回滚](docs/install-upgrade-rollback.md)
- [Tailscale 与 Peer Relay 运维](docs/tailscale-peer-relay-ops.md)
- [Codex 协议支持边界](docs/codex-protocol-support.md)
- [Capability 声明与本地降级](docs/capability-rollout.md)
- [Claude bridge 架构](docs/claude-bridge-architecture.md)
- [与 Litter 的能力对照](docs/litter-comparison.md)
- [隐私政策](docs/privacy-policy.md)
- [使用条款](docs/terms-of-use.md)
- [商标与品牌使用政策](TRADEMARKS.md)
- [支持说明](docs/support.md)
- [安全政策](SECURITY.md)

## 隐私与安全

Mimi Remote 不包含广告、分析 SDK 或开发者自建遥测，不把项目内容、对话、日志、代码或 Token 上传到项目维护者服务器。用户主动启用的 Codex、Claude Code、GitHub、Codex 语音转写或 MCP 等第三方能力仍受各自服务条款约束；Apple 语音输入使用设备端 SpeechAnalyzer 处理。

请不要在公开 Issue、PR、日志或截图中提交真实 Token、Tailscale IP、私有工作目录或项目内容。安全问题请按 [SECURITY.md](SECURITY.md) 私下报告。

## License

Mimi Remote 自有的 iOS App、Mac App、Go 后端和文档使用 [GNU GPLv3](LICENSE)，并依据 GPLv3 第 7 节授予通过 Apple App Store 和 Google Play 分发的额外许可。允许商业使用和收费分发；但如果向第三方分发 GPL 覆盖的修改作品或目标代码，必须确保接收者取得该覆盖作品的 GPLv3 权利，并按 GPLv3 要求提供对应源码或合规的源码获取方式。不能把该覆盖作品作为不向接收者提供这些权利或源码获取方式的闭源产品分发；独立作品和第三方组件仍适用各自许可证。

GPLv3 授予的是代码相关权利，不自动授予 Mimi Remote 名称、Logo、App 图标或官方发行身份。面向用户的修改版产品如果使用这些项目标识，必须遵守[商标与品牌使用政策](TRADEMARKS.md)；未经书面授权，应使用独立品牌且不得冒充官方版本。如实说明“基于 Mimi Remote”或兼容性仍然允许。

[`bridges/claude`](bridges/claude) 源自 Alleycat 多位贡献者，保留独立的 [GPLv3-only](bridges/claude/LICENSE)；仓库根目录的商店分发额外许可不适用于这部分上游代码。

此前已经明确以 MIT License 发布的历史版本继续受其原有许可；本次变更不追溯撤销已经授予的权利。第三方版权与许可证正文见 [NOTICE.md](NOTICE.md) 和 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
