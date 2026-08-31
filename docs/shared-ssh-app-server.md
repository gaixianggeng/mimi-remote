# 共享 SSH App Server

本文只描述 macOS/Linux 的共享 SSH transport。Windows `agentd` 宿主管理一个 loopback WebSocket App Server，不使用 Unix Socket、SSH proxy 或 Desktop 私有 IPC。

## 目标

Mimi、Windows Codex Desktop 和本机 Codex Desktop 通过 SSH 连接同一个 Unix App Server。任一入口创建的普通 Codex Thread 都可以由其他入口接续。

```text
Mimi App -> agentd 鉴权 WebSocket -> localhost SSH -> codex app-server proxy --┐
本机 Desktop -----------------------> localhost SSH -> proxy -----------------+-> ~/.codex/app-server-control/app-server-control.sock
远程 Desktop -------------------------------> Mac SSH -> proxy ---------------┘
```

OpenClaw 和 Desktop 的普通 “This Mac” 模式继续使用自己的 App Server。agentd 不枚举、不停止，也不重配这些进程。

## 配置

`~/Library/Application Support/mimi-remote/config.json` 的 Codex 部分使用以下配置：

```json
{
  "app_server": {
    "transport": "ssh",
    "ssh_target": "127.0.0.1",
    "auto_title": true
  }
}
```

`ssh_target` 是传给 OpenSSH 的单个目标参数。它可以是主机名、`user@host`，或 `~/.ssh/config` 中的 Host 别名。目标必须登录运行共享 App Server 的同一个 macOS 用户，并使用同一个默认 `~/.codex`。

首次 `setup` / `up` 可以用命令行参数或环境变量指定目标。命令行参数优先；成功预检后，目标会写入配置，后台服务不需要继承安装终端的环境变量：

```bash
agentd up --app-server-ssh-target user@mac-host
AGENTD_APP_SERVER_SSH_TARGET=user@mac-host agentd up
```

agentd 不保存 SSH 密码或私钥。启动前必须确保 Remote Login、host key 和非交互密钥认证可用：

```bash
ssh 127.0.0.1 codex --version
```

首次运行会要求确认本机 SSH host key。命令必须在无需输入登录密码的情况下成功。完成后运行：

```bash
agentd doctor
agentd up --no-pair
agentd status
```

## 启动与连接

agentd 先通过 SSH 打开 `codex app-server proxy` 并执行真实 WebSocket 初始化。若默认 Unix Socket 尚未提供服务，agentd 才通过同一个 SSH 目标后台启动：

```bash
open_file_limit=$(ulimit -Sn)
if test "$open_file_limit" != unlimited && test "$open_file_limit" -lt 8192; then
  ulimit -Sn 8192
fi
CODEX_INTERNAL_APP_SERVER_REMOTE_CONTROL_DISABLED=1 \
  codex -c features.code_mode_host=true app-server --listen unix://
```

SSH 登录在 macOS 上的 open-file soft limit 通常只有 256。agentd 启动新 resident 前会读取当前值；低于 8192 时先提高到 8192，无法提高时拒绝启动。它不会降低已经更高的限制。

这个容量余量不能替代订阅释放。App Server 会为每个已加载 Thread 保留 session 和 MCP 资源；取消最后一个订阅后，官方实现仍有 30 分钟无活动宽限期，之后才卸载 Thread。

这个 App Server 只接受 Unix Socket 上的 SSH proxy 连接。启动命令会关闭它的 Remote Control 注册，防止它继承 Desktop 已保存的同一套服务端身份。ChatGPT 移动端和 Desktop 普通 “This Mac” 模式继续连接官方 App Server，不会被 SSH resident 接管。

agentd 在进程内串行执行探测与启动。多个入口同时尝试启动时，只有成功绑定默认 Socket 的 App Server 成为 owner；其余 proxy 连接这个 owner。

agentd 或单条 Mimi WebSocket 退出时只关闭对应 SSH proxy，不停止共享 App Server。SSH、Codex 版本或协议初始化失败时，agentd 明确失败，不回退到独立 WebSocket、stdio 或 Desktop IPC。

若默认 Socket 文件仍存在，但 proxy 无法完成初始化，agentd 会停止并报告错误。它不会猜测 owner 或删除共享 Socket。先在 SSH 目标上确认没有仍在使用该 Socket 的 App Server，再手工运行上面的 `codex ... app-server --listen unix://`；Codex 会按自己的启动锁和 stale-socket 规则恢复。

## 会话和消息规则

- `thread/start` 创建 Thread，`thread/resume` 订阅和接续现有 Thread。
- Mimi 在同一个 Thread 的最后一个本地事件观察者离开时发送 `thread/unsubscribe`。同一 Thread 有多个观察者时，只由最后一个离开的观察者退订。物理连接异常结束时不为退订重新建立连接；App Server 会清理断开连接上的订阅。
- Mimi 的普通消息只使用 `thread/queue/add`。运行中的 Thread 会在 App Server 内排队，空闲后自动开始，不会被误解释成 `turn/steer`。
- 同一个 Thread 同时最多有一条由 Mimi 提交、尚未开始的服务端队列消息。下一条继续保留在 Mimi 本地，避免后一次线程设置覆盖前一条尚未开始的消息。
- 发送结果不确定时，Mimi 使用相同的 `clientUserMessageId` 完整分页查询 `thread/queue/list` 和 `thread/items/list`，并在两者切换的竞态窗口再次查询队列。找不到记录时保留待发送状态，由用户确认是否重试。
- 模型、工作目录、权限和协作模式属于共享 Thread 状态。Mimi 创建新 Thread 时通过 `thread/start` 写入初始设置；恢复 Thread 或发送普通消息时不隐式覆盖当前设置。其他入口可以继续修改这些共享设置。
- 历史读取使用 `thread/read(includeTurns:false)`、`thread/turns/list` 和 `thread/items/list`，不再请求整段历史。
- 标准审批和补充输入会广播给订阅该 Thread 的入口，第一个响应生效。Mimi 不自动拒绝未知的 Desktop 私有请求。

## Desktop 使用方式

本机 Desktop 需要新增一个指向 `127.0.0.1` 的 SSH 主机，并从这个主机打开共享项目。远程 Desktop 使用指向这台 Mac 的 SSH 主机。两个入口都必须登录与 agentd 相同的 macOS 用户。

普通 “This Mac” 模式仍可用于 ChatGPT Desktop 私有的 `codex_app`、Browser 和专用渲染能力，但它不属于共享运行时。不要同时用普通本地模式和 SSH 模式打开同一个活动 Thread。

Thread writer 锁仍然生效。若普通 “This Mac” 模式和共享 SSH 模式同时恢复同一个活动 Thread，后恢复的一方会明确失败。该限制用于保护历史文件，不能通过取消 writer 锁规避。

## 诊断与验收

```bash
agentd doctor
agentd status --json
ps -axo pid,ppid,command | grep '[c]odex.*app-server'
lsof -U | grep app-server-control.sock
```

升级到包含 open-file 修复的版本后，已经运行的 resident 不会自动获得新限制。先结束所有共享 Thread 的活动 Turn，并关闭对应的 Mimi 和 SSH Desktop 页面。然后核对并重启唯一的 Unix resident：

```bash
ps -axo pid=,ppid=,command= | grep '[c]odex.*app-server --listen unix://'
kill -TERM <上一步确认的-resident-pid>
agentd doctor
```

不要对模糊的 `pgrep codex` 结果批量执行 `kill`。普通 “This Mac”、OpenClaw 和共享 SSH resident 可能同时存在。

验收至少覆盖：Mimi-first、远程 Desktop-first、本机 Desktop-first、并发排队、审批首响应、agentd 重启和分页历史。验收前后分别记录 OpenClaw 的 App Server PID；二者必须保持不变。

`thread/queue/*` 当前是 Codex 实验接口。本版本要求远端 Codex 不低于已验证的 `0.149.1`；接口不支持时发送会明确失败，不降级为有竞态的 `turn/start`。
