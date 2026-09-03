# Tailcat 远程连接实验

## 目标

验证 iPad 不安装 Tailscale 客户端时，Mimi Remote 能否仅通过 Tailcat 连接 Mac 上的 `agentd`，并保持现有 HTTP、WebSocket、认证和大文件传输能力。

本实验固定使用 Tailcat `v0.5.0`。Tailcat 不使用 Tailscale 控制平面，但仍使用 Tailscale 的网络库和 DERP 中继。

## 方案

Mac 运行一个独立的 Tailcat sidecar。sidecar 只接受已经扫码配对的设备公钥，并且只把远端 `8787` 端口转发到本机 `127.0.0.1:8787`。sidecar 启停失败不会让 `agentd` 或现有 Tailscale 会话退出。

iPad App 内嵌 Tailcat Go 客户端。客户端在本机打开一个随机 loopback 端口，Mimi Remote 的现有 HTTP 和 WebSocket 客户端只连接这个本地端口。连接能直连时走点对点路径，不能直连时由 Tailcat 使用 DERP 中继。

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

恢复 Tailcat 默认中继：

```bash
agentd tailcat configure --derp-map-url=
```

这里需要填写 DERP Map 地址，不是 DERP 服务的 IP 和端口。

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

真实 iPad 的跨网络、后台恢复和长期稳定性还没有完成，因此当前结论是“技术链路可行，但不能替换生产 Tailscale”。

## 风险与优化

- Tailcat `v0.5.0` 未承诺 API 或连接地址格式稳定。升级前必须重新构建和回归。
- 本地生成的 XCFramework 约 137 MB；当前 Debug App 约 98 MB。此体积不能直接视为发布包体积，但需要在发布前单独评估。
- 当前自动测试验证了 HTTP、WebSocket、认证、1 MB 以上二进制传输、重连和身份持久化。真实蜂窝网络、NAT 切换、后台恢复、耗电和长期稳定性仍需真机验证。
- DERP 是外部依赖。中继不可用时，无法直连的设备会断开。国内自建 DERP Map 仍需在跨网络验收时确认地址、证书和可达性。
- 该实验产物尚未补齐发布所需的完整第三方许可证清单，也未完成 App Store 审核评估。因此不得进入正式发布包。
