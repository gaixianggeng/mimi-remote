# 会话状态模型

关联 #683（电脑端会话实时状态）、#546（三表面词汇统一）、#365 / #366（Codex Desktop 本地会话）。

## 目标

iPhone / iPad 上的会话列表、侧栏和工作区页对同一个会话回答同样三个问题，并且答案实时：

1. **在跑吗、谁在跑** —— 本 App 的运行时、电脑上的 Claude Code / Claude 桌面端，还是没在跑。
2. **要不要我回来** —— 等待审批、等待补充输入、失败。
3. **结果我看过了没** —— 空闲会话上的未读点与「刚完成」。

## 分类：`SessionActivityState`

`AgentSession.activityState`（`ios/MimiRemote/Sources/Core/Models/SessionActivityState.swift`）是唯一的活动分类，
顺序即优先级：

| 状态 | 判定 | 列表字形 | 侧栏分区 | 工作区分组 | 状态文字 |
| --- | --- | --- | --- | --- | --- |
| `draft` | 本地草稿，未发首条消息 | — | 进行中 | 进行中 | 新会话 |
| `needsYou(approval / userInput)` | 状态为等待审批 / 输入，或带有待处理请求 | 等待（警示三角） | 待你处理 | 待你处理 | 待审批 / 待输入 |
| `running(.computer(owner))` | 会话被电脑上其他 Claude 进程持有且持有方 `busy` / `shell` | 运行中（旋转环） | 进行中 | 进行中 | 电脑端运行中 |
| `running(.mimi(hasActiveTurn))` | 本端有进行中的 turn，或状态为 running | 运行中 | 进行中 | 进行中 | 处理中 / 运行中 |
| `failed` | 上一轮以失败结束 | 失败（红色感叹） | （按最近） | 待你处理 | 失败 |
| `idle` | 其余：历史、完成、已结束、空闲 | 未读点或无 | 刚完成 / 置顶 / 最近 | 最近 | 历史 / 完成 / 已结束 |

- `displayStatus(foregroundActivity:)`、`SessionRowState`、`WorkspaceSessionGroup.of`、`SessionListPresentation.sidebarSections`
  都从这个分类派生。前台刷新 / 等待回复 / 正在回复的提示（`SessionForegroundActivity`）仍压在"在跑"之上，
  只影响当前选中会话的文字。
- 「未读」「刚完成」「置顶」不是活动状态。它们由 `SessionStore` 的已读水位（`SessionHistoryReadState`）和本地
  观察时间维护，只在 `idle` 行上出现；进行中的会话永远不标未读。
- 工作区分组与侧栏分区的名字已统一为「待你处理 / 进行中 / 最近」（`ui.needs_you` / `ui.in_progress` / `ui.recently`）；
  会话 tab 另有日期桶，表达的是历史轴，不与状态分组合并。时间格式与行组件的统一仍归 #546。

## 数据来源

### Claude（SDK 适配器）

- 持有方来自 Claude Code 自己写的占用登记（`<配置目录>/sessions/<pid>.json`，含 `status`、`statusUpdatedAt`）。
- `thread/list`、`thread/read`、`thread/resume` 的 `status` 同源：本适配器有进行中的 turn 或持有方正在执行 → `active`；
  本适配器有常驻进程或持有方空闲 → `idle`；否则 `notLoaded`。`claudeOwner` 附 `statusUpdatedAt`。
- 历史里的最后一轮只在本适配器自己在跑时标为进行中。电脑端持有方执行时不合成进行中的 turn：客户端会把它当成
  自己的活跃 turn，一旦错过空闲推送（例如断线超过会话保留期）就会停在「处理中」。
- 占用登记监听覆盖登记里出现过的每个会话，不限已订阅的会话；变化时向全部已附着连接广播
  `thread/status/changed`，带 `status`、`canAcceptDirectInput`、`claudeOwner` 和会话最后活动时间 `updatedAt`。
  网关按连接已授权的 thread 过滤，客户端只收到自己列表里有的会话。

### iOS

- `thread/status/changed` 更新运行时缓存的会话快照（状态、持有方、`updatedAt` 只前移不倒退）；转为非运行状态时
  一并清掉缓存里的进行中 turn。
- 运行时只为被页面订阅的会话开邮箱；没有邮箱的会话此前只缓冲。现在 `.session` 快照同时交给
  `sessionIndexObserver`（`AppServerRuntimeBundle` → `AppStore` → `SessionStore.applyLiveSessionIndexUpdate`），
  只更新 Store 里已有的行的状态、持有方、活跃 turn 与时间，不插入新行、不改标题与摘要，然后重新归并已读水位。
  因此离开详情页后，本 App 发起的会话跑完同样会实时落成「刚完成 / 未读」。
- `thread/list` 刷新仍是权威来源；推送只是让刷新之间的状态不陈旧。

### Codex

- 共享 App Server（本机 control socket、Desktop SSH 模式）的会话在 `thread/list` 里已带 `active` / `idle`，
  列表刷新即正确；非订阅会话的实时通知受 Codex app-server 订阅模型限制，不在本模型里承诺。
- Codex Desktop "This Mac" 普通模式运行在另一个 App Server，公开协议读不到状态，仍显示为历史；见 #365 / #366。

## 验证

- 适配器：`bash ./scripts/check-claude-sdk-adapter.sh`（含持有方 busy / idle / 退出三态的列表与广播用例）。
- iOS：`SessionActivityStateTests`、`ClaudeTakeoverTests/testStatusPushForUnsubscribedSessionReachesTheIndexObserverWithRunState`、
  `SessionListPresentationTests/testSidebarSectionsUsePriorityOrderAndStableDeduplication`。
