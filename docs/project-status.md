# Mimi Remote 项目现状与关键决策

更新日期：2026-08-12

## 目标

本文是当前实现的入口文档，用来承接历史开发会话中仍然有效的结论。历史会话、旧 PR 描述或阶段性设计稿与本文冲突时，以当前代码、本文和对应运维文档为准。

Mimi Remote 的目标是让 iPhone / iPad 安全连接用户自己的 Mac，在明确授权的工作区内远程使用 Codex。项目保持单机优先：不建设云端账号系统，不把代码、Codex 凭证或完整会话托管到开发者服务器。

完整源码与新版本的目标 canonical 仓库为 `gaixianggeng/mimi-remote`，包括 iOS App、Mac App、Go 后端、Claude bridge、测试、文档、DMG、Go/Linux 归档、Homebrew Formula 和安装 Skill。仓库内代码与发布配置已经为新身份做好准备，但本 PR 不执行 GitHub 外部删除或改名；原完整源码仓库与同名历史归档的一次性切换按[中文仓库改名 runbook](operations/github-repository-rename-runbook.zh-CN.md)执行，历史产物离线备份，不再维护第二份在线仓库。自有 iOS / Mac / Go 代码使用 GNU GPLv3，并附 App Store / Google Play 分发例外；从 Alleycat 收窄导入的 `bridges/claude` 保留 GPLv3-only 和上游归属。

## 方案

### 当前生产链路

```text
iPhone / iPad SwiftUI App
  -> Mac Tailscale 或同一局域网 Endpoint:8787
  -> agentd Bearer 鉴权、工作区授权和 JSON-RPC 安全校验
  -> 默认：managed loopback codex app-server WebSocket:4222
  -> macOS 实验叠加层：已验证 Codex Desktop IPC（Desktop-owned thread 才路由回 Desktop）
  -> 本机 Codex 凭证、线程状态和项目目录
```

网络只有一个应用入口：Mac 的私网 Endpoint。自动配对优先 Tailscale；未安装或不可用时，Mac App 会显式启用 LAN 监听并返回当前私有局域网地址。Tailscale 模式仍自动选择直连、上海 VPS Peer Relay 或官方 DERP；VPS 只提供网络层 Peer Relay，不运行 Mimi Remote 的 nginx、SSH reverse tunnel 或公网备用 Endpoint。

### 已确定的边界

- `agentd` 是薄网关，不复制一套 Codex 业务协议。
- macOS 实验开关只启用 Desktop IPC overlay，不创建、签名、恢复或诊断共享 daemon。Mimi 的独立 App Server 始终保留为稳定主链路；Desktop-owned thread 的读写才通过已验证的 owner/follower IPC 路由，Mimi-owned thread 继续由 App Server 执行。
- IPC 不在官方 App Server 公开契约内，因此只放行已完成真机协议验收的 Codex Desktop build。当前白名单为 `26.820.60940 (7119)` 和 `26.825.31414 (7287)`。未知 build、socket 不可用、协议错误或所有权不明确时保持只读/明确失败，不能回退为本地重复写入。
- 生产主链路使用 `/api/app-server/ws`；旧 `/api/sessions*`、Web/PWA 和 PTY 文本解析链路不再恢复。
- 未显式选择模型时不发送 `model`，交给本机 app-server rollout 决定；不要在客户端写死某个模型版本。
- Codex 默认保持网络关闭；只有用户显式选择 `danger-full-access` 或 `:danger-full-access` 时允许 `approvalPolicy=never`，其它模式继续由 Gateway 收敛审批策略。
- iPad 只保存外侧 `agentd` Token；访问 loopback app-server 的 capability token 只保存在 Mac。
- 项目目录、`browse_roots` 内明确打开的目录和 agentd 管理的 Worktree 都要绑定到真实 canonical cwd，不能跨授权根切换。
- 任意 shell 不是移动端 MVP。远程命令只允许执行配置中的 action，并保留确认、超时和输出截断。

## 实现

### 当前能力

| 领域 | 已实现 | 当前边界 |
| --- | --- | --- |
| 会话 | 列表、本地即时搜索、Codex 全文搜索及显式分页、新建、恢复、历史分页、流式输出、steer、interrupt、审批、goal、fork、archive/unarchive、本地 pin | 全文搜索每页最多 50 条，严格裁剪到授权 cwd，并由用户显式继续加载；Cloud / projectless thread 未支持；每个会话同时只允许一个 iOS WebSocket attach |
| 工作区 | 项目扫描、`browse_roots` 目录浏览、打开目录、managed Worktree 创建/列出/受保护删除/prune/分支选择；registry 记录真实 checkout 根和使用时间，Git 状态区分 clean/dirty/unknown；APP 可预览 30 天清理候选、查看 blocker 并二次确认；Gateway 建立 thread 期间用 pending-use lease 阻止删除 | 每项目至少保留最近 3 个，清理和普通移动 API 都不允许 force；无人值守自动删除仍关闭 |
| Git | status、diff、文件和 hunk 级 stage/unstage/revert、commit、push、草稿 PR 和 PR 状态；完整/摘要状态统一返回 upstream 与 ahead/behind，支持从工作区直达并在回合结束后防抖刷新；Quick Publish 尊重既有 upstream，落后远端时在提交前阻断 | pull/rebase 与冲突处理、GitHub Review API 级 inline comment 尚未接入 |
| 输入输出 | 富 Markdown、图片输入、历史图片按需加载、语音转写、文件安全读取和 QuickLook；当前会话可导出 ANSI 清洗后的有界 UTF-8 日志，导出头部不读取连接凭据 | PDF/大型 artifact 的富预览和后台下载尚未实现；日志正文可能包含用户命令、代码和工具输出，分享前需自行检查 |
| 能力发现 | Skills 和 MCP 配置只读浏览、allowlist actions | 不在 iPad 上启停 MCP、修改 Codex 配置或处理 OAuth |
| 移动体验 | iPhone/iPad 自适应、深浅色、主题和字号、Codex 5h/7d 用量、提醒、运行态通知、通知点击回到当前 Mac 会话；通知未授权时提醒仍可保留为 App 内状态并明确告知，冷启动/回前台清理过期提醒；通知 payload 不含 Token 或明文 endpoint，错 Mac 只提示手动切换档案；凭据失效终止重试；NWPath 事件按递增序号交付并丢弃迟到旧状态，离线暂停、恢复单次重连和 jitter 退避，首次 unknown→在线只在已有网络错误或挂起会话时恢复一次；首次配对提交后最多等待 45 秒恢复项目/会话，已有档案修复或切换等待 10 秒，超时保留 Keychain 凭据且打开设置可直接重试；保存、重命名和删除多台 Mac 档案，每台独立 Keychain Token 和稳定安装身份，候选连接验证后原子单活切换；非当前 Mac 只在菜单打开后轻量探测，不加载业务状态；缓存、媒体、通知和异步任务按 Profile 隔离；重命名只更新非敏感显示名，不重建连接；忘记/删除凭据必须二次确认并统一清理 Profile 数据；AI 用量刷新按 runtime 独立 loading 和去重，Claude 慢查询不禁用其他设置操作 | 后台 push、离线通知、连接档案云同步和离线队列持久化尚未实现；快速切换发布前仍需通过 Release 真机性能门禁 |
| Claude | 仓库内 `alleycat-claude-bridge >= 0.2.7` 实验通道，当前 `0.2.7` 支持 resident bridge、稳定 session + sequence replay、审批闭环、运行期历史热刷新、历史记录过滤、OAuth 额度查询、过期凭据委托续期、事件降级和 Fable 5 模型目录；正式 Mac App 已内置并签名兼容 bridge | 默认关闭；每个 Claude thread 一个 headless 进程，不跟单次 WebSocket 生命周期绑定；不支持 goal、archive、fork；优先复用 Claude Code Keychain/凭据文件只读查询 Anthropic OAuth usage beta endpoint，返回 5h/7d 百分比与重置时间并短缓存；macOS access token 过期或接口返回 401 时，通过 Claude CLI `/status` 让凭据所有者更新 Keychain，bridge 不直接消费 refresh token；内部 beta endpoint 变化、凭据缺少 `user:profile`、续期或查询失败时降级到官方 `rate_limit_event`，两者均不可用才显示暂无数据；CLI 登录整体失效时仍需在 Mac 重新登录 |

完整能力矩阵见 [Codex Mac App 功能对照](codex-mac-feature-parity.md)。

### 会话与历史同步约束

历史会话曾集中出现列表抖动、排序错误、大历史首屏慢、断线后消息长期排队和偶发 `-32080`。当前实现采用以下规则，后续修改不能破坏：

- 相同 `thread/list` 请求使用 single-flight 合并，避免并发请求被 Gateway 拒绝为 `-32080`。
- 会话列表优先读取小页、最近更新时间倒序和 `useStateDbOnly=true`，索引遗漏时才回退普通扫描。
- 新建空会话不立即读取完整历史；带首轮 prompt 和恢复历史会话仍做权威快照校准。
- 切回会话先用 `thread/read` 补齐状态，再用 `thread/resume` 建立实时监听；断线后必须重新绑定监听。
- 权威快照确认旧 turn 已完成时，要补发缺失的完成状态，推动本地排队消息继续发送。
- 大历史按窗口展示；历史 inline 图片先返回轻量引用，用户点按后再读取，避免图片阻塞文字首屏。
- 进入长会话的贴底动作允许在布局稳定后重试；用户主动上滑或加载更早历史时不能强制跳到底部。

性能探针和验收命令见 [Tailscale 直连与上海 Peer Relay 运维手册](tailscale-peer-relay-ops.md)。

### UI 约束

- 信息层级优先于功能平铺；常用动作直接可达，低频和危险动作收进菜单或 Inspector。
- iPad 使用工作台侧栏；iPhone 进入会话详情后隐藏底部 TabBar，返回列表时恢复。
- 组件圆角、按钮尺寸和选中态保持同一视觉语言；深色模式避免高饱和紫色和低对比文字。
- Codex 与已启用 Claude 的额度状态收进设置页同一个“AI 用量”模块；Codex 展示 5h/7d 双窗口，Claude 只展示 headless 协议真实可得的数据，缺失百分比不显示为 0%，且不抓取私有网页接口。额度耗尽复用阻断提示，不叠加重复警告。
- 用户打开过的目录才进入工作区列表；后端扫描候选只用于“打开目录”，不能自动污染工作区。

### 构建与验证

```bash
# Go
go test ./...
go build -o bin/agentd ./cmd/agentd

# macOS Homebrew 服务的签名构建、独立重启和失败回滚
bash ./scripts/restart-agentd-dev-macos.sh

# 重启后 file-access-preflight 会优先探测配置目录；无人值守访问整个 Home 需一次性授予完全磁盘访问
open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

# Claude bridge
cargo test --locked \
  -p alleycat-codex-proto \
  -p alleycat-bridge-core \
  -p alleycat-claude-bridge

# iOS 工程
xcodegen generate \
  --spec ios/MimiRemote/project.yml \
  --project ios/MimiRemote

bash ./scripts/ios-dev.sh build-for-testing
```

Mimi TestFlight 使用本机 `git testflight-push`：先推送并核对远端 commit，再在干净 worktree 中归档、上传和内部组分发，不依赖 GitHub Actions。其他 CI 与公开 Release workflows 保持不变。

### 文档入口

- [根 README](../README.md)：安装、配置、开发和发布入口。
- [P0 / P1 发布推进清单](p0-p1-roadmap.md)：发布门禁、当前完成度和外部阻断项。
- [安装、升级与回滚](install-upgrade-rollback.md)：Mac/Linux 安装、凭据备份、升级验证和应急回滚。
- [iOS README](../ios/MimiRemote/README.md)：iOS 工程结构、构建和验收。
- [Claude bridge 架构](claude-bridge-architecture.md)：Claude 实验通道的进程生命周期、权限、状态和失败模式。
- [Tailscale 运维](tailscale-peer-relay-ops.md)：跨网络 Endpoint、Peer Relay、验证和回滚。
- [多 Mac 单活切换](multi-mac-single-active.md)：身份隔离、快速候选链路、缓存策略和 Release 真机门禁。
- [生产可达性审计](production-reachability-audit.md)：生产主链路与旧代码边界。
- [功能对照](codex-mac-feature-parity.md)：完整能力、缺口和优先级。
- [与 Litter 的能力对照](litter-comparison.md)：竞品能力差异、当前优势和不应进入首发的复杂度。
- [隐私政策](privacy-policy.md)：本地数据和网络边界。

## 风险与优化

- Tailscale 未连接时不会回退公网；Mac 与移动设备在同一局域网时可重新生成 LAN 配对信息，否则必须恢复 Tailnet。
- 当前 Endpoint 仍可能是 Tailscale 裸 IP 上的 HTTP；ATS 已收窄为本地网络和 `ts.net` 例外，并由应用层拒绝公网 HTTP。公开发布前继续完成真机验收并评估 MagicDNS `*.ts.net` + HTTPS。
- 旧 REST runtime、PTY session manager 和 stdio app-server client 仍有测试/兼容代码，但不在生产主链路。删除前必须先做可达性复核和全量回归。
- Claude 通道依赖外部 CLI 与 bridge，鉴权和生命周期仍弱于 Codex 主通道，不能作为默认路径；agentd 对 bridge 执行 `>=0.2.7` 版本门禁、强制关闭 bypass permissions，版本不兼容时 fail closed 并给出升级命令。
- 多 Mac 的本地单活档案已完成；Bonjour/SSH 自动发现、跨设备档案同步、Cloud thread、后台 push、IDE sync、Browser / Computer Use 后置。在真实需求明确前不增加云端控制面或复杂分布式架构。
- 设计文档只描述目标或历史方案，不能覆盖当前代码事实。功能完成后要同步更新本文和对应专题文档，避免再次依赖会话历史判断现状。
