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
launchd LaunchAgent ──> OpenAI 签名 node supervisor（前台常驻）
                                  │ foreground child
                                  ▼
                         OpenAI 签名 codex app-server
                                  │
Codex Desktop ────────────────────┤
Mimi agentd ──────────────────────┘
                    $CODEX_HOME/app-server-control/app-server-control.sock
       ↑
iPhone / iPad 通过 /api/app-server/ws 继续经过鉴权、cwd 和方法策略
```

Desktop 使用官方 `CODEX_APP_SERVER_USE_LOCAL_DAEMON=1` 开关连接 Unix Socket；`agentd` 使用 WebSocket-over-UDS 连接同一 socket。writer 仍然是单写者，但所有客户端位于同一个 app-server 进程内，因此空闲 thread 的 `thread/resume` 会复用已加载实例，不再触发跨进程锁冲突。

Browser 原生授权读取的三级进程链必须是 `node_repl → codex app-server → node supervisor`。旧 `codex app-server daemon start` 会把 listener 脱离成 `PPID=1`，第三级落到 `launchd`，即使共享 socket 和新会话都正常，Browser 仍会拒绝。新 owner 使用 Codex Desktop bundle 内的签名 Node 保持为 app-server 直接父进程；Mimi、shell 和 launchd 都位于这三级之外。落盘前验证实际执行的 Node 与 codex 叶子程序的 Developer ID requirement，并要求 Node 位于可信 Desktop bundle 边界；运行后再从真实 socket peer 沿 PPID 读取内核 `csops` 的 signing identifier、Team ID 和 hardened-runtime 状态，不能只信 plist、路径或 `codesign -d` metadata。

默认仍保留独立 loopback WebSocket，避免没有安装官方 standalone daemon 的机器在升级后无法启动。共享功能只能由用户在 Mimi Remote Mac 设置中显式开启，或使用命令行开启。

## 实现

### 启用

Mac App 的“Codex Desktop → 共享本地 app-server 会话”会按以下顺序执行：

1. 使用配置中的同一 `CODEX_HOME` 探测官方 Unix Socket；已有 listener 必须完成 `initialize` / `initialized` 握手，stale socket 文件不算就绪；
2. 先把 `com.gaixianggeng.mimi.codex-shared-daemon` 用户 LaunchAgent 准备成 `RunAtLoad=false` 的 manual owner。`ProgramArguments` 直接以前台方式执行 Codex Desktop bundle 内的签名 Node supervisor，supervisor 再以前台 child 启动 `codex app-server --listen unix://`。不经过 shell、不使用 `daemon start`，也不托管自定义二进制。job 使用 `KeepAlive=false`，不设置 `AbandonProcessGroup`，并显式设置 `SoftResourceLimits/NumberOfFiles=8192`；上限由 supervisor、app-server 和 Browser/MCP 子进程逐级继承，不覆盖 hard limit。child 退出后 supervisor 同步退出，后续只由已有 gateway recovery 在真实连接失败时受控 kickstart。`NODE_OPTIONS`、`NODE_PATH` 等可改变 Node 启动代码的变量会被清空。此时绝不启动新 Unix daemon；
3. 对内置 Node 与配置解析出的 codex 叶子程序分别执行严格 Developer ID requirement 验证，要求固定 Team `2DC432GLL2`、对应 signing identifier 和 hardened runtime；Node 还必须位于 Codex Desktop bundle 的可信路径边界，codex 与 Node 的符号链接会固定到已经验证的真实版本路径。全新启用还会写入私有 durable intent；任一提交前条件不完整都直接失败并清理本次 owner，配置与 Desktop 环境均不修改；
4. 在 shared-daemon 操作锁内再次复核同一份原始配置，并用所有 Mimi 配置写入者共用的跨进程 CAS 锁，原子保存当前 `app_server` transport 为 `shared_fallback`、再切换到 `unix://`。只有配置 rename 已成功且启用前没有旧 listener，manual job 才会显式 `kickstart` 并校验完整协议、`CODEX_HOME`、standalone 路径、版本以及真实 `listener → signed node supervisor` 父链；foreground app-server 的 lifecycle `backend=nil` 在完整签名父链成立时是正常状态，不会被无条件放开。即使冷启动全部通过，也继续保留 marker 与 `RunAtLoad=false`，因为 kickstart 与 socket 建立之间不能原子证明是谁赢得 listener。durable intent 只用于恢复“rename 已完成但首次冷启动尚未完成”的崩溃窗口，第一次完整签名拓扑校验通过后立即消费，不能被后续普通 recovery 重用。首次启用和接管既有 listener 都必须经过第 7 步的用户确认，才清 marker 并提升为 `RunAtLoad=true`。配置提交后的启动失败会作为“已提交、待恢复”结果返回，Mac App 会重新加载状态；若进程在 rename 与 kickstart 之间退出，下一次 shared agentd 会在锁内复核配置身份后继续该 durable intent，但仍不会自动完成 owner 迁移；
5. 重启并确认 agentd 的 runtime 状态为 `transport=unix`、`shared=true`、daemon 可连接；
6. 经 ownership 检查后，为 GUI 用户会话写入官方 daemon 开关、相同的 canonical `CODEX_HOME` 和 Mimi 私有的随机会话 marker，确保从 Dock / Finder 启动也生效；三键按事务写入，任一失败都会按相反顺序恢复，外部已有值不会被覆盖；
7. 首次启用或启用前已有 daemon 时，owner 都会持久标记为“待迁移”，并把磁盘 plist 固定为 `RunAtLoad=false`，不会静默中断既有进程，也不会在注销、登录或 Mac 重启后自动完成迁移。旧 `pid` backend、SSH/CLI 直启 listener 或签名父链不成立的 listener 都只能保持 attach 并收敛到 pending，不能因为它们来自官方 codex 就冒充 Browser 可用的 stable 状态；只有真实 socket peer 的签名 supervisor 拓扑通过才算 stable。普通 ensure 在每个 `bootout/bootstrap` 前都会重新探测 socket：即使 listener 在 codesign 或 plist 落盘期间才出现，也会立刻把 owner 降成 manual+marker，绝不对活跃 launchd coalition 执行 bootout。仅 durable fresh-enable intent 且 socket 尚未创建时允许 manual job 恢复一次冷启动，恢复后仍保持 pending；其他 pending 掉线只等待用户再次确认。

   用户确认后，Desktop 正在运行时先请求它正常退出。旧 server 已由官方 `pid` backend 管理时执行官方 `daemon stop`；直接 listener（包括旧 SSH bootstrap 和已签名 supervisor child）只有在同一私有 socket、当前用户、官方 standalone 真实路径、直接 `app-server --listen unix://` argv、PID 启动时间及 Desktop 最终退出状态全部两次匹配时，才向该唯一 listener 发送一次 `SIGTERM`，supervisor 会逐次转发 `SIGHUP/SIGTERM/SIGINT` 且不使用 `SIGKILL`。等待旧 socket 持续拒绝连接 500 ms 且原 listener 的 PID/启动时间证据确认进程已经退出后，才 `bootout` 旧的已加载定义、`bootstrap` 磁盘上的 manual 新定义并 `kickstart` 一次。新进程必须完成协议、版本和运行态签名父链验证，全部通过后才清 intent/marker、把 plist 恢复为 `RunAtLoad=true`。上次已启动新签名 supervisor、但恰好在清 marker 前崩溃时，重试会直接提交健康进程，不再中断一次。任意失败都保留 manual+marker，不自动重试、强杀或打开 Desktop；
8. 在没有待迁移 marker 的正常已提交状态下，如果共享 daemon 后续异常退出，只有一次真实的移动端 gateway 连接失败后才会通过同一 LaunchAgent 恢复并重试；跨连接恢复串行且缓存最近 30 秒结果，恢复与显式迁移还共用用户级文件锁，避免在 `stop/start` 中间被另一进程插入。新安装或 reload 的 `RunAtLoad` job 已经启动 supervisor 时只等待其 socket，不会再 kickstart 第二套；登录时 job 已运行但 app-server socket 尚在冷启动，也会先等待一秒 grace。永久故障不会堆积成多倍启动超时，高频 readiness 也不会拉起进程。

Mac App 执行迁移的短命 `agentd` 控制命令有明确超时。超时后先发送普通 `SIGTERM`，两秒仍未退出才只回收该 control CLI；不会因此向共享 Codex daemon 发送 `SIGKILL`。manual plist 与迁移 marker 会继续保留，设置页退出“正在更新”并显示可重试错误，避免控制命令异常时无限卡住。

`runtime status` 与 Doctor 会从 Unix socket 的真实 peer PID 取证，不信任缓存 PID 或进程名；Darwin 上直接读取内核的打开 FD 数、启动时间和进程表中的直接子进程数，不额外启动 `lsof`、`ps` 或 `pgrep`。stable owner 的 `8192` 只标记为下一次启动的目标值，不冒充当前 listener 的实际 `RLIMIT_NOFILE`；macOS 无法可靠读取另一进程的实际 soft limit 时，百分比与资源等级保持 unknown，只展示绝对 FD 数和“当前进程未验证”。稳定 owner 的这一未知项作为正常信息展示，不制造无法消除的 WARN；将来只有取得实际生效上限后才按 70%/90% 阈值判断。AttachOnly / 外部 owner 同样不套用 Mimi 的上限，也不阻断转发。状态接口只返回 PID、计数、时间和枚举，不暴露命令行、环境、原始错误或 owner/socket 路径。

旧 `daemon start` 的 `pid` backend 无论是否返回精确 listener PID，都只标记为 `owner_claimed_unverified`；它证明官方 lifecycle 与 socket 对得上，但不能证明签名 Node 父链或实际继承的 FD soft limit。缺少 backend 且签名拓扑失败的旧 SSH/CLI listener 仍视为 unmanaged。两者都会等待显式迁移，不会被诊断误报成 Browser 可用的 stable。

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

关闭共享会恢复 Mimi 在 `shared_fallback` 中保存的 transport、listen、managed 和 token file，并删除 Mimi 的磁盘 LaunchAgent 与待迁移标记；不会停止当前 daemon，因为 Desktop 可能仍在使用它。已加载的 job registration 会保留到当前 GUI 会话注销：`bootout` 没有“不影响 launchd coalition 后代”的契约，删除未来登录入口已经足够阻止下次自动启动。即使进程在“plist 已删、marker 尚未清”之间崩溃，立即重试也会幂等清理 marker/intent，不要求先注销。事务顺序固定为：先把 owner 降为 manual 并移除未来启动入口，再 CAS 提交非共享配置。这样进程在任意一步退出，最多留下 `shared + 无 owner/manual owner`，不会形成 `WS + RunAtLoad=true`。owner 删除失败时配置不提交并保留 fail-closed 的 manual 状态；配置已被其他 writer 改动或提交失败时也不恢复可能已经失权的 auto owner，下一次明确操作再幂等收敛。`setup --force`、sharing、Claude、network 与 repair 写入共用配置提交锁；只有平台默认配置可以拥有或清理当前用户全局 LaunchAgent，自定义 `--config` profile 不会触碰默认服务的 owner。完整 stable-owner 共享目前只在 macOS 开放；非 macOS 升级后仍允许执行 disable 回退旧配置。若当前 Unix backend 原本由用户或其他工具管理、没有 Mimi 的 fallback 账本，启用时只 attach 已经可握手的 socket，缺失时明确失败且绝不启动；禁用时只关闭 Desktop 环境并保留 backend，绝不虚构默认 WS 覆盖外部配置。配置更新后需要重启 agentd 与 Codex Desktop。

```bash
agentd runtime --codex-sharing=disabled --json
agentd restart --no-pair
```

旧 iOS 可能仍调用 `/api/app-server/thread-handoff`。当 agentd 配置为共享 daemon 时，它返回旧客户端可解码的 `already_released`，但不再执行 archive/unarchive；这个值只是兼容 ACK，不代表 agentd 已证明 Desktop 新进程实际采用 daemon。历史恢复日志仍会完成必要的 unarchive，避免升级中断留下归档状态。

## 风险与优化

- 签名 supervisor 冷启动需要配置解析出的 codex 与 Codex Desktop bundle 内置 Node。已有健康 socket 但任一材料缺失或签名不符时，owner 更新也会阻断，避免本次看似成功、Mac 重启后持续拉起失败；Mimi Remote 不会静默下载替代二进制，只给出官方安装指引。
- 安全校验会把 `standalone/current/codex` 的符号链接固定到已验签的真实版本，避免验签与执行之间被替换。升级使 `current` 指向新版本且旧 listener 仍在运行时，新 plist 会进入 manual+marker，用户需要显式“应用待处理设置”；若当时没有 listener，则可安全自动 reload。使用 Desktop bundle 内稳定 codex 路径的安装不受该版本目录变化影响。
- 共享架构把两端的会话一致性放在同一个官方 app-server 上，因此该 server 自身崩溃时 Codex Desktop 与 Mimi 会同时短暂失去后端。稳定 owner 只在 server 已不可连时尝试恢复它，不会为了恢复而退出或重开 Codex Desktop。
- 8192 是防止过低 launchd soft limit 把资源累积过早放大成全能力故障，不是对子进程或 FD 泄漏的掩盖。Doctor 同时展示真实 FD 与直接子进程水位；持续上涨仍需定位 Codex/MCP 上游的回收责任。本方案不基于不完整的 external activity 证据自动 recycle 健康 daemon。
- Desktop 必须支持 local daemon，当前最低启动基线仍为 app-server `0.141.0`。这个版本检查只证明共享 daemon transport 可用，不代表更高版本的每个协议枚举都向后兼容；客户端请求仍必须跟随当前 app-server schema。发布回归至少覆盖 `0.141.x` 基线和当前支持版本，自动审批固定使用 `approvalPolicy=on-request`、`approvalsReviewer=auto_review` 与 `workspaceWrite`，不再发送已删除的 `on-failure`。版本、socket 类型、目录权限、socket 权限和返回的 `codexHome` 都会在启用前校验。
- Desktop 的自定义 CLI、强制 CLI 或资源覆盖可能让它回退到独立 stdio。Mac App 会确认 agentd 已连接共享 daemon，并明确要求完全重启 Desktop；Desktop 是否采用 daemon 仍要通过下面的跨端验收验证，不能只根据环境变量推断成功。
- 稳定 LaunchAgent 的 `PATH` 会固定 Apple Silicon / Intel Homebrew 与系统工具目录，并在首次安装时追加调用进程可见的绝对用户工具目录；相对路径会被拒绝。之后 resident agentd 会复用已安装值，避免 MCP/plugin 路径随启动入口反复变化；需要完全自定义时可显式配置 `codex.env.PATH`。
- 为了让 Dock / Finder 启动同样生效，Mac App 使用当前 GUI 用户的 `launchctl` 环境。它只管理自己写入的两个官方键，并用第三个随机 marker 区分当前登录会话的 ownership；禁用时仅在三者仍匹配时恢复原值。agentd 启动 Codex 子进程时会过滤 Desktop 专属 transport 开关与 marker，`CODEX_HOME` 则刻意保持一致。该设置不会默认开启。
- `launchctl` 环境会在注销后消失；Mac App 只会为已经显式启用、backend 再次确认共享且三键均为空的用户生成新 marker 并恢复环境，不会借登录启动替新用户自动开启功能。新会话里其他程序即使写入相同的官方值，没有匹配 marker 也不会被 Mimi 认领。若 Desktop 比 Mimi 更早启动，设置页会保持“需要重启”，由用户确认后正常退出并重开。
- Unix Socket 的安全边界是当前用户私有目录与 `0600` socket；它不会暴露到 TCP，也不复用 iPad 的 Bearer Token 或旧 app-server capability token。
- Mimi 自己的配置写入通过用户私有的跨进程文件锁与同源 raw snapshot CAS 串行；不遵守该协议的外部编辑器无法被强制加锁，因此最终 rename 前仍会复核 bytes 并在可检测冲突时 fail closed，但不会宣称能对任意第三方写入提供数据库级事务。
- LaunchAgent plist 可能包含为 Codex/MCP 配置的运行环境，因此固定为 `0600`，日志目录/文件也按当前用户私有权限创建；Desktop 专属 transport/ownership 变量与 Node 代码注入变量由 job 的空值覆盖。稳定运行链固定为 `launchd → signed node supervisor → signed codex`；launchd 位于 Browser 读取的 `node_repl → codex → node` 三级授权链之外。
- LaunchAgent 已安装、socket 可握手、版本一致和内核签名父链验证仍只证明本地结构闭环；Browser 的内部授权实现不是公开协议，正式发布必须用真实 Codex Desktop 新会话调用一次 Browser，并同时验证 Mimi/手机仍连接同一 socket。Doctor 和单元测试不能冒充这项端到端证明。
- `thread/unsubscribe` 只取消当前连接订阅，不释放 writer；没有公开的单 thread takeover/unload RPC，因此不要重新叠加客户端 idle 猜测或自动抢占逻辑。

验收场景：

1. Desktop 打开同一 thread，不发送消息；手机发送下一条消息，应沿原 thread 成功。
2. Desktop 正在运行 turn；手机应显示只读，不能并发发送。
3. Desktop turn 完成并保持 thread 页面打开；手机再次发送，应成功。
4. 禁用共享并重启两端；agentd 应恢复原 WS 配置，已有配对与 thread ID 不变。
5. 在没有待迁移 marker 的正常已提交状态下杀掉共享 daemon，再从手机新建一次 gateway 连接，应由 LaunchAgent 自动恢复并只重试一次；pending 状态下同样操作必须保持 manual owner，等待用户再次确认。
6. 在 Codex Desktop 新建一个从未在手机/iPad 打开的会话，调用 Browser 打开页面；应成功识别 Browser，同时 socket peer 的父链为 `node_repl → codex → node`，三个运行进程都满足 OpenAI Team/identifier 要求。
7. Browser 验收期间从 Mimi/手机继续同一共享会话，确认只有一个 app-server listener；重启 Codex Desktop、agentd 或 gateway 不应分叉成第二个 listener/supervisor。
8. 用签名的 Mimi Remote Mac 与 Codex Desktop 分别访问一个受保护目录，确认系统权限提示/授权不再归因到 Mimi 的旧 App 路径；该项不能由无签名单测替代。
