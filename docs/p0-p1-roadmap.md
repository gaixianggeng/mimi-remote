# P0 / P1 发布推进清单

更新日期：2026-07-27

## 目标

这份清单把“功能已经写了”和“用户可以稳定安装、连接、排障、升级”分开。P0 的完成标准是个人开发者可以从公开仓库安装 Mac 服务，并让 iPhone / iPad 稳定接入；P1 的完成标准是在不扩大远程安全边界的前提下，补齐高频开发闭环。

## 方案

- P0 优先处理发布阻断、服务就绪、配对、诊断、安全和自动化验证。
- P1 优先处理 Review、Worktree、Git 和 allowlist action 等高频操作。
- Cloud、多用户、公网中继、任意 Shell、Codex 配置写入继续后置，不为了“功能数量”进入当前版本。

## 实现

### P0：发布与可用性

| 项目 | 当前状态 | 完成证据 / 下一步 |
| --- | --- | --- |
| Mac 一键启动 | 已完成菜单栏安装闭环 | 正式 Release 生成 Developer ID 签名并经过 Apple 公证的 universal DMG；菜单栏 App 内置 `agentd` 和 Claude bridge，负责首次设置、状态、配对、Doctor、登录启动和服务生命周期。检测到旧 Homebrew 服务时先保持其运行，用户确认后安全接管，失败自动尝试恢复旧服务；配置、移动端 Token 和配对关系继续保留。 |
| 服务存活与就绪分离 | 本轮完成 | `/healthz` 只表示进程存活；`/api/readyz` 除 Doctor 静态检查外，还会通过当前平台 transport 对 App Server 完成真实 `initialize`，失败返回 503。macOS SSH 探测与 Linux/Windows 受管 WebSocket 探测都使用 single-flight。`up/start/restart` 通过前不展示二维码；`agentd status --json` 的 `process_ok` 对应存活，`service_ok` 对应 transport、版本和协议就绪。 |
| 安装、升级与回滚 | 本轮完成 | macOS 普通用户使用 DMG 覆盖升级，App 与配置分离，回滚优先恢复上一版已签名、公证 App；Homebrew 保留给命令行、服务器、自动化和恢复。Linux Release 内置 user-systemd 安装脚本，默认由 agentd 托管 loopback WebSocket App Server，并在升级失败时恢复旧二进制和 unit。setup 原子写入配置；macOS 旧 managed WebSocket 配置只在 SSH 预检通过后原子迁移。安全卸载只移除 Mimi 程序和服务，不停止 Desktop 普通本地实例或 OpenClaw 实例。 |
| macOS 稳定代码身份与文件授权 | 本轮完成代码闭环 | Doctor 会把 cdhash-only ad-hoc 二进制标记为 warning；开发脚本使用固定 identifier + Apple Development 签名，并通过独立 launchd job 完成替换、kickstart、readyz 验证和失败回滚。每次 serve 启动最前面异步预检 projects/scan/browse roots，Home 浏览根额外触发 Desktop、Documents、Downloads 探测，结果进入 Doctor 与日志但不阻塞远程控制面。无人值守访问整个 Home 仍需人工一次性授予完全磁盘访问。正式 GoReleaser 链路强制 Developer ID + Apple notarization，发布后重新解包两个 Darwin 归档校验 Authority、TeamIdentifier 和 designated requirement。 |
| 敏感文件权限 | 本轮完成 | Doctor 检查配置必须是当前用户私有 regular file，并把权限收紧到 `0600`。Linux/Windows 的独立 App Server token 文件同样只允许当前用户读取。agentd 不保存 SSH 密码或私钥；macOS 的 host key、密钥和默认 Unix Socket 由当前用户管理。 |
| APP 凭据与弱网 | 本轮完成代码闭环 | Keychain/连接切换失败保留旧连接；清除配对先完成 Keychain 删除再提交 UserDefaults/内存状态，删除失败不会形成“默认地址 + 旧 Token”。忘记当前 Mac 和删除其它档案都先展示目标与重新配对影响，二次确认时重验 profile ID，避免旧弹窗误删后来切换的新当前档案。扫码相机权限拒绝/受限时提供系统设置和手动连接两个恢复动作，相机不可用或配置失败时也能选择回到原连接页并展开已有手动区域；权限与相机回调延后交回 SwiftUI，不增加后台相机能力。首次扫码、URL Scheme 和手动配对在凭据提交后统一复用冷启动恢复，最多等待 45 秒；修复或切换已有档案等待 10 秒。超时保留已提交凭据并展示无需重新扫码的可重试错误，不再误报“已连接”。REST/WS 401/鉴权 403 进入重新配对终态并停止重试；离线暂停轮询/WS，恢复只重连一次，瞬时失败使用 jitter + 30 秒上限。进入后台会主动退役旧 WebSocket 并保留会话、消息、排队 turn 与审批，回到前台后按网络状态只恢复一次。会话提醒在系统通知未授权时明确标记为仅 App 内保存，冷启动和回前台会清理已到期状态，不增加常驻 timer。提醒与运行态通知只携带版本/profile/project/session 路由，不含 Token 或明文 endpoint；点击后等待 bootstrap 完成，只打开当前 Mac 的会话，其他 Mac 仅提示手动切换档案。 |
| HTTP 请求资源边界 | 本轮完成 | 全部 JSON handler 统一拒绝未知字段、第二个 JSON 值和超限尾部；未鉴权配对为 16 KiB、普通控制面为 256 KiB、12 MiB 原始语音对应的 JSON envelope 为 17 MiB。`Content-Length`、chunked 和伪造长度都返回通用 413，不回显请求内容。 |
| App Store 隐私清单 | 本轮完成 | App bundle 根包含 `PrivacyInfo.xcprivacy`，声明不跟踪、不由开发者收集，UserDefaults 使用 approved reason `CA92.1`；iOS CI/TestFlight 归档前强制校验。 |
| iPad 诊断体验 | 本轮完成 | Doctor 页面结构化展示总状态、逐项检查和修复建议；保留可复制原始 JSON；非 2xx、超时和畸形响应进入明确错误态并可重试。当前会话日志可导出 ANSI 清洗后的有界 UTF-8 `.log`；头部只含生成时间、App 版本、会话 ID/标题和 Mac 显示名，不读取连接凭据。 |
| Gateway 协议边界 | 已完成 | Gateway 只放行移动端需要的公开方法，并按 schema 重建请求；`thread/search` 响应按 project、`browse_roots` 和 managed Worktree 的 cwd scope 逐条裁剪。标准审批和补充输入允许任一订阅入口首个响应；未知 Desktop 私有反向请求保持沉默。共享队列最低兼容 Codex `0.149.1`。 |
| PR 质量门禁 | 本轮完成配置 | Go/iOS/协议回归外，新增当前工作树 + Git 历史凭据扫描、Action SHA 固定、第三方许可证正文/版本门禁、隐私清单门禁。推送后仍需以 GitHub Actions 真实运行结果作为最终证据。 |
| 公开二进制发布 | 正式发布链路已完成 | GoReleaser 生成并校验 darwin/linux、amd64/arm64 四套归档、checksums 和 Homebrew Formula；同一 tag workflow 还会构建 universal Mac App DMG，强制验证内嵌 `agentd` / Claude bridge、Developer ID、notarization ticket 和 Gatekeeper。缺少任何 Apple Secret 会在创建发布产物前失败。 |
| 真机网络与 ATS | 已完成 iOS 27 模拟器 Tailscale 裸 IP 回归定位，真机完整验收待执行 | 2026-07-14 确认只保留 `NSAllowsLocalNetworking` 会导致 Tailscale 裸 IP HTTP 在发请求前被 ATS 以 `-1022` 拦截。系统层恢复 `NSAllowsArbitraryLoads`，设置提交、REST 和 WebSocket 仍由应用层统一拒绝公网 HTTP，CI 检查两层配置不再互相冲突。发布前仍需在真机上完成 Token 鉴权、前后台切换和 Wi-Fi/蜂窝弱网验收，并决定是否切换 MagicDNS HTTPS。 |

### P1：高频远程开发闭环

| 项目 | 当前状态 | 后续边界 |
| --- | --- | --- |
| 会话 Review | 本轮完成 | iPad Review Sheet 支持未提交改动、Base Branch、Commit；统一 trim/非空校验，始终 inline，拒绝 custom/detached。 |
| 会话管理 | 已完成 | 重命名、手动压缩、切换时 unsubscribe 已接入；继续观察真实使用频率。 |
| 会话全文搜索 | 本轮完成 | iOS 保留已加载会话的即时本地过滤，并在输入稳定 300ms 后调用 Codex `thread/search`；防抖和首屏请求共用独立 loading，本地已有匹配继续显示，只有空结果时展示“正在搜索历史会话”，不再先闪错误空态。新查询会取消旧请求，迟到响应和跨 Mac 响应由双 generation 丢弃。首屏加载 50 条，存在后续 cursor 时在窄屏会话列表和宽屏项目侧栏底部提供全局“继续搜索”；翻页失败保留已有结果与 cursor，可原位重试，空过滤页只要仍有后续 cursor 也可继续。远端结果使用独立投影，不污染基础会话缓存；旧服务、弱网或搜索失败静默回退本地结果。Gateway 会删除越权 cwd 及其 snippet，仅实际可见结果获得后续 thread 权限。为控制弱网请求和界面跳动，当前不做自动无限滚动。 |
| 多台 Mac 连接档案 | 本轮完成 MVP | APP 可保存、重命名和删除多台 Mac 档案，记录名称、规范化 endpoint 和最近成功时间；Token 按 profile 独立存入 Keychain，UserDefaults 只存非敏感元数据，重命名不会读取 Token 或重建连接；legacy 单连接可安全迁移。切换固定为“读取目标 Token → 完整验证 → 提交 Keychain/元数据 → 退役旧 WS → 清理旧 Mac 数据”，验证或提交失败时保留旧连接与会话。同一时间只连接一台，不增加 Bonjour、SSH、云端同步或多连接常驻。 |
| Managed Worktree | 本轮完成 P1 生命周期闭环 | 创建、分支选择、fork、打开和受保护删除可用。registry 记录真实 checkout 根与生命周期，实际访问会节流更新 `last_used_at`；清理固定为“30 天候选 + 每项目保留最近 3 个 + dry-run 计划 + APP 二次确认”，执行前重验 Git、仓库 identity、托管根、会话状态和计划指纹。Gateway 的 `thread/start`、`thread/resume`、`thread/fork` 在上游响应前持有 pending-use lease，避免普通删除撞上正在建立的会话；Codex/Claude 断连会释放 lease，成功时先登记 thread 再释放。清理永远不用 `force`，旧删除接口的 `force=true` 也会被后端拒绝。checkout 已删但 registry unlink 失败时返回结构化部分结果，APP 先移除真实 checkout 再提示重试 prune。创建后处理失败会回滚本次 checkout 和新分支；无人值守定时删除继续关闭。 |
| Git 审查动作 | MVP 已完成 | stage/unstage/revert、hunk、commit、push、草稿 PR 和本地 review note 已形成闭环；GitHub Review API inline comment 后置。 |
| 项目 Action | MVP 已完成 | 只执行配置 allowlist 中的命令，带确认、超时、输出截断和本地队列；不开放任意交互式 Shell。 |
| 运行与诊断细节 | 本轮完成代码闭环 | `/api/diagnostics/relay` 提供限界现场数据；APP 已区分凭据终态、离线和瞬时失败，并保留会话/排队消息。`serve` 在 signal 或 HTTP 异常时先停止 HTTP 接入并 drain，再回收 agentd 自己的会话；macOS 关闭 SSH proxy 并保留共享 Unix App Server，Linux/Windows 停止自己托管的 loopback App Server。transport 或 App Server 异常会明确失败。剩余仅是真机 Wi-Fi/蜂窝、前后台和 Tailscale 暂停/恢复验收。 |

与 Litter 的详细比较见[能力对照](litter-comparison.md)。当前优先吸收的是“保存多台 Mac、单次只连接一台、每台独立 Keychain Token”的低复杂度闭环；Bonjour/SSH 任意主机、内置终端、Watch/CarPlay、Android、云端线程和 vendored Codex runtime 不进入首发范围。

### 正式发布前的外部动作

完整源码与新 Release 的 canonical 仓库是 `gaixianggeng/mimi-remote`。仓库身份的一次性切换必须在短维护窗口按[中文仓库改名 runbook](operations/github-repository-rename-runbook.zh-CN.md)完成，Tap 继续独立维护 Formula。正式打 tag 前，仓库维护者必须逐项验证：

1. `gaixianggeng/mimi-remote` 为 **Public**，承载完整 iOS / Mac / Go 源码、测试、开发文档和新 Release；
2. `gaixianggeng/mimi-remote` 的仓库描述、Topics、Actions、Release 与源码树均已切换到唯一主仓库身份；
3. `gaixianggeng/homebrew-tap` 为 **Public**，保证 Homebrew 用户不需 GitHub 认证；
4. 主仓库 `TAP_DEPLOY_KEY` 只对应 Tap 的可写 Deploy Key，不复用维护者 PAT；
5. 主仓库配置 Developer ID PKCS#12 和 App Store Connect Notary API 五项 Secrets；
6. Go CI、公开安全门禁和 Codex Protocol Drift 在公开仓库真实通过后，再创建 `v*` tag。

Release workflow 已加入前置闸门：它通过 GitHub API JSON 验证目标仓库名、主仓库与 Tap 均为 PUBLIC，再使用 Deploy Key 对 Tap `main` 执行 dry-run push 验证写权限；随后验证 Developer ID PKCS#12 和 Notary API 凭据结构。任一条件未准备好时，会在创建半成品 Release 前停止。本地可运行 `bash ./scripts/check-release-prerequisites.sh --self-test` 和 `bash ./scripts/check-macos-release-signing.sh --self-test` 验证判定逻辑，不访问 GitHub 或 Apple。

2026-07-14 已完成 Public 后端仓库、Public Tap 和 Tap 可写 Deploy Key；2026-07-17 决定把完整源码仓库一并公开。公开前必须完成当前工作树、全部 Git refs、提交身份、签名产物和截图审计。剩余发布门禁是公开仓库 Actions 全绿和首个 tag 发布验证；真机网络与交互验收由维护者后续手动执行。

### 本地验收

```bash
go test ./... -count=1
go vet ./...
bash ./scripts/check-codex-protocol.sh
bash ./scripts/test-conversation-regressions.sh
bash ./scripts/check-public-repo-safety.sh
bash ./scripts/check-third-party-notices.sh
bash ./scripts/check-ios-privacy-manifest.sh

bash ./scripts/check-packaging.sh
bash ./scripts/install-linux.sh --self-test
bash ./scripts/restart-agentd-dev-macos.sh --self-test
bash ./scripts/verify-release.sh
```

## 风险与优化

- GitHub Actions 文件只有推送后才能获得托管环境的最终证明；本地 YAML 解析和命令通过不能替代真实 CI。
- 本地发布只使用 `scripts/verify-release.sh` 下载并校验的 GoReleaser 预编译包；不要用 `go run` 编译 GoReleaser，否则它可能自动切换 Go 工具链，让本地快照与 CI 正式产物不一致。
- GoReleaser 已显式固定 `release.github=gaixianggeng/mimi-remote`，快照 Formula 必须生成完整源码仓库的下载 URL；产物门禁会拒绝任何非 canonical 仓库的 Release 下载地址。
- 同 tag 重跑会替换已有同名附件，只能用于“同 tag、同提交”的 Release/tap 部分失败恢复；如果 tag 被移动，必须停止而不是覆盖公开产物。
- 当前 Homebrew Formula 仍使用 GoReleaser 已弃用的 `brews` 生成器；首个版本先保持已经验证的安装方式，后续再单独迁移 `homebrew_casks` 并验证 `brew services` 替代方案。
- 新版本只从唯一完整源码仓库发布；迁移完成后不再维护第二份源码或导出镜像，也不创建额外的仓库 tag。
- Tailscale HTTP 的 ATS 与应用层边界已经收窄，但 App Store 公开发布前仍需要用真机验证 Tailscale IP、后台切换和弱网恢复。
- 弱网诊断只保留内存中最近 80 条握手失败和连接结束样本，服务重启后清空；APP 的离线恢复已有确定性测试，但仍需真机验收，不替代长期日志或云端监控。
- Worktree 无人值守自动删除、任意 Shell、MCP/OAuth 配置写入仍属于高风险能力。当前 Worktree 只提供可解释候选和人工确认，不增加后台 ticker；多个 checkout 无法形成文件系统事务，极端外部竞争导致部分完成时必须依赖结构化 `deleted_paths/failed_path` 恢复 UI 状态。
- checkout 删除后的 registry unlink 失败会通过 `registry_cleanup_error`、`deleted_paths/failed_path/error` 或 prune 的 `failed_paths` 返回；失败登记保留供后续 prune 重试，不会误报为完整成功。
