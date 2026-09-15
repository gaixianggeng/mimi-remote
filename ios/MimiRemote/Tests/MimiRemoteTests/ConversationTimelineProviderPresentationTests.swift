import XCTest
@testable import MimiRemote

final class ConversationTimelineProviderPresentationTests: XCTestCase {
    func testCodexKeepsNarrativeOrderAndGroupsOnlyAdjacentExploration() throws {
        let turnID = "codex-turn"
        let messages = [
            makeMessage(id: "commentary", turnID: turnID, role: .assistant, kind: .commentary, content: "先检查文件。"),
            makeActivity(id: "thinking", turnID: turnID, category: .thinking, title: "分析实现", content: "分析实现"),
            makeActivity(id: "read", turnID: turnID, category: .runCommand, title: "读取文件", commandKind: .exploration),
            makeActivity(id: "search", turnID: turnID, category: .runCommand, title: "搜索调用", commandKind: .exploration),
            makeActivity(id: "build", turnID: turnID, category: .runCommand, title: "运行构建", commandKind: .execution),
            makeActivity(id: "file", turnID: turnID, category: .editFile, title: "修改文件", content: "@@ -1 +1 @@\n-old\n+new"),
            makeActivity(id: "tool", turnID: turnID, category: .toolCall, title: "调用工具", content: "tool result"),
            makeMessage(id: "final", turnID: turnID, role: .assistant, kind: .message, content: "已完成。"),
        ]

        let items = ConversationTimelineItemBuilder.items(from: messages, provider: .codex)

        XCTAssertEqual(items.count, 7)
        XCTAssertEqual(try message(in: items[0]).stableID, "commentary")
        XCTAssertEqual(try activity(in: items[1]).stableID, "thinking")
        XCTAssertEqual(try batch(in: items[2]).messages.compactMap(\.stableID), ["read", "search"])
        XCTAssertEqual(try activity(in: items[3]).stableID, "build")
        XCTAssertEqual(try activity(in: items[4]).stableID, "file")
        XCTAssertEqual(try activity(in: items[5]).stableID, "tool")
        XCTAssertEqual(try message(in: items[6]).stableID, "final")
    }

    func testCodexDetailedTranscriptShowsEveryExplorationActivitySeparately() throws {
        let activities = [
            makeActivity(id: "read", turnID: "turn", category: .runCommand, title: "读取", commandKind: .exploration),
            makeActivity(id: "list", turnID: "turn", category: .runCommand, title: "列出", commandKind: .exploration),
            makeActivity(id: "search", turnID: "turn", category: .runCommand, title: "搜索", commandKind: .exploration),
        ]

        let items = ConversationTimelineItemBuilder.items(
            from: activities,
            provider: .codex,
            showsDetailedTranscript: true
        )

        XCTAssertEqual(try items.map { try activity(in: $0) }.compactMap(\.stableID), ["read", "list", "search"])
    }

    func testClaudeKeepsThinkingAndEveryToolCallAsSeparateRows() throws {
        let messages = [
            makeActivity(id: "thinking-1", turnID: "claude-turn", category: .thinking, title: "思考一", content: "思考一"),
            makeActivity(id: "tool-1", turnID: "claude-turn", category: .toolCall, title: "Read", content: "result one"),
            makeActivity(id: "thinking-2", turnID: "claude-turn", category: .thinking, title: "思考二", content: "思考二"),
            makeActivity(id: "tool-2", turnID: "claude-turn", category: .toolCall, title: "Read", content: "result two"),
        ]

        let items = ConversationTimelineItemBuilder.items(from: messages, provider: .claude)

        XCTAssertEqual(try items.map { try activity(in: $0) }.compactMap(\.stableID), [
            "thinking-1", "tool-1", "thinking-2", "tool-2",
        ])
    }

    func testProviderChangeReprojectsSameScopeAsHistoryReplacement() throws {
        let messages = [
            makeActivity(id: "read", turnID: "turn", category: .runCommand, title: "读取", commandKind: .exploration),
            makeActivity(id: "search", turnID: "turn", category: .runCommand, title: "搜索", commandKind: .exploration),
        ]
        let source = ConversationTimelineSourceSnapshot(
            scope: ScopedSessionID(profileID: "profile", sessionID: "session"),
            messages: messages,
            versions: .init()
        )
        let cache = ConversationTimelineItemCache()

        let codex = cache.snapshot(from: source, provider: .codex)
        let claude = cache.snapshot(from: source, provider: .claude)

        XCTAssertEqual(codex.rows.count, 1)
        XCTAssertEqual(claude.rows.count, 2)
        XCTAssertTrue(claude.changes.contains(.historyReplacement))
        XCTAssertEqual(Set(claude.rows.flatMap(\.anchorMessageIDs)), Set(messages.map(\.id)))
    }

    func testDetailedModeReprojectsAsHistoryReplacementAndKeepsAnchors() {
        let messages = [
            makeActivity(id: "read", turnID: "turn", category: .runCommand, title: "读取", commandKind: .exploration),
            makeActivity(id: "search", turnID: "turn", category: .runCommand, title: "搜索", commandKind: .exploration),
        ]
        let source = ConversationTimelineSourceSnapshot(
            scope: ScopedSessionID(profileID: "profile", sessionID: "session"),
            messages: messages,
            versions: .init()
        )
        let cache = ConversationTimelineItemCache()

        _ = cache.snapshot(from: source, provider: .codex)
        let detailed = cache.snapshot(
            from: source,
            provider: .codex,
            showsDetailedTranscript: true
        )

        XCTAssertEqual(detailed.rows.count, 2)
        XCTAssertTrue(detailed.changes.contains(.historyReplacement))
        XCTAssertEqual(Set(detailed.rows.flatMap(\.anchorMessageIDs)), Set(messages.map(\.id)))
    }

    func testExpandedDetailUsesFullContentAndOldHistoryFallsBackToPreview() {
        let full = makeActivity(
            id: "full",
            turnID: "turn",
            category: .runCommand,
            title: "运行",
            content: "full stdout\nfull stderr",
            outputPreview: "short preview"
        )
        let payload = full.activityPayload
        let legacy = ConversationMessage(
            stableID: "legacy",
            turnID: "turn",
            role: .system,
            kind: .commandSummary,
            content: payload?.summaryText ?? "",
            sendStatus: .confirmed,
            activityPayload: payload
        )

        XCTAssertEqual(ConversationActivityPresentationText.fullDetail(for: full), "full stdout\nfull stderr")
        XCTAssertEqual(ConversationActivityPresentationText.fullDetail(for: legacy), "short preview")
        XCTAssertEqual(ConversationActivityPresentationText.compactPreview(for: full), "short preview")
    }

    func testReasoningSelectionUsesSummaryUntilExpandedThenReadsFullContent() {
        let reasoning = makeActivity(
            id: "reasoning",
            turnID: "turn",
            category: .thinking,
            title: "确认状态映射",
            content: "第一段完整推理。\n\n第二段完整推理。"
        )

        XCTAssertEqual(
            ConversationActivityPresentationText.reasoningText(for: reasoning, isExpanded: false),
            "确认状态映射"
        )
        XCTAssertEqual(
            ConversationActivityPresentationText.reasoningText(for: reasoning, isExpanded: true),
            "第一段完整推理。\n\n第二段完整推理。"
        )
    }

    func testClaudeFailureStaysVisibleAndActivityIdentitySurvivesCompletion() throws {
        let messageID = UUID()
        func message(status: String, content: String) -> ConversationMessage {
            let payload = ConversationActivityPayload(
                category: .toolCall,
                displayTitle: "MCP request",
                status: status,
                outputPreview: "short result"
            )
            return ConversationMessage(
                id: messageID,
                stableID: "mcp-call",
                turnID: "claude-turn",
                role: .system,
                kind: .commandSummary,
                content: content,
                sendStatus: .confirmed,
                activityPayload: payload,
                turnLifecycle: status == "running" ? .inProgress : .completed
            )
        }
        let running = ConversationTimelineItemBuilder.items(
            from: [message(status: "running", content: "partial result")],
            provider: .claude
        )
        let failed = ConversationTimelineItemBuilder.items(
            from: [message(status: "failed", content: "permission denied")],
            provider: .claude
        )

        XCTAssertEqual(running.first?.id, failed.first?.id, "用户展开状态依赖稳定 activity ID")
        let failedMessage = try activity(in: XCTUnwrap(failed.first))
        XCTAssertTrue(failedMessage.activityPayload?.isFailure == true)
        XCTAssertEqual(ConversationActivityPresentationText.fullDetail(for: failedMessage), "permission denied")
    }

    func testReasoningDeltaCarriesThinkingPayload() throws {
        let notification = try AgentAPIClient.decoder.decode(
            CodexAppServerNotification.self,
            from: Data(#"{"method":"item/reasoning/summaryTextDelta","params":{"threadId":"thread-live","turnId":"turn-live","itemId":"reasoning-live","summaryIndex":0,"delta":"正在检查实现"}}"#.utf8)
        )
        var projector = CodexAppServerEventProjector()

        guard case .messageCompleted(let message, _) = try XCTUnwrap(projector.project(notification)) else {
            return XCTFail("reasoning delta 应投影为流式系统消息")
        }
        XCTAssertEqual(message.kind, .reasoningSummary)
        XCTAssertEqual(message.activityPayload?.category, .thinking)
        XCTAssertEqual(message.activityPayload?.subtitle, "正在检查实现")
        XCTAssertTrue(message.activityPayload?.isInProgress == true)
    }

    func testLiveAgentMessageKeepsCommentaryKind() throws {
        let started = try AgentAPIClient.decoder.decode(
            CodexAppServerNotification.self,
            from: Data(#"{"method":"item/started","params":{"threadId":"thread-live","turnId":"turn-live","item":{"type":"agentMessage","id":"commentary-live","text":"","phase":"commentary"}}}"#.utf8)
        )
        let delta = try AgentAPIClient.decoder.decode(
            CodexAppServerNotification.self,
            from: Data(#"{"method":"item/agentMessage/delta","params":{"threadId":"thread-live","turnId":"turn-live","itemId":"commentary-live","delta":"链路已经确认"}}"#.utf8)
        )
        var projector = CodexAppServerEventProjector()

        XCTAssertNil(projector.project(started))
        guard case .assistantDelta(let projectedDelta, _) = try XCTUnwrap(projector.project(delta)) else {
            return XCTFail("commentary delta 应保持助手正文语义")
        }
        XCTAssertEqual(projectedDelta.kind, .commentary)
    }

    private func makeActivity(
        id: String,
        turnID: TurnID,
        category: ConversationActivityCategory,
        title: String,
        content: String? = nil,
        outputPreview: String? = nil,
        commandKind: ConversationCommandPresentationKind? = nil
    ) -> ConversationMessage {
        let payload = ConversationActivityPayload(
            category: category,
            displayTitle: title,
            subtitle: category == .thinking ? title : nil,
            status: "completed",
            outputPreview: outputPreview,
            commandPresentationKind: commandKind
        )
        return ConversationMessage(
            stableID: id,
            turnID: turnID,
            role: .system,
            kind: payload.messageKind,
            content: content ?? payload.summaryText,
            sendStatus: .confirmed,
            activityPayload: payload,
            turnLifecycle: .completed
        )
    }

    private func makeMessage(
        id: String,
        turnID: TurnID,
        role: ConversationMessage.Role,
        kind: MessageKind,
        content: String
    ) -> ConversationMessage {
        ConversationMessage(
            stableID: id,
            turnID: turnID,
            role: role,
            kind: kind,
            content: content,
            sendStatus: .confirmed,
            turnLifecycle: .completed
        )
    }

    private func activity(in item: ConversationTimelineItem) throws -> ConversationMessage {
        guard case .activity(let message) = item else { throw TestError.expectedActivity }
        return message
    }

    private func batch(in item: ConversationTimelineItem) throws -> ConversationActivityBatch {
        guard case .activityBatch(let group) = item else { throw TestError.expectedBatch }
        return group
    }

    private func message(in item: ConversationTimelineItem) throws -> ConversationMessage {
        guard case .message(let message) = item else { throw TestError.expectedMessage }
        return message
    }
}

private enum TestError: Error {
    case expectedActivity
    case expectedBatch
    case expectedMessage
}
