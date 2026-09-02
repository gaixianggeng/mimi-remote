# MIM-233 App Store 1.2.1 提交素材

## 目标

为 App Store Connect 新版本 `1.2.1` 更新简体中文公开名称和推广截图。App 代码逻辑不在本 Issue 的修改范围内。

## 方案

- 简体中文公开名称：`Mimi Remote`。
- 英文（美国）公开名称继续使用 `Mimi Remote`。
- 只替换 `zh-Hans` 截图；英文截图保持上一版本内容。
- iPhone 6.5 英寸与 iPad 13 英寸各 4 张，共 8 张。
- 上传顺序：会话、会话列表、开发会话、连接。

## 实现

- iPhone 图片为 `1242 × 2688` RGB PNG。
- iPad 图片为 `2064 × 2752` RGB PNG。
- 所有图片均无透明通道。
- 第 3 张图片使用 Codex 内置 ImageGen 将宣传标题从第三方产品名称改为“多种开发会话 / 无缝接力”。App 界面内用于说明实际兼容能力的产品名称保持不变。
- `upload/manifest.json` 记录上传文件的尺寸、文件大小和 SHA-256。
- 本素材只用于在 App Store Connect 手工替换 `zh-Hans` 截图。仓库现有 `ios_asc_publish_screenshots.rb` 要求中英文各 5 张，因此不得用于本目录。
- 版本号为 `1.2.1`，首个构建号为 `100098`。

## 风险与优化

- 图片含 AI 重采样内容。上传前已经检查主要宣传文案、设备边框和界面信息；App Store 审核仍可能要求进一步调整。
- 新版本基于当前 `main` 构建，因此会包含 1.2 发布后已经合并到 `main` 的代码。
- App Store Connect 的英文截图不在本次替换范围内。
- App Store Connect 上传与正式审核提交完成后，再在本文件补充提交回执。
