import Foundation

enum VoiceInputProviderIcon: Equatable {
    case asset(String)
    case system(String)
}

/// 语音提供方是设备级偏好。Apple 负责设备端实时转写，
/// Codex 通过用户配置的主机复用现有登录态完成录音转写。
enum VoiceInputProvider: String, CaseIterable, Identifiable {
    static let storageKey = "voice.input.provider"
    static let appleTipAcknowledgedStorageKey = "voice.input.appleTipAcknowledged"

    case codex
    case apple

    var id: String { rawValue }

    /// Apple 实时语音 API 只在 iOS 26 及以上可用；通过系统能力判断集中管理提供方列表，
    /// 避免旧系统在设置页展示一个实际无法启动的 Apple 选项。
    static var supportsAppleRealtimeTranscription: Bool {
        if #available(iOS 26.0, *) {
            return true
        }
        return false
    }

    /// 返回当前系统可以真正使用的提供方。参数允许纯逻辑测试显式模拟旧系统能力。
    static func availableProviders(supportsAppleSpeech: Bool? = nil) -> [Self] {
        let supportsAppleSpeech = supportsAppleSpeech ?? Self.supportsAppleRealtimeTranscription
        return supportsAppleSpeech ? Array(allCases) : [.codex]
    }

    /// 将存储值解析为当前系统可用的提供方；旧系统读取到历史 apple 偏好时确定性回退 Codex，
    /// 但不改写 UserDefaults，从而保留用户原有偏好，待升级到 iOS 26 后仍可恢复选择。
    static func resolved(
        rawValue: String?,
        supportsAppleSpeech: Bool? = nil
    ) -> Self {
        let supportsAppleSpeech = supportsAppleSpeech ?? Self.supportsAppleRealtimeTranscription
        // 未选择提供方时优先设备端；旧系统仍使用可用的 Codex 转写。
        let provider = rawValue.flatMap(Self.init(rawValue:)) ?? .apple
        guard provider != .apple || supportsAppleSpeech else {
            return .codex
        }
        return provider
    }

    var title: String {
        switch self {
        case .codex:
            return L10n.text("ui.codex_voice_input")
        case .apple:
            return L10n.text("ui.apple_voice_input")
        }
    }

    /// 每个选项直接说明主要取舍，避免用户还要把底部整段说明映射回具体提供方。
    var subtitle: String {
        switch self {
        case .codex:
            return L10n.text("ui.codex_voice_input_description")
        case .apple:
            return L10n.text("ui.apple_voice_input_description")
        }
    }

    var icon: VoiceInputProviderIcon {
        switch self {
        case .codex:
            // 这里表达的是“录音后转写”能力，不再嵌入第三方品牌图标；
            // 使用系统波形后，也能和设备端的 Siri 标识保持同一套视觉语言。
            return .system("waveform")
        case .apple:
            return .system("siri")
        }
    }

    static func stored(
        in defaults: UserDefaults = .standard,
        supportsAppleSpeech: Bool? = nil
    ) -> VoiceInputProvider {
        // 新安装默认使用设备端转写；用户已保存的选择继续生效。
        resolved(
            rawValue: defaults.string(forKey: storageKey),
            supportsAppleSpeech: supportsAppleSpeech
        )
    }
}
