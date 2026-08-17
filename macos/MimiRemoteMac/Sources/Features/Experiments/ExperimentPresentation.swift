import Foundation

enum ExperimentMenuRouting {
    static let menuTitle = "实验功能…"
    static let windowID = "experiments"
}

/// 实验功能窗口与菜单入口共用的展示规则。
///
/// 这里仅描述已有 HostStore 状态，不保存或推导第二份配置；这样菜单、设置导航
/// 和实验功能窗口始终从同一个事实源渲染，也能在不依赖 SwiftUI 的情况下测试文案。
enum ExperimentPresentation {
    static func codexStatusTitle(for state: CodexDesktopStatusState) -> String {
        switch state {
        case .disabled:
            "已关闭"
        case .notInstalled:
            "未安装"
        case .backendNotShared:
            "后端未确认共享"
        case .pendingRestart:
            "需要重启"
        case .ready:
            "环境已配置"
        case .failed:
            "配置失败"
        case .externalConflict:
            "外部配置冲突"
        }
    }

    static func codexStatusDetail(
        for state: CodexDesktopStatusState,
        error: String? = nil
    ) -> String {
        let detail: String
        switch state {
        case .disabled:
            detail = "共享已关闭。Mimi Remote 仍使用独立服务；如果两端同时打开同一会话，可能发生写入冲突。"
        case .notInstalled:
            detail = "未检测到 Codex Desktop。请先安装后再启用共享。"
        case .backendNotShared:
            detail = "共享尚未生效。请先修复配置并确认 agentd 的共享服务；同一会话可能无法在两端打开。"
        case .pendingRestart:
            detail = "保存任务后应用设置并完全重启 Codex Desktop。"
        case .ready:
            detail = "环境已配置，待用同一空闲会话跨端验证；正在运行的任务仍只读。"
        case .failed:
            detail = "共享尚未生效，配置失败。请先修复配置后再重试；同一会话可能无法在两端打开。"
        case .externalConflict:
            detail = "共享尚未生效，检测到外部配置冲突。请先修复配置；同一会话可能无法在两端打开。"
        }

        guard state == .pendingRestart || state == .failed || state == .externalConflict,
              let diagnostic = sanitizedDiagnostic(error)
        else {
            return detail
        }
        return detail + " 详情：" + diagnostic
    }

    static func codexToggleDescription(isEnabled: Bool) -> String {
        if isEnabled {
            return "已开启：Mimi Remote 与 Codex Desktop 将尝试共享同一空闲会话；正在运行的任务仍只读。"
        }
        return "已关闭：Mimi Remote 仍使用独立服务；如果两端同时打开同一会话，可能发生写入冲突。"
    }

    /// 菜单入口只显示少量可行动的摘要；详细状态始终在实验功能窗口内查看。
    static func menuStatusText(
        owner: ServiceOwner,
        codexState: CodexDesktopStatusState
    ) -> String? {
        guard owner == .macApp else { return "不可管理" }
        switch codexState {
        case .pendingRestart:
            return "需要重启"
        case .ready:
            return "已启用"
        case .disabled, .notInstalled, .backendNotShared, .failed, .externalConflict:
            return nil
        }
    }

    static func menuAccessibilityLabel(
        owner: ServiceOwner,
        codexState: CodexDesktopStatusState
    ) -> String {
        let title = "实验功能"
        guard let status = menuStatusText(owner: owner, codexState: codexState) else {
            return title
        }
        return "\(title)，\(status)"
    }

    private static func sanitizedDiagnostic(_ error: String?) -> String? {
        guard let error else { return nil }
        var value = error.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        // 保留失败原因对诊断的价值，但把协议码和英文 writer 术语转成平静的
        // 用户文案，避免把底层 JSON-RPC 错误直接当作界面提示。
        value = value.replacingOccurrences(of: "-32600", with: "会话写入冲突")
        value = value.replacingOccurrences(
            of: "already has an active writer",
            with: "同一会话正在被其他端占用",
            options: [.caseInsensitive]
        )
        value = value.replacingOccurrences(
            of: "active writer",
            with: "同一会话占用",
            options: [.caseInsensitive]
        )
        return value
    }
}
