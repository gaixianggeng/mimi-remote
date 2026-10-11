import SwiftUI

/// 还没有打开任何工作区时，直接列出这台电脑上的候选项目（#554）。
///
/// 「已打开的工作区」只保存在 iOS 本地、按连接档案分开存，新配对的设备必然为空，
/// 哪怕电脑上早就有项目；而 agentd 已经把电脑端首次设置所选代码文件夹下的子目录
/// 作为候选项目返回（`/api/projects`）。过去用户要先找到「打开目录」，再在服务端目录
/// 浏览器里认路径；这里点一下就打开，不在列表里的再走「打开其他文件夹…」。
///
/// 会话、工作区两个 Tab 保持平铺写法，不用卡片。组件本身不滚动：会话页把它放在列表行里，
/// 工作区页在外面包一层 ScrollView。
struct WorkspaceSuggestionsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore
    @State private var openingProjectID: String?
    @State private var errorMessage: String?

    let projects: [AgentProject]
    let onOpen: (AgentProject) async -> WorkspaceOpenOutcome
    let onBrowseOther: () -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.text("ui.workspace_definition_open_one"))
                .font(themeStore.uiFont(.subheadline))
                .foregroundStyle(tokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 20)

            Text(L10n.text("ui.projects_on_this_computer"))
                .pageSectionHeaderStyle()
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 4)

            ForEach(sortedProjects) { project in
                projectRow(project, tokens: tokens)
                Divider()
                    .overlay(tokens.settingsRowSeparator)
                    .padding(.leading, Self.textLeading)
            }

            Button(action: onBrowseOther) {
                HStack(spacing: 12) {
                    rowIcon("folder.badge.plus", tokens: tokens)
                    Text(L10n.text("ui.open_other_folder"))
                        .font(themeStore.uiFont(.body))
                        .foregroundStyle(tokens.primaryText)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tokens.tertiaryText)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(openingProjectID != nil)
            .accessibilityIdentifier("workspace.suggestions.browse")

            if let errorMessage {
                Text(errorMessage)
                    .font(themeStore.uiFont(.footnote))
                    .foregroundStyle(tokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
                    .accessibilityIdentifier("workspace.suggestions.error")
            }

            Text(L10n.text("ui.projects_on_this_computer_footnote"))
                .font(themeStore.uiFont(.footnote))
                .foregroundStyle(tokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
        }
        .frame(maxWidth: 560, alignment: .leading)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.suggestions")
    }

    /// 图标列 + 间距：分隔线从名称起画，与设置页卡片内的分隔线同一种读法。
    private static let textLeading: CGFloat = 24 + 12

    private var sortedProjects: [AgentProject] {
        projects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func projectRow(_ project: AgentProject, tokens: ThemeTokens) -> some View {
        Button {
            open(project)
        } label: {
            HStack(spacing: 12) {
                rowIcon("folder", tokens: tokens)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(themeStore.uiFont(.body))
                        .foregroundStyle(tokens.primaryText)
                        .lineLimit(1)
                    Text(Self.compactPath(project.path))
                        .font(themeStore.uiFont(.footnote))
                        .foregroundStyle(tokens.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if openingProjectID == project.id {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(L10n.text("ui.open"))
                        .font(themeStore.uiFont(.subheadline))
                        .foregroundStyle(tokens.secondaryText)
                }
            }
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        // 列表行里放多枚按钮时必须用 plain，否则点一行会同时触发整组按钮。
        .buttonStyle(.plain)
        .disabled(openingProjectID != nil)
        .accessibilityLabel(project.name)
        .accessibilityValue(Self.compactPath(project.path))
        .accessibilityHint(L10n.text("ui.open_this_project_as_workspace"))
        .accessibilityIdentifier("workspace.suggestion.\(project.id)")
    }

    private func rowIcon(_ systemImage: String, tokens: ThemeTokens) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .regular))
            .foregroundStyle(tokens.settingsIconTint)
            .frame(width: 24, height: 24)
            .accessibilityHidden(true)
    }

    private func open(_ project: AgentProject) {
        guard openingProjectID == nil else { return }
        openingProjectID = project.id
        errorMessage = nil
        Task {
            let outcome = await onOpen(project)
            openingProjectID = nil
            if case .failed(let message) = outcome {
                errorMessage = message
            }
        }
    }

    /// 隐去本机用户名：降低视觉噪音，也避免屏幕共享时反复露出完整路径。
    static func compactPath(_ path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard path.hasPrefix("/"), components.count >= 2, components.first == "Users" else {
            return path
        }
        let relativeComponents = components.dropFirst(2)
        return relativeComponents.isEmpty ? "~" : "~/" + relativeComponents.joined(separator: "/")
    }
}
