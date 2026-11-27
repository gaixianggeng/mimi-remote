import SwiftUI

/// 选择值必须由 Shell 持有，确保会话详情替换工作区根视图时不会丢失；
/// 状态规则留在独立类型中，避免继续把工作区职责堆入 Shell。
struct WorkspaceRuntimeSelectionState {
    var manualRuntime: WorkspaceSessionRuntimeChoice?
    var manualBrowseScope: WorkspaceSessionBrowseScope?

    /// 能力可能在首屏之后才到达；回落只影响显示，不写回偏好或手动选择。
    /// 同时尊重用户在模型设置中开启的 Runtime 集合。
    func resolvedRuntime(
        preferredRuntime: WorkspaceSessionRuntimeChoice,
        availableRuntimeProviders: Set<String>,
        enabledRuntimes: Set<WorkspaceSessionRuntimeChoice> = Set(WorkspaceSessionRuntimeChoice.allCases)
    ) -> WorkspaceSessionRuntimeChoice {
        let enabledOrder = WorkspaceSessionRuntimeChoice.allCases.filter { enabledRuntimes.contains($0) }
        let effectiveEnabled = Set(enabledOrder.isEmpty ? [.codex] : enabledOrder)
        let effectivePreferred = effectiveEnabled.contains(preferredRuntime)
            ? preferredRuntime
            : (enabledOrder.first ?? .codex)
        let validManual = manualRuntime.flatMap { effectiveEnabled.contains($0) ? $0 : nil }
        let requestedRuntime = validManual ?? effectivePreferred
        if requestedRuntime.isAvailable(in: availableRuntimeProviders, enabledRuntimes: effectiveEnabled) {
            return requestedRuntime
        }
        // 首选不可用时回落到**已开启且实际可用**的第一个，而不是无条件 .codex：
        // 一个只开了 claude 的主机上，把 codex 顶上来等于提供一个用不了的选择。
        return WorkspaceSessionRuntimeChoice.available(
            runtimeProviders: availableRuntimeProviders,
            enabledRuntimes: effectiveEnabled
        ).first ?? effectivePreferred
    }

    /// 结合已启用运行时数量、手动浏览选择与「默认展示全部运行时」开关解析当前工作区浏览范围（M8）。
    /// 仅启用 1 个运行时时不展示「全部」，始终落回该单运行时。
    func resolvedBrowseScope(
        preferredRuntime: WorkspaceSessionRuntimeChoice,
        defaultShowAllRuntimes: Bool,
        availableRuntimeProviders: Set<String>,
        enabledRuntimes: Set<WorkspaceSessionRuntimeChoice> = Set(WorkspaceSessionRuntimeChoice.allCases)
    ) -> WorkspaceSessionBrowseScope {
        let enabledOrder = WorkspaceSessionRuntimeChoice.allCases.filter { enabledRuntimes.contains($0) }
        let effectiveEnabled = Set(enabledOrder.isEmpty ? [.codex] : enabledOrder)
        let resolvedSingle = resolvedRuntime(
            preferredRuntime: preferredRuntime,
            availableRuntimeProviders: availableRuntimeProviders,
            enabledRuntimes: effectiveEnabled
        )
        guard effectiveEnabled.count > 1 else {
            return .single(resolvedSingle)
        }
        if let manualBrowseScope {
            switch manualBrowseScope {
            case .all:
                return .all
            case .single:
                return .single(resolvedSingle)
            }
        }
        if manualRuntime != nil {
            return .single(resolvedSingle)
        }
        return defaultShowAllRuntimes ? .all : .single(resolvedSingle)
    }

    mutating func setBrowseScope(_ scope: WorkspaceSessionBrowseScope) {
        manualBrowseScope = scope
        switch scope {
        case .all:
            manualRuntime = nil
        case let .single(choice):
            manualRuntime = choice
        }
    }

    /// 切换电脑或修改全局偏好后，重新使用偏好；普通导航不调用此方法。
    mutating func reset() {
        manualRuntime = nil
        manualBrowseScope = nil
    }
}

/// 工作区浏览选择同理：宽屏会话详情、横竖屏切换布局容器都会替换工作区根视图，
/// 根视图里的局部选择随之重建；Shell 记住最后浏览的工作区，重建时据此恢复（#501）。
struct WorkspaceBrowseSelectionState: Equatable {
    private(set) var workspaceID: String?

    /// 目录暂时为空（重连、加载中）时根视图会把选择清成 nil，这不代表用户离开了该工作区；
    /// 忽略 nil，目录恢复后仍能回到原来的工作区。
    mutating func record(_ workspaceID: String?) {
        guard let workspaceID else { return }
        self.workspaceID = workspaceID
    }

    /// 切换电脑后旧 ID 不再属于当前目录；普通导航不调用此方法。
    mutating func reset() {
        workspaceID = nil
    }

    /// 根视图重建或目录变化后的选择顺序：仍在目录中的当前选择 → 身份替换后的同一工作区 →
    /// Shell 记住的浏览来源 → 活动会话所在工作区 → 列表第一项。
    static func resolvedWorkspaceID(
        current: String?,
        retainedCurrent: String?,
        remembered: String?,
        activeProjectID: String?,
        projectIDs: [String]
    ) -> String? {
        for candidate in [current, retainedCurrent, remembered, activeProjectID] {
            if let candidate, projectIDs.contains(candidate) {
                return candidate
            }
        }
        return projectIDs.first
    }
}

struct WorkspaceWorkbenchRootView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var workspaceAppearanceStore: WorkspaceAppearanceStore

    let usesCompactNavigation: Bool
    let isPhone: Bool
    var bottomContentMargin: CGFloat? = nil
    let onManageConnections: () -> Void
    let onOpenSession: (AgentSession) -> Void
    @Binding var browseScope: WorkspaceSessionBrowseScope
    var preferredRuntime: WorkspaceSessionRuntimeChoice = .codex
    @Binding var browseSelection: WorkspaceBrowseSelectionState

    var body: some View {
        WorkspaceRootView(
            browseScope: $browseScope,
            preferredRuntime: preferredRuntime,
            onStartSession: startSession,
            onOpenSession: onOpenSession,
            manageConnections: manageConnections,
            onConnectComputer: onManageConnections,
            embedsNavigationStack: WorkspaceRootView.shouldEmbedNavigationStack(
                usesCompactNavigation: usesCompactNavigation
            ),
            appearanceStore: workspaceAppearanceStore,
            initialWorkspaceID: browseSelection.workspaceID,
            bottomContentMargin: bottomContentMargin,
            onWorkspaceSelectionChange: {
                browseSelection.record($0)
                prioritizeSessionLibrary(workspaceID: $0)
            }
        )
        .onAppear { prioritizeSessionLibrary(workspaceID: browseSelection.workspaceID) }
        .onChange(of: browseScope) { _, _ in
            prioritizeSessionLibrary(workspaceID: browseSelection.workspaceID)
        }
    }

    private func prioritizeSessionLibrary(workspaceID: String?) {
        guard let workspaceID, let workspace = sessionStore.workspacesByID[workspaceID] else { return }
        let priorityProvider = browseScope.singleRuntimeChoice?.runtimeProvider ?? preferredRuntime.runtimeProvider
        sessionStore.sessionLibraryPriorityScope = sessionStore.workspaceDirectoryScopeKey(
            for: workspace, runtimeProvider: priorityProvider
        )
    }

    private var manageConnections: (() -> Void)? {
        guard usesCompactNavigation, isPhone else { return nil }
        return onManageConnections
    }

    private func startSession(
        project: AgentProject,
        runtimeChoice: WorkspaceSessionRuntimeChoice
    ) {
        Task {
            await sessionStore.startNewSession(
                in: project,
                runtimeProvider: runtimeChoice.runtimeProvider
            )
        }
    }
}
