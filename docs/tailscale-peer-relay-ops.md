# Tailscale 直连与上海 Peer Relay 运维手册

## 目标

Mimi Remote 只配置并访问 Mac 的 Tailscale Endpoint。App 不维护公网备用地址，也不感知底层链路切换。

Tailscale 按网络情况自动选择：

```text
1. iPad <-> Mac                         Tailscale direct
2. iPad -> 上海 VPS -> Mac              Tailscale Peer Relay
3. iPad -> Tailscale 官方 DERP -> Mac   Tailscale 最终兜底
```

应用层始终使用同一个地址：

```text
http://<Mac-Tailscale-IP>:8787
```

VPS 只运行 Tailscale Peer Relay，不运行 `agentd`、nginx 或 SSH reverse tunnel。VPS 公网地址仅用于 SSH 运维，以及向 Tailscale 公布 Peer Relay 静态 UDP Endpoint。

## 方案

公开仓库只保留脱敏示例；实际节点名、tailnet 地址和 VPS 公网地址应放在用户自己的运维记录中：

- Mac Tailscale 节点：`<Mac-Tailscale-Hostname>`
- 上海 Peer Relay 节点：`<Peer-Relay-Hostname>`
- Peer Relay 监听：`40000/UDP`
- 上海 VPS 公网地址：`<VPS-Public-IP>`
- Mac `agentd`：`<Mac-Tailscale-IP>:8787/TCP`
- App Endpoint：`http://<Mac-Tailscale-IP>:8787`

App 冷启动、回到前台和 WebSocket 重连时都继续使用同一个 Mac Endpoint。直连失败后的 Peer Relay/DERP 切换由 Tailscale 网络层完成，REST 和 WebSocket 不需要应用层 Endpoint 探测或切换逻辑。

## 实现

### 1. VPS 安装并加入 tailnet

VPS 公网 IP 仍可用于 SSH 管理：

```bash
ssh ubuntu@<VPS-Public-IP>

curl -fsSL https://tailscale.com/install.sh | sh
sudo systemctl enable --now tailscaled
sudo tailscale up \
  --hostname=<Peer-Relay-Hostname> \
  --accept-dns=false
```

浏览器完成一次设备授权后确认：

```bash
tailscale status
tailscale ip -4
```

### 2. 启用 Peer Relay

腾讯云公网 IP 通过 NAT 映射给实例，因此需要同时公布静态公网 Endpoint：

```bash
sudo tailscale set \
  --relay-server-port=40000 \
  --relay-server-static-endpoints="<VPS-Public-IP>:40000"

sudo ss -lunp | grep ':40000'
```

腾讯云 CVM 安全组需要保留以下入站规则：

```text
来源:   0.0.0.0/0
协议:   UDP
端口:   40000
策略:   允许
备注:   Tailscale Peer Relay
```

不再需要为 Mimi Remote 开放 `80/TCP`、`443/TCP` 或 SSH 反向隧道端口。`22/TCP` 是否开放以及允许哪些来源，按 VPS SSH 运维策略单独管理。

Peer Relay 只接受同一 tailnet 内通过 Tailscale 身份认证且获得 capability 的节点。中继看到的是 WireGuard 加密包，不会解密 `agentd` 业务数据。

### 3. 配置 tailnet policy

在 Tailscale Admin Console 的 `Access controls -> JSON editor` 中，把以下 grant 合并进现有 `grants`。实际部署使用设备当前的 Tailscale IP，仓库不记录私有地址。

```jsonc
{
  "grants": [
    // 保留现有网络访问规则。
    {
      "src": ["<Mac-Tailscale-IP>", "<iPad-Tailscale-IP>"],
      "dst": ["<Relay-Tailscale-IP>"],
      "app": {
        "tailscale.com/cap/relay": []
      }
    }
  ]
}
```

不要把 relay capability 的 `src` 长期写成 `*`。只授权需要访问 Mimi Remote 的 Mac 和 iPad，避免其他设备无意中使用上海 VPS 带宽。

### 4. 下线旧应用层公网代理

切换完成后，VPS 仅保留 `tailscaled` 和 SSH 运维入口。旧 nginx + SSH reverse tunnel 可以按以下顺序下线：

1. 确认 iPad App 已只保存 Mac Tailscale Endpoint，并通过它完成一次 REST 和 WebSocket 会话。
2. 在 Mac 停止并移除维护 SSH reverse tunnel 的 LaunchAgent。
3. 在 VPS 删除 Mimi Remote 的 nginx 配置并重新加载 nginx；如果 nginx 不承载其他站点，再停止并禁用该服务。
4. 从云安全组移除仅供公网应用代理使用的 TCP 入站规则，保留 Peer Relay 的 `40000/UDP`。
5. 再次验证 App 仍能访问 Mac Endpoint，并确认 Peer Relay 节点在线。

示例命令中的 LaunchAgent label 和 nginx 配置名以旧部署为准，执行前先核对实际文件：

```bash
# Mac：停止旧 SSH reverse tunnel
launchctl bootout \
  "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/com.mimi-remote.agentd-vps-tunnel.plist"

# VPS：只删除 Mimi Remote 的应用层反代配置
ssh ubuntu@<VPS-Public-IP> \
  'sudo rm -f /etc/nginx/conf.d/mimi-agentd-relay.conf && sudo nginx -t && sudo systemctl reload nginx'
```

如果 nginx 还承载其他服务，不要停止或禁用整个 nginx 服务。不要删除 Tailscale 配置，也不要关闭 `40000/UDP`。

### 5. 验证

在 Mac 验证唯一业务入口：

```bash
curl -fsS http://<Mac-Tailscale-IP>:8787/healthz
```

确认上海节点在线且网络可直达：

```bash
tailscale ping <Peer-Relay-Hostname>
tailscale status
```

iPad 在线并产生 Mimi Remote 流量后，在 Mac 和 VPS 查看连接类型：

```bash
tailscale status | grep -E 'direct|peer-relay|relay'
```

结果含义：

```text
direct       iPad 与 Mac 直接通信，最快
peer-relay   直连失败，经过上海 VPS
relay        Peer Relay 也不可达，经过官方 DERP
```

Peer Relay 是自动降级路径，直连成功时不会强制绕行上海 VPS。仅看到 relay 节点在线不能证明业务已经走 Peer Relay；必须在 iPad 在线、产生实际流量且直连失败时观察连接类型。

### 6. 列表链路性能回归

脚本只执行 `initialize + thread/list`，不会创建会话或调用模型。默认自动读取当前 Mac 的 Tailscale IPv4 地址：

```bash
bash ./scripts/history-sync-regression.sh --rounds 10
```

也可以显式指定 Tailscale IP 或 MagicDNS Endpoint：

```bash
bash ./scripts/history-sync-regression.sh \
  --rounds 10 \
  --endpoint tailscale=http://<Mac-Tailscale-IP>:8787
```

日常探针默认发送小页、最近更新时间倒序和 `useStateDbOnly=true`，对应 App 的 Codex 状态库快路径。需要验证 SQLite 索引遗漏时的普通扫描回退：

```bash
go run -tags ipadwsprobe ./scripts/ipad-ws-probe.go \
  -endpoint http://<Mac-Tailscale-IP>:8787 \
  -list-only \
  -state-db-only=false \
  -list-limit 20
```

链路应保持零错误；当前验收目标是 Tailscale `thread/list` P95 不超过 1.5 秒。若普通扫描明显慢于快路径，先检查 Codex 状态库是否完成索引，不要直接提高 Gateway 超时或响应上限。

## 回滚

如果上海 VPS Peer Relay 异常，可以临时禁用它：

```bash
ssh ubuntu@<VPS-Public-IP> \
  'sudo tailscale set --relay-server-port="" --relay-server-static-endpoints=""'
```

然后从 tailnet policy 删除 `tailscale.com/cap/relay` grant，并移除腾讯云 `40000/UDP` 入站规则。App Endpoint 不变；Tailscale 会继续尝试 direct，并以官方 DERP 兜底。

这个回滚只停用自建 Peer Relay，不恢复 nginx + SSH reverse tunnel 公网入口。需要重新启用 Peer Relay 时，重新执行“启用 Peer Relay”和“配置 tailnet policy”两节即可。

## 风险与优化

- iOS 必须保持 Tailscale VPN 开启，才能访问 `100.64.0.0/10` 地址并使用 direct、Peer Relay 或 DERP。
- 腾讯云安全组未放行 `40000/UDP` 时，VPS 进程即使显示监听，移动端仍无法主动建立 Peer Relay 连接。
- Tailscale 官方 DERP 是最终兜底，不能由 Peer Relay 完全替代。
- Mac 或 iPad 的外网 IP 变化不影响 Tailscale 身份，Tailscale 会重新发布 Endpoint；上海 VPS 继续使用固定公网地址公布 Peer Relay 静态 Endpoint。
- App 不再有公网备用 Endpoint。Tailscale 整体未连接时，App 会连接失败，需要先恢复 Tailscale，而不是切换应用层地址。
