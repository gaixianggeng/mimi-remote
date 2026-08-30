# Tailcat 远程连接实验

## 目标

验证 iPad 不安装 Tailscale 客户端时，Mimi Remote 能否仅通过 Tailcat 连接 Mac 上的 `agentd`，并保持现有 HTTP、WebSocket、认证和大文件传输能力。

本实验固定使用 Tailcat `v0.2.0`。这是 2026-08-30 GitHub 上最新的稳定版本。Tailcat 不使用 Tailscale 控制平面，但仍使用 Tailscale 的网络库和公共 DERP 中继。

## 方案

Mac 运行一个独立的 Tailcat sidecar。它只接受指定 iPad 公钥，并且只把远端 `8787` 端口转发到本机 `127.0.0.1:8787`。

iPad App 内嵌 Tailcat Go 客户端。客户端在本机打开一个随机 loopback 端口，Mimi Remote 的现有 HTTP 和 WebSocket 客户端只连接这个本地端口。连接能直连时走点对点路径，不能直连时由 Tailcat 使用 DERP 中继。

设置页的“实验功能”提供显式开关。开关打开后，App 只探测 Tailcat 路由，不回退到 Tailscale 地址或本机直连。开关关闭后，App 立即恢复原连接档案，且不会改写档案地址或 Agent Token。

## 实现

### 1. 生成 iOS 框架

需要 Xcode 27 和可自动获取 Go 1.26.5 或更高版本工具链的 Go 环境。仓库根目录执行：

```bash
bash ./scripts/build-tailcat-mobile.sh
```

脚本固定使用 `golang.org/x/mobile` 版本 `v0.0.0-20260821190718-4776eadac327`，并生成：

```text
ios/MimiRemote/Generated/TailcatMobile.xcframework
```

该产物只用于本地实验，不提交到 Git。缺少该产物时，App 仍能正常构建，但 Tailcat 开关不可用。

### 2. 获取 iPad 客户端公钥

使用统一入口构建并运行 App：

```bash
bash ./scripts/ios-dev.sh target
bash ./scripts/ios-dev.sh leases
bash ./scripts/ios-dev.sh run
```

在 App 中打开“设置 → 实验功能”，复制“客户端公钥”。私钥只保存在 iOS Keychain 中。

### 3. 启动 Mac sidecar

先确认 Mac 上的 `agentd` 已监听 `127.0.0.1:8787`。然后把 iPad 客户端公钥放入 Mac 剪贴板，并在仓库根目录执行：

```bash
TAILCAT_STATE_DIR="$HOME/Library/Application Support/MimiRemote/tailcat-experiment"
install -d -m 700 "$TAILCAT_STATE_DIR"
pbpaste > "$TAILCAT_STATE_DIR/client.public"
chmod 600 "$TAILCAT_STATE_DIR/client.public"

bash ./scripts/tailcat-experiment.sh host \
  --target 127.0.0.1:8787 \
  --port 8787 \
  --identity "$TAILCAT_STATE_DIR/host.json" \
  --address "$TAILCAT_STATE_DIR/address" \
  --allow "$TAILCAT_STATE_DIR/client.public"
```

保持该进程运行。另开一个终端，把连接地址复制到剪贴板：

```bash
TAILCAT_STATE_DIR="$HOME/Library/Application Support/MimiRemote/tailcat-experiment"
pbcopy < "$TAILCAT_STATE_DIR/address"
```

不要公开 `host.json`、`client.public` 或连接地址。删除 `host.json` 会生成新的服务端身份和连接地址。

### 4. 打开实验模式

在 App 中进入“设置 → 实验功能”，粘贴连接地址，打开“启用 Tailcat 实验”，再点“保存并连接”。

以下结果同时成立才算本轮通过：

- iPad 未运行 Tailscale 客户端。
- App 状态显示 Tailcat 已连接。
- 工作区列表、会话列表和消息收发正常。
- WebSocket 流式输出不中断。
- 图片或其他大于 1 MB 的二进制内容可以上传。
- Mac sidecar 重启后，原连接地址仍可使用。
- 关闭实验开关后，App 恢复原 Tailscale 连接档案。

### 当前验证结果

截至 2026-08-30，以下自动验证已通过：

- 本地 DERP/STUN 集成测试通过，覆盖 HTTP 401/200、WebSocket 二进制回显、1 MB 以上上传、客户端重连和服务端重启。
- 默认 `tailcat.dev` DERP Map 的实连冒烟通过，Tailcat 能把请求转发到当前运行的真实 `agentd`。
- `gomobile bind` 已生成真机和 Simulator 两个平台的 XCFramework。
- 固定 M5 iPad Simulator 能在存在 XCFramework 时构建和运行路由测试，也能在缺少 XCFramework 时完成干净构建。

真实 iPad 的跨网络、后台恢复和长期稳定性还没有完成，因此当前结论是“技术链路可行，但不能替换生产 Tailscale”。

## 风险与优化

- Tailcat `v0.2.0` 未承诺 API 或连接地址格式稳定。升级前必须重新构建和回归。
- 本地生成的 XCFramework 约 137 MB；当前 Debug App 约 98 MB。此体积不能直接视为发布包体积，但需要在发布前单独评估。
- 当前自动测试验证了 HTTP、WebSocket、认证、1 MB 以上二进制传输、重连和身份持久化。真实蜂窝网络、NAT 切换、后台恢复、耗电和长期稳定性仍需真机验证。
- 公共 DERP 是外部依赖。中继不可用时，无法直连的设备会断开。
- 该实验产物尚未补齐发布所需的完整第三方许可证清单，也未完成 App Store 审核评估。因此不得进入正式发布包。
