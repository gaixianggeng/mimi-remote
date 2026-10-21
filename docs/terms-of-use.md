# Mimi Remote 使用条款 / Terms of Use

生效日期 / Effective date：2026-10-21

## 中文

### 目标

Mimi Remote 是连接用户自有或获授权电脑（macOS、Windows 或 Linux）开发环境的原生客户端。安装或使用 Mimi Remote 官方发行版，即表示你就该产品的使用行为同意本条款；不同意时请停止使用该发行版。接收、运行、修改和传播 GPL 覆盖代码的权利由适用的开源许可证独立授予，不以接受本使用条款为条件。

### 方案

- Mimi Remote 的 App 与电脑端免费开源，局域网、Tailscale 和自建 Tailcat 连接继续免费。可选付费的「Mimi 托管连接」提供订阅核验、设备授权及必要时的加密中继。自建 Tailcat 的默认公共中继由 Tailscale 运营；托管连接的中继由 Mimi 运营。中继处理网络元数据，无法读取端到端加密的工作内容，详见[隐私政策](privacy-policy.md)。Mimi Remote 不提供 AI 模型、AI 账号、AI 订阅、云端代码执行或项目托管服务。
- 用户自行安装、配置和维护电脑上的 `agentd`（Mimi Remote 宿主）、Codex，以及可选的 Claude Code、DeepSeek Harness 等运行时，并自行承担相关账号、网络和第三方服务费用。第三方运行时的使用须遵守其提供方条款。
- 用户只能连接自己拥有或已获明确授权访问的设备、项目和账号。

### 实现

#### Mimi 托管连接订阅

- 名称为「Mimi 托管连接」（Mimi Managed Connection），通过 App 内购买提供自动续期订阅。月付期限为 1 个月，中国大陆 ¥9.9、美国 US$1.99；年付期限为 1 年，中国大陆 ¥68、美国 US$9.99。所有 App Store 地区均提供，其余地区由 Apple 换算。实际价格、币种、税费及扣款以 Apple 购买确认页为准。不提供终身买断，不支持家人共享。
- 两个方案均提供 7 天免费试用。每个 Apple ID 在本订阅组内只能享受一次试用，资格由 Apple 判断。试用结束后按所选方案自动转为付费订阅，除非提前取消。为避免扣款，请至少在试用结束前 24 小时取消。
- Apple 通过你的 Apple 账户处理付款。订阅自动续期，除非在当前周期结束前至少 24 小时关闭自动续费；续期费用会在当前周期结束前 24 小时内扣取。可在系统「设置 → Apple 账户 → 订阅」中管理或取消。卸载 App 或移除设备不会取消订阅；取消续费后，已付费权益通常持续至当前周期结束，以 Apple 显示的到期时间为准。
- 退款申请由 Apple 按其[退款政策和流程](https://support.apple.com/zh-cn/118223)处理，并受适用的消费者保护法律约束。开发者无法代替 Apple 扣款或批准退款。
- 每个订阅最多登记 3 台电脑和 5 台手机或平板。可在 App 内移除设备以释放名额；移除会撤销托管授权，不会删除电脑上的项目或会话。请在权益有效期内管理设备。无需 Mimi 账号；使用同一 Apple ID 可恢复订阅权益，但不会同步连接地址、私钥或 `agentd` Token，新手机或平板需要对每台电脑重新接入。
- 托管连接需要一台运行 Mimi 的电脑和双方可用的网络。维护、网络限制、Apple 服务或设备状态可能导致中断；不承诺始终直连、固定速度、固定延迟或无中断可用。权益到期且无有效宽限期，或权益被撤销后，托管授权停止；免费连接方式仍可使用。
- 订阅只用于访问自己拥有或获授权的电脑。不得转售托管连接、共享或出租设备授权、绕过名额或订阅校验、攻击服务、转发他人无关流量或用于未经授权的访问。为阻止上述滥用，可限制或暂停相关托管服务；适用法律赋予的权利不受影响。
- 服务内容、价格或可用范围如需变更或停止，将通过 App 或公开公告说明影响及生效时间，并按适用法律和 Apple 规则处理。计划停止服务时会提前通知，停止新增订阅和后续续费，并说明剩余已付费期间的处理方式与 Apple 退款申请渠道；不承诺服务永久运营。适用法律要求的退款或其他救济不受影响。

用户不得使用 Mimi Remote 未经授权访问设备或数据、侵犯知识产权、规避安全控制、传播恶意软件，或从事违反适用法律和第三方服务条款的活动。用户应妥善保护连接 Token、设备、代码仓库和第三方账号，并在共享日志或截图前移除敏感信息。

Codex、Claude Code、DeepSeek Harness、Tailscale、Tailcat、GitHub、MCP Server 及其他外部工具由各自提供方运营并适用其各自条款。Mimi Remote 是独立第三方客户端，不隶属于或代表这些提供方，也不承诺外部服务持续可用或保持协议兼容。

开源代码与本使用条款分层适用。Mimi Remote 自有源码按 [GNU GPLv3 与商店分发额外许可](../LICENSE)提供，第三方组件继续适用各自许可证。任何人都可以在遵守适用许可证的前提下商业使用或收费分发。向第三方分发 GPL 覆盖的修改作品或目标代码时，必须针对该 GPL 覆盖作品履行 GPLv3 要求，包括保留适用声明、在适用时标记修改、确保接收者取得 GPLv3 规定的权利，并按 GPLv3 要求提供对应源码或合规的源码获取方式；不得把该覆盖作品作为不向接收者提供这些权利或源码获取方式的闭源产品分发。独立作品和第三方组件仍适用各自许可证。

本条款不减少适用开源许可证授予的权利。两者就某一开源组件发生冲突时，以该组件的开源许可证为准；停止使用 App 也不会撤销已经根据开源许可证取得的代码权利。此前已经明确按 MIT License 发布的历史版本继续受其原有许可。

源码许可证不授予 Mimi Remote 产品名称、Logo、App 图标或官方发行身份的额外使用权。商标和来源识别规则不是复制、运行、修改或分发代码的额外许可条件；但面向用户的修改版产品或发行物如果使用项目标识，该使用必须遵守[商标与品牌使用政策](../TRADEMARKS.md)。未经书面授权，其主要品牌和发行身份应保持独立，并且不得暗示由 Mimi Remote 官方维护者发布、认可或支持。如实说明来源、兼容性以及保留许可证要求的归属声明不受影响。

### 风险与优化

在适用法律允许的最大范围内，Mimi Remote 按现状提供，不保证无中断、无错误或适合特定目的。新会话默认使用「完全文件访问」权限档位，此时 Agent 在电脑上执行命令、修改文件和访问网络时不会逐条请求审批；需要逐条确认时，请在 App 设置中把默认权限改为「请求审批」或「只读」。用户应在批准代码修改、命令、Git 操作和删除操作前检查内容，并自行维护备份。风险说明见 [SECURITY.md](../SECURITY.md)。开发者不对第三方服务、用户配置的主机或未经授权的使用负责。

条款可能因产品能力或法律要求变化而更新，更新版本会公布在同一地址并修改生效日期。问题请联系：`gaixg94@gmail.com`

## English

### Purpose

Mimi Remote is a native client for a development environment on a computer (macOS, Windows, or Linux) that you own or are authorized to use. By installing or using an official Mimi Remote distribution, you agree to these Terms as they apply to product use. If you do not agree, stop using that distribution. Your rights to receive, run, modify, and propagate GPL-covered code are granted independently by the applicable open-source licenses and do not depend on accepting these Terms.

### Approach

- The Mimi Remote app and computer software are free and open source. Local-network, Tailscale, and self-hosted Tailcat connections remain free. Optional paid Mimi Managed Connection provides subscription verification, device authorization, and encrypted relaying when needed. The default public relay for self-hosted Tailcat is operated by Tailscale; managed connection relays are operated by Mimi. Relays process network metadata but cannot read end-to-end encrypted work content. See the [Privacy Policy](privacy-policy.md). Mimi Remote does not provide AI models, AI accounts, AI subscriptions, cloud code execution, or project hosting.
- You install, configure, and maintain `agentd` (the Mimi Remote host), Codex, and any optional runtimes such as Claude Code or DeepSeek Harness on your computer, and you are responsible for related accounts, networking, and third-party charges. Your use of third-party runtimes is subject to their providers' terms.
- You may connect only to devices, projects, and accounts that you own or have explicit authorization to access.

### Implementation

#### Mimi Managed Connection subscription

- Mimi Managed Connection is an auto-renewable in-app subscription. The monthly plan lasts 1 month and costs ¥9.9 in mainland China or US$1.99 in the United States. The annual plan lasts 1 year and costs ¥68 in mainland China or US$9.99 in the United States. It is offered in all App Store regions, with prices converted by Apple elsewhere. The actual price, currency, taxes, and charge are shown on Apple's purchase confirmation screen. There is no lifetime purchase or Family Sharing.
- Both plans offer a 7-day free trial. Each Apple ID may use a trial only once within this subscription group; Apple determines eligibility. Unless canceled in advance, the trial converts to a paid subscription at the selected plan's price. Cancel at least 24 hours before the trial ends to avoid being charged.
- Apple handles payment through your Apple Account. Subscriptions renew automatically unless auto-renewal is turned off at least 24 hours before the current period ends. Renewal is charged within 24 hours before that period ends. Manage or cancel in system Settings → Apple Account → Subscriptions. Uninstalling the app or removing a device does not cancel a subscription. After canceling renewal, paid access normally continues until the current period ends, subject to the expiry shown by Apple.
- Apple handles refund requests under its [refund policies and process](https://support.apple.com/en-us/118223), subject to applicable consumer-protection law. The developer cannot charge you or approve refunds on Apple's behalf.
- Each subscription supports up to 3 computers and 5 phones or tablets. Remove devices in the app to release slots; removal revokes managed authorization without deleting projects or sessions on your computer. Manage devices while your entitlements remain valid. No Mimi account is required. You can restore subscription entitlements with the same Apple ID, but connection addresses, private keys, and `agentd` tokens do not sync. A new phone or tablet must connect to each computer again.
- Managed connection requires a computer running Mimi and working networks on both devices. Maintenance, network restrictions, Apple services, or device conditions may interrupt access. There is no guarantee of direct connectivity, fixed speed or latency, or uninterrupted availability. Managed authorization stops when entitlements expire without a valid grace period, or are revoked. Free connection methods remain available.
- Use the subscription only to access computers you own or are authorized to use. Do not resell managed connections, share or rent device authorizations, bypass device limits or subscription verification, attack the service, relay unrelated third-party traffic, or access resources without authorization. Related managed service access may be restricted or suspended to prevent such abuse; rights granted by applicable law remain unaffected.
- Changes to or discontinuation of service features, pricing, or availability will be announced in the app or publicly, with their impact and effective date, and handled under applicable law and Apple's rules. A planned shutdown will be announced in advance, with new subscriptions and subsequent renewals stopped and instructions for remaining paid periods and Apple's refund process. Permanent service operation is not guaranteed. Refunds and other remedies required by applicable law remain unaffected.

You must not use Mimi Remote to access devices or data without authorization, infringe intellectual-property rights, bypass security controls, distribute malware, or violate applicable law or third-party terms. Protect connection tokens, devices, repositories, and third-party accounts, and remove sensitive information before sharing logs or screenshots.

Codex, Claude Code, DeepSeek Harness, Tailscale, Tailcat, GitHub, MCP servers, and other external tools are operated under their providers' terms. Mimi Remote is an independent third-party client; it is not affiliated with or acting on behalf of those providers and does not guarantee their availability or continued protocol compatibility.

Open-source code and these Terms apply at separate layers. Mimi Remote-owned source code is provided under [GNU GPLv3 with the additional store-distribution permission](../LICENSE), while third-party components remain subject to their own licenses. Anyone may use the software commercially or charge for distribution while complying with the applicable licenses. If you distribute a GPL-covered modified work or object code to another party, you must meet GPLv3's requirements for that covered work, including preserving applicable notices, marking changes when required, ensuring recipients receive the rights provided by GPLv3, and providing Corresponding Source or a GPLv3-compliant way to obtain it. You may not distribute that covered work as a closed-source product that withholds those rights or the required access to Corresponding Source. Independent works and third-party components remain governed by their own licenses.

These Terms do not reduce rights granted by an applicable open-source license. If they conflict for an open-source component, that component's open-source license controls. Stopping use of the app does not revoke code rights already obtained under an open-source license. Historical versions previously released under the MIT License remain governed by that license.

The source-code licenses do not grant additional rights to the Mimi Remote product name, logo, app icon, or official-distribution identity. Trademark and source-identification rules are not additional conditions on permission to copy, run, modify, or distribute the code. If a user-facing modified product or distribution uses Project Marks, that use must comply with the [Trademark and Brand Policy](../TRADEMARKS.md). Without written permission, its primary brand and distribution identity must remain independent and must not imply that it is published, endorsed, or supported by the official Mimi Remote maintainers. Truthful source or compatibility references and attribution notices required by the licenses remain permitted.

### Risks and future changes

To the maximum extent permitted by applicable law, Mimi Remote is provided as-is, without a guarantee of uninterrupted or error-free operation or fitness for a particular purpose. New sessions use the Full File Access permission mode by default. In that mode, agents run commands, change files, and access the network on your computer without asking for approval each time. To confirm actions one by one, change Default permissions in the app's settings to Ask for Approval or Read Only. Review code changes, commands, Git operations, and deletion actions before approval, and maintain your own backups. See [SECURITY.md](../SECURITY.md) for the risks. The developer is not responsible for third-party services, user-configured hosts, or unauthorized use.

These terms may be updated as the product or legal requirements change. Updates will be published at this address with a revised effective date. Contact: `gaixg94@gmail.com`
