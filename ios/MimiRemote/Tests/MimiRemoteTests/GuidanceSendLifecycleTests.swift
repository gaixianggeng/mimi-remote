import XCTest
@testable import MimiRemote

@MainActor
final class GuidanceSendLifecycleTests: XCTestCase {
    func testMultiRuntimeGuidanceAcknowledgementSurvivesWrapperRelease() async throws {
        try await assertGuidanceResultSurvivesWrapperRelease(
            suffix: "ack",
            response: .acknowledged
        )
    }

    func testMultiRuntimeGuidanceFailureSurvivesWrapperRelease() async throws {
        try await assertGuidanceResultSurvivesWrapperRelease(
            suffix: "failure",
            response: .rejected
        )
    }

    func testDefaultSendMethodFallsBackToQueueWhenPreferenceIsMissingOrUnknown() {
        // 没存过偏好、或旧版本写进去的值读不出来时，必须保持既有行为：排队。
        XCTAssertEqual(RunningTurnDelivery.fallbackDefault, .queued)
        XCTAssertEqual(RunningTurnDelivery.stored(""), .queued)
        XCTAssertEqual(RunningTurnDelivery.stored("steer"), .queued)
        XCTAssertEqual(RunningTurnDelivery.stored(RunningTurnDelivery.queued.rawValue), .queued)
        XCTAssertEqual(RunningTurnDelivery.stored(RunningTurnDelivery.guided.rawValue), .guided)
        // 设置页按这个顺序排两个胶囊；排队在前，保持与今天的默认一致。
        XCTAssertEqual(RunningTurnDelivery.allCases, [.queued, .guided])
    }

    func testGuidedDefaultOnlyAppliesWhileSteeringIsAvailable() {
        // 切换会话、发送成功和可用性变化都走这一个入口；两个运行时共用同一份偏好，
        // 因此这里不按 runtime 分叉，只看当前 turn 能不能被引导。
        XCTAssertEqual(
            RunningTurnDelivery.restoredSelection(default: .guided, canUseGuidedFollowUp: true),
            .guided
        )
        XCTAssertEqual(
            RunningTurnDelivery.restoredSelection(default: .guided, canUseGuidedFollowUp: false),
            .queued,
            "没有可引导的活动 turn 时，偏好选了引导也必须回落排队"
        )
        XCTAssertEqual(
            RunningTurnDelivery.restoredSelection(default: .queued, canUseGuidedFollowUp: true),
            .queued
        )
        XCTAssertEqual(
            RunningTurnDelivery.restoredSelection(default: .queued, canUseGuidedFollowUp: false),
            .queued
        )
    }

    func testDeliveryContextChangesWhenActiveReplyChangesWithoutLosingSteering() {
        let previous = RunningTurnDeliveryContext(turnID: "turn-one", canGuide: true)
        let next = RunningTurnDeliveryContext(turnID: "turn-two", canGuide: true)

        XCTAssertNotEqual(previous, next)
        XCTAssertEqual(
            RunningTurnDelivery.restoredSelection(default: .guided, canUseGuidedFollowUp: next.canGuide),
            .guided,
            "the new reply must restore the configured preference after a one-off Queue choice"
        )
        XCTAssertNotEqual(next, RunningTurnDeliveryContext(turnID: "turn-two", canGuide: false))
    }

    func testBackgroundSendOnlyRestoresChoicesFromItsComposerActivation() {
        let instanceID = UUID()
        let sessionA = ComposerDraftScopeKey.session("session-a")
        let sessionB = ComposerDraftScopeKey.session("session-b")
        let submitted = ComposerTransientSelectionCheckpoint(
            instanceID: instanceID,
            scopeRevision: 4,
            deliveryRevision: 7,
            cachedDeliveryRevision: 2,
            sendModeRevision: 3,
            cachedSendModeRevision: 2
        )

        let resumed = submitted.restoration(
            activeInstanceID: instanceID,
            activeScope: sessionA, selectedScope: sessionA,
            scopeRevision: 4, deliveryRevision: 7, sendModeRevision: 3
        )
        XCTAssertTrue(resumed.delivery)
        XCTAssertTrue(resumed.sendMode, "same-session resume may advance the selection lease")

        let migrated = submitted.restoration(
            activeInstanceID: instanceID,
            activeScope: .session("server-session"), selectedScope: .session("server-session"),
            scopeRevision: 4, deliveryRevision: 7, sendModeRevision: 3
        )
        XCTAssertTrue(migrated.delivery)
        XCTAssertTrue(migrated.sendMode, "an optimistic ID handoff preserves this composer activation")

        let changedDelivery = submitted.restoration(
            activeInstanceID: instanceID,
            activeScope: sessionA, selectedScope: sessionA,
            scopeRevision: 4, deliveryRevision: 8, sendModeRevision: 3
        )
        XCTAssertFalse(changedDelivery.delivery, "keep a new Queue/Steer choice made while sending")
        XCTAssertTrue(changedDelivery.sendMode)

        let changedMode = submitted.restoration(
            activeInstanceID: instanceID,
            activeScope: sessionA, selectedScope: sessionA,
            scopeRevision: 4, deliveryRevision: 7, sendModeRevision: 4
        )
        XCTAssertTrue(changedMode.delivery)
        XCTAssertFalse(changedMode.sendMode)

        for (active, selected, revision) in [
            (sessionB, sessionB, UInt64(5)),
            (sessionA, sessionA, UInt64(6)),
            (sessionA, sessionB, UInt64(4)),
        ] {
            let afterNavigation = submitted.restoration(
                activeInstanceID: instanceID,
                activeScope: active, selectedScope: selected,
                scopeRevision: revision, deliveryRevision: 7, sendModeRevision: 3
            )
            XCTAssertFalse(afterNavigation.delivery)
            XCTAssertFalse(afterNavigation.sendMode)
        }

        let rebuiltComposer = submitted.restoration(
            activeInstanceID: UUID(),
            activeScope: sessionA, selectedScope: sessionA,
            scopeRevision: 4, deliveryRevision: 7, sendModeRevision: 3
        )
        XCTAssertFalse(rebuiltComposer.delivery)
        XCTAssertFalse(rebuiltComposer.sendMode, "a rebuilt composer can reuse local revision values")
    }

    func testHiddenSubmittedModeClearsOnlyUnchangedCache() {
        let scope = ComposerDraftScopeKey.session("session-a")
        var cache = ComposerSendModeCache()
        cache.save(.plan, for: scope)
        let submittedRevision = cache.revision
        cache.save(.plan, for: scope)
        XCTAssertEqual(cache.revision, submittedRevision, "reconstruction must not invalidate an unchanged choice")
        XCTAssertEqual(cache.clearSubmittedModeIfUnchanged(revision: submittedRevision), scope)
        XCTAssertEqual(cache.modeForReappearance(of: scope), .standard)
        XCTAssertEqual(
            cache.modeForScopeActivation(
                previousScope: .none, nextScope: scope,
                currentMode: .standard, isOptimisticSessionHandoff: false
            ),
            .standard
        )

        cache.save(.goal, for: scope)
        XCTAssertNil(cache.clearSubmittedModeIfUnchanged(revision: submittedRevision))
        XCTAssertEqual(cache.modeForReappearance(of: scope), .goal)
        XCTAssertEqual(
            cache.modeForScopeActivation(
                previousScope: .none, nextScope: scope,
                currentMode: .standard, isOptimisticSessionHandoff: false
            ),
            .goal,
            "a newer choice must survive the old submission's completion"
        )
    }

    func testOneOffQueueSelectionSurvivesReconstructionButNotAnotherTurn() {
        let scope = ComposerDraftScopeKey.session("session-a")
        let turn = RunningTurnDeliveryContext(turnID: "turn-a", canGuide: true)
        let nextTurn = RunningTurnDeliveryContext(turnID: "turn-b", canGuide: true)
        var cache = ComposerDeliverySelectionCache()
        cache.save(.queued, for: scope, context: turn, default: .guided)
        let submittedRevision = cache.revision

        XCTAssertEqual(cache.selection(for: scope, context: turn, default: .guided), .queued)
        XCTAssertNil(cache.selection(for: scope, context: nextTurn, default: .guided))
        XCTAssertNil(cache.selection(for: scope, context: turn, default: .queued))
        XCTAssertEqual(cache.clearIfUnchanged(revision: submittedRevision), scope)
        XCTAssertNil(cache.selection(for: scope, context: turn, default: .guided))

        cache.save(.queued, for: scope, context: turn, default: .guided)
        let olderRevision = cache.revision
        cache.save(.guided, for: scope, context: turn, default: .guided)
        XCTAssertNil(cache.clearIfUnchanged(revision: olderRevision))
        XCTAssertEqual(cache.selection(for: scope, context: turn, default: .guided), .guided)
    }

    func testOneOffQueueSelectionMigratesWithOptimisticSessionIdentity() {
        let local = ComposerDraftScopeKey.session("local:project:message")
        let server = ComposerDraftScopeKey.session("server-session")
        let turn = RunningTurnDeliveryContext(turnID: "turn-a", canGuide: true)
        var cache = ComposerDeliverySelectionCache()
        cache.save(.queued, for: local, context: turn, default: .guided)
        let submittedRevision = cache.revision

        cache.migrateScope(from: local, to: server)
        XCTAssertEqual(cache.revision, submittedRevision)
        XCTAssertEqual(cache.selection(for: server, context: turn, default: .guided), .queued)
        XCTAssertEqual(cache.clearIfUnchanged(revision: submittedRevision), server)
    }

    func testRebuiltComposerNavigationInvalidatesPreviousSessionOverride() {
        let sessionA = ComposerDraftScopeKey.session("session-a")
        let sessionB = ComposerDraftScopeKey.session("session-b")
        let turn = RunningTurnDeliveryContext(turnID: "turn", canGuide: true)
        var cache = ComposerDeliverySelectionCache()
        cache.save(.queued, for: sessionA, context: turn, default: .guided)

        XCTAssertNil(cache.selectionForActivation(of: sessionB, context: turn, default: .guided))
        XCTAssertNil(cache.selectionForActivation(of: sessionA, context: turn, default: .guided))
        cache.save(.queued, for: sessionA, context: turn, default: .guided)
        XCTAssertNil(cache.selectionForActivation(of: sessionA, context: turn, default: .queued))
    }

    func testSubmittedModeRevisionSurvivesOptimisticIdentityHandoff() {
        let local = ComposerDraftScopeKey.session("local:project:message")
        let server = ComposerDraftScopeKey.session("server-session")
        var cache = ComposerSendModeCache()
        cache.save(.goal, for: local)
        let submittedRevision = cache.revision

        cache.migrateScope(from: local, to: server, mode: .goal)
        XCTAssertEqual(cache.revision, submittedRevision)
        XCTAssertEqual(cache.clearSubmittedModeIfUnchanged(revision: submittedRevision), server)
        XCTAssertEqual(cache.modeForReappearance(of: server), .standard)

        cache.save(.goal, for: server)
        XCTAssertNil(cache.clearSubmittedModeIfUnchanged(revision: submittedRevision))
        XCTAssertEqual(cache.modeForReappearance(of: server), .goal)
    }

    func testSendMethodMenuMarksThePreferredOptionAsDefault() {
        XCTAssertEqual(
            RunningTurnDelivery.queued.menuTitle(isDefault: true, isGuidedAvailable: true),
            L10n.text("ui.queue_default")
        )
        XCTAssertEqual(
            RunningTurnDelivery.queued.menuTitle(isDefault: false, isGuidedAvailable: true),
            L10n.text("ui.queue_for_next_round"),
            "默认改成引导后，「（默认）」不能继续钉在排队项上"
        )
        XCTAssertEqual(
            RunningTurnDelivery.guided.menuTitle(isDefault: true, isGuidedAvailable: true),
            L10n.text("ui.steer_current_reply_default")
        )
        XCTAssertEqual(
            RunningTurnDelivery.guided.menuTitle(isDefault: false, isGuidedAvailable: true),
            L10n.text("ui.lead_current_reply")
        )
        XCTAssertEqual(
            RunningTurnDelivery.guided.menuTitle(isDefault: true, isGuidedAvailable: false),
            L10n.text("ui.guide_current_reply_no_active_round_currently"),
            "引导不可用时先说明原因，默认标记让位"
        )
    }

    private enum GuidanceResponse {
        case acknowledged
        case rejected
    }

    private func assertGuidanceResultSurvivesWrapperRelease(
        suffix: String,
        response: GuidanceResponse
    ) async throws {
        let project = AgentProject(
            id: "proj_guidance_lifecycle_\(suffix)",
            name: "Guidance Lifecycle",
            path: "/tmp/guidance-lifecycle-\(suffix)"
        )
        let threadID = "thread_guidance_lifecycle_\(suffix)"
        let turnID = "turn_guidance_lifecycle_\(suffix)"
        let clientMessageID = "message_guidance_lifecycle_\(suffix)"
        let thread = #"{"id":"\#(threadID)","sessionId":"\#(threadID)","preview":"guidance","ephemeral":false,"modelProvider":"openai","createdAt":1780500000,"updatedAt":1780500001,"status":{"type":"active"},"cwd":"\#(project.path)","source":"appServer","threadSource":"user","turns":[{"id":"\#(turnID)","status":"inProgress","items":[]}]}"#
        let config = makeDirectAppServerConfig(
            project: project,
            allowedMethods: [
                "initialize", "initialized", "thread/list", "thread/resume",
                "thread/unsubscribe", "turn/steer"
            ]
        )
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "test-token",
            transportFactory: { transport },
            configProvider: { config }
        )
        let unusedClaudeRuntime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "test-token",
            runtimeProvider: "claude",
            transportFactory: { FakeCodexAppServerTransport() },
            configProvider: { config }
        )
        let bundle = AppServerRuntimeBundle(
            codexRuntime: runtime,
            claudeRuntime: unusedClaudeRuntime
        )
        bundle.routes.remember("codex", for: threadID)

        let pageTask = Task {
            try await runtime.sessionsPage(projectID: project.id, cursor: nil, limit: 20)
        }
        let initialize = try await waitForFakeAppServerRequest(transport, method: "initialize")
        transportResponse(
            transport,
            id: initialize.id,
            result: #"{"userAgent":"fake-codex","platformFamily":"macos"}"#
        )
        let list = try await waitForFakeAppServerRequest(transport, method: "thread/list")
        transportResponse(
            transport,
            id: list.id,
            result: appServerThreadListResult([thread], nextCursor: nil)
        )
        _ = try await pageTask.value

        var socket: MultiRuntimeSessionWebSocketClient? = MultiRuntimeSessionWebSocketClient(bundle: bundle)
        weak var releasedSocket = socket
        var connected = false
        var receivedClientMessageID: ClientMessageID?
        var receivedOutcome: TurnSendOutcome?
        socket?.onStatus = { status in
            if status == .connected {
                connected = true
            }
        }
        socket?.onTurnSendOutcome = { clientMessageID, outcome in
            receivedClientMessageID = clientMessageID
            receivedOutcome = outcome
        }
        socket?.connect(sessionID: threadID)
        let resume = try await waitForFakeAppServerRequest(transport, method: "thread/resume")
        transportResponse(transport, id: resume.id, result: #"{"thread":\#(thread)}"#)
        for _ in 0..<200 where !connected {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(connected)

        XCTAssertTrue(socket?.sendGuidance(
            CodexAppServerTurnPayload(prompt: "继续当前回复"),
            clientMessageID: clientMessageID,
            expectedTurnID: turnID
        ) == true)
        let steer = try await waitForFakeAppServerRequest(transport, method: "turn/steer")

        // 模拟切页释放前台 wrapper；底层 RPC 保持在途，结果仍应送到提交时的 generation handler。
        socket?.disconnect()
        socket = nil
        XCTAssertNil(releasedSocket)

        switch response {
        case .acknowledged:
            transportResponse(transport, id: steer.id, result: #"{}"#)
        case .rejected:
            transportErrorResponse(
                transport,
                id: steer.id,
                code: -32602,
                message: "guidance rejected"
            )
        }
        for _ in 0..<200 where receivedOutcome == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(receivedClientMessageID, clientMessageID)
        switch (response, receivedOutcome) {
        case (.acknowledged, .some(.guidanceAccepted)):
            break
        case (.rejected, .some(.rejected(let message))):
            XCTAssertTrue(message.contains("guidance rejected"))
        default:
            XCTFail("unexpected guidance result: \(String(describing: receivedOutcome))")
        }
        await runtime.shutdownForHostSwitch()
    }
}
