# 工作区 Git 边界（#522 / R1）

## 本次范围

从 `main@578ae40eb6ae9bda221ed0c5c193a6e5b08a656a` 抽取 Git 状态和操作。不修改会话执行、历史、审批、队列、网关协议或服务端安全策略；不吸收 #521，也不合并 #499。

生产调用链：

```text
现有页面 / 会话完成后的 Git 刷新触发
  → SessionStore 的选择解析与兼容转发
  → WorkspaceGitStore
  → WorkspaceGitAPIClient（AgentAPIClient）
  → agentd /api/git/*
```

`WorkspaceGitStore` 不依赖 `SessionStore`、当前选中会话或某个 Agent Runtime。它接收主机作用域读取闭包及窄客户端工厂。Git 状态、工作区轻量摘要、PR/TestFlight 状态、loading、错误和刷新任务只在该对象存储。

## 迁移期间的约束

- `SessionStoreGitState.swift` 是无存储的转发层。旧页面、主机切换清理及既有测试仍可使用原属性名；不能在这里新建第二份字典或业务状态。
- `SessionStore` 转发子 Store 的 `objectWillChange`，保留现有页面的刷新行为。本次不宣称减少整棵工作台的重绘，页面改为直接观察 Git Store 属于下一步。
- 生产默认通过 `AppStore.client()` 构造主机 REST 客户端，保留凭据挂起检查、选路和地址校验。不创建/唤醒 Codex 或 Harness runtime。
- 显式提供 `workspaceGitClientFactory` 时优先使用它。只有明确注入旧 `clientFactory`、且未注入新工厂的测试或嵌入式调用，才使用 `SessionClientWorkspaceGitAdapter`。它不是失败回退路径。
- `SessionStoreAPIClient` 中旧 Git 声明及 runtime 的旧转发方法暂留兼容；生产 Git 入口已不走它们。删除它们需要同时迁移剩余 fake 和直接消费者，不能把本次表述为所有旧接口已经清零。
- `ProjectsGitHostLease` 仍由文件、会话接管、分页等调用使用，不改变它的类型。Git 使用独立 `WorkspaceGitHostLease`。

## 保持不变的行为

每个操作冻结主机作用域和客户端；成功、失败和 defer 都检查原主机仍有效。Quick Publish 失败后的状态读取及成功后的 TestFlight 查询复用同一个客户端，不从全局工厂重新取目标。轻量摘要保留 60 秒 TTL、最多 3 个并发请求；轮次完成触发的 Git 刷新仍按工作区路径去抖。切换主机时原清理入口经计算属性直接清理同一份子 Store 状态。

本次不改变原有同主机 loading 粒度、Git 组合操作的失败展示策略或取消语义，不把结构抽取包装成这些问题的修复。

## 验证及工程生成

新增 `WorkspaceGitStoreTests` 覆盖独立工厂、单份状态与通知转发、旧主机成功/失败回调、复合操作客户端冻结、空路径和摘要 TTL。

新增源文件与测试由 `ios/MimiRemote/project.yml` 中递归的 `Sources` / `Tests` 路径纳入。提交环境没有 Xcode/XcodeGen；在 Mac 上需要先生成工程，再使用仓库统一验证入口。不要直接用未更新的已检入工程编译新文件。

```bash
xcodegen generate --spec ios/MimiRemote/project.yml --project ios/MimiRemote
bash ./scripts/verify-change.sh --full --plan
bash ./scripts/verify-change.sh --full
```

仍需核对 `WorkspaceGitStoreTests`、`WorkspaceGitSummaryTests` 和既有 `ConversationSessionStoreTests` 的 Git/主机租约用例实际执行，不能把仅编译或部分 selector 通过当作这些测试通过。必要时通过 `scripts/ios-dev.sh test` 执行完整目标；固定 M5 设备缺失/忙时按原规则处理。

本次环境只完成了六个改动 Swift 文件的语法解析，以及新 Git Store 的隔离类型检查（模型与 Combine 为检查用占位；不等于 App 类型检查）。Xcode 构建、XCTest、真机 UI、弱网和完整分层验证均未执行。工程生成结果需在 Mac 验证后同步提交；PR 在此之前保持草稿。

## 后续退出条件

先完成上述验证，再迁移 Git 页面直接观察子 Store、删除不再需要的兼容接口。Worktree/File 客户端拆分、R0 事件串行化、R2/R3 状态提交与历史对账、agentd Router 资源拆分分别推进；不要与本次 Git 抽取混为一个已完成阶段。
