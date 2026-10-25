import XCTest
@testable import MimiRemote

@MainActor
final class NativePromptSuggestionTests: XCTestCase {
    private func notification(text: String = "补上回归测试", turnID: String = "turn-1") -> CodexAppServerNotification {
        CodexAppServerNotification(method: "_mimi/turn/promptSuggestion", params: .object([
            "threadId": .string("thread-1"), "turnId": .string(turnID),
            "id": .string("suggestion-1"), "text": .string(text)
        ]))
    }

    private func metadata(turnID: String = "turn-1", lifecycle: ConversationTurnLifecycle? = nil) -> AgentEventMetadata {
        AgentEventMetadata(seq: nil, sessionID: "thread-1", turnID: turnID, itemID: nil,
                           messageID: nil, clientMessageID: nil, revision: nil, createdAt: nil,
                           turnLifecycle: lifecycle)
    }

    private func makeStore(runtime: String = "claude") -> SessionStore {
        let store = SessionStore(appStore: makeIsolatedAppStore(), conversationStore: ConversationStore(),
                                 logStore: LogStore(), clientFactory: { MockSessionStoreClient(projects: [], sessions: []) })
        store.sessions = [makeSession(id: "thread-1", projectID: "project", title: "测试", status: "completed",
                                     source: runtime, runtimeProvider: runtime)]
        store.selectedSessionID = "thread-1"
        store.webSocketStatus = .connected
        return store
    }

    private func lease(_ store: SessionStore) -> HostSessionLease {
        HostSessionLease(hostScope: store.appStore.activeHostScope, sessionID: "thread-1")
    }

    private func completeTurn(_ store: SessionStore, lifecycle: ConversationTurnLifecycle = .completed) {
        store.observeNativePromptSuggestion(.turnStarted(metadata()), lease: lease(store))
        store.observeNativePromptSuggestion(.turnCompleted(metadata(lifecycle: lifecycle)), lease: lease(store))
    }

    private func deliver(_ store: SessionStore, turnID: String = "turn-1") throws {
        var projector = CodexAppServerEventProjector()
        let event = try XCTUnwrap(projector.project(notification(turnID: turnID)))
        store.observeNativePromptSuggestion(event.bindingPromptSuggestion(to: store.webSocketConnectionGeneration), lease: lease(store))
    }

    func testArrivalDoesNotEditOrSendAndAcceptOnlyPrefillsEditableDraft() async throws {
        let store = makeStore()
        let currentLease = lease(store)
        await store.applyRuntimeEvent(.turnStarted(metadata()), lease: currentLease, sendsNotification: false)
        await store.applyRuntimeEvent(.turnCompleted(metadata(lifecycle: .completed)), lease: currentLease, sendsNotification: false)
        var projector = CodexAppServerEventProjector()
        let event = try XCTUnwrap(projector.project(notification())).bindingPromptSuggestion(to: store.webSocketConnectionGeneration)
        await store.applyRuntimeEvent(event, lease: currentLease, sendsNotification: false)

        var composer = ComposerState()
        XCTAssertEqual(composer.draft, "")
        XCTAssertEqual(store.composerDraft(for: .session("thread-1")), .empty)
        XCTAssertEqual(store.currentNativePromptSuggestion?.text, "补上回归测试")
        let messageCount = store.conversationStore.messages(for: "thread-1").count
        let suggestion = try XCTUnwrap(store.takeNativePromptSuggestion(
            id: "suggestion-1", scope: .session("thread-1"), draft: composer.draftSnapshot()
        ))
        XCTAssertTrue(composer.insertNativePromptSuggestion(suggestion))
        XCTAssertEqual(composer.draft, "补上回归测试")
        composer.draft += "，只覆盖当前改动"
        XCTAssertTrue(composer.draft.hasSuffix("，只覆盖当前改动"))
        XCTAssertNil(store.currentNativePromptSuggestion)
        XCTAssertEqual(store.conversationStore.messages(for: "thread-1").count, messageCount)
        XCTAssertTrue(store.selectedQueuedTurns.isEmpty)
        XCTAssertNil(store.selectedSession?.activeTurnID)
    }

    func testTextWhitespaceAndAttachmentsCannotBeOverwritten() throws {
        let suggestion = try XCTUnwrap(AgentPromptSuggestion(params: ["id": .string("s"), "text": .string("建议")]))
        for text in ["已有草稿", " "] {
            let store = makeStore()
            completeTurn(store)
            try deliver(store)
            var composer = ComposerState()
            composer.draft = text
            XCTAssertNil(store.takeNativePromptSuggestion(id: "suggestion-1", scope: .session("thread-1"), draft: composer.draftSnapshot()))
            XCTAssertFalse(composer.insertNativePromptSuggestion(suggestion))
            XCTAssertEqual(composer.draft, text)
        }
        var composer = ComposerState()
        composer.attachments = [.image(url: "data:image/png;base64,AAAA", detail: .auto)]
        XCTAssertFalse(composer.insertNativePromptSuggestion(suggestion))
        XCTAssertEqual(composer.attachments.count, 1)
    }

    func testTypingThenClearingDismissAndDuplicateCompletionNeverResurfaceSuggestion() throws {
        let store = makeStore()
        completeTurn(store)
        store.saveComposerDraft(ComposerDraftSnapshot(text: "输入", attachments: [], voiceDraftNeedsReview: false), for: .session("thread-1"))
        store.saveComposerDraft(.empty, for: .session("thread-1"))
        try deliver(store)
        XCTAssertNil(store.currentNativePromptSuggestion)

        completeTurn(store)
        try deliver(store)
        XCTAssertNotNil(store.currentNativePromptSuggestion)
        store.nativePromptSuggestionState.dismiss()
        store.observeNativePromptSuggestion(.turnCompleted(metadata(lifecycle: .completed)), lease: lease(store))
        try deliver(store)
        XCTAssertNil(store.currentNativePromptSuggestion)
    }

    func testSwitchingSessionOrDisconnectingDropsLateSuggestions() throws {
        for disconnect in [false, true] {
            let store = makeStore()
            completeTurn(store)
            if disconnect {
                store.webSocketStatus = .disconnected
                store.webSocketStatus = .connected
            } else {
                store.selectedSessionID = "thread-other"
                store.selectedSessionID = "thread-1"
            }
            try deliver(store)
            XCTAssertNil(store.currentNativePromptSuggestion)
        }
    }

    func testWrongHostRuntimeAndTurnCannotOfferSuggestion() throws {
        let store = makeStore()
        completeTurn(store)
        try deliver(store, turnID: "old-turn")
        XCTAssertNil(store.currentNativePromptSuggestion)
        var projector = CodexAppServerEventProjector()
        let event = try XCTUnwrap(projector.project(notification()))
        let otherHost = HostScope(profileID: "other-host", installationID: "other-install", generation: 1)
        store.observeNativePromptSuggestion(event, lease: HostSessionLease(hostScope: otherHost, sessionID: "thread-1"))
        XCTAssertNil(store.currentNativePromptSuggestion)
        let codex = makeStore(runtime: "codex")
        completeTurn(codex)
        try deliver(codex)
        XCTAssertNil(codex.currentNativePromptSuggestion)
    }

    func testAlreadyQueuedSuggestionFromPreviousConnectionCannotReappear() async throws {
        let store = makeStore()
        completeTurn(store)
        var projector = CodexAppServerEventProjector()
        let queued = try XCTUnwrap(projector.project(notification()))
            .bindingPromptSuggestion(to: store.webSocketConnectionGeneration)
        store.webSocketConnectionGeneration &+= 1
        await store.applyRuntimeEvent(queued, lease: lease(store), sendsNotification: false)
        XCTAssertNil(store.currentNativePromptSuggestion)
        try deliver(store)
        XCTAssertNotNil(store.currentNativePromptSuggestion, "当前连接的独立事件仍可投影")
    }

    func testFailedInterruptedUnobservedAndSupersededTurnsCannotOfferSuggestion() throws {
        for lifecycle in [ConversationTurnLifecycle.failed, .interrupted] {
            let store = makeStore()
            completeTurn(store, lifecycle: lifecycle)
            try deliver(store)
            XCTAssertNil(store.currentNativePromptSuggestion)
        }
        let store = makeStore()
        store.observeNativePromptSuggestion(.turnCompleted(metadata(lifecycle: .completed)), lease: lease(store))
        try deliver(store)
        XCTAssertNil(store.currentNativePromptSuggestion, "历史完成不能激活建议")
        completeTurn(store)
        store.observeNativePromptSuggestion(.turnStarted(metadata(turnID: "turn-2")), lease: lease(store))
        try deliver(store)
        XCTAssertNil(store.currentNativePromptSuggestion)
    }

    func testMalformedSuggestionsAndAssistantTextAreNotProjected() {
        var projector = CodexAppServerEventProjector()
        for text in [" ", String(repeating: "x", count: 4_097)] {
            XCTAssertNil(projector.project(notification(text: text)))
        }
        XCTAssertNil(projector.project(CodexAppServerNotification(method: "_mimi/turn/promptSuggestion", params: .object([
            "threadId": .string("thread-1"), "text": .string("建议")
        ]))))
        let textEvent = projector.project(CodexAppServerNotification(method: "item/agentMessage/delta", params: .object([
            "threadId": .string("thread-1"), "turnId": .string("turn-1"), "delta": .string("建议你继续")
        ])))
        guard case .assistantDelta = textEvent else { return XCTFail("正文仍应是正文") }
    }

    func testRuntimeNeverBuffersOrRevivesTurnAndRejectsOldConnectionAndCodex() async {
        for runtimeProvider in ["claude", "codex"] {
            let runtime = CodexAppServerSessionRuntime(endpoint: "http://127.0.0.1:8787", token: "test", runtimeProvider: runtimeProvider)
            await runtime.handle(notification())
            let buffered = await runtime.bufferedEvents(sessionID: "thread-1", replayPolicy: .all)
            XCTAssertTrue(buffered.isEmpty)
            let live = await runtime.hasRecentLiveSignal(sessionID: "thread-1")
            XCTAssertFalse(live)
            for sameConnection in [false, true] {
                let mailbox = await runtime.deliverNativeSuggestionForTest(notification(), sameConnection: sameConnection)
                let received = await mailbox.next()
                if runtimeProvider == "claude" && sameConnection {
                    guard case .promptSuggestion = received else { return XCTFail("当前 Claude 连接应收到建议") }
                } else {
                    XCTAssertNil(received)
                }
            }
        }
    }
}

private extension CodexAppServerSessionRuntime {
    func deliverNativeSuggestionForTest(_ notification: CodexAppServerNotification, sameConnection: Bool) -> CodexAppServerEventMailbox {
        let current = CodexAppServerConnection(transport: FakeCodexAppServerTransport(), requestTimeout: 1)
        connection = current
        let mailbox = CodexAppServerEventMailbox(onCancellation: {})
        eventMailboxesBySessionID["thread-1"] = [UUID(): mailbox]
        let source = sameConnection ? current : CodexAppServerConnection(transport: FakeCodexAppServerTransport(), requestTimeout: 1)
        handle(notification, from: source)
        mailbox.finishFromProducer()
        eventMailboxesBySessionID.removeAll()
        return mailbox
    }
}
