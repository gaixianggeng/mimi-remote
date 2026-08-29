import SwiftUI

struct ThirdPartyNoticesView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    private let projectLicense: String
    private let blocks: [MarkdownBlock]

    init() {
        // 项目协议按纯文本展示，避免 GPL 正文中的缩进被误判为 Markdown 代码块；
        // 第三方许可文件继续复用会话中已经验证过的解析与表格渲染，
        // 避免把 #、反引号和表格分隔符作为源码暴露给用户。
        projectLicense = Self.loadProjectLicense()
        blocks = MarkdownParser.shared.parse(Self.loadNotices()).blocks
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
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.text("ui.mimi_remote_project_license"))
                        .font(.title3.weight(.semibold))
                    Text("Copyright © 2026 Gaixiang Geng")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(L10n.text("ui.mimi_remote_is_licensed_under_the_gnu_gplv3"))
                        .font(.body)
                    DisclosureGroup(L10n.text("ui.view_the_full_terms_of_gnu_gplv3")) {
                        Text(projectLicense)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                            .textSelection(.enabled)
                    }
                }

                Divider()

                Text(L10n.text("ui.third_party_dependency_license"))
                    .font(.title3.weight(.semibold))

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
        .navigationTitle(L10n.text("ui.open_source_license"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private static func loadProjectLicense() -> String {
        guard let url = Bundle.main.url(forResource: "LICENSE", withExtension: nil) else {
            return L10n.text("ui.project_license_file_not_found_please_view_license")
        }

        // 协议正文随 App 本地打包，离线也能完整查看，不依赖外部网页长期可用。
        return (try? String(contentsOf: url, encoding: .utf8))
            ?? L10n.text("ui.failed_to_read_the_project_license_file_please")
    }

    private static func loadNotices() -> String {
        guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") else {
            return L10n.text("ui.third_party_license_file_not_found_please_view")
        }

        // 许可正文随 App 本地打包，查看时不依赖网络，也不会把设备信息发送给外部服务。
        return (try? String(contentsOf: url, encoding: .utf8))
            ?? L10n.text("ui.failed_to_read_third_party_license_file_please")
    }
}
