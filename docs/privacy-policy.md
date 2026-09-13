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

Mimi Remote 直接连接用户手动输入或扫码导入的 `agentd`。`agentd` 在用户控制的计算机上调用用户自行安装、配置并登录的兼容开发运行时。相关工具可能按照用户与其提供方之间的条款处理提示词、代码和输出。Mimi Remote 开发者不接收这些内容，也不托管第三方账号凭据。

连接可使用局域网、Tailscale 等私有网络或用户配置的 HTTPS 地址。Mimi Remote 不运营用于查看或保存工作内容的中继服务；网络基础设施提供方可能按照其自身政策处理加密连接所必需的网络元数据。

#### 锁屏审批提醒（可选，默认关闭）

「锁屏审批提醒」是默认关闭的实验功能。不开启它时，App 不会请求远程通知授权、不会注册设备 Token，链路上也不会产生任何对外请求；审批仍然只经过用户自己的私有网络。

开启需要用户在 App 内明确同意，且同意绑定到具体的收件主机——中转地址变化后必须重新同意。开启后：

- 会离开设备的只有：本次安装的 APNs 设备 Token、电脑与会话的匿名短标签、审批类型枚举、请求过期时间。
- 不会离开设备的包括：提示词、回复、模型输出、完整命令、文件路径、diff、源码、文件内容、会话历史，以及 `agentd` 访问 Token。
- 用户的「允许」与「拒绝」不经过该服务，仍由设备通过私有网络直接提交给自己的 `agentd`。

该提醒服务由 Mimi Remote 开发者运营。它不保存设备 Token，也不保存通知内容；仅保留已撤销的凭据标识到其自然到期为止（最长 30 天），以及不含请求体的结构化错误日志（7 天）与聚合成功率、延迟指标（30 天）。为完成投递，它会短暂处理请求来源 IP。

关闭开关等价于撤销：App 会注销设备 Token，`agentd` 删除本地凭据，服务端把该凭据标识加入撤销表。这项功能是对此前「不运营任何中转服务」表述的实质变更，因此单独列出并保持默认关闭。

#### 系统权限

- 相机：仅在用户打开配对扫码页，或在消息输入框中明确选择“相机”时使用。拍摄的照片会先在设备上重新编码并作为消息附件处理，不会自动保存到系统照片图库，也不会在后台使用相机。
- 麦克风与语音识别：仅在用户主动录入语音时使用。用户可以选择设备端或 Codex 转写。设备端模式使用系统 SpeechAnalyzer 实时处理；系统可能下载并维护语言模型，但录音不会发送到模型提供方。Codex 模式会把录音发送到用户配置的主机，再由 `agentd` 使用用户自己的 Codex 登录态请求转写；相关处理受用户与服务提供方之间的条款约束。Mimi Remote 开发者不接收这些录音。
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

Mimi Remote connects directly to an `agentd` endpoint that you enter or import by QR code. On your computer, `agentd` invokes compatible developer runtimes that you install, configure, and authenticate. Those tools may process prompts, code, and output under the terms between you and their providers. The developer of Mimi Remote does not receive this content or host third-party account credentials.

Connections may use a local network, a private network such as Tailscale, or an HTTPS endpoint you configure. Mimi Remote does not operate a relay that reads or stores your work. Network infrastructure providers may process network metadata required to carry the encrypted connection under their own policies.

#### Lock Screen approval reminders (optional, off by default)

Lock Screen approval reminders are an experimental feature that is off by default. While it is off, the app does not request remote notification authorization, does not register a device token, and sends nothing to any service; approvals continue to travel only over your own private network.

Turning it on requires your explicit in-app agreement, and that agreement is bound to the specific receiving host — if the address changes, you are asked again. Once on:

- What leaves your device: the APNs device token for this install, anonymous short tags for the Mac and the session, the approval kind as a fixed enum, and the request expiry.
- What never leaves: prompts, replies, model output, full commands, file paths, diffs, source code, file contents, session history, and your `agentd` access token.
- Your allow and deny actions do not pass through the service. They go straight from your device to your own `agentd` over your private network.

The reminder service is operated by the developer of Mimi Remote. It does not store device tokens or notification payloads. It keeps only revoked credential identifiers until they expire (at most 30 days), structured error logs without request bodies (7 days), and aggregate delivery and latency metrics (30 days). It briefly processes the source IP address required to deliver a request.

Turning the switch off revokes the registration: the app unregisters the device token, `agentd` deletes the local credential, and the service adds that credential identifier to its revocation list. Because this is a material change from the earlier statement that no relay is operated at all, it is listed separately and kept off by default.

#### System permissions

- Camera: used only while you open the QR pairing scanner or explicitly choose Camera in the message composer. Captured photos are re-encoded on device and handled as message attachments. They are not automatically saved to your photo library, and the camera is not used in the background.
- Microphone and speech recognition: used only when you actively dictate text. You can choose on-device or Codex transcription. On-device mode uses the system SpeechAnalyzer framework in real time; the system may download and maintain language models, but recordings are not sent to a model provider. Codex mode sends the recording to the host you configured, where `agentd` uses your own Codex session to request transcription under the terms between you and the service provider. The developer of Mimi Remote does not receive these recordings.
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
