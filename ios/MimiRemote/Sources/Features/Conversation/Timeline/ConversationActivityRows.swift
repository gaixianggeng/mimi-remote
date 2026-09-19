import QuickLook
import SwiftUI

/// 结果层只保留一个轻量入口；状态刷新不比较隐藏的完整工具输出。
struct ConversationProcessGroupRow: View, Equatable {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let group: ConversationProcessGroup
    let layout: ConversationLayout
    let liveStatus: ConversationLiveStatus?
    let showsDetailedTranscript: Bool
    let toggle: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.group.id == rhs.group.id
            && lhs.group.isExpanded == rhs.group.isExpanded
            && lhs.group.lifecycle == rhs.group.lifecycle
            && lhs.group.failedCount == rhs.group.failedCount
            && lhs.layout == rhs.layout
            && lhs.liveStatus == rhs.liveStatus
            && lhs.showsDetailedTranscript == rhs.showsDetailedTranscript
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: toggle) {
                if let liveStatus {
                    SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                        header(text: liveStatus.text(at: context.date, includesTokens: false),
                               warning: liveStatus.isWarning(at: context.date))
                    }
                } else {
                    header(text: group.title, warning: group.lifecycle == .failed || group.failedCount > 0)
                }
            }
            .buttonStyle(.plain)
            .disabled(showsDetailedTranscript)
            .accessibilityValue(group.isExpanded ? L10n.text("ui.expanded") : L10n.text("ui.collected"))
            .accessibilityHint(L10n.text("ui.process_disclosure_hint"))
            .accessibilityIdentifier("conversation.process.\(group.id)")
            .frame(maxWidth: layout.assistantBubbleMaxWidth, alignment: .leading)
            Spacer(minLength: layout.messageSideSpacer)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func header(text: String, warning: Bool) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)
        return HStack(spacing: 8) {
            if let liveStatus {
                ConversationLiveStatusGlyph(tint: warning ? tokens.warning : tokens.accent,
                                            animates: liveStatus.animates && !reduceMotion)
                    .frame(width: 16, height: 18)
            }
            Text(text)
                .font(themeStore.uiFont(.footnote, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
            if group.failedCount > 0 {
                Text(L10n.plural("ui.items_unsuccessful_count", count: group.failedCount))
                    .font(themeStore.uiFont(.caption))
                    .lineLimit(1)
            }
            if !showsDetailedTranscript {
                Image(systemName: "chevron.right")
                    .font(themeStore.uiFont(.caption2, weight: .semibold))
                    .rotationEffect(.degrees(group.isExpanded ? 90 : 0))
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(warning ? tokens.warning : tokens.secondaryText)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct ConversationActivityRow: View, Equatable {
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var activityTitleSize: CGFloat = 14
    @ScaledMetric(relativeTo: .footnote) private var activityDetailSize: CGFloat = 12
    @ScaledMetric(relativeTo: .caption) private var activityMarkerSize: CGFloat = 11
    @State private var historyOutputPreviewURL: URL?
    @State private var isOpeningHistoryOutput = false
    @State private var historyOutputError: String?
    let message: ConversationMessage
    let layout: ConversationLayout
    let provider: ConversationTimelineProvider
    let showsDetailedTranscript: Bool
    let isExpanded: Bool
    let toggle: () -> Void

    static func == (lhs: ConversationActivityRow, rhs: ConversationActivityRow) -> Bool {
        lhs.message.id == rhs.message.id
            && lhs.message.renderFingerprint == rhs.message.renderFingerprint
            && lhs.message.activityPayload == rhs.message.activityPayload
            && lhs.layout == rhs.layout
            && lhs.provider == rhs.provider
            && lhs.showsDetailedTranscript == rhs.showsDetailedTranscript
            && lhs.isExpanded == rhs.isExpanded
    }

    var body: some View {
        HStack(spacing: 0) {
            rowSurface
                .contentShape(.interaction, Rectangle())
                .contentShape(.contextMenuPreview, Rectangle())
                .messageContextMenu(for: message)
                .frame(maxWidth: layout.assistantBubbleMaxWidth, alignment: .leading)

            Spacer(minLength: layout.messageSideSpacer)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .quickLookPreview($historyOutputPreviewURL)
    }

    @ViewBuilder
    private var rowSurface: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasExpandableDetails, !showsDetailedTranscript {
                Button(action: toggle) {
                    rowContent
                }
                .buttonStyle(.plain)
                .accessibilityLabel(activityAccessibilityDescription)
                .accessibilityValue(isExpanded ? L10n.text("ui.expanded") : L10n.text("ui.collected"))
                .accessibilityHint(isExpanded ? L10n.text("ui.collapse_current_process_details") : L10n.text("ui.expand_current_process_details"))
            } else {
                rowContent
            }

            if isExpanded, hasExpandableDetails {
                expandedDetails
                    .padding(.leading, 22)
                    .padding(.top, 3)
            }
        }
    }

    private var rowContent: some View {
        HStack(alignment: isReasoning ? .top : .firstTextBaseline, spacing: 8) {
            activityMarker

            if isReasoning, provider == .codex {
                Text(reasoningText)
                    .font(themeStore.uiFont(size: activityTitleSize))
                    .italic()
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(isExpanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(activityTitle)
                        .font(themeStore.uiFont(size: activityTitleSize, weight: .medium))
                        .foregroundStyle(activityTint)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                        .truncationMode(.middle)
                    if let detail = activityDetail {
                        Text(detail)
                            .font(themeStore.uiFont(size: activityDetailSize))
                            .foregroundStyle(tokens.secondaryText.opacity(0.84))
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if hasExpandableDetails, !showsDetailedTranscript {
                Image(systemName: "chevron.right")
                    .font(themeStore.uiFont(.caption2, weight: .semibold))
                    .foregroundStyle(tokens.secondaryText.opacity(0.75))
                    .frame(width: 12, height: 16)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
        }
        // 只有可展开行是操作控件；视觉仍保持紧凑，但触控区至少 44pt。
        .frame(minHeight: hasExpandableDetails ? 44 : 28)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(activityAccessibilityDescription)
    }

    @ViewBuilder
    private var expandedDetails: some View {
        if let payload = message.activityPayload {
            VStack(alignment: .leading, spacing: 4) {
                if let command = payload.command?.conversationActivityTrimmedNonEmpty {
                    activityDetailLine(L10n.text("ui.command"), value: command, monospaced: true)
                }
                if let cwd = payload.cwd?.conversationActivityTrimmedNonEmpty {
                    activityDetailLine(L10n.text("ui.directory"), value: cwd, monospaced: true)
                }
                if !payload.filePaths.isEmpty {
                    activityDetailLine(L10n.text("ui.file"), value: payload.filePaths.joined(separator: "\n"), monospaced: true)
                }
                let status = [
                    payload.displayStatusText,
                    payload.exitCode.map { L10n.format("ui.exit_code_value", $0) }
                ]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                if !status.isEmpty {
                    activityDetailLine(L10n.text("ui.status"), value: status)
                }
                if let detailText = fullDetailText, !isReasoning || provider == .claude {
                    Text(detailText)
                        .font(themeStore.uiFont(.caption2).monospaced())
                        .foregroundStyle(tokens.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if let historyOutputID = payload.historyOutputID {
                    Button {
                        Task { await openHistoryOutput(id: historyOutputID) }
                    } label: {
                        HStack(spacing: 6) {
                            Label(historyOutputButtonTitle(payload), systemImage: "doc.text.magnifyingglass")
                            if isOpeningHistoryOutput {
                                ProgressView()
                                    .controlSize(.mini)
                            }
                        }
                        // iPad 上可见表面保持紧凑，但原生 Button 触控区仍至少 44pt。
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isOpeningHistoryOutput)
                    .accessibilityHint(L10n.text("ui.open_full_output"))
                }
                if let historyOutputError {
                    Text(historyOutputError)
                        .font(themeStore.uiFont(.caption2))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func historyOutputButtonTitle(_ payload: ConversationActivityPayload) -> String {
        guard let bytes = payload.outputByteCount, bytes > 0 else {
            return L10n.text("ui.open_full_output")
        }
        return [
            L10n.text("ui.open_full_output"),
            ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file),
        ].joined(separator: " · ")
    }

    @MainActor
    private func openHistoryOutput(id: String) async {
        guard !isOpeningHistoryOutput else {
            return
        }
        isOpeningHistoryOutput = true
        historyOutputError = nil
        defer { isOpeningHistoryOutput = false }
        do {
            historyOutputPreviewURL = try await sessionStore.previewHistoryOutput(id: id)
        } catch is CancellationError {
            return
        } catch {
            historyOutputError = userFacingHistoryOutputError(error)
        }
    }

    private func userFacingHistoryOutputError(_ error: Error) -> String {
        if case AgentAPIError.server(let status, _) = error, status == 404 {
            return L10n.text("ui.the_historical_output_cache_has_expired_please_refresh")
        }
        return error.localizedDescription
    }

    private func activityDetailLine(_ label: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(themeStore.uiFont(.caption2, weight: .semibold))
                .foregroundStyle(tokens.secondaryText.opacity(0.76))
                .frame(width: 30, alignment: .leading)
            Text(value)
                .font(monospaced ? themeStore.uiFont(.caption2).monospaced() : themeStore.uiFont(.caption2))
                .foregroundStyle(tokens.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var activityMarker: some View {
        if isRunning {
            ProgressView()
                .controlSize(.mini)
                .tint(activityTint)
                .frame(width: 14, height: 16)
        } else {
            Image(systemName: markerSymbol)
                .font(themeStore.uiFont(
                    size: markerSymbol == "circle.fill" ? activityMarkerSize * 0.45 : activityMarkerSize,
                    weight: .semibold
                ))
                .foregroundStyle(activityTint)
                .frame(width: 14, height: 16)
        }
    }

    private var isReasoning: Bool {
        message.kind == .reasoningSummary
    }

    private var reasoningText: String {
        ConversationActivityPresentationText.reasoningText(
            for: message,
            isExpanded: isExpanded
        )
    }

    private var activityTitle: String {
        if let payload = message.activityPayload {
            return payload.displayTitle
        }
        switch message.kind {
        case .commentary:
            return message.content
        case .commandSummary:
            return message.content.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? L10n.text("ui.run_command")
        case .fileChangeSummary:
            return message.content.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? L10n.text("ui.file_changes")
        case .approval:
            if isApprovedInteraction {
                return L10n.text("ui.approval_approved")
            }
            if isDeclinedInteraction {
                return L10n.text("ui.approval_rejected")
            }
            return L10n.text("ui.approval_status")
        case .userInput:
            return isSkippedInteraction ? L10n.text("ui.additional_information_skipped") : L10n.text("ui.additional_information_has_been_submitted")
        default:
            return message.content
        }
    }

    private var activityDetail: String? {
        guard let payload = message.activityPayload else {
            return interactionDetail
        }
        switch payload.category {
        case .editFile:
            return payload.filePaths.isEmpty ? payload.displayStatusText : payload.filePaths.prefix(4).joined(separator: ", ")
        case .runCommand:
            let exit = payload.exitCode.flatMap { code in
                code == 0 ? nil : L10n.format("ui.exit_code_value", code)
            }
            return compactActivityDetail(
                provider == .claude ? payload.displayStatusText : exit,
                payload.cwd,
                compactOutputPreview
            )
        case .toolCall:
            let status = provider == .claude
                ? payload.displayStatusText
                : (payload.displayStatusText == L10n.text("ui.completed_status") ? nil : payload.displayStatusText)
            return compactActivityDetail(
                payload.subtitle?.conversationActivityTrimmedNonEmpty,
                status,
                compactOutputPreview
            )
        case .thinking:
            return provider == .claude ? nil : payload.subtitle.map(ConversationActivityPayload.plainProgressText)
        case .plan, .error:
            return payload.subtitle.map(ConversationActivityPayload.plainProgressText)
        }
    }

    private func compactActivityDetail(_ values: String?...) -> String? {
        values
            .compactMap { $0?.conversationActivityTrimmedNonEmpty }
            .joined(separator: " · ")
            .conversationActivityTrimmedNonEmpty
    }

    private var compactOutputPreview: String? {
        ConversationActivityPresentationText.compactPreview(for: message)
    }

    private var fullDetailText: String? {
        ConversationActivityPresentationText.fullDetail(for: message)
    }

    private var interactionDetail: String? {
        guard message.kind == .approval || message.kind == .userInput else {
            return nil
        }
        let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let separator = content.firstIndex(where: { $0 == "：" || $0 == ":" }) {
            return String(content[content.index(after: separator)...]).conversationActivityTrimmedNonEmpty
        }
        return nil
    }

    private var hasExpandableDetails: Bool {
        if isReasoning {
            if provider == .claude {
                return fullDetailText != nil
            }
            let summary = ConversationActivityPresentationText.reasoningText(for: message, isExpanded: false)
            let full = ConversationActivityPresentationText.reasoningText(for: message, isExpanded: true)
            return full != summary || summary.count > 160 || summary.filter { $0 == "\n" }.count >= 3
        }
        guard let payload = message.activityPayload else {
            return false
        }
        return payload.command?.conversationActivityTrimmedNonEmpty != nil ||
            payload.cwd?.conversationActivityTrimmedNonEmpty != nil ||
            !payload.filePaths.isEmpty ||
            fullDetailText != nil ||
            payload.historyOutputID != nil
    }

    private var isRunning: Bool {
        message.activityPayload?.isInProgress == true
    }

    private var isFailure: Bool {
        message.activityPayload?.isFailure == true
    }

    private var isInterrupted: Bool {
        message.activityPayload?.isInterrupted == true
    }

    private var activityAccessibilityDescription: String {
        if isReasoning, provider == .codex, isExpanded {
            return reasoningText
        }
        return message.activityPayload?.accessibilityDescription ?? [
            activityTitle,
            activityDetail,
        ]
            .compactMap { $0?.conversationActivityTrimmedNonEmpty }
            .joined(separator: L10n.text("ui.list_separator"))
    }

    private var markerSymbol: String {
        if isFailure {
            return "exclamationmark.circle.fill"
        }
        if isInterrupted {
            return "stop.circle.fill"
        }
        if isApprovedInteraction || (message.kind == .userInput && !isSkippedInteraction) {
            return "checkmark.circle.fill"
        }
        if isDeclinedInteraction || isSkippedInteraction {
            return "xmark.circle"
        }
        if message.activityPayload?.category == .editFile {
            return "pencil"
        }
        if let toolKind = message.activityPayload?.toolPresentationKind {
            return toolKind.systemImageName
        }
        return "circle.fill"
    }

    private var activityTint: Color {
        if isFailure {
            return .red
        }
        if isRunning {
            // 运行中的转圈统一使用主题紫；完成态继续保持中性，避免整页到处发亮。
            return tokens.accent
        }
        if isApprovedInteraction || (message.kind == .userInput && !isSkippedInteraction) {
            return tokens.success
        }
        if message.activityPayload?.category == .editFile {
            return tokens.accent
        }
        return tokens.secondaryText
    }

    private var isApprovedInteraction: Bool {
        message.kind == .approval &&
            (message.content.hasPrefix(L10n.text("ui.approval_approved")) || message.content.hasPrefix(L10n.text("ui.approved")))
    }

    private var isDeclinedInteraction: Bool {
        message.kind == .approval &&
            (message.content.hasPrefix(L10n.text("ui.approval_rejected")) || message.content.hasPrefix(L10n.text("ui.rejected")))
    }

    private var isSkippedInteraction: Bool {
        message.kind == .userInput &&
            (message.content.hasPrefix(L10n.text("ui.additional_information_skipped")) || message.content.hasPrefix(L10n.text("ui.boot_input_skipped")))
    }

    private var tokens: ThemeTokens {
        themeStore.tokens(for: colorScheme)
    }
}

enum ProcessedActivitySymbol {
    static func symbolName(for payload: ConversationActivityPayload) -> String {
        if let toolKind = payload.toolPresentationKind {
            return toolKind.systemImageName
        }
        return symbolName(for: payload.category)
    }

    static func symbolName(for category: ConversationActivityCategory) -> String {
        switch category {
        case .thinking:
            return "brain.head.profile"
        case .plan:
            return "list.clipboard"
        case .runCommand:
            return "terminal"
        case .editFile:
            return "doc.text"
        case .toolCall:
            return "wrench.and.screwdriver"
        case .error:
            return "exclamationmark.triangle"
        }
    }
}

enum ConversationActivityPresentationText {
    static func reasoningText(for message: ConversationMessage, isExpanded: Bool) -> String {
        let payload = message.activityPayload
        let source: String
        if isExpanded {
            source = fullDetail(for: message)
                ?? payload?.subtitle?.conversationActivityTrimmedNonEmpty
                ?? message.content
        } else {
            source = payload?.subtitle?.conversationActivityTrimmedNonEmpty
                ?? message.content
        }
        return ConversationActivityPayload.plainProgressText(source)
    }

    static func compactPreview(for message: ConversationMessage, limit: Int = 140) -> String? {
        guard let preview = message.activityPayload?.outputPreview?.conversationActivityTrimmedNonEmpty,
              let firstLine = preview.split(separator: "\n", omittingEmptySubsequences: true).first else {
            return nil
        }
        let value = String(firstLine)
        guard value.count > limit else { return value }
        return String(value.prefix(max(0, limit - 1))) + "…"
    }

    static func fullDetail(for message: ConversationMessage) -> String? {
        guard let payload = message.activityPayload else {
            return nil
        }
        let content = message.content.conversationActivityTrimmedNonEmpty
        if payload.category == .thinking {
            return content ?? payload.subtitle?.conversationActivityTrimmedNonEmpty
        }
        if let content,
           content != payload.summaryText.trimmingCharacters(in: .whitespacesAndNewlines) {
            return content
        }
        // 旧 history 只把 summaryText 写进 content；此时仍保留已有短预览。
        return payload.outputPreview?.conversationActivityTrimmedNonEmpty
    }
}

private extension String {
    var conversationActivityTrimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
