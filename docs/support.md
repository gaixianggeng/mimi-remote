# Mimi Remote 支持 / Support

## 中文

### 目标

本页提供 Mimi Remote 的安装、连接、诊断、数据删除和联系入口。

### 方案

使用前请确认：

- iPhone 或 iPad 运行 App 支持的系统版本。
- Mac 已安装并登录 Codex CLI。
- Mac 已通过 Homebrew 安装并启动 `mimi-remote` 后端。
- 移动设备能够通过局域网、Tailscale 私有网络或用户配置的 HTTPS 地址访问 Mac。

```bash
brew update
brew install gaixianggeng/tap/mimi-remote
agentd up
agentd status
```

运行 `agentd pair` 获取新的短期配对二维码，然后在 App 的“Mac 连接”页面扫码。也可以手动输入地址和访问 Token。

### 实现

连接失败时依次检查：

1. 在 Mac 执行 `agentd doctor --fix` 和 `agentd status`。
2. 确认移动设备与 Mac 的网络可达，且没有把私网 HTTP 地址替换成公网 HTTP。
3. 在 App 中打开“设置 → 诊断与支持”，运行连接测速并查看失败阶段。
4. 重新执行 `agentd pair`，使用新的二维码配对。

删除本地连接资料：在“设置 → Mac 连接”中选择“忘记连接”或删除连接档案。这样会删除对应配置和 Keychain Token。删除 App 前建议先完成此操作。

### 风险与优化

联系邮箱：`gaixg94@gmail.com`

也可以在 [公开 Issue](https://github.com/gaixianggeng/mimi-remote/issues) 报告可复现问题。请附 App 版本、后端版本、设备系统版本和脱敏后的复现步骤，但不要提交 Token、真实 Tailnet 地址、私有路径、代码、完整日志或签名文件。安全问题请按公开仓库 [SECURITY.md](https://github.com/gaixianggeng/mimi-remote/blob/main/SECURITY.md) 私下报告。

## English

### Purpose

This page provides installation, connection, diagnostics, data-deletion, and contact information for Mimi Remote.

### Setup

Before using the app, confirm that:

- Your iPhone or iPad runs a supported system version.
- Codex CLI is installed and signed in on your Mac.
- The `mimi-remote` backend is installed with Homebrew and running on the Mac.
- The mobile device can reach the Mac over a local network, a private Tailscale network, or an HTTPS endpoint you configure.

```bash
brew update
brew install gaixianggeng/tap/mimi-remote
agentd up
agentd status
```

Run `agentd pair` to create a new short-lived pairing QR code, then scan it from the Mac Connection screen. Manual endpoint and token entry are also available.

### Troubleshooting

If connection fails:

1. Run `agentd doctor --fix` and `agentd status` on the Mac.
2. Confirm network reachability and do not replace a private HTTP address with a public HTTP endpoint.
3. Open Settings → Diagnostics & Support in the app, run the connection speed test, and inspect the failed stage.
4. Run `agentd pair` again and pair with a fresh QR code.

To remove local connection data, choose Forget Connection or delete the connection profile under Settings → Mac Connection. This removes its configuration and Keychain token. Do this before uninstalling if you want credentials explicitly removed.

### Contact and safe reporting

Email: `gaixg94@gmail.com`

You may also report reproducible problems in [public Issues](https://github.com/gaixianggeng/mimi-remote/issues). Include app version, backend version, OS version, and redacted reproduction steps. Never include tokens, real Tailnet addresses, private paths, source code, full logs, or signing files. Report security issues privately as described in the public repository's [SECURITY.md](https://github.com/gaixianggeng/mimi-remote/blob/main/SECURITY.md).
