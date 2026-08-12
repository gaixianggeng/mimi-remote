# Mimi Remote iOS App

## Build from source (English)

Mimi Remote is a native iPhone/iPad client for coding agents running on your own Mac. The current source tree supports iOS/iPadOS 18 or later; App Store availability and minimum OS requirements follow the current listing for each region. The public release is available from the [App Store](https://apps.apple.com/us/app/mimi-remote/id6778076511) in supported regions, while [TestFlight](https://testflight.apple.com/join/jhGPbSk6) provides beta builds. Building from source still requires Xcode 26 or later with the iOS 26 SDK plus XcodeGen so the same binary can keep iOS 26+ Liquid Glass and Apple Speech features behind availability checks. From the repository root, install XcodeGen, then generate and open the project:

```bash
brew install xcodegen

xcodegen generate \
  --spec ios/MimiRemote/project.yml \
  --project ios/MimiRemote

open ios/MimiRemote/MimiRemote.xcodeproj
```

Select the `MimiRemote` scheme in Xcode and configure your development team for physical-device builds. Daily `build` and `run` lease an available, paired USB iOS device, skip busy targets, and then fall back to the fixed `iPad Pro 13-inch (M5)` Simulator. Tests, snapshots, and CI require that exact Simulator and never switch to iPad mini. Build the Mac service first with Codex CLI signed in, run `agentd up`, then scan its short-lived pairing QR code in the app. For a command-line test build check:

```bash
bash ./scripts/ios-dev.sh build-for-testing
```

The detailed engineering and operational reference below is currently in Chinese.

## 目标

Mimi Remote 是原生 iPhone / iPad SwiftUI 控制台。`MimiRemote` 只保留为 Xcode target、scheme 和源码目录名，不作为用户侧产品名。

目标主链路是 iPhone / iPad App 直接消费 Codex app-server JSON-RPC 协议；Mac 上的 `agentd` 只负责项目 allowlist、鉴权、健康诊断、app-server 启动和可选薄网关。这个 App 是独立第三方客户端，不隶属于 OpenAI，也不是任何商业产品的免费替代品。

## 方案

整体链路：

```text
iPhone / iPad SwiftUI App
  -> REST: /api/projects /api/app-server/config
  -> WebSocket: /api/app-server/ws
  -> Codex app-server JSON-RPC
Mac agentd control plane / thin gateway
  -> loopback codex app-server WebSocket upstream
```

已下线旧链路：`/api/sessions*`、`/api/sessions/{id}/ws`、Web/PWA 和 iOS PTY 文本解析回退都已经删除。后续不要再基于这些入口增加功能。

高级体验继续按 iOS/iPadOS 26+ 推进，但 `project.yml` 的 deployment target 为 iOS 18.0。iOS 18–25 使用普通系统材质，并隐藏或回退无法提供的系统能力；iOS 26+ 保留 Liquid Glass 与 Apple 设备端实时语音。MVP 不在 iPad 上运行 Codex；Mac Catalyst 只自动检测同机固定 loopback，不扫描局域网或其它 Mac。用户先在 Mac 上执行：

```bash
codex --version
codex app-server --help

agentd up
agentd doctor
```

`agentd start` 会通过当前平台的后台服务管理器启动 agentd（macOS 为 Homebrew，Linux Release 为 user-systemd），并在当前终端输出扫码连接二维码；后台服务本身不会把 Token 写入日志。然后在设置页优先点“扫码连接”，扫描后会自动测试连接。二维码不可用时再手动输入：

- Endpoint，例如 `http://100.x.y.z:8787` 或 MagicDNS 的 `http://<mac-hostname>.<tailnet>.ts.net:8787`
- Token，也就是 `AGENTD_TOKEN`
- 连接链接，例如 `mimiremote://connect?endpoint=...&token=...`
- 配对二维码使用 `mimiremote://pair?endpoint=...&issued_at=...&expires_at=...&pair_sig=...`，不直接携带长期 Token；同一票据和复制链接可在生成后的 10 分钟内重复兑换，超过 `expires_at` 后统一拒绝

相机权限被拒绝或受设备限制时，扫码页会提供“前往系统设置”和“改用手动连接”；相机不可用或配置失败时也可选择手动连接，回到当前连接页后自动展开已有的手动连接区域。App 只在用户主动打开扫码页时申请相机权限，不增加后台相机能力。

App 可以保存多台 Mac，但同一时间只连接一台。每台 Mac 的 Token 存入独立 Keychain account；UserDefaults 只保存显示名、Endpoint、最近成功时间和当前档案 ID。已有档案可在设置中重命名，名称会 trim 且最多 48 个字符；重命名只更新本地非敏感元数据，不读取 Keychain、不切换 Endpoint，也不重建 WebSocket。“忘记当前 Mac”和删除非当前档案都会先明确提示将删除系统 Keychain 访问码、需要重新扫码配对，只有用户二次确认后才执行。旧版单 Endpoint/Token 会按 Keychain-first 顺序迁移，失败时继续保留原连接。iPad 客户端只保存 Mac 的 Tailscale Endpoint，旧版本保存过的备用公网配置会在启动时自动清理。当前支持 `http://100.x.x.x:8787` 这类 Tailscale 裸 IP；由于 iOS 27 实测中 `NSAllowsLocalNetworking` 仍会拦截该地址，系统层使用 `NSAllowsArbitraryLoads`，应用层在设置、REST 和 WebSocket 三层统一拒绝公网 HTTP。公开发布仍推荐评估 MagicDNS HTTPS，减少私网 HTTP 的运维解释成本。

会话提醒和运行态本地通知支持点击回到目标会话。App 前台已经显示目标会话时，Codex 与 Claude 的审批、补充信息、完成和失败通知会保持静默，避免与会话内状态重复打断；列表页、其他会话、设置页或后台状态仍正常提醒。系统通知 payload 只保存版本、profile/project/session 路由，不保存 Token 或明文 Endpoint；只有当前活动 Mac 可以直接打开，其他档案的通知只提示用户到设置中手动切换，不会在后台读取 Token 或自动跨连接。

App target 打包 `Resources/PrivacyInfo.xcprivacy`：声明不跟踪、不配置跟踪域、不由项目开发者收集用户数据；`UserDefaults` 只用于 Endpoint、界面偏好和本地会话控制状态，因此按 Apple 的 approved reason `CA92.1` 声明。发布前运行 `bash ./scripts/check-ios-privacy-manifest.sh`，并以 App Store Connect 的实际隐私报告为最终准入依据。Apple 规则入口：[Privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)、[Required reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)。

direct 模式下，iPad 仍只连接 `agentd`，不会直接保存 app-server upstream token。`agentd setup` 会生成独立 upstream token file；Mac 侧由 `agentd` 读取并注入上游 `Authorization`，iPad 不接触这个 token。

直连要求：

1. 推荐用 `agentd setup` 生成配置；`agentd serve` 会在 `app_server.managed=true` 时自动托管 loopback `codex app-server`。
2. 设置页扫码连接会先用短期配对票据兑换 Endpoint/Token，再校验 `/api/app-server/config` 和 gateway 可用性。
3. 点击“保存并加载”会先原子提交新 Endpoint/Keychain Token；只有提交成功才断开旧 WebSocket 并切换 client，失败时完整保留旧连接和会话。凭据提交后会复用冷启动退避加载项目和会话：首次配对最多等待 45 秒，修复或切换已有档案最多等待 10 秒；超时保留已提交凭据并提示直接重试，不会误报“已连接”。配对票据未过期时可以直接重试，无需重新扫码。
4. 网络不可用时暂停可见轮询和 WebSocket 重连；恢复后只触发一次受 connection generation 保护的重连。瞬时失败使用带 jitter 的指数退避，401/403 凭据终态不会继续重试。
5. 切换已保存 Mac 时先读取目标档案 Token 并完成连接验证，再提交档案、退役旧 WebSocket 和清理旧 Mac 会话；不同时维持两台 Mac 的连接。

## 实现

目录结构：

```text
Sources/
  Core/API              agentd control-plane 和 app-server JSON-RPC 客户端
  Core/Models           app-server / agentd control-plane JSON 模型
  Core/Parsing          历史文本解析与 Markdown 渲染辅助
  Core/Security         Keychain TokenStore
  State                 AppStore / SessionStore / SessionIndexStore / MessageStore / EventReducer / LogStore
  Features              设置、项目、会话、对话、日志、诊断视图
```

关键性能约束：

- 输入框只维护本地 `ComposerState`，不触发日志刷新。
- direct 模式由 Swift JSON-RPC client 处理 app-server request/response、notification 和 server request。
- app-server 事件先投影成内部 `AgentEvent`，再由 `EventReducer` 分发给消息层和日志层；`SessionStore` 只协调低频 session 状态。
- `LogStore` 先批量合并 output，再以 120ms 节流刷新 UI；内部保留 120000 字符，界面渲染最近 80000 字符。
- app-server runtime 不依赖终端尺寸，不跟随 iPad 键盘或布局变化频繁发送 resize。
- direct 模式不把终端文本作为主消息来源；消息以 app-server 结构化事件为准。

Managed Worktree 清理采用固定的人工确认流程：

1. APP 先调用 `/api/worktrees/cleanup` 获取 dry-run 计划，展示固定的 30 天候选阈值、每项目至少保留最近 3 个以及每个 checkout 的 blocker。
2. 只有 `candidate_paths` 与当前 `eligible` 的交集可被选择；执行时必须回传同一个 `plan_id`、精确路径并显式确认。
3. APP 不提供 `force` 入口。agentd 会在删除前重新检查托管根、仓库身份、Git clean 状态、HEAD、最近使用时间和运行中会话，任一状态变化都失败关闭。
4. 批量删除如果只完成一部分，APP 会先移除 `deleted_paths` 并刷新列表，再保留页面展示 `failed_path/error`，不会把部分成功误报成完全失败。checkout 已删除但 registry unlink 失败时，普通删除的 `registry_cleanup_error` 和 prune 的 `failed_paths` 也会显示为可重试警告。

## 构建

生成 Xcode 工程：

```bash
cd "$HOME/code/mimi-remote"
xcodegen generate --spec ios/MimiRemote/project.yml --project ios/MimiRemote
```

日常 `build` / `run` 会先检测 available、paired、USB 连接且未占用的真机：多台设备按 `iPad Pro`、设备名、UDID 的固定顺序选择；设备已有租约或被外部 `xcodebuild` 使用时跳过。没有空闲 USB 真机时才使用 `iPad Pro 13-inch (M5)` Simulator。`build-for-testing`、`test`、视觉快照和 CI 始终精确固定这台 M5 iPad；设备缺失或忙时明确失败，不切换到 iPad mini。

先查看本次实际目标：

```bash
bash ./scripts/ios-dev.sh target
```

查看全部设备的租约和外部 `xcodebuild`：

```bash
bash ./scripts/ios-dev.sh leases
```

命令行验证 Swift 代码可编译：

```bash
bash ./scripts/ios-dev.sh build
```

测试 target 编译：

```bash
bash ./scripts/ios-dev.sh build-for-testing
```

运行全部单测，或构建、安装并启动 App：

```bash
bash ./scripts/ios-dev.sh test
bash ./scripts/ios-dev.sh run
```

只有明确验证 iPhone 布局时才覆盖目标；完成后恢复默认 iPad：

```bash
IOS_TARGET_MODE=simulator IOS_SIMULATOR_NAME="iPhone 17 Pro" bash ./scripts/ios-dev.sh run
IOS_TARGET_MODE=simulator IOS_SIMULATOR_NAME="iPhone 17e" bash ./scripts/ios-dev.sh run
```

需要显式覆盖自动规则时，使用 `IOS_TARGET_MODE=device|simulator`、`IOS_DEVICE_ID` 或 `IOS_SIMULATOR_ID`。普通 `build` / `run` 会按 UDID 原子获取跨 Worktree 租约，记录 PID、Codex Task、Worktree、命令、DerivedData 和开始时间；正常退出自动释放，死 PID 租约在下次获取时清理。固定快照设备忙时可以设置 `IOS_DEVICE_LEASE_WAIT_SECONDS` 等待，否则脚本明确失败。

所有 Simulator 和真机都在对应根目录下按 UDID 隔离 DerivedData；即使两个 Runtime 中存在同名 `iPad Pro 13-inch (M5)`，也会使用不同构建目录，避免不同设备并发写入同一构建数据库。显式设置 `IOS_DERIVED_DATA_PATH` 时，调用方必须保证该路径只供当前目标使用。

XcodeBuildMCP 会从仓库根目录的 `.xcodebuildmcp/config.yaml` 读取 project、scheme、Debug 和 Simulator fallback，但配置不保存静态 DerivedData。使用 Simulator workflow 前，先分别运行 `bash ./scripts/ios-dev.sh destination` 与 `bash ./scripts/ios-dev.sh derived-data-path`，再把同一目标的 `simulatorId` 和 `derivedDataPath` 一起写入本次 session defaults；不得把本机 UDID 持久化到仓库。如果日常 `build` / `run` 选中真机，应使用 device workflow 或统一脚本，不能继续沿用 Simulator defaults。

Simulator 开关采用“开发时保持一台、结束后关闭”的标准：

- 只运行 `build` 或 `build-for-testing` 时无需预先启动 Simulator；USB 真机构建也不会为此启动 Simulator。
- 使用 Simulator 连续开发、调试 UI 或运行测试期间保持默认 iPad 开启，不在同一开发时段反复开关。
- 预计一小时内还会继续时可以保持开启；长时间不用、当天开发结束或准备让 Mac 合盖过夜前关闭。
- 切换 iPhone 兼容性目标前先确认 `leases` 没有其他任务占用 iPad；统一脚本不会关闭其他任务正在使用的 Simulator。验收结束后关闭不用的 iPhone，后续开发恢复默认 iPad。
- 出现高 CPU、安装卡住或睡眠恢复异常时，关闭并重新启动现有 Simulator；不要擦除主力设备或创建新设备绕过问题。

Mac Catalyst 使用同一套 SwiftUI 源码和 iPad 缩放界面，不增加 Mac 专用功能。生成工程后，可在 Apple Silicon Mac 上验证独立 Catalyst 构建：

```bash
xcodebuild \
  -project ios/MimiRemote/MimiRemote.xcodeproj \
  -scheme MimiRemote \
  -configuration Debug \
  -destination 'generic/platform=macOS,variant=Mac Catalyst' \
  CODE_SIGNING_ALLOWED=NO \
  clean build
```

在 Mac 上运行：

1. 用 Xcode 打开 `ios/MimiRemote/MimiRemote.xcodeproj`。
2. 选择 `MimiRemote` scheme。
3. 运行目标选择 `My Mac (Mac Catalyst)`。
4. 设置开发者 Team 和签名后 Run。

Catalyst 产物使用独立的 Mac `Info.plist`、App Sandbox 权限和标准 Mac 图标；现有 iPhone/iPad 构建、部署与 TestFlight 流程不变。

同机连接有一条轻量优化链路：当 `agentd` 配置为具体的 Tailscale 或局域网 IP 时，服务端会同时监听相同端口的 `127.0.0.1`，不会扩大到 `0.0.0.0`。Catalyst 冷启动先探测 `http://127.0.0.1:8787/healthz`，再用当前 Mac 档案已经保存的 Token 验证本机链路；验证成功后本次运行优先走 loopback，但档案身份和缓存仍使用原 Tailscale Endpoint。首次配对仍需扫描二维码或输入访问码，本机健康检查不会返回 Token。手动填写私网 HTTP 地址时省略端口会自动补为 `8787`。

自动规则选中真机时，`bash ./scripts/ios-dev.sh run` 会完成构建、安装和启动。也可以显式使用真机部署入口：

1. 用 Xcode 打开 `ios/MimiRemote/MimiRemote.xcodeproj`。
2. 选择 `MimiRemote` scheme。
3. 选择 iPad 真机。
4. 设置开发者 Team 和签名。
5. Run。

如果真机覆盖安装后主屏仍显示旧图标或空白图标，可以用仓库根目录的部署脚本刷新安装：

```bash
REFRESH_INSTALL=1 ./scripts/deploy-ipad.sh
```

## 验收

基础验收：

- 能保存 Endpoint + Token。
- 拒绝或限制相机权限时能前往系统设置或改用手动连接；相机不可用时选择手动连接会回到原连接页并展开手动连接区域。
- 首次扫码、URL Scheme 或手动配对遇到 Tailscale/gateway 瞬时未就绪时，会在 45 秒内自动恢复；超时保留凭据、展示可重试错误且不弹成功提示。
- 修复或切换已有 Mac 使用 10 秒有界恢复，失败时不回滚已安全提交的新档案，也不误报加载成功。
- Keychain 或连接提交失败时仍保留旧 Endpoint、Token、WebSocket 和本地会话。
- “忘记当前 Mac”和删除非当前档案第一次点击只展示确认；取消不删除 Keychain，确认文案包含目标 Mac 和重新扫码配对提示。
- 401/403 凭据失效会停止轮询/重连并提示重新配对；普通业务 403 不误判。
- 离线时不重连且不清空会话/排队消息；网络恢复后只重连一次。
- 能测试连接并显示 agentd 版本。
- 能拉取项目列表和会话列表。
- 能选择 Codex 历史会话并加载历史消息。
- 能新建会话和继续历史会话。
- direct 模式能完成 `initialize -> thread/start -> turn/start`。
- 能通过 app-server notification 接收 assistant delta、completed item、日志、diff、turn completed。
- 能发送普通输入、Ctrl-C/interrupt 和审批响应。
- 能停止 running session。
- 能预览 Managed Worktree 清理候选和 blocker；确认执行后正确处理全部成功、状态过期和部分成功结果，且没有强制丢弃改动入口。
- 设置页固定使用 direct 模式，保存后不复用旧 WebSocket。
- 能在设置页切换外观模式、主题预设、UI 字体、代码字体和字体大小，主工作台立即生效并在重启后保持。

外观验收：

- 外观模式支持 `系统`、`浅色`、`深色`；系统模式跟随当前设备外观，手动浅色/深色不跟随系统变化。
- 主题预设先支持 `Codex`、`Xcode`、`Gruvbox`，覆盖聊天背景、气泡、代码块、侧栏选中态、日志和 Inspector 常用面板。
- 字体设置支持 UI 字体、代码字体和 85%-135% 字体大小；超出范围会自动 clamp。
- 外观设置只写入本机 `UserDefaults`，不触发连接重置，不影响 Endpoint、Token、会话、日志和 app-server runtime。

性能验收：

- 输入框连续输入 200-500 字，右侧日志不应随每个按键刷新。
- WebSocket 持续输出时，输入框仍可编辑。
- 日志超过 120000 字符后只保留尾部。
- 日志面板可把当前会话 ANSI 清洗后的 120000 字符缓存窗口导出为 UTF-8 `.log`；导出头部不读取 Token、Endpoint 或 Keychain，但正文可能包含用户命令、代码和工具输出，分享前需要检查。
- 大段终端输出时 CPU 不应长期高占用，优先用 Instruments 的 Time Profiler 和 Allocations 看 `LogStore`、`ConversationStore`。
- 真机优先验收，Simulator 只能做辅助。

## 风险与优化

当前限制：

- 可以保存多台 Mac，但只支持一个当前档案和一条活动后端连接；Catalyst 仅检测同机固定 loopback，不做 Bonjour/SSH 任意主机发现或档案云同步。
- direct 模式仍需要 app-server WebSocket transport 或 agentd 薄网关。
- 每个 session 当前只允许一个 iOS WebSocket attach。
- app-server runtime 走结构化事件；iOS 不再用 PTY/TUI 文本启发式解析消息气泡。
- 当前后端默认是 HTTP。iOS 27 上 Tailscale 裸 IP 需要 `NSAllowsArbitraryLoads`，App 再在应用层只允许本机、私网或 Tailscale Endpoint；不提供应用层公网备用入口。发布前仍需用真机验收 Tailscale IP、前后台切换和弱网恢复，并优先评估 MagicDNS 域名 + HTTPS。
- 弱网恢复逻辑已有确定性回归测试，但仍需在真机上验证 Wi-Fi/蜂窝切换、前后台切换和 Tailscale VPN 暂停/恢复。
- Managed Worktree 不做无人值守自动删除；多个 checkout 也不能形成文件系统事务，极端外部竞争可能返回结构化部分结果，需要以服务端最新列表为准。

后续优化：

- Cloud / projectless thread。
- 后台 push、真正离线时的远端通知和离线状态同步。
- Instruments 基准脚本和 XCTest UI 自动化。
