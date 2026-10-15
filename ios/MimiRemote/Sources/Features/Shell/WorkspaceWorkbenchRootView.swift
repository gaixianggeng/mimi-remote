import SwiftUI

/// 选择值必须由 Shell 持有，确保会话详情替换工作区根视图时不会丢失；
/// 状态规则留在独立类型中，避免继续把工作区职责堆入 Shell。
struct WorkspaceRuntimeSelectionState {
    var manualRuntime: WorkspaceSessionRuntimeChoice?

    /// 能力可能在首屏之后才到达；回落只影响显示，不写回偏好或手动选择。
    func resolvedRuntime(
        preferredRuntime: WorkspaceSessionRuntimeChoice,
        availableRuntimeProviders: Set<String>
    ) -> WorkspaceSessionRuntimeChoice {
        let requestedRuntime = manualRuntime ?? preferredRuntime
        if requestedRuntime.isAvailable(in: availableRuntimeProviders) {
            return requestedRuntime
        }
        // 首选不可用时回落到**实际可用**的第一个，而不是无条件 .codex：
        // 一个只开了 claude 的主机上，把 codex 顶上来等于提供一个用不了的选择。
        // 集合为空时 `available` 会兜底成 [.codex]，因此这里一定有值。
        return WorkspaceSessionRuntimeChoice.available(
            runtimeProviders: availableRuntimeProviders
        ).first ?? .codex
    }

    /// 切换电脑或修改全局偏好后，重新使用偏好；普通导航不调用此方法。
    mutating func reset() {
        manualRuntime = nil
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
    let onManageConnections: () -> Void
    let onOpenSession: (AgentSession) -> Void
    @Binding var selectedRuntime: WorkspaceSessionRuntimeChoice
    @Binding var browseSelection: WorkspaceBrowseSelectionState

    var body: some View {
        WorkspaceRootView(
            selectedSessionRuntime: $selectedRuntime,
            onStartSession: startSession,
            onOpenSession: onOpenSession,
            manageConnections: manageConnections,
            embedsNavigationStack: WorkspaceRootView.shouldEmbedNavigationStack(
                usesCompactNavigation: usesCompactNavigation
            ),
            appearanceStore: workspaceAppearanceStore,
            initialWorkspaceID: browseSelection.workspaceID,
            onWorkspaceSelectionChange: { browseSelection.record($0) }
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
