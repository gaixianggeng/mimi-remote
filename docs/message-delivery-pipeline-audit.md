# 消息投递链路审计：完成提示出现但正文缺失

## 目标

处理 Codex 会话收到完成提示、短回复仍需手动刷新才能出现的问题。关联 GitHub #388、PR #420。
本文区分已复现的代码缺陷与现场现象；真机端到端验收仍需单独确认。

## 现状与证据边界

2026-09-10 的现场记录显示：用户发送短消息后收到完成震动，手动刷新后才出现回复。
同一时间段的 agentd 日志包含客户端断开、重新读取配置和 broker 重连；Codex rollout 记录了回复完成。

这些记录能确认重连与正文缺失同时发生，但不能单独证明唯一根因。长回复正常、短回复缺失，
与事件序号重置的缺陷相容；仍需客户端事件序号和正文接收水位的现场记录才能完成因果对应。
`broker_sink_replaced` 只证明同名连接发生接管，不能把所有接管都归因于探针。

## 方案与实现

### 事件序号在 runtime 重建后继续递增

事件先经 `CodexAppServerEventProjector` 转成 `AgentEvent`，再进入 `SessionStore`。
正文更新受 `ConversationStore` 的事件序号水位限制，turn 状态更新走另一条路径。
原先投影器实例的计数从头开始，新 runtime 可能产生低于旧水位的事件，导致正文被判为过期，
而完成状态仍被接受。测试已复现这个机制。

投影器现在共用进程内、按线程递增的 `CodexAppServerEventSequenceClock`。
它使用锁保护计数，并放在独立文件中以满足源码行数门禁。
序号只用于本进程内排序，不是服务端回放游标。

重连时的 `stateOnly` 策略仍保留 `messageCompleted`。它会过滤增量事件，不能据此推断
完整正文事件也必然被过滤；最终正文仍需通过上述水位和 revision 检查。

### 探针不占用 Codex 常驻 broker

broker 是网关中保留上游连接和待审批请求的会话对象。同名连接会接管旧连接。
原先探针复用正式会话名，确实存在顶掉正式连接的代码路径。

仅给 Codex 探针加 `-probe` 后缀仍有缺陷：常驻池上限为 4，池满时注册新名字可能淘汰
离线但仍在运行或等待审批的正式 broker。

本次改为 Codex 探针不发送 `session` 参数，沿用网关现有的一对一临时连接路径。
正式 Codex 连接继续发送稳定会话名。Claude 保持已有的独立探针名和回放游标行为。
服务端生产代码不变，不需要为这次修正升级 agentd。

### 按 turn 保留缺失正文并补读新历史

当前可见、可写且不是本地草稿的会话收到 completed 事件后，如果对应 turn 没有 assistant
正文，就记录这个缺口。等待 400ms 合并窗口后，通过 `.missingAssistantReply` 发起强制历史读取。
正文已存在时不增加请求。

这次读取会替换更早的历史任务，即使旧任务已经使用 bypass，也不能复用完成事件之前的快照。
旧响应继续受原有请求 token 和主机范围检查约束。

同一会话保存待补齐的 turn 集合。后一轮已收到正文不会取消前一轮的缺口；读取期间完成的新 turn
会留到下一批。只有正文实际合并后才清除缺口。同一 turn 在一次前台或选择周期内最多触发一次补读，
重复完成事件不会形成无限重试。空结果或读取失败保留缺口，回前台或重新进入会话时可再尝试。
切换主机、清理连接或删除会话时会清理对应任务，避免旧数据进入新的连接范围。

## 验证

本轮在固定 M5 Simulator 上运行了 13 个定向 XCTest，均通过。它们覆盖序号跨 runtime 重建、
探针 URL、正文实际补齐、旧 bypass 请求、连续 turn、重复完成事件、空结果、失败后重新进入、
后台恢复和清理连接后的迟到响应。

Go 定向测试 `TestAnonymousCodexProbesPreserveFullResidentBrokerPool` 已通过：常驻池满时，
两条同时存在的无名探针不替换正式 broker；在线会话继续收事件，离线会话重连后仍能收到审批；
探针断开后释放各自临时上游。

可执行的定向复查命令：

```bash
go test ./internal/httpapi -run TestAnonymousCodexProbesPreserveFullResidentBrokerPool -count=1
bash ./scripts/ios-dev.sh test -quiet -collect-test-diagnostics never \
  -only-testing:MimiRemoteTests/CodexAppServerProtocolTests/testCodexProbeGatewayURLDoesNotUseResidentBrokerSession \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testMissingAssistantReplyAppearsAfterFreshRead \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testMissingAssistantReplyReplacesOlderBypassHistoryRequest \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testMissingAssistantReplySurvivesNextTurnWithReply
```

收尾检查及真机安装结果记录在 PR 与 Issue 中。真机验收重点是「短消息完成后正文自动出现」和
「发送后切到后台，再回到会话」。安装启动成功不等于这两项已验收。

## 风险与后续边界

- Codex broker 离线期间不会回放所有通知，客户端仍依赖权威历史恢复。进程内序号不能补回未收到的帧。
- 自动补读受历史分页范围约束；空页或暂时失败不会立即无限重试。
- 后台宽限、Codex 通知回放、Tailcat 重启策略和连接轮询属于其他工作，本 PR 没有实现，也不把它们列为本次验收的前提。
