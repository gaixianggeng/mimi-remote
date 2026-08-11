# Mimi Remote Notice

## 目标

这个文件说明 Mimi Remote / `mimi-remote` 的归属、第三方品牌边界和开源使用方式。

## 项目归属

Mimi Remote 是独立开发的第三方客户端。它连接用户自己 Mac 上运行的 `agentd`，再由 `agentd` 连接用户本机的 Codex CLI / app-server 环境。

本项目不隶属于 OpenAI 或 Anthropic，也没有获得这些公司的赞助、背书或官方授权。`Codex`、`OpenAI`、`Claude`、`Anthropic` 等名称和界面内对应的服务标识，只用于描述兼容的用户自有工具链及区分用户主动选择的运行时。相关商标和标识归各自权利人所有，不构成合作或背书。

## 开源许可

Copyright (c) 2026 Gaixiang Geng

本仓库自有的 iOS App、Mac App、Go 后端和文档使用 GNU GPLv3，并依据 GPLv3 第 7 节授予通过 Apple App Store 和 Google Play 分发的额外许可。完整条款见 [LICENSE](LICENSE)。

商业使用和收费分发并未被禁止。向第三方分发 GPL 覆盖的修改作品或目标代码时，必须针对该 GPL 覆盖作品履行 GPLv3 要求，包括保留适用声明、在适用时标记修改、确保接收者取得 GPLv3 规定的权利，并按 GPLv3 要求提供对应源码或合规的源码获取方式；不得把该覆盖作品作为不向接收者提供这些权利或源码获取方式的闭源产品分发。独立作品和第三方组件仍适用各自许可证。此前已经明确以 MIT License 发布的历史版本继续受其原有许可。

[`bridges/claude`](bridges/claude) 源自 Alleycat 多位贡献者，按 [GPLv3-only](bridges/claude/LICENSE) 分发。根目录中的 App Store / Google Play 额外许可只由 Mimi Remote 自有代码的 copyright holders 授予，不适用于其他上游贡献者拥有版权的 bridge 代码。具体来源和导入 commit 见 [UPSTREAM.md](bridges/claude/UPSTREAM.md)。

## 第三方依赖

本项目依赖的第三方包保留其各自上游许可证。当前发布涉及的运行时和已解析依赖包括：

完整版权声明、NOTICE 和许可证正文见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)，该文件会随 `agentd` 发布压缩包和 iOS App 一起分发。

Go 依赖：

- Go standard library / runtime
- `github.com/creack/pty`
- `github.com/gorilla/websocket`
- `github.com/skip2/go-qrcode`
- `golang.org/x/image`
- `golang.org/x/text`（间接依赖）

Swift Package Manager 依赖：

- `swift-markdown`
- `swift-cmark`
- `swift-syntax`
- `swift-custom-dump`
- `swift-snapshot-testing`
- `xctest-dynamic-overlay`

运行时外部工具：

- 用户本机自行安装和登录的 Codex CLI / app-server。
- 用户显式启用实验通道时，自行安装和登录的 Claude Code；`alleycat-claude-bridge` 源码位于本仓库 `bridges/claude`。

本仓库不打包用户的 Codex 凭证，也不托管第三方服务账号。

## 品牌与设计边界

开源许可证授予的是代码、二进制和文档的相关权利，不自动授予 Mimi Remote 产品名称、Logo、App 图标或官方发行身份。面向用户的修改版产品如果使用这些项目标识，必须遵守[商标与品牌使用政策](TRADEMARKS.md)；未经书面授权，应使用独立的主要品牌且不得冒充官方版本。如实说明来源与兼容性仍然允许。

除上述用于兼容性说明和运行时区分的服务标识外，本项目不会把自己宣传为任何商业产品的免费替代品，也不会以复刻其他产品的 UI、交互、图标、截图或文案为目标。

iOS 工作区中的 Codex 运行时入口使用 OpenAI 官方 macOS 应用资源包中的 `icon-chatgpt.png`，仅按 iOS 显示倍率等比缩小，用于帮助用户识别其使用 ChatGPT 账号连接的 Codex 运行时。该图标及相关商标归 OpenAI 所有，不代表 OpenAI 对本项目的赞助或背书。

iOS 首次连接页使用 GitHub 官方 Brand Toolkit 提供的黑白 Invertocat 标识，仅用于链接本项目的公开 Release 页面。该标识及 GitHub 商标归 GitHub, Inc. 所有，不代表 GitHub 对本项目的赞助或背书。

如果你认为本仓库的代码、文档、视觉设计或宣传文案和你的项目过于相似，欢迎通过 GitHub Issue 说明具体文件、截图或链接。我们会优先处理可以明确定位的归属、许可证和混淆风险。
