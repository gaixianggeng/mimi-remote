import SwiftUI

/// `$` 与 `/` 共用的候选浮层。浮在输入卡上方，不改变输入卡高度，聊天列表不会被挤动（#765）。
struct ComposerAutocompletePanel: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    let trigger: ComposerSkillQuery.Trigger
    let suggestions: [ComposerAutocompleteSuggestion]
    let selectedIndex: Int
    /// 列表最大高度；超出部分滚动，不再像旧面板那样截掉第 6 项之后的结果。
    let maxListHeight: CGFloat
    let onSelect: (ComposerAutocompleteSuggestion) -> Void

    @State private var measuredListHeight: CGFloat = 0

    private static let estimatedRowHeight: CGFloat = 46

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(
                    trigger == .command ? L10n.text("ui.command") : L10n.text("ui.select_skill"),
                    systemImage: trigger == .command ? "slash.circle" : "wand.and.stars"
                )
                Spacer()
                Text(L10n.text("ui.select_confirm_esc_close"))
            }
            .font(themeStore.uiFont(.caption2, weight: .semibold))
            .foregroundStyle(tokens.secondaryText)
            .padding(.horizontal, 8)
            .padding(.bottom, 2)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                            row(suggestion, isSelected: index == selectedIndex, tokens: tokens)
                                .id(suggestion.id)
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.size.height
                    } action: { height in
                        measuredListHeight = height
                    }
                }
                // 浮层按内容高度收缩；首帧尚未测量时用估算值，避免先撑满再回弹。
                .frame(height: min(listHeight, maxListHeight))
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: selectedIndex) { _, index in
                    guard suggestions.indices.contains(index) else { return }
                    proxy.scrollTo(suggestions[index].id)
                }
            }
        }
        .padding(8)
        .background(WorkbenchMaterial.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tokens.border.opacity(0.9), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.18), radius: 16, y: 7)
        .accessibilityIdentifier("composer.autocomplete")
    }

    private var listHeight: CGFloat {
        measuredListHeight > 0
            ? measuredListHeight
            : CGFloat(suggestions.count) * Self.estimatedRowHeight
    }

    private func row(
        _ suggestion: ComposerAutocompleteSuggestion,
        isSelected: Bool,
        tokens: ThemeTokens
    ) -> some View {
        let isUnavailable: Bool
        if case .command(let command) = suggestion {
            isUnavailable = command.unavailableReason != nil
        } else {
            isUnavailable = false
        }
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

        return Button {
            onSelect(suggestion)
        } label: {
            HStack(spacing: 9) {
                rowContent(suggestion, tokens: tokens)
                Spacer(minLength: 8)
                if case .command(let command) = suggestion, command.isCurrent {
                    Text(L10n.text("ui.slash_command_current"))
                        .font(themeStore.uiFont(.caption2, weight: .semibold))
                        .foregroundStyle(tokens.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(tokens.selectionFill, in: Capsule())
                }
                if isSelected, !isUnavailable {
                    Image(systemName: "return")
                        .foregroundStyle(tokens.accent)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(minHeight: 44)
            .background(isSelected ? tokens.selectionFill : .clear, in: shape)
            .contentShape(shape)
            .opacity(isUnavailable ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isUnavailable)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func rowContent(_ suggestion: ComposerAutocompleteSuggestion, tokens: ThemeTokens) -> some View {
        switch suggestion {
        case .command(let command):
            Image(systemName: command.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tokens.accent)
                .frame(width: 28, height: 28)
                .background(tokens.selectionFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("/\(command.name)")
                        .font(themeStore.uiFont(.caption, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                    Text(command.title)
                        .font(themeStore.uiFont(.caption))
                        .foregroundStyle(tokens.secondaryText)
                }
                .lineLimit(1)
                Text(command.unavailableReason ?? command.detail)
                    .font(themeStore.uiFont(.caption2))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(1)
            }
        case .skill(let skill):
            SkillIconView(metadata: SkillVisualMetadata(capability: skill), size: 28)
            VStack(alignment: .leading, spacing: 1) {
                // `$` 沿用技能展示名；`/` 用技能 ID，与终端里输入的命令一致。
                Text(trigger == .command ? "/\(skill.name)" : "$\(skill.presentationName)")
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                    .lineLimit(1)
                if let description = skill.presentationDescription {
                    Text(description)
                        .font(themeStore.uiFont(.caption2))
                        .foregroundStyle(tokens.secondaryText)
                        .lineLimit(1)
                }
            }
            if trigger == .command {
                Text("Skill")
                    .font(themeStore.uiFont(size: 9, weight: .bold))
                    .foregroundStyle(tokens.secondaryText)
            }
        }
    }
}
