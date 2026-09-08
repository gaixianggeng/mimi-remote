# 锁屏审批推送服务运维手册

对应 MIM-112。设计与边界见 [锁屏审批通知最小架构](../secure-approval-push-architecture.md)。

这份文档只覆盖运维：部署、密钥、观测、轮换、降级与排障。

## 服务是什么

`cmd/mimi-push-provider` 是一个单进程 Go 服务，只做三件事：

1. 用设备提交的 APNs Token 换一张不透明 Push Ticket；
2. 撤销 Ticket；
3. 按固定枚举向 APNs 发一条审批提醒。

它不托管账号、不托管会话、不中继代码、不代理审批动作。用户的「允许 / 拒绝」始终由设备通过私有网络直接提交给自己的 `agentd`，不经过这里。

## 历史部署记录（迁移前）

| 项 | 值 |
| --- | --- |
| 主机 | `api.code89757.com`（原记录与历史 `mimi-relay` 同机；不代表当前 Tailcat DERP） |
| 服务单元 | `mimi-push-provider.service` |
| 运行用户 | `mimi-push`（system 用户，`nologin`） |
| 监听 | `127.0.0.1:8087`，只经 nginx 对外 |
| 对外前缀 | `/mimi-push/`，见 `snippets/mimi_push_locations.conf` |
| 二进制 | `/opt/mimi-push-provider/mimi-push-provider` |
| 配置 | `/etc/mimi-push-provider/`（`0750 root:mimi-push`） |
| 撤销表 | `/var/lib/mimi-push-provider/revocations.db` |

`/mimi-push/metrics` 明确 `deny all`，不对外暴露。

## 与 Tailcat DERP 同机部署

#353 的部署要求是：APNs Provider 与当前 Tailcat DERP 使用同一台服务器。
服务器目标尚待核实，以下为部署步骤，不能作为已完成迁移的证明。

两个服务保留独立进程、用户、配置和状态目录。DERP 转发 Tailcat 加密流量；
Provider 只发送固定格式的系统提醒。锁屏允许/拒绝按通知来源选择 Mac，使用该
Profile 保存的 Tailcat 地址和设备私钥建立临时连接，不切换当前 Profile，不回退直连。
APNs 私钥只由 `mimi-push` 读取，不交给 DERP 或客户端。同机故障会同时影响中转和提醒。

### 安装前确认

在目标服务器执行：

```bash
sudo systemctl list-units --type=service --all | grep -E 'derp|tailcat|mimi-push'
sudo ss -lntup
sudo nginx -t
```

确认现有 DERP/TLS 入口、UDP STUN 端口和 `127.0.0.1:8087` 占用情况。
模板只向现有 HTTPS 虚拟主机添加 `/mimi-push/`，不接管 DERP 的端口、域名或准入规则。
如果当前由 derper 直接监听 443，先确定共用 HTTPS 入口的配置再部署，不能直接让 nginx 抢占端口。

### 安装服务

将仓库中的 `config/push-provider/` 和对应架构的 Provider 二进制上传到目标服务器，
然后在上传目录执行：

```bash
getent passwd mimi-push >/dev/null || sudo useradd --system --no-create-home --shell /usr/sbin/nologin mimi-push
sudo install -d -o root -g root -m 0755 /opt/mimi-push-provider
sudo install -d -o root -g mimi-push -m 0750 /etc/mimi-push-provider
sudo install -d -o mimi-push -g mimi-push -m 0700 /var/lib/mimi-push-provider
sudo install -o root -g root -m 0755 ./mimi-push-provider /opt/mimi-push-provider/mimi-push-provider
sudo install -o root -g root -m 0644 ./mimi-push-provider.service /etc/systemd/system/mimi-push-provider.service
sudo install -o root -g root -m 0644 ./nginx-locations.conf /etc/nginx/snippets/mimi_push_locations.conf
```

`env.example` 仅用于对照字段。已有服务迁移时，保留原 `env`、`apns.p8`、全部版本的
`ticket.keys` 和 `revocations.db`，不要重新生成密钥或覆盖撤销记录。停写旧 Provider 后
通过受限 SSH 传输完整快照，再将目标配置文件设为 `0640 root:mimi-push`、撤销表设为
`0600 mimi-push:mimi-push`。旧服务器保留可回滚副本，验收前不删除。

在目标已有 HTTPS `server` 块中加入：

```nginx
include /etc/nginx/snippets/mimi_push_locations.conf;
```

然后执行：

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now mimi-push-provider
sudo nginx -t && sudo systemctl reload nginx
curl --fail --silent --show-error http://127.0.0.1:8087/healthz
```

### 验收与回滚

- 对外检查 `/mimi-push/healthz`，并确认 `/mimi-push/metrics` 返回 403。
- 用原 Ticket 验证迁移前后的有效性；已撤销 Ticket 仍必须拒绝。
- 在 iPhone 和 iPad 上分别验证：先锁屏再产生审批、系统身份验证、允许、拒绝、查看详情。
- 强制经过同机 DERP 验证 Tailcat 连接，并确认未知节点准入策略没有改变。
- 保持 Provider URL 不变时无需重新同意；URL 变化时先向用户披露新地址并重新开启，不能静默沿用旧同意。

切流失败时恢复旧入口和旧 Provider。目标已经接受新签发或撤销请求后，必须先停写并
同步最新密钥与撤销表再回滚，不能恢复旧快照使已撤销 Ticket 重新有效。

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

## APNs 私钥（已就位）

当前使用 Key ID **`NXU86Q978A`**（门户里名为 *CatName APNs*），配置为 **Team Scoped (All topics)**、
**Sandbox & Production**。Team Scoped 意味着它对该团队下所有 Bundle ID 有效，包含
`com.gaixianggeng.mimi`，因此不需要为 Mimi 单独建一把。

**这把 key 与 CatName 共用。** 轮换它会同时影响两个服务，动手前先确认另一侧也准备好了。
Apple 每个团队最多只能同时存在 2 把 APNs Auth Key，目前已用 1 把。

私钥原件在服务器的通用受限目录（例如 `/path/to/secure/AuthKey_NXU86Q978A.p8`），Provider 用的副本在
`/etc/mimi-push-provider/apns.p8`（`0640 root:mimi-push`）。Apple 只允许下载一次，
别删原件。

### 换成另一把 key 时

1. 把新 `.p8` 放到 `/etc/mimi-push-provider/apns.p8`，`chown root:mimi-push`、`chmod 0640`；
2. 在 `/etc/mimi-push-provider/env` 里改 `MIMI_PUSH_APNS_KEY_ID`；
3. `sudo systemctl restart mimi-push-provider`；
4. 按下面的验证清单确认。

### 怎么判断 key 是否生效

用一个**伪造的** device token 打一次真实 APNs，看 `/metrics` 里的 `apns_statuses`：

- `403` → `InvalidProviderToken`，key 或 Key ID 不对，**鉴权没过**；
- `400` → `BadDeviceToken`，**鉴权已通过**，只是 token 是假的。这就是 key 正常的标志。

要看到 `delivered:true` 必须用真机拿到的真实 device token。

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
