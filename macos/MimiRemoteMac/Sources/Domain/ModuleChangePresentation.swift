import Foundation

enum ModuleChangePresentation {
    static func impact(_ module: HostModuleID, enabled: Bool) -> String {
        if module == .tailcat {
            return enabled
                ? "仅启动 Mimi 的 Tailcat 通道，不重启系统 Tailscale。原有配对保留。"
                : "Tailcat 上的移动连接会断开。Tailscale 与局域网连接不变，已保存配对保留。"
        }
        return "此操作可能重新加载 Mac 服务，所有移动连接会短暂断开，执行中的任务可能受影响。其他模块的启用设置及已有配对不会删除。\n\n" + boundary(module)
    }

    static func boundary(_ module: HostModuleID) -> String {
        switch module {
        case .codex: "仅管理 Mimi 对 Codex 的访问，不退出 Codex Desktop 或删除会话。"
        case .claude: "仅管理 Mimi 的 Claude 通道，不删除 Claude 登录与历史。"
        case .tailscale: "只允许或拒绝 Mimi 端口上的 Tailscale IPv4 连接，不修改系统 Tailscale 或其他应用。"
        case .lan: "只允许或拒绝 Mimi 端口上的局域网 IPv4 连接。关闭后保留本机管理通道；不会因此关闭已启用的 Tailscale 或 Tailcat。"
        case .tailcat: "独立 sidecar 通道，可与 Tailscale、局域网同时开启。重置身份与修改中继需要单独确认。"
        }
    }
}
