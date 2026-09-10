# 消息投递链路审计：为什么「震动响了、回复没出现」

2026-09-10 针对 iPhone 上 Codex 会话「发送短消息后收到完成震动、正文却要手动刷新才出现」的排查结论，
以及整条消息处理链路的不合理点清单。三处已在本分支修复，其余给出方案与优先级。

## 1. 现象与实证

用户 11:32 在会话 `01a0895f…131d` 发送「测试」，App 收到完成震动，时间线里没有回复；点顶部刷新后才出现
「收到，消息正常。」。agentd 日志（`~/Library/Logs/mimi-remote/agentd.log`）与 Codex rollout 对照：

| 时刻 | 事件 | 来源 |
| --- | --- | --- |
| 11:32:29 | 网关转发 `turn/start` | agentd |
| 11:32:30 | 客户端主动关闭 WebSocket（1001 going away，尚有请求在途） | agentd `broker detached` / 诊断面 `outstanding_requests` |
| 11:32:32 | 客户端重新拉 `/api/app-server/config`，新 WebSocket 接管 broker | agentd `reattached` |
| 11:32:35 | Codex 生成回复并 `task_complete` | rollout jsonl |
| 11:32 | App 震动，无正文 | 用户截图 |

同一线程 11:32:04 的第一轮（回复较长）经历了同样的两次断线重连却正常显示。差异只在回复长短。

## 2. 链路全景

```
Composer ──turn/start──▶ CodexAppServerSessionRuntime(actor, 每个 runtime bundle 一份)
                              │ 单条共享 WebSocket ──▶ agentd gateway broker(按 session 名复用) ──▶ codex app-server
                              │ 通知: turn/started, item/*, item/agentMessage/delta, turn/completed, thread/status
                              ▼
                     CodexAppServerEventProjector.project → AgentEvent(+metadata.seq 由投影器计数)
                              │ emit → 每个订阅者一个合并邮箱；无人订阅时进 bufferedEvents
                              ▼
        SessionWebSocketClient.attachEvents(replayPolicy: all | stateOnly) → onEvent
                              │ 前台 socket 走 TerminalStreamStore 80ms 合并批；队列/子代理 socket 直投
                              ▼
        SessionStore.applyRuntimeEvent → EventReducer → applyEventReducerOutput
              ├─ 状态: session.status / activeTurnID / foregroundActivity（不经任何水位线）→ 列表相变 → 震动
              └─ 正文: ConversationStore.completeMessage / applyAssistantDelta（经 seq 水位线 + revision 门）
                              ▼
        ConversationTimelineItemBuilder → 时间线
```

断线/后台路径：`scenePhase == .background` → `SessionStore.suspendForBackground()` 关 socket、
`AppStore.suspendCredentialsForBackground()` 清 token 并把 runtime bundle 置空。回前台：Tailcat 代理强制重启
（本地端口变化）→ 新 endpoint → **新建 runtime bundle 与投影器** → 拉 config → 新 WebSocket →
`reconcileHistoryForRecovery`（thread/read）→ 以 `stateOnly` 策略挂事件流。

## 3. 不合理点（按严重度）

### 3.1 【根因，已修】事件序号随 runtime 重建从 1 重来，正文水位线不重置

- `CodexAppServerEventProjector.nextSeq` 是投影器实例内的计数器；投影器随 runtime 重建。
- `ConversationStore.shouldAccept` 用 `lastSeenSeqBySessionID` 做单调水位线，只在会话被清理时重置。
- 重建后同一线程的前 N 条事件序号全部低于旧水位，`completeMessage` / `applyAssistantDelta` 静默丢弃；
  `turn/completed` 走状态路径不受影响 → 列表状态翻成完成 → 震动。
- 长回复为何「正常」：delta 数量多，序号越过水位后剩余 delta 和最终 `item/completed` 被接受。
- 修法：序号源改为进程内按线程单调递增的 `CodexAppServerEventSequenceClock`，投影器实例共用。
  回归测试 `testProjectorSequenceSurvivesRuntimeRebuildSoShortReplyIsNotDroppedAsStale`。

### 3.2 【已修】探针连接与正式连接同名，把正式连接从网关踢下线

- `validateDirectGateway()`（路由选路 `defaultConnectionRouteProbe`、连接诊断）开一条连上即断的探针，
  URL 里的 `session=` 与常驻连接相同。
- 网关 `codexGatewayBroker.attach` 规则是「同名会话只留一条」，旧 sink 以 `broker_sink_replaced` 结束。
- 今天日志里 35 次 reattach 只有 3 次是客户端先断，其余 32 次都是被顶掉。
- 修法：`GatewayConnectionPurpose.probe` 给探针加 `-probe` 后缀会话名；探针 broker 无 turn，detach 即回收。

### 3.3 【已修】turn 完成而正文缺失时没有任何兜底

- 现有 `TurnCompletionReconciliation` 只处理反方向（正文到了、`turn/completed` 缺失）；
  `resumeTurnCompletionReconciliationIfNeeded` 还要求本地已有该 turn 的 assistant 消息，短回复丢失时恰好不满足。
- `isNoOpHistorySelection` / `HistoryLoadSignature` 让离开再进入也不会重拉。
- 修法：`scheduleMissingAssistantReplyBackfillIfNeeded`——当前可见会话的 turn 以 completed 收尾、
  本地没有该 turn 的 assistant 正文时，等 400ms 合并窗口后安静地强制权威读取一次（等价于手动刷新）。
  正文在时零额外请求。

### 3.4 【方案】进后台立刻拆链路，且不申请后台执行时间

- `RootView.onChange(scenePhase)` 一进 background 就关 socket、清 token、shutdown runtime；全代码库没有
  `beginBackgroundTask` / `BGTaskScheduler`。发完消息立刻回主界面时，`turn/start` 的响应可能还没回来。
- 建议：进后台先 `UIApplication.shared.beginBackgroundTask`，给 10–15s 宽限：在途请求收完响应、
  收到 `turn/started` 后再拆；回前台若宽限未过则直接复用连接，不重建 runtime。
  凭据清内存可以立刻做，socket 与 runtime 的销毁延后。

### 3.5 【方案】网关在客户端离线窗口丢弃除审批外的所有帧

- `pumpUpstream`：`sink == nil` 时只保留待审批帧，RPC 响应与通知一律丢弃，注释假设「iOS 重连后走权威历史补齐」。
- Claude 通道已有 `last_seen` cursor + ReplayRing；Codex 通道没有。
- 建议：给 Codex broker 加同样的按序号回放环（至少覆盖 `turn/started`、`item/completed`、`turn/completed`
  和客户端请求的响应），客户端重连带 `last_seen`。这是让「发完就切走」也能实时补回的根治手段。

### 3.6 【方案】回前台必然冷重连

- `recoverRouteFromForeground` 对 Tailcat 用 `forceRestart: true`，本地端口每次都变；runtime bundle 按
  endpoint+token 做身份，端口一变就整体重建（config 拉取 + 新 WebSocket）。
- 另有隐患：REST 工厂用 `validatedEndpoint`、WebSocket 工厂用 `normalizedEndpoint`，endpoint 无显式端口时
  两者字符串不同，会来回换 bundle。
- 建议：Tailcat 代理在后台保活或复用端口；bundle 身份用规范化后的同一形式；
  runtime 重建时把投影器序号显式接续（3.1 已从源头解决）。

### 3.7 其他观察

- 重连退避每次成功连接后归零，连上即死的循环永远停在约 1 秒。
- 单个无法解码的入站帧会直接杀掉共享连接（`failProtocolConnection`）。
- `thread/list` 3.5 小时请求 201 次、响应 36MB（`/api/diagnostics/relay` 的 `methods` 统计），轮询偏重。
- 客户端不发 ping；WebSocket `timeoutInterval = 20` 对 `URLSessionWebSocketTask` 可能表现为空闲计时。
- `SessionListView` 的完成震动只看列表状态相变，与正文是否落地无关；这是「震动等于收到消息」错觉的来源。

## 4. 验证与排查工具

```bash
# 断线与重连时间线（客户端会话键前缀按需替换）
grep -E "broker (de|re)attached|GET /api/app-server/ws|GET /api/app-server/config|forwarded client turn" \
  ~/Library/Logs/mimi-remote/agentd.log | grep "2026/09/10 11:3"

# 网关关闭原因（agentd 重启后清零）
TOKEN=$(python3 -c "import json;print(json.load(open('$HOME/Library/Application Support/codex-ipad-agent/config.json'))['auth']['token'])")
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8787/api/diagnostics/relay | python3 -m json.tool | grep -A6 recent_terminations

# Codex 侧真实事件序列
python3 - ~/.codex/sessions/2026/09/10/rollout-*-<threadId>.jsonl
```

`close_reason == broker_sink_replaced` 对应 3.2/3.6；`client_read:normal_close:1001` 对应 3.4；
`client_read:timeout`（150s）是 App 被系统挂起后的服务端读超时。

## 5. 建议顺序

1. 本分支：3.1 + 3.2 + 3.3（已完成，真机验收「发短消息 → 立刻回主界面 → 2 秒后回来」）。
2. 3.4 后台宽限（客户端，改动集中在 RootView/SessionStore/AppStore 的挂起路径）。
3. 3.5 Codex broker 回放环（服务端 + 客户端握手），彻底消除离线窗口丢帧。
4. 3.6/3.7 连接稳定性清理。
