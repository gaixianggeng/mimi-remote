# Codex Desktop 共享 daemon

## 目标

Codex App Server 新版对 thread writer 增加了跨进程互斥。同一个 thread 被 Codex Desktop 的独立 app-server `thread/resume` 后，即使没有正在运行的 turn，另一个 app-server 进程也会在恢复时返回 `-32600 already has an active writer`。

本方案保证：

- Codex Desktop 只打开一个空闲会话时，iPhone / iPad 可以在原 thread 继续发送；
- Desktop 正在运行 turn、等待审批或等待补充输入时，移动端仍保持只读；
- 不创建 fork，不复制会话，也不通过 archive/unarchive 改变用户数据；
- 共享功能失败时不覆盖原有 WebSocket 配置，并可显式回滚。
- 日常启动、连接恢复和 agentd 重启都不退出、重开或强制终止 Codex Desktop；唯一例外是用户在 Mac App 设置页显式确认的一次性 owner 迁移。

## 方案

macOS 上显式启用 Codex 官方 local daemon：

```text
launchd LaunchAgent ──> 官方 codex daemon start ──> local daemon
                                                    │
Codex Desktop ──────────────────────────────────────┤
Mimi agentd ────────────────────────────────────────┘
                    $CODEX_HOME/app-server-control/app-server-control.sock
       ↑
iPhone / iPad 通过 /api/app-server/ws 继续经过鉴权、cwd 和方法策略
```

Desktop 使用官方 `CODEX_APP_SERVER_USE_LOCAL_DAEMON=1` 开关连接 Unix Socket；`agentd` 使用 WebSocket-over-UDS 连接同一 socket。writer 仍然是单写者，但所有客户端位于同一个 app-server 进程内，因此空闲 thread 的 `thread/resume` 会复用已加载实例，不再触发跨进程锁冲突。

默认仍保留独立 loopback WebSocket，避免没有安装官方 standalone daemon 的机器在升级后无法启动。共享功能只能由用户在 Mimi Remote Mac 设置中显式开启，或使用命令行开启。

## 实现

### 启用

Mac App 的“Codex Desktop → 共享本地 app-server 会话”会按以下顺序执行：

1. 使用配置中的同一 `CODEX_HOME` 探测官方 Unix Socket；已有 listener 必须完成 `initialize` / `initialized` 握手，stale socket 文件不算就绪；
2. 先把 `com.gaixianggeng.mimi.codex-shared-daemon` 用户 LaunchAgent 准备成 `RunAtLoad=false` 的 manual owner。`ProgramArguments` 直接执行官方 `codex app-server daemon start`，不经过 shell，也不托管自定义 daemon；job 显式设置 `SoftResourceLimits/NumberOfFiles=8192`，避免用户域 launchd 常见的 256 soft limit 让长期共享 daemon 同时丢失 Browser、Skills、MCP、Shell 与网络能力；不覆盖 hard limit。此时绝不启动新 Unix daemon；
3. 验证官方 standalone 可执行文件与 daemon lifecycle 冷启动能力。全新启用还会写入私有 durable intent；任一提交前条件不完整都直接失败并清理本次 owner，配置与 Desktop 环境均不修改；
4. 在 shared-daemon 操作锁内再次复核同一份原始配置，并用所有 Mimi 配置写入者共用的跨进程 CAS 锁，原子保存当前 `app_server` transport 为 `shared_fallback`、再切换到 `unix://`。只有配置 rename 已成功且启用前没有旧 listener，manual job 才会显式 `kickstart` 并校验完整协议、官方 pid backend、`CODEX_HOME`、standalone 路径和版本；即使冷启动全部通过，也继续保留 marker 与 `RunAtLoad=false`，因为 kickstart 与 socket 建立之间不能原子证明是谁赢得 listener。durable intent 只用于恢复“rename 已完成但首次冷启动尚未完成”的崩溃窗口，第一次完整 managed 校验通过后立即消费，不能被后续普通 recovery 重用。首次启用和接管既有 listener 都必须经过第 7 步的用户确认，才清 marker 并提升为 `RunAtLoad=true`。配置提交后的启动失败会作为“已提交、待恢复”结果返回，Mac App 会重新加载状态；若进程在 rename 与 kickstart 之间退出，下一次 shared agentd 会在锁内复核配置身份后继续该 durable intent，但仍不会自动完成 owner 迁移；
5. 重启并确认 agentd 的 runtime 状态为 `transport=unix`、`shared=true`、daemon 可连接；
6. 经 ownership 检查后，为 GUI 用户会话写入官方 daemon 开关、相同的 canonical `CODEX_HOME` 和 Mimi 私有的随机会话 marker，确保从 Dock / Finder 启动也生效；三键按事务写入，任一失败都会按相反顺序恢复，外部已有值不会被覆盖；
7. 首次启用或启用前已有 daemon 时，owner 都会持久标记为“待迁移”，并把磁盘 plist 固定为 `RunAtLoad=false`，不会静默中断既有进程，也不会在注销、登录或 Mac 重启后自动完成迁移。稳定 owner 已安装后，如果未来又由 Codex 原生 SSH bootstrap 先抢到 socket，agentd 仍会在完成协议、版本、`CODEX_HOME` 和 standalone 路径验证后保持 attach，并把 owner 收敛回同一 pending 状态；socket 仍可连接时普通启动只 attach；仅 durable fresh-enable intent 且 socket 尚未创建时允许 manual job 恢复一次冷启动，恢复后仍保持 pending。其他 socket 不可连接场景下普通启动和 gateway recovery 直接返回 pending，既不 `kickstart` 也不清 marker。该标记独立于五分钟 runtime 缓存，每次状态请求都实时读取，因此用户取消确认或先退出 Desktop 后入口仍保留。用户确认后，Desktop 正在运行时先请求它正常退出。旧 server 已由官方 pid backend 管理时执行官方 `daemon stop`；旧 server 是 Codex 原生 SSH bootstrap 直启链时，只有在同一私有 socket、当前用户、官方 standalone 真实路径、直接 `app-server --listen unix://` 命令行、PID 启动时间及 Desktop 最终退出状态全部两次匹配时，才向该唯一 PID 发送一次 `SIGTERM`。官方 stop 与新 daemon kickstart 各自在副作用前按固定 bundle ID 最终复核 Desktop，App 已重开或 LaunchServices 查询失败都立即停止迁移。不使用进程组信号、`SIGKILL`、模糊进程名或自动重试。等待最长 15 秒，且旧 socket 持续拒绝连接 500 ms 后，才由 LaunchAgent 拉起一次并完成协议/生命周期/版本验证；全部通过后才清 intent/marker、把 plist 恢复为 `RunAtLoad=true`，并按实际执行时的 Desktop 状态决定是否重新打开 App。任意检查或启动失败均保留 manual plist 与待迁移标记，不自动打开 Desktop；若旧进程在等待超时后才完成退出，用户稍后重试不会再发送第二次信号。两种情况都会短暂中断连接该 daemon 的手机、SSH 或 CLI；
8. 在没有待迁移 marker 的正常已提交状态下，如果共享 daemon 后续异常退出，只有一次真实的移动端 gateway 连接失败后才会通过同一 LaunchAgent 恢复并重试；跨连接恢复串行且缓存最近 30 秒结果，恢复与显式迁移还共用用户级文件锁，避免在 `stop/start` 中间被另一进程插入。永久故障不会堆积成多倍启动超时，高频 readiness 也不会拉起进程。

Mac App 执行迁移的短命 `agentd` 控制命令有明确超时。超时后先发送普通 `SIGTERM`，两秒仍未退出才只回收该 control CLI；不会因此向共享 Codex daemon 发送 `SIGKILL`。manual plist 与迁移 marker 会继续保留，设置页退出“正在更新”并显示可重试错误，避免控制命令异常时无限卡住。

`runtime status` 与 Doctor 会从 Unix socket 的真实 peer PID 取证，不信任缓存 PID 或进程名；Darwin 上直接读取内核的打开 FD 数、启动时间和进程表中的直接子进程数，不额外启动 `lsof`、`ps` 或 `pgrep`。stable owner 的 `8192` 只标记为下一次启动的目标值，不冒充当前 listener 的实际 `RLIMIT_NOFILE`；macOS 无法可靠读取另一进程的实际 soft limit 时，百分比与资源等级保持 unknown，只展示绝对 FD 数和“当前进程未验证”。将来只有取得实际生效上限后才按 70%/90% 阈值判断。AttachOnly / 外部 owner 同样不套用 Mimi 的上限，也不阻断转发。状态接口只返回 PID、计数、时间和枚举，不暴露命令行、环境、原始错误或 owner/socket 路径。

官方 `daemon start` 完成 detached listener 交接后，部分版本仍报告 `pid` backend，但不会继续返回 listener PID。只有 stable owner 已提交、socket 路径一致且 backend 仍为 `pid` 时，才标记为 `owner_claimed_unverified` warning；缺少 backend 的旧 SSH/CLI listener 仍视为 unmanaged。该 warning 既不把当前 listener 误报为已验证 stable，也不把 owner 的目标上限当成 listener 已实际继承。

移动端写入前，gateway 还会复用现有 external activity 的精确 Thread / Turn ownership 证据：同一 thread 确认由 Codex Desktop 运行时，`turn/start`、`turn/steer`、中断和其他写操作会在转发前返回 `accepted=false`；对 app-server 发给客户端的审批、补充输入和 MCP elicitation，移动端返回的反向 JSON-RPC response 也执行相同 guard，拒绝时保留 pending request 并恢复移动端卡片。`thread/resume` 与读取接口仍可用于只读观察。Desktop 仅打开空闲 thread 不会被当成占用。共享 Unix 模式下状态库不可读、观测器缺失或反向 request 缺少 thread scope 时会 fail-closed，暂时拒绝写入但继续允许读取；默认独立 WS 没有共同 writer，仍保持原有可用性策略。

命令行等价操作：

```bash
agentd runtime --codex-sharing=enabled --json
agentd restart --no-pair
agentd status --json --runtime
agentd doctor
```

破坏性 daemon 迁移的两个 CLI flag 是防误触 interlock，不是可信调用方鉴权。正式
产品只由 Mac App 在用户确认后、并在 Codex Desktop 已正常退出的受控流程中调用；
Go 端仍会实时复核 marker、owner 和 Desktop 状态。同一用户下的其他进程也能自行传入
这两个公开 flag，因此不能把它们表述成“只有设置页才能授权”的安全边界；若未来需要
可信来源认证，应改用带 audit token / code-sign requirement 的 XPC 或等价可信 IPC。

### 关闭与回滚

关闭共享会恢复 Mimi 在 `shared_fallback` 中保存的 transport、listen、managed 和 token file，并卸载 Mimi 的 LaunchAgent 与待迁移标记；不会停止当前 daemon，因为 Desktop 可能仍在使用它。事务顺序固定为：先把 owner 降为 manual 并移除未来启动入口，再 CAS 提交非共享配置。这样进程在任意一步退出，最多留下 `shared + 无 owner/manual owner`，不会形成 `WS + RunAtLoad=true`。owner 卸载失败时配置不提交并保留 fail-closed 的 manual 状态；配置已被其他 writer 改动或提交失败时也不恢复可能已经失权的 auto owner，下一次明确操作再幂等收敛。`setup --force`、sharing、Claude、network 与 repair 写入共用配置提交锁；只有平台默认配置可以拥有或清理当前用户全局 LaunchAgent，自定义 `--config` profile 不会触碰默认服务的 owner。完整 stable-owner 共享目前只在 macOS 开放；非 macOS 升级后仍允许执行 disable 回退旧配置。若当前 Unix backend 原本由用户或其他工具管理、没有 Mimi 的 fallback 账本，启用时只 attach 已经可握手的 socket，缺失时明确失败且绝不启动；禁用时只关闭 Desktop 环境并保留 backend，绝不虚构默认 WS 覆盖外部配置。配置更新后需要重启 agentd 与 Codex Desktop。

```bash
agentd runtime --codex-sharing=disabled --json
agentd restart --no-pair
```

旧 iOS 可能仍调用 `/api/app-server/thread-handoff`。当 agentd 配置为共享 daemon 时，它返回旧客户端可解码的 `already_released`，但不再执行 archive/unarchive；这个值只是兼容 ACK，不代表 agentd 已证明 Desktop 新进程实际采用 daemon。历史恢复日志仍会完成必要的 unarchive，避免升级中断留下归档状态。

## 风险与优化

- 官方 daemon 冷启动需要 `$CODEX_HOME/packages/standalone/current/codex`。已有健康 socket 但 standalone 缺失时，启用操作也会阻断，避免本次看似成功、Mac 重启后 agentd 持续拉起失败；Mimi Remote 不会静默执行 `curl | sh`，只给出官方安装指引。
- 共享架构把两端的会话一致性放在同一个官方 app-server 上，因此该 server 自身崩溃时 Codex Desktop 与 Mimi 会同时短暂失去后端。稳定 owner 只在 server 已不可连时尝试恢复它，不会为了恢复而退出或重开 Codex Desktop。
- 8192 是防止过低 launchd soft limit 把资源累积过早放大成全能力故障，不是对子进程或 FD 泄漏的掩盖。Doctor 同时展示真实 FD 与直接子进程水位；持续上涨仍需定位 Codex/MCP 上游的回收责任。本方案不基于不完整的 external activity 证据自动 recycle 健康 daemon。
- Desktop 必须支持 local daemon，当前最低兼容 app-server 版本为 `0.141.0`。版本、socket 类型、目录权限、socket 权限和返回的 `codexHome` 都会在启用前校验。
- Desktop 的自定义 CLI、强制 CLI 或资源覆盖可能让它回退到独立 stdio。Mac App 会确认 agentd 已连接共享 daemon，并明确要求完全重启 Desktop；Desktop 是否采用 daemon 仍要通过下面的跨端验收验证，不能只根据环境变量推断成功。
- 稳定 LaunchAgent 的 `PATH` 会固定 Apple Silicon / Intel Homebrew 与系统工具目录，并在首次安装时追加调用进程可见的绝对用户工具目录；相对路径会被拒绝。之后 resident agentd 会复用已安装值，避免 MCP/plugin 路径随启动入口反复变化；需要完全自定义时可显式配置 `codex.env.PATH`。
- 为了让 Dock / Finder 启动同样生效，Mac App 使用当前 GUI 用户的 `launchctl` 环境。它只管理自己写入的两个官方键，并用第三个随机 marker 区分当前登录会话的 ownership；禁用时仅在三者仍匹配时恢复原值。agentd 启动 Codex 子进程时会过滤 Desktop 专属 transport 开关与 marker，`CODEX_HOME` 则刻意保持一致。该设置不会默认开启。
- `launchctl` 环境会在注销后消失；Mac App 只会为已经显式启用、backend 再次确认共享且三键均为空的用户生成新 marker 并恢复环境，不会借登录启动替新用户自动开启功能。新会话里其他程序即使写入相同的官方值，没有匹配 marker 也不会被 Mimi 认领。若 Desktop 比 Mimi 更早启动，设置页会保持“需要重启”，由用户确认后正常退出并重开。
- Unix Socket 的安全边界是当前用户私有目录与 `0600` socket；它不会暴露到 TCP，也不复用 iPad 的 Bearer Token 或旧 app-server capability token。
- Mimi 自己的配置写入通过用户私有的跨进程文件锁与同源 raw snapshot CAS 串行；不遵守该协议的外部编辑器无法被强制加锁，因此最终 rename 前仍会复核 bytes 并在可检测冲突时 fail closed，但不会宣称能对任意第三方写入提供数据库级事务。
- LaunchAgent plist 可能包含为 Codex/MCP 配置的运行环境，因此固定为 `0600`，日志目录/文件也按当前用户私有权限创建；Desktop 专属 transport/ownership 环境变量由 job 的空值覆盖，避免继承 GUI 用户域值，同时保持 `launchd -> codex` 的直接进程链。
- LaunchAgent 已安装、socket 可握手和版本一致只能证明结构与协议闭环；macOS TCC 的最终文件权限归因必须用正式签名 App 做一次受保护目录读写验收，Doctor 会明确保留这项运行态要求，不把单元测试冒充为 TCC 证明。
- `thread/unsubscribe` 只取消当前连接订阅，不释放 writer；没有公开的单 thread takeover/unload RPC，因此不要重新叠加客户端 idle 猜测或自动抢占逻辑。

验收场景：

1. Desktop 打开同一 thread，不发送消息；手机发送下一条消息，应沿原 thread 成功。
2. Desktop 正在运行 turn；手机应显示只读，不能并发发送。
3. Desktop turn 完成并保持 thread 页面打开；手机再次发送，应成功。
4. 禁用共享并重启两端；agentd 应恢复原 WS 配置，已有配对与 thread ID 不变。
5. 在没有待迁移 marker 的正常已提交状态下杀掉共享 daemon，再从手机新建一次 gateway 连接，应由 LaunchAgent 自动恢复并只重试一次；pending 状态下同样操作必须保持 manual owner，等待用户再次确认。
6. 用签名的 Mimi Remote Mac 与 Codex Desktop 分别访问一个受保护目录，确认系统权限提示/授权不再归因到 Mimi 的旧 App 路径；该项不能由无签名单测替代。
