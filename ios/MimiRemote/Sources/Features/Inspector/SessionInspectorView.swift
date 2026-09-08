import SwiftUI

struct SessionInspectorView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedSection: SessionInspectorSection = .overview

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(spacing: 0) {
            header
            Picker(L10n.text("ui.inspector"), selection: $selectedSection) {
                ForEach(SessionInspectorSection.allCases) { section in
                    Image(systemName: section.symbolName)
                        .font(themeStore.uiFont(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .tag(section)
                        .accessibilityLabel(section.title)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 14)
            .padding(.bottom, 12)

            Rectangle()
                .fill(tokens.border.opacity(0.7))
                .frame(height: 1)

            Group {
                switch selectedSection {
                case .overview:
                    SessionContextSidebarView()
                case .changes:
                    DiffPanelView()
                case .activity:
                    // 审批/补充输入历史也是运行活动的一部分；待处理卡仍直接显示在 Composer。
                    RuntimeActivityPanelView()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(tokens.sidebarBackground)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(tokens.border.opacity(0.78))
                .frame(width: 1)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(tokens.border.opacity(0.42))
                .frame(height: 1)
        }
    }

    private var header: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        return HStack(spacing: 10) {
            Image(systemName: selectedSection.symbolName)
                .font(themeStore.uiFont(size: 15, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tokens.accent)
                .frame(width: 34, height: 34)
                .background(tokens.elevatedSurface.opacity(0.74), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(tokens.border.opacity(0.62), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(selectedSection.title)
                    .font(themeStore.uiFont(.subheadline, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                Text(sessionSubtitle)
                    .font(themeStore.codeFont(.caption2))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .layoutPriority(1)

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 9)
        .padding(.bottom, 9)
    }

    private var sessionSubtitle: String {
        sessionStore.selectedSession?.title ?? sessionStore.selectedProject?.name ?? L10n.text("ui.no_session_selected")
    }
}

private enum SessionInspectorSection: String, CaseIterable, Identifiable {
    case overview
    case changes
    case activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview:
            return L10n.text("ui.overview")
        case .changes:
            return L10n.text("ui.change")
        case .activity:
            return L10n.text("ui.activities")
        }
    }

    var symbolName: String {
        switch self {
        case .overview:
            return "sidebar.right"
        case .changes:
            return "doc.text.magnifyingglass"
        case .activity:
            return "list.bullet.rectangle"
        }
    }
}

struct SessionInspectorSectionDescriptor: Equatable {
    let id: String
    let title: String
    let symbolName: String

    static var all: [SessionInspectorSectionDescriptor] {
        SessionInspectorSection.allCases.map {
            SessionInspectorSectionDescriptor(
                id: $0.id,
                title: $0.title,
                symbolName: $0.symbolName
            )
        }
    }
}

private enum RuntimeActivityMode: String, CaseIterable, Identifiable {
    case entries
    case output

    var id: String { rawValue }

    var title: String {
        switch self {
        case .entries:
            return L10n.text("ui.entry")
        case .output:
            return L10n.text("ui.raw_output")
        }
    }
}

private struct RuntimeActivityPanelView: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var conversationStore: ConversationStore
    @EnvironmentObject private var logStore: LogStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedMode: RuntimeActivityMode = .entries

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(spacing: 0) {
            Picker(L10n.text("ui.activities"), selection: $selectedMode) {
                ForEach(RuntimeActivityMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(12)

            Rectangle()
                .fill(tokens.border)
                .frame(height: 1)

            Group {
                switch selectedMode {
                case .entries:
                    entriesContent(tokens: tokens)
                case .output:
                    outputContent(tokens: tokens)
                }
            }
        }
        .background(tokens.surface)
    }

    private func entriesContent(tokens: ThemeTokens) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if runtimeMessages.isEmpty {
                    ContentUnavailableView(L10n.text("ui.no_active_entries_yet"), systemImage: "list.bullet.rectangle")
                        .font(themeStore.uiFont(.caption))
                        .padding(.top, 48)
                } else {
                    ForEach(runtimeMessages) { message in
                        InspectorSummaryCard(
                            symbolName: symbolName(for: message.kind),
                            title: title(for: message.kind),
                            subtitle: message.content,
                            tint: tint(for: message.kind, tokens: tokens),
                            lineLimit: nil
                        )
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func outputContent(tokens: ThemeTokens) -> some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Toggle(L10n.text("ui.autoscroll"), isOn: $logStore.autoScroll)
                    .toggleStyle(.switch)
                    .font(themeStore.uiFont(.caption))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(tokens.surface)

            Rectangle()
                .fill(tokens.border)
                .frame(height: 1)

            LogTailContentView()
        }
    }

    private var runtimeMessages: [ConversationMessage] {
        Array(
            conversationStore
                .messages(for: sessionStore.selectedSessionID)
                .filter { $0.kind != .message }
                .suffix(80)
        )
    }

    private func title(for kind: MessageKind) -> String {
        switch kind {
        case .commentary:
            return L10n.text("ui.process_description")
        case .plan:
            return L10n.text("ui.plan")
        case .reasoningSummary:
            return L10n.text("ui.reasoning_summary")
        case .commandSummary:
            return L10n.text("ui.command_tool")
        case .fileChangeSummary:
            return L10n.text("ui.file_changes")
        case .approval:
            return L10n.text("ui.approval")
        case .userInput:
            return L10n.text("ui.supplementary_information")
        case .error:
            return L10n.text("ui.abnormal_operation")
        case .warning:
            return L10n.text("ui.run_warning")
        case .message:
            return L10n.text("ui.news")
        }
    }

    private func symbolName(for kind: MessageKind) -> String {
        switch kind {
        case .commentary:
            return "text.bubble"
        case .plan:
            return "list.clipboard"
        case .reasoningSummary:
            return "brain.head.profile"
        case .commandSummary:
            return "terminal"
        case .fileChangeSummary:
            return "doc.text.magnifyingglass"
        case .approval:
            return "checkmark.seal"
        case .userInput:
            return "questionmark.bubble"
        case .error:
            return "exclamationmark.triangle"
        case .warning:
            return "exclamationmark.triangle"
        case .message:
            return "info.circle"
        }
    }

    private func tint(for kind: MessageKind, tokens: ThemeTokens) -> Color {
        switch kind {
        case .plan:
            return tokens.accent
        case .approval:
            return tokens.warning
        case .userInput:
            return tokens.accent
        case .error:
            return .red
        case .fileChangeSummary:
            return tokens.accent
        default:
            return tokens.secondaryText
        }
    }
}
