import SwiftUI
import UIKit

struct FileReferencePreviewStrip: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let references: [ConversationFileReference]
    let previewingPath: String?
    let previewError: String?
    let onPreview: (ConversationFileReference) -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(alignment: .leading, spacing: 6) {
            ForEach(references) { reference in
                Button {
                    onPreview(reference)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.viewfinder")
                            .font(themeStore.uiFont(.caption, weight: .semibold))
                            .foregroundStyle(tokens.accent)
                            .frame(width: 18, height: 18)
                        Text(reference.name)
                            .font(themeStore.uiFont(.caption, weight: .medium))
                            .foregroundStyle(tokens.primaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if previewingPath == reference.path {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(tokens.elevatedSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(tokens.border, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .disabled(previewingPath != nil)
                .accessibilityLabel(L10n.format("ui.preview_value", reference.name))
            }

            if let previewError {
                Text(previewError)
                    .font(themeStore.uiFont(.caption2))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SystemNotice: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let message: ConversationMessage
    let layout: ConversationLayout

    var body: some View {
        noticeSurface
            .contentShape(.interaction, Capsule())
            .contentShape(.contextMenuPreview, Capsule())
            .messageContextMenu(for: message)
            .frame(maxWidth: layout.systemMaxWidth)
    }

    private var noticeSurface: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        return ZStack(alignment: .bottomTrailing) {
            Text(message.content)
                .font(themeStore.uiFont(.caption))
                .foregroundStyle(tokens.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)
            MessageTimestampCaption(text: message.timestampCaptionText, isFallback: message.isTimestampFallback)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(tokens.systemBubble, in: Capsule())
    }
}

struct RuntimeSummaryCard: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var isRetryingClaudeAuthentication = false
    let message: ConversationMessage
    let layout: ConversationLayout

    var body: some View {
        cardSurface
            .contentShape(.interaction, RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 8, style: .continuous))
            .messageContextMenu(for: message)
            .frame(maxWidth: cardMaxWidth, alignment: .leading)
    }

    private var cardSurface: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbolName)
                .font(themeStore.uiFont(.caption, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16, height: 18)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                contentView
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    MessageTimestampCaption(text: message.timestampCaptionText, isFallback: message.isTimestampFallback)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tint.opacity(0.22), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var contentView: some View {
        if let payload = message.activityPayload {
            activityContent(payload)
        } else if message.kind == .plan {
            planMarkdownContent
        } else {
            Text(message.content)
                .font(themeStore.uiFont(.caption))
                .foregroundStyle(tokens.secondaryText)
                .lineLimit(3)
        }
    }

    private func activityContent(_ payload: ConversationActivityPayload) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if payload.isClaudeAuthenticationRecovery {
                Text(payload.subtitle ?? ClaudeAuthenticationRecovery.recoveryMessage)
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(tokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    claudeAuthenticationActions(stacked: false)
                    claudeAuthenticationActions(stacked: true)
                }
                .padding(.top, 3)
            } else if payload.category == .plan {
                planMarkdownContent
            } else if payload.category == .thinking, let subtitle = payload.subtitle {
                Text(subtitle)
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(3)
            } else {
                if let command = payload.command {
                    activityDetailRow(L10n.text("ui.command"), value: command, monospaced: true)
                }
                if let cwd = payload.cwd {
                    activityDetailRow(L10n.text("ui.directory"), value: cwd, monospaced: true)
                }
                if !payload.filePaths.isEmpty {
                    activityDetailRow(L10n.text("ui.file"), value: payload.filePaths.prefix(5).joined(separator: ", "), monospaced: true)
                }
                if let toolName = payload.toolName, payload.category == .toolCall {
                    activityDetailRow(L10n.text("ui.tools"), value: toolName, monospaced: true)
                }
                let statusText = [payload.displayStatusText.map { L10n.format("ui.status_value", $0) }, payload.exitCode.map { L10n.format("ui.exit_code_value", $0) }]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                if !statusText.isEmpty {
                    Text(statusText)
                        .font(themeStore.uiFont(.caption2, weight: .medium))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                }
                if let output = payload.outputPreview {
                    Text(output)
                        .font(themeStore.uiFont(.caption2).monospaced())
                        .foregroundStyle(tokens.secondaryText)
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func claudeAuthenticationActions(stacked: Bool) -> some View {
        if stacked {
            VStack(alignment: .leading, spacing: 8) {
                copyClaudeLoginCommandButton
                retryClaudeRequestButton
            }
        } else {
            HStack(spacing: 8) {
                copyClaudeLoginCommandButton
                retryClaudeRequestButton
            }
        }
    }

    private var copyClaudeLoginCommandButton: some View {
        Button {
            UIPasteboard.general.string = ClaudeAuthenticationRecovery.loginCommand
            sessionStore.setStatusMessage(L10n.text("ui.claude_login_command_copied"))
        } label: {
            Label(L10n.text("ui.copy_login_command"), systemImage: "doc.on.doc")
                // small control 的样式还会补齐边距，最终保持至少 44pt 的触控区域。
                .frame(minHeight: 36)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        // 不依赖页面或系统的默认 tint：深色外观的浅色 accent 会让白色
        // doc.on.doc 图标和按钮底色融在一起，主操作色才是可读的实色背景。
        .tint(tokens.primaryAction)
        .foregroundStyle(tokens.primaryActionForeground)
        .accessibilityHint(L10n.text("ui.copy_login_command_hint"))
        .accessibilityIdentifier("conversation.claudeAuthentication.copyLoginCommand")
    }

    private var retryClaudeRequestButton: some View {
        Button {
            guard !isRetryingClaudeAuthentication else { return }
            isRetryingClaudeAuthentication = true
            Task {
                _ = await sessionStore.retryClaudeAuthenticationFailure(message)
                isRetryingClaudeAuthentication = false
            }
        } label: {
            HStack(spacing: 5) {
                if isRetryingClaudeAuthentication {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
                Text(L10n.text("ui.try_again"))
            }
            .frame(minHeight: 36)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isRetryingClaudeAuthentication)
    }

    private func activityDetailRow(_ label: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(themeStore.uiFont(.caption2, weight: .semibold))
                .foregroundStyle(tokens.secondaryText.opacity(0.82))
                .frame(width: 30, alignment: .leading)
            Text(value)
                .font(monospaced ? themeStore.uiFont(.caption2).monospaced() : themeStore.uiFont(.caption2))
                .foregroundStyle(tokens.secondaryText)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private var planMarkdownContent: some View {
        let style = MarkdownStyle.make(
            role: .assistant,
            colorScheme: colorScheme,
            fontScale: themeStore.fontScale * 0.94,
            tokens: tokens
        )
        let plan = MessageRenderPlanCache.shared.plan(for: message)
        let blocks = displayBlocks(for: plan)

        return VStack(alignment: .leading, spacing: style.blockSpacing) {
            ForEach(blocks) { block in
                MarkdownBlockView(block: block, style: style)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cardMaxWidth: CGFloat {
        message.kind == .plan ? layout.assistantBubbleMaxWidth : layout.runtimeCardMaxWidth
    }

    private func displayBlocks(for plan: MessageRenderPlan) -> [MarkdownBlock] {
        guard plan.blocks.count == 1,
              case let .proposedPlan(blocks, _) = plan.blocks[0].kind
        else {
            return plan.blocks
        }
        return blocks
    }

    private var title: String {
        if let payload = message.activityPayload {
            return payload.displayTitle
        }
        switch message.kind {
        case .commentary:
            return L10n.text("ui.process_description")
        case .plan:
            return L10n.text("ui.plan")
        case .reasoningSummary:
            return L10n.text("ui.reasoning_summary")
        case .commandSummary:
            return L10n.text("ui.command")
        case .fileChangeSummary:
            return L10n.text("ui.file_changes")
        case .approval:
            if isApprovedApproval {
                return L10n.text("ui.approval_approved")
            }
            if isDeclinedApproval {
                return L10n.text("ui.approval_rejected")
            }
            return L10n.text("ui.waiting_for_approval")
        case .userInput:
            if message.content.hasPrefix(L10n.text("ui.additional_information_skipped")) || message.content.hasPrefix(L10n.text("ui.boot_input_skipped")) {
                return L10n.text("ui.supplementary_information_skipped")
            }
            if message.content.hasPrefix(L10n.text("ui.additional_information_has_been_submitted")) || message.content.hasPrefix(L10n.text("ui.boot_input_submitted")) {
                return L10n.text("ui.additional_information_has_been_submitted")
            }
            return L10n.text("ui.waiting_for_additional_information")
        case .error:
            return L10n.text("ui.abnormal_operation")
        case .message:
            return L10n.text("ui.status")
        }
    }

    private var symbolName: String {
        if let payload = message.activityPayload {
            return ProcessedActivitySymbol.symbolName(for: payload)
        }
        switch message.kind {
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
            if isApprovedApproval {
                return "checkmark.circle"
            }
            if isDeclinedApproval {
                return "xmark.circle"
            }
            return "exclamationmark.shield"
        case .userInput:
            return "questionmark.bubble"
        case .error:
            return "exclamationmark.triangle"
        case .message:
            return "info.circle"
        }
    }

    private var tint: Color {
        if let category = message.activityPayload?.category {
            switch category {
            case .plan, .editFile:
                return tokens.accent
            case .error:
                return .red
            case .thinking, .runCommand, .toolCall:
                return tokens.secondaryText
            }
        }
        switch message.kind {
        case .plan:
            return tokens.accent
        case .approval:
            if isApprovedApproval {
                return tokens.success
            }
            if isDeclinedApproval {
                return .red
            }
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

    private var background: Color {
        if let category = message.activityPayload?.category {
            switch category {
            case .plan:
                return tokens.accent.opacity(0.08)
            case .editFile:
                return tokens.accent.opacity(0.10)
            case .error:
                return Color.red.opacity(0.10)
            case .thinking, .runCommand, .toolCall:
                return tokens.systemBubble
            }
        }
        switch message.kind {
        case .plan:
            return tokens.accent.opacity(0.08)
        case .approval:
            if isApprovedApproval {
                return tokens.success.opacity(0.10)
            }
            if isDeclinedApproval {
                return Color.red.opacity(0.10)
            }
            return tokens.warning.opacity(0.12)
        case .error:
            return Color.red.opacity(0.10)
        case .fileChangeSummary:
            return tokens.accent.opacity(0.10)
        default:
            return tokens.systemBubble
        }
    }

    private var isApprovedApproval: Bool {
        message.content.hasPrefix(L10n.text("ui.approval_approved")) || message.content.hasPrefix(L10n.text("ui.approved"))
    }

    private var isDeclinedApproval: Bool {
        message.content.hasPrefix(L10n.text("ui.approval_rejected")) || message.content.hasPrefix(L10n.text("ui.rejected"))
    }

    private var tokens: ThemeTokens {
        themeStore.tokens(for: colorScheme)
    }
}

private struct MessageContextMenuModifier: ViewModifier {
    @EnvironmentObject private var themeStore: ThemeStore
    let message: ConversationMessage
    let retry: (() -> Void)?
    let stop: (() -> Void)?
    @State private var isSelectingText = false

    func body(content: Content) -> some View {
        // 菜单只提供动作，预览由系统直接从调用处的真实消息表面生成。
        // 各表面通过 .contentShape(.contextMenuPreview, ...) 声明自己的边界，
        // 避免维护第二套会与 Markdown、图片和流式高度脱节的“假气泡”。
        content
            .contextMenu {
                Button {
                    UIPasteboard.general.string = message.content
                } label: {
                    Label(L10n.text("ui.copy"), systemImage: "doc.on.doc")
                }

                // 全幅气泡的 contextMenu 长按会抢占文本选区的长按手势，直接给正文加
                // .textSelection 无法在气泡内起效；因此提供一个专用的可选择文本表面，
                // 让用户能挑选返回内容里的任意片段单独复制。
                if !selectableText.isEmpty {
                    Button {
                        isSelectingText = true
                    } label: {
                        Label(L10n.text("ui.select_text"), systemImage: "text.cursor")
                    }
                }

                if message.role == .user && message.sendStatus == .failed, let retry {
                    Button(action: retry) {
                        Label(L10n.text("ui.try_again"), systemImage: "arrow.clockwise")
                    }
                }

                if message.role == .assistant && message.sendStatus == .sending, let stop {
                    Button(role: .destructive, action: stop) {
                        Label(L10n.text("ui.stop"), systemImage: "stop.circle")
                    }
                }
            }
            .sheet(isPresented: $isSelectingText) {
                MessageTextSelectionSheet(text: selectableText)
                    .environmentObject(themeStore)
            }
    }

    private var selectableText: String {
        message.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 可选择文本表面：正文渲染层被 contextMenu 手势占用，这里用一个不带长按菜单的
/// 独立视图承载 `.textSelection(.enabled)`，从而支持逐句/逐段挑选复制。
struct MessageTextSelectionSheet: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    let text: String

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(themeStore.uiFont(.body))
                    .foregroundStyle(tokens.primaryText)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(tokens.background)
            .navigationTitle(L10n.text("ui.select_text"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.text("ui.close")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = text
                        dismiss()
                    } label: {
                        Label(L10n.text("ui.copy"), systemImage: "doc.on.doc")
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
}

extension View {
    func messageContextMenu(
        for message: ConversationMessage,
        retry: (() -> Void)? = nil,
        stop: (() -> Void)? = nil
    ) -> some View {
        modifier(MessageContextMenuModifier(message: message, retry: retry, stop: stop))
    }
}

struct MessageTimestampCaption: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let text: String
    var isFallback = false
    var foreground: Color?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        // 估算时间不使用 warning 色，改用 tertiaryText，并在可见文字前加“~ ”；
        // VoiceOver 仍通过完整本地化文案明确朗读“估算”，不依赖颜色或符号猜测。
        Text(isFallback ? "~ \(text)" : text)
            .font(themeStore.uiFont(.caption2, weight: .medium))
            .foregroundStyle(isFallback ? tokens.tertiaryText : (foreground ?? tokens.tertiaryText))
            .lineLimit(1)
            .minimumScaleFactor(0.88)
            .accessibilityLabel(isFallback ? L10n.format("ui.message_time_full_estimate_value", text) : L10n.format("ui.message_time_value", text))
    }
}

extension ConversationMessage {
    var timestampCaptionText: String {
        let text: String
        switch role {
        case .user:
            text = L10n.format("ui.issue_value", Self.compactTime(createdAt))
        case .assistant:
            guard sendStatus != .sending else {
                let started = Self.compactTime(createdAt)
                guard let updatedAt else {
                    return L10n.format("ui.start_value", started)
                }
                let latest = Self.compactTime(updatedAt)
                return started == latest ? L10n.format("ui.start_value", started) : L10n.format("ui.started_value_last_value", started, latest)
            }
            let completedAt = updatedAt ?? createdAt
            let started = Self.compactTime(createdAt)
            let completed = Self.compactTime(completedAt)
            // 同一分钟内开始和完成显示相同时间时，只保留完成时间，减少气泡右下角噪音。
            if started == completed {
                text = L10n.format("ui.complete_value", completed)
            } else {
                text = L10n.format("ui.start_value_complete_value", started, completed)
            }
        case .system:
            if let updatedAt, Self.compactTime(updatedAt) != Self.compactTime(createdAt) {
                text = "\(Self.compactTime(createdAt)) · \(Self.compactTime(updatedAt))"
            } else {
                text = Self.compactTime(createdAt)
            }
        }
        return text
    }

    private static func compactTime(_ date: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDateInToday(date) {
            return date.formatted(.dateTime.hour().minute())
        }
        return date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
    }
}
