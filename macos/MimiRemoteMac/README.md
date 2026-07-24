# Mimi Remote Mac

## 目标

把原本隐藏在终端和 Homebrew service 后面的 Mac 端能力，收敛为一个轻量菜单栏 App。App 负责状态、设置、配对、诊断与系统服务生命周期；Go `agentd` 继续负责协议、安全边界和 Codex / Claude Runtime，不重复实现后端。

源码开发需要 macOS 26、Xcode 27、XcodeGen 和 Go 1.25。正式 Release 通过 GitHub Actions 生成 universal DMG，对 App、内嵌 `agentd` 和磁盘镜像使用 Developer ID 签名，并完成 Apple Notarization；自动更新暂不进入首个安装包闭环。

## 方案

- `SwiftUI + Observation`：原生菜单栏、Dashboard、配对、诊断和设置界面。
- `SMAppService`：注册 App bundle 内的 LaunchAgent；登录后同时启动菜单栏 App 和 `agentd`。
- 内嵌 Go `agentd`：构建阶段按目标架构编译并使用稳定 identifier 签名。
- 单一 `HostStore`：统一管理服务 owner、迁移、就绪、错误和监控状态。
- 小型 Client：命令执行、健康检查、ServiceManagement、Homebrew 和日志相互独立，便于测试与复用。
- 自动网络：优先使用 Tailscale；未安装或不可用时启用同一局域网直连，并返回真实 LAN 地址而不是本机回环地址。
- 轻量监控：每 10 秒只请求 localhost `/healthz`，每 5 分钟才执行一次完整状态刷新。

App 不读取或展示长期 Token。设置和配对只调用 `agentd ... --qr-only --json`，界面只接收短期配对票据。

## 实现

### 构建与测试

```bash
cd macos/MimiRemoteMac
xcodegen generate --spec project.yml

cd ../..
xcodebuild \
  -project macos/MimiRemoteMac/MimiRemoteMac.xcodeproj \
  -scheme MimiRemoteMac \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/MimiRemoteMac \
  CODE_SIGN_STYLE=Automatic \
  test
```

构建本地 Release：

```bash
bash macos/MimiRemoteMac/Scripts/build-local.sh
```

安装到当前用户的 Applications 目录：

```bash
bash macos/MimiRemoteMac/Scripts/install-local.sh
open "$HOME/Applications/Mimi Remote Mac.app"
```

也可以显式安装到系统 Applications；目录不可写时 macOS 会要求在终端中自行使用有权限的账户操作：

```bash
bash macos/MimiRemoteMac/Scripts/install-local.sh "/Applications/Mimi Remote Mac.app"
```

### 正式安装包

正式 tag 的 Release workflow 会生成 `Mimi-Remote-Mac.dmg` 和 SHA-256 文件。维护者可在没有发布凭据时先验证完整的 universal 构建链路：

```bash
bash scripts/build-macos-installer.sh \
  --snapshot \
  --version 0.2.0 \
  --output-dir dist-macos
bash scripts/check-macos-installer.sh dist-macos/Mimi-Remote-Mac.dmg
```

正式构建必须提供 Developer ID PKCS#12 和 App Store Connect Notary API 凭据；脚本拒绝把 ad-hoc 快照作为正式包生成。

### 首次启动

1. 如果没有配置，选择项目扫描的代码根目录。App 将项目扫描范围设为该目录、文件浏览范围设为当前用户 Home，再调用安全的 `agentd setup --qr-only` 完成设置；有 Tailscale 时优先使用，否则自动启用局域网。
2. 如果检测到 `homebrew.mxcl.mimi-remote`，App 先保持旧服务运行并显示“等待接管”。
3. 用户确认后，App 先跑 Doctor，再停止 Homebrew service、注册内嵌 LaunchAgent 并等待 readyz。
4. 任一步失败都会尝试重新启动 Homebrew service；设置页也保留手动恢复入口。

### 运行数据

- 配置：`~/Library/Application Support/mimi-remote/`
- 当前日志：`~/Library/Logs/mimi-remote/agentd.log`
- 上一段日志：`~/Library/Logs/mimi-remote/agentd.log.previous`
- 日志单文件上限：5 MiB

## 风险与优化

- macOS 文件权限与签名身份绑定。开发版保持固定 Team 和 helper identifier，但首次从 Homebrew 二进制迁移仍可能需要重新确认文件访问权限。
- 文件浏览范围默认覆盖当前用户 Home，配对 Token 是远程读取文件的安全边界；项目扫描仍只遍历用户选择的代码目录。
- `SMAppService` 的 `.requiresApproval` 不能由 App 绕过；界面会引导用户打开“系统设置 → 通用 → 登录项与扩展”。
- App 被移走或删除前，应先在 App 内恢复 Homebrew 或停止服务，避免系统仍保留指向旧 bundle 的注册记录。
- 首个 DMG 不带自动更新；升级时下载新 DMG 覆盖 App，`agentd` 配置和配对数据保存在用户 Application Support 中，不随 App 覆盖。
