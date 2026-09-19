
// Kept in the same file as HostStore so configuration writes share its existing
// private lifecycle machinery and single-writer gate.
extension HostStore {
    var canManageModules: Bool {
        owner == .macApp && !isBusy && !isRefreshingStatus
            && lifecycle != .loading && lifecycle != .starting
            && status?.moduleConfiguration != nil
    }

    var modulesApplied: Bool {
        guard let desired = status?.moduleConfiguration,
              let running = status?.runtimeStatus?.modules else { return false }
        return desired.matchesResident(running)
    }

    func moduleEnabled(_ module: HostModule) -> Bool {
        if module == .tailcat, let tailcatStatus { return tailcatStatus.enabled }
        return status?.moduleConfiguration?.isEnabled(module)
            ?? moduleRuntime(module)?.enabled ?? false
    }

    func moduleRuntime(_ module: HostModule) -> AgentRuntimeStatus? {
        status?.runtimeStatus?.runtimes.first { $0.id == module.rawValue }
    }

    func moduleAvailable(_ module: HostModule) -> Bool {
        guard moduleEnabled(module), status?.serviceOK == true, !isBusy else { return false }
        if module == .tailcat { return tailcatStatus?.running == true }
        guard modulesApplied else { return false }
        if module.isAgent {
            guard status?.runtimeStatus?.isExpired() == false,
                  let runtime = moduleRuntime(module), runtime.enabled else { return false }
            return runtime.state == .connected || runtime.state == .available
        }
        return status?.connectionStatus?.first { $0.id == module.rawValue }?.available == true
    }

    var availablePairingNetworks: [PairingNetwork] {
        [HostModule.tailscale, .lan, .tailcat].filter { moduleAvailable($0) }.compactMap(\.network)
    }

    var pairingBlockReason: String? {
        if isBusy { return "正在应用设置，请稍后重新配对。" }
        guard status?.moduleConfiguration != nil else {
            return "请先完成 App 服务接管，并刷新新版 agentd 的模块状态。"
        }
        if !moduleEnabled(.codex) && !moduleEnabled(.claude) {
            return "所有 AI Agent 都已关闭。请在设置的 AI Agent 分组中启用至少一个。"
        }
        if !moduleAvailable(.codex) && !moduleAvailable(.claude) {
            return "尚无可用的 AI Agent，请检查登录状态、服务状态并刷新。"
        }
        if availablePairingNetworks.isEmpty {
            return "尚无可用连接方式。请在设置的连接方式分组中启用并检查一个通道。"
        }
        return nil
    }

    func moduleStateTitle(_ module: HostModule) -> String {
        if modulePending == module { return "正在应用" }
        guard status?.moduleConfiguration != nil else { return "需要更新状态" }
        if !moduleEnabled(module) { return "已关闭" }
        if module == .tailcat { return tailcatStatusTitle }
        if !modulesApplied { return "等待服务应用" }
        if status?.serviceOK != true { return "服务未就绪" }
        if module.isAgent {
            if status?.runtimeStatus?.isExpired() == true { return "状态已过期" }
            guard let runtime = moduleRuntime(module) else { return "正在检查" }
            switch runtime.state {
            case .connected, .available: return "可用"
            case .signedOut: return "需要登录"
            case .disabled: return "等待服务应用"
            case .unavailable:
                return runtime.reason == "refresh_in_progress" ? "正在检查" : "暂不可用"
            }
        }
        return moduleAvailable(module) ? "可用" : "暂不可用"
    }

    func moduleDetail(_ module: HostModule) -> String {
        switch module {
        case .codex:
            return "仅控制 Mimi 的 Codex 接入；关闭不会退出 Codex Desktop 或删除会话。"
        case .claude:
            return "通过本机 Claude bridge 接入。开启意图与登录、可用状态分别显示。"
        case .tailscale:
            return status?.connectionStatus?.first { $0.id == module.rawValue }?.reason
                ?? "仅控制 Mimi 的 Tailscale 通道，不会开启或关闭系统 Tailscale。网络变化后可重启 Mimi 服务。"
        case .lan:
            return status?.connectionStatus?.first { $0.id == module.rawValue }?.reason
                ?? "允许同一局域网的设备连接 Mimi，仍需配对鉴权。关闭后不接受此通道的新请求。"
        case .tailcat: return tailcatStatusDetail
        }
    }

    func invalidateModulePairing() {
        pairingRefreshGeneration &+= 1
        pairing = nil
    }

    func refreshModules() async {
        await refresh()
        if !isBusy { await refreshTailcatStatus() }
    }

    func setModuleEnabled(_ module: HostModule, enabled: Bool) async {
        guard canManageModules else { return }
        moduleUndo = nil
        invalidateModulePairing()
        _ = nextStatusRequestSequence()
        modulePending = module
        lastError = nil
        if module == .tailcat {
            let previous = tailcatEnabled
            await setTailcatEnabled(enabled)
            modulePending = nil
            if tailcatError == nil, tailcatEnabled == enabled, previous != enabled, !enabled {
                offerModuleUndo(module, change: nil)
            }
            return
        }
        isBusy = true
        defer {
            modulePending = nil
            isBusy = false
            if runtimeStatusNeedsFollowUp { scheduleRuntimeStatusFollowUp() }
        }
        var change: ModuleChange?
        do {
            let updated = try await agent.configureModule(module, enabled, nil, nil)
            change = updated
            if updated.restartRequired {
                try await reloadMacAgentForConfigurationChange()
            }
            try await waitForModuleConfiguration(updated.configuration)
            claudeConfiguration = nil
            if updated.changed && !enabled { offerModuleUndo(module, change: updated) }
        } catch {
            let originalError = error.localizedDescription
            guard let change, change.changed else {
                lastError = originalError
                return
            }
            do {
                let restored = try await agent.configureModule(module, nil, change.previous, change.revision)
                try await reloadMacAgentForConfigurationChange()
                try await waitForModuleConfiguration(restored.configuration)
                lastError = "修改未生效，已恢复原设置：\(originalError)"
            } catch {
                lastError = "修改失败：\(originalError)。自动恢复未完成：\(error.localizedDescription)。请打开诊断；不会覆盖后来修改的配置。"
            }
        }
    }

    func undoModuleChange() async {
        guard canManageModules, let undo = moduleUndo, undo.expiresAt > Date() else { return }
        moduleUndo = nil
        invalidateModulePairing()
        if undo.module == .tailcat {
            await refreshTailcatStatus()
            guard tailcatError == nil, !tailcatEnabled else { return }
            await setModuleEnabled(.tailcat, enabled: true)
            return
        }
        guard let change = undo.change else { return }
        isBusy = true
        modulePending = undo.module
        _ = nextStatusRequestSequence()
        defer { isBusy = false; modulePending = nil }
        do {
            let restored = try await agent.configureModule(undo.module, nil, change.previous, change.revision)
            if restored.restartRequired { try await reloadMacAgentForConfigurationChange() }
            try await waitForModuleConfiguration(restored.configuration)
            lastError = nil
        } catch {
            lastError = "撤销未完成：\(error.localizedDescription)。请刷新后检查模块状态。"
        }
    }

    private func offerModuleUndo(_ module: HostModule, change: ModuleChange?) {
        let undo = ModuleUndo(module: module, change: change)
        moduleUndo = undo
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard self?.moduleUndo?.id == undo.id else { return }
            self?.moduleUndo = nil
        }
    }

    private func waitForModuleConfiguration(_ expected: ModuleConfiguration) async throws {
        for attempt in 0..<8 {
            if let current = try await fetchAndApplyLatestStatus(),
               let running = current.runtimeStatus?.modules,
               running.matchesResident(expected) { return }
            if attempt < 7 { try await Task.sleep(for: .seconds(1)) }
        }
        throw AgentClientError.commandFailed("服务未确认新的模块配置已加载。")
    }
}
