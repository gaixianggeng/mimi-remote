import XCTest
@testable import MimiRemote

@MainActor
final class ConversationTimelineSnapshotBoundaryTests: XCTestCase {
    func testSourceSnapshotKeepsScopeMetadataAndMessagesTogether() throws {
        let store = ConversationStore()
        store.activate(profileID: "profile-a")
        store.appendUser("A", sessionID: "thread")

        let scopeA = ScopedSessionID(profileID: "profile-a", sessionID: "thread")
        let scopeB = ScopedSessionID(profileID: "profile-b", sessionID: "thread")
        let sourceA = store.timelineSource(for: scopeA.sessionID)
        store.activate(profileID: scopeB.profileID)
        let sourceB = store.timelineSource(for: scopeB.sessionID)

        XCTAssertEqual(sourceA.scope, scopeA)
        XCTAssertEqual(try XCTUnwrap(sourceA.messages.first).content, "A")
        XCTAssertGreaterThan(sourceA.revision, 0)
        XCTAssertEqual(sourceA.versions.live, sourceA.revision)
        XCTAssertEqual(sourceB.scope, scopeB)
        XCTAssertTrue(sourceB.messages.isEmpty)
        XCTAssertEqual(sourceB.revision, 0)
    }

    func testInitialHistorySnapshotIsReplacementInsteadOfLive() {
        let store = ConversationStore()
        store.activate(profileID: "profile")
        let scope = ScopedSessionID(profileID: "profile", sessionID: "thread")
        store.replaceHistorySnapshot(
            [Self.history(id: "latest", content: "历史", clientMessageID: "history-client")],
            sessionID: scope.sessionID
        )

        let snapshot = ConversationTimelineItemCache().snapshot(from: store.timelineSource(for: scope.sessionID))

        XCTAssertTrue(snapshot.changes.contains(.historyReplacement))
        XCTAssertFalse(snapshot.changes.contains(.live))
        XCTAssertFalse(snapshot.changes.contains(.localSubmission))
        XCTAssertEqual(snapshot.rows.count, 1)
    }

    func testFrozenSnapshotAccumulatesHistoryThenLiveReasons() {
        let store = ConversationStore()
        store.activate(profileID: "profile")
        let scope = ScopedSessionID(profileID: "profile", sessionID: "thread")
        store.replaceHistorySnapshot([Self.history(id: "latest", content: "最新")], sessionID: scope.sessionID)
        let cache = ConversationTimelineItemCache()
        let initial = cache.snapshot(from: store.timelineSource(for: scope.sessionID))

        store.setHistory(
            [
                Self.history(id: "older", content: "更早", createdAt: 1),
                Self.history(id: "latest", content: "最新", createdAt: 2)
            ],
            sessionID: scope.sessionID,
            timelineMutationKind: .prepend
        )
        let frozenAfterHistory = cache.snapshot(
            from: store.timelineSource(for: scope.sessionID),
            suspendingUpdates: true
        )
        store.appendLocalUser(
            "继续",
            sessionID: scope.sessionID,
            clientMessageID: "client-local"
        )
        let frozenAfterLive = cache.snapshot(
            from: store.timelineSource(for: scope.sessionID),
            suspendingUpdates: true
        )
        let thawed = cache.snapshot(from: store.timelineSource(for: scope.sessionID))

        XCTAssertEqual(frozenAfterHistory.revision, initial.revision)
        XCTAssertEqual(frozenAfterLive.revision, initial.revision)
        XCTAssertTrue(thawed.changes.contains(.historyPrepend))
        XCTAssertTrue(thawed.changes.contains(.live))
        XCTAssertTrue(thawed.changes.contains(.localSubmission))
        XCTAssertEqual(thawed.rows.count, 3)
        XCTAssertEqual(thawed.tail?.clientMessageID, "client-local")
        XCTAssertEqual(thawed.tail?.role, .user)
        XCTAssertEqual(thawed.tail?.kind, .message)
    }

    func testHistoryFlushAndMutationRemainCombinedUntilDelivered() {
        let store = ConversationStore()
        store.activate(profileID: "profile")
        let sessionID = "thread"
        let scope = ScopedSessionID(profileID: "profile", sessionID: sessionID)
        store.replaceHistorySnapshot([Self.history(id: "latest", content: "最新")], sessionID: sessionID)
        let cache = ConversationTimelineItemCache()
        _ = cache.snapshot(from: store.timelineSource(for: scope.sessionID))

        store.applyAssistantDelta(
            AgentDelta(text: "实时", role: .assistant, kind: .message),
            metadata: Self.metadata(sequence: 1, revision: 1),
            fallbackSessionID: sessionID
        )
        store.applyAssistantDelta(
            AgentDelta(text: "增量", role: .assistant, kind: .message),
            metadata: Self.metadata(sequence: 2, revision: 2),
            fallbackSessionID: sessionID
        )
        store.setHistory(
            [
                Self.history(id: "older", content: "更早", createdAt: 1),
                Self.history(id: "latest", content: "最新", createdAt: 2)
            ],
            sessionID: sessionID,
            timelineMutationKind: .prepend
        )

        let snapshot = cache.snapshot(from: store.timelineSource(for: scope.sessionID))
        XCTAssertTrue(snapshot.changes.contains(.live))
        XCTAssertTrue(snapshot.changes.contains(.historyPrepend))
        XCTAssertTrue(store.messages(for: sessionID).contains { $0.content == "实时增量" })
    }

    func testLocalSubmissionIntentSurvivesLaterAssistantTail() {
        let store = ConversationStore()
        store.activate(profileID: "profile")
        let sessionID = "thread"
        let scope = ScopedSessionID(profileID: "profile", sessionID: sessionID)
        let cache = ConversationTimelineItemCache()
        _ = cache.snapshot(from: store.timelineSource(for: scope.sessionID))

        store.appendLocalUser("开始", sessionID: sessionID, clientMessageID: "client-local")
        store.applyAssistantDelta(
            AgentDelta(text: "收到", role: .assistant, kind: .message),
            metadata: Self.metadata(sequence: 1, revision: 1),
            fallbackSessionID: sessionID
        )
        let snapshot = cache.snapshot(from: store.timelineSource(for: scope.sessionID))

        XCTAssertTrue(snapshot.changes.contains(.localSubmission))
        XCTAssertEqual(snapshot.tail?.role, .assistant)
        XCTAssertNil(snapshot.tail?.clientMessageID)
    }

    func testResetPublishesEmptyReplacementForSameScope() {
        let store = ConversationStore()
        store.activate(profileID: "profile")
        let sessionID = "thread"
        let scope = ScopedSessionID(profileID: "profile", sessionID: sessionID)
        store.appendLocalUser("开始", sessionID: sessionID, clientMessageID: "client-local")
        let cache = ConversationTimelineItemCache()
        let initial = cache.snapshot(from: store.timelineSource(for: scope.sessionID))

        store.reset(sessionID: sessionID)
        let resetSource = store.timelineSource(for: scope.sessionID)
        let reset = cache.snapshot(from: resetSource)

        XCTAssertEqual(resetSource.revision, 0)
        XCTAssertGreaterThan(reset.revision, initial.revision)
        XCTAssertTrue(reset.rows.isEmpty)
        XCTAssertTrue(reset.changes.contains(.historyReplacement))
    }

    func testFrozenClearThenRewriteCombinesReplacementAndLiveReasons() {
        let store = ConversationStore()
        store.activate(profileID: "profile")
        let sessionID = "thread"
        let scope = ScopedSessionID(profileID: "profile", sessionID: sessionID)
        store.appendLocalUser("旧消息", sessionID: sessionID, clientMessageID: "client-old")
        let cache = ConversationTimelineItemCache()
        let initial = cache.snapshot(from: store.timelineSource(for: scope.sessionID))

        store.reset(sessionID: sessionID)
        let frozenEmpty = cache.snapshot(
            from: store.timelineSource(for: scope.sessionID),
            suspendingUpdates: true
        )
        store.appendLocalUser("新消息", sessionID: sessionID, clientMessageID: "client-new")
        let thawed = cache.snapshot(from: store.timelineSource(for: scope.sessionID))

        XCTAssertEqual(frozenEmpty.revision, initial.revision)
        XCTAssertTrue(thawed.changes.contains(.historyReplacement))
        XCTAssertTrue(thawed.changes.contains(.live))
        XCTAssertTrue(thawed.changes.contains(.localSubmission))
        XCTAssertEqual(thawed.rows.count, 1)
        XCTAssertNotEqual(thawed.tail?.messageID, initial.tail?.messageID)
    }

    func testReasonOnlySourceRevisionPublishesWithoutChangingRows() {
        let scope = ScopedSessionID(profileID: "profile", sessionID: "thread")
        let message = ConversationMessage(role: .assistant, content: "保持不变")
        var initialVersions = ConversationTimelineSourceVersions()
        initialVersions.record(.live, revision: 1)
        let cache = ConversationTimelineItemCache()
        let initial = cache.snapshot(from: ConversationTimelineSourceSnapshot(
            scope: scope,
            messages: [message],
            versions: initialVersions
        ))
        var reasonOnlyVersions = initialVersions
        reasonOnlyVersions.record(.historyPrepend, revision: 2)

        let updated = cache.snapshot(from: ConversationTimelineSourceSnapshot(
            scope: scope,
            messages: [message],
            versions: reasonOnlyVersions
        ))

        XCTAssertGreaterThan(updated.revision, initial.revision)
        XCTAssertEqual(updated.rowIDs, initial.rowIDs)
        XCTAssertEqual(updated.tail, initial.tail)
        XCTAssertEqual(updated.changes, .historyPrepend)
    }

    func testScopeChangeBypassesFreezeWithoutLeakingRows() {
        let store = ConversationStore()
        let scopeA = ScopedSessionID(profileID: "profile-a", sessionID: "thread")
        let scopeB = ScopedSessionID(profileID: "profile-b", sessionID: "thread")
        store.activate(profileID: scopeA.profileID)
        store.appendUser("A", sessionID: scopeA.sessionID)
        let cache = ConversationTimelineItemCache()
        _ = cache.snapshot(from: store.timelineSource(for: scopeA.sessionID))
        store.activate(profileID: scopeB.profileID)
        store.appendUser("B", sessionID: scopeB.sessionID)

        let switched = cache.snapshot(
            from: store.timelineSource(for: scopeB.sessionID),
            suspendingUpdates: true
        )
        let unchanged = cache.snapshot(from: store.timelineSource(for: scopeB.sessionID))

        XCTAssertEqual(switched.scope, scopeB)
        XCTAssertEqual(switched.rows.count, 1)
        XCTAssertEqual(switched.tail?.messageID, store.timelineSource(for: scopeB.sessionID).messages.last?.id)
        XCTAssertEqual(unchanged.revision, switched.revision)
    }

    func testTimestampSeparatorAppearsAcrossDayAndLongGapOnly() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let locale = Locale(identifier: "zh_Hans_CN")
        let twoDaysAgo = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 9, minute: 30))!
        let yesterdayEvening = calendar.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 23, minute: 50))!
        let day2Morning = calendar.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 10, minute: 55))!
        let day2CloseFollowUp = day2Morning.addingTimeInterval(3 * 60)
        let day2LaterGap = day2CloseFollowUp.addingTimeInterval(12 * 60)
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 16, minute: 0))!

        let m0 = ConversationMessage(role: .user, content: "前天", createdAt: twoDaysAgo)
        let m1 = ConversationMessage(role: .user, content: "昨晚", createdAt: yesterdayEvening)
        let m2 = ConversationMessage(role: .assistant, content: "今早日报", createdAt: day2Morning)
        let m3 = ConversationMessage(role: .user, content: "紧接着追问", createdAt: day2CloseFollowUp)
        let m4 = ConversationMessage(role: .user, content: "隔了十二分钟", createdAt: day2LaterGap)

        let items: [ConversationTimelineItem] = [.message(m0), .message(m1), .message(m2), .message(m3), .message(m4)]
        let labels = ConversationTimestampSeparatorPolicy.separatorLabels(
            for: items,
            now: now,
            calendar: calendar,
            locale: locale
        )

        XCTAssertNil(labels[items[0].id], "首条消息前不额外插时间分隔")
        XCTAssertEqual(labels[items[1].id], "\(L10n.text("ui.yesterday")) 23:50", "跨日到昨天应显示昨天时间")
        XCTAssertEqual(labels[items[2].id], "\(L10n.text("ui.today")) 10:55", "跨自然日到今天应展示居中时间分隔")
        XCTAssertNil(labels[items[3].id], "三分钟内的连续对话不应重复插分隔")
        XCTAssertEqual(labels[items[4].id], "\(L10n.text("ui.today")) 11:10", "超过 10 分钟的新段落应展示时间分隔")
    }

    func testReturnToTailButtonUsesCompactVisualDiscWithFullTouchTargetOnPhone() {
        let phone = ConversationReturnToTailButtonMetrics.resolve(isCompactPhone: true)
        XCTAssertEqual(phone.visualDiameter, 36)
        XCTAssertGreaterThanOrEqual(phone.hitDiameter, 44)
        XCTAssertEqual(phone.symbolName, "chevron.down")

        let pad = ConversationReturnToTailButtonMetrics.resolve(isCompactPhone: false)
        XCTAssertEqual(pad.visualDiameter, 48)
        XCTAssertEqual(pad.hitDiameter, 48)
        XCTAssertEqual(pad.symbolName, "arrow.down")
    }

    private static func history(
        id: String,
        content: String,
        createdAt: TimeInterval = 2,
        clientMessageID: ClientMessageID? = nil
    ) -> CodexHistoryMessage {
        CodexHistoryMessage(
            id: id,
            role: "assistant",
            content: content,
            createdAt: Date(timeIntervalSince1970: createdAt),
            clientMessageID: clientMessageID,
            turnID: "turn-\(id)",
            itemID: "item-\(id)"
        )
    }

    private static func metadata(sequence: Int64, revision: Int) -> AgentEventMetadata {
        AgentEventMetadata(
            seq: sequence,
            sessionID: "thread",
            turnID: "turn-live",
            itemID: "item-live",
            messageID: "assistant-live",
            clientMessageID: nil,
            revision: revision,
            createdAt: Date(timeIntervalSince1970: 3)
        )
    }
}
