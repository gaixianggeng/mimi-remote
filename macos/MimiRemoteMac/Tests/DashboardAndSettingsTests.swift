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

    private func makeRecheckHostStore(
        configExists: Bool = true,
        agentStatus: @escaping @MainActor () -> ServiceRegistrationState,
        mainAppStatus: @escaping @MainActor () -> ServiceRegistrationState = { .enabled },
        isAgentRegistrationCurrent: @escaping @MainActor () -> Bool = { true },
        homebrewLoaded: @escaping @Sendable () async -> Bool = { false },
        status: @escaping @Sendable () async throws -> AgentStatus,
        statusAt: @escaping @Sendable (URL) async throws -> AgentStatus = { _ in
            DashboardAndSettingsTests.makeAgentStatus(processOK: true, serviceOK: true)
        },
        mutatingCalls: EventRecorder
    ) -> HostStore {
        HostStore(
            agent: AgentCommandClient(
                configExists: { configExists },
                setup: { _ in
                    mutatingCalls.append("agent.setup")
                    throw AgentClientError.commandFailed("unexpected setup")
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
                readiness: status,
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
            health: HealthClient(check: { _ in true }, checkDirect: { _ in true }),
            logs: AgentLogClient(recentLines: { _ in [] }, exportLines: { [] }),
            systemPrivacySettings: .noop
        )
    }

    private nonisolated static func makeAgentStatus(
        processOK: Bool,
        serviceOK: Bool,
        processError: String? = nil,
        serviceError: String? = nil,
        version: String = "1.0.0",
        serverVersion: String? = "1.0.0",
        projects: Int = 1
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
            pairExpires: nil
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
