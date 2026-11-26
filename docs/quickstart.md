# 在手机上连接自己的电脑

先把 Mimi Remote 装在存放代码的电脑上。安装包可以提前下载后带到离线电脑。即使还没安装编程助手、还没选手机连接方式，也可以先保存设置并启动后台服务。准备配对时，再选一个助手和一种连接方式。

## 1. 安装桌面端并选择代码目录

| 系统 | 在电脑上操作 |
| --- | --- |
| macOS 15 及以上 | 校验 DMG 后打开，把 **Mimi Remote Mac** 拖到「应用程序」，从那里打开。按设置窗口提示选择代码目录。如果系统要求批准后台项目，在「系统设置 → 通用 → 登录项与扩展」中允许 Mimi Remote，然后回到 App 检查。日常操作在菜单栏的 Mimi Remote 图标里。 |
| Windows 10/11 x64 | 用当前桌面用户运行已校验的 Setup。需要现在授权时，勾选确认工作区的选项并选择已有的代码目录。也可以跳过，之后从通知区域打开 Mimi Remote。静默新装会先启动核心服务，等你确认目录后才能配对。 |
| Linux amd64 / arm64 | 以普通用户解压与架构匹配的 Release，在解压目录执行 `bash ./scripts/install-linux.sh install`。首次默认扫描和浏览目录都是 `~/code`。可从桌面菜单打开 Mimi Remote，或执行 `~/.local/bin/mimi-remote-tray --show`。 |

选择的文件夹可以为空。手机能浏览的范围由浏览目录决定，请选择你愿意授权的项目文件夹。Windows 待确认时，从支持的托盘或 App 选择「完成首次设置」。旧托盘可重新运行正式安装器，在工作区页面确认目录。安装包和摘要见[桌面端下载](https://github.com/gaixianggeng/mimi-remote/releases/latest)。

## 2. 准备一个助手

在电脑上用自己的账号完成对应助手的安装或登录，再在 Mimi Remote 的助手设置里启用它并重新检查。只用 Claude、Antigravity 或 DeepSeek 的用户可以跳过 Codex。

| 我想用 | 需要准备什么 |
| --- | --- |
| Codex | 安装受支持的 Codex CLI 或带兼容 CLI 的 ChatGPT 桌面版，在电脑上登录。打开 Mimi Remote 检查 Codex 的可用状态。[Codex 指南](https://learn.chatgpt.com/docs/codex/cli) |
| Claude Code | 安装并登录 Claude Code，启用 Claude 助手。桌面端提示缺少适配器时，先检查是否使用了适合本平台的完整软件包。[Claude Code 入门](https://code.claude.com/docs/en/quickstart) |
| Antigravity | 安装支持的 Antigravity 命令行工具（`agy`），完成该工具的账号登录，再检查 Antigravity 行。[Antigravity](https://antigravity.google/) |
| DeepSeek | 在电脑上启动自己的 DeepSeek Harness，将它提供的私有连接地址交给 Mimi Remote 的 DeepSeek 连接入口。连接成功并读到至少一个模型后可以配对。地址含凭据，请仅在本机输入。[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) |

## 3. 选一种手机能到达的连接方式

- **同一局域网**。手机和电脑连接同一个受信任的网络，在电脑上开启局域网访问（Linux / macOS 命令行可运行 `agentd network --lan-enabled=true` 后执行 `agentd restart --no-pair`）。Windows 安装器默认关闭此项。需要时用已签名的安装器维护入口开启，核对专用网络和防火墙授权。公共 Wi-Fi 上可选其他通道。
- **Tailscale**。两端登录同一个能互访的 Tailscale 网络，在 Mimi Remote 开启 Tailscale 连接（命令行可运行 `agentd network --tailscale-enabled=true` 后执行 `agentd restart --no-pair`）。
- **内置连接（Tailcat）**。仅适用于可联网环境：在支持的桌面端开启内置连接并等待就绪，或运行 `agentd tailcat enable` 后使用 `agentd tailcat pair` 配对。

## 4. 在手机上配对

在电脑菜单栏或托盘打开「配对设备…」，选择已就绪的通道；命令行可先运行 `agentd status --pairing` 检查当前配对前提与修复命令，条件满足后再按提示运行 `agentd pair --qr-only`（或 `agentd tailcat pair --qr-only`）。在手机或 iPad 的 Mimi Remote 中添加电脑，扫描本次二维码，也可以粘贴电脑刚复制的短期配对链接。二维码过期后在电脑上刷新即可。链接可以用于认领设备，请勿放进日志或公开消息。

如果没有出现二维码，按顺序检查代码目录是否已确认、后台服务是否就绪、一个助手是否可用，以及手机能否通过选定通道到达电脑。解决提示后重新配对。如果已有设备连过这台电脑，请保留原配置和凭据。安装包校验、升级和恢复步骤见[安装、升级与回滚](install-upgrade-rollback.md)。
