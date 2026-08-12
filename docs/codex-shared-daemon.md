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

1. 使用配置中的同一 `CODEX_HOME` 探测官方 Unix Socket，并完成 `initialize` / `initialized` 握手；stale socket 文件不算就绪；
2. 幂等安装 `com.gaixianggeng.mimi.codex-shared-daemon` 用户 LaunchAgent。`ProgramArguments` 直接执行官方 `codex app-server daemon start`，不经过 shell，也不托管自定义 daemon；agentd 不再直接 spawn Codex daemon；
3. 同时验证官方 standalone 可执行文件与 daemon lifecycle，确保注销或重启 Mac 后仍能冷启动；任一前置条件不完整都直接失败，配置与 Desktop 环境均不修改；
4. 原子保存当前 `app_server` transport 作为 `shared_fallback`，再切换到 `unix://`；
5. 重启并确认 agentd 的 runtime 状态为 `transport=unix`、`shared=true`、daemon 可连接；
6. 经 ownership 检查后，为 GUI 用户会话写入官方 daemon 开关、相同的 canonical `CODEX_HOME` 和 Mimi 私有的随机会话 marker，确保从 Dock / Finder 启动也生效；三键按事务写入，任一失败都会按相反顺序恢复，外部已有值不会被覆盖；
7. 如果启用前已有 daemon，owner 变更会持久标记为“待迁移”，不会静默中断它。稳定 owner 已安装后，如果未来又由 Codex 原生 SSH bootstrap 先抢到 socket，agentd 仍会在完成协议、版本、`CODEX_HOME` 和 standalone 路径验证后保持 attach，并重建该标记，不会在日常启动中停止它。该标记独立于五分钟 runtime 缓存，每次状态请求都实时读取，因此用户取消确认或先退出 Desktop 后入口仍保留。用户确认后，Desktop 正在运行时先请求它正常退出。旧 server 已由官方 pid backend 管理时执行官方 `daemon stop`；旧 server 是 Codex 原生 SSH bootstrap 直启链时，只有在同一私有 socket、当前用户、官方 standalone 真实路径、直接 `app-server --listen unix://` 命令行、PID 启动时间及 Desktop 最终退出状态全部两次匹配时，才向该唯一 PID 发送一次 `SIGTERM`。不使用进程组信号、`SIGKILL`、模糊进程名或自动重试。等待最长 15 秒，且旧 socket 持续拒绝连接 500 ms 后，才由 LaunchAgent 拉起一次并完成协议/生命周期/版本验证，成功后才重新打开 App；Desktop 已退出时只迁移 daemon，不擅自打开 App。任意检查或启动失败均保留待迁移标记并停止，不自动打开 Desktop；若旧进程在等待超时后才完成退出，用户稍后重试不会再发送第二次信号。两种情况都会短暂中断连接该 daemon 的手机、SSH 或 CLI；
8. 如果共享 daemon 后续异常退出，只有一次真实的移动端 gateway 连接失败后才会通过同一 LaunchAgent 恢复并重试；跨连接恢复串行且缓存最近 30 秒结果，恢复与独立 CLI 迁移还共用用户级文件锁，避免在 `stop/start` 中间被另一进程插入。永久故障不会堆积成多倍启动超时，高频 readiness 也不会拉起进程。

移动端写入前，gateway 还会复用现有 external activity 的精确 Thread / Turn ownership 证据：同一 thread 确认由 Codex Desktop 运行时，`turn/start`、`turn/steer`、中断和其他写操作会在转发前返回 `accepted=false`；`thread/resume` 与读取接口仍可用于只读观察。Desktop 仅打开空闲 thread 不会被当成占用。共享 Unix 模式下状态库不可读或观测器缺失时会 fail-closed，暂时拒绝写入但继续允许读取；默认独立 WS 没有共同 writer，仍保持原有可用性策略。

命令行等价操作：

```bash
agentd runtime --codex-sharing=enabled --json
agentd restart --no-pair
agentd status --json --runtime
agentd doctor
```

破坏性 daemon 迁移不是命令行等价操作。它由 Mac App 在用户确认后、并在
Codex Desktop 已正常退出的受控流程中调用内部 runtime 入口，避免脚本绕过原生
Desktop 的退出顺序。

### 关闭与回滚

关闭共享会恢复 Mimi 在 `shared_fallback` 中保存的 transport、listen、managed 和 token file，并卸载 Mimi 的 LaunchAgent 与待迁移标记；不会停止当前 daemon，因为 Desktop 可能仍在使用它。配置恢复与 owner 卸载是一个可回滚事务：owner 卸载失败时恢复原 shared 配置；既有 owner 内容更新后若 bootout、bootstrap、marker 或最终检查失败，也会恢复原 plist、加载状态和 marker。若当前 Unix backend 原本由用户或其他工具管理、没有 Mimi 的 fallback 账本，启用时只 attach 已经可握手的 socket，缺失时明确失败且绝不启动；禁用时只关闭 Desktop 环境并保留 backend，绝不虚构默认 WS 覆盖外部配置。配置更新后需要重启 agentd 与 Codex Desktop。

```bash
agentd runtime --codex-sharing=disabled --json
agentd restart --no-pair
```

旧 iOS 可能仍调用 `/api/app-server/thread-handoff`。当 agentd 配置为共享 daemon 时，它返回旧客户端可解码的 `already_released`，但不再执行 archive/unarchive；这个值只是兼容 ACK，不代表 agentd 已证明 Desktop 新进程实际采用 daemon。历史恢复日志仍会完成必要的 unarchive，避免升级中断留下归档状态。

## 风险与优化

- 官方 daemon 冷启动需要 `$CODEX_HOME/packages/standalone/current/codex`。已有健康 socket 但 standalone 缺失时，启用操作也会阻断，避免本次看似成功、Mac 重启后 agentd 持续拉起失败；Mimi Remote 不会静默执行 `curl | sh`，只给出官方安装指引。
- 共享架构把两端的会话一致性放在同一个官方 app-server 上，因此该 server 自身崩溃时 Codex Desktop 与 Mimi 会同时短暂失去后端。稳定 owner 只在 server 已不可连时尝试恢复它，不会为了恢复而退出或重开 Codex Desktop。
- Desktop 必须支持 local daemon，当前最低兼容 app-server 版本为 `0.141.0`。版本、socket 类型、目录权限、socket 权限和返回的 `codexHome` 都会在启用前校验。
- Desktop 的自定义 CLI、强制 CLI 或资源覆盖可能让它回退到独立 stdio。Mac App 会确认 agentd 已连接共享 daemon，并明确要求完全重启 Desktop；Desktop 是否采用 daemon 仍要通过下面的跨端验收验证，不能只根据环境变量推断成功。
- 稳定 LaunchAgent 的 `PATH` 会固定 Apple Silicon / Intel Homebrew 与系统工具目录，并在首次安装时追加调用进程可见的绝对用户工具目录；相对路径会被拒绝。之后 resident agentd 会复用已安装值，避免 MCP/plugin 路径随启动入口反复变化；需要完全自定义时可显式配置 `codex.env.PATH`。
- 为了让 Dock / Finder 启动同样生效，Mac App 使用当前 GUI 用户的 `launchctl` 环境。它只管理自己写入的两个官方键，并用第三个随机 marker 区分当前登录会话的 ownership；禁用时仅在三者仍匹配时恢复原值。agentd 启动 Codex 子进程时会过滤 Desktop 专属 transport 开关与 marker，`CODEX_HOME` 则刻意保持一致。该设置不会默认开启。
- `launchctl` 环境会在注销后消失；Mac App 只会为已经显式启用、backend 再次确认共享且三键均为空的用户生成新 marker 并恢复环境，不会借登录启动替新用户自动开启功能。新会话里其他程序即使写入相同的官方值，没有匹配 marker 也不会被 Mimi 认领。若 Desktop 比 Mimi 更早启动，设置页会保持“需要重启”，由用户确认后正常退出并重开。
- Unix Socket 的安全边界是当前用户私有目录与 `0600` socket；它不会暴露到 TCP，也不复用 iPad 的 Bearer Token 或旧 app-server capability token。
- LaunchAgent plist 可能包含为 Codex/MCP 配置的运行环境，因此固定为 `0600`，日志目录/文件也按当前用户私有权限创建；Desktop 专属 transport/ownership 环境变量由 job 的空值覆盖，避免继承 GUI 用户域值，同时保持 `launchd -> codex` 的直接进程链。
- LaunchAgent 已安装、socket 可握手和版本一致只能证明结构与协议闭环；macOS TCC 的最终文件权限归因必须用正式签名 App 做一次受保护目录读写验收，Doctor 会明确保留这项运行态要求，不把单元测试冒充为 TCC 证明。
- `thread/unsubscribe` 只取消当前连接订阅，不释放 writer；没有公开的单 thread takeover/unload RPC，因此不要重新叠加客户端 idle 猜测或自动抢占逻辑。

验收场景：

1. Desktop 打开同一 thread，不发送消息；手机发送下一条消息，应沿原 thread 成功。
2. Desktop 正在运行 turn；手机应显示只读，不能并发发送。
3. Desktop turn 完成并保持 thread 页面打开；手机再次发送，应成功。
4. 禁用共享并重启两端；agentd 应恢复原 WS 配置，已有配对与 thread ID 不变。
5. 杀掉共享 daemon 后从手机新建一次 gateway 连接，应由 LaunchAgent 自动恢复并只重试一次；已有 Desktop 空闲会话随后仍可读取。
6. 用签名的 Mimi Remote Mac 与 Codex Desktop 分别访问一个受保护目录，确认系统权限提示/授权不再归因到 Mimi 的旧 App 路径；该项不能由无签名单测替代。
