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
