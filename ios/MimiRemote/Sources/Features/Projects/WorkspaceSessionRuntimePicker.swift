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
    @Namespace private var selectionNamespace

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
                    if reduceMotion {
                        selection = choice
                    } else {
                        // 选中内胶囊从当前显示位置继续运动，避免两个独立色块交叉闪烁。
                        withAnimation(.spring(response: 0.28, dampingFraction: 1)) {
                            selection = choice
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(choice.brandAssetName)
                            .resizable()
                            // 品牌资源是带自身底色的位图，模板着色会把整张画布染成方块。
                            .renderingMode(.original)
                            .scaledToFit()
                            .frame(width: 17, height: 17)
                            .accessibilityHidden(true)

                        Text(choice.listTitle)
                            .font(themeStore.uiFont(.subheadline, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                    }
                    // 选中态使用品牌色文字和描边，不再与右侧“新建会话”争抢实色主操作层级。
                    .foregroundStyle(
                        isSelected
                            ? tokens.primaryAction
                            : (isAvailable ? tokens.secondaryText : tokens.tertiaryText)
                    )
                    .opacity(
                        isSelected
                            ? 1
                            : (isAvailable ? 0.78 : 0.52)
                    )
                    .padding(.horizontal, 10)
                    .frame(minHeight: WorkbenchChromeIconMetrics.minimumHitTarget)
                    .contentShape(Rectangle())
                    .background {
                        if isSelected {
                            // 与右侧“新建会话”共用胶囊曲率；两个入口属于同一层级的会话操作，
                            // 曲率一致后仍通过实色/描边区分主操作与筛选状态。
                            let shape = Capsule()
                            shape
                                .fill(tokens.contentPanelBackground)
                                .overlay {
                                    // 常规模式不描边，避免选中态像获得焦点的输入框；
                                    // 增强对比度仅补中性轮廓，不重新引入紫色边框。
                                    if colorSchemeContrast == .increased {
                                        shape.stroke(tokens.border, lineWidth: 1)
                                    }
                                }
                                .shadow(
                                    color: tokens.primaryAction.opacity(
                                        colorScheme == .dark ? 0.18 : 0.10
                                    ),
                                    radius: 2,
                                    y: 1
                                )
                                .matchedGeometryEffect(
                                    id: "workspace-runtime-selection",
                                    in: selectionNamespace
                                )
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
        .padding(3)
        .background {
            // 外轨只负责把两个选项映射为同一控件，保持中性并让内容层级更安静。
            Capsule()
                .fill(tokens.surface.opacity(colorScheme == .dark ? 0.82 : 0.72))
        }
        .overlay {
            Capsule()
                .stroke(
                    tokens.border.opacity(colorSchemeContrast == .increased ? 1 : 0.64),
                    lineWidth: colorSchemeContrast == .increased ? 1 : 0.5
                )
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("ui.runtime_provider"))
        .accessibilityIdentifier("workspace.sessions.runtimePicker")
    }
}
