# 锁屏审批推送服务运维手册

对应 MIM-112。设计与边界见 [锁屏审批通知最小架构](../secure-approval-push-architecture.md)。

这份文档只覆盖运维：部署、密钥、观测、轮换、降级与排障。

## 服务是什么

`cmd/mimi-push-provider` 是一个单进程 Go 服务，只做三件事：

1. 用设备提交的 APNs Token（含 Live Activity Token）换一张不透明 Push Ticket；
2. 撤销 Ticket；
3. 按固定枚举向 APNs 发送审批、回复完成、任务失败或中断提醒，以及启动、更新、结束 Live Activity（#830）。

它不托管账号、不托管会话、不中继代码、不代理审批动作。用户的「允许 / 拒绝」始终由设备通过私有网络直接提交给自己的 `agentd`，不经过这里。

## 当前部署记录（2026-09-08 核实）

| 项 | 值 |
| --- | --- |
| 主机 | `api.code89757.com`（已核实与 `tailcat-derper.service` 同机） |
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
2026-09-08 已通过 SSH 核实两个服务同机运行，并更新 Provider 二进制。
沿用现有 URL、systemd/nginx 配置、APNs 密钥、Ticket 密钥和撤销表；DERP 进程未重启。
升级前 Ticket 可解密，已撤销 Ticket 仍被拒绝；沙盒和正式 APNs 接口均返回测试 Token 无效。
公网健康检查返回 200，指标入口返回 403。后续生命周期验证已用真机注册的 Ticket
收到 APNs 200，用户确认 iPad mini 显示通知；点击打开、锁屏身份验证与审批操作仍需真机验收。
以下步骤用于后续部署或迁移。

两个服务保留独立进程、用户、配置和状态目录。DERP 转发 Tailcat 加密流量；
Provider 只发送固定格式的系统提醒。锁屏允许/拒绝按通知来源选择 Mac，使用该
Profile 复用 App 的 Tailcat 恢复流程；来源是另一台 Mac 时切换到该 Mac，再提交动作，不回退直连。
同一设备身份不能并存两套 Tailcat 引擎，否则会抢占 DERP 连接。后台自动维护不切换 Mac；
更换通知绑定前，先回到原 Mac 关闭锁屏提醒，再在目标 Mac 开启。
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
`0600 mimi-push:mimi-push`。旧服务器保留可回滚副本，验收前不删除。若更换 Provider URL，换绑期间旧 URL 仍须
代理到同一份目标 Provider 状态，供客户端撤销旧 Ticket；直接关闭旧 URL 会使换绑回滚。

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

## 消息提醒版本升级

新增回复提醒时，先更新本机验证过的 Provider，再更新 Mac 和 iOS。旧 Provider 会拒绝新的 `turn.*` 事件。
此版本沿用原地址、密钥和撤销表，不迁移已有 Ticket。回复提醒不发送回复正文或错误详情。

锁屏显示会话标题（#418）同样依赖部署这一版 Provider：它只为 `turn.*` 事件多带 `aps.mutable-content: 1`，
Payload 里仍然没有标题；标题由设备上的通知扩展从 App Group 本地缓存改写。两个方向都向后兼容：
旧版 App 没有该扩展时照常显示通用文案，旧 Provider 配新 App 时也只是不改写标题。部署命令见下文「部署与升级」。

DeepSeek 回复提醒（#568）同样先更新 Provider：旧 Provider 对 `runtime=deepseek` 回 400，agentd 只记日志、
不删设备，所以先装新 agentd 也安全，只是收不到提醒。Provider 只接受 DeepSeek 的 `turn.*`，审批与等待提醒仍拒绝。

最小验收：开启“消息提醒”后发送一个延迟完成的任务并锁屏；确认只收到一次回复提醒，点击能打开来源任务。
另测失败、自动重试、需要输入、当前任务前台静默、审批允许/拒绝，以及锁屏提醒显示会话标题、缓存缺失时退回通用文案。真实 APNs 投递仍须真机验证。

## Live Activity（#830）

锁屏与灵动岛的回合进度经同一个 Provider 投递。Provider 只接收状态枚举、计数、时间戳和匿名短标签；
会话标题由设备上的 Widget 扩展按短标签从 App Group 本地缓存查，Payload 与日志里都没有标题。

### Ticket 用途

`POST /v1/ticket` 新增可选字段 `kind`，其余字段与响应不变：

| `kind` | 用途 | apns-topic | Ticket 有效期 |
| --- | --- | --- | --- |
| 省略、`""` 或 `notification` | 通知（原有行为） | `<Bundle ID>` | 原有设置（默认 30 天） |
| `activity_update` | 某一个活动的更新 Token，只能发 update / end | `<Bundle ID>.push-type.liveactivity` | 不超过 24 小时 |
| `activity_start` | iOS 17.2+ 的 push-to-start Token，只能发 start | `<Bundle ID>.push-type.liveactivity` | 原有设置 |

- 通知 Ticket 仍是 v1 格式，明文里没有 `kind`。升级前签发的 Ticket 继续可用，旧客户端不受影响。
- 两类活动 Ticket 用 v2 格式并在密文里写明用途。活动 Token 上限是 400 个十六进制字符，通知 Token 仍是 200。
- 用途不符的 Ticket 一律回 `400 ticket_kind_mismatch`，包括活动 Ticket 调 `/v1/notify`、更新 Ticket 发 start 等情况。
- 撤销沿用 `/v1/ticket/revoke`，撤销表不变。

### `POST /v1/notify/liveactivity`

```json
{
  "version": 1,
  "event": "update",
  "ticket": "mpt1.<…>",
  "content_state": {
    "status": "running",
    "running_count": 2,
    "needs_you_count": 1,
    "started_at": 1700000000,
    "focus_session_tag": "7D92"
  },
  "stale_date": 1700001800,
  "expires_at": "2026-10-20T12:00:00Z"
}
```

| 字段 | 规则 |
| --- | --- |
| `event` | `start` / `update` / `end` |
| `content_state.status` | `running` / `needsYou` / `completed` / `failed`，区分大小写 |
| `running_count`、`needs_you_count` | 整数 0–99。agentd 发送前自行截断 |
| `started_at` | Unix 秒，不早于 24 小时前、不晚于 5 分钟后 |
| `focus_session_tag` | 最需要关注的会话的匿名短标签，规则同 `session_tag`（大写十六进制，≤16 位） |
| `attributes_type`、`attributes` | 仅 start，且必填。`attributes_type` 必须是 `MimiTurnActivityAttributes`，`attributes` 只有 `host_tag` 一个字段 |
| `stale_date` | 可选，Unix 秒，晚于当前且不超过 12 小时；end 不能带 |
| `dismissal_date` | 仅 end，可选，Unix 秒，不超过 4 小时后；早于当前表示立即移除 |
| `expires_at` | RFC3339，不超过 12 小时；与 Ticket 到期取较早者，作为 `apns-expiration` |

任何未知字段，包括 `content_state` 和 `attributes` 内部的字段，都会回 `400 invalid_body`。取值越界回 `400 invalid_request`，两种情况都不触发投递。

Provider 生成的 APNs 请求：

- Header：`apns-push-type: liveactivity`，`apns-topic` 取 Ticket 里的 `<Bundle ID>.push-type.liveactivity`，不带 `apns-collapse-id`。
- `apns-priority`：普通 update 用 5，不占系统的高优先级预算；start、end 和 `status=needsYou` 的 update 用 10。
- `aps.timestamp` 取 Provider 收到请求的时间，`aps.event` 与请求相同。`aps.content-state` 的键是 `status`、`runningCount`、`needsYouCount`、`startedAt`、`focusSessionTag`。
- start 另带 `attributes-type`、`attributes.hostTag`、`input-push-token: 1`，以及 Apple 要求的 `alert`。`alert` 只用扁平本地化键 `title-loc-key: push.liveactivity.start.title` 与 `loc-key: push.liveactivity.start.body`，不带参数和声音。
- end 带 `dismissal-date`，update 与 start 可以带 `stale-date`。

App 端（阶段二）必须对齐的约定：

- ActivityAttributes 的 Swift 类型名是 `MimiTurnActivityAttributes`，属性名与上面的键一致。
- `startedAt` 是 Unix 秒，应声明为整数。系统用默认 Codable 策略解码，声明成 `Date` 会按 2001 年参考时间解释。
- 两个 start 文案 key 需要放进 App 的本地化表。

### 频率与合并

- 限速沿用原有令牌桶参数（突发 20、每秒 2 条），但 Live Activity 单独按设备计数：同一安装的所有活动共用一个桶，与审批通知的额度互不挤占。
- 同一活动（同一张更新 Ticket）的 update 至少间隔 5 秒。窗口内的请求回 `202 {"accepted":true,"coalesced":true}`，只保留最后一条，窗口结束时以它收到时的 `timestamp` 发出。
- 以下情况不等窗口：end，以及从其它状态转入 `needsYou` 的 update。它们立即发出，并丢弃窗口里更旧的 update。已处于 `needsYou` 时，计数变化照常合并。
- start 不合并，只受限速约束。
- 合并后延迟发出的 update 没有调用方等待结果。发出前会重新检查撤销表；APNs 判定 Token 失效时照常自动撤销，调用方下一次请求会得到 `403 ticket_revoked`。

### 响应与失效

响应码与 `/v1/notify` 一致：`200 delivered:true`；APNs 协议级拒绝回 `200 delivered:false + reason`；
Token 永久失效回 `410 reason:unregistered` 并自动撤销 Ticket；传输故障回 `502`。活动 Ticket 在
`Unregistered`、`BadDeviceToken`、`DeviceTokenNotForTopic` 之外还认 `ExpiredToken`（活动结束后其更新 Token 会过期）。
通知路径的判定不变。

日志只含环境、事件枚举和 APNs 状态与原因，不记录 `content_state`、Ticket、Token 或 Payload。
新增指标计数：`ticket_issued_activity_update`、`ticket_issued_activity_start`、`liveactivity_delivered_<event>`、
`liveactivity_coalesced`、`liveactivity_rejected_{ticket,ticket_kind,schema,revoked}`、`notify_rejected_ticket_kind`。

### 部署注意事项

- **先部署 Provider，再发布阶段二的 agentd 与 App。** 旧 Provider 不认 `kind`，按未知字段回 400；也没有 `/v1/notify/liveactivity`。部署须由维护者单独确认，沿用上文「部署与升级」的备份与回滚流程。
- 不新增环境变量、密钥或持久数据。`liveactivity` topic 由 `MIMI_PUSH_TOPIC` 自动派生，nginx 的 `/mimi-push/` 前缀已覆盖新路径。
- APNs Key 必须对 `<Bundle ID>.push-type.liveactivity` 有效。Team Scoped (All topics) 的 Key 满足要求；换成 Topic 限定的 Key 时需要勾选该 topic。
- 回滚到旧 Provider 时，通知 Ticket 不受影响，活动 Ticket 会回 `401 invalid_ticket`。旧版只认 v1，不会把活动 Token 当成通知 Token 投递。重新升级后，活动 Ticket 在有效期内恢复可用。
- 重启会丢掉进程内的合并状态，每个活动最多丢失一条尚未发出的中间态 update。下一次状态变化会覆盖它。

最小验收（部署后、阶段二之前）：

1. 用测试 Token 分别签发 `activity_update` 和 `activity_start` Ticket，确认响应字段与原有一致。
2. 用活动 Ticket 调 `/v1/notify` 应回 `400 ticket_kind_mismatch`。原有通知 Ticket 的审批提醒照常 `delivered:true`。
3. 测试 Token 打 `/v1/notify/liveactivity` 应回 `410 unregistered` 或 `delivered:false`，说明请求已到达 APNs。真实锁屏显示要等阶段二用真机验证。

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
- APNs 指标为 `400` 且 Provider 返回 `410 + reason: unregistered` → 测试 Token 被判为永久无效，Provider 已自动撤销 Ticket。这可验证接口调用，但不代表真机投递成功。

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

除设备永久失效错误返回 `410 + reason: unregistered` 外，APNs 的**协议级拒绝**以 `200 + delivered:false + reason` 回报，不能用 5xx。托管 CDN 会把 5xx 的响应体替换成自己的错误页，`reason` 就此丢失，线上只剩一个无从下手的状态码。传输层故障仍然回 502——那种情况本来也没有 reason 可言。改动它之前请先想清楚这一点。

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
