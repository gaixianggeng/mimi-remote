#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "==> Go unit and gateway integration regressions"
if command -v go >/dev/null 2>&1; then
  go_bin="$(command -v go)"
elif [[ -x /usr/local/go/bin/go ]]; then
  # 从 Xcode/Codex 启动的非交互 shell 可能没有加载 /usr/local/go/bin。
  go_bin="/usr/local/go/bin/go"
else
  echo "未找到 Go，请安装 Go 或将 go 加入 PATH" >&2
  exit 1
fi
"$go_bin" test \
  ./internal/auth \
  ./internal/config \
  ./internal/appserver \
  ./internal/httpapi \
  -count=1

echo "==> iOS conversation regressions"
# 这些测试组覆盖 Mimi Remote 对话请求链路和发布安全边界：
# - AgentAPIClientRequestTests：全部 REST 调用的路径、方法、鉴权、JSON 字段和超时契约。
# - CameraAttachmentTests：相机可用性、权限恢复和现有图片压缩上限。
# - CodexAppServerProtocolTests：JSON-RPC payload、collaborationMode、目标/steer 协议。
# - ConversationDataFlowTests 的精确方法：只保留配对后的会话、流式事件、恢复、
#   exactly-once、审批/中断、Host 隔离和 fake smoke；其余大集合不无条件进入 PR Gate。
# - FileAttachmentModelsTests：文件上传、capability 状态矩阵、内部上下文编解码和旧服务端兼容。
# - ConversationProcessGrouperTests：过程组边界、commentary 前后保留和 source order。
# - SessionListLifecycleCoordinatorTests：滚动冻结、idle 重排和完成/失败 Haptic exactly-once。
# - ConversationSnapshotTests：用户气泡/助手文档流、复杂 Markdown、图片和过程组的关键视觉回归。
# - MarkdownRenderingTests：proposed_plan 流式和完整渲染。
# - PairingLinkTests：Endpoint allowlist、ATS 传输策略、Host capability 隔离和 stale lease。
# - DoctorDiagnosticsTests：结构化 Doctor 响应、HTTP 错误和向后兼容。
# - ProtocolContractTests：iOS/agentd 当前、上一版和明确不兼容的版本窗口。
ios_test_action="${IOS_TEST_ACTION:-test}"
case "$ios_test_action" in
  test|test-without-building) ;;
  *)
    echo "IOS_TEST_ACTION 只支持 test 或 test-without-building：$ios_test_action" >&2
    exit 2
    ;;
esac
bash "$ROOT_DIR/scripts/ios-dev.sh" "$ios_test_action" \
  -quiet \
  -collect-test-diagnostics never \
  -testLanguage zh-Hans \
  -testRegion CN \
  -only-testing:MimiRemoteTests/AgentAPIClientRequestTests \
  -only-testing:MimiRemoteTests/CameraAttachmentTests \
  -only-testing:MimiRemoteTests/CodexAppServerProtocolTests \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testCodexAppServerFakeSmokeCoversThreadTurnAndApproval \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testSessionStoreConsumesDirectAppServerEventsWithoutMobileProtocolConversion \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testCodexAppServerSessionRuntimeReconnectsAfterTransportReceiveFailure \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testDirectRuntimeRestoresReplayedServerRequestOnIdleReportingThread \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testTurnInterruptAcknowledgementPollsUntilAuthoritativeTerminalTurn \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testTargetedInterruptRecoveryWorksWithoutCachedActiveTurnAndProtectsNewerTurn \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testTerminalStreamStoreSeparatesSameSessionAcrossHostScopes \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testConversationStoreScopesSameSessionAndDelayedDeltaByProfile \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testWebSocketFailureAutoReconnectsWithLatestReplayWatermark \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testStaleWebSocketStatusDoesNotRetireCurrentReconnect \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testOfflineSuspendsReconnectAndPreservesSessionQueueAndMessages \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testNetworkRecoveryReconnectsExactlyOnce \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testCredentialTerminalStatusStopsReconnectAndPreservesLocalSessionState \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testRecoveryGenerationFailureDoesNotReuseOlderFullSnapshot \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testRecoveryForceLoadReplacesOlderReuseRecentRequest \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testRunningQueuedDeliverySendsOneMessageAfterEachCompletedTurn \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testRunningQueueDoesNotDispatchMerelyBecauseWebSocketReconnected \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testFailedRunningMessageRetryReusesClientMessageID \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testRunningSendFailureNoRolloutFoundMarksLocalEchoFailedAndRetainsRetryPayload \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testApprovalDecisionSendsThroughCurrentWebSocket \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testSessionStoreReplaysDirectAppServerEventStreamFixture \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testSessionStoreSendsUserInputAnswersThroughExistingSocket \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testRunningTurnLifecycleKeepsEchoAndFinalAssistantStable \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testWorkbenchRestorationRouteRejectsSnapshotFromDifferentEndpoint \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testColdStartResolvedCandidateCannotCommitAfterUserSelectsAnotherSession \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testLateGitStatusFromPreviousHostCannotOverwriteCurrentHostState \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testArchiveFailureRollsBackPinnedStateOrderingAndPreservesProjections \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testUnarchiveFailureRollsBackToArchivedVisibility \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testArchivePendingSuppressesDuplicateButAllowsDifferentSessionsConcurrently \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testArchivePendingPreferenceSaveAndRestartKeepCommittedStateUntilSuccess \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testConnectionClearKeepsArchivePendingAndStaleHostFailureRollsBackPersistedProfile \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testStaleHostArchiveSuccessKeepsOldProfileCommitAndDoesNotPolluteCurrentProfile \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testArchiveLateSuccessAfterSwitchingBackRestoresMemoryAndDurableState \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testDeletedProfileIgnoresLateArchiveSuccessWithoutResurrectingPreferences \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testArchiveOldTokenCannotClearNewPendingAndPendingArchiveBlocksPin \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testArchivedSessionMustUnarchiveRemotelyBeforePinning \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testMarkHistorySessionUnreadPersistsCompletionWatermark \
  -only-testing:MimiRemoteTests/ConversationProcessGrouperTests \
  -only-testing:MimiRemoteTests/SessionListLifecycleCoordinatorTests \
  -only-testing:MimiRemoteTests/FileAttachmentModelsTests \
  -only-testing:MimiRemoteTests/ConversationSnapshotTests/testConversationBubbleAlignment \
  -only-testing:MimiRemoteTests/ConversationSnapshotTests/testDefaultDarkConversationPalette \
  -only-testing:MimiRemoteTests/ConversationSnapshotTests/testEmptyConversationShowsCurrentDirectoryAcrossAppearances \
  -only-testing:MimiRemoteTests/ConversationSnapshotTests/testRichMarkdownConversationRendering \
  -only-testing:MimiRemoteTests/ConversationSnapshotTests/testMixedActivityAndImageConversationRendering \
  -only-testing:MimiRemoteTests/ConversationSnapshotTests/testSingleImageMediaCardAlignmentAcrossLayouts \
  -only-testing:MimiRemoteTests/ConversationSnapshotTests/testUnavailableUserImageGalleryRemainsLegibleInLightTheme \
  -only-testing:MimiRemoteTests/ConversationSnapshotTests/testSessionRuntimeBadgesInConversationList \
  -only-testing:MimiRemoteTests/ConversationSnapshotTests/testProjectSessionDashboard \
  -only-testing:MimiRemoteTests/ConversationSnapshotTests/testCommentaryAndTrailingProcessRendering \
  -only-testing:MimiRemoteTests/ConversationSnapshotTests/testExpandedProcessGroupRendering \
  -only-testing:MimiRemoteTests/MarkdownRenderingTests \
  -only-testing:MimiRemoteTests/PairingLinkTests \
  -only-testing:MimiRemoteTests/DoctorDiagnosticsTests \
  -only-testing:MimiRemoteTests/ProtocolContractTests
