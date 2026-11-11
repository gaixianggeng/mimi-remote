import AppKit
import SwiftUI

/// 「打开」菜单用到的本机 App 信息：装没装、图标。
@MainActor
enum SessionOpenApps {
    private static var icons: [String: NSImage] = [:]

    static func installedBundleIDs() -> Set<String> {
        let all = [SessionOpenTarget.codexDesktopBundleID, SessionOpenTarget.claudeDesktopBundleID]
            + TerminalApp.allCases.map(\.bundleID)
        return Set(all.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil })
    }

    static func icon(for target: SessionOpenTarget) -> NSImage? {
        if let cached = icons[target.bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 16, height: 16)
        icons[target.bundleID] = image
        return image
    }
}

/// Codex 桌面版没接本机 SSH 时的一次性说明：建议先配置，也允许直接打开。
@MainActor
enum CodexSharedHint {
    enum Choice: Equatable {
        case openAnyway(mute: Bool)
        case showGuide
        case cancel
    }

    static func present() -> Choice {
        let alert = NSAlert()
        alert.messageText = "Codex 桌面版还没有接入 Mimi 的共用服务"
        alert.informativeText = """
        在 Codex 桌面版里添加指向本机的 SSH 主机后，可以直接打开，手机和电脑能同时使用同一条会话。

        现在也可以直接打开。如果这条会话正被手机占用，Codex 桌面版会先报错；手机离开这条会话约 1 分钟后，点桌面版里的「重试」即可。
        """
        alert.addButton(withTitle: "仍然打开")
        alert.addButton(withTitle: "查看配置方法")
        alert.addButton(withTitle: "取消")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "不再提示"
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .openAnyway(mute: alert.suppressionButton?.state == .on)
        case .alertSecondButtonReturn: return .showGuide
        default: return .cancel
        }
    }
}
