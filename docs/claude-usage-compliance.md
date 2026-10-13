# Claude 用量查询合规分析

检索日期：2026-10-12（#684）

本文整理 Mimi Remote 获取 Claude 额度（5 小时 / 7 天使用率）的实际实现，对照 Anthropic 当时公开的条款与文档，给出工程侧的风险评估和可选方案，供维护者决定。本文不是法律意见；Anthropic 的页面可能随时更新，结论以检索当日内容为准。

## 目标

- 说明 Claude 额度数据从哪里来，是否读取、缓存或外发 Claude 登录凭据。
- 对照 Anthropic 公开规定，标出与之存在张力的行为。
- 列出可选方案和需要维护者决定的事项。

## 结论摘要

- **默认路径风险较低。** Mac App 与 Windows 安装包默认使用基于 Claude Agent SDK 的适配器 `mimi-claude-adapter`。它只使用 Claude Code 在会话中自己上报的额度事件，不读取凭据，也不另外调用接口。
- **旧 bridge 风险较高。** Linux 与 Homebrew 宿主当前使用旧 Rust bridge，Mac App 与 Windows 打开 `claude.legacy_bridge` 回退时也会用它。客户端请求额度时，它会从本机取出 Claude Code 的 OAuth access token，在 Claude Code 之外调用未公开的用量接口，并使用 Claude Code 的 User-Agent。这与 Anthropic 关于 OAuth 用途和第三方处理凭据的公开表述存在直接张力。
- **整个 Claude 通道还有一个总体性问题待确认。** Agent SDK 文档写明，除非事先获批，第三方产品不得提供 claude.ai 登录或额度。Mimi Remote 不提供登录流程，只驱动用户自己安装并登录、未经修改的 Claude Code，这是较有利的事实，但公开材料没有对这种用法给出明确结论。
- **建议：** 优先移除旧 bridge 的 OAuth 用量查询，或改为默认关闭；同时去掉模拟 Claude Code 的 User-Agent。Claude 通道整体的条款适配随 #660 正式发布前一并确认。

## 代码实际行为

### 默认：Claude SDK 适配器

- 代码：`bridges/claude-sdk/src/runtime/rateLimits.ts`、`bridges/claude-sdk/src/handlers/account.ts`。
- `account/rateLimits/read` 返回会话中最近一次观测到的 `rate_limit_event`（5 小时与 7 天窗口）。适配器启动后还没跑过回合时，返回“不可用”，不显示为 0%。
- 不读取 `~/.claude` 下的凭据文件或系统钥匙串，不发起额外网络请求。模型调用全部由用户自行安装、未经修改的 Claude Code，以用户本人的登录完成。
- 随附范围：Mac App 与 Windows 安装包。

### 旧 Rust bridge

- 代码：`bridges/claude/crates/claude-bridge/src/oauth_usage.rs`、`bridges/claude/crates/claude-bridge/src/handlers/lifecycle.rs`。
- 触发条件：只在客户端请求 `account/rateLimits/read` 时执行，例如 iOS 设置页的“AI 用量”或 Mac 菜单栏刷新运行时状态。成功结果在内存缓存 5 分钟，两次实际查询至少间隔 15 秒，整条链路最多 12 秒。
- 读取凭据：先读 `~/.claude/.credentials.json`（文件对组或其他用户可读时拒绝使用），再读 macOS 钥匙串中 Claude Code 的条目（调用 `/usr/bin/security`）。只读，不刷新、不写回 token。收到 401 时重新读取一次，以使用 Claude Code 刚轮换的凭据。
- 发出请求：通过 `curl` 向 `https://api.anthropic.com/api/oauth/usage` 发送 GET，携带 `Authorization: Bearer <access token>`、`anthropic-beta: oauth-2025-04-20` 和 `User-Agent: claude-code/2.1.0`。token 经 stdin 交给 `curl`，不出现在进程参数中。
- 凭据去向：只发往 `api.anthropic.com`。不写磁盘、不进日志，也不发给 iOS、`agentd` 或任何 Mimi Remote 开发者运营的服务。内存只缓存额度快照，不缓存 token。
- 随附范围：Linux 归档与 Homebrew（二者不随附 SDK 适配器）。Mac App 与 Windows 安装包也随附旧 bridge，打开 `claude.legacy_bridge` 时使用。
- 接口性质：在 Anthropic 公开 API 文档中未查到 `api/oauth/usage`，它是 Claude Code 自身使用的接口。

### agentd

- 只通过官方 CLI 的 `claude auth status` 判断登录状态（`internal/setup/claude.go`），不读取凭据文件。

## Anthropic 公开规定

以下为检索日期当天的页面要点，均为转述。

| 来源 | 与本问题相关的要点 |
| --- | --- |
| [Claude Code：Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance) | OAuth 认证供订阅用户在 Claude Code 及其他 Anthropic 原生应用中正常使用。开发者构建产品（包括基于 Agent SDK 的产品）应使用 Claude Console 或受支持云厂商的 API key。第三方开发者不得在自己的应用中提供 Claude.ai 登录，不得代用户经 Free / Pro / Max 凭据路由请求，也不得收集、存储或中转 Claude.ai 凭据或会话 token。这些限制不妨碍终端用户用自己的订阅登录未经修改的 Claude Code。Anthropic 保留不经事先通知执行这些限制的权利。Pro / Max 宣传的额度以普通、个人地使用 Claude Code 和 Agent SDK 为前提。 |
| [Agent SDK overview](https://code.claude.com/docs/en/agent-sdk/overview) | 除非事先获批，Anthropic 不允许第三方开发者为其产品（包括基于 Agent SDK 构建的 agent）提供 claude.ai 登录或额度，应改用 API key 认证。Agent SDK 的使用受 Anthropic Commercial Terms 约束。 |
| [Consumer Terms of Service](https://www.anthropic.com/legal/consumer-terms)（页面标注 2025-10-08 生效） | 第 3 节：除通过 Anthropic API key 或另有明确许可外，不得以 bot、脚本等自动化或非人工方式访问服务。第 2 节：不得与他人共享账号登录信息或凭据。 |
| [Usage Policy](https://www.anthropic.com/legal/aup)（检索时页面标注 2026-11-12 生效） | 不得故意绕过或干扰产品内设立的能力、限制或防护；不得以未授权方式转售、代理或提供 Claude 访问，示例包括经消费者订阅路由请求的服务。 |
| [Agent SDK TypeScript 参考](https://code.claude.com/docs/en/agent-sdk/typescript) | 在 SDK 会话中发送 `/usage` 时，Claude Code 会在回复上附带结构化的 `usage_report`（Agent SDK v0.3.273 起，类型标为实验性），其中包含订阅额度；需要 claude.ai 凭据且带 `user:profile` scope。 |
| [Claude Code statusline](https://code.claude.com/docs/en/statusline) | statusline 输入包含 `rate_limits.five_hour` / `seven_day` 的使用百分比与重置时间，仅对 Pro / Max 订阅、且在会话收到首个 API 响应后出现。 |
| `api/oauth/usage` 的公开文档 | 未查到。 |
| 针对“第三方程序只读复用本机 Claude Code 凭据查询自身额度”的专门规定或许可 | 未查到。 |

## 风险评估

| 编号 | 等级 | 行为 | 与公开规定的关系 |
| --- | --- | --- | --- |
| R1 | 高 | 旧 bridge 取出 OAuth access token，在 Claude Code 之外调用用量接口 | 法务页把 OAuth 限定于 Claude Code 等 Anthropic 原生应用，并禁止开发者收集 Claude.ai 凭据或会话 token。代码只读、不持久化、只发往 Anthropic，降低了泄漏风险，但“第三方程序取出 token 并自行使用”本身就落在这些表述的字面范围内。 |
| R2 | 高 | 请求使用 `User-Agent: claude-code/2.1.0` | 让请求看起来来自 Claude Code，可能被视为绕过平台识别或限制（Usage Policy 关于绕过产品限制的条款）。 |
| R3 | 中 | 由 App 刷新触发的程序化请求，未使用 API key | 与 Consumer Terms 关于自动化访问的条款存在张力。 |
| R4 | 中 | 未公开接口 | 接口可能随时变更、限流或封禁。Anthropic 声明可不经事先通知执行限制，后果首先落在用户本人的 Claude 账号上。 |
| R5 | 中（整体性） | 第三方 App 经 Agent SDK 驱动用户已登录的 Claude Code，并显示订阅额度 | Agent SDK 文档不允许第三方产品未经批准提供 claude.ai 登录或额度；法务页同时说明不妨碍用户用自己的订阅登录未经修改的 Claude Code。Mimi Remote 不提供登录流程、不托管凭据、不代付或转售用量，但这种用法是否属于“为产品提供额度”，公开材料没有明确结论。另外，Agent SDK 受 Commercial Terms 约束，`docs/project-status.md` 已将其列为正式发布前需确认的事项。 |
| R6 | 低 | 默认适配器显示会话内上报的额度 | 不涉及凭据，风险随 R5。 |

## 可选方案

| 方案 | 做法 | 效果 | 代价 |
| --- | --- | --- | --- |
| A. 移除 | 删除旧 bridge 的 `oauth_usage.rs`，只使用会话内的 `rate_limit_event`，与默认适配器一致 | 消除 R1–R4，改动最小；旧 bridge 原本也计划在一个版本周期后删除 | Linux / Homebrew 宿主在首轮会话前看不到 Claude 额度 |
| B. 默认关闭 + 显式开启 | 新增配置开关，默认关闭；开启处明确说明“会读取本机 Claude Code 凭据并调用未公开接口，可能不符合 Anthropic 条款” | 默认安装不再触发 R1–R4 | 仍保留高风险路径，需要维护开关和说明 |
| C. 改用官方 CLI 输出 | 通过未经修改的 Claude Code 获取额度，例如 SDK 会话中的 `/usage` 结构化报告，或 statusline 的 `rate_limits` | 不再由 Mimi 持有 token | `usage_report` 为实验性类型，需要额外的 Claude 进程；`/usage` 是否计入额度或消耗 token 未查到说明；仍属程序化使用订阅，R5 不变 |
| D. 维持现状并告知 | 在 README、隐私政策和设置页披露旧 bridge 的凭据用法 | 提高透明度 | 不降低条款风险 |
| E. 向 Anthropic 咨询 | 通过法务页提供的销售联系渠道确认用法 | 可能获得明确答复 | 周期不确定 |

建议顺序：短期采用 A（或至少 B），并去掉模拟的 User-Agent；中期按需要评估 C；R5 随 #660 正式发布前的条款确认一起处理，必要时采用 E。

## 需维护者决定

1. 旧 bridge 的 OAuth 用量查询是移除、默认关闭，还是保留并加披露。
2. 是否接受 Linux / Homebrew 宿主在首轮会话前不显示 Claude 额度。
3. Claude 通道整体（Agent SDK 与用户订阅登录）是否需要向 Anthropic 确认，以及确认前是否继续在对外宣传中突出 Claude 额度显示。

## 风险与优化

- 本文依据 2026-10-12 的公开页面整理；Anthropic 更新条款或文档后，应重新核对并更新检索日期。
- 代码行为以本文列出的源文件为准；修改额度查询实现时，同步更新本文、`SECURITY.md` 和 `docs/project-status.md`。
