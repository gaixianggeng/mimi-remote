import AVFoundation
import AudioToolbox
import ImageIO
import PhotosUI
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum VoiceTranscriptionDefaults {
    // 语音识别跟随系统首选语言，避免英文系统仍以中文模型转写。
    static var languageCode: String {
        Locale.autoupdatingCurrent.language.languageCode?.identifier ?? "en"
    }
}

struct ComposerView: View {
    // 相关实现按职责分布在 Composer* 扩展文件中；这些成员保持 module-internal，
    // 仅用于跨文件扩展协作，不构成对外 API。
    @EnvironmentObject var sessionStore: SessionStore
    @EnvironmentObject var themeStore: ThemeStore
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.colorSchemeContrast) var colorSchemeContrast
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @Environment(\.dynamicTypeSize) var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    @State var composerState = ComposerState()
    @State var activeComposerDraftScope = ComposerDraftScopeKey.none
    @State var composerTextExternalRevision = 0
    @StateObject var voiceInput = VoiceInputController()
    @State var photoLibraryPickerRequest: PhotoLibraryPickerRequest?
    @State var cameraAttachmentPickerRequest: CameraAttachmentPickerRequest?
    @State var cameraAttachmentAccessIssue: CameraAttachmentAccessIssue?
    @State var isRequestingCameraAuthorization = false
    @State var fileImporterPresentation = FileImporterPresentationState()
    @State var pendingAddContentAction: PendingAddContentAction?
    @State var showsAddContentPanel = false
    @State var showsSkillPicker = false
    @State var showsModelGridPicker = false
    @State var showsManualSkillInputSheet = false
    @State var showsAdvancedOptionsSheet = false
    @State var previewingAttachment: CodexAppServerUserInput?
    @State var goalEditor: ThreadGoalEditorDraft?
    @State var presentedPendingUserInput: PendingUserInputPresentation?
    @State var pendingUserInputFormState = PendingUserInputFormState()
    @State var isGoalStatusExpanded = false
    @State var attachmentErrorMessage: String?
    @State var isVoicePressActive = false
    @State var isVoiceTranscribing = false
    @State var voiceTranscriptionTask: Task<Void, Never>?
    @State var activeVoiceTranscriptionContext: VoiceTranscriptionContext?
    @State var retryableVoiceTranscription: RetryableVoiceTranscription?
    @State var measuredComposerTextHeight: CGFloat = 0
    @State var isComposerTextComposing = false
    @State var composerTextSubmitBridge = ComposerTextSubmitBridge()
    @State var composerTextFocusRequestID: UUID?
    // 收起状态只服务 iPad 的显式操作；iPhone 始终保留可直接编辑的一行输入。
    @State var isComposerCollapsed: Bool
    @State var activeSkillQuery: ComposerSkillQuery?
    @State var selectedSkillSuggestionIndex = 0
    @AppStorage("agentd.developerMode") var developerModeEnabled = false
    @AppStorage(ComposerPermissionMode.defaultStorageKey) var defaultPermissionModeID = ComposerPermissionMode.defaultMode.rawValue
    @AppStorage(VoiceInputProvider.storageKey) var voiceInputProviderRawValue = VoiceInputProvider.codex.rawValue
    @State var guidedFollowUpEnabled = false
    @State var editingQueuedTurn: QueuedTurnEditorDraft?
    @State var showsQueuedTurnManager = false
    @State var isSelectingVoiceDraftText = false

    var availableWidth: CGFloat?

    init(
        availableWidth: CGFloat? = nil,
        initialGoalStatusExpanded: Bool = false,
        initialComposerCollapsed: Bool? = nil
    ) {
        self.availableWidth = availableWidth
        _isGoalStatusExpanded = State(initialValue: initialGoalStatusExpanded)
        _isComposerCollapsed = State(initialValue: initialComposerCollapsed ?? false)
    }

    static let minimumUsableVoiceDuration: TimeInterval = 0.35
    static let maximumImageAttachmentCount = 8

    var composerMotionAnimation: Animation {
        MimiMotion.stateTransition.animation(reduceMotion: reduceMotion)
    }

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        // 外层保持透明，由底部输入面板承担唯一主表面；面板内部依靠实色和间距分组，
        // 不再叠加玻璃材质、键帽高光或投影。
        let presentedContent = VStack(alignment: .leading, spacing: 10) {
            queuedTurnTray
            // iPhone 把会话状态并入唯一 Composer 外壳；iPad 继续使用独立托盘，
            // 保留宽屏上的信息密度与既有收起布局。
            if !isPhoneComposer {
                composerStatusTray
            }
            pendingApprovalAction
            pendingUserInputAction
            voiceErrorMessage
            voiceNoticeMessage
            attachmentErrorNotice
            FileUploadJobsStrip(store: sessionStore.fileUploadStore, scope: activeComposerDraftScope)
                .environmentObject(themeStore)
            attachmentStrip
            composerStatusRow
            composerInputRow(tokens: tokens)
        }
        // 零尺寸键盘快捷键不能作为 VStack 的 arranged child：即使自身是 0×0，
        // 它仍会吃掉一段 spacing，让 iPhone 输入卡无故悬高 10pt。
        .background(alignment: .topLeading) {
            voiceKeyboardShortcutButton
                .overlay {
                    composerKeyboardShortcutButtons
                }
        }
        .sheet(isPresented: $showsManualSkillInputSheet) {
            ManualSkillInputSheet { input in
                composerState.addAttachment(input)
            }
        }
        .sheet(isPresented: $showsAdvancedOptionsSheet) {
            AdvancedTurnOptionsSheet(options: composerState.turnOptions) { options in
                composerState.updateTurnOptions { $0 = options }
            }
        }
        .sheet(item: $previewingAttachment) { item in
            AttachmentPreviewSheet(item: item)
                .environmentObject(themeStore)
        }
        .sheet(item: $goalEditor) { draft in
            ThreadGoalEditorSheet(draft: draft)
                .environmentObject(sessionStore)
                .environmentObject(themeStore)
        }
        .sheet(item: $presentedPendingUserInput) { presentation in
            PendingUserInputSheet(
                presentation: presentation,
                isSubmitting: sessionStore.isUserInputResponsePending(presentation.request),
                draft: pendingUserInputDraftBinding,
                onSubmit: { answers in
                    sessionStore.respondToUserInput(presentation.request, answers: answers)
                }
            )
            .environmentObject(themeStore)
        }
        .sheet(item: $editingQueuedTurn) { draft in
            QueuedTurnEditorSheet(draft: draft) { payload in
                _ = sessionStore.updateQueuedTurn(
                    clientMessageID: draft.id,
                    payload: payload
                )
            }
            .environmentObject(themeStore)
        }
        .sheet(isPresented: $showsQueuedTurnManager) {
            QueuedTurnManagerSheet(
                turns: sessionStore.selectedQueuedTurns,
                canGuideCurrentTurn: canUseGuidedFollowUp,
                onUpdate: { turn, payload in
                    _ = sessionStore.updateQueuedTurn(clientMessageID: turn.id, payload: payload)
                },
                onDelete: { _ = sessionStore.deleteQueuedTurn(clientMessageID: $0.id) },
                onRetry: { _ = sessionStore.retryQueuedTurn(clientMessageID: $0.id) },
                onGuideNow: { _ = sessionStore.guideQueuedTurnNow(clientMessageID: $0.id) },
                onMove: { source, destination in
                    _ = sessionStore.moveSelectedQueuedTurns(fromOffsets: source, toOffset: destination)
                }
            )
            .environmentObject(themeStore)
        }
        .sheet(item: $photoLibraryPickerRequest) { request in
            PhotoLibraryPicker(selectionLimit: request.selectionLimit) { results in
                photoLibraryPickerRequest = nil
                guard !results.isEmpty else {
                    return
                }
                loadPhotoAttachments(results, targetScope: request.targetScope)
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(item: $cameraAttachmentPickerRequest) { request in
            CameraAttachmentPicker { result in
                handleCameraAttachmentCapture(result, targetScope: request.targetScope)
            }
            .ignoresSafeArea()
        }
        .fileImporter(
            isPresented: $fileImporterPresentation.isPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            guard let request = fileImporterPresentation.consumeRequest() else {
                return
            }
            handleSelectedFile(result, request: request)
        }
        .confirmationDialog(
            cameraAttachmentAccessIssue?.title ?? "",
            isPresented: Binding(
                get: { cameraAttachmentAccessIssue != nil },
                set: { isPresented in
                    if !isPresented {
                        cameraAttachmentAccessIssue = nil
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: cameraAttachmentAccessIssue
        ) { issue in
            Button(L10n.text("ui.choose_photos")) {
                choosePhotosAfterCameraIssue(issue)
            }
            if issue.canOpenSettings {
                Button(L10n.text("ui.open_settings")) {
                    cameraAttachmentAccessIssue = nil
                    openCameraPrivacySettings()
                }
            }
            Button(L10n.text("ui.cancel"), role: .cancel) {
                cameraAttachmentAccessIssue = nil
            }
        } message: { issue in
            Text(issue.message)
        }

        let scopeObservedContent = presentedContent
        .onChange(of: developerModeEnabled) { _, enabled in
            guard !enabled else {
                return
            }
            composerState.updateTurnOptions { options in
                options = options.sanitizedForStandardComposer()
                normalizeModelControlsForStandardComposer(&options)
            }
            showsAdvancedOptionsSheet = false
        }
        .onChange(of: defaultPermissionModeID) { _, _ in
            applyDefaultPermissionModeForActiveScope()
        }
        .onChange(of: voiceInputProviderRawValue) { _, _ in
            // 提供方变化是语音会话边界；旧引擎的迟到结果不能写入新选择下的草稿。
            cancelVoiceInteraction(clearStatus: true)
        }
        .onChange(of: currentComposerDraftScope) { _, newScope in
            switchComposerDraftScope(to: newScope)
            Task { @MainActor in
                await refreshPermissionProfilesForCurrentCWD()
            }
        }
        .onChange(of: pendingUserInputSelectionIdentity) { previous, current in
            synchronizePendingUserInputPresentation(previous: previous, current: current)
        }

        let observedContent = scopeObservedContent
        .onChange(of: composerState.draftSnapshot()) { _, snapshot in
            // 每次确认文字或附件变化都写入稳定内存仓，视图突然重建时也能恢复最新草稿。
            sessionStore.saveComposerDraft(snapshot, for: activeComposerDraftScope)
        }
        .onChange(of: composerState.modelSelectionSnapshot()) { _, snapshot in
            // 模型偏好独立于正文保存；空输入、发送成功和视图重建都不能清掉会话选择。
            sessionStore.saveComposerModelSelection(snapshot, for: activeComposerDraftScope)
        }
        .onChange(of: sessionStore.latestFileUploadCompletion) { _, completion in
            guard let completion,
                  completion.targetScope == activeComposerDraftScope,
                  !composerState.attachments.contains(where: {
                      $0.id == "uploadedFile:\(completion.attachment.uploadID)"
                  })
            else {
                return
            }
            composerState.addAttachment(.uploadedFile(completion.attachment))
        }
        .onChange(of: selectedSessionRuntimeProviderForModelMenu) { _, _ in
            // 会话 scope 的 onChange 可能稍晚到达。此时仍显示旧 Composer，不能先用新
            // runtime 改写并保存旧会话的模型；scope 切换完成后会统一恢复并校验。
            guard activeComposerDraftScope == currentComposerDraftScope else {
                return
            }
            clampModelSelectionToSelectedSessionRuntime()
            clampPermissionSelectionToSelectedSessionRuntime()
        }
        .onChange(of: modelOptionsForMenu) { _, _ in
            // model/list 刷新后能力元数据可能变化；立即清理当前模型已不支持的推理强度。
            guard activeComposerDraftScope == currentComposerDraftScope else {
                return
            }
            clampModelSelectionToSelectedSessionRuntime()
        }

        return observedContent
        .onChange(of: canUseGuidedFollowUp) { _, canGuide in
            if !canGuide {
                guidedFollowUpEnabled = false
            }
        }
        .onChange(of: sessionStore.selectedSessionID) { _, _ in
            // 引导是只对当前正在生成的回复生效的一次性选择。切换会话后恢复安全的
            // 默认排队，避免把上一条会话的发送意图意外带到另一条运行中会话。
            guidedFollowUpEnabled = false
        }
        .onChange(of: sessionStore.selectedThreadGoal) { previousGoal, goal in
            syncGoalStatusBarExpansion(from: previousGoal, to: goal)
        }
        .task(id: voiceInput.errorMessage) {
            await autoDismissVoiceErrorIfNeeded(voiceInput.errorMessage)
        }
        .onAppear {
            switchComposerDraftScope(to: currentComposerDraftScope)
            restorePendingUserInputFormStateFromCache()
            synchronizePendingUserInputPresentation(previous: nil, current: pendingUserInputSelectionIdentity)
            clampModelSelectionToSelectedSessionRuntime()
            clampPermissionSelectionToSelectedSessionRuntime()
        }
        .task {
            await prepareComposer()
        }
        .onDisappear {
            synchronizeComposerTextBeforeDraftScopeChange()
            sessionStore.saveComposerDraft(composerState.draftSnapshot(), for: activeComposerDraftScope)
            sessionStore.saveComposerModelSelection(
                composerState.modelSelectionSnapshot(),
                for: activeComposerDraftScope
            )
            sessionStore.saveComposerPermissionSelection(
                composerState.permissionSelectionSnapshot(),
                for: activeComposerDraftScope
            )
            cancelVoiceInteraction(clearStatus: true)
            activeSkillQuery = nil
        }
    }

    @MainActor
    private func prepareComposer() async {
        switchComposerDraftScope(to: currentComposerDraftScope)
        clampModelSelectionToSelectedSessionRuntime()
        restoreComposerPermissionSelection(for: currentComposerDraftScope)
        voiceInput.prewarm()
        await sessionStore.refreshAppServerModelOptions()
        await sessionStore.refreshCapabilities()
        await refreshPermissionProfilesForCurrentCWD()
    }

    @MainActor
    private func refreshPermissionProfilesForCurrentCWD() async {
        let requestedCWD = permissionProfileCWD
        await sessionStore.refreshPermissionProfiles(cwd: requestedCWD)
        guard !Task.isCancelled,
              requestedCWD == permissionProfileCWD,
              sessionStore.permissionProfilesCWD == requestedCWD
        else { return }
        clampPermissionProfileToAvailableOptions()
    }

    @discardableResult
    func submitDraft() -> Bool {
        guard synchronizeComposerTextBeforeSubmit() else {
            return false
        }
        guard !sessionStore.fileUploadStore.hasBlockingJob(for: activeComposerDraftScope) else {
            attachmentErrorMessage = L10n.text("ui.wait_for_file_upload_to_complete")
            return false
        }
        let pendingPayload = CodexAppServerTurnPayload(
            input: CodexAppServerTurnPayload.defaultInput(for: composerState.draft) + composerState.attachments
        )
        guard pendingPayload.encodedAppServerInputByteCount <= CodexAppServerTurnPayload.maximumEncodedInputBytes else {
            attachmentErrorMessage = L10n.text("ui.message_attachments_are_too_large")
            return false
        }
        if composerState.isGoalModeSelected {
            return submitGoalDraft()
        }
        let submittedDraftScope = activeComposerDraftScope
        let options = preparedTurnOptionsForSubmit()
        guard let submitted = composerState.takeDraftForSubmit(isLoading: sessionStore.isLoading, turnOptionsOverride: options) else {
            return false
        }
        resetPhoneComposerAfterSubmit()
        sessionStore.removeComposerDraft(for: submittedDraftScope)
        let runningDelivery = runningTurnDeliveryForSubmit
        cancelVoiceInteraction(clearStatus: false)
        clearVoiceTransientStatus()
        Task {
            let accepted = await sessionStore.sendTurn(submitted.payload, runningDelivery: runningDelivery)
            if !accepted {
                await MainActor.run {
                    restoreSubmittedDraft(submitted, originalScope: submittedDraftScope)
                }
            } else {
                await MainActor.run {
                    // 提交时已经同步清过对应 cache。这里不能再次删除，否则发送期间
                    // 输入的下一条草稿会被成功回调误删。
                    guidedFollowUpEnabled = false
                    resetComposerSendModeAfterSubmit()
                }
            }
        }
        return true
    }

    @discardableResult
    func submitGoalDraft() -> Bool {
        var options = preparedTurnOptionsForSubmit()
        // 目标模式不是 Plan Mode：目标元数据走 thread/goal/set，turn/start 仍显式声明 default，
        // 防止 app-server 沿用上一轮规划协作状态。
        options.collaborationMode = .default
        let submittedDraftScope = activeComposerDraftScope
        guard let submitted = composerState.takeDraftForSubmit(
            isLoading: sessionStore.isLoading || sessionStore.isUpdatingThreadGoal,
            turnOptionsOverride: options
        ) else {
            return false
        }
        resetPhoneComposerAfterSubmit()
        sessionStore.removeComposerDraft(for: submittedDraftScope)
        let objective = submitted.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !objective.isEmpty else {
            composerState.restore(submitted)
            sessionStore.saveComposerDraft(composerState.draftSnapshot(), for: submittedDraftScope)
            return false
        }
        let runningDelivery = runningTurnDeliveryForSubmit
        cancelVoiceInteraction(clearStatus: false)
        clearVoiceTransientStatus()
        Task {
            let accepted = await sessionStore.startGoalTurn(
                payload: submitted.payload,
                objective: objective,
                runningDelivery: runningDelivery
            )
            if !accepted {
                await MainActor.run {
                    restoreSubmittedDraft(submitted, originalScope: submittedDraftScope)
                }
            } else {
                await MainActor.run {
                    // 与普通发送保持一致：成功回调不二次触碰草稿 cache。
                    guidedFollowUpEnabled = false
                    resetComposerSendModeAfterSubmit()
                }
            }
        }
        return true
    }

    func synchronizeComposerTextBeforeSubmit() -> Bool {
        guard let snapshot = composerTextSubmitBridge.finalSnapshotForSubmit() else {
            return true
        }
        if composerState.draft != snapshot.text {
            // 只在提交边界同步 UIKit 最终文本，输入过程中仍维持单向的低频状态回写。
            composerState.draft = snapshot.text
        }
        isComposerTextComposing = false
        activeSkillQuery = nil
        selectedSkillSuggestionIndex = 0
        return true
    }

    var currentComposerDraftScope: ComposerDraftScopeKey {
        ComposerDraftScopeKey.current(
            selectedSessionID: sessionStore.selectedSessionID,
            selectedProjectID: sessionStore.selectedProjectID
        )
    }

    func switchComposerDraftScope(to nextScope: ComposerDraftScopeKey) {
        guard activeComposerDraftScope != nextScope else {
            return
        }
        let previousScope = activeComposerDraftScope
        let isOptimisticHandoff = isOptimisticSessionHandoff(from: previousScope, to: nextScope)
        let restoredSendMode = sessionStore.composerSendModeForScopeActivation(
            previousScope: previousScope,
            nextScope: nextScope,
            currentMode: composerState.sendMode,
            isOptimisticSessionHandoff: isOptimisticHandoff
        )
        synchronizeComposerTextBeforeDraftScopeChange()
        let outgoingDraft = composerState.draftSnapshot()
        let outgoingModelSelection = composerState.modelSelectionSnapshot()
        let outgoingPermissionSelection = composerState.permissionSelectionSnapshot()
        sessionStore.saveComposerDraft(outgoingDraft, for: previousScope)
        sessionStore.saveComposerModelSelection(outgoingModelSelection, for: previousScope)
        sessionStore.saveComposerPermissionSelection(outgoingPermissionSelection, for: previousScope)
        if isOptimisticHandoff {
            // local:* 只是创建接口返回前的临时身份。服务端 ID 回来时迁移当前可见草稿，
            // 避免用户正在输入的追加指令和模型选择被新 scope 的默认值覆盖。
            sessionStore.saveComposerDraft(outgoingDraft, for: nextScope)
            sessionStore.saveComposerModelSelection(outgoingModelSelection, for: nextScope)
            sessionStore.saveComposerPermissionSelection(outgoingPermissionSelection, for: nextScope)
            sessionStore.removeComposerDraft(for: previousScope)
            sessionStore.removeComposerModelSelection(for: previousScope)
            sessionStore.removeComposerPermissionSelection(for: previousScope)
        }
        cancelVoiceInteraction(clearStatus: true)

        // 先切 scope 再恢复，避免 restore 触发的 onChange 把新会话草稿误写回旧 scope。
        activeComposerDraftScope = nextScope
        composerState.setSendMode(restoredSendMode)
        persistComposerSendMode(restoredSendMode, for: nextScope)
        composerState.restoreDraftSnapshot(sessionStore.composerDraft(for: nextScope))
        restoreComposerModelSelection(for: nextScope)
        restoreComposerPermissionSelection(for: nextScope)
        clampModelSelectionToSelectedSessionRuntime()
        composerTextExternalRevision += 1
        guidedFollowUpEnabled = false
        measuredComposerTextHeight = 0
        isComposerTextComposing = false
        // iPad 的收起是用户对当前会话输入画布的显式选择；切会话时不自动改写。
        // iPhone 复用同一个编辑器，外部 revision 会把新会话草稿同步进 TextKit。
    }

    func isOptimisticSessionHandoff(
        from previousScope: ComposerDraftScopeKey,
        to nextScope: ComposerDraftScopeKey
    ) -> Bool {
        guard case .session(let previousSessionID) = previousScope,
              case .session(let nextSessionID) = nextScope
        else {
            return false
        }
        return previousSessionID.hasPrefix("local:") && !nextSessionID.hasPrefix("local:")
    }

    func persistComposerSendMode(_ mode: ComposerSendMode, for scope: ComposerDraftScopeKey) {
        sessionStore.saveComposerSendMode(mode, for: scope)
    }

    func restoreComposerModelSelection(for scope: ComposerDraftScopeKey) {
        if let snapshot = sessionStore.composerModelSelection(for: scope) {
            composerState.restoreModelSelectionSnapshot(snapshot)
            return
        }

        let runtimeProvider = selectedSessionRuntimeProviderForModelMenu
            ?? normalizedRuntimeProvider(composerState.turnOptions.runtimeProvider)
        composerState.updateTurnOptions { options in
            applyPreferredDefaultModel(runtimeProvider: runtimeProvider, to: &options)
        }
    }

    func restoreComposerPermissionSelection(for scope: ComposerDraftScopeKey) {
        if let snapshot = sessionStore.composerPermissionSelection(for: scope) {
            composerState.restorePermissionSelectionSnapshot(snapshot)
        } else if case .session(let sessionID) = scope,
                  !sessionID.hasPrefix("local:"),
                  selectedSessionRuntimeProviderForModelMenu != "claude" {
            composerState.preserveThreadPermissionSettings()
        } else {
            applyDefaultPermissionMode()
        }
        sessionStore.saveComposerPermissionSelection(
            composerState.permissionSelectionSnapshot(),
            for: scope
        )
    }

    func resetComposerSendModeAfterSubmit() {
        composerState.resetSendModeAfterSubmit()
        persistComposerSendMode(.standard, for: activeComposerDraftScope)
    }

    func synchronizeComposerTextBeforeDraftScopeChange() {
        guard let snapshot = composerTextSubmitBridge.snapshotForSubmit() else {
            return
        }
        if snapshot.isComposing {
            // resize/切会话时即使仍在输入法候选态，也保留当前可见文本；恢复拼音比静默丢失整个草稿更安全。
            isComposerTextComposing = true
        }
        if composerState.draft != snapshot.text {
            composerState.draft = snapshot.text
        }
        if isComposerTextComposing && !snapshot.isComposing {
            isComposerTextComposing = false
        }
    }

    @MainActor
    func restoreSubmittedDraft(_ submitted: SubmittedComposerDraft, originalScope: ComposerDraftScopeKey) {
        let restoreScope = submittedDraftRestoreScope(originalScope: originalScope)
        if restoreScope == activeComposerDraftScope {
            guard composerState.canRestore(submitted) else {
                return
            }
            composerState.restore(submitted)
        } else {
            sessionStore.saveComposerDraft(ComposerDraftSnapshot(submitted: submitted), for: restoreScope)
        }
    }

    func submittedDraftRestoreScope(originalScope: ComposerDraftScopeKey) -> ComposerDraftScopeKey {
        // 新建会话提交时会先进入 local:<project>:<client_message_id> 乐观会话；
        // 如果创建失败，草稿应回到这个用户正在看的失败会话，而不是藏回项目入口。
        if case .session(let sessionID) = activeComposerDraftScope,
           sessionID.hasPrefix("local:") || sessionStore.selectedSession?.source == "local" {
            return activeComposerDraftScope
        }
        return originalScope
    }

    func preparedTurnOptionsForSubmit() -> CodexAppServerTurnOptions {
        var options = developerModeEnabled ? composerState.turnOptions : composerState.turnOptions.sanitizedForStandardComposer()
        options.modelSelectionPolicy = developerModeEnabled ? .allowUnlisted : .catalogOnly
        if developerModeEnabled,
           let effort = options.reasoningEffort,
           !supportsReasoningEffort(effort, modelID: options.model ?? effectiveModelID) {
            // 提交边界再做一次兜底，避免模型列表刷新与点击发送之间的竞态把非法组合发给 runtime。
            options.reasoningEffort = nil
        } else if !developerModeEnabled {
            normalizeModelControlsForStandardComposer(&options)
        }
        if composerState.isPlanModeSelected {
            options.collaborationMode = .plan
        } else {
            // 普通发送也必须显式退出 Plan Mode，不能依赖 nil/absent。
            options.collaborationMode = .default
        }
        return options
    }

    var canChooseRunningFollowUpDelivery: Bool {
        guard let session = sessionStore.selectedSession else {
            return false
        }
        return session.isRunning &&
            composerState.sendMode == .standard &&
            sessionStore.canControlSession(session)
    }

    var canUseGuidedFollowUp: Bool {
        guard let session = sessionStore.selectedSession else {
            return false
        }
        return canChooseRunningFollowUpDelivery && session.activeTurnID != nil
    }

    var runningTurnDeliveryForSubmit: RunningTurnDelivery {
        composerState.runningTurnDelivery(
            canUseGuidedFollowUp: canUseGuidedFollowUp,
            guidedFollowUpEnabled: guidedFollowUpEnabled
        )
    }

    var canSubmitDraft: Bool {
        if composerState.isGoalModeSelected {
            return canSubmitGoalDraft
        }
        return sessionStore.canSendInSelectedSession
            && hasComposerContentForSubmit
            && !sessionStore.isLoading
            && !sessionStore.fileUploadStore.hasBlockingJob(for: activeComposerDraftScope)
    }

    var canSubmitGoalDraft: Bool {
        sessionStore.canSendInSelectedSession
            && hasNonWhitespaceComposerTextForSubmit
            && !sessionStore.isLoading
            && !sessionStore.isUpdatingThreadGoal
            && !sessionStore.fileUploadStore.hasBlockingJob(for: activeComposerDraftScope)
    }

    var hasNonWhitespaceComposerTextForSubmit: Bool {
        composerState.hasNonWhitespaceDraft
            || (isComposerTextComposing && composerTextSubmitBridge.hasNonWhitespaceTextForSubmit())
    }

    var hasComposerContentForSubmit: Bool {
        hasNonWhitespaceComposerTextForSubmit || !composerState.attachments.isEmpty
    }

    var usesCompactComposerMetrics: Bool {
        ConversationLayout.usesCompactComposerMetrics(
            availableWidth: availableWidth,
            horizontalSizeClass: horizontalSizeClass
        )
    }


    @ViewBuilder
    var queuedTurnTray: some View {
        let turns = sessionStore.selectedQueuedTurns
        if !turns.isEmpty || sessionStore.queuedTurnStorageErrorMessage != nil {
            let tokens = themeStore.tokens(for: colorScheme)
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "tray.full")
                        .foregroundStyle(tokens.accent)
                    Text(L10n.plural("ui.items_to_send_count", count: turns.count))
                        .font(themeStore.uiFont(.caption, weight: .semibold))
                        .foregroundStyle(tokens.primaryText)
                    Text(L10n.text("ui.save_on_this_device"))
                        .font(themeStore.uiFont(.caption2, weight: .medium))
                        .foregroundStyle(tokens.tertiaryText)
                    Spacer(minLength: 4)
                    if turns.count > 1 {
                        Button(L10n.text("ui.manage")) {
                            showsQueuedTurnManager = true
                        }
                        .buttonStyle(.borderless)
                        .font(themeStore.uiFont(.caption, weight: .semibold))
                    }
                }

                ForEach(Array(turns.prefix(queuedTurnPreviewLimit))) { turn in
                    queuedTurnRow(turn, tokens: tokens)
                }

                if let message = sessionStore.queuedTurnStorageErrorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(themeStore.uiFont(.caption2, weight: .medium))
                        .foregroundStyle(tokens.warning)
                        .lineLimit(2)
                }
            }
            .padding(10)
            // 待发送内容悬浮在正文上方，复用输入框的模糊材质，避免高对比文字穿透后叠字。
            // 圆角略小于主输入框，保留二级浮层层级，不与主要输入操作争夺注意力。
            .background {
                composerContainerBackground(shape: shape, tokens: tokens)
            }
            .overlay {
                shape.strokeBorder(tokens.border.opacity(0.58), lineWidth: 0.75)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .contain)
        }
    }

    var queuedTurnPreviewLimit: Int {
        usesCompactComposerMetrics ? 2 : 3
    }

    func queuedTurnRow(_ turn: QueuedTurnEntry, tokens: ThemeTokens) -> some View {
        HStack(spacing: 9) {
            Image(systemName: turn.displayIcon)
                .font(themeStore.uiFont(.caption, weight: .semibold))
                .foregroundStyle(turn.displayTint(tokens: tokens))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(turn.previewText.isEmpty ? L10n.text("ui.accessories_only") : turn.previewText)
                    .font(themeStore.uiFont(.caption, weight: .medium))
                    .foregroundStyle(tokens.primaryText)
                    .lineLimit(1)
                Text(turn.displayStatusText)
                    .font(themeStore.uiFont(.caption2, weight: .medium))
                    .foregroundStyle(turn.displayTint(tokens: tokens))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                Button {
                    editingQueuedTurn = QueuedTurnEditorDraft(turn: turn)
                } label: {
                    Label(L10n.text("ui.edit"), systemImage: "pencil")
                }
                .disabled(turn.dispatchState == .dispatching)

                if turn.intent.canGuideCurrentTurn {
                    Button {
                        _ = sessionStore.guideQueuedTurnNow(clientMessageID: turn.id)
                    } label: {
                        Label(L10n.text("ui.direct_current_reply_now"), systemImage: "text.bubble")
                    }
                    .disabled(!canUseGuidedFollowUp || turn.dispatchState != .waiting)
                }

                if turn.dispatchState == .needsConfirmation {
                    Button {
                        _ = sessionStore.retryQueuedTurn(clientMessageID: turn.id)
                    } label: {
                        Label(L10n.text("ui.confirm_and_try_again"), systemImage: "arrow.clockwise")
                    }
                }

                Divider()
                Button(role: .destructive) {
                    _ = sessionStore.deleteQueuedTurn(clientMessageID: turn.id)
                } label: {
                    Label(L10n.text("ui.delete"), systemImage: "trash")
                }
                .disabled(turn.dispatchState == .dispatching)
            } label: {
                Image(systemName: "ellipsis")
                    .font(themeStore.uiFont(.caption, weight: .semibold))
                    .foregroundStyle(tokens.secondaryText)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(L10n.text("ui.message_operation_to_be_sent"))
        }
        .padding(.leading, 2)
    }


    @ViewBuilder
    var composerStatusTray: some View {
        let visibleGoal = selectedVisibleThreadGoal
        let usageNotice = selectedComposerUsageNotice
        if sessionStore.selectedSessionControlNotice != nil ||
            usageNotice != nil ||
            visibleGoal != nil {
            ComposerStatusTray(
                sessionControlNotice: sessionStore.selectedSessionControlNotice,
                // 阻断额度已经由 Conversation 顶部唯一状态区展示，Composer 不再重复一份。
                quotaNotice: nil,
                usage: usageNotice,
                goal: visibleGoal,
                placement: isPhoneComposer ? .embedded : .standalone,
                isGoalExpanded: isGoalStatusExpanded,
                isGoalUpdating: sessionStore.isUpdatingThreadGoal,
                goalErrorMessage: sessionStore.threadGoalErrorMessage,
                isRefreshDisabled: sessionStore.isRefreshingSelectedSession || sessionStore.isLoading,
                allowsTakeOver: sessionStore.selectedSessionAllowsTakeOver,
                onTakeOver: {
                    sessionStore.takeOverSelectedSession()
                },
                onRefreshUsage: {
                    Task {
                        await sessionStore.refreshCurrentContext()
                    }
                },
                onEditGoal: {
                    if let goal = visibleGoal {
                        goalEditor = ThreadGoalEditorDraft(sessionID: goal.threadID, existing: goal)
                    }
                },
                onTogglePauseGoal: {
                    if let goal = visibleGoal {
                        Task { await sessionStore.updateSelectedThreadGoalStatus(nextPrimaryGoalStatus(for: goal.status)) }
                    }
                },
                onCompleteGoal: {
                    Task { await sessionStore.updateSelectedThreadGoalStatus(.complete) }
                },
                onClearGoal: {
                    Task { await sessionStore.clearSelectedThreadGoal() }
                },
                onToggleGoalExpanded: {
                    withAnimation(composerMotionAnimation) {
                        isGoalStatusExpanded.toggle()
                    }
                }
            )
            .environmentObject(themeStore)
            .transition(
                reduceMotion || isPhoneComposer
                    ? .opacity
                    : .move(edge: .top).combined(with: .opacity)
            )
        }
    }

    var selectedComposerUsageNotice: CodexUsageDisplaySummary? {
        guard sessionStore.selectedQuotaNotice == nil,
              let usage = sessionStore.selectedCodexUsageDisplay,
              !usage.isExhausted,
              usage.isNearLimit
        else {
            return nil
        }
        return usage
    }

    var selectedVisibleThreadGoal: ThreadGoal? {
        // Goal 是 thread 级状态，不是单个 turn 的瞬时提示。即使已经完成也保留状态条，
        // 直到用户明确清除目标或切换 thread，避免一次回复结束后 UI 无故消失。
        sessionStore.selectedThreadGoal
    }

    // 输入框上方只保留瞬时语音状态。当前回复的停止操作已经收敛到发送按钮原位，
    // 不再额外悬浮一组 Ctrl-C / 停止会话控件。
    @ViewBuilder
    var composerStatusRow: some View {
        if isVoiceActive {
            HStack(spacing: 10) {
                voiceWaveformContent
                    .layoutPriority(1)
                Spacer(minLength: 0)
            }
        }
    }

    var isVoiceActive: Bool {
        voiceInput.isRecording || voiceInput.isPreparing || isVoicePressActive || isVoiceTranscribing
    }

    var showsTurnStopButton: Bool {
        guard let session = sessionStore.selectedSession else {
            return false
        }
        // 显示状态只跟 active turn 绑定。短暂断线时保持“停止”外观但禁用，
        // 避免错误切回发送按钮，让用户误以为当前回复已经结束。
        return session.isRunning &&
            session.activeTurnID != nil &&
            sessionStore.canControlSession(session)
    }

    var primaryComposerAction: ComposerPrimaryAction {
        ComposerPrimaryAction.resolve(
            canSubmitDraft: canSubmitDraft,
            canStopCurrentReply: showsTurnStopButton
        )
    }

    var canInterruptSelectedSession: Bool {
        guard showsTurnStopButton else {
            return false
        }
        return sessionStore.webSocketStatus == .connected
    }

    func syncGoalStatusBarExpansion(from previousGoal: ThreadGoal?, to goal: ThreadGoal?) {
        guard let goal else {
            isGoalStatusExpanded = false
            return
        }
        if previousGoal?.threadID != goal.threadID {
            isGoalStatusExpanded = false
        }
    }

    func nextPrimaryGoalStatus(for status: ThreadGoalStatus) -> ThreadGoalStatus {
        switch status {
        case .active:
            return .paused
        case .paused, .blocked, .usageLimited, .budgetLimited, .complete:
            return .active
        }
    }

    func composerInputRow(tokens: ThemeTokens) -> some View {
        Group {
            if isPhoneComposer {
                phoneComposerCard(tokens: tokens)
            } else if usesCollapsedIPadComposer {
                collapsedIPadComposerCard(tokens: tokens)
            } else {
                composerCard(tokens: tokens)
            }
        }
        .layoutPriority(1)
        .animation(
            composerMotionAnimation,
            value: usesCollapsedIPadComposer
        )
    }

    /// iPhone 始终保留同一个编辑器和工具栏：空草稿是一行，正文增加时按 TextKit
    /// 实际高度自然向上生长。这样不再需要向上箭头，也避免切换 View 树打断输入法。
    func phoneComposerCard(tokens: ThemeTokens) -> some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)

        return VStack(alignment: .leading, spacing: 4) {
            // 状态是输入上下文的一部分，不再单独绘制第二张材质卡。展开时整个
            // Composer 向上生长，编辑器和主工具栏仍保持同一外轮廓与阅读顺序。
            composerStatusTray
            expandedPhoneComposerContent(tokens: tokens)

            // 工具栏身份稳定，输入区增高时只向上生长，不重新插入或缩放按钮。
            compactPrimaryComposerToolbar(showsModelTitle: compactToolbarShowsModelTitle)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background {
            composerContainerBackground(shape: shape, tokens: tokens)
        }
        .overlay {
            shape.strokeBorder(composerCardBorderColor(tokens), lineWidth: composerCardBorderWidth)
        }
        .tint(tokens.accent)
    }

    func expandedPhoneComposerContent(tokens: ThemeTokens) -> some View {
        let skillSuggestions = filteredSkillSuggestions
        return VStack(alignment: .leading, spacing: composerCardSpacing) {
            composerTextArea(tokens: tokens, skillSuggestions: skillSuggestions)
            skillAutocompletePanel(skills: skillSuggestions)
            voiceReviewNotice
        }
        // 水平保留 10pt 阅读边距，与参考输入光标位置对齐；竖向由外层 8pt 统一控制，避免单行态
        // 在编辑器与工具栏之间多出一档空白。
        .padding(.horizontal, 2)
    }

    func composerCard(tokens: ThemeTokens) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        let skillSuggestions = filteredSkillSuggestions
        return VStack(alignment: .leading, spacing: composerCardSpacing) {
            // iPad、iPad mini 与 Catalyst 有稳定的横向空间，直接展示发送上下文；
            // iPhone 则统一收进底部「+」，不再保留需要二次展开的“快捷”状态。
            if !isPhoneComposer {
                composerContextControlsRow
            }
            composerTextArea(tokens: tokens, skillSuggestions: skillSuggestions)
            skillAutocompletePanel(skills: skillSuggestions)
            voiceReviewNotice
            primaryComposerToolbar
        }
        .padding(composerCardPadding)
        .frame(maxWidth: .infinity)
        .background {
            composerContainerBackground(shape: shape, tokens: tokens)
        }
        .tint(tokens.accent)
        .overlay {
            shape.strokeBorder(composerCardBorderColor(tokens), lineWidth: composerCardBorderWidth)
        }
    }

    @ViewBuilder
    func composerContainerBackground(
        shape: RoundedRectangle,
        tokens: ThemeTokens
    ) -> some View {
        if colorScheme == .light {
            if reduceTransparency || colorSchemeContrast == .increased {
                // 增强对比度靠实线边界定义卡片，阴影保持克制，避免和描边叠成脏边。
                shape
                    .fill(tokens.inputBackground)
                    .shadow(color: Color.black.opacity(0.07), radius: 4, y: 2)
            } else {
                // 浅色输入卡不再按设备分叉：iPad 之前是纯实色白、iPhone 是材质，
                // 同一个组件在两块屏上是两种质感，iPad 上底部还成了整屏唯一不透明的一块。
                //
                // Material 必须保持完整强度才能真正采样并虚化后方正文；不能直接给
                // Material 加 opacity，那会把已经合成的模糊结果重新混回清晰背景。
                // 亮度仍由单层轻 tint 稳住，避免繁忙正文重新穿透成可读文字。
                // 阴影沿用材质路径那一组：半径与偏移刻意收紧，避免在暖底上形成第三圈模糊白色。
                shape
                    .fill(WorkbenchMaterial.surface)
                    .overlay {
                        shape.fill(tokens.inputBackground.opacity(0.14))
                    }
                    .shadow(color: Color.black.opacity(0.03), radius: 2, y: 1)
                    .shadow(color: Color.black.opacity(0.05), radius: 8, y: 3)
            }
        } else if reduceTransparency {
            shape.fill(tokens.elevatedSurface)
        } else {
            // 深色输入区继续作为底部唯一的功能材质层，档位与其它表面一致。
            shape
                .fill(WorkbenchMaterial.surface)
                .overlay {
                    shape.fill(tokens.elevatedSurface.opacity(0.46))
                }
        }
    }

    func composerTextArea(tokens: ThemeTokens, skillSuggestions: [SkillCapability]) -> some View {
        ZStack(alignment: .topLeading) {
            ComposerTextView(
                text: composerDraftBinding,
                submitBridge: composerTextSubmitBridge,
                font: composerUIFont,
                textColor: UIColor(tokens.conversationPrimaryText),
                tintColor: UIColor(tokens.accent),
                externalTextRevision: composerTextExternalRevision,
                focusRequestID: $composerTextFocusRequestID,
                minHeight: composerMinHeight,
                maxHeight: composerMaxHeight,
                textContainerInset: isPhoneComposer
                    ? UIEdgeInsets(top: 8, left: 0, bottom: 0, right: 0)
                    : .zero,
                onSubmit: { submitDraft() },
                onContentHeightChange: { height in
                    if abs(measuredComposerTextHeight - height) > 0.5 {
                        measuredComposerTextHeight = height
                    }
                },
                onCompositionStateChange: { isComposing in
                    if isComposerTextComposing != isComposing {
                        isComposerTextComposing = isComposing
                    }
                },
                onVoiceShortcutPressChanged: { pressed in
                    if pressed {
                        beginHoldToTalk()
                    } else {
                        endHoldToTalk()
                    }
                },
                skillAutocompleteActive: activeSkillQuery != nil && !skillSuggestions.isEmpty,
                onSkillQueryChange: { query in
                    if query != activeSkillQuery {
                        activeSkillQuery = query
                        selectedSkillSuggestionIndex = 0
                    }
                },
                onSkillAutocompleteMove: { offset in
                    moveSkillSuggestion(by: offset)
                },
                onSkillAutocompleteCommit: {
                    commitSelectedSkillSuggestion()
                },
                onSkillAutocompleteDismiss: {
                    activeSkillQuery = nil
                }
            )
            .frame(height: composerTextHeight)

            if composerState.draft.isEmpty && !isComposerTextComposing {
                // 占位文案复用 TextKit 的手机上内边距，确保首行文字与真实输入基线一致。
                Text(composerPlaceholderText)
                    .font(themeStore.uiFont(.body))
                    .foregroundStyle(tokens.conversationTertiaryText)
                    .padding(.top, isPhoneComposer ? 8 : 0)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var composerDraftBinding: Binding<String> {
        Binding(
            get: { composerState.draft },
            set: { newValue in
                guard newValue != composerState.draft else {
                    return
                }
                composerState.draft = newValue
                clearVoiceTransientStatus()
            }
        )
    }

    @ViewBuilder
    func skillAutocompletePanel(skills: [SkillCapability]) -> some View {
        if activeSkillQuery != nil, !skills.isEmpty {
            SkillAutocompletePanel(
                skills: skills,
                selectedIndex: min(selectedSkillSuggestionIndex, skills.count - 1),
                onSelect: { skill in
                    selectSkillFromAutocomplete(skill)
                }
            )
            .environmentObject(themeStore)
            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topLeading)))
        }
    }

    var filteredSkillSuggestions: [SkillCapability] {
        guard let activeSkillQuery else { return [] }
        let query = activeSkillQuery.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = enabledSkillShortcuts.filter { skill in
            guard !selectedSkillPaths.contains(skill.path) else { return false }
            return query.isEmpty
                || skill.name.localizedCaseInsensitiveContains(query)
                || skill.presentationName.localizedCaseInsensitiveContains(query)
        }
        return Array(matches.prefix(5))
    }

    func moveSkillSuggestion(by offset: Int) {
        let suggestions = filteredSkillSuggestions
        guard !suggestions.isEmpty else { return }
        let count = suggestions.count
        selectedSkillSuggestionIndex = (selectedSkillSuggestionIndex + offset + count) % count
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func commitSelectedSkillSuggestion() {
        let suggestions = filteredSkillSuggestions
        guard !suggestions.isEmpty else { return }
        let index = min(selectedSkillSuggestionIndex, suggestions.count - 1)
        selectSkillFromAutocomplete(suggestions[index])
    }

    func selectSkillFromAutocomplete(_ skill: SkillCapability) {
        guard let query = activeSkillQuery else { return }
        if let updatedText = composerTextSubmitBridge.replaceText(in: query.replacementRange, with: "") {
            composerState.draft = updatedText
        }
        addSkillAttachment(skill, closesPanel: false)
        activeSkillQuery = nil
        selectedSkillSuggestionIndex = 0
    }

    func composerCardBorderColor(_ tokens: ThemeTokens) -> Color {
        if voiceInput.isRecording {
            // 录音时只给输入框一圈很淡的主题色描边作为氛围提示，真正“正在录音”的强调交给
            // 上方那条带波形的胶囊；不再让整个输入框被强描边抢走注意力。
            return tokens.voiceRecording.opacity(colorSchemeContrast == .increased ? 0.78 : 0.4)
        }
        if voiceInput.isPreparing || isVoicePressActive {
            return tokens.accent.opacity(colorSchemeContrast == .increased ? 0.9 : 0.55)
        }
        if isVoiceTranscribing {
            return tokens.accent.opacity(colorSchemeContrast == .increased ? 0.82 : 0.5)
        }
        if colorSchemeContrast == .increased {
            // 增强对比度时使用明确实线边界；默认外观仍保持“结构可感知、不过度描边”。
            return tokens.primaryText.opacity(colorScheme == .light ? 0.5 : 0.68)
        }
        // 浅色使用中性黑低透明描边，既得到清晰轮廓，也不会把暖灰边缘误读成第三种表面色。
        if colorScheme == .light {
            return Color.black.opacity(isPhoneComposer ? 0.09 : 0.06)
        }
        return tokens.border.opacity(0.58)
    }

    var composerPlaceholderText: String {
        if composerState.isGoalModeSelected {
            return sessionStore.selectedThreadGoal == nil ? L10n.text("ui.describe_the_target_task") : L10n.text("ui.request_subsequent_changes_to_goals")
        }
        if composerState.isPlanModeSelected {
            return L10n.text("ui.describe_the_issues_to_plan_for_first")
        }
        if canChooseRunningFollowUpDelivery {
            return guidedFollowUpEnabled && canUseGuidedFollowUp ? L10n.text("ui.lead_current_reply") : L10n.text("ui.add_next_round_of_instructions")
        }
        if sessionStore.selectedThreadGoal != nil {
            return L10n.text("ui.request_subsequent_changes")
        }
        return L10n.text("ui.enter_tasks_or_follow_up_instructions")
    }

    var composerCardBorderWidth: CGFloat {
        // 录音时不再加粗描边，靠颜色而非粗细提示，避免“大红框”观感；准备阶段仍略加粗。
        if voiceInput.isPreparing || isVoicePressActive {
            return 1.5
        }
        if voiceInput.isRecording {
            return 1.25
        }
        if colorSchemeContrast == .increased {
            return 1.25
        }
        return colorScheme == .light && !isPhoneComposer ? 1 : 0.75
    }

    @ViewBuilder
    var primaryComposerToolbar: some View {
        if usesCompactComposerMetrics {
            compactPrimaryComposerToolbar(showsModelTitle: compactToolbarShowsModelTitle)
        } else {
            HStack(spacing: 10) {
                addContentButton
                modelPickerControl
                followUpDeliveryMenu
                Spacer(minLength: 0)
                composerOptionsMenu
                voiceMicControl
                sendButton(showLabels: true)
            }
            .frame(maxWidth: .infinity)
        }
    }

    var compactToolbarShowsModelTitle: Bool {
        isPhoneComposer
            ? ConversationLayout.phoneComposerShowsModelTitle(availableWidth: availableWidth)
            : ConversationLayout.compactComposerShowsModelTitle(availableWidth: availableWidth)
    }

    var compactToolbarShowsInlineDeliveryControl: Bool {
        ConversationLayout.compactComposerShowsInlineDeliveryControl(
            isPhone: isPhoneComposer,
            availableWidth: availableWidth,
            canChooseDelivery: canChooseRunningFollowUpDelivery
        )
    }

    var foldsRunningFollowUpDeliveryIntoOptions: Bool {
        canChooseRunningFollowUpDelivery
            && usesCompactComposerMetrics
            && !compactToolbarShowsInlineDeliveryControl
    }

    func compactPrimaryComposerToolbar(showsModelTitle: Bool) -> some View {
        CompactComposerToolbarShell(
            leadingControls: compactLeadingControlsBox(showsModelTitle: showsModelTitle),
            toolControls: compactToolControlsBox(),
            submitControl: compactSubmitControlBox(),
            spacing: isPhoneComposer ? 6 : 8
        )
    }

    @inline(never)
    func compactLeadingControlsBox(showsModelTitle: Bool) -> AnyView {
        // iPhone 运行态把投递方式收进设置菜单，避免第六个控件挤破 320–390pt 工具栏。
        // iPad 保留原有平铺入口。
        let deliveryControl = compactToolbarShowsInlineDeliveryControl
            ? compactDeliveryControlBox()
            : nil
        return AnyView(
            CompactComposerLeadingControlsShell(
                addControl: compactAddContentControlBox(),
                modelControl: compactModelControlBox(showsTitle: showsModelTitle),
                deliveryControl: deliveryControl
            )
        )
    }

    // 每个复杂控件单独进入一个不可内联的栈帧；返回后父层只保留小型 AnyView，
    // 这是对真机泛型元数据栈溢出的边界修复，不用于普通组件的类型兼容。
    @inline(never)
    func compactAddContentControlBox() -> AnyView {
        AnyView(addContentButton)
    }

    @inline(never)
    func compactModelControlBox(showsTitle: Bool) -> AnyView {
        AnyView(modelPickerControl(showsTitle: showsTitle, usesCompactTitle: isPhoneComposer))
    }

    @inline(never)
    func compactDeliveryControlBox() -> AnyView {
        AnyView(followUpDeliveryMenu)
    }

    @inline(never)
    func compactToolControlsBox() -> AnyView {
        return AnyView(
            CompactComposerToolControlsShell(
                optionsControl: compactOptionsControlBox(showsRestingSurface: true),
                microphoneControl: compactMicrophoneControlBox(showsRestingSurface: true)
            )
        )
    }

    @inline(never)
    func compactOptionsControlBox(showsRestingSurface: Bool) -> AnyView {
        AnyView(composerOptionsMenu(showsRestingSurface: showsRestingSurface))
    }

    @inline(never)
    func compactMicrophoneControlBox(showsRestingSurface: Bool) -> AnyView {
        AnyView(voiceMicControl(showsRestingSurface: showsRestingSurface))
    }

    @inline(never)
    func compactSubmitControlBox() -> AnyView {
        AnyView(sendButton(showLabels: false))
    }

    var composerOptionsMenu: some View {
        composerOptionsMenu(showsRestingSurface: true)
    }

    func composerOptionsMenu(showsRestingSurface: Bool) -> some View {
        // 模型固定在底部主工具栏；权限与 Skill 在 iPad 上平铺、在 iPhone 上进入「+」。
        // 这里仅保留低频运行参数和发送模式，避免同一屏幕出现两套配置面。
        Menu {
            runSettingsMenu

            Divider()

            Button {
                setSendMode(composerState.isPlanModeSelected ? .standard : .plan)
            } label: {
                Label(composerState.isPlanModeSelected ? L10n.text("ui.turn_off_planning_mode") : L10n.text("ui.planning_mode"), systemImage: composerState.isPlanModeSelected ? "checkmark" : "list.clipboard")
            }
            .accessibilityIdentifier("composer.mode.plan")

            Button {
                setSendMode(composerState.isGoalModeSelected ? .standard : .goal)
            } label: {
                Label(composerState.isGoalModeSelected ? L10n.text("ui.close_target_task") : L10n.text("ui.target_task"), systemImage: composerState.isGoalModeSelected ? "checkmark" : "target")
            }
            .accessibilityIdentifier("composer.mode.goal")

            if foldsRunningFollowUpDeliveryIntoOptions {
                Divider()
                followUpDeliveryMenuItems
            }
        } label: {
            composerToolbarControlLabel(
                title: usesCompactComposerMetrics ? nil : L10n.text("ui.options"),
                systemImage: "slider.horizontal.3",
                isSelected: composerState.isPlanModeSelected || composerState.isGoalModeSelected,
                showsRestingSurface: showsRestingSurface,
                accessibilityLabel: L10n.text("ui.session_options")
            )
        }
        .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
        .accessibilityLabel(L10n.text("ui.session_options"))
        .accessibilityValue(composerOptionsAccessibilityValue)
        .accessibilityHint(L10n.text("ui.adjust_build_settings_and_sending_mode"))
        .accessibilityIdentifier("composer.options")
    }

    var composerOptionsAccessibilityValue: String {
        var values: [String] = []
        if composerState.isPlanModeSelected {
            values.append(L10n.text("ui.planning_mode"))
        } else if composerState.isGoalModeSelected {
            values.append(L10n.text("ui.target_task"))
        } else {
            values.append(L10n.text("ui.normal"))
        }
        if foldsRunningFollowUpDeliveryIntoOptions {
            values.append(
                guidedFollowUpEnabled && canUseGuidedFollowUp
                    ? L10n.text("ui.lead_current_reply")
                    : L10n.text("ui.queue_for_next_round")
            )
        }
        return values.joined(separator: " · ")
    }

    var voiceMicControl: some View {
        voiceMicControl(showsRestingSurface: true)
    }

    func voiceMicControl(showsRestingSurface: Bool) -> some View {
        VoiceMicButton(
            isPreparing: voiceInput.isPreparing || (isVoicePressActive && !voiceInput.isRecording),
            isRecording: voiceInput.isRecording,
            isTranscribing: isVoiceTranscribing,
            usesRealtimeTranscription: selectedVoiceInputProvider == .apple,
            onTap: {
                toggleVoiceInput()
            },
            showsRestingSurface: showsRestingSurface,
            usesPhoneStyle: isPhoneComposer
        )
        .layoutPriority(0)
        .accessibilityIdentifier("composer.voice")
    }

    var voiceKeyboardShortcutButton: some View {
        Button {
            toggleVoiceInputFromKeyboard()
        } label: {
            EmptyView()
        }
        .keyboardShortcut("d", modifiers: [.command, .shift])
        .buttonStyle(.plain)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityLabel(voiceInput.isRecording || isVoicePressActive || isVoiceTranscribing ? L10n.text("ui.end_voice_input") : L10n.text("ui.start_voice_input"))
        .accessibilityHidden(true)
    }

    var composerKeyboardShortcutButtons: some View {
        ZStack {
            hiddenKeyboardShortcut(L10n.text("ui.open_command_palette"), key: "k", modifiers: [.command]) {
                showsAddContentPanel = true
            }
            hiddenKeyboardShortcut(L10n.text("ui.open_the_references_panel"), key: "k", modifiers: [.command, .shift]) {
                showsAddContentPanel = true
            }
            hiddenKeyboardShortcut(L10n.text("ui.switch_target_mission_mode"), key: "g", modifiers: [.command, .shift]) {
                setSendMode(composerState.isGoalModeSelected ? .standard : .goal)
            }
            hiddenKeyboardShortcut(L10n.text("ui.switch_planning_mode"), key: "p", modifiers: [.command, .shift]) {
                setSendMode(composerState.isPlanModeSelected ? .standard : .plan)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    func hiddenKeyboardShortcut(
        _ title: String,
        key: Character,
        modifiers: EventModifiers,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            EmptyView()
        }
        .keyboardShortcut(KeyEquivalent(key), modifiers: modifiers)
        .buttonStyle(.plain)
        .frame(width: 0, height: 0)
        .accessibilityLabel(title)
        .accessibilityHidden(true)
    }

    var skillPickerButton: some View {
        Button {
            showsSkillPicker.toggle()
        } label: {
            composerToolbarControlLabel(
                title: "Skill",
                systemImage: "wand.and.stars",
                isSelected: !selectedSkillPaths.isEmpty,
                accessibilityLabel: L10n.text("ui.select_skill")
            )
        }
        .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
        .accessibilityLabel(L10n.text("ui.select_skill"))
        .accessibilityValue(selectedSkillPaths.isEmpty ? L10n.text("ui.not_selected") : L10n.plural("ui.skills_selected_count", count: selectedSkillPaths.count))
        .accessibilityIdentifier("composer.skill")
        .help(L10n.text("ui.select_skill_or_type_in_the_input_box"))
        .popover(isPresented: $showsSkillPicker, arrowEdge: .bottom) {
            SkillPickerPanel(
                skills: enabledSkillShortcuts,
                selectedPaths: selectedSkillPaths,
                errorMessage: sessionStore.capabilityErrorMessage,
                isRefreshing: sessionStore.isRefreshingCapabilities,
                onToggle: { skill in
                    toggleSkillAttachment(skill)
                },
                onRefresh: {
                    Task { await sessionStore.refreshCapabilities(forceReload: true) }
                },
                onManualAdd: {
                    showsSkillPicker = false
                    DispatchQueue.main.async {
                        showsManualSkillInputSheet = true
                    }
                },
                onDone: {
                    showsSkillPicker = false
                }
            )
            .environmentObject(themeStore)
            .presentationCompactAdaptation(.sheet)
        }
    }

    var enabledSkillShortcuts: [SkillCapability] {
        // 菜单直接消费 agentd capabilities，避免写死技能短语；排序后截断，保证菜单稳定且不拖慢 body。
        (sessionStore.capabilityList?.skills ?? [])
            .filter(\.enabled)
            .sorted { lhs, rhs in
                lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    var installedPluginShortcuts: [CodexPluginCapability] {
        (sessionStore.capabilityList?.plugins ?? [])
            .sorted { lhs, rhs in
                if lhs.enabled != rhs.enabled {
                    return lhs.enabled && !rhs.enabled
                }
                return lhs.presentationName.localizedStandardCompare(rhs.presentationName) == .orderedAscending
            }
    }

    var selectedSkillPaths: Set<String> {
        Set(composerState.attachments.compactMap { item in
            guard case .skill(_, let path) = item else { return nil }
            return path
        })
    }

    func addSkillAttachment(_ skill: SkillCapability, closesPanel: Bool = true) {
        guard !selectedSkillPaths.contains(skill.path) else {
            if closesPanel {
                showsAddContentPanel = false
            }
            return
        }
        composerState.addAttachment(.skill(name: skill.name, path: skill.path))
        clearVoiceTransientStatus()
        if closesPanel {
            showsAddContentPanel = false
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func toggleSkillAttachment(_ skill: SkillCapability) {
        if let index = composerState.attachments.firstIndex(where: { item in
            guard case .skill(_, let path) = item else { return false }
            return path == skill.path
        }) {
            composerState.removeAttachment(at: index)
            UISelectionFeedbackGenerator().selectionChanged()
        } else {
            addSkillAttachment(skill, closesPanel: false)
        }
    }

    func setSendMode(_ mode: ComposerSendMode) {
        composerState.setSendMode(mode)
        let scope = activeComposerDraftScope == .none ? currentComposerDraftScope : activeComposerDraftScope
        persistComposerSendMode(mode, for: scope)
    }

    func composerToolbarControlLabel(
        title: String?,
        systemImage: String?,
        trailingSystemImage: String? = nil,
        isSelected: Bool = false,
        tint: Color? = nil,
        titleMaxWidth: CGFloat? = nil,
        showsRestingSurface: Bool = true,
        usesCondensedTitle: Bool = false,
        accessibilityLabel: String
    ) -> some View {
        ComposerToolbarControlLabel(
            title: title,
            systemImage: systemImage,
            trailingSystemImage: trailingSystemImage,
            isSelected: isSelected,
            tint: tint,
            titleMaxWidth: titleMaxWidth,
            accessibilityLabel: accessibilityLabel,
            showsRestingSurface: showsRestingSurface,
            usesPhoneStyle: isPhoneComposer,
            usesCondensedTitle: usesCondensedTitle
        )
    }

    @ViewBuilder
    var followUpDeliveryMenuItems: some View {
        if canChooseRunningFollowUpDelivery {
            let isGuidedAvailable = canUseGuidedFollowUp
            let isGuidedSelected = guidedFollowUpEnabled && isGuidedAvailable
            Section(L10n.text("ui.send_method")) {
                Button {
                    selectFollowUpDelivery(guided: false)
                } label: {
                    Label(L10n.text("ui.queue_default"), systemImage: isGuidedSelected ? "clock" : "checkmark")
                }
                Button {
                    selectFollowUpDelivery(guided: true)
                } label: {
                    Label(isGuidedAvailable ? L10n.text("ui.lead_current_reply") : L10n.text("ui.guide_current_reply_no_active_round_currently"), systemImage: isGuidedSelected ? "checkmark" : "text.bubble")
                }
                .disabled(!isGuidedAvailable)
            }
        }
    }

    @ViewBuilder
    var followUpDeliveryMenu: some View {
        if canChooseRunningFollowUpDelivery {
            let tokens = themeStore.tokens(for: colorScheme)
            let isGuidedAvailable = canUseGuidedFollowUp
            let isGuidedSelected = guidedFollowUpEnabled && isGuidedAvailable
            Menu {
                followUpDeliveryMenuItems
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isGuidedSelected ? "text.bubble.fill" : "clock")
                        .font(themeStore.uiFont(size: 16, weight: .bold))
                    if !usesCompactComposerMetrics {
                        Text(isGuidedSelected ? L10n.text("ui.guide") : L10n.text("ui.queue"))
                            .font(themeStore.uiFont(.callout, weight: .semibold))
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(isGuidedSelected ? tokens.accent : tokens.primaryText)
                .frame(height: 44)
                .padding(.horizontal, usesCompactComposerMetrics ? 0 : 11)
                .frame(minWidth: usesCompactComposerMetrics ? 44 : 76)
                .background {
                    RoundedRectangle(cornerRadius: usesCompactComposerMetrics ? 22 : 12, style: .continuous)
                        .fill(isGuidedSelected ? tokens.accent.opacity(0.12) : Color.clear)
                        .padding(4)
                }
                .modifier(
                    ComposerFlatControlSurface(
                        tokens: tokens,
                        cornerRadius: usesCompactComposerMetrics ? 22 : 12,
                        isEmphasized: isGuidedSelected
                    )
                )
                .contentShape(RoundedRectangle(cornerRadius: usesCompactComposerMetrics ? 22 : 12, style: .continuous))
            }
            .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
            .help(isGuidedSelected ? L10n.text("ui.immediately_change_the_reply_currently_being_generated") : L10n.text("ui.save_it_in_this_device_first_and_automatically"))
            .accessibilityLabel(L10n.text("ui.append_mode_on_the_fly"))
            .accessibilityValue(isGuidedSelected ? L10n.text("ui.lead_current_reply") : L10n.text("ui.queue_for_next_round"))
            .accessibilityHint(L10n.text("ui.tap_to_toggle_queuing_or_directing_current_replies"))
            .accessibilityIdentifier("composer.followUpDelivery")
        }
    }

    func selectFollowUpDelivery(guided: Bool) {
        guard !guided || canUseGuidedFollowUp else {
            return
        }
        guard guidedFollowUpEnabled != guided else {
            return
        }
        guidedFollowUpEnabled = guided
        UISelectionFeedbackGenerator().selectionChanged()
    }

    @ViewBuilder
    var voiceReviewNotice: some View {
        if composerState.voiceDraftNeedsReview {
            let draftText = composerState.draft.trimmingCharacters(in: .whitespacesAndNewlines)
            HStack(spacing: 7) {
                Image(systemName: "checkmark.shield")
                Text(L10n.text("ui.voice_draft_to_be_confirmed"))
                    .lineLimit(1)
            }
            .font(themeStore.uiFont(.caption, weight: .medium))
            .foregroundStyle(themeStore.tokens(for: colorScheme).accent)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(themeStore.tokens(for: colorScheme).accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(themeStore.tokens(for: colorScheme).accent.opacity(0.35))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // 与对话面板保持一致：转写草稿也可长按整条复制，或进入可自由选择的文本表面
            // 挑选片段复制，而不必手动在输入框里精确拖选。
            .contextMenu {
                if !draftText.isEmpty {
                    Button {
                        UIPasteboard.general.string = draftText
                    } label: {
                        Label(L10n.text("ui.copy"), systemImage: "doc.on.doc")
                    }
                    Button {
                        isSelectingVoiceDraftText = true
                    } label: {
                        Label(L10n.text("ui.select_text"), systemImage: "text.cursor")
                    }
                }
            }
            .sheet(isPresented: $isSelectingVoiceDraftText) {
                MessageTextSelectionSheet(text: draftText)
                    .environmentObject(themeStore)
            }
        }
    }

    var runSettingsMenu: some View {
        Menu {
            outputOptionsMenu
            if developerModeEnabled {
                Divider()
                Button {
                    showsAdvancedOptionsSheet = true
                } label: {
                    Label(L10n.text("ui.advanced_options"), systemImage: "ellipsis.circle")
                }
            }
        } label: {
            composerToolbarControlLabel(
                title: L10n.text("ui.generate"),
                systemImage: "gearshape",
                accessibilityLabel: L10n.text("ui.build_settings")
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text("ui.build_settings"))
        .accessibilityHint(L10n.text("ui.adjust_speed_and_output"))
    }

    var outputOptionsMenu: some View {
        Menu {
            Section(L10n.text("ui.summary")) {
                Button(L10n.text("ui.default_option")) { composerState.updateTurnOptions { $0.reasoningSummary = nil } }
                ForEach(CodexAppServerReasoningSummary.allCases) { summary in
                    Button(summary.rawValue) { composerState.updateTurnOptions { $0.reasoningSummary = summary } }
                }
            }
            Section(L10n.text("ui.personality")) {
                Button(L10n.text("ui.default_option")) { composerState.updateTurnOptions { $0.personality = nil } }
                Button("none") { composerState.updateTurnOptions { $0.personality = CodexAppServerPersonality.none } }
                Button("friendly") { composerState.updateTurnOptions { $0.personality = .friendly } }
                Button("pragmatic") { composerState.updateTurnOptions { $0.personality = .pragmatic } }
            }
        } label: {
            Label(L10n.text("ui.summary_personality"), systemImage: "text.bubble")
        }
    }

    var permissionMenu: some View {
        ComposerPermissionMenu(
            permissionModes: availablePermissionModes,
            permissionProfiles: availablePermissionProfiles,
            selectedMode: composerState.permissionMode,
            selectedProfileID: selectedPermissionProfileID,
            activeProfileID: activePermissionProfile?.id,
            permissionAccessibilityValue: permissionTitle,
            tint: permissionTint,
            reduceMotion: reduceMotion,
            usesPhoneStyle: isPhoneComposer,
            onSelectMode: { setPermissionMode($0) },
            onSelectProfile: { setPermissionProfile($0) }
        )
    }

    // 录音/准备/转写的实时状态，作为状态行中段的胶囊。波形单独订阅 levelMeter，
    // 不会带动整条 ComposerView 重绘。紧凑布局（iPhone/窄分屏）下只留波形、隐去文案，避免一行挤不下。
    @ViewBuilder
    var voiceWaveformContent: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        if isVoiceTranscribing {
            voiceActivityCapsule(tint: tokens.accent) {
                ProgressView()
                    .controlSize(.small)
                    .tint(tokens.accent)
                if !usesCompactComposerMetrics {
                    Text(selectedVoiceInputProvider == .apple ? L10n.text("ui.finalizing_apple_voice_input") : L10n.text("ui.model_transcribing"))
                        .lineLimit(1)
                }
            }
        } else if voiceInput.isRecording {
            voiceActivityCapsule(tint: tokens.voiceRecording, emphasized: true) {
                VoiceWaveformView(meter: voiceInput.levelMeter, isActive: true, colors: tokens.voiceWaveformGradient)
                    .frame(width: usesCompactComposerMetrics ? 124 : 190, height: usesCompactComposerMetrics ? 32 : 34)
                if !usesCompactComposerMetrics {
                    Text(selectedVoiceInputProvider == .apple ? L10n.text("ui.listening_and_transcribing_in_real_time") : L10n.text("ui.listening_now_let_go_and_transcribe"))
                        .lineLimit(1)
                }
            }
        } else if voiceInput.isPreparing || isVoicePressActive {
            voiceActivityCapsule(tint: tokens.accent) {
                ProgressView()
                    .controlSize(.small)
                    .tint(tokens.accent)
                if !usesCompactComposerMetrics {
                    Text(L10n.text("ui.preparing_572335f8"))
                        .lineLimit(1)
                }
            }
        }
    }

    func voiceActivityCapsule<Content: View>(
        tint: Color,
        emphasized: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let shape = Capsule(style: .continuous)

        return HStack(spacing: 8) {
            content()
        }
        .font(themeStore.uiFont(.caption, weight: .medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .frame(height: emphasized ? 40 : 36)
        .background {
            // 语音状态悬浮在正文之上：先用输入框同款材质模糊底层文字，
            // 再轻覆状态色，既保留录音反馈，也避免半透明胶囊出现叠字。
            composerFloatingControlBackground(tokens: tokens)
                .overlay {
                    shape.fill(tint.opacity(emphasized ? 0.10 : 0.07))
                }
        }
        .overlay {
            shape.strokeBorder(tint.opacity(emphasized ? 0.4 : 0.32), lineWidth: 0.75)
        }
        .fixedSize(horizontal: true, vertical: false)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }

    func applyDefaultPermissionMode() {
        let stored = ComposerPermissionMode.stored(defaultPermissionModeID)
        composerState.applyPermissionMode(safePermissionMode(stored))
        sessionStore.saveComposerPermissionSelection(
            composerState.permissionSelectionSnapshot(),
            for: activeComposerDraftScope
        )
    }

    func applyDefaultPermissionModeForActiveScope() {
        // 设置页的“默认权限”只面向新会话。已有 Thread 在用户未点击当前输入区的
        // 权限按钮时必须继续沿用服务端设置，不能因全局偏好变化而被静默覆盖。
        switch activeComposerDraftScope {
        case .newSession:
            applyDefaultPermissionMode()
        case .session(let sessionID) where sessionID.hasPrefix("local:"):
            applyDefaultPermissionMode()
        case .none, .session:
            break
        }
    }

    func setPermissionMode(_ mode: ComposerPermissionMode) {
        let safeMode = safePermissionMode(mode)
        // Claude 的安全降级只影响当前会话，不覆盖用户为 Codex 保存的“完全访问”默认值。
        if selectedSessionRuntimeProviderForModelMenu != "claude" {
            defaultPermissionModeID = safeMode.rawValue
        }
        composerState.applyPermissionMode(safeMode)
        sessionStore.saveComposerPermissionSelection(
            composerState.permissionSelectionSnapshot(),
            for: activeComposerDraftScope
        )
    }

    func setPermissionProfile(_ profile: CodexAppServerPermissionProfileSummary) {
        if let builtInMode = ComposerPermissionMode(builtInPermissionProfileID: profile.id) {
            setPermissionMode(builtInMode)
            return
        }
        composerState.updateTurnOptions { options in
            options.preservesThreadPermissionSettings = false
            options.permissionProfileID = profile.id
            options.approvalPolicy = .forPermissionProfileID(profile.id)
            options.approvalsReviewer = "user"
            options.networkAccess = false
        }
        sessionStore.saveComposerPermissionSelection(
            composerState.permissionSelectionSnapshot(),
            for: activeComposerDraftScope
        )
    }

    var permissionProfileCWD: String? {
        let path = sessionStore.selectedSession?.dir ?? sessionStore.selectedProject?.path
        return path?.trimmingCharacters(in: .whitespacesAndNewlines).appServerNilIfEmpty
    }

    var availablePermissionProfiles: [CodexAppServerPermissionProfileSummary] {
        guard selectedSessionRuntimeProviderForModelMenu != "claude",
              sessionStore.permissionProfilesCWD == permissionProfileCWD
        else {
            return []
        }
        // 三个内建档案与上方用户权限模式完全重复，只把真正的自定义档案放进高级入口。
        return sessionStore.appServerPermissionProfiles.filter {
            ComposerPermissionMode(builtInPermissionProfileID: $0.id) == nil
        }
    }

    var selectedPermissionProfileID: String? {
        if let profileID = composerState.turnOptions.permissionProfileID?
            .trimmingCharacters(in: .whitespacesAndNewlines).appServerNilIfEmpty {
            return profileID
        }
        return composerState.turnOptions.preservesThreadPermissionSettings
            ? activePermissionProfile?.id
            : nil
    }

    var activePermissionProfile: CodexAppServerActivePermissionProfile? {
        guard let sessionID = sessionStore.selectedSessionID else {
            return nil
        }
        return sessionStore.activePermissionProfileBySessionID[sessionID]
    }

    func clampPermissionProfileToAvailableOptions() {
        guard let explicitProfileID = composerState.turnOptions.permissionProfileID?
            .trimmingCharacters(in: .whitespacesAndNewlines).appServerNilIfEmpty else { return }
        if let builtInMode = ComposerPermissionMode(builtInPermissionProfileID: explicitProfileID) {
            composerState.applyPermissionMode(builtInMode)
            sessionStore.saveComposerPermissionSelection(
                composerState.permissionSelectionSnapshot(),
                for: activeComposerDraftScope
            )
            return
        }
        guard availablePermissionProfiles.contains(where: { $0.id == explicitProfileID }) else {
            composerState.updateTurnOptions { options in
                options.permissionProfileID = nil
            }
            return
        }
    }

    var availablePermissionModes: [ComposerPermissionMode] {
        if selectedSessionRuntimeProviderForModelMenu == "claude" {
            return [.requestApproval, .readOnly, .autoApprove]
        }
        return ComposerPermissionMode.allCases
    }

    func safePermissionMode(_ mode: ComposerPermissionMode) -> ComposerPermissionMode {
        // Claude 不支持“完全访问”，也不持久化自己的默认；当共享默认落在 fullAccess 时，
        // 降级到“自动批准低风险操作”作为 Claude 的安全默认，而不是每轮都请求审批。
        // autoApprove 仍是安全档（workspaceWrite + auto_review），绝不映射 bypassPermissions。
        selectedSessionRuntimeProviderForModelMenu == "claude" && mode == .fullAccess
            ? .autoApprove
            : mode
    }

    func clampPermissionSelectionToSelectedSessionRuntime() {
        let safeMode = safePermissionMode(composerState.permissionMode)
        guard safeMode != composerState.permissionMode else {
            return
        }
        composerState.applyPermissionMode(safeMode)
    }

}
