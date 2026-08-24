import SwiftUI

/// 「我的」页里可选项设置的统一表达。
///
/// 过去语言、语音输入、默认权限三行都是系统 `Picker(.menu)`：改一个二选一要经过
/// 点开、看、点选项、关闭四步，而且每项只渲染 `Text(title)`，
/// `VoiceInputProvider.subtitle` 和 `ComposerPermissionMode.detail` 这些
/// app 里已经写好的说明在菜单里完全用不上——用户选「完全文件访问」时看不到它意味着什么。
protocol SettingsChoiceOption: Identifiable, Hashable {
    var choiceTitle: String { get }
    var choiceSubtitle: String? { get }
    var choiceSystemImage: String? { get }
}

extension SettingsChoiceOption {
    var choiceSubtitle: String? { nil }
    var choiceSystemImage: String? { nil }
}

extension AppLanguage: SettingsChoiceOption {
    var choiceTitle: String { displayName }
}

extension VoiceInputProvider: SettingsChoiceOption {
    var choiceTitle: String { title }
    var choiceSubtitle: String? { subtitle }
    var choiceSystemImage: String? {
        guard case .system(let name) = icon else { return nil }
        return name
    }
}

extension ComposerPermissionMode: SettingsChoiceOption {
    var choiceTitle: String { title }
    var choiceSubtitle: String? { detail }
    var choiceSystemImage: String? { systemImage }
}

enum SettingsChoiceMetrics {
    /// 胶囊的内边距。选项行要按它回退缩进，才能让选项文字和标题、说明左对齐。
    static let capsuleHorizontalPadding: CGFloat = 12
}

/// 呈现方式按内容形态选，而不是按平台写死尺寸。
enum SettingsChoicePresentation {
    /// 选项少且短，不需要逐条对照说明：胶囊就地切换，零弹层。
    case inline
    /// 选项多，或每项都要读完说明才能选：推一整页，天然适配 Dynamic Type 与 iPad。
    case page
}

struct SettingsChoiceRow<Option: SettingsChoiceOption>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var themeStore: ThemeStore

    let title: String
    let systemImage: String
    let options: [Option]
    @Binding var selection: Option
    var presentation: SettingsChoicePresentation = .inline

    var body: some View {
        switch presentation {
        case .inline:
            inlineRow(tokens: themeStore.tokens(for: colorScheme))
        case .page:
            NavigationLink {
                SettingsOptionListView(
                    title: title,
                    options: options,
                    selection: $selection
                )
            } label: {
                SettingsValueLabel(
                    title: title,
                    value: selection.choiceTitle,
                    systemImage: systemImage
                )
            }
        }
    }

    private func inlineRow(tokens: ThemeTokens) -> some View {
        // 行数由可用宽度决定，不写死。语言这种短选项在多数宽度下一行就放得下；
        // 语音输入带说明，通常需要第二行给胶囊。
        ViewThatFits(in: .horizontal) {
            if !dynamicTypeSize.isAccessibilitySize {
                HStack(alignment: .center, spacing: 12) {
                    titleCluster(tokens: tokens)
                    Spacer(minLength: 12)
                    optionCapsules(tokens: tokens)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 12) {
                    titleCluster(tokens: tokens)
                    Spacer(minLength: 8)
                }

                // 胶囊自带内边距，直接按 optionInset 缩进会让选项文字比标题右移同样的量。
                // 这里回退相同距离，让「文字对文字」对齐。
                optionCapsules(tokens: tokens)
                    .padding(.leading, optionInset - SettingsChoiceMetrics.capsuleHorizontalPadding)
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    /// 图标、标题和当前项说明是同一簇信息。说明放标题右边而不是另起一行，
    /// 省下的那一行让整块从三行降到两行。
    private func titleCluster(tokens: ThemeTokens) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: SettingsLayoutMetrics.symbolPointSize, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                // 图标统一降到次要色，颜色只留给状态。四个偏好图标全用强调色时，
                // 颜色没有承载任何信息，只是噪音。
                .foregroundStyle(tokens.secondaryText)
                .frame(width: SettingsLayoutMetrics.iconSlot, alignment: .leading)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }
                .accessibilityHidden(true)

            Text(title)
                .font(themeStore.uiFont(.body))
                .foregroundStyle(tokens.primaryText)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .fixedSize(horizontal: true, vertical: false)

            if let subtitle = selection.choiceSubtitle {
                Text(subtitle)
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                    .minimumScaleFactor(0.85)
            }
        }
    }

    private var optionInset: CGFloat {
        SettingsLayoutMetrics.iconSlot + 12
    }

    @ViewBuilder
    private func optionCapsules(tokens: ThemeTokens) -> some View {
        // 大字号下一行摆不开就竖排，胶囊各自占满宽度；不横向滚动、不裁切。
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(options) { option in
                    capsule(for: option, tokens: tokens, fillsWidth: true)
                }
            }
        } else {
            HStack(spacing: 6) {
                ForEach(options) { option in
                    capsule(for: option, tokens: tokens, fillsWidth: false)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func capsule(
        for option: Option,
        tokens: ThemeTokens,
        fillsWidth: Bool
    ) -> some View {
        let isSelected = option == selection

        return Button {
            guard !isSelected else { return }
            selection = option
        } label: {
            Text(option.choiceTitle)
                .font(themeStore.uiFont(.subheadline, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundStyle(isSelected ? tokens.accent : tokens.secondaryText)
                .padding(.horizontal, SettingsChoiceMetrics.capsuleHorizontalPadding)
                .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
                .frame(height: 32)
                // 未选中不画容器，和工作区页的筛选器保持同一套写法。
                .background(isSelected ? tokens.selectionFill : Color.clear, in: Capsule())
                // 视觉高度 32，触达高度补到 44。
                .frame(minHeight: 44)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.choiceTitle)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// 选项需要逐条说明时的整页选择器。push 在 iPhone 与 iPad 上表现一致，
/// 不必为 detent 高度、popover 箭头和窗口尺寸各写一套。
struct SettingsOptionListView<Option: SettingsChoiceOption>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var themeStore: ThemeStore

    let title: String
    let options: [Option]
    @Binding var selection: Option

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Form {
            Section {
                ForEach(options) { option in
                    Button {
                        selection = option
                    } label: {
                        optionRow(option, tokens: tokens)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .themedSettingsForm(tokens: tokens)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .background(tokens.workbenchCanvasBackground.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func optionRow(_ option: Option, tokens: ThemeTokens) -> some View {
        let isSelected = option == selection

        return HStack(alignment: .top, spacing: 12) {
            if let systemImage = option.choiceSystemImage {
                Image(systemName: systemImage)
                    .font(.system(size: SettingsLayoutMetrics.symbolPointSize, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tokens.secondaryText)
                    .frame(
                        width: SettingsLayoutMetrics.iconSlot,
                        height: SettingsLayoutMetrics.iconSlot
                    )
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(option.choiceTitle)
                    .font(themeStore.uiFont(.body))
                    .foregroundStyle(tokens.primaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if let subtitle = option.choiceSubtitle {
                    Text(subtitle)
                        .font(themeStore.uiFont(.footnote))
                        .foregroundStyle(tokens.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tokens.accent)
                .opacity(isSelected ? 1 : 0)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 6)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// 语言入口的详情页把应用语言和语音提供方放在同一层，首页只负责展示当前摘要。
/// 两个选择器仍然绑定到设置页持有的 AppStorage，因此返回首页或重启 App 后不会出现第二份状态。
struct LanguageSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    @Binding var appLanguageRawValue: String
    @Binding var voiceInputProviderRawValue: String

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Form {
            Section {
                SettingsChoiceRow(
                    title: L10n.text("ui.language"),
                    systemImage: "globe",
                    options: AppLanguage.allCases,
                    selection: appLanguageSelection
                )
                .detailListRow()
                .accessibilityIdentifier("settings.language.detail.language")
            } header: {
                Text(L10n.text("ui.language"))
            }

            Section {
                SettingsChoiceRow(
                    title: L10n.text("ui.voice_input"),
                    systemImage: "waveform",
                    options: VoiceInputProvider.availableProviders(),
                    selection: voiceInputProviderSelection
                )
                .detailListRow()
                .accessibilityIdentifier("settings.language.detail.voiceInput")
            }
        }
        .themedSettingsForm(tokens: tokens)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .background(tokens.workbenchCanvasBackground.ignoresSafeArea())
        .navigationTitle(L10n.text("ui.language"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var appLanguageSelection: Binding<AppLanguage> {
        Binding(
            get: { AppLanguage(rawValue: appLanguageRawValue) ?? .system },
            set: { appLanguageRawValue = $0.rawValue }
        )
    }

    private var voiceInputProviderSelection: Binding<VoiceInputProvider> {
        Binding(
            get: { VoiceInputProvider.resolved(rawValue: voiceInputProviderRawValue) },
            set: { voiceInputProviderRawValue = $0.rawValue }
        )
    }
}

private extension View {
    func detailListRow() -> some View {
        listRowInsets(
            EdgeInsets(
                top: 0,
                leading: SettingsLayoutMetrics.rowHorizontalInset,
                bottom: 0,
                trailing: SettingsLayoutMetrics.rowHorizontalInset
            )
        )
    }
}
