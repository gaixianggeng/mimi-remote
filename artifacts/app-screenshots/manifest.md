# README 公开截图清单

## 目标

这里只保留 README 正在引用的截图。iOS 与 iPadOS 的历史截图（DeviceHub、模拟器、App Store 各版本提交素材与推广图）已于 2026-09-13 删除，当前界面截图统一以官网 `web/assets/shots/` 为准（2026-09-12 重拍，由 `web/capture-screenshots.sh` 生成）。

## 当前资产

| 设备 | 文件名 | 尺寸 | 展示内容 |
| --- | --- | --- | --- |
| Mimi Remote Mac Debug | `mac-menu-bar-debug-2026-07-28.png` | 680×1220 | 340pt 菜单栏控制面、双 Runtime 状态、额度环与运维动作。 |

## 采集方式

- Mac 图由当前源码构建 Debug App，以 `--debug-seed-ui` 启动并复用现有 Preview 数据；只裁出 MenuBarExtra 窗口。截图进程在采集后已退出，已安装的正式 App 和正在运行的服务没有被重启或替换。
- 图片来自实际运行的 SwiftUI 界面，没有重绘或修改 App 内容。

## 隐私与更新规则

- Debug 种子数据只使用 `/Users/demo`、占位凭证、公开 README 检查文案和 `mimi-demo.local` 演示 Endpoint。
- 图片已目视检查，不包含真实 Token、Tailnet 地址、个人仓库或个人文件目录。
- Mac 菜单栏发生明显变化后，应重拍并直接替换当前资产，不再累积旧版正式截图。
- 被删除的历史 PNG 都是 Git 已跟踪文件，如需审计可从 Git 历史恢复。
