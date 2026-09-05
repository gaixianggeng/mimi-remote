# Linux 桌面托盘

Mimi Remote 在 Linux 上通过标准 StatusNotifierItem / DBusMenu 提供常驻系统托盘。菜单展示服务、Runtime 和 Tailcat 状态，提供终端入口、三种网络配对方式、复制地址，以及分组的服务管理和诊断/日志。菜单外观和位置由桌面环境决定，图标可能位于顶栏的折叠区；Omarchy 可以在托盘管理中固定 Mimi Remote。

托盘使用透明单色 symbolic 图标，Omarchy 根据顶栏前景色自动着色；设备、感叹号、暂停标记分别表示正常、需要处理和已停止，菜单与悬停提示同时给出文字状态。刷新失败保留最后一次有效状态并显示错误；确认状态前不允许配对或改变服务生命周期。单个登录用户只运行一个托盘实例，桌面面板重启后会自动重新注册。

## 安装与使用

Linux amd64/arm64 Release 归档包含 `agentd`、`mimi-remote-tray`、图标、桌面入口与安装脚本。完成 checksum 校验并解压后运行：

```bash
bash ./scripts/install-linux.sh install
```

安装器先完成 agentd 的就绪检查，再安装托盘。托盘安装失败会明确告警，已就绪的 agentd 服务继续保留。可在同一 Release 解压目录单独重试：

```bash
bash ./scripts/install-linux-tray.sh install
```

程序安装至 `~/.local/bin/mimi-remote-tray`，应用菜单提供 **Mimi Remote**，XDG 自启动文件位于 `~/.config/autostart/mimi-remote.desktop`。升级保留该文件中的 `Hidden=true` 偏好。无图形会话时仅安装文件；下一次桌面登录再启动。`MIMI_TRAY_NO_START=1` 可在安装时跳过立即启动。

```bash
# 手动打开终端界面；重复运行使用已有托盘实例
"$HOME/.local/bin/mimi-remote-tray" --show

# 直接在当前终端中运行；不要求启动托盘或图形会话
"$HOME/.local/bin/mimi-remote-tray" --terminal status

# 只退出托盘，agentd、Codex App Server 与已打开的终端继续运行
"$HOME/.local/bin/mimi-remote-tray" --quit

# 独立回滚/卸载托盘；主安装器 rollback/uninstall 也会调用它
bash "$HOME/.local/share/mimi-remote/install-linux-tray.sh" rollback
bash "$HOME/.local/share/mimi-remote/install-linux-tray.sh" uninstall
```

托盘二进制、图标、桌面/自启动入口和安装助手使用同一快照回滚。升级失败会恢复原文件；首次安装的前一状态是“无托盘”。托盘日志为 `~/.local/share/mimi-remote/tray.log`。不修改 Waybar、Hyprland、GNOME 或 Tailscale 配置。

## 终端界面与配对

托盘操作通过 `xdg-terminal-exec` 打开系统首选终端，缺少它时选择已安装的常见终端。界面跟随终端背景和文字主题，输入快捷键后按 Enter：`0` 主机概览、`1` Tailcat、`2` Tailscale、`3` 局域网、`4` 诊断、`5` 日志、`6` 服务、`r` 刷新、`q` 退出。长内容使用 `n` / `p` 翻页。主机概览包含连接地址、agentd 版本及内置/外部网络状态。

Tailcat 是 main 已支持的内置连接功能，与外部 Tailscale 网络独立。未启用时，Tailcat 配对入口先说明作用，输入 `enable` 确认后调用现有 `agentd tailcat enable --json`，就绪后使用 `agentd tailcat pair --qr-only --json` 生成配对码。不可用或未就绪时显示真实原因。Tailscale / LAN 分别使用 `agentd pair --network tailscale|lan --qr-only --json`；LAN 入口要求已有配置允许局域网访问。

停止、重启、关闭 Tailcat 分别要求输入 `stop`、`restart`、`disable`；其他输入取消。终端只调用现有 agentd CLI，不运行浏览器或新增 HTTP 管理服务，也不自动切换连接网络。多个管理窗口共享操作锁，避免同时启停或生成配对信息。

二维码使用高对比度黑白字符，过期后自动清除。终端尺寸不足时提示所需列数/行数，调整窗口或字号后自动显示，不输出被折行破坏的二维码。界面使用备用屏幕，退出后配对码不会留在普通滚动历史中。长期 Token 不进入界面；诊断和日志有长度上限、凭据脱敏及终端控制序列过滤。

## 桌面兼容性

| 环境 | 支持边界 |
| --- | --- |
| Omarchy / Quickshell | 使用现有 StatusNotifier 托盘，图标可能在折叠区；已在本机完成真实注册、菜单协议和状态面板验证 |
| Waybar | 需要已有 `tray` 模块；遵循相同协议，独立 Waybar 会话仍需视觉验收 |
| KDE Plasma | 使用系统 StatusNotifier 托盘；独立 KDE 会话仍需视觉验收 |
| GNOME | 需要提供 AppIndicator/StatusNotifier 支持的扩展；不自动安装或配置扩展 |
| 无托盘宿主 / SSH | agentd 可以独立工作；使用 `--terminal status` 在当前交互终端管理；桌面托盘进程等待宿主出现 |

托盘为纯 Go 构建，不依赖 GTK 开发库。终端入口优先使用 `xdg-terminal-exec`，支持回退到 Foot、Kitty、Alacritty、Konsole、GNOME Terminal、XTerm 等。菜单直接复制地址在 Wayland 使用 `wl-copy`、在 X11 使用 `xclip`；缺少工具时打开终端概览，可使用终端的文字选择和复制功能。

## 开发验证

```bash
go test -race ./cmd/mimi-remote-tray
bash ./scripts/test-install-linux-tray.sh
bash ./scripts/test-install-linux.sh
CGO_ENABLED=0 go build -o /tmp/mimi-remote-tray ./cmd/mimi-remote-tray
/tmp/mimi-remote-tray --agent "$HOME/.local/bin/agentd"
```

D-Bus 回归在隔离的 `dbus-daemon` 中验证注册、子菜单、重复启动、宿主重启和退出；PTY 回归验证真实终端输入、确认取消和退出。控制层覆盖 Tailcat 启用后配对、三种网络参数、跨窗口互斥、票据过期与终端控制序列过滤。测试不操作用户现有 agentd。真实服务停止、重启及手机扫码仍需在可中断连接的验收时段完成，不用 mock 结果替代这些验证。

协议参考：[StatusNotifierItem](https://specifications.freedesktop.org/status-notifier-item/latest/status-notifier-item.html)、[Waybar DBusMenu](https://github.com/Alexays/Waybar/blob/master/protocol/dbus-menu.xml)。
