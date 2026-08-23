import AVFoundation
import os
import Speech

/// 系统转写器会交替发布可变结果和最终结果；这里只保留一个可变尾段，
/// 最终结果按系统给出的顺序拼接，避免实时刷新时把同一段文字重复插入草稿。
struct AppleSpeechTranscriptAccumulator: Equatable {
    private(set) var finalizedText = ""
    private(set) var volatileText = ""

    var text: String {
        finalizedText + volatileText
    }

    mutating func apply(_ text: String, isFinal: Bool) {
        if isFinal {
            // 最终结果可能为空（系统撤回一段噪声误识别）；此时也必须清掉旧的 volatile 文本。
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                finalizedText += text
            }
            volatileText = ""
        } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            volatileText = text
        }
    }
}

/// 把“确实有人持续说话，但分析器迟迟没有新结果”的判定做成纯状态机，
/// 既避免一次咳嗽或环境噪声误触发，也便于不依赖真机 Speech 模型做回归测试。
struct AppleSpeechHealthMonitor: Equatable {
    static let audibleThreshold: CGFloat = 0.18
    static let sustainedAudioDuration: TimeInterval = 0.6
    static let maximumAudibleGap: TimeInterval = 0.35
    static let resultTimeout: TimeInterval = 5

    private var audibleSequenceStartedAt: TimeInterval?
    private var lastAudibleAt: TimeInterval?
    private var awaitingResultGeneration: Int?
    private var nextGeneration = 0

    mutating func observeLevel(_ level: CGFloat, at uptime: TimeInterval) -> Int? {
        guard level >= Self.audibleThreshold else {
            if let lastAudibleAt,
               uptime - lastAudibleAt > Self.maximumAudibleGap {
                // 已经停止连续发音时解除本代等待，避免短暂噪声或一句话后的静音误触发超时。
                audibleSequenceStartedAt = nil
                self.lastAudibleAt = nil
                awaitingResultGeneration = nil
            }
            return nil
        }

        if let lastAudibleAt,
           uptime - lastAudibleAt <= Self.maximumAudibleGap {
            // 当前声音仍属于同一段连续发音。
        } else {
            // 音频采样本身出现较长间隔时，也视为上一段发音已经结束。
            audibleSequenceStartedAt = uptime
            awaitingResultGeneration = nil
        }
        lastAudibleAt = uptime

        guard awaitingResultGeneration == nil else {
            return nil
        }
        guard let audibleSequenceStartedAt,
              uptime - audibleSequenceStartedAt >= Self.sustainedAudioDuration else {
            return nil
        }
        nextGeneration += 1
        awaitingResultGeneration = nextGeneration
        return nextGeneration
    }

    mutating func observeResult() {
        audibleSequenceStartedAt = nil
        lastAudibleAt = nil
        awaitingResultGeneration = nil
    }

    func isAwaitingResult(generation: Int) -> Bool {
        awaitingResultGeneration == generation
    }

    mutating func reset() {
        audibleSequenceStartedAt = nil
        lastAudibleAt = nil
        awaitingResultGeneration = nil
    }
}

enum AppleSpeechAudioSessionEvent: Equatable, Sendable {
    case interruptionBegan(reasonRawValue: UInt?)
    case interruptionEnded
    case mediaServicesReset

    static func interruption(from notification: Notification) -> Self? {
        guard notification.name == AVAudioSession.interruptionNotification,
              let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else {
            return nil
        }
        switch type {
        case .began:
            return .interruptionBegan(
                reasonRawValue: notification.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
            )
        case .ended:
            return .interruptionEnded
        @unknown default:
            return nil
        }
    }
}

enum AppleSpeechTranscriptionError: LocalizedError {
    case unsupportedLocale
    case audioFormatUnavailable
    case audioConversionFailed
    case recordingFailed
    case resultStreamEnded
    case noTranscriptionResult
    case audioSessionInterrupted
    case mediaServicesReset
    case startupTimedOut

    var errorDescription: String? {
        switch self {
        case .unsupportedLocale:
            return L10n.text("ui.apple_voice_input_does_not_support_the_current_language")
        case .audioFormatUnavailable:
            return L10n.text("ui.apple_voice_input_audio_format_is_unavailable")
        case .audioConversionFailed:
            return L10n.text("ui.apple_voice_input_audio_conversion_failed")
        case .recordingFailed:
            return L10n.text("ui.apple_voice_input_could_not_start_recording")
        case .resultStreamEnded, .noTranscriptionResult, .mediaServicesReset, .startupTimedOut:
            return L10n.text("ui.apple_voice_input_stopped_please_try_again")
        case .audioSessionInterrupted:
            return L10n.text("ui.apple_voice_input_was_interrupted_please_try_again")
        }
    }

    var diagnosticCode: String {
        switch self {
        case .unsupportedLocale:
            return "unsupported_locale"
        case .audioFormatUnavailable:
            return "audio_format_unavailable"
        case .audioConversionFailed:
            return "audio_conversion_failed"
        case .recordingFailed:
            return "recording_failed"
        case .resultStreamEnded:
            return "result_stream_ended"
        case .noTranscriptionResult:
            return "no_transcription_result"
        case .audioSessionInterrupted:
            return "audio_session_interrupted"
        case .mediaServicesReset:
            return "media_services_reset"
        case .startupTimedOut:
            return "startup_timeout"
        }
    }
}

/// iOS 26 的实时分析器只负责分析，实时麦克风采集仍由 App 管理。
/// 该对象限定在主线程持有生命周期；音频 tap 里只做同步格式转换和 AsyncStream yield。
@available(iOS 26.0, *)
@MainActor
final class AppleSpeechTranscriptionSession {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.gaixianggeng.mimi",
        category: "AppleSpeech"
    )

    private let sessionID: UUID
    private var analyzer: SpeechAnalyzer?
    private var audioEngine: AVAudioEngine?
    private let audioSessionCoordinator: VoiceAudioSessionCoordinator
    private var audioSessionActivation: VoiceAudioSessionCoordinator.Activation?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var audioSessionObserverTokens: [NSObjectProtocol] = []
    private var healthWatchdogTask: Task<Void, Never>?
    private var healthMonitor = AppleSpeechHealthMonitor()
    private var didReceiveFirstAudioBuffer = false
    private var didReceiveFirstResult = false
    private var didReportFailure = false
    private var acceptsTranscriptionResults = false
    private var isFinishing = false

    init(
        sessionID: UUID = UUID(),
        audioSessionCoordinator: VoiceAudioSessionCoordinator = .shared
    ) {
        self.sessionID = sessionID
        self.audioSessionCoordinator = audioSessionCoordinator
    }

    func logStartRequested(locale: Locale) {
        Self.logger.info(
            "start_requested id=\(self.sessionID.uuidString, privacy: .public) locale=\(locale.identifier, privacy: .public)"
        )
    }

    func logPermissionDone(granted: Bool) {
        Self.logger.info(
            "permission_done id=\(self.sessionID.uuidString, privacy: .public) granted=\(granted, privacy: .public)"
        )
    }

    func logStartupTimeout() {
        Self.logger.error(
            "startup_timeout id=\(self.sessionID.uuidString, privacy: .public)"
        )
    }

    func start(
        locale: Locale,
        onStartupMonitoringReady: @escaping @MainActor () -> Void,
        onTranscript: @escaping @MainActor (String) -> Void,
        onLevel: @escaping @MainActor (CGFloat) -> Void,
        onFailure: @escaping @MainActor (Error) -> Void
    ) async throws {
        guard analyzer == nil, audioEngine == nil else {
            throw AppleSpeechTranscriptionError.recordingFailed
        }
        isFinishing = false
        didReportFailure = false
        didReceiveFirstAudioBuffer = false
        didReceiveFirstResult = false
        acceptsTranscriptionResults = true
        healthMonitor.reset()
        Self.logger.info(
            "session_start id=\(self.sessionID.uuidString, privacy: .public) locale=\(locale.identifier, privacy: .public)"
        )
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            Self.logger.error(
                "session_start_failed id=\(self.sessionID.uuidString, privacy: .public) reason=unsupported_locale"
            )
            throw AppleSpeechTranscriptionError.unsupportedLocale
        }

        let transcriber = SpeechTranscriber(locale: supportedLocale, preset: .progressiveTranscription)
        let modules: [any SpeechModule] = [transcriber]
        if let installationRequest = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            try await installationRequest.downloadAndInstall()
        }
        try Task.checkCancellation()
        onStartupMonitoringReady()

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw AppleSpeechTranscriptionError.audioFormatUnavailable
        }
        let analyzer = SpeechAnalyzer(modules: modules)
        try await analyzer.prepareToAnalyze(in: analyzerFormat)
        try Task.checkCancellation()
        Self.logger.info(
            "analyzer_prepared id=\(self.sessionID.uuidString, privacy: .public)"
        )

        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.analyzer = analyzer
        inputContinuation = continuation
        startObservingAudioSession(onFailure: onFailure)

        resultsTask = Task { [weak self] in
            var accumulator = AppleSpeechTranscriptAccumulator()
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled,
                          let self,
                          self.acceptsTranscriptionResults else {
                        return
                    }
                    self.handleTranscriptionResult()
                    accumulator.apply(String(result.text.characters), isFinal: result.isFinal)
                    let transcript = accumulator.text
                    if !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        onTranscript(transcript)
                    }
                }
                guard let self, !self.isFinishing else { return }
                self.reportFailure(
                    AppleSpeechTranscriptionError.resultStreamEnded,
                    stage: "result_stream",
                    onFailure: onFailure
                )
            } catch is CancellationError {
                return
            } catch {
                guard let self, !self.isFinishing else { return }
                self.reportFailure(error, stage: "result_stream", onFailure: onFailure)
            }
        }

        try await analyzer.start(inputSequence: inputSequence)
        guard !isFinishing else {
            throw CancellationError()
        }
        Self.logger.info(
            "analyzer_started id=\(self.sessionID.uuidString, privacy: .public)"
        )
        do {
            try await startAudioCapture(
                analyzerFormat: analyzerFormat,
                continuation: continuation,
                onLevel: onLevel,
                onFailure: onFailure
            )
        } catch {
            stopObservingAudioSession()
            await cancel()
            throw error
        }
    }

    func finish() async throws {
        guard let analyzer else {
            return
        }
        Self.logger.info(
            "session_finish id=\(self.sessionID.uuidString, privacy: .public)"
        )
        isFinishing = true
        stopObservingAudioSession()
        healthWatchdogTask?.cancel()
        healthWatchdogTask = nil
        await stopAudioCapture()
        inputContinuation?.finish()
        inputContinuation = nil
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        reset()
    }

    func cancel() async {
        Self.logger.info(
            "session_cancel id=\(self.sessionID.uuidString, privacy: .public)"
        )
        isFinishing = true
        acceptsTranscriptionResults = false
        stopObservingAudioSession()
        healthWatchdogTask?.cancel()
        healthWatchdogTask = nil
        await stopAudioCapture()
        inputContinuation?.finish()
        inputContinuation = nil
        resultsTask?.cancel()
        if let analyzer {
            await analyzer.cancelAndFinishNow()
        }
        reset()
    }

    private func startAudioCapture(
        analyzerFormat: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        onLevel: @escaping @MainActor (CGFloat) -> Void,
        onFailure: @escaping @MainActor (Error) -> Void
    ) async throws {
        try Task.checkCancellation()
        let activation = try await audioSessionCoordinator.activate(onRecovery: { [weak self] succeeded in
            self?.recoverAudioCapture(succeeded: succeeded, onFailure: onFailure)
        })
        Self.logger.info(
            "audio_session_activated id=\(self.sessionID.uuidString, privacy: .public)"
        )
        do {
            // start() 等待系统会话期间可能已被取消；先检查，再触碰 MainActor 上的 engine。
            try Task.checkCancellation()

            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0,
                  inputFormat.channelCount > 0,
                  let converter = AppleSpeechAudioBufferConverter(from: inputFormat, to: analyzerFormat)
            else {
                throw AppleSpeechTranscriptionError.audioFormatUnavailable
            }

            var didFailConversion = false
            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
                guard !didFailConversion else { return }
                do {
                    let converted = try converter.convert(buffer)
                    continuation.yield(AnalyzerInput(buffer: converted))
                    let level = AppleSpeechAudioLevel.normalizedPower(from: buffer)
                    Task { @MainActor [weak self] in
                        self?.handleAudioLevel(level, onLevel: onLevel, onFailure: onFailure)
                    }
                } catch {
                    guard !didFailConversion else { return }
                    didFailConversion = true
                    continuation.finish()
                    Task { @MainActor [weak self] in
                        self?.reportFailure(
                            AppleSpeechTranscriptionError.audioConversionFailed,
                            stage: "audio_conversion",
                            onFailure: onFailure
                        )
                    }
                }
            }
            engine.prepare()
            do {
                try engine.start()
            } catch {
                inputNode.removeTap(onBus: 0)
                throw AppleSpeechTranscriptionError.recordingFailed
            }
            Self.logger.info(
                "audio_engine_started id=\(self.sessionID.uuidString, privacy: .public)"
            )
            audioEngine = engine
            audioSessionActivation = activation
            Self.logger.info(
                "audio_capture_started id=\(self.sessionID.uuidString, privacy: .public)"
            )
        } catch {
            await audioSessionCoordinator.deactivate(activation)
            throw error
        }
    }

    private func recoverAudioCapture(
        succeeded: Bool,
        onFailure: @escaping @MainActor (Error) -> Void
    ) {
        guard !isFinishing,
              audioSessionActivation != nil,
              let audioEngine else {
            return
        }
        guard succeeded else {
            reportFailure(
                AppleSpeechTranscriptionError.recordingFailed,
                stage: "audio_session_recovery",
                onFailure: onFailure
            )
            return
        }
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
            Self.logger.info(
                "audio_capture_recovered id=\(self.sessionID.uuidString, privacy: .public)"
            )
        } catch {
            reportFailure(
                AppleSpeechTranscriptionError.recordingFailed,
                stage: "audio_session_recovery",
                onFailure: onFailure
            )
        }
    }

    private func handleAudioLevel(
        _ level: CGFloat,
        onLevel: @escaping @MainActor (CGFloat) -> Void,
        onFailure: @escaping @MainActor (Error) -> Void
    ) {
        guard !isFinishing else { return }
        if !didReceiveFirstAudioBuffer {
            didReceiveFirstAudioBuffer = true
            Self.logger.info(
                "first_audio_buffer id=\(self.sessionID.uuidString, privacy: .public)"
            )
        }
        onLevel(level)

        let uptime = ProcessInfo.processInfo.systemUptime
        guard let generation = healthMonitor.observeLevel(level, at: uptime) else {
            return
        }
        Self.logger.info(
            "result_watchdog_armed id=\(self.sessionID.uuidString, privacy: .public) generation=\(generation)"
        )
        healthWatchdogTask?.cancel()
        healthWatchdogTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(AppleSpeechHealthMonitor.resultTimeout))
            } catch {
                return
            }
            guard let self,
                  !self.isFinishing,
                  self.healthMonitor.isAwaitingResult(generation: generation) else {
                return
            }
            self.reportFailure(
                AppleSpeechTranscriptionError.noTranscriptionResult,
                stage: "result_watchdog",
                onFailure: onFailure
            )
        }
    }

    private func handleTranscriptionResult() {
        healthMonitor.observeResult()
        healthWatchdogTask?.cancel()
        healthWatchdogTask = nil
        guard !didReceiveFirstResult else { return }
        didReceiveFirstResult = true
        Self.logger.info(
            "first_result id=\(self.sessionID.uuidString, privacy: .public)"
        )
    }

    private func startObservingAudioSession(
        onFailure: @escaping @MainActor (Error) -> Void
    ) {
        stopObservingAudioSession()
        let center = NotificationCenter.default
        let interruptionToken = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let event = AppleSpeechAudioSessionEvent.interruption(from: notification) else {
                return
            }
            Task { @MainActor [weak self] in
                self?.handleAudioSessionEvent(event, onFailure: onFailure)
            }
        }
        let resetToken = center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleAudioSessionEvent(.mediaServicesReset, onFailure: onFailure)
            }
        }
        audioSessionObserverTokens = [interruptionToken, resetToken]
    }

    private func stopObservingAudioSession() {
        let center = NotificationCenter.default
        audioSessionObserverTokens.forEach(center.removeObserver)
        audioSessionObserverTokens.removeAll()
    }

    private func handleAudioSessionEvent(
        _ event: AppleSpeechAudioSessionEvent,
        onFailure: @escaping @MainActor (Error) -> Void
    ) {
        guard !isFinishing else { return }
        switch event {
        case .interruptionBegan(let reasonRawValue):
            Self.logger.error(
                "audio_interruption_began id=\(self.sessionID.uuidString, privacy: .public) reason=\(String(describing: reasonRawValue), privacy: .public)"
            )
            reportFailure(
                AppleSpeechTranscriptionError.audioSessionInterrupted,
                stage: "audio_session",
                onFailure: onFailure
            )
        case .mediaServicesReset:
            Self.logger.error(
                "media_services_reset id=\(self.sessionID.uuidString, privacy: .public)"
            )
            reportFailure(
                AppleSpeechTranscriptionError.mediaServicesReset,
                stage: "audio_session",
                onFailure: onFailure
            )
        case .interruptionEnded:
            Self.logger.info(
                "audio_interruption_ended id=\(self.sessionID.uuidString, privacy: .public)"
            )
        }
    }

    private func reportFailure(
        _ error: Error,
        stage: String,
        onFailure: @escaping @MainActor (Error) -> Void
    ) {
        guard !isFinishing, !didReportFailure else { return }
        didReportFailure = true
        isFinishing = true
        acceptsTranscriptionResults = false
        stopObservingAudioSession()
        healthWatchdogTask?.cancel()
        healthWatchdogTask = nil

        let nsError = error as NSError
        let reason = (error as? AppleSpeechTranscriptionError)?.diagnosticCode ?? "system_error"
        Self.logger.error(
            "session_failed id=\(self.sessionID.uuidString, privacy: .public) stage=\(stage, privacy: .public) reason=\(reason, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code)"
        )
        onFailure(error)
    }

    private func stopAudioCapture() async {
        if let audioEngine {
            if audioEngine.isRunning {
                audioEngine.stop()
            }
            audioEngine.inputNode.removeTap(onBus: 0)
            self.audioEngine = nil
        }
        if let activation = audioSessionActivation {
            audioSessionActivation = nil
            await audioSessionCoordinator.deactivate(activation)
        }
    }

    private func reset() {
        resultsTask?.cancel()
        resultsTask = nil
        healthWatchdogTask?.cancel()
        healthWatchdogTask = nil
        stopObservingAudioSession()
        healthMonitor.reset()
        acceptsTranscriptionResults = false
        analyzer = nil
    }
}

/// Xcode 26 没有系统音频格式转换器，使用 AVAudioConverter 保持最低版本兼容。
private final class AppleSpeechAudioBufferConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat

    init?(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return nil
        }
        self.converter = converter
        self.outputFormat = outputFormat
    }

    func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let estimatedFrames = max(1, ceil(Double(input.frameLength) * ratio))
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(estimatedFrames)
        ) else {
            throw AppleSpeechTranscriptionError.audioConversionFailed
        }

        var conversionError: NSError?
        var suppliedInput = false
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard !suppliedInput else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return input
        }
        if let conversionError {
            throw conversionError
        }
        guard status == .haveData || status == .inputRanDry else {
            throw AppleSpeechTranscriptionError.audioConversionFailed
        }
        return output
    }
}

private enum AppleSpeechAudioLevel {
    static func normalizedPower(from buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let channelData = buffer.floatChannelData?[0] else {
            return 0
        }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else {
            return 0
        }
        var sumSquares: Float = 0
        for index in 0..<frameLength {
            let sample = channelData[index]
            sumSquares += sample * sample
        }
        let rms = sqrt(sumSquares / Float(frameLength))
        let decibels = 20 * log10(max(rms, 0.000_000_1))
        let clamped = max(-60, min(0, decibels))
        return CGFloat((clamped + 60) / 60)
    }
}
