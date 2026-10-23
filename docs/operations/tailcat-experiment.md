# Tailcat 远程连接实验

## 目标

验证 iPad 不安装 Tailscale 客户端时，Mimi Remote 能否仅通过 Tailcat 连接 Mac 上的 `agentd`，并保持现有 HTTP、WebSocket、认证和大文件传输能力。

本实验固定使用 Tailcat `v0.7.0`。Tailcat 不使用 Tailscale 控制平面，但仍使用 Tailscale 的网络库和 DERP 中继。未配置自定义中继时，使用上游常量 `DefaultDERPMapURL`（`https://tailcat.dev/derpmap.json`），即 Tailcat 项目提供、由 Tailscale 运营的免费限速公共中继；Mimi Remote 不运营该中继。

## 方案

Mac 运行一个独立的 Tailcat sidecar。sidecar 只接受已经扫码配对的设备公钥，并且只把远端 `8787` 端口转发到本机 `127.0.0.1:8787`。sidecar 启停失败不会让 `agentd` 或现有 Tailscale 会话退出。

iPad App 内嵌 Tailcat Go 客户端。客户端在本机打开一个随机 loopback 端口，Mimi Remote 的现有 HTTP 和 WebSocket 客户端只连接这个本地端口。每次连接都先经 DERP 发现对端并完成初始握手，再在网络允许时切换为点对点直连，否则继续经中继转发。随后直连也会产生初始连接阶段的网络元数据。流程以 [Tailcat v0.7.0 上游说明](https://github.com/tailscale/tailcat/blob/v0.7.0/README.md#connection-flow)为准。

回到前台时先检查已有隧道，健康时保留本地端口；一次短暂拨号或探测失败会先再次确认，持续失败才重建引擎。恢复只重试尚未发送业务字节的连接，不重放消息。切换电脑时，同一设备身份的旧引擎必须先关闭，再启动候选引擎；候选验证失败后串行恢复原线路。

托管授权列表只增加设备时原地追加，不中断现有连接；撤销设备时仍重建服务，确保旧授权失效。直连与 DERP 路径切换不代表辅助进程重启。

Mac 和 iPad 设置页都提供显式实验开关。开关打开后，App 只使用 Tailcat 路由，不回退到 Tailscale 地址或本机直连。开关关闭后，App 立即恢复原连接档案，且不会改写档案地址或 Agent Token。

配对使用 10 分钟有效的签名二维码。二维码不包含长期 Agent Token。iPad 先通过临时 Tailcat 服务提交自己的公钥，Mac 将该公钥写入稳定服务的允许列表，再返回稳定连接地址。任何验证、Keychain 写入或档案提交失败都会恢复原路由。

## 实现

### 1. 生成 iOS 框架

需要 Xcode 27 和可自动获取 Go 1.27 工具链的 Go 环境。仓库根目录执行：

```bash
bash ./scripts/build-tailcat-mobile.sh
```

脚本固定使用 `golang.org/x/mobile` 版本 `v0.0.0-20260821190718-4776eadac327`，并生成：

```text
ios/MimiRemote/Generated/TailcatMobile.xcframework
```

该产物不提交到 Git。本地实验需要先运行上述脚本；TestFlight 发布入口会从仓库固定的 Tailcat 版本自动重新生成。缺少该产物时，普通 Debug App 仍能构建，但 Tailcat 开关不可用。

### 2. 在 Mac 开启实验并生成二维码

打开 Mac 版 Mimi 的“实验功能”，开启 Tailcat 实验。状态必须显示 sidecar 正在运行。中继节点可选“Tailcat 默认”或“自定义”。自定义模式填写完整的 DERP Map HTTPS 地址，再点击“应用中继配置”。切换成功后需要重新生成二维码并扫码；切换失败时会自动恢复原中继。

也可以用命令行执行同一控制流程：

```bash
agentd tailcat status
agentd tailcat enable
agentd tailcat configure --derp-map-url=https://relay.example/derpmap/default
agentd tailcat pair
```

`agentd tailcat pair` 只输出短期配对链接。它不会输出或修改长期 Agent Token。

购买托管连接后，必须先在电脑上进入托管模式，再生成二维码。不能扫码后才切换，
因为切换中继会重建稳定主机公钥，扫码授权绑定的是二维码中的原公钥。

```bash
agentd tailcat enable
agentd tailcat enter-managed
agentd tailcat status
agentd tailcat pair
```

本机控制接口 `POST /api/local/tailcat` 对应的 `action` 是 `enter-managed` 和
`exit-managed`，沿用现有本机 Token、loopback 和禁止 Origin 的控制边界。
状态 JSON 的 `mode` 为 `managed`（托管）或 `self_hosted`（自建）；命令状态会显示中文模式。
电脑端界面的进入、退出入口及各端模式展示另行实现。

托管模式使用 Mimi 官方 DERP Map：
`https://api.code89757.com/v1/relay/tailcat-derp-map.json`。配置项
`tailcat.managed_derp_map_url` 可以覆盖该地址，只允许完整 HTTPS URL，供测试或自建控制面使用。
不配置时使用统一的官方默认值。`tailcat.mode`、当前 `tailcat.derp_map_url` 和
`tailcat.previous_derp_map_url` 在一次配置提交中保存；原地址为空表示 Tailcat 默认中继。
旧配置没有 `mode` 时按自建处理，不自动迁移已有配对。

进入和退出模式都会重建 Tailcat 身份并清空自建配对；同一台电脑同一时间只使用一种模式。
切换失败时恢复切换前的中继、身份和自建配对，退出失败时也恢复仍有效的托管授权。
成功退出会清空托管注册，并恢复进入前的默认或自定义中继；它不会找回进入前已清空的配对。
重复进入或退出不改变身份或已记录的原值。`agentd` 重启后继续保留模式及原中继记录。

```bash
agentd tailcat exit-managed
agentd tailcat status
```

托管模式下，手动 `configure` 返回 HTTP 409、错误码 `tailcat_managed_relay_locked`。
未进入托管模式的托管 claim 返回 HTTP 409、错误码 `tailcat_managed_mode_required`，
并提示先在电脑进入托管模式后重新生成二维码。iOS 现有错误处理会显示这条中文提示。

二维码会同时携带 Mac 的随机安装 ID 和稳定 Tailcat 公钥。这两项都是公开身份，
不是访问凭证。免费自建 Tailcat 仍按原流程把扫码设备公钥写入 `clients.json`。

Mimi 托管连接会在移动端取得订阅权益和 10 分钟配对授权后，把授权一并提交给
`agentd`。`agentd` 先让官方控制面完成 Mac 登记，再应用控制面返回的移动设备
公钥白名单。短期配对授权不会写入磁盘。

托管策略保存在 Tailcat 状态目录的 `managed-policy.json`，文件权限固定为 `0600`，
写入采用临时文件替换。`agentd` 启动后立即同步，此后每 5 分钟同步一次。在线撤销
最迟在 10 分钟内生效。控制面临时不可达时可以继续使用最后一次有效策略，但最多
保留 24 小时；超时、主机身份变化或控制面明确撤销后会清空托管白名单。免费自建
白名单与托管白名单分开保存，应用策略时才合并，托管撤销不会删除免费配对。
云端撤销、主机身份变化及显式 `reset` 都保持托管模式，只清空对应授权或注册并等待重新配对。
只有显式 `exit-managed` 才恢复原中继，避免一次云端异常让电脑悄悄换回公共中继。

自建模式下恢复 Tailcat 默认中继：

```bash
agentd tailcat configure --derp-map-url=
```

这里需要填写 DERP Map 地址，不是 DERP 服务的 IP 和端口。

#### 已连接设备一键接入（agentd 接口）

已经持有这台电脑 Agent Token 的客户端可调用 `POST /api/tailcat/managed-pairing-link`，
获取与 `agentd tailcat pair` 二维码相同格式的托管配对链接。该接口强制要求
`Authorization: Bearer …`，开发免鉴权及查询参数 Token 都不能代替 Bearer。
`/api/local/tailcat` 的本机控制限制保持不变。iOS 入口由客户端另行实现。

请求 JSON 为 `{"confirm_reset_self_hosted":false}`，字段可省略，默认为 `false`。
接口先开启 Tailcat，再检查自建设备数；自建模式存在已配对设备时返回 HTTP 409，
响应包含 `code: "tailcat_self_hosted_clients_present"`、中文 `error` 和
`paired_device_count`。客户端展示设备将被断开的提示，用户确认后以
`{"confirm_reset_self_hosted":true}` 重试。状态读取失败时不会把设备数当作零。

sidecar 在 `experiments/tailcat/internal/tunnel/host.go` 中通过普通 TCP 连接转发到
agentd 的回环地址，不写入可信 HTTP 标记。agentd 无法从 `RemoteAddr`、`Host` 或
转发头可靠区分 Tailcat 与本机请求，因此采用所有自建设备均需确认的替代方案，
不会返回 `tailcat_upgrade_over_tailcat`。确认后的模式切换仍可能切断当前 Tailcat
请求；客户端应通过已有局域网或 Tailscale 线路调用，避免在自建 Tailcat 线路上确认切换。

以下命令通过已有连接调用接口。`AGENT_URL` 设置为当前电脑的 HTTP 服务地址，
`AGENT_TOKEN` 设置为现有 Agent Token；不要把两者或返回链接写入日志。

```bash
curl --fail-with-body --request POST \
  "${AGENT_URL:?请先设置现有连接地址}/api/tailcat/managed-pairing-link" \
  --header "Authorization: Bearer ${AGENT_TOKEN:?请先设置现有 Agent Token}" \
  --header 'Content-Type: application/json' \
  --data '{"confirm_reset_self_hosted":false}'
```

成功返回 HTTP 200，且响应带 `Cache-Control: no-store`：

| 字段 | 含义 |
| --- | --- |
| `pair_url` | 可交给现有扫码解析流程的短期链接，包含 `managed_*` 公开身份和配对签名，不含长期 Agent Token |
| `pair_expires_at` | RFC3339 格式的有效期，取签名票据与临时节点有效期中较早者 |
| `mode` | 固定为 `managed` |

接口与本机模式切换、配对和自建 claim 共用流程锁。同一时间只执行一个升级请求；
已有控制操作执行时立即返回 HTTP 409、`tailcat_operation_in_progress`，不排队生成链接。
现有配对接口没有按时间窗口限流；新接口继续使用 sidecar 配对超时及超时节点复用逻辑。
操作日志只记录固定结果码，不包含链接、地址、公钥或凭证。

业务失败响应包含 `code` 和中文 `error`：

| HTTP | `code` | 含义与处理 |
| --- | --- | --- |
| 409 | `tailcat_self_hosted_clients_present` | 有自建设备，展示 `paired_device_count`，用户确认断开后重试 |
| 409 | `tailcat_operation_in_progress` | Tailcat 正忙，稍后重试 |
| 503 | `tailcat_managed_pairing_unavailable` | Tailcat、托管控制器或安装身份未就绪，在电脑上检查服务 |
| 503 | `tailcat_agents_disabled` | 全部 AI 编程助手已关闭，先启用助手 |
| 500 / 503 | `tailcat_enable_failed` | 保存开启配置或启动 sidecar 失败，在电脑上检查 |
| 503 | `tailcat_enable_rollback_failed` | 开启失败且恢复关闭状态也失败，需要在电脑上处理 |
| 503 | `tailcat_status_unavailable` | 无法可靠读取设备状态，稍后重试 |
| 503 | `tailcat_managed_mode_failed` | 模式切换或收敛失败，已按原逻辑尝试恢复，在电脑上检查 |
| 503 | `tailcat_pair_failed` | 临时配对节点生成失败、超时、缺失或过期，稍后重试 |
| 500 | `tailcat_pair_link_failed` | 配置无法生成有效链接，或磁盘凭证与运行中服务不一致，在电脑上检查并重启服务 |

另沿用公共中间件响应：400 非法 JSON、401 未鉴权、405 方法不支持、413 请求体过大，
这些响应只有 `error`；协议头错误为 400 `protocol_metadata_invalid`，协议不兼容为
426 `protocol_incompatible`。客户端先按 HTTP 状态兜底，再使用业务 `code` 提示。

启用失败时关闭配置并停止 sidecar，取消请求不取消这一步恢复；模式切换失败沿用身份、
白名单及托管注册回滚。模式切换成功后的配对或链接生成失败保持托管模式，重试不会恢复
已清空的自建配对。已托管且官方中继未变化时保留稳定身份与已有授权；中继配置变化时
仍按现有收敛逻辑重建身份。生成链接本身不完成云端授权，后续订阅校验与 claim 流程保持不变。

### 3. 在 iPad 扫码

使用统一入口构建并运行 App：

```bash
bash ./scripts/ios-dev.sh target
bash ./scripts/ios-dev.sh leases
bash ./scripts/ios-dev.sh run
```

从常规的“添加电脑”或“修复当前电脑”入口扫描 Mac 二维码。扫码成功后，iPad 会自动开启 Tailcat 实验。无需粘贴连接地址或手工复制公钥。

完成后可在“设置 → 实验功能 → 连接诊断”查看当前路径延迟和一次真实 HTTP 请求耗时。诊断区分直连、Peer Relay 和 DERP 中转。本机只保留最近 10 条脱敏结果。

以下结果同时成立才算本轮通过：

- iPad 未运行 Tailscale 客户端。
- App 状态显示 Tailcat 已连接。
- 路径诊断能返回路径类型和延迟。
- 工作区列表、会话列表和消息收发正常。
- WebSocket 流式输出不中断。
- 图片或其他大于 1 MB 的二进制内容可以上传。
- Mac sidecar 重启后，原连接地址仍可使用。
- 关闭实验开关后，App 恢复原 Tailscale 连接档案。

### 当前验证结果

截至 2026-09-01，以下自动验证已通过：

- 本地 DERP/STUN 集成测试通过，覆盖 HTTP 401/200、WebSocket 二进制回显、1 MB 以上上传、客户端重连和服务端重启。
- 默认 `tailcat.dev` DERP Map 的实连冒烟通过，Tailcat 能把请求转发到当前运行的真实 `agentd`。
- Tailcat `v0.5.0` 模块测试通过，覆盖稳定服务允许列表、短期二维码和本地控制边界。
- Mac App 60 项测试通过，且可嵌入、签名和启动独立 sidecar。
- `gomobile bind` 已生成真机和 Simulator 两个平台的 XCFramework。
- iOS 覆盖二维码字段、Tailcat-only 路由验证和规范地址保留测试。

2026-09-12 升级到 Tailcat `v0.6.0` 后补充验证：

- 模块测试通过，新增“稳定地址不带 PSK”断言；未关闭 PSK 时原有的“重启后地址不变”测试会失败。
- `gomobile bind` 重新生成 XCFramework，体积仍约 137 MB；`test-tailcat-mobile-build.sh` 通过。
- 本机 DERP 上用 `v0.5.0` 与 `v0.6.0` 两套 sidecar 二进制交叉冒烟：Mac 与 iPad 新旧四种组合都能连通，
  沿用 `v0.5.0` 身份文件升级后地址不变；开启 PSK 的对照组中 `v0.5.0` 客户端握手超时。
- 默认公共 DERP 上（开发机当前网络），`v0.5.0` 客户端连 `v0.5.0` 服务端也会超时，`v0.6.0` 客户端 2–3 秒连通。
  现象与 `v0.6.0` 的 meow 重发改动一致，但尚未确认根因。

真实 iPad 的跨网络、后台恢复和长期稳定性还没有完成，因此当前结论是“技术链路可行，但不能替换生产 Tailscale”。

## 风险与优化

- Tailcat `v0.7.0` 未承诺 API 或连接地址格式稳定。升级前必须重新构建和回归。
- Tailcat `v0.6.0` 起地址默认携带 WireGuard 预共享密钥（PSK），且 `Server.Start` 每次启动都会生成新的 PSK。
  稳定服务和短期配对服务都显式关闭 PSK：已配对 iPad 持有的是无 PSK 地址，`v0.5.0` 客户端解析地址时会
  静默忽略 PSK 字段并在握手阶段超时。以后启用 PSK 必须同时满足三点：身份文件恢复原 PSK、iOS 设置最低
  客户端版本、重新审查地址流经的二维码、日志和控制面（届时地址成为秘密）。
- 本地生成的 XCFramework 约 137 MB；当前 Debug App 约 98 MB。此体积不能直接视为发布包体积，但需要在发布前单独评估。
- 当前自动测试验证了 HTTP、WebSocket、认证、1 MB 以上二进制传输、重连和身份持久化。真实蜂窝网络、NAT 切换、后台恢复、耗电和长期稳定性仍需真机验证。
- DERP 是外部依赖。中继不可用时，新的连接无法完成发现与初始握手；已经建立的直连和中继连接按各自网络路径受影响。默认公共中继免费且限速，其可用性、容量和数据处理政策由 Tailscale 决定，不受 Mimi Remote 控制。国内自建 DERP Map 仍需在跨网络验收时确认地址、证书和可达性。
- 当前 Mac 安装包、Linux 归档和 iOS App 构建已经包含 Tailcat 组件（宿主默认关闭），但 Tailcat 与 `tailscale.com` 依赖的许可证正文尚未并入 `THIRD_PARTY_NOTICES.md`，App Store 审核评估也未完成。补齐许可证清单还是从发布包移除，由维护者决定（#684）。隐私政策已说明默认中继的数据处理。
