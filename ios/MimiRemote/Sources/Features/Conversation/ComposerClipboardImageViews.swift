import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 剪贴板里有图片时，输入框上方出现一行提示和系统「粘贴」按钮（#829）。
///
/// 探测只读 `hasImages` 和 `changeCount`，不读取内容，不会弹出系统的「允许粘贴」提示；
/// 真正读取用 `PasteButton`，这是系统认可的用户操作，同样不弹授权。
/// 用过或关闭后记住当时的 `changeCount`，剪贴板换了新内容才会再次出现。
struct ComposerClipboardImageState: Equatable {
    var availableChangeCount: Int?
    var dismissedChangeCount: Int?

    var isVisible: Bool { availableChangeCount != nil }

    mutating func refresh(hasImages: Bool, changeCount: Int, acceptsImages: Bool) {
        guard acceptsImages, hasImages, changeCount != dismissedChangeCount else {
            availableChangeCount = nil
            return
        }
        availableChangeCount = changeCount
    }

    mutating func dismissCurrent() {
        dismissedChangeCount = availableChangeCount
        availableChangeCount = nil
    }
}

extension ComposerView {
    static var clipboardRefreshPublisher: AnyPublisher<Void, Never> {
        Publishers.Merge(
            NotificationCenter.default.publisher(for: UIPasteboard.changedNotification),
            NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
        )
        .map { _ in () }
        .eraseToAnyPublisher()
    }

    var acceptsPastedImages: Bool {
        activeComposerDraftScope != .none
            && RuntimeFeatureSupport.supportsAttachments(for: composerRuntimeProvider)
    }

    func refreshClipboardImageAvailability() {
        let pasteboard = UIPasteboard.general
        clipboardImageState.refresh(
            hasImages: pasteboard.hasImages,
            changeCount: pasteboard.changeCount,
            acceptsImages: acceptsPastedImages
        )
    }

    /// 输入框 ⌘V / 长按粘贴图片时的回调；当前通道不收附件时返回 nil，粘贴回落为普通文字粘贴。
    var composerPasteImagesHandler: (([Data]) -> Void)? {
        guard acceptsPastedImages else { return nil }
        return { images in
            // 用过的剪贴板内容不再提示，避免同一张图被重复加入。
            clipboardImageState.dismissCurrent()
            addPastedImageData(images)
        }
    }

    @ViewBuilder
    var clipboardImageNotice: some View {
        if clipboardImageState.isVisible, acceptsPastedImages {
            let tokens = themeStore.tokens(for: colorScheme)
            HStack(spacing: 8) {
                Image(systemName: "photo.on.rectangle")
                    .foregroundStyle(tokens.secondaryText)
                    .accessibilityHidden(true)
                Text(L10n.text("ui.clipboard_has_image"))
                    .foregroundStyle(tokens.secondaryText)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                PasteButton(supportedContentTypes: [.image]) { providers in
                    Task { @MainActor in
                        await addPastedImageProviders(providers)
                    }
                }
                .labelStyle(.titleAndIcon)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .tint(tokens.accent)
                .accessibilityIdentifier("composer.clipboardImage.paste")
                Button {
                    clipboardImageState.dismissCurrent()
                } label: {
                    Image(systemName: "xmark")
                        .font(themeStore.uiFont(size: 12, weight: .semibold))
                        .foregroundStyle(tokens.secondaryText)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("ui.close"))
                .accessibilityIdentifier("composer.clipboardImage.dismiss")
            }
            .font(themeStore.uiFont(.caption))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
        }
    }

    @MainActor
    func addPastedImageProviders(_ providers: [NSItemProvider]) async {
        var images: [Data] = []
        for provider in providers {
            if let data = try? await Self.loadImageData(from: provider) {
                images.append(data)
            }
        }
        clipboardImageState.dismissCurrent()
        if images.isEmpty {
            attachmentErrorMessage = L10n.text("ui.clipboard_image_unreadable")
        } else {
            addPastedImageData(images)
        }
    }

    func addPastedImageData(_ images: [Data]) {
        let targetScope = activeComposerDraftScope
        let available = remainingImageAttachmentCapacity(for: targetScope)
        guard targetScope != .none, available > 0 else {
            attachmentErrorMessage = targetScope == .none
                ? L10n.text("ui.select_a_workspace_before_adding_files")
                : L10n.format("ui.at_most_images_can_be_added_to_each", Self.maximumImageAttachmentCount)
            return
        }
        let selected = Array(images.prefix(available))
        let skipped = images.count - selected.count
        Task {
            var prepared: [CodexAppServerUserInput] = []
            var failedCount = 0
            var firstError: Error?
            for data in selected {
                do {
                    let result = try await Task.detached(priority: .userInitiated) {
                        try ImageAttachmentEncoder.prepare(data)
                    }.value
                    prepared.append(.image(url: result.dataURL, detail: .auto))
                } catch {
                    failedCount += 1
                    firstError = firstError ?? error
                }
            }
            let added = addPreparedImageAttachments(prepared, to: targetScope)
            updateBatchAttachmentNotice(
                addedCount: added,
                failedCount: failedCount,
                skippedCount: skipped + max(0, prepared.count - added),
                firstError: firstError
            )
        }
    }

    /// 只给当前草稿里的图片附件开放标注。
    func annotationHandler(for item: CodexAppServerUserInput) -> ((UIImage) -> Void)? {
        guard case .image = item,
              composerState.attachments.contains(where: { $0.id == item.id }) else {
            return nil
        }
        return { annotated in
            replaceAnnotatedAttachment(item, with: annotated)
        }
    }

    /// 标注完成后用新图替换原附件，位置不变；原附件已被移除时不再追加，避免标注结果串到别的草稿。
    func replaceAnnotatedAttachment(_ original: CodexAppServerUserInput, with annotated: UIImage) {
        let targetScope = activeComposerDraftScope
        guard let data = annotated.pngData() else {
            attachmentErrorMessage = L10n.text("ui.image_annotation_failed")
            return
        }
        Task {
            do {
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try ImageAttachmentEncoder.prepare(data)
                }.value
                let replacement = CodexAppServerUserInput.image(url: prepared.dataURL, detail: .auto)
                guard targetScope == activeComposerDraftScope,
                      let index = composerState.attachments.firstIndex(where: { $0.id == original.id }) else {
                    return
                }
                composerState.attachments[index] = replacement
                sessionStore.saveComposerDraft(composerState.draftSnapshot(), for: targetScope)
            } catch {
                attachmentErrorMessage = userFacingAttachmentError(error)
            }
        }
    }
}
