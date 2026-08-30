import QuickLook
import SwiftUI

struct ConversationActivityBatchRow: View, Equatable {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.colorScheme) private var colorScheme
    let group: ConversationActivityBatch
    let layout: ConversationLayout
    let isExpanded: Bool
    let expandedActivityIDs: Set<String>
    let toggleGroup: () -> Void
    let toggleActivity: (ConversationMessage) -> Void
    let recordAnchorGeometry: ([UUID], CGRect) -> Void

    init(
        group: ConversationActivityBatch,
        layout: ConversationLayout,
        isExpanded: Bool,
        expandedActivityIDs: Set<String>,
        toggleGroup: @escaping () -> Void,
        toggleActivity: @escaping (ConversationMessage) -> Void,
        recordAnchorGeometry: @escaping ([UUID], CGRect) -> Void = { _, _ in }
    ) {
        self.group = group
        self.layout = layout
        self.isExpanded = isExpanded
        self.expandedActivityIDs = expandedActivityIDs
        self.toggleGroup = toggleGroup
        self.toggleActivity = toggleActivity
        self.recordAnchorGeometry = recordAnchorGeometry
    }

    static func == (lhs: ConversationActivityBatchRow, rhs: ConversationActivityBatchRow) -> Bool {
        guard lhs.group.id == rhs.group.id,
              lhs.group.kind == rhs.group.kind,
              lhs.group.status == rhs.group.status,
              lhs.group.messages.count == rhs.group.messages.count,
              lhs.group.latestDetail == rhs.group.latestDetail,
              lhs.group.failedCount == rhs.group.failedCount,
              lhs.layout == rhs.layout,
              lhs.isExpanded == rhs.isExpanded,
              lhs.expandedActivityIDs == rhs.expandedActivityIDs
        else {
            return false
        }
        // 折叠时忽略 stdout/stderr 摘要变化，避免终端增量驱动整行重绘；
        // 用户主动展开后再比较完整消息，让诊断详情保持实时。
        return !lhs.isExpanded || lhs.group.messages == rhs.group.messages
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Button(action: toggleGroup) {
                    header
                }
                .buttonStyle(.plain)
                .accessibilityLabel(summaryText)
                .accessibilityValue(accessibilityValue)
                .accessibilityHint(isExpanded ? L10n.text("ui.collapse_this_stage_of_activities") : L10n.text("ui.expand_this_stage_of_activities"))

                if isExpanded {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(group.messages) { message in
                            ConversationActivityRow(
                                message: message,
                                layout: layout,
                                isExpanded: expandedActivityIDs.contains(
                                    ConversationTimelineItem.activityID(for: message)
                                ),
                                toggle: { toggleActivity(message) }
                            )
                            .equatable()
                            .padding(.leading, 20)
                            .modifier(ConversationHistoryAnchorGeometryModifier(
                                isEnabled: true,
                                messageIDs: [message.id],
                                action: recordAnchorGeometry
                            ))
                        }
                    }
                    .transition(activityTransition)
                }
            }
            .frame(maxWidth: layout.assistantBubbleMaxWidth, alignment: .leading)

            Spacer(minLength: layout.messageSideSpacer)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .modifier(ConversationHistoryAnchorGeometryModifier(
            isEnabled: !isExpanded,
            messageIDs: group.messages.map(\.id),
            action: recordAnchorGeometry
        ))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            statusMarker

            Text(summaryText)
                .font(themeStore.uiFont(size: 14, weight: .medium))
                .foregroundStyle(headerTint)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(themeStore.uiFont(.caption2, weight: .semibold))
                .foregroundStyle(tokens.secondaryText.opacity(0.76))
                .frame(width: 18, height: 18)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var statusMarker: some View {
        switch group.status {
        case .running:
            ProgressView()
                .controlSize(.mini)
                .tint(tokens.accent)
                .frame(width: 14, height: 18)
        case .completed:
            Image(systemName: "circle.fill")
                .font(themeStore.uiFont(size: 5, weight: .semibold))
                .foregroundStyle(tokens.secondaryText)
                .frame(width: 14, height: 18)
        case .interrupted:
            Image(systemName: "stop.circle.fill")
                .font(themeStore.uiFont(size: 11, weight: .semibold))
                .foregroundStyle(tokens.secondaryText)
                .frame(width: 14, height: 18)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(themeStore.uiFont(size: 11, weight: .semibold))
                .foregroundStyle(Color.red)
                .frame(width: 14, height: 18)
        }
    }

    private var summaryText: String {
        [group.title, group.latestDetail, group.failureDetail]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private var accessibilityValue: String {
        let state = isExpanded ? L10n.text("ui.expanded") : L10n.text("ui.collected")
        return L10n.format(
            "ui.value_contains_value",
            state,
            L10n.plural("ui.activities_count", count: group.messages.count)
        )
    }

    private var activityTransition: AnyTransition {
        accessibilityReduceMotion
            ? .opacity
            : .opacity.combined(with: .move(edge: .top))
    }

    private var headerTint: Color {
        group.status == .failed ? .red : tokens.secondaryText
    }

    private var tokens: ThemeTokens {
        themeStore.tokens(for: colorScheme)
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
    let isExpanded: Bool
    let toggle: () -> Void

    static func == (lhs: ConversationActivityRow, rhs: ConversationActivityRow) -> Bool {
        lhs.message.id == rhs.message.id
            && lhs.message.renderFingerprint == rhs.message.renderFingerprint
            && lhs.message.activityPayload == rhs.message.activityPayload
            && lhs.layout == rhs.layout
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
            if hasExpandableDetails {
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

            if isReasoning {
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

            if hasExpandableDetails {
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
                if let output = payload.outputPreview?.conversationActivityTrimmedNonEmpty {
                    Text(output)
                        .font(themeStore.uiFont(.caption2).monospaced())
                        .foregroundStyle(tokens.secondaryText)
                        .lineLimit(8)
                        .fixedSize(horizontal: false, vertical: true)
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
        ConversationActivityPayload.plainProgressText(
            message.activityPayload?.subtitle?.conversationActivityTrimmedNonEmpty ?? message.content
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
            if let exitCode = payload.exitCode, exitCode != 0 {
                return L10n.format("ui.exit_code_value", exitCode)
            }
            return payload.cwd
        case .toolCall:
            return [
                payload.subtitle?.conversationActivityTrimmedNonEmpty,
                payload.displayStatusText == L10n.text("ui.completed_status") ? nil : payload.displayStatusText,
            ]
                .compactMap { $0 }
                .joined(separator: " · ")
                .conversationActivityTrimmedNonEmpty
        case .thinking, .plan, .error:
            return payload.subtitle.map(ConversationActivityPayload.plainProgressText)
        }
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
            return reasoningText.count > 160 || reasoningText.filter { $0 == "\n" }.count >= 3
        }
        guard let payload = message.activityPayload else {
            return false
        }
        return payload.command?.conversationActivityTrimmedNonEmpty != nil ||
            payload.cwd?.conversationActivityTrimmedNonEmpty != nil ||
            !payload.filePaths.isEmpty ||
            payload.outputPreview?.conversationActivityTrimmedNonEmpty != nil
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
        message.activityPayload?.accessibilityDescription ?? [
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

private extension String {
    var conversationActivityTrimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
