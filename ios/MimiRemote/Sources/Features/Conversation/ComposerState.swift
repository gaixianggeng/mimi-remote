import Foundation

enum ComposerPrimaryAction: Equatable {
    case submit
    case stopCurrentReply

    static func resolve(canSubmitDraft: Bool, canStopCurrentReply: Bool) -> ComposerPrimaryAction {
        // 运行中只有草稿此刻确实可提交时，发送/排队才抢占主按钮。
        // 上传、加载或额度限制暂时阻塞提交时保留“停止”，同时不丢弃用户草稿。
        canStopCurrentReply && !canSubmitDraft ? .stopCurrentReply : .submit
    }
}

struct SubmittedComposerDraft {
    let text: String
    let attachments: [CodexAppServerUserInput]
    let payload: CodexAppServerTurnPayload
    let voiceDraftNeedsReview: Bool
    // 发送清空后的内容版本。异步失败返回时，只有版本未变化才允许恢复，
    // 避免覆盖用户在等待期间输入的下一条消息。
    let clearedContentRevision: UInt64
}

enum ComposerDraftScopeKey: Hashable {
    case session(SessionID)
    case newSession(projectID: String)
    case none

    static func current(selectedSessionID: SessionID?, selectedProjectID: String?) -> ComposerDraftScopeKey {
        if let selectedSessionID, !selectedSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .session(selectedSessionID)
        }
        if let selectedProjectID, !selectedProjectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .newSession(projectID: selectedProjectID)
        }
        return .none
    }

}

struct ComposerDraftSnapshot: Equatable {
    var text: String
    var attachments: [CodexAppServerUserInput]
    var voiceDraftNeedsReview: Bool

    static let empty = ComposerDraftSnapshot(text: "", attachments: [], voiceDraftNeedsReview: false)

    init(text: String, attachments: [CodexAppServerUserInput], voiceDraftNeedsReview: Bool) {
        self.text = text
        self.attachments = attachments
        self.voiceDraftNeedsReview = voiceDraftNeedsReview && Self.containsNonWhitespace(text)
    }

    init(submitted: SubmittedComposerDraft) {
        self.init(
            text: submitted.text,
            attachments: submitted.attachments,
            voiceDraftNeedsReview: submitted.voiceDraftNeedsReview
        )
    }

    var isEmpty: Bool {
        !Self.containsNonWhitespace(text) && attachments.isEmpty
    }

    private static func containsNonWhitespace(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
    }
}

struct ComposerDraftCache {
    private var snapshotsByScope: [ComposerDraftScopeKey: ComposerDraftSnapshot] = [:]
    private var recentlyUsedScopes: [ComposerDraftScopeKey] = []
    private var byteCountByScope: [ComposerDraftScopeKey: Int] = [:]
    private var retainedByteCount = 0
    static let retainedDraftLimit = 24
    static let retainedDraftByteLimit = 32 * 1_024 * 1_024

    mutating func save(_ snapshot: ComposerDraftSnapshot, for scope: ComposerDraftScopeKey) {
        guard scope != .none else {
            return
        }
        // 空草稿直接移除，避免用户发出或删空后再次切回时恢复旧内容。
        if snapshot.isEmpty {
            remove(scope: scope)
        } else {
            retainedByteCount -= byteCountByScope[scope] ?? 0
            snapshotsByScope[scope] = snapshot
            let byteCount = Self.estimatedByteCount(of: snapshot)
            byteCountByScope[scope] = byteCount
            retainedByteCount += byteCount
            touch(scope)
            // 图片是 base64 内联数据，必须同时限制会话数和总字节数；单张超限草稿仍保留当前作用域。
            while recentlyUsedScopes.count > 1,
                  (recentlyUsedScopes.count > Self.retainedDraftLimit || retainedByteCount > Self.retainedDraftByteLimit) {
                let evictedScope = recentlyUsedScopes.removeFirst()
                snapshotsByScope.removeValue(forKey: evictedScope)
                retainedByteCount -= byteCountByScope.removeValue(forKey: evictedScope) ?? 0
            }
        }
    }

    mutating func remove(scope: ComposerDraftScopeKey) {
        snapshotsByScope.removeValue(forKey: scope)
        retainedByteCount -= byteCountByScope.removeValue(forKey: scope) ?? 0
        recentlyUsedScopes.removeAll { $0 == scope }
    }

    mutating func removeAll() {
        snapshotsByScope.removeAll(keepingCapacity: false)
        byteCountByScope.removeAll(keepingCapacity: false)
        recentlyUsedScopes.removeAll(keepingCapacity: false)
        retainedByteCount = 0
    }

    func snapshot(for scope: ComposerDraftScopeKey) -> ComposerDraftSnapshot {
        snapshotsByScope[scope] ?? .empty
    }

    private mutating func touch(_ scope: ComposerDraftScopeKey) {
        recentlyUsedScopes.removeAll { $0 == scope }
        recentlyUsedScopes.append(scope)
    }

    private static func estimatedByteCount(of snapshot: ComposerDraftSnapshot) -> Int {
        snapshot.text.utf8.count + snapshot.attachments.reduce(into: 0) { result, item in
            switch item {
            case .text(let text, let elements):
                result += text.utf8.count + elements.count * 64
            case .image(let url, _):
                result += url.utf8.count
            case .localImage(let path, _):
                result += path.utf8.count
            case .uploadedFile(let file):
                result += file.name.utf8.count
                result += file.extractedText.utf8.count
                result += file.pageImageDataURLs.reduce(0) { $0 + $1.utf8.count }
            case .skill(let name, let path), .mention(let name, let path):
                result += name.utf8.count + path.utf8.count
            }
        }
    }
}

struct ComposerModelSelectionSnapshot: Equatable {
    var runtimeProvider: String?
    var model: String?
    var modelProvider: String?
    var reasoningEffort: CodexAppServerReasoningEffort?
    var serviceTier: String?

    init(options: CodexAppServerTurnOptions) {
        runtimeProvider = options.runtimeProvider
        model = options.model
        modelProvider = options.modelProvider
        reasoningEffort = options.reasoningEffort
        serviceTier = options.serviceTier
    }

    func apply(to options: inout CodexAppServerTurnOptions) {
        options.runtimeProvider = runtimeProvider
        options.model = model
        options.modelProvider = modelProvider
        options.reasoningEffort = reasoningEffort
        options.serviceTier = serviceTier
    }
}

struct ComposerModelSelectionCache {
    private var snapshotsByScope: [ComposerDraftScopeKey: ComposerModelSelectionSnapshot] = [:]

    mutating func save(_ snapshot: ComposerModelSelectionSnapshot, for scope: ComposerDraftScopeKey) {
        guard scope != .none else {
            return
        }
        // 模型偏好与正文是否为空无关；即使消息已经发出，也要在切回会话时恢复。
        snapshotsByScope[scope] = snapshot
    }

    func snapshot(for scope: ComposerDraftScopeKey) -> ComposerModelSelectionSnapshot? {
        snapshotsByScope[scope]
    }

    mutating func remove(scope: ComposerDraftScopeKey) {
        snapshotsByScope.removeValue(forKey: scope)
    }

    mutating func removeAll() {
        snapshotsByScope.removeAll(keepingCapacity: false)
    }
}

enum DefaultModelRuntime: String, CaseIterable, Hashable, Identifiable {
    case codex
    case claude

    var id: String { rawValue }

    var payloadRuntimeProvider: String? {
        self == .codex ? nil : rawValue
    }
}

struct DefaultModelSelection: Equatable {
    let option: CodexAppServerModelOption
    let effort: CodexAppServerReasoningEffort?
}

enum DefaultModelPreferences {
    static let codexModelOptionIDKey = "composer.defaultModel.codex.optionID"
    static let codexReasoningEffortKey = "composer.defaultModel.codex.reasoningEffort"
    static let claudeModelOptionIDKey = "composer.defaultModel.claude.optionID"
    static let claudeReasoningEffortKey = "composer.defaultModel.claude.reasoningEffort"

    /// 默认值是本机偏好，不跟随 Host 或会话保存；只有“没有会话快照”时才会被 Composer 使用。
    static func options(
        for runtimeProvider: String,
        allOptions: [CodexAppServerModelOption]
    ) -> [CodexAppServerModelOption] {
        let runtime = CodexAppServerSessionRuntime.normalizedRuntimeProvider(runtimeProvider)
        let available = allOptions.filter {
            !$0.hidden
                && CodexAppServerSessionRuntime.normalizedRuntimeProvider($0.runtimeProvider) == runtime
        }
        guard available.isEmpty else {
            return available
        }
        return runtime == "claude"
            ? CodexAppServerModelOption.builtInClaudeFallback
            : CodexAppServerModelOption.builtInFallback
    }

    static func modelOptionIDKey(for runtimeProvider: String) -> String {
        CodexAppServerSessionRuntime.normalizedRuntimeProvider(runtimeProvider) == "claude"
            ? claudeModelOptionIDKey
            : codexModelOptionIDKey
    }

    static func reasoningEffortKey(for runtimeProvider: String) -> String {
        CodexAppServerSessionRuntime.normalizedRuntimeProvider(runtimeProvider) == "claude"
            ? claudeReasoningEffortKey
            : codexReasoningEffortKey
    }

    static func storedModelOptionID(
        for runtimeProvider: String,
        in defaults: UserDefaults = .standard
    ) -> String? {
        defaults.string(forKey: modelOptionIDKey(for: runtimeProvider))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .appServerNilIfEmpty
    }

    static func storedReasoningEffort(
        for runtimeProvider: String,
        in defaults: UserDefaults = .standard
    ) -> CodexAppServerReasoningEffort? {
        guard let rawValue = defaults.string(forKey: reasoningEffortKey(for: runtimeProvider)) else {
            return nil
        }
        return CodexAppServerReasoningEffort(rawValue: rawValue)
    }

    static func resolvedSelection(
        for runtimeProvider: String,
        allOptions: [CodexAppServerModelOption],
        defaults: UserDefaults = .standard
    ) -> DefaultModelSelection? {
        let candidates = options(for: runtimeProvider, allOptions: allOptions)
        let option = storedModelOptionID(for: runtimeProvider, in: defaults)
            .flatMap { storedID in candidates.first { $0.id == storedID } }
            ?? ModelReasoningGridCatalog.preferredDefaultOption(
                runtimeProvider: runtimeProvider,
                options: candidates
            )
        guard let option else {
            return nil
        }

        let layout = ModelReasoningGridCatalog.layout(
            runtimeProvider: runtimeProvider,
            options: candidates
        )
        let visibleEfforts = ModelReasoningGridCatalog.visibleEfforts(
            for: option,
            layout: layout
        )
        let storedEffort = storedReasoningEffort(for: runtimeProvider, in: defaults)
            .flatMap { visibleEfforts.contains($0) ? $0 : nil }
        let effort = storedEffort
            ?? ModelReasoningGridCatalog.preferredDefaultEffort(
                runtimeProvider: runtimeProvider,
                option: option,
                layout: layout
            )
        return DefaultModelSelection(option: option, effort: effort)
    }

    /// 将本机默认配置转换成 turn/start 可直接使用的显式模型选择。
    /// 目录中找不到已保存的模型或推理档位时，先解析到当前 runtime 的安全默认项。
    static func applyDefault(
        for runtimeProvider: String,
        allOptions: [CodexAppServerModelOption],
        defaults: UserDefaults = .standard,
        to options: inout CodexAppServerTurnOptions
    ) {
        guard let selection = resolvedSelection(
            for: runtimeProvider,
            allOptions: allOptions,
            defaults: defaults
        ) else {
            options.runtimeProvider = DefaultModelRuntime(rawValue: runtimeProvider)?.payloadRuntimeProvider
            options.model = nil
            options.modelProvider = nil
            options.reasoningEffort = nil
            options.serviceTier = nil
            return
        }

        let layout = ModelReasoningGridCatalog.layout(
            runtimeProvider: runtimeProvider,
            options: Self.options(for: runtimeProvider, allOptions: allOptions)
        )
        let effort = ModelReasoningGridCatalog.normalizedVisibleEffort(
            option: selection.option,
            current: selection.effort,
            layout: layout
        )
        ModelReasoningGridCatalog.applySelection(
            option: selection.option,
            effort: effort,
            preservesServerDefault: false,
            fallbackRuntimeProvider: DefaultModelRuntime(rawValue: runtimeProvider)?.payloadRuntimeProvider,
            to: &options
        )
        options.serviceTier = nil
    }

    static func reset(for runtimeProvider: String, in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: modelOptionIDKey(for: runtimeProvider))
        defaults.removeObject(forKey: reasoningEffortKey(for: runtimeProvider))
    }
}

enum ComposerPermissionMode: String, CaseIterable, Identifiable {
    case requestApproval
    case readOnly
    case autoApprove
    case fullAccess

    static let defaultStorageKey = "composer.defaultPermissionMode"
    static let defaultMode: ComposerPermissionMode = .fullAccess

    var id: String { rawValue }

    static func stored(_ rawValue: String) -> ComposerPermissionMode {
        ComposerPermissionMode(rawValue: rawValue) ?? defaultMode
    }

    init(options: CodexAppServerTurnOptions) {
        let reviewer = options.approvalsReviewer.trimmingCharacters(in: .whitespacesAndNewlines)
        if options.sandboxMode == .readOnly {
            self = .readOnly
        } else if options.sandboxMode == .dangerFullAccess {
            self = .fullAccess
        } else if options.approvalPolicy == .onRequest, reviewer == Self.autoReviewer {
            self = .autoApprove
        } else {
            self = .requestApproval
        }
    }

    var title: String {
        switch self {
        case .requestApproval:
            return L10n.text("ui.request_approval")
        case .readOnly:
            return L10n.text("ui.read_only")
        case .autoApprove:
            return L10n.text("ui.approval_for_me")
        case .fullAccess:
            return L10n.text("ui.full_access")
        }
    }

    var chipTitle: String {
        switch self {
        case .requestApproval:
            return L10n.text("ui.permissions_request_approval")
        case .readOnly:
            return L10n.text("ui.permissions_read_only")
        case .autoApprove:
            return L10n.text("ui.permissions_approval_for_me")
        case .fullAccess:
            return L10n.text("ui.permissions_full_access")
        }
    }

    var detail: String {
        switch self {
        case .requestApproval:
            return L10n.text("ui.can_write_to_the_current_workspace_and_be")
        case .readOnly:
            return L10n.text("ui.do_not_write_files_by_default")
        case .autoApprove:
            return L10n.text("ui.leave_low_risk_approvals_to_agents")
        case .fullAccess:
            return L10n.text("ui.allow_access_to_entire_file_system")
        }
    }

    var systemImage: String {
        switch self {
        case .requestApproval:
            return "lock.shield"
        case .readOnly:
            return "eye"
        case .autoApprove:
            return "checkmark.shield"
        case .fullAccess:
            return "exclamationmark.shield"
        }
    }

    var approvalPolicy: CodexAppServerApprovalPolicy {
        switch self {
        case .requestApproval, .readOnly, .autoApprove, .fullAccess:
            return .onRequest
        }
    }

    var approvalsReviewer: String {
        switch self {
        case .requestApproval, .readOnly, .fullAccess:
            return "user"
        case .autoApprove:
            return Self.autoReviewer
        }
    }

    var sandboxMode: CodexAppServerSandboxMode {
        switch self {
        case .autoApprove:
            return .workspaceWrite
        case .requestApproval:
            return .workspaceWrite
        case .readOnly:
            return .readOnly
        case .fullAccess:
            return .dangerFullAccess
        }
    }

    func apply(to options: inout CodexAppServerTurnOptions) {
        // 选择旧权限预设表示显式退出命名档案，确保请求只走一条权限通道。
        options.permissionProfileID = nil
        options.approvalPolicy = approvalPolicy
        options.approvalsReviewer = approvalsReviewer
        options.sandboxMode = sandboxMode
        // 权限预设只开放“审批策略 + 本项目沙盒”这条安全通道；移动端仍不打开网络访问。
        options.networkAccess = false
    }

    private static let autoReviewer = "auto_review"
}

enum ComposerSendMode: String, CaseIterable, Identifiable {
    case standard
    case goal
    case plan

    var id: String { rawValue }
}

struct ComposerSendModeCache {
    private var storedScope: ComposerDraftScopeKey = .none
    private var storedMode: ComposerSendMode = .standard

    func modeForScopeActivation(
        previousScope: ComposerDraftScopeKey,
        nextScope: ComposerDraftScopeKey,
        currentMode: ComposerSendMode,
        isOptimisticSessionHandoff: Bool
    ) -> ComposerSendMode {
        if isOptimisticSessionHandoff {
            // local:* 切换到服务端 thread ID 是同一会话的身份交接，不应清掉发送模式。
            return currentMode
        }
        guard previousScope == .none, storedScope == nextScope else {
            // 真正切换 thread / 项目时回到标准发送，避免跨会话带入目标或计划。
            return .standard
        }
        // 横竖屏或导航容器重建时，恢复同一 SessionStore、同一 scope 的选择。
        return storedMode
    }

    mutating func save(_ mode: ComposerSendMode, for scope: ComposerDraftScopeKey) {
        storedScope = scope
        storedMode = mode
    }

    mutating func removeAll() {
        storedScope = .none
        storedMode = .standard
    }
}

struct ComposerState {
    var draft = "" {
        didSet {
            hasNonWhitespaceDraft = Self.containsNonWhitespace(draft)
            if !hasNonWhitespaceDraft {
                voiceDraftNeedsReview = false
            }
            if draft != oldValue {
                contentRevision &+= 1
            }
        }
    }
    var attachments: [CodexAppServerUserInput] = [] {
        didSet {
            if attachments != oldValue {
                contentRevision &+= 1
            }
        }
    }
    var turnOptions: CodexAppServerTurnOptions = .default
    var sendMode: ComposerSendMode = .standard
    private(set) var hasNonWhitespaceDraft = false
    private(set) var voiceDraftNeedsReview = false
    private(set) var contentRevision: UInt64 = 0
    private var voiceDraftBase: String?
    private var voiceLastRenderedDraft: String?
    private var voiceRealtimeManualSuffix = ""

    init(defaultPermissionMode: ComposerPermissionMode = .defaultMode) {
        defaultPermissionMode.apply(to: &turnOptions)
    }

    var isEmpty: Bool {
        !hasNonWhitespaceDraft && attachments.isEmpty
    }

    func canSubmit(isLoading: Bool) -> Bool {
        !isEmpty && !isLoading
    }

    var permissionMode: ComposerPermissionMode {
        ComposerPermissionMode(options: turnOptions)
    }

    mutating func applyPermissionMode(_ mode: ComposerPermissionMode) {
        updateTurnOptions { options in
            mode.apply(to: &options)
        }
    }

    mutating func updateTurnOptions(_ update: (inout CodexAppServerTurnOptions) -> Void) {
        var updatedOptions = turnOptions
        update(&updatedOptions)
        guard updatedOptions != turnOptions else {
            return
        }
        // 每次用户操作只发布一个完整 options 快照，避免连续改多个字段导致工具栏多次刷新。
        turnOptions = updatedOptions
    }

    mutating func setSendMode(_ mode: ComposerSendMode) {
        guard sendMode != mode else {
            return
        }
        sendMode = mode
    }

    var isGoalModeSelected: Bool {
        sendMode == .goal
    }

    var isPlanModeSelected: Bool {
        sendMode == .plan
    }

    mutating func toggleGoalMode() {
        // 目标是发送形态，不是立即动作；toggle 只改变下一次普通发送按钮的行为。
        sendMode = isGoalModeSelected ? .standard : .goal
    }

    mutating func togglePlanMode() {
        sendMode = isPlanModeSelected ? .standard : .plan
    }

    mutating func resetSendModeAfterSubmit() {
        resetTransientSendMode()
    }

    mutating func resetTransientSendMode() {
        // 目标/计划是下一次发送的临时模式，跟具体对话相关；切换 thread 时不能沿用到新对话。
        sendMode = .standard
    }

    func runningTurnDelivery(canUseGuidedFollowUp: Bool, guidedFollowUpEnabled: Bool) -> RunningTurnDelivery {
        // 目标/计划都必须启动一个新的 turn：目标要先写 thread 级元数据，计划模式要把
        // collaborationMode 放进 turn/start。turn/steer 只补充当前 turn 的输入，会丢掉这些启动参数。
        guard sendMode == .standard else {
            return .queued
        }
        return canUseGuidedFollowUp && guidedFollowUpEnabled ? .guided : .queued
    }

    mutating func takeDraftForSubmit(
        isLoading: Bool,
        turnOptionsOverride: CodexAppServerTurnOptions? = nil
    ) -> SubmittedComposerDraft? {
        guard canSubmit(isLoading: isLoading) else {
            return nil
        }
        let text = draft
        let sentAttachments = attachments
        let input = CodexAppServerTurnPayload.defaultInput(for: text) + sentAttachments
        let payload = CodexAppServerTurnPayload(input: input, options: turnOptionsOverride ?? turnOptions)
        let submittedVoiceDraftNeedsReview = voiceDraftNeedsReview
        draft = ""
        attachments = []
        voiceDraftNeedsReview = false
        voiceDraftBase = nil
        voiceLastRenderedDraft = nil
        voiceRealtimeManualSuffix = ""
        return SubmittedComposerDraft(
            text: text,
            attachments: sentAttachments,
            payload: payload,
            voiceDraftNeedsReview: submittedVoiceDraftNeedsReview,
            clearedContentRevision: contentRevision
        )
    }

    func canRestore(_ submitted: SubmittedComposerDraft) -> Bool {
        // 清空后只要正文或附件发生过变化，就说明用户已经开始下一次编辑。
        // 此时失败消息由时间线重试入口处理，不能把旧内容自动灌回输入框。
        isEmpty && contentRevision == submitted.clearedContentRevision
    }

    mutating func restore(_ text: String) {
        draft = text
        voiceDraftNeedsReview = false
        endVoiceInput()
    }

    mutating func restore(_ submitted: SubmittedComposerDraft) {
        draft = submitted.text
        attachments = submitted.attachments
        voiceDraftNeedsReview = submitted.voiceDraftNeedsReview
        voiceDraftBase = nil
        voiceLastRenderedDraft = nil
        voiceRealtimeManualSuffix = ""
    }

    func draftSnapshot() -> ComposerDraftSnapshot {
        ComposerDraftSnapshot(
            text: draft,
            attachments: attachments,
            voiceDraftNeedsReview: voiceDraftNeedsReview
        )
    }

    mutating func restoreDraftSnapshot(_ snapshot: ComposerDraftSnapshot) {
        draft = snapshot.text
        attachments = snapshot.attachments
        voiceDraftNeedsReview = snapshot.voiceDraftNeedsReview && hasNonWhitespaceDraft
        voiceDraftBase = nil
        voiceLastRenderedDraft = nil
        voiceRealtimeManualSuffix = ""
    }

    func modelSelectionSnapshot() -> ComposerModelSelectionSnapshot {
        ComposerModelSelectionSnapshot(options: turnOptions)
    }

    mutating func restoreModelSelectionSnapshot(_ snapshot: ComposerModelSelectionSnapshot) {
        snapshot.apply(to: &turnOptions)
    }

    mutating func addAttachment(_ input: CodexAppServerUserInput) {
        attachments.append(input)
    }

    mutating func removeAttachment(id: CodexAppServerUserInput.ID) {
        attachments.removeAll { $0.id == id }
    }

    mutating func removeAttachment(at index: Int) {
        guard attachments.indices.contains(index) else {
            return
        }
        attachments.remove(at: index)
    }

    mutating func insertShortcut(_ text: String) {
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = text
        } else {
            draft += "\n\(text)"
        }
    }

    mutating func insertPluginMention(_ name: String) {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return
        }
        let mention = "@\(normalized)"
        // 插件引用属于正文 token，不伪装成文件 mention；前后留空格可避免和用户已有文字粘连。
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = "\(mention) "
        } else if draft.last?.isWhitespace == true {
            draft += "\(mention) "
        } else {
            draft += " \(mention) "
        }
    }

    mutating func beginVoiceInput() {
        voiceDraftBase = draft
        voiceLastRenderedDraft = draft
        voiceRealtimeManualSuffix = ""
    }

    mutating func applyVoiceTranscript(_ transcript: String) {
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return
        }
        // 录音时用户仍可能键入文字或插入快捷短语；一旦发现草稿不是上一次语音写入的内容，
        // 就把当前草稿作为新的基底，避免下一段 partial transcript 回滚用户手动编辑。
        if let voiceLastRenderedDraft, draft != voiceLastRenderedDraft {
            voiceDraftBase = draft
        }
        let base = voiceDraftBase ?? draft
        if !Self.containsNonWhitespace(base) {
            draft = normalized
        } else {
            draft = base + "\n" + normalized
        }
        // 语音输入只是降低录入成本；一旦产生语音草稿，发送前仍要让用户明确审核。
        voiceDraftNeedsReview = true
        voiceLastRenderedDraft = draft
    }

    mutating func applyRealtimeVoiceTranscript(_ transcript: String) {
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return
        }

        if let lastRendered = voiceLastRenderedDraft, draft != lastRendered {
            if draft.hasPrefix(lastRendered) {
                // 实时听写时最常见的并行编辑是继续在尾部输入；把新增尾段单独保留，
                // 下一次 volatile 结果替换语音部分时不会重复已经显示过的文字。
                voiceRealtimeManualSuffix += String(draft.dropFirst(lastRendered.count))
            } else {
                // 用户修改了语音区域或前文时无法安全推断编辑意图；以当前草稿为新基底，
                // 保证不丢用户文字，代价是后续识别内容从新段落继续追加。
                voiceDraftBase = draft
                voiceRealtimeManualSuffix = ""
            }
        }

        let base = voiceDraftBase ?? draft
        draft = Self.renderVoiceTranscript(normalized, on: base) + voiceRealtimeManualSuffix
        voiceDraftNeedsReview = true
        voiceLastRenderedDraft = draft
    }

    mutating func endVoiceInput() {
        voiceDraftBase = nil
        voiceLastRenderedDraft = nil
        voiceRealtimeManualSuffix = ""
    }

    private static func renderVoiceTranscript(_ transcript: String, on base: String) -> String {
        containsNonWhitespace(base) ? base + "\n" + transcript : transcript
    }

    private static func containsNonWhitespace(_ text: String) -> Bool {
        // 输入热路径只需要知道“有没有有效字符”；逐字扫描可以在首个非空白处停止，
        // 避免每次按键都通过 trimmingCharacters 创建新字符串。
        text.unicodeScalars.contains { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
    }
}
