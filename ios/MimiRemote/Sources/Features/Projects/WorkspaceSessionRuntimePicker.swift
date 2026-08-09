import SwiftUI

/// 工作区会话只浏览一个 Runtime；这里集中维护上游 provider、品牌资源和可用性映射。
enum WorkspaceSessionRuntimeChoice: String, CaseIterable, Identifiable {
    case codex
    case claude

    var id: String { rawValue }

    var runtimeProvider: String {
        switch self {
        case .codex:
            return "codex"
        case .claude:
            return "claude"
        }
    }

    var listTitle: String {
        switch self {
        case .codex:
            return L10n.text("ui.runtime_default")
        case .claude:
            return L10n.text("ui.runtime_claude_short")
        }
    }

    var title: String {
        switch self {
        case .codex:
            return L10n.text("ui.create_a_new_codex_session")
        case .claude:
            return L10n.text("ui.create_a_new_claude_code_session")
        }
    }

    var brandAssetName: String {
        switch self {
        case .codex:
            return "ChatGPT"
        case .claude:
            return "Claude"
        }
    }

    static func available(claudeChannelAvailable: Bool) -> [Self] {
        claudeChannelAvailable ? [.codex, .claude] : [.codex]
    }
}

/// 独立子视图保持 Runtime 选择的布局、命中区和辅助功能语义稳定。
struct WorkspaceRuntimePicker: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    @Binding var selection: WorkspaceSessionRuntimeChoice
    let claudeChannelAvailable: Bool

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        HStack(spacing: 2) {
            ForEach(WorkspaceSessionRuntimeChoice.allCases) { choice in
                let isSelected = selection == choice
                let isAvailable = choice != .claude || claudeChannelAvailable

                Button {
                    guard isAvailable else { return }
                    selection = choice
                } label: {
                    HStack(spacing: 6) {
                        Image(choice.brandAssetName)
                            .resizable()
                            .renderingMode(.original)
                            .scaledToFit()
                            .frame(width: 17, height: 17)
                            .accessibilityHidden(true)

                        Text(choice.listTitle)
                            .font(themeStore.uiFont(.subheadline, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                    }
                    // 选中态同时使用主操作实色、前景色和字重；未选中项留在中性轨道内，
                    // 不把颜色差异当作唯一状态线索。
                    .foregroundStyle(
                        isSelected
                            ? tokens.primaryActionForeground
                            : (isAvailable ? tokens.secondaryText : tokens.tertiaryText)
                    )
                    .opacity(
                        isSelected
                            ? 1
                            : (isAvailable ? 0.60 : 0.42)
                    )
                    .padding(.horizontal, 8)
                    .frame(minHeight: WorkbenchChromeIconMetrics.minimumHitTarget)
                    .contentShape(Rectangle())
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(tokens.primaryAction)
                        }
                    }
                    .overlay {
                        if isSelected, colorSchemeContrast == .increased {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(tokens.primaryActionForeground, lineWidth: 1)
                        }
                    }
                }
                .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
                .disabled(!isAvailable)
                .accessibilityLabel(choice.listTitle)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityHint(
                    isAvailable
                        ? L10n.text("ui.show_runtime_sessions_hint")
                        : L10n.text("ui.runtime_unavailable_hint")
                )
                .accessibilityIdentifier("workspace.sessions.runtime.\(choice.rawValue)")
            }
        }
        .padding(2)
        .background {
            // 外轨保持中性，选中项才承载主操作色，减少运行时筛选器对会话内容的干扰。
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tokens.surface.opacity(0.72))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    tokens.border.opacity(colorSchemeContrast == .increased ? 1 : 0.72),
                    lineWidth: colorSchemeContrast == .increased ? 1 : 0.5
                )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("ui.runtime_provider"))
        .accessibilityIdentifier("workspace.sessions.runtimePicker")
    }
}
