import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var sessionStore: SessionStore
    @EnvironmentObject private var themeStore: ThemeStore
    @EnvironmentObject private var workspaceAppearanceStore: WorkspaceAppearanceStore
    @EnvironmentObject private var notificationResponseAdapter: SessionNotificationResponseAdapter
    @EnvironmentObject private var lockScreenApprovalStore: LockScreenApprovalStore
    @EnvironmentObject private var hostStatusStore: HostStatusStore
    @EnvironmentObject private var tailcatExperimentController: TailcatExperimentController
    @EnvironmentObject private var managedConnectionEntitlementStore: ManagedConnectionEntitlementStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingLogInspector = false
    @SceneStorage("root.lastSessionSnapshot") private var lastSessionSnapshot = ""
    @SceneStorage("root.workbenchRoute.v1") private var workbenchRouteStorage = WorkbenchRestorationRoute.defaultStorageValue
    @SceneStorage("root.hostRestoration.v2") private var hostRestorationStorage = ""
    @State private var notificationRouteAlertMessage: String?
    @State private var hasCompletedInitialBootstrap = false
    @State private var workbenchRouteRevision: UInt64 = 0
    @State private var pendingNotificationRouteRevision: UInt64?
    @State private var activeRestorationProfileID: String?
    /// 严格表示“后台之后还欠一次 Tailcat 重启”；它不再是通知闸门的条件，
    /// 只保证下一次进入前台仍会重试恢复。
    @State private var needsTailcatRecoveryAfterBackground = false
    @State private var foregroundResumeTask: Task<Void, Never>?
    @State private var foregroundResume = ForegroundResumeTracker()
    /// 恢复失败的提示每条通知只弹一次；用户反复切前后台不该被同一条通知反复打断。
    @State private var lastResumeFailureAlertDeliveryID: String?

    var body: some View {
        let tokens = themeStore.tokens(for: colorScheme)

        Group {
            if appStore.canEnterWorkbench {
                appShell
            } else {
                SettingsView(isInitialSetup: true)
                    .environment(\.themeSystemColorScheme, colorScheme)
            }
        }
        .task(id: appStore.activeHostScope) {
            migrateLegacyWorkspaceAppearance()
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            // StoreKit 当前权益是冷启动与回到前台时的本地事实入口。
            // 只有发现 Apple 已验证的交易后，Store 才会把两份签名 JWS 发给权益服务。
            await managedConnectionEntitlementStore.refreshEntitlement()
            await managedConnectionEntitlementStore.refreshProducts()
        }
        .task {
            // 从 App 启动开始监听未完成和后续交易；任务随 RootView 生命周期取消。
            await managedConnectionEntitlementStore.observeTransactionUpdates()
        }
        .task {
            await managedConnectionEntitlementStore.observeStorefrontUpdates()
        }
        .task(id: managedConnectionEntitlementStore.currentGrant?.tokenExpiresAt) {
            // App 长时间停留前台时，也要在短期 Token 到期前主动续期。
            await managedConnectionEntitlementStore.maintainCurrentGrant()
        }
        .onChange(of: appStore.connectionProfiles) { _, _ in
            // 删除重复 endpoint 后，旧数据可能刚刚变成可唯一归属；此时立即重试，
            // 不要求用户先进入工作区页面才能恢复原来的图标偏好。
            migrateLegacyWorkspaceAppearance()
        }
        .task {
            restoreActiveHostNavigationIfNeeded()
            defer { hasCompletedInitialBootstrap = true }
            // 预热窗口必须早于 Tailcat 选路和第一次 preflight：冷启动的首个探测在隧道
            // 建好之前几乎必然失败，而那只是过程，不能让首屏先渲染成运行时不可用。
            // bootstrap 和它内部的退避重试各自再持有一份，窗口一直开到这条启动链路走完。
            let warmUpToken = sessionStore.beginConnectionWarmUp()
            defer { sessionStore.endConnectionWarmUp(warmUpToken) }
            // Tailcat 本地转发必须先于首批 REST/WebSocket client 建立；关闭实验时此调用立即返回。
            let tailcatReady = await tailcatExperimentController.prepareRoute(appStore: appStore)
            guard !tailcatExperimentController.isEnabled || tailcatReady else { return }
#if targetEnvironment(macCatalyst)
            // Catalyst 先完成本机选路，再创建首批 REST/WebSocket client；否则并行 bootstrap
            // 可能已经拿 Tailscale 地址建好 runtime，导致本次启动无法真正切到 loopback。
            await appStore.preflightConnection()
#endif
            let requestedRoute = workbenchRoute
            let requestedRouteRevision = workbenchRouteRevision
            let requestedSnapshot = decodedSessionRestoreSnapshot
            await sessionStore.bootstrap()

            guard workbenchRoute == requestedRoute,
                  workbenchRouteRevision == requestedRouteRevision else {
                return
            }
            guard requestedRoute.detailSessionID != nil else {
                return
            }
            guard let requestedSnapshot else {
                // endpoint 或快照失效时安全回到列表，但不能覆盖 bootstrap 期间产生的新导航。
                setWorkbenchRoute(.sessions)
                return
            }

            let restoreLease = sessionStore.currentSelectionLease()
            let restoredSession = await sessionStore.resolveSessionForRestore(requestedSnapshot)
            guard workbenchRoute == requestedRoute,
                  workbenchRouteRevision == requestedRouteRevision,
                  sessionStore.isSelectionLeaseCurrent(restoreLease) else {
                return
            }
            guard let restoredSession else {
                setWorkbenchRoute(.sessions)
                return
            }
            _ = await sessionStore.selectSession(
                restoredSession,
                reason: .restoration,
                ifCurrent: restoreLease
            )
        }
        .task {
            // SwiftUI 不保证兄弟 .task 的执行顺序，所以这条 preflight 必须自己持有一份预热窗口，
            // 不能依赖上面的启动任务先抢到令牌；否则它的首次失败仍会抢先发布 .failed。
            // 预热是引用计数的，两条链路各持有一份不会互相提前关窗。
            let warmUpToken = sessionStore.beginConnectionWarmUp()
            defer { sessionStore.endConnectionWarmUp(warmUpToken) }
            let tailcatReady = await tailcatExperimentController.prepareRoute(appStore: appStore)
            guard !tailcatExperimentController.isEnabled || tailcatReady else { return }
#if targetEnvironment(macCatalyst)
            // 已在上面的有序启动任务中完成。
#else
            // 冷启动先并行探测真实控制面和 WebSocket，设置页无需用户手动测试即可看到连接状态。
            await appStore.preflightConnection()
#endif
        }
        .task(id: lockScreenApprovalRoutingTaskID) {
            guard let delivery = notificationResponseAdapter.approvalInbox.pending else { return }
            let gate = notificationRoutingGate
            let reference = NotificationRouteDiagnostics.shortReference(delivery.notification.actionID)
            guard gate.isReady else {
                NotificationRouteDiagnostics.record(
                    stage: NotificationRouteDiagnostics.Stage.gate,
                    outcome: "closed",
                    reason: gate.closedReason?.rawValue,
                    correlation: reference
                )
                return
            }
            NotificationRouteDiagnostics.record(
                stage: NotificationRouteDiagnostics.Stage.gate,
                outcome: "open",
                correlation: reference
            )
            // 闸门关闭（切后台、开始新一轮恢复）会改变 task id 并取消这里；
            // handler 以 retryLater 保留通知，下一次闸门打开再处理。
            await notificationResponseAdapter.approvalInbox.processPending { delivery in
                await handleLockScreenApproval(delivery)
            }
        }
        .task(id: notificationRouteTaskID) {
            guard let route = notificationResponseAdapter.pendingRoute else {
                pendingNotificationRouteRevision = nil
                return
            }
            // 记录通知到达时的内容路由。bootstrap 自己可能补齐默认项目，因此不能保存它之前的
            // selection lease；用户真正去往别处会推进 route revision，仍可淘汰这条旧通知。
            guard hasCompletedInitialBootstrap else {
                if pendingNotificationRouteRevision == nil {
                    pendingNotificationRouteRevision = workbenchRouteRevision
                }
                return
            }
            let expectedRouteRevision = pendingNotificationRouteRevision ?? workbenchRouteRevision
            // 先消费再做网络操作；新点击可独立入队，不会被旧任务结束时误清。
            notificationResponseAdapter.consume(route)
            pendingNotificationRouteRevision = nil
            guard expectedRouteRevision == workbenchRouteRevision else {
                return
            }
            // 在任何 await 之前占住导航意图：之后用户真实去往别处会推进代次，
            // 通知加载完成时就提交不了了，而自动刷新的租约推进不算在内。
            let intent = sessionStore.reserveSelectionIntent()
            await handleNotificationRoute(
                route,
                ifCurrent: intent,
                reference: NotificationRouteDiagnostics.shortReference(
                    LockScreenApprovalRouting.messageSessionTag(threadID: route.sessionID)
                )
            )
        }
        .task(id: lockScreenApprovalLifecycleTaskID) {
            guard scenePhase == .active else { return }
            // 冷启动不要求用户先打开设置页；失败只保留为可重试状态，
            // 下一次前台恢复仍会再次尝试。
            await refreshLockScreenApprovalLifecycle(markFailure: true)
        }
        .task(id: scenePhase == .active ? sessionStore.selectedProjectID : nil) {
            guard scenePhase == .active else {
                return
            }
            await sessionStore.pollSelectedProjectSessionsWhileVisible()
        }
        .onChange(of: scenePhase) { _, phase in
            foregroundResumeTask?.cancel()
            foregroundResumeTask = nil
            if phase == .background {
                needsTailcatRecoveryAfterBackground = true
                persistActiveHostRestoration()
                hostStatusStore.cancel()
                sessionStore.suspendForBackground()
                appStore.suspendCredentialsForBackground()
                return
            }
            guard phase == .active else {
                return
            }
            let shouldRecoverTailcat = needsTailcatRecoveryAfterBackground
            let generation = foregroundResume.begin()
            foregroundResumeTask = Task {
                var outcome = ForegroundResumeOutcome.cancelled
                // 无论怎么结束都要清掉进行中标记，否则通知闸门永远不开；
                // 但被更新任务顶掉的旧任务不能清掉新任务的标记，代次在 tracker 里把关。
                defer { foregroundResume.finish(generation: generation, outcome: outcome) }
                outcome = await performForegroundResume(recoverTailcat: shouldRecoverTailcat)
            }
        }
        .onChange(of: sessionStore.selectedSession) { _, session in
            persistSessionRestoreSnapshotIfNeeded(session)
        }
        .onChange(of: appStore.activeConnectionProfileID) { _, profileID in
            switchRestorationNamespace(to: profileID)
        }
        .onChange(of: sessionStore.isConnectionSwitchInProgress) { _, isSwitching in
            if isSwitching {
                hostStatusStore.cancel()
            }
        }
        .environment(\.themeSystemColorScheme, colorScheme)
        .preferredColorScheme(themeStore.preferredColorScheme)
        .tint(tokens.accent)
        .background {
            ThemeScreenContextReader { isPad, screenSize in
                themeStore.applyDeviceDefaultFontScale(isPad: isPad, screenSize: screenSize)
            }
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .background(tokens.background.ignoresSafeArea())
        .alert(L10n.text("ui.can_t_open_notifications"), isPresented: notificationRouteAlertBinding) {
            Button(L10n.text("ui.got_it"), role: .cancel) {}
        } message: {
            Text(notificationRouteAlertMessage ?? L10n.text("ui.please_try_again_later"))
        }
    }

    private func migrateLegacyWorkspaceAppearance() {
        workspaceAppearanceStore.migrateLegacyValueIfNeeded(
            profileID: appStore.activeHostScope.profileID,
            endpoint: appStore.endpoint,
            profiles: appStore.connectionProfiles
        )
    }

    private var notificationRouteAlertBinding: Binding<Bool> {
        Binding(
            get: { notificationRouteAlertMessage != nil },
            set: { isPresented in
                if !isPresented {
                    notificationRouteAlertMessage = nil
                }
            }
        )
    }

    private var notificationRouteTaskID: NotificationRouteTaskID {
        NotificationRouteTaskID(
            route: notificationResponseAdapter.pendingRoute,
            hasCompletedInitialBootstrap: hasCompletedInitialBootstrap
        )
    }

    private var notificationRoutingGate: NotificationRoutingGate {
        NotificationRoutingGate(
            bootstrapped: hasCompletedInitialBootstrap,
            sceneActive: scenePhase == .active,
            foregroundResumeInFlight: foregroundResume.isInFlight
        )
    }

    /// 闸门原因也进 task id：从“恢复中”变成“放行”必须重新触发任务，
    /// 而只有闸门状态变化、没有待处理通知时任务立即返回，不产生副作用。
    private var lockScreenApprovalRoutingTaskID: LockScreenApprovalRoutingTaskID {
        LockScreenApprovalRoutingTaskID(
            closedReason: notificationRoutingGate.closedReason,
            pending: notificationResponseAdapter.approvalInbox.pending
        )
    }

    /// 前台恢复链路本体。每一步失败都要返回明确结论，而不是提前 return 让调用方猜。
    private func performForegroundResume(recoverTailcat: Bool) async -> ForegroundResumeOutcome {
        await lockScreenApprovalStore.reconcileDeliveredNotifications()
        do {
            try await appStore.restoreCredentialsForForeground()
        } catch is CancellationError {
            // 真取消，或凭据代次/活动档案在等待期间已变：由最新的生命周期操作接管。
            return .cancelled
        } catch {
            appStore.connectionStatus = .failed(error.localizedDescription)
            appStore.lastError = error.localizedDescription
            // Store 仍要离开后台态，否则提醒清理和后续重连会一直停在挂起状态；
            // 它内部会因为没有凭据而不发任何请求。
            await sessionStore.resumeFromForeground()
            return .credentialsUnavailable
        }
        guard !Task.isCancelled else { return .cancelled }
        if recoverTailcat {
            let tailcatReady = await tailcatExperimentController
                .recoverRouteFromForeground(appStore: appStore)
            guard !Task.isCancelled else { return .cancelled }
            guard tailcatReady else {
                // 保留 needsTailcatRecoveryAfterBackground，下一次 .active 继续重试。
                // Tailcat 未就绪时 endpoint 被锁到不可用的 loopback，恢复只会本机失败。
                await sessionStore.resumeFromForeground()
                return .tailcatUnavailable
            }
            needsTailcatRecoveryAfterBackground = false
        }
        guard !Task.isCancelled else { return .cancelled }
        await sessionStore.resumeFromForeground()
        await refreshLockScreenApprovalLifecycle(markFailure: true)
        return .completed
    }

    private var lockScreenApprovalLifecycleTaskID: String {
        [
            scenePhase == .active ? "active" : "inactive",
            appStore.activeConnectionProfileID ?? "",
            lockScreenApprovalStore.registeredProfileID ?? "",
        ].joined(separator: "|")
    }

    private func refreshLockScreenApprovalLifecycle(markFailure: Bool) async {
        guard lockScreenApprovalStore.isEnabled,
              let profileID = lockScreenApprovalStore.registeredProfileID else {
            return
        }
        do {
            let client: AgentAPIClient
            if profileID == appStore.activeConnectionProfileID {
                client = try appStore.client()
            } else {
                client = try await LockScreenApprovalRouting.client(
                    profileID: profileID,
                    appStore: appStore
                )
            }
            lockScreenApprovalStore.registerNotificationInfrastructure()
			await lockScreenApprovalStore.refreshHostSupport(client: client, profileID: profileID)
            await lockScreenApprovalStore.refreshTicketIfNeeded(
                client: client,
                profileID: profileID
            )
			let installationID = appStore.connectionProfiles.first { $0.id == profileID }?.installationID
            await lockScreenApprovalStore.reconcileDeliveredNotifications(
                client: client,
                sourceProfileTag: installationID.map { LockScreenApprovalRouting.profileTag(installationID: $0) }
            )
        } catch is CancellationError {
            return
        } catch {
            if markFailure {
                lockScreenApprovalStore.markRegistrationFailed()
            }
        }
    }

    /// 锁屏动作只做两件事：把决策交给自己的 agentd，或者打开 App 看详情。
    /// 结果未知时如实展示未知——把超时当成已允许是这条链路上最危险的错误。
    private func handleLockScreenApproval(
        _ delivery: LockScreenApprovalDelivery
    ) async -> NotificationDeliveryOutcome {
        guard let decision = delivery.decision else {
            if delivery.notification.event == .resolved {
                await lockScreenApprovalStore.handleResolved(delivery.notification)
                return .handled
            }
            return await openLockScreenApprovalDetails(delivery)
        }
        let reference = NotificationRouteDiagnostics.shortReference(delivery.notification.actionID)
        await foregroundResumeTask?.value
        guard !Task.isCancelled else { return .retryLater }
        guard let source = try? await LockScreenApprovalRouting.sourceClient(
            for: delivery.notification,
            appStore: appStore,
            sessionStore: sessionStore,
            recoverRouteFromBackground: false
        ) else {
            guard !Task.isCancelled else { return .retryLater }
            NotificationRouteDiagnostics.record(
                stage: NotificationRouteDiagnostics.Stage.sourceClient,
                outcome: "failed",
                reason: "unavailable",
                correlation: reference
            )
            notificationRouteAlertMessage = L10n.text("ui.push_approval_result_unknown")
            return .handled
        }
        await lockScreenApprovalStore.submitDecision(
            decision,
            for: delivery.notification,
            client: source.client,
            notificationRequestIdentifier: delivery.requestIdentifier
        )
        if let message = lockScreenApprovalStore.lastDecisionMessage {
            notificationRouteAlertMessage = message
        }
        return .handled
    }

    /// 点开通知本身。顺序有讲究：先看恢复是否失败（失败就提示并保留通知），再在任何
    /// await 之前占住导航意图，然后尝试本机快路径；只有本机解析不到时才走网络定位。
    private func openLockScreenApprovalDetails(
        _ delivery: LockScreenApprovalDelivery
    ) async -> NotificationDeliveryOutcome {
        let notification = delivery.notification
        let reference = NotificationRouteDiagnostics.shortReference(notification.actionID)
        if let resumeOutcome = foregroundResume.lastOutcome, resumeOutcome.blocksNotificationRouting {
            NotificationRouteDiagnostics.record(
                stage: NotificationRouteDiagnostics.Stage.sessionOpen,
                outcome: "deferred",
                reason: resumeOutcome.diagnosticReason,
                correlation: reference
            )
            if lastResumeFailureAlertDeliveryID != delivery.id {
                lastResumeFailureAlertDeliveryID = delivery.id
                notificationRouteAlertMessage = L10n.text("ui.push_route_connection_not_restored")
            }
            return .retryLater
        }
        lastResumeFailureAlertDeliveryID = nil
        // 用户在等待期间点进会话 B 会推进代次，旧通知 A 完成时就提交不了导航；
        // 这一步必须早于 sourceClient / 定位请求等所有 await。
        let intent = sessionStore.reserveSelectionIntent()
        let localSession = localNotificationSession(for: notification, reference: reference)
        let previousRoute = workbenchRoute
        var targetRoute: WorkbenchRestorationRoute?
        if let localSession {
            // 先把工作台路由切到目标详情：外壳在选择尚未提交时只画稳定底板，
            // 旧页面不会再闪一秒；随后 openSessionFromNotification 负责真正加载。
            let route = WorkbenchRestorationRoute.session(id: localSession.id, source: previousRoute.rootPage)
            targetRoute = route
            setWorkbenchRoute(route)
        }
        // 闸门已保证恢复不在进行中；这里只是复用同一结果，避免与恢复链路并行。
        await foregroundResumeTask?.value
        guard !Task.isCancelled else { return .retryLater }
        if let localSession {
            let route = SessionNotificationRoute.current(
                profileID: appStore.notificationRoutingProfileID,
                projectID: localSession.projectID,
                sessionID: localSession.id,
                runtimeProvider: localSession.runtimeProvider
            )
            let outcome = await handleNotificationRoute(route, ifCurrent: intent, reference: reference)
            if outcome != .opened,
               let targetRoute,
               workbenchRoute == targetRoute,
               sessionStore.selectedSessionID != localSession.id {
                // 没打开、用户也没自己去别处：把路由退回去，不能把人留在一张空白详情页上。
                setWorkbenchRoute(previousRoute)
            }
            return .handled
        }
        return await openLockScreenApprovalDetailsFromServer(
            notification,
            intent: intent,
            reference: reference
        )
    }

    /// 同一台 Mac 且本地缓存能按会话标签唯一命中时，不必等网络定位。
    /// 命中与否由 SessionStore 自己记 local_resolve；这里只补“不是这台 Mac”这一条它看不到的原因。
    private func localNotificationSession(
        for notification: LockScreenApprovalNotification,
        reference: String?
    ) -> AgentSession? {
        guard LockScreenApprovalRouting.isLocalRouteEligible(
            notification,
            activeProfileID: appStore.activeConnectionProfileID,
            profiles: appStore.connectionProfiles
        ) else {
            NotificationRouteDiagnostics.record(
                stage: NotificationRouteDiagnostics.Stage.localResolve,
                outcome: "miss",
                reason: "other_mac",
                correlation: reference
            )
            return nil
        }
        return sessionStore.localNotificationSession(matching: notification)
    }

    private func openLockScreenApprovalDetailsFromServer(
        _ notification: LockScreenApprovalNotification,
        intent: SessionSelectionLease,
        reference: String?
    ) async -> NotificationDeliveryOutcome {
        do {
            let source = try await resolveSourceClient(for: notification, reference: reference)
            let destination = try await locateNotificationRoute(
                notification,
                client: source.client,
                reference: reference
            )
            var selectionIntent = intent
            if appStore.activeConnectionProfileID != source.profileID {
                guard sessionStore.isSelectionLeaseCurrent(intent) else {
                    NotificationRouteDiagnostics.record(
                        stage: NotificationRouteDiagnostics.Stage.sessionOpen,
                        outcome: "superseded",
                        reason: "before_profile_switch",
                        correlation: reference
                    )
                    return .handled
                }
                _ = try await sessionStore.switchConnectionProfile(id: source.profileID)
                await sessionStore.bootstrap()
                // 租约绑定 HostScope，换了 Mac 之后旧意图必然失效；切换本身已经清空选择，
                // 这里重新占一次，让 bootstrap 之后的用户操作仍能淘汰这条通知。
                selectionIntent = sessionStore.reserveSelectionIntent()
            }
            // project_resolve 的命中规则由 SessionStore 记录；解析不到不再当成“来源档案不可用”，
            // 会话本身可能还在，只是本地没有可归属的工作区。
            guard let projectID = sessionStore.notificationProjectID(
                threadID: destination.threadID,
                cwd: destination.cwd,
                scopeID: destination.scopeID,
                projectID: destination.projectID
            ) else {
                notificationRouteAlertMessage = L10n.text("ui.the_session_corresponding_to_the_notification_is_temporarily")
                return .handled
            }
            // 审批已到终态也照样打开会话：用户想看的是结果，而不是一句“已过期”。
            let route = SessionNotificationRoute.current(
                profileID: appStore.notificationRoutingProfileID,
                projectID: projectID,
                sessionID: destination.threadID,
                runtimeProvider: destination.runtime
            )
            await handleNotificationRoute(route, ifCurrent: selectionIntent, reference: reference)
            return .handled
        } catch {
            // 真取消（切后台、新通知顶替）静默保留；合成的 CancellationError（凭据代次
            // 或活动档案变了）任务并未被取消，必须如实提示，否则用户点了没反应。
            guard !Task.isCancelled else { return .retryLater }
            notificationRouteAlertMessage = LockScreenApprovalRouting.detailsErrorMessage(
                error,
                for: notification
            )
            return .handled
        }
    }

    private func resolveSourceClient(
        for notification: LockScreenApprovalNotification,
        reference: String?
    ) async throws -> (profileID: String, client: AgentAPIClient) {
        let startedAt = Date()
        do {
            let source = try await LockScreenApprovalRouting.sourceClient(
                for: notification,
                appStore: appStore,
                sessionStore: sessionStore,
                recoverRouteFromBackground: false
            )
            NotificationRouteDiagnostics.record(
                stage: NotificationRouteDiagnostics.Stage.sourceClient,
                outcome: "ok",
                correlation: reference,
                elapsedMilliseconds: NotificationRouteDiagnostics.elapsedMilliseconds(since: startedAt)
            )
            return source
        } catch {
            NotificationRouteDiagnostics.record(
                stage: NotificationRouteDiagnostics.Stage.sourceClient,
                outcome: "failed",
                reason: Self.diagnosticReason(for: error),
                correlation: reference,
                elapsedMilliseconds: NotificationRouteDiagnostics.elapsedMilliseconds(since: startedAt)
            )
            throw error
        }
    }

    private func locateNotificationRoute(
        _ notification: LockScreenApprovalNotification,
        client: AgentAPIClient,
        reference: String?
    ) async throws -> PushActionRouteResponse {
        let startedAt = Date()
        do {
            let destination = try await client.pushActionRoute(
                actionID: notification.actionID,
                deviceID: notification.deviceID
            )
            // 旧版 agentd 不返回 kind/state；只有拿到时才把它们记进原因。
            let detail = [destination.kind, destination.state].compactMap { $0 }.joined(separator: "/")
            NotificationRouteDiagnostics.record(
                stage: NotificationRouteDiagnostics.Stage.routeLookup,
                outcome: "200",
                reason: detail.isEmpty ? nil : detail,
                correlation: reference,
                elapsedMilliseconds: NotificationRouteDiagnostics.elapsedMilliseconds(since: startedAt)
            )
            return destination
        } catch {
            NotificationRouteDiagnostics.record(
                stage: NotificationRouteDiagnostics.Stage.routeLookup,
                outcome: "failed",
                reason: Self.diagnosticReason(for: error),
                correlation: reference,
                elapsedMilliseconds: NotificationRouteDiagnostics.elapsedMilliseconds(since: startedAt)
            )
            throw error
        }
    }

    @discardableResult
    private func handleNotificationRoute(
        _ route: SessionNotificationRoute,
        ifCurrent selectionLease: SessionSelectionLease,
        reference: String?
    ) async -> SessionNotificationOpenOutcome {
        let startedAt = Date()
        let outcome = await sessionStore.openSessionFromNotification(route, ifCurrent: selectionLease)
        let elapsed = NotificationRouteDiagnostics.elapsedMilliseconds(since: startedAt)
        switch outcome {
        case .opened:
            NotificationRouteDiagnostics.record(
                stage: NotificationRouteDiagnostics.Stage.sessionOpen,
                outcome: "opened",
                correlation: reference,
                elapsedMilliseconds: elapsed
            )
        case .superseded:
            // 唯一允许保持安静的结果：用户在等待期间已经明确去了别处。
            NotificationRouteDiagnostics.record(
                stage: NotificationRouteDiagnostics.Stage.sessionOpen,
                outcome: "superseded",
                correlation: reference,
                elapsedMilliseconds: elapsed
            )
        case .requiresProfileSwitch(let displayName):
            NotificationRouteDiagnostics.record(
                stage: NotificationRouteDiagnostics.Stage.sessionOpen,
                outcome: "requires_profile_switch",
                correlation: reference,
                elapsedMilliseconds: elapsed
            )
            if let displayName {
                notificationRouteAlertMessage = L10n.format("ui.this_notification_comes_from_value_please_switch_to", displayName)
            } else {
                notificationRouteAlertMessage = L10n.text("ui.this_notification_comes_from_another_mac_please_switch")
            }
        case .unavailable(let message):
            NotificationRouteDiagnostics.record(
                stage: NotificationRouteDiagnostics.Stage.sessionOpen,
                outcome: "unavailable",
                correlation: reference,
                elapsedMilliseconds: elapsed
            )
            notificationRouteAlertMessage = message
        }
        return outcome
    }

    /// 诊断只要错误类别：HTTP 状态码、取消、URLError 代码或错误类型名，不带描述文本。
    private static func diagnosticReason(for error: Error) -> String {
        if let apiError = error as? AgentAPIError {
            switch apiError {
            case .server(let status, _):
                return "http_\(status)"
            case .credentialsInvalid(let status, _):
                return "credentials_invalid_\(status)"
            case .invalidEndpoint:
                return "invalid_endpoint"
            case .insecurePublicHTTPEndpoint:
                return "insecure_endpoint"
            case .invalidResponse:
                return "invalid_response"
            case .decoding:
                return "decoding"
            }
        }
        if let routingError = error as? LockScreenApprovalRoutingError {
            switch routingError {
            case .sourceProfileUnavailable:
                return "source_profile_unavailable"
            case .sourceCredentialUnavailable:
                return "source_credential_unavailable"
            }
        }
        if isCancellationError(error) {
            return Task.isCancelled ? "cancelled" : "synthetic_cancellation"
        }
        if let urlError = error as? URLError {
            return "url_error_\(urlError.code.rawValue)"
        }
        return String(describing: type(of: error))
    }

    private var decodedSessionRestoreSnapshot: SessionRestoreSnapshot? {
        workbenchRoute.restoreSnapshot(
            from: lastSessionSnapshot,
            currentProfileID: appStore.activeConnectionProfileID,
            currentEndpoint: appStore.endpoint
        )
    }

    private var workbenchRoute: WorkbenchRestorationRoute {
        WorkbenchRestorationRoute(storageValue: workbenchRouteStorage)
    }

    private var workbenchRouteBinding: Binding<WorkbenchRestorationRoute> {
        Binding(
            get: { workbenchRoute },
            set: { setWorkbenchRoute($0) }
        )
    }

    private func setWorkbenchRoute(_ route: WorkbenchRestorationRoute) {
        guard workbenchRoute != route else { return }
        workbenchRouteRevision &+= 1
        workbenchRouteStorage = route.storageValue
        if route.detailSessionID == nil {
            // 用户已经真实离开详情页；旧快照继续存在会让下次冷启动再次进入会话。
            lastSessionSnapshot = ""
        } else {
            // 通知和工作区入口可能先完成 selectSession、再切详情路由；这里补齐另一种事件顺序。
            persistSessionRestoreSnapshotIfNeeded(sessionStore.selectedSession, route: route)
        }
        persistActiveHostRestoration()
    }

    private func persistSessionRestoreSnapshotIfNeeded(
        _ session: AgentSession?,
        route: WorkbenchRestorationRoute? = nil
    ) {
        let route = route ?? workbenchRoute
        guard let session,
              route.detailSessionID == session.id else { return }
        let snapshot = SessionRestoreSnapshot(
            profileID: appStore.notificationRoutingProfileID,
            endpoint: appStore.endpoint,
            session: session
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            lastSessionSnapshot = data.base64EncodedString()
            persistActiveHostRestoration()
        }
    }

    private func restoreActiveHostNavigationIfNeeded() {
        guard activeRestorationProfileID == nil else { return }
        let profileID = appStore.notificationRoutingProfileID
        activeRestorationProfileID = profileID
        guard let record = hostRestorationEnvelope.records[profileID] else {
            return
        }
        workbenchRouteRevision &+= 1
        workbenchRouteStorage = record.routeStorage
        lastSessionSnapshot = record.sessionSnapshot
    }

    private func switchRestorationNamespace(to rawProfileID: String?) {
        let nextProfileID = rawProfileID ?? appStore.notificationRoutingProfileID
        if let currentProfileID = activeRestorationProfileID {
            persistRestorationRecord(for: currentProfileID)
        }
        activeRestorationProfileID = nextProfileID
        let record = hostRestorationEnvelope.records[nextProfileID]
        workbenchRouteRevision &+= 1
        workbenchRouteStorage = record?.routeStorage ?? WorkbenchRestorationRoute.defaultStorageValue
        lastSessionSnapshot = record?.sessionSnapshot ?? ""
    }

    private func persistActiveHostRestoration() {
        guard let profileID = activeRestorationProfileID else { return }
        persistRestorationRecord(for: profileID)
    }

    private func persistRestorationRecord(for profileID: String) {
        var envelope = hostRestorationEnvelope
        envelope.records[profileID] = HostRestorationRecord(
            routeStorage: workbenchRouteStorage,
            sessionSnapshot: lastSessionSnapshot,
            updatedAt: Date()
        )
        // SceneStorage 只保留最近 8 台的轻量导航，不保存历史正文或媒体。
        if envelope.records.count > 8 {
            let retainedIDs = envelope.records
                .sorted { $0.value.updatedAt > $1.value.updatedAt }
                .prefix(8)
                .map(\.key)
            envelope.records = envelope.records.filter { retainedIDs.contains($0.key) }
        }
        if let data = try? JSONEncoder().encode(envelope) {
            hostRestorationStorage = data.base64EncodedString()
        }
    }

    private var hostRestorationEnvelope: HostRestorationEnvelope {
        guard let data = Data(base64Encoded: hostRestorationStorage),
              let decoded = try? JSONDecoder().decode(HostRestorationEnvelope.self, from: data) else {
            return HostRestorationEnvelope(records: [:])
        }
        return decoded
    }

    private var appShell: some View {
        UnifiedWorkbenchShell(
            showingInspector: $showingLogInspector,
            restorationRoute: workbenchRouteBinding
        )
    }
}

private struct HostRestorationEnvelope: Codable {
    var records: [String: HostRestorationRecord]
}

private struct HostRestorationRecord: Codable {
    let routeStorage: String
    let sessionSnapshot: String
    let updatedAt: Date
}

private struct NotificationRouteTaskID: Equatable {
    let route: SessionNotificationRoute?
    let hasCompletedInitialBootstrap: Bool
}

private struct LockScreenApprovalRoutingTaskID: Equatable {
    let closedReason: NotificationRoutingGate.ClosedReason?
    let pending: LockScreenApprovalDelivery?
}

/// SwiftUI 的容器宽度会随 Split View 改变；通过实际 Window Scene 读取物理屏幕，
/// 才能让 iPad mini 的默认字号稳定，并避免大屏 iPad 窄窗口被误判。
private struct ThemeScreenContextReader: UIViewRepresentable {
    let onResolve: @MainActor (_ isPad: Bool, _ screenSize: CGSize) -> Void

    func makeUIView(context: Context) -> ThemeScreenContextView {
        ThemeScreenContextView(onResolve: onResolve)
    }

    func updateUIView(_ uiView: ThemeScreenContextView, context: Context) {
        uiView.onResolve = onResolve
    }
}

private final class ThemeScreenContextView: UIView {
    var onResolve: @MainActor (_ isPad: Bool, _ screenSize: CGSize) -> Void

    init(onResolve: @escaping @MainActor (_ isPad: Bool, _ screenSize: CGSize) -> Void) {
        self.onResolve = onResolve
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let screen = window?.windowScene?.screen else {
            return
        }
#if targetEnvironment(macCatalyst)
        let isPad = false
#else
        let isPad = traitCollection.userInterfaceIdiom == .pad
#endif
        onResolve(isPad, screen.bounds.size)
    }
}
