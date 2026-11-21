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

/// 会话行「打开」按钮可选的去处：Codex 桌面版，或电脑上装着的终端。
enum SessionOpenTarget: Hashable, Sendable {
    case codexDesktop
    case terminal(TerminalApp)

    static let codexDesktopBundleID = "com.openai.codex"

    /// 写进偏好设置的值。
    var storageValue: String {
        switch self {
        case .codexDesktop: "desktop.codex"
        case .terminal(let app): "terminal." + app.rawValue
        }
    }

    init?(storageValue: String) {
        switch storageValue {
        case "desktop.codex": self = .codexDesktop
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
        case .terminal(let app): app.title
        }
    }

    var bundleID: String {
        switch self {
        case .codexDesktop: Self.codexDesktopBundleID
        case .terminal(let app): app.bundleID
        }
    }

    /// 已支持的桌面版始终列出。只支持终端接手、且未检测到终端时，仍提供系统终端。
    static func candidates(for runtime: SessionRuntime, installedBundleIDs: Set<String>) -> [SessionOpenTarget] {
        let terminals = TerminalApp.allCases
            .filter { installedBundleIDs.contains($0.bundleID) }
            .map(SessionOpenTarget.terminal)
        if let desktop = runtime.desktopOpenTarget {
            return [desktop] + terminals
        }
        return terminals.isEmpty ? [.terminal(.terminal)] : terminals
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
        case .terminal:
            return DesktopSessionActions.terminalUnavailableReason(for: session)
        }
    }

    func buttonTitle(for session: DesktopSession) -> String {
        "打开"
    }
}
