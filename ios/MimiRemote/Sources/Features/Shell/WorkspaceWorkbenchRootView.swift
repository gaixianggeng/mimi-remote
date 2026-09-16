import SwiftUI

/// 选择值必须由 Shell 持有，确保会话详情替换工作区根视图时不会丢失；
/// 状态规则留在独立类型中，避免继续把工作区职责堆入 Shell。
struct WorkspaceRuntimeSelectionState {
    var manualRuntime: WorkspaceSessionRuntimeChoice?

    /// 能力可能在首屏之后才到达；回落只影响显示，不写回偏好或手动选择。
    func resolvedRuntime(
        preferredRuntime: WorkspaceSessionRuntimeChoice,
        claudeChannelAvailable: Bool
    ) -> WorkspaceSessionRuntimeChoice {
        let requestedRuntime = manualRuntime ?? preferredRuntime
        return requestedRuntime == .claude && !claudeChannelAvailable ? .codex : requestedRuntime
    }

    /// 切换电脑或修改全局偏好后，重新使用偏好；普通导航不调用此方法。
    mutating func reset() {
        manualRuntime = nil
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

    var body: some View {
        WorkspaceRootView(
            selectedSessionRuntime: $selectedRuntime,
            onStartSession: startSession,
            onOpenSession: onOpenSession,
            manageConnections: manageConnections,
            embedsNavigationStack: WorkspaceRootView.shouldEmbedNavigationStack(
                usesCompactNavigation: usesCompactNavigation
            ),
            appearanceStore: workspaceAppearanceStore
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
