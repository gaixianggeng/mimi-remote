# 工作区主机数据边界（#522 / R0、R1）

## 本次范围

在原 Git 状态抽取基础上，合入包含 #521 和 DeepSeek 原生接入 #499 的 main。主机目录、Worktree、文件预览及快捷动作也直接使用主机客户端；会话执行、历史、审批、队列仍使用各 Runtime 的原生路径。

生产调用链：

```text
现有页面 / 会话完成后的 Git 刷新触发
  → SessionStore 的选择解析与兼容转发
  → WorkspaceGitStore
  → WorkspaceGitAPIClient（AgentAPIClient）
  → agentd /api/git/*
```

`WorkspaceGitStore` 不依赖 `SessionStore`、当前选中会话或某个 Agent Runtime。它接收主机作用域读取闭包及窄客户端工厂。Git 状态、工作区轻量摘要、PR/TestFlight 状态、loading、错误和刷新任务只在该对象存储。

其余主机数据的生产调用链：

```text
工作区目录 / Worktree / 文件预览 / 快捷动作
  → SessionStore 的页面状态与操作协调
  → WorkspaceHostAPIClient（AgentAPIClient）
  → agentd 的主机 REST 入口
```

项目目录使用 `/api/projects`。路径校验、Worktree、目录浏览、文件和动作分别使用现有 `/api/workspaces/*`、`/api/worktrees/*`、`/api/directories/*`、`/api/files/*`、`/api/actions/*`。历史大媒体和输出仍从 agentd 的受鉴权缓存读取。权限及路径校验继续由 agentd 执行。

## Runtime 与主机传输的边界

| 能力 | 生产路径 | 状态所有者 |
| --- | --- | --- |
| Codex 会话 | iOS 原生 app-server 客户端 → agentd gateway → local / SSH / Windows managed WebSocket | Codex Runtime 与 SessionStore 的既有提交边界 |
| Claude 会话 | iOS app-server 客户端 → agentd Claude gateway → Claude bridge | Claude Runtime 与 SessionStore 的既有提交边界 |
| DeepSeek 会话 | iOS Harness 原生客户端 → `/api/harness/rpc`、`/api/harness/ws` → Harness | Harness journal、recovery、interaction 组件 |
| 主机工作区数据 | iOS AgentAPIClient → agentd REST | Git 子 Store；其余页面状态暂由 SessionStore 持有 |

DeepSeek 保留原生协议和事件序号，不进入 Codex 翻译路径。主机资源加载不通过某个 Runtime 的配置或连接；因此查看工作区和文件不需要先唤醒 Codex。会话列表、正文、审批与发送仍按已登记的 Runtime 路由。详细的原生恢复约束见 [Harness 原生客户端](harness-native-client.md)。

## 迁移期间的约束

- `SessionStoreGitState.swift` 是无存储的转发层。旧页面、主机切换清理及既有测试仍可使用原属性名；不能在这里新建第二份字典或业务状态。
- `SessionStore` 转发子 Store 的 `objectWillChange`，保留现有页面的刷新行为。本次不宣称减少整棵工作台的重绘，页面改为直接观察 Git Store 属于下一步。
- 生产默认通过 `AppStore.client()` 构造主机 REST 客户端，保留凭据挂起检查、选路和地址校验。不创建/唤醒 Codex 或 Harness runtime。
- 显式提供 `workspaceGitClientFactory` 时优先使用它。只有明确注入旧 `clientFactory`、且未注入新工厂的测试或嵌入式调用，才使用 `SessionClientWorkspaceGitAdapter`。它不是失败回退路径。
- `workspaceHostClientFactory` 使用同样的注入规则；生产通过 `AppStore.client()` 保留凭据挂起、选路及地址校验。显式旧测试注入由 `SessionClientWorkspaceHostAdapter` 兼容。
- `SessionStoreAPIClient` 中旧 Git 声明及 runtime 的旧转发方法暂留兼容；生产 Git 入口已不走它们。删除它们需要同时迁移剩余 fake 和直接消费者，不能把本次表述为所有旧接口已经清零。
- 文件与动作使用 `WorkspaceHostLease`，Git 使用 `WorkspaceGitHostLease`。旧 `ProjectsGitHostLease` 仅供尚未迁移的会话管理/分页使用。

## 保持不变的行为

每个操作冻结主机作用域和客户端；成功、失败和 defer 都检查原主机仍有效。Quick Publish 失败后的状态读取及成功后的 TestFlight 查询复用同一个客户端，不从全局工厂重新取目标。轻量摘要保留 60 秒 TTL、最多 3 个并发请求；轮次完成触发的 Git 刷新仍按工作区路径去抖。切换主机时原清理入口经计算属性直接清理同一份子 Store 状态。

本次不改变原有同主机 loading 粒度、Git 组合操作的失败展示策略或取消语义，不把结构抽取包装成这些问题的修复。

Worktree 的创建、列表、分支、清理和删除在 await 后复核请求所属的 HostScope。旧主机成功、失败和 defer 都不能写入新主机。创建和 handoff 还复核导航意图；过期结果不能先写入工作区缓存，handoff 在切主机后不能向新主机继续 fork。handoff 等待历史后再次检查主机和任务取消状态，再写入完成提示；同主机切页仍将提示保留在原分叉会话。

## 原生桥接与页面观察

agentd 的 `harnessNativeResources` 单独拥有原生 WebSocket 连接、会话订阅名额和关闭门。Router 关闭时先阻止新连接与订阅，再取消已有连接的请求上下文、关闭 socket，并等待 handler 释放上游订阅。它不拥有 Harness 进程或 Agent 任务。连接持续读取客户端帧，由单个协程按接收顺序处理，客户端断开可以取消正在等待的授权或应答 RPC 并归还订阅名额。待处理帧超过 32 条时关闭连接，避免队列阻塞断线检测或无限增长。

页面观察与已提交命令分开管理。`MultiRuntimeSessionWebSocketClient` 用观察代次拒绝旧客户端的事件、状态和路由写入；发送结果仍交回原有对账路径。Harness follow 任务在 actor 读取后复核会话和观察代次，所有退出路径只取消该任务自己打开的 follow ID。切页不会关闭宿主共享连接或 `$events`，也不会改变原生 seq、cursor、revision。

## 验证及工程生成

`WorkspaceGitStoreTests` 覆盖独立工厂、单份状态与通知转发、旧主机成功/失败回调、复合操作客户端冻结、空路径和摘要 TTL。`WorkspaceHostBoundaryTests` 覆盖无 Runtime 的目录/启动加载、旧主机 Worktree 结果隔离，以及 handoff 历史等待后的主机切换、任务取消和同主机导航。两类测试及 `WorkspaceGitSummaryTests` 接入既有 PR Gate selector。

`SessionObservationLeaseTests` 覆盖失效客户端回调、路由保护、snapshot/live 切页及旧订阅释放，同样加入 PR Gate。Go 的 `TestHarnessNative*` 回归覆盖 Router 关闭、关闭后的连接拒绝、客户端断开和订阅打开中的授权取消，并运行 race 检查。

新增源文件与测试由 `ios/MimiRemote/project.yml` 中递归的 `Sources` / `Tests` 路径纳入。工程使用 XcodeGen 生成并同步提交，再使用仓库统一验证入口。

```bash
xcodegen generate --spec ios/MimiRemote/project.yml --project ios/MimiRemote
bash ./scripts/verify-change.sh --full --plan
bash ./scripts/verify-change.sh --full
```

定向验证可通过 `bash ./scripts/ios-dev.sh test -only-testing:MimiRemoteTests/WorkspaceHostBoundaryTests -only-testing:MimiRemoteTests/WorkspaceGitStoreTests -only-testing:MimiRemoteTests/WorkspaceGitSummaryTests` 执行。固定 M5 设备缺失/忙时按原规则处理。每轮受检提交的实际结果写入 #522 / PR #523；Simulator 结果不代表真机弱网或发布专项完成。

## 后续退出条件

先完成上述验证，再迁移 Git 页面直接观察子 Store、删除不再需要的兼容接口。Worktree/File 的客户端边界已抽取，业务状态仍待按真实修改热点迁移。R2/R3 完整状态提交与历史对账、Router 其余资源归拢按独立结果推进；本阶段验收不代表 R0–R5 全部完成。
