import SwiftUI
import UIKit
import XCTest
@testable import MimiRemote

/// Codex、Claude 与 DeepSeek 共用同一时间线展示和滚动结果合同。
///
/// fixture 只写入脱敏的本地历史，不连接真实 runtime，也不依赖某个滚动策略布尔函数。
@MainActor
final class ConversationTimelineRuntimeRegressionTests: XCTestCase {
    func testActiveProcessCollapsesWhenOnlySessionStatusChanges() async throws {
        for provider in [TimelineRuntimeProviderFixture.codex, .claude, .deepseek] {
            let fixture = try makeFixture(provider: provider)
            defer {
                fixture.tearDown()
                ConversationTimelineViewport.testingViewObserver = nil
            }
            _ = try await waitForFirstReadableTail(in: fixture.host.view, provider: provider)
            let steps: [CodexHistoryMessage] = (0..<2).map { (index: Int) -> CodexHistoryMessage in
                let timestamp = Date(timeIntervalSince1970: Double(2_000 + index))
                let ordinal = Int64(2_000 + index)
                return CodexHistoryMessage(
                    id: "live-process-\(index)", role: "assistant", kind: .commentary,
                    content: index == 0 ? "检查配置" : "读取代码",
                    createdAt: timestamp, turnID: "live-turn",
                    timelineOrdinal: ordinal, turnLifecycle: .inProgress
                )
            }
            fixture.sessionStore.sessions[0].status = "running"
            fixture.sessionStore.sessions[0].activeTurnID = "live-turn"
            fixture.conversationStore.setHistory(steps, sessionID: fixture.primarySessionID)
            let source = fixture.conversationStore.timelineSource(for: fixture.primarySessionID)
            let first = try XCTUnwrap(source.messages.first { $0.stableID == steps[0].id })
            let second = try XCTUnwrap(source.messages.first { $0.stableID == steps[1].id })
            let expandedDeadline = Date().addingTimeInterval(5)
            var hasSeparateRows = false
            repeat {
                fixture.host.view.layoutIfNeeded()
                if let firstView = fixture.markerViews.object(forKey: first.id as NSUUID),
                   let secondView = fixture.markerViews.object(forKey: second.id as NSUUID),
                   firstView.window != nil, secondView.window != nil {
                    hasSeparateRows = firstView !== secondView
                }
                if hasSeparateRows { break }
                try await Task.sleep(for: .milliseconds(16))
            } while Date() < expandedDeadline
            XCTAssertTrue(hasSeparateRows, "\(provider.label) 当前轮的两个过程步骤应各自显示")

            // 不写入新消息，专门验证会话从 running 变为 idle 能触发 UI 重投影。
            fixture.sessionStore.sessions[0].status = "idle"
            let collapsedDeadline = Date().addingTimeInterval(5)
            var hasSharedSummary = false
            repeat {
                fixture.host.view.layoutIfNeeded()
                if let firstView = fixture.markerViews.object(forKey: first.id as NSUUID),
                   let secondView = fixture.markerViews.object(forKey: second.id as NSUUID),
                   firstView.window != nil, secondView.window != nil {
                    hasSharedSummary = firstView === secondView
                }
                if hasSharedSummary { break }
                try await Task.sleep(for: .milliseconds(16))
            } while Date() < collapsedDeadline
            XCTAssertTrue(hasSharedSummary, "\(provider.label) 结束后两个步骤只共享同一个过程总览")
            XCTAssertEqual(fixture.conversationStore.timelineSource(for: fixture.primarySessionID).revision, source.revision)
            let scrollView = try XCTUnwrap(conversationTimelineScrollView(in: fixture.host.view))
            try await assertReadableFramesStayAtTail(in: fixture.host.view, frameCount: 8,
                                                     provider: provider, context: "过程自动收起")
            XCTAssertLessThanOrEqual(distanceFromBottom(scrollView), 4)
        }
    }

    func testCodexTimelineKeepsReadableViewportAcrossRuntimeUpdates() async throws {
        try await assertRuntimeTimelineUserResults(provider: .codex)
    }

    func testClaudeTimelineKeepsReadableViewportAcrossRuntimeUpdates() async throws {
        try await assertRuntimeTimelineUserResults(provider: .claude)
    }

    func testDeepSeekTimelineKeepsReadableViewportAcrossRuntimeUpdates() async throws {
        try await assertRuntimeTimelineUserResults(provider: .deepseek)
    }

    func testCodexLoadingEarlierHistoryKeepsTopMessageInPlace() async throws {
        try await assertLoadingEarlierHistoryKeepsTopMessageInPlace(provider: .codex)
    }

    func testClaudeLoadingEarlierHistoryKeepsTopMessageInPlace() async throws {
        try await assertLoadingEarlierHistoryKeepsTopMessageInPlace(provider: .claude)
    }

    func testDeepSeekLoadingEarlierHistoryKeepsTopMessageInPlace() async throws {
        try await assertLoadingEarlierHistoryKeepsTopMessageInPlace(provider: .deepseek)
    }

    func testCodexLoadingEarlierHistoryKeepsTopMessageInPlaceWhenMorePagesRemain() async throws {
        try await assertLoadingEarlierHistoryKeepsTopMessageInPlace(
            provider: .codex,
            pageHasMoreBefore: true
        )
    }

    func testClaudeLoadingEarlierHistoryKeepsTopMessageInPlaceWhenMorePagesRemain() async throws {
        try await assertLoadingEarlierHistoryKeepsTopMessageInPlace(
            provider: .claude,
            pageHasMoreBefore: true
        )
    }

    func testDeepSeekLoadingEarlierHistoryKeepsTopMessageInPlaceWhenMorePagesRemain() async throws {
        try await assertLoadingEarlierHistoryKeepsTopMessageInPlace(
            provider: .deepseek,
            pageHasMoreBefore: true
        )
    }

    private func assertRuntimeTimelineUserResults(provider: TimelineRuntimeProviderFixture) async throws {
        ConversationScrollDiagnostics.shared.start()
        defer { ConversationScrollDiagnostics.shared.stop() }
        let commandRecorder = TimelineRuntimeCommandRecorder()
        ConversationTimelineScrollController.testingCommandObserver = { commandRecorder.append($0) }
        defer {
            ConversationTimelineScrollController.testingCommandObserver = nil
            ConversationTimelineViewport.testingViewObserver = nil
        }
        let fixture = try makeFixture(provider: provider)
        defer { fixture.tearDown() }

        let firstScrollView = try await waitForFirstReadableTail(in: fixture.host.view, provider: provider)
        XCTAssertLessThanOrEqual(distanceFromBottom(firstScrollView), 4)
        XCTAssertTrue(
            commandRecorder.records.contains {
                $0.scope.sessionID == fixture.primarySessionID && $0.target == .tail
            },
            "\(provider.label) 首屏必须经过统一滚动命令入口"
        )
        try await assertReadableFramesStayAtTail(
            in: fixture.host.view,
            frameCount: 32,
            provider: provider,
            context: "首屏稳定"
        )
        try await assertProgrammaticCommandsBecomeQuiet(
            in: fixture.host.view,
            recorder: commandRecorder
        )
        assertNoRepeatedProgrammaticCommand(
            commandRecorder.records,
            context: "\(provider.label) 首屏"
        )

        // 三批 runtime 补齐均在独立输入代次中发布。最后一批延迟发布，覆盖正文
        // 已可读后发生的异步 self-sizing；允许多次真实行高变化，但不允许同一写入自反馈。
        for batch in 0..<3 {
            let commandStart = commandRecorder.records.count
            let update = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(batch == 2 ? 48 : 8))
                fixture.conversationStore.setHistory(
                    [fixture.message(index: 18 + batch * 24, lineCount: 10 + batch * 7)],
                    sessionID: fixture.primarySessionID,
                    timelineMutationKind: .enrichment
                )
            }
            try await assertReadableFramesStayAtTail(
                in: fixture.host.view,
                frameCount: 32,
                provider: provider,
                context: "第 \(batch + 1) 批补齐"
            )
            await update.value
            try await assertProgrammaticCommandsBecomeQuiet(
                in: fixture.host.view,
                recorder: commandRecorder
            )
            assertNoRepeatedProgrammaticCommand(
                Array(commandRecorder.records.dropFirst(commandStart)),
                context: "\(provider.label) 第 \(batch + 1) 批补齐"
            )
        }

        let scrollView = try await moveToMiddleReadingPosition(fixture: fixture, provider: provider)
        let anchor = try await applyHistoryMutationAndCaptureAnchor(
            fixture: fixture,
            scrollView: scrollView,
            messages: fixture.messages(range: -20..<0, lineCount: 2),
            mutationKind: .prepend,
            expectedAnchorID: nil,
            context: "prepend"
        )
        XCTAssertEqual(anchor.frame.minY, anchor.baselineMinY, accuracy: 6)

        let enrichedAnchor = try await applyHistoryMutationAndCaptureAnchor(
            fixture: fixture,
            scrollView: scrollView,
            messages: [fixture.message(index: 4, lineCount: 24)],
            mutationKind: .enrichment,
            expectedAnchorID: anchor.id,
            context: "enrichment"
        )
        XCTAssertEqual(enrichedAnchor.frame.minY, anchor.baselineMinY, accuracy: 6)

        try await assertInteractionWinsOverRuntimeUpdates(
            fixture: fixture,
            scrollView: scrollView,
            provider: provider,
            recorder: commandRecorder
        )
        try await assertOldSessionWorkCannotMoveReplacementTimeline(
            fixture: fixture,
            provider: provider,
            recorder: commandRecorder
        )
    }

    private func assertLoadingEarlierHistoryKeepsTopMessageInPlace(
        provider: TimelineRuntimeProviderFixture,
        pageHasMoreBefore: Bool = false
    ) async throws {
        ConversationScrollDiagnostics.shared.start()
        let commandRecorder = TimelineRuntimeCommandRecorder()
        ConversationTimelineScrollController.testingCommandObserver = { commandRecorder.append($0) }
        defer {
            ConversationScrollDiagnostics.shared.stop()
            ConversationTimelineScrollController.testingCommandObserver = nil
            ConversationTimelineViewport.testingSelectionObserver = nil
            ConversationTimelineViewport.testingViewObserver = nil
        }
        let fixture = try makeFixture(provider: provider, hasEarlierHistory: true)
        defer { fixture.tearDown() }

        let scrollView = try await waitForFirstReadableTail(in: fixture.host.view, provider: provider)
        let originalMessage = try XCTUnwrap(
            fixture.conversationStore.messages(for: fixture.primarySessionID).first {
                $0.timelineOrdinal == 0
            }
        )
        await scrollToTopAsUser(scrollView)
        for _ in 0..<16 {
            fixture.host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(16))
        }
        let originalView = try XCTUnwrap(
            fixture.markerViews.object(forKey: originalMessage.id as NSUUID),
            "\(provider.label) 顶部第一条原消息必须已实例化"
        )
        let visibleFrame = scrollView.convert(scrollView.bounds, to: nil)
        let baselineFrame = originalView.convert(originalView.bounds, to: nil)
        XCTAssertTrue(isViewEffectivelyVisible(originalView, within: scrollView))
        XCTAssertTrue(baselineFrame.intersects(visibleFrame))
        XCTAssertTrue(fixture.sessionStore.canLoadEarlierHistory(sessionID: fixture.primarySessionID))

        var selectedAnchor: (id: UUID, frame: CGRect)?
        ConversationTimelineViewport.testingSelectionObserver = { selectedAnchor = ($0, $1) }
        let loadTask = Task { @MainActor in
            await fixture.sessionStore.loadEarlierHistory(sessionID: fixture.primarySessionID)
        }
        await fixture.client.waitForHistoryRequestCount(1)
        XCTAssertTrue(fixture.sessionStore.isLoadingEarlierHistory(sessionID: fixture.primarySessionID))
        XCTAssertNotNil(fixture.sessionStore.historyLoadProgress(sessionID: fixture.primarySessionID))

        // 加载按钮只建立阅读意图。锚点必须在旧页真正发布时捕获，不能依赖 250ms 临时事务。
        for _ in 0..<24 {
            fixture.host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(16))
        }
        XCTAssertNil(selectedAnchor, "\(provider.label) 网络等待期间不应提前捕获分页锚点")
        XCTAssertEqual(
            originalView.convert(originalView.bounds, to: nil).minY,
            baselineFrame.minY,
            accuracy: 6
        )

        fixture.client.resolveHistoryRequest(
            at: 0,
            with: HistoryMessagesPage(
                messages: fixture.messages(range: -60..<0, lineCount: 3),
                previousCursor: pageHasMoreBefore ? "timeline-runtime-\(provider.rawValue)-oldest" : nil,
                hasMoreBefore: pageHasMoreBefore
            )
        )
        await loadTask.value

        let deadline = Date().addingTimeInterval(4)
        var preservedFrame: CGRect?
        repeat {
            fixture.host.view.layoutIfNeeded()
            if selectedAnchor != nil,
               let currentView = fixture.markerViews.object(forKey: originalMessage.id as NSUUID),
               isViewEffectivelyVisible(currentView, within: scrollView) {
                let frame = currentView.convert(currentView.bounds, to: nil)
                if abs(frame.minY - baselineFrame.minY) <= 6 {
                    preservedFrame = frame
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(16))
        } while Date() < deadline

        let currentOriginalView = fixture.markerViews.object(forKey: originalMessage.id as NSUUID)
        let currentOriginalState: String
        if let currentOriginalView {
            currentOriginalState = "descendant=\(currentOriginalView.isDescendant(of: scrollView)) "
                + "minY=\(currentOriginalView.convert(currentOriginalView.bounds, to: nil).minY)"
        } else {
            currentOriginalState = "nativeView=nil"
        }
        let selectedAnchorState = selectedAnchor.map {
            "id=\($0.id.uuidString) frame=\($0.frame)"
        } ?? "nil"
        let currentMessages = fixture.conversationStore.messages(for: fixture.primarySessionID)
        let originalIndex = currentMessages.firstIndex { $0.id == originalMessage.id }
        let leadingOrdinals = currentMessages.prefix(8).map {
            String(describing: $0.timelineOrdinal)
        }.joined(separator: ",")
        var ancestorDescriptions: [String] = []
        var nearestCell: UICollectionViewCell?
        var ancestor = currentOriginalView
        while let view = ancestor {
            if nearestCell == nil, let cell = view as? UICollectionViewCell {
                nearestCell = cell
            }
            ancestorDescriptions.append(
                "\(String(describing: type(of: view))) hidden=\(view.isHidden) alpha=\(view.alpha) frame=\(view.frame)"
            )
            if view === scrollView { break }
            ancestor = view.superview
        }
        let nearestCellState: String
        if let nearestCell, let collectionView = scrollView as? UICollectionView {
            nearestCellState = "\(String(describing: type(of: nearestCell))) "
                + "inVisibleCells=\(collectionView.visibleCells.contains { $0 === nearestCell })"
        } else {
            nearestCellState = "nil-or-scrollView-not-UICollectionView"
        }
        let failureEvidence = """
        selectedAnchor=\(selectedAnchorState)
        originalID=\(originalMessage.id.uuidString) baselineFrame=\(baselineFrame)
        currentOriginal=\(currentOriginalState)
        storeOriginalIndex=\(originalIndex.map(String.init) ?? "nil") messageCount=\(currentMessages.count) leadingOrdinals=\(leadingOrdinals)
        originalAncestorChain:
        \(ancestorDescriptions.joined(separator: "\n"))
        nearestCollectionCell=\(nearestCellState)
        nativeScroll=offset:\(scrollView.contentOffset.y) height:\(scrollView.contentSize.height) minimum:\(-scrollView.adjustedContentInset.top)
        diagnostics:
        \(ConversationScrollDiagnostics.shared.export())
        """
        let finalFrame = try XCTUnwrap(
            preservedFrame,
            "\(provider.label) 前插多个屏幕的历史后，原消息仍须留在原屏幕位置\n\(failureEvidence)"
        )
        XCTAssertEqual(finalFrame.minY, baselineFrame.minY, accuracy: 6)
        XCTAssertNotNil(selectedAnchor, "\(provider.label) 发布 prepend 前必须捕获可见消息")
        for _ in 0..<20 {
            fixture.host.view.layoutIfNeeded()
            let currentView = try XCTUnwrap(
                fixture.markerViews.object(forKey: originalMessage.id as NSUUID),
                "\(provider.label) prepend 稳定期间原消息不能被回收"
            )
            XCTAssertTrue(isViewEffectivelyVisible(currentView, within: scrollView))
            XCTAssertEqual(
                currentView.convert(currentView.bounds, to: nil).minY,
                baselineFrame.minY,
                accuracy: 6,
                "\(provider.label) prepend 后原消息必须连续稳定 20 帧"
            )
            try await Task.sleep(for: .milliseconds(16))
        }
        var anchorItemCountByInput: [Int: Int] = [:]
        for record in commandRecorder.records where record.scope.sessionID == fixture.primarySessionID {
            if case .anchorItem = record.target {
                anchorItemCountByInput[record.inputGeneration, default: 0] += 1
            }
        }
        XCTAssertTrue(
            anchorItemCountByInput.values.allSatisfy { $0 <= 1 },
            "\(provider.label) 每个分页输入最多只能执行一次 row bootstrap：\(anchorItemCountByInput)"
        )
        XCTAssertFalse(fixture.sessionStore.isLoadingEarlierHistory(sessionID: fixture.primarySessionID))
        XCTAssertEqual(
            fixture.sessionStore.canLoadEarlierHistory(sessionID: fixture.primarySessionID),
            pageHasMoreBefore
        )

        let oldestMessage = try XCTUnwrap(
            fixture.conversationStore.messages(for: fixture.primarySessionID).first {
                $0.timelineOrdinal == -60
            }
        )
        let offsetBeforeManualScroll = scrollView.contentOffset.y
        await scrollToTopAsUser(scrollView)
        var oldestFrame: CGRect?
        let scrollDeadline = Date().addingTimeInterval(4)
        repeat {
            fixture.host.view.layoutIfNeeded()
            if let view = fixture.markerViews.object(forKey: oldestMessage.id as NSUUID),
               isViewEffectivelyVisible(view, within: scrollView) {
                let frame = view.convert(view.bounds, to: nil)
                if frame.intersects(scrollView.convert(scrollView.bounds, to: nil)) {
                    oldestFrame = frame
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(16))
        } while Date() < scrollDeadline
        XCTAssertLessThan(scrollView.contentOffset.y, offsetBeforeManualScroll - 200)
        XCTAssertNotNil(oldestFrame, "\(provider.label) 用户继续上滑后必须能看到新加载的旧消息")
    }

    private func makeFixture(
        provider: TimelineRuntimeProviderFixture,
        hasEarlierHistory: Bool = false
    ) throws -> TimelineRuntimeFixture {
        let appStore = makeIsolatedAppStore()
        let conversationStore = ConversationStore()
        conversationStore.activate(profileID: appStore.activeHostScope.profileID)
        let client = OrderedHistoryPageClient(projects: [], page: SessionsPage(sessions: []))
        let sessionStore = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: { client }
        )
        let primarySessionID = "timeline-runtime-\(provider.rawValue)-a"
        let replacementSessionID = "timeline-runtime-\(provider.rawValue)-b"
        let projectID = "timeline-runtime-project-\(provider.rawValue)"
        sessionStore.sessions = [primarySessionID, replacementSessionID].map { sessionID in
            makeSession(
                id: sessionID,
                projectID: projectID,
                title: sessionID,
                status: "history",
                source: provider.rawValue,
                runtimeProvider: provider.rawValue,
                resumeID: sessionID
            )
        }
        sessionStore.selectedSessionID = primarySessionID

        let fixture = TimelineRuntimeFixture(
            provider: provider,
            primarySessionID: primarySessionID,
            replacementSessionID: replacementSessionID,
            conversationStore: conversationStore,
            sessionStore: sessionStore,
            client: client
        )
        conversationStore.setHistory(fixture.messages(range: 0..<72, lineCount: 3), sessionID: primarySessionID)
        conversationStore.setHistory(fixture.messages(range: 100..<172, lineCount: 3), sessionID: replacementSessionID)
        sessionStore.historyLoadedQualityBySessionID[primarySessionID] = .full
        sessionStore.historyLoadedQualityBySessionID[replacementSessionID] = .full
        if hasEarlierHistory {
            let cursor = "timeline-runtime-\(provider.rawValue)-older"
            sessionStore.historyPreviousCursorBySessionID[primarySessionID] = cursor
            sessionStore.historyHasMoreBeforeBySessionID[primarySessionID] = true
            sessionStore.historySeenPreviousCursorsBySessionID[primarySessionID] = [cursor]
        }
        ConversationTimelineViewport.testingViewObserver = { [weak fixture] id, view in
            fixture?.markerViews.setObject(view, forKey: id as NSUUID)
        }
        fixture.mount()
        return fixture
    }

    private func scrollToTopAsUser(_ scrollView: UIScrollView) async {
        let minimumOffsetY = -scrollView.adjustedContentInset.top
        scrollView.delegate?.scrollViewWillBeginDragging?(scrollView)
        await Task.yield()
        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: minimumOffsetY),
            animated: false
        )
        scrollView.delegate?.scrollViewDidScroll?(scrollView)
        scrollView.delegate?.scrollViewDidEndDragging?(scrollView, willDecelerate: false)
    }

    private func waitForFirstReadableTail(
        in rootView: UIView,
        provider: TimelineRuntimeProviderFixture
    ) async throws -> UIScrollView {
        let deadline = Date().addingTimeInterval(8)
        var firstReadableDistances: [CGFloat] = []
        var latest: UIScrollView?
        repeat {
            rootView.layoutIfNeeded()
            if let scrollView = conversationTimelineScrollView(in: rootView),
               isViewEffectivelyVisible(scrollView, within: rootView) {
                latest = scrollView
                if !conversationTimelineIsStabilizing(in: rootView) {
                    firstReadableDistances.append(distanceFromBottom(scrollView))
                    if firstReadableDistances.count >= 6 { break }
                }
            }
            try await Task.sleep(for: .milliseconds(16))
        } while Date() < deadline

        XCTAssertFalse(firstReadableDistances.isEmpty, "\(provider.label) 长历史必须出现可读首帧\n\(ConversationScrollDiagnostics.shared.export())")
        XCTAssertLessThanOrEqual(
            firstReadableDistances.max() ?? .infinity,
            4,
            "\(provider.label) 从首个可读帧起就必须贴底"
        )
        return try XCTUnwrap(latest)
    }

    private func assertReadableFramesStayAtTail(
        in rootView: UIView,
        frameCount: Int,
        provider: TimelineRuntimeProviderFixture,
        context: String
    ) async throws {
        var distances: [CGFloat] = []
        for _ in 0..<frameCount {
            rootView.layoutIfNeeded()
            XCTAssertFalse(
                conversationTimelineIsStabilizing(in: rootView),
                "\(provider.label) 首帧交接后，\(context)不能重新遮住正文"
            )
            let scrollView = try XCTUnwrap(conversationTimelineScrollView(in: rootView))
            distances.append(distanceFromBottom(scrollView))
            try await Task.sleep(for: .milliseconds(16))
        }
        XCTAssertLessThanOrEqual(
            distances.max() ?? .infinity,
            4,
            "\(provider.label) \(context)的每个可读帧都必须贴底"
        )
    }

    private func moveToMiddleReadingPosition(
        fixture: TimelineRuntimeFixture,
        provider: TimelineRuntimeProviderFixture
    ) async throws -> UIScrollView {
        let scrollView = try XCTUnwrap(conversationTimelineScrollView(in: fixture.host.view))
        let minimum = -scrollView.adjustedContentInset.top
        let maximum = max(
            minimum,
            scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        )
        let target = minimum + (maximum - minimum) * 0.45
        scrollView.delegate?.scrollViewWillBeginDragging?(scrollView)
        await Task.yield()
        scrollView.setContentOffset(CGPoint(x: 0, y: target), animated: false)
        scrollView.delegate?.scrollViewDidScroll?(scrollView)
        scrollView.delegate?.scrollViewDidEndDragging?(scrollView, willDecelerate: false)
        for _ in 0..<12 {
            fixture.host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(16))
        }
        XCTAssertGreaterThan(distanceFromBottom(scrollView), 200, "\(provider.label) 必须进入历史阅读位置")
        return scrollView
    }

    private func applyHistoryMutationAndCaptureAnchor(
        fixture: TimelineRuntimeFixture,
        scrollView: UIScrollView,
        messages: [CodexHistoryMessage],
        mutationKind: ConversationHistoryTimelineMutationKind,
        expectedAnchorID: UUID?,
        context: String
    ) async throws -> (id: UUID, baselineMinY: CGFloat, frame: CGRect) {
        let observedBaseline = expectedAnchorID.flatMap { id in
            fixture.markerViews.object(forKey: id as NSUUID).map { $0.convert($0.bounds, to: nil).minY }
        }
        var selection: (id: UUID, frame: CGRect)?
        ConversationTimelineViewport.testingSelectionObserver = { selection = ($0, $1) }
        defer {
            ConversationTimelineViewport.testingSelectionObserver = nil
        }

        fixture.conversationStore.setHistory(
            messages,
            sessionID: fixture.primarySessionID,
            timelineMutationKind: mutationKind
        )
        let deadline = Date().addingTimeInterval(3)
        repeat {
            fixture.host.view.layoutIfNeeded()
            if let selection, let view = fixture.markerViews.object(forKey: selection.id as NSUUID),
               view.isDescendant(of: scrollView),
               abs(view.convert(view.bounds, to: nil).minY - selection.frame.minY) <= 6 {
                break
            }
            try await Task.sleep(for: .milliseconds(16))
        } while Date() < deadline

        let selected = try XCTUnwrap(selection, "\(context) 前必须选中真实可见消息")
        // 下一次事务可选择另一个可见候选；用户结果是原消息仍在原位置，而非内部选择 ID 相同。
        let observedID = expectedAnchorID ?? selected.id
        let baseline = observedBaseline ?? selected.frame.minY
        for _ in 0..<20 {
            fixture.host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(16))
        }
        let marker = try XCTUnwrap(fixture.markerViews.object(forKey: observedID as NSUUID), "\(context) 后原消息锚点必须仍存在")
        XCTAssertTrue(marker.isDescendant(of: scrollView), "锚点必须仍在当前 List 中")
        let current = marker.convert(marker.bounds, to: nil)
        XCTAssertEqual(current.minY, baseline, accuracy: 6, "\(context) 后消息不能在屏幕中跳动")
        XCTAssertGreaterThan(distanceFromBottom(scrollView), 200, "\(context) 不能把历史阅读者拉回尾部")
        return (observedID, baseline, current)
    }

    private func assertInteractionWinsOverRuntimeUpdates(
        fixture: TimelineRuntimeFixture,
        scrollView: UIScrollView,
        provider: TimelineRuntimeProviderFixture,
        recorder: TimelineRuntimeCommandRecorder
    ) async throws {
        let dragCommandStart = recorder.records.count
        scrollView.delegate?.scrollViewWillBeginDragging?(scrollView)
        await Task.yield()
        fixture.conversationStore.setHistory(
            [fixture.message(index: 6, lineCount: 30)],
            sessionID: fixture.primarySessionID,
            timelineMutationKind: .enrichment
        )
        for _ in 0..<8 {
            fixture.host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(16))
        }
        XCTAssertEqual(
            recorder.records.count,
            dragCommandStart,
            "\(provider.label) 用户拖动时必须零程序写"
        )

        scrollView.delegate?.scrollViewDidEndDragging?(scrollView, willDecelerate: true)
        let decelerationCommandStart = recorder.records.count
        fixture.conversationStore.setHistory(
            [fixture.message(index: 7, lineCount: 32)],
            sessionID: fixture.primarySessionID,
            timelineMutationKind: .enrichment
        )
        for _ in 0..<8 {
            fixture.host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(16))
        }
        XCTAssertFalse(
            recorder.records.dropFirst(decelerationCommandStart).contains { $0.target == .tail },
            "\(provider.label) 惯性滚动期间不能尾随"
        )
        scrollView.delegate?.scrollViewDidEndDecelerating?(scrollView)
        for _ in 0..<16 {
            fixture.host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(16))
        }
        XCTAssertGreaterThan(distanceFromBottom(scrollView), 200, "用户结束滚动后仍应留在历史阅读位置")
    }

    private func assertOldSessionWorkCannotMoveReplacementTimeline(
        fixture: TimelineRuntimeFixture,
        provider: TimelineRuntimeProviderFixture,
        recorder: TimelineRuntimeCommandRecorder
    ) async throws {
        // 先让 A 产生一次待处理的历史事务，再在同一主线程拍切到 B。随后继续更新 A，
        // 验证旧 scope 的布局与任务都不能写进替换后的 List。
        fixture.conversationStore.setHistory(
            [fixture.message(index: 8, lineCount: 36)],
            sessionID: fixture.primarySessionID,
            timelineMutationKind: .enrichment
        )
        fixture.host.view.layoutIfNeeded()
        fixture.sessionStore.selectedSessionID = fixture.replacementSessionID
        let replacementCommandStart = recorder.records.count
        let staleUpdate = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(32))
            fixture.conversationStore.setHistory(
                [fixture.message(index: 9, lineCount: 40)],
                sessionID: fixture.primarySessionID,
                timelineMutationKind: .enrichment
            )
        }
        _ = try await waitForFirstReadableTail(in: fixture.host.view, provider: provider)
        try await assertReadableFramesStayAtTail(
            in: fixture.host.view,
            frameCount: 20,
            provider: provider,
            context: "A 切换到 B 后的旧事务"
        )
        await staleUpdate.value
        let replacementRecords = recorder.records.dropFirst(replacementCommandStart)
        XCTAssertFalse(
            replacementRecords.contains { $0.scope.sessionID == fixture.primarySessionID },
            "切到 B 后不得再执行 A scope 的旧命令"
        )
        XCTAssertTrue(
            replacementRecords.contains { $0.scope.sessionID == fixture.replacementSessionID },
            "B 必须用自己的 scope 完成首屏定位"
        )
    }

    private func assertNoRepeatedProgrammaticCommand(
        _ records: [ConversationTimelineScrollCommandRecord],
        context: String
    ) {
        var counts: [String: Int] = [:]
        for record in records {
            let target: String
            switch record.target {
            case .tail:
                target = "tail"
            case let .offset(value):
                target = "offset:\((value * 2).rounded() / 2)"
            case let .item(id):
                target = "item:\(id)"
            case let .anchorItem(id):
                target = "anchor_item:\(id)"
            }
            let fingerprint = [
                record.scope.profileID, record.scope.sessionID,
                String(record.revision), String(record.inputGeneration),
                record.reason.rawValue, target, String(Double(record.contentHeight).bitPattern)
            ].joined(separator: "|")
            counts[fingerprint, default: 0] += 1
        }
        let repeated = counts.filter { $0.value > 1 }
        XCTAssertTrue(repeated.isEmpty, "\(context) 出现重复程序写：\(repeated)")
    }

    private func assertProgrammaticCommandsBecomeQuiet(
        in rootView: UIView,
        recorder: TimelineRuntimeCommandRecorder
    ) async throws {
        let commandsAtQuietStart = recorder.records.count
        for _ in 0..<8 {
            rootView.layoutIfNeeded()
            XCTAssertFalse(conversationTimelineIsStabilizing(in: rootView))
            XCTAssertLessThanOrEqual(
                distanceFromBottom(try XCTUnwrap(conversationTimelineScrollView(in: rootView))),
                4
            )
            try await Task.sleep(for: .milliseconds(16))
        }
        XCTAssertEqual(
            recorder.records.count,
            commandsAtQuietStart,
            "外部输入停止后必须至少连续 100ms 零程序写"
        )
    }
}

private enum TimelineRuntimeProviderFixture: String {
    case codex
    case claude
    case deepseek

    var label: String { rawValue.capitalized }
}

@MainActor
private final class TimelineRuntimeCommandRecorder {
    private(set) var records: [ConversationTimelineScrollCommandRecord] = []

    func append(_ record: ConversationTimelineScrollCommandRecord) {
        records.append(record)
    }
}

@MainActor
private final class TimelineRuntimeFixture {
    let markerViews = NSMapTable<NSUUID, UIView>.strongToWeakObjects()
    let provider: TimelineRuntimeProviderFixture
    let primarySessionID: SessionID
    let replacementSessionID: SessionID
    let conversationStore: ConversationStore
    let sessionStore: SessionStore
    let client: OrderedHistoryPageClient
    let host: UIHostingController<AnyView>
    private let themeSuiteName: String
    private let themeDefaults: UserDefaults
    private var window: UIWindow?

    init(
        provider: TimelineRuntimeProviderFixture,
        primarySessionID: SessionID,
        replacementSessionID: SessionID,
        conversationStore: ConversationStore,
        sessionStore: SessionStore,
        client: OrderedHistoryPageClient
    ) {
        self.provider = provider
        self.primarySessionID = primarySessionID
        self.replacementSessionID = replacementSessionID
        self.conversationStore = conversationStore
        self.sessionStore = sessionStore
        self.client = client
        themeSuiteName = "TimelineRuntimeRegressionTests.\(provider.rawValue).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: themeSuiteName) else {
            fatalError("无法创建时间线测试 UserDefaults")
        }
        themeDefaults = defaults
        host = UIHostingController(rootView: AnyView(
            ConversationView()
                .environmentObject(sessionStore)
                .environmentObject(conversationStore)
                .environmentObject(ThemeStore(defaults: defaults))
                .environment(\.colorScheme, .light)
        ))
    }

    func mount() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            fatalError("时间线测试需要 UIWindowScene")
        }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 420, height: 820)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        self.window = window
    }

    func tearDown() {
        window?.isHidden = true
        window = nil
        themeDefaults.removePersistentDomain(forName: themeSuiteName)
    }

    func messages(range: Range<Int>, lineCount: Int) -> [CodexHistoryMessage] {
        range.map { message(index: $0, lineCount: lineCount) }
    }

    func message(index: Int, lineCount: Int) -> CodexHistoryMessage {
        CodexHistoryMessage(
            id: "\(primarySessionID)-history-\(index)",
            role: index.isMultiple(of: 2) ? "user" : "assistant",
            content: String(
                repeating: "\(provider.label) 第 \(index) 条历史内容用于滚动验收。\n",
                count: lineCount
            ),
            createdAt: Date(timeIntervalSince1970: Double(index + 1_000)),
            turnID: "\(primarySessionID)-turn-\(index)",
            itemID: "\(primarySessionID)-item-\(index)",
            timelineOrdinal: Int64(index)
        )
    }
}
