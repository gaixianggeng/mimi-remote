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
    @State private var isUserScrollingTimeline = false

    private let messageTailFollowThreshold: CGFloat = 120
    private static let timelineTailSentinelID = "__conversation_timeline_safe_tail__"

    init(layout: ConversationLayout, sessionID: SessionID? = nil) {
        self.layout = layout
        explicitSessionID = sessionID
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
        let tailFollowTaskKey = Self.tailFollowTaskKey(
            sessionID: displayedSessionID,
            tailItemID: timelineItems.last?.id
        )
        let activeUserDeliveryMessageID = Self.activeUserDeliveryMessageID(in: messages)
        let crossSessionOriginMessageID = Self.crossSessionOriginMessageID(
            session: displayedSessionID.flatMap { sessionStore.sessionsByID[$0] },
            messages: messages
        )
        let isHistoryLoading = sessionStore.historyLoadProgress(sessionID: displayedSessionID) != nil
        let shouldShowInlineHistoryLoading = Self.shouldShowInlineHistoryLoading(
            timelineItemsAreEmpty: timelineItems.isEmpty,
            isHistoryLoading: isHistoryLoading,
            isLoadingEarlierHistory: sessionStore.isLoadingEarlierHistory(sessionID: displayedSessionID),
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
                                loadEarlierRow(proxy: proxy, timelineItems: timelineItems)
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
                            .id(Self.timelineTailSentinelID)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                // 每个会话使用独立的 List 身份，避免复用上一个会话的 contentOffset；
                // 挂载后再定位到固定尾部哨兵。
                .id(ScopedSessionID(
                    profileID: hostProfileID,
                    sessionID: displayedSessionID ?? "__none__"
                ))
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .background(tokens.conversationCanvasBackground)
                // Composer 是唯一的底部功能材质；时间线只在它后方留一层柔和渐隐，
                // 不再在输入区外侧切出一整块与页面不同的底色。
                .workbenchSoftBottomScrollEdge()
                .simultaneousGesture(TapGesture().onEnded {
                    KeyboardDismissal.dismiss()
                })
                .simultaneousGesture(userScrollAwayFromTailGesture)
                // 是否贴近底部用滚动几何实时判断，只在贴底时跟随流式输出，
                // 用户上翻历史时不会被尾部更新甩回底部。
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    isNearBottom(geometry)
                } action: { _, nearBottom in
                    isTimelineNearBottom = nearBottom
                    if nearBottom {
                        shouldFollowMessageTail = true
                        hasUnseenTailMessage = false
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
                        return
                    }
                    // 手指驱动滚动时优先保证交互帧率：停止旧的尾部重锚任务，
                    // 流式消息在 Store 中继续累计，滚动结束后再一次性刷新 List。
                    isTailFollowLocked = false
                    shouldFollowMessageTail = false
                    tailScrollCoordinator.userScrollAwayGeneration += 1
                    cancelPendingTailScrollAttempts()
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
                expandedActivityIDs.removeAll()
                expandedActivityGroupIDs.removeAll()
                workGroupExpansionOverrides.removeAll()
                timelineItemCache.removeAll()
                cancelPendingTailScrollAttempts()
                if newID != nil {
                    // onChange 与新 body 的 task(id:) 在高负载下没有固定先后顺序；闭包捕获的
                    // timelineItems 可能仍属于 oldID。必须按 newID 重新取值，否则旧尾 ID 会
                    // 取消正确的新会话滚动任务，最终停在上一会话的 contentOffset。
                    let newTimelineItems = timelineItemCache.snapshot(
                        from: conversationStore.messages(for: newID)
                    ).items
                    queueTailScrollAttempts(
                        timelineItems: newTimelineItems,
                        proxy: proxy,
                        sessionID: newID,
                        expectedTailItemID: newTimelineItems.last?.id,
                        animatedFirstAttempt: false,
                        force: true
                    )
                }
            }
            .onChange(of: hostProfileID) { _, _ in
                timelineItemCache.removeAll()
                cancelPendingTailScrollAttempts()
                shouldFollowMessageTail = true
                forceNextMessageTailScroll = true
                isTailFollowLocked = displayedSessionID != nil
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
                    force: true,
                    retriesAfterLayout: false
                )
            }
            .onChange(of: messages.last?.id) { _, newID in
                guard newID != nil else {
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
                    // 首屏/切换会话：List 拿到首页数据后无动画贴底，并在下一拍补一次，
                    // 覆盖首次布局时机，确保落在真正的底部而不是空白区。
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
            .onChange(of: messages.last?.renderFingerprint) { _, _ in
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
                    force: false,
                    retriesAfterLayout: false
                )
            }
            .onChange(of: timelineItemIDs) { _, _ in
                // 新活动批次或独立进度行出现时，只有用户原本贴底才继续跟随。
                queueTailScrollAttempts(
                    timelineItems: timelineItems,
                    proxy: proxy,
                    sessionID: displayedSessionID,
                    expectedTailItemID: timelineItems.last?.id,
                    animatedFirstAttempt: false,
                    force: false,
                    retriesAfterLayout: false
                )
            }
            .task(id: tailFollowTaskKey) {
                guard tailFollowTaskKey != nil else {
                    return
                }
                // 进入一个已经有缓存消息的会话时，messages.last 不一定再触发 onChange；
                // 用 task(id:) 补一条首帧重锚路径，避免 List 默认停在最早消息。
                queueTailScrollAttempts(
                    timelineItems: timelineItems,
                    proxy: proxy,
                    sessionID: displayedSessionID,
                    expectedTailItemID: timelineItems.last?.id,
                    animatedFirstAttempt: false,
                    // 首次打开/切换会话不能被尚未稳定的滚动几何拦截；
                    // 后续新消息仍尊重用户主动上翻，不会强行抢回底部。
                    force: forceNextMessageTailScroll
                )
            }
            .onDisappear {
                cancelPendingTailScrollAttempts()
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

    private func loadEarlierRow(proxy: ScrollViewProxy, timelineItems: [ConversationTimelineItem]) -> some View {
        HStack {
            Spacer()
            Button {
                let sessionID = displayedSessionID
                // prepend 后把原来最早的一条滚回顶部，保住用户当前阅读位置。
                let anchorID = timelineItems.first?.id
                Task { @MainActor in
                    await loadEarlierHistory(preserving: anchorID, sessionID: sessionID, proxy: proxy)
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
            .disabled(sessionStore.isLoadingEarlierHistory(sessionID: displayedSessionID))
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

    private func isNearBottom(_ geometry: ScrollGeometry) -> Bool {
        // 距底部多远用滚动几何直接算，不依赖某个具体行是否还被实例化。
        let distanceFromBottom = geometry.contentSize.height - geometry.visibleRect.maxY
        return distanceFromBottom <= messageTailFollowThreshold
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
        isTimelineNearBottom = true
        forceNextMessageTailScroll = false
        scrollToTimelineTail(proxy: proxy, animated: animated)
    }

    private func queueTailScrollAttempts(
        timelineItems: [ConversationTimelineItem],
        proxy: ScrollViewProxy,
        sessionID: SessionID?,
        expectedTailItemID: String?,
        animatedFirstAttempt: Bool,
        force: Bool,
        retriesAfterLayout: Bool = true
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
        // MainActor 更新周期，等 List 提交完当前快照后再滚动，避免并发滚动互相覆盖。
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

            guard retriesAfterLayout else {
                return
            }
            // 首次挂载和 Markdown 排版可能跨布局周期完成，只保留一次兜底重锚。
            // 后续真实快照变化仍会由 onChange 重新调度，不再固定制造四次 scrollTo。
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled,
                  tailScrollCoordinator.attemptGeneration == attemptGeneration,
                  tailScrollCoordinator.userScrollAwayGeneration == scrollAwayGeneration,
                  displayedSessionID == sessionID,
                  currentTimelineTailItemID() == expectedTailItemID,
                  !isPreservingHistoryScroll
            else {
                return
            }
            forceScrollToTimelineTail(timelineItems: timelineItems, proxy: proxy, animated: false)
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
            force: true,
            retriesAfterLayout: false
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
    private func loadEarlierHistory(
        preserving anchorID: String?,
        sessionID: SessionID?,
        proxy: ScrollViewProxy
    ) async {
        guard !isPreservingHistoryScroll else {
            return
        }
        // 加载更早是向上 prepend，期间屏蔽尾部跟随，避免阅读位置被打断。
        isPreservingHistoryScroll = true
        shouldFollowMessageTail = false
        forceNextMessageTailScroll = false
        hasUnseenTailMessage = false
        defer { isPreservingHistoryScroll = false }

        if let sessionID {
            await sessionStore.loadEarlierHistory(sessionID: sessionID)
        }
        guard displayedSessionID == sessionID, let anchorID else {
            return
        }
        await Task.yield()
        restoreHistoryAnchor(anchorID, proxy: proxy)
    }

    private func restoreHistoryAnchor(_ anchorID: String, proxy: ScrollViewProxy) {
        let messages = conversationStore.messages(for: displayedSessionID)
        let timelineItems = timelineItemCache.snapshot(from: messages).items
        guard timelineItems.contains(where: { $0.id == anchorID }) else {
            return
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(anchorID, anchor: .top)
        }
    }

    private static func tailFollowTaskKey(sessionID: SessionID?, tailItemID: String?) -> String? {
        guard let sessionID, let tailItemID else {
            return nil
        }
        return "\(sessionID):\(tailItemID)"
    }

    private func currentTimelineTailItemID() -> String? {
        timelineItemCache.tailItemID
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

    @ViewBuilder
    private var buttonLabel: some View {
        Group {
            if #available(iOS 26.0, *) {
                baseLabel
                    .background {
                        if reduceTransparency {
                            Circle().fill(tokens.elevatedSurface)
                        }
                    }
                    // regular glass 先打散正文再折射，避免 clear glass 把下方大字扭成不可辨识符号。
                    // Reduce Transparency 关闭玻璃动画与透明度。
                    .glassEffect(
                        reduceTransparency ? .identity : .regular.interactive(),
                        in: .circle
                    )
            } else {
                baseLabel
                    .background {
                        if reduceTransparency {
                            Circle().fill(tokens.elevatedSurface)
                        } else {
                            // iOS 18–25 使用普通系统材质，只保留浮层层级和 44pt 命中区域。
                            Circle().fill(.regularMaterial)
                        }
                    }
            }
        }
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

private enum KeyboardDismissal {
    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
