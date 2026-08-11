# Codex Desktop 共享 daemon

## 目标

Codex App Server 新版对 thread writer 增加了跨进程互斥。同一个 thread 被 Codex Desktop 的独立 app-server `thread/resume` 后，即使没有正在运行的 turn，另一个 app-server 进程也会在恢复时返回 `-32600 already has an active writer`。

本方案保证：

- Codex Desktop 只打开一个空闲会话时，iPhone / iPad 可以在原 thread 继续发送；
- Desktop 正在运行 turn、等待审批或等待补充输入时，移动端仍保持只读；
- 不创建 fork，不复制会话，也不通过 archive/unarchive 改变用户数据；
- 共享功能失败时不覆盖原有 WebSocket 配置，并可显式回滚。

## 方案

macOS 上显式启用 Codex 官方 local daemon：

```text
Codex Desktop ─┐
               ├─ $CODEX_HOME/app-server-control/app-server-control.sock
Mimi agentd ───┘
       ↑
iPhone / iPad 通过 /api/app-server/ws 继续经过鉴权、cwd 和方法策略
```

Desktop 使用官方 `CODEX_APP_SERVER_USE_LOCAL_DAEMON=1` 开关连接 Unix Socket；`agentd` 使用 WebSocket-over-UDS 连接同一 socket。writer 仍然是单写者，但所有客户端位于同一个 app-server 进程内，因此空闲 thread 的 `thread/resume` 会复用已加载实例，不再触发跨进程锁冲突。

默认仍保留独立 loopback WebSocket，避免没有安装官方 standalone daemon 的机器在升级后无法启动。共享功能只能由用户在 Mimi Remote Mac 设置中显式开启，或使用命令行开启。

## 实现

### 启用

Mac App 的“Codex Desktop → 共享本地 app-server 会话”会按以下顺序执行：

1. 使用配置中的同一 `CODEX_HOME` 探测官方 Unix Socket，并完成 `initialize` / `initialized` 握手；
2. socket 不存在时，只调用官方 `codex app-server daemon start`，不创建自定义常驻进程；
3. 同时验证官方 standalone 可执行文件与 daemon lifecycle，确保注销或重启 Mac 后仍能冷启动；任一前置条件不完整都直接失败，配置与 Desktop 环境均不修改；
4. 原子保存当前 `app_server` transport 作为 `shared_fallback`，再切换到 `unix://`；
5. 重启并确认 agentd 的 runtime 状态为 `transport=unix`、`shared=true`、daemon 可连接；
6. 经 ownership 检查后，为 GUI 用户会话写入官方 daemon 开关、相同的 canonical `CODEX_HOME` 和 Mimi 私有的随机会话 marker，确保从 Dock / Finder 启动也生效；三键按事务写入，任一失败都会按相反顺序恢复，外部已有值不会被覆盖；
7. 已运行的 Desktop 不会被静默杀死。用户确认“重启并应用”后，只请求正常退出，等待完全结束，再通过 LaunchServices 启动同一个 App；不会 `forceTerminate`，也不会并存第二实例。

移动端写入前，gateway 还会复用现有 external activity 的精确 Thread / Turn ownership 证据：同一 thread 确认由 Codex Desktop 运行时，`turn/start`、`turn/steer`、中断和其他写操作会在转发前返回 `accepted=false`；`thread/resume` 与读取接口仍可用于只读观察。只有“正在运行”的明确证据才会触发该保护，Desktop 仅打开空闲 thread 不会被当成占用；状态库短暂不可读时也不会猜测为 active。

命令行等价操作：

```bash
agentd runtime --codex-sharing=enabled --json
agentd restart --no-pair
agentd status --json --runtime
agentd doctor
```

### 关闭与回滚

关闭共享会恢复 Mimi 在 `shared_fallback` 中保存的 transport、listen、managed 和 token file；不会停止官方 daemon，因为 Desktop 可能仍在使用它。若当前 Unix backend 原本由用户或其他工具管理、没有 Mimi 的 fallback 账本，则只关闭 Desktop 环境并保留 backend，绝不虚构默认 WS 覆盖外部配置。配置更新后需要重启 agentd 与 Codex Desktop。

```bash
agentd runtime --codex-sharing=disabled --json
agentd restart --no-pair
```

旧 iOS 可能仍调用 `/api/app-server/thread-handoff`。当 agentd 配置为共享 daemon 时，它返回旧客户端可解码的 `already_released`，但不再执行 archive/unarchive；这个值只是兼容 ACK，不代表 agentd 已证明 Desktop 新进程实际采用 daemon。历史恢复日志仍会完成必要的 unarchive，避免升级中断留下归档状态。

## 风险与优化

- 官方 daemon 冷启动需要 `$CODEX_HOME/packages/standalone/current/codex`。已有健康 socket 但 standalone 缺失时，启用操作也会阻断，避免本次看似成功、Mac 重启后 agentd 持续拉起失败；Mimi Remote 不会静默执行 `curl | sh`，只给出官方安装指引。
- Desktop 必须支持 local daemon，当前最低兼容 app-server 版本为 `0.141.0`。版本、socket 类型、目录权限、socket 权限和返回的 `codexHome` 都会在启用前校验。
- Desktop 的自定义 CLI、强制 CLI 或资源覆盖可能让它回退到独立 stdio。Mac App 会确认 agentd 已连接共享 daemon，并明确要求完全重启 Desktop；Desktop 是否采用 daemon 仍要通过下面的跨端验收验证，不能只根据环境变量推断成功。
- 为了让 Dock / Finder 启动同样生效，Mac App 使用当前 GUI 用户的 `launchctl` 环境。它只管理自己写入的两个官方键，并用第三个随机 marker 区分当前登录会话的 ownership；禁用时仅在三者仍匹配时恢复原值。agentd 启动 Codex 子进程时会过滤 Desktop 专属 transport 开关与 marker，`CODEX_HOME` 则刻意保持一致。该设置不会默认开启。
- `launchctl` 环境会在注销后消失；Mac App 只会为已经显式启用、backend 再次确认共享且三键均为空的用户生成新 marker 并恢复环境，不会借登录启动替新用户自动开启功能。新会话里其他程序即使写入相同的官方值，没有匹配 marker 也不会被 Mimi 认领。若 Desktop 比 Mimi 更早启动，设置页会保持“需要重启”，由用户确认后正常退出并重开。
- Unix Socket 的安全边界是当前用户私有目录与 `0600` socket；它不会暴露到 TCP，也不复用 iPad 的 Bearer Token 或旧 app-server capability token。
- `thread/unsubscribe` 只取消当前连接订阅，不释放 writer；没有公开的单 thread takeover/unload RPC，因此不要重新叠加客户端 idle 猜测或自动抢占逻辑。

验收场景：

1. Desktop 打开同一 thread，不发送消息；手机发送下一条消息，应沿原 thread 成功。
2. Desktop 正在运行 turn；手机应显示只读，不能并发发送。
3. Desktop turn 完成并保持 thread 页面打开；手机再次发送，应成功。
4. 禁用共享并重启两端；agentd 应恢复原 WS 配置，已有配对与 thread ID 不变。
