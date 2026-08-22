import PhotosUI
import QuickLook
import SwiftUI
import UIKit

struct AttachmentPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var previewURL: URL?
    @State private var embeddedImage: UIImage?
    @State private var isLoadingEmbeddedImage = false
    @State private var previewingLocalImagePath: String?
    @State private var localImagePreviewError: String?

    let item: CodexAppServerUserInput

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    previewContent(tokens: tokens)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(tokens.surface)
            .navigationTitle(L10n.text("ui.attachment_preview"))
            .navigationBarTitleDisplayMode(.inline)
            .quickLookPreview($previewURL)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("ui.close")) { dismiss() }
                }
            }
        }
        .task(id: previewMediaRequestIdentity) {
            await loadEmbeddedImageIfNeeded()
        }
    }

    @ViewBuilder
    private func previewContent(tokens: ThemeTokens) -> some View {
        switch item {
        case .image(let url, _):
            if let image = embeddedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else if isLoadingEmbeddedImage {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else if let remoteURL = URL(string: url),
                      let scheme = remoteURL.scheme?.lowercased(),
                      ["http", "https"].contains(scheme) {
                AsyncImage(url: remoteURL) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 180)
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    case .failure:
                        previewMessage(L10n.text("ui.image_loading_failed"), detail: url, tokens: tokens)
                    @unknown default:
                        previewMessage(L10n.text("ui.image_loading_failed"), detail: url, tokens: tokens)
                    }
                }
            } else {
                previewMessage(L10n.text("ui.unable_to_preview_this_image_reference"), detail: url, tokens: tokens)
            }
        case .localImage(let path, _):
            localImagePreview(path: path, tokens: tokens)
        case .uploadedFile(let file):
            VStack(alignment: .leading, spacing: 14) {
                Label(file.name, systemImage: "doc")
                    .font(themeStore.uiFont(.headline, weight: .semibold))
                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(tokens.secondaryText)
                if let image = embeddedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                if !file.extractedText.isEmpty {
                    Text(file.extractedText)
                        .font(themeStore.uiFont(.body))
                        .foregroundStyle(tokens.primaryText)
                        .textSelection(.enabled)
                }
            }
        case .text(let text, _):
            previewMessage(L10n.text("ui.text_attachment"), detail: text, tokens: tokens)
        case .skill(let name, let path):
            previewMessage("$\(name)", detail: path, tokens: tokens)
        case .mention(let name, let path):
            previewMessage("@\(name)", detail: path, tokens: tokens)
        }
    }

    private var previewImageSource: ConversationImageSource? {
        ConversationImageSource.input(item)
    }

    private var previewMediaRequestIdentity: MediaRequestIdentity {
        MediaRequestIdentity(
            profileID: sessionStore.mediaProfileScope,
            resourceID: previewImageSource?.id ?? "none"
        )
    }

    @MainActor
    private func loadEmbeddedImageIfNeeded() async {
        let profileID = sessionStore.mediaProfileScope
        previewURL = nil
        embeddedImage = nil
        isLoadingEmbeddedImage = false
        previewingLocalImagePath = nil
        localImagePreviewError = nil
        guard case .dataURL(let value, _) = previewImageSource else {
            return
        }
        let expectedSourceID = previewImageSource?.id
        guard let expectedSourceID else {
            return
        }
        isLoadingEmbeddedImage = true
        let image = await DataURLImageDecoder.image(
            from: value,
            cacheKey: expectedSourceID,
            profileID: profileID,
            maxPixelSize: 2_400
        )
        guard !Task.isCancelled,
              previewImageSource?.id == expectedSourceID,
              sessionStore.mediaProfileScope == profileID
        else {
            return
        }
        embeddedImage = image
        isLoadingEmbeddedImage = false
    }

    private func localImagePreview(path: String, tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            previewMessage(
                L10n.text("ui.native_image_path"),
                detail: path + L10n.text("ui.it_is_read_by_the_local_agentd_when"),
                tokens: tokens
            )
            Button {
                Task { await previewLocalImage(path: path) }
            } label: {
                if previewingLocalImagePath == path {
                    Label(L10n.text("ui.previewing"), systemImage: "hourglass")
                } else {
                    Label(L10n.text("ui.preview_file"), systemImage: "eye")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(previewingLocalImagePath != nil || path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if let localImagePreviewError {
                Text(localImagePreviewError)
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(tokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func previewLocalImage(path: String) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty else {
            localImagePreviewError = L10n.text("ui.the_local_path_is_empty_and_cannot_be")
            return
        }

        previewingLocalImagePath = targetPath
        localImagePreviewError = nil
        defer {
            if previewingLocalImagePath == targetPath {
                previewingLocalImagePath = nil
            }
        }
        do {
            previewURL = try await sessionStore.previewFile(path: targetPath)
        } catch is CancellationError {
            return
        } catch {
            localImagePreviewError = userFacingPreviewError(error)
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

    private func previewMessage(_ title: String, detail: String, tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "photo")
                .font(themeStore.uiFont(.headline, weight: .semibold))
                .foregroundStyle(tokens.primaryText)
            Text(detail)
                .font(themeStore.codeFont(.caption))
                .foregroundStyle(tokens.secondaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

}

struct PhotoLibraryPickerRequest: Identifiable {
    let id = UUID()
    let selectionLimit: Int
    let targetScope: ComposerDraftScopeKey
}

enum PhotoLibraryPickerError: LocalizedError {
    case unsupportedImage
    case unreadableImage

    var errorDescription: String? {
        switch self {
        case .unsupportedImage:
            return L10n.text("ui.the_selected_item_is_not_a_supported_image")
        case .unreadableImage:
            return L10n.text("ui.unable_to_read_selected_image")
        }
    }
}

struct PhotoLibraryPicker: UIViewControllerRepresentable {
    let selectionLimit: Int
    let onFinish: ([PHPickerResult]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        let configuration = Self.makeConfiguration(selectionLimit: selectionLimit)

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    static func makeConfiguration(selectionLimit: Int) -> PHPickerConfiguration {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = max(1, selectionLimit)
        configuration.selection = .ordered
        return configuration
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {
        context.coordinator.onFinish = onFinish
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        var onFinish: ([PHPickerResult]) -> Void

        init(onFinish: @escaping ([PHPickerResult]) -> Void) {
            self.onFinish = onFinish
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            // PHPicker 只在用户点击“添加/取消”后进入这里，因此一次回传完整有序选择。
            onFinish(results)
        }
    }
}

struct FileUploadJobsStrip: View {
    @ObservedObject var store: FileUploadStore
    let scope: ComposerDraftScopeKey

    var body: some View {
        let scopedJobs = store.jobs(for: scope)
        if !scopedJobs.isEmpty {
            VStack(spacing: 8) {
                ForEach(scopedJobs) { job in
                    FileUploadJobRow(
                        job: job,
                        onRetry: { store.retry(id: job.id) },
                        onCancel: { store.cancel(id: job.id) }
                    )
                }
            }
        }
    }
}

private struct FileUploadJobRow: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    let job: FileUploadJob
    let onRetry: () -> Void
    let onCancel: () -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        HStack(spacing: 10) {
            statusIcon
                .foregroundStyle(job.phase == .failed ? Color.red : tokens.accent)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(job.fileName)
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                    .lineLimit(1)
                jobStatus
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if job.phase == .failed, job.canRetry {
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("ui.try_again"))
            }
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(tokens.secondaryText)
            .accessibilityLabel(L10n.text("ui.cancel"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(tokens.elevatedSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tokens.border.opacity(0.72), lineWidth: 0.75)
        }
    }

    private var statusIcon: Image {
        Image(systemName: job.phase == .failed ? "exclamationmark.doc" : "doc.badge.arrow.up")
    }

    @ViewBuilder
    private var jobStatus: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        if job.phase == .uploading {
            ProgressView(value: job.progress)
                .tint(tokens.accent)
                .accessibilityLabel(L10n.text("ui.upload_progress"))
                .accessibilityValue(Text(job.progress, format: .percent))
        } else {
            Text(statusText)
                .font(themeStore.uiFont(.caption2))
                .foregroundStyle(job.phase == .failed ? Color.red : tokens.secondaryText)
                .lineLimit(2)
        }
    }

    private var statusText: String {
        switch job.phase {
        case .preparing:
            return L10n.text("ui.preparing_file")
        case .uploading:
            return L10n.text("ui.uploading_file")
        case .failed:
            return job.errorMessage ?? L10n.text("ui.file_upload_failed")
        }
    }
}

enum AddContentPanelPage: Equatable {
    case root
    case plugins
    case skills
    case permissions
    case shortcuts
}

enum PendingAddContentAction: Equatable {
    case camera(targetScope: ComposerDraftScopeKey)
    case files(targetScope: ComposerDraftScopeKey)
    case photos(targetScope: ComposerDraftScopeKey, selectionLimit: Int)
}

struct FileImporterRequest: Identifiable, Equatable {
    let id = UUID()
    let targetScope: ComposerDraftScopeKey
    let capabilityLease: HostCapabilityLease
}

struct FileImporterPresentationState: Equatable {
    private(set) var request: FileImporterRequest?
    var isPresented = false

    mutating func present(_ request: FileImporterRequest) {
        self.request = request
        isPresented = true
    }

    mutating func consumeRequest() -> FileImporterRequest? {
        // 系统会先把 isPresented 写回 false，再调用文件选择结果回调。
        // 请求上下文必须保留到回调消费，否则用户选中文件后会被静默忽略。
        isPresented = false
        defer { request = nil }
        return request
    }
}

struct AddContentPanel: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var page: AddContentPanelPage = .root
    @State private var searchText = ""

    let skillShortcuts: [SkillCapability]
    let pluginShortcuts: [CodexPluginCapability]
    let capabilityErrorMessage: String?
    let isRefreshingCapabilities: Bool
    let showsPermissionSettings: Bool
    let permissionModes: [ComposerPermissionMode]
    let selectedPermissionMode: ComposerPermissionMode
    let showsCameraAction: Bool
    let selectedSkillPaths: Set<String>
    let onPickFile: () -> Void
    let onCapturePhoto: () -> Void
    let onPickPhotos: () -> Void
    let onToggleSkill: (SkillCapability) -> Void
    let onManualAddSkill: () -> Void
    let onPluginShortcut: (CodexPluginCapability) -> Void
    let onRefreshCapabilities: () -> Void
    let onPermissionMode: (ComposerPermissionMode) -> Void
    let onShortcut: (String) -> Void

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        VStack(spacing: 0) {
            if page != .root && page != .skills {
                panelHeader(tokens: tokens)
                    .padding(.bottom, 12)
            }

            Group {
                switch page {
                case .root:
                    rootActions(tokens: tokens)
                case .plugins:
                    pluginList(tokens: tokens)
                case .skills:
                    SkillSelectionContent(
                        skills: skillShortcuts,
                        selectedPaths: selectedSkillPaths,
                        errorMessage: capabilityErrorMessage,
                        isRefreshing: isRefreshingCapabilities,
                        maxListHeight: 320,
                        onBack: {
                            searchText = ""
                            page = .root
                        },
                        onToggle: onToggleSkill,
                        onRefresh: onRefreshCapabilities,
                        onManualAdd: {
                            // 先让当前展示层退出，再交给外层打开手动添加 Sheet，
                            // 避免两个 presentation 在同一更新周期争抢宿主控制器。
                            dismiss()
                            DispatchQueue.main.async {
                                onManualAddSkill()
                            }
                        },
                        onDone: {
                            dismiss()
                        }
                    )
                case .permissions:
                    permissionList(tokens: tokens)
                case .shortcuts:
                    shortcutList(tokens: tokens)
                }
            }
            .transition(
                reduceMotion
                    ? .opacity
                    : .asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    )
            )
        }
        .padding(16)
        .frame(idealWidth: 390, maxWidth: 420, alignment: .top)
        .animation(
            reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.34, dampingFraction: 1),
            value: page
        )
        // 整个 Sheet 只使用一层材质，避免内容区和底部留白分别落到不同的不透明背景上。
        // “降低透明度”开启时改回主题实色，保证文字与控件对比度。
        .presentationBackground {
            if reduceTransparency {
                tokens.surface
            } else {
                Rectangle()
                    .fill(WorkbenchMaterial.surface)
                    .overlay(tokens.surface.opacity(colorScheme == .light ? 0.28 : 0.20))
            }
        }
        .modifier(
            AddContentPanelPresentationSizing(
                page: page,
                usesAccessibilityLayout: dynamicTypeSize.isAccessibilitySize,
                standardRootHeight: standardRootPanelHeight
            )
        )
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }

    private func panelHeader(tokens: ThemeTokens) -> some View {
        HStack(spacing: 10) {
            if page != .root {
                Button {
                    searchText = ""
                    page = .root
                } label: {
                    Image(systemName: "chevron.left")
                        .font(themeStore.uiFont(.callout, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(tokens.selectionFill, in: Circle())
                }
                .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
                .accessibilityLabel(L10n.text("ui.return_to_add_content"))
            } else {
                Image(systemName: "plus")
                    .font(themeStore.uiFont(.callout, weight: .bold))
                    .foregroundStyle(tokens.accent)
                    .frame(width: 44, height: 44)
                    .background(tokens.selectionFill, in: Circle())
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(pageTitle)
                    .font(themeStore.uiFont(.headline, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                Text(pageSubtitle)
                    .font(themeStore.uiFont(.caption))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(themeStore.uiFont(.caption, weight: .bold))
                    .foregroundStyle(tokens.secondaryText)
                    .frame(width: 44, height: 44)
                    .background(tokens.selectionFill.opacity(0.72), in: Circle())
            }
            .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
            .accessibilityLabel(L10n.text("ui.close_adding_content"))
        }
    }

    @ViewBuilder
    private func rootActions(tokens: ThemeTokens) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            ScrollView {
                accessibleRootActions(tokens: tokens)
            }
            .scrollIndicators(.hidden)
        } else {
            standardRootActions(tokens: tokens)
        }
    }

    private func standardRootActions(tokens: ThemeTokens) -> some View {
        VStack(spacing: 0) {
            LazyVGrid(columns: sourceActionColumns, spacing: 8) {
                sourceActionButton(
                    title: L10n.text("ui.file"),
                    subtitle: L10n.text("ui.select_pdf_text_or_source_file"),
                    systemImage: "paperclip",
                    accessibilityIdentifier: "composer.addContent.file",
                    tokens: tokens,
                    action: onPickFile
                )
                if showsCameraAction {
                    sourceActionButton(
                        title: L10n.text("ui.camera"),
                        subtitle: L10n.text("ui.take_a_photo_to_attach_to_the_message"),
                        systemImage: "camera",
                        accessibilityIdentifier: "composer.addContent.camera",
                        tokens: tokens,
                        action: onCapturePhoto
                    )
                }
                sourceActionButton(
                    title: L10n.text("ui.pictures"),
                    subtitle: L10n.text("ui.select_from_photo_gallery_multiple_selections_possible"),
                    systemImage: "photo.on.rectangle.angled",
                    accessibilityIdentifier: "composer.addContent.photos",
                    tokens: tokens,
                    action: onPickPhotos
                )
            }

            Divider()
                .padding(.vertical, 6)

            compactListActionButton(
                title: L10n.text("ui.plugin"),
                subtitle: pluginShortcuts.isEmpty ? L10n.text("ui.view_installed_codex_plugins") : L10n.plural("ui.plugins_installed_count", count: pluginShortcuts.count),
                systemImage: "at",
                tokens: tokens
            ) {
                page = .plugins
            }
            compactListActionButton(
                title: "Skill",
                subtitle: skillShortcuts.isEmpty ? L10n.text("ui.add_structured_workflow") : L10n.plural("ui.skills_available_count", count: skillShortcuts.count),
                systemImage: "wand.and.stars",
                accessibilityIdentifier: "composer.addContent.skills",
                tokens: tokens
            ) {
                page = .skills
            }
            if showsPermissionSettings {
                compactListActionButton(
                    title: L10n.text("ui.permission_mode"),
                    subtitle: selectedPermissionMode.title,
                    systemImage: selectedPermissionMode.systemImage,
                    tokens: tokens
                ) {
                    page = .permissions
                }
            }
            compactListActionButton(
                title: L10n.text("ui.shortcut_phrase"),
                subtitle: L10n.text("ui.insert_frequently_used_task_templates"),
                systemImage: "bolt.fill",
                tokens: tokens
            ) {
                page = .shortcuts
            }
        }
    }

    private func accessibleRootActions(tokens: ThemeTokens) -> some View {
        VStack(spacing: 0) {
            accessibleListActionButton(
                title: L10n.text("ui.file"),
                subtitle: L10n.text("ui.select_pdf_text_or_source_file"),
                systemImage: "paperclip",
                showsDisclosure: false,
                accessibilityIdentifier: "composer.addContent.file",
                tokens: tokens,
                action: onPickFile
            )
            if showsCameraAction {
                accessibleListActionButton(
                    title: L10n.text("ui.camera"),
                    subtitle: L10n.text("ui.take_a_photo_to_attach_to_the_message"),
                    systemImage: "camera",
                    showsDisclosure: false,
                    accessibilityIdentifier: "composer.addContent.camera",
                    tokens: tokens,
                    action: onCapturePhoto
                )
            }
            accessibleListActionButton(
                title: L10n.text("ui.pictures"),
                subtitle: L10n.text("ui.select_from_photo_gallery_multiple_selections_possible"),
                systemImage: "photo.on.rectangle.angled",
                showsDisclosure: false,
                accessibilityIdentifier: "composer.addContent.photos",
                tokens: tokens,
                action: onPickPhotos
            )
            Divider()
                .padding(.vertical, 6)
            accessibleListActionButton(
                title: L10n.text("ui.plugin"),
                subtitle: pluginShortcuts.isEmpty ? L10n.text("ui.view_installed_codex_plugins") : L10n.plural("ui.plugins_installed_count", count: pluginShortcuts.count),
                systemImage: "at",
                tokens: tokens
            ) {
                page = .plugins
            }
            accessibleListActionButton(
                title: "Skill",
                subtitle: skillShortcuts.isEmpty ? L10n.text("ui.add_structured_workflow") : L10n.plural("ui.skills_available_count", count: skillShortcuts.count),
                systemImage: "wand.and.stars",
                accessibilityIdentifier: "composer.addContent.skills",
                tokens: tokens
            ) {
                page = .skills
            }
            if showsPermissionSettings {
                accessibleListActionButton(
                    title: L10n.text("ui.permission_mode"),
                    subtitle: selectedPermissionMode.title,
                    systemImage: selectedPermissionMode.systemImage,
                    tokens: tokens
                ) {
                    page = .permissions
                }
            }
            accessibleListActionButton(
                title: L10n.text("ui.shortcut_phrase"),
                subtitle: L10n.text("ui.insert_frequently_used_task_templates"),
                systemImage: "bolt.fill",
                tokens: tokens
            ) {
                page = .shortcuts
            }
        }
    }

    private var sourceActionColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 72), spacing: 8),
            count: showsCameraAction ? 3 : 2
        )
    }

    private func sourceActionButton(
        title: String,
        subtitle: String,
        systemImage: String,
        accessibilityIdentifier: String,
        tokens: ThemeTokens,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(themeStore.uiFont(size: 17, weight: .semibold))
                    .foregroundStyle(tokens.accent)
                    .frame(width: 38, height: 38)
                    .background(tokens.selectionFill, in: Circle())

                Text(title)
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(tokens.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            // 视觉内容保持紧凑，但整个格子都能点击，避免牺牲触控命中区域。
            .frame(maxWidth: .infinity, minHeight: 80)
            .background(tokens.elevatedSurface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(tokens.border.opacity(0.62), lineWidth: 0.75)
            }
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func compactListActionButton(
        title: String,
        subtitle: String,
        systemImage: String,
        accessibilityIdentifier: String = "",
        tokens: ThemeTokens,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(themeStore.uiFont(size: 16, weight: .semibold))
                    .foregroundStyle(tokens.accent)
                    .frame(width: 36, height: 36)
                    .background(tokens.selectionFill, in: Circle())

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(themeStore.uiFont(.callout, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(themeStore.uiFont(.caption))
                        .foregroundStyle(tokens.secondaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(themeStore.uiFont(.caption2, weight: .bold))
                    .foregroundStyle(tokens.tertiaryText)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func accessibleListActionButton(
        title: String,
        subtitle: String,
        systemImage: String,
        showsDisclosure: Bool = true,
        accessibilityIdentifier: String = "",
        tokens: ThemeTokens,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(themeStore.uiFont(size: 19, weight: .semibold))
                    .foregroundStyle(tokens.accent)
                    .frame(width: 44, height: 44)
                    .background(tokens.selectionFill, in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(themeStore.uiFont(.callout, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                    Text(subtitle)
                        .font(themeStore.uiFont(.caption))
                        .foregroundStyle(tokens.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if showsDisclosure {
                    Image(systemName: "chevron.right")
                        .font(themeStore.uiFont(.caption2, weight: .bold))
                        .foregroundStyle(tokens.tertiaryText)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func pluginList(tokens: ThemeTokens) -> some View {
        VStack(spacing: 10) {
            searchField(placeholder: L10n.text("ui.search_plugin"), tokens: tokens)
            if filteredPlugins.isEmpty {
                emptyCapabilities(
                    title: searchText.isEmpty ? L10n.text("ui.no_plugins_installed_yet") : L10n.text("ui.no_matching_plugin"),
                    detail: searchText.isEmpty ? L10n.text("ui.please_install_and_enable_the_codex_plug_in") : L10n.text("ui.try_another_name"),
                    tokens: tokens
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(filteredPlugins) { plugin in
                            Button {
                                onPluginShortcut(plugin)
                            } label: {
                                HStack(spacing: 11) {
                                    pluginIcon(tokens: tokens)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("@\(plugin.presentationName)")
                                            .font(themeStore.uiFont(.callout, weight: .semibold))
                                            .foregroundStyle(tokens.primaryText)
                                            .lineLimit(1)
                                        Text(pluginSubtitle(plugin))
                                            .font(themeStore.uiFont(.caption))
                                            .foregroundStyle(tokens.secondaryText)
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    if plugin.enabled {
                                        Image(systemName: "plus.circle.fill")
                                            .foregroundStyle(tokens.accent)
                                    } else {
                                        Text(L10n.text("ui.deactivated"))
                                            .font(themeStore.uiFont(.caption2, weight: .semibold))
                                            .foregroundStyle(tokens.tertiaryText)
                                    }
                                }
                                .padding(10)
                                .background(tokens.elevatedSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
                            .disabled(!plugin.enabled)
                            .opacity(plugin.enabled ? 1 : 0.58)
                        }
                    }
                }
                .frame(maxHeight: 320)
                .scrollIndicators(.hidden)
            }
        }
    }

    private func permissionList(tokens: ThemeTokens) -> some View {
        ScrollView {
            LazyVStack(spacing: 7) {
                ForEach(permissionModes) { mode in
                    Button {
                        onPermissionMode(mode)
                        dismiss()
                    } label: {
                        HStack(spacing: 11) {
                            Image(systemName: mode.systemImage)
                                .font(themeStore.uiFont(.callout, weight: .semibold))
                                .foregroundStyle(tokens.accent)
                                .frame(width: 38, height: 38)
                                .background(
                                    tokens.selectionFill,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.title)
                                    .font(themeStore.uiFont(.callout, weight: .semibold))
                                    .foregroundStyle(tokens.primaryText)
                                Text(mode.detail)
                                    .font(themeStore.uiFont(.caption))
                                    .foregroundStyle(tokens.secondaryText)
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            if selectedPermissionMode == mode {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(tokens.accent)
                            }
                        }
                        .padding(10)
                        .background(
                            tokens.elevatedSurface,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
                    .accessibilityHint(mode.detail)
                }
            }
        }
        .frame(maxHeight: 330)
        .scrollIndicators(.hidden)
    }

    private func shortcutList(tokens: ThemeTokens) -> some View {
        ScrollView {
            LazyVStack(spacing: 7) {
                ForEach(Self.shortcuts, id: \.self) { shortcut in
                    Button {
                        onShortcut(shortcut)
                    } label: {
                        HStack(spacing: 11) {
                            Image(systemName: "bolt.fill")
                                .font(themeStore.uiFont(.callout, weight: .semibold))
                                .foregroundStyle(tokens.accent)
                                .frame(width: 36, height: 36)
                                .background(tokens.selectionFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            Text(shortcut)
                                .font(themeStore.uiFont(.callout, weight: .medium))
                                .foregroundStyle(tokens.primaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .multilineTextAlignment(.leading)
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(tokens.accent)
                        }
                        .padding(10)
                        .background(tokens.elevatedSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
                }
            }
        }
        .frame(maxHeight: 330)
        .scrollIndicators(.hidden)
    }

    private func searchField(placeholder: String, tokens: ThemeTokens) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(tokens.tertiaryText)
            TextField(placeholder, text: $searchText)
                .font(themeStore.uiFont(.callout))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(tokens.tertiaryText)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("ui.clear_search"))
            }
        }
        .padding(.horizontal, 11)
        .frame(minHeight: 44)
        .background(tokens.selectionFill.opacity(0.72), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func emptyCapabilities(title: String, detail: String, tokens: ThemeTokens) -> some View {
        VStack(spacing: 8) {
            Image(systemName: page == .plugins ? "puzzlepiece.extension" : "wand.and.stars")
                .font(themeStore.uiFont(size: 24, weight: .medium))
                .foregroundStyle(tokens.tertiaryText)
            Text(title)
                .font(themeStore.uiFont(.callout, weight: .semibold))
                .foregroundStyle(tokens.primaryText)
            Text(nonEmpty(capabilityErrorMessage) ?? detail)
                .font(themeStore.uiFont(.caption))
                .foregroundStyle(tokens.secondaryText)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if searchText.isEmpty {
                Button {
                    onRefreshCapabilities()
                } label: {
                    Label(isRefreshingCapabilities ? L10n.text("ui.refreshing") : L10n.text("ui.refresh_list"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(isRefreshingCapabilities)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 230)
    }

    private func pluginIcon(tokens: ThemeTokens) -> some View {
        Image(systemName: "at")
            .font(themeStore.uiFont(size: 17, weight: .bold))
            .foregroundStyle(tokens.accent)
            .frame(width: 38, height: 38)
            .background(tokens.selectionFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var filteredPlugins: [CodexPluginCapability] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return pluginShortcuts }
        return pluginShortcuts.filter { plugin in
            plugin.presentationName.localizedCaseInsensitiveContains(query)
                || (plugin.description?.localizedCaseInsensitiveContains(query) ?? false)
                || plugin.marketplace.localizedCaseInsensitiveContains(query)
        }
    }

    private func pluginSubtitle(_ plugin: CodexPluginCapability) -> String {
        nonEmpty(plugin.description)
            ?? nonEmpty(plugin.marketplace)
            ?? L10n.text("ui.plugin_installed")
    }

    private func nonEmpty(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? nil : normalized
    }

    private var pageTitle: String {
        switch page {
        case .root: return L10n.text("ui.add_content")
        case .plugins: return L10n.text("ui.plugin")
        case .skills: return L10n.text("ui.select_skill")
        case .permissions: return L10n.text("ui.permission_mode")
        case .shortcuts: return L10n.text("ui.shortcut_phrase")
        }
    }

    private var pageSubtitle: String {
        switch page {
        case .root: return L10n.text("ui.add_context_for_the_next_message")
        case .plugins: return L10n.text("ui.reference_the_installed_codex_plug_in_on_mac")
        case .skills: return L10n.text("ui.selected_and_sent_as_structured_capabilities")
        case .permissions: return selectedPermissionMode.detail
        case .shortcuts: return L10n.text("ui.click_to_insert_input_box")
        }
    }

    private var standardRootPanelHeight: CGFloat {
        // `.height` 只负责 iPhone 上 Popover 的 Sheet 退化；原生 Popover 本身由
        // `.presentationSizing(.fitted)` 按真实内容测量，二者都不会再撑到旧的 512pt。
        let listActionCount = showsPermissionSettings ? 4 : 3
        return 32 + 80 + 13 + CGFloat(listActionCount * 56)
    }

    private static let shortcuts = [
        L10n.text("ui.check_this_implementation_and_give_the_risks"),
        L10n.text("ui.implement_this_function_and_add_tests"),
        L10n.text("ui.only_make_the_smallest_runnable_version_to_avoid"),
        L10n.text("ui.explain_the_failure_log_and_provide_repair_solutions")
    ]
}

private struct AddContentPanelPresentationSizing: ViewModifier {
    let page: AddContentPanelPage
    let usesAccessibilityLayout: Bool
    let standardRootHeight: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if page == .root {
            if usesAccessibilityLayout {
                content
                    .presentationSizing(.form)
                    .presentationDetents([.large])
            } else {
                content
                    .presentationSizing(.fitted)
                    .presentationDetents([.height(standardRootHeight)])
            }
        } else {
            // 子页面继续沿用原来的尺寸和滚动策略。
            if usesAccessibilityLayout {
                content
                    .presentationSizing(.form)
                    .presentationDetents([.large])
            } else {
                content
                    .presentationSizing(.form)
                    .presentationDetents([.height(470)])
            }
        }
    }
}
