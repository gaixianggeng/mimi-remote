#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
  echo "关键链路回归映射检查失败：$1" >&2
  exit 1
}

for command_name in bash grep; do
  command -v "$command_name" >/dev/null 2>&1 \
    || fail "缺少命令 ${command_name}。"
done

runner="scripts/test-conversation-regressions.sh"
map_doc="docs/critical-user-journey-regressions.md"

[[ -f "$runner" ]] || fail "缺少回归入口 ${runner}。"
[[ -f "$map_doc" ]] || fail "缺少风险映射 ${map_doc}。"

for risk_id in R1 R2 R3 R4 R5 R6 R7 R8 R9; do
  grep -Fq "| ${risk_id} |" "$map_doc" \
    || fail "${map_doc} 缺少 ${risk_id} 的风险映射。"
done

grep -Fq './internal/auth \' "$runner" \
  || fail "Go 单元层缺少 internal/auth。"
grep -Fq './internal/config \' "$runner" \
  || fail "Go 单元层缺少 internal/config。"
grep -Fq './internal/appserver \' "$runner" \
  || fail "Go 适配层缺少 internal/appserver。"
grep -Fq './internal/httpapi \' "$runner" \
  || fail "Go 集成层缺少 internal/httpapi。"
grep -Fq '  -count=1' "$runner" \
  || fail "Go 回归必须禁用测试缓存。"
grep -Fq -- '-only-testing:MimiRemoteTests/LocalizationTests' "$runner" \
  || fail "日常核心回归未合并双语资源测试。"
grep -Fq 'func TestCriticalJourneyFixtureMatchesAgentDGateway(' \
  internal/httpapi/protocol_contract_test.go \
  || fail "Go 缺少共享关键链路 fixture 回归。"
grep -Fq 'func testCriticalJourneyFixtureMatchesIOSRequestBuilders(' \
  ios/MimiRemote/Tests/MimiRemoteTests/ProtocolContractTests.swift \
  || fail "iOS 缺少共享关键链路 fixture 回归。"
grep -Fq -- '-only-testing:MimiRemoteTests/ProtocolContractTests' "$runner" \
  || fail "iOS runner 未选择共享关键链路 fixture 回归。"
grep -Fq 'testCriticalJourneyFixtureMatchesIOSRequestBuilders' "$map_doc" \
  || fail "${map_doc} 未记录共享关键链路 fixture 回归。"
grep -Fq 'final class SessionListLifecycleCoordinatorTests' \
  ios/MimiRemote/Tests/MimiRemoteTests/SessionListLifecycleCoordinatorTests.swift \
  || fail "iOS 缺少会话生命周期连续性回归。"
grep -Fq -- '-only-testing:MimiRemoteTests/SessionListLifecycleCoordinatorTests' "$runner" \
  || fail "iOS runner 未选择会话生命周期连续性回归。"
grep -Fq 'SessionListLifecycleCoordinatorTests' "$map_doc" \
  || fail "${map_doc} 未记录会话生命周期连续性回归。"
grep -Fq 'func TestFileUploadCapabilityRolloutMatrix(' \
  internal/httpapi/capability_rollout_test.go \
  || fail "Go 缺少 capability enabled/disabled/dependency 矩阵。"
grep -Fq 'func testFileUploadCapabilityDecisionMatrixFailsClosed(' \
  ios/MimiRemote/Tests/MimiRemoteTests/FileAttachmentModelsTests.swift \
  || fail "iOS 缺少 capability fail-closed 状态矩阵。"
grep -Fq 'func testCapabilityNegotiationIsIsolatedPerHostAndRejectsStaleLease(' \
  ios/MimiRemote/Tests/MimiRemoteTests/PairingLinkTests.swift \
  || fail "iOS 缺少多 Host capability 隔离与 stale lease 回归。"
for test_group in FileAttachmentModelsTests PairingLinkTests ProtocolContractTests; do
  grep -Fq -- "-only-testing:MimiRemoteTests/${test_group}" "$runner" \
    || fail "iOS runner 未选择 ${test_group} capability 回归。"
done
for test_name in \
  TestFileUploadCapabilityRolloutMatrix \
  testFileUploadCapabilityDecisionMatrixFailsClosed \
  testCapabilityNegotiationIsIsolatedPerHostAndRejectsStaleLease; do
  grep -Fq "$test_name" "$map_doc" \
    || fail "${map_doc} 未记录 ${test_name}。"
done

# 每个条目同时绑定 XCTest selector 与真实源码。测试改名、移动或从 runner
# 移除时都会给出具体失败点，避免文档仍显示覆盖但 Gate 已经漏跑。
critical_swift_tests=(
  "ios/MimiRemote/Tests/MimiRemoteTests/ConversationDirectRuntimeTests.swift|testCodexAppServerFakeSmokeCoversThreadTurnAndApproval"
  "ios/MimiRemote/Tests/MimiRemoteTests/ConversationDirectRuntimeHistoryTests.swift|testSessionStoreConsumesDirectAppServerEventsWithoutMobileProtocolConversion"
  "ios/MimiRemote/Tests/MimiRemoteTests/ConversationDirectRuntimeHistoryTests.swift|testCodexAppServerSessionRuntimeReconnectsAfterTransportReceiveFailure"
  "ios/MimiRemote/Tests/MimiRemoteTests/ConversationDirectRuntimeHistoryTests.swift|testDirectRuntimeRestoresReplayedServerRequestOnIdleReportingThread"
  "ios/MimiRemote/Tests/MimiRemoteTests/ConversationDirectRuntimeHistoryTests.swift|testTurnInterruptAcknowledgementPollsUntilAuthoritativeTerminalTurn"
  "ios/MimiRemote/Tests/MimiRemoteTests/ConversationDirectRuntimeHistoryTests.swift|testTargetedInterruptRecoveryWorksWithoutCachedActiveTurnAndProtectsNewerTurn"
  "ios/MimiRemote/Tests/MimiRemoteTests/ConversationRuntimeFlowTests.swift|testTerminalStreamStoreSeparatesSameSessionAcrossHostScopes"
  "ios/MimiRemote/Tests/MimiRemoteTests/ConversationRuntimeFlowTests.swift|testWebSocketFailureAutoReconnectsWithLatestReplayWatermark"
  "ios/MimiRemote/Tests/MimiRemoteTests/ConversationRuntimeFlowTests.swift|testStaleWebSocketStatusDoesNotRetireCurrentReconnect"
  "ios/MimiRemote/Tests/MimiRemoteTests/ConversationRuntimeFlowTests.swift|testFailedRunningMessageRetryReusesClientMessageID"
  "ios/MimiRemote/Tests/MimiRemoteTests/ConversationRuntimeFlowTests.swift|testRunningTurnLifecycleKeepsEchoAndFinalAssistantStable"
  "ios/MimiRemote/Tests/MimiRemoteTests/ConversationConnectionRecoveryTests.swift|testOfflineSuspendsReconnectAndPreservesSessionQueueAndMessages"
  "ios/MimiRemote/Tests/MimiRemoteTests/ConversationConnectionRecoveryTests.swift|testNetworkRecoveryReconnectsExactlyOnce"
  "ios/MimiRemote/Tests/MimiRemoteTests/ConversationConnectionRecoveryTests.swift|testCredentialTerminalStatusStopsReconnectAndPreservesLocalSessionState"
  "ios/MimiRemote/Tests/MimiRemoteTests/ConversationConnectionRecoveryTests.swift|testRecoveryGenerationFailureDoesNotReuseOlderFullSnapshot"
  "ios/MimiRemote/Tests/MimiRemoteTests/ConversationConnectionRecoveryTests.swift|testRecoveryForceLoadReplacesOlderReuseRecentRequest"
  "ios/MimiRemote/Tests/MimiRemoteTests/ConversationTurnQueueTests.swift|testRunningQueuedDeliverySendsOneMessageAfterEachCompletedTurn"
  "ios/MimiRemote/Tests/MimiRemoteTests/ConversationTurnQueueTests.swift|testRunningQueueDoesNotDispatchMerelyBecauseWebSocketReconnected"
  "ios/MimiRemote/Tests/MimiRemoteTests/ConversationTurnQueueTests.swift|testRunningSendFailureNoRolloutFoundMarksLocalEchoFailedAndRetainsRetryPayload"
  "ios/MimiRemote/Tests/MimiRemoteTests/ConversationTurnQueueTests.swift|testApprovalDecisionSendsThroughCurrentWebSocket"
  "ios/MimiRemote/Tests/MimiRemoteTests/ConversationTurnQueueTests.swift|testSessionStoreReplaysDirectAppServerEventStreamFixture"
  "ios/MimiRemote/Tests/MimiRemoteTests/ConversationSessionStoreTests.swift|testSessionStoreSendsUserInputAnswersThroughExistingSocket"
  "ios/MimiRemote/Tests/MimiRemoteTests/ConversationSessionStoreTests.swift|testWorkbenchRestorationRouteRejectsSnapshotFromDifferentEndpoint"
  "ios/MimiRemote/Tests/MimiRemoteTests/ConversationSessionStoreTests.swift|testColdStartResolvedCandidateCannotCommitAfterUserSelectsAnotherSession"
  "ios/MimiRemote/Tests/MimiRemoteTests/ConversationSessionStoreTests.swift|testLateGitStatusFromPreviousHostCannotOverwriteCurrentHostState"
)

for test_entry in "${critical_swift_tests[@]}"; do
  test_file="${test_entry%%|*}"
  test_name="${test_entry#*|}"
  [[ -f "$test_file" ]] || fail "测试源码不存在：${test_file}。"
  grep -Fq "func ${test_name}(" "$test_file" \
    || fail "${test_file} 缺少 ${test_name}。"
  grep -Fq -- "-only-testing:MimiRemoteTests/ConversationDataFlowTests/${test_name}" "$runner" \
    || fail "${runner} 未选择 ${test_name}。"
  grep -Fq "$test_name" "$map_doc" \
    || fail "${map_doc} 未记录 ${test_name}。"
done

grep -Fq 'bash ./scripts/check-critical-regressions.sh' scripts/check-pr-gate.sh \
  || fail "PR Gate 自检没有调用关键链路映射检查。"
grep -Fq 'scripts/test-conversation-regressions.sh|scripts/check-critical-regressions.sh' scripts/ci-pr-scope.sh \
  || fail "路径分类没有把关键链路 runner/checker 共同映射到 Go 与 iOS。"
grep -Fq '"scripts/check-critical-regressions.sh"' .github/workflows/go-ci.yml \
  || fail "Go CI 的 push 路径缺少关键链路 checker。"
grep -Fq '"scripts/check-critical-regressions.sh"' .github/workflows/ios-ci.yml \
  || fail "iOS CI 的 push 路径缺少关键链路 checker。"

echo "关键链路回归映射检查通过：9 类风险、4 个 Go 包和 ${#critical_swift_tests[@]} 个高价值 iOS 测试均已接入。"
