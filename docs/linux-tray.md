# Linux 桌面托盘

Mimi Remote 在 Linux 上通过标准 StatusNotifierItem / DBusMenu 提供常驻系统托盘。菜单显示当前宿主的服务、网络、agentd 版本和已启用 Runtime 状态，并提供刷新、配对、复制地址、诊断、日志及启动/重启/停止入口。菜单的外观和位置由桌面环境决定，图标可能位于顶栏的折叠托盘中。

绿色图标表示服务正常，橙色表示需要处理或状态尚未确认，灰色表示已停止。刷新失败保留最后一次有效状态并显示错误；确认状态前不允许配对或改变服务生命周期。单个登录用户只运行一个实例，桌面面板重启后会自动重新注册。

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
# 手动打开状态面板；重复运行使用已有托盘实例
"$HOME/.local/bin/mimi-remote-tray" --show

# 只退出托盘，agentd 与共享 Codex App Server 继续运行
"$HOME/.local/bin/mimi-remote-tray" --quit

# 独立回滚/卸载托盘；主安装器 rollback/uninstall 也会调用它
bash "$HOME/.local/share/mimi-remote/install-linux-tray.sh" rollback
bash "$HOME/.local/share/mimi-remote/install-linux-tray.sh" uninstall
```

托盘二进制、图标、桌面/自启动入口和安装助手使用同一快照回滚。升级失败会恢复原文件；首次安装的前一状态是“无托盘”。托盘日志为 `~/.local/share/mimi-remote/tray.log`。不修改 Waybar、Hyprland、GNOME 或 Tailscale 配置。

## 面板与配对

二维码、诊断、日志和服务确认页在默认浏览器中打开。面板由托盘进程监听随机 `127.0.0.1` 端口，使用随机会话地址、同源检查及 CSRF 校验；不对 LAN/Tailnet 提供管理接口。退出托盘后该面板失效，重新打开时应从托盘进入。

停止/重启页面必须点击确认按钮才执行。配对只使用 `agentd pair --qr-only --json` 返回的短期票据，二维码过期后自动隐藏，长期 Token 不进入托盘。日志有长度上限，包含凭据的行会隐藏。浏览器响应禁止缓存、第三方资源和嵌入。

## 桌面兼容性

| 环境 | 支持边界 |
| --- | --- |
| Omarchy / Quickshell | 使用现有 StatusNotifier 托盘，图标可能在折叠区；已在本机完成真实注册、菜单协议和状态面板验证 |
| Waybar | 需要已有 `tray` 模块；遵循相同协议，独立 Waybar 会话仍需视觉验收 |
| KDE Plasma | 使用系统 StatusNotifier 托盘；独立 KDE 会话仍需视觉验收 |
| GNOME | 需要提供 AppIndicator/StatusNotifier 支持的扩展；不自动安装或配置扩展 |
| 无托盘宿主 / SSH | agentd 可以独立工作；桌面托盘进程等待宿主出现，`--show` 仍需可用的浏览器 |

托盘为纯 Go 构建，不依赖 GTK 开发库。图形面板需要 `xdg-open` 与默认浏览器。菜单直接复制地址在 Wayland 使用 `wl-copy`、在 X11 使用 `xclip`；缺少工具时打开状态面板，仍可用浏览器按钮或 Ctrl+C 复制。

## 开发验证

```bash
go test -race ./cmd/mimi-remote-tray
bash ./scripts/test-install-linux-tray.sh
bash ./scripts/test-install-linux.sh
CGO_ENABLED=0 go build -o /tmp/mimi-remote-tray ./cmd/mimi-remote-tray
/tmp/mimi-remote-tray --agent "$HOME/.local/bin/agentd"
```

D-Bus 回归在隔离的 `dbus-daemon` 中验证注册、菜单布局、重复启动、宿主重启和退出；不操作用户现有 agentd。真实服务停止、重启及手机扫码仍需在可中断连接的验收时段完成，不用 mock 结果替代这些验证。

协议参考：[StatusNotifierItem](https://specifications.freedesktop.org/status-notifier-item/latest/status-notifier-item.html)、[Waybar DBusMenu](https://github.com/Alexays/Waybar/blob/master/protocol/dbus-menu.xml)。
