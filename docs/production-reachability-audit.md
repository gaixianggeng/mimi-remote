# 生产可达性审计

## 目标

在继续做安全修复前，先明确哪些代码是当前生产路径会走到的，哪些只是调试或测试遗留。这样后续优化不会修到旧路径里，也不会误删仍有诊断价值的代码。

## 方案

当前生产形态是 iPad App 直连 `agentd` 的鉴权 WebSocket gateway。`agentd` 负责鉴权、项目 allowlist，并通过 SSH proxy 连接共享 Unix App Server。它不拥有 App Server 生命周期。客户端发起的 request 和客户端回给 app-server server request 的 response 都必须经过 gateway 校验。

### 生产可达路径

| 模块 | 入口 | 说明 |
| --- | --- | --- |
| HTTP 路由 | `cmd/agentd/main.go` 的 `httpapi.NewRouterWithInstallationIDAndOptions(...)` | 生产路由只注入当前 Gateway 所需的配置、安装身份和 SSH transport。 |
| app-server gateway | `internal/httpapi/appserver_gateway.go` | iPad 的 `/api/app-server/ws` 主链路，负责方法白名单、cwd allowlist、thread 授权和策略校验。 |
| SSH app-server transport | `internal/appserver/ssh.go` | 每条移动端协议连接拥有一个 SSH proxy；共享 Unix App Server 独立存活。 |
| 本机自动配对 | `/api/pair/local` + Catalyst `AppStore.preflightConnection` | 仅接受 TCP 来源和 Host 均为 loopback、带原生客户端请求头且无浏览器 `Origin` 的 POST；领取凭据后仍须通过真实 gateway 握手才提交 Keychain。按单用户开发机建模。 |
| 工作区授权 | `internal/projects` + `/api/projects` + `/api/workspaces/resolve` | iPad 可使用配置项目、`browse_roots` 内明确打开的具体目录和 agentd 管理的 Worktree；所有请求都绑定 canonical cwd。 |
| iOS 直连 runtime | `CodexAppServerSessionRuntime.swift` | iOS 端直接构造 app-server JSON-RPC 请求并处理 notification/server request。 |

### 调试可达路径

| 模块 | 入口 | 说明 |
| --- | --- | --- |
| Codex history diagnostics | `/api/debug/codex-history`、`DoctorView` | 默认关闭；需要 Bearer Token 且 `debug.enable_codex_history=true` 或 `AGENTD_DEBUG_CODEX_HISTORY=true`。用于诊断本机 Codex 历史和项目映射问题，不是主业务链路。 |

### 仅测试可达或旧架构遗留

| 模块 | 现状 | 后续处理 |
| --- | --- | --- |
| `internal/session/session.go` | 旧 PTY session manager，生产只创建 manager 供诊断/兼容，主链路不调用 `Create`。 | 先不删，P2 做可达性复核后清理。 |
| `internal/appserver/client.go` 的 stdio client | 当前生产使用 SSH proxy 连接共享 Unix App Server。 | P2 阶段清理或降级为测试支持代码。 |

## 实现

近期安全修复只改生产可达路径：

1. iOS permission approval：只改 `CodexAppServerSessionRuntime.swift` 的活路径。
2. 审批 UI 状态：只改 `SessionStore`、Composer 审批卡与 Gateway 策略。
3. Gateway 安全默认值、WebSocket 限制、server request response 校验：只改 `internal/httpapi/appserver_gateway.go`。
4. agentd 误配防护：改 `internal/config` 与 HTTP 日志。
5. Catalyst 同机自动配对：只改 `/api/pair/local`、AppStore 冷启动选路和 Keychain 提交，不向 Tailscale/LAN 放宽未鉴权入口。

## 风险与优化

- 旧 REST `SessionRuntime` / `CodexAppServerRuntime` 已删除。不要恢复 `/api/sessions*` 或再建立一套会话状态与审批适配层。
- PTY session manager 与 stdio app-server client 仍有诊断、测试或平台消费者；删除前需要分别完成可达性复核。
- Debug history 已加默认关闭开关；后续如果做公开发布，还应补充更细的输出脱敏策略。
- iOS 端仍保留 `100.64/10` Tailscale 裸 IP 的 HTTP 支持，这是当前 README 和配对链接的主路径。2026-07-14 已在 iOS 27 模拟器确认 `NSAllowsLocalNetworking` 会将该地址以 ATS `-1022` 拦截，因此系统层恢复 `NSAllowsArbitraryLoads`；应用层在设置、REST 和 WebSocket 三层统一拒绝公网 HTTP，CI 会同时检查系统可达性与应用层边界。上线前仍必须做真机 ATS/Tailscale 验证，并优先评估 MagicDNS `*.ts.net` + HTTPS。
