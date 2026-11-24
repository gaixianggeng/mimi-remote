import Combine
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 应用级（进程内）剪贴板图片横幅关闭记录。
///
/// 离开再进会话（重建 `ComposerView` / `@State`）或并存多个输入区实例时共用同一份记录，
/// 关闭或粘贴后不再对同一 `UIPasteboard.changeCount` 重复提示，且所有现存横幅同步收起。
/// 记录随应用进程结束失效，不向 `UserDefaults` 长期写入裸 `changeCount`，
/// 避免设备重启将 `UIPasteboard.changeCount` 重置为 0 后与新图片撞号。
@MainActor
@Observable
final class ComposerClipboardImageDismissStore {
    static let shared = ComposerClipboardImageDismissStore()

    private(set) var dismissedChangeCount: Int?

    init(dismissedChangeCount: Int? = nil) {
        self.dismissedChangeCount = dismissedChangeCount
    }

    func isDismissed(_ changeCount: Int) -> Bool {
        guard let dismissedChangeCount else { return false }
        return changeCount <= dismissedChangeCount
    }

    func markDismissed(_ changeCount: Int) {
        // 单次进程内 UIPasteboard.changeCount 单调递增；过期的关闭事件不得覆盖更新的记录。
        if let existing = dismissedChangeCount, changeCount < existing {
            return
        }
        dismissedChangeCount = changeCount
    }
}

/// 剪贴板里有图片时，输入框上方出现一行提示和系统「粘贴」按钮（#829）。
///
/// 探测只读 `hasImages` 和 `changeCount`，不读取内容，不会弹出系统的「允许粘贴」提示；
/// 真正读取用 `PasteButton`，这是系统认可的用户操作，同样不弹授权。
/// 用过或关闭后把对应的 `changeCount` 记入应用级共享状态，离开再进会话也不会对同一份剪贴板重复提示，
/// 剪贴板换了新内容才会再次出现。
struct ComposerClipboardImageState: Equatable {
    var availableChangeCount: Int?
    /// 粘贴图片编码、标注替换还没写回草稿时按草稿计数；不为零就禁止发送，
    /// 避免先发出不带图（或带原图）的消息，再把结果串到下一条（#845 评审）。
    var preparingCountByScope: [ComposerDraftScopeKey: Int] = [:]
    /// 打开预览时附件在附件条里的位置；同一张图加了两次时 id 相同，只能靠位置区分。
    var previewingAttachmentIndex: Int?
    private let dismissStore: ComposerClipboardImageDismissStore

    @MainActor
    init(dismissStore: ComposerClipboardImageDismissStore? = nil) {
        self.dismissStore = dismissStore ?? .shared
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.availableChangeCount == rhs.availableChangeCount
            && lhs.preparingCountByScope == rhs.preparingCountByScope
            && lhs.previewingAttachmentIndex == rhs.previewingAttachmentIndex
            && lhs.dismissStore === rhs.dismissStore
    }

    @MainActor
    var dismissedChangeCount: Int? {
        dismissStore.dismissedChangeCount
    }

    /// 当前应展示给用户的剪贴板计数；结合共享 `dismissStore` 实时计算，
    /// 让并存的输入区在任一处关闭后同步收起。
    @MainActor
    var visibleChangeCount: Int? {
        guard let availableChangeCount, !dismissStore.isDismissed(availableChangeCount) else {
            return nil
        }
        return availableChangeCount
    }

    @MainActor
    var isVisible: Bool {
        visibleChangeCount != nil
    }

    func isPreparing(_ scope: ComposerDraftScopeKey) -> Bool {
        (preparingCountByScope[scope] ?? 0) > 0
    }

    mutating func beginPreparing(_ scope: ComposerDraftScopeKey) {
        preparingCountByScope[scope, default: 0] += 1
    }

    mutating func endPreparing(_ scope: ComposerDraftScopeKey) {
        let next = (preparingCountByScope[scope] ?? 0) - 1
        preparingCountByScope[scope] = next > 0 ? next : nil
    }

    @MainActor
    mutating func refresh(hasImages: Bool, changeCount: Int, acceptsImages: Bool) {
        guard acceptsImages, hasImages, !dismissStore.isDismissed(changeCount) else {
            availableChangeCount = nil
            return
        }
        availableChangeCount = changeCount
    }

    /// 按明确的目标 `changeCount` 记录关闭状态。
    ///
    /// 过期的关闭事件既不会覆盖共享存储中更新的记录，也不会隐藏当前已经刷新出的更新横幅。
    @MainActor
    mutating func dismiss(changeCount: Int) {
        dismissStore.markDismissed(changeCount)
        if let availableChangeCount, dismissStore.isDismissed(availableChangeCount) {
            self.availableChangeCount = nil
        }
    }

    /// 关闭当前可见横幅；不可见时不修改共享记录。
    @MainActor
    mutating func dismissCurrent() {
        guard let targetChangeCount = visibleChangeCount else {
            availableChangeCount = nil
            return
        }
        dismiss(changeCount: targetChangeCount)
    }

    /// 在横幅 `PasteButton` 回调内同步确认并记录目标计数。
    ///
    /// 只有按钮显示时的计数、当前横幅可见计数与此刻剪贴板计数一致时才关闭；
    /// 交接期间计数变化（有歧义）时返回 `false`，保留当前内容的提示不误关。
    @MainActor
    @discardableResult
    mutating func dismissForBannerPaste(
        displayedChangeCount: Int,
        currentPasteboardChangeCount: Int
    ) -> Bool {
        guard visibleChangeCount == displayedChangeCount,
              currentPasteboardChangeCount == displayedChangeCount else {
            return false
        }
        dismiss(changeCount: displayedChangeCount)
        return true
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
    var composerPasteImagesHandler: (([Data], Int) -> Void)? {
        guard acceptsPastedImages else { return nil }
        return { images, pastedChangeCount in
            // 用过的剪贴板内容不再提示；使用读取图片瞬间捕获的 changeCount，
            // 避免横幅仍缓存旧计数时把旧值写进共享记录。
            clipboardImageState.dismiss(changeCount: pastedChangeCount)
            addPastedImageData(images)
        }
    }

    @ViewBuilder
    var clipboardImageNotice: some View {
        if let displayedChangeCount = clipboardImageState.visibleChangeCount, acceptsPastedImages {
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
                    // 在 PasteButton 回调内同步确认目标计数，再启动异步读图任务；
                    // 计数有歧义时不误关当前提示，并刷新到最新剪贴板状态。
                    let confirmed = clipboardImageState.dismissForBannerPaste(
                        displayedChangeCount: displayedChangeCount,
                        currentPasteboardChangeCount: UIPasteboard.general.changeCount
                    )
                    if !confirmed {
                        refreshClipboardImageAvailability()
                    }
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
                    clipboardImageState.dismiss(changeCount: displayedChangeCount)
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
        clipboardImageState.beginPreparing(targetScope)
        Task {
            defer { clipboardImageState.endPreparing(targetScope) }
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
        let index = clipboardImageState.previewingAttachmentIndex
        return { annotated in
            replaceAnnotatedAttachment(item, at: index, with: annotated)
        }
    }

    /// 从附件条打开预览：记住位置，标注完成后替换的是点开的那一份。
    func previewAttachment(_ item: CodexAppServerUserInput, at index: Int) {
        clipboardImageState.previewingAttachmentIndex = index
        previewingAttachment = item
    }

    /// 优先用打开预览时的位置；位置已失效（附件被删或重排）时退回第一份同内容附件。
    static func annotationReplacementIndex(
        in attachments: [CodexAppServerUserInput],
        original: CodexAppServerUserInput,
        preferredIndex: Int?
    ) -> Int? {
        if let preferredIndex,
           attachments.indices.contains(preferredIndex),
           attachments[preferredIndex].id == original.id {
            return preferredIndex
        }
        return attachments.firstIndex { $0.id == original.id }
    }

    /// 标注完成后用新图替换原附件，位置不变；原附件已被移除时不再追加，避免标注结果串到别的草稿。
    func replaceAnnotatedAttachment(_ original: CodexAppServerUserInput, at preferredIndex: Int?, with annotated: UIImage) {
        let targetScope = activeComposerDraftScope
        guard let data = annotated.pngData() else {
            attachmentErrorMessage = L10n.text("ui.image_annotation_failed")
            return
        }
        clipboardImageState.beginPreparing(targetScope)
        Task {
            defer { clipboardImageState.endPreparing(targetScope) }
            do {
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try ImageAttachmentEncoder.prepare(data)
                }.value
                let replacement = CodexAppServerUserInput.image(url: prepared.dataURL, detail: .auto)
                guard targetScope == activeComposerDraftScope,
                      let index = Self.annotationReplacementIndex(
                        in: composerState.attachments,
                        original: original,
                        preferredIndex: preferredIndex
                      ) else {
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
