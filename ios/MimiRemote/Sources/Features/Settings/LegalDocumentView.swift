import SwiftUI

enum LegalDocument: CaseIterable {
    case privacyPolicy
    case termsOfUse
    case support

    var title: String {
        switch self {
        case .privacyPolicy:
            return L10n.text("ui.privacy_policy")
        case .termsOfUse:
            return L10n.text("ui.terms_of_use")
        case .support:
            return L10n.text("ui.support_and_contact")
        }
    }

    var resourceName: String {
        switch self {
        case .privacyPolicy:
            return "privacy-policy"
        case .termsOfUse:
            return "terms-of-use"
        case .support:
            return "support"
        }
    }

    var onlineURL: URL {
        switch self {
        case .privacyPolicy:
            return AppExternalLinks.privacyPolicy
        case .termsOfUse:
            return AppExternalLinks.termsOfUse
        case .support:
            return AppExternalLinks.support
        }
    }
}

struct LegalDocumentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    let document: LegalDocument

    private var blocks: [MarkdownBlock] {
        MarkdownParser.shared.parse(Self.load(document)).blocks
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let style = MarkdownStyle.make(
            role: .assistant,
            colorScheme: colorScheme,
            fontScale: themeStore.fontScale,
            tokens: tokens
        )

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                Link(destination: document.onlineURL) {
                    Label(L10n.text("ui.view_online"), systemImage: "arrow.up.right.square")
                        .font(themeStore.uiFont(.callout, weight: .semibold))
                }
                .accessibilityIdentifier("settings.legalDocument.viewOnline")

                ForEach(blocks) { block in
                    MarkdownBlockView(block: block, style: style)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .textSelection(.enabled)
        }
        .settingsCanvasBackground(tokens: tokens)
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private static func load(_ document: LegalDocument) -> String {
        guard let url = Bundle.main.url(forResource: document.resourceName, withExtension: "md"),
              let content = try? String(contentsOf: url, encoding: .utf8)
        else {
            return L10n.text("ui.legal_document_could_not_be_loaded")
        }
        return content
    }
}
