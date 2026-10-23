import XCTest
@testable import MimiRemote

@MainActor
final class ConversationTurnHintTests: XCTestCase {
    func testWrapUpParsesTrimmedContentAndCapsActions() throws {
        let hint = try XCTUnwrap(ConversationTurnHint(item: hintItem(
            server: "ccd_turn",
            tool: "wrap_up",
            arguments: [
                "recap": .string("  Finished the fix.  "),
                "ask": .string("  What next?  "),
                "actions": .array([
                    action("Review", "review it"),
                    action("Merge", "merge it"),
                    .object(["label": .string("Missing message")]),
                    action("Release", "release it"),
                    action("Ignored", "ignore it")
                ])
            ]
        )))

        XCTAssertEqual(hint.kind, .nextStep)
        XCTAssertEqual(hint.recap, "Finished the fix.")
        XCTAssertEqual(hint.question, "What next?")
        XCTAssertEqual(hint.actions.map(\.label), ["Review", "Merge", "Release"])
        XCTAssertEqual(hint.plainText, "Finished the fix.\n\nWhat next?")
    }

    func testStartSessionAndLegacySpawnTaskKeepTheirDisplayFields() throws {
        let start = try XCTUnwrap(ConversationTurnHint(item: hintItem(
            server: "ccd_session",
            tool: "start_session",
            arguments: ["title": .string("Follow-up"), "prompt": .string("Continue in a new session")]
        )))
        let spawn = try XCTUnwrap(ConversationTurnHint(item: hintItem(
            server: "ccd_session",
            tool: "spawn_task",
            arguments: [
                "title": .string("Legacy follow-up"),
                "tldr": .string("Short summary"),
                "prompt": .string("Long prompt"),
                "cwd": .string("/private/workspace")
            ]
        )))

        XCTAssertEqual(start.kind, .taskProposal)
        XCTAssertEqual(start.title, "Follow-up")
        XCTAssertEqual(start.brief, "Continue in a new session")
        XCTAssertEqual(spawn.title, "Legacy follow-up")
        XCTAssertEqual(spawn.brief, "Short summary")
        XCTAssertFalse(spawn.plainText.contains("/private/workspace"))
    }

    func testMalformedAndAcceptanceCallsDoNotBecomeCards() {
        XCTAssertNil(ConversationTurnHint(item: hintItem(
            server: "ccd_turn", tool: "wrap_up", arguments: ["actions": .array([])]
        )))
        XCTAssertNil(ConversationTurnHint(item: hintItem(
            server: "ccd_session", tool: "start_session", arguments: ["proposal_id": .string("proposal-1")]
        )))
        XCTAssertNil(ConversationTurnHint(item: hintItem(
            server: "other", tool: "wrap_up", arguments: ["recap": .string("done")]
        )))
        XCTAssertNil(ConversationTurnHint(item: hintItem(
            server: "ccd_turn", tool: "wrap_up", status: "failed", arguments: ["recap": .string("done")]
        )))
        XCTAssertNil(ConversationTurnHint(item: hintItem(
            server: "ccd_session",
            tool: "start_session",
            status: "interrupted",
            arguments: ["title": .string("Follow-up")]
        )))
        var inconsistent = hintItem(
            server: "ccd_turn",
            tool: "wrap_up",
            arguments: ["recap": .string("done")]
        )
        inconsistent["error"] = .object(["message": .string("failed")])
        XCTAssertNil(ConversationTurnHint(item: inconsistent))
        XCTAssertNotNil(ConversationTurnHint(item: hintItem(
            server: "ccd_turn", tool: "wrap_up", status: "inProgress", arguments: ["recap": .string("done")]
        )))
    }

    func testFailedHintKeepsOrdinaryToolFailurePresentation() throws {
        let item = hintItem(
            server: "ccd_turn",
            tool: "wrap_up",
            status: "failed",
            arguments: ["recap": .string("done"), "ask": .string("continue?")]
        )
        let payload = try XCTUnwrap(ConversationActivityPayload(item: item))

        XCTAssertNil(payload.turnHint)
        XCTAssertEqual(payload.status, "failed")
        XCTAssertTrue(payload.isFailure)
        let message = ConversationMessage(
            turnID: "turn-failed",
            itemID: "hint-failed",
            role: .system,
            kind: payload.messageKind,
            content: payload.detailText(from: item),
            activityPayload: payload
        )
        let rows = ConversationTimelineItemBuilder.items(from: [message], showsDetailedTranscript: true)
        guard case .processGroup = try XCTUnwrap(rows.first),
              case .activity = try XCTUnwrap(rows.last) else {
            return XCTFail("failed hint must use the ordinary tool failure timeline")
        }
    }

    func testLiveAndHistoryProjectionProduceTheSameCardPayload() async throws {
        let item = hintItem(
            server: "ccd_turn",
            tool: "wrap_up",
            arguments: [
                "recap": .string("Tests passed"),
                "ask": .string("Open a PR?"),
                "actions": .array([action("Open PR", "open the PR")])
            ]
        )
        var projector = CodexAppServerEventProjector()
        let event = try XCTUnwrap(projector.project(CodexAppServerNotification(
            method: "item/completed",
            params: .object([
                "threadId": .string("session-hint"),
                "turnId": .string("turn-hint"),
                "item": .object(item)
            ])
        )))
        guard case .processItemCompleted(let live, _, _) = event else {
            return XCTFail("turn hint must remain visible as a completed process item")
        }

        let runtime = CodexAppServerSessionRuntime(endpoint: "http://127.0.0.1:8787", token: "test")
        let restored = await runtime.historyMessages(from: [
            "turns": .array([.object([
                "id": .string("turn-hint"),
                "status": .string("completed"),
                "startedAt": .int(100),
                "completedAt": .int(101),
                "items": .array([.object(item)])
            ])])
        ], sessionID: "session-hint", snapshotReadAt: Date(timeIntervalSince1970: 102))
        let history = try XCTUnwrap(restored.first)

        XCTAssertEqual(live.activityPayload, history.activityPayload)
        XCTAssertEqual(live.content, history.content)
        XCTAssertEqual(live.turnID, history.turnID)
        XCTAssertEqual(live.itemID, history.itemID)
        let timelineMessage = ConversationMessage(
            turnID: history.turnID,
            itemID: history.itemID,
            role: .system,
            kind: history.kind,
            content: history.content,
            activityPayload: history.activityPayload
        )
        let rows = ConversationTimelineItemBuilder.items(from: [timelineMessage])
        guard case .message(let cardMessage) = try XCTUnwrap(rows.first) else {
            return XCTFail("turn hint must stay outside the collapsible process group")
        }
        XCTAssertEqual(cardMessage.activityPayload?.turnHint?.question, "Open a PR?")
    }

    func testInteractionRetriesFailureLocksSuccessAndDismissesWithoutSubmitting() {
        var state = ConversationTurnHintInteractionState()
        XCTAssertTrue(state.begin(actionIndex: 0))
        XCTAssertFalse(state.begin(actionIndex: 0))
        state.finish(actionIndex: 0, succeeded: false)
        XCTAssertTrue(state.canSubmit(cardCanAct: true))

        XCTAssertTrue(state.begin(actionIndex: 0))
        state.finish(actionIndex: 0, succeeded: true)
        XCTAssertFalse(state.canSubmit(cardCanAct: true))
        XCTAssertFalse(state.begin(actionIndex: 1))

        var dismissed = ConversationTurnHintInteractionState()
        XCTAssertTrue(dismissed.dismiss())
        XCTAssertTrue(dismissed.isDismissed)
        XCTAssertFalse(dismissed.begin(actionIndex: 0))
    }

    func testActionTargetRejectsHostConnectionSessionTurnAndReadOnlyChanges() throws {
        let host = HostScope(profileID: "host-a", installationID: "install-a", generation: 7)
        let session = makeSession()
        let lease = SessionSelectionLease(
            hostScope: host,
            generation: 11,
            projectID: session.projectID,
            sessionID: session.id
        )
        let message = turnHintMessage(itemID: "hint-1", turnID: "turn-1")
        let context = TurnSubmissionContext(
            hostScope: host,
            selectionLease: lease,
            projectID: session.projectID,
            session: session
        )
        let target = try XCTUnwrap(ConversationTurnHintActionTarget(
            submissionContext: context,
            connectionGeneration: 21,
            message: message
        ))

        XCTAssertTrue(target.isCurrent(
            hostScope: host,
            selectionLease: lease,
            connectionGeneration: 21,
            session: session,
            messages: [message]
        ))
        XCTAssertFalse(target.isCurrent(
            hostScope: HostScope(profileID: "host-a", installationID: "install-a", generation: 8),
            selectionLease: lease,
            connectionGeneration: 21,
            session: session,
            messages: [message]
        ))
        XCTAssertFalse(target.isCurrent(
            hostScope: host,
            selectionLease: SessionSelectionLease(
                hostScope: host, generation: 12, projectID: session.projectID, sessionID: session.id
            ),
            connectionGeneration: 21,
            session: session,
            messages: [message]
        ))
        XCTAssertFalse(target.isCurrent(
            hostScope: host,
            selectionLease: lease,
            connectionGeneration: 22,
            session: session,
            messages: [message]
        ))
        XCTAssertFalse(target.isCurrent(
            hostScope: host,
            selectionLease: lease,
            connectionGeneration: 21,
            session: makeSession(status: "running"),
            messages: [message]
        ))
        XCTAssertFalse(target.isCurrent(
            hostScope: host,
            selectionLease: lease,
            connectionGeneration: 21,
            session: makeSession(canAcceptDirectInput: false),
            messages: [message]
        ))
        XCTAssertFalse(target.isCurrent(
            hostScope: host,
            selectionLease: lease,
            connectionGeneration: 21,
            session: session,
            messages: [message, ConversationMessage(turnID: "turn-2", role: .user, content: "new request")]
        ))
        XCTAssertFalse(target.isCurrent(
            hostScope: host,
            selectionLease: lease,
            connectionGeneration: 21,
            session: session,
            messages: [message, ConversationMessage(turnID: "turn-2", role: .assistant, content: "newer turn")]
        ))
        XCTAssertFalse(target.isCurrent(
            hostScope: host,
            selectionLease: lease,
            connectionGeneration: 21,
            session: session,
            messages: [message, turnHintMessage(itemID: "hint-2", turnID: "turn-2")]
        ))
    }

    private func action(_ label: String, _ message: String) -> CodexAppServerJSONValue {
        .object(["label": .string(label), "message": .string(message)])
    }

    private func hintItem(
        server: String,
        tool: String,
        status: String = "completed",
        arguments: [String: CodexAppServerJSONValue]
    ) -> [String: CodexAppServerJSONValue] {
        [
            "type": .string("mcpToolCall"),
            "id": .string("hint-item"),
            "server": .string(server),
            "tool": .string(tool),
            "status": .string(status),
            "arguments": .object(arguments)
        ]
    }

    private func turnHintMessage(itemID: String, turnID: String) -> ConversationMessage {
        let item = hintItem(
            server: "ccd_turn",
            tool: "wrap_up",
            arguments: ["recap": .string("done"), "ask": .string("continue?")]
        )
        let payload = ConversationActivityPayload(item: item)
        return ConversationMessage(
            turnID: turnID,
            itemID: itemID,
            role: .system,
            kind: payload?.messageKind ?? .commandSummary,
            content: payload?.detailText(from: item) ?? "",
            activityPayload: payload
        )
    }

    private func makeSession(
        status: String = "idle",
        canAcceptDirectInput: Bool = true
    ) -> AgentSession {
        AgentSession(
            id: "session-hint",
            projectID: "project-hint",
            project: "Project",
            dir: "/workspace",
            title: "Hint session",
            status: status,
            source: "claude",
            runtimeProvider: "claude",
            resumeID: "session-hint",
            createdAt: nil,
            updatedAt: nil,
            canAcceptDirectInput: canAcceptDirectInput
        )
    }
}
