# Mimi Remote 隐私政策 / Privacy Policy

生效日期 / Effective date：2026-10-21

## 中文

### 目标

本政策说明 Mimi Remote iPhone、iPad 与 Mac Catalyst 客户端如何处理数据。Mimi Remote 是连接用户自有或获授权电脑（macOS、Windows 或 Linux）开发环境的独立第三方开发者工具，不提供 AI 模型、AI 订阅、云端代码执行、VPN 或开发者运营的项目托管服务。

### 方案

Mimi Remote 不需要 Mimi 账号，不收集邮箱、密码或手机号。App 与电脑端免费开源；局域网、Tailscale 和自建 Tailcat 连接继续免费。可选付费的「Mimi 托管连接」和消息通知服务由开发者运营，仅处理提供相应功能所需的数据。App 不包含广告或第三方分析 SDK，不出售数据，不将数据用于跨 App 或网站追踪。

App 仅在完成用户明确请求时处理以下数据：

- 连接资料：用户配置的 `agentd` 地址、连接名称与访问 Token。Token 保存在系统 Keychain 中。使用实验性 Tailcat 连接时，本机 Tailcat 客户端密钥与连接地址也保存在 Keychain 中。
- 本地状态：语言、外观、权限偏好、最近工作区、会话索引、恢复路由、待发送草稿及诊断历史。
- 开发内容：提示词、会话、代码、Diff、图片、日志和工具结果仅供设备与用户配置的电脑处理。托管中继可能转发其端到端加密数据包，开发者无法读取内容。
- 本地通知：仅保存打开指定连接、项目和会话所需的路由标识，不包含 Token、消息正文或工作目录。

### 实现

#### 用户配置的电脑与外部工具

Mimi Remote 直接连接用户手动输入或扫码导入的 `agentd`。`agentd` 在用户控制的计算机上调用用户自行安装、配置并登录的兼容开发运行时。相关工具可能按照用户与其提供方之间的条款处理提示词、代码和输出。Mimi Remote 开发者不接收这些内容，也不托管第三方账号凭据。

连接可使用局域网、Tailscale 等私有网络、自建 Tailcat、Mimi 托管连接或用户配置的 HTTPS 地址。Mimi Remote 运营的托管中继仅转发端到端加密的数据包，不解密、查看或保存工作内容。其他网络基础设施提供方可能按照其自身政策处理加密连接所必需的网络元数据。

#### 自建 Tailcat 连接（实验性，可选，默认关闭）

App 内置 Tailcat 客户端。Tailcat 是 Tailscale 发布的开源点对点连接库。只有用户在电脑端的 Mimi Remote 中开启 Tailcat 并扫码配对后，App 才会使用这条连接。

- 连接经 WireGuard 端到端加密。每次连接都会先通过 DERP 中继服务器发现对端并完成初始握手，随后在网络允许时将加密流量切换为设备与电脑的点对点直连；无法直连时继续经中继转发。
- 默认中继是 Tailcat 上游提供、由 Tailscale 运营的公共中继；用户也可以在电脑端改为自己配置的中继。Mimi Remote 开发者不运营默认中继，也不接收经中继转发的内容。
- 中继服务器无法读取连接内容，但会处理建立连接及转发所需的网络元数据，例如双方 IP 地址、连接公钥、连接时间和流量大小，并按其运营方的政策处理。即使流量随后转为直连，初始连接阶段也会联系中继并产生这些网络元数据。

#### Mimi 托管连接（可选订阅）

Mimi 托管连接（Mimi Managed Connection）让不在同一 Wi-Fi 的设备连接自己的电脑，无需安装其他联网工具。它包含开发者运营的控制面（核验订阅和管理设备授权的服务）与 DERP 中继。

购买、恢复购买和刷新权益时，App 向控制面发送 Apple 签名的 App 交易与订阅交易数据。控制面验证签名后保存 App 交易标识的 SHA-256 散列、订阅商品与交易标识、购买环境、权益状态、到期与撤销时间，以及状态更新和签名时间。Apple 订阅通知还会留下通知标识、类型、子类型、签名时间与处理结果，用于更新权益和防止重复处理。购买与扣款由 Apple 处理；开发者不接收支付卡资料或 Apple ID 登录凭据。

同一 Apple ID 可以恢复订阅权益。恢复购买不恢复或同步电脑连接地址、Tailcat 私钥或 `agentd` Token；新手机或平板需要对每台电脑重新接入。

登记、配对和管理设备时，控制面处理随机安装编号、设备类型、设备与主机编号、双方连接公钥（包括临时配对节点公钥）、配对请求与会话编号，以及专用于托管连接的授权凭据。保存的安装编号与授权凭据为 SHA-256 散列；控制面还保存登记、配对、授权关系、策略版本和相关创建、到期、完成或撤销时间。这些记录可关联同一订阅及其设备，不等于无法关联个人的数据。控制面不接收 Tailcat 私钥、完整连接地址、`agentd` Token、提示词、代码、对话或文件内容。

为诊断连接可用性，App 发送随机事件编号、连接路径、成功或失败、耗时区间、粗粒度错误分类、适用时的中继区域代码和 App 版本。控制面记录接收时间；事件记录不保存订阅编号、设备编号或 IP 地址。中继区域代码表示中继位置，不是设备定位。事件按 30 天保留窗口每日清理，超过窗口的记录在下一次清理时删除。

数据连接使用 Tailcat，通过 WireGuard 端到端加密。能直连时点对点传输，否则由 Mimi 运营的 DERP 中继转发。中继无法读取内容，但会处理双方 IP 地址、连接公钥、连接时间和流量大小。官方中继只接受有效订阅下已登记并获授权的设备节点，包括有效配对期间的临时节点。

控制面应用关闭常规请求日志，但会记录服务错误用于排障。目前订阅、设备、配对、节点归属、授权凭据散列和 Apple 通知记录没有按时间自动清理的机制。凭据与配对授权的有效期只限制其使用，不代表到期后删除历史记录。

在 App 的「Mimi 托管连接」设备列表中移除设备，会撤销其托管授权并释放名额，相关电脑授权在策略更新或现有策略失效后停止生效。移除不会抹除控制面的登记和配对历史，也不会删除电脑上的项目或会话。建议在订阅有效期内移除不再使用的设备；权益到期或撤销后，当前设备管理功能也不可用。

取消自动续费不会立即删除记录或立即终止已付费期间的权益。权益到期且无有效宽限期，或权益被撤销后，控制面停止提供托管授权；历史记录仍按上述方式保留。卸载 App、忘记本地电脑连接或取消订阅均不等于删除控制面记录。需要就这些记录提出隐私或删除请求时，请通过本政策末尾的邮箱联系开发者；目前没有一键删除全部控制面历史的功能。

#### 消息通知

消息通知默认开启。首次成功连接电脑后，App 请求系统通知权限；允许后注册通知服务。用户可以在 App 设置关闭消息通知，也可以在系统设置管理通知权限。旧版明确关闭的选择会保留。

官方通知服务不需要额外授权弹窗。自定义服务需要确认具体服务地址，地址变化后重新确认。开启后：

- 发送给该服务的只有：本次安装的 APNs 设备 Token（服务把它换成加密的推送凭据，由电脑保存）、随机安装编号与一次性通知编号、电脑与会话的匿名短标签、运行时类型（Codex 或 Claude）、事件类型枚举（如待审批、任务完成、失败或中断）、审批类型枚举、请求过期时间。
- 不会离开设备的包括：提示词、回复、模型输出、完整命令、文件路径、diff、源码、文件内容、会话历史，以及 `agentd` 访问 Token。
- 用户的「允许」与「拒绝」不经过该服务，仍由设备通过私有网络直接提交给自己的 `agentd`。

该提醒服务由 Mimi Remote 开发者运营。它不保存设备 Token，也不保存通知内容；仅保留已撤销的凭据标识到其自然到期为止（最长 30 天），以及不含请求体的结构化错误日志（7 天）与聚合成功率、延迟指标（30 天）。为完成投递，它会短暂处理请求来源 IP。

关闭开关后，App 立即停止本地自动任务通知，并注销远程通知。远程注销失败时保留必要凭据以便重试，设置页显示“远程通知关闭未完成”。关闭不会影响会话内审批，也不会取消用户主动设置的定时会话提醒。

#### 锁屏与灵动岛实时活动

实时活动默认开启，并跟随消息通知：消息通知关闭时，实时活动不会启动或更新。也可以在 App 设置里单独关闭。开启后：

- 发送给通知服务的只有：系统为实时活动分配的推送 Token（同样换成加密的推送凭据，由电脑保存）、状态枚举（运行中、待你处理、已完成、失败）、运行中与待你处理的会话数、本轮开始时间，以及电脑与会话的匿名短标签。
- 会话标题、项目名和电脑名从设备上的本机缓存读取，只在本机显示，不发送给通知服务或 Apple。
- 关闭开关、关闭消息通知或删除对应的电脑时，App 会结束锁屏上的实时活动，并撤销相关推送凭据。

通知服务处理和保留这些请求的方式与消息通知相同。

#### 系统权限

- 相机：仅在用户打开配对扫码页，或在消息输入框中明确选择“相机”时使用。拍摄的照片会先在设备上重新编码并作为消息附件处理，不会自动保存到系统照片图库，也不会在后台使用相机。
- 麦克风与语音识别：仅在用户主动录入语音时使用。用户可以选择设备端或 Codex 转写。设备端模式使用系统 SpeechAnalyzer 实时处理；系统可能下载并维护语言模型，但录音不会发送到模型提供方。Codex 模式会把录音发送到用户配置的主机，再由 `agentd` 使用用户自己的 Codex 登录态请求转写；相关处理受用户与服务提供方之间的条款约束。Mimi Remote 开发者不接收这些录音。
- 照片与文件：仅处理用户通过系统选择器明确选择的内容；内容随后按用户指令发送到其电脑上的运行时。
- 添加到照片图库：仅在用户于「加入用户群」页点击保存时，把开发者微信二维码写入照片图库。App 只申请添加权限，不读取图库内容。

拒绝上述权限不会阻止用户通过手动输入、键盘输入或其他不需要该权限的方式使用对应核心功能。

#### 保留、删除与撤回权限

- 在 App 的「设备」页（或设置中的「电脑连接」）选择「忘记这台电脑」或删除连接档案，会删除对应本地配置和 Keychain Token。
- 用户可以在系统设置中随时撤回相机、麦克风、语音识别、照片和本地网络权限。
- 删除 App 会删除其沙盒中的配置和缓存。为确保连接凭据被明确删除，建议先在 App 内忘记所有连接；Keychain 项在卸载后的保留行为由 Apple 操作系统决定。
- Mimi Remote 不托管工作内容。托管连接的服务记录与移除设备的处理见上文；本地删除不会自动删除这些服务记录。

### 风险与优化

用户应只连接自己拥有或获授权访问的电脑，并保护连接 Token、审核凭据、项目内容和日志。不要把 Token、真实 Tailnet 地址或私有代码提交到公开 Issue。

如果未来加入账号、云同步、其他遥测、崩溃上报或远程推送正文，本政策和 App Store 隐私披露会在功能上线前同步更新。

隐私问题请联系：`gaixg94@gmail.com`

## English

### Purpose

This policy explains how the Mimi Remote client for iPhone, iPad, and Mac Catalyst handles data. Mimi Remote is an independent third-party developer tool that connects to a computer (macOS, Windows, or Linux) you own or are authorized to use. It does not provide AI models, AI subscriptions, cloud code execution, a VPN, or developer-operated project hosting.

### Approach

Mimi Remote requires no Mimi account and does not collect email addresses, passwords, or phone numbers. The app and computer software are free and open source; local-network, Tailscale, and self-hosted Tailcat connections remain free. The optional paid Mimi Managed Connection and message notification service are operated by the developer and process data needed for those features. The app contains no advertising or third-party analytics SDK, does not sell data, and does not use data for tracking across apps or websites.

The app processes the following data only to perform actions you request:

- Connection data: the `agentd` address, connection name, and access token you configure. Tokens are stored in the system Keychain. When you use the experimental Tailcat connection, the app's Tailcat client key and connection address are also stored in the Keychain.
- Local state: language, appearance and permission preferences, recent workspaces, session indexes, restoration routes, queued drafts, and diagnostic history.
- Development content: prompts, conversations, code, diffs, images, logs, and tool results are processed only by your device and the computer you configure. The managed relay may forward their end-to-end encrypted packets; the developer cannot read the content.
- Local notifications: only routing identifiers needed to open a connection, project, and session are stored. Tokens, message bodies, and working-directory paths are excluded.

### Implementation

#### Your computer and external tools

Mimi Remote connects directly to an `agentd` endpoint that you enter or import by QR code. On your computer, `agentd` invokes compatible developer runtimes that you install, configure, and authenticate. Those tools may process prompts, code, and output under the terms between you and their providers. The developer of Mimi Remote does not receive this content or host third-party account credentials.

Connections may use a local network, a private network such as Tailscale, self-hosted Tailcat, Mimi Managed Connection, or an HTTPS endpoint you configure. Mimi Remote's managed relay only forwards end-to-end encrypted packets; it does not decrypt, view, or store your work content. Other network infrastructure providers may process metadata needed for encrypted connections under their own policies.

#### Self-hosted Tailcat connection (experimental, optional, off by default)

The app includes a Tailcat client. Tailcat is an open-source peer-to-peer connection library published by Tailscale. The app uses this connection only after you turn on Tailcat in Mimi Remote on your computer and pair by scanning its QR code.

- The connection is end-to-end encrypted with WireGuard. Every connection first uses a DERP relay server for peer discovery and the initial handshake, then switches encrypted traffic to a direct peer-to-peer path when available. Otherwise, the relay continues forwarding that traffic.
- By default, the relay is the public relay provided by the Tailcat project and operated by Tailscale. You can switch to a relay you configure on your computer. The developer of Mimi Remote does not operate the default relay and does not receive content forwarded through it.
- Relay servers cannot read the connection content, but they process network metadata needed to establish and relay the connection, such as both peers' IP addresses, connection public keys, connection times, and traffic volume, under their operator's policies. The initial connection phase contacts the relay and produces this metadata even when traffic later moves to a direct path.

#### Mimi Managed Connection (optional subscription)

Mimi Managed Connection lets your devices connect to your own computer when they are on different Wi-Fi networks, without installing another networking tool. It includes a developer-operated control service for subscription verification and device authorization, and a DERP relay.

When purchasing, restoring purchases, or refreshing entitlements, the app sends Apple-signed app and subscription transaction data to the control service. After verifying the signatures, the service stores a SHA-256 hash of the app transaction identifier, subscription product and transaction identifiers, purchase environment, entitlement status, expiry and revocation times, and state update and signature times. Apple subscription notifications also produce records of notification identifiers, types, subtypes, signature times, and processing outcomes to update entitlements and prevent duplicate processing. Apple handles purchases and billing; the developer does not receive payment card details or Apple ID sign-in credentials.

You can restore subscription entitlements with the same Apple ID. Restoring purchases does not restore or sync computer connection addresses, Tailcat private keys, or `agentd` tokens. A new phone or tablet must connect to each computer again.

During device registration, pairing, and management, the control service processes random installation identifiers, device types, device and host identifiers, both peers' connection public keys (including temporary pairing node public keys), pairing request and session identifiers, and credentials dedicated to managed connection authorization. Stored installation identifiers and authorization credentials are SHA-256 hashes. The service also stores registration, pairing and authorization relationships, policy versions, and related creation, expiry, completion, or revocation times. These records can link the same subscription and its devices; they are not unlinked personal data. The control service does not receive Tailcat private keys, complete connection addresses, `agentd` tokens, prompts, code, conversations, or file contents.

To diagnose connection availability, the app sends a random event identifier, connection path, success or failure, duration range, coarse error category, relay region code when applicable, and app version. The control service records receipt times; event records do not store subscription identifiers, device identifiers, or IP addresses. The relay region code describes the relay's location, not the device's location. Events use a 30-day retention window with daily cleanup; records outside that window are deleted on the next cleanup run.

Data connections use Tailcat with WireGuard end-to-end encryption. Traffic travels directly between peers when possible; otherwise, a DERP relay operated by Mimi forwards it. The relay cannot read content but processes both peers' IP addresses, connection public keys, connection times, and traffic volume. Official relays accept only registered and authorized device nodes under a valid subscription, including temporary nodes during valid pairing sessions.

The control service application disables routine request logging but records service errors for troubleshooting. Subscription, device, pairing, node ownership, authorization credential hash, and Apple notification records currently have no time-based automatic cleanup mechanism. Credential and pairing authorization expiry limits their use; it does not delete historical records.

Removing a device from the Mimi Managed Connection device list in the app revokes its managed authorization and releases its slot. Related computer authorization stops taking effect after a policy update or expiry of the existing policy. Removal does not erase control-service registration or pairing history, or delete projects or sessions on the computer. Remove unused devices while your subscription is valid; current device management is also unavailable after entitlements expire or are revoked.

Canceling auto-renewal does not immediately delete records or end access for a paid period. Once entitlements expire without a valid grace period, or are revoked, the control service stops granting managed authorization; historical records remain as described above. Uninstalling the app, forgetting a local computer connection, or canceling the subscription does not delete control-service records. Contact the developer at the email address below for privacy or deletion requests about these records. There is currently no one-step feature to delete all control-service history.

#### Message notifications

Message notifications are enabled by default. After the first successful computer connection, the app requests system notification permission and registers when allowed. You can turn message notifications off in the app or manage permission in system settings. Explicit off settings from earlier versions are preserved.

The official notification service does not require an additional agreement dialog. Custom service addresses require confirmation, including when the address changes. When enabled:

- What the service receives: the APNs device token for this install (exchanged for an encrypted push credential that your computer stores), random installation and one-time notification identifiers, anonymous short tags for the computer and the session, the runtime type (Codex or Claude), the event type as a fixed enum (such as approval pending, task completed, failed, or interrupted), the approval kind as a fixed enum, and the request expiry.
- What never leaves: prompts, replies, model output, full commands, file paths, diffs, source code, file contents, session history, and your `agentd` access token.
- Your allow and deny actions do not pass through the service. They go straight from your device to your own `agentd` over your private network.

The reminder service is operated by the developer of Mimi Remote. It does not store device tokens or notification payloads. It keeps only revoked credential identifiers until they expire (at most 30 days), structured error logs without request bodies (7 days), and aggregate delivery and latency metrics (30 days). It briefly processes the source IP address required to deliver a request.

Turning the switch off immediately stops automatic local task notifications and revokes remote registration. If revocation fails, the app retains the credentials needed to retry and reports that remote notifications have not been fully turned off. In-app approvals and manually scheduled session reminders remain available.

#### Lock Screen and Dynamic Island Live Activities

Live Activities are on by default and follow message notifications: when message notifications are off, Live Activities neither start nor update. You can also turn them off separately in the app. When enabled:

- What the notification service receives: the push tokens the system assigns for Live Activities (also exchanged for encrypted push credentials that your computer stores), the status as a fixed enum (running, needs you, completed, or failed), the number of running sessions and of sessions waiting for you, the start time of the current round, and anonymous short tags for the computer and the session.
- Session titles, project names, and computer names are read from a cache on your device and shown only there. They are not sent to the notification service or to Apple.
- Turning the switch off, turning message notifications off, or removing the computer ends the Live Activity on your Lock Screen and revokes the related push credentials.

The notification service handles and retains these requests in the same way as message notifications.

#### System permissions

- Camera: used only while you open the QR pairing scanner or explicitly choose Camera in the message composer. Captured photos are re-encoded on device and handled as message attachments. They are not automatically saved to your photo library, and the camera is not used in the background.
- Microphone and speech recognition: used only when you actively dictate text. You can choose on-device or Codex transcription. On-device mode uses the system SpeechAnalyzer framework in real time; the system may download and maintain language models, but recordings are not sent to a model provider. Codex mode sends the recording to the host you configured, where `agentd` uses your own Codex session to request transcription under the terms between you and the service provider. The developer of Mimi Remote does not receive these recordings.
- Photos and files: only items you explicitly choose through system pickers are processed, then sent to the runtime on your computer as you direct.
- Adding to the photo library: only when you tap Save on the Join the User Group screen, the developer's WeChat QR code is written to your photo library. The app requests add-only access and does not read your library.

Declining a permission does not prevent use of alternatives such as manual pairing or keyboard input.

#### Retention, deletion, and permission withdrawal

- Choosing Forget this computer from the Devices tab (or Computer connection in Settings), or deleting a connection profile, removes its local configuration and Keychain token.
- You can revoke camera, microphone, speech-recognition, photos, and local-network access in system settings at any time.
- Deleting the app removes configuration and caches in its sandbox. To explicitly remove connection credentials, forget all connections before uninstalling; post-uninstall Keychain behavior is controlled by the Apple operating system.
- Mimi Remote does not host your work content. Service records and device removal for managed connections are described above; deleting local data does not automatically delete those service records.

### Risks and future changes

Connect only to computers you own or are authorized to use. Protect connection tokens, review credentials, project content, and logs. Never post tokens, real Tailnet addresses, or private code in public issues.

If accounts, cloud sync, other telemetry, crash reporting, or remote notification content are introduced, this policy and the App Store privacy disclosure will be updated before those features are released.

Privacy contact: `gaixg94@gmail.com`
