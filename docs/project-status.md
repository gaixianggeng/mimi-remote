# Mimi Remote 项目现状与关键决策

更新日期：2026-10-10

## 目标

本文是当前实现的入口文档，用来承接历史开发会话中仍然有效的结论。历史会话、旧 PR 描述或阶段性设计稿与本文冲突时，以当前代码、本文和对应运维文档为准。

Mimi Remote 的目标是让 iPhone / iPad 安全连接用户自己的电脑（以 Mac 为主，也支持 Windows 与 Linux 宿主），在明确授权的工作区内远程使用 Codex，并可选接入 Claude Code 与 DeepSeek Harness。项目保持单机优先：不建设云端账号系统，不把代码、Codex 凭证或完整会话托管到开发者服务器。

完整源码与新版本的目标 canonical 仓库为 `gaixianggeng/mimi-remote`，包括 iOS App、Mac App、Go 后端、Claude bridge、测试、文档、DMG、Go/Linux 归档、Homebrew Formula 和安装 Skill。仓库内代码与发布配置已经为新身份做好准备，但本 PR 不执行 GitHub 外部删除或改名；原完整源码仓库与同名历史归档的一次性切换按[中文仓库改名 runbook](operations/github-repository-rename-runbook.zh-CN.md)执行，历史产物离线备份，不再维护第二份在线仓库。自有 iOS / Mac / Go 代码使用 GNU GPLv3，并附 App Store / Google Play 分发例外；从 Alleycat 收窄导入的 `bridges/claude` 保留 GPLv3-only 和上游归属。

## 方案

### 当前生产链路

```text
iPhone / iPad SwiftUI App
  -> 宿主的 Tailscale 或同一局域网 Endpoint:8787
     或 Tailcat 实验连接：App 内嵌客户端 -> 宿主 Tailcat sidecar -> 127.0.0.1:8787
  -> agentd Bearer 鉴权、工作区授权和 JSON-RPC 安全校验
  -> Codex：
     macOS / Linux：agentd 直连标准 Unix control socket 上的共享 App Server
       （与 `codex --remote unix://` 本机终端、Codex Desktop 的 SSH 主机共用；
        Mac App 由 launchd 前门持有该 socket，并在 Aqua 会话启动独立 backend）
     Windows：agentd 托管的 loopback WebSocket App Server
     显式远端 SSH target：ssh -> codex app-server proxy -> 远端共享 Unix App Server
  -> 可选：Claude Code bridge、DeepSeek Harness 本机服务
  -> 本机 Agent 凭证、线程状态和项目目录
```

应用入口只有宿主上 `agentd` 的 Endpoint：Tailscale、局域网和 Tailcat 都到达同一个端口，并经过同一套 Bearer 鉴权。macOS 与 Linux 首次设置时优先 Tailscale；未检测到 Tailscale 时启用局域网监听，并在配对时返回当前私有局域网地址。之后可在 Mac App 的模块管理中分别开关这三种连接；生成配对码只使用已开启且本机可用的连接，不会顺带开启其他连接。Tailscale 模式仍自动选择直连、上海 VPS Peer Relay 或官方 DERP；VPS 只提供网络层 Peer Relay，不运行 Mimi Remote 的 nginx、SSH reverse tunnel 或公网备用 Endpoint。

自建 Tailcat 是实验连接，Mac 与 Linux 宿主随包提供 sidecar，iPhone / iPad 不需要安装 Tailscale 客户端。扫码配对后 App 只走 Tailcat 路由，不回退到 Tailscale 或局域网地址；能直连时点对点，否则经 Tailcat 默认或用户自定义的 DERP 中继。二维码只含 10 分钟有效的配对信息，不含长期 Agent Token。Mimi 托管连接（官方控制面与订阅）尚未开放，Release 构建不显示入口。细节见 [Tailcat 远程连接实验](operations/tailcat-experiment.md)。

### 已确定的边界

- `agentd` 是薄网关，不复制一套 Codex 业务协议。
- macOS 与 Linux 默认 `app_server.transport=local`：`agentd` 直接连接标准 Unix control socket，不要求 macOS“远程登录”、sshd 或免密 SSH。Mac App 安装版登记 launchd 前门（`agentd codex-front`），由 launchd 持有标准 socket，首次连接时在 Aqua 会话启动独立 Codex backend；Linux 与 macOS Homebrew 版在 socket 缺失时由 `agentd` 启动 resident。旧版自动写入的 `ssh` + 本机回环 target 会在预检通过后原子迁移为 `local`。SSH 只用于 Codex Desktop 自己的 SSH 主机，或显式指定的远端 target。Windows 由 `agentd` 托管 loopback WebSocket 生命周期。main 不读取或控制 Codex Desktop 私有 IPC，也不依赖仅支持 standalone 安装的 `app-server daemon` 生命周期。细节见[共享 App Server](shared-ssh-app-server.md)。
- macOS 上 Mimi、使用 `codex --remote unix://` 的本机终端、本机 Desktop SSH 主机和远程 Desktop SSH 主机共享同一个 Unix App Server。Linux 上 Mimi 与使用 control socket 的本机终端共享同一个 App Server。Codex Desktop 普通 “This Mac” 模式、Windows 的受管 App Server 以及 OpenClaw 等其他 runtime 保持独立；agentd 不枚举或停止不属于自己的进程。
- 从共享实验版本升级前，必须先在旧版本中关闭 Codex Desktop 共享。新版本检测到旧配置、LaunchAgent job、plist 或 Mimi ownership 环境时会拒绝启动，并保持文件和进程不变；它不会在后台终止 Desktop 任务。旧 LaunchAgent 若用 `--codex-daemon-supervisor` 启动新 App，新 App 只退出该后台进程，不会恢复 daemon 或误开第二个菜单栏实例。
- Codex 与 Claude 使用 `/api/app-server/ws`；DeepSeek Harness 使用独立的 `/api/harness/rpc` 与 `/api/harness/ws` 原生中继，只转发到配置中固定的 Harness origin。旧 `/api/sessions*`、Web/PWA 和 PTY 文本解析链路不再恢复。
- 未显式选择模型时不发送 `model`，交给本机 app-server rollout 决定；不要在客户端写死某个模型版本。
- Gateway 只在请求为 `danger-full-access` 或 `:danger-full-access` 时允许 `approvalPolicy=never`；其他档位保持 sandbox 网络关闭，并继续由 Gateway 收敛审批策略。#496 之后 iOS 输入框的默认权限档位是完全访问，用户可在设置中改为其他默认档位；Claude 只在 bridge 支持时提供完全访问，DeepSeek 只提供完全访问。
- iPad 只保存外侧 `agentd` Token，使用 Tailcat 时另在 Keychain 保存本机 Tailcat 客户端密钥与连接地址；macOS / Linux 的 Unix Socket、显式 SSH 模式的 SSH host key 与密钥、Windows 的 App Server capability token，以及 DeepSeek Harness 启动 token，都只留在对应宿主。
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
| 移动体验 | iPhone/iPad 自适应、深浅色、主题和字号、Codex 5h/7d 用量、提醒、运行态通知；消息通知默认开启（旧版明确关闭的选择保留），agentd 默认经开发者运营的推送服务（APNs）发送审批请求和 Codex / Claude 任务完成、失败、中断提醒，推送只含匿名短标签和事件枚举，通知点击回到当前 Mac 会话，锁屏上的允许 / 拒绝仍由设备经私有网络直接提交给 agentd；通知未授权时提醒仍可保留为 App 内状态并明确告知，冷启动/回前台清理过期提醒；通知 payload 不含 Token 或明文 endpoint，错 Mac 只提示手动切换档案；凭据失效终止重试；NWPath 事件按递增序号交付并丢弃迟到旧状态，离线暂停、恢复单次重连和 jitter 退避，首次 unknown→在线只在已有网络错误或挂起会话时恢复一次；首次配对提交后最多等待 45 秒恢复项目/会话，已有档案修复或切换等待 10 秒，超时保留 Keychain 凭据且打开设置可直接重试；保存、重命名和删除多台 Mac 档案，每台独立 Keychain Token 和稳定安装身份，候选连接验证后原子单活切换；非当前 Mac 只在菜单打开后轻量探测，不加载业务状态；缓存、媒体、通知和异步任务按 Profile 隔离；重命名只更新非敏感显示名，不重建连接；忘记/删除凭据必须二次确认并统一清理 Profile 数据；AI 用量刷新按 runtime 独立 loading 和去重，Claude 慢查询不禁用其他设置操作 | 让上游连接在 App 退到后台后继续接住审批和最终回复的 `app_server.approval_broker` 默认关闭；DeepSeek 任务不发推送；连接档案云同步和离线队列持久化尚未实现；快速切换发布前仍需通过 Release 真机性能门禁。通知数据边界见[隐私政策](privacy-policy.md) |
| Claude | 仓库内 `alleycat-claude-bridge` 实验通道（仓库版本 `0.2.15`，agentd 最低要求 `0.2.8`），支持 resident bridge、稳定 session + sequence replay、审批闭环、运行期历史热刷新、历史记录过滤、OAuth 额度查询、事件降级和经 Claude CLI 动态读取的模型目录；bridge `>= 0.2.13` 时支持完全访问档位，`>= 0.2.14` 时可在 Mac 上的持有方空闲后手动接管会话；正式 Mac App 已内置并签名兼容 bridge，启动时检测到 Claude Code 已安装并登录即自动开启，用户在模块管理中显式关闭后保持关闭 | Mac App 以外的宿主默认关闭，需手动启用（Windows 安装包随附 bridge，Linux 与 Homebrew 需单独安装）；每个 Claude thread 一个 headless 进程，不跟单次 WebSocket 生命周期绑定；不支持 goal、archive、fork；优先复用 Claude Code Keychain/凭据文件只读查询 Anthropic OAuth usage beta endpoint，返回 5h/7d 百分比与重置时间并短缓存；接口返回 401 时只重新读取一次 Keychain/凭据文件，bridge 不刷新也不消费 refresh token（`0.2.8` 起移除经 `/status` 的隐藏续期）；内部 beta endpoint 变化、凭据缺少 `user:profile` 或查询失败时降级到官方 `rate_limit_event`，两者均不可用才显示暂无数据；CLI 登录失效时需在 Mac 重新登录 |
| DeepSeek | 可选 DeepSeek Harness 运行时：Mac App 可连接自动发现的本机 Harness，或粘贴 Harness 启动链接；iOS 支持会话列表、搜索、新建、历史分页、实时进度、文本对话、取消、模型选择和回答 Harness 发起的交互；agentd 经 `/api/harness/*` 原生中继，并按授权工作区裁剪会话 | 默认关闭；Harness 由用户自行安装运行，agentd 不安装、启动或配置它，也不管理模型供应商、密钥与套餐；只接受文本输入，执行权限由 Harness 管理，App 只提供完全访问档位；不支持附件、Skills、计划、目标和归档；Harness 重启换 token 后，只有自动发现的连接会在同一地址重新取得凭据。协议见 [DeepSeek Harness 接入协议](deepseek-harness-protocol.md) |
| 宿主与连接 | Mac App 菜单和设置共用模块管理：Codex 与 Claude 可独立开关，DeepSeek 用“连接 / 关闭通道”管理；Tailscale、局域网和 Tailcat 三种连接可独立开关，也可同时开启；直连入口按真实 TCP 地址校验，两种外部直连都关闭时只监听回环；普通切换不轮换 Token、不删除配对，也不终止共享的 Codex Desktop 进程；关闭 Codex 后跳过 CLI 修复、transport 迁移和用量探测 | 切换 Codex、Claude 或直连会重载 agentd，界面在切换前提示移动连接可能断开、进行中任务可能受影响；入口策略只覆盖 IPv4 应用入口，不是系统防火墙；Tailcat 仍是实验连接，中继修改和身份重置需单独确认；Mimi 托管连接尚未开放。细节见 [GH-491 模块管理](implementation/gh-491-module-controls.md) |

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
- [共享 App Server](shared-ssh-app-server.md)：macOS / Linux 本机 control socket、Mac App launchd 前门、Codex Desktop 接入和显式远端 SSH。
- [Claude bridge 架构](claude-bridge-architecture.md)：Claude 实验通道的进程生命周期、权限、状态和失败模式。
- [DeepSeek Harness 接入协议](deepseek-harness-protocol.md)：agentd 与 Harness 之间的线路契约和授权边界。
- [GH-491 模块管理](implementation/gh-491-module-controls.md)：Mac App 运行时与连接方式开关的配置、入口策略和兼容性。
- [Tailscale 运维](tailscale-peer-relay-ops.md)：跨网络 Endpoint、Peer Relay、验证和回滚。
- [Tailcat 远程连接实验](operations/tailcat-experiment.md)：自建 Tailcat sidecar、扫码配对、中继配置和验证结果。
- [多 Mac 单活切换](multi-mac-single-active.md)：身份隔离、快速候选链路、缓存策略和 Release 真机门禁。
- [生产可达性审计](production-reachability-audit.md)：生产主链路与旧代码边界。
- [功能对照](codex-mac-feature-parity.md)：完整能力、缺口和优先级。
- [与 Litter 的能力对照](litter-comparison.md)：竞品能力差异、当前优势和不应进入首发的复杂度。
- [隐私政策](privacy-policy.md)：本地数据和网络边界。

## 风险与优化

- Tailscale 未连接时不会回退公网；Mac 与移动设备在同一局域网时可重新生成 LAN 配对信息，否则需恢复 Tailnet 或改用 Tailcat 实验连接。
- 当前 Endpoint 仍可能是 Tailscale 裸 IP 上的 HTTP；ATS 已收窄为本地网络和 `ts.net` 例外，并由应用层拒绝公网 HTTP。公开发布前继续完成真机验收并评估 MagicDNS `*.ts.net` + HTTPS。
- 旧 REST runtime 已删除。PTY session manager 和 stdio app-server client 仍有诊断、测试或平台消费者，但不在生产会话主链路；删除前必须分别完成可达性复核和全量回归。
- Claude 通道依赖外部 CLI 与 bridge，鉴权和生命周期仍弱于 Codex 主通道，不能作为默认路径；agentd 对 bridge 执行 `>=0.2.8` 版本门禁、强制关闭 bridge 级 bypass permissions（会话级完全访问只在请求完全访问档位且 bridge `>= 0.2.13` 时生效），版本不兼容时 fail closed 并给出升级命令。
- DeepSeek 通道依赖用户自行运行的 Harness，协议仍可能随 Harness 版本变化；agentd 只做固定 origin 的原生中继和授权裁剪，不维护模型供应商配置。
- 多 Mac 的本地单活档案已完成；Bonjour/SSH 自动发现、跨设备档案同步、Cloud thread、IDE sync、Browser / Computer Use 后置。在真实需求明确前不增加云端控制面或复杂分布式架构。
- 设计文档只描述目标或历史方案，不能覆盖当前代码事实。功能完成后要同步更新本文和对应专题文档，避免再次依赖会话历史判断现状。
