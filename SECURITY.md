# 安全政策

## 目标

Mimi Remote / `agentd` 的默认安全边界是：用户自己的 iPhone / iPad 连接用户自己的电脑（macOS、Windows 或 Linux）。它不是公网 SaaS，也不应该直接暴露给不可信网络。

## 支持范围

当前支持范围：

- 本机开发环境。
- 局域网中的可信设备。
- Tailscale 等私有网络。
- 实验性 Tailcat 连接（默认关闭）。流量经 WireGuard 端到端加密；每次连接先经 DERP 中继发现对端并完成初始握手，网络允许时再切换为直连，否则继续经中继转发。默认中继是 Tailcat 上游提供、由 Tailscale 运营的公共中继（`https://tailcat.dev/derpmap.json`），也可以改为自建中继。中继方看不到连接内容，但能看到双方 IP、公钥、连接时间和流量大小；随后直连也不会消除初始连接阶段产生的网络元数据。

不建议支持的使用方式：

- 直接把 `agentd` 暴露到公网。
- 多用户共享同一个 `AGENTD_TOKEN`。
- 在不可信网络、共用设备或他人可接触的手机上保持「完全访问」默认档位，见下文“默认权限档位与风险”。
- 在截图、日志、Issue、PR 或 App Store 截图里公开真实 Token、Tailscale IP、私有路径或项目内容。

## 默认权限档位与风险

当前 iOS 新会话的默认权限档位是「完全访问」（界面显示为「完全文件访问」）：

- Codex 使用 `danger-full-access` 沙箱和 `approvalPolicy=never`；Gateway 只在请求完全访问时放行 `approvalPolicy=never`。
- Claude Code 使用 `bypassPermissions` 权限模式，工具调用不再逐条请求审批。
- DeepSeek Harness 只提供完全访问，执行权限由 Harness 自己管理。

在该档位下，Agent 在电脑上执行命令、修改文件和访问网络时不会逐条向手机请求审批。`agentd` 仍然校验 Bearer Token 和工作区授权，但 Agent 进程可以读写该系统用户能访问的任何文件。访问码泄漏、手机被他人使用或项目内容中的提示注入，都可能导致以该系统用户身份执行任意命令。

降低风险的做法：

- 只配对自己的设备，只在可信网络中开放 `agentd`，并保护访问码。
- 需要逐条确认时，在 App 设置的「默认权限」中改为「请求审批」或「只读」；单个会话也可以在输入框的权限菜单中切换。
- 重要仓库保持 Git 提交与备份，批准或合并前检查 Diff。

这一默认值是产品当前的取舍，不代表本政策推荐在所有环境中使用完全访问。

## 报告安全问题

如果你发现安全问题，请不要先公开披露细节。可以通过 GitHub Security Advisory，或邮件联系：

```text
gaixg94@gmail.com
```

报告时尽量包含：

- 影响版本或 commit。
- 可复现步骤。
- 预期影响，例如越权访问、Token 泄漏、路径绕过、审批绕过。
- 你已经验证过的范围，避免包含不必要的真实凭证或私有代码。

## 默认防护原则

- 除短期二维码兑换和 Catalyst 同机自动配对外，`agentd` API 和 WebSocket gateway 都要求 Bearer Token。
- 同机自动配对只接受 TCP 来源与 Host 均为 loopback、带原生客户端专用请求头且没有浏览器 `Origin` 的请求；它按单用户开发机建模，不隔离同一登录用户下的恶意本地进程。
- iPhone / iPad 只保存访问 `agentd` 的外侧 Token；使用 Tailcat 时另在 Keychain 保存本机 Tailcat 客户端密钥与连接地址。App 不保存 app-server upstream token。
- app-server upstream token file 只留在电脑本机。
- 项目路径必须在 allowlist 内。
- 默认不接受 URL query token，避免 Token 出现在浏览器历史、日志或 Referer。
- 推荐通过 Tailscale ACL 限制只有可信 iPhone / iPad 能访问电脑的 `8787` 端口。
- Claude 默认适配器（`mimi-claude-adapter`）不读取 Claude 登录凭据。旧 Claude bridge（Linux / Homebrew 宿主，以及 `claude.legacy_bridge` 回退）在客户端请求额度时，会只读读取本机 Claude Code 的 OAuth 凭据并直接请求 Anthropic 的用量接口；凭据不写磁盘、不进日志，也不发送到 Anthropic 以外的主机。合规风险见 [Claude 用量查询合规分析](docs/claude-usage-compliance.md)。

## 风险与优化

当前项目仍是个人开发者友好的 MVP。后续如果增加多用户、云同步、远程日志或公网访问，需要重新设计认证、授权、审计日志、密钥轮换和权限隔离。
