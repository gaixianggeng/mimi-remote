import Foundation

extension HostStore {
    var canChangeModules: Bool {
        owner == .macApp && !isBusy && lifecycle != .loading && lifecycle != .starting
    }
    var codexEnabled: Bool {
        status?.moduleStatus?.codexEnabled ?? runtime(for: .codex)?.enabled ?? true
    }
    var tailscaleEnabled: Bool {
        if let modules = status?.moduleStatus { return modules.tailscaleEnabled }
        guard let status else { return false }
        guard status.moduleStatusState != .unavailable else { return false }
        return status.networkStatus?.mode == "tailscale" || status.networkStatus?.allowLAN == true
    }
    var canPair: Bool {
        status?.serviceOK == true && (codexEnabled || claudeEnabled) && !availablePairingNetworks.isEmpty
    }
    var availablePairingNetworks: [PairingNetwork] {
        guard status?.serviceOK == true else { return [] }
        var networks: [PairingNetwork] = []
        if let modules = status?.moduleStatus, status?.moduleStatusState != .unavailable {
            if modules.tailscaleEnabled && modules.tailscaleAvailable { networks.append(.tailscale) }
            if modules.lanEnabled && modules.lanAvailable { networks.append(.localNetwork) }
        } else if status?.moduleStatusState != .unavailable,
                  let endpoint = status?.endpoint,
                  let host = URLComponents(string: endpoint)?.host,
                  host != "127.0.0.1", host != "localhost", host != "::1" {
            // Compatibility with an older daemon: only its concrete advertised endpoint.
            networks.append(PairingNetwork.inferred(from: endpoint))
        }
        if tailcatEnabled && tailcatStatus?.running == true { networks.append(.tailcat) }
        return networks
    }
    var pairingUnavailableReason: String {
        if !(codexEnabled || claudeEnabled) { return "全部 AI 编程助手已关闭。请先启用至少一个助手。" }
        if status?.serviceOK != true { return "Mac 服务尚未就绪，请先启动或修复服务。" }
        return "没有可用的连接方式。请开启并连接 Tailscale、局域网或 Tailcat 后再配对。"
    }
    func runtime(for module: HostModuleID) -> AgentRuntimeStatus? {
        guard module.isAgent else { return nil }
        return status?.runtimeStatus?.runtimes.first { $0.id.lowercased() == module.rawValue }
    }
    func moduleEnabled(_ module: HostModuleID) -> Bool {
        switch module {
        case .codex: codexEnabled
        case .claude: claudeEnabled
        case .tailscale: tailscaleEnabled
        case .lan: lanEnabled
        case .tailcat: tailcatEnabled
        }
    }
    func moduleError(_ module: HostModuleID) -> String? {
        switch module {
        case .codex: codexError
        case .claude: claudeError
        case .tailscale, .lan:
            networkErrorModule == module ? networkError : nil
        case .tailcat: tailcatError ?? tailcatStatus?.error
        }
    }
    func moduleStateTitle(_ module: HostModuleID) -> String {
        if updatingModule == module || (module == .claude && isUpdatingClaude) ||
            (module == .tailcat && isUpdatingTailcat) { return "正在更新" }
        if moduleError(module) != nil { return "失败" }
        if (module == .tailscale || module == .lan), status?.moduleStatusState == .unavailable {
            return "等待状态更新"
        }
        if !moduleEnabled(module) { return "已关闭" }
        guard status?.serviceOK == true else { return "等待服务启动" }
        if module.isAgent {
            guard let runtime = runtime(for: module) else { return "正在检查" }
            if status?.runtimeStatus?.isExpired() == true { return "等待状态更新" }
            switch runtime.state {
            case .available, .connected: return "可用"
            case .signedOut: return "需要登录"
            case .disabled: return "等待设置生效"
            case .unavailable: return runtime.reason == "refresh_in_progress" ? "正在检查" : "暂不可用"
            }
        }
        switch module {
        case .tailscale: return status?.moduleStatus?.tailscaleAvailable == true ? "本机地址可用" : "需要连接 Tailscale"
        case .lan: return status?.moduleStatus?.lanAvailable == true ? "本机地址可用" : "需要连接网络"
        case .tailcat: return tailcatStatus?.running == true ? "可用" : "正在检查"
        default: return "正在检查"
        }
    }
    func setModule(_ module: HostModuleID, enabled: Bool) async {
        switch module {
        case .codex: await setCodexEnabled(enabled)
        case .claude: await setClaudeEnabled(enabled)
        case .tailscale: await setTailscaleEnabled(enabled)
        case .lan: await setLANEnabled(enabled)
        case .tailcat: await setTailcatEnabled(enabled)
        }
    }
}
