# Mimi Remote 支持 / Support

## 中文

### 目标

本页提供 Mimi Remote 的安装、连接、诊断、数据删除和联系入口。

### 方案

使用前请确认：

- iPhone 或 iPad 运行 iOS / iPadOS 18 或更高版本。
- 电脑运行 macOS 15 或更高版本、Windows 10/11 x64，或带 systemd 用户会话的 Linux（x86_64 或 ARM64），并已安装和登录 Codex（Mac 上 Codex CLI 或 ChatGPT 桌面版均可，Windows 和 Linux 需要 Codex CLI）。
- 电脑已从 [GitHub Releases](https://github.com/gaixianggeng/mimi-remote/releases/latest) 安装并启动 Mimi Remote 宿主：Mac 使用 **Mimi Remote Mac**，Windows 使用 `Mimi-Remote-Setup` 安装程序，Linux 使用 `linux` 归档。
- 移动设备能够通过局域网、Tailscale 私有网络、实验性 Tailcat 连接或用户配置的 HTTPS 地址访问电脑。

支持范围：只有来自 App Store、TestFlight 或从本仓库源码构建的正式签名包在支持范围内。iOS 16 / 17 回移分支，以及未签名 / TrollStore / 越狱构建不受支持，相关问题不进入修复排期。

Mac 普通用户请下载 `Mimi-Remote-Mac.dmg`，打开后将 **Mimi Remote Mac** 拖入“应用程序”，再在 Mac App 内完成首次设置。Windows 与 Linux 的安装、校验、升级和回滚见[安装文档](https://github.com/gaixianggeng/mimi-remote/blob/main/docs/install-upgrade-rollback.md)。macOS 命令行安装只作为服务器、自动化或故障恢复入口：

```bash
brew update
brew install gaixianggeng/tap/mimi-remote
agentd up
agentd status
```

宿主首次设置会显示短期配对二维码：首次打开 Mac App 会自动弹出设置窗口，选好代码文件夹后，窗口直接显示二维码。在移动端 App（主屏上叫 mimi）的“连接电脑”页面扫码；已经连过电脑时，在「设备」页（或设置中的「电脑连接」）添加电脑。扫不了码时，在 Mac 的配对窗口点“复制配对链接”，再在 App 里点“粘贴配对链接”。命令行用户可运行 `agentd pair` 重新生成二维码；也可以手动输入地址和访问 Token。

连上之后，App 会列出代码文件夹里的项目，点一下就打开为工作区，然后新建会话。新会话页提示没有可用的 Codex 时，先在电脑上安装并登录 Codex，再回到 App 重试。

### 实现

连接失败时依次检查（下面以 Mac 为例，都是界面操作，不要求命令行；Windows 与 Linux 使用托盘图标中的同类入口）：

1. 看 Mac 菜单栏的 Mimi Remote 图标是否还在，点开后是否显示“Mac 服务运行中”。图标不在就重新打开“应用程序”里的 **Mimi Remote Mac**。
2. 打开 Mac App 的窗口，按首屏提示处理：未配置时会提示先选择代码目录，服务未运行时窗口会给出启动入口。
3. 确认移动设备与 Mac 的网络可达，且没有把私网 HTTP 地址替换成公网 HTTP。
4. 在 App 的“设备”页打开当前电脑的“连接诊断”，运行测速并查看失败阶段；更多信息在“我的 → 诊断与支持”。
5. 二维码过期或配对失效时，在 Mac 菜单栏的 Mimi Remote 里点“配对设备…”，再点“刷新二维码”，然后在 App 里扫新码。

命令行安装（服务器、自动化或故障恢复）用同一套检查：第 1、2 步换成 `agentd status`（必要时 `agentd doctor --fix`），第 5 步换成 `agentd pair`。

删除本地连接资料：在 App 的「设备」页（或设置中的「电脑连接」）打开这台电脑的菜单，选择「忘记这台电脑」，或删除连接档案。这样会删除对应配置和 Keychain Token。删除 App 前建议先完成此操作。

### 风险与优化

联系邮箱：`gaixg94@gmail.com`

也可以在 [公开 Issue](https://github.com/gaixianggeng/mimi-remote/issues) 报告可复现问题。请附 App 版本、后端版本、设备系统版本和脱敏后的复现步骤，但不要提交 Token、真实 Tailnet 地址、私有路径、代码、完整日志或签名文件。安全问题请按公开仓库 [SECURITY.md](https://github.com/gaixianggeng/mimi-remote/blob/main/SECURITY.md) 私下报告。

## English

### Purpose

This page provides installation, connection, diagnostics, data-deletion, and contact information for Mimi Remote.

### Setup

Before using the app, confirm that:

- Your iPhone or iPad runs iOS/iPadOS 18 or later.
- Your computer runs macOS 15 or later, Windows 10/11 x64, or Linux (x86_64 or ARM64 with a systemd user session), with Codex installed and signed in (on a Mac, the Codex CLI or the ChatGPT desktop app; on Windows and Linux, the Codex CLI).
- The Mimi Remote host is installed from [GitHub Releases](https://github.com/gaixianggeng/mimi-remote/releases/latest) and running: **Mimi Remote Mac** on Mac, the `Mimi-Remote-Setup` installer on Windows, or the `linux` archive on Linux.
- The mobile device can reach the computer over a local network, a private Tailscale network, the experimental Tailcat connection, or an HTTPS endpoint you configure.

Supported builds: only signed builds from the App Store, TestFlight, or source built from this repository are supported. iOS 16/17 back-ports, and unsigned / TrollStore / jailbroken builds, are out of scope and are not scheduled for fixes.

For normal setup on a Mac, download `Mimi-Remote-Mac.dmg`, open it, drag **Mimi Remote Mac** to Applications, and finish setup in the Mac app. For Windows and Linux installation, verification, upgrades, and rollback, see the [installation guide](https://github.com/gaixianggeng/mimi-remote/blob/main/docs/install-upgrade-rollback.md). Use the macOS command-line path only for servers, automation, or recovery:

```bash
brew update
brew install gaixianggeng/tap/mimi-remote
agentd up
agentd status
```

The host shows a short-lived pairing QR code during first-run setup: the first time you open the Mac app, a setup window appears, and after you choose your code folder it shows the code. Scan it from the Connect a computer screen in the iPhone or iPad app (called mimi on the home screen); if you already have a computer, add another from the Devices tab (or Computer connection in Settings). If you can't scan, copy the pairing link in the Mac pairing window and tap Paste pairing link in the app. Command-line users can run `agentd pair` to generate a new code. Manual endpoint and token entry are also available.

Once connected, the app lists the projects in your code folder; tap one to open it as a workspace and start a session. If creating a new session says Codex isn't available, install and sign in to Codex on the computer, then try again.

### Troubleshooting

If connection fails, check these in order (the steps use a Mac as the example and are all in the UI; no command line required. On Windows and Linux, use the matching items in the tray icon):

1. Check the Mimi Remote icon in the Mac menu bar: it should still be there and, when opened, report that the Mac service is running. If it is gone, reopen **Mimi Remote Mac** from Applications.
2. Open the Mac app window and follow what it shows: an unconfigured app asks you to choose a code directory first, and a stopped service offers a start action.
3. Confirm network reachability and do not replace a private HTTP address with a public HTTP endpoint.
4. In the app's Devices tab, open Connection diagnostics for the current computer, run the speed test, and inspect the failed stage. More details are under Me → Diagnosis and Support.
5. When the QR code expires or pairing stops working, open Mimi Remote in the Mac menu bar, choose the item with the QR-code icon, click the circular-arrow button in the pairing window, then scan the new code in the app.

For command-line installs (servers, automation, or recovery), the same checks apply: replace steps 1–2 with `agentd status` (and `agentd doctor --fix` when needed), and step 5 with `agentd pair`.

To remove local connection data, open the computer's menu in the Devices tab (or Computer connection in Settings) and choose Forget this computer, or delete its connection profile. This removes its configuration and Keychain token. Do this before uninstalling if you want credentials explicitly removed.

### Contact and safe reporting

Email: `gaixg94@gmail.com`

You may also report reproducible problems in [public Issues](https://github.com/gaixianggeng/mimi-remote/issues). Include app version, backend version, OS version, and redacted reproduction steps. Never include tokens, real Tailnet addresses, private paths, source code, full logs, or signing files. Report security issues privately as described in the public repository's [SECURITY.md](https://github.com/gaixianggeng/mimi-remote/blob/main/SECURITY.md).
