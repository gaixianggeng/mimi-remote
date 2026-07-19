# 安全政策

## 目标

Mimi Remote / `agentd` 的默认安全边界是：用户自己的 iPad 连接用户自己的 Mac。它不是公网 SaaS，也不应该直接暴露给不可信网络。

## 支持范围

当前支持范围：

- 本机开发环境。
- 局域网中的可信设备。
- Tailscale 等私有网络。

不建议支持的使用方式：

- 直接把 `agentd` 暴露到公网。
- 多用户共享同一个 `AGENTD_TOKEN`。
- 把 `approvalPolicy=never` 或不受限文件系统权限作为移动端默认策略。
- 在截图、日志、Issue、PR 或 App Store 截图里公开真实 Token、Tailscale IP、私有路径或项目内容。

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
- iPad 只保存访问 `agentd` 的外侧 Token，不保存 app-server upstream token。
- app-server upstream token file 只留在 Mac 本机。
- 项目路径必须在 allowlist 内。
- 默认不接受 URL query token，避免 Token 出现在浏览器历史、日志或 Referer。
- 推荐通过 Tailscale ACL 限制只有可信 iPad 能访问 Mac 的 `8787` 端口。

## 风险与优化

当前项目仍是个人开发者友好的 MVP。后续如果增加多用户、云同步、远程日志或公网访问，需要重新设计认证、授权、审计日志、密钥轮换和权限隔离。
