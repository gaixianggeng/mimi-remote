import SwiftUI
import UIKit

struct ComposerSkillQuery: Equatable {
    let query: String
    let replacementRange: NSRange

    static func match(text: String, selectedRange: NSRange) -> ComposerSkillQuery? {
        let source = text as NSString
        guard selectedRange.length == 0,
              selectedRange.location >= 0,
              selectedRange.location <= source.length
        else {
            return nil
        }

        let prefixRange = NSRange(location: 0, length: selectedRange.location)
        let whitespace = source.rangeOfCharacter(
            from: .whitespacesAndNewlines,
            options: .backwards,
            range: prefixRange
        )
        let tokenStart = whitespace.location == NSNotFound ? 0 : NSMaxRange(whitespace)
        let tokenRange = NSRange(location: tokenStart, length: selectedRange.location - tokenStart)
        guard tokenRange.length > 0 else {
            return nil
        }
        let token = source.substring(with: tokenRange)
        guard token.hasPrefix("$") else {
            return nil
        }
        return ComposerSkillQuery(
            query: String(token.dropFirst()),
            replacementRange: tokenRange
        )
    }
}

struct SkillVisualMetadata: Hashable {
    let name: String
    let displayName: String
    let description: String?
    let scope: String?
    let path: String
    let brandColor: String?

    init(capability: SkillCapability) {
        name = capability.name
        displayName = capability.presentationName
        description = capability.presentationDescription
        scope = capability.scope
        path = capability.path
        brandColor = capability.brandColor
    }

    init(name: String, path: String, capability: SkillCapability? = nil) {
        self.name = name
        displayName = capability?.presentationName ?? name
        description = capability?.presentationDescription
        scope = capability?.scope
        self.path = path
        brandColor = capability?.brandColor
    }

    var scopeTitle: String? {
        switch scope?.lowercased() {
        case "repo": return L10n.text("ui.project")
        case "user": return L10n.text("ui.personal")
        case "system": return L10n.text("ui.system")
        case "admin": return L10n.text("ui.management")
        default: return scope?.uppercased()
        }
    }
}

struct SkillIconView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    let metadata: SkillVisualMetadata
    var size: CGFloat = 32

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let tint = SkillBrandColor.color(metadata.brandColor) ?? tokens.accent
        let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)

        Image(systemName: "wand.and.stars")
            .font(themeStore.uiFont(size: size * 0.43, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: shape)
            .overlay {
                shape.strokeBorder(Color.white.opacity(0.22), lineWidth: 0.75)
            }
            .shadow(color: tint.opacity(0.2), radius: 5, y: 2)
            .accessibilityHidden(true)
    }
}

/// 两个 Skill 入口共用的选择内容。它不拥有 Popover/Sheet，只负责一致的
/// 多选语义、搜索、刷新和完成操作，外层可按入口提供返回动作。
struct SkillSelectionContent: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let skills: [SkillCapability]
    let selectedPaths: Set<String>
    let errorMessage: String?
    let isRefreshing: Bool
    let maxListHeight: CGFloat
    let onBack: (() -> Void)?
    let onToggle: (SkillCapability) -> Void
    let onRefresh: () -> Void
    let onManualAdd: () -> Void
    let onDone: () -> Void

    @State private var searchText = ""

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 14) {
            header(tokens: tokens)

            if skills.count > 7 {
                searchField(tokens: tokens)
            }

            Group {
                if filteredSkills.isEmpty {
                    emptyState(tokens: tokens)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(filteredSkills) { skill in
                                SkillSelectionRow(
                                    skill: skill,
                                    isSelected: selectedPaths.contains(skill.path),
                                    onToggle: { onToggle(skill) }
                                )
                            }
                        }
                        .padding(.vertical, 1)
                    }
                    .frame(maxHeight: maxListHeight)
                    .scrollIndicators(.hidden)
                }
            }

            Button(action: onManualAdd) {
                Label(L10n.text("ui.add_skills_manually"), systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .frame(minHeight: 44)
        }
        .accessibilityIdentifier("composer.skillPicker")
    }

    @ViewBuilder
    private func header(tokens: ThemeTokens) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    leadingHeaderControl(tokens: tokens)
                    headerTitle(tokens: tokens)
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    refreshButton(tokens: tokens)
                    doneButton
                }
            }
        } else {
            HStack(spacing: 10) {
                leadingHeaderControl(tokens: tokens)
                headerTitle(tokens: tokens)
                Spacer(minLength: 4)
                refreshButton(tokens: tokens)
                doneButton
            }
        }
    }

    @ViewBuilder
    private func leadingHeaderControl(tokens: ThemeTokens) -> some View {
        if let onBack {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(themeStore.uiFont(.callout, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                    .frame(width: 44, height: 44)
                    .background(tokens.selectionFill, in: Circle())
            }
            .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
            .accessibilityLabel(L10n.text("ui.return_to_add_content"))
        } else {
            SkillIconView(
                metadata: SkillVisualMetadata(name: "skill", path: "skill"),
                size: 38
            )
            .frame(width: 44, height: 44)
        }
    }

    private func headerTitle(tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.text("ui.skills"))
                .font(themeStore.uiFont(.headline, weight: .semibold))
                .foregroundStyle(tokens.primaryText)
            Text(L10n.text("ui.once_selected_it_will_be_sent_with_the"))
                .font(themeStore.uiFont(.caption))
                .foregroundStyle(tokens.secondaryText)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func refreshButton(tokens: ThemeTokens) -> some View {
        Button(action: onRefresh) {
            Group {
                if isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(themeStore.uiFont(.callout, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                }
            }
            .frame(width: 44, height: 44)
            .background(tokens.selectionFill.opacity(0.72), in: Circle())
        }
        .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
        .disabled(isRefreshing)
        .accessibilityLabel(L10n.text("ui.refresh_skill_list"))
    }

    private var doneButton: some View {
        Button(L10n.text("ui.complete"), action: onDone)
            .buttonStyle(.borderedProminent)
            .frame(minWidth: 64, minHeight: 44)
            .accessibilityIdentifier("composer.skillPicker.done")
    }

    private func searchField(tokens: ThemeTokens) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(tokens.tertiaryText)
            TextField(L10n.text("ui.search_skill"), text: $searchText)
                .font(themeStore.uiFont(.callout))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(tokens.tertiaryText)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("ui.clear_search"))
            }
        }
        .padding(.leading, 11)
        .frame(minHeight: 44)
        .background(tokens.selectionFill.opacity(0.72), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var filteredSkills: [SkillCapability] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return skills }
        return skills.filter { skill in
            skill.name.localizedCaseInsensitiveContains(query)
                || skill.presentationName.localizedCaseInsensitiveContains(query)
                || (skill.presentationDescription?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private func emptyState(tokens: ThemeTokens) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "wand.and.stars.inverse")
                .font(themeStore.uiFont(size: 26, weight: .medium))
                .foregroundStyle(tokens.tertiaryText)
            Text(searchText.isEmpty ? L10n.text("ui.no_skills_available_yet") : L10n.text("ui.no_matching_skill"))
                .font(themeStore.uiFont(.callout, weight: .medium))
                .foregroundStyle(tokens.secondaryText)
            if searchText.isEmpty, let error = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
                Text(error)
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(tokens.tertiaryText)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 150)
    }
}

/// 独立 Skill 入口的展示壳；`+` 面板直接嵌入 SkillSelectionContent，
/// 两处因容器不同保留各自材质和尺寸，但列表视觉与行为完全一致。
struct SkillPickerPanel: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    let skills: [SkillCapability]
    let selectedPaths: Set<String>
    let errorMessage: String?
    let isRefreshing: Bool
    let onToggle: (SkillCapability) -> Void
    let onRefresh: () -> Void
    let onManualAdd: () -> Void
    let onDone: () -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        SkillSelectionContent(
            skills: skills,
            selectedPaths: selectedPaths,
            errorMessage: errorMessage,
            isRefreshing: isRefreshing,
            maxListHeight: 390,
            onBack: nil,
            onToggle: onToggle,
            onRefresh: onRefresh,
            onManualAdd: onManualAdd,
            onDone: onDone
        )
        .padding(16)
        .frame(idealWidth: 390, maxWidth: 420)
        .background(tokens.surface)
    }
}

private struct SkillSelectionRow: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let skill: SkillCapability
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let metadata = SkillVisualMetadata(capability: skill)
        let tint = SkillBrandColor.color(skill.brandColor) ?? tokens.accent

        return Button(action: onToggle) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 11) {
                            SkillIconView(metadata: metadata, size: 38)
                            skillDescription(metadata: metadata, tokens: tokens)
                            selectionIndicator(isSelected: isSelected, tint: tint, tokens: tokens)
                        }
                        if let scope = metadata.scopeTitle {
                            scopeBadge(scope, isSelected: isSelected, tint: tint, tokens: tokens)
                                .padding(.leading, 49)
                        }
                    }
                } else {
                    HStack(spacing: 11) {
                        SkillIconView(metadata: metadata, size: 38)
                        skillDescription(metadata: metadata, tokens: tokens)
                        if let scope = metadata.scopeTitle {
                            scopeBadge(scope, isSelected: isSelected, tint: tint, tokens: tokens)
                        }
                        selectionIndicator(isSelected: isSelected, tint: tint, tokens: tokens)
                    }
                }
            }
            .padding(10)
            .frame(minHeight: dynamicTypeSize.isAccessibilitySize ? 82 : 58)
            .background(
                isSelected ? tint.opacity(0.11) : tokens.elevatedSurface,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? tint.opacity(0.52) : tokens.border.opacity(0.82), lineWidth: isSelected ? 1.25 : 1)
            }
            .scaleEffect(isSelected && !reduceMotion ? 1.012 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.32, dampingFraction: 0.86), value: isSelected)
        .accessibilityLabel(L10n.format("ui.skill_named", metadata.displayName))
        .accessibilityValue(isSelected ? L10n.text("ui.selected") : L10n.text("ui.not_selected"))
        .accessibilityIdentifier("composer.skillPicker.row.\(skill.name)")
    }

    private func skillDescription(
        metadata: SkillVisualMetadata,
        tokens: ThemeTokens
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("$\(metadata.displayName)")
                .font(themeStore.uiFont(.callout, weight: .semibold))
                .foregroundStyle(tokens.primaryText)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            if let description = metadata.description {
                Text(description)
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func scopeBadge(
        _ scope: String,
        isSelected: Bool,
        tint: Color,
        tokens: ThemeTokens
    ) -> some View {
        Text(scope)
            .font(themeStore.uiFont(.caption2, weight: .semibold))
            .foregroundStyle(isSelected ? tint : tokens.tertiaryText)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background((isSelected ? tint : tokens.border).opacity(0.12), in: Capsule())
    }

    private func selectionIndicator(
        isSelected: Bool,
        tint: Color,
        tokens: ThemeTokens
    ) -> some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(themeStore.uiFont(size: 18, weight: .semibold))
            .foregroundStyle(isSelected ? tint : tokens.tertiaryText)
            .frame(width: 28, height: 38)
            .accessibilityHidden(true)
    }
}

struct SkillAttachmentToken: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    let metadata: SkillVisualMetadata
    let onOpen: (() -> Void)?
    let onRemove: () -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let tint = SkillBrandColor.color(metadata.brandColor) ?? tokens.accent
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)

        HStack(spacing: 8) {
            Button {
                onOpen?()
            } label: {
                HStack(spacing: 8) {
                    SkillIconView(metadata: metadata, size: 30)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("$\(metadata.displayName)")
                            .font(themeStore.uiFont(.caption, weight: .semibold))
                            .foregroundStyle(tokens.primaryText)
                            .lineLimit(1)
                        Text("SKILL")
                            .font(themeStore.uiFont(size: 9, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(tint)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(onOpen == nil)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(themeStore.uiFont(size: 16, weight: .semibold))
                    .foregroundStyle(tokens.tertiaryText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.format("ui.remove_skill_value", metadata.displayName))
        }
        .padding(.leading, 7)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(tint.opacity(0.09), in: shape)
        .overlay {
            shape.strokeBorder(tint.opacity(0.38), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer.skillAttachment.\(metadata.name)")
    }
}

struct SkillInvocationCard: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let metadata: SkillVisualMetadata
    let sendStatus: MessageSendStatus
    var usesUserBubbleContrast = false

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let tint = SkillBrandColor.color(metadata.brandColor) ?? tokens.accent
        let primary = usesUserBubbleContrast ? Color.white : tokens.primaryText
        let secondary = usesUserBubbleContrast ? Color.white.opacity(0.76) : tokens.secondaryText
        let statusTint = usesUserBubbleContrast ? Color.white.opacity(0.9) : tint
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

        HStack(alignment: .top, spacing: 10) {
            SkillIconView(metadata: metadata, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text("$\(metadata.displayName)")
                        .font(themeStore.uiFont(.callout, weight: .semibold))
                        .foregroundStyle(primary)
                        .lineLimit(1)
                    statusSymbol(tint: statusTint)
                }
                if let description = metadata.description {
                    Text(description)
                        .font(themeStore.uiFont(.caption))
                        .foregroundStyle(secondary)
                        .lineLimit(2)
                } else {
                    Text(L10n.text("ui.has_been_called_with_this_round"))
                        .font(themeStore.uiFont(.caption))
                        .foregroundStyle(secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("SKILL")
                .font(themeStore.uiFont(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(usesUserBubbleContrast ? Color.white.opacity(0.82) : tint)
                .padding(.top, 2)
        }
        .padding(10)
        .background {
            if usesUserBubbleContrast {
                shape.fill(Color.white.opacity(0.1))
            } else if tokens.resolvedScheme == .light {
                // 浅色用户气泡是中性浅表面，卡片再用主题表面加少量品牌色，
                // 避免信息与外层背景粘在一起。
                shape
                    .fill(tokens.surface)
                    .overlay {
                        shape.fill(tint.opacity(0.08))
                    }
            } else {
                shape.fill(tint.opacity(0.08))
            }
        }
        .overlay {
            shape.strokeBorder(
                sendStatus == .failed
                    ? Color.red.opacity(0.7)
                    : (usesUserBubbleContrast ? Color.white.opacity(0.22) : tint.opacity(0.32)),
                lineWidth: 1
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.format("ui.skill_value_has_been_called", metadata.displayName))
    }

    @ViewBuilder
    private func statusSymbol(tint: Color) -> some View {
        switch sendStatus {
        case .sending, .local:
            ProgressView()
                .controlSize(.mini)
                .tint(tint)
                .transition(.opacity)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        case .sent, .confirmed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(tint)
                .symbolEffect(.appear, options: reduceMotion ? .nonRepeating : .nonRepeating)
        }
    }
}

struct SkillAutocompletePanel: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    let skills: [SkillCapability]
    let selectedIndex: Int
    let onSelect: (SkillCapability) -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(L10n.text("ui.select_skill"), systemImage: "wand.and.stars")
                Spacer()
                Text(L10n.text("ui.select_confirm_esc_close"))
            }
            .font(themeStore.uiFont(.caption2, weight: .semibold))
            .foregroundStyle(tokens.secondaryText)
            .padding(.horizontal, 8)
            .padding(.bottom, 2)

            ForEach(Array(skills.enumerated()), id: \.element.id) { index, skill in
                Button {
                    onSelect(skill)
                } label: {
                    HStack(spacing: 9) {
                        SkillIconView(metadata: SkillVisualMetadata(capability: skill), size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("$\(skill.presentationName)")
                                .font(themeStore.uiFont(.caption, weight: .semibold))
                                .foregroundStyle(tokens.primaryText)
                            if let description = skill.presentationDescription {
                                Text(description)
                                    .font(themeStore.uiFont(.caption2))
                                    .foregroundStyle(tokens.secondaryText)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        if index == selectedIndex {
                            Image(systemName: "return")
                                .foregroundStyle(tokens.accent)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        index == selectedIndex ? tokens.selectionFill : .clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(WorkbenchMaterial.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tokens.border.opacity(0.9), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.18), radius: 16, y: 7)
    }
}

private enum SkillBrandColor {
    static func color(_ rawValue: String?) -> Color? {
        guard var value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("#") {
            value.removeFirst()
        }
        guard value.count == 6, let rgb = UInt64(value, radix: 16) else {
            return nil
        }
        return Color(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}
