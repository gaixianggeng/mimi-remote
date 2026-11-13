import Foundation

/// Mimi 中转的后台任务和去重状态，都不直接驱动界面，所以不是 @Published。
struct MimiRelayRuntime {
    var task: Task<Void, Never>?
    var operationID: UUID?
    var profileID: String?
    var attemptKey: String?
    var backupAttemptID: String?
    var fallbackAttemptID: String?
    var computerChoiceTask: Task<Void, Never>?
    var computerChoiceCheckedAt: Date?
}

extension SessionStore {
    /// 只有明确选择 Mimi 后才自动配置；开通权益本身不改变用户的线路选择。
    static func shouldAutomaticallyActivateRelay(
        route: ConnectionProfileRoute?, connected: Bool, entitled: Bool, selectedMimi: Bool = false
    ) -> Bool {
        selectedMimi && route != nil && route?.isManaged == false && connected && entitled
    }

    func reconcileMimiRelay(_ entitlements: ManagedConnectionEntitlementStore, retry: Bool = false) {
        guard let profile = appStore.activeConnectionProfile else { cancelMimiRelay(); return }
        if mimiRelay.profileID != profile.id {
            cancelMimiRelay()
            mimiRelay.profileID = profile.id
        }
        guard mimiRelay.task == nil, !isAppInBackground, inFlightConnectionChangeGeneration == nil,
              !appStore.requiresRePairing, connectionTermination != .credentialsInvalid else { return }
        if retry { mimiRelay.attemptKey = nil; mimiRelay.fallbackAttemptID = nil; mimiRelay.backupAttemptID = nil }
        syncComputerRelayChoice(force: retry)
        let connected = appStore.connectionStatus.isConnected
        let entitled = ManagedConnectionDevicesView.hasEntitlementForUpgrade(
            status: entitlements.status, grant: entitlements.currentGrant, now: Date()
        )
        if tailcatExperimentController?.relayServiceChoice(profileID: profile.id) == .mimi,
           Self.shouldAutomaticallyActivateRelay(route: profile.connectionRoute, connected: connected, entitled: entitled, selectedMimi: true),
           ManagedConnectionSubscriptionView.isEntryVisible {
            let key = profile.id + ":" + (entitlements.currentGrant?.entitlement.id ?? "")
            guard mimiRelay.attemptKey != key else { return }
            mimiRelay.attemptKey = key
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
        if (expired || failed), mimiRelay.fallbackAttemptID != profile.id,
           appStore.authenticatedCredentialFingerprint != nil,
           case .usingTemporaryRoute = tailcatExperimentController?.state { return }
        if (expired || failed), mimiRelay.fallbackAttemptID != profile.id,
           appStore.authenticatedCredentialFingerprint != nil {
            mimiRelay.fallbackAttemptID = profile.id
            useFreeConnectionAfterRelayFailure()
        } else if connected, mimiRelay.backupAttemptID != profile.id,
                  tailcatExperimentController?.hasFreeRoute(profileID: profile.id) == false {
            mimiRelay.backupAttemptID = profile.id
            let scope = appStore.activeHostScope
            let operationID = UUID()
            mimiRelay.operationID = operationID
            mimiRelay.task = Task { @MainActor in
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
        guard mimiRelay.computerChoiceTask == nil, ManagedConnectionSubscriptionView.isEntryVisible, !isAppInBackground,
              let controller = tailcatExperimentController,
              let profile = appStore.activeConnectionProfile, profile.connectionRoute.usesTailcat,
              appStore.connectionStatus.isConnected else { return }
        let now = Date()
        if !force, let checkedAt = mimiRelay.computerChoiceCheckedAt, now.timeIntervalSince(checkedAt) < 5 { return }
        mimiRelay.computerChoiceCheckedAt = now
        let scope = appStore.activeHostScope
        mimiRelay.computerChoiceTask = Task { @MainActor in
            defer { mimiRelay.computerChoiceTask = nil }
            // 查询失败（旧版电脑、线路正在重建）不影响连接，下一次连接变化再查。
            guard let client = try? appStore.client(),
                  let choice = try? await client.tailcatRelayChoice(),
                  appStore.activeHostScope == scope, !Task.isCancelled else { return }
            followComputerRelayChoice(choice, profileID: profile.id, route: profile.connectionRoute, controller: controller)
        }
    }

    /// 让手机的待启用选择跟上电脑。电脑新选了 Mimi 是一次新的选择，上一次启用尝试的去重不能挡住它，
    /// 否则同一次运行里电脑切走再切回，手机会一直停在免费线路。
    /// 电脑离开 Mimi 而手机还没启用成功时要撤销选择：手机发起的启用会把电脑切到 Mimi，留着它，
    /// 下一次重试（回前台、下拉刷新）就会推翻用户刚在电脑上做的决定。只认「离开」这一下，
    /// 电脑一直没选 Mimi 时用户在手机上点启用是合法操作，不能被查询撤销。
    func followComputerRelayChoice(
        _ choice: ComputerRelayChoice, profileID: String, route: ConnectionProfileRoute,
        controller: TailcatExperimentController
    ) {
        let previous = controller.computerRelayChoice(profileID: profileID)
        if controller.noteComputerRelayChoice(choice, profileID: profileID) {
            mimiRelay.attemptKey = nil
            controller.selectRelayService(.mimi, profileID: profileID)
        } else if previous == .mimi, choice.relay != .mimi, !route.isManaged, mimiRelay.task == nil {
            abandonMimiSelection(profileID: profileID, controller: controller)
            mimiRelayNotice = nil
        }
    }

    private func abandonMimiSelection(profileID: String, controller: TailcatExperimentController) {
        guard controller.relayServiceChoice(profileID: profileID) == .mimi else { return }
        controller.selectRelayService(controller.lastFreeRelayChoice(profileID: profileID), profileID: profileID)
    }

    /// 定期执行，直到所在任务被取消。电脑改选中转时没有事件推给手机，中转服务页靠它在几秒内跟上。
    static func repeatUntilCancelled(
        every interval: Duration,
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        action: () -> Void
    ) async {
        while !Task.isCancelled {
            do { try await sleep(interval) } catch { return }
            guard !Task.isCancelled else { return }
            action()
        }
    }

    /// 下拉刷新：和回到前台一样重新核对电脑的选择和开通状态，失败过的启用也会再试一次。
    /// 查询结束才收起下拉指示。
    func refreshMimiRelay(_ entitlements: ManagedConnectionEntitlementStore) async {
        await afterComputerRelayChoiceCheck { reconcileMimiRelay(entitlements, retry: true) }
        await entitlements.refreshEntitlement()
        await mimiRelay.computerChoiceTask?.value
    }

    /// 等电脑的选择查回来再继续。重试会立刻发起启用，而启用会把电脑切到 Mimi；
    /// 不等结果，电脑刚离开 Mimi 时待启用的选择来不及撤销。
    func afterComputerRelayChoiceCheck(_ next: () -> Void) async {
        syncComputerRelayChoice(force: true)
        await mimiRelay.computerChoiceTask?.value
        next()
    }

    /// 手机上改回免费线路，长期生效。与启用共用连接事务，防止并发替换底层线路。
    /// 服务资格和设备名额都不动，所以随时可以再一键启用 Mimi。
    @discardableResult
    func switchToFreeRelay() async -> Bool {
        guard mimiRelay.task == nil, inFlightConnectionChangeGeneration == nil, !isAppInBackground,
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
        // 提交会递增连接代次，这里不能再和提交前的 scope 比较；只确认还是这台电脑。
        // 提交时旧连接已经断开，必须刷新才能恢复实时更新。
        guard appStore.activeConnectionProfileID == profile.id, !Task.isCancelled else { return true }
        _ = await refreshAfterConnectionCommit(maxWait: 10)
        return true
    }

    func cancelMimiRelay() {
        mimiRelay.computerChoiceTask?.cancel()
        mimiRelay.computerChoiceTask = nil
        mimiRelay.computerChoiceCheckedAt = nil
        if let profileID = mimiRelay.profileID {
            // 回滚后的操作已终止；立刻重试必须使用新编号，不能重新领取旧失败结果。
            tailcatExperimentController?.clearRelayActivationRequest(profileID: profileID)
        }
        mimiRelay.task?.cancel()
        mimiRelay.task = nil
        mimiRelay.operationID = nil
        mimiRelay.profileID = nil
        mimiRelay.attemptKey = nil
        mimiRelay.backupAttemptID = nil
        mimiRelay.fallbackAttemptID = nil
        isActivatingMimiRelay = false
        mimiRelayNotice = nil
    }

    func activateMimiRelay() {
        guard mimiRelay.task == nil, !isAppInBackground, inFlightConnectionChangeGeneration == nil,
              !appStore.requiresRePairing, connectionTermination != .credentialsInvalid,
              let controller = tailcatExperimentController else { return }
        do {
            let context = try ManagedConnectionUpgradeContext(appStore: appStore, client: appStore.client())
            controller.selectRelayService(.mimi, profileID: context.profile.id)
            mimiRelay.profileID = context.profile.id
            let operationID = UUID()
            mimiRelay.operationID = operationID
            isActivatingMimiRelay = true
            mimiRelayNotice = L10n.text("ui.relay_activating")
            mimiRelay.task = Task { @MainActor in
                defer { finishMimiRelay(operationID) }
                let requestID = controller.relayActivationRequestID(profileID: context.profile.id)
                // 回滚也会终止操作，包括传输失败；迟到的清理只能移除自己的编号。
                defer { controller.clearRelayActivationRequest(profileID: context.profile.id, matching: requestID) }
                do {
                    if context.profile.connectionRoute == .customTailcat {
                        try await controller.preserveFreeRoute(appStore: appStore)
                    }
                    let link = try await context.requestRelayActivation(requestID: requestID, appStore: appStore)
                    guard let url = URL(string: link.pairURL) else { throw AgentAPIError.invalidResponse }
                    _ = try await applyManagedPairingURL(url, upgrading: context)
                    guard appStore.activeConnectionProfileID == context.profile.id, !Task.isCancelled else { return }
                    mimiRelayNotice = L10n.text("ui.relay_enabled")
                    _ = await refreshAfterConnectionCommit(maxWait: 10)
                } catch is CancellationError {
                    await context.rollbackRelayActivation(requestID: requestID, appStore: appStore)
                    return
                } catch {
                    await context.rollbackRelayActivation(requestID: requestID, appStore: appStore)
                    guard context.isCurrent(in: appStore), !Task.isCancelled else { return }
                    if appStore.acceptsCredentialInvalidation(error) {
                        appStore.markCredentialsInvalid()
                        return
                    }
                    if !(error is URLError) {
                        // 被明确拒绝就放弃这次选择。手机发起的启用会把电脑切到 Mimi，
                        // 留着选择，每次回前台都会再失败并再切一次；用户可以随时点启用重试。
                        abandonMimiSelection(profileID: context.profile.id, controller: controller)
                    }
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
        mimiRelay.operationID = operationID
        mimiRelayNotice = L10n.text("ui.relay_trying_free")
        mimiRelay.task = Task { @MainActor in
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
        guard mimiRelay.operationID == operationID else { return }
        mimiRelay.task = nil
        mimiRelay.operationID = nil
        isActivatingMimiRelay = false
    }
}
