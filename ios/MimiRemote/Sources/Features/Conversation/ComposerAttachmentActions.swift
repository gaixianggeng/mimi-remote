import AVFoundation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension ComposerView {
    @MainActor
    func consumePendingAddContentAction() {
        guard let action = pendingAddContentAction,
              photoLibraryPickerRequest == nil,
              cameraAttachmentPickerRequest == nil,
              cameraAttachmentAccessIssue == nil,
              !fileImporterPresentation.isPresented,
              !isRequestingCameraAuthorization
        else {
            return
        }
        pendingAddContentAction = nil
        switch action {
        case .camera(let targetScope):
            beginCameraAttachmentCapture(for: targetScope)
        case .photos(let targetScope, let selectionLimit):
            photoLibraryPickerRequest = PhotoLibraryPickerRequest(
                selectionLimit: selectionLimit,
                targetScope: targetScope
            )
        case .files(let targetScope):
            Task {
                let decision = await sessionStore.appStore.refreshCapabilityNegotiationForCurrentHost(
                    capability: "file_upload_v1"
                )
                guard !Task.isCancelled else {
                    return
                }
                guard let capabilityLease = sessionStore.appStore.capabilityLease(
                    for: "file_upload_v1"
                ) else {
                    attachmentErrorMessage = MobileFileUploadError(decision: decision).localizedDescription
                    return
                }
                fileImporterPresentation.present(
                    FileImporterRequest(
                        targetScope: targetScope,
                        capabilityLease: capabilityLease
                    )
                )
            }
        }
    }

    @MainActor
    func beginCameraAttachmentCapture(for targetScope: ComposerDraftScopeKey) {
        guard targetScope != .none,
              remainingImageAttachmentCapacity(for: targetScope) > 0
        else {
            attachmentErrorMessage = targetScope == .none
                ? L10n.text("ui.select_a_workspace_before_adding_files")
                : L10n.format("ui.at_most_images_can_be_added_to_each", Self.maximumImageAttachmentCount)
            return
        }

        switch CameraAttachmentAccess.currentAvailability {
        case .ready:
            cameraAttachmentPickerRequest = CameraAttachmentPickerRequest(targetScope: targetScope)
        case .needsAuthorization:
            requestCameraAttachmentAuthorization(for: targetScope)
        case .denied:
            cameraAttachmentAccessIssue = CameraAttachmentAccessIssue(
                kind: .denied,
                targetScope: targetScope
            )
        case .restricted:
            cameraAttachmentAccessIssue = CameraAttachmentAccessIssue(
                kind: .restricted,
                targetScope: targetScope
            )
        case .unavailable:
            cameraAttachmentAccessIssue = CameraAttachmentAccessIssue(
                kind: .unavailable,
                targetScope: targetScope
            )
        }
    }

    @MainActor
    func requestCameraAttachmentAuthorization(for targetScope: ComposerDraftScopeKey) {
        guard !isRequestingCameraAuthorization else {
            return
        }
        isRequestingCameraAuthorization = true

        Task { @MainActor in
            _ = await CameraAttachmentAccess.requestAccess()
            // TCC 的回调会早于权限弹窗完全退场；等待系统过渡结束后再呈现全屏相机。
            try? await Task.sleep(for: .milliseconds(550))
            isRequestingCameraAuthorization = false

            guard photoLibraryPickerRequest == nil,
                  cameraAttachmentPickerRequest == nil,
                  cameraAttachmentAccessIssue == nil,
                  !fileImporterPresentation.isPresented
            else {
                return
            }

            switch CameraAttachmentAccess.currentAvailability {
            case .ready:
                cameraAttachmentPickerRequest = CameraAttachmentPickerRequest(targetScope: targetScope)
            case .denied, .needsAuthorization:
                cameraAttachmentAccessIssue = CameraAttachmentAccessIssue(
                    kind: .denied,
                    targetScope: targetScope
                )
            case .restricted:
                cameraAttachmentAccessIssue = CameraAttachmentAccessIssue(
                    kind: .restricted,
                    targetScope: targetScope
                )
            case .unavailable:
                cameraAttachmentAccessIssue = CameraAttachmentAccessIssue(
                    kind: .unavailable,
                    targetScope: targetScope
                )
            }
        }
    }

    @MainActor
    func handleCameraAttachmentCapture(
        _ result: Result<Data?, Error>,
        targetScope: ComposerDraftScopeKey
    ) {
        cameraAttachmentPickerRequest = nil

        switch result {
        case .success(nil):
            return
        case .failure(let error):
            attachmentErrorMessage = userFacingAttachmentError(error)
        case .success(.some(let data)):
            Task {
                do {
                    let prepared = try await Task.detached(priority: .userInitiated) {
                        try ImageAttachmentEncoder.prepare(data)
                    }.value
                    let input = CodexAppServerUserInput.image(url: prepared.dataURL, detail: .auto)
                    let addedCount = addPreparedImageAttachments([input], to: targetScope)
                    updateBatchAttachmentNotice(
                        addedCount: addedCount,
                        failedCount: 0,
                        skippedCount: max(0, 1 - addedCount),
                        firstError: nil
                    )
                } catch {
                    attachmentErrorMessage = userFacingAttachmentError(error)
                }
            }
        }
    }

    @MainActor
    func choosePhotosAfterCameraIssue(_ issue: CameraAttachmentAccessIssue) {
        cameraAttachmentAccessIssue = nil

        Task { @MainActor in
            // confirmationDialog 仍在执行关闭动画；稍后再交给 PHPicker，避免 presenter 冲突。
            try? await Task.sleep(for: .milliseconds(350))
            guard photoLibraryPickerRequest == nil,
                  cameraAttachmentPickerRequest == nil,
                  !fileImporterPresentation.isPresented
            else {
                return
            }

            let availableCount = remainingImageAttachmentCapacity(for: issue.targetScope)
            guard issue.targetScope != .none, availableCount > 0 else {
                attachmentErrorMessage = issue.targetScope == .none
                    ? L10n.text("ui.select_a_workspace_before_adding_files")
                    : L10n.format("ui.at_most_images_can_be_added_to_each", Self.maximumImageAttachmentCount)
                return
            }
            photoLibraryPickerRequest = PhotoLibraryPickerRequest(
                selectionLimit: availableCount,
                targetScope: issue.targetScope
            )
        }
    }

    @MainActor
    func openCameraPrivacySettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            return
        }
        UIApplication.shared.open(url)
    }

    func handleSelectedFile(
        _ result: Result<[URL], Error>,
        request: FileImporterRequest
    ) {
        switch result {
        case .failure(let error):
            let nsError = error as NSError
            guard nsError.code != NSUserCancelledError else {
                return
            }
            attachmentErrorMessage = error.localizedDescription
        case .success(let urls):
            guard sessionStore.appStore.isCurrentCapabilityLease(request.capabilityLease) else {
                attachmentErrorMessage = MobileFileUploadError.hostChanged.localizedDescription
                return
            }
            guard let url = urls.first else {
                return
            }
            guard FileAttachmentPreparer.isSupportedFilename(url.lastPathComponent) else {
                attachmentErrorMessage = L10n.text("ui.only_pdf_text_and_source_files_are_supported")
                return
            }
            attachmentErrorMessage = nil
            sessionStore.fileUploadStore.start(
                selectedURL: url,
                targetScope: request.targetScope,
                endpoint: sessionStore.appStore.connectionEndpoint,
                token: sessionStore.appStore.token
            ) { [weak sessionStore] attachment, scope in
                sessionStore?.storeCompletedFileUpload(attachment, for: scope)
            }
        }
    }

    func hasFileAttachment(for scope: ComposerDraftScopeKey) -> Bool {
        func containsFile(_ attachments: [CodexAppServerUserInput]) -> Bool {
            attachments.contains { input in
                if case .uploadedFile = input {
                    return true
                }
                return false
            }
        }
        // 上传完成时 SessionStore 会先写稳定草稿，再发布 completion 给当前 View。
        // 同时检查两处可关闭这一个发布帧内再次选择第二个文件的竞态。
        if scope == activeComposerDraftScope, containsFile(composerState.attachments) {
            return true
        }
        return containsFile(sessionStore.composerDraft(for: scope).attachments)
    }

    func loadPhotoAttachments(
        _ results: [PHPickerResult],
        targetScope: ComposerDraftScopeKey
    ) {
        let availableCount = remainingImageAttachmentCapacity(for: targetScope)
        let selectedResults = Array(results.prefix(availableCount))
        let skippedCount = max(0, results.count - selectedResults.count)
        guard !selectedResults.isEmpty else {
            attachmentErrorMessage = L10n.format("ui.at_most_images_can_be_added_to_each", Self.maximumImageAttachmentCount)
            return
        }

        Task {
            var preparedInputs: [CodexAppServerUserInput] = []
            var failedCount = 0
            var firstError: Error?

            // 串行读取和下采样，避免多张 iPad 截图同时完整解码造成瞬时内存峰值。
            for result in selectedResults {
                do {
                    let data = try await Self.loadImageData(from: result.itemProvider)
                    let prepared = try await Task.detached(priority: .userInitiated) {
                        try ImageAttachmentEncoder.prepare(data)
                    }.value
                    preparedInputs.append(.image(url: prepared.dataURL, detail: .auto))
                } catch {
                    failedCount += 1
                    firstError = firstError ?? error
                }
            }

            let addedCount = addPreparedImageAttachments(preparedInputs, to: targetScope)
            updateBatchAttachmentNotice(
                addedCount: addedCount,
                failedCount: failedCount,
                skippedCount: skippedCount + max(0, preparedInputs.count - addedCount),
                firstError: firstError
            )
        }
    }

    static func loadImageData(from provider: NSItemProvider) async throws -> Data {
        guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else {
            throw PhotoLibraryPickerError.unsupportedImage
        }

        return try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: PhotoLibraryPickerError.unreadableImage)
                }
            }
        }
    }

    @MainActor
    func addPreparedImageAttachments(
        _ inputs: [CodexAppServerUserInput],
        to targetScope: ComposerDraftScopeKey
    ) -> Int {
        guard targetScope != .none, !inputs.isEmpty else {
            return 0
        }

        if targetScope == activeComposerDraftScope {
            let allowed = Array(inputs.prefix(remainingImageAttachmentCapacity(in: composerState.attachments)))
            composerState.attachments.append(contentsOf: allowed)
            // 异步图片任务可能在旧 ComposerView 已消失后才完成，必须直接写稳定仓，不能只依赖 onChange。
            sessionStore.saveComposerDraft(composerState.draftSnapshot(), for: targetScope)
            return allowed.count
        }

        // 图片处理期间如果用户切了会话，结果仍写回发起选择时的草稿，不能串到当前会话。
        var snapshot = sessionStore.composerDraft(for: targetScope)
        let allowed = Array(inputs.prefix(remainingImageAttachmentCapacity(in: snapshot.attachments)))
        snapshot.attachments.append(contentsOf: allowed)
        sessionStore.saveComposerDraft(snapshot, for: targetScope)
        return allowed.count
    }

    func remainingImageAttachmentCapacity(for scope: ComposerDraftScopeKey) -> Int {
        if scope == activeComposerDraftScope {
            return remainingImageAttachmentCapacity(in: composerState.attachments)
        }
        return remainingImageAttachmentCapacity(in: sessionStore.composerDraft(for: scope).attachments)
    }

    func remainingImageAttachmentCapacity(in attachments: [CodexAppServerUserInput]) -> Int {
        let imageCount = attachments.reduce(into: 0) { count, input in
            switch input {
            case .image, .localImage:
                count += 1
            case .text, .uploadedFile, .skill, .mention:
                break
            }
        }
        return max(0, Self.maximumImageAttachmentCount - imageCount)
    }

    @MainActor
    func updateBatchAttachmentNotice(
        addedCount: Int,
        failedCount: Int,
        skippedCount: Int,
        firstError: Error?
    ) {
        if failedCount == 0, skippedCount == 0 {
            attachmentErrorMessage = nil
        } else if addedCount > 0 {
            let omitted = failedCount + skippedCount
            attachmentErrorMessage = L10n.format("ui.pictures_have_been_added_and_have_not_been", addedCount, omitted)
        } else if skippedCount > 0, failedCount == 0 {
            attachmentErrorMessage = L10n.format("ui.at_most_images_can_be_added_to_each", Self.maximumImageAttachmentCount)
        } else if let firstError {
            attachmentErrorMessage = userFacingAttachmentError(firstError)
        } else {
            attachmentErrorMessage = L10n.text("ui.image_reading_failed")
        }
    }

    func canPreviewAttachment(_ item: CodexAppServerUserInput) -> Bool {
        switch item {
        case .image, .localImage, .uploadedFile:
            return true
        case .text, .skill, .mention:
            return false
        }
    }

    func userFacingAttachmentError(_ error: Error) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? L10n.text("ui.image_reading_failed") : L10n.format("ui.image_reading_failed_20ce920a", message)
    }

    func attachmentSymbol(for item: CodexAppServerUserInput) -> String {
        switch item {
        case .image, .localImage:
            return "photo"
        case .uploadedFile:
            return "doc"
        case .skill:
            return "wand.and.stars"
        case .mention:
            return "at"
        case .text:
            return "text.alignleft"
        }
    }
}

enum VoiceInputToggleAction: Equatable {
    case start
    case end
    case ignore

    static func resolve(
        isPressActive: Bool,
        isPreparing: Bool,
        isRecording: Bool,
        isTranscribing: Bool
    ) -> Self {
        if isTranscribing {
            return .ignore
        }
        if isPressActive || isPreparing || isRecording {
            return .end
        }
        return .start
    }
}
