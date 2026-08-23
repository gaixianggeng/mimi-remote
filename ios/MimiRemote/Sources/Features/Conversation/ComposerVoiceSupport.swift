import AVFoundation
import SwiftUI
import UIKit

struct AppleVoiceStartupWatchdog {
    static let defaultTimeout: Duration = .seconds(15)

    let timeout: Duration

    init(timeout: Duration = Self.defaultTimeout) {
        self.timeout = timeout
    }

    func arm(onTimeout: @escaping @MainActor @Sendable () -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            onTimeout()
        }
    }
}

enum VoiceMicButtonState: Equatable {
    case idle
    case preparing
    case recording
    case transcribing

    init(isPreparing: Bool, isRecording: Bool, isTranscribing: Bool) {
        // 转写阶段必须优先：即使异步状态短暂重叠，也不能把不可重复触发的转写误报成可操作状态。
        if isTranscribing {
            self = .transcribing
        } else if isRecording {
            self = .recording
        } else if isPreparing {
            self = .preparing
        } else {
            self = .idle
        }
    }

    var isEnabled: Bool {
        self != .transcribing
    }

    var showsProgress: Bool {
        self == .preparing || self == .transcribing
    }

    var isActive: Bool {
        self != .idle
    }

    var accessibilityTitle: String {
        switch self {
        case .idle:
            return L10n.text("ui.start_voice_input")
        case .preparing:
            return L10n.text("ui.end_voice_input")
        case .recording:
            return L10n.text("ui.stop_recording")
        case .transcribing:
            return L10n.text("ui.transcribing_speech")
        }
    }

    var accessibilityValue: String {
        switch self {
        case .idle:
            return L10n.text("ui.not_started")
        case .preparing:
            return L10n.text("ui.preparing")
        case .recording:
            return L10n.text("ui.recording")
        case .transcribing:
            return L10n.text("ui.transcribing")
        }
    }

    func accessibilityHint(usesRealtimeTranscription: Bool) -> String {
        switch self {
        case .idle:
            return usesRealtimeTranscription
                ? L10n.text("ui.tap_to_start_apple_realtime_voice_input")
                : L10n.text("ui.click_to_start_recording")
        case .preparing:
            return L10n.text("ui.tap_to_cancel_voice_input_preparation")
        case .recording:
            return usesRealtimeTranscription
                ? L10n.text("ui.tap_to_stop_apple_voice_input")
                : L10n.text("ui.tap_to_stop_recording_and_start_transcribing")
        case .transcribing:
            // 转写阶段按钮不可重复触发；标题和值已经完整表达状态，不再提供错误的操作提示。
            return ""
        }
    }
}

struct VoiceMicButton: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isPreparing: Bool
    let isRecording: Bool
    let isTranscribing: Bool
    let usesRealtimeTranscription: Bool
    let onTap: () -> Void
    var showsRestingSurface = true
    var usesPhoneStyle = false

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let state = VoiceMicButtonState(
            isPreparing: isPreparing,
            isRecording: isRecording,
            isTranscribing: isTranscribing
        )

        Button(action: onTap) {
            Group {
                if state.showsProgress {
                    ProgressView()
                } else {
                    Image(
                        systemName: state == .recording
                            ? "stop.fill"
                            : (usesPhoneStyle ? "mic" : "mic.fill")
                    )
                }
            }
            .font(
                themeStore.uiFont(
                    size: usesPhoneStyle ? 17 : 16,
                    weight: usesPhoneStyle ? .medium : .semibold
                )
            )
            // 空闲态和其它工具按钮保持中性；录音、准备和转写才使用主题紫表达活动状态。
            .foregroundStyle(
                state.isActive
                    ? tokens.primaryAction
                    : (usesPhoneStyle ? tokens.conversationPrimaryText : tokens.primaryText)
            )
            .frame(width: 44, height: 44)
            .background(Color.clear, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .modifier(
                ComposerFlatControlSurface(
                    tokens: tokens,
                    cornerRadius: 22,
                    isEmphasized: false,
                    showsRestingFill: showsRestingSurface,
                    surfaceInset: usesPhoneStyle ? 2 : 4,
                    usesNeutralControlSurface: usesPhoneStyle
                )
            )
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(MimiPressButtonStyle(reduceMotion: reduceMotion))
        // 准备音频会话可能耗时，必须允许用户再次点击取消；否则准备卡住时按钮会永久无响应。
        .disabled(!state.isEnabled)
        .accessibilityLabel(state.accessibilityTitle)
        .accessibilityValue(state.accessibilityValue)
        .accessibilityHint(state.accessibilityHint(usesRealtimeTranscription: usesRealtimeTranscription))
    }
}

/// Composer 控件使用独立的中性实色，在输入卡内部形成安静但明确的操作表面；
/// 外壳已经是 Material，这里不再叠第二层玻璃。
struct ComposerFlatControlSurface: ViewModifier {
    let tokens: ThemeTokens
    let cornerRadius: CGFloat
    let isEmphasized: Bool
    let showsRestingFill: Bool
    let surfaceInset: CGFloat
    let usesNeutralControlSurface: Bool

    init(
        tokens: ThemeTokens,
        cornerRadius: CGFloat,
        isEmphasized: Bool,
        showsRestingFill: Bool = true,
        surfaceInset: CGFloat = 4,
        usesNeutralControlSurface: Bool = false
    ) {
        self.tokens = tokens
        self.cornerRadius = cornerRadius
        self.isEmphasized = isEmphasized
        self.showsRestingFill = showsRestingFill
        self.surfaceInset = surfaceInset
        self.usesNeutralControlSurface = usesNeutralControlSurface
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private var restingFill: Color {
        guard !isEmphasized, showsRestingFill else { return .clear }
        return usesNeutralControlSurface ? tokens.composerControlSurface : tokens.background
    }

    func body(content: Content) -> some View {
        content
            .background {
                // iPhone 可见键帽为 40pt，iPad 保持 36pt；外层命中面积始终不小于 44pt。
                ZStack {
                    shape
                        .fill(restingFill)
                        // 纯色画布后方没有正文可供 Material 折射时，接触阴影仍能稳定
                        // 区分键面与 Composer；阴影跟随 40pt 可见面，不放大到 44pt 命中区。
                        .shadow(
                            color: usesNeutralControlSurface && !isEmphasized && showsRestingFill
                                ? Color.black.opacity(0.035)
                                : .clear,
                            radius: 2,
                            y: 1
                        )
                        .padding(surfaceInset)
                    if usesNeutralControlSurface, !isEmphasized, showsRestingFill {
                        // 玻璃外壳遇到纯色正文背景时仍需保留一档控件轮廓；发丝线只稳定
                        // 边缘，不把低频按钮重新画成厚重的边框按钮。
                        shape
                            .strokeBorder(
                                tokens.resolvedScheme == .light
                                    ? Color.black.opacity(0.075)
                                    : Color.white.opacity(0.06),
                                lineWidth: 0.75
                            )
                            .padding(surfaceInset)
                    }
                }
            }
    }
}

struct VoiceWaveformLevelMapping {
    static let noiseGate: CGFloat = 0.035
    static let responseCurve: Double = 0.42
    static let audibleFloor: CGFloat = 0.10

    static func visualLevel(for rawLevel: CGFloat) -> CGFloat {
        let clamped = max(0, min(1, rawLevel))
        guard clamped > noiseGate else {
            return 0
        }
        // 低音量区做更明显的视觉增益：静音仍被 gate 压住，一开口就能看到清楚的上下起伏。
        let normalized = (clamped - noiseGate) / (1 - noiseGate)
        let boosted = pow(Double(normalized), responseCurve)
        let lifted = audibleFloor + CGFloat(boosted) * (1 - audibleFloor)
        return max(0, min(1, lifted))
    }
}

struct VoiceWaveformSampleShape {
    static let barCount = 22

    static func samples(for rawLevel: CGFloat, count: Int = Self.barCount) -> [CGFloat] {
        let clamped = max(0, min(1, rawLevel))
        guard count > 0 else {
            return []
        }
        guard VoiceWaveformLevelMapping.visualLevel(for: clamped) > 0 else {
            return Array(repeating: 0, count: count)
        }

        return (0..<count).map { index in
            // 固定条位生成一个中间波峰：每一帧只反映“此刻声音大小”，不再把历史音量往前滚动。
            let progress = count == 1 ? 0.5 : CGFloat(index) / CGFloat(count - 1)
            let distanceFromCenter = abs(progress - 0.5) * 2
            let bell = CGFloat(exp(-pow(Double(distanceFromCenter / 0.48), 2)))
            let shoulder: CGFloat = 0.16
            return min(1, clamped * (shoulder + bell * (1 - shoulder)))
        }
    }
}

struct VoiceWaveformView: View {
    @ObservedObject var meter: VoiceLevelMeter
    let isActive: Bool
    let colors: [Color]

    var body: some View {
        GeometryReader { proxy in
            let samples = Array(meter.samples.enumerated())
            let spacing: CGFloat = 3
            let count = max(samples.count, 1)
            let availableWidth = max(0, proxy.size.width - spacing * CGFloat(max(count - 1, 0)))
            let barWidth = max(2.7, min(5.2, availableWidth / CGFloat(count)))

            // 用一条铺满整个宽度的横向渐变，再用竖条形状做 mask：每根条只露出它所在位置的渐变色，
            // 于是整组波形从左到右是平滑的主题渐变，而不是每根单独着色拼出来的硬边。
            LinearGradient(
                colors: colors,
                startPoint: .leading,
                endPoint: .trailing
            )
            .mask {
                HStack(alignment: .center, spacing: spacing) {
                    ForEach(samples, id: \.offset) { index, level in
                        RoundedRectangle(cornerRadius: barWidth / 2, style: .continuous)
                            .frame(width: barWidth, height: barHeight(index: index, level: level, maxHeight: proxy.size.height))
                            .animation(.easeOut(duration: 0.07), value: level)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .opacity(isActive ? 1 : 0.45)
        }
    }

    private func barHeight(index: Int, level: CGFloat, maxHeight: CGFloat) -> CGFloat {
        let minHeight: CGFloat = 3
        let usable = max(0, maxHeight - minHeight)
        guard isActive else {
            // 静止时给一点高低错落，避免看起来像坏掉的直线。
            return minHeight + (index.isMultiple(of: 2) ? 3 : 0)
        }
        let visibleLevel = VoiceWaveformLevelMapping.visualLevel(for: level)
        return minHeight + visibleLevel * usable
    }
}

@MainActor
final class VoiceLevelMeter: ObservableObject {
    static let barCount = VoiceWaveformSampleShape.barCount

    @Published private(set) var samples: [CGFloat] = Array(repeating: 0, count: VoiceLevelMeter.barCount)
    private var previousLevel: CGFloat = 0

    func push(_ level: CGFloat) {
        let clamped = max(0, min(1, level))
        let risingDelta = max(0, clamped - previousLevel)
        // 只对“正在变大”的瞬间做一点 attack 增强；不保留历史队列，所以视觉不会横向滚动。
        let emphasizedLevel = min(1, clamped + risingDelta * 0.35)
        samples = VoiceWaveformSampleShape.samples(for: emphasizedLevel, count: Self.barCount)
        previousLevel = clamped
    }

    func prepareForRecording() {
        // 录音器刚启动但还没检测到声音时保持平线；一开口再按当前音量抬起中心波峰。
        samples = Array(repeating: 0, count: Self.barCount)
        previousLevel = 0
    }

    func reset() {
        samples = Array(repeating: 0, count: VoiceLevelMeter.barCount)
        previousLevel = 0
    }
}

struct ManualSkillInputSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var path = ""

    let onAdd: (CodexAppServerUserInput) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField(L10n.text("ui.skill_name"), text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(L10n.text("ui.path_within_allowlist"), text: $path)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .navigationTitle(L10n.text("ui.add_skills_manually"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("ui.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("ui.add")) {
                        if let input {
                            onAdd(input)
                            dismiss()
                        }
                    }
                    .disabled(input == nil)
                }
            }
        }
    }

    private var input: CodexAppServerUserInput? {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !value.isEmpty else {
            return nil
        }
        return .skill(name: title, path: value)
    }
}

struct AdvancedTurnOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CodexAppServerTurnOptions
    @State private var configText: String
    @State private var outputSchemaText: String
    @State private var errorMessage: String?

    let onSave: (CodexAppServerTurnOptions) -> Void

    init(options: CodexAppServerTurnOptions, onSave: @escaping (CodexAppServerTurnOptions) -> Void) {
        _draft = State(initialValue: options)
        _configText = State(initialValue: Self.jsonText(from: options.config))
        _outputSchemaText = State(initialValue: Self.jsonText(from: options.outputSchema))
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.text("ui.model")) {
                    TextField(L10n.text("ui.runtime_provider"), text: optionalStringBinding(\.runtimeProvider))
                    TextField(L10n.text("ui.model"), text: optionalStringBinding(\.model))
                    TextField(L10n.text("ui.model_provider"), text: optionalStringBinding(\.modelProvider))
                    TextField(L10n.text("ui.service_name"), text: optionalStringBinding(\.serviceName))
                }

                Section(L10n.text("ui.reasoning_and_service_tier")) {
                    // 标准选择器只暴露四档；完整协议值集中在开发者高级选项中，
                    // 让 Low、Codex Max、auto 和 flex 仍可显式配置而不污染普通入口。
                    Picker(L10n.text("ui.reasoning_effort"), selection: $draft.reasoningEffort) {
                        Text(L10n.text("ui.default_option"))
                            .tag(Optional<CodexAppServerReasoningEffort>.none)
                        ForEach(CodexAppServerReasoningEffort.allCases) { effort in
                            Text(ModelReasoningGridCatalog.effortTitle(effort))
                                .tag(Optional(effort))
                        }
                    }

                    Picker(L10n.text("ui.service_tier"), selection: $draft.serviceTier) {
                        Text(L10n.text("ui.default_option"))
                            .tag(Optional<String>.none)
                        // Service tier 是协议枚举值，展示时保持原值，不能参与本地化。
                        Text(verbatim: "auto").tag(Optional("auto"))
                        Text(verbatim: "priority").tag(Optional("priority"))
                        Text(verbatim: "flex").tag(Optional("flex"))
                    }
                }

                Section(L10n.text("ui.thread_source")) {
                    TextField(L10n.text("ui.session_start_source"), text: optionalStringBinding(\.sessionStartSource))
                    TextField(L10n.text("ui.thread_source"), text: optionalStringBinding(\.threadSource))
                }

                Section(L10n.text("ui.instructions")) {
                    TextEditor(text: optionalStringBinding(\.baseInstructions))
                        .frame(minHeight: 90)
                    TextEditor(text: optionalStringBinding(\.developerInstructions))
                        .frame(minHeight: 90)
                }

                Section("JSON") {
                    TextEditor(text: $configText)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 110)
                    TextEditor(text: $outputSchemaText)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 130)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(L10n.text("ui.advanced_options"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("ui.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button(L10n.text("ui.clear")) { clearAdvancedOptions() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("ui.application")) { apply() }
                }
            }
        }
    }

    private func optionalStringBinding(_ keyPath: WritableKeyPath<CodexAppServerTurnOptions, String?>) -> Binding<String> {
        Binding(
            get: { draft[keyPath: keyPath] ?? "" },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                draft[keyPath: keyPath] = trimmed.isEmpty ? nil : value
            }
        )
    }

    private func apply() {
        do {
            draft.config = try parseOptionalJSON(configText, requireObject: true, label: "config")
            draft.outputSchema = try parseOptionalJSON(outputSchemaText, requireObject: false, label: "outputSchema")
            onSave(draft)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearAdvancedOptions() {
        draft.runtimeProvider = nil
        draft.modelProvider = nil
        draft.reasoningEffort = nil
        draft.serviceTier = nil
        draft.config = nil
        draft.baseInstructions = nil
        draft.developerInstructions = nil
        draft.outputSchema = nil
        draft.serviceName = nil
        draft.sessionStartSource = nil
        draft.threadSource = nil
        configText = ""
        outputSchemaText = ""
        errorMessage = nil
    }

    private func parseOptionalJSON(_ text: String, requireObject: Bool, label: String) throws -> CodexAppServerJSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        let value = try JSONDecoder().decode(CodexAppServerJSONValue.self, from: Data(trimmed.utf8))
        if requireObject, value.objectValue == nil {
            throw AdvancedTurnOptionsError.invalidJSON(label + L10n.text("ui.must_be_a_json_object"))
        }
        return value
    }

    private static func jsonText(from value: CodexAppServerJSONValue?) -> String {
        guard let value else {
            return ""
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }
}

enum AdvancedTurnOptionsError: LocalizedError {
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON(let message):
            return message
        }
    }
}

/// 将系统音频会话调用隔离在非 MainActor 的协调域中。
///
/// AVAudioSession 的 category/active 切换可能阻塞；UI 与录音器生命周期仍由 MainActor 管理，
/// 这里只负责系统会话租约，避免阻塞界面或发生旧清理关闭新录音的竞态。
protocol VoiceAudioSessionBackend: Sendable {
    func prepareForRecording() throws
    func activateForRecording() throws
    func deactivateRecording() throws
}

final class SystemVoiceAudioSessionBackend: VoiceAudioSessionBackend, @unchecked Sendable {
    private let audioSession: AVAudioSession

    init(audioSession: AVAudioSession = .sharedInstance()) {
        self.audioSession = audioSession
    }

    func prepareForRecording() throws {
        try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
    }

    func activateForRecording() throws {
        try audioSession.setActive(true)
    }

    func deactivateRecording() throws {
        try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
    }
}

actor VoiceAudioSessionCoordinator {
    struct Activation: Sendable, Equatable {
        fileprivate let id: UUID
    }

    static let shared = VoiceAudioSessionCoordinator()

    private let backend: any VoiceAudioSessionBackend
    private var currentActivationID: UUID?
    private var activationRequestIDs: Set<UUID> = []
    private var latestActivationRequestID: UUID?
    private var hasAbandonedActivation = false

    init(backend: any VoiceAudioSessionBackend = SystemVoiceAudioSessionBackend()) {
        self.backend = backend
    }

    func prewarm() throws {
        try backend.prepareForRecording()
    }

    func activate() async throws -> Activation {
        try Task.checkCancellation()
        let requestID = UUID()
        activationRequestIDs.insert(requestID)
        latestActivationRequestID = requestID

        let backend = self.backend
        // setActive(true) 是同步阻塞调用。每次请求使用独立执行任务，确保一次挂起不会占住
        // coordinator actor；后续重试仍能登记自己的请求并独立尝试激活。
        let activationTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            try backend.prepareForRecording()
            try Task.checkCancellation()
            try backend.activateForRecording()
        }
        do {
            try await withTaskCancellationHandler {
                try await activationTask.value
            } onCancel: {
                activationTask.cancel()
                Task {
                    await self.cancelActivationRequest(requestID)
                }
            }
        } catch {
            activationRequestIDs.remove(requestID)
            deactivateAbandonedActivationIfIdle()
            throw error
        }

        activationRequestIDs.remove(requestID)
        do {
            try Task.checkCancellation()
        } catch {
            markAbandonedActivation()
            deactivateAbandonedActivationIfIdle()
            throw error
        }
        guard latestActivationRequestID == requestID else {
            markAbandonedActivation()
            deactivateAbandonedActivationIfIdle()
            throw CancellationError()
        }

        let activation = Activation(id: requestID)
        currentActivationID = activation.id
        hasAbandonedActivation = false
        return activation
    }

    private func cancelActivationRequest(_ requestID: UUID) {
        // 同步系统调用可能不响应 Task 取消；先移除逻辑请求，避免它阻止有效重试结束时停用。
        activationRequestIDs.remove(requestID)
        deactivateAbandonedActivationIfIdle()
    }

    private func markAbandonedActivation() {
        // AVAudioSession 是进程级共享状态；已有租约时，迟到成功已经由该租约共同拥有。
        if currentActivationID == nil {
            hasAbandonedActivation = true
        }
    }

    private func deactivateAbandonedActivationIfIdle() {
        // 有更新请求或有效租约时不能停用全局 AVAudioSession，否则迟到旧请求会关闭新录音。
        guard
            hasAbandonedActivation,
            activationRequestIDs.isEmpty,
            currentActivationID == nil
        else {
            return
        }
        hasAbandonedActivation = false
        try? backend.deactivateRecording()
    }

    func deactivate(_ activation: Activation) {
        // 快速停止后重新开始时，旧清理任务可能晚到；租约不匹配就不能关闭新会话。
        guard currentActivationID == activation.id else {
            return
        }
        currentActivationID = nil
        // 新请求已进入 setActive 时，旧租约只能移交当前激活状态，不能执行全局停用。
        // 新请求成功后会接管租约；失败或取消后再由 abandoned cleanup 配对停用。
        guard activationRequestIDs.isEmpty else {
            hasAbandonedActivation = true
            return
        }
        hasAbandonedActivation = false
        try? backend.deactivateRecording()
    }
}

@MainActor
final class VoiceInputController: NSObject, ObservableObject {
    @Published private(set) var isPreparing = false
    @Published private(set) var isRecording = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var noticeMessage: String?

    // 音量计单独成对象：波形按 buffer 频率刷新，只让 VoiceWaveformView 订阅它，
    // 避免高频 level 变化把整个 ComposerView 一起重绘。
    let levelMeter = VoiceLevelMeter()

    private var recorder: AVAudioRecorder?
    private var meteringTask: Task<Void, Never>?
    private var finishHandler: ((VoiceRecordingResult?) -> Void)?
    private var recordingURL: URL?
    private var startRequestID: UUID?
    private var pressStartedAt: Date?
    private var recordingStartedAt: Date?
    private var activeProvider: VoiceInputProvider?
    // Swift 不允许 stored property 自身标记 availability；用不透明引用保存会话，
    // 只在 iOS 26+ 方法内部还原成 AppleSpeechTranscriptionSession。
    private var appleSession: AnyObject?
    private var appleLifecycleTask: Task<Void, Never>?
    private var appleStartupWatchdogTask: Task<Void, Never>?
    private var appleFinishHandler: (() -> Void)?
    private let audioSessionCoordinator: VoiceAudioSessionCoordinator
    private var audioSessionActivation: VoiceAudioSessionCoordinator.Activation?
    private var audioSessionCleanupTask: Task<Void, Never>?

    init(audioSessionCoordinator: VoiceAudioSessionCoordinator = .shared) {
        self.audioSessionCoordinator = audioSessionCoordinator
        super.init()
    }

    func start(onFinish: @escaping (VoiceRecordingResult?) -> Void) {
        guard activeProvider == nil, !isRecording, finishHandler == nil else {
            return
        }
        let requestID = UUID()
        activeProvider = .codex
        startRequestID = requestID
        finishHandler = onFinish
        pressStartedAt = Date()
        recordingStartedAt = nil
        errorMessage = nil
        noticeMessage = nil

        switch recordPermissionState() {
        case .undetermined:
            Task {
                // 首次系统权限弹窗可能吞掉按住手势结束事件；授权后不自动接着录，
                // 让用户重新按住一次，保证 UI 状态和真实录音起点一致。
                let granted = await requestRecordPermission()
                guard startRequestID == requestID else {
                    return
                }
                if granted {
                    noticeMessage = L10n.text("ui.the_microphone_is_on_please_press_and_hold")
                } else {
                    errorMessage = L10n.text("ui.microphone_permission_is_not_enabled_please_allow_it")
                }
                finish(fileURL: nil)
            }
            return
        case .denied:
            errorMessage = L10n.text("ui.microphone_permission_is_not_enabled_please_allow_it")
            finish(fileURL: nil)
            return
        case .granted:
            break
        }

        isPreparing = true
        MimiHaptics.prepare(.commit)

        let pendingAudioSessionCleanup = audioSessionCleanupTask
        Task {
            // 新一轮录音必须等待上一轮清理落地，避免 category/active 状态交叉。
            await pendingAudioSessionCleanup?.value
            guard startRequestID == requestID else {
                return
            }
            // 按住说话时权限弹窗可能晚于松手返回；用 requestID 防止松手后又启动录音。
            guard await requestRecordPermission() else {
                guard startRequestID == requestID else {
                    return
                }
                errorMessage = L10n.text("ui.microphone_permission_is_not_enabled")
                finish(fileURL: nil)
                return
            }
            guard startRequestID == requestID else {
                return
            }
            do {
                try await startRecording(requestID: requestID)
            } catch {
                guard startRequestID == requestID else {
                    return
                }
                errorMessage = error.localizedDescription
                finish(fileURL: nil)
            }
        }
    }

    @available(iOS 26.0, *)
    func startAppleTranscription(
        locale: Locale,
        onTranscript: @escaping @MainActor (String) -> Void,
        onFinish: @escaping () -> Void
    ) {
        guard activeProvider == nil, !isRecording, appleFinishHandler == nil else {
            return
        }
        let requestID = UUID()
        activeProvider = .apple
        startRequestID = requestID
        appleFinishHandler = onFinish
        errorMessage = nil
        noticeMessage = nil

        isPreparing = true
        MimiHaptics.prepare(.commit)
        let session = AppleSpeechTranscriptionSession(
            sessionID: requestID,
            audioSessionCoordinator: audioSessionCoordinator
        )
        appleSession = session
        session.logStartRequested(locale: locale)
        appleLifecycleTask = Task { [weak self, weak session] in
            guard let self, let session else { return }
            do {
                guard startRequestID == requestID else { return }
                let granted = await requestRecordPermission()
                session.logPermissionDone(granted: granted)
                guard granted else {
                    guard startRequestID == requestID else { return }
                    cancelAppleStartupWatchdog()
                    errorMessage = L10n.text("ui.microphone_permission_is_not_enabled_please_allow_it")
                    await session.cancel()
                    completeAppleInteraction(notifyFinish: true)
                    return
                }
                guard startRequestID == requestID else {
                    await session.cancel()
                    return
                }
                try await session.start(
                    locale: locale,
                    onStartupMonitoringReady: { [weak self] in
                        guard let self,
                              activeProvider == .apple,
                              startRequestID == requestID,
                              isPreparing else {
                            return
                        }
                        armAppleStartupWatchdog(requestID: requestID)
                    },
                    onTranscript: { [weak self] transcript in
                        guard self?.activeProvider == .apple,
                              self?.startRequestID == requestID else {
                            return
                        }
                        onTranscript(transcript)
                    },
                    onLevel: { [weak self] level in
                        guard self?.activeProvider == .apple,
                              self?.startRequestID == requestID else {
                            return
                        }
                        self?.levelMeter.push(level)
                    },
                    onFailure: { [weak self, weak session] error in
                        guard let self,
                              let session,
                              activeProvider == .apple,
                              startRequestID == requestID else {
                            return
                        }
                        // 结果流可能在 session.start() 返回前就失败；先让本次请求失效，
                        // 防止外层启动任务随后又把已经失败的会话标成录音中。
                        startRequestID = nil
                        cancelAppleStartupWatchdog()
                        errorMessage = userFacingAppleSpeechError(error)
                        isPreparing = false
                        isRecording = false
                        levelMeter.reset()
                        appleLifecycleTask = Task { [weak self, weak session] in
                            await session?.cancel()
                            self?.completeAppleInteraction(notifyFinish: true)
                        }
                    }
                )
                guard startRequestID == requestID else {
                    await session.cancel()
                    return
                }
                cancelAppleStartupWatchdog()
                appleLifecycleTask = nil
                isPreparing = false
                isRecording = true
                levelMeter.prepareForRecording()
                // 录音器真正开始采样后只发出一次 commit；准备和持续录音状态不重复触发。
                MimiHaptics.fire(.commit)
            } catch is CancellationError {
                await session.cancel()
                if startRequestID == requestID {
                    completeAppleInteraction(notifyFinish: true)
                }
            } catch {
                await session.cancel()
                guard startRequestID == requestID else { return }
                errorMessage = userFacingAppleSpeechError(error)
                completeAppleInteraction(notifyFinish: true)
            }
        }
    }

    func stop() {
        if activeProvider == .apple {
            if #available(iOS 26.0, *) {
                finishAppleTranscription()
            } else {
                // Apple 提供方不会在旧系统被选中；此分支只保护历史状态，直接收尾而不触碰 Speech API。
                completeUnavailableAppleInteraction(notifyFinish: true)
            }
            return
        }
        let shouldFinishImmediately = !isRecording && recorder == nil
        startRequestID = nil
        if shouldFinishImmediately {
            finish(fileURL: nil)
            return
        }
        finish(fileURL: recordingURL)
    }

    func cancel() {
        if activeProvider == .apple {
            if #available(iOS 26.0, *) {
                cancelAppleTranscription(notifyFinish: false)
            } else {
                completeUnavailableAppleInteraction(notifyFinish: false)
            }
            return
        }
        let fileURL = recordingURL
        startRequestID = nil
        finishHandler = nil
        finish(fileURL: nil)
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    @available(iOS 26.0, *)
    private func finishAppleTranscription() {
        guard activeProvider == .apple else { return }
        guard let session = appleSession as? AppleSpeechTranscriptionSession else {
            completeAppleInteraction(notifyFinish: true)
            return
        }
        cancelAppleStartupWatchdog()
        isPreparing = false
        isRecording = false
        levelMeter.reset()
        appleLifecycleTask?.cancel()
        appleLifecycleTask = Task { [weak self, weak session] in
            guard let self, let session else { return }
            do {
                try await session.finish()
            } catch is CancellationError {
                await session.cancel()
            } catch {
                errorMessage = userFacingAppleSpeechError(error)
                await session.cancel()
            }
            completeAppleInteraction(notifyFinish: true)
        }
    }

    @available(iOS 26.0, *)
    private func cancelAppleTranscription(notifyFinish: Bool) {
        let session = appleSession as? AppleSpeechTranscriptionSession
        let lifecycleTask = appleLifecycleTask
        startRequestID = nil
        cancelAppleStartupWatchdog()
        lifecycleTask?.cancel()
        // 系统权限或 Speech await 可能不响应取消；旧任务只异步收尾，不能成为下一轮启动的闸门。
        // 会话的 activation lease 会让迟到的旧 deactivate 失效，避免关闭新会话。
        Task {
            await session?.cancel()
        }
        completeAppleInteraction(notifyFinish: notifyFinish)
    }

    @available(iOS 26.0, *)
    private func completeAppleInteraction(notifyFinish: Bool) {
        let handler = appleFinishHandler
        cancelAppleStartupWatchdog()
        appleFinishHandler = nil
        appleSession = nil
        appleLifecycleTask = nil
        activeProvider = nil
        startRequestID = nil
        isPreparing = false
        isRecording = false
        levelMeter.reset()
        if notifyFinish {
            handler?()
        }
    }

    private func completeUnavailableAppleInteraction(notifyFinish: Bool) {
        let handler = appleFinishHandler
        cancelAppleStartupWatchdog()
        appleFinishHandler = nil
        appleLifecycleTask?.cancel()
        appleLifecycleTask = nil
        activeProvider = nil
        startRequestID = nil
        isPreparing = false
        isRecording = false
        levelMeter.reset()
        if notifyFinish {
            handler?()
        }
    }

    private func cancelAppleStartupWatchdog() {
        appleStartupWatchdogTask?.cancel()
        appleStartupWatchdogTask = nil
    }

    @available(iOS 26.0, *)
    private func armAppleStartupWatchdog(requestID: UUID) {
        cancelAppleStartupWatchdog()
        appleStartupWatchdogTask = AppleVoiceStartupWatchdog().arm { [weak self] in
            guard let self,
                  self.activeProvider == .apple,
                  self.startRequestID == requestID,
                  self.isPreparing else {
                return
            }
            (self.appleSession as? AppleSpeechTranscriptionSession)?.logStartupTimeout()
            self.errorMessage = self.userFacingAppleSpeechError(
                AppleSpeechTranscriptionError.startupTimedOut
            )
            self.cancelAppleTranscription(notifyFinish: true)
        }
    }

    private func userFacingAppleSpeechError(_ error: Error) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            return L10n.text("ui.apple_voice_input_is_currently_unavailable")
        }
        if error is AppleSpeechTranscriptionError {
            return message
        }
        return L10n.format("ui.apple_voice_input_failed", message)
    }

    func setErrorMessage(_ message: String?) {
        errorMessage = message
        if message != nil {
            noticeMessage = nil
        }
    }

    func setNoticeMessage(_ message: String?) {
        noticeMessage = message
        if message != nil {
            errorMessage = nil
        }
    }

    func prewarm() {
        // 进入对话页时先把音频会话 category 配好（不激活、不触发麦克风指示灯）。
        // 这样真正按住说话时只需 setActive + record，省掉冷启动里最慢的 category 切换，
        // 缩短“按下 → 看到红色波形”的可感知延迟。
        guard recorder == nil, !isRecording else {
            return
        }
        Task {
            try? await audioSessionCoordinator.prewarm()
        }
        MimiHaptics.prepare(.commit)
    }

    private func startRecording(requestID: UUID) async throws {
        let activation = try await audioSessionCoordinator.activate()
        do {
            try Task.checkCancellation()
            guard startRequestID == requestID else {
                throw CancellationError()
            }

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("voice-\(UUID().uuidString)")
                .appendingPathExtension("m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                throw VoiceInputError.recordingFailed
            }
            self.recorder = recorder
            audioSessionActivation = activation
            recordingURL = url
            recordingStartedAt = Date()
            levelMeter.prepareForRecording()
            isPreparing = false
            isRecording = true
            // 录音器真正开始采样后只发出一次 commit；准备和持续录音状态不重复触发。
            MimiHaptics.fire(.commit)
            startMetering()
        } catch {
            await audioSessionCoordinator.deactivate(activation)
            throw error
        }
    }

    private func startMetering() {
        meteringTask?.cancel()
        meteringTask = Task { [weak self] in
            while !Task.isCancelled {
                // 45ms ≈ 22fps：比原来的 80ms 更跟手，波形随语音瞬态跳动而不是一卡一卡，
                // 同时仍远低于会让主线程吃紧的刷新频率。
                try? await Task.sleep(nanoseconds: 45_000_000)
                await MainActor.run {
                    guard let self, let recorder = self.recorder, self.isRecording else {
                        return
                    }
                    recorder.updateMeters()
                    let level = Self.normalizedPower(
                        average: recorder.averagePower(forChannel: 0),
                        peak: recorder.peakPower(forChannel: 0)
                    )
                    self.levelMeter.push(level)
                }
            }
        }
    }

    private func requestRecordPermission() async -> Bool {
        if #available(iOS 17.0, *) {
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        } else {
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func recordPermissionState() -> VoiceRecordPermissionState {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .undetermined:
                return .undetermined
            case .denied:
                return .denied
            case .granted:
                return .granted
            @unknown default:
                return .denied
            }
        } else {
            switch AVAudioSession.sharedInstance().recordPermission {
            case .undetermined:
                return .undetermined
            case .denied:
                return .denied
            case .granted:
                return .granted
            @unknown default:
                return .denied
            }
        }
    }

    private func finish(fileURL: URL?) {
        let now = Date()
        let pressDuration = pressStartedAt.map { now.timeIntervalSince($0) } ?? 0
        let recordedDuration = max(
            recorder?.currentTime ?? 0,
            recordingStartedAt.map { now.timeIntervalSince($0) } ?? 0
        )
        recorder?.stop()
        recorder = nil
        meteringTask?.cancel()
        meteringTask = nil
        recordingURL = nil
        startRequestID = nil
        pressStartedAt = nil
        recordingStartedAt = nil
        isPreparing = false
        isRecording = false
        activeProvider = nil
        levelMeter.reset()
        scheduleAudioSessionCleanup(audioSessionActivation)
        audioSessionActivation = nil
        if let fileURL {
            finishHandler?(VoiceRecordingResult(
                fileURL: fileURL,
                recordedDuration: recordedDuration,
                pressDuration: pressDuration
            ))
        } else {
            finishHandler?(nil)
        }
        finishHandler = nil
    }

    private func scheduleAudioSessionCleanup(_ activation: VoiceAudioSessionCoordinator.Activation?) {
        guard let activation else {
            return
        }
        let previousCleanup = audioSessionCleanupTask
        audioSessionCleanupTask = Task { [audioSessionCoordinator] in
            // 清理任务排成一条链；即使用户快速点按，也不会并发改动系统音频会话。
            await previousCleanup?.value
            await audioSessionCoordinator.deactivate(activation)
        }
    }

    nonisolated private static func normalizedPower(average: Float, peak: Float) -> CGFloat {
        // 以峰值为主、平均值兜底：峰值跟住人声爆破音，平均值避免纯底噪把波形误拉高。
        // 映射区间略收紧到 [-50, -4] dBFS，轻声会更早动起来，正常说话会明显上下波动。
        let floorDB: Float = -50
        let ceilDB: Float = -4
        let blended = max(average + 2, peak - 4)
        let clamped = max(floorDB, min(ceilDB, blended))
        return CGFloat((clamped - floorDB) / (ceilDB - floorDB))
    }
}

struct VoiceRecordingResult {
    let fileURL: URL
    let recordedDuration: TimeInterval
    let pressDuration: TimeInterval
}

struct VoiceTranscriptionContext: Equatable {
    let id = UUID()
    let sessionID: SessionID?
}

struct RetryableVoiceTranscription: Identifiable {
    let id = UUID()
    let filename: String
    let contentType: String
    let audioData: Data
    let recordedDuration: TimeInterval
    let pressDuration: TimeInterval
    let sessionID: SessionID?
}

enum VoiceRecordPermissionState {
    case undetermined
    case denied
    case granted
}

enum VoiceInputError: LocalizedError {
    case recordingFailed

    var errorDescription: String? {
        switch self {
        case .recordingFailed:
            return L10n.text("ui.recording_startup_failed")
        }
    }
}
