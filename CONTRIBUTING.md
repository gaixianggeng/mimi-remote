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

开发过程中只运行当前问题需要的最小检查，不要在每次微调后重复执行全量测试、
Simulator 回归和真机验证。完成最后一次代码修改后，根据风险选择下面一个流程。

普通改动选择 quick：

```bash
bash ./scripts/verify-change.sh --plan
bash ./scripts/verify-change.sh
```

命中下述 full 条件时选择 full：

```bash
bash ./scripts/verify-change.sh --plan --full
bash ./scripts/verify-change.sh --full
```

计划与执行使用同一模式，不要先执行 quick 再运行 full。`--plan` 展示变更来源、受影响栈、
命令、执行或跳过原因和真机延后项。
脚本会合并 `origin/main...HEAD`、暂存区、工作区和未跟踪文件并去重：

- 纯文档不启动 Go、Cargo、Xcode 或真机；
- CI、脚本和发布控制面只运行语法检查及对应的无设备自测；
- Go 默认只测试直接变更的 package；
- iOS 默认固定 `iPad Pro 13-inch (M5)`，只编译 App，不编译或运行整个 XCTest 测试包；
- Rust、Mac App、共享契约和打包改动只进入各自的必要门禁；
- 未映射路径会明确失败，不会被静默当作通过。

开发过程中需要 XCTest 时，只运行与当前问题直接相关的 selector。共享协议、跨栈接口或同一
链路包含多个产品栈时，要定向覆盖接口兼容、错误语义和降级链路，但这类路径本身不要求
本地 full。只有修改鉴权、权限、持久化或迁移、消息 exactly-once、并发、重连等高风险
语义，影响范围无法界定的大重构，本地 full 能补齐必要回归的 CI 覆盖缺口，准备正式发布，或用户明确要求时才选择
full。

选择 full 时，先检查 full 计划中的命令，并核对这些命令所调用脚本的实际目标、配置和
selector。full 计划已经覆盖 quick 项目时，不另跑 quick；full 没有覆盖当前风险所需的专项
时，才额外补验。full 计划列出的每一项仍须在本轮执行，不能用开发阶段或以前轮次的等价
结果跳过。普通 UI、文案、单 package、测试文件、改动文件较多和准备提交都不是 full 的
触发条件。

实际执行会把 `plan.txt`、`summary.txt` 和每项编号日志写入脚本报告的结果目录；默认位置是
本机临时目录。控制台只显示状态、实际耗时和失败项的有限日志。前置静态检查失败时，依赖它
的重型检查不会启动；其他独立检查仍继续并汇总。非零退出、阻塞退出码 75、取消和超时都
不能算通过，也不能用以前轮次的结果替代本轮结果。检查执行中收到 INT 或 TERM 时，脚本只终止当前
检查的进程组，并保留取消结果。

普通本地 full 不默认扫描完整 Git 历史，但保留必要的 PR Gate 自检和 Codex 协议检查。
修改公开仓库安全门自身时，仍执行完整安全检查。`Public Repository Safety` 在 `main` push
和 `workflow_dispatch` 使用 full-history，在 Pull Request 使用增量检查。

日常 `build` / `run` 只通过 `bash ./scripts/ios-dev.sh` 执行，优先租用 available、paired、USB 连接的真机，再选择可达的本地网络真机。只有没有可达真机时才回退 `iPad Pro 13-inch (M5)` Simulator；检测到真机但全部忙时明确失败，不静默切换设备类型。`build-for-testing`、`test`、快照与 CI 精确固定这台 M5 iPad，忙或缺失时不切换 iPad mini。使用 `bash ./scripts/ios-dev.sh target` 查看目标和选择原因，使用 `bash ./scripts/ios-dev.sh leases` 查看跨 Worktree 租约和外部 `xcodebuild`；兼容性运行通过 `IOS_TARGET_MODE=simulator` 和 `IOS_SIMULATOR_NAME` 显式切换。

真机只在改动涉及相机、通知、Keychain、Tailscale/弱网、性能、发布前验收，或 Issue
明确要求时执行。Simulator 通过不代表这些专项完成；真机结果也不替代固定 M5 的回归。

需要单独排障时，仍可直接运行对应命令。例如 Go 全量回归：

```bash
go test ./... -count=1
go vet ./...
```

公开仓库安全相关改动可单独运行：

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
- README、CONTRIBUTING 与 `docs/**` 只执行轻量文档静态门禁，检查安装、App Store 和 Nightly/Release 说明；
- Go、Windows/Linux 打包或 Release 相关路径调用现有 Go CI；
- Mac App 源码与 Xcode 工程路径调用独立 Mac App CI，使用无签名 build 运行现有 Scheme 单测；
- iOS 源码、App Store/TestFlight 脚本或配置路径调用现有 iOS CI；
- Cargo 或 `bridges/claude` 路径调用现有 Rust bridge CI；
- `.github/workflows`、`.github/actions` 或 Gate 分类脚本变化时执行全部语言检查。

本地统一入口会按变化范围选择上述门禁；不需要再手工重复一遍。要预览 PR 的语言
scope，可运行：

```bash
bash ./scripts/verify-change.sh --plan
bash ./scripts/ci-pr-scope.sh --base origin/main --head HEAD
```

Release/打包改动仍可用下面的专项检查定位问题：

```bash
bash ./scripts/check-packaging.sh
```

`PR Gate` 红灯时先打开失败的子 job；最终聚合 job 只负责判断必需检查是否成功，
真正的错误日志保留在 `Go and release`、`iOS`、`Rust bridge`、`Mac App`、
`Docs and static policy`、`Codex protocol` 或 `Repository safety` 中。`Detect change scope` 失败时，先用下面的命令确认
base/head 可读取且路径分类符合预期：

```bash
bash ./scripts/ci-pr-scope.sh --base origin/main --head HEAD
```

收尾时必须确认最新受检提交的必需检查实际成功。现有 CI 会运行 Go 全仓 `test` 与 `vet`、
三个 Rust crate、iOS 核心回归、Codex 协议和公开仓库安全检查；按路径不适用的 job 应为
`skipped`。使用测试版 Xcode 的本地结果与使用稳定版 Xcode 的 CI 结果分别记录，不能互相替代。

等待本地命令或 CI 时，使用宿主已有的阻塞或挂起能力。没有状态变化时，不反复运行
`tail`、`ps`，也不安排另一个 Agent 监视。设备排队沿用现有租约等待预算；超时是阻塞，
不能豁免检查或换设备。环境故障必须由日志和运行环境证据支持；`main` 有相同失败或重跑
变绿都不能单独证明改动无关。

如果宿主没有完成事件可继续唤醒当前任务，把 Issue 保持在 `Verify`，并按下面的内容交接。
负责人在 CI 成功或失败后回到原任务继续处理；开发结束本身不满足 `Done`。

```text
Commit / PR：<提交、PR 与 CI 链接>
本轮验证：<脚本输出的计划、结果汇总和分项日志；含实际耗时>
未验证范围：<延后到 CI、真机或发布阶段的项目>
恢复入口：<原 Codex 任务或 Issue，以及下一项动作>
```

`main` 分支保护必须把名称精确为 `PR Gate` 的 check 设为 required，并让未完成或
失败状态阻止常规合并。紧急 bypass 只允许用于回滚已经确认影响生产可用性的提交；
不得用于功能交付、测试不稳定或赶发布时间。使用 bypass 时必须在回滚 PR 或关联
Issue 中记录原因、被绕过的失败 check、操作者、时间、回滚 commit，以及后续补验
负责人和结果；补验完成前不得关闭关联 Issue。不要通过临时删除 required check、
关闭 `enforce admins` 或修改 workflow 让 Gate 变绿。
