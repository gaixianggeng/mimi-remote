# Codex Desktop IPC 同步

## 目标

macOS 实验开关在 Mimi 的独立 App Server 上增加一层 Desktop IPC overlay。overlay 只负责把明确归属 Codex Desktop 的 Thread 投影到移动端，并把移动端操作交回当前 owner。它不创建共享 daemon，也不改变 Codex Desktop 的启动环境。

## 开启

Mac App 的“实验功能”中打开“同步 Codex Desktop 会话（实验）”。普通启停只重载 `agentd`，不会退出或重开 Codex Desktop。等状态显示“可用”后，再用同一条空闲会话完成跨端读写验证。

等价 CLI：

```bash
agentd runtime --codex-desktop-sync=enabled --json
agentd runtime --codex-desktop-sync=disabled --json
```

当前验证白名单包含 Codex Desktop `26.820.60940 (7119)` 和 `26.825.31414 (7287)`，对应 profile 为 `desktop-7119` 和 `desktop-7287`。Windows 始终使用独立 App Server。

开关开启后，overlay 仍以 Desktop 进程状态为触发条件：

- Desktop 已关闭：状态为 `desktop_not_running`，overlay 不参与请求，Mimi 完整使用独立 App Server。
- Desktop 正在运行且状态为 `ready`：启用 owner/follower，并按 Thread 的明确 owner 路由。
- Desktop 正在运行但连接中、build 不支持、socket 不可用或协议异常：暂停写操作，不向独立 App Server 猜测重跑；读请求仍可读取独立 App Server 中已有的历史。

Desktop 断开后，agentd 先失效旧 owner 和投影。下一次进程检查确认 Desktop 已关闭后，状态转为 `desktop_not_running`，独立 App Server 自动恢复正常读写，不需要重启 agentd。

## 传输和安全边界

- IPC socket 固定为 `$CODEX_HOME/ipc/ipc.sock`，采用 4 字节 little-endian 长度帧，单帧上限 64 MiB。
- `agentd` 只接受当前用户、无组或其他用户权限的 socket。
- 对端必须是已验证的 `com.openai.codex` bundle，Team ID 为 `2DC432GLL2`。
- build 7119 和 7287 的已验证方法版本如下；版本不匹配时进入 `protocol_error`：

  ```text
  initialize v1
  thread-stream-state-changed v11
  thread-read-state-changed v2
  thread-archived v2
  thread-follower-start-turn v2
  thread-follower-interrupt-turn v4
  thread-follower-edit-last-user-turn v2
  其余已支持的 thread-stream-*、thread-owner-discovery 和 thread-follower-* 为 v1
  ```
- 状态、日志和错误不会写入 socket 路径、IPC client ID、提示词或原始 `conversationState`。

跨端路由使用结构化 trace 记录 owner 判定、请求交付、Desktop 回执、Turn 状态和工具项状态。trace 只记录事件名、端类型、结果和不可逆的短标识；不记录提示词、命令、工作区、socket 路径或完整 Thread/Turn ID。

这是 Codex Desktop 的私有 IPC，不属于[官方 App Server 文档](https://learn.chatgpt.com/docs/app-server)的公开契约。Desktop 升级后必须先经过 build gate 和完整验收，不能根据版本号猜测协议兼容。

## Writer 和故障恢复

一个 Thread 同时只允许一个明确 writer：

- Desktop-owned Thread 的历史、实时事件、续问、Steer、中断、审批和补充输入由 Desktop 执行。
- Mimi-owned Thread 继续由独立 App Server 执行，并把标准事件投影给 Desktop follower。
- 只有 Desktop 明确返回 `no-client-found` 时，未送达操作才允许交给独立 App Server。
- IPC timeout、断线、协议错误或 owner 不明确时不本地重跑 Turn；返回可重试且交付状态不确定的错误，或保持只读。
- revision 缺口、patch 失败或断线后会重新请求完整历史，不猜测中间状态。

Mimi-owned Thread 使用以下方式挂载 Desktop follower：

1. 新 Thread 收到 `thread/started`，或已有 Thread 从 Mimi 发起下一次 `turn/start` 时，agentd 先确认 Desktop IPC 已经 `ready`。
2. 新 Thread 最多等待 5 秒，直到 App Server 的 rollout 文件可读。超时后仍可使用已知 Thread ID 尝试挂载。
3. agentd 先广播 `thread-stream-following-status-requested`，再打开带唯一 `mimi-follow` 查询参数的 `codex://threads/<thread-id>` 路由。
4. Desktop 返回 `thread-stream-following-changed(following=true)` 后，agentd 绑定该 follower，并立即发送 revision 连续的完整 snapshot。之后才发送 patch。
5. 每次等待确认 1500 毫秒，最多尝试 3 次。重复生命周期事件复用同一次激活；`following=false` 或 follower 断开后，下一次符合条件的操作可重新激活。

路由激活前会按 `com.openai.codex` bundle 精确确认 Desktop 已经运行，因此正常关闭状态不会主动冷启动 Desktop。macOS 的进程检查和 LaunchServices 路由分发不是一个原子操作；如果 Desktop 恰好在两者之间退出，系统仍可能重新拉起它。这是平台竞态，必须在真机验收中单独观察。激活失败只影响 Desktop follower 的挂载，不会切换 writer、取消或重放已经交给独立 App Server 的请求。
Desktop 关闭或 IPC 正在连接时，agentd 只保留最近一次有效的 Mimi 路由意图。Desktop 首次连接或重新连接后只恢复该路由，避免多个 gateway 或旧重试争抢 Desktop 前台。

agentd 使用 `desktop_ipc_route_requested`、`desktop_ipc_route_deferred`、`desktop_ipc_route_opened`、`desktop_ipc_route_following_confirmed`、`desktop_ipc_route_confirmation_timeout` 和 `desktop_ipc_route_exhausted` 记录路由阶段。每条日志只包含 Thread 短哈希、尝试次数、稳定原因和耗时，不包含原始 Thread ID、路由、IPC client ID 或会话内容。

状态接口中的 `desktop_sync.state` 只使用以下值：

`disabled`、`not_installed`、`desktop_not_running`、`connecting`、`ready`、`unsupported_build`、`socket_unavailable`、`protocol_error`、`legacy_cleanup_required`。

## 一次性遗留清理

如果升级时检测到旧共享模式的配置或文件，Mac App 会显示“需要清理旧配置”。确认 Codex Desktop 已退出后，才执行：

```bash
agentd runtime \
  --codex-desktop-sync=disabled \
  --cleanup-legacy-sharing-confirmed \
  --json
```

清理只处理 Mimi 旧 ownership 账本匹配的固定文件、plist、迁移标记和日志，并恢复 `shared_fallback` 中保存的独立 WebSocket 配置。未知 JSON 字段会保留；外部管理的 daemon 不会被停止或接管；重复执行是幂等的。清理完成后普通开关不再触碰旧资源。

## 能力边界

首版不投影 Desktop 私有选择、折叠状态和 Mimi 本地未读水位。未覆盖的 Desktop 写方法返回 `desktop_sync_method_unsupported` 和 `accepted=false`，不伪造成功。Browser、MCP、审批和工具执行仍由拥有该 Thread 的 Desktop 或独立 App Server 负责。

`turn/interrupt` 的验收语义是 Desktop 确认目标 Turn，Turn 进入 `interrupted`，且不再产生最终 assistant 回复。已启动的终端或工具进程由 Codex Desktop 自身收敛；其 item 可能稍后才进入终态，IPC overlay 不伪造进程级强制终止。

## 验证

单元和集成验证：

```bash
go test ./...
bash ./scripts/test-macos-app.sh
bash ./scripts/check-source-size.sh
bash ./scripts/check-third-party-notices.sh
bash ./scripts/verify-change.sh
```

真机验收使用 [MIM-148 跨端验收矩阵](mim-148-acceptance-matrix.md)。
