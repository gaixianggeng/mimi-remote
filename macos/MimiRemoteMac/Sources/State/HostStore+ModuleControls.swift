import Foundation

extension HostStore {
    func setLANEnabled(_ enabled: Bool) async {
        await setNetworkModule(.localNetwork, enabled: enabled)
    }

    func setTailscaleEnabled(_ enabled: Bool) async {
        await setNetworkModule(.tailscale, enabled: enabled)
    }

    func setCodexEnabled(_ enabled: Bool) async {
        guard canChangeModules else { return }
        isBusy = true
        updatingModule = .codex
        codexError = nil
        invalidateModulePairing()
        defer { updatingModule = nil; isBusy = false }
        do {
            let result = try await agent.configureCodex(enabled ? "enabled" : "disabled")
            guard result.enabled == enabled, !enabled || result.available else {
                codexError = result.message
                return
            }
            do {
                if result.restartRequired || status?.moduleStatus?.codexEnabled != enabled {
                    try await reloadMacAgentForConfigurationChange()
                }
                try await confirmAppliedModules(codexEnabled: enabled)
            } catch {
                let cause = error.localizedDescription
                if result.changed {
                    do {
                        let restored = try await agent.restoreCodex(result)
                        try await reloadMacAgentForConfigurationChange()
                        try await confirmAppliedModules(codexEnabled: restored.enabled)
                        codexError = "更新 Codex 失败：\(cause)。已恢复修改前设置。"
                    } catch {
                        codexError = "更新 Codex 失败：\(cause)。自动恢复未完成：\(error.localizedDescription)"
                    }
                } else { codexError = cause }
                await settleModuleChangeFailure(codexError ?? cause)
            }
        } catch {
            codexError = error.localizedDescription
            await settleModuleChangeFailure(error.localizedDescription)
        }
    }

    private func setNetworkModule(_ network: PairingNetwork, enabled: Bool) async {
        let module: HostModuleID = network == .tailscale ? .tailscale : .lan
        guard canChangeModule(module) else { return }
        isBusy = true
        updatingModule = module
        isUpdatingLAN = network == .localNetwork
        networkError = nil
        networkErrorModule = updatingModule
        lanError = nil
        invalidateModulePairing()
        defer { updatingModule = nil; isUpdatingLAN = false; isBusy = false }
        do {
            let result = try await agent.configureNetwork(network, enabled)
            do {
                if result.restartRequired || status?.moduleStatus?.lanEnabled != result.lanEnabled ||
                    status?.moduleStatus?.tailscaleEnabled != result.tailscaleEnabled {
                    try await reloadMacAgentForConfigurationChange()
                }
                try await confirmAppliedModules(network: result)
            } catch {
                let cause = error.localizedDescription
                if result.changed {
                    do {
                        let restored = try await agent.restoreNetwork(result)
                        try await reloadMacAgentForConfigurationChange()
                        try await confirmAppliedModules(network: restored)
                        networkError = "更新连接失败：\(cause)。已恢复修改前设置。"
                    } catch {
                        networkError = "更新连接失败：\(cause)。自动恢复未完成：\(error.localizedDescription)"
                    }
                } else { networkError = cause }
                await settleModuleChangeFailure(networkError ?? cause)
            }
        } catch {
            networkError = error.localizedDescription
            await settleModuleChangeFailure(error.localizedDescription)
        }
        lanError = networkError
    }

    func settleModuleChangeFailure(_ detail: String) async {
        guard lifecycle == .starting else { return }
        let applied: AgentStatus? = (try? await fetchAndApplyLatestStatus()) ?? nil
        if applied != nil, status?.serviceOK == false { return }
        lifecycle = .degraded(detail)
    }

    func confirmAppliedModules(codexEnabled: Bool? = nil, network: NetworkConfigurationResult? = nil) async throws {
        for attempt in 0..<3 {
            if let current = try await fetchAndApplyLatestStatus(), let modules = current.moduleStatus,
               current.serviceOK,
               codexEnabled == nil || modules.codexEnabled == codexEnabled,
               network == nil || (modules.lanEnabled == network?.lanEnabled &&
                                  modules.tailscaleEnabled == network?.tailscaleEnabled) {
                return
            }
            if attempt < 2 { try await Task.sleep(for: .milliseconds(300)) }
        }
        throw AgentClientError.commandFailed("运行中的 agentd 尚未确认模块设置，请检查版本并重启服务。")
    }

    func invalidateModulePairing() {
        pairingRefreshGeneration &+= 1
        statusRequestSequence &+= 1
        pairing = nil
    }

    func setClaudeEnabled(_ enabled: Bool) async {
        guard !isBusy, owner == .macApp else {
            claudeError = "请先启动并接管 Mimi Remote Mac 服务。"
            return
        }
        isBusy = true
        isUpdatingClaude = true
        claudeError = nil
        invalidateModulePairing()
        defer {
            isUpdatingClaude = false
            isBusy = false
        }

        do {
            let preference: ClaudeActivationPreference = enabled ? .enabled : .disabled
            let result = try await agent.configureClaude(preference, nil)
            claudeConfiguration = result
            guard !enabled || result.enabled else {
                claudeError = result.message
                return
            }
            do {
                if result.restartRequired || status?.moduleStatus?.claudeEnabled != result.enabled {
                    try await reloadMacAgentForConfigurationChange()
                }
                try await waitForManagedRuntime(id: "claude", enabled: result.enabled)
            } catch {
                let updateError = error
                if result.changed {
                    let rolledBack = await rollbackClaudeConfiguration(result)
                    let rollbackDetail = rolledBack
                        ? "已恢复修改前的 Claude 设置。"
                        : "自动恢复也失败，请打开诊断后重试。"
                    claudeError = "更新 Claude 设置失败：\(updateError.localizedDescription) \(rollbackDetail)"
                } else {
                    claudeError = "更新 Claude 设置失败：\(updateError.localizedDescription)"
                }
                await settleModuleChangeFailure(claudeError ?? updateError.localizedDescription)
            }
        } catch {
            claudeError = error.localizedDescription
            await settleModuleChangeFailure(error.localizedDescription)
        }
    }

    func waitForClaudeRuntime(enabled: Bool) async throws {
        try await waitForManagedRuntime(id: "claude", enabled: enabled)
    }

    func setAgyEnabled(_ enabled: Bool) async {
        guard !isBusy, owner == .macApp else {
            agyError = "请先启动并接管 Mimi Remote Mac 服务。"
            return
        }
        isBusy = true
        isUpdatingAgy = true
        agyError = nil
        invalidateModulePairing()
        defer {
            isUpdatingAgy = false
            isBusy = false
        }

        do {
            let preference: ClaudeActivationPreference = enabled ? .enabled : .disabled
            let result = try await agent.configureAgy(preference, nil)
            agyConfiguration = result
            guard !enabled || result.enabled else {
                agyError = result.message
                return
            }
            do {
                if result.restartRequired || status?.moduleStatus?.agyEnabled != result.enabled {
                    try await reloadMacAgentForConfigurationChange()
                }
                if result.enabled {
                    try await waitForManagedRuntime(id: "agy", enabled: true)
                } else {
                    _ = try? await fetchAndApplyLatestStatus()
                }
            } catch {
                let updateError = error
                if result.changed {
                    let rolledBack = await rollbackAgyConfiguration(result)
                    let rollbackDetail = rolledBack
                        ? "已恢复修改前的 Antigravity 设置。"
                        : "自动恢复也失败，请打开诊断后重试。"
                    agyError = "更新 Antigravity 设置失败：\(updateError.localizedDescription) \(rollbackDetail)"
                } else {
                    agyError = "更新 Antigravity 设置失败：\(updateError.localizedDescription)"
                }
                await settleModuleChangeFailure(agyError ?? updateError.localizedDescription)
            }
        } catch {
            agyError = error.localizedDescription
            await settleModuleChangeFailure(error.localizedDescription)
        }
    }

    private func rollbackAgyConfiguration(_ previous: AgyConfigurationResult) async -> Bool {
        do {
            let restored = try await agent.restoreAgy(previous)
            agyConfiguration = restored
            try await reloadMacAgentForConfigurationChange()
            _ = try? await fetchAndApplyLatestStatus()
            return true
        } catch {
            return false
        }
    }

    /// 通用受管运行时状态轮询，供 Claude 及后续常驻适配器运行时（如 Antigravity）复用。
    func waitForManagedRuntime(id runtimeID: String, enabled: Bool) async throws {
        isAwaitingServiceStart = true
        defer { isAwaitingServiceStart = false }
        for attempt in 0..<12 {
            try Task.checkCancellation()
            if let current = try? await fetchAndApplyLatestStatus() {
                if let runtime = current.runtimeStatus?.runtimes.first(where: {
                    $0.id.caseInsensitiveCompare(runtimeID) == .orderedSame
                }) {
                    if !enabled, !runtime.enabled || runtime.state == .disabled {
                        return
                    }
                    if enabled {
                        switch runtime.state {
                        case .connected, .available:
                            return
                        case .signedOut:
                            throw ClaudeRuntimeControlError.signedOut
                        case .unavailable where runtime.reason != "refresh_in_progress":
                            throw ClaudeRuntimeControlError.unavailable
                        case .disabled:
                            throw ClaudeRuntimeControlError.disabled
                        case .unavailable:
                            break
                        }
                    }
                }
            }
            if attempt < 11 {
                try await Task.sleep(for: .seconds(1))
            }
        }
        throw ClaudeRuntimeControlError.timedOut(enabled: enabled)
    }

    func reconcileClaudeConfigurationAtLaunch() async -> Bool {
        do {
            let result = try await agent.configureClaude(.automatic, nil)
            claudeConfiguration = result
            claudeError = result.available || result.preference == .disabled
                ? nil
                : result.message
            return result.restartRequired
        } catch {
            claudeError = "Claude 自动检测失败：\(error.localizedDescription)"
            return false
        }
    }

    private func rollbackClaudeConfiguration(_ changed: ClaudeConfigurationResult) async -> Bool {
        do {
            let restored = try await agent.restoreClaude(changed)
            claudeConfiguration = restored
            try await reloadMacAgentForConfigurationChange()
            try await waitForManagedRuntime(id: "claude", enabled: restored.enabled)
            return true
        } catch {
            return false
        }
    }

    func inspectDeepSeek() async {
        guard owner == .macApp, !isUpdatingDeepSeek, !isBusy else { return }
        isUpdatingDeepSeek = true
        defer { isUpdatingDeepSeek = false }
        do {
            let result = try await agent.configureDeepSeek(.inspect, nil)
            deepSeekConfiguration = result
            deepSeekError = result.enabled && !result.available ? result.message : nil
        } catch {
            deepSeekError = error.localizedDescription
        }
    }

    func configureDeepSeek(_ action: DeepSeekConfigurationAction, startupURL: String? = nil) async {
        guard canChangeDeepSeek, !isUpdatingDeepSeek else { return }
        isBusy = true
        isUpdatingDeepSeek = true
        deepSeekError = nil
        defer {
            isUpdatingDeepSeek = false
            isBusy = false
        }
        do {
            let result = try await agent.configureDeepSeek(action, startupURL)
            deepSeekConfiguration = result
            deepSeekError = result.enabled && !result.available ? result.message : nil
            if result.restartRequired {
                do {
                    try await reloadMacAgentForConfigurationChange(fastRestart: true)
                } catch {
                    deepSeekError = "配置已保存，但 agentd 重新加载失败。请重试启动服务。\(error.localizedDescription)"
                    fail(error)
                    return
                }
            }
            await refreshMacAgentStatus()
            if runtimeStatusNeedsFollowUp { scheduleRuntimeStatusFollowUp() }
        } catch {
            deepSeekError = error.localizedDescription
        }
    }

    func setDeepSeekEnabled(_ enabled: Bool) async {
        await configureDeepSeek(enabled ? .connect : .disabled)
    }

    func reconcileDeepSeekConfigurationAtLaunch() async -> Bool {
        do {
            let result = try await agent.configureDeepSeek(.refresh, nil)
            deepSeekConfiguration = result
            deepSeekError = nil
            return result.restartRequired
        } catch {
            deepSeekError = "DeepSeek 自动检测失败：\(error.localizedDescription)"
            return false
        }
    }

    func refreshTailcatStatus() async {
        await refreshTailcatStatus(allowDuringUpdate: false)
    }

    private func refreshTailcatStatus(allowDuringUpdate: Bool) async {
        guard owner == .macApp, allowDuringUpdate || !isUpdatingTailcat else { return }
        let generation = pairingRefreshGeneration
        tailcatStatusRequestSequence &+= 1
        let requestSequence = tailcatStatusRequestSequence
        do {
            let current = try await agent.tailcatStatus()
            guard generation == pairingRefreshGeneration,
                  requestSequence == tailcatStatusRequestSequence else { return }
            tailcatStatus = current
            if !isUpdatingTailcat { tailcatError = nil }
            if current.error != nil || !current.running { tailcatNotice = nil }
        } catch {
            guard generation == pairingRefreshGeneration,
                  requestSequence == tailcatStatusRequestSequence else { return }
            tailcatError = error.localizedDescription
        }
    }

    func setTailcatEnabled(_ enabled: Bool) async {
        guard !isBusy, owner == .macApp else {
            tailcatError = "请先启动并接管 Mimi Remote Mac 服务。"
            return
        }
        isBusy = true
        isUpdatingTailcat = true
        tailcatStatusRequestSequence &+= 1
        tailcatError = nil
        invalidateModulePairing()
        tailcatNotice = nil
        defer {
            isUpdatingTailcat = false
            isBusy = false
        }
        do {
            tailcatStatus = try await agent.setTailcatEnabled(enabled)
            if !enabled, pairingNetwork == .tailcat {
                pairing = nil
                pairingNetwork = .tailscale
            }
        } catch {
            let updateError = error.localizedDescription
            await refreshTailcatStatus(allowDuringUpdate: true)
            tailcatError = updateError
        }
    }

    func configureTailcatDERPMap(_ derpMapURL: String) async {
        guard !isBusy, owner == .macApp else {
            tailcatError = "请先启动并接管 Mimi Remote Mac 服务。"
            return
        }
        isBusy = true
        isUpdatingTailcat = true
        tailcatStatusRequestSequence &+= 1
        tailcatError = nil
        invalidateModulePairing()
        tailcatNotice = nil
        let wasEnabled = tailcatEnabled
        defer {
            isUpdatingTailcat = false
            isBusy = false
        }
        do {
            tailcatStatus = try await agent.configureTailcatDERPMap(derpMapURL)
            if pairingNetwork == .tailcat {
                pairing = nil
                pairingNetwork = .tailscale
            }
            tailcatNotice = wasEnabled
                ? "中转已更新，请在手机上重新扫码。"
                : "中转配置已保存，开启内置连接后生效。"
        } catch {
            tailcatError = error.localizedDescription
        }
    }

    func setTailcatManagedMode(_ managed: Bool) async {
        guard !isBusy, owner == .macApp else {
            tailcatError = "请先启动并接管 Mimi Remote Mac 服务。"
            return
        }
        isBusy = true
        isUpdatingTailcat = true
        tailcatStatusRequestSequence &+= 1
        tailcatError = nil
        invalidateModulePairing()
        tailcatNotice = nil
        let wasEnabled = tailcatEnabled
        defer {
            isUpdatingTailcat = false
            isBusy = false
        }
        do {
            tailcatStatus = try await agent.setTailcatManagedMode(managed)
            if pairingNetwork == .tailcat {
                pairing = nil
                pairingNetwork = .tailscale
            }
            if managed {
                tailcatNotice = wasEnabled
                    ? "本机已启用 Mimi 中转。已开通的手机可使用中转，免费连接继续可用。"
                    : "本机已准备好 Mimi 中转，开启内置连接后生效。"
            } else {
                tailcatNotice = "本机已停用 Mimi 中转。手机会尝试免费备用线路；旧设备可能需要重新扫码。"
            }
        } catch {
            tailcatError = error.localizedDescription
        }
    }

    func resetTailcat() async {
        guard !isBusy, owner == .macApp, tailcatEnabled else { return }
        isBusy = true
        isUpdatingTailcat = true
        tailcatStatusRequestSequence &+= 1
        tailcatError = nil
        invalidateModulePairing()
        tailcatNotice = nil
        defer {
            isUpdatingTailcat = false
            isBusy = false
        }
        do {
            tailcatStatus = try await agent.resetTailcat()
            if pairingNetwork == .tailcat {
                pairing = nil
            }
        } catch {
            tailcatError = error.localizedDescription
        }
    }
}
