import SwiftUI
import UIKit

struct ConversationTimelineView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var conversationStore: ConversationStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.colorScheme) private var colorScheme
    let layout: ConversationLayout
    let explicitSessionID: SessionID?
    let allowsTopUnderlap: Bool
    @State private var shouldFollowMessageTail = true
    @State private var forceNextMessageTailScroll = true
    // 在会话切换、本地提交或用户主动“回到底部”后，旧 List 的滚动几何可能还会
    // 回报上一个会话的 offset。锁住跟随直到用户明确上翻，避免这份过期几何把
    // 新会话的首帧尾部定位提前关掉。
    @State private var isTailFollowLocked = false
    @State private var isTimelineNearBottom = true
    @State private var hasUnseenTailMessage = false
    @State private var isPreservingHistoryScroll = false
    @State private var expandedActivityIDs: Set<String> = []
    @State private var expandedActivityGroupIDs: Set<String> = []
    // nil 表示跟随状态默认值；显式 true/false 都是用户 override，状态切换时优先保留。
    @State private var workGroupExpansionOverrides: [String: Bool] = [:]
    @State private var timelineItemCache = ConversationTimelineItemCache()
    // 滚动任务 bookkeeping 不属于界面状态，放在引用对象中避免每次取消/重排任务都触发 body 失效。
    @State private var tailScrollCoordinator = ConversationTailScrollCoordinator()
    @State private var historyScrollCoordinator = ConversationHistoryScrollCoordinator()
    @State private var timelineScrollPosition = ScrollPosition(idType: String.self)
    @State private var isUserScrollingTimeline = false
    @State private var timelinePresentationGeneration = 0
    @State private var initialTailScrollAttemptedIdentity: ConversationTimelineListIdentity?
    @State private var visibleTailSentinelIdentity: ConversationTimelineListIdentity?
    @State private var presentedTimelineIdentity: ConversationTimelineListIdentity?

    private let messageTailFollowThreshold: CGFloat = 120
    private static let timelineTailSentinelID = "__conversation_timeline_safe_tail__"
    static let stabilizingCoverAccessibilityIdentifier = "conversation.timeline.stabilizing-cover"

    init(
        layout: ConversationLayout,
        sessionID: SessionID? = nil,
        allowsTopUnderlap: Bool = false
    ) {
        self.layout = layout
        explicitSessionID = sessionID
        self.allowsTopUnderlap = allowsTopUnderlap
    }

    private var displayedSessionID: SessionID? {
        explicitSessionID ?? sessionStore.selectedSessionID
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let hostProfileID = sessionStore.mediaProfileScope
        let messages = conversationStore.messages(for: displayedSessionID)
        let timelineSnapshot = timelineItemCache.snapshot(
            from: messages,
            suspendingUpdates: isUserScrollingTimeline
        )
        let timelineItems = timelineSnapshot.items
        let timelineItemIDs = timelineSnapshot.itemIDs
        let historyTimelineMutation = conversationStore.historyTimelineMutation(for: displayedSessionID)
        let historyMutationGeneration = historyTimelineMutation?.generation
        let observedTailMessageID = ConversationTimelineObservedChange(
            value: messages.last?.id,
            historyMutationGeneration: historyMutationGeneration
        )
        let observedTailRenderFingerprint = ConversationTimelineObservedChange(
            value: messages.last?.renderFingerprint,
            historyMutationGeneration: historyMutationGeneration
        )
        let observedTimelineItemIDs = ConversationTimelineObservedChange(
            value: timelineItemIDs,
            historyMutationGeneration: historyMutationGeneration
        )
        let visibleTimelineItemID = timelineScrollPosition.viewID(type: String.self)
        let timelineListIdentity = ConversationTimelineListIdentity(
            scope: ScopedSessionID(
                profileID: hostProfileID,
                sessionID: displayedSessionID ?? "__none__"
            ),
            hasTimelineContent: !timelineItems.isEmpty,
            presentationGeneration: timelinePresentationGeneration
        )
        let isTimelineReadable = timelineItems.isEmpty
            || presentedTimelineIdentity == timelineListIdentity
        let activeUserDeliveryMessageID = Self.activeUserDeliveryMessageID(in: messages)
        let crossSessionOriginMessageID = Self.crossSessionOriginMessageID(
            session: displayedSessionID.flatMap { sessionStore.sessionsByID[$0] },
            messages: messages
        )
        let isHistoryLoading = sessionStore.historyLoadProgress(sessionID: displayedSessionID) != nil
        let isLoadingEarlierHistory = sessionStore.isLoadingEarlierHistory(sessionID: displayedSessionID)
        let shouldShowInlineHistoryLoading = Self.shouldShowInlineHistoryLoading(
            timelineItemsAreEmpty: timelineItems.isEmpty,
            isHistoryLoading: isHistoryLoading,
            isLoadingEarlierHistory: isLoadingEarlierHistory,
            hasHistorySavingsNotice: explicitSessionID == nil && sessionStore.selectedHistorySavingsNotice != nil
        )
        return ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                // 用 List 替代 ScrollView + LazyVStack：行高是真实测量值、
                // 有 cell 复用，scrollTo 对尚未实例化的行也可靠。这样既消除首屏/切换会话
                // “空白要手滑一下”的竞态，右侧滚动条也不再因 LazyVStack 高度估算而长度/位置乱跳。
                List {
                    Section {
                        if timelineItems.isEmpty {
                            timelineEmptyState(isHistoryLoading: isHistoryLoading)
                                .padding(.top, 80)
                                .frame(maxWidth: .infinity)
                                .listRowSeparator(.hidden)
                                .listRowInsets(layout.messageRowInsets)
                                .listRowBackground(Color.clear)
                        } else {
                            if sessionStore.canLoadEarlierHistory(sessionID: displayedSessionID) {
                                loadEarlierRow
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(layout.messageRowInsets)
                                    .listRowBackground(Color.clear)
                            }
                            ForEach(timelineItems) { item in
                                // .equatable() 让流式输出时只重绘内容变化的那一行，其余行直接复用，
                                // 长对话下 ForEach 的 diff 成本降到只看可见行的值比较。
                                timelineRow(
                                    item,
                                    activeUserDeliveryMessageID: activeUserDeliveryMessageID,
                                    crossSessionOriginMessageID: crossSessionOriginMessageID,
                                    proxy: proxy
                                )
                                    .simultaneousGesture(TapGesture().onEnded {
                                        KeyboardDismissal.dismiss()
                                    })
                                    .id(item.id)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(layout.messageRowInsets)
                                    .listRowBackground(Color.clear)
                                    .modifier(ConversationHistoryAnchorGeometryModifier(
                                        isEnabled: item.id == historyScrollCoordinator.activeAnchorItemID
                                            || item.id == visibleTimelineItemID,
                                        itemID: item.id,
                                        action: recordHistoryAnchorGeometry
                                    ))
                            }
                            if shouldShowInlineHistoryLoading {
                                historyLoadingRow
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(layout.messageRowInsets)
                                    .listRowBackground(Color.clear)
                            }
                        }
                    }

                    Section {
                        // 尾部哨兵独占固定 Section，始终是 row 0。消息增删只影响前一个
                        // Section，scrollTo 不会把新快照行号用于旧 UICollectionView 快照。
                        Color.clear
                            .frame(height: 1)
                            .background {
                                ConversationTimelineScrollViewLocator { scrollView in
                                    historyScrollCoordinator.bind(scrollView: scrollView)
                                }
                                .frame(width: 0, height: 0)
                            }
                            .onScrollVisibilityChange(threshold: 0.5) { isVisible in
                                if isVisible {
                                    visibleTailSentinelIdentity = timelineListIdentity
                                    confirmTimelinePresentationIfReady(
                                        timelineListIdentity,
                                        hasTimelineContent: !timelineItems.isEmpty
                                    )
                                } else if visibleTailSentinelIdentity == timelineListIdentity {
                                    visibleTailSentinelIdentity = nil
                                }
                            }
                            // ID 必须标记可见性包装后的整行，否则 ScrollViewReader 可能只找到
                            // 尚未进入 List 快照的内部 Color，首屏 scrollTo 会一直无效。
                            .id(Self.timelineTailSentinelID)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                // 支持该语义的系统会在 List 首次提交前计算底部 offset；其余系统由下方
                // 的稳定遮罩兜住首次布局，不能让尚未贴底的正文成为可读画面。
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .scrollPosition($timelineScrollPosition)
                // 每个会话使用独立的 List 身份，避免复用上一个会话的 contentOffset；
                // 空占位变成正文时也重建一次，让未缓存会话重新应用初始底部锚点。
                .id(timelineListIdentity)
                .allowsHitTesting(isTimelineReadable)
                .accessibilityHidden(!isTimelineReadable)
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .background(tokens.conversationCanvasBackground)
                // 顶部正文进入导航层、底部正文经过 Composer 时都使用系统柔和虚化；
                // 不再在任一边缘切出一整块与页面不同的实色底板。
                .workbenchSoftConversationScrollEdges(allowsTopUnderlap: allowsTopUnderlap)
                .simultaneousGesture(TapGesture().onEnded {
                    KeyboardDismissal.dismiss()
                })
                .simultaneousGesture(userScrollAwayFromTailGesture)
                // 是否贴近底部用滚动几何实时判断，只在贴底时跟随流式输出，
                // 用户上翻历史时不会被尾部更新甩回底部。
                .onScrollGeometryChange(for: ConversationTimelineScrollMetrics.self) { geometry in
                    scrollMetrics(for: geometry)
                } action: { oldMetrics, metrics in
                    if let correction = historyScrollCoordinator.update(metrics: metrics) {
                        queueHistoryPrependCorrection(correction)
                    }
                    // 仅内容增高、视口本身未移动时继续贴尾。这样 Markdown/媒体异步展开
                    // 可以跟随，但用户正在上翻时不会被同一帧的布局变化抢回底部。
                    if abs(oldMetrics.contentHeight - metrics.contentHeight) >= 0.5,
                       abs(oldMetrics.contentOffsetY - metrics.contentOffsetY) < 0.5,
                       shouldFollowMessageTail,
                       !isUserScrollingTimeline,
                       !isPreservingHistoryScroll {
                        queueTailScrollAttempts(
                            timelineItems: timelineItems,
                            proxy: proxy,
                            sessionID: displayedSessionID,
                            expectedTailItemID: timelineItems.last?.id,
                            animatedFirstAttempt: false,
                            force: true
                        )
                    }
                    isTimelineNearBottom = metrics.isNearBottom
                    if metrics.isNearBottom {
                        shouldFollowMessageTail = true
                        hasUnseenTailMessage = false
                        historyScrollCoordinator.cancelPreservation()
                    } else if !isTailFollowLocked {
                        shouldFollowMessageTail = false
                    }
                }
                .onScrollPhaseChange { _, newPhase in
                    let shouldSuspend = Self.shouldSuspendTimelineUpdates(for: newPhase)
                    guard shouldSuspend != isUserScrollingTimeline else {
                        return
                    }
                    isUserScrollingTimeline = shouldSuspend
                    guard shouldSuspend else {
                        beginVisibleHistoryAnchorPreservation()
                        return
                    }
                    // 手指驱动滚动时优先保证交互帧率：停止旧的尾部重锚任务，
                    // 流式消息在 Store 中继续累计，滚动结束后再一次性刷新 List。
                    isTailFollowLocked = false
                    shouldFollowMessageTail = false
                    tailScrollCoordinator.userScrollAwayGeneration += 1
                    cancelPendingTailScrollAttempts()
                    cancelHistoryAnchorPreservation()
                }

                if shouldShowReturnToTailButton(timelineItems: timelineItems) {
                    ConversationReturnToTailButton(
                        tokens: tokens,
                        accessibilityLabel: returnToTailAccessibilityLabel
                    ) {
                        returnToTimelineTail(timelineItems: timelineItems, proxy: proxy)
                    }
                    // 放在输入区正上方的视觉中轴，不与用户气泡或右侧滚动条争抢空间。
                    .padding(.bottom, 10)
                }

                if !isTimelineReadable {
                    // List 必须先进入视图层级才能获得真实高度并执行 scrollTo。用真实画布
                    // 覆盖这段布局窗口；尾部哨兵确认可见后整块移除，不展示顶部或中间位置。
                    ConversationTimelineStabilizingCover(
                        backgroundColor: UIColor(tokens.conversationCanvasBackground)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .onChange(of: displayedSessionID) { oldID, newID in
                let shouldPreserveTailFollowLock = isTailFollowLocked
                    && Self.isOptimisticSessionID(oldID)
                    && newID != nil
                shouldFollowMessageTail = true
                forceNextMessageTailScroll = true
                // 会话切换本来就要进入最新上下文。首帧 List 尚未替换前，旧会话的
                // geometry 可能先报“未贴底”；把锁延续到用户主动上翻，后续流式消息
                // 才不会被错误地当成历史阅读状态而停止重锚。
                isTailFollowLocked = newID != nil || shouldPreserveTailFollowLock
                hasUnseenTailMessage = false
                isTimelineNearBottom = true
                isPreservingHistoryScroll = false
                isUserScrollingTimeline = false
                // 每次进入会话都生成新的 List/展示身份。不能只清空 Optional 状态，
                // 否则 onChange 与新 task 的执行顺序可能再次取消正确的首屏定位。
                timelinePresentationGeneration += 1
                expandedActivityIDs.removeAll()
                expandedActivityGroupIDs.removeAll()
                workGroupExpansionOverrides.removeAll()
                timelineItemCache.removeAll()
                cancelPendingTailScrollAttempts()
                historyScrollCoordinator.reset()
                timelineScrollPosition = ScrollPosition(idType: String.self)
            }
            .onChange(of: hostProfileID) { _, _ in
                timelineItemCache.removeAll()
                cancelPendingTailScrollAttempts()
                historyScrollCoordinator.reset()
                timelineScrollPosition = ScrollPosition(idType: String.self)
                shouldFollowMessageTail = true
                forceNextMessageTailScroll = true
                isTailFollowLocked = displayedSessionID != nil
                timelinePresentationGeneration += 1
                if !messages.isEmpty {
                    HostSwitchSignpost.event("first_text_visible")
                }
            }
            .onChange(of: messages.isEmpty) { _, isEmpty in
                if !isEmpty {
                    HostSwitchSignpost.event("first_text_visible")
                }
            }
            .onChange(of: isHistoryLoading) { _, isLoading in
                guard isLoading,
                      shouldShowInlineHistoryLoading,
                      !isUserScrollingTimeline,
                      (isTimelineNearBottom
                          || isTailFollowLocked
                          || shouldFollowMessageTail
                          || forceNextMessageTailScroll),
                      !isPreservingHistoryScroll
                else {
                    return
                }
                // 加载行位于尾部哨兵之前；仅在用户原本贴底时重锚，避免它插入后落到屏幕外，
                // 同时不抢走用户已经上翻的历史阅读位置。
                queueTailScrollAttempts(
                    timelineItems: timelineItems,
                    proxy: proxy,
                    sessionID: displayedSessionID,
                    expectedTailItemID: timelineItems.last?.id,
                    animatedFirstAttempt: false,
                    force: true
                )
            }
            .onChange(of: isLoadingEarlierHistory) { _, isLoading in
                guard isLoading else {
                    return
                }
                historyScrollCoordinator.preparePrependPreservation(sessionID: displayedSessionID)
            }
            .onChange(of: historyTimelineMutation) { oldMutation, newMutation in
                guard oldMutation != newMutation, newMutation != nil else {
                    return
                }
                // 历史变化不代表用户进入最新上下文。位于尾部时继续贴尾；
                // 阅读历史时，前插页按内容高度差保持视口，Item 补齐按可见行保持视口。
                cancelPendingTailScrollAttempts()
                if isTimelineNearBottom, !isUserScrollingTimeline {
                    queueTailScrollAttempts(
                        timelineItems: timelineItems,
                        proxy: proxy,
                        sessionID: displayedSessionID,
                        expectedTailItemID: timelineItems.last?.id,
                        animatedFirstAttempt: false,
                        force: true
                    )
                    return
                }
                switch newMutation?.kind {
                case .prepend:
                    if let newMutation,
                       let correction = historyScrollCoordinator.armPrependPreservation(
                        mutation: newMutation,
                        sessionID: displayedSessionID
                       ) {
                        queueHistoryPrependCorrection(correction)
                    }
                case .enrichment:
                    historyScrollCoordinator.cancelPrependPreservation()
                    beginVisibleHistoryAnchorPreservation()
                    queueHistoryAnchorCorrection()
                case nil:
                    break
                }
            }
            .onChange(of: observedTailMessageID) { oldValue, newValue in
                guard newValue.value != nil else {
                    return
                }
                guard !Self.isHistoricalTimelineChange(
                    previousGeneration: oldValue.historyMutationGeneration,
                    currentGeneration: newValue.historyMutationGeneration
                ) else {
                    return
                }
                guard !isUserScrollingTimeline else {
                    hasUnseenTailMessage = true
                    return
                }
                // 首条活动会通过 timelineItemIDs 插入并触发尾部跟随；同一批次后续命令
                // 只更新摘要，不再为每个底层消息重复发起滚动。
                if !Self.shouldScheduleTailFollowForNewTailMessage(messages.last) {
                    return
                }
                if Self.shouldForceTailFollow(forNewTailMessage: messages.last) {
                    // 本地发送代表用户明确进入最新上下文；即使滚动几何刚好误判为“不在底部”，
                    // 也要立即贴到尾部，避免发完消息后还停在历史位置。
                    cancelHistoryAnchorPreservation()
                    isTailFollowLocked = true
                    queueTailScrollAttempts(
                        timelineItems: timelineItems,
                        proxy: proxy,
                        sessionID: displayedSessionID,
                        expectedTailItemID: timelineItems.last?.id,
                        animatedFirstAttempt: true,
                        force: true
                    )
                    return
                }
                if forceNextMessageTailScroll {
                    // 首屏/切换会话：List 拿到首页数据后，在下一拍无动画贴底，
                    // 确保落在真正的底部而不是空白区。
                    queueTailScrollAttempts(
                        timelineItems: timelineItems,
                        proxy: proxy,
                        sessionID: displayedSessionID,
                        expectedTailItemID: timelineItems.last?.id,
                        animatedFirstAttempt: false,
                        force: true
                    )
                    return
                }
                queueTailScrollAttempts(
                    timelineItems: timelineItems,
                    proxy: proxy,
                    sessionID: displayedSessionID,
                    expectedTailItemID: timelineItems.last?.id,
                    animatedFirstAttempt: true,
                    force: false
                )
            }
            .onChange(of: observedTailRenderFingerprint) { oldValue, newValue in
                guard !Self.isHistoricalTimelineChange(
                    previousGeneration: oldValue.historyMutationGeneration,
                    currentGeneration: newValue.historyMutationGeneration
                ) else {
                    return
                }
                // 只有助手正文流式增长才需要持续贴底。命令 stdout/stderr 已保存在详情中，
                // 折叠状态下不应驱动滚动请求，否则会形成“日志一条、列表一顿”的观感。
                guard messages.last?.role == .assistant else {
                    return
                }
                guard !isUserScrollingTimeline else {
                    hasUnseenTailMessage = true
                    return
                }
                queueTailScrollAttempts(
                    timelineItems: timelineItems,
                    proxy: proxy,
                    sessionID: displayedSessionID,
                    expectedTailItemID: timelineItems.last?.id,
                    animatedFirstAttempt: false,
                    force: false
                )
            }
            .onChange(of: observedTimelineItemIDs) { oldValue, newValue in
                guard !Self.isHistoricalTimelineChange(
                    previousGeneration: oldValue.historyMutationGeneration,
                    currentGeneration: newValue.historyMutationGeneration
                ) else {
                    return
                }
                // 新活动批次或独立进度行出现时，只有用户原本贴底才继续跟随。
                queueTailScrollAttempts(
                    timelineItems: timelineItems,
                    proxy: proxy,
                    sessionID: displayedSessionID,
                    expectedTailItemID: timelineItems.last?.id,
                    animatedFirstAttempt: false,
                    force: false
                )
            }
            .task(id: timelineListIdentity) {
                guard !timelineItems.isEmpty,
                      presentedTimelineIdentity != timelineListIdentity else {
                    return
                }
                // List 尚不可见时在首轮布局内贴底。尾部哨兵确认可见后再放开正文，
                // 不需要延迟 900ms 后制造一次用户可见的重锚。
                let expectedSessionID = displayedSessionID
                let expectedTailItemID = timelineItems.last?.id
                await Task.yield()
                guard !Task.isCancelled,
                      displayedSessionID == expectedSessionID,
                      currentTimelineTailItemID() == expectedTailItemID else {
                    return
                }
                initialTailScrollAttemptedIdentity = timelineListIdentity
                // List 的 UIKit 快照可能晚于 SwiftUI task 提交。所有重试都发生在稳定遮罩下，
                // 并且只由尾部哨兵真实可见或任务取消来结束，不能用固定次数制造永久空白。
                var attempt = 0
                while true {
                    guard !Task.isCancelled,
                          displayedSessionID == expectedSessionID,
                          currentTimelineTailItemID() == expectedTailItemID,
                          initialTailScrollAttemptedIdentity == timelineListIdentity,
                          presentedTimelineIdentity != timelineListIdentity else {
                        return
                    }
                    forceScrollToTimelineTail(
                        timelineItems: timelineItems,
                        proxy: proxy,
                        animated: false
                    )
                    attempt += 1
                    // 首轮快速覆盖常规 List 快照延迟；慢布局随后降频，避免长历史在
                    // 遮罩期间持续高频占用 MainActor，同时仍能在快照就绪后自行恢复。
                    let retryDelay = attempt <= 8 ? 32_000_000 : 160_000_000
                    do {
                        try await Task.sleep(nanoseconds: UInt64(retryDelay))
                    } catch {
                        return
                    }
                    confirmTimelinePresentationIfReady(
                        timelineListIdentity,
                        hasTimelineContent: true
                    )
                }
            }
            .onDisappear {
                cancelPendingTailScrollAttempts()
                historyScrollCoordinator.reset()
                timelinePresentationGeneration += 1
            }
        }
    }

    @ViewBuilder
    private func timelineRow(
        _ item: ConversationTimelineItem,
        activeUserDeliveryMessageID: UUID?,
        crossSessionOriginMessageID: UUID?,
        proxy: ScrollViewProxy
    ) -> some View {
        switch item {
        case .message(let message):
            MessageRow(
                message: message,
                themeVersion: themeStore.themeVersion,
                layout: layout,
                showsActiveDeliveryStatus: message.id == activeUserDeliveryMessageID,
                showsCrossSessionOrigin: message.id == crossSessionOriginMessageID,
                skills: sessionStore.capabilityList?.skills ?? [],
                retry: { message in
                    Task { await sessionStore.retryFailedUserMessage(message) }
                },
                stop: {
                    sessionStore.interruptSelectedTurn()
                },
                previewFile: { path in
                    try await sessionStore.previewFile(path: path)
                }
            )
                .equatable()
        case .activity(let message):
            ConversationActivityRow(
                message: message,
                layout: layout,
                isExpanded: expandedActivityIDs.contains(item.id),
                toggle: {
                    toggleActivityDetails(itemID: item.id, scrollAnchorID: item.id, proxy: proxy)
                }
            )
                .equatable()
        case .activityBatch(let group):
            ConversationActivityBatchRow(
                group: group,
                layout: layout,
                isExpanded: expandedActivityGroupIDs.contains(group.id),
                expandedActivityIDs: expandedActivityIDs,
                toggleGroup: {
                    toggleActivityGroup(groupID: group.id, proxy: proxy)
                },
                toggleActivity: { message in
                    toggleActivityDetails(
                        itemID: ConversationTimelineItem.activityID(for: message),
                        scrollAnchorID: group.id,
                        proxy: proxy
                    )
                }
            )
                .equatable()
        case .processGroup(let group):
            ConversationProcessGroupRow(
                group: group,
                layout: layout,
                isExpanded: expandedActivityGroupIDs.contains(group.id),
                expandedActivityIDs: expandedActivityIDs,
                toggleGroup: {
                    toggleActivityGroup(groupID: group.id, proxy: proxy)
                },
                toggleActivity: { message in
                    toggleActivityDetails(
                        itemID: ConversationTimelineItem.activityID(for: message),
                        scrollAnchorID: group.id,
                        proxy: proxy
                    )
                }
            )
            .equatable()
        case .workGroup(let group):
            let isExpanded = workGroupExpansionOverrides[group.id] ?? group.defaultIsExpanded
            ConversationWorkGroupRow(
                group: group,
                layout: layout,
                isExpanded: isExpanded,
                toggleGroup: {
                    toggleWorkGroup(
                        group: group,
                        isCurrentlyExpanded: isExpanded,
                        proxy: proxy
                    )
                }
            ) {
                ForEach(group.entries) { entry in
                    workGroupEntryRow(
                        entry,
                        activeUserDeliveryMessageID: activeUserDeliveryMessageID,
                        outerGroupID: group.id,
                        proxy: proxy
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func workGroupEntryRow(
        _ entry: ConversationWorkGroupEntry,
        activeUserDeliveryMessageID: UUID?,
        outerGroupID: String,
        proxy: ScrollViewProxy
    ) -> some View {
        switch entry {
        case .commentary(let message):
            MessageRow(
                message: message,
                themeVersion: themeStore.themeVersion,
                layout: layout,
                showsActiveDeliveryStatus: message.id == activeUserDeliveryMessageID,
                showsCrossSessionOrigin: false,
                skills: sessionStore.capabilityList?.skills ?? [],
                retry: { message in
                    Task { await sessionStore.retryFailedUserMessage(message) }
                },
                stop: {
                    sessionStore.interruptSelectedTurn()
                },
                previewFile: { path in
                    try await sessionStore.previewFile(path: path)
                }
            )
            .equatable()
        case .activity(let message):
            ConversationActivityRow(
                message: message,
                layout: layout,
                isExpanded: expandedActivityIDs.contains(entry.id),
                toggle: {
                    toggleActivityDetails(
                        itemID: entry.id,
                        scrollAnchorID: outerGroupID,
                        proxy: proxy
                    )
                }
            )
            .equatable()
        case .activityBatch(let group):
            ConversationActivityBatchRow(
                group: group,
                layout: layout,
                isExpanded: expandedActivityGroupIDs.contains(group.id),
                expandedActivityIDs: expandedActivityIDs,
                toggleGroup: {
                    toggleActivityGroup(
                        groupID: group.id,
                        scrollAnchorID: outerGroupID,
                        proxy: proxy
                    )
                },
                toggleActivity: { message in
                    toggleActivityDetails(
                        itemID: ConversationTimelineItem.activityID(for: message),
                        scrollAnchorID: outerGroupID,
                        proxy: proxy
                    )
                }
            )
            .equatable()
        case .processGroup(let group):
            ConversationProcessGroupRow(
                group: group,
                layout: layout,
                isExpanded: expandedActivityGroupIDs.contains(group.id),
                expandedActivityIDs: expandedActivityIDs,
                toggleGroup: {
                    toggleActivityGroup(
                        groupID: group.id,
                        scrollAnchorID: outerGroupID,
                        proxy: proxy
                    )
                },
                toggleActivity: { message in
                    toggleActivityDetails(
                        itemID: ConversationTimelineItem.activityID(for: message),
                        scrollAnchorID: outerGroupID,
                        proxy: proxy
                    )
                }
            )
            .equatable()
        }
    }

    private func toggleActivityDetails(
        itemID: String,
        scrollAnchorID: String,
        proxy: ScrollViewProxy
    ) {
        let isExpanding = !expandedActivityIDs.contains(itemID)
        if isExpanding {
            expandedActivityIDs.insert(itemID)
        } else {
            expandedActivityIDs.remove(itemID)
        }
        guard isExpanding, isTimelineNearBottom else {
            return
        }
        Task { @MainActor in
            await Task.yield()
            guard expandedActivityIDs.contains(itemID) else {
                return
            }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(scrollAnchorID, anchor: .bottom)
            }
        }
    }

    private func toggleActivityGroup(
        groupID: String,
        scrollAnchorID: String? = nil,
        proxy: ScrollViewProxy
    ) {
        let isExpanding = !expandedActivityGroupIDs.contains(groupID)
        let updateExpansion = {
            if isExpanding {
                expandedActivityGroupIDs.insert(groupID)
            } else {
                expandedActivityGroupIDs.remove(groupID)
            }
        }
        if accessibilityReduceMotion {
            updateExpansion()
        } else {
            // 无回弹弹簧从当前呈现状态继续，连续点击时不会等待上一段动画结束。
            withAnimation(.spring(response: 0.32, dampingFraction: 1)) {
                updateExpansion()
            }
        }
        guard isExpanding, isTimelineNearBottom else {
            return
        }
        Task { @MainActor in
            await Task.yield()
            guard expandedActivityGroupIDs.contains(groupID) else {
                return
            }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(scrollAnchorID ?? groupID, anchor: .bottom)
            }
        }
    }

    private func toggleWorkGroup(
        group: ConversationWorkGroup,
        isCurrentlyExpanded: Bool,
        proxy: ScrollViewProxy
    ) {
        let isExpanding = !isCurrentlyExpanded
        let updateExpansion = {
            // 不删除等于默认值的 override：用户选择必须在 running→terminal 后继续优先。
            workGroupExpansionOverrides[group.id] = isExpanding
        }
        if accessibilityReduceMotion {
            updateExpansion()
        } else {
            withAnimation(.spring(response: 0.32, dampingFraction: 1)) {
                updateExpansion()
            }
        }
        guard isExpanding, isTimelineNearBottom else {
            return
        }
        Task { @MainActor in
            await Task.yield()
            guard workGroupExpansionOverrides[group.id] == true else {
                return
            }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(group.id, anchor: .bottom)
            }
        }
    }

    private static func activeUserDeliveryMessageID(in messages: [ConversationMessage]) -> UUID? {
        // 只把“最新一条还没看到 assistant 回复的用户输入”标成活跃发送态；
        // assistant 气泡一出现，等待文案就收起，避免旧消息长期挂着“等待回复”。
        for message in messages.reversed() {
            if message.role == .assistant && message.kind == .message {
                return nil
            }
            if message.role == .user,
               message.kind == .message,
               message.sendStatus == .sending || message.sendStatus == .sent || message.sendStatus == .failed {
                return message.id
            }
        }
        return nil
    }

    private static func crossSessionOriginMessageID(
        session: AgentSession?,
        messages: [ConversationMessage]
    ) -> UUID? {
        guard let initialUserMessage = messages.first(where: {
            $0.role == .user && $0.kind == .message
        }),
        ConversationOriginPresentation.isCreatedFromAnotherConversation(
            session: session,
            initialUserContent: initialUserMessage.content
        ) else {
            return nil
        }
        return initialUserMessage.id
    }

    private static func isOptimisticSessionID(_ sessionID: SessionID?) -> Bool {
        sessionID?.hasPrefix("local:") == true
    }

    private var userScrollAwayFromTailGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard value.translation.height > 12 else {
                    return
                }
                guard isTailFollowLocked || shouldFollowMessageTail || tailScrollCoordinator.pendingTask != nil else {
                    return
                }
                // 用户向下拖动列表是在主动回看更早内容；解除本轮发送后的尾部跟随锁。
                isTailFollowLocked = false
                shouldFollowMessageTail = false
                tailScrollCoordinator.userScrollAwayGeneration += 1
                cancelPendingTailScrollAttempts()
            }
    }

    static func shouldForceTailFollow(forNewTailMessage message: ConversationMessage?) -> Bool {
        guard let message else {
            return false
        }
        return message.role == .user
            && message.kind == .message
            && message.clientMessageID != nil
    }

    static func shouldScheduleTailFollowForNewTailMessage(_ message: ConversationMessage?) -> Bool {
        message?.role != .system
    }

    static func isHistoricalTimelineChange(
        previousGeneration: UInt64?,
        currentGeneration: UInt64?
    ) -> Bool {
        currentGeneration != nil && previousGeneration != currentGeneration
    }

    static func historyPreservedOffset(
        currentOffsetY: CGFloat,
        currentAnchorMinY: CGFloat,
        baselineAnchorMinY: CGFloat,
        minimumOffsetY: CGFloat,
        maximumOffsetY: CGFloat
    ) -> CGFloat {
        let upperBound = max(minimumOffsetY, maximumOffsetY)
        let corrected = currentOffsetY + currentAnchorMinY - baselineAnchorMinY
        return min(upperBound, max(minimumOffsetY, corrected))
    }

    static func historyPrependPreservedOffset(
        baselineOffsetY: CGFloat,
        baselineContentHeight: CGFloat,
        currentContentHeight: CGFloat,
        minimumOffsetY: CGFloat,
        maximumOffsetY: CGFloat
    ) -> CGFloat {
        let upperBound = max(minimumOffsetY, maximumOffsetY)
        let corrected = baselineOffsetY + currentContentHeight - baselineContentHeight
        return min(upperBound, max(minimumOffsetY, corrected))
    }

    static func shouldSuspendTimelineUpdates(for phase: ScrollPhase) -> Bool {
        switch phase {
        case .tracking, .interacting, .decelerating:
            return true
        case .idle, .animating:
            return false
        }
    }

    static func shouldAttemptTailScroll(
        force: Bool,
        shouldFollowMessageTail: Bool,
        forceNextMessageTailScroll: Bool,
        isTailFollowLocked: Bool,
        isTimelineNearBottom: Bool
    ) -> Bool {
        force ||
            shouldFollowMessageTail ||
            forceNextMessageTailScroll ||
            isTailFollowLocked ||
            isTimelineNearBottom
    }

    static func shouldShowInlineHistoryLoading(
        timelineItemsAreEmpty: Bool,
        isHistoryLoading: Bool,
        isLoadingEarlierHistory: Bool,
        hasHistorySavingsNotice: Bool
    ) -> Bool {
        !timelineItemsAreEmpty
            && isHistoryLoading
            && !isLoadingEarlierHistory
            && !hasHistorySavingsNotice
    }

    static func shouldPresentStabilizedTimeline(
        hasTimelineContent: Bool,
        didAttemptInitialTailScroll: Bool,
        isTailSentinelVisible: Bool
    ) -> Bool {
        hasTimelineContent && didAttemptInitialTailScroll && isTailSentinelVisible
    }

    private var loadEarlierRow: some View {
        HStack {
            Spacer()
            Button {
                let sessionID = displayedSessionID
                Task { @MainActor in
                    await loadEarlierHistory(sessionID: sessionID)
                }
            } label: {
                if sessionStore.isLoadingEarlierHistory(sessionID: displayedSessionID) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(workbenchSecondaryText)
                } else {
                    Label(L10n.text("ui.load_older_messages"), systemImage: "clock.arrow.circlepath")
                }
            }
            .font(themeStore.uiFont(.caption, weight: .medium))
            .buttonStyle(.borderless)
            .foregroundStyle(workbenchSecondaryText)
            .disabled(
                sessionStore.isLoadingEarlierHistory(sessionID: displayedSessionID)
                    || isPreservingHistoryScroll
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(statusChipBackground, in: Capsule())
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var historyLoadingRow: some View {
        HStack {
            HStack(alignment: .center, spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                    .tint(workbenchSecondaryText)
                Text(L10n.text("ui.loading_session_records"))
                    .font(themeStore.uiFont(.caption, weight: .medium))
                    .foregroundStyle(workbenchSecondaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(statusChipBackground, in: Capsule())
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("conversation.historyLoading")
        .accessibilityLabel(L10n.text("ui.loading_session_records"))
        .allowsHitTesting(false)
    }

    private func scrollMetrics(for geometry: ScrollGeometry) -> ConversationTimelineScrollMetrics {
        // 距底部多远用滚动几何直接算，不依赖某个具体行是否还被实例化。
        let distanceFromBottom = geometry.contentSize.height - geometry.visibleRect.maxY
        let minimumOffsetY = -geometry.contentInsets.top
        let maximumOffsetY = max(
            minimumOffsetY,
            geometry.contentSize.height - geometry.containerSize.height + geometry.contentInsets.bottom
        )
        return ConversationTimelineScrollMetrics(
            isNearBottom: distanceFromBottom <= messageTailFollowThreshold,
            contentOffsetY: geometry.contentOffset.y,
            contentHeight: geometry.contentSize.height,
            minimumOffsetY: minimumOffsetY,
            maximumOffsetY: maximumOffsetY
        )
    }

    private func shouldShowReturnToTailButton(timelineItems: [ConversationTimelineItem]) -> Bool {
        !timelineItems.isEmpty && !isPreservingHistoryScroll && (hasUnseenTailMessage || !isTimelineNearBottom)
    }

    private var returnToTailAccessibilityLabel: String {
        hasUnseenTailMessage ? L10n.text("ui.return_to_the_bottom_to_view_new_messages") : L10n.text("ui.back_to_latest_news")
    }

    private var emptyState: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        return VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(themeStore.uiFont(size: 24, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tokens.primaryAction)
                .frame(width: 52, height: 52)
                .background(tokens.accentSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(spacing: 6) {
                Text(L10n.text("ui.start_this_conversation"))
                    .font(themeStore.uiFont(.headline, weight: .semibold))
                    .foregroundStyle(workbenchPrimaryText)
                Text(L10n.text("ui.enter_your_tasks_below_and_mimi_remote_retains"))
                    .font(themeStore.uiFont(.callout))
                    .foregroundStyle(workbenchSecondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: layout.emptyStateMaxWidth)
            }

            if let directoryPath = emptyStateDirectoryPath {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(themeStore.uiFont(.caption, weight: .semibold))
                        .foregroundStyle(tokens.primaryAction)

                    Text(directoryPath)
                        .font(themeStore.uiFont(.caption))
                        .foregroundStyle(workbenchSecondaryText)
                        .lineLimit(1)
                        // 中间截断同时保留根路径和末级目录名，长路径也不会撑破空状态卡。
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(tokens.elevatedSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(tokens.border.opacity(0.45), lineWidth: 1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.format("ui.directory_value", directoryPath))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 26)
        .frame(maxWidth: layout.emptyStateMaxWidth)
        .background(tokens.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(tokens.border.opacity(0.58), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(tokens.resolvedScheme == .light ? 0.045 : 0.16), radius: 12, y: 5)
        .frame(maxWidth: .infinity)
    }

    private var emptyStateDirectoryPath: String? {
        let candidates = [
            displayedSessionID.flatMap { sessionStore.sessionsByID[$0]?.dir },
            sessionStore.selectedProject?.path
        ]
        for candidate in candidates {
            let path = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !path.isEmpty {
                return path
            }
        }
        return nil
    }

    @ViewBuilder
    private func timelineEmptyState(isHistoryLoading: Bool) -> some View {
        if isHistoryLoading {
            ProgressView(L10n.text("ui.loading_session_records"))
                .accessibilityLabel(L10n.text("ui.loading_session_records"))
        } else if let error = sessionStore.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
            ContentUnavailableView {
                Label(L10n.text("ui.session_record_loading_failed"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button(L10n.text("ui.try_again")) {
                    Task { await sessionStore.refreshCurrentContext() }
                }
                .buttonStyle(.bordered)
            }
        } else {
            emptyState
        }
    }

    private var statusChipBackground: Color {
        themeStore.tokens(for: colorScheme).elevatedSurface
    }

    private var workbenchPrimaryText: Color {
        themeStore.tokens(for: colorScheme).primaryText
    }

    private var workbenchSecondaryText: Color {
        themeStore.tokens(for: colorScheme).secondaryText
    }

    private func forceScrollToTimelineTail(
        timelineItems: [ConversationTimelineItem],
        proxy: ScrollViewProxy,
        animated: Bool
    ) {
        guard !timelineItems.isEmpty else {
            return
        }
        guard !isPreservingHistoryScroll else {
            return
        }
        shouldFollowMessageTail = true
        hasUnseenTailMessage = false
        forceNextMessageTailScroll = false
        scrollToTimelineTail(proxy: proxy, animated: animated)
    }

    private func queueTailScrollAttempts(
        timelineItems: [ConversationTimelineItem],
        proxy: ScrollViewProxy,
        sessionID: SessionID?,
        expectedTailItemID: String?,
        animatedFirstAttempt: Bool,
        force: Bool
    ) {
        guard let sessionID, let expectedTailItemID, !timelineItems.isEmpty else {
            return
        }
        guard !isPreservingHistoryScroll else {
            return
        }
        guard Self.shouldAttemptTailScroll(
            force: force,
            shouldFollowMessageTail: shouldFollowMessageTail,
            forceNextMessageTailScroll: forceNextMessageTailScroll,
            isTailFollowLocked: isTailFollowLocked,
            isTimelineNearBottom: isTimelineNearBottom
        ) else {
            hasUnseenTailMessage = true
            return
        }

        // 消息 ID、内容指纹和派生行 ID 可能在同一帧一起变化。先取消旧请求并让出一次
        // MainActor 更新周期，等 List 提交完当前快照后再滚动。后续内容增高由滚动几何
        // 变化再次触发，不使用固定延时重复写入位置。
        tailScrollCoordinator.pendingTask?.cancel()
        tailScrollCoordinator.attemptGeneration += 1
        let attemptGeneration = tailScrollCoordinator.attemptGeneration
        let scrollAwayGeneration = tailScrollCoordinator.userScrollAwayGeneration
        tailScrollCoordinator.pendingTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled,
                  tailScrollCoordinator.attemptGeneration == attemptGeneration,
                  tailScrollCoordinator.userScrollAwayGeneration == scrollAwayGeneration,
                  displayedSessionID == sessionID,
                  currentTimelineTailItemID() == expectedTailItemID,
                  !isPreservingHistoryScroll
            else {
                return
            }
            forceScrollToTimelineTail(
                timelineItems: timelineItems,
                proxy: proxy,
                animated: animatedFirstAttempt
            )
        }
    }

    private func cancelPendingTailScrollAttempts() {
        tailScrollCoordinator.pendingTask?.cancel()
        tailScrollCoordinator.pendingTask = nil
        tailScrollCoordinator.attemptGeneration += 1
    }

    private func returnToTimelineTail(
        timelineItems: [ConversationTimelineItem],
        proxy: ScrollViewProxy
    ) {
        cancelHistoryAnchorPreservation()
        hasUnseenTailMessage = false
        shouldFollowMessageTail = true
        isTailFollowLocked = true
        isTimelineNearBottom = true
        queueTailScrollAttempts(
            timelineItems: timelineItems,
            proxy: proxy,
            sessionID: displayedSessionID,
            expectedTailItemID: timelineItems.last?.id,
            animatedFirstAttempt: true,
            force: true
        )
    }

    private func scrollToTimelineTail(proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(Self.timelineTailSentinelID, anchor: .bottom)
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(Self.timelineTailSentinelID, anchor: .bottom)
            }
        }
    }

    @MainActor
    private func loadEarlierHistory(sessionID: SessionID?) async {
        guard !isPreservingHistoryScroll else {
            return
        }
        // 加载更早是向上 prepend，期间屏蔽尾部跟随，避免阅读位置被打断。
        cancelPendingTailScrollAttempts()
        isPreservingHistoryScroll = true
        shouldFollowMessageTail = false
        forceNextMessageTailScroll = false
        hasUnseenTailMessage = false
        defer { isPreservingHistoryScroll = false }

        if let sessionID {
            await sessionStore.loadEarlierHistory(sessionID: sessionID)
        }
    }

    private func recordHistoryAnchorGeometry(itemID: String, minY: CGFloat) {
        historyScrollCoordinator.updateAnchorMinY(itemID, minY)
        queueHistoryAnchorCorrection()
    }

    private func beginVisibleHistoryAnchorPreservation() {
        guard !isUserScrollingTimeline,
              !isTimelineNearBottom,
              historyScrollCoordinator.activeGeneration == nil,
              let itemID = timelineScrollPosition.viewID(type: String.self),
              itemID != Self.timelineTailSentinelID,
              let baselineMinY = historyScrollCoordinator.anchorMinY(itemID)
        else {
            return
        }
        _ = historyScrollCoordinator.beginPreserving(
            sessionID: displayedSessionID,
            itemID: itemID,
            baselineMinY: baselineMinY
        )
    }

    private func queueHistoryAnchorCorrection(expectedGeneration: Int? = nil) {
        historyScrollCoordinator.scheduleCorrection(
            expectedGeneration: expectedGeneration,
            displayedSessionID: displayedSessionID
        ) { correction in
            applyHistoryAnchorCorrection(correction)
        }
    }

    private func applyHistoryAnchorCorrection(_ correction: ConversationHistoryAnchorCorrection) {
        let targetOffsetY = Self.historyPreservedOffset(
            currentOffsetY: correction.metrics.contentOffsetY,
            currentAnchorMinY: correction.currentAnchorMinY,
            baselineAnchorMinY: correction.baselineAnchorMinY,
            minimumOffsetY: correction.metrics.minimumOffsetY,
            maximumOffsetY: correction.metrics.maximumOffsetY
        )
        guard abs(targetOffsetY - correction.metrics.contentOffsetY) >= 0.5 else {
            return
        }
        historyScrollCoordinator.setContentOffsetY(targetOffsetY)
    }

    private func queueHistoryPrependCorrection(_ correction: ConversationHistoryPrependCorrection) {
        historyScrollCoordinator.schedulePrependCorrection(correction) { correction in
            applyHistoryPrependCorrection(correction)
        }
    }

    private func applyHistoryPrependCorrection(_ correction: ConversationHistoryPrependCorrection) {
        let targetOffsetY = Self.historyPrependPreservedOffset(
            baselineOffsetY: correction.baselineOffsetY,
            baselineContentHeight: correction.baselineContentHeight,
            currentContentHeight: correction.metrics.contentHeight,
            minimumOffsetY: correction.metrics.minimumOffsetY,
            maximumOffsetY: correction.metrics.maximumOffsetY
        )
        guard abs(targetOffsetY - correction.metrics.contentOffsetY) >= 0.5 else {
            return
        }
        historyScrollCoordinator.setContentOffsetY(targetOffsetY)
    }

    private func cancelHistoryAnchorPreservation() {
        historyScrollCoordinator.cancelPreservation()
        isPreservingHistoryScroll = false
    }

    private func currentTimelineTailItemID() -> String? {
        timelineItemCache.tailItemID
    }

    private func confirmTimelinePresentationIfReady(
        _ identity: ConversationTimelineListIdentity,
        hasTimelineContent: Bool
    ) {
        guard Self.shouldPresentStabilizedTimeline(
            hasTimelineContent: hasTimelineContent,
            didAttemptInitialTailScroll: initialTailScrollAttemptedIdentity == identity,
            isTailSentinelVisible: visibleTailSentinelIdentity == identity
        ) else {
            return
        }
        presentedTimelineIdentity = identity
    }
}

private struct ConversationTimelineListIdentity: Hashable {
    let scope: ScopedSessionID
    let hasTimelineContent: Bool
    let presentationGeneration: Int
}

private struct ConversationTimelineObservedChange<Value: Equatable>: Equatable {
    let value: Value
    let historyMutationGeneration: UInt64?
}

struct ConversationTimelineScrollMetrics: Equatable {
    let isNearBottom: Bool
    let contentOffsetY: CGFloat
    let contentHeight: CGFloat
    let minimumOffsetY: CGFloat
    let maximumOffsetY: CGFloat
}

struct ConversationHistoryAnchorCorrection {
    let baselineAnchorMinY: CGFloat
    let currentAnchorMinY: CGFloat
    let metrics: ConversationTimelineScrollMetrics
}

struct ConversationHistoryPrependCorrection {
    let baselineOffsetY: CGFloat
    let baselineContentHeight: CGFloat
    let metrics: ConversationTimelineScrollMetrics
}

private struct ConversationHistoryAnchorGeometryModifier: ViewModifier {
    let isEnabled: Bool
    let itemID: String
    let action: (String, CGFloat) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.onGeometryChange(for: CGFloat.self) { geometry in
                geometry.frame(in: .global).minY
            } action: { minY in
                action(itemID, minY)
            }
        } else {
            content
        }
    }
}

private struct ConversationTimelineScrollViewLocator: UIViewRepresentable {
    let onResolve: (UIScrollView) -> Void

    func makeUIView(context: Context) -> LocatorView {
        let view = LocatorView()
        view.onResolve = onResolve
        return view
    }

    func updateUIView(_ uiView: LocatorView, context: Context) {
        uiView.onResolve = onResolve
        uiView.resolveIfNeeded()
    }

    final class LocatorView: UIView {
        var onResolve: ((UIScrollView) -> Void)?
        private weak var resolvedScrollView: UIScrollView?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            resolveIfNeeded()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            resolveIfNeeded()
        }

        func resolveIfNeeded() {
            var ancestor = superview
            while let view = ancestor {
                if let scrollView = view as? UIScrollView {
                    guard scrollView !== resolvedScrollView else {
                        return
                    }
                    resolvedScrollView = scrollView
                    onResolve?(scrollView)
                    return
                }
                ancestor = view.superview
            }
        }
    }
}

private struct ConversationTimelineStabilizingCover: UIViewRepresentable {
    let backgroundColor: UIColor

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = backgroundColor
        view.accessibilityIdentifier = ConversationTimelineView.stabilizingCoverAccessibilityIdentifier
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        uiView.backgroundColor = backgroundColor
    }
}

/// 回到底部按钮和滚动实现放在同一文件，避免为单个私有控件扩张工程文件清单。
private struct ConversationReturnToTailButton: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    let tokens: ThemeTokens
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            buttonLabel
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("conversation.returnToTail")
    }

    private var buttonLabel: some View {
        baseLabel
            // 与顶栏按钮、侧栏控件、工作区胶囊共用同一档扁平磨砂。这里原本用
            // `.glassEffect(.regular.interactive())`，浮在 Composer 正上方时就是一屏里
            // 第二种玻璃浓度——「回到底部」比输入卡还亮，反而抢了视线。
            // 描边和阴影保留：这枚按钮浮在滚动正文之上，需要边界和高度差才读得出层级。
            .background { WorkbenchChromeMaterial(shape: Circle(), tokens: tokens) }
            .overlay {
                Circle()
                    .stroke(
                        colorScheme == .light
                            ? Color.black.opacity(reduceTransparency ? 0.22 : 0.10)
                            : Color.white.opacity(reduceTransparency ? 0.28 : 0.14),
                        lineWidth: 0.75
                    )
            }
            .shadow(
                color: Color.black.opacity(reduceTransparency ? 0.12 : 0.07),
                radius: 6,
                y: 2
            )
    }

    private var baseLabel: some View {
        Image(systemName: "arrow.down")
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(tokens.primaryText)
            .frame(width: 48, height: 48)
    }
}

@MainActor
private final class ConversationTailScrollCoordinator {
    var pendingTask: Task<Void, Never>?
    var attemptGeneration = 0
    var userScrollAwayGeneration = 0
}

@MainActor
final class ConversationHistoryScrollCoordinator {
    private struct ActiveAnchor {
        let generation: Int
        let sessionID: SessionID?
        let itemID: String
        let baselineMinY: CGFloat
    }

    private struct ActivePrepend {
        let generation: Int
        let sessionID: SessionID?
        let baselineOffsetY: CGFloat
        let baselineContentHeight: CGFloat
        let mutationGeneration: UInt64?
    }

    private enum ActivePreservation {
        case anchor(ActiveAnchor)
        case prepend(ActivePrepend)

        var generation: Int {
            switch self {
            case .anchor(let anchor):
                anchor.generation
            case .prepend(let prepend):
                prepend.generation
            }
        }
    }

    private var activePreservation: ActivePreservation?
    private var anchorMinYByItemID: [String: CGFloat] = [:]
    private var metrics: ConversationTimelineScrollMetrics?
    private weak var scrollView: UIScrollView?
    private var generation = 0
    private var correctionTask: Task<Void, Never>?

    var activeGeneration: Int? {
        activePreservation?.generation
    }

    var activeAnchorItemID: String? {
        activeAnchor?.itemID
    }

    private var activeAnchor: ActiveAnchor? {
        guard case .anchor(let anchor) = activePreservation else {
            return nil
        }
        return anchor
    }

    private var activePrepend: ActivePrepend? {
        guard case .prepend(let prepend) = activePreservation else {
            return nil
        }
        return prepend
    }

    func updateAnchorMinY(_ itemID: String, _ minY: CGFloat) {
        anchorMinYByItemID[itemID] = minY
    }

    func bind(scrollView: UIScrollView) {
        self.scrollView = scrollView
    }

    func setContentOffsetY(_ offsetY: CGFloat) {
        guard let scrollView else {
            return
        }
        let target = CGPoint(x: scrollView.contentOffset.x, y: offsetY)
        guard abs(target.y - scrollView.contentOffset.y) >= 0.5 else {
            return
        }
        scrollView.setContentOffset(target, animated: false)
    }

    func anchorMinY(_ itemID: String) -> CGFloat? {
        anchorMinYByItemID[itemID]
    }

    @discardableResult
    func update(metrics newMetrics: ConversationTimelineScrollMetrics) -> ConversationHistoryPrependCorrection? {
        metrics = newMetrics
        return takePrependCorrection(currentMetrics: newMetrics)
    }

    func preparePrependPreservation(sessionID: SessionID?) {
        cancelPreservation()
        guard let metrics else {
            return
        }
        generation += 1
        activePreservation = .prepend(ActivePrepend(
            generation: generation,
            sessionID: sessionID,
            baselineOffsetY: metrics.contentOffsetY,
            baselineContentHeight: metrics.contentHeight,
            mutationGeneration: nil
        ))
    }

    func armPrependPreservation(
        mutation: ConversationHistoryTimelineMutation,
        sessionID: SessionID?
    ) -> ConversationHistoryPrependCorrection? {
        guard mutation.kind == .prepend,
              let activePrepend,
              activePrepend.sessionID == sessionID,
              activePrepend.mutationGeneration == nil else {
            return nil
        }
        activePreservation = .prepend(ActivePrepend(
            generation: activePrepend.generation,
            sessionID: activePrepend.sessionID,
            baselineOffsetY: activePrepend.baselineOffsetY,
            baselineContentHeight: activePrepend.baselineContentHeight,
            mutationGeneration: mutation.generation
        ))
        guard let metrics else {
            return nil
        }
        return takePrependCorrection(currentMetrics: metrics)
    }

    private func takePrependCorrection(
        currentMetrics: ConversationTimelineScrollMetrics
    ) -> ConversationHistoryPrependCorrection? {
        guard let activePrepend,
              activePrepend.mutationGeneration != nil,
              abs(currentMetrics.contentHeight - activePrepend.baselineContentHeight) >= 0.5 else {
            return nil
        }
        activePreservation = nil
        correctionTask?.cancel()
        correctionTask = nil
        return ConversationHistoryPrependCorrection(
            baselineOffsetY: activePrepend.baselineOffsetY,
            baselineContentHeight: activePrepend.baselineContentHeight,
            metrics: currentMetrics
        )
    }

    func cancelPrependPreservation() {
        guard activePrepend != nil else {
            return
        }
        cancelPreservation()
    }

    func beginPreserving(
        sessionID: SessionID?,
        itemID: String?,
        baselineMinY: CGFloat?
    ) -> Int? {
        cancelPreservation()
        guard let itemID, let baselineMinY else {
            return nil
        }
        generation += 1
        activePreservation = .anchor(ActiveAnchor(
            generation: generation,
            sessionID: sessionID,
            itemID: itemID,
            baselineMinY: baselineMinY
        ))
        return generation
    }

    func correction(
        expectedGeneration: Int,
        displayedSessionID: SessionID?
    ) -> ConversationHistoryAnchorCorrection? {
        guard let activeAnchor,
              activeAnchor.generation == expectedGeneration,
              activeAnchor.sessionID == displayedSessionID,
              let currentAnchorMinY = anchorMinYByItemID[activeAnchor.itemID],
              let metrics else {
            return nil
        }
        return ConversationHistoryAnchorCorrection(
            baselineAnchorMinY: activeAnchor.baselineMinY,
            currentAnchorMinY: currentAnchorMinY,
            metrics: metrics
        )
    }

    func scheduleCorrection(
        expectedGeneration: Int? = nil,
        displayedSessionID: SessionID?,
        apply: @escaping @MainActor (ConversationHistoryAnchorCorrection) -> Void
    ) {
        guard let generation = expectedGeneration ?? activeAnchor?.generation,
              activeAnchor?.generation == generation else {
            return
        }
        correctionTask?.cancel()
        correctionTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled,
                  let self,
                  let correction = self.correction(
                    expectedGeneration: generation,
                    displayedSessionID: displayedSessionID
                  ) else {
                return
            }
            apply(correction)
        }
    }

    func schedulePrependCorrection(
        _ correction: ConversationHistoryPrependCorrection,
        apply: @escaping @MainActor (ConversationHistoryPrependCorrection) -> Void
    ) {
        correctionTask?.cancel()
        correctionTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else {
                return
            }
            apply(correction)
        }
    }

    func cancelPreservation(expectedGeneration: Int? = nil) {
        if let expectedGeneration, activePreservation?.generation != expectedGeneration {
            return
        }
        activePreservation = nil
        correctionTask?.cancel()
        correctionTask = nil
    }

    func reset() {
        cancelPreservation()
        anchorMinYByItemID.removeAll()
        metrics = nil
    }
}

private enum KeyboardDismissal {
    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
