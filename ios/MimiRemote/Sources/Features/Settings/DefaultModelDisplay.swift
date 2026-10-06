import Foundation

enum DefaultModelDisplay {
    static func inheritedTitle(
        for runtime: DefaultModelRuntime,
        allOptions: [CodexAppServerModelOption],
        isRefreshing: Bool
    ) -> String {
        // 默认项继续跟随解析策略，固定模型项则保存 ID；同名时也必须能区分。
        L10n.format("ui.default_model_inherited_name", title(
            for: runtime, allOptions: allOptions, isRefreshing: isRefreshing
        ))
    }

    static func title(
        for runtime: DefaultModelRuntime,
        allOptions: [CodexAppServerModelOption],
        isRefreshing: Bool
    ) -> String {
        let candidates = DefaultModelPreferences.options(for: runtime.rawValue, allOptions: allOptions)
        let option = ModelReasoningGridCatalog.preferredDefaultOption(
            runtimeProvider: runtime.rawValue,
            options: candidates
        )
        // 展示复用发送策略，但不写入偏好或把空选项改成显式选择。
        // Claude 离线兜底只有稳定别名，不能把它当成已解析的实际版本。
        if let option, !isUnresolvedClaudeAlias(option, runtime: runtime) {
            return option.menuTitle
        }
        return L10n.text(isRefreshing ? "ui.default_model_loading" : "ui.default_model_unconfirmed")
    }

    private static func isUnresolvedClaudeAlias(
        _ option: CodexAppServerModelOption,
        runtime: DefaultModelRuntime
    ) -> Bool {
        guard runtime == .claude else { return false }
        let title = option.title.lowercased()
        if option.model == "default", title == "default" { return true }
        return CodexAppServerModelOption.builtInClaudeFallback.contains {
            $0.model == option.model && (title == $0.title.lowercased() || title == $0.model)
        }
    }
}
