import XCTest
@testable import MimiRemote

final class ConversationProcessGrouperTests: XCTestCase {
    func testBuilderGroupsReasoningAndFollowingActivitiesWithStableIdentity() throws {
        let reasoning = makeReasoning(id: "reasoning-1", turnID: "turn-1", text: "先检查实现，再完成修改。")
        let command = makeActivity(
            id: "command-1",
            turnID: "turn-1",
            kind: .commandSummary,
            payload: ConversationActivityPayload(
                category: .runCommand,
                displayTitle: "运行 xcodebuild test",
                status: "completed",
                command: "xcodebuild test"
            )
        )
        let file = makeActivity(
            id: "file-1",
            turnID: "turn-1",
            kind: .fileChangeSummary,
            payload: ConversationActivityPayload(
                category: .editFile,
                displayTitle: "修改 ConversationView.swift",
                status: "completed",
                filePaths: ["ConversationView.swift"]
            )
        )

        let activeItems = ConversationTimelineItemBuilder.items(from: [reasoning, command])
        let activeWorkGroup = try workGroup(in: activeItems, at: 0)
        let activeGroup = try processGroup(in: activeWorkGroup.entries, at: 0)
        XCTAssertEqual(activeGroup.title, "先检查实现，再完成修改。")
        XCTAssertEqual(activeGroup.activities.map(\.stableID), ["command-1"])
        XCTAssertEqual(activeWorkGroup.status, .running)

        let completedItems = ConversationTimelineItemBuilder.items(from: [
            reasoning,
            command,
            file,
            makeAssistant(id: "assistant-1", turnID: "turn-1")
        ])
        let completedWorkGroup = try workGroup(in: completedItems, at: 0)
        let completedGroup = try processGroup(in: completedWorkGroup.entries, at: 0)
        XCTAssertEqual(completedWorkGroup.id, activeWorkGroup.id)
        XCTAssertEqual(completedGroup.id, activeGroup.id)
        XCTAssertEqual(completedGroup.activities.map(\.stableID), ["command-1", "file-1"])
        XCTAssertEqual(completedWorkGroup.status, .completed)
        XCTAssertEqual(completedItems.count, 2)
    }

    func testRepeatedLinearQueriesFoldButKeepEveryExpandedActionAndStatus() throws {
        let turnID = "turn-linear-queries"
        let reasoning = makeReasoning(id: "reasoning-linear", turnID: turnID, text: "核对 Linear 账本")
        let tools = try [
            ("linear-list-1", "list_issues", "completed"),
            ("linear-list-2", "list_issues", "failed"),
            ("linear-list-3", "list_issues", "timed_out"),
        ].map { entry in
            let (id, tool, status) = entry
            let payload = try XCTUnwrap(ConversationActivityPayload(item: [
                "type": .string("mcpToolCall"),
                "id": .string(id),
                "server": .string("linear"),
                "tool": .string(tool),
                "status": .string(status),
            ]))
            return makeActivity(
                id: id,
                turnID: turnID,
                kind: .commandSummary,
                payload: payload
            )
        }

        let items = ConversationTimelineItemBuilder.items(from: [
            reasoning,
            tools[0],
            tools[1],
            tools[2],
            makeAssistant(id: "linear-final", turnID: turnID),
        ])

        let workGroup = try workGroup(in: items, at: 0)
        let processGroup = try processGroup(in: workGroup.entries, at: 0)
        XCTAssertEqual(processGroup.activities.count, 3, "折叠只改变容器，不合并或丢弃重复查询")
        XCTAssertEqual(
            processGroup.activities.compactMap(\.activityPayload?.displayTitle),
            Array(repeating: L10n.text("ui.query_linear_issues"), count: 3)
        )
        XCTAssertEqual(
            processGroup.activities.compactMap(\.activityPayload?.displayStatusText),
            [
                L10n.text("ui.completed_status"),
                L10n.text("ui.failed_status"),
                L10n.text("ui.timed_out_status"),
            ]
        )
    }

    func testCommentaryAndCommandFormOuterWorkGroupInSourceOrder() throws {
        let commentary = ConversationMessage(
            stableID: "commentary-1",
            turnID: "turn-commentary",
            role: .assistant,
            kind: .commentary,
            content: "我先检查上下文。",
            sendStatus: .confirmed
        )
        let command = makeActivity(
            id: "command-commentary",
            turnID: "turn-commentary",
            kind: .commandSummary,
            payload: ConversationActivityPayload(
                category: .runCommand,
                displayTitle: "运行 git status",
                status: "completed",
                command: "git status"
            )
        )

        let items = ConversationTimelineItemBuilder.items(from: [commentary, command])

        let group = try workGroup(in: items, at: 0)
        XCTAssertEqual(group.entries.count, 2)
        guard case .commentary(let visibleCommentary) = group.entries[0],
              case .activityBatch(let visibleCommands) = group.entries[1] else {
            return XCTFail("外层组必须按 commentary→activity 保留原始顺序")
        }
        XCTAssertEqual(visibleCommands.messages.map(\.stableID), ["command-commentary"])
        XCTAssertEqual(visibleCommentary.kind, .commentary)
    }

    func testLatestReasoningUpdatesSingleGroupWithoutChangingIdentity() throws {
        let firstReasoning = makeReasoning(id: "reasoning-a", turnID: "turn-a", text: "先定位问题")
        let firstCommand = makeActivity(
            id: "command-a",
            turnID: "turn-a",
            kind: .commandSummary,
            payload: ConversationActivityPayload(category: .runCommand, displayTitle: "运行 rg", status: "completed")
        )
        let secondReasoning = makeReasoning(id: "reasoning-b", turnID: "turn-a", text: "再验证修复")
        let secondCommand = makeActivity(
            id: "command-b",
            turnID: "turn-a",
            kind: .commandSummary,
            payload: ConversationActivityPayload(category: .runCommand, displayTitle: "运行测试", status: "completed")
        )

        let firstItems = ConversationTimelineItemBuilder.items(from: [firstReasoning, firstCommand])
        let firstWorkGroup = try workGroup(in: firstItems, at: 0)
        let firstGroup = try processGroup(in: firstWorkGroup.entries, at: 0)

        let items = ConversationTimelineItemBuilder.items(from: [
            firstReasoning,
            firstCommand,
            secondReasoning,
            secondCommand
        ])

        let updatedWorkGroup = try workGroup(in: items, at: 0)
        let updatedGroup = try processGroup(in: updatedWorkGroup.entries, at: 0)
        XCTAssertEqual(updatedWorkGroup.id, firstWorkGroup.id)
        XCTAssertEqual(updatedGroup.id, firstGroup.id)
        XCTAssertEqual(updatedGroup.title, "再验证修复")
        XCTAssertEqual(updatedGroup.activities.map(\.stableID), ["command-a", "command-b"])
    }

    func testBuilderDoesNotGroupAcrossTurnsOrCreateEmptyGroup() {
        let reasoning = makeReasoning(id: "reasoning-turn-a", turnID: "turn-a", text: "检查 A")
        let otherTurnCommand = makeActivity(
            id: "command-turn-b",
            turnID: "turn-b",
            kind: .commandSummary,
            payload: ConversationActivityPayload(category: .runCommand, displayTitle: "运行 B", status: "completed")
        )

        let items = ConversationTimelineItemBuilder.items(from: [reasoning, otherTurnCommand])

        let group = try? workGroup(in: items, at: 0)
        guard let group,
              case .activityBatch(let standaloneCommand) = group.entries.first else {
            return XCTFail("跨 turn 命令应进入自己的外层工作组")
        }
        XCTAssertEqual(standaloneCommand.messages.map(\.stableID), ["command-turn-b"])
    }

    func testBuilderKeepsLargeAlternatingTimelineSemanticsAndCachesTailID() {
        var messages: [ConversationMessage] = []
        messages.reserveCapacity(1_500)
        for index in 0..<500 {
            let turnID = "turn-linear-\(index)"
            messages.append(makeReasoning(id: "reasoning-linear-\(index)", turnID: turnID, text: "检查 \(index)"))
            messages.append(makeActivity(
                id: "command-linear-\(index)",
                turnID: turnID,
                kind: .commandSummary,
                payload: ConversationActivityPayload(
                    category: .runCommand,
                    displayTitle: "运行 \(index)",
                    status: "completed"
                )
            ))
            messages.append(makeAssistant(id: "assistant-linear-\(index)", turnID: turnID))
        }

        let cache = ConversationTimelineItemCache()
        let snapshot = cache.snapshot(from: messages)

        // 每个 turn 线性投影成一个 work group + 一个 final，没有跨 turn 吞并。
        XCTAssertEqual(snapshot.rows.count, 1_000)
        XCTAssertEqual(snapshot.rows.filter {
            if case .workGroup = $0 { return true }
            return false
        }.count, 500)
        XCTAssertEqual(snapshot.tail?.rowID, snapshot.rows.last?.id)
        XCTAssertEqual(cache.snapshot(from: messages).tail?.rowID, snapshot.tail?.rowID)
    }

    func testResolvedInteractionCanJoinGroupButPendingInteractionEndsIt() {
        let reasoning = makeReasoning(id: "reasoning-input", turnID: "turn-input", text: "等待确认后继续")
        let command = makeActivity(
            id: "command-input",
            turnID: "turn-input",
            kind: .commandSummary,
            payload: ConversationActivityPayload(category: .runCommand, displayTitle: "运行迁移", status: "completed")
        )
        let pending = ConversationMessage(
            stableID: "pending-input",
            turnID: "turn-input",
            role: .system,
            kind: .userInput,
            content: "请选择迁移方式",
            sendStatus: .confirmed
        )
        let submitted = ConversationMessage(
            stableID: "submitted-input",
            turnID: "turn-input",
            role: .system,
            kind: .userInput,
            content: "补充信息已提交：直接迁移",
            sendStatus: .confirmed
        )

        let pendingElements = ConversationProcessGrouper.elements(
            from: [reasoning, command, pending],
            turnLifecycle: .inProgress,
            keepsRunningWhileTurnIsActive: true
        )
        guard pendingElements.count == 2,
              case .group = pendingElements[0],
              case .activity(let visiblePending) = pendingElements[1] else {
            return XCTFail("待输入卡必须结束当前组并保持独立")
        }
        XCTAssertEqual(visiblePending.stableID, "pending-input")

        let submittedItems = ConversationTimelineItemBuilder.items(from: [reasoning, command, submitted])
        guard case .workGroup(let workGroup) = submittedItems.first,
              case .processGroup(let group) = workGroup.entries.first else {
            return XCTFail("已提交结果可以作为阶段里程碑收进组内")
        }
        XCTAssertEqual(group.activities.map(\.stableID), ["command-input", "submitted-input"])
    }

    func testCommentaryKeepsAdjacentProcessBatchesInSourceOrder() throws {
        let firstReasoning = makeReasoning(id: "reasoning-first", turnID: "turn-real", text: "先检查登录链路")
        let firstCommand = makeActivity(
            id: "command-first",
            turnID: "turn-real",
            kind: .commandSummary,
            payload: ConversationActivityPayload(category: .runCommand, displayTitle: "查看登录日志", status: "completed")
        )
        let firstCommentary = makeCommentary(
            id: "commentary-first",
            turnID: "turn-real",
            text: "链路已经确认：登录和 ticket 创建都成功。"
        )
        let secondReasoning = makeReasoning(id: "reasoning-second", turnID: "turn-real", text: "检查私钥配置")
        let secondCommand = makeActivity(
            id: "command-second",
            turnID: "turn-real",
            kind: .commandSummary,
            payload: ConversationActivityPayload(category: .runCommand, displayTitle: "读取生产配置", status: "completed")
        )
        let secondCommentary = makeCommentary(
            id: "commentary-second",
            turnID: "turn-real",
            text: "根因已经锁定：线上私钥文件不存在。"
        )
        let trailingReasoning = makeReasoning(id: "reasoning-trailing", turnID: "turn-real", text: "Planning credential validation")
        let trailingCommand = makeActivity(
            id: "command-trailing",
            turnID: "turn-real",
            kind: .commandSummary,
            payload: ConversationActivityPayload(category: .runCommand, displayTitle: "检查备份", status: "running")
        )

        let items = ConversationTimelineItemBuilder.items(from: [
            firstReasoning,
            firstCommand,
            firstCommentary,
            secondReasoning,
            secondCommand,
            secondCommentary,
            trailingReasoning,
            trailingCommand
        ])

        let workGroup = try workGroup(in: items, at: 0)
        XCTAssertEqual(workGroup.entries.count, 5)
        let firstGroup = try processGroup(in: workGroup.entries, at: 0)
        XCTAssertEqual(firstGroup.title, "先检查登录链路")
        XCTAssertEqual(firstGroup.activities.map(\.stableID), ["command-first"])
        guard case .commentary(let firstVisible) = workGroup.entries[1],
              case .commentary(let secondVisible) = workGroup.entries[3] else {
            return XCTFail("commentary 应在外层组中保持正文和 source order")
        }
        XCTAssertEqual(firstVisible.kind, .commentary)
        XCTAssertEqual(secondVisible.kind, .commentary)
        let secondGroup = try processGroup(in: workGroup.entries, at: 2)
        XCTAssertEqual(secondGroup.title, "检查私钥配置")
        XCTAssertEqual(secondGroup.activities.map(\.stableID), ["command-second"])
        let trailingGroup = try processGroup(in: workGroup.entries, at: 4)
        XCTAssertEqual(trailingGroup.title, "Planning credential validation")
        XCTAssertEqual(trailingGroup.activities.map(\.stableID), ["command-trailing"])
    }

    func testBuilderDoesNotMoveTrailingProcessAcrossFinalAssistant() throws {
        let turnID = "turn-final-boundary"
        let firstReasoning = makeReasoning(id: "reasoning-before-final", turnID: turnID, text: "完成主任务")
        let firstCommand = makeActivity(
            id: "command-before-final",
            turnID: turnID,
            kind: .commandSummary,
            payload: ConversationActivityPayload(
                category: .runCommand,
                displayTitle: "运行主测试",
                status: "completed"
            )
        )
        let final = makeAssistant(id: "assistant-final-boundary", turnID: turnID)
        let trailingReasoning = makeReasoning(id: "reasoning-after-final", turnID: turnID, text: "收集补充诊断")
        let trailingCommand = makeActivity(
            id: "command-after-final",
            turnID: turnID,
            kind: .commandSummary,
            payload: ConversationActivityPayload(
                category: .runCommand,
                displayTitle: "读取补充日志",
                status: "completed"
            )
        )

        let items = ConversationTimelineItemBuilder.items(from: [
            firstReasoning,
            firstCommand,
            final,
            trailingReasoning,
            trailingCommand
        ])

        XCTAssertEqual(items.count, 3)
        let firstWorkGroup = try workGroup(in: items, at: 0)
        XCTAssertEqual(
            try processGroup(in: firstWorkGroup.entries, at: 0).activities.map(\.stableID),
            ["command-before-final"]
        )
        guard case .message(let visibleFinal) = items[1] else {
            return XCTFail("最终回答应保持原始位置")
        }
        XCTAssertEqual(visibleFinal.stableID, "assistant-final-boundary")
        let trailingWorkGroup = try workGroup(in: items, at: 2)
        XCTAssertEqual(
            try processGroup(in: trailingWorkGroup.entries, at: 0).activities.map(\.stableID),
            ["command-after-final"]
        )
    }

    func testWorkGroupCollectsCommentaryActivitiesAndStopsBeforeFinal() throws {
        let turnID = "turn-work-stream"
        let first = ConversationMessage(
            stableID: "commentary-work-1",
            turnID: turnID,
            role: .assistant,
            kind: .commentary,
            content: "先检查实现。",
            createdAt: Date(timeIntervalSince1970: 100),
            sendStatus: .confirmed,
            turnLifecycle: .inProgress
        )
        let command = ConversationMessage(
            stableID: "command-work",
            turnID: turnID,
            role: .system,
            kind: .commandSummary,
            content: "运行测试",
            createdAt: Date(timeIntervalSince1970: 104),
            sendStatus: .confirmed,
            activityPayload: ConversationActivityPayload(
                category: .runCommand,
                displayTitle: "运行测试",
                status: "completed"
            ),
            turnLifecycle: .inProgress
        )
        let second = ConversationMessage(
            stableID: "commentary-work-2",
            turnID: turnID,
            role: .assistant,
            kind: .commentary,
            content: "测试通过，准备总结。",
            createdAt: Date(timeIntervalSince1970: 110),
            sendStatus: .confirmed,
            turnLifecycle: .completed
        )
        let final = ConversationMessage(
            stableID: "final-work",
            turnID: turnID,
            role: .assistant,
            content: "已经完成。",
            createdAt: Date(timeIntervalSince1970: 174),
            sendStatus: .confirmed,
            turnLifecycle: .completed
        )

        let items = ConversationTimelineItemBuilder.items(from: [first, command, second, final])

        XCTAssertEqual(items.count, 2)
        let group = try workGroup(in: items, at: 0)
        XCTAssertEqual(group.status, .completed)
        XCTAssertEqual(group.entries.count, 3)
        guard case .commentary(let firstEntry) = group.entries[0],
              case .activityBatch = group.entries[1],
              case .commentary(let lastEntry) = group.entries[2],
              case .message(let visibleFinal) = items[1] else {
            return XCTFail("外层组必须保持 commentary→activity→commentary，final 永远独立")
        }
        XCTAssertEqual(firstEntry.stableID, "commentary-work-1")
        XCTAssertEqual(lastEntry.stableID, "commentary-work-2")
        XCTAssertEqual(visibleFinal.stableID, "final-work")
        XCTAssertEqual(group.startedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(group.endedAt, Date(timeIntervalSince1970: 174))
        XCTAssertEqual(group.duration(at: Date(timeIntervalSince1970: 999)), 74)
    }

    func testWorkGroupResolvesAllFourStatusesWithTurnPrecedence() throws {
        func status(for lifecycle: ConversationTurnLifecycle) throws -> ConversationActivityGroupStatus {
            let message = ConversationMessage(
                stableID: "status-\(lifecycle.rawValue)",
                turnID: "turn-status-\(lifecycle.rawValue)",
                role: .system,
                kind: .commandSummary,
                content: "运行命令",
                createdAt: Date(timeIntervalSince1970: 10),
                sendStatus: .confirmed,
                activityPayload: ConversationActivityPayload(
                    category: .runCommand,
                    displayTitle: "运行命令",
                    status: lifecycle == .inProgress ? "running" : "completed"
                ),
                turnLifecycle: lifecycle
            )
            return try workGroup(
                in: ConversationTimelineItemBuilder.items(from: [message]),
                at: 0
            ).status
        }

        XCTAssertEqual(try status(for: .inProgress), .running)
        XCTAssertEqual(try status(for: .completed), .completed)
        XCTAssertEqual(try status(for: .interrupted), .interrupted)
        XCTAssertEqual(try status(for: .failed), .failed)
    }

    func testHardBoundariesNeverMoveEntriesAcrossPlanPendingErrorOrFinal() throws {
        let turnID = "turn-hard-boundary"
        func command(_ id: String) -> ConversationMessage {
            ConversationMessage(
                stableID: id,
                turnID: turnID,
                role: .system,
                kind: .commandSummary,
                content: id,
                sendStatus: .confirmed,
                activityPayload: ConversationActivityPayload(
                    category: .runCommand,
                    displayTitle: id,
                    status: "completed"
                ),
                turnLifecycle: .inProgress
            )
        }
        let plan = ConversationMessage(
            stableID: "plan-boundary",
            turnID: turnID,
            role: .assistant,
            kind: .plan,
            content: "计划",
            sendStatus: .confirmed
        )
        let pending = ConversationMessage(
            stableID: "pending-boundary",
            turnID: turnID,
            role: .system,
            kind: .approval,
            content: "是否允许？",
            sendStatus: .confirmed
        )
        let error = ConversationMessage(
            stableID: "error-boundary",
            turnID: turnID,
            role: .system,
            kind: .error,
            content: "连接失败",
            sendStatus: .confirmed
        )
        let final = makeAssistant(id: "final-boundary", turnID: turnID)

        let items = ConversationTimelineItemBuilder.items(from: [
            command("command-a"),
            plan,
            command("command-b"),
            pending,
            command("command-c"),
            error,
            command("command-d"),
            final,
            command("command-after-final")
        ])

        XCTAssertEqual(items.count, 9)
        for index in stride(from: 0, through: 8, by: 2) {
            _ = try workGroup(in: items, at: index)
        }
        guard case .message(let visiblePlan) = items[1],
              case .message(let visiblePending) = items[3],
              case .message(let visibleError) = items[5],
              case .message(let visibleFinal) = items[7] else {
            return XCTFail("所有硬边界必须保留原槽位")
        }
        XCTAssertEqual(visiblePlan.kind, .plan)
        XCTAssertEqual(visiblePending.kind, .approval)
        XCTAssertEqual(visibleError.kind, .error)
        XCTAssertEqual(visibleFinal.role, .assistant)
    }

    func testTurnChangeEmptyTurnAndUserMessageAreHardBoundaries() throws {
        let turnA = makeActivity(
            id: "turn-a-command",
            turnID: "turn-a",
            kind: .commandSummary,
            payload: ConversationActivityPayload(category: .runCommand, displayTitle: "A", status: "completed")
        )
        let turnB = makeActivity(
            id: "turn-b-command",
            turnID: "turn-b",
            kind: .commandSummary,
            payload: ConversationActivityPayload(category: .runCommand, displayTitle: "B", status: "completed")
        )
        var emptyTurn = makeActivity(
            id: "empty-turn-command",
            turnID: "placeholder",
            kind: .commandSummary,
            payload: ConversationActivityPayload(category: .runCommand, displayTitle: "无 turn", status: "completed")
        )
        emptyTurn.turnID = ""
        let user = ConversationMessage(
            stableID: "user-boundary",
            turnID: "turn-b",
            role: .user,
            content: "继续",
            sendStatus: .confirmed
        )

        let items = ConversationTimelineItemBuilder.items(from: [turnA, turnB, emptyTurn, user])

        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(try workGroup(in: items, at: 0).turnID, "turn-a")
        XCTAssertEqual(try workGroup(in: items, at: 1).turnID, "turn-b")
        guard case .activityBatch = items[2], case .message(let visibleUser) = items[3] else {
            return XCTFail("空 turn 过程项和用户消息都必须保持边界")
        }
        XCTAssertEqual(visibleUser.role, .user)
    }

    func testWorkGroupIDStaysStableAcrossDeltaAppendAndTerminalTransition() throws {
        let commentaryID = UUID()
        var commentary = ConversationMessage(
            id: commentaryID,
            stableID: "stable-commentary",
            turnID: "turn-stable-work",
            role: .assistant,
            kind: .commentary,
            content: "检查",
            sendStatus: .confirmed,
            turnLifecycle: .inProgress
        )
        var command = makeActivity(
            id: "stable-command",
            turnID: "turn-stable-work",
            kind: .commandSummary,
            payload: ConversationActivityPayload(category: .runCommand, displayTitle: "运行", status: "running")
        )
        command.turnLifecycle = .inProgress
        let running = try workGroup(
            in: ConversationTimelineItemBuilder.items(from: [commentary, command]),
            at: 0
        )

        commentary.appendContent("更多内容")
        commentary.turnLifecycle = .completed
        command.turnLifecycle = .completed
        let completed = try workGroup(
            in: ConversationTimelineItemBuilder.items(from: [
                commentary,
                command,
                makeAssistant(id: "stable-final", turnID: "turn-stable-work")
            ]),
            at: 0
        )

        XCTAssertEqual(running.id, "work:turn-stable-work:\(commentaryID.uuidString)")
        XCTAssertEqual(completed.id, running.id)
        XCTAssertEqual(running.status, .running)
        XCTAssertEqual(completed.status, .completed)
    }

    func testDurationClampsNegativeValuesAndDoesNotInventFallbackTime() {
        let negative = ConversationWorkGroup(
            id: "negative",
            turnID: "turn-duration",
            entries: [],
            status: .completed,
            startedAt: Date(timeIntervalSince1970: 20),
            endedAt: Date(timeIntervalSince1970: 10)
        )
        XCTAssertEqual(negative.duration(), 0)

        let fallbackCommand = ConversationMessage(
            stableID: "fallback-command",
            turnID: "turn-fallback-duration",
            role: .system,
            kind: .commandSummary,
            content: "运行",
            createdAt: Date(timeIntervalSince1970: 10),
            sendStatus: .confirmed,
            activityPayload: ConversationActivityPayload(
                category: .runCommand,
                displayTitle: "运行",
                status: "completed"
            ),
            turnLifecycle: .completed,
            isTimestampFallback: true
        )
        guard case .workGroup(let fallbackGroup) = ConversationTimelineItemBuilder.items(from: [fallbackCommand]).first else {
            return XCTFail("真实活动应形成 work group")
        }
        XCTAssertNil(fallbackGroup.startedAt)
        XCTAssertNil(fallbackGroup.duration())
    }

    func testDurationFindsReliableTimesAfterFallbackEntries() throws {
        let turnID = "turn-reliable-duration"
        let fallbackCommentary = ConversationMessage(
            stableID: "fallback-commentary",
            turnID: turnID,
            role: .assistant,
            kind: .commentary,
            content: "正在准备",
            createdAt: Date(timeIntervalSince1970: 10),
            sendStatus: .confirmed,
            isTimestampFallback: true
        )
        let command = ConversationMessage(
            stableID: "reliable-command",
            turnID: turnID,
            role: .system,
            kind: .commandSummary,
            content: "运行",
            createdAt: Date(timeIntervalSince1970: 20),
            updatedAt: Date(timeIntervalSince1970: 25),
            sendStatus: .confirmed,
            activityPayload: ConversationActivityPayload(
                category: .runCommand,
                displayTitle: "运行",
                status: "completed"
            )
        )
        let fallbackTail = ConversationMessage(
            stableID: "fallback-tail",
            turnID: turnID,
            role: .assistant,
            kind: .commentary,
            content: "准备总结",
            createdAt: Date(timeIntervalSince1970: 30),
            sendStatus: .confirmed,
            isTimestampFallback: true
        )
        let planBoundary = ConversationMessage(
            stableID: "plan-after-work",
            turnID: turnID,
            role: .assistant,
            kind: .plan,
            content: "下一步",
            createdAt: Date(timeIntervalSince1970: 200),
            sendStatus: .confirmed
        )

        let group = try workGroup(
            in: ConversationTimelineItemBuilder.items(from: [
                fallbackCommentary,
                command,
                fallbackTail,
                planBoundary
            ]),
            at: 0
        )

        XCTAssertEqual(group.startedAt, Date(timeIntervalSince1970: 20))
        XCTAssertEqual(group.endedAt, Date(timeIntervalSince1970: 25))
        XCTAssertEqual(group.duration(), 5)
    }

    func testUnrelatedFailedBoundaryDoesNotPollutePreviousWorkGroup() throws {
        let command = ConversationMessage(
            stableID: "previous-turn-command",
            turnID: "turn-previous",
            role: .system,
            kind: .commandSummary,
            content: "完成上一轮",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 12),
            sendStatus: .confirmed,
            activityPayload: ConversationActivityPayload(
                category: .runCommand,
                displayTitle: "完成上一轮",
                status: "completed"
            )
        )
        let failedUser = ConversationMessage(
            stableID: "next-turn-failed-user",
            turnID: "turn-next",
            role: .user,
            content: "发送失败",
            createdAt: Date(timeIntervalSince1970: 100),
            sendStatus: .failed
        )

        let group = try workGroup(
            in: ConversationTimelineItemBuilder.items(from: [command, failedUser]),
            at: 0
        )

        XCTAssertEqual(group.status, .completed)
        XCTAssertEqual(group.endedAt, Date(timeIntervalSince1970: 12))
        XCTAssertEqual(group.duration(), 2)
    }

    func testTimelineCacheInvalidatesWhenLifecycleOrOrdinalChanges() throws {
        var command = makeActivity(
            id: "cache-command",
            turnID: "turn-cache",
            kind: .commandSummary,
            payload: ConversationActivityPayload(category: .runCommand, displayTitle: "运行", status: "running")
        )
        command.turnLifecycle = .inProgress
        command.timelineOrdinal = 1
        let cache = ConversationTimelineItemCache()
        let running = try workGroup(in: cache.snapshot(from: [command]).rows, at: 0)

        command.turnLifecycle = .completed
        let completed = try workGroup(in: cache.snapshot(from: [command]).rows, at: 0)
        XCTAssertEqual(running.status, .running)
        XCTAssertEqual(completed.status, .completed)

        command.timelineOrdinal = 2
        let ordinalSnapshot = cache.snapshot(from: [command])
        guard case .workGroup(let ordinalGroup) = ordinalSnapshot.rows.first,
              case .activityBatch(let batch) = ordinalGroup.entries.first else {
            return XCTFail("ordinal 更新后应重建同一语义快照")
        }
        XCTAssertEqual(batch.messages.first?.timelineOrdinal, 2)
    }

    func testCodexAndClaudeNormalizedMessagesProduceEquivalentWorkProjection() throws {
        func normalized(provider: String) -> [ConversationMessage] {
            let turnID = "\(provider)-turn"
            return [
                makeCommentary(id: "\(provider)-commentary", turnID: turnID, text: "正在检查"),
                makeActivity(
                    id: "\(provider)-command",
                    turnID: turnID,
                    kind: .commandSummary,
                    payload: ConversationActivityPayload(
                        category: .toolCall,
                        displayTitle: "读取文件",
                        status: "completed"
                    )
                ),
                makeAssistant(id: "\(provider)-final", turnID: turnID)
            ]
        }
        func signature(_ group: ConversationWorkGroup) -> [String] {
            group.entries.map { entry in
                switch entry {
                case .commentary:
                    return "commentary"
                case .activity:
                    return "activity"
                case .activityBatch:
                    return "activityBatch"
                case .processGroup:
                    return "processGroup"
                }
            }
        }

        let codex = try workGroup(
            in: ConversationTimelineItemBuilder.items(from: normalized(provider: "codex")),
            at: 0
        )
        let claude = try workGroup(
            in: ConversationTimelineItemBuilder.items(from: normalized(provider: "claude")),
            at: 0
        )
        XCTAssertEqual(signature(codex), signature(claude))
        XCTAssertEqual(codex.status, claude.status)
        XCTAssertEqual(codex.activityCount, claude.activityCount)
    }

    func testRecoverableChildFailureDoesNotFailWholeProcessGroup() throws {
        let reasoning = makeReasoning(id: "reasoning-recovery", turnID: "turn-recovery", text: "继续尝试其他路径")
        let failedCommand = makeActivity(
            id: "command-recovery",
            turnID: "turn-recovery",
            kind: .commandSummary,
            payload: ConversationActivityPayload(
                category: .runCommand,
                displayTitle: "运行候选命令",
                status: "failed",
                exitCode: 127
            )
        )

        let running = ConversationProcessGrouper.elements(
            from: [reasoning, failedCommand],
            turnLifecycle: .inProgress,
            keepsRunningWhileTurnIsActive: true
        )
        guard case .group(let runningGroup) = running.first else {
            return XCTFail("恢复中的失败命令应保留在过程组中")
        }
        XCTAssertEqual(runningGroup.status, .running)
        XCTAssertEqual(runningGroup.failedCount, 1)

        let completed = ConversationProcessGrouper.elements(
            from: [reasoning, failedCommand],
            turnLifecycle: .completed,
            keepsRunningWhileTurnIsActive: false
        )
        guard case .group(let completedGroup) = completed.first else {
            return XCTFail("成功恢复后仍应保留过程组")
        }
        XCTAssertEqual(completedGroup.status, .completed)
        XCTAssertEqual(completedGroup.failedCount, 1)

        var recoveredReasoning = reasoning
        recoveredReasoning.turnLifecycle = .completed
        var recoveredCommand = failedCommand
        recoveredCommand.turnLifecycle = .completed
        let recoveredWorkGroup = try workGroup(
            in: ConversationTimelineItemBuilder.items(from: [
                recoveredReasoning,
                recoveredCommand
            ]),
            at: 0
        )
        XCTAssertEqual(
            recoveredWorkGroup.status,
            .completed,
            "子命令失败但 turn 已恢复完成时，外层工作流不能误报失败"
        )

        let failed = ConversationProcessGrouper.elements(
            from: [reasoning, failedCommand],
            turnLifecycle: .failed,
            keepsRunningWhileTurnIsActive: false
        )
        guard case .group(let failedGroup) = failed.first else {
            return XCTFail("turn 失败后仍应保留过程组")
        }
        XCTAssertEqual(failedGroup.status, .failed)
    }

    func testReasoningSummaryDeltaCarriesThinkingPayload() throws {
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

    func testReasoningBufferClearsWhenTurnCompletes() throws {
        let first = try AgentAPIClient.decoder.decode(
            CodexAppServerNotification.self,
            from: Data(#"{"method":"item/reasoning/summaryTextDelta","params":{"threadId":"thread-clear","turnId":"turn-clear","itemId":"reason-clear","summaryIndex":0,"delta":"旧内容"}}"#.utf8)
        )
        let completed = try AgentAPIClient.decoder.decode(
            CodexAppServerNotification.self,
            from: Data(#"{"method":"turn/completed","params":{"threadId":"thread-clear","turnId":"turn-clear"}}"#.utf8)
        )
        let next = try AgentAPIClient.decoder.decode(
            CodexAppServerNotification.self,
            from: Data(#"{"method":"item/reasoning/summaryTextDelta","params":{"threadId":"thread-clear","turnId":"turn-clear","itemId":"reason-clear","summaryIndex":0,"delta":"新内容"}}"#.utf8)
        )
        var projector = CodexAppServerEventProjector()

        _ = projector.project(first)
        _ = projector.project(completed)
        guard case .messageCompleted(let message, _) = try XCTUnwrap(projector.project(next)) else {
            return XCTFail("完成后下一段 reasoning 仍应正常投影")
        }
        XCTAssertEqual(message.content, "新内容")
    }

    func testLiveAgentMessageKeepsCommentaryKindFromItemStarted() throws {
        let started = try AgentAPIClient.decoder.decode(
            CodexAppServerNotification.self,
            from: Data(#"{"method":"item/started","params":{"threadId":"thread-live","turnId":"turn-live","item":{"type":"agentMessage","id":"commentary-live","text":"","phase":"commentary"}}}"#.utf8)
        )
        let delta = try AgentAPIClient.decoder.decode(
            CodexAppServerNotification.self,
            from: Data(#"{"method":"item/agentMessage/delta","params":{"threadId":"thread-live","turnId":"turn-live","itemId":"commentary-live","delta":"链路已经确认"}}"#.utf8)
        )
        let completed = try AgentAPIClient.decoder.decode(
            CodexAppServerNotification.self,
            from: Data(#"{"method":"item/completed","params":{"threadId":"thread-live","turnId":"turn-live","item":{"type":"agentMessage","id":"commentary-live","text":"链路已经确认。"}}}"#.utf8)
        )
        var projector = CodexAppServerEventProjector()

        XCTAssertNil(projector.project(started))
        guard case .assistantDelta(let projectedDelta, _) = try XCTUnwrap(projector.project(delta)) else {
            return XCTFail("commentary delta 应保持助手正文语义")
        }
        XCTAssertEqual(projectedDelta.kind, .commentary)

        guard case .messageCompleted(let message, _) = try XCTUnwrap(projector.project(completed)) else {
            return XCTFail("commentary completed 应投影为完整助手正文")
        }
        XCTAssertEqual(message.role, .assistant)
        XCTAssertEqual(message.kind, .commentary)
    }

    @MainActor
    func testConversationStoreKeepsCommentaryKindAcrossBufferedDeltas() {
        let store = ConversationStore()
        let sessionID = "commentary-stream-store"
        let firstMetadata = AgentEventMetadata(
            seq: 1,
            sessionID: sessionID,
            turnID: "turn-commentary",
            itemID: "commentary-item",
            messageID: "commentary-item",
            clientMessageID: nil,
            revision: 1,
            createdAt: nil
        )
        let secondMetadata = AgentEventMetadata(
            seq: 2,
            sessionID: sessionID,
            turnID: "turn-commentary",
            itemID: "commentary-item",
            messageID: "commentary-item",
            clientMessageID: nil,
            revision: 2,
            createdAt: nil
        )

        store.applyAssistantDelta(
            AgentDelta(text: "链路已经", role: .assistant, kind: .commentary),
            metadata: firstMetadata,
            fallbackSessionID: sessionID
        )
        store.applyAssistantDelta(
            AgentDelta(text: "确认。", role: .assistant, kind: .commentary),
            metadata: secondMetadata,
            fallbackSessionID: sessionID
        )
        store.resetLiveTranscript(sessionID: sessionID)

        XCTAssertEqual(store.messages(for: sessionID).first?.kind, .commentary)
        XCTAssertEqual(store.messages(for: sessionID).first?.content, "链路已经确认。")
    }

    private func processGroup(
        in entries: [ConversationWorkGroupEntry],
        at index: Int
    ) throws -> ConversationProcessGroup {
        guard case .processGroup(let group) = entries[index] else {
            throw ProcessGroupTestError.expectedGroup
        }
        return group
    }

    private func workGroup(
        in items: [ConversationTimelineItem],
        at index: Int
    ) throws -> ConversationWorkGroup {
        guard case .workGroup(let group) = items[index] else {
            throw ProcessGroupTestError.expectedWorkGroup
        }
        return group
    }

    private func makeReasoning(id: String, turnID: TurnID, text: String) -> ConversationMessage {
        ConversationMessage(
            stableID: id,
            turnID: turnID,
            role: .system,
            kind: .reasoningSummary,
            content: text,
            sendStatus: .confirmed,
            activityPayload: ConversationActivityPayload(
                category: .thinking,
                displayTitle: "推理摘要",
                subtitle: text,
                status: "inProgress"
            )
        )
    }

    private func makeActivity(
        id: String,
        turnID: TurnID,
        kind: MessageKind,
        payload: ConversationActivityPayload
    ) -> ConversationMessage {
        ConversationMessage(
            stableID: id,
            turnID: turnID,
            role: .system,
            kind: kind,
            content: payload.summaryText,
            sendStatus: .confirmed,
            activityPayload: payload
        )
    }

    private func makeCommentary(id: String, turnID: TurnID, text: String) -> ConversationMessage {
        ConversationMessage(
            stableID: id,
            turnID: turnID,
            role: .assistant,
            kind: .commentary,
            content: text,
            sendStatus: .confirmed
        )
    }

    private func makeAssistant(id: String, turnID: TurnID) -> ConversationMessage {
        ConversationMessage(
            stableID: id,
            turnID: turnID,
            role: .assistant,
            content: "已完成。",
            sendStatus: .confirmed
        )
    }
}

private enum ProcessGroupTestError: Error {
    case expectedGroup
    case expectedWorkGroup
}
