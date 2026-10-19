#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'EOF'
用法：
  bash ./scripts/test-conversation-regressions.sh [--ios-only]

默认执行 Go 与 iOS 关键链路回归。--ios-only 供已经由独立 Go 验证覆盖的
iOS CI / full 验证使用，只跳过 Go 阶段，不改变任何 XCTest selector。
EOF
}

ios_only=false
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --ios-only)
      ios_only=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "不支持的参数：$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$ios_only" == false ]]; then
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
fi

echo "==> iOS conversation regressions"
# 这些测试组覆盖 Mimi Remote 对话请求链路和发布安全边界：
# - AgentAPIClientRequestTests：全部 REST 调用的路径、方法、鉴权、JSON 字段和超时契约。
# - CameraAttachmentTests：相机可用性、权限恢复和现有图片压缩上限。
# - CodexAppServerProtocolTests：JSON-RPC payload、collaborationMode、目标/steer 协议。
# - ComposerAutocompleteTests：输入框 `/` 命令与 `$` 技能补全的触发、替换范围和排序。
# - ClaudeSlashCommandCatalogTests：Claude 会话 `/` 菜单命令目录的解析、请求与按键缓存。
# - ConversationDataFlowTests 的精确方法：只保留配对后的会话、流式事件、恢复、
#   exactly-once、审批/中断、Host 隔离和 fake smoke；其余大集合不无条件进入 PR Gate。
# - QueuedSessionBackgroundDispatchTests：离开会话后排队消息的后台连接，覆盖重连退避与停止、
#   错误只归属原会话和各 Runtime 的离开监听。
# - FileAttachmentModelsTests：文件上传、capability 状态矩阵、内部上下文编解码和旧服务端兼容。
# - ConversationTimelineProviderPresentationTests：Codex/Claude 默认与详细记录投影、锚点和全文入口。
# - ConversationScrollStabilityTests：首屏可读交接、手势取消、阅读锚点和显式回到底部。
# - ConversationTimelineRuntimeRegressionTests：原生 List 在 Codex/Claude/DeepSeek 更新及历史前插后的视口。
# - SessionListLifecycleCoordinatorTests：滚动冻结、idle 重排和完成/失败 Haptic exactly-once。
# - SessionListPresentationTests：会话摘要、分支身份、时间格式和紧凑行数策略。
# - ConversationSnapshotTests：用户气泡/助手文档流、复杂 Markdown、图片和活动行的关键视觉回归。
# - ConversationQuestionReplyTests：Desktop 异步提问答复的结构化投影，以及实时、重进和分页历史的一致顺序。
# - MarkdownRenderingTests：proposed_plan 流式和完整渲染。
# - PairingLinkTests：Endpoint allowlist、ATS 传输策略、Host capability 隔离和 stale lease。
# - DoctorDiagnosticsTests：结构化 Doctor 响应、HTTP 错误和向后兼容。
# - ProtocolContractTests：iOS/agentd 当前、上一版和明确不兼容的版本窗口。
# - ManagedConnectionEntitlementStoreTests、ManagedConnectionEntitlementAPIClientTests、
#   ManagedConnectionStoreKitClientTests：订阅状态机、服务端授权契约和 StoreKit 适配。
# - LocalizationTests：日常单次 XCTest 内覆盖双语资源和 App 内显式语言切换。
# - RuntimeRouteRetentionTests：回前台重建 bundle 后会话仍走所属 Runtime，重新授权不为别的 Runtime 翻列表（#784）。
# - LocalCompletionSupersededTests：本地完成标记只挡落后快照，电脑端开始的新一轮能恢复进行中并让发送排队（#805）。
# - CodexTurnInterruptBeforeStartTests：turn/start 响应后、turn/started 前的停止等回合开始后重发，
#   不把这段窗口里的 no active turn 当成已停止（#808）。
# - NotificationTitleCacheTests、NotificationContentRewriterTests：会话标题的 App Group 本地缓存，
#   以及通知扩展只用该缓存在设备上改写锁屏文案、缓存缺失时退回通用文案。
# - RuntimeCatalogRefreshTests：Runtime 探测失败不撤下可用通道、选择器重探，以及模型目录缺席 Runtime 的补齐（#777/#778）。
# - WorkbenchLayoutModeCommitTests：iPad 旋转跨 860pt 时换树等系统尺寸过渡结束，
#   以及输入框焦点、面板跨换树交接（#755）。
#
# 每个测试类必须整类出现在下面的 selector 里，或登记在 config/ios-tests/nightly-classes.txt
# 由每晚全量任务执行；scripts/check-ios-test-selectors.sh 校验类名、方法与归属。
# config/ios-tests/quarantine.tsv 中隔离的单个用例在这里同样跳过。
quarantine_output="$(python3 "$ROOT_DIR/scripts/ios-test-inventory.py" skip-args)"
quarantine_skip_args=()
while IFS= read -r skip_arg; do
  if [[ -n "$skip_arg" ]]; then
    quarantine_skip_args+=("$skip_arg")
  fi
done <<<"$quarantine_output"
test_result_bundle="$(mktemp -d "${TMPDIR:-/tmp}/mimi-conversation-tests.XXXXXX")/core.xcresult"
test_status=0
bash "$ROOT_DIR/scripts/ios-dev.sh" test \
  -quiet \
  -resultBundlePath "$test_result_bundle" \
  -collect-test-diagnostics never \
  -testLanguage zh-Hans \
  -testRegion CN \
  ${quarantine_skip_args[@]+"${quarantine_skip_args[@]}"} \
  -only-testing:MimiRemoteTests/AgentAPIClientRequestTests \
  -only-testing:MimiRemoteTests/CameraAttachmentTests \
  -only-testing:MimiRemoteTests/CodexAppServerProtocolTests \
  -only-testing:MimiRemoteTests/ComposerAutocompleteTests \
  -only-testing:MimiRemoteTests/ClaudeSlashCommandCatalogTests \
  -only-testing:MimiRemoteTests/DeepSeekComposerPolicyTests \
  -only-testing:MimiRemoteTests/RuntimeCatalogRefreshTests \
  -only-testing:MimiRemoteTests/DeepSeekSearchRoutingTests \
  -only-testing:MimiRemoteTests/DeepSeekRuntimePresentationTests \
  -only-testing:MimiRemoteTests/DefaultModelDisplayTests \
  -only-testing:MimiRemoteTests/HarnessNativeRoutingSeamTests \
  -only-testing:MimiRemoteTests/SessionObservationLeaseTests \
  -only-testing:MimiRemoteTests/HarnessTransportTests \
  -only-testing:MimiRemoteTests/HarnessSessionDirectoryTests \
  -only-testing:MimiRemoteTests/HarnessDirectoryWiringTests \
  -only-testing:MimiRemoteTests/HarnessSessionJournalTests \
  -only-testing:MimiRemoteTests/HarnessSubmissionControllerTests \
  -only-testing:MimiRemoteTests/HarnessPresentationProjectorTests \
  -only-testing:MimiRemoteTests/HarnessInterruptedSettlementTests \
  -only-testing:MimiRemoteTests/HarnessEventClientTests \
  -only-testing:MimiRemoteTests/HarnessStreamReconnectTests \
  -only-testing:MimiRemoteTests/HarnessSnapshotBaselineTests \
  -only-testing:MimiRemoteTests/HarnessSnapshotReplayTests \
  -only-testing:MimiRemoteTests/HarnessInteractionStoreTests \
  -only-testing:MimiRemoteTests/HarnessRecoveryCoordinatorTests \
  -only-testing:MimiRemoteTests/HarnessHostEventObserverTests \
  -only-testing:MimiRemoteTests/HarnessHistoryPageTests \
  -only-testing:MimiRemoteTests/HistoryPolicyClassificationTests \
  -only-testing:MimiRemoteTests/ClaudeTakeoverTests \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testCodexAppServerFakeSmokeCoversThreadTurnAndApproval \
  -only-testing:MimiRemoteTests/NewSessionBufferedReplyTests \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testSessionStoreConsumesDirectAppServerEventsWithoutMobileProtocolConversion \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testSharedLocalOpeningIdleThreadResumesToValidateWriter \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testSharedSSHOpeningIdleThreadResumesToValidateWriter \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testThreadResumeRestoresPlanModeWithoutWritingSharedMode \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testFailedThreadResumeDoesNotPublishCollaborationMode \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testResumeModeRequiresMatchingThreadCWD \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testSettingsUpdateDuringResumeWinsOverResumeSnapshot \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testMissingNullAndUnknownModesDoNotReplaceAuthoritativeMode \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testSessionStorePublishesAuthoritativeCollaborationModePerSession \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testAuthoritativeCollaborationModeDoesNotOverrideActiveComposerChoice \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testSubmittedPlanResetIgnoresCachedModeUntilCurrentSessionChanges \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testAcceptedPlanSendSuppressesSubmittedModeBeforeSettingsEcho \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testPartialAnswerAllowsMoreItemsUntilTurnCompleted \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testAgentMessageWithoutPhaseKeepsLegacyMessageProjection \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testDirectIdleHistorySessionSendsThroughResumePath \
  -only-testing:MimiRemoteTests/WriterConflictForkStoreTests \
  -only-testing:MimiRemoteTests/ForkOnWriterConflictProtocolTests \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testSteerTurnSurvivesLastObserverLeavingWhileThreadResumeIsPending \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testStartTurnSurvivesLastObserverLeavingWhileThreadResumeIsPending \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testStartTurnSurvivesLastObserverLeavingWhileTurnStartAcknowledgementIsPending \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testStartTurnDeferredUnsubscribeDoesNotOverrideObserverReentry \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testStartTurnDoesNotRetryAfterConnectionDropsDuringThreadResume \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testRunningQueuedSendDuringModelLookupSurvivesReturnToList \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testLocalDraftSendSurvivesDiscardAndKeepsNewDraftSelectedAfterCreateACK \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testContinuationCreateACKDoesNotReplaceNewSessionSelection \
  -only-testing:MimiRemoteTests/ConversationLiveStatusTests \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testFirstSendPublishesPreparationBeforeAcknowledgementAndLiveSubscription \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testTargetModelFailureCacheIsPerRuntimeAndCanExpire \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testForcedMenuRefreshSupersedesPendingTargetModelResult \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testConcurrentTargetModelPreparationSharesCatalog \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testLocalCodexDraftDoesNotAdoptClaudeFromPartialModelCatalog \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testDefaultModelResolutionCarriesRuntimeProviderBeforeCreate \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testModelListFailureFallsBackToBuiltInModelBeforeCreate \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testClaudeHistorySessionIgnoresStaleCodexModelSelectionBeforeResume \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testReopenShowsHistoryThenConnectionWithoutInventingNetworkFailure \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testHostChangeDuringModelLookupCancelsCapturedSubmission \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testHostSwitchSettlesPendingGuidanceInOriginalProfile \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testCapturedGuidedSendAfterSelectingAnotherSessionUsesBackgroundSocketUntilACK \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testForegroundGuidedSendACKAfterNavigationStillSettlesOriginalEcho \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testReenteringCreatingSessionBlocksSecondSendUntilRemoteIdentityArrives \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testBackgroundGuidanceWriterConflictDoesNotDisableSelectedSession \
  -only-testing:MimiRemoteTests/GuidanceSendLifecycleTests \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testCodexAuthoritativeFirstPageReadsFreshIndexIncludingExternalUnarchive \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testCodexAuthoritativeEmptyIndexFallsBackToHistoryScan \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testExternalArchiveDoesNotPermanentlyDisableDirectoryIndex \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testCodexContinuationUsesIndexWithoutRepairingFirstPageRows \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testCodexGlobalDiscoveryUsesIndexAcrossPages \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testCodexGlobalDiscoveryFallsBackWhenIndexUnsupported \
  -only-testing:MimiRemoteTests/SessionStorePublishBudgetTests \
  -only-testing:MimiRemoteTests/ControlledGlobalCursorLifecycleTests \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testGlobalLibraryPublishesAllRuntimeFirstPagesBeforeBackfill \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testGlobalLibraryFirstPageFailureDoesNotBlockOtherRuntimeFirstPages \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testScanFallbackContinuationKeepsItsQueryModeForDirectoryAndGlobalLists \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testGlobalIndexRepairsKnownMissingSessionsAcrossFilteredAndCompletePages \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testCodexAppServerSessionRuntimeReconnectsAfterTransportReceiveFailure \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testDirectRuntimeKeepsStaleReplayedServerRequestSilentOnIdleThread \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testTurnInterruptAcknowledgementPollsUntilAuthoritativeTerminalTurn \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testTargetedInterruptRecoveryWorksWithoutCachedActiveTurnAndProtectsNewerTurn \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testStaleInterruptRealRuntimeDispatchesQueuedTurnAfterResume \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testStaleInterruptRuntimeClearsPendingReplayAndRejectsLateRequests \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testStaleInterruptRuntimePreservesSupersedingTurn \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testNonStaleInterruptRuntimeFailureKeepsActiveTurn \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testStaleStopRealAPIClientsCloseRuntimeWithoutReleasingNextTurn \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testStaleStopRealAPIClientDoesNotCloseSupersedingTurn \
  -only-testing:MimiRemoteTests/CodexTurnInterruptBeforeStartTests \
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
  -only-testing:MimiRemoteTests/QueuedTurnActiveTurnGapTests \
  -only-testing:MimiRemoteTests/QueuedSessionBackgroundDispatchTests \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testFailedRunningMessageRetryReusesClientMessageID \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testRunningSendFailureNoRolloutFoundMarksLocalEchoFailedAndRetainsRetryPayload \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testApprovalDecisionSendsThroughCurrentWebSocket \
  -only-testing:MimiRemoteTests/LockScreenApprovalTests \
  -only-testing:MimiRemoteTests/MessageNotificationTests \
  -only-testing:MimiRemoteTests/LockScreenApprovalRoutingTests \
  -only-testing:MimiRemoteTests/NotificationRoutingGateTests \
  -only-testing:MimiRemoteTests/NotificationRouteResolutionTests \
  -only-testing:MimiRemoteTests/RuntimeRouteRetentionTests \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testCompletionAwaitingReducerDoesNotOverwriteNewerActiveTurn \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testPagedHistoryRetainsInvisibleTurnStatesForCompletionRecovery \
  -only-testing:MimiRemoteTests/NotificationTitleCacheTests \
  -only-testing:MimiRemoteTests/NotificationContentRewriterTests \
  -only-testing:MimiRemoteTests/WorkbenchLayoutModeCommitTests \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testSessionStoreReplaysDirectAppServerEventStreamFixture \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testSessionStoreSendsUserInputAnswersThroughExistingSocket \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testRunningTurnLifecycleKeepsEchoAndFinalAssistantStable \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testWorkbenchRestorationRouteRejectsSnapshotFromDifferentEndpoint \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testColdStartResolvedCandidateCannotCommitAfterUserSelectsAnotherSession \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testLateGitStatusFromPreviousHostCannotOverwriteCurrentHostState \
  -only-testing:MimiRemoteTests/WorkspaceGitStoreTests \
  -only-testing:MimiRemoteTests/WorkspaceGitSummaryTests \
  -only-testing:MimiRemoteTests/WorkspaceHostBoundaryTests \
  -only-testing:MimiRemoteTests/SessionArchiveReconciliationTests \
  -only-testing:MimiRemoteTests/LocalCompletionSupersededTests \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testManualWorkspaceRefreshRestartsFromFirstCursor \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testManualSessionLibraryRefreshRestartsDirectoryPageFromFirstCursor \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testWorkspacePageDropsLocallyArchivedCacheWhileKeepingProtectedRows \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testManualRestartStopsContinuationAfterCurrentNetworkPage \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testConcurrentManualRestartsShareFirstPageAndLineage \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testRestartedFirstPageRejectsOldLineageEvenWhenCursorMatches \
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
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testMarkHistorySessionUnreadKeepsCompletionObservationPersisted \
  -only-testing:MimiRemoteTests/WorkspacePullRefreshTests \
  -only-testing:MimiRemoteTests/ConversationTimelineProviderPresentationTests \
  -only-testing:MimiRemoteTests/ConversationActivityDetailProjectionTests \
  -only-testing:MimiRemoteTests/ConversationScrollStabilityTests \
  -only-testing:MimiRemoteTests/ConversationTimelineRuntimeRegressionTests \
  -only-testing:MimiRemoteTests/SessionListLifecycleCoordinatorTests \
  -only-testing:MimiRemoteTests/SessionListPresentationTests \
  -only-testing:MimiRemoteTests/TokenUsageCardSnapshotTests \
  -only-testing:MimiRemoteTests/FileAttachmentModelsTests \
  -only-testing:MimiRemoteTests/ConversationSnapshotTests/testConversationBubbleAlignment \
  -only-testing:MimiRemoteTests/ConversationSnapshotTests/testDefaultDarkConversationPalette \
  -only-testing:MimiRemoteTests/ConversationSnapshotTests/testEmptyConversationShowsCurrentDirectoryAcrossAppearances \
  -only-testing:MimiRemoteTests/ConversationSnapshotTests/testRichMarkdownConversationRendering \
  -only-testing:MimiRemoteTests/ConversationSnapshotTests/testMixedActivityAndImageConversationRendering \
  -only-testing:MimiRemoteTests/ConversationSnapshotTests/testSingleImageMediaCardAlignmentAcrossLayouts \
  -only-testing:MimiRemoteTests/ConversationSnapshotTests/testUnavailableUserImageGalleryRemainsLegibleInLightTheme \
  -only-testing:MimiRemoteTests/ConversationSnapshotTests/testSessionRuntimeIconsInPhoneConversationRows \
  -only-testing:MimiRemoteTests/ConversationSnapshotTests/testProjectSessionDashboard \
  -only-testing:MimiRemoteTests/ConversationSnapshotTests/testCommentaryAndTrailingActivitiesRendering \
  -only-testing:MimiRemoteTests/ConversationQuestionReplyTests \
  -only-testing:MimiRemoteTests/ConversationTimelineProviderPresentationSnapshotTests \
  -only-testing:MimiRemoteTests/MarkdownRenderingTests \
  -only-testing:MimiRemoteTests/MessageTextSelectionTests \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testLongHistoryFirstPresentationAndCachedReopenForBothProviders \
  -only-testing:MimiRemoteTests/ConversationDataFlowTests/testLongProseHistoryFirstPresentationAndCachedReopenForBothProviders \
  -only-testing:MimiRemoteTests/PairingLinkTests \
  -only-testing:MimiRemoteTests/TailcatExperimentRoutingTests \
  -only-testing:MimiRemoteTests/TailcatLocalEndpointProbeTests \
  -only-testing:MimiRemoteTests/DoctorDiagnosticsTests \
  -only-testing:MimiRemoteTests/ProtocolContractTests \
  -only-testing:MimiRemoteTests/ManagedConnectionEntitlementStoreTests \
  -only-testing:MimiRemoteTests/ManagedConnectionEntitlementAPIClientTests \
  -only-testing:MimiRemoteTests/ManagedConnectionStoreKitClientTests \
  -only-testing:MimiRemoteTests/LocalizationTests || test_status=$?

if [[ "$test_status" -ne 0 && -d "$test_result_bundle" ]]; then
  # quiet 日志可能只列测试名；失败时保留具体断言，诊断失败也不能覆盖原退出码。
  xcrun xcresulttool get test-results summary --path "$test_result_bundle" || true
fi
exit "$test_status"
