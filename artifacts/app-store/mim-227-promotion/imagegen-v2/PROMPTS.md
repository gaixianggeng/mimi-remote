# MIM-227 iPhone ImageGen v2 提示词

本组图片使用 Codex 内置 ImageGen 编辑模式生成。iPad 图片不变。

## 颜色依据

- Apple 官方名称：宇宙橙色（Cosmic Orange）。
- Apple 官方材质：铝金属一体成型机身。
- 主要视觉依据：[iPhone 17 Pro 官方产品图](https://www.apple.com/iphone-17-pro/)。
- Apple 未公布官方 Hex。以下颜色来自官方产品图采样，仅用于限制生成结果的明暗与饱和度：阴影 `#A94F28`、中间调 `#CC6F38`、高光 `#DC7E47`。

## 统一提示词

```text
Edit the supplied vertical Chinese App Store marketing image.

Use the previous campaign image only for layout, typography, copy,
background, crop, and composition. Use the approved v2 render for device
tone and lighting consistency. Use Apple's official iPhone 17 Pro Cosmic
Orange product image only for anodized aluminum color and material. Use the
raw app screenshot as the exact display content.

Render a subdued warm Cosmic Orange satin/matte anodized aluminum unibody.
Keep deep orange-brown midtones, restrained saturation, soft broad highlights,
and a distinct black front bezel. Do not create neon orange, an emissive rim,
a thin yellow highlight, glossy copper, chrome, or titanium texture.

Preserve every supplied Chinese marketing phrase exactly once. Keep the app
screen faithful to the raw screenshot. Do not invent UI, labels, icons, logos,
badges, watermarks, or product marks.
```

## 场景与角度

| 文件 | 标识 | 主标题 | 说明 | 角度 |
| --- | --- | --- | --- | --- |
| `01-conversation.png` | 会话接力 | 电脑上的会话 / 接着在移动端用 | 离开电脑，也不用重新开始 | 顺时针约 1.5°，接近正面 |
| `02-sessions.png` | 多设备控制 | 多台设备 / 移动端一处掌控 | 支持 Windows、Mac 与 Linux | 逆时针约 2.5°，略向右移 |
| `03-workspace.png` | 原生客户端会话 | Codex 与 Claude Code / 会话无缝接力 | 保留熟悉的工作方式与上下文 | 顺时针约 3°，略近景 |
| `04-connection.png` | 优雅设计 | 复杂能力 / 也能简单好用 | 为 iPhone 与 iPad 分别打磨 | 逆时针约 1°，接近正面 |

斜杠表示海报中的强制换行，不是成图文字。

## 发布前限制

ImageGen 会重采样设备内的界面。发布前必须逐张核对界面文字、图标和控件，不应把生成图视为像素级原始截图。
