# 通过 SSH 接入同一个 Codex App Server

## 目标

Mimi 和远程 Codex CLI 连接 agentd 管理的同一个 Codex App Server 进程。远程链路使用 SSH 本地端口转发，不把 App Server 或 agentd HTTP 接口暴露到局域网。

这条链路不支持官方 Codex Desktop。Desktop 通过 SSH 打开项目时会启动自己的 App Server，不能接管 agentd 的进程。

## 主机配置

先在主机的 `config.json` 中启用独立入口：

```json
{
  "app_server": {
    "transport": "ws",
    "managed": true,
    "listen": "ws://127.0.0.1:4222",
    "remote_gateway": {
      "enabled": true,
      "listen": "127.0.0.1:8788"
    }
  }
}
```

生成只供远程 CLI 使用的 token，并重启 agentd：

```bash
agentd doctor --fix
agentd restart
```

`doctor --fix` 会创建权限为 `0600` 的 `remote_gateway.token_file`。该 token 与 Mimi 访问 token、App Server upstream token 相互独立。

首次远程打开项目前，必须先在主机信任该项目。远程入口不会接受 `config/batchWrite`：

```bash
agentd stop
codex -C /absolute/host/project
# 在 Codex 中确认信任，然后退出。
agentd start
```

## 远程连接

在远程设备建立 SSH 隧道。以下命令把远程设备的 `4500` 端口转发到主机的 remote gateway：

```bash
ssh -N \
  -L 4500:127.0.0.1:8788 \
  -o ExitOnForwardFailure=yes \
  devbox
```

通过受保护的渠道把主机 `remote_gateway.token_file` 的内容保存到远程设备。例如：

```bash
mkdir -p "$HOME/.config/mimi-remote"
chmod 700 "$HOME/.config/mimi-remote"
install -m 600 /dev/null "$HOME/.config/mimi-remote/remote-token"
scp devbox:/absolute/path/from/remote_gateway.token_file \
  "$HOME/.config/mimi-remote/remote-token"
```

启动 Codex CLI：

```bash
export MIMI_CODEX_REMOTE_TOKEN="$(tr -d '\r\n' < "$HOME/.config/mimi-remote/remote-token")"

codex \
  --remote ws://127.0.0.1:4500 \
  --remote-auth-token-env MIMI_CODEX_REMOTE_TOKEN \
  -C /absolute/host/project
```

`-C` 必须对应主机已经授权的项目路径。Codex CLI 也需要能够接受这个路径；跨操作系统或目录结构不一致时，先建立相同路径或改用 SSH 登录主机后运行 CLI。

## 使用边界

- remote gateway 默认关闭，只允许绑定 loopback。
- 同时只允许一个远程 CLI 连接。
- Mimi 和远程 CLI 可以先后接手同一线程，但同一线程同时只能启动一个 turn。
- 启用 remote gateway 时，Mimi 的 inline review 与普通 turn 共用同一门禁；`thread/compact/start` 暂时禁用，因为当前响应不提供可安全关联的 turn ID。
- 连接在 `turn/start` 后异常断开时，agentd 不会假定请求失败，也不会自动重放。若终态通知没有被任何连接观察到，需要重启 agentd 后再接手。
- 远程 CLI 可以读取经过过滤的当前项目配置和账号类型。它不能读取配置层、环境变量或 MCP 配置。
- v1 远程 CLI 不能写 Codex 配置，也不能调用 hooks、plugin、app、`review/start`、`thread/compact/start` 或未知协议方法。
- agentd 不提供重试或消息重放。客户端必须根据原始请求结果决定下一步。

## 轮换 token

以下命令原子替换 token。新 WebSocket 握手会立即拒绝旧 token，不需要重启 agentd：

```bash
agentd remote-token rotate
```

轮换后重新复制 token 文件，并重启远程 Codex CLI。已经建立的连接不会被强制中断。

## 验证

在主机确认监听器仍只绑定 loopback：

```bash
lsof -nP -iTCP:8788 -sTCP:LISTEN
```

在远程设备确认隧道和鉴权可用：

```bash
codex \
  --remote ws://127.0.0.1:4500 \
  --remote-auth-token-env MIMI_CODEX_REMOTE_TOKEN \
  -C /absolute/host/project
```

如果 TUI 要求重新信任项目，请退出，不要从远程写配置。回到主机完成信任步骤后重试。
