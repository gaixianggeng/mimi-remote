import XCTest
@testable import MimiRemote

final class ConversationTimelineProviderPresentationTests: XCTestCase {
    func testDefaultProvidersCollapseProcessAndKeepFinalAndFileEntry() throws {
        let narrative = makeMessage(id: "progress", turnID: "turn", role: .assistant, kind: .commentary, content: "检查中")
        let read = makeActivity(id: "read", turnID: "turn", category: .runCommand, title: "读取", commandKind: .exploration)
        let edit = makeActivity(id: "edit", turnID: "turn", category: .editFile, title: "修改", content: "full patch")
        let final = makeMessage(id: "final", turnID: "turn", role: .assistant, kind: .message, content: "完成")
        for provider in [ConversationTimelineProvider.codex, .claude] {
            let rows = ConversationTimelineItemBuilder.items(from: [narrative, read, edit, final], provider: provider)
            XCTAssertEqual(rows.count, 3)
            let process = try group(in: rows[0])
            XCTAssertEqual(process.messages.map(\.id), [narrative.id, read.id, edit.id])
            XCTAssertFalse(process.isExpanded)
            XCTAssertEqual(try message(in: rows[1]).id, final.id)
            guard case .fileChanges(let files) = rows[2] else { return XCTFail("需要单一文件结果入口") }
            XCTAssertEqual(files.messageIDs, [edit.id])
            XCTAssertEqual(files.firstActivityID, ConversationTimelineItem.activityID(for: edit))
        }
    }

    func testExpandedProcessKeepsNarrativeOrderWithoutAnotherBatchLevel() throws {
        let first = makeActivity(id: "read", turnID: "turn", category: .runCommand, title: "读取", commandKind: .exploration)
        let progress = makeMessage(id: "progress", turnID: "turn", role: .assistant, kind: .commentary, content: "继续")
        let second = makeActivity(id: "search", turnID: "turn", category: .runCommand, title: "搜索", commandKind: .exploration)
        for provider in [ConversationTimelineProvider.codex, .claude] {
            let rows = ConversationTimelineItemBuilder.items(from: [first, progress, second], provider: provider,
                                                            expandedProcessMessageIDs: [first.id])
            XCTAssertEqual(rows.count, 4)
            XCTAssertTrue(try group(in: rows[0]).isExpanded)
            XCTAssertEqual(try activity(in: rows[1]).id, first.id)
            guard case .processMessage(let visibleProgress) = rows[2] else { return XCTFail("说明保持原始位置") }
            XCTAssertEqual(visibleProgress.id, progress.id)
            XCTAssertEqual(try activity(in: rows[3]).id, second.id)
        }
    }

    func testDetailedModeRestoresManualExpansionAndPreservesEveryAnchor() throws {
        let first = makeActivity(id: "a", turnID: "a", category: .toolCall, title: "读取")
        let second = makeActivity(id: "b", turnID: "b", category: .toolCall, title: "搜索")
        let cache = ConversationTimelineItemCache()
        let manual = cache.snapshot(from: [first, second], expandedProcessMessageIDs: [first.id])
        let detailed = cache.snapshot(from: [first, second], showsDetailedTranscript: true, expandedProcessMessageIDs: [first.id])
        let restored = cache.snapshot(from: [first, second], expandedProcessMessageIDs: [first.id])
        XCTAssertEqual(manual.rows.count, 3)
        XCTAssertEqual(detailed.rows.count, 4)
        XCTAssertEqual(restored.rows, manual.rows)
        XCTAssertTrue(detailed.changes.contains(.presentation))
        XCTAssertTrue(restored.changes.contains(.historyReplacement))
        for snapshot in [manual, detailed, restored] {
            XCTAssertEqual(snapshot.rows.flatMap(\.anchorMessageIDs).sorted(by: { $0.uuidString < $1.uuidString }),
                           [first.id, second.id].sorted(by: { $0.uuidString < $1.uuidString }))
        }
    }

    func testProviderChangePreservesSharedDefaultHierarchy() {
        let read = makeActivity(id: "read", turnID: "turn", category: .runCommand, title: "读取")
        let cache = ConversationTimelineItemCache()
        let codex = cache.snapshot(from: [read], provider: .codex)
        let claude = cache.snapshot(from: [read], provider: .claude)
        XCTAssertEqual(codex.rows, claude.rows)
        XCTAssertTrue(claude.changes.contains(.historyReplacement))
    }

    func testManualExpansionSurvivesCompletionAndEarlierHistoryPrepend() throws {
        var original = makeActivity(id: "running", turnID: "turn", category: .toolCall, title: "执行")
        original.turnLifecycle = .inProgress
        let before = ConversationTimelineItemBuilder.items(from: [original], expandedProcessMessageIDs: [original.id])
        original.turnLifecycle = .completed
        let completed = ConversationTimelineItemBuilder.items(from: [original], expandedProcessMessageIDs: [original.id])
        XCTAssertEqual(before.map(\.id), completed.map(\.id))
        let earlier = makeActivity(id: "earlier", turnID: "turn", category: .thinking, title: "检查")
        let prepended = ConversationTimelineItemBuilder.items(from: [earlier, original], expandedProcessMessageIDs: [original.id])
        XCTAssertTrue(try group(in: prepended[0]).isExpanded)
        XCTAssertEqual(prepended.dropFirst().map(\.stableAnchorMessageID), [earlier.id, original.id])
    }

    func testUnknownTextAndPendingInteractionsStayOutsideProcess() throws {
        let first = makeActivity(id: "first", turnID: "same", category: .toolCall, title: "第一步")
        let pending = makeMessage(id: "approval", turnID: "same", role: .system, kind: .approval, content: "是否批准？")
        let second = makeActivity(id: "second", turnID: "same", category: .toolCall, title: "第二步")
        let unknown = makeMessage(id: "unknown", turnID: "same", role: .assistant, kind: .message, content: "不可猜测成过程")
        let input = makeMessage(id: "input", turnID: "same", role: .system, kind: .userInput, content: "请选择")
        let error = makeMessage(id: "error", turnID: "same", role: .system, kind: .error, content: "连接失败")
        let user = makeMessage(id: "user", turnID: "same", role: .user, kind: .message, content: "继续")
        let third = makeActivity(id: "third", turnID: "same", category: .thinking, title: "继续检查")
        let rows = ConversationTimelineItemBuilder.items(from: [first, pending, second, unknown, input, error, user, third])
        XCTAssertEqual(rows.count, 8)
        XCTAssertEqual(try group(in: rows[0]).messages.map(\.id), [first.id])
        XCTAssertEqual(try group(in: rows[2]).messages.map(\.id), [second.id])
        for (index, expected) in [(1, pending), (3, unknown), (4, input), (5, error), (6, user)] {
            XCTAssertEqual(try message(in: rows[index]).id, expected.id)
        }
        XCTAssertEqual(try group(in: rows[7]).messages.map(\.id), [third.id])
    }

    func testPlainAnswerHasNoEmptyProcessAndLegacyHistoryOnlyGroupsKnownSegments() throws {
        let answer = makeMessage(id: "answer", turnID: "", role: .assistant, kind: .message, content: "你好")
        XCTAssertEqual(ConversationTimelineItemBuilder.items(from: [answer]).count, 1)
        var progress = makeMessage(id: "progress", turnID: "", role: .assistant, kind: .commentary, content: "检查")
        var command = makeActivity(id: "cmd", turnID: "", category: .runCommand, title: "命令")
        progress.turnID = nil
        command.turnID = nil
        let user = makeMessage(id: "user", turnID: "", role: .user, kind: .message, content: "另一个问题")
        let rows = ConversationTimelineItemBuilder.items(from: [progress, command, answer, user, progress])
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(try group(in: rows[0]).messages.count, 2)
        XCTAssertEqual(try group(in: rows[3]).messages.count, 1)
    }

    func testFileEntrySurvivesMissingFinalAndTargetsOnlyThisTurn() throws {
        let first = makeActivity(id: "edit-a", turnID: "a", category: .editFile, title: "修改 A")
        let user = makeMessage(id: "user", turnID: "b", role: .user, kind: .message, content: "下一轮")
        let second = makeActivity(id: "edit-b", turnID: "b", category: .editFile, title: "修改 B")
        let final = makeMessage(id: "final", turnID: "b", role: .assistant, kind: .message, content: "完成")
        let rows = ConversationTimelineItemBuilder.items(from: [first, user, second, final])
        let links = rows.compactMap { item -> ConversationFileChanges? in
            if case .fileChanges(let files) = item { return files }; return nil
        }
        XCTAssertEqual(links.map(\.messageIDs), [[first.id], [second.id]])
        let expanded = ConversationTimelineItemBuilder.items(from: [first, user, second, final], expandedProcessMessageIDs: Set(links[1].messageIDs))
        XCTAssertTrue(expanded.map(\.id).contains(links[1].firstActivityID))
        XCTAssertFalse(try group(in: expanded[0]).isExpanded)
    }

    func testTranscriptPreferenceIsTemporaryAndScopedToComputerAndSession() {
        let a = ScopedSessionID(profileID: "computer-a", sessionID: "same")
        let b = ScopedSessionID(profileID: "computer-b", sessionID: "same")
        var presentation = ConversationTranscriptPresentation()
        XCTAssertFalse(presentation.isEnabled(for: a))
        presentation.setEnabled(true, for: a)
        XCTAssertTrue(presentation.isEnabled(for: a))
        XCTAssertFalse(presentation.isEnabled(for: b))
        XCTAssertFalse(presentation.isEnabled(for: nil))
        presentation.reset()
        XCTAssertFalse(presentation.isEnabled(for: a))
    }

    func testLegacyFileEntryStaysBeforeFollowingKnownTurn() throws {
        var legacy = makeActivity(id: "legacy-edit", turnID: "", category: .editFile, title: "旧修改")
        legacy.turnID = nil
        let next = makeActivity(id: "next", turnID: "next", category: .runCommand, title: "下一轮")
        let rows = ConversationTimelineItemBuilder.items(from: [legacy, next])
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(try group(in: rows[0]).messages.map(\.id), [legacy.id])
        guard case .fileChanges(let files) = rows[1] else { return XCTFail("旧文件入口必须留在旧过程之后") }
        XCTAssertEqual(files.messageIDs, [legacy.id])
        XCTAssertEqual(try group(in: rows[2]).turnID, "next")
    }

    @MainActor
    func testLiveStatusDoesNotAttachToPreviousTurnAfterNewUserInput() {
        let old = makeActivity(id: "old", turnID: "old", category: .toolCall, title: "之前")
        let user = makeMessage(id: "user", turnID: "new", role: .user, kind: .message, content: "新请求")
        let messages = [old, user]
        XCTAssertNil(ConversationTimelineView.liveProcessID(in: ConversationTimelineItemBuilder.items(from: messages),
                                                           messages: messages, activeTurnID: "new"))
        var next = makeActivity(id: "new", turnID: "new", category: .toolCall, title: "运行")
        next.turnLifecycle = .inProgress
        let active = messages + [next]
        let rows = ConversationTimelineItemBuilder.items(from: active)
        XCTAssertEqual(ConversationTimelineView.liveProcessID(in: rows, messages: active, activeTurnID: "new"), rows.last?.id)
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
        let failedGroup = try group(in: XCTUnwrap(failed.first))
        XCTAssertEqual(failedGroup.failedCount, 1)
        let failedMessage = try XCTUnwrap(failedGroup.messages.first)
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

    private func group(in item: ConversationTimelineItem) throws -> ConversationProcessGroup {
        guard case .processGroup(let group) = item else { throw TestError.expectedBatch }
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
