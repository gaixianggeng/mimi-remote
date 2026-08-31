import XCTest
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testCompletedUserProjectionBindsLocalEchoToAuthoritativeTurn() throws {
        var projector = CodexAppServerEventProjector()
        let completedUser = try decodeAppServerNotification(#"{"method":"item/completed","params":{"threadId":"thr_demo","turnId":"turn_demo","item":{"type":"userMessage","id":"user_1","clientId":"client_1","content":[{"type":"text","text":"继续原请求","text_elements":[]}]}}}"#)
        if case .messageCompleted(let message, let meta) = try XCTUnwrap(projector.project(completedUser)) {
            XCTAssertEqual(message.id, "appserver:turn_demo:user_1")
            XCTAssertEqual(message.role, .user)
            XCTAssertEqual(message.content, "继续原请求")
            XCTAssertEqual(message.clientMessageID, "client_1")
            XCTAssertEqual(message.turnID, "turn_demo")
            XCTAssertEqual(meta.clientMessageID, "client_1")
        } else {
            XCTFail("Expected user messageCompleted")
        }

        let imageUser = try decodeAppServerNotification(#"{"method":"item/completed","params":{"threadId":"thr_demo","turnId":"turn_image","item":{"type":"userMessage","id":"user_image","clientId":"client_image","content":[{"type":"image","url":"data:image/png;base64,AA=="}]}}}"#)
        let imageEvent = try XCTUnwrap(projector.project(imageUser))
        guard case .messageCompleted(let imageMessage, let imageMetadata) = imageEvent else {
            return XCTFail("Expected image user messageCompleted")
        }
        let imagePayload = CodexAppServerTurnPayload(input: [
            .image(url: "data:image/png;base64,AA==")
        ])
        let imageStore = ConversationStore()
        imageStore.appendLocalUser(
            imagePayload.previewText,
            sessionID: "thr_demo",
            clientMessageID: "client_image",
            sendStatus: .sending,
            turnPayload: imagePayload
        )
        imageStore.completeMessage(imageMessage, metadata: imageMetadata, fallbackSessionID: "thr_demo")
        let mergedImage = try XCTUnwrap(imageStore.messages(for: "thr_demo").first)
        XCTAssertEqual(mergedImage.turnID, "turn_image")
        XCTAssertEqual(mergedImage.turnPayload, imagePayload)
        XCTAssertEqual(mergedImage.content, imagePayload.previewText)
    }

    func testLegacyClaudeSnapshotDeduplicatesConfirmedLocalUserEcho() {
        let localID = UUID()
        let local = ConversationMessage(
            id: localID,
            stableID: "client-confirmed",
            clientMessageID: "client-confirmed",
            role: .user,
            content: "如何",
            createdAt: Date(timeIntervalSince1970: 100),
            sendStatus: .confirmed
        )
        let history = ConversationMessage(
            stableID: "appserver:turn_0:user_0_100",
            turnID: "turn_0",
            itemID: "user_0_100",
            role: .user,
            content: "如何",
            createdAt: Date(timeIntervalSince1970: 102),
            sendStatus: .confirmed
        )

        let result = ConversationTimelineReducer().rebase(
            snapshot: [history],
            current: [local]
        )

        XCTAssertEqual(result.messages.count, 1)
        XCTAssertEqual(result.messages.first?.id, localID)
        XCTAssertEqual(result.messages.first?.stableID, history.stableID)
        XCTAssertEqual(result.messages.first?.clientMessageID, "client-confirmed")
    }

    func testLegacyClaudeFallbackDoesNotMergeConfirmedHistoryWithoutLocalClientID() {
        let local = ConversationMessage(
            role: .user,
            content: "重复发送",
            createdAt: Date(timeIntervalSince1970: 100),
            sendStatus: .confirmed
        )
        let history = ConversationMessage(
            stableID: "appserver:turn_1:user_1_101",
            turnID: "turn_1",
            itemID: "user_1_101",
            role: .user,
            content: "重复发送",
            createdAt: Date(timeIntervalSince1970: 101),
            sendStatus: .confirmed
        )

        let result = ConversationTimelineReducer().rebase(
            snapshot: [history],
            current: [local]
        )

        XCTAssertEqual(result.messages.count, 2)
    }

    func testTargetThreadSnapshotRebaseKeepsLivePlanAtFirstSeenSlot() {
        let store = ConversationStore()
        let sessionID = "019f7454-64e2-7f70-8208-21291af45ea6"
        let turnID = "019f745b-c22c-7920-be01-936112fe021c"

        func complete(
            id: String,
            itemID: String,
            role: MessageRole,
            kind: MessageKind,
            content: String,
            seq: EventSequence,
            createdAt: TimeInterval
        ) {
            store.completeMessage(
                AgentMessage(
                    id: id,
                    sessionID: sessionID,
                    turnID: turnID,
                    itemID: itemID,
                    role: role,
                    kind: kind,
                    content: content,
                    createdAt: Date(timeIntervalSince1970: createdAt),
                    seq: seq,
                    revision: Int(seq),
                    sendStatus: .confirmed
                ),
                metadata: AgentEventMetadata(
                    seq: seq,
                    sessionID: sessionID,
                    turnID: turnID,
                    itemID: itemID,
                    messageID: id,
                    clientMessageID: nil,
                    revision: Int(seq),
                    createdAt: Date(timeIntervalSince1970: createdAt)
                ),
                fallbackSessionID: sessionID
            )
        }

        complete(id: "live-commentary-1", itemID: "msg-commentary-1", role: .assistant, kind: .commentary, content: "先检查服务和日志。", seq: 1, createdAt: 30)
        complete(id: "live-turn-plan", itemID: "turn-plan", role: .system, kind: .plan, content: "最小修复 → 测试 → 发布", seq: 2, createdAt: 33)
        complete(id: "live-commentary-2", itemID: "msg-commentary-2", role: .assistant, kind: .commentary, content: "生产发布已成功。", seq: 3, createdAt: 45)
        complete(id: "live-command", itemID: "cmd-find", role: .tool, kind: .commandSummary, content: "命令：find /opt/chat-archive/releases", seq: 4, createdAt: 47)
        complete(id: "live-final", itemID: "msg-final", role: .assistant, kind: .message, content: "已修复并上线。", seq: 5, createdAt: 51)

        // legacy thread/read 不含 turn/plan/updated，并把真实 msg_* 重编号为 item-N；
        // 同时 active turn 的缺失时间都会落在 turn.startedAt 附近。
        store.replaceHistorySnapshot([
            CodexHistoryMessage(id: "history-user", role: "user", content: "修复并发布", createdAt: Date(timeIntervalSince1970: 18), turnID: turnID, itemID: "item-0", timelineOrdinal: 0, turnLifecycle: .completed, isTimestampFallback: true),
            CodexHistoryMessage(id: "history-commentary-1", role: "assistant", kind: .commentary, content: "先检查服务和日志。", createdAt: Date(timeIntervalSince1970: 18.001), turnID: turnID, itemID: "item-1", timelineOrdinal: 1, turnLifecycle: .completed, isTimestampFallback: true),
            CodexHistoryMessage(id: "history-commentary-2", role: "assistant", kind: .commentary, content: "生产发布已成功。", createdAt: Date(timeIntervalSince1970: 18.002), turnID: turnID, itemID: "item-2", timelineOrdinal: 2, turnLifecycle: .completed, isTimestampFallback: true),
            CodexHistoryMessage(id: "history-command", role: "system", kind: .commandSummary, content: "命令：find /opt/chat-archive/releases", createdAt: Date(timeIntervalSince1970: 18.003), turnID: turnID, itemID: "item-3", timelineOrdinal: 3, turnLifecycle: .completed, isTimestampFallback: true),
            CodexHistoryMessage(id: "history-final", role: "assistant", content: "已修复并上线。", createdAt: Date(timeIntervalSince1970: 18.004), turnID: turnID, itemID: "item-4", timelineOrdinal: 4, turnLifecycle: .completed, isTimestampFallback: true)
        ], sessionID: sessionID)

        XCTAssertEqual(
            store.messages(for: sessionID).map(\.content),
            [
                "修复并发布",
                "先检查服务和日志。",
                "最小修复 → 测试 → 发布",
                "生产发布已成功。",
                "命令：find /opt/chat-archive/releases",
                "已修复并上线。"
            ]
        )

        complete(id: "live-turn-plan", itemID: "turn-plan", role: .system, kind: .plan, content: "✓ 最小修复 → ✓ 测试 → ✓ 发布", seq: 6, createdAt: 50)
        let refreshed = store.messages(for: sessionID)
        XCTAssertEqual(refreshed.filter { $0.kind == .plan }.count, 1)
        XCTAssertEqual(refreshed.firstIndex { $0.kind == .plan }, 2, "计划更新必须留在首次出现槽位")
        XCTAssertEqual(refreshed.last?.content, "已修复并上线。")
    }

    func testAmbiguousLegacyAliasesPreserveAllSameTextItems() {
        let store = ConversationStore()
        let sessionID = "thread-ambiguous-alias"
        let turnID = "turn-ambiguous-alias"

        for index in 0..<2 {
            let itemID = "msg-live-\(index)"
            store.completeMessage(
                AgentMessage(
                    id: itemID,
                    sessionID: sessionID,
                    turnID: turnID,
                    itemID: itemID,
                    role: .assistant,
                    kind: .commentary,
                    content: "继续检查。",
                    createdAt: Date(timeIntervalSince1970: TimeInterval(10 + index)),
                    seq: Int64(index + 1),
                    revision: index + 1,
                    sendStatus: .confirmed
                ),
                metadata: AgentEventMetadata(
                    seq: Int64(index + 1),
                    sessionID: sessionID,
                    turnID: turnID,
                    itemID: itemID,
                    messageID: itemID,
                    clientMessageID: nil,
                    revision: index + 1,
                    createdAt: nil
                ),
                fallbackSessionID: sessionID
            )
        }

        store.setHistory((0..<2).map { index in
            CodexHistoryMessage(
                id: "item-\(index)",
                role: "assistant",
                kind: .commentary,
                content: "继续检查。",
                createdAt: Date(timeIntervalSince1970: TimeInterval(20 + index)),
                turnID: turnID,
                itemID: "item-\(index)",
                timelineOrdinal: Int64(index)
            )
        }, sessionID: sessionID)

        XCTAssertEqual(store.messages(for: sessionID).filter { $0.content == "继续检查。" }.count, 4)
    }

    func testExplicitTurnLifecycleControlsProcessCompletionStyle() throws {
        let turnID = "turn-explicit-lifecycle"
        let reasoning = ConversationMessage(
            turnID: turnID,
            itemID: "reasoning",
            role: .system,
            kind: .reasoningSummary,
            content: "正在排查",
            activityPayload: ConversationActivityPayload(
                category: .thinking,
                displayTitle: "正在排查",
                status: "running"
            ),
            turnLifecycle: .inProgress
        )
        let command = ConversationMessage(
            turnID: turnID,
            itemID: "command",
            role: .system,
            kind: .commandSummary,
            content: "运行命令",
            activityPayload: ConversationActivityPayload(
                category: .runCommand,
                displayTitle: "运行命令",
                status: "completed"
            ),
            turnLifecycle: .inProgress
        )
        let final = ConversationMessage(
            turnID: turnID,
            itemID: "final",
            role: .assistant,
            content: "阶段输出",
            sendStatus: .confirmed,
            turnLifecycle: .inProgress
        )

        let runningItems = ConversationTimelineItemBuilder.items(from: [reasoning, command, final])
        guard case .workGroup(let runningWorkGroup) = runningItems.first,
              case .processGroup(let runningGroup) = runningWorkGroup.entries.first else {
            return XCTFail("相邻 reasoning/command 应组成过程组")
        }
        XCTAssertEqual(runningGroup.status, .running, "内层过程组继续反映显式 turn lifecycle")
        XCTAssertEqual(
            runningWorkGroup.status,
            .running,
            "final 开始 streaming 时显式 inProgress 仍应保持外层展开，等待 completed lifecycle 再收口"
        )

        let completedMessages = [reasoning, command, final].map { message -> ConversationMessage in
            var next = message
            next.turnLifecycle = .completed
            return next
        }
        let completedItems = ConversationTimelineItemBuilder.items(from: completedMessages)
        guard case .workGroup(let completedWorkGroup) = completedItems.first,
              case .processGroup(let completedGroup) = completedWorkGroup.entries.first else {
            return XCTFail("完成后仍应保留同一个过程组")
        }
        XCTAssertEqual(completedGroup.status, .completed)
        XCTAssertEqual(completedWorkGroup.status, .completed)

        let legacyMessages = [reasoning, command, final].map { message -> ConversationMessage in
            var next = message
            next.turnLifecycle = nil
            return next
        }
        let legacyItems = ConversationTimelineItemBuilder.items(from: legacyMessages)
        guard case .workGroup(let legacyWorkGroup) = legacyItems.first else {
            return XCTFail("旧 runtime 输入仍应保留外层工作组")
        }
        XCTAssertEqual(
            legacyWorkGroup.status,
            .completed,
            "缺少 lifecycle 的旧 runtime 仍应由 final 兜底完成，不能永久停在运行态"
        )
    }

    func testOrderingConflictFallsBackToFirstSeenSlotsInsteadOfTimestamps() {
        let first = ConversationMessage(
            stableID: "live-a",
            turnID: "turn-cycle",
            itemID: "a",
            role: .assistant,
            kind: .commentary,
            content: "先出现 A",
            createdAt: Date(timeIntervalSince1970: 30)
        )
        let localPlan = ConversationMessage(
            stableID: "local-plan",
            turnID: "turn-cycle",
            itemID: "plan",
            role: .system,
            kind: .plan,
            content: "本地计划",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let second = ConversationMessage(
            stableID: "live-b",
            turnID: "turn-cycle",
            itemID: "b",
            role: .assistant,
            kind: .commentary,
            content: "后出现 B",
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let snapshot = [
            ConversationMessage(stableID: "live-b", turnID: "turn-cycle", itemID: "b", role: .assistant, kind: .commentary, content: "快照 B"),
            ConversationMessage(stableID: "live-a", turnID: "turn-cycle", itemID: "a", role: .assistant, kind: .commentary, content: "快照 A")
        ]

        let result = ConversationTimelineReducer().rebase(
            snapshot: snapshot,
            current: [first, localPlan, second]
        )

        XCTAssertTrue(result.hadOrderingCycle)
        XCTAssertEqual(result.messages.map(\.content), ["快照 A", "本地计划", "快照 B"])
    }

    func testPagedItemsWithSameTurnTimeKeepTimelineOrdinalOrder() {
        let reducer = ConversationTimelineReducer()
        let createdAt = Date(timeIntervalSince1970: 100)
        func item(_ ordinal: Int64) -> ConversationMessage {
            ConversationMessage(
                stableID: "item-\(ordinal)",
                turnID: "turn-paged",
                itemID: "item-\(ordinal)",
                role: .assistant,
                content: "item-\(ordinal)",
                createdAt: createdAt,
                timelineOrdinal: ordinal
            )
        }

        let firstPage = reducer.rebase(snapshot: [item(0), item(1)], current: [])
        let secondPage = reducer.rebase(snapshot: [item(2), item(3)], current: firstPage.messages)

        XCTAssertFalse(secondPage.hadOrderingCycle)
        XCTAssertEqual(secondPage.messages.compactMap(\.timelineOrdinal), [0, 1, 2, 3])
    }

    func testSummaryFinalMovesBehindLaterCanonicalEnrichmentItems() {
        let reducer = ConversationTimelineReducer()
        let turnID = "turn-large-enrichment"
        let completedAt = Date(timeIntervalSince1970: 200)
        let initial = [
            ConversationMessage(
                stableID: "summary-user",
                turnID: turnID,
                itemID: "user-0",
                role: .user,
                content: "请修复消息顺序",
                createdAt: Date(timeIntervalSince1970: 100)
            ),
            ConversationMessage(
                stableID: "final-236",
                turnID: turnID,
                itemID: "final-236",
                role: .assistant,
                content: "已修复并推送",
                createdAt: completedAt
            )
        ]
        let image = ConversationMessage(
            stableID: "image-207",
            turnID: turnID,
            itemID: "image-207",
            role: .assistant,
            content: "![截图](/tmp/result.png)",
            createdAt: completedAt,
            timelineOrdinal: 207
        )

        let afterFirstEnrichment = reducer.rebase(
            snapshot: [image],
            current: initial,
            snapshotOrdering: .incrementalFragments
        )
        XCTAssertEqual(afterFirstEnrichment.messages.map(\.itemID), ["user-0", "image-207", "final-236"])

        let laterActivity = ConversationMessage(
            stableID: "activity-220",
            turnID: turnID,
            itemID: "activity-220",
            role: .system,
            kind: .commandSummary,
            content: "回归测试通过",
            // 无 Item 时间的活动使用 startedAt + ordinal 估算，可能早于此前已显示的图片。
            createdAt: Date(timeIntervalSince1970: 100.220),
            timelineOrdinal: 220
        )
        let canonicalFinal = ConversationMessage(
            stableID: "final-236",
            turnID: turnID,
            itemID: "final-236",
            role: .assistant,
            content: "已修复并推送",
            createdAt: completedAt,
            timelineOrdinal: 236
        )
        let afterSecondEnrichment = reducer.rebase(
            snapshot: [laterActivity, canonicalFinal],
            current: afterFirstEnrichment.messages,
            snapshotOrdering: .incrementalFragments
        )

        XCTAssertFalse(afterSecondEnrichment.hadOrderingCycle)
        XCTAssertEqual(
            afterSecondEnrichment.messages.map(\.itemID),
            ["user-0", "image-207", "activity-220", "final-236"]
        )
        XCTAssertEqual(afterSecondEnrichment.messages.last?.content, "已修复并推送")
    }

    func testTimelineOrdinalDoesNotOrderItemsAcrossTurns() {
        let createdAt = Date(timeIntervalSince1970: 100)
        let current = ConversationMessage(
            stableID: "turn-b-item",
            turnID: "turn-b",
            itemID: "turn-b-item",
            role: .assistant,
            content: "turn B",
            createdAt: createdAt,
            timelineOrdinal: 0
        )
        let snapshot = ConversationMessage(
            stableID: "turn-a-item",
            turnID: "turn-a",
            itemID: "turn-a-item",
            role: .assistant,
            content: "turn A",
            createdAt: createdAt,
            timelineOrdinal: 10
        )

        let result = ConversationTimelineReducer().rebase(snapshot: [snapshot], current: [current])

        XCTAssertEqual(result.messages.map(\.content), ["turn A", "turn B"])
    }

    func testPartialSnapshotMovesInjectedUserAheadOfLaterLiveReplies() {
        let turnID = "turn-guidance-order"
        let clientMessageID = "client-guidance-order"
        let anchor = ConversationMessage(
            stableID: "anchor",
            turnID: turnID,
            itemID: "anchor",
            role: .assistant,
            kind: .commentary,
            content: "先运行测试。",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let firstReply = ConversationMessage(
            stableID: "reply-1",
            turnID: turnID,
            itemID: "reply-1",
            role: .assistant,
            kind: .message,
            content: "还在修改和回归。",
            createdAt: Date(timeIntervalSince1970: 30)
        )
        let secondReply = ConversationMessage(
            stableID: "reply-2",
            turnID: turnID,
            itemID: "reply-2",
            role: .assistant,
            kind: .message,
            content: "又发现一个代次交叉。",
            createdAt: Date(timeIntervalSince1970: 40)
        )
        let localGuidance = ConversationMessage(
            stableID: clientMessageID,
            clientMessageID: clientMessageID,
            role: .user,
            content: "还在修改是么",
            createdAt: Date(timeIntervalSince1970: 20),
            sendStatus: .sent,
            userDelivery: .guided
        )

        // 省流历史可能先确认中途 steer 用户消息，但暂时不带其后的实时回复。
        // 即使当前列表已经错误地把本地回显放在尾部，用户消息也必须按真实发送时间
        // 回到后续回复之前，不能继续显示成“Agent 先回答、用户后提问”。
        let partialSnapshot = [
            ConversationMessage(
                stableID: "anchor",
                turnID: turnID,
                itemID: "anchor",
                role: .assistant,
                kind: .commentary,
                content: "先运行测试。",
                createdAt: Date(timeIntervalSince1970: 10),
                timelineOrdinal: 0,
                isTimestampFallback: true
            ),
            ConversationMessage(
                stableID: "server-guidance",
                clientMessageID: clientMessageID,
                turnID: turnID,
                itemID: "guidance",
                role: .user,
                content: "还在修改是么",
                createdAt: Date(timeIntervalSince1970: 10.001),
                sendStatus: .confirmed,
                timelineOrdinal: 1,
                userDelivery: .injected,
                isTimestampFallback: true
            )
        ]

        let result = ConversationTimelineReducer().rebase(
            snapshot: partialSnapshot,
            current: [anchor, firstReply, secondReply, localGuidance]
        )

        XCTAssertFalse(result.hadOrderingCycle)
        XCTAssertEqual(
            result.messages.map(\.content),
            ["先运行测试。", "还在修改是么", "还在修改和回归。", "又发现一个代次交叉。"]
        )
    }

    func testAnnotatedHistoryMutationAdvancesOnlyWhenTimelineChanges() throws {
        let sessionID = "history-mutation-generation"
        let store = ConversationStore()
        store.activate(profileID: "history-mutation-profile")
        let latest = CodexHistoryMessage(
            id: "history:latest",
            role: "assistant",
            content: "最新文案",
            createdAt: Date(timeIntervalSince1970: 20),
            turnID: "turn-latest",
            itemID: "item-latest"
        )

        store.setHistory([latest], sessionID: sessionID, timelineMutationKind: .enrichment)
        let firstMutation = try XCTUnwrap(store.historyTimelineMutation(for: sessionID))
        XCTAssertEqual(firstMutation.kind, .enrichment)

        store.setHistory([latest], sessionID: sessionID, timelineMutationKind: .enrichment)
        XCTAssertEqual(store.historyTimelineMutation(for: sessionID), firstMutation)

        let earlier = CodexHistoryMessage(
            id: "history:earlier",
            role: "user",
            content: "更早文案",
            createdAt: Date(timeIntervalSince1970: 10),
            turnID: "turn-earlier",
            itemID: "item-earlier"
        )
        store.setHistory(
            [earlier, latest],
            sessionID: sessionID,
            timelineMutationKind: .prepend
        )
        let secondMutation = try XCTUnwrap(store.historyTimelineMutation(for: sessionID))
        XCTAssertEqual(secondMutation.kind, .prepend)
        XCTAssertGreaterThan(secondMutation.generation, firstMutation.generation)
    }

    func testHistoryMergeDoesNotOverwriteNewerLiveContentOrTerminalState() throws {
        let turnID = "turn-live-wins"
        let existing = ConversationMessage(
            stableID: "assistant-live-wins",
            turnID: turnID,
            itemID: "assistant-live-wins",
            role: .assistant,
            content: "实时最终内容",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 30),
            sendStatus: .failed,
            revision: 3,
            turnLifecycle: .interrupted
        )
        let staleHistory = ConversationMessage(
            stableID: "assistant-live-wins",
            turnID: turnID,
            itemID: "assistant-live-wins",
            role: .assistant,
            content: "旧的历史内容",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 40),
            sendStatus: .sent,
            revision: nil,
            turnLifecycle: .completed
        )

        let merged = try XCTUnwrap(ConversationTimelineReducer().rebase(
            snapshot: [staleHistory],
            current: [existing]
        ).messages.first)

        XCTAssertEqual(merged.content, "实时最终内容")
        XCTAssertEqual(merged.revision, 3)
        XCTAssertEqual(merged.sendStatus, .failed)
        XCTAssertEqual(merged.turnLifecycle, .interrupted)
    }

    func testHistoryMergePreservesTerminalActivityWithoutRevisionAgainstNewerRunningSnapshot() throws {
        for revision in [nil, 7] as [ModelRevision?] {
            let existingPayload = ConversationActivityPayload(
                category: .runCommand,
                displayTitle: "运行完成",
                status: "failed",
                outputPreview: "实时终态输出"
            )
            let runningPayload = ConversationActivityPayload(
                category: .runCommand,
                displayTitle: "运行中",
                status: "running"
            )
            let existing = ConversationMessage(
                stableID: "terminal-activity",
                turnID: "turn-terminal-activity",
                itemID: "terminal-activity",
                role: .system,
                kind: .commandSummary,
                content: "实时终态输出",
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 20),
                revision: revision,
                activityPayload: existingPayload
            )
            let staleRunningSnapshot = ConversationMessage(
                stableID: "terminal-activity",
                turnID: "turn-terminal-activity",
                itemID: "terminal-activity",
                role: .system,
                kind: .commandSummary,
                content: "历史运行中输出",
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 30),
                revision: revision,
                activityPayload: runningPayload,
                turnLifecycle: .inProgress
            )

            let merged = try XCTUnwrap(ConversationTimelineReducer().rebase(
                snapshot: [staleRunningSnapshot],
                current: [existing]
            ).messages.first)

            XCTAssertEqual(merged.content, "实时终态输出")
            XCTAssertEqual(merged.activityPayload, existingPayload)
        }
    }

    func testSetHistoryMarksMutationMixedWhenItFlushesPendingLiveDelta() throws {
        let store = ConversationStore()
        let sessionID = "history-and-pending-live"
        let metadata = AgentEventMetadata(
            seq: 1,
            sessionID: sessionID,
            turnID: "turn-live",
            itemID: "item-live",
            messageID: "assistant-live",
            clientMessageID: nil,
            revision: 2,
            createdAt: Date(timeIntervalSince1970: 20)
        )
        store.applyAssistantDelta(
            AgentDelta(text: "实时增量", role: .assistant, kind: .message),
            metadata: metadata,
            fallbackSessionID: sessionID
        )
        store.applyAssistantDelta(
            AgentDelta(text: "继续输出", role: .assistant, kind: .message),
            metadata: AgentEventMetadata(
                seq: 2,
                sessionID: sessionID,
                turnID: "turn-live",
                itemID: "item-live",
                messageID: "assistant-live",
                clientMessageID: nil,
                revision: 3,
                createdAt: Date(timeIntervalSince1970: 21)
            ),
            fallbackSessionID: sessionID
        )

        store.setHistory([
            CodexHistoryMessage(
                id: "history-old",
                role: "user",
                content: "更早内容",
                createdAt: Date(timeIntervalSince1970: 10),
                turnID: "turn-old",
                itemID: "item-old"
            )
        ], sessionID: sessionID, timelineMutationKind: .prepend)

        XCTAssertTrue(try XCTUnwrap(store.historyTimelineMutation(for: sessionID)).includesLiveChange)
        XCTAssertTrue(store.messages(for: sessionID).contains { $0.content == "实时增量继续输出" })
    }

    func testHistoricalTimelineGenerationSeparatesHistoryFromLiveUpdates() {
        XCTAssertTrue(
            ConversationTimelineView.isHistoricalTimelineChange(
                previousGeneration: nil,
                currentGeneration: 1
            )
        )
        XCTAssertTrue(
            ConversationTimelineView.isHistoricalTimelineChange(
                previousGeneration: 1,
                currentGeneration: 2
            )
        )
        XCTAssertFalse(
            ConversationTimelineView.isHistoricalTimelineChange(
                previousGeneration: 2,
                currentGeneration: 2
            )
        )
        XCTAssertFalse(
            ConversationTimelineView.isHistoricalTimelineChange(
                previousGeneration: nil,
                currentGeneration: nil
            )
        )
    }

    func testHistoryPreservedOffsetKeepsAnchorAtOriginalScreenPosition() {
        XCTAssertEqual(
            ConversationTimelineView.historyPreservedOffset(
                currentOffsetY: 400,
                currentAnchorMinY: 150,
                baselineAnchorMinY: 90,
                minimumOffsetY: -20,
                maximumOffsetY: 1_200
            ),
            460,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ConversationTimelineView.historyPreservedOffset(
                currentOffsetY: 1_180,
                currentAnchorMinY: 160,
                baselineAnchorMinY: 90,
                minimumOffsetY: -20,
                maximumOffsetY: 1_200
            ),
            1_200,
            accuracy: 0.001
        )
    }

    func testHistoryScrollCoordinatorCoalescesAndCancelsCorrections() async throws {
        let coordinator = ConversationHistoryScrollCoordinator()
        let anchorID = UUID()
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        coordinator.bind(scrollView: scrollView)
        coordinator.updateAnchorFrame([anchorID], CGRect(x: 0, y: 90, width: 300, height: 40))
        let generation = try XCTUnwrap(coordinator.beginPreservingVisible(sessionID: "session"))
        coordinator.update(metrics: ConversationTimelineScrollMetrics(
            isNearBottom: false,
            contentOffsetY: 400,
            contentHeight: 1_800,
            minimumOffsetY: -20,
            maximumOffsetY: 1_200
        ))
        coordinator.updateAnchorFrame([anchorID], CGRect(x: 0, y: 150, width: 300, height: 40))

        var corrections: [ConversationHistoryAnchorCorrection] = []
        for _ in 0..<3 {
            coordinator.scheduleCorrection(
                expectedGeneration: generation,
                displayedSessionID: "session"
            ) { correction in
                corrections.append(correction)
            }
        }
        for _ in 0..<4 {
            await Task.yield()
        }

        XCTAssertEqual(corrections.count, 1)
        XCTAssertEqual(corrections.first?.baselineAnchorMinY, 90)
        XCTAssertEqual(corrections.first?.currentAnchorMinY, 150)

        coordinator.updateAnchorFrame([anchorID], CGRect(x: 0, y: 180, width: 300, height: 40))
        coordinator.scheduleCorrection(
            expectedGeneration: generation,
            displayedSessionID: "session"
        ) { correction in
            corrections.append(correction)
        }
        coordinator.cancelPreservation()
        for _ in 0..<4 {
            await Task.yield()
        }

        XCTAssertEqual(corrections.count, 1, "取消阅读锚点后，迟到布局不得再次写入 offset")
    }

    func testHistoryScrollCoordinatorUsesVisibleRawMessageAndIgnoresUnrelatedHeightGrowth() throws {
        let coordinator = ConversationHistoryScrollCoordinator()
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        coordinator.bind(scrollView: scrollView)
        let staleID = UUID()
        let visibleID = UUID()
        coordinator.updateAnchorFrame([staleID], CGRect(x: 0, y: -900, width: 300, height: 40))
        coordinator.updateAnchorFrame([visibleID], CGRect(x: 0, y: 80, width: 300, height: 40))
        let generation = try XCTUnwrap(coordinator.beginPreservingVisible(sessionID: "session"))
        XCTAssertEqual(coordinator.activeAnchorMessageID, visibleID)

        coordinator.update(metrics: ConversationTimelineScrollMetrics(
            isNearBottom: false,
            contentOffsetY: 400,
            contentHeight: 3_000,
            minimumOffsetY: -20,
            maximumOffsetY: 2_200
        ))
        let correction = try XCTUnwrap(coordinator.correction(
            expectedGeneration: generation,
            displayedSessionID: "session"
        ))
        XCTAssertEqual(correction.baselineAnchorMinY, 80)
        XCTAssertEqual(correction.currentAnchorMinY, 80)
    }

    func testDirectRuntimeMapsThreadReadProcessItemsForTimelineCollapse() async throws {
        let project = AgentProject(id: "proj_processed_history", name: "Processed", path: "/tmp/processed")
        let transport = FakeCodexAppServerTransport()
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "outer-token",
            transportFactory: { transport },
            configProvider: { makeDirectAppServerConfig(project: project) }
        )
        let client = CodexAppServerSessionAPIClient(runtime: runtime)

        let pageTask = Task {
            try await client.messagesPage(sessionID: "thr_processed", before: nil, limit: nil)
        }

        let initializeMessages = try await waitForFakeAppServerMessages(transport, count: 1)
        let initialize = try decodeAppServerRequest(initializeMessages[0])
        XCTAssertEqual(initialize.method, "initialize")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: initialize.id)),"result":{"userAgent":"fake-codex","platformFamily":"macos"}}"#)

        let readMessages = try await waitForFakeAppServerMessages(transport, count: 3)
        let read = try decodeAppServerRequest(readMessages[2])
        XCTAssertEqual(read.method, "thread/read")
        transport.enqueue(#"{"id":\#(try jsonFragment(for: read.id)),"result":{"thread":{"id":"thr_processed","sessionId":"thr_processed","preview":"调用子 agent 讲个笑话","ephemeral":false,"modelProvider":"openai","createdAt":1780490100,"updatedAt":1780490134,"status":{"type":"idle"},"path":null,"cwd":"/tmp/processed","cliVersion":"0.0.0","source":"appServer","threadSource":"user","name":"processed","turns":[{"id":"turn_processed","startedAt":1780490100,"completedAt":1780490134,"itemsView":"full","status":"completed","error":null,"items":[{"type":"userMessage","id":"user_processed","clientId":"client_processed","content":[{"type":"text","text":"调用子 agent 讲个笑话"}]},{"type":"agentMessage","id":"commentary_processed","text":"我先调用一个子 agent。","phase":"commentary","memoryCitation":null},{"type":"plan","id":"plan_processed","text":"让子 agent 生成一个短笑话。"},{"type":"reasoning","id":"reasoning_processed","summary":["确认请求要讲笑话","准备生成最终笑话"],"content":[]},{"type":"commandExecution","id":"cmd_processed","command":"echo joke","cwd":"/tmp/processed","processId":null,"source":"exec","status":"completed","commandActions":[],"aggregatedOutput":"ok","exitCode":0,"durationMs":1000},{"type":"agentMessage","id":"assistant_processed","text":"程序员相亲，对方问：你会浪漫吗？","phase":"final_answer","memoryCitation":null}]}]}}}"#)

        let page = try await pageTask.value
        let messages = try await fullyLoadedHistoryMessages(
            from: page,
            sessionID: "thr_processed",
            client: client
        )
        XCTAssertEqual(messages.map(\.role), ["user", "assistant", "system", "system", "system", "assistant"])
        XCTAssertEqual(messages.map(\.kind), [.message, .commentary, .plan, .reasoningSummary, .commandSummary, .message])
        XCTAssertEqual(messages.last?.createdAt, Date(timeIntervalSince1970: 1780490134))
        XCTAssertEqual(messages.first { $0.itemID == "reasoning_processed" }?.activityPayload?.subtitle, "准备生成最终笑话")
        let historyCommand = try XCTUnwrap(messages.first { $0.itemID == "cmd_processed" })
        XCTAssertEqual(historyCommand.activityPayload?.category, .runCommand)
        XCTAssertEqual(historyCommand.activityPayload?.displayTitle, "运行 echo joke")

        var projector = CodexAppServerEventProjector()
        let liveCommand = try decodeAppServerNotification(#"{"method":"item/completed","params":{"threadId":"thr_processed","turnId":"turn_processed","item":{"type":"commandExecution","id":"cmd_processed","command":"echo joke","cwd":"/tmp/processed","processId":null,"source":"exec","status":"completed","commandActions":[],"aggregatedOutput":"ok","exitCode":0,"durationMs":1000}}}"#)
        if case .processItemCompleted(let liveMessage, _, _) = try XCTUnwrap(projector.project(liveCommand)) {
            XCTAssertEqual(liveMessage.content, historyCommand.content)
            XCTAssertEqual(liveMessage.activityPayload, historyCommand.activityPayload)
        } else {
            XCTFail("Expected live command process item")
        }

        let conversationStore = ConversationStore()
        conversationStore.setHistory(messages, sessionID: "thr_processed")
        let items = ConversationTimelineItemBuilder.items(from: conversationStore.messages(for: "thr_processed"))

        XCTAssertEqual(items.count, 5)
        guard case .message(let commentary) = items[1] else {
            return XCTFail("commentary 应保持完整正文")
        }
        XCTAssertEqual(commentary.itemID, "commentary_processed")
        XCTAssertEqual(commentary.kind, .commentary)
        guard case .message(let plan) = items[2] else {
            return XCTFail("plan 应保留在服务端 source order 中")
        }
        XCTAssertEqual(plan.kind, .plan)
        XCTAssertEqual(plan.content, "让子 agent 生成一个短笑话。")
        guard case .workGroup(let workGroup) = items[3],
              case .processGroup(let processGroup) = workGroup.entries.first else {
            return XCTFail("真实 reasoning 与后续命令应合并为可折叠阶段")
        }
        XCTAssertEqual(processGroup.header.itemID, "reasoning_processed")
        XCTAssertEqual(processGroup.activities.map(\.itemID), ["cmd_processed"])
        guard case .message(let final) = items[4] else {
            return XCTFail("最终 assistant 应保持独立展开")
        }
        XCTAssertEqual(final.role, .assistant)
        XCTAssertEqual(final.content, "程序员相亲，对方问：你会浪漫吗？")
    }
}
