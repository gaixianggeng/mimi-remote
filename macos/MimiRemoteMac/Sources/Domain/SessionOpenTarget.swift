import Foundation

/// 能接手「在终端继续」的终端（#991）。只列实测过能运行启动脚本的。
enum TerminalApp: String, CaseIterable, Sendable {
    case ghostty
    case herdr
    case terminal

    var bundleID: String {
        switch self {
        case .ghostty: "com.mitchellh.ghostty"
        case .herdr: "dev.herdr.app"
        case .terminal: "com.apple.Terminal"
        }
    }

    var title: String {
        switch self {
        case .ghostty: "Ghostty"
        case .herdr: "Herdr"
        case .terminal: "终端"
        }
    }
}

/// 会话行「打开」按钮可选的去处：对应助手的桌面版，或电脑上装着的终端。
enum SessionOpenTarget: Hashable, Sendable {
    case codexDesktop
    case claudeDesktop
    case terminal(TerminalApp)

    static let codexDesktopBundleID = "com.openai.codex"
    static let claudeDesktopBundleID = "com.anthropic.claudefordesktop"

    /// 写进偏好设置的值。
    var storageValue: String {
        switch self {
        case .codexDesktop: "desktop.codex"
        case .claudeDesktop: "desktop.claude"
        case .terminal(let app): "terminal." + app.rawValue
        }
    }

    init?(storageValue: String) {
        switch storageValue {
        case "desktop.codex": self = .codexDesktop
        case "desktop.claude": self = .claudeDesktop
        default:
            guard storageValue.hasPrefix("terminal."),
                  let app = TerminalApp(rawValue: String(storageValue.dropFirst("terminal.".count)))
            else { return nil }
            self = .terminal(app)
        }
    }

    var title: String {
        switch self {
        case .codexDesktop: "Codex 桌面版"
        case .claudeDesktop: "Claude 桌面版"
        case .terminal(let app): app.title
        }
    }

    var bundleID: String {
        switch self {
        case .codexDesktop: Self.codexDesktopBundleID
        case .claudeDesktop: Self.claudeDesktopBundleID
        case .terminal(let app): app.bundleID
        }
    }

    /// 这类会话的菜单里列哪些去处。桌面版总是列出（没装时灰显并说明），终端只列装着的。
    static func candidates(for runtime: SessionRuntime, installedBundleIDs: Set<String>) -> [SessionOpenTarget] {
        let desktop: SessionOpenTarget = runtime == .codex ? .codexDesktop : .claudeDesktop
        let terminals = TerminalApp.allCases
            .filter { installedBundleIDs.contains($0.bundleID) }
            .map(SessionOpenTarget.terminal)
        return [desktop] + terminals
    }

    /// 「打开」左半边用的去处：上次选的还在就用它，否则用第一个装着的。
    static func preferred(stored: String?, candidates: [SessionOpenTarget], installedBundleIDs: Set<String>) -> SessionOpenTarget? {
        if let stored, let target = SessionOpenTarget(storageValue: stored), candidates.contains(target) {
            return target
        }
        return candidates.first { installedBundleIDs.contains($0.bundleID) } ?? candidates.first
    }

    /// 现在不能用这个去处打开的原因；nil 表示可以。
    func unavailableReason(for session: DesktopSession, installedBundleIDs: Set<String>) -> String? {
        switch self {
        case .codexDesktop:
            return installedBundleIDs.contains(bundleID) ? nil : "没有找到 Codex 桌面版。"
        case .claudeDesktop:
            switch DesktopSessionActions.primary(for: session) {
            case .openInClaudeDesktop, .bringClaudeDesktopForward: return nil
            case .waitForTurn: return "这一轮结束后才能打开。"
            case nil:
                return session.holder == .claudeTerminal
                    ? "这条会话已经在终端里打开。"
                    : "电脑上另一个 Claude 正在使用这条会话。"
            }
        case .terminal:
            return DesktopSessionActions.terminalUnavailableReason(for: session)
        }
    }

    /// 桌面版已经开着这条会话时，按钮写「前往」。
    func buttonTitle(for session: DesktopSession) -> String {
        self == .claudeDesktop && session.holder == .claudeDesktop ? "前往" : "打开"
    }
}
