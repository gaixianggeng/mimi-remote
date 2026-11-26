import Foundation
import XCTest
@testable import MimiRemoteMac

@MainActor
final class DashboardAndSettingsTests: XCTestCase {
    // MARK: - Dashboard deduplication & typed remediation

    func testDashboardEliminatesDuplicateRedErrorWhenLifecycleDetailMatchesLastError() {
        let message = "后台服务启动失败：端口已被占用"
        let remediation = DashboardPresentation.remediation(
            lifecycle: .failed(message),
            owner: .none,
            agentRegistrationState: .enabled,
            hasConfiguration: true
        )
        XCTAssertNotNil(remediation)
        XCTAssertEqual(remediation?.primaryAction, .repairAndStartService)
        XCTAssertEqual(remediation?.primaryButtonTitle, "重试启动服务")
        XCTAssertNil(
            DashboardPresentation.additionalErrorBanner(
                lifecycle: .failed(message),
                lastError: message,
                remediation: remediation
            ),
            "不能在标题副文/修复卡之外重复渲染同一份红字错误"
        )
    }

    func testDashboardProvidesTypedRemediationForDegradedStoppedAndFailedStates() {
        // 1. Degraded due to background agent requiresApproval
        let approval = DashboardPresentation.remediation(
            lifecycle: .degraded("请在系统设置的登录项中允许 Mimi Remote Mac。"),
            owner: .none,
            agentRegistrationState: .requiresApproval,
            hasConfiguration: true
        )
        XCTAssertEqual(approval?.primaryAction, .openLoginItems)
        XCTAssertEqual(approval?.primaryButtonTitle, "打开登录项设置…")

        // 2. Stopped state
        let stopped = DashboardPresentation.remediation(
            lifecycle: .stopped,
            owner: .macApp,
            agentRegistrationState: .notRegistered,
            hasConfiguration: true
        )
        XCTAssertEqual(stopped?.primaryAction, .repairAndStartService)
        XCTAssertEqual(stopped?.primaryButtonTitle, "启动服务")
        XCTAssertTrue(stopped?.secondaryActions.contains(.openDiagnostics) == true)

        // 3. Failed without config offers returning to onboarding wizard
        let unconfiguredFailed = DashboardPresentation.remediation(
            lifecycle: .failed("未找到配置"),
            owner: .none,
            agentRegistrationState: .notRegistered,
            hasConfiguration: false
        )
        XCTAssertTrue(unconfiguredFailed?.secondaryActions.contains(.returnToOnboarding) == true)

        // 4. Ready state needs no remediation card
        XCTAssertNil(DashboardPresentation.remediation(
            lifecycle: .ready,
            owner: .macApp,
            agentRegistrationState: .enabled,
            hasConfiguration: true
        ))
    }

    func testDashboardSurfacesReadOnlyHostRecoveryWhenConfigInvalid() {
        let configCheck = OnboardingCheck(
            id: .configStore,
            state: .error,
            detail: "配置无法安全读取。",
            blocking: true,
            code: "config_invalid",
            fix: .openSettings(.hostRecovery),
            configPath: "/fixture/config/config.json"
        )
        let report = OnboardingPreflightReport(
            ok: false,
            stage: .pair,
            configured: true,
            workspaceConfirmed: false,
            configPath: "/fixture/config/config.json",
            scanRoot: "/fixture/workspace",
            browseRoot: "/fixture/workspace",
            scanRootExists: true,
            recommendedNext: .configStore,
            recommendedTransport: nil,
            checks: [configCheck]
        )
        let remediation = DashboardPresentation.remediation(
            lifecycle: .degraded("配置异常"),
            owner: .none,
            agentRegistrationState: .enabled,
            hasConfiguration: true,
            preflightReport: report
        )
        XCTAssertEqual(remediation?.primaryAction, .openHostRecovery)
        XCTAssertEqual(remediation?.primaryButtonTitle, "查看恢复信息…")
    }

    // MARK: - Settings Local Network explanation & Widen Browse Scope preview/cancel/confirm

    func testFileAccessSettingsIncludesLocalNetworkExplanationForBothOwners() {
        let macApp = FileAccessSettingsPresentation.make(owner: .macApp, photosAccess: .notDetermined)
        let homebrew = FileAccessSettingsPresentation.make(owner: .homebrew, photosAccess: .authorized)

        XCTAssertEqual(FileAccessSettingsPresentation.localNetworkActionTitle, "打开本地网络权限设置…")
        XCTAssertTrue(macApp.localNetworkCaption.contains("同一局域网"))
        XCTAssertTrue(macApp.localNetworkCaption.contains("自动刷新"))
        XCTAssertTrue(homebrew.localNetworkCaption.contains("同一局域网"))
        XCTAssertTrue(homebrew.localNetworkCaption.contains("自动刷新"))
    }

    func testWorkspaceScopeWidenPreviewCancelDoesZeroMutationsAndConfirmPassesBothRoots() async throws {
        let home = URL(filePath: "/fixture/home", directoryHint: .isDirectory)
        let scanRoot = URL(filePath: "/fixture/home/code", directoryHint: .isDirectory)
        let updateCalls = LockedWorkspaceCalls()
        let currentBrowse = LockedWorkspaceCalls()
        currentBrowse.append((scanRoot.path, scanRoot.path))

        var deps = WorkspaceScopeDependencies(
            preflight: {
                OnboardingPreflightReport(
                    ok: true,
                    stage: .pair,
                    configured: true,
                    workspaceConfirmed: true,
                    configPath: "/fixture/config/config.json",
                    scanRoot: scanRoot.path,
                    browseRoot: currentBrowse.values.last!.1,
                    scanRootExists: true,
                    recommendedNext: .networkAny,
                    recommendedTransport: .tailscale,
                    checks: [OnboardingCheck(id: .configStore, state: .ok, detail: "", blocking: false)]
                )
            },
            updateWorkspaceScope: { scan, browse in
                updateCalls.append((scan.path, browse.path))
                currentBrowse.append((scan.path, browse.path))
            },
            directoryExists: { _ in true },
            homeDirectory: { home },
            verifiesSingleGrant: { _ in true }
        )

        deps.reloadIfRunning = { throw AgentClientError.commandFailed("fixture") }
        let store = WorkspaceScopeStore(dependencies: deps)
        await store.refresh()
        XCTAssertTrue(store.canWidenBrowseScope)
        XCTAssertEqual(store.scanRoot?.path, scanRoot.path)
        XCTAssertEqual(store.browseRoot?.path, scanRoot.path)

        // 不包含当前代码目录的无关路径被拒绝
        store.prepareWidenPreview(proposedBrowseRoot: URL(filePath: "/fixture/other", directoryHint: .isDirectory))
        XCTAssertNil(store.pendingPreview)
        XCTAssertNotNil(store.errorMessage)

        // 选择主目录时展示完整授权预览，此时尚未写入
        store.prepareWidenPreview(proposedBrowseRoot: home)
        let preview = try XCTUnwrap(store.pendingPreview)
        XCTAssertTrue(preview.widensBeyondScanRoot)
        XCTAssertTrue(preview.coversHomeDirectory)
        XCTAssertTrue(preview.summaryLines.contains(where: { $0.contains(scanRoot.path) }))
        XCTAssertTrue(preview.summaryLines.contains(where: { $0.contains(home.path) }))
        XCTAssertTrue(preview.summaryLines.contains(where: { $0.contains("个人主目录") }))
        XCTAssertTrue(updateCalls.values.isEmpty)

        // 取消扩权：零写入、原范围不变
        store.cancelWidenPreview()
        XCTAssertNil(store.pendingPreview)
        XCTAssertEqual(store.browseRoot?.path, scanRoot.path)
        XCTAssertTrue(updateCalls.values.isEmpty)

        // 再次预览并显式确认：调用 workspace --scan-root ... --browse-root ...
        store.prepareWidenPreview(proposedBrowseRoot: home)
        await store.confirmWidenBrowseScope()
        XCTAssertNil(store.pendingPreview)
        XCTAssertEqual(updateCalls.values.count, 1)
        XCTAssertEqual(updateCalls.values.first?.0, scanRoot.path)
        XCTAssertEqual(updateCalls.values.first?.1, home.path)
        XCTAssertEqual(store.browseRoot?.path, home.path)
        XCTAssertTrue(store.errorMessage?.contains("已保存") == true)
        store.prepareWidenPreview(proposedBrowseRoot: scanRoot)
        XCTAssertNil(store.pendingPreview, "Widening must preserve the existing broader grant")
    }

    func testWideningRequiresEveryExistingGrantToMatchThePreview() throws {
        let config = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: config) }
        let report = OnboardingPreflightReport(
            ok: true, stage: .pair, configured: true, workspaceConfirmed: true, configPath: config.path,
            scanRoot: "/code", browseRoot: "/code", scanRootExists: true,
            recommendedNext: .networkAny, recommendedTransport: nil, checks: []
        )
        func write(_ arrays: [String: [String]]) throws {
            try JSONEncoder().encode(arrays).write(to: config)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        }
        try write(["scan_roots": ["/code"], "browse_roots": ["/code"]])
        XCTAssertTrue(WorkspaceScopeDependencies.hasSingleGrant(at: config, report: report))
        try write(["scan_roots": ["/code", "/other"], "browse_roots": ["/code"]])
        XCTAssertFalse(WorkspaceScopeDependencies.hasSingleGrant(at: config, report: report))
        try write(["scan_roots": ["/code"], "browse_roots": ["/code", "/other"]])
        XCTAssertFalse(WorkspaceScopeDependencies.hasSingleGrant(at: config, report: report))
    }

    func testRefreshPermissionsOnReturnUpdatesNativeStateWithoutStartingService() {
        let registerCalls = CallCounter()
        var mainAppState: ServiceRegistrationState = .notRegistered
        var photosState: PhotosAccessState = .notDetermined

        let store = HostStore(
            agent: AgentCommandClient(
                configExists: { true },
                setup: { _ in throw AgentClientError.commandFailed("unused") },
                status: { throw AgentClientError.commandFailed("unused") },
                readiness: { throw AgentClientError.commandFailed("unused") },
                statusAt: { _ in throw AgentClientError.commandFailed("unused") },
                doctor: { _ in throw AgentClientError.commandFailed("unused") },
                configureClaude: { _, _ in throw AgentClientError.commandFailed("unused") },
                setLANAccess: { _ in throw AgentClientError.commandFailed("unused") },
                pair: { _ in throw AgentClientError.commandFailed("unused") },
                version: { "test" }
            ),
            services: ServiceManagementClient(
                agentStatus: { .notRegistered },
                agentConfigurationError: { nil },
                isAgentRegistrationCurrent: { true },
                markAgentRegistrationCurrent: {},
                registerAgent: { _ = registerCalls.increment() },
                unregisterAgent: {},
                agentLaunchFailure: { nil },
                mainAppStatus: { mainAppState },
                registerMainApp: {},
                unregisterMainApp: {},
                openLoginItemsSettings: {}
            ),
            homebrew: HomebrewServiceClient(isLoaded: { false }, installedAgentBinary: { nil }, start: {}, stop: {}),
            health: HealthClient(check: { _ in false }, checkDirect: { _ in false }),
            logs: AgentLogClient(recentLines: { _ in [] }, exportLines: { [] }),
            systemPrivacySettings: SystemPrivacySettingsClient(
                openFullDiskAccessSettings: {},
                photosAccessState: { photosState },
                requestPhotosAccess: { photosState },
                openPhotosPrivacySettings: {}
            )
        )

        store.loginItemWarning = "尚未允许"
        mainAppState = .enabled
        photosState = .authorized

        store.refreshPermissionsOnReturn()

        XCTAssertTrue(store.launchesAtLogin)
        XCTAssertEqual(store.photosAccess, .authorized)
        XCTAssertNil(store.loginItemWarning)
        XCTAssertEqual(registerCalls.current, 0)
    }

    // MARK: - Dashboard passive recheck recovery

    func testDashboardRecheckAfterApprovalRecoversOwnerStatusAndLifecycleWithoutStartingService() async {
        let mutatingCalls = EventRecorder()
        let statusCalls = CallCounter()
        var agentState: ServiceRegistrationState = .requiresApproval
        var mainAppState: ServiceRegistrationState = .requiresApproval

        let readyStatus = Self.makeAgentStatus(processOK: true, serviceOK: true)
        let store = makeRecheckHostStore(
            agentStatus: { agentState },
            mainAppStatus: { mainAppState },
            status: {
                _ = statusCalls.increment()
                return readyStatus
            },
            mutatingCalls: mutatingCalls
        )

        await store.bootstrap()
        XCTAssertEqual(store.owner, .none)
        XCTAssertEqual(store.lifecycle, .degraded("请在系统设置的登录项中允许 Mimi Remote Mac。"))
        XCTAssertNil(store.status)
        XCTAssertEqual(
            DashboardPresentation.remediation(
                lifecycle: store.lifecycle,
                owner: store.owner,
                agentRegistrationState: store.agentRegistrationState,
                hasConfiguration: store.hasConfiguration()
            )?.primaryAction,
            .openLoginItems
        )

        // 用户在系统设置中允许后台服务与主应用登录项后点击「重新检查」。
        let preRecheckMutations = mutatingCalls.values
        agentState = .enabled
        mainAppState = .enabled
        store.lastError = "此前失败的旧错误"

        var lifecycleDuringPreflightReload: HostLifecycleState?
        await DashboardPresentation.performRecheck(store: store) {
            lifecycleDuringPreflightReload = store.lifecycle
        }

        XCTAssertEqual(store.owner, .macApp)
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertEqual(store.status, readyStatus)
        XCTAssertNil(store.lastError)
        XCTAssertTrue(store.launchesAtLogin)
        XCTAssertNil(store.loginItemWarning)
        XCTAssertEqual(lifecycleDuringPreflightReload, .ready)
        XCTAssertEqual(statusCalls.current, 1)
        XCTAssertEqual(
            mutatingCalls.values,
            preRecheckMutations,
            "批准后的重新检查只做被动观察，绝不能再次触发启动、重启、注册或修复"
        )
        XCTAssertNil(
            DashboardPresentation.remediation(
                lifecycle: store.lifecycle,
                owner: store.owner,
                agentRegistrationState: store.agentRegistrationState,
                hasConfiguration: store.hasConfiguration()
            )
        )
    }

    func testDashboardRecheckOnHealthyRunningServiceDoesNotRestartEvenWhenRegistrationStaleOrVersionMismatched() async {
        let mutatingCalls = EventRecorder()
        let statusCalls = CallCounter()
        var registrationCurrent = true
        let initialStatus = Self.makeAgentStatus(processOK: true, serviceOK: true, version: "1.0.0", serverVersion: "1.0.0")
        let updatedStatus = Self.makeAgentStatus(
            processOK: true,
            serviceOK: true,
            version: "1.1.0",
            serverVersion: "1.0.0",
            projects: 3
        )
        let currentStatus = LockedValue(initialStatus)

        let store = makeRecheckHostStore(
            agentStatus: { .enabled },
            isAgentRegistrationCurrent: { registrationCurrent },
            status: {
                _ = statusCalls.increment()
                return currentStatus.value
            },
            mutatingCalls: mutatingCalls
        )

        await store.bootstrap()
        XCTAssertEqual(store.owner, .macApp)
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertEqual(statusCalls.current, 1)
        XCTAssertEqual(mutatingCalls.values, [])

        // 即使登记版本号过期或存在版本差异，被动重新检查也不能重启健康运行中的服务。
        registrationCurrent = false
        currentStatus.value = updatedStatus

        await DashboardPresentation.performRecheck(store: store) {}

        XCTAssertEqual(store.owner, .macApp)
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertEqual(store.status, updatedStatus)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(statusCalls.current, 2)
        XCTAssertEqual(mutatingCalls.values, [])
    }

    func testDashboardRecheckFailureKeepsDegradedStateWithoutStartingOrRestarting() async {
        let mutatingCalls = EventRecorder()
        let statusCalls = CallCounter()
        var agentState: ServiceRegistrationState = .requiresApproval
        let statusResult = LockedValue<Result<AgentStatus, Error>>(
            .failure(AgentClientError.commandFailed("无法连接后台服务"))
        )

        let store = makeRecheckHostStore(
            agentStatus: { agentState },
            status: {
                _ = statusCalls.increment()
                return try statusResult.value.get()
            },
            mutatingCalls: mutatingCalls
        )

        await store.bootstrap()
        XCTAssertEqual(store.owner, .none)
        XCTAssertEqual(store.lifecycle, .degraded("请在系统设置的登录项中允许 Mimi Remote Mac。"))

        // 1. 尚未在系统设置中批准：保持审批降级态，不查询也不起服。
        await DashboardPresentation.performRecheck(store: store) {}
        XCTAssertEqual(store.owner, .none)
        XCTAssertEqual(store.lifecycle, .degraded("请在系统设置的登录项中允许 Mimi Remote Mac。"))
        XCTAssertEqual(statusCalls.current, 0)
        XCTAssertEqual(mutatingCalls.values, [])

        // 2. 已批准但 status 命令失败：保持降级态，不自动重启/修复。
        agentState = .enabled
        await DashboardPresentation.performRecheck(store: store) {}
        XCTAssertEqual(store.owner, .macApp)
        XCTAssertEqual(store.lifecycle, .degraded("无法连接后台服务"))
        XCTAssertEqual(statusCalls.current, 1)
        XCTAssertEqual(mutatingCalls.values, [])

        // 3. 已批准且进程存活但 readyz 未就绪：保持降级态，不自动重启/修复。
        statusResult.value = .success(Self.makeAgentStatus(
            processOK: true,
            serviceOK: false,
            serviceError: "readyz 不可用"
        ))
        await DashboardPresentation.performRecheck(store: store) {}
        XCTAssertEqual(store.owner, .macApp)
        XCTAssertEqual(store.lifecycle, .degraded("readyz 不可用"))
        XCTAssertEqual(statusCalls.current, 2)
        XCTAssertEqual(mutatingCalls.values, [])
    }

    func testDashboardRecheckDetectsHealthyHomebrewOwnerWithoutStartingOrStopping() async {
        let mutatingCalls = EventRecorder()
        let statusAtCalls = CallCounter()
        let homebrewLoaded = LockedValue(false)
        let readyStatus = Self.makeAgentStatus(processOK: true, serviceOK: true)

        let store = makeRecheckHostStore(
            agentStatus: { .requiresApproval },
            homebrewLoaded: { homebrewLoaded.value },
            status: { readyStatus },
            statusAt: { _ in
                _ = statusAtCalls.increment()
                return readyStatus
            },
            mutatingCalls: mutatingCalls
        )

        await store.bootstrap()
        XCTAssertEqual(store.owner, .none)
        XCTAssertEqual(store.lifecycle, .degraded("请在系统设置的登录项中允许 Mimi Remote Mac。"))

        homebrewLoaded.value = true
        await DashboardPresentation.performRecheck(store: store) {}

        XCTAssertEqual(store.owner, .homebrew)
        XCTAssertTrue(store.homebrewLoaded)
        XCTAssertEqual(store.lifecycle, .migrationRequired)
        XCTAssertEqual(store.status, readyStatus)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(statusAtCalls.current, 1)
        XCTAssertEqual(mutatingCalls.values, [])
    }

    func testDashboardRecheckUsesReadinessWithoutRuntimeAndNeverSchedulesFollowUpOrStartsService() async {
        let mutatingCalls = EventRecorder()
        let fullStatusCalls = CallCounter()
        let readinessCalls = CallCounter()
        var agentState: ServiceRegistrationState = .requiresApproval

        let retryableRuntime = AgentRuntimeStatusSnapshot(
            checkedAt: "2026-11-26T00:00:00Z",
            runtimes: [
                AgentRuntimeStatus(
                    id: "claude",
                    title: "Claude",
                    enabled: true,
                    state: .unavailable,
                    version: nil,
                    startedAt: nil,
                    authMode: nil,
                    planType: nil,
                    reason: "bridge_unavailable",
                    rateLimits: nil
                ),
            ],
            refreshing: true,
            stale: false
        )
        let retryRequestedStatus = Self.makeAgentStatus(
            processOK: true,
            serviceOK: true,
            runtimeStatus: retryableRuntime
        )
        let store = makeRecheckHostStore(
            agentStatus: { agentState },
            status: {
                _ = fullStatusCalls.increment()
                mutatingCalls.append("agent.status(--runtime)")
                return retryRequestedStatus
            },
            readiness: {
                _ = readinessCalls.increment()
                return retryRequestedStatus
            },
            mutatingCalls: mutatingCalls
        )

        await store.bootstrap()
        XCTAssertEqual(fullStatusCalls.current, 0)
        XCTAssertEqual(readinessCalls.current, 0)

        // 1. 批准后重新检查：只走不含 --runtime 的 readiness，即使返回需要重试的 runtime 状态也不调度后台 follow-up。
        agentState = .enabled
        await store.observeServiceStatePassively()

        XCTAssertEqual(store.owner, .macApp)
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertTrue(store.runtimeStatusNeedsFollowUp)
        XCTAssertFalse(
            store.hasScheduledRuntimeStatusFollowUp,
            "被动重新检查绝不能调度会调用 refreshMacAgentStatus / startMacAgentIfNeeded 的 follow-up"
        )
        XCTAssertEqual(readinessCalls.current, 1)
        XCTAssertEqual(fullStatusCalls.current, 0, "被动重新检查不得调用会拉起 Claude bridge 的 --runtime status")
        XCTAssertEqual(mutatingCalls.values, [])
        XCTAssertEqual(AgentCommandClient.statusArguments(includeRuntime: false), ["status", "--json"])

        // 菜单先前发起的重试也属于旧代，即使本次观察没有改变 owner。
        store.scheduleRuntimeStatusFollowUp()
        XCTAssertTrue(store.hasScheduledRuntimeStatusFollowUp)
        await store.observeServiceStatePassively()
        XCTAssertFalse(store.hasScheduledRuntimeStatusFollowUp)
        XCTAssertEqual(readinessCalls.current, 2)

        // 2. 登记变为 .notFound 后再次重新检查：仅切回未托管停止态，不注册、不启动、不重启。
        agentState = .notFound
        await store.observeServiceStatePassively()

        XCTAssertEqual(store.owner, .none)
        XCTAssertEqual(store.lifecycle, .stopped)
        XCTAssertNil(store.status)
        XCTAssertNil(store.doctor)
        XCTAssertNil(store.lastError)
        XCTAssertFalse(store.hasScheduledRuntimeStatusFollowUp)
        XCTAssertEqual(readinessCalls.current, 2)
        XCTAssertEqual(fullStatusCalls.current, 0)
        XCTAssertEqual(mutatingCalls.values, [])
    }

    func testInFlightMonitoringTickCannotStartServiceOrOverwriteRecheckAfterOwnerReset() async {
        // 场景 A：monitoring tick 挂起在 health.check，期间 recheck 观察到 .notRegistered 将 owner 归零。
        // 恢复后 health.check 返回 false 时，旧 tick 不得回退调用 HostStore.refresh() 起服。
        do {
            let mutatingCalls = EventRecorder()
            let healthGate = SuspendedStatusGate()
            var agentState: ServiceRegistrationState = .enabled
            let readyStatus = Self.makeAgentStatus(processOK: true, serviceOK: true)

            let store = makeRecheckHostStore(
                agentStatus: { agentState },
                status: { readyStatus },
                readiness: { readyStatus },
                healthCheck: { _ in
                    await healthGate.suspendReturning(false)
                },
                mutatingCalls: mutatingCalls
            )
            await store.bootstrap()
            XCTAssertEqual(store.owner, .macApp)
            XCTAssertEqual(store.lifecycle, .ready)

            let tickTask = Task { @MainActor in
                await store.performMonitoringTick(1, now: Date())
            }
            await healthGate.waitUntilSuspended()

            agentState = .notRegistered
            await store.observeServiceStatePassively()
            XCTAssertEqual(store.owner, .none)
            XCTAssertEqual(store.lifecycle, .stopped)
            XCTAssertNil(store.status)

            healthGate.resume()
            await tickTask.value

            XCTAssertEqual(store.owner, .none)
            XCTAssertEqual(store.lifecycle, .stopped)
            XCTAssertNil(store.status)
            XCTAssertEqual(mutatingCalls.values, [], "挂起恢复的旧监控 tick 绝不能在 owner 变更后回退启动服务")
        }

        // 场景 B：monitoring tick 挂起在 readiness，期间 recheck 观察到 .notRegistered 将状态置为 .stopped。
        // 恢复后旧 readiness 返回 .ready，不得覆盖 .stopped。
        do {
            let mutatingCalls = EventRecorder()
            let readinessGate = SuspendedStatusGate()
            var agentState: ServiceRegistrationState = .enabled
            let readyStatus = Self.makeAgentStatus(processOK: true, serviceOK: true)

            let store = makeRecheckHostStore(
                agentStatus: { agentState },
                status: { readyStatus },
                readiness: {
                    await readinessGate.suspendReturning(readyStatus)
                },
                healthCheck: { _ in true },
                mutatingCalls: mutatingCalls
            )
            await store.bootstrap()
            XCTAssertEqual(store.owner, .macApp)
            XCTAssertEqual(store.lifecycle, .ready)

            let tickTask = Task { @MainActor in
                await store.performMonitoringTick(6, now: Date().addingTimeInterval(60))
            }
            await readinessGate.waitUntilSuspended()

            agentState = .notRegistered
            await store.observeServiceStatePassively()
            XCTAssertEqual(store.owner, .none)
            XCTAssertEqual(store.lifecycle, .stopped)
            XCTAssertNil(store.status)

            readinessGate.resume()
            await tickTask.value

            XCTAssertEqual(store.owner, .none)
            XCTAssertEqual(store.lifecycle, .stopped)
            XCTAssertNil(store.status)
            XCTAssertEqual(mutatingCalls.values, [])
        }
    }

    func testFullMonitoringTickDuringRecheckCannotRegisterMissingAgent() async {
        let brewProbe = SuspendedStatusGate()
        let calls = EventRecorder()
        let ready = Self.makeAgentStatus(processOK: true, serviceOK: true)
        let store = makeRecheckHostStore(
            agentStatus: { .notFound },
            homebrewLoaded: { await brewProbe.suspendReturning(false) },
            status: {
                calls.append("agent.status(--runtime)")
                return ready
            },
            mutatingCalls: calls
        )
        store.owner = .macApp
        store.status = ready
        store.lifecycle = .degraded("服务需要检查")

        let recheck = Task { await store.observeServiceStatePassively() }
        await brewProbe.waitUntilSuspended()
        await store.performMonitoringTick(30, now: Date())
        brewProbe.resume()
        await recheck.value

        XCTAssertEqual(calls.values, [])
        XCTAssertEqual(store.lifecycle, .stopped)
        XCTAssertEqual(store.owner, .none)
        XCTAssertNil(store.status)
    }

    func testRecheckCannotResetOwnerWhileRestartWaitsForOldListener() async {
        let brewProbe = SuspendedStatusGate()
        let stopProbe = SuspendedStatusGate()
        let calls = EventRecorder()
        let ready = Self.makeAgentStatus(processOK: true, serviceOK: true)
        var registration: ServiceRegistrationState = .enabled
        let store = makeRecheckHostStore(
            agentStatus: { registration },
            homebrewLoaded: { await brewProbe.suspendReturning(false) },
            status: { ready },
            healthCheck: { _ in await stopProbe.suspendReturning(false) },
            mutatingCalls: calls
        )
        store.owner = .macApp
        store.status = ready
        store.lifecycle = .degraded("服务需要检查")

        let recheck = Task { await store.observeServiceStatePassively() }
        await brewProbe.waitUntilSuspended()
        registration = .notRegistered
        let restart = Task { await store.restartService() }
        await stopProbe.waitUntilSuspended()
        brewProbe.resume()
        await recheck.value
        XCTAssertEqual(store.lifecycle, .starting)
        XCTAssertEqual(store.owner, .macApp)

        registration = .enabled
        stopProbe.resume()
        await restart.value
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertEqual(store.owner, .macApp)
        XCTAssertEqual(calls.values, ["services.unregisterAgent", "services.registerAgent"])
    }

    func testStaleRecheckResponseIsIgnoredWhenOwnerChangesMidRecheck() async {
        let mutatingCalls = EventRecorder()
        let readinessGate = SuspendedStatusGate()
        var agentState: ServiceRegistrationState = .requiresApproval
        let staleDegraded = Self.makeAgentStatus(
            processOK: true,
            serviceOK: false,
            serviceError: "旧的就绪失败"
        )

        let store = makeRecheckHostStore(
            agentStatus: { agentState },
            status: { staleDegraded },
            readiness: {
                await readinessGate.suspendReturning(staleDegraded)
            },
            mutatingCalls: mutatingCalls
        )
        await store.bootstrap()

        agentState = .enabled
        let recheckTask = Task { @MainActor in
            await store.observeServiceStatePassively()
        }
        await readinessGate.waitUntilSuspended()

        // 模拟 recheck 挂起期间发生了更新的所有权切换。
        store.owner = .homebrew
        store.lifecycle = .migrationRequired

        readinessGate.resume()
        await recheckTask.value

        XCTAssertEqual(store.owner, .homebrew)
        XCTAssertEqual(store.lifecycle, .migrationRequired)
        XCTAssertNil(store.status)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(mutatingCalls.values, [])
    }

    func testOnboardingStartedMidRecheckIsNotOverwritten() async {
        // 场景 A：挂起在 homebrew.isLoaded() 时用户进入向导，恢复后无论是否检测到 Homebrew 都不得覆写向导态。
        do {
            let mutatingCalls = EventRecorder()
            let homebrewGate = SuspendedStatusGate()
            let readinessCalls = CallCounter()
            let statusAtCalls = CallCounter()
            let readyStatus = Self.makeAgentStatus(processOK: true, serviceOK: true)

            let store = makeRecheckHostStore(
                agentStatus: { .notRegistered },
                homebrewLoaded: {
                    await homebrewGate.suspendReturning(true)
                },
                status: { readyStatus },
                readiness: {
                    _ = readinessCalls.increment()
                    return readyStatus
                },
                statusAt: { _ in
                    _ = statusAtCalls.increment()
                    return readyStatus
                },
                mutatingCalls: mutatingCalls
            )
            store.lifecycle = .stopped

            let recheckTask = Task { @MainActor in
                await store.observeServiceStatePassively()
            }
            await homebrewGate.waitUntilSuspended()

            store.beginOnboarding()
            XCTAssertTrue(store.isOnboardingInProgress)
            XCTAssertEqual(store.lifecycle, .notConfigured)

            homebrewGate.resume()
            await recheckTask.value

            XCTAssertTrue(store.isOnboardingInProgress)
            XCTAssertEqual(store.lifecycle, .notConfigured)
            XCTAssertEqual(store.owner, .none)
            XCTAssertFalse(store.homebrewLoaded)
            XCTAssertEqual(readinessCalls.current, 0)
            XCTAssertEqual(statusAtCalls.current, 0)
            XCTAssertEqual(mutatingCalls.values, [])
        }

        // 场景 B：挂起在 agent.readiness() 时用户进入向导，恢复后不得覆盖 .notConfigured。
        do {
            let mutatingCalls = EventRecorder()
            let readinessGate = SuspendedStatusGate()
            let readyStatus = Self.makeAgentStatus(processOK: true, serviceOK: true)

            let store = makeRecheckHostStore(
                agentStatus: { .enabled },
                status: { readyStatus },
                readiness: {
                    await readinessGate.suspendReturning(readyStatus)
                },
                mutatingCalls: mutatingCalls
            )
            store.lifecycle = .degraded("此前失败")

            let recheckTask = Task { @MainActor in
                await store.observeServiceStatePassively()
            }
            await readinessGate.waitUntilSuspended()

            store.beginOnboarding()
            readinessGate.resume()
            await recheckTask.value

            XCTAssertTrue(store.isOnboardingInProgress)
            XCTAssertEqual(store.lifecycle, .notConfigured)
            XCTAssertNil(store.status)
            XCTAssertNil(store.lastError)
            XCTAssertEqual(mutatingCalls.values, [])
        }
    }

    func testDashboardRecheckClearsStaleStatusAndCommandErrorOnOwnerResetOrNewDiagnosis() async {
        let mutatingCalls = EventRecorder()
        var agentState: ServiceRegistrationState = .enabled
        let readyStatus = Self.makeAgentStatus(processOK: true, serviceOK: true)
        let readinessResult = LockedValue<Result<AgentStatus, Error>>(.success(readyStatus))

        let store = makeRecheckHostStore(
            agentStatus: { agentState },
            status: { readyStatus },
            readiness: { try readinessResult.value.get() },
            mutatingCalls: mutatingCalls
        )
        await store.bootstrap()
        XCTAssertEqual(store.owner, .macApp)
        XCTAssertNotNil(store.status)
        XCTAssertEqual(DashboardPresentation.connectionOwnerLabel(owner: .macApp), "Mimi Remote Mac")
        XCTAssertEqual(DashboardPresentation.connectionOwnerLabel(owner: .homebrew), "Homebrew")
        XCTAssertNil(DashboardPresentation.connectionOwnerLabel(owner: .none))

        // 1. 观测到 .notRegistered 将 owner 归零：必须清空旧 status/doctor/lastError，避免连接卡误标为 Homebrew。
        store.lastError = "旧的命令错误"
        agentState = .notRegistered
        await store.observeServiceStatePassively()

        XCTAssertEqual(store.owner, .none)
        XCTAssertEqual(store.lifecycle, .stopped)
        XCTAssertNil(store.status)
        XCTAssertNil(store.doctor)
        XCTAssertNil(store.lastError)

        // 2. 先遇到命令错误，再由成功的 readiness 返回新的就绪失败：必须清掉旧命令错误，只展示最新诊断。
        agentState = .enabled
        readinessResult.value = .failure(AgentClientError.commandFailed("无法连接后台服务"))
        await store.observeServiceStatePassively()
        XCTAssertEqual(store.lifecycle, .degraded("无法连接后台服务"))
        XCTAssertEqual(store.lastError, "无法连接后台服务")

        readinessResult.value = .success(Self.makeAgentStatus(
            processOK: true,
            serviceOK: false,
            serviceError: "readyz 不可用"
        ))
        await store.observeServiceStatePassively()
        XCTAssertEqual(store.owner, .macApp)
        XCTAssertEqual(store.lifecycle, .degraded("readyz 不可用"))
        XCTAssertNil(store.lastError, "新的只读诊断返回后必须清空上一轮命令错误，不能同时显示两套诊断")
        let remediation = DashboardPresentation.remediation(
            lifecycle: store.lifecycle,
            owner: store.owner,
            agentRegistrationState: store.agentRegistrationState,
            hasConfiguration: store.hasConfiguration()
        )
        XCTAssertNil(
            DashboardPresentation.additionalErrorBanner(
                lifecycle: store.lifecycle,
                lastError: store.lastError,
                remediation: remediation
            )
        )
        XCTAssertEqual(mutatingCalls.values, [])
    }

    func testSingleDashboardPreflightPerRecheckClickAndStalePreflightIgnored() async throws {
        let mutatingCalls = EventRecorder()
        let preflightCalls = CallCounter()
        var agentState: ServiceRegistrationState = .enabled
        let readyStatus = Self.makeAgentStatus(processOK: true, serviceOK: true)
        let degradedStatus = Self.makeAgentStatus(
            processOK: true,
            serviceOK: false,
            serviceError: "readyz 不可用"
        )
        let readinessResult = LockedValue<Result<AgentStatus, Error>>(.success(degradedStatus))
        let serviceNotRunningReport = try Self.makeValidMacPairPreflightReport(
            serviceCode: "service_not_running"
        )
        let configInvalidReport = try Self.makeValidMacPairPreflightReport(
            configCode: "config_invalid"
        )
        let preflightGate = LockedValue<SuspendedStatusGate?>(nil)
        let currentReport = LockedValue(serviceNotRunningReport)

        let store = makeRecheckHostStore(
            agentStatus: { agentState },
            status: { degradedStatus },
            readiness: { try readinessResult.value.get() },
            preflight: { _, _ in
                _ = preflightCalls.increment()
                let report = currentReport.value
                if let gate = preflightGate.value {
                    preflightGate.value = nil
                    return await gate.suspendReturning(report)
                }
                return report
            },
            mutatingCalls: mutatingCalls
        )
        store.owner = .macApp
        store.lifecycle = .degraded("readyz 不可用")

        let coordinator = DashboardPreflightCoordinator()
        // 初始视图挂载触发一次预检。
        await coordinator.handleLifecycleTask(store: store)
        XCTAssertEqual(preflightCalls.current, 1)
        XCTAssertNotNil(coordinator.report)

        // 1. 单次点击「重新检查」引发 .degraded -> .stopped，同时模拟 SwiftUI .task(id:) 回调：
        // 整个点击过程必须只触发一次预检，不能双触发。
        agentState = .notRegistered
        await coordinator.performRecheck(store: store)
        await coordinator.handleLifecycleTask(store: store)
        XCTAssertEqual(store.lifecycle, .stopped)
        XCTAssertEqual(preflightCalls.current, 2, "从 .degraded 切到 .stopped 的单次重新检查只能触发一次预检")
        XCTAssertNotNil(coordinator.report)

        // 2. 生命周期未变化（.stopped -> .stopped）的再次点击也只触发一次预检。
        await coordinator.performRecheck(store: store)
        await coordinator.handleLifecycleTask(store: store)
        XCTAssertEqual(preflightCalls.current, 3)

        // 3. 较慢的旧预检响应恢复后不能覆盖较新一次重新检查写入的诊断。
        let slowGate = SuspendedStatusGate()
        currentReport.value = configInvalidReport
        preflightGate.value = slowGate
        let slowReload = Task { @MainActor in
            await coordinator.reloadPreflight(store: store)
        }
        await slowGate.waitUntilSuspended()
        XCTAssertEqual(preflightCalls.current, 4)

        currentReport.value = serviceNotRunningReport
        await coordinator.performRecheck(store: store)
        XCTAssertEqual(preflightCalls.current, 5)
        XCTAssertEqual(
            coordinator.report?.checks.first(where: { $0.id == .serviceDaemon })?.code,
            "service_not_running"
        )
        XCTAssertNil(coordinator.report?.checks.first(where: { $0.id == .configStore })?.code)

        slowGate.resume()
        await slowReload.value
        XCTAssertEqual(
            coordinator.report?.checks.first(where: { $0.id == .serviceDaemon })?.code,
            "service_not_running",
            "挂起恢复的旧预检不能覆盖更新的诊断报告"
        )
        XCTAssertNil(coordinator.report?.checks.first(where: { $0.id == .configStore })?.code)

        // 4. 服务恢复为 .ready 时重新检查清空预检报告且不再发起新预检。
        agentState = .enabled
        readinessResult.value = .success(readyStatus)
        await coordinator.performRecheck(store: store)
        await coordinator.handleLifecycleTask(store: store)
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertEqual(preflightCalls.current, 5)
        XCTAssertNil(coordinator.report)
        XCTAssertTrue(coordinator.diagnostics.isEmpty)
        XCTAssertEqual(mutatingCalls.values, [])
    }

    private func makeRecheckHostStore(
        configExists: Bool = true,
        agentStatus: @escaping @MainActor () -> ServiceRegistrationState,
        mainAppStatus: @escaping @MainActor () -> ServiceRegistrationState = { .enabled },
        isAgentRegistrationCurrent: @escaping @MainActor () -> Bool = { true },
        homebrewLoaded: @escaping @Sendable () async -> Bool = { false },
        status: @escaping @Sendable () async throws -> AgentStatus,
        readiness: (@Sendable () async throws -> AgentStatus)? = nil,
        statusAt: @escaping @Sendable (URL) async throws -> AgentStatus = { _ in
            DashboardAndSettingsTests.makeAgentStatus(processOK: true, serviceOK: true)
        },
        preflight: (@Sendable (
            OnboardingPreflightOptions,
            (@Sendable (OnboardingCheck) -> Void)?
        ) async throws -> OnboardingPreflightReport)? = nil,
        healthCheck: @escaping @Sendable (String) async -> Bool = { _ in true },
        mutatingCalls: EventRecorder
    ) -> HostStore {
        HostStore(
            agent: AgentCommandClient(
                configExists: { configExists },
                setup: { _ in
                    mutatingCalls.append("agent.setup")
                    throw AgentClientError.commandFailed("unexpected setup")
                },
                preflight: preflight ?? { _, _ in
                    throw AgentClientError.commandFailed("unused preflight")
                },
                setupNoPair: { _, _ in
                    mutatingCalls.append("agent.setupNoPair")
                    throw AgentClientError.commandFailed("unexpected setupNoPair")
                },
                up: { _ in
                    mutatingCalls.append("agent.up")
                    throw AgentClientError.commandFailed("unexpected up")
                },
                status: status,
                readiness: readiness ?? status,
                statusAt: statusAt,
                doctor: { fix in
                    mutatingCalls.append("agent.doctor(\(fix))")
                    throw AgentClientError.commandFailed("unexpected doctor")
                },
                configureClaude: { _, _ in throw AgentClientError.commandFailed("unused") },
                setLANAccess: { _ in throw AgentClientError.commandFailed("unused") },
                pair: { _ in throw AgentClientError.commandFailed("unused") },
                version: { "1.0.0" }
            ),
            services: ServiceManagementClient(
                agentStatus: agentStatus,
                agentConfigurationError: { nil },
                isAgentRegistrationCurrent: isAgentRegistrationCurrent,
                markAgentRegistrationCurrent: {},
                registerAgent: { mutatingCalls.append("services.registerAgent") },
                unregisterAgent: { mutatingCalls.append("services.unregisterAgent") },
                restartAgent: { mutatingCalls.append("services.restartAgent") },
                agentLaunchFailure: { nil },
                mainAppStatus: mainAppStatus,
                registerMainApp: { mutatingCalls.append("services.registerMainApp") },
                unregisterMainApp: { mutatingCalls.append("services.unregisterMainApp") },
                openLoginItemsSettings: { mutatingCalls.append("services.openLoginItemsSettings") }
            ),
            homebrew: HomebrewServiceClient(
                isLoaded: homebrewLoaded,
                installedAgentBinary: { URL(filePath: "/opt/homebrew/bin/agentd") },
                start: { mutatingCalls.append("homebrew.start") },
                stop: { mutatingCalls.append("homebrew.stop") }
            ),
            health: HealthClient(check: healthCheck, checkDirect: { _ in true }),
            logs: AgentLogClient(recentLines: { _ in [] }, exportLines: { [] }),
            systemPrivacySettings: .noop
        )
    }

    private nonisolated static func makeValidMacPairPreflightReport(
        serviceCode: String? = nil,
        configCode: String? = nil
    ) throws -> OnboardingPreflightReport {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let fixtureURL = root.appendingPathComponent("contracts/host-cli/preflight-permission-needed.json")
        let base = try JSONDecoder().decode(
            OnboardingPreflightReport.self,
            from: try Data(contentsOf: fixtureURL)
        )
        let checks = base.checks.map { check -> OnboardingCheck in
            if check.id == .serviceDaemon, let serviceCode {
                return OnboardingCheck(
                    id: .serviceDaemon,
                    state: .actionNeeded,
                    detail: "后台服务尚未运行。请在电脑上启动服务。",
                    blocking: true,
                    code: serviceCode,
                    fix: .runFix(.restartService)
                )
            }
            if check.id == .configStore, let configCode {
                return OnboardingCheck(
                    id: .configStore,
                    state: .error,
                    detail: "配置无法安全读取。",
                    blocking: true,
                    code: configCode,
                    fix: .openSettings(.hostRecovery),
                    configPath: base.configPath
                )
            }
            return check
        }
        return OnboardingPreflightReport(
            ok: false,
            stage: .pair,
            configured: true,
            workspaceConfirmed: true,
            configPath: base.configPath,
            scanRoot: base.scanRoot,
            browseRoot: base.browseRoot,
            scanRootExists: true,
            recommendedNext: configCode != nil ? .configStore : .serviceDaemon,
            recommendedTransport: base.recommendedTransport,
            checks: checks
        )
    }

    private nonisolated static func makeAgentStatus(
        processOK: Bool,
        serviceOK: Bool,
        processError: String? = nil,
        serviceError: String? = nil,
        version: String = "1.0.0",
        serverVersion: String? = "1.0.0",
        projects: Int = 1,
        runtimeStatus: AgentRuntimeStatusSnapshot? = nil
    ) -> AgentStatus {
        AgentStatus(
            processOK: processOK,
            serviceOK: serviceOK,
            processError: processError,
            serviceError: serviceError,
            version: version,
            serverVersion: serverVersion,
            endpoint: "http://100.64.0.8:8787",
            configPath: "/tmp/config.json",
            projects: projects,
            doctorOK: serviceOK,
            doctor: AgentDoctorResults(
                ok: serviceOK,
                version: version,
                listen: "127.0.0.1:8787",
                checks: []
            ),
            pairExpires: nil,
            runtimeStatus: runtimeStatus
        )
    }
}

private final class LockedWorkspaceCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(String, String)] = []

    var values: [(String, String)] {
        lock.withLock { storage }
    }

    func append(_ pair: (String, String)) {
        lock.withLock { storage.append(pair) }
    }
}

private final class LockedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T

    init(_ initial: T) {
        storage = initial
    }

    var value: T {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}
