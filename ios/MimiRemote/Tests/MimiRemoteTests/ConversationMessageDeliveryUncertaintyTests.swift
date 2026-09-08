import XCTest
@testable import MimiRemote

@MainActor
final class ConversationMessageDeliveryUncertaintyTests: XCTestCase {
    func testDisconnectMarksDirectAndGuidedMessagesUncertainButKeepsQueuedMessage() {
        let store = ConversationStore()
        store.appendLocalUser("direct", sessionID: "thread", clientMessageID: "direct", sendStatus: .sending)
        store.appendLocalUser(
            "guided",
            sessionID: "thread",
            clientMessageID: "guided",
            sendStatus: .sending,
            userDelivery: .guided
        )
        store.appendLocalUser(
            "queued",
            sessionID: "thread",
            clientMessageID: "queued",
            sendStatus: .sending,
            userDelivery: .queued
        )

        store.markSendingUserMessagesUncertain(sessionID: "thread")

        let statuses: [String: MessageSendStatus] = Dictionary(
            uniqueKeysWithValues: store.messages(for: "thread").compactMap {
            guard let clientMessageID = $0.clientMessageID else { return nil }
            return (clientMessageID, $0.sendStatus)
            }
        )
        XCTAssertEqual(statuses["direct"], .uncertain)
        XCTAssertEqual(statuses["guided"], .uncertain)
        XCTAssertEqual(statuses["queued"], .sending)
        XCTAssertTrue(store.hasLocallyUnreconciledUserDelivery(sessionID: "thread"))
    }

    func testUncertainMessageCanReconcileButCannotRegressFromConfirmed() {
        let store = ConversationStore()
        store.appendLocalUser("message", sessionID: "thread", clientMessageID: "message", sendStatus: .sending)

        XCTAssertTrue(store.updateSendStatus(clientMessageID: "message", sessionID: "thread", status: .uncertain))
        XCTAssertTrue(store.updateSendStatus(clientMessageID: "message", sessionID: "thread", status: .confirmed))
        XCTAssertFalse(store.updateSendStatus(clientMessageID: "message", sessionID: "thread", status: .failed))
        XCTAssertEqual(store.messages(for: "thread").first?.sendStatus, .confirmed)
    }

    func testGuidedHistoryRequiresMatchingClientAndTurnPair() {
        let store = ConversationStore()
        store.appendLocalUser(
            "guide",
            sessionID: "thread",
            clientMessageID: "client",
            sendStatus: .uncertain,
            userDelivery: .guided
        )
        XCTAssertTrue(store.bindTurnID("turn-a", clientMessageID: "client", sessionID: "thread"))

        let history = [
            CodexHistoryMessage(
                role: "user",
                content: "guide",
                createdAt: Date(),
                clientMessageID: "client",
                turnID: "turn-b"
            )
        ]
        store.replaceHistorySnapshot(history, sessionID: "thread")
        store.reconcileUncertainGuidedMessages(
            sessionID: "thread",
            authoritativeHistory: history,
            historyIsComplete: false
        )

        let original = store.messages(for: "thread").first { $0.turnID == "turn-a" }
        XCTAssertEqual(original?.sendStatus, .uncertain)
        XCTAssertEqual(original?.turnID, "turn-a")
    }

    func testGuidedMatchingPairConfirmsAndCompleteTerminalAbsenceFails() {
        let store = ConversationStore()
        for (clientID, turnID) in [("matched", "turn-match"), ("missing", "turn-missing")] {
            store.appendLocalUser(
                clientID,
                sessionID: "thread",
                clientMessageID: clientID,
                sendStatus: .uncertain,
                userDelivery: .guided
            )
            XCTAssertTrue(store.bindTurnID(turnID, clientMessageID: clientID, sessionID: "thread"))
        }
        let history = [
            CodexHistoryMessage(
                role: "user",
                content: "matched",
                createdAt: Date(),
                clientMessageID: "matched",
                turnID: "turn-match",
                turnLifecycle: .completed
            ),
            CodexHistoryMessage(
                role: "assistant",
                content: "done",
                createdAt: Date(),
                turnID: "turn-missing",
                turnLifecycle: .completed
            )
        ]
        store.replaceHistorySnapshot(history, sessionID: "thread")
        store.reconcileUncertainGuidedMessages(
            sessionID: "thread",
            authoritativeHistory: history,
            historyIsComplete: true
        )

        let messages = store.messages(for: "thread")
        XCTAssertEqual(messages.first { $0.clientMessageID == "matched" }?.sendStatus, .confirmed)
        XCTAssertEqual(messages.first { $0.clientMessageID == "missing" }?.sendStatus, .failed)
    }

    func testFinalEarlierHistoryPageFailsMissingGuidanceOnlyAfterPaginationCompletes() async {
        let project = makeProject(id: "guided-pagination")
        let session = makeSession(
            id: "guided-pagination-thread",
            projectID: project.id,
            title: "Guided pagination",
            status: "history",
            source: "codex",
            resumeID: "guided-pagination-thread"
        )
        let client = MockSessionStoreClient(
            projects: [project],
            sessions: [session],
            historyPages: [
                session.id: HistoryMessagesPage(
                    messages: [],
                    previousCursor: "older",
                    hasMoreBefore: true,
                    loadMode: .full
                )
            ],
            historyCursorPages: [
                "older": HistoryMessagesPage(
                    messages: [
                        CodexHistoryMessage(
                            role: "assistant",
                            content: "turn completed without the guidance item",
                            createdAt: Date(),
                            turnID: "turn-guided",
                            turnLifecycle: .completed
                        )
                    ],
                    hasMoreBefore: false,
                    loadMode: .full
                )
            ]
        )
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )
        await store.refreshAll(autoAttach: false)
        await store.selectSession(session)
        conversationStore.appendLocalUser(
            "guidance",
            sessionID: session.id,
            clientMessageID: "guided-client",
            sendStatus: .uncertain,
            userDelivery: .guided
        )
        XCTAssertTrue(conversationStore.bindTurnID(
            "turn-guided",
            clientMessageID: "guided-client",
            sessionID: session.id
        ))
        XCTAssertEqual(
            conversationStore.messages(for: session.id).first { $0.clientMessageID == "guided-client" }?.sendStatus,
            .uncertain
        )

        await store.loadEarlierHistoryForSelectedSession()

        XCTAssertEqual(client.requestedMessageCursors, [nil, "older"])
        XCTAssertEqual(
            conversationStore.messages(for: session.id).first { $0.clientMessageID == "guided-client" }?.sendStatus,
            .failed
        )
    }

    func testNonQueuedUncertainOutcomeUsesNeutralStatusInsteadOfErrorBanner() {
        let conversationStore = ConversationStore()
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [], sessions: []) }
        )
        // SessionStore 初始化时会把 ConversationStore 切到当前 Host scope。
        // 测试消息必须在切换后写入，才能和发送结果使用同一个索引。
        conversationStore.appendLocalUser(
            "guidance",
            sessionID: "thread",
            clientMessageID: "client",
            sendStatus: .sending,
            userDelivery: .guided
        )

        store.handleTurnSendOutcome(
            clientMessageID: "client",
            sessionID: "thread",
            outcome: .uncertain(message: "ack lost")
        )

        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.statusMessage, L10n.text("ui.sending_result_pending_confirmation"))
        XCTAssertEqual(conversationStore.messages(for: "thread").first?.sendStatus, .uncertain)
    }
}
