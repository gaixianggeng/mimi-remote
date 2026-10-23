import Foundation

/// Harness 首版只接受文本，权限由 Harness 维护；不能沿用 Codex 的输入与沙盒承诺。
enum RuntimeFeatureSupport {
    static let runtimeProviders = ["codex", "claude", "deepseek"]

    static func permissionModes(for provider: String) -> [ComposerPermissionMode] {
        isDeepSeek(provider) ? [.fullAccess] : ComposerPermissionMode.allCases
    }

    static func supportsAttachments(for provider: String) -> Bool { !isDeepSeek(provider) }
    static func supportsSkills(for provider: String) -> Bool { !isDeepSeek(provider) }
    static func supportsArchive(for provider: String) -> Bool { !isDeepSeek(provider) }
    static func supportsPlanning(for provider: String) -> Bool { !isDeepSeek(provider) }

    /// 目标任务以通道声明为准（`declaredBy` 来自 thread/goal/* 能力探测，#791）；Harness 不消费 goal 参数。
    static func supportsGoals(for provider: String, declaredBy goalProviders: Set<String>) -> Bool {
        !isDeepSeek(provider)
            && goalProviders.contains(CodexAppServerSessionRuntime.normalizedRuntimeProvider(provider))
    }

    static func isDeepSeek(_ provider: String?) -> Bool {
        CodexAppServerSessionRuntime.normalizedRuntimeProvider(provider) == "deepseek"
    }

    static func submissionError(for payload: CodexAppServerTurnPayload) -> String? {
        guard isDeepSeek(payload.options.runtimeProvider) else { return nil }
        let options = payload.options
        // 继承既有线程设置不改变权限；显式只读/工作区档位必须拒绝，不能自动提升。
        if !options.preservesThreadPermissionSettings,
           options.sandboxMode != .dangerFullAccess || options.permissionProfileID?.isEmpty == false {
            return L10n.text("ui.deepseek_requires_full_access")
        }
        if payload.input.contains(where: { if case .text = $0 { return false }; return true }) {
            return L10n.text("ui.deepseek_text_only")
        }
        if !payload.isEmpty, options.model?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            return L10n.text("ui.deepseek_models_unavailable")
        }
        return nil
    }
}
