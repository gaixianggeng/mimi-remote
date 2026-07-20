# Mimi Remote 隐私政策 / Privacy Policy

生效日期 / Effective date：2026-07-20

## 中文

### 目标

本政策说明 Mimi Remote iPhone、iPad 与 Mac Catalyst 客户端如何处理数据。Mimi Remote 是连接用户自有或获授权 Mac 开发环境的独立第三方开发者工具，不提供 AI 模型、AI 订阅、云端代码执行、VPN 或开发者运营的项目托管服务。

### 方案

Mimi Remote 开发者不收集、上传、出售或共享用户的个人数据。App 不包含广告、第三方分析 SDK 或开发者运营的遥测、崩溃上报与流量代理服务。

App 仅在完成用户明确请求时处理以下数据：

- 连接资料：用户配置的 `agentd` 地址、连接名称与访问 Token。Token 保存在系统 Keychain 中。
- 本地状态：语言、外观、权限偏好、最近工作区、会话索引、恢复路由、待发送草稿及诊断历史。
- 开发内容：提示词、会话、代码、Diff、图片、日志和工具结果仅在设备与用户配置的 Mac 之间传输，不发送给 Mimi Remote 开发者。
- 本地通知：仅保存打开指定连接、项目和会话所需的路由标识，不包含 Token、消息正文或工作目录。

### 实现

#### 用户配置的 Mac 与外部工具

Mimi Remote 直接连接用户手动输入或扫码导入的 `agentd`。`agentd` 在用户控制的 Mac 上调用 Codex；用户明确启用可选 Claude Code bridge 时，也可能调用 Claude Code。相关服务可能按照用户与其提供方之间的条款处理提示词、代码和输出。Mimi Remote 开发者不接收这些内容，也不托管第三方账号凭据。

连接可使用局域网、Tailscale 等私有网络或用户配置的 HTTPS 地址。Mimi Remote 不运营用于查看或保存工作内容的中继服务；网络基础设施提供方可能按照其自身政策处理加密连接所必需的网络元数据。

#### 系统权限

- 相机：仅在用户打开扫码页时读取配对二维码。
- 麦克风与语音识别：仅在用户主动录入语音时使用。语音识别由 Apple 系统能力完成，是否需要联网由设备、语言和系统设置决定，并受 Apple 隐私政策约束。
- 照片与文件：仅处理用户通过系统选择器明确选择的内容；内容随后按用户指令发送到其 Mac 上的运行时。

拒绝上述权限不会阻止用户通过手动输入、键盘输入或其他不需要该权限的方式使用对应核心功能。

#### 保留、删除与撤回权限

- 在 App 的连接管理中选择“忘记连接”或删除连接档案，会删除对应本地配置和 Keychain Token。
- 用户可以在系统设置中随时撤回相机、麦克风、语音识别和本地网络权限。
- 删除 App 会删除其沙盒中的配置和缓存。为确保连接凭据被明确删除，建议先在 App 内忘记所有连接；Keychain 项在卸载后的保留行为由 Apple 操作系统决定。
- Mimi Remote 开发者没有用户账号或云端数据副本，因此没有可由开发者执行的远程数据删除流程。

### 风险与优化

用户应只连接自己拥有或获授权访问的 Mac，并保护连接 Token、审核凭据、项目内容和日志。不要把 Token、真实 Tailnet 地址或私有代码提交到公开 Issue。

如果未来加入账号、云同步、开发者遥测、崩溃上报、远程推送正文或开发者运营的中继服务，本政策和 App Store 隐私披露会在功能上线前同步更新。

隐私问题请联系：`gaixg94@gmail.com`

## English

### Purpose

This policy explains how the Mimi Remote client for iPhone, iPad, and Mac Catalyst handles data. Mimi Remote is an independent third-party developer tool that connects to a Mac you own or are authorized to use. It does not provide AI models, AI subscriptions, cloud code execution, a VPN, or developer-operated project hosting.

### Approach

The developer of Mimi Remote does not collect, upload, sell, or share personal data. The app contains no advertising, third-party analytics SDK, developer-operated telemetry, crash reporting, or traffic proxy.

The app processes the following data only to perform actions you request:

- Connection data: the `agentd` address, connection name, and access token you configure. Tokens are stored in the system Keychain.
- Local state: language, appearance and permission preferences, recent workspaces, session indexes, restoration routes, queued drafts, and diagnostic history.
- Development content: prompts, conversations, code, diffs, images, logs, and tool results travel only between your device and the Mac you configure. They are not sent to the developer of Mimi Remote.
- Local notifications: only routing identifiers needed to open a connection, project, and session are stored. Tokens, message bodies, and working-directory paths are excluded.

### Implementation

#### Your Mac and external tools

Mimi Remote connects directly to an `agentd` endpoint that you enter or import by QR code. On your Mac, `agentd` invokes Codex and, only when you explicitly enable the optional Claude Code bridge, may invoke Claude Code. Those services may process prompts, code, and output under the terms between you and their providers. The developer of Mimi Remote does not receive this content or host third-party account credentials.

Connections may use a local network, a private network such as Tailscale, or an HTTPS endpoint you configure. Mimi Remote does not operate a relay that reads or stores your work. Network infrastructure providers may process network metadata required to carry the encrypted connection under their own policies.

#### System permissions

- Camera: used only while you open the QR pairing scanner.
- Microphone and speech recognition: used only when you actively dictate text. Recognition uses Apple system capabilities; network use depends on the device, language, and system settings and is governed by Apple's privacy policy.
- Photos and files: only items you explicitly choose through system pickers are processed, then sent to the runtime on your Mac as you direct.

Declining a permission does not prevent use of alternatives such as manual pairing or keyboard input.

#### Retention, deletion, and permission withdrawal

- Choosing Forget Connection or deleting a connection profile removes its local configuration and Keychain token.
- You can revoke camera, microphone, speech-recognition, and local-network access in system settings at any time.
- Deleting the app removes configuration and caches in its sandbox. To explicitly remove connection credentials, forget all connections before uninstalling; post-uninstall Keychain behavior is controlled by the Apple operating system.
- Mimi Remote has no developer account system or cloud copy of your data, so there is no remote data copy for the developer to delete.

### Risks and future changes

Connect only to Macs you own or are authorized to use. Protect connection tokens, review credentials, project content, and logs. Never post tokens, real Tailnet addresses, or private code in public issues.

If accounts, cloud sync, developer telemetry, crash reporting, remote notification content, or a developer-operated relay are introduced, this policy and the App Store privacy disclosure will be updated before those features are released.

Privacy contact: `gaixg94@gmail.com`
