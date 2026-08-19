# 锁屏审批推送服务运维手册

对应 MIM-112。设计与边界见 [锁屏审批通知最小架构](../secure-approval-push-architecture.md)。

这份文档只覆盖运维：部署、密钥、观测、轮换、降级与排障。

## 服务是什么

`cmd/mimi-push-provider` 是一个单进程 Go 服务，只做三件事：

1. 用设备提交的 APNs Token 换一张不透明 Push Ticket；
2. 撤销 Ticket；
3. 按固定枚举向 APNs 发一条审批提醒。

它不托管账号、不托管会话、不中继代码、不代理审批动作。用户的「允许 / 拒绝」始终由设备通过私有网络直接提交给自己的 `agentd`，不经过这里。

## 当前部署

| 项 | 值 |
| --- | --- |
| 主机 | `api.code89757.com`（与 `mimi-relay` 同机） |
| 服务单元 | `mimi-push-provider.service` |
| 运行用户 | `mimi-push`（system 用户，`nologin`） |
| 监听 | `127.0.0.1:8087`，只经 nginx 对外 |
| 对外前缀 | `/mimi-push/`，见 `snippets/mimi_push_locations.conf` |
| 二进制 | `/opt/mimi-push-provider/mimi-push-provider` |
| 配置 | `/etc/mimi-push-provider/`（`0750 root:mimi-push`） |
| 撤销表 | `/var/lib/mimi-push-provider/revocations.db` |

`/mimi-push/metrics` 明确 `deny all`，不对外暴露。

## 密钥

全部只存在于服务器，权限 `0640 root:mimi-push`，绝不进入仓库、镜像或 Release 资产。

| 文件 / 变量 | 用途 |
| --- | --- |
| `/etc/mimi-push-provider/apns.p8` | APNs Auth Key（Apple Developer 后台创建，勾选 APNs） |
| `MIMI_PUSH_APNS_KEY_ID` | 上述 Key 的 ID |
| `MIMI_PUSH_APNS_TEAM_ID` | 开发者团队 ID |
| `MIMI_PUSH_TOPIC` | iOS Bundle ID |
| `/etc/mimi-push-provider/ticket.keys` | Ticket 加密密钥，每行 `版本:64位十六进制` |

生成一把新的 Ticket 密钥：

```bash
/opt/mimi-push-provider/mimi-push-provider -genkey
```

## 部署与升级

在仓库根目录交叉编译并替换二进制：

```bash
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /tmp/mimi-push-provider ./cmd/mimi-push-provider
```

上传后：

```bash
sudo install -o root -g root -m 0755 /tmp/mimi-push-provider /opt/mimi-push-provider/mimi-push-provider && sudo systemctl restart mimi-push-provider
```

服务无状态迁移需求，重启只会丢掉进程内的限速计数与指标；撤销表在磁盘上。

## 换上真实 APNs 私钥

首次上线时用的是占位私钥，Apple 会稳定返回 `InvalidProviderToken`。换真钥：

1. 把 `.p8` 放到 `/etc/mimi-push-provider/apns.p8`，`chown root:mimi-push`、`chmod 0640`；
2. 在 `/etc/mimi-push-provider/env` 里把 `MIMI_PUSH_APNS_KEY_ID` 改成真实 Key ID；
3. `sudo systemctl restart mimi-push-provider`；
4. 用下面的验证清单确认 `delivered:true`。

## 密钥轮换

**APNs Key**：在 Apple 后台创建新 Key → 部署到服务器 → 重启 → 观察投递成功率 → 确认稳定后再在 Apple 后台撤销旧 Key。Apple 允许同时存在多把 Key，因此不必停机。

**Ticket 加密密钥**：新增一行更高版本号的密钥并保留旧行，把 `MIMI_PUSH_TICKET_KEY_VERSION` 指向新版本，重启。此后新签发的 Ticket 用新密钥，已发出的旧 Ticket 继续可用。等过完最长 Ticket 有效期（30 天）后再删除旧行。**先删旧行会让所有在用 Ticket 立刻失效**，用户必须重新开启开关才能恢复提醒。

## 验证清单

```bash
curl -s https://api.code89757.com/mimi-push/healthz
```

完整链路（签发 → 投递 → 撤销）：

```bash
TICKET=$(curl -s -X POST https://api.code89757.com/mimi-push/v1/ticket -H 'Content-Type: application/json' -d '{"version":1,"environment":"sandbox","device_token":"<64位十六进制>","installation":"ops-check"}' | sed -n 's/.*"ticket":"\([^"]*\)".*/\1/p')
```

拿到 Ticket 后发一条提醒，确认返回 `delivered:true`；随后撤销该 Ticket，确认再次投递返回 `403 ticket_revoked`。

指标只能在服务器本机读：

```bash
curl -s http://127.0.0.1:8087/metrics
```

## 观测与告警

服务只记录：请求计数、延迟、限速、APNs 状态码与原因、密钥版本。**不记录** Authorization、Push Ticket、Device Token、`action_id`、请求体或 APNs Payload。

至少应告警：

- APNs 认证失败（`InvalidProviderToken` / `ExpiredProviderToken` 持续出现）；
- Topic 或环境不匹配（`BadDeviceToken` 激增，通常是 sandbox / production 用混）；
- `410 Unregistered` 激增；
- 服务 5xx 或撤销表不可写；
- 投递延迟异常。

## 一个已经踩过的坑

APNs 的**协议级拒绝**必须以 `200 + delivered:false + reason` 回报，不能用 5xx。托管 CDN 会把 5xx 的响应体替换成自己的错误页，`reason` 就此丢失，线上只剩一个无从下手的状态码。传输层故障仍然回 502——那种情况本来也没有 reason 可言。改动它之前请先想清楚这一点。

## 保留策略

| 数据 | 保留 |
| --- | --- |
| 已撤销 Ticket ID + 原到期时间 | 到其自然到期为止，最长 30 天，每小时清理 |
| 不含请求体的结构化错误日志 | 7 天 |
| 聚合成功率与延迟指标 | 30 天 |
| APNs Device Token | 不落库，仅在注册与投递请求的进程内短暂处理 |

## 故障降级

Provider 或 APNs 不可用**不会**影响任何审批本身：`agentd` 只记录有界错误，前台 WebSocket 审批链路照常工作。用户最坏的体验是收不到锁屏提醒，需要主动打开 App。

因此这个服务的可用性目标可以远低于 `agentd` 本身——它是一条提醒旁路，不是控制面。
