import SwiftUI

extension UnifiedWorkbenchShell {
    /// 外接键盘快捷键（#828）：⌘O / ⌘F 跳转，⌘1～9 侧栏前 9 条，⌘N 新建，⌘. 停止，⌘[ / ⌘] 前后会话。
    func keyboardCommandActions(layout: WorkbenchLayout) -> WorkbenchCommandActions {
        let sidebarShortcuts = sidebarMonitorSections(now: Date())
            .flatMap(\.sessions)
            .prefix(9)
            .map { WorkbenchCommandActions.SidebarShortcut(id: $0.id, title: $0.title) }
        let visibleID = navigationState.visibleSessionID(usesCompactNavigation: layout.usesCompactNavigation)
        let canStop = sessionStore.selectedSession.map { session in
            session.id == visibleID && session.isRunning && session.activeTurnID != nil
                && sessionStore.canControlSession(session)
        } ?? false
        let stopCurrentReply: (() -> Void)? = canStop ? { sessionStore.interruptSelectedTurn() } : nil
        return WorkbenchCommandActions(
            sidebarShortcuts: Array(sidebarShortcuts),
            openJumpPanel: { isSessionJumpPanelPresented = true },
            openSession: { open(.session($0), source: .sessions, layout: layout) },
            newSession: { presentSheet(.newSession) },
            stopCurrentReply: stopCurrentReply,
            goBack: sessionHistory.canGoBack ? { stepSessionHistory(back: true, layout: layout) } : nil,
            goForward: sessionHistory.canGoForward ? { stepSessionHistory(back: false, layout: layout) } : nil
        )
    }

    private func stepSessionHistory(back: Bool, layout: WorkbenchLayout) {
        var history = sessionHistory
        // 已归档的会话仍留在 sessions 里，只是从列表投影中隐藏；前后切换要一起跳过。
        let isAvailable: (SessionID) -> Bool = { id in
            !sessionStore.archivedSessionIDs.contains(id) && sessionStore.sessions.contains { $0.id == id }
        }
        let target = back ? history.goBack(isAvailable: isAvailable) : history.goForward(isAvailable: isAvailable)
        sessionHistory = history
        if let target {
            open(.session(target), source: .sessions, layout: layout)
        }
    }

    func applyNavigation(
        _ event: WorkbenchNavigationEvent,
        layout: WorkbenchLayout,
        preferredSession: AgentSession? = nil,
        origin: WorkbenchNavigationOrigin = .user
    ) {
        let commit = makeNavigationCommit(event, layout: layout, origin: origin)
        commitVisualNavigation(commit)
        commitNavigationSideEffects(
            commit,
            layout: layout,
            preferredSession: preferredSession
        )
    }

    /// TabView / NavigationStack 的 selection/path 必须在 Binding setter 所在事务内更新，
    /// 否则系统高亮或返回手势会先走一帧，内容下一轮才跳到目标页。外部副作用继续延后，
    /// 并以完整导航快照校验，避免快速连点或恢复事件执行已经过期的网络操作。
    func applyInteractiveNavigation(
        _ event: WorkbenchNavigationEvent,
        lane: WorkbenchNavigationBindingScheduler.Lane,
        layout: WorkbenchLayout
    ) {
        navigationBindingScheduler.commit(
            on: lane,
            visualUpdate: {
                let commit = makeNavigationCommit(event, layout: layout)
                commitVisualNavigation(commit)
                return commit
            },
            deferredSideEffect: { commit in
                guard navigationState == commit.state else { return }
                commitNavigationSideEffects(commit, layout: layout)
            }
        )
    }

    private func makeNavigationCommit(
        _ event: WorkbenchNavigationEvent,
        layout: WorkbenchLayout,
        origin: WorkbenchNavigationOrigin = .user
    ) -> WorkbenchNavigationCommit {
        var nextState = navigationState
        let effect = nextState.reduce(
            event,
            usesCompactNavigation: layout.usesCompactNavigation,
            selectedSessionID: sessionStore.selectedSessionID,
            usesPhoneIntegratedBottomChrome: layout.usesPhoneIntegratedBottomChrome
        )
        // 忽略 SwiftUI 对相同 path/tab 的回写；真实交互在视觉事务内撤销旧通知。
        if nextState != navigationState || effect != nil {
            sessionStore.notificationNavigation.observe(event, origin: origin)
        }
        return WorkbenchNavigationCommit(state: nextState, effect: effect)
    }

    private func commitVisualNavigation(_ commit: WorkbenchNavigationCommit) {
        // 一个事件只提交一个本地导航状态，避免 NavigationStack 在同一帧接收多次 path 写入。
        if commit.state != navigationState {
            navigationState = commit.state
        }
    }

    private func commitNavigationSideEffects(
        _ commit: WorkbenchNavigationCommit,
        layout: WorkbenchLayout,
        preferredSession: AgentSession? = nil
    ) {
        if restorationRoute != commit.state.route {
            restorationRoute = commit.state.route
        }
        if layout.usesPhoneIntegratedBottomChrome {
            let tabRawValue = commit.state.compactSelectedTab.rawValue
            if storedCompactSelectedTabRawValue != tabRawValue {
                storedCompactSelectedTabRawValue = tabRawValue
            }
        }

        switch commit.effect {
        case .returnToSessionList:
            sessionStore.returnToSessionList()
        case .selectSession(let sessionID):
            let session = preferredSession?.id == sessionID
                ? preferredSession
                : sessionStore.openedWorkspaceSessionLibrarySessions.first(where: { $0.id == sessionID })
            guard let session else {
                applyNavigation(.sessionSelectionFinished(sessionID), layout: layout)
                return
            }
            Task {
                await sessionStore.selectSession(session)
                applyNavigation(.sessionSelectionFinished(sessionID), layout: layout)
            }
        case nil:
            break
        }
    }

    @ToolbarContentBuilder
    func inspectorToolbarItem(
        layout: WorkbenchLayout,
        tokens: ThemeTokens
    ) -> some ToolbarContent {
        if layout.usesSheetInspectorNavigation, #available(iOS 26.0, *) {
            ToolbarItem(placement: .topBarTrailing) {
                inspectorToolbarButton(
                    layout: layout,
                    tokens: tokens,
                    source: .sessionToolbarInspector
                )
            }
            // 只有中等宽度的独立按钮是稳定锚点；attached Inspector 不参与 Sheet zoom。
            .matchedTransitionSource(
                id: InspectorPresentationSource
                    .sessionToolbarInspector
                    .transitionSourceID,
                in: presentationNamespace
            )
            // 按钮自带磨砂圆，系统共享玻璃必须关掉，否则是两层背景。
            .sharedBackgroundVisibility(.hidden)
        } else {
            // iOS 18–25 仍可打开 Inspector，只取消依赖新 Toolbar API 的 zoom 来源。
            workbenchChromeToolbarItem(placement: .topBarTrailing) {
                inspectorToolbarButton(
                    layout: layout,
                    tokens: tokens,
                    source: nil
                )
            }
        }
    }

    private func inspectorToolbarButton(
        layout: WorkbenchLayout,
        tokens: ThemeTokens,
        source: InspectorPresentationSource?
    ) -> some View {
        workbenchToolbarIconButton(
            systemImage: "sidebar.right",
            accessibilityLabel: showingInspector
                ? L10n.text("ui.hide_details")
                : L10n.text("ui.show_details"),
            tokens: tokens,
            isActive: showingInspector
        ) {
            toggleInspector(layout: layout, source: source)
        }
        .accessibilityIdentifier("sessionDetail.inspector")
    }

    /// 顶栏图标按钮的统一形态：44pt 扁平磨砂圆，和工作区胶囊、侧栏控件同一档材质。
    /// 调用方必须把它放进 `workbenchChromeToolbarItem`（或自行 `sharedBackgroundVisibility(.hidden)`），
    /// 否则 iOS 26 的系统玻璃底板会叠在这层磨砂下面。
    func workbenchToolbarIconButton(
        systemImage: String,
        accessibilityLabel: String,
        tokens: ThemeTokens,
        isActive: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            // 磨砂圆只作为背景，不参与布局；外层 ToolbarItem 负责关掉
            // iOS 26 自动附加的系统玻璃底板。
            WorkbenchChromeIcon(systemName: systemImage)
                .workbenchToolbarChromeCircle(tokens: tokens)
        }
        .foregroundStyle(isActive ? tokens.tint(for: .active) : tokens.secondaryText)
        .disabled(isDisabled)
        .accessibilityLabel(accessibilityLabel)
    }

    func sessionDetailNavigationTitle(
        session: AgentSession?,
        usesSelectedSessionState: Bool,
        layout: WorkbenchLayout,
        tokens: ThemeTokens,
        now: Date
    ) -> some View {
        let showsStatus = usesSelectedSessionState && selectedSessionShowsNavigationStatus
        let subtitle = usesSelectedSessionState
            ? sessionTitleSubtitle(now: now)
            : SessionNavigationTitlePresentation.pendingSubtitle(session: session)
        let subtitleColor = usesSelectedSessionState
            ? sessionTitleSubtitleColor(tokens: tokens, now: now)
            : tokens.secondaryText
        let workspaceIcon: WorkspaceProjectIconContent? = {
            guard SessionNavigationTitlePresentation.showsWorkspaceIcon(
                layout: layout,
                projectID: session?.projectID
            ),
            let projectID = session?.projectID.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return nil
            }
            return workspaceAppearanceStore.projectIconContent(
                profileID: appStore.activeHostScope.profileID,
                projectID: projectID
            )
        }()
        let textAlignment: HorizontalAlignment = workspaceIcon == nil ? .center : .leading
        let titleStack = VStack(alignment: textAlignment, spacing: 1) {
            // 标题只保留一行当前任务；普通状态收进固定副标题槽，
            // 避免 running / idle 切换时把整条时间线向下推。
            Text(session?.title ?? L10n.text("ui.session"))
                .font(.headline)
                .foregroundStyle(tokens.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)

            HStack(spacing: 5) {
                if showsStatus {
                    Circle()
                        .fill(subtitleColor)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)
                }
                Text(subtitle)
                    .font(
                        SessionNavigationTitlePresentation.subtitleFont(
                            layout: layout,
                            themeStore: themeStore
                        )
                    )
                    .foregroundStyle(subtitleColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .multilineTextAlignment(workspaceIcon == nil ? .center : .leading)

        return Group {
            if let workspaceIcon {
                HStack(spacing: 7) {
                    WorkspaceProjectIconTile(content: workspaceIcon, size: 22, tokens: tokens)
                    titleStack
                }
                .frame(maxWidth: layout.titleMaxWidth)
            } else {
                titleStack
                    .frame(width: layout.titleMaxWidth)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(session?.title ?? L10n.text("ui.session"))
        .accessibilityValue(
            usesSelectedSessionState ? sessionTitleAccessibilityValue(now: now) : subtitle
        )
        .accessibilityIdentifier("sessionDetail.title")
    }

    private func sessionTitleSubtitle(now: Date) -> String {
        guard let session = sessionStore.selectedSession else {
            return L10n.text("ui.session")
        }

        if selectedSessionShowsNavigationStatus {
            let status = session.displayStatus(foregroundActivity: sessionStore.selectedForegroundActivity)
            if let snapshot = sessionStore.selectedRuntimeActivitySnapshot {
                let elapsed = RuntimeActivityDisplay.compactClockDuration(
                    now.timeIntervalSince(snapshot.turnStartedAt)
                )
                return "\(status.title) · \(elapsed)"
            }
            return status.title
        }

        let project = session.project.trimmingCharacters(in: .whitespacesAndNewlines)
        return project.isEmpty ? session.displayStatus(foregroundActivity: sessionStore.selectedForegroundActivity).title : project
    }

    private func sessionTitleAccessibilityValue(now: Date) -> String {
        guard let session = sessionStore.selectedSession else {
            return L10n.text("ui.session")
        }
        guard selectedSessionShowsNavigationStatus else {
            return sessionTitleSubtitle(now: now)
        }

        let status = session.displayStatus(foregroundActivity: sessionStore.selectedForegroundActivity)
        if let runtimeDisplay = RuntimeActivityDisplay.make(
            snapshot: sessionStore.selectedRuntimeActivitySnapshot,
            webSocketStatus: sessionStore.webSocketStatus,
            now: now
        ) {
            // 视觉副标题只留状态和时长；连接诊断仍完整提供给 VoiceOver。
            return "\(status.title) · \(runtimeDisplay.detailText)"
        }
        return status.title
    }

    private var selectedSessionShowsNavigationStatus: Bool {
        guard let session = sessionStore.selectedSession else {
            return false
        }
        return session.isRunning ||
            sessionStore.selectedForegroundActivity != nil ||
            session.pendingApproval != nil ||
            session.status == SessionStatus.failed.rawValue ||
            session.status == SessionStatus.waitingForInput.rawValue ||
            session.status == SessionStatus.waitingForApproval.rawValue
    }

    private func sessionTitleSubtitleColor(tokens: ThemeTokens, now: Date) -> Color {
        guard selectedSessionShowsNavigationStatus else {
            return tokens.tertiaryText
        }
        if let runtimeDisplay = RuntimeActivityDisplay.make(
            snapshot: sessionStore.selectedRuntimeActivitySnapshot,
            webSocketStatus: sessionStore.webSocketStatus,
            now: now
        ) {
            return tokens.tint(for: runtimeDisplay.tone)
        }
        return selectedSessionStatusColor(tokens: tokens)
    }

    private func selectedSessionStatusColor(tokens: ThemeTokens) -> Color {
        guard let session = sessionStore.selectedSession else {
            return tokens.tertiaryText
        }
        switch session.displayStatus(foregroundActivity: sessionStore.selectedForegroundActivity).tone {
        case .active:
            return tokens.tint(for: .active)
        case .warning:
            return tokens.warning
        case .danger:
            return .red
        case .complete:
            return tokens.success
        case .neutral:
            return tokens.tertiaryText
        }
    }

}
