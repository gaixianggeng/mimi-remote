# 关键用户链路分层回归

## 目标

这份映射把 Mimi Remote 的真实用户风险绑定到稳定、可重复、可诊断的测试层，避免
“iOS 和 `agentd` 各有单测”被误认为已经形成跨边界闭环。PR Gate 只运行能够阻止
数据丢失、状态串线、重复副作用或安全越界的高价值回归；大范围组合、全量视觉和
真机专项仍保留在完整本地回归及后续 Nightly/Release 任务中。

关键链路统一通过：

```bash
bash ./scripts/test-conversation-regressions.sh
```

静态检查不启动 Simulator，可单独运行：

```bash
bash ./scripts/check-critical-regressions.sh
```

## 方案

测试按四层组织：

1. **单元层**：状态机、解析/适配、错误分类和安全降级。
2. **契约层**：共享版本 fixture、iOS 请求序列化、Go 路由解析和 app-server
   JSON-RPC 投影必须成对存在。
3. **集成层**：Go 使用 `httptest`、临时 Git 仓库和 fake WebSocket；iOS 使用
   注入式 client/socket/transport，验证恢复代次、Host 隔离和 exactly-once。
4. **端到端 smoke**：只使用进程内 fake/fixture，走完 thread → turn → stream →
   approval/interrupt；不读取真实凭据，不访问外部网络，不用固定 `sleep` 驱动
   runner。

iOS 的关键测试仍由同一次 `xcodebuild` 执行并复用同一台 Simulator。
`ConversationDataFlowTests` 是跨多个 Swift 文件扩展的大集合，因此 PR Gate 使用
精确 method selector，不再无条件运行整个集合。

## 实现

### 风险映射

| ID | 用户风险与触发路径 | 测试层 / 模块 | PR Gate 证据 | 用户影响 |
| --- | --- | --- | --- | --- |
| R1 | 首次安装、配对票据重复兑换/过期边界、安装身份损坏或换 Mac 后仍沿用旧身份 | 单元 + 契约；`internal/auth`、`internal/config`、`PairingLinkTests`、`ProtocolContractTests` | `TestPairingTicketRejectsAtExactExpiryAfterRepeatedValidation`、`TestPairingClaimRejectsInvalidSignatureAndAllowsRepeatedValidClaims`、`TestPairingClaimRejectsExpiredTicketUnderConcurrentRetries`、`TestLoadOrCreateInstallationIDRejectsCorruptionWithoutReplacement`，以及完整 `PairingLinkTests` | 无法配对、连错主机或凭据边界失效 |
| R2 | iOS 请求与 `agentd` 路由、鉴权、版本 header 或 app-server JSON-RPC 字段漂移 | 契约 + 集成；`AgentAPIClientRequestTests`、`CodexAppServerProtocolTests`、`ProtocolContractTests`、`internal/httpapi` | `critical-journey.json` 同时驱动 Go 的 `TestCriticalJourneyFixtureMatchesAgentDGateway` 与 iOS 的 `testCriticalJourneyFixtureMatchesIOSRequestBuilders`；`testSessionStoreConsumesDirectAppServerEventsWithoutMobileProtocolConversion` 验证直连事件不经移动协议二次转换 | 列表、打开、发送或流式事件在升级后静默失效 |
| R3 | WebSocket 断线、前后台切换或网络恢复造成丢事件、重复重连或旧连接抢占 | 状态机 + 集成；iOS connection/runtime | `testWebSocketFailureAutoReconnectsWithLatestReplayWatermark`、`testStaleWebSocketStatusDoesNotRetireCurrentReconnect`、`testOfflineSuspendsReconnectAndPreservesSessionQueueAndMessages`、`testNetworkRecoveryReconnectsExactlyOnce`、`testCredentialTerminalStatusStopsReconnectAndPreservesLocalSessionState`、`testCodexAppServerSessionRuntimeReconnectsAfterTransportReceiveFailure` | 会话卡死、消息丢失或无限重试 |
| R4 | 恢复代次、Host 切换或迟到异步结果覆盖当前会话 | 状态机 + 集成；`SessionStore`、history recovery、Git status | `testTerminalStreamStoreSeparatesSameSessionAcrossHostScopes`、`testRecoveryGenerationFailureDoesNotReuseOlderFullSnapshot`、`testRecoveryForceLoadReplacesOlderReuseRecentRequest`、`testWorkbenchRestorationRouteRejectsSnapshotFromDifferentEndpoint`、`testColdStartResolvedCandidateCannotCommitAfterUserSelectsAnotherSession`、`testLateGitStatusFromPreviousHostCannotOverwriteCurrentHostState` | 看到另一台 Mac 的消息、历史或 Git 状态 |
| R5 | 活跃 turn 的 append/queue/retry 在重连或事件重放后重复发送 | 状态机 + 集成；turn queue、conversation store | `testRunningQueuedDeliverySendsOneMessageAfterEachCompletedTurn`、`testRunningQueueDoesNotDispatchMerelyBecauseWebSocketReconnected`、`testFailedRunningMessageRetryReusesClientMessageID`、`testRunningSendFailureNoRolloutFoundMarksLocalEchoFailedAndRetainsRetryPayload` | 同一提示执行两次，产生重复写入或命令 |
| R6 | 审批、补充输入或中断只完成单向发送，没有以服务端事件收敛；空闲线程中的陈旧或未知重放请求被自动拒绝 | 集成 + fake smoke；approval/user-input/interrupt | `testApprovalDecisionSendsThroughCurrentWebSocket` 同时断言失败保留与 `approvalResolved` 收敛；`testDirectRuntimeKeepsStaleReplayedServerRequestSilentOnIdleThread` 验证空闲线程中的陈旧或未知重放请求保持沉默、不自动拒绝；`testTurnInterruptAcknowledgementPollsUntilAuthoritativeTerminalTurn`、`testTargetedInterruptRecoveryWorksWithoutCachedActiveTurnAndProtectsNewerTurn`、`testSessionStoreSendsUserInputAnswersThroughExistingSocket` | UI 误报已批准/已中断，恢复后丢失待办，或错误拒绝其他入口产生的请求 |
| R7 | 会话列表、打开、turn start/stream/completion 的 happy path 在适配层断裂，或滚动中完成导致 row 跳位和重复反馈 | 契约 + 端到端 fake + UI 状态机；direct app-server runtime、`SessionListLifecycleCoordinatorTests` | `testCodexAppServerFakeSmokeCoversThreadTurnAndApproval`、`testSessionStoreReplaysDirectAppServerEventStreamFixture`、`testRunningTurnLifecycleKeepsEchoAndFinalAssistantStable`，以及完整 `SessionListLifecycleCoordinatorTests` | 用户无法进入会话、发消息、看到最终回答，或列表浏览被实时状态更新打断 |
| R8 | Git/Worktree 接受越界路径、错误清理目标或旧 Host 的迟到结果 | Go 集成 + iOS Host 隔离；`internal/httpapi`、`SessionStore` | `TestGitActionRejectsUnsafeFilePath`、`TestWorktreeDeleteRejectsUnmanagedPath`、`TestWorktreeCleanupRejectsAllBeforeDeletionWhenSelectedStateChanges`、`testLateGitStatusFromPreviousHostCannotOverwriteCurrentHostState` | 修改错误仓库、误删工作区或显示错误发布状态 |
| R9 | 可选能力在依赖失败、本地禁用、旧服务端、未知状态或切换 Host 后仍误走新路径 | 单元 + 契约 + 集成；`internal/config`、`internal/httpapi`、`FileAttachmentModelsTests`、`PairingLinkTests`、`ProtocolContractTests` | `TestFileUploadCapabilityRolloutMatrix`、`testFileUploadCapabilityDecisionMatrixFailsClosed`、`testCapabilityNegotiationIsIsolatedPerHostAndRejectsStaleLease`，以及 `version-unknown-capability.json` 两端兼容验证 | 文件请求错误发往另一台 Mac、禁用失效或依赖异常时继续暴露高风险入口 |

### 分层执行

Go 快速层固定禁用缓存：

```bash
go test \
  ./internal/auth \
  ./internal/config \
  ./internal/appserver \
  ./internal/httpapi \
  -count=1
```

- `internal/auth` / `internal/config`：票据、安装身份、损坏、权限和并发首次启动。
- `internal/appserver`：JSON-RPC 解析、server request、错误和 fail-closed 适配。
- `internal/httpapi`：真实 handler、fake upstream、会话授权与恢复、Git/Worktree 临时仓库。

iOS Gate 保留请求/协议/配对整组测试；庞大的 `ConversationDataFlowTests` 只选择映射表
中的关键方法。测试失败会直接显示 XCTest class/method；Go 失败会显示 package/test，
静态检查则报告缺失的风险 ID、源码方法、runner selector 或 CI scope。

Rust bridge 只在 Cargo/bridge 路径变化时运行现有完整 suite，其中：

- `session_resilience.rs` 覆盖 replay、审批恢复和旧 generation；
- `socket_attach.rs` 覆盖断线附着与 session ring 隔离；
- `smoke_in_process.rs` 使用 fake Claude 完成 initialize → thread/start → turn/start。

本次不把 Rust suite 无条件塞入 iOS/Go 路径的 PR Gate。

## 风险与优化

- 当前跨进程契约采用“共享 `critical-journey.json` + 两侧序列化/handler +
  fake transport”闭环，
  不会启动真实 Codex/Claude，也不依赖外网。它能发现字段和状态语义漂移，但不能替代
  已安装二进制、签名、Keychain、Tailscale/弱网和真机专项验收。
- 相机、全量附件组合、全量 `ConversationDataFlowTests`、更多视觉快照及长时恢复组合
  不属于 MIM-29 的关键 PR 集合；后续 Nightly/Release 是否托管执行由 MIM-31 决定，
  本次不创建对应 workflow。
- `scripts/check-critical-regressions.sh` 故意校验完整测试名。测试重命名或移动会让
  Gate 失败，要求同时更新 runner 和本映射，避免覆盖关系静默漂移。
- PR 继续以 MIM-27 的约 10–12 分钟为预算。MIM-29 将大集合改为精确方法并把 Go
  小包测试放在 Simulator 准备前执行；若托管耗时超预算，优先依据 job step 时间删除
  重复选择，不降低 R1–R8 的风险覆盖。
