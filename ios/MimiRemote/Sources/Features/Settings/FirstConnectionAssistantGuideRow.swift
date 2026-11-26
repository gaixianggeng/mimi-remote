import SwiftUI

/// 首次连接步骤 1 的多助手准备项：只需在电脑上准备好 4 个受支持助手中的任意 1 个即可开始。
struct FirstConnectionAssistantGuideItem: Identifiable, Equatable, Sendable {
    let id: String
    let titleKey: String
    let systemImage: String
    let fixURL: PairingOnboardingFixURL

    var title: String {
        L10n.text(titleKey)
    }

    var destination: URL {
        fixURL.url
    }

    static let allItems: [Self] = [
        Self(
            id: "codex",
            titleKey: "ui.first_connection_assistant_codex_guide",
            systemImage: "terminal",
            fixURL: .codex
        ),
        Self(
            id: "claude",
            titleKey: "ui.first_connection_assistant_claude_guide",
            systemImage: "terminal",
            fixURL: .claude
        ),
        Self(
            id: "agy",
            titleKey: "ui.first_connection_assistant_agy_guide",
            systemImage: "sparkles",
            fixURL: .agy
        ),
        Self(
            id: "deepseek",
            titleKey: "ui.first_connection_assistant_deepseek_guide",
            systemImage: "cpu",
            fixURL: .harness
        ),
    ]
}

/// 首次连接步骤 1 内的多助手说明行：默认折叠，展开后展示 4 个受支持助手的官方准备入口，
/// 明确说明只需其中任意 1 个即可配对使用。
struct FirstConnectionAssistantGuideRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore
    @State private var isExpanded = false

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        DisclosureGroup(isExpanded: $isExpanded) {
            EmptyView()
        } label: {
            ConnectionRowLabel(
                title: L10n.text("ui.first_connection_prepare_assistant"),
                systemImage: "sparkles"
            )
            .accessibilityIdentifier("settings.firstConnection.assistants.disclosure")
        }
        .disclosureGroupStyle(SettingsDisclosureGroupStyle())
        .settingsRow()
        .settingsGroupRowStyle()
        .accessibilityHint(L10n.text("ui.first_connection_codex_note"))
        .accessibilityIdentifier("settings.firstConnection.assistants")

        if isExpanded {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("ui.first_connection_assistant_guide_summary"))
                    .font(themeStore.uiFont(.footnote))
                    .foregroundStyle(tokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 8)

                ForEach(FirstConnectionAssistantGuideItem.allItems) { item in
                    SettingsExternalLinkRow(
                        title: item.title,
                        systemImage: item.systemImage,
                        destination: item.destination
                    )
                    .accessibilityIdentifier("settings.firstConnection.assistant.\(item.id)")
                }
            }
            .settingsRow()
            .settingsGroupRowStyle()
            .listRowSeparator(.hidden, edges: .top)
        }
    }
}
