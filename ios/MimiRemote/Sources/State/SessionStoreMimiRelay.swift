import Foundation

extension SessionStore {
    /// 只有明确选择 Mimi 后才自动配置；开通权益本身不改变用户的线路选择。
    static func shouldAutomaticallyActivateRelay(
        route: ConnectionProfileRoute?, connected: Bool, entitled: Bool, selectedMimi: Bool = false
    ) -> Bool {
        selectedMimi && route != nil && route?.isManaged == false && connected && entitled
    }

    func reconcileMimiRelay(_ entitlements: ManagedConnectionEntitlementStore, retry: Bool = false) {
        guard let profile = appStore.activeConnectionProfile else { cancelMimiRelay(); return }
        if mimiRelayProfileID != profile.id {
            cancelMimiRelay()
            mimiRelayProfileID = profile.id
        }
        guard mimiRelayTask == nil, !isAppInBackground, inFlightConnectionChangeGeneration == nil,
              !appStore.requiresRePairing, connectionTermination != .credentialsInvalid else { return }
        if retry { mimiRelayAttemptKey = nil; mimiRelayFallbackAttemptID = nil; mimiRelayBackupAttemptID = nil }
        syncComputerRelayChoice(force: retry)
        let connected = appStore.connectionStatus.isConnected
        let entitled = ManagedConnectionDevicesView.hasEntitlementForUpgrade(
            status: entitlements.status, grant: entitlements.currentGrant, now: Date()
        )
        if tailcatExperimentController?.relayServiceChoice(profileID: profile.id) == .mimi,
           Self.shouldAutomaticallyActivateRelay(route: profile.connectionRoute, connected: connected, entitled: entitled, selectedMimi: true),
           ManagedConnectionSubscriptionView.isEntryVisible {
            let key = profile.id + ":" + (entitlements.currentGrant?.entitlement.id ?? "")
            guard mimiRelayAttemptKey != key else { return }
            mimiRelayAttemptKey = key
            activateMimiRelay()
            return
        }
        guard profile.connectionRoute.isManaged else { return }
        let expired: Bool
        switch entitlements.status {
        case .expired, .revoked, .available: expired = true
        default: expired = false // 查询失败或短暂刷新不是过期证据。
        }
        let failed: Bool
        if case .failed = appStore.connectionStatus { failed = true }
        else if case .failed = tailcatExperimentController?.state { failed = true }
        else { failed = false }
        if (expired || failed), mimiRelayFallbackAttemptID != profile.id,
           appStore.authenticatedCredentialFingerprint != nil,
           case .usingTemporaryRoute = tailcatExperimentController?.state { return }
        if (expired || failed), mimiRelayFallbackAttemptID != profile.id,
           appStore.authenticatedCredentialFingerprint != nil {
            mimiRelayFallbackAttemptID = profile.id
            useFreeConnectionAfterRelayFailure()
        } else if connected, mimiRelayBackupAttemptID != profile.id,
                  tailcatExperimentController?.hasFreeRoute(profileID: profile.id) == false {
            mimiRelayBackupAttemptID = profile.id
            let scope = appStore.activeHostScope
            let operationID = UUID()
            mimiRelayOperationID = operationID
            mimiRelayTask = Task { @MainActor in
                defer { finishMimiRelay(operationID) }
                guard appStore.activeHostScope == scope, !Task.isCancelled else { return }
                do { try await tailcatExperimentController?.preserveFreeRoute(appStore: appStore) }
                catch { /* 旧电脑没有免费备用接口时保留健康连接，不能把补齐失败显示成断线。 */ }
            }
        }
    }

    /// 读取电脑上选择的中转：页面据此显示实际线路；电脑改选 Mimi 时手机跟随，已开通的会自动启用。
    /// 回到前台、重连和打开中转页时检查，其余连接变化最多 5 秒查一次。
    func syncComputerRelayChoice(force: Bool = false) {
        guard computerRelayChoiceTask == nil, ManagedConnectionSubscriptionView.isEntryVisible, !isAppInBackground,
              let controller = tailcatExperimentController,
              let profile = appStore.activeConnectionProfile, profile.connectionRoute.usesTailcat,
              appStore.connectionStatus.isConnected else { return }
        let now = Date()
        if !force, let checkedAt = computerRelayChoiceCheckedAt, now.timeIntervalSince(checkedAt) < 5 { return }
        computerRelayChoiceCheckedAt = now
        let scope = appStore.activeHostScope
        computerRelayChoiceTask = Task { @MainActor in
            defer { computerRelayChoiceTask = nil }
            // 查询失败（旧版电脑、线路正在重建）不影响连接，下一次连接变化再查。
            guard let client = try? appStore.client(),
                  let choice = try? await client.tailcatRelayChoice(),
                  appStore.activeHostScope == scope, !Task.isCancelled else { return }
            if controller.noteComputerRelayChoice(choice, profileID: profile.id) {
                controller.selectRelayService(.mimi, profileID: profile.id)
            }
        }
    }

    /// 手机上改回免费线路，长期生效。与启用共用连接事务，防止并发替换底层线路。
    /// 服务资格和设备名额都不动，所以随时可以再一键启用 Mimi。
    @discardableResult
    func switchToFreeRelay() async -> Bool {
        guard mimiRelayTask == nil, inFlightConnectionChangeGeneration == nil, !isAppInBackground,
              !appStore.requiresRePairing, connectionTermination != .credentialsInvalid,
              let controller = tailcatExperimentController,
              let profile = appStore.activeConnectionProfile, profile.connectionRoute.isManaged,
              controller.hasFreeRoute(profileID: profile.id) else { return false }
        let scope = appStore.activeHostScope
        let previousChoice = controller.relayServiceChoice(profileID: profile.id)
        // 必须在提交前改掉选择：提交后的连接变化会触发对账，若还写着 Mimi 就会立刻被启用回去。
        controller.selectRelayService(controller.lastFreeRelayChoice(profileID: profile.id), profileID: profile.id)
        // 电脑可能还选着 Mimi：记为已看到，否则下一次检查会把这次改回当成新选择。
        _ = controller.noteComputerRelayChoice(ComputerRelayChoice(relay: .mimi, free: nil), profileID: profile.id)
        mimiRelayNotice = nil
        isSwitchingToFreeRelay = true
        defer { isSwitchingToFreeRelay = false }
        do {
            _ = try await performPreparedConnectionChange(
                isNavigationCurrent: { self.appStore.activeHostScope == scope }
            ) {
                try await controller.prepareFreeRouteSwitch(appStore: self.appStore)
            }
        } catch {
            controller.selectRelayService(previousChoice, profileID: profile.id)
            if !(error is CancellationError), appStore.activeHostScope == scope {
                mimiRelayNotice = L10n.format("ui.relay_switch_failed", error.localizedDescription)
            }
            return false
        }
        guard appStore.activeHostScope == scope, !Task.isCancelled else { return true }
        _ = await refreshAfterConnectionCommit(maxWait: 10)
        return true
    }

    func cancelMimiRelay() {
        computerRelayChoiceTask?.cancel()
        computerRelayChoiceTask = nil
        computerRelayChoiceCheckedAt = nil
        mimiRelayTask?.cancel()
        mimiRelayTask = nil
        mimiRelayOperationID = nil
        mimiRelayProfileID = nil
        mimiRelayAttemptKey = nil
        mimiRelayBackupAttemptID = nil
        mimiRelayFallbackAttemptID = nil
        isActivatingMimiRelay = false
        mimiRelayNotice = nil
    }

    func activateMimiRelay() {
        guard mimiRelayTask == nil, !isAppInBackground, inFlightConnectionChangeGeneration == nil,
              !appStore.requiresRePairing, connectionTermination != .credentialsInvalid,
              let controller = tailcatExperimentController else { return }
        do {
            let context = try ManagedConnectionUpgradeContext(appStore: appStore, client: appStore.client())
            controller.selectRelayService(.mimi, profileID: context.profile.id)
            mimiRelayProfileID = context.profile.id
            let operationID = UUID()
            mimiRelayOperationID = operationID
            isActivatingMimiRelay = true
            mimiRelayNotice = L10n.text("ui.relay_activating")
            mimiRelayTask = Task { @MainActor in
                defer { finishMimiRelay(operationID) }
                do {
                    if context.profile.connectionRoute == .customTailcat {
                        try await controller.preserveFreeRoute(appStore: appStore)
                    }
                    let requestID = controller.relayActivationRequestID(profileID: context.profile.id)
                    let link = try await context.requestRelayActivation(requestID: requestID, appStore: appStore)
                    guard let url = URL(string: link.pairURL) else { throw AgentAPIError.invalidResponse }
                    _ = try await applyManagedPairingURL(url, upgrading: context)
                    controller.clearRelayActivationRequest(profileID: context.profile.id)
                    guard appStore.activeConnectionProfileID == context.profile.id, !Task.isCancelled else { return }
                    mimiRelayNotice = L10n.text("ui.relay_enabled")
                    _ = await refreshAfterConnectionCommit(maxWait: 10)
                } catch is CancellationError {
                    return
                } catch {
                    guard context.isCurrent(in: appStore), !Task.isCancelled else { return }
                    if appStore.acceptsCredentialInvalidation(error) {
                        appStore.markCredentialsInvalid()
                        return
                    }
                    if !(error is URLError) { controller.clearRelayActivationRequest(profileID: context.profile.id) }
                    mimiRelayNotice = L10n.format("ui.relay_activation_failed", error.localizedDescription)
                    // 免费节点身份没有改变；启用失败时重新验证原连接，不要求用户重新扫码。
                    if context.profile.connectionRoute == .customTailcat {
                        _ = await controller.recoverRouteFromForeground(appStore: appStore)
                    }
                    _ = await appStore.preflightConnection(force: true)
                }
            }
        } catch { mimiRelayNotice = error.localizedDescription }
    }

    private func useFreeConnectionAfterRelayFailure() {
        guard let controller = tailcatExperimentController else { return }
        let scope = appStore.activeHostScope
        let operationID = UUID()
        mimiRelayOperationID = operationID
        mimiRelayNotice = L10n.text("ui.relay_trying_free")
        mimiRelayTask = Task { @MainActor in
            defer { finishMimiRelay(operationID) }
            // 尽量先补齐旧档案；即使过期，仍健康的直连也可登记免费授权。
            if let id = appStore.activeConnectionProfileID, !controller.hasFreeRoute(profileID: id),
               appStore.connectionStatus.isConnected {
                try? await controller.preserveFreeRoute(appStore: appStore)
            }
            guard appStore.activeHostScope == scope, !Task.isCancelled else { return }
            var recovered = await controller.useFreeRouteOnce(appStore: appStore)
            if !recovered, let route = appStore.savedFallbackConnectionRoute,
               !appStore.requiresRePairing, appStore.canUseSavedFallback(route),
               appStore.activeHostScope == scope, !Task.isCancelled {
                recovered = await controller.useSavedRouteOnce(route, appStore: appStore)
            }
            guard appStore.activeHostScope == scope, !Task.isCancelled else { return }
            mimiRelayNotice = L10n.text(recovered ? "ui.relay_using_free" : "ui.relay_free_unavailable")
            if recovered {
                resetConnectionForSettingsChange()
                _ = await refreshAfterConnectionCommit(maxWait: 10)
            }
        }
    }

    private func finishMimiRelay(_ operationID: UUID) {
        // 同一台电脑切走再切回时，旧任务的 defer 也不能清除新任务。
        guard mimiRelayOperationID == operationID else { return }
        mimiRelayTask = nil
        mimiRelayOperationID = nil
        isActivatingMimiRelay = false
    }
}
