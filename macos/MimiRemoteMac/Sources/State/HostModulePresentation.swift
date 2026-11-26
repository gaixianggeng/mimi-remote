import Foundation

extension HostStore {
    // Tailcat 的只读展示状态（#896 拆出，HostStore 只保留会修改状态的操作）。
    var tailcatEnabled: Bool {
        tailcatStatus?.enabled ?? false
    }

    var canChangeTailcat: Bool {
        owner == .macApp && !isBusy && lifecycle != .loading && lifecycle != .starting
    }

    var tailcatDERPMapURL: String {
        tailcatStatus?.derpMapURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var tailcatIsManaged: Bool {
        tailcatStatus?.isManagedMode ?? false
    }

    nonisolated static let tailcatTagline = "免费可用 · 支持跨网"

    var tailcatStatusDetail: String {
        if owner == .homebrew {
            return "先完成 App 服务接管，再由 Mimi Remote Mac 管理 Tailcat 模块。"
        }
        if let tailcatError { return tailcatError }
        if let tailcatNotice { return tailcatNotice }
        if let error = tailcatStatus?.error, !error.isEmpty { return error }
        guard let tailcatStatus, tailcatStatus.enabled else {
            return "内置连接\(Self.tailcatTagline)。开启后即可扫码；Mimi 中转可在手机上开通。"
        }
        return "已配对 \(tailcatStatus.pairedDeviceCount) 台设备。"
    }

    var canChangeModules: Bool {
        owner == .macApp && !isBusy && lifecycle != .loading && lifecycle != .starting
    }
    func canChangeModule(_ module: HostModuleID) -> Bool {
        guard canChangeModules else { return false }
        guard module == .tailscale || module == .lan else { return true }
        guard let status else { return false }
        // 首次状态读取失败时没有可信开关方向，禁用网络 Toggle，避免把未知误画成关闭
        // 后再发送相反操作。已有快照会被标记为 stale，可继续作为显式操作的基线。
        return status.moduleStatusState != .unavailable || status.moduleStatus != nil
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
        guard !isOnboardingInProgress else { return false }
        if agentRegistrationState == .requiresApproval && owner != .homebrew {
            return false
        }
        guard status?.serviceOK == true else { return false }
        guard hasEnabledAssistantForPairing else { return false }
        return !availablePairingNetworks.isEmpty
    }

    private var hasEnabledAssistantForPairing: Bool {
        let enabledAgents: [HostModuleID] = [.codex, .claude, .agy, .deepseek].filter { moduleEnabled($0) }
        guard !enabledAgents.isEmpty else { return false }
        guard let runtimes = status?.runtimeStatus?.runtimes, !runtimes.isEmpty else {
            return true
        }
        return enabledAgents.contains { module in
            guard let runtime = runtime(for: module) else {
                // 旧版或局部状态快照未包含该运行时条目时，保留兼容判定；
                // 实时配对窗口由 `preflight --stage pair` 的 `assistant_any == ok` 严格门控。
                return true
            }
            return runtime.state == .available || runtime.state == .connected
        }
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
        pairingUnavailableReason(for: .automatic)
    }
    func pairingUnavailableReason(for selection: PairingNetwork) -> String {
        if !(codexEnabled || claudeEnabled || agyEnabled || deepSeekEnabled) {
            return "全部 AI 编程助手已关闭。请先启用至少一个助手。"
        }
        switch selection {
        case .localNetwork:
            if let lanError, !lanError.isEmpty { return lanError }
        case .tailscale:
            if let error = moduleError(.tailscale), !error.isEmpty { return error }
        case .tailcat:
            if let error = moduleError(.tailcat), !error.isEmpty { return error }
        case .automatic:
            break
        }
        if status?.serviceOK != true { return "Mac 服务尚未就绪，请先启动或修复服务。" }
        if status?.moduleStatusState == .unavailable {
            return "正在确认连接方式状态，请稍后刷新。"
        }
        switch selection {
        case .localNetwork:
            if !lanEnabled { return "局域网已关闭，请先在连接方式中明确启用。" }
            if status?.moduleStatus?.lanAvailable == false {
                return "未检测到可用的局域网 IPv4，请确认这台 Mac 已连接 Wi-Fi 或以太网。"
            }
        case .tailscale:
            if !tailscaleEnabled { return "Tailscale 已关闭，请先在菜单栏「连接方式」中开启。" }
            if status?.moduleStatus?.tailscaleAvailable == false {
                return "未检测到 Tailscale 地址，请先安装、登录并连接 Tailscale。"
            }
        case .tailcat:
            if !tailcatEnabled { return "内置连接尚未开启，请重试或前往设置开启。" }
            if tailcatStatus?.running != true { return "内置连接正在启动，请稍后重试。" }
        case .automatic:
            break
        }
        return "没有可用的连接方式。请开启并连接 Tailscale、局域网或 Tailcat 后再配对。"
    }
    /// 配对窗口切换连接方式或点击刷新仅刷新当前选定通道，严禁在选中时自动开启任何网络通道。
    func refreshPairingFromPicker(_ targetNetwork: PairingNetwork) async {
        await refreshPairing(network: targetNetwork)
    }

    func runtime(for module: HostModuleID) -> AgentRuntimeStatus? {
        guard module.isAgent else { return nil }
        return status?.runtimeStatus?.runtimes.first { $0.id.lowercased() == module.rawValue }
    }
    var deepSeekEnabled: Bool {
        deepSeekConfiguration?.enabled ?? runtime(for: .deepseek)?.enabled ?? false
    }
    var canChangeDeepSeek: Bool {
        owner == .macApp && !isBusy && lifecycle != .loading && lifecycle != .starting
    }
    var deepSeekStatusTitle: String {
        if isUpdatingDeepSeek { return "正在检查" }
        if deepSeekError != nil { return "需要处理" }
        if !deepSeekEnabled {
            return deepSeekConfiguration?.discovered == true ? "发现运行中的服务" : "未启用"
        }
        guard let runtime = runtime(for: .deepseek) else { return "等待服务加载" }
        if runtime.reason == "refresh_in_progress" { return "正在检查" }
        switch runtime.state {
        case .available, .connected: return "已连接"
        case .signedOut: return "需要更新启动链接"
        case .disabled: return "等待服务加载"
        case .unavailable: return "暂不可用"
        }
    }
    var deepSeekStatusDetail: String {
        if owner != .macApp { return "先由 Mimi Remote Mac 接管服务，再配置 DeepSeek。" }
        if let deepSeekError { return deepSeekError }
        if deepSeekEnabled, runtime(for: .deepseek)?.reason == "refresh_in_progress" {
            return "正在确认 agentd 与 Harness 的连接。"
        }
        if deepSeekEnabled, runtime(for: .deepseek)?.state == .signedOut {
            // agentd 已自动尝试过换凭据：走到这里说明本机取不到 Harness 的新启动链接。
            return "Harness 重启后，保存的启动凭据已失效，且没能自动更新（启动日志可能已被清理）。"
                + "重启 Harness 后点击重新检测，或在手动连接中粘贴新的启动链接。"
        }
        if deepSeekEnabled, runtime(for: .deepseek)?.state == .unavailable {
            return "Harness 暂不可用。确认它仍在运行后，点击重新检测。"
        }
        return deepSeekConfiguration?.message ?? "自动检测本机运行中的 Harness 后台服务。"
    }
    func moduleEnabled(_ module: HostModuleID) -> Bool {
        switch module {
        case .codex: codexEnabled
        case .claude: claudeEnabled
        case .agy: agyEnabled
        case .deepseek: deepSeekEnabled
        case .tailscale: tailscaleEnabled
        case .lan: lanEnabled
        case .tailcat: tailcatEnabled
        }
    }
    func moduleError(_ module: HostModuleID) -> String? {
        switch module {
        case .codex: codexError
        case .claude: claudeError
        case .agy: agyError
        case .deepseek: deepSeekError
        case .tailscale, .lan:
            networkErrorModule == module ? networkError : nil
        case .tailcat: tailcatError ?? tailcatStatus?.error
        }
    }
    func moduleStateTitle(_ module: HostModuleID) -> String {
        if updatingModule == module || (module == .claude && isUpdatingClaude) ||
            (module == .agy && isUpdatingAgy) ||
            (module == .tailcat && isUpdatingTailcat) ||
            (module == .deepseek && isUpdatingDeepSeek) { return "正在更新" }
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
            case .signedOut: return module == .deepseek ? "需要更新启动链接" : "需要登录"
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
        case .agy: await setAgyEnabled(enabled)
        case .deepseek: await setDeepSeekEnabled(enabled)
        case .tailscale: await setTailscaleEnabled(enabled)
        case .lan: await setLANEnabled(enabled)
        case .tailcat: await setTailcatEnabled(enabled)
        }
    }
}
