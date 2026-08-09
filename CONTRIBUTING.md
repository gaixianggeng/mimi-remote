# 贡献指南

感谢你愿意改进 Mimi Remote。这个项目优先接受能解决真实使用问题、保持本地优先安全边界、且不会显著增加小团队维护成本的改动。

## 提交 Issue

Bug 请尽量包含：

- iPhone / iPad 型号与系统版本；
- Mimi Remote、`agentd`、Codex CLI 或 Claude bridge 的版本；
- 最小复现步骤、预期结果和实际结果；
- 已脱敏的日志或截图。

不要公开提交 Token、Tailscale IP、私有仓库内容、真实工作目录或完整会话。安全问题请按 [SECURITY.md](SECURITY.md) 私下报告。

## 提交 Pull Request

1. 先确认改动范围清晰；较大功能建议先开 Issue 讨论边界。
2. 保留现有架构与安全策略，不引入无必要的云服务、遥测或重型依赖。
3. 核心逻辑添加中文注释，说明为什么这样实现。
4. PR 描述中写清目标、实现、验证结果和已知风险。
5. 新增或改变可选能力时，PR 必须写明 capability 名称/版本、启用依赖、安全旧路径、
   本地 kill switch、回滚步骤，以及旧服务端、未知状态和多 Host 验证结果。

## 本地验证

Go 后端改动至少运行：

```bash
go test ./... -count=1
go vet ./...
bash ./scripts/check-codex-protocol.sh
```

iOS 改动至少生成工程并完成无签名构建：

```bash
xcodegen generate \
  --spec ios/MimiRemote/project.yml \
  --project ios/MimiRemote

bash ./scripts/ios-dev.sh build-for-testing
```

日常 `build` / `run` 优先租用 available、paired、USB 连接的真机，跳过已占用设备后回退到 `iPad Pro 13-inch (M5)` Simulator。`build-for-testing`、`test`、快照与 CI 精确固定这台 M5 iPad，忙或缺失时不切换 iPad mini。使用 `bash ./scripts/ios-dev.sh leases` 查看跨 Worktree 租约和外部 `xcodebuild`；兼容性运行通过 `IOS_TARGET_MODE=simulator` 和 `IOS_SIMULATOR_NAME` 显式切换。

Claude bridge 改动至少运行：

```bash
cargo fmt --all -- --check
cargo test --locked \
  -p alleycat-codex-proto \
  -p alleycat-bridge-core \
  -p alleycat-claude-bridge
```

公开仓库安全相关改动还应运行：

```bash
bash ./scripts/check-public-repo-safety.sh
bash ./scripts/check-third-party-notices.sh
bash ./scripts/check-ios-privacy-manifest.sh
```

## Mimi iOS / agentd 契约

iOS 与 `agentd` 的版本窗口、握手 header、capabilities 和共享 golden fixtures 以
[`contracts/mimi-protocol/`](contracts/mimi-protocol/) 为权威来源。不要直接修改
Go/Swift 生成文件。协议变化先更新 manifest 与 fixtures，再执行：

```bash
go run ./internal/protocolcontract/cmd/generate --write
bash ./scripts/check-mimi-protocol-contract.sh
bash ./scripts/test-conversation-regressions.sh
```

字段演进、跨版本矩阵、失败语义和风险边界见
[Mimi iOS / agentd 版本化契约](docs/mimi-protocol-contracts.md)。
可选能力的声明、状态机、本地禁用和恢复步骤见
[Capability 声明与本地降级](docs/capability-rollout.md)。

关键用户链路的风险、测试层和 PR Gate selector 映射见
[关键用户链路分层回归](docs/critical-user-journey-regressions.md)。修改配对、Host
切换、连接恢复、会话/turn、审批/中断或 Git/Worktree 链路时，先运行：

```bash
bash ./scripts/check-critical-regressions.sh
bash ./scripts/test-conversation-regressions.sh
```

## 快速 PR Gate

每个 Pull Request 都会产生名称固定的 `PR Gate` check。该 workflow 本身不使用
`paths` 或 `paths-ignore`，因此纯文档、删除文件或跨目录移动也会得到明确结果，
不会因为整条 workflow 未触发而留下可忽略的检查缺口。

门禁并行执行以下检查：

- 始终执行 Codex 协议快照、公开仓库安全和 PR Gate 配置自检；
- Go、Windows/Linux 打包或 Release 相关路径调用现有 Go CI；
- Mac App 源码与 Xcode 工程路径调用独立 Mac App CI，使用无签名 build 运行现有 Scheme 单测；
- iOS、App Store/TestFlight 脚本或相关文档路径调用现有 iOS CI；
- Cargo 或 `bridges/claude` 路径调用现有 Rust bridge CI；
- `.github/workflows`、`.github/actions` 或 Gate 分类脚本变化时执行全部语言检查。

提交前始终运行：

```bash
bash ./scripts/check-pr-gate.sh
bash ./scripts/check-public-repo-safety.sh
bash ./scripts/check-codex-protocol.sh
```

再按改动范围运行本文件前述 Go、iOS 或 Claude bridge 命令。Release/打包改动还需运行：

```bash
bash ./scripts/check-packaging.sh
```

`PR Gate` 红灯时先打开失败的子 job；最终聚合 job 只负责判断必需检查是否成功，
真正的错误日志保留在 `Go and release`、`iOS`、`Rust bridge`、`Mac App`、`Codex protocol`
或 `Repository safety` 中。`Detect change scope` 失败时，先用下面的命令确认
base/head 可读取且路径分类符合预期：

```bash
bash ./scripts/ci-pr-scope.sh --base origin/main --head HEAD
```

`main` 分支保护必须把名称精确为 `PR Gate` 的 check 设为 required，并让未完成或
失败状态阻止常规合并。紧急 bypass 只允许用于回滚已经确认影响生产可用性的提交；
不得用于功能交付、测试不稳定或赶发布时间。使用 bypass 时必须在回滚 PR 或关联
Issue 中记录原因、被绕过的失败 check、操作者、时间、回滚 commit，以及后续补验
负责人和结果；补验完成前不得关闭关联 Issue。不要通过临时删除 required check、
关闭 `enforce admins` 或修改 workflow 让 Gate 变绿。
