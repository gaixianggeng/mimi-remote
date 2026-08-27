import Foundation

enum ExperimentMenuRouting {
    static let menuTitle = "实验功能…"
    static let windowID = "experiments"
}

/// 实验功能窗口与菜单入口共用的展示规则。
enum ExperimentPresentation {
    static func codexStatusTitle(for state: CodexDesktopSyncState) -> String {
        switch state {
        case .disabled:
            "已关闭"
        case .notInstalled:
            "未安装"
        case .desktopNotRunning:
            "Desktop 未运行"
        case .connecting:
            "连接中"
        case .ready:
            "可用"
        case .unsupportedBuild:
            "版本不支持"
        case .socketUnavailable:
            "IPC 不可用"
        case .protocolError:
            "协议错误"
        case .legacyCleanupRequired:
            "需要清理旧配置"
        }
    }

    static func codexStatusDetail(
        for state: CodexDesktopSyncState,
        error: String? = nil,
        version: String? = nil,
        build: String? = nil
    ) -> String {
        let detail: String
        switch state {
        case .disabled:
            detail = "同步已关闭。Mimi Remote 继续使用独立 App Server。"
        case .notInstalled:
            detail = "未检测到 Codex Desktop。安装后可开启同步。"
        case .desktopNotRunning:
            detail = "请打开 Codex Desktop；Mimi 不会替你退出或重启 Desktop。"
        case .connecting:
            detail = "正在连接 Codex Desktop IPC。"
        case .ready:
            detail = "Codex Desktop IPC 已连接，可继续已明确归属的会话。"
        case .unsupportedBuild:
            let detected = [version, build].compactMap { $0 }.joined(separator: " / ")
            detail = detected.isEmpty
                ? "当前 Codex Desktop build 不在验证白名单内。首版只支持 26.820.60940 (7119)。"
                : "当前版本（\(detected)）不在验证白名单内。首版只支持 26.820.60940 (7119)。"
        case .socketUnavailable:
            detail = "Codex Desktop IPC 不可用。请确认 Desktop 正在运行并重试。"
        case .protocolError:
            detail = "Codex Desktop IPC 协议不兼容。请更新到支持的 Desktop build。"
        case .legacyCleanupRequired:
            detail = "检测到旧共享配置。确认 Codex Desktop 已退出后，执行一次遗留清理。"
        }

        guard let diagnostic = sanitizedDiagnostic(error),
              state == .protocolError || state == .socketUnavailable || state == .legacyCleanupRequired
        else {
            return detail
        }
        return detail + " 详情：" + diagnostic
    }

    static func codexToggleDescription(isEnabled: Bool) -> String {
        isEnabled
            ? "已开启：Mimi Remote 通过 Desktop IPC 同步会话；未验证的 build 会自动阻断。"
            : "已关闭：Mimi Remote 使用独立 App Server，不影响 Codex Desktop。"
    }

    static func menuStatusText(
        owner: ServiceOwner,
        codexState: CodexDesktopSyncState
    ) -> String? {
        guard owner == .macApp else { return "不可管理" }
        switch codexState {
        case .ready:
            return "已连接"
        case .connecting:
            return "连接中"
        case .unsupportedBuild:
            return "版本不支持"
        case .legacyCleanupRequired:
            return "需清理"
        case .disabled, .notInstalled, .desktopNotRunning, .socketUnavailable, .protocolError:
            return nil
        }
    }

    static func menuAccessibilityLabel(
        owner: ServiceOwner,
        codexState: CodexDesktopSyncState
    ) -> String {
        let title = "实验功能"
        guard let status = menuStatusText(owner: owner, codexState: codexState) else {
            return title
        }
        return "\(title)，\(status)"
    }

    private static func sanitizedDiagnostic(_ error: String?) -> String? {
        guard let error else { return nil }
        let value = error.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
