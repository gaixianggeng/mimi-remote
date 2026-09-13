# 2026-09 推广海报（ChatGPT 生图原稿）

2026-09-14 按 [`docs/design/promo-image-prompts.md`](../../../docs/design/promo-image-prompts.md) 生成的第一批带壳海报，用作后续 App Store 推广截图的底稿。截图素材来自 `web/assets/shots/`（2026-09-12 重拍，Debug 种子数据）。

这里存的是**原稿**，还不能直接上传 App Store：尺寸不达标，界面文字经过生图工具重采样。上传前按文末清单处理。

## 文件

全部为 RGB PNG，无透明通道。

### `iphone/`（853 × 1844，比例与 App Store iPhone 一致，需放大）

| 文件 | 标题 | 截图来源 | 状态 |
| --- | --- | --- | --- |
| `01-conversation-zh.png` | 离开电脑，会话不断 | `iphone-conversation` | 屏幕把对话与审批卡拼在一起，原始截图里没有这个画面；上传前换回真实截图 |
| `02-approval-zh.png` | 审批就在手边，一步放行 | `iphone-approval` | 可用 |
| `03-notifications-zh.png` | 需要你的时候，第一时间知道 | `iphone-conversation` | **半成品**：三条通知卡片是空白的，需在 Figma 补文字 |
| `04-computers-zh.png` | 一部手机，管好每台电脑 | `iphone-mac-connection` | **界面过时**：设备页 09-13 已改版，需重拍截图后重做 |
| `05-light-dark-zh.png` | 浅色深色，同样用心 | `iphone-conversation` 浅 + 深 | 可用 |

### `iphone-3x4/`（1086 × 1448，3:4）

会话列表与工作区的中英、深浅四个版本：`sessions-{en,zh}-{dark,light}.png`、`workspaces-{en,zh}-{dark,light}.png`。

3:4 不符合 App Store iPhone 截图比例，只适合官网、社交平台或小红书。英文版里的 `session`、`workspace`、`ended` 小写来自 App 本身的英文译文，见 #465，修复后再重出英文版。

### `ipad/`（1086 × 1448，3:4，与 iPad 13" 比例一致，需放大到 2064 × 2752）

| 文件 | 标题 | 状态 |
| --- | --- | --- |
| `01-workbench-zh-light.png` | 同样的会话，在 iPad 上展开成工作台 | 可用 |
| `02-workspaces-zh-light.png` | 每个项目，进度一眼看清 | 可用 |
| `03-workbench-zh-dark.png` | 深色模式，一样精致 | 输入框占位符被改成「添加下一回合指令」，原文是「追加下一回合指令」 |

### `web/`（1642 × 958）

`overview-zh.png`：官网总览横幅「离开电脑，会话不断」，iPad + iPhone。副标题含 Codex 与 Claude Code，只能用于官网，不能用于 App Store。尚无英文版。

## 上传 App Store 前

- [ ] 放大到规定尺寸：iPhone 6.5" 1242 × 2688，iPad 13" 2064 × 2752。放大后仍发糊的，按提示词文档第一节「两步走」重做：生图只出壳和背景，真实截图在 Figma 里贴进屏幕。
- [ ] 逐字核对屏幕内界面与原始截图，处理上表列出的问题。
- [ ] 标题与画面文字不含第三方产品名称。
- [ ] 补齐英文版（等 #465 修复后重拍英文截图）。
