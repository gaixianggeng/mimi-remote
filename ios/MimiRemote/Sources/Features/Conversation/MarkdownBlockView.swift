import SwiftUI
import UIKit

struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let style: MarkdownStyle

    var body: some View {
        blockView(block)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block.kind {
        case let .paragraph(inline):
            inlineText(inline)
        case let .heading(level, inline):
            inlineText(inline, font: style.headingFont(level: level))
                .padding(.top, level <= 2 ? 4 : 2)
        case let .bulletList(items, tight):
            listStack(items: items, tight: tight) { _, item in
                if let checked = item.checkbox {
                    taskCheckbox(checked)
                } else {
                    Text("•")
                        .font(style.bodyFont.weight(.semibold))
                        .foregroundStyle(style.secondaryColor)
                        .frame(width: 20, alignment: .trailing)
                }
            }
        case let .orderedList(start, items, tight):
            listStack(items: items, tight: tight) { index, item in
                if let checked = item.checkbox {
                    taskCheckbox(checked, width: 30)
                } else {
                    Text("\(start + index).")
                        .font(style.bodyFont)
                        .foregroundStyle(style.secondaryColor)
                        .monospacedDigit()
                        .frame(width: 30, alignment: .trailing)
                }
            }
        case let .taskList(items):
            taskList(items)
        case let .blockquote(blocks):
            blockquote(blocks)
        case let .codeBlock(language, code):
            codeBlock(language: language, code: code)
        case let .proposedPlan(blocks, isComplete):
            proposedPlan(blocks: blocks, isComplete: isComplete)
        case let .image(reference):
            ConversationImagePreview(
                source: .markdown(reference.source),
                title: reference.displayText,
                style: style
            )
        case let .table(header, rows, alignments):
            table(header: header, rows: rows, alignments: alignments)
        case .thematicBreak:
            Divider()
                .overlay(style.dividerColor)
        }
    }

    @ViewBuilder
    private func inlineText(_ inline: MarkdownInlineText, font: Font? = nil, expand: Bool = false) -> some View {
        let text = Text(inline.attributed)
            .font(font ?? style.bodyFont)
            .foregroundStyle(style.textColor)
            .tint(style.linkColor)
            .lineSpacing(style.textLineSpacing)
            .fixedSize(horizontal: false, vertical: true)

        if expand {
            text.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            text
        }
    }

    private func listStack<Marker: View>(
        items: [MarkdownListItem],
        tight: Bool,
        @ViewBuilder marker: @escaping (Int, MarkdownListItem) -> Marker
    ) -> some View {
        VStack(alignment: .leading, spacing: tight ? 4 : 8) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HStack(alignment: .top, spacing: 8) {
                    marker(index, item)
                    VStack(alignment: .leading, spacing: tight ? 3 : style.blockSpacing) {
                        ForEach(item.blocks) { child in
                            MarkdownBlockView(block: child, style: style)
                        }
                    }
                }
            }
        }
    }

    private func taskList(_ items: [MarkdownTaskListItem]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 8) {
                    taskCheckbox(item.checked)

                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(item.blocks) { child in
                            MarkdownBlockView(block: child, style: style)
                        }
                    }
                }
            }
        }
    }

    private func taskCheckbox(_ checked: Bool, width: CGFloat = 20) -> some View {
        Image(systemName: checked ? "checkmark.square.fill" : "square")
            .font(style.bodyFont)
            .foregroundStyle(checked ? style.linkColor : style.secondaryColor)
            .frame(width: width, alignment: .trailing)
    }

    private func blockquote(_ blocks: [MarkdownBlock]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(style.quoteBar)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: style.blockSpacing) {
                ForEach(blocks) { child in
                    MarkdownBlockView(block: child, style: style)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func codeBlock(language: String?, code: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                if let language {
                    Text(language)
                        .font(style.captionFont)
                        .foregroundStyle(style.codeForeground.opacity(0.72))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Button {
                    UIPasteboard.general.string = code
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(style.codeForeground.opacity(0.72))
                .help(L10n.text("ui.copy_code"))
                .accessibilityLabel(L10n.text("ui.copy_code"))
            }

            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(style.codeFont)
                    .foregroundStyle(style.codeForeground)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .background(style.codeBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func proposedPlan(blocks: [MarkdownBlock], isComplete: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "list.clipboard")
                    .font(style.captionFont.weight(.semibold))
                    .foregroundStyle(style.linkColor)
                Text(L10n.text("ui.plan"))
                    .font(style.captionFont.weight(.semibold))
                    .foregroundStyle(style.secondaryColor)
                if !isComplete {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(style.linkColor)
                }
            }

            VStack(alignment: .leading, spacing: style.blockSpacing) {
                ForEach(blocks) { child in
                    MarkdownBlockView(block: child, style: style)
                }
            }
        }
        .padding(9)
        .background(style.planCardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(style.planCardBorder)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func table(
        header: [MarkdownInlineText],
        rows: [[MarkdownInlineText]],
        alignments: [MarkdownColumnAlignment]
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { index, cell in
                        inlineText(cell, font: style.bodyFont.weight(.semibold), expand: true)
                            .frame(minWidth: 96, alignment: alignment(for: alignments, index: index))
                    }
                }

                Divider()
                    .overlay(style.dividerColor)
                    .gridCellColumns(max(header.count, 1))

                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<max(header.count, row.count), id: \.self) { index in
                            inlineText(index < row.count ? row[index] : .empty, expand: true)
                                .frame(minWidth: 96, alignment: alignment(for: alignments, index: index))
                        }
                    }
                }
            }
            .padding(8)
            .background(style.tableBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func alignment(for alignments: [MarkdownColumnAlignment], index: Int) -> Alignment {
        guard index < alignments.count else {
            return .leading
        }

        switch alignments[index] {
        case .leading:
            return .leading
        case .center:
            return .center
        case .trailing:
            return .trailing
        }
    }
}

enum ConversationImageSource: Hashable, Identifiable {
    case dataURL(value: String, digest: String)
    case remoteURL(URL)
    case localPath(String)
    case historyMedia(id: String)
    case unsupported(String)

    var id: String {
        switch self {
        case .dataURL(_, let digest):
            return "data:\(digest)"
        case .remoteURL(let url):
            return "remote:\(url.absoluteString)"
        case .localPath(let path):
            return "local:\(path)"
        case .historyMedia(let id):
            return "historyMedia:\(id)"
        case .unsupported(let value):
            return "unsupported:\(value)"
        }
    }

    static func input(_ item: CodexAppServerUserInput) -> ConversationImageSource? {
        switch item {
        case .image(let url, _):
            return markdown(url)
        case .localImage(let path, _):
            return .localPath(path.trimmingCharacters(in: .whitespacesAndNewlines))
        case .uploadedFile(let file):
            guard let firstPage = file.pageImageDataURLs.first else {
                return nil
            }
            return markdown(firstPage)
        case .text, .skill, .mention:
            return nil
        }
    }

    static func markdown(_ source: String) -> ConversationImageSource {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .unsupported(source)
        }
        if trimmed.range(of: "data:image/", options: [.anchored, .caseInsensitive]) != nil {
            return .dataURL(value: trimmed, digest: stableDigest(trimmed))
        }
        if let id = historyMediaID(from: trimmed) {
            return .historyMedia(id: id)
        }
        if let localPath = localFilePath(from: trimmed) {
            return .localPath(localPath)
        }
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return .remoteURL(url)
        }
        return .unsupported(trimmed)
    }

    private static func localFilePath(from value: String) -> String? {
        if value.hasPrefix("/") {
            return value
        }
        guard let url = URL(string: value),
              url.scheme?.lowercased() == "file",
              !url.path.isEmpty
        else {
            return nil
        }
        return url.path
    }

    private static func historyMediaID(from value: String) -> String? {
        let prefix = "agentd-history-media://"
        guard value.hasPrefix(prefix) else {
            return nil
        }
        let id = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    private static func stableDigest(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

struct ConversationImagePreview: View {
    @EnvironmentObject private var sessionStore: SessionStore

    let source: ConversationImageSource
    let title: String?
    let style: MarkdownStyle
    let statusStyle: MarkdownStyle?
    var maxHeight: CGFloat = 280
    var showsCaption = true
    var fillsAvailableWidth = false
    var contentAlignment: Alignment = .leading
    var contentSizedMaxWidth: CGFloat?

    init(
        source: ConversationImageSource,
        title: String?,
        style: MarkdownStyle,
        statusStyle: MarkdownStyle? = nil,
        maxHeight: CGFloat = 280,
        showsCaption: Bool = true,
        fillsAvailableWidth: Bool = false,
        contentAlignment: Alignment = .leading,
        contentSizedMaxWidth: CGFloat? = nil
    ) {
        self.source = source
        self.title = title
        self.style = style
        self.statusStyle = statusStyle
        self.maxHeight = maxHeight
        self.showsCaption = showsCaption
        self.fillsAvailableWidth = fillsAvailableWidth
        self.contentAlignment = contentAlignment
        self.contentSizedMaxWidth = contentSizedMaxWidth
    }

    var body: some View {
        let profileID = sessionStore.mediaProfileScope
        let identity = MediaRequestIdentity(
            profileID: profileID,
            resourceID: source.id
        )

        ConversationImagePreviewContent(
            profileID: profileID,
            source: source,
            title: title,
            style: style,
            statusStyle: statusStyle,
            maxHeight: maxHeight,
            showsCaption: showsCaption,
            fillsAvailableWidth: fillsAvailableWidth,
            contentAlignment: contentAlignment,
            contentSizedMaxWidth: contentSizedMaxWidth
        )
        // Profile 改变时重建媒体叶子状态，旧 Mac 的 UIImage/QuickLook URL 不会闪现在新 Mac。
        .id(identity)
    }
}

private struct ConversationImagePreviewContent: View {
    @EnvironmentObject private var sessionStore: SessionStore
    @State private var embeddedImage: UIImage?
    @State private var localImage: UIImage?
    @State private var localFileURL: URL?
    @State private var quickLookURL: URL?
    @State private var isLoadingLocalImage = false
    @State private var loadError: String?

    let profileID: String
    let source: ConversationImageSource
    let title: String?
    let style: MarkdownStyle
    let statusStyle: MarkdownStyle?
    var maxHeight: CGFloat = 280
    var showsCaption = true
    var fillsAvailableWidth = false
    var contentAlignment: Alignment = .leading
    var contentSizedMaxWidth: CGFloat?

    init(
        profileID: String,
        source: ConversationImageSource,
        title: String?,
        style: MarkdownStyle,
        statusStyle: MarkdownStyle? = nil,
        maxHeight: CGFloat = 280,
        showsCaption: Bool = true,
        fillsAvailableWidth: Bool = false,
        contentAlignment: Alignment = .leading,
        contentSizedMaxWidth: CGFloat? = nil
    ) {
        self.profileID = profileID
        self.source = source
        self.title = title
        self.style = style
        self.statusStyle = statusStyle
        self.maxHeight = maxHeight
        self.showsCaption = showsCaption
        self.fillsAvailableWidth = fillsAvailableWidth
        self.contentAlignment = contentAlignment
        self.contentSizedMaxWidth = contentSizedMaxWidth
        let cachedImage: UIImage?
        switch source {
        case .dataURL:
            cachedImage = DataURLImageDecoder.cachedImage(
                cacheKey: source.id,
                profileID: profileID,
                maxPixelSize: 1_600
            )
        case .remoteURL:
            cachedImage = RemoteURLImageLoader.cachedImage(
                cacheKey: source.id,
                profileID: profileID,
                maxPixelSize: 1_600
            )
        case .localPath, .historyMedia, .unsupported:
            cachedImage = nil
        }
        _embeddedImage = State(initialValue: cachedImage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            content
            if showsCaption, let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                Text(title)
                    .font(style.captionFont)
                    .foregroundStyle(style.secondaryColor)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: contentAlignment)
        .quickLookPreview($quickLookURL)
        .task(id: mediaRequestIdentity) {
            await loadSourceIfNeeded()
        }
    }

    private var mediaRequestIdentity: MediaRequestIdentity {
        MediaRequestIdentity(profileID: profileID, resourceID: source.id)
    }

    @ViewBuilder
    private var content: some View {
        switch source {
        case .dataURL:
            if let image = embeddedImage {
                imageView(Image(uiImage: image), sourceSize: image.size)
            } else if isLoadingLocalImage {
                loadingPlaceholder
            } else {
                fallback(L10n.text("ui.image_data_cannot_be_decoded"), detail: "data:image/...")
            }
        case .remoteURL(let url):
            if let image = embeddedImage {
                imageView(Image(uiImage: image), sourceSize: image.size)
            } else if isLoadingLocalImage {
                loadingPlaceholder
            } else {
                fallback(loadError ?? L10n.text("ui.image_loading_failed"), detail: url.absoluteString)
            }
        case .localPath(let path):
            localImageContent(path: path)
                .task(id: MediaRequestIdentity(
                    profileID: profileID,
                    resourceID: "local:\(path)"
                )) {
                    await loadLocalImage(path: path)
                }
        case .historyMedia(let id):
            historyMediaContent(id: id)
        case .unsupported(let value):
            fallback(L10n.text("ui.this_image_address_is_not_supported_yet"), detail: compactSource(value))
        }
    }

    @MainActor
    private func loadSourceIfNeeded() async {
        let expectedSourceID = source.id
        switch source {
        case .dataURL(let value, _):
            loadError = nil
            if let cached = DataURLImageDecoder.cachedImage(
                cacheKey: expectedSourceID,
                profileID: profileID,
                maxPixelSize: 1_600
            ) {
                embeddedImage = cached
                isLoadingLocalImage = false
                return
            }
            embeddedImage = nil
            isLoadingLocalImage = true
            HostSwitchSignpost.event("first_media_request")
            let image = await DataURLImageDecoder.image(
                from: value,
                cacheKey: expectedSourceID,
                profileID: profileID,
                maxPixelSize: 1_600
            )
            guard !Task.isCancelled,
                  source.id == expectedSourceID,
                  sessionStore.mediaProfileScope == profileID
            else {
                return
            }
            embeddedImage = image
            isLoadingLocalImage = false
            if image != nil {
                HostSwitchSignpost.event("first_media_decoded")
            }
        case .remoteURL(let url):
            loadError = nil
            if let cached = RemoteURLImageLoader.cachedImage(
                cacheKey: expectedSourceID,
                profileID: profileID,
                maxPixelSize: 1_600
            ) {
                embeddedImage = cached
                isLoadingLocalImage = false
                return
            }
            embeddedImage = nil
            isLoadingLocalImage = true
            HostSwitchSignpost.event("first_media_request")
            let image = await RemoteURLImageLoader.image(
                from: url,
                cacheKey: expectedSourceID,
                profileID: profileID,
                maxPixelSize: 1_600
            )
            guard !Task.isCancelled,
                  source.id == expectedSourceID,
                  sessionStore.mediaProfileScope == profileID
            else {
                return
            }
            embeddedImage = image
            isLoadingLocalImage = false
            if image != nil {
                HostSwitchSignpost.event("first_media_decoded")
            } else {
                loadError = L10n.text("ui.image_loading_failed")
            }
        case .historyMedia(let id):
            embeddedImage = nil
            isLoadingLocalImage = false
            // history-media 只在图片进入可见区域时加载；列表展示不需要重复解码 1600px 原图。
            await loadHistoryMedia(id: id)
        case .localPath, .unsupported:
            embeddedImage = nil
            isLoadingLocalImage = false
        }
    }

    private func localImageContent(path: String) -> some View {
        Group {
            if let localImage {
                Button {
                    quickLookURL = localFileURL
                } label: {
                    imageView(Image(uiImage: localImage), sourceSize: localImage.size)
                }
                .buttonStyle(.plain)
                .disabled(localFileURL == nil)
                .accessibilityLabel(L10n.text("ui.preview_picture"))
            } else if isLoadingLocalImage {
                loadingPlaceholder
            } else {
                fallback(loadError ?? L10n.text("ui.image_not_loaded_yet"), detail: URL(fileURLWithPath: path).lastPathComponent)
            }
        }
    }

    private func historyMediaContent(id: String) -> some View {
        Group {
            if let localImage {
                Button {
                    quickLookURL = localFileURL
                } label: {
                    imageView(Image(uiImage: localImage), sourceSize: localImage.size)
                }
                .buttonStyle(.plain)
                .disabled(localFileURL == nil)
                .accessibilityLabel(L10n.text("ui.preview_historical_pictures"))
            } else if isLoadingLocalImage {
                loadingPlaceholder
            } else {
                Button {
                    Task {
                        await loadHistoryMedia(id: id)
                    }
                } label: {
                    fallback(loadError == nil ? L10n.text("ui.historical_images_not_loaded") : L10n.text("ui.failed_to_load_historical_images"), detail: loadError ?? L10n.text("ui.click_to_load"))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("ui.load_historical_images"))
            }
        }
    }

    private func imageView(_ image: Image, sourceSize: CGSize? = nil) -> some View {
        renderedImage(image, sourceSize: sourceSize)
            // 单图与多图统一成中性媒体卡：4pt 内边距把图像从描边内缩，
            // 白底截图不再顶死边框，圆角也能稳稳咬住内容，避免“图与框对不齐”。
            .padding(4)
            .background(
                style.tableBackground,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(style.dividerColor, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func renderedImage(_ image: Image, sourceSize: CGSize?) -> some View {
        if let fittedSize = contentSizedImageSize(for: sourceSize) {
            // 单图必须先得到明确的渲染尺寸，再添加背景和描边。只用 scaledToFit 会让
            // Image 的像素缩小、布局视图却继续占满父容器，最终留下整行灰色空白。
            image
                .resizable()
                .scaledToFit()
                .frame(width: fittedSize.width, height: fittedSize.height)
        } else {
            image
                .resizable()
                .scaledToFit()
                // 普通 Markdown 图片保持原有布局；用户多图消息继续使用统一宽度画布。
                .frame(
                    maxWidth: fillsAvailableWidth ? .infinity : nil,
                    maxHeight: maxHeight,
                    alignment: fillsAvailableWidth ? .center : contentAlignment
                )
        }
    }

    private func contentSizedImageSize(for sourceSize: CGSize?) -> CGSize? {
        guard let contentSizedMaxWidth,
              let sourceSize,
              sourceSize.width > 0,
              sourceSize.height > 0
        else {
            return nil
        }

        // 8pt 是媒体卡左右各 4pt 的内边距；小图不放大，避免低清附件被无意义拉伸。
        let maximumImageWidth = max(1, contentSizedMaxWidth - 8)
        let scale = min(
            1,
            maximumImageWidth / sourceSize.width,
            maxHeight / sourceSize.height
        )
        return CGSize(
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )
    }

    private var loadingPlaceholder: some View {
        let resolvedStatusStyle = statusStyle ?? style
        return HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(L10n.text("ui.picture_loading"))
                .font(style.captionFont)
        }
        .foregroundStyle(resolvedStatusStyle.secondaryColor)
        .frame(maxWidth: .infinity, minHeight: 120)
        .background(resolvedStatusStyle.tableBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(resolvedStatusStyle.dividerColor, lineWidth: 1)
        }
    }

    private func fallback(_ title: String, detail: String) -> some View {
        let resolvedStatusStyle = statusStyle ?? style
        return VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "photo")
                .font(style.captionFont.weight(.semibold))
                .foregroundStyle(resolvedStatusStyle.textColor)
            Text(detail)
                .font(style.captionFont)
                .foregroundStyle(resolvedStatusStyle.secondaryColor)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(resolvedStatusStyle.tableBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(resolvedStatusStyle.dividerColor, lineWidth: 1)
        }
    }

    @MainActor
    private func loadLocalImage(path: String) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty else {
            loadError = L10n.text("ui.the_local_path_is_empty_and_the_image")
            return
        }

        localImage = nil
        localFileURL = nil
        loadError = nil
        isLoadingLocalImage = true
        defer { isLoadingLocalImage = false }

        do {
            // 本机路径只代表 Mac/agentd 可读文件，iPad 端必须走 agentd 的授权文件读取接口；
            // 这样既能内嵌展示，也不会绕过后端的 projects/browse_roots 边界检查。
            HostSwitchSignpost.event("first_media_request")
            let url = try await sessionStore.previewFile(path: targetPath)
            guard !Task.isCancelled, sessionStore.mediaProfileScope == profileID else {
                return
            }
            guard let image = await DataURLImageDecoder.image(
                fromFileURL: url,
                cacheKey: "local:\(targetPath)",
                profileID: profileID,
                maxPixelSize: 1_600
            ) else {
                loadError = L10n.text("ui.the_file_was_read_but_could_not_be")
                return
            }
            guard !Task.isCancelled, sessionStore.mediaProfileScope == profileID else {
                return
            }
            localFileURL = url
            localImage = image
            HostSwitchSignpost.event("first_media_decoded")
        } catch is CancellationError {
            return
        } catch {
            loadError = userFacingPreviewError(error)
        }
    }

    @MainActor
    private func loadHistoryMedia(id: String) async {
        let targetID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetID.isEmpty else {
            loadError = L10n.text("ui.the_historical_image_id_is_empty_and_cannot")
            return
        }

        localImage = nil
        localFileURL = nil
        loadError = nil
        isLoadingLocalImage = true
        defer { isLoadingLocalImage = false }

        do {
            // 历史图片首屏只保留短 ID；用户点按时再从 agentd 短期缓存取回原始二进制。
            HostSwitchSignpost.event("first_media_request")
            let url = try await sessionStore.previewHistoryMedia(id: targetID)
            guard !Task.isCancelled, sessionStore.mediaProfileScope == profileID else {
                return
            }
            guard let image = await DataURLImageDecoder.image(
                fromFileURL: url,
                cacheKey: "historyMedia:\(targetID)",
                profileID: profileID,
                maxPixelSize: 960
            ) else {
                loadError = L10n.text("ui.historical_pictures_were_read_but_could_not_be")
                return
            }
            guard !Task.isCancelled, sessionStore.mediaProfileScope == profileID else {
                return
            }
            localFileURL = url
            localImage = image
            HostSwitchSignpost.event("first_media_decoded")
        } catch is CancellationError {
            return
        } catch {
            loadError = userFacingHistoryMediaError(error)
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

    private func userFacingHistoryMediaError(_ error: Error) -> String {
        if case AgentAPIError.server(let status, _) = error, status == 404 {
            return L10n.text("ui.the_historical_image_cache_has_expired_please_refresh")
        }
        if case AgentAPIError.server(let status, _) = error, status == 405 {
            return L10n.text("ui.the_current_agentd_version_does_not_support_on")
        }
        return userFacingPreviewError(error)
    }

    private func compactSource(_ value: String) -> String {
        if value.range(of: "data:image/", options: [.anchored, .caseInsensitive]) != nil {
            return "data:image/..."
        }
        if ConversationImageSource.markdown(value).id.hasPrefix("historyMedia:") {
            return "agentd-history-media://..."
        }
        return value
    }

}
