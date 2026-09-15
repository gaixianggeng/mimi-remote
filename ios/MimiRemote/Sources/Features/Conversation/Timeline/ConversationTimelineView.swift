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
    @State private var expandedActivityIDs: Set<String> = []
    @State private var collapsedDefaultActivityIDs: Set<String> = []
    @State private var expandedActivityGroupIDs: Set<String> = []
    @State private var timelineItemCache = ConversationTimelineItemCache()
    @State private var presentedSnapshot = ConversationTimelineSnapshot.empty
    @State private var scrollController = ConversationTimelineScrollController()
    @State private var showsDetailedTranscript = false

    private let messageTailFollowThreshold: CGFloat = 120
    private static let timelineTailSentinelID = "__conversation_timeline_safe_tail__"
    private static let timelineLiveStatusRowID = "__conversation_timeline_live_status__"
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
        let source = conversationStore.timelineSource(for: displayedSessionID ?? "__none__")
        let scope = source.scope
        let displayedSession = displayedSessionID.flatMap { sessionStore.sessionsByID[$0] }
        let timelineProvider = ConversationTimelineProvider(
            runtimeProvider: displayedSession?.runtimeProvider ?? displayedSession?.source
        )
        // body 只读来源与已发布列表；投影、旧位置捕获和发布在同一个 onChange 中完成。
        let timelineSnapshot = presentedSnapshot.scope == scope ? presentedSnapshot : .empty
        let timelineItems = timelineSnapshot.rows
        let timelineListIdentity = ConversationTimelineListIdentity(
            scope: scope,
            hasTimelineContent: !timelineItems.isEmpty,
            presentationGeneration: scrollController.epoch
        )
        let incomingIdentity = ConversationTimelineSnapshotIdentity(
            scope: scope,
            revision: source.revision,
            isInteracting: scrollController.isInteracting,
            provider: timelineProvider,
            showsDetailedTranscript: showsDetailedTranscript
        )
        let isTimelineReadable = timelineItems.isEmpty || scrollController.isReadable
        let activeUserDeliveryMessageID = Self.activeUserDeliveryMessageID(in: source.messages)
        let crossSessionOriginMessageID = Self.crossSessionOriginMessageID(
            session: displayedSession,
            messages: source.messages
        )
        let isHistoryLoading = sessionStore.historyLoadProgress(sessionID: displayedSessionID) != nil
        let liveStatus = displayedSessionID.flatMap { sessionID -> ConversationLiveStatus? in
            guard let session = displayedSession else { return nil }
            return ConversationLiveStatus.make(
                session: session,
                messages: source.messages,
                foregroundActivity: sessionStore.foregroundActivity(for: sessionID),
                runtimeActivity: sessionStore.runtimeActivitySnapshot(for: sessionID),
                tokenCounter: sessionStore.turnOutputTokensBySessionID[sessionID],
                readiness: sessionStore.conversationReadiness(for: session)
            )
        }
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
                                timelineListRow(
                                    item,
                                    provider: timelineProvider,
                                    activeUserDeliveryMessageID: activeUserDeliveryMessageID,
                                    crossSessionOriginMessageID: crossSessionOriginMessageID
                                )
                            }
                            if let liveStatus {
                                // 独立于 timelineItems 的尾部行：不参与条目 ID、历史锚点与分组投影，
                                // 贴底跟随仍以下方哨兵为准，出现/消失只表现为内容高度变化。
                                ConversationLiveStatusRow(status: liveStatus, layout: layout)
                                    .id(Self.timelineLiveStatusRowID)
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
                            .background {
                                ConversationTimelineScrollViewLocator { scrollView in
                                    scrollController.bind(
                                        scrollView: scrollView,
                                        epoch: timelineListIdentity.presentationGeneration
                                    )
                                }
                                .frame(width: 0, height: 0)
                            }
                            .onScrollVisibilityChange(threshold: 0.5) { isVisible in
                                scrollController.tailVisibilityChanged(
                                    isVisible,
                                    epoch: timelineListIdentity.presentationGeneration
                                )
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
                // 是否贴近底部用滚动几何实时判断，只在贴底时跟随流式输出，
                // 用户上翻历史时不会被尾部更新甩回底部。
                .onScrollGeometryChange(for: ConversationTimelineScrollMetrics.self) { geometry in
                    scrollMetrics(for: geometry)
                } action: { _, metrics in
                    scrollController.geometryChanged(
                        metrics,
                        epoch: timelineListIdentity.presentationGeneration
                    )
                }
                .onScrollPhaseChange { _, phase in
                    scrollController.phaseChanged(phase, epoch: timelineListIdentity.presentationGeneration)
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    if !timelineItems.isEmpty {
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            detailedTranscriptControl
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }

                if shouldShowReturnToTailButton(timelineItems: timelineItems) {
                    ConversationReturnToTailButton(
                        tokens: tokens,
                        accessibilityLabel: returnToTailAccessibilityLabel
                    ) {
                        scrollController.returnToTail()
                    }
                    // 放在输入区正上方的视觉中轴，不与用户气泡或右侧滚动条争抢空间。
                    .padding(.bottom, 10)
                }

                if !isTimelineReadable {
                    // List 必须先进入视图层级才能获得真实高度并执行 scrollTo。用真实画布
                    // 只覆盖首次尾部布局窗口，不等待后台网络补齐。
                    ConversationTimelineStabilizingCover(
                        backgroundColor: UIColor(tokens.conversationCanvasBackground)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .onChange(of: incomingIdentity, initial: true) { _, _ in
                publishTimelineSource(source, provider: timelineProvider)
            }
            .onChange(of: timelineListIdentity, initial: true) { _, identity in
                connectScrollCommands(proxy: proxy, epoch: identity.presentationGeneration)
            }
            .onAppear {
                publishTimelineSource(source, provider: timelineProvider)
            }
            .environment(\.conversationMediaLayoutWillChange, scrollController.mediaLayoutWillChange)
            .environment(\.conversationBindAnchorView, anchorViewBinder())
            .environment(\.conversationTimelineIsScrolling, scrollController.isInteracting)
            .onDisappear {
                scrollController.invalidate()
            }
        }
    }

    @ViewBuilder
    private func timelineListRow(
        _ item: ConversationTimelineItem,
        provider: ConversationTimelineProvider,
        activeUserDeliveryMessageID: UUID?,
        crossSessionOriginMessageID: UUID?
    ) -> some View {
        timelineRow(
            item,
            provider: provider,
            activeUserDeliveryMessageID: activeUserDeliveryMessageID,
            crossSessionOriginMessageID: crossSessionOriginMessageID
        )
        .modifier(ConversationHistoryAnchorGeometryModifier(
            // List 只实例化视口附近的少量 cell。持续量这些真实行，才能在派生行 ID
            // 重建时仍按 raw message UUID 选中锚点。
            isEnabled: !outerAnchorMessageIDs(for: item).isEmpty,
            messageIDs: outerAnchorMessageIDs(for: item),
            action: anchorFrameRecorder(),
            bindView: anchorViewBinder()
        ))
        .simultaneousGesture(TapGesture().onEnded { KeyboardDismissal.dismiss() })
        .id(item.id)
        // List 行属性必须位于自定义 modifier 外层，否则 SwiftUI 会恢复默认分隔线和 inset。
        .listRowSeparator(.hidden)
        .listRowInsets(layout.messageRowInsets)
        .listRowBackground(Color.clear)
    }

    private func outerAnchorMessageIDs(for item: ConversationTimelineItem) -> [UUID] {
        switch item {
        case .message(let message), .activity(let message):
            return [message.id]
        case .activityBatch(let group):
            return expandedActivityGroupIDs.contains(group.id) ? [] : group.messages.map(\.id)
        }
    }

    @ViewBuilder
    private func timelineRow(
        _ item: ConversationTimelineItem,
        provider: ConversationTimelineProvider,
        activeUserDeliveryMessageID: UUID?,
        crossSessionOriginMessageID: UUID?
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
            let itemID = ConversationTimelineItem.activityID(for: message)
            ConversationActivityRow(
                message: message,
                layout: layout,
                provider: provider,
                showsDetailedTranscript: showsDetailedTranscript,
                isExpanded: isActivityExpanded(message, itemID: itemID, provider: provider),
                toggle: {
                    toggleActivityDetails(
                        message: message,
                        itemID: itemID,
                        scrollAnchorID: itemID,
                        provider: provider
                    )
                }
            )
                .equatable()
        case .activityBatch(let group):
            ConversationActivityBatchRow(
                group: group,
                layout: layout,
                provider: provider,
                showsDetailedTranscript: showsDetailedTranscript,
                isExpanded: showsDetailedTranscript || expandedActivityGroupIDs.contains(group.id),
                expandedActivityIDs: expandedActivityIDs,
                toggleGroup: {
                    toggleActivityGroup(groupID: group.id)
                },
                toggleActivity: { message in
                    toggleActivityDetails(
                        message: message,
                        itemID: ConversationTimelineItem.activityID(for: message),
                        scrollAnchorID: group.id,
                        provider: provider
                    )
                },
                recordAnchorGeometry: anchorFrameRecorder()
            )
                .equatable()
        }
    }

    private func toggleActivityDetails(
        message: ConversationMessage,
        itemID: String,
        scrollAnchorID: String,
        provider: ConversationTimelineProvider
    ) {
        guard !showsDetailedTranscript else { return }
        let isExpanding = !isActivityExpanded(message, itemID: itemID, provider: provider)
        scrollController.expansionChanged(scrollAnchorID, isExpanded: isExpanding, isAnimated: false)
        if isExpanding {
            collapsedDefaultActivityIDs.remove(itemID)
            expandedActivityIDs.insert(itemID)
        } else {
            expandedActivityIDs.remove(itemID)
            if activityIsExpandedByDefault(message, provider: provider) {
                collapsedDefaultActivityIDs.insert(itemID)
            }
        }
    }

    private func isActivityExpanded(
        _ message: ConversationMessage,
        itemID: String,
        provider: ConversationTimelineProvider
    ) -> Bool {
        if showsDetailedTranscript { return true }
        if collapsedDefaultActivityIDs.contains(itemID) { return false }
        return expandedActivityIDs.contains(itemID)
            || activityIsExpandedByDefault(message, provider: provider)
    }

    private func activityIsExpandedByDefault(
        _ message: ConversationMessage,
        provider: ConversationTimelineProvider
    ) -> Bool {
        provider == .codex && message.activityPayload?.category == .editFile
    }

    private func toggleActivityGroup(
        groupID: String,
        scrollAnchorID: String? = nil
    ) {
        let isExpanding = !expandedActivityGroupIDs.contains(groupID)
        let isAnimated = !accessibilityReduceMotion
        let input = scrollController.expansionChanged(scrollAnchorID ?? groupID, isExpanded: isExpanding, isAnimated: isAnimated)
        withAnimation(
            accessibilityReduceMotion ? nil : .spring(response: 0.32, dampingFraction: 1),
            completionCriteria: .removed
        ) {
            if isExpanding {
                expandedActivityGroupIDs.insert(groupID)
            } else {
                expandedActivityGroupIDs.remove(groupID)
            }
        } completion: {
            if isAnimated { scrollController.expansionCompleted(input) }
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
        !timelineItems.isEmpty
            && scrollController.isReadable
            && (scrollController.mode == .readingHistory || scrollController.hasUnseenTail)
    }

    private var returnToTailAccessibilityLabel: String {
        scrollController.hasUnseenTail ? L10n.text("ui.return_to_the_bottom_to_view_new_messages") : L10n.text("ui.back_to_latest_news")
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

    private var detailedTranscriptControl: some View {
        Button {
            showsDetailedTranscript.toggle()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "text.page")
                Text(L10n.text("ui.detailed_transcript"))
                    .lineLimit(1)
                if showsDetailedTranscript {
                    Image(systemName: "checkmark")
                }
            }
            .font(themeStore.uiFont(.footnote, weight: .medium))
            .foregroundStyle(
                showsDetailedTranscript
                    ? themeStore.tokens(for: colorScheme).accent
                    : workbenchSecondaryText
            )
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(themeStore.tokens(for: colorScheme).elevatedSurface, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(themeStore.tokens(for: colorScheme).border.opacity(0.7), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.06), radius: 5, y: 2)
        .accessibilityValue(
            showsDetailedTranscript ? L10n.text("ui.selected") : L10n.text("ui.not_selected")
        )
        .accessibilityHint(L10n.text("ui.detailed_transcript_hint"))
    }

    private func publishTimelineSource(
        _ source: ConversationTimelineSourceSnapshot,
        provider: ConversationTimelineProvider
    ) {
        let snapshot = timelineItemCache.snapshot(
            from: source,
            provider: provider,
            showsDetailedTranscript: showsDetailedTranscript,
            suspendingUpdates: scrollController.isInteracting
        )
        guard scrollController.prepare(snapshot) else { return }
        if presentedSnapshot.scope != snapshot.scope {
            expandedActivityIDs.removeAll()
            collapsedDefaultActivityIDs.removeAll()
            expandedActivityGroupIDs.removeAll()
        }
        if !snapshot.rows.isEmpty, presentedSnapshot.rows.isEmpty || presentedSnapshot.scope != snapshot.scope {
            HostSwitchSignpost.event("first_text_visible")
        }
        presentedSnapshot = snapshot
        ConversationScrollDiagnostics.shared.record(
            "projection",
            "revision=\(snapshot.revision) rows=\(snapshot.rows.count) changes=\(snapshot.changes.rawValue)"
        )
        scrollController.snapshotWasPublished()
    }

    private func connectScrollCommands(proxy: ScrollViewProxy, epoch: Int) {
        let reduceMotion = accessibilityReduceMotion
        let controller = scrollController
        // 长列表首次定位不能依赖尾行已经实例化；proxy 接线与原生视口发现独立。
        controller.connect(epoch: epoch) { [weak controller] command in
            // 所有滚动副作用只从控制器到达此处，不反向观察 contentOffset 产生新命令。
            let apply = {
                switch command.target {
                case .tail:
                    if !command.animated,
                       let scrollView = controller?.viewport.scrollView,
                       let metrics = controller?.viewport.metrics {
                        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: metrics.maximumOffsetY), animated: false)
                    } else {
                        proxy.scrollTo(Self.timelineTailSentinelID, anchor: .bottom)
                    }
                case let .offset(offset):
                    guard let scrollView = controller?.viewport.scrollView else { return }
                    scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: offset), animated: false)
                case let .item(id):
                    proxy.scrollTo(id, anchor: .bottom)
                case let .anchorItem(id):
                    proxy.scrollTo(id, anchor: .top)
                }
            }
            if command.animated && !reduceMotion {
                withAnimation(.easeOut(duration: 0.18), apply)
            } else {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction, apply)
            }
        }
    }

    @MainActor
    private func loadEarlierHistory(sessionID: SessionID?) async {
        scrollController.beginLoadingEarlierHistory()
        if let sessionID {
            await sessionStore.loadEarlierHistory(sessionID: sessionID)
        }
    }

    private func anchorFrameRecorder() -> ([UUID], CGRect) -> Void {
        let controller = scrollController
        let epoch = controller.epoch
        return { [weak controller] ids, frame in
            controller?.recordAnchorFrame(ids, frame, epoch: epoch)
        }
    }

    private func anchorViewBinder() -> ([UUID], UIView) -> Void {
        let controller = scrollController
        let epoch = controller.epoch
        return { [weak controller] ids, view in
            guard let controller, controller.epoch == epoch else { return }
            controller.anchorViewDidLayout(ids, view: view, epoch: epoch)
        }
    }

}

private struct ConversationTimelineListIdentity: Hashable {
    let scope: ScopedSessionID
    let hasTimelineContent: Bool
    let presentationGeneration: Int
}

private struct ConversationTimelineSnapshotIdentity: Equatable {
    let scope: ScopedSessionID
    let revision: UInt64
    let isInteracting: Bool
    let provider: ConversationTimelineProvider
    let showsDetailedTranscript: Bool
}

struct ConversationHistoryAnchorGeometryModifier: ViewModifier {
    @Environment(\.conversationBindAnchorView) private var environmentAnchorBinder
    let isEnabled: Bool
    let messageIDs: [UUID]
    let action: ([UUID], CGRect) -> Void
    var bindView: (([UUID], UIView) -> Void)?
    @State private var latestFrame = CGRect.null
    @State private var isVisible = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.onGeometryChange(for: CGRect.self) { geometry in
                geometry.frame(in: .global)
            } action: { frame in
                latestFrame = frame
                if isVisible {
                    action(messageIDs, frame)
                }
            }
            .onScrollVisibilityChange(threshold: 0.01) { visible in
                isVisible = visible
                if visible, !latestFrame.isNull {
                    action(messageIDs, latestFrame)
                } else if !visible {
                    action(messageIDs, .null)
                }
            }
            .onDisappear {
                action(messageIDs, .null)
            }
            .background {
                ConversationHistoryAnchorView { view in
                    (bindView ?? environmentAnchorBinder)(messageIDs, view)
                }
                .allowsHitTesting(false)
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

private enum KeyboardDismissal {
    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
