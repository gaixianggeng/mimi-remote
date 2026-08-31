# 本地自动发布 Mimi TestFlight

## 目标

iOS 的日常 Nightly 由 GitHub Actions 每天从最新 `main` 上传 Internal TestFlight；本页的 `git testflight-push` 保留为维护者的本地、手工和恢复入口。它会先推送 `main`、核对远端 SHA，再从该 commit 创建干净 worktree，在本机完成 build number 预检、签名 Archive、上传和 `咪咪 Internal` 分发。

正式 iOS 候选仍通过 iOS CI 手工 dispatch；Mac 和 agentd 正式版本仍由维护者推送 `v*` tag。Windows 安装器由同一个正式 Release workflow 验证并上传。Nightly 不执行 App Store 审核或公开上架。公开二进制、Go/iOS CI 和协议检查继续由 GitHub workflows 负责。

## 配置

仓库内配置位于 `config/release/ios-testflight.local.env`。本机 Secrets 位于：

```text
~/.config/ios-testflight/mimi/secrets.env
```

首次配置：

```bash
mkdir -p "$HOME/.config/ios-testflight/mimi"
cp config/release/ios-testflight.secrets.example \
  "$HOME/.config/ios-testflight/mimi/secrets.env"
chmod 600 "$HOME/.config/ios-testflight/mimi/secrets.env"
./scripts/install_git_testflight_push.sh
```

MIM-78 引入 Widget Extension 后，Apple Developer 还必须先完成：

1. 注册 App Group `group.com.gaixianggeng.mimi`。
2. 注册 Widget App ID `com.gaixianggeng.mimi.carstatuswidget`，并让主 App 与 Widget App ID 都启用该 App Group。
3. 重新生成主 App 的 App Store profile，并新建 Widget App Store profile。
4. 将重新生成的主 App profile ID/name 更新到 `IOS_PROVISIONING_PROFILE_ID`、`IOS_EXPECTED_PROVISIONING_PROFILE_NAME`，并将 Widget profile 的真实 ID/name 写入已注释的 `IOS_WIDGET_PROVISIONING_PROFILE_ID`、`IOS_WIDGET_EXPECTED_PROVISIONING_PROFILE_NAME`；也可在本机 Secrets 中使用对应的 profile path 临时覆盖。

配置未完成时，`git testflight-push --check` 会明确失败；不要用主 App profile 代替 Widget profile。

### 固定版本 asc（MIM-92 第一阶段）

仓库把 `asc` 固定为 `3.4.1`，版本、macOS arm64/amd64 SHA-256 与 Developer ID Team 都记录在 `config/release/ios-asc-cli.env`。不使用 `latest`，也不把二进制或凭据提交到仓库。

本机安装和离线校验：

```bash
bash ./scripts/ios_asc_cli.sh install \
  --destination "$HOME/.local/bin/asc"

bash ./scripts/ios_asc_cli.sh check \
  --binary "$HOME/.local/bin/asc"
```

安装命令从固定的 GitHub Release URL 下载，校验 SHA-256、`codesign --verify --strict`、Developer ID Team 和 `asc version` 后才写入目标路径；目标已存在但不匹配时会直接失败，不会静默覆盖。上游 3.4.1 的 Developer ID 签名有效，但未 notarize，因此这里不把会拒绝该产物的 `spctl` 作为通过条件。

第一阶段提供三种构建号模式：

- `off`：默认本地行为，不调用 asc。
- `shadow`：查询 `asc builds next-build-number` 并记录与 Ruby 预检的差异；查询失败或不一致只告警，Ruby 结果仍唯一决定 Archive 和上传使用的 build number。
- `enforce`：与 shadow 相同，但工具校验、查询或构建号不一致会阻止发布；完成真实影子验证前不启用。

本地启用 shadow 时，只在仓库外的 `~/.config/ios-testflight/mimi/secrets.env` 增加：

```bash
IOS_ASC_BUILD_NUMBER_MODE=shadow
ASC_CLI_BIN="$HOME/.local/bin/asc"
```

调用 asc 时脚本会把现有 `APP_STORE_CONNECT_API_KEY_*` 映射为 asc 的环境变量，并在单次进程内强制设置：

```bash
ASC_TELEMETRY_DISABLED=1
ASC_BYPASS_KEYCHAIN=1
ASC_STRICT_AUTH=1
```

不要执行 `asc install-skills`，也不要创建仓库内 `.asc/config.json`。GitHub TestFlight job 会把固定二进制安装到 `RUNNER_TEMP` 并启用 `shadow`；现阶段不会用 asc 上传、分发、提交审核或替代 `altool --validate-app`。

## 使用

先做无副作用预检：

```bash
git testflight-push --check
```

预检会验证当前分支、已提交的项目配置、发布入口、本机 Secrets、证书/ASC Key 文件、Keychain 密码条目和 Xcode 等命令依赖；不会 push、Archive 或上传。Mimi 客户端的 TestFlight 按钮以该检查结果为准，未通过时只展示失败原因，不允许发布。

签名、Archive 和 Apple 服务端验证，但不上传：

```bash
./scripts/ios_testflight_local.sh \
  --dry-run \
  --ref HEAD \
  --what-to-test '本地验证，不上传。'
```

推送成功后自动发布：

```bash
git testflight-push \
  --what-to-test '验证 iPad 连接、项目、会话、日志和审批链路。'
```

普通 `git push` 只推送，不发布。标准 Git 没有客户端 `post-push` hook，因此使用显式包装命令保证“远端成功后才上传”。

客户端快捷发布的执行顺序是：用户确认 → 暂存当前授权工作区 → commit → 普通 push。TestFlight 是第二个独立确认动作，启动后由主机后台任务执行；关闭客户端页面不会中断发布，重新进入“变更”页会继续读取任务状态。

## 风险与恢复

- push 失败不会上传；Apple 阶段失败后可对同一 commit 重新执行。
- 同一 commit 成功状态保存在 `~/Library/Application Support/ios-testflight-local/mimi/`，默认防止重复上传。
- 主工作区的未提交内容不会进入构建；发布来源始终是明确 commit。
- 本机必须在线、解锁，并安装配置指定的 Xcode 与有效签名材料。
- asc shadow 的 `error` 或 `mismatch` 不是验证通过；先从发布日志中的 `ASC_CLI_SHADOW_STATUS` 核对差异，再决定是否升级为 `enforce`。
- `agentd` 重启会丢失内存中的任务展示状态；发布是否已经结束应从 `~/Library/Logs/ios-testflight-local/<project-id>/` 和 last-run 状态文件恢复核对，确认后再决定是否重试。
