import SwiftUI

/// 选择值必须由 Shell 持有，确保会话详情替换工作区根视图时不会丢失；
/// 状态规则留在独立类型中，避免继续把工作区职责堆入 Shell。
struct WorkspaceRuntimeSelectionState {
    var selectedRuntime: WorkspaceSessionRuntimeChoice = .codex

    mutating func resetForHostChange() {
        selectedRuntime = .codex
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
