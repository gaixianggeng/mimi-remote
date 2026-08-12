import QuickLook
import SwiftUI

struct ConversationMessageContent: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let message: ConversationMessage
    let layout: ConversationLayout
    let skills: [SkillCapability]
    let retry: (ConversationMessage) -> Void
    let stop: () -> Void
    let previewFile: (String) async throws -> URL
    @State private var previewURL: URL?
    @State private var previewingPath: String?
    @State private var previewError: String?

    var body: some View {
        Group {
            if shouldRenderUserImages {
                userImageBubbleSurface
            } else if isAssistantDocument {
                assistantDocumentSurface
            } else if isPlainUserMessage {
                plainUserBubbleSurface
            } else {
                bubbleSurface
            }
        }
            .frame(maxWidth: maxContentWidth, alignment: contentAlignment)
            .opacity(message.sendStatus == .sending ? 0.72 : 1)
            .quickLookPreview($previewURL)
    }

    private var userImageBubbleSurface: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let style = MarkdownStyle.make(
            role: message.role,
            colorScheme: colorScheme,
            fontScale: themeStore.fontScale,
            tokens: tokens
        )
        return userImageContent(style: style)
            .contentShape(.interaction, RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 12, style: .continuous))
            .messageContextMenu(
                for: message,
                retry: {
                    retry(message)
                },
                stop: stop
            )
    }

    private var bubbleSurface: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return bubbleChrome
            // 长按菜单必须锚定在实际气泡上，不能挂到外层全宽行，否则 iPad 上菜单预览会撑满整行。
            .contentShape(.interaction, shape)
            .contentShape(.contextMenuPreview, shape)
            .messageContextMenu(
                for: message,
                retry: {
                    retry(message)
                },
                stop: stop
            )
    }

    private var plainUserBubbleSurface: some View {
        VStack(alignment: .trailing, spacing: 3) {
            let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
            renderContent
                // 纯文本用户消息只把正文放进气泡；时间单独落在下方，避免正文右下角
                // 被时间占位挤出不必要的空白。context menu 仍锚定真实气泡边界。
                .foregroundStyle(foreground)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(background, in: shape)
                .overlay {
                    shape.strokeBorder(bubbleBorder, lineWidth: 1)
                }
                .shadow(color: bubbleShadowColor, radius: 2, y: 1)
                .contentShape(.interaction, shape)
                .contentShape(.contextMenuPreview, shape)
                .messageContextMenu(
                    for: message,
                    retry: {
                        retry(message)
                    },
                    stop: stop
                )

            MessageTimestampCaption(
                text: message.timestampCaptionText,
                isFallback: message.isTimestampFallback,
                foreground: timestampForeground
            )
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var assistantDocumentSurface: some View {
        let shape = Rectangle()
        let tokens = themeStore.tokens(for: colorScheme)

        return VStack(alignment: .leading, spacing: 6) {
            // 助手回复是持续生长的 Markdown 文档，不再额外包一层气泡。
            // 内容仍走原有 MessageRenderPlanCache，流式增量解析和稳定块复用保持不变。
            renderContent

            HStack(spacing: 0) {
                Spacer(minLength: 0)
                MessageTimestampCaption(
                    text: message.timestampCaptionText,
                    isFallback: message.isTimestampFallback
                )
            }
        }
        .foregroundStyle(tokens.conversationPrimaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.interaction, shape)
        .contentShape(.contextMenuPreview, shape)
        .messageContextMenu(
            for: message,
            stop: stop
        )
        // 真机 smoke 需要区分助手正文和用户 prompt；identifier 不携带正文或 UUID，
        // 只增加稳定的测试定位信息，不改变 VoiceOver 的 label/value。
        .accessibilityIdentifier("conversation.message.assistant")
    }

    private var bubbleChrome: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return contentWithTimestamp
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(background, in: shape)
            .overlay {
                shape.strokeBorder(bubbleBorder, lineWidth: 1)
            }
            .shadow(color: bubbleShadowColor, radius: message.role == .user ? 2 : 6, y: message.role == .user ? 1 : 2)
    }

    private var contentWithTimestamp: some View {
        ZStack(alignment: .bottomTrailing) {
            renderContent
                .padding(.bottom, 16)
            MessageTimestampCaption(text: message.timestampCaptionText, isFallback: message.isTimestampFallback, foreground: timestampForeground)
        }
    }

    @ViewBuilder
    private var renderContent: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let style = MarkdownStyle.make(
            role: message.role,
            colorScheme: colorScheme,
            fontScale: themeStore.fontScale,
            tokens: tokens
        )
        if shouldRenderUserImages {
            userImageContent(style: style)
        } else if shouldRenderStructuredUserPayload {
            structuredUserContent(style: style)
        } else if shouldRenderMarkdownMessage {
            let presentationContent = message.role == .assistant
                ? ConversationMarkdownPresentation.displayContent(from: message.content)
                : message.content
            let plan = MessageRenderPlanCache.shared.plan(for: message, rendering: presentationContent)
            let references = fileReferences
            if references.isEmpty {
                markdownContent(plan: plan, style: style)
            } else {
                VStack(alignment: .leading, spacing: style.blockSpacing) {
                    markdownContent(plan: plan, style: style)
                    FileReferencePreviewStrip(
                        references: references,
                        previewingPath: previewingPath,
                        previewError: previewError,
                        onPreview: { reference in
                            Task { await preview(reference) }
                        }
                    )
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(message.content)
                .font(themeStore.uiFont(.body))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func userImageContent(style: MarkdownStyle) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)
        return VStack(alignment: .trailing, spacing: 8) {
            let text = userImageText
            if !text.isEmpty {
                userTextContent(text, style: style)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(tokens.userBubble, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }

            userImageGallery(style: style)

            userPayloadAccessories(style: style)

            MessageTimestampCaption(
                text: message.timestampCaptionText,
                isFallback: message.isTimestampFallback,
                foreground: tokens.secondaryText
            )
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func userImageGallery(style: MarkdownStyle) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)
        // 图片网格位于用户气泡之外；加载/失败状态必须使用页面中性表面，
        // 避免气泡语义色渗入独立媒体状态卡。
        let statusStyle = MarkdownStyle.make(
            role: .assistant,
            colorScheme: colorScheme,
            fontScale: themeStore.fontScale,
            tokens: tokens
        )
        if userImageSources.count > 1 {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ],
                alignment: .trailing,
                spacing: 8
            ) {
                ForEach(userImageSources) { source in
                    ConversationImagePreview(
                        source: source,
                        title: nil,
                        style: style,
                        statusStyle: statusStyle,
                        maxHeight: 208,
                        showsCaption: false,
                        fillsAvailableWidth: true
                    )
                    .frame(height: 220, alignment: .center)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            ForEach(userImageSources) { source in
                // 单图按图片实际渲染尺寸收缩媒体卡，并继续保持用户消息的右侧语义。
                ConversationImagePreview(
                    source: source,
                    title: nil,
                    style: style,
                    statusStyle: statusStyle,
                    maxHeight: 320,
                    showsCaption: false,
                    contentAlignment: .trailing,
                    contentSizedMaxWidth: layout.userBubbleMaxWidth
                )
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func markdownContent(plan: MessageRenderPlan, style: MarkdownStyle) -> some View {
        if plan.isSinglePlainParagraph, case let .paragraph(inline) = plan.blocks.first?.kind {
            Text(inline.plain)
                .font(style.bodyFont)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: style.blockSpacing) {
                ForEach(plan.blocks) { block in
                    MarkdownBlockView(block: block, style: style)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var isAssistantDocument: Bool {
        message.role == .assistant && message.kind == .message
    }

    private var isPlainUserMessage: Bool {
        message.role == .user
            && message.kind == .message
            && !shouldRenderUserImages
            && !shouldRenderStructuredUserPayload
    }

    private var shouldRenderMarkdownMessage: Bool {
        guard message.kind == .message else {
            return false
        }
        return message.role == .assistant
            || (message.role == .user && ConversationMarkdownPresentation.containsLink(in: message.content))
    }

    private var shouldRenderUserImages: Bool {
        message.role == .user
            && message.kind == .message
            && (!payloadImageItems.isEmpty || !contentImageReferences.isEmpty)
    }

    private var shouldRenderStructuredUserPayload: Bool {
        message.role == .user
            && message.kind == .message
            && (!payloadSkillItems.isEmpty || !payloadMentionItems.isEmpty || !payloadFileItems.isEmpty)
    }

    private func structuredUserContent(style: MarkdownStyle) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            let text = structuredPayloadText
            if !text.isEmpty {
                userTextContent(text, style: style)
            }
            userPayloadAccessories(style: style)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func userTextContent(_ text: String, style: MarkdownStyle) -> some View {
        if ConversationMarkdownPresentation.containsLink(in: text) {
            let plan = MessageRenderPlanCache.shared.plan(for: message, rendering: text)
            markdownContent(plan: plan, style: style)
        } else {
            Text(text)
                .font(style.bodyFont)
                .foregroundStyle(userBubbleForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var structuredPayloadText: String {
        if !payloadText.isEmpty {
            return payloadText
        }
        var text = message.content
        for item in payloadSkillItems + payloadMentionItems + payloadFileItems {
            text = text.replacingOccurrences(of: item.previewText, with: "")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private func userPayloadAccessories(style: MarkdownStyle) -> some View {
        ForEach(payloadSkillItems) { item in
            if case .skill(let name, let path) = item {
                let capability = skills.first { $0.path == path || $0.name == name }
                SkillInvocationCard(
                    metadata: SkillVisualMetadata(name: name, path: path, capability: capability),
                    sendStatus: message.sendStatus,
                    // 浅色用户气泡是中性浅底，必须使用主题深色文字；
                    // 只有深色主题继续使用原有的高对比白字样式。
                    usesUserBubbleContrast: themeStore.tokens(for: colorScheme).resolvedScheme == .dark
                )
                .environmentObject(themeStore)
            }
        }

        ForEach(payloadFileItems) { item in
            if case .uploadedFile(let file) = item {
                HStack(spacing: 10) {
                    Image(systemName: "doc")
                        .font(themeStore.uiFont(.headline, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(
                            themeStore.tokens(for: colorScheme).selectionFill,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name)
                            .font(style.bodyFont.weight(.semibold))
                            .lineLimit(2)
                        Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                            .font(style.captionFont)
                            .foregroundStyle(style.secondaryColor)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .background(
                    themeStore.tokens(for: colorScheme).elevatedSurface,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            }
        }

        let accessoryText = payloadAccessoryText
        if !accessoryText.isEmpty {
            Text(accessoryText)
                .font(style.captionFont)
                .foregroundStyle(style.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var payloadImageItems: [CodexAppServerUserInput] {
        guard let payload = message.turnPayload else {
            return []
        }
        return payload.input.filter { ConversationImageSource.input($0) != nil }
    }

    private var contentImageReferences: [ConversationFileReference] {
        guard message.turnPayload == nil || payloadImageItems.isEmpty else {
            return []
        }
        return ConversationFileReferenceDetector.imageReferences(in: message.content)
    }

    private var userImageSources: [ConversationImageSource] {
        let payloadSources = payloadImageItems.compactMap(ConversationImageSource.input)
        if !payloadSources.isEmpty {
            return payloadSources
        }
        return contentImageReferences.map { .localPath($0.path) }
    }

    private var userImageText: String {
        if !payloadImageItems.isEmpty {
            return payloadText
        }
        return contentTextWithoutImagePaths
    }

    private var payloadText: String {
        guard let payload = message.turnPayload else {
            return ""
        }
        return payload.input.compactMap { item in
            if case .text(let text, _) = item {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    private var contentTextWithoutImagePaths: String {
        var text = message.content
        for reference in contentImageReferences {
            let fileURL = URL(fileURLWithPath: reference.path).absoluteString
            let variants = [
                reference.path,
                reference.path.replacingOccurrences(of: " ", with: "\\ "),
                fileURL,
                fileURL.removingPercentEncoding ?? fileURL,
                L10n.format("ui.image_value", reference.name),
                L10n.text("ui.image_attachment")
            ]
            for variant in variants where !variant.isEmpty {
                text = text.replacingOccurrences(of: variant, with: "")
            }
        }
        text = strippedUserFileMentionPrompt(from: text)
        return text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "：:，,。.；;"))
    }

    private func strippedUserFileMentionPrompt(from text: String) -> String {
        for marker in ["## My request for Codex:", "## My request for Codex："] {
            if let range = text.range(of: marker, options: [.caseInsensitive]) {
                return String(text[range.upperBound...])
            }
        }
        return text
    }

    private var payloadAccessoryText: String {
        guard let payload = message.turnPayload else {
            return ""
        }
        return payload.input.compactMap { item in
            switch item {
            case .mention:
                return item.previewText
            case .text, .image, .localImage, .uploadedFile, .skill:
                return nil
            }
        }
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var payloadSkillItems: [CodexAppServerUserInput] {
        message.turnPayload?.input.filter { item in
            if case .skill = item { return true }
            return false
        } ?? []
    }

    private var payloadMentionItems: [CodexAppServerUserInput] {
        message.turnPayload?.input.filter { item in
            if case .mention = item { return true }
            return false
        } ?? []
    }

    private var payloadFileItems: [CodexAppServerUserInput] {
        message.turnPayload?.input.filter { item in
            if case .uploadedFile = item { return true }
            return false
        } ?? []
    }

    private var fileReferences: [ConversationFileReference] {
        guard isAssistantDocument, message.sendStatus != .sending else {
            return []
        }
        return ConversationFileReferenceDetector.references(in: message.content)
    }

    private func preview(_ reference: ConversationFileReference) async {
        previewingPath = reference.path
        previewError = nil
        defer {
            if previewingPath == reference.path {
                previewingPath = nil
            }
        }
        do {
            previewURL = try await previewFile(reference.path)
        } catch {
            previewError = userFacingPreviewError(error)
        }
    }

    private func userFacingPreviewError(_ error: Error) -> String {
        if case AgentAPIError.server(let status, _) = error, status == 404 || status == 405 {
            return L10n.text("ui.the_current_agentd_version_does_not_support_file")
        }
        if case AgentAPIError.server(let status, _) = error, status == 403 {
            return L10n.text("ui.the_file_is_not_within_authorization_or_is")
        }
        if case AgentAPIError.server(let status, _) = error, status == 413 {
            return L10n.text("ui.the_file_is_too_large_and_preview_is")
        }
        return error.localizedDescription
    }

    private var contentAlignment: Alignment {
        message.role == .user ? .trailing : .leading
    }

    private var maxContentWidth: CGFloat {
        message.role == .user ? layout.userBubbleMaxWidth : layout.assistantBubbleMaxWidth
    }

    private var background: Color {
        let tokens = themeStore.tokens(for: colorScheme)
        switch message.role {
        case .user:
            return tokens.userBubble
        default:
            return tokens.assistantBubble
        }
    }

    private var bubbleBorder: Color {
        let tokens = themeStore.tokens(for: colorScheme)
        return tokens.border.opacity(message.role == .assistant ? 0.58 : 0.54)
    }

    private var bubbleShadowColor: Color {
        let tokens = themeStore.tokens(for: colorScheme)
        let opacity: Double
        if message.role == .user {
            opacity = tokens.resolvedScheme == .light ? 0.05 : 0.12
        } else {
            opacity = tokens.resolvedScheme == .light ? 0.045 : 0.16
        }
        return Color.black.opacity(opacity)
    }

    private var foreground: Color {
        let tokens = themeStore.tokens(for: colorScheme)
        return message.role == .user ? userBubbleForeground : tokens.conversationPrimaryText
    }

    private var timestampForeground: Color? {
        guard message.role == .user else {
            return nil
        }
        return userBubbleForeground.opacity(0.64)
    }

    private var userBubbleForeground: Color {
        themeStore.tokens(for: colorScheme).userBubbleForeground
    }
}
