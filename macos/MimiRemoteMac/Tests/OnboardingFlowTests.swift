import Foundation
import XCTest
@testable import MimiRemoteMac

@MainActor
final class OnboardingFlowTests: XCTestCase {
    private static func contractsDirectory() -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        return root.appendingPathComponent("contracts/host-cli")
    }

    private func loadContractData(_ filename: String) throws -> Data {
        try Data(contentsOf: Self.contractsDirectory().appendingPathComponent(filename))
    }

    private func decodeFixture<T: Decodable>(_ type: T.Type, filename: String) throws -> T {
        try JSONDecoder().decode(type, from: loadContractData(filename))
    }

    // MARK: - Single-flight cancellation, late response discard & NDJSON streaming

    func testSingleFlightCancelsInFlightPreflightAndDiscardsLateResponsesAndProgress() async throws {
        let firstGate = OnboardingGate()
        let report1 = try Self.makeMacSetupReport(
            configured: false,
            scanRoot: "/fixture/workspace-old",
            browseRoot: "/fixture/workspace-old",
            claudeReady: false
        )
        let report2 = try Self.makeMacSetupReport(
            configured: false,
            scanRoot: "/fixture/workspace-new",
            browseRoot: "/fixture/workspace-new",
            claudeReady: true
        )
        let calls = CallCounter()
        let capturedOptions = LockedBox<[OnboardingPreflightOptions]>([])

        var deps = Self.makeDependencies()
        deps.preflight = { options, onProgress in
            capturedOptions.modify { $0.append(options) }
            let call = calls.increment()
            if call == 1 {
                onProgress?(OnboardingCheck(
                    id: .assistantCodex,
                    state: .checking,
                    detail: "正在检查。",
                    blocking: false,
                    enabled: false,
                    available: nil,
                    hasAvailableKey: true,
                    candidates: []
                ))
                await firstGate.wait()
                // 模拟迟到进度与迟到完整报告：即使忽略取消也不能覆盖新一代状态。
                onProgress?(OnboardingCheck(
                    id: .assistantClaude,
                    state: .checking,
                    detail: "迟到的检查。",
                    blocking: false,
                    enabled: false,
                    available: nil,
                    hasAvailableKey: true,
                    candidates: []
                ))
                return report1
            }
            return report2
        }

        let store = OnboardingStore(dependencies: deps)
        let firstTask = Task { await store.start() }
        await firstGate.waitUntilWaiting()

        // 切换路径立即取消第 1 次预检并启动第 2 次预检。
        await store.selectWorkspaceRoot(URL(filePath: "/fixture/workspace-new"))
        XCTAssertEqual(store.report?.scanRoot, "/fixture/workspace-new")
        XCTAssertEqual(store.check(for: .assistantClaude)?.state, .ok)

        // 释放第 1 次迟到响应，验证不会被旧报告或旧进度覆盖。
        firstGate.resume()
        await firstTask.value
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(calls.current, 2)
        XCTAssertEqual(store.report?.scanRoot, "/fixture/workspace-new")
        XCTAssertEqual(store.check(for: .assistantClaude)?.state, .ok)
    }

    func testStreamingSlowAssistantUpdatesFastRowsBeforeSlowAssistantFinishes() async throws {
        let ndjsonLines = String(
            decoding: try loadContractData("preflight-progress-slow-assistant.ndjson"),
            as: UTF8.self
        )
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map(String.init)
        XCTAssertEqual(ndjsonLines.count, 36)

        let streamedChecks = try ndjsonLines.map { line in
            try JSONDecoder().decode(OnboardingCheck.self, from: Data(line.utf8))
        }
        let finalReport = try decodeFixture(
            OnboardingPreflightReport.self,
            filename: "preflight-codex-chatgpt-app.json"
        )
        let slowGate = OnboardingGate()

        var deps = Self.makeDependencies()
        deps.preflight = { _, onProgress in
            for check in streamedChecks.prefix(26) {
                onProgress?(check)
            }
            await slowGate.wait()
            for check in streamedChecks.dropFirst(26) {
                onProgress?(check)
            }
            return finalReport
        }

        let store = OnboardingStore(dependencies: deps)
        let task = Task { await store.runPreflight(stage: .pair) }
        await slowGate.waitUntilWaiting()
        try await Task.sleep(for: .milliseconds(40))

        // 慢助手 Claude 还在 checking 时，快助手 Codex 与 assistant_any 已实时更新为 ok。
        XCTAssertTrue(store.isCheckingPreflight)
        XCTAssertEqual(store.check(for: .assistantCodex)?.state, .ok)
        XCTAssertEqual(store.check(for: .assistantAny)?.state, .ok)
        XCTAssertEqual(store.check(for: .assistantClaude)?.state, .checking)

        slowGate.resume()
        await task.value

        XCTAssertFalse(store.isCheckingPreflight)
        XCTAssertEqual(store.check(for: .assistantClaude)?.state, .actionNeeded)
        XCTAssertEqual(store.check(for: .assistantClaude)?.code, "claude_signed_out")
    }

    // MARK: - Wire-state rendering, signed-out, pin reset & in-memory draft

    func testSignedOutUsesOpenURLAndSecondaryRetryWithoutTerminalExecution() async throws {
        let report = try decodeFixture(
            OnboardingPreflightReport.self,
            filename: "preflight-codex-chatgpt-app.json"
        )
        let openedURLs = EventRecorder()
        let preflightCalls = CallCounter()

        var deps = Self.makeDependencies()
        deps.preflight = { _, _ in
            _ = preflightCalls.increment()
            return report
        }
        deps.openURL = { url in
            openedURLs.append(url.absoluteString)
        }

        let store = OnboardingStore(dependencies: deps)
        await store.runPreflight(stage: .pair)

        let claude = try XCTUnwrap(store.check(for: .assistantClaude))
        let diag = try XCTUnwrap(store.diagnostic(for: claude))
        XCTAssertEqual(claude.state, .actionNeeded)
        XCTAssertFalse(claude.blocking)
        XCTAssertEqual(diag.code, "claude_signed_out")
        XCTAssertTrue(diag.message.contains("2.1.300"))
        XCTAssertEqual(diag.primaryAction, .openURL(.claude))
        XCTAssertEqual(diag.secondaryAction, .retry)
        XCTAssertEqual(diag.secondaryLabel, "我已登录，重新检查")
        XCTAssertEqual(claude.candidates?.count, 1)

        await store.performCheckPrimaryAction(for: claude)
        XCTAssertEqual(openedURLs.values, [OnboardingFixURL.claude.rawValue])
        XCTAssertEqual(preflightCalls.current, 1)

        // 点击次按钮「我已登录，重新检查」仅重新检查。
        await store.performCheckSecondaryAction(for: claude)
        XCTAssertEqual(preflightCalls.current, 2)
    }

    func testUnconfiguredDraftEnableAndRuntimePinResetNeverMutateConfig() async throws {
        let report = try Self.makeMacSetupReport(
            configured: false,
            scanRoot: "/fixture/workspace",
            browseRoot: "/fixture/workspace",
            claudeReady: false,
            codexInvalidPin: true,
            agyAvailableDisabled: true
        )
        let recordedOptions = LockedBox<[OnboardingPreflightOptions]>([])
        let enableAssistantCalls = CallCounter()
        let setRuntimePathCalls = CallCounter()
        let setupCalls = CallCounter()

        var deps = Self.makeDependencies()
        deps.preflight = { options, _ in
            recordedOptions.modify { $0.append(options) }
            return report
        }
        deps.enableAssistant = { _ in _ = enableAssistantCalls.increment() }
        deps.setRuntimePath = { _, _ in _ = setRuntimePathCalls.increment() }
        deps.setupNoPair = { _, _ in
            _ = setupCalls.increment()
            throw TestError.expected
        }

        let store = OnboardingStore(dependencies: deps)
        await store.start()
        XCTAssertFalse(store.isConfigured)

        // 未配置前启用 agy 只改内存草稿并带 --assistant agy=enabled 重跑预检。
        let agyCheck = try XCTUnwrap(store.check(for: .assistantAgy))
        await store.performCheckPrimaryAction(for: agyCheck)
        XCTAssertEqual(enableAssistantCalls.current, 0)
        XCTAssertEqual(setupCalls.current, 0)
        XCTAssertEqual(store.draftAssistants["agy"], "enabled")
        XCTAssertEqual(recordedOptions.value.last?.assistants.map { "\($0.id)=\($0.value)" }, ["agy=enabled"])

        // 坏 pin 显示「恢复自动检测」；未配置前先手选路径再恢复自动检测，每个 ID 只传一次。
        let codexCheck = try XCTUnwrap(store.check(for: .assistantCodex))
        XCTAssertTrue(store.canResetRuntimePin(for: codexCheck))
        await store.selectRuntimeBinaryPath(for: "codex", url: URL(filePath: "/opt/homebrew/bin/codex"))
        XCTAssertEqual(setRuntimePathCalls.current, 0)
        XCTAssertEqual(
            recordedOptions.value.last?.runtimePaths.map { "\($0.id)=\($0.value)" },
            ["codex=/opt/homebrew/bin/codex"]
        )

        await store.resetRuntimePathToAuto(for: "codex")
        XCTAssertEqual(setRuntimePathCalls.current, 0)
        XCTAssertEqual(
            recordedOptions.value.last?.runtimePaths.map { "\($0.id)=\($0.value)" },
            ["codex=auto"]
        )

        // 配置后修改 pin 与清 pin 走 agentd runtime --runtime-path。
        let configuredReport = try Self.makeMacSetupReport(
            configured: true,
            scanRoot: "/fixture/workspace",
            browseRoot: "/fixture/workspace",
            claudeReady: true,
            codexInvalidPin: true
        )
        let runtimeMutations = EventRecorder()
        var postDeps = Self.makeDependencies()
        postDeps.preflight = { _, _ in configuredReport }
        postDeps.setRuntimePath = { id, value in runtimeMutations.append("\(id)=\(value)") }

        let postStore = OnboardingStore(dependencies: postDeps)
        await postStore.start()
        XCTAssertTrue(postStore.isConfigured)
        await postStore.resetRuntimePathToAuto(for: "codex")
        XCTAssertEqual(runtimeMutations.values, ["codex=auto"])
    }

    // MARK: - Step 2: Zero-assistant save, least-privilege browse root, missing dir confirm, concurrent change & never replay save

    func testZeroAssistantEmptyDirSaveEnforcesLeastPrivilegeBrowseRootAndMissingDirConfirmation() async throws {
        let setupReport = try Self.makeMacSetupReport(
            configured: false,
            scanRoot: "/fixture/empty-workspace",
            browseRoot: "/fixture/empty-workspace",
            scanRootExists: false,
            claudeReady: false
        )
        let pairReport = try decodeFixture(
            OnboardingPreflightReport.self,
            filename: "preflight-all-green.json"
        )
        let setupReceipt = try decodeFixture(
            SetupReceipt.self,
            filename: "setup-ok-no-assistant.json"
        )

        let createdDirs = EventRecorder()
        let capturedSetup = LockedBox<(URL, OnboardingSetupOptions)?>(nil)
        let dirExists = LockedBox(false)

        var deps = Self.makeDependencies()
        deps.preflight = { options, _ in
            options.stage == .setup ? setupReport : pairReport
        }
        deps.directoryExists = { _ in dirExists.value }
        deps.createDirectory = { url in
            createdDirs.append(url.path)
            dirExists.modify { $0 = true }
        }
        deps.setupNoPair = { root, options in
            capturedSetup.modify { $0 = (root, options) }
            return setupReceipt
        }
        deps.registerOrStartService = { .ready }

        let store = OnboardingStore(dependencies: deps)
        await store.start()
        // 零助手、零外部网络也可继续进入步骤 2。
        XCTAssertEqual(store.check(for: .assistantAny)?.state, .actionNeeded)
        XCTAssertEqual(store.check(for: .networkAny)?.state, .actionNeeded)
        XCTAssertTrue(store.canProceedFromEnvironmentCheck)

        await store.proceedToWorkspaceStep()
        XCTAssertEqual(store.currentStep, .workspaceSelection)
        XCTAssertEqual(store.selectedScanRoot?.path, "/fixture/empty-workspace")
        XCTAssertEqual(store.effectiveBrowseRoot?.path, "/fixture/empty-workspace")
        XCTAssertNotEqual(
            store.effectiveBrowseRoot?.path,
            FileManager.default.homeDirectoryForCurrentUser.path
        )

        // 目录不存在时首次点击只要求显式确认，绝不静默建目录或保存。
        await store.saveWorkspaceAndContinue(confirmCreateMissingDirectory: false)
        XCTAssertTrue(store.needsCreateDirectoryConfirmation)
        XCTAssertEqual(createdDirs.values, [])
        XCTAssertNil(capturedSetup.value)

        // 显式确认后创建目录并调用 setup --no-pair --json，且 --browse-root == --scan-root。
        await store.saveWorkspaceAndContinue(confirmCreateMissingDirectory: true)
        XCTAssertEqual(createdDirs.values, ["/fixture/empty-workspace"])
        let committed = try XCTUnwrap(capturedSetup.value)
        XCTAssertEqual(committed.0.path, "/fixture/empty-workspace")
        XCTAssertEqual(committed.1.browseRoot?.path, "/fixture/empty-workspace")
        XCTAssertEqual(store.currentStep, .serviceAndPermissions)
        XCTAssertEqual(store.servicePhase, .ready)
    }

    func testConfigConcurrentChangeReloadsWithoutReplayingSaveAndNeverReplaysAfterCommit() async throws {
        let initialReport = try Self.makeMacSetupReport(
            configured: false,
            scanRoot: "/fixture/workspace-a",
            browseRoot: "/fixture/workspace-a",
            claudeReady: true
        )
        let reloadedReport = try Self.makeMacSetupReport(
            configured: false,
            scanRoot: "/fixture/workspace-b",
            browseRoot: "/fixture/workspace-b",
            claudeReady: true
        )
        let concurrentData = try loadContractData("setup-error-config-concurrent-change.json")
        let concurrentDiag = try OnboardingCopyCatalog.decodeErrorEnvelope(
            from: concurrentData,
            context: OnboardingValidationContext(surface: .cli, platform: .macos, stage: .setup, configured: false)
        ).get()
        let timeoutData = try loadContractData("up-error-service-start-timeout.json")
        let timeoutDiag = try OnboardingCopyCatalog.decodeErrorEnvelope(
            from: timeoutData,
            context: OnboardingValidationContext(surface: .cli, platform: .macos, stage: .pair, configured: true)
        ).get()
        let receipt = SetupReceipt(
            configPath: "/fixture/config/config.json",
            scanRoot: "/fixture/workspace-b",
            browseRoot: "/fixture/workspace-b"
        )
        let pairReport = try decodeFixture(OnboardingPreflightReport.self, filename: "preflight-all-green.json")

        let preflightCalls = CallCounter()
        let setupCalls = CallCounter()
        let serviceStartCalls = CallCounter()

        var deps = Self.makeDependencies()
        deps.preflight = { options, _ in
            if options.stage == .pair { return pairReport }
            let count = preflightCalls.increment()
            return count <= 2 ? initialReport : reloadedReport
        }
        deps.directoryExists = { _ in true }
        deps.setupNoPair = { _, _ in
            if setupCalls.increment() == 1 {
                throw AgentClientError.onboarding(concurrentDiag)
            }
            return receipt
        }
        deps.registerOrStartService = {
            if serviceStartCalls.increment() == 1 {
                throw AgentClientError.onboarding(timeoutDiag)
            }
            return .ready
        }

        let store = OnboardingStore(dependencies: deps)
        await store.start()
        await store.proceedToWorkspaceStep()

        // 第 1 次保存遇到 config_concurrent_change：留在步骤 2，重读配置，绝不自动重放保存。
        await store.saveWorkspaceAndContinue()
        XCTAssertEqual(store.currentStep, .workspaceSelection)
        XCTAssertEqual(store.stepError?.code, "config_concurrent_change")
        XCTAssertEqual(setupCalls.current, 1)
        XCTAssertEqual(store.selectedScanRoot?.path, "/fixture/workspace-b")

        // 用户确认新目录后再次保存成功，但步骤 3 服务启动超时。
        await store.saveWorkspaceAndContinue()
        XCTAssertEqual(setupCalls.current, 2)
        XCTAssertEqual(store.currentStep, .serviceAndPermissions)
        XCTAssertEqual(serviceStartCalls.current, 1)

        // 在步骤 3 重试启动：只重试服务启动，绝不重放 setup --no-pair！
        await store.ensureServiceReady()
        XCTAssertEqual(setupCalls.current, 2)
        XCTAssertEqual(serviceStartCalls.current, 2)
        XCTAssertEqual(store.servicePhase, .ready)

        // 返回步骤 2 不改目录直接继续：仍然绝不重放 setup --no-pair！
        await store.goBack()
        XCTAssertEqual(store.currentStep, .workspaceSelection)
        await store.saveWorkspaceAndContinue()
        XCTAssertEqual(setupCalls.current, 2)
        XCTAssertEqual(store.currentStep, .serviceAndPermissions)
    }

    func testCancellationNearCommitReadsBackConfigAndNeverReplaysCommittedSave() async throws {
        let beforeReport = try Self.makeMacSetupReport(
            configured: false,
            scanRoot: "/fixture/workspace",
            browseRoot: "/fixture/workspace",
            claudeReady: true
        )
        let afterReport = try Self.makeMacSetupReport(
            configured: true,
            scanRoot: "/fixture/workspace",
            browseRoot: "/fixture/workspace",
            claudeReady: true
        )
        let commitGate = OnboardingGate()
        let setupCalls = CallCounter()
        let committedOnDisk = LockedBox(false)

        var deps = Self.makeDependencies()
        deps.preflight = { _, _ in
            committedOnDisk.value ? afterReport : beforeReport
        }
        deps.directoryExists = { _ in true }
        deps.setupNoPair = { _, _ in
            _ = setupCalls.increment()
            committedOnDisk.modify { $0 = true }
            await commitGate.wait()
            throw CancellationError()
        }

        let store = OnboardingStore(dependencies: deps)
        await store.start()
        await store.proceedToWorkspaceStep()

        let saveTask = Task { await store.saveWorkspaceAndContinue() }
        await commitGate.waitUntilWaiting()
        saveTask.cancel()
        commitGate.resume()
        await saveTask.value

        // 取消后读回确认已落盘，后续继续不再重放 setup --no-pair。
        XCTAssertTrue(store.isConfigured)
        XCTAssertTrue(store.hasCommittedCurrentDraft)
        XCTAssertEqual(setupCalls.current, 1)

        await store.saveWorkspaceAndContinue()
        XCTAssertEqual(setupCalls.current, 1)
    }

    func testExistingDistinctBrowseRootIsPreservedAcrossReload() async throws {
        let existingReport = try Self.makeMacSetupReport(
            configured: true,
            scanRoot: "/fixture/workspace",
            browseRoot: "/fixture/parent-browse",
            claudeReady: true
        )
        var deps = Self.makeDependencies()
        deps.preflight = { _, _ in existingReport }

        let store = OnboardingStore(dependencies: deps)
        await store.start()
        XCTAssertTrue(store.isConfigured)
        XCTAssertEqual(store.selectedScanRoot?.path, "/fixture/workspace")
        XCTAssertEqual(store.effectiveBrowseRoot?.path, "/fixture/parent-browse")
    }

    // MARK: - Passive didBecomeActive without HostStore.refresh(), native overlay & service_requires_approval gate

    func testDidBecomeActiveRunsOnlyPassivePreflightWithoutHostStoreRefresh() async throws {
        let preflightCalls = CallCounter()
        let statusCalls = CallCounter()
        let registerCalls = CallCounter()
        let setupReport = try Self.makeMacSetupReport(
            configured: false,
            scanRoot: "/fixture/workspace",
            browseRoot: "/fixture/workspace",
            claudeReady: true
        )

        let agent = AgentCommandClient(
            configExists: { false },
            setup: { _ in throw TestError.expected },
            preflight: { _, _ in
                _ = preflightCalls.increment()
                return setupReport
            },
            status: {
                _ = statusCalls.increment()
                throw TestError.expected
            },
            readiness: { throw TestError.expected },
            statusAt: { _ in throw TestError.expected },
            doctor: { _ in throw TestError.expected },
            configureClaude: { _, _ in throw TestError.expected },
            setLANAccess: { _ in throw TestError.expected },
            pair: { _ in throw TestError.expected },
            version: { "1.0.0" }
        )
        let services = ServiceManagementClient(
            agentStatus: { .notRegistered },
            agentConfigurationError: { nil },
            isAgentRegistrationCurrent: { true },
            markAgentRegistrationCurrent: {},
            registerAgent: { _ = registerCalls.increment() },
            unregisterAgent: {},
            agentLaunchFailure: { nil },
            mainAppStatus: { .notRegistered },
            registerMainApp: {},
            unregisterMainApp: {},
            openLoginItemsSettings: {}
        )
        let hostStore = HostStore(
            agent: agent,
            services: services,
            homebrew: HomebrewServiceClient(isLoaded: { false }, installedAgentBinary: { nil }, start: {}, stop: {}),
            health: HealthClient(check: { _ in false }, checkDirect: { _ in false }),
            logs: AgentLogClient(recentLines: { _ in [] }, exportLines: { [] })
        )
        await hostStore.bootstrap()

        let onboarding = OnboardingStore(dependencies: .live(hostStore: hostStore))
        await onboarding.start()
        XCTAssertEqual(preflightCalls.current, 1)
        XCTAssertEqual(hostStore.lifecycle, .notConfigured)

        // 切回前台仅跑被动预检，绝不触发 HostStore.refresh()、status 或服务注册。
        onboarding.handleApplicationDidBecomeActive()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(preflightCalls.current, 2)
        XCTAssertEqual(statusCalls.current, 0)
        XCTAssertEqual(registerCalls.current, 0)
        XCTAssertEqual(hostStore.lifecycle, .notConfigured)
    }

    func testServiceRequiresApprovalOverlayBlocksQRAndCopyUntilApprovedWhileMainAppLoginItemAllowsPairing() async throws {
        let baseNotRunningReport = try Self.makeMacPairReportWithServiceNotRunning()
        let approvedReportWithLoginWarning = try Self.makeMacPairReportReadyWithLoginItemDisabled()
        let ticket = try decodeFixture(PairingTicketReceipt.self, filename: "pair-ok-direct.json").asPairingInfo

        let agentRegState = LockedBox(ServiceRegistrationState.requiresApproval)
        let mainAppRegState = LockedBox(ServiceRegistrationState.notRegistered)
        let pairCalls = CallCounter()
        let copiedValues = EventRecorder()
        let openedSettings = EventRecorder()
        let currentNow = LockedBox(try XCTUnwrap(OnboardingDateParser.parseRFC3339("2030-01-01T00:01:00Z")))

        var deps = Self.makeDependencies()
        deps.preflight = { _, _ in
            agentRegState.value == .requiresApproval ? baseNotRunningReport : approvedReportWithLoginWarning
        }
        deps.agentRegistrationState = { agentRegState.value }
        deps.mainAppRegistrationState = { mainAppRegState.value }
        deps.photosAccessState = { .notDetermined }
        deps.pair = { _ in
            _ = pairCalls.increment()
            return ticket
        }
        deps.copyToClipboard = { value in
            copiedValues.append(value)
            return true
        }
        deps.openSettings = { target in
            openedSettings.append(target.rawValue)
        }
        deps.now = { currentNow.value }

        let store = OnboardingStore(dependencies: deps)
        await store.goToStep(.connectPhone)

        // 原生覆盖将 service_not_running 替换为 service_requires_approval 并重算 ok / recommended_next。
        XCTAssertEqual(store.check(for: .serviceDaemon)?.code, "service_requires_approval")
        XCTAssertEqual(store.check(for: .serviceDaemon)?.blocking, true)
        XCTAssertEqual(store.report?.ok, false)
        XCTAssertEqual(store.report?.recommendedNext, .serviceDaemon)
        XCTAssertEqual(store.check(for: .permissionLoginItem)?.code, "permission_login_item_disabled")
        XCTAssertEqual(store.check(for: .permissionPhotos)?.code, "permission_unobserved")

        // 审批中严禁出码与复制，且没有跳过出码路径。
        XCTAssertTrue(store.isServiceRequiresApproval)
        XCTAssertFalse(store.canIssuePairingQR)
        XCTAssertFalse(store.canCopyPairingLink)
        XCTAssertNil(store.issuedPairing)
        await store.issuePairingQR()
        XCTAssertFalse(store.copyPairingLink())
        XCTAssertEqual(pairCalls.current, 0)
        XCTAssertEqual(copiedValues.values, [])

        // 用户批准后台 agent，但主应用登录项仍然关闭：重新检查后允许带警告出码并复制真实 pair_url。
        agentRegState.modify { $0 = .enabled }
        mainAppRegState.modify { $0 = .notRegistered }
        await store.runPreflight(stage: .pair)
        try await Task.sleep(for: .milliseconds(40))

        XCTAssertFalse(store.isServiceRequiresApproval)
        XCTAssertNotNil(store.mainAppLoginItemWarning)
        XCTAssertTrue(store.canIssuePairingQR)
        XCTAssertEqual(pairCalls.current, 1)
        XCTAssertEqual(store.issuedPairing?.pairURL, ticket.pairURL)
        XCTAssertTrue(store.canCopyPairingLink)
        XCTAssertTrue(store.copyPairingLink())
        XCTAssertEqual(copiedValues.values, [ticket.pairURL!])
        XCTAssertNotEqual(copiedValues.values.first, ticket.endpoint)

        // 超过真实 pair_expires_at 后立即清除二维码并禁止复制。
        let expiredNow = try XCTUnwrap(OnboardingDateParser.parseRFC3339("2030-01-01T00:06:00Z"))
        currentNow.modify { $0 = expiredNow }
        XCTAssertTrue(store.isIssuedPairingExpired)
        XCTAssertFalse(store.canCopyPairingLink)
        XCTAssertFalse(store.copyPairingLink())
        store.clearIssuedPairingIfExpired()
        XCTAssertNil(store.issuedPairing)
    }

    func testStep4TransportSelectionPerformsZeroAutoMutationAndExplicitEnableIssuesTailcatQR() async throws {
        let tailcatDisabledReport = try Self.makeMacPairReportTailscaleReadyTailcatDisabled()
        let allGreenReport = try decodeFixture(OnboardingPreflightReport.self, filename: "preflight-all-green.json")
        let directTicket = try decodeFixture(PairingTicketReceipt.self, filename: "pair-ok-direct.json").asPairingInfo
        let tailcatTicket = try decodeFixture(PairingTicketReceipt.self, filename: "pair-ok-tailcat.json").asPairingInfo

        let tailcatEnabled = LockedBox(false)
        let enableTransportCalls = EventRecorder()

        var deps = Self.makeDependencies()
        deps.preflight = { _, _ in
            tailcatEnabled.value ? allGreenReport : tailcatDisabledReport
        }
        deps.enableTransport = { transport in
            enableTransportCalls.append(transport.rawValue)
            if transport == .tailcat { tailcatEnabled.modify { $0 = true } }
        }
        deps.pair = { network in
            network == .tailcat ? tailcatTicket : directTicket
        }
        deps.now = { OnboardingDateParser.parseRFC3339("2030-01-01T00:01:00Z")! }

        let store = OnboardingStore(dependencies: deps)
        XCTAssertEqual(store.orderedTransports, [.tailscale, .tailcat, .lan])

        await store.goToStep(.connectPhone)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(store.selectedTransport, .tailscale)
        XCTAssertEqual(store.issuedPairing?.pairURL, directTicket.pairURL)
        XCTAssertEqual(enableTransportCalls.values, [])

        // 切换到未启用的内置连接：清空旧二维码，绝不自动启用通道。
        store.selectTransport(.tailcat)
        XCTAssertNil(store.issuedPairing)
        XCTAssertEqual(enableTransportCalls.values, [])

        // 用户显式点击启用后才启用并签发 Tailcat 二维码。
        await store.enableSelectedTransportAndIssueQR(.tailcat)
        XCTAssertEqual(enableTransportCalls.values, ["tailcat"])
        XCTAssertEqual(store.issuedPairing?.pairURL, tailcatTicket.pairURL)
    }

    func testStep4DiscardsLateQRResponseAfterSwitchingTransport() async throws {
        let allGreenReport = try decodeFixture(OnboardingPreflightReport.self, filename: "preflight-all-green.json")
        let directTicket = try decodeFixture(PairingTicketReceipt.self, filename: "pair-ok-direct.json").asPairingInfo
        let tailcatTicket = try decodeFixture(PairingTicketReceipt.self, filename: "pair-ok-tailcat.json").asPairingInfo
        let slowTailscaleGate = OnboardingGate()

        var deps = Self.makeDependencies()
        deps.preflight = { _, _ in allGreenReport }
        deps.pair = { network in
            if network == .tailscale {
                await slowTailscaleGate.wait()
                return directTicket
            }
            return tailcatTicket
        }
        deps.now = { OnboardingDateParser.parseRFC3339("2030-01-01T00:01:00Z")! }

        let store = OnboardingStore(dependencies: deps)
        await store.goToStep(.connectPhone)
        await slowTailscaleGate.waitUntilWaiting()

        // Tailscale 签发尚未完成时切换至 Tailcat：旧请求被作废，新请求立即生效。
        store.selectTransport(.tailcat)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(store.issuedPairing?.pairURL, tailcatTicket.pairURL)

        slowTailscaleGate.resume()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(store.issuedPairing?.pairURL, tailcatTicket.pairURL)
    }

    func testDMGReadOnlyHelperOpensApplicationsFolderAndUntrustedDiagnosticsDispatchZeroActions() async throws {
        var openedURL: URL?
        let result = ServiceManagementClient.openApplicationsFolder { url in
            openedURL = url
            return true
        }
        XCTAssertTrue(result)
        XCTAssertEqual(openedURL, URL(filePath: "/Applications", directoryHint: .isDirectory))
        XCTAssertEqual(ServiceManagementClient.openApplicationsFolderButtonTitle, "打开“应用程序”文件夹")

        // 不可信或篡改的诊断（例如 rotations_token 注入导致 isTrusted == false）零执行。
        let actions = EventRecorder()
        var deps = Self.makeDependencies()
        deps.runSafeDoctorFix = { actions.append("doctor_fix") }
        deps.openURL = { actions.append($0.absoluteString) }
        let store = OnboardingStore(dependencies: deps)
        let untrusted = OnboardingResolvedDiagnostic(
            code: "config_permissions_unsafe",
            step: .configStore,
            message: OnboardingCopyCatalog.safeFallbackCopy,
            primaryAction: .runFix(.doctorFix),
            secondaryAction: nil,
            secondaryLabel: nil,
            configPath: nil,
            recoveryPath: nil,
            isTrusted: false,
            isLegacyHost: false
        )
        await store.performDiagnosticAction(untrusted)
        XCTAssertEqual(actions.values, [])
    }

    func testConfigInvalidShowsReadOnlyRecoveryWithoutTokenRotation() async throws {
        let invalidData = try loadContractData("setup-error-config-invalid.json")
        let invalidDiag = try OnboardingCopyCatalog.decodeErrorEnvelope(
            from: invalidData,
            context: OnboardingValidationContext(surface: .cli, platform: .macos, stage: .setup, configured: false)
        ).get()
        let setupReport = try Self.makeMacSetupReport(
            configured: false,
            scanRoot: "/fixture/workspace",
            browseRoot: "/fixture/workspace",
            claudeReady: true
        )
        let openedSettings = EventRecorder()
        var deps = Self.makeDependencies()
        deps.preflight = { _, _ in setupReport }
        deps.directoryExists = { _ in true }
        deps.setupNoPair = { _, _ in throw AgentClientError.onboarding(invalidDiag) }
        deps.openSettings = { openedSettings.append($0.rawValue) }

        let store = OnboardingStore(dependencies: deps)
        await store.start()
        await store.proceedToWorkspaceStep()
        await store.saveWorkspaceAndContinue()

        XCTAssertEqual(store.currentStep, .workspaceSelection)
        XCTAssertEqual(store.recoveryDiagnostic?.code, "config_invalid")
        XCTAssertEqual(store.recoveryDiagnostic?.configPath, "…/config.json")
        XCTAssertEqual(store.recoveryDiagnostic?.recoveryPath, "…/config.previous.json")
        if let diag = store.stepError {
            await store.performDiagnosticAction(diag)
        }
        XCTAssertEqual(openedSettings.values, ["host_recovery"])
    }

    // MARK: - Fixture Builders

    private static func makeDependencies() -> OnboardingDependencies {
        OnboardingDependencies(
            preflight: { _, _ in throw TestError.expected },
            setupNoPair: { _, _ in throw TestError.expected },
            setRuntimePath: { _, _ in },
            updateWorkspace: { _, _ in },
            pair: { _ in throw TestError.expected },
            enableAssistant: { _ in },
            enableTransport: { _ in },
            connectDeepSeek: { _ in },
            registerOrStartService: { .ready },
            restartService: {},
            takeoverHomebrew: {},
            runSafeDoctorFix: {},
            agentRegistrationState: { .enabled },
            mainAppRegistrationState: { .enabled },
            photosAccessState: { .notDetermined },
            requestPhotosAccess: { .authorized },
            localNetworkAccessDenied: { false },
            openURL: { _ in },
            openSettings: { _ in },
            directoryExists: { _ in true },
            createDirectory: { _ in },
            copyToClipboard: { _ in true },
            notifyOnboardingStarted: {},
            notifyOnboardingCompleted: { _ in },
            now: { Date() }
        )
    }

    private static func makeMacSetupReport(
        configured: Bool,
        scanRoot: String,
        browseRoot: String,
        scanRootExists: Bool = true,
        claudeReady: Bool,
        codexInvalidPin: Bool = false,
        agyAvailableDisabled: Bool = false
    ) throws -> OnboardingPreflightReport {
        let codexCheck: OnboardingCheck = codexInvalidPin
            ? OnboardingCheck(
                id: .assistantCodex,
                state: .error,
                detail: "Codex 助手：所选程序无法使用。请重新选择程序，或恢复自动检测。",
                blocking: false,
                code: "runtime_path_invalid",
                fix: .choosePath(.codexBin),
                enabled: false,
                available: false,
                candidates: [OnboardingCandidate(path: "/fixture/bad/codex", outcome: .unusable)],
                source: .pin
            )
            : OnboardingCheck(
                id: .assistantCodex,
                state: .optional,
                detail: "未找到 Codex。请打开安装说明，安装完成后重新检查。",
                blocking: false,
                code: "codex_not_found",
                fix: .openURL(.codex),
                enabled: false,
                available: false,
                candidates: [OnboardingCandidate(path: "/fixture/bin/codex", outcome: .missing)],
                source: .auto
            )

        let claudeCheck: OnboardingCheck = claudeReady
            ? OnboardingCheck(
                id: .assistantClaude,
                state: .ok,
                detail: "Claude Code 已就绪。",
                blocking: false,
                enabled: true,
                available: true,
                candidates: [OnboardingCandidate(path: "/fixture/bin/claude", outcome: .selected, version: "2.1.300")],
                source: .auto,
                detectedVersion: "2.1.300"
            )
            : OnboardingCheck(
                id: .assistantClaude,
                state: .optional,
                detail: "未找到 Claude Code。请打开安装说明，安装完成后重新检查。",
                blocking: false,
                code: "claude_not_found",
                fix: .openURL(.claude),
                enabled: false,
                available: false,
                candidates: [OnboardingCandidate(path: "/fixture/bin/claude", outcome: .missing)],
                source: .auto
            )

        let agyCheck: OnboardingCheck = agyAvailableDisabled
            ? OnboardingCheck(
                id: .assistantAgy,
                state: .optional,
                detail: "Antigravity 助手：已检测到可用助手。需要使用时可启用。",
                blocking: false,
                code: "assistant_disabled",
                fix: .runFix(.enableAgy),
                enabled: false,
                available: true,
                candidates: [OnboardingCandidate(path: "/fixture/bin/agy", outcome: .selected, version: "1.5.0")],
                source: .auto,
                detectedVersion: "1.5.0"
            )
            : OnboardingCheck(
                id: .assistantAgy,
                state: .optional,
                detail: "未找到 Antigravity。请打开安装说明，安装完成后重新检查。",
                blocking: false,
                code: "agy_not_found",
                fix: .openURL(.agy),
                enabled: false,
                available: false,
                candidates: [OnboardingCandidate(path: "/fixture/bin/agy", outcome: .missing)],
                source: .auto
            )

        let workspaceCheck: OnboardingCheck = scanRootExists
            ? OnboardingCheck(id: .workspaceRoot, state: .ok, detail: "所选目录可读取。", blocking: false)
            : OnboardingCheck(
                id: .workspaceRoot,
                state: .error,
                detail: "找不到所选代码目录。请重新选择。",
                blocking: true,
                code: "workspace_not_found",
                fix: .choosePath(.workspaceRoot)
            )

        let checks: [OnboardingCheck] = [
            OnboardingCheck(id: .configStore, state: .ok, detail: "可以在此位置保存配置。", blocking: false),
            workspaceCheck,
            OnboardingCheck(id: .serviceOwnerConflict, state: .ok, detail: "后台服务归属已确认。", blocking: false),
            OnboardingCheck(
                id: .serviceDaemon,
                state: .actionNeeded,
                detail: "后台服务尚未注册。请在电脑上注册并启动服务。",
                blocking: false,
                code: "service_not_registered",
                fix: configured ? .runFix(.registerService) : .runFix(.saveSetup)
            ),
            codexCheck,
            claudeCheck,
            agyCheck,
            OnboardingCheck(
                id: .assistantDeepSeek,
                state: .optional,
                detail: "未检测到正在运行的 DeepSeek Harness。请打开启动说明。",
                blocking: false,
                code: "deepseek_not_running",
                fix: .openURL(.harness),
                enabled: false,
                available: false
            ),
            claudeReady
                ? OnboardingCheck(id: .assistantAny, state: .ok, detail: "至少有一个已启用的助手可用。", blocking: false)
                : OnboardingCheck(
                    id: .assistantAny,
                    state: .actionNeeded,
                    detail: "请启用至少一个可用助手，然后重新配对。",
                    blocking: false,
                    code: "no_enabled_assistant",
                    fix: .openURL(.guide)
                ),
            OnboardingCheck(
                id: .networkTailscale,
                state: .optional,
                detail: "未检测到 Tailscale。需要此连接方式时请按说明安装。",
                blocking: false,
                code: "tailscale_not_installed",
                fix: .openURL(.tailscale),
                enabled: false,
                available: false
            ),
            OnboardingCheck(
                id: .networkTailcat,
                state: .optional,
                detail: "内置连接可用，可在配对设置中启用。",
                blocking: false,
                code: "tailcat_disabled",
                fix: configured ? .openSettings(.connections) : .runFix(.saveSetup),
                enabled: false,
                available: true
            ),
            OnboardingCheck(
                id: .networkLAN,
                state: .optional,
                detail: "未检测到可信局域网。请连接专用网络后重新检查。",
                blocking: false,
                code: "lan_unavailable",
                fix: .retry,
                enabled: false,
                available: false
            ),
            OnboardingCheck(
                id: .networkAny,
                state: .actionNeeded,
                detail: "没有可用的直连通道。可在配对时启用内置连接。",
                blocking: false,
                code: "no_direct_network",
                fix: configured ? .openSettings(.connections) : .runFix(.saveSetup)
            ),
            OnboardingCheck(id: .permissionLoginItem, state: .ok, detail: "已允许登录时启动。", blocking: false),
            OnboardingCheck(id: .permissionFolderAccess, state: .ok, detail: "已允许访问所选目录。", blocking: false),
            OnboardingCheck(id: .permissionLocalNetwork, state: .ok, detail: "已允许访问本地网络。", blocking: false),
            OnboardingCheck(
                id: .permissionPhotos,
                state: .optional,
                detail: "照片：尚未获得此权限的状态。可以跳过此项。",
                blocking: false,
                code: "permission_unobserved",
                fix: .skip
            ),
            OnboardingCheck(
                id: .permissionFullDisk,
                state: .optional,
                detail: "完全磁盘访问：尚未获得此权限的状态。可以跳过此项。",
                blocking: false,
                code: "permission_unobserved",
                fix: .skip
            ),
        ]

        let firstBlocker = checks.first(where: \.blocking)?.id
        return OnboardingPreflightReport(
            ok: firstBlocker == nil,
            stage: .setup,
            configured: configured,
            workspaceConfirmed: configured,
            configPath: "/fixture/config/config.json",
            scanRoot: scanRoot,
            browseRoot: browseRoot,
            scanRootExists: scanRootExists,
            recommendedNext: firstBlocker ?? (configured ? .networkAny : .configStore),
            recommendedTransport: .tailcat,
            checks: checks
        )
    }

    private static func makeMacPairReportWithServiceNotRunning() throws -> OnboardingPreflightReport {
        let base = try JSONDecoder().decode(
            OnboardingPreflightReport.self,
            from: try Data(contentsOf: contractsDirectory().appendingPathComponent("preflight-permission-needed.json"))
        )
        let checks = base.checks.map { check -> OnboardingCheck in
            guard check.id == .serviceDaemon else { return check }
            return OnboardingCheck(
                id: .serviceDaemon,
                state: .actionNeeded,
                detail: "后台服务尚未运行。请在电脑上启动服务。",
                blocking: true,
                code: "service_not_running",
                fix: .runFix(.restartService)
            )
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
            recommendedNext: .serviceDaemon,
            recommendedTransport: base.recommendedTransport,
            checks: checks
        )
    }

    private static func makeMacPairReportReadyWithLoginItemDisabled() throws -> OnboardingPreflightReport {
        let base = try JSONDecoder().decode(
            OnboardingPreflightReport.self,
            from: try Data(contentsOf: contractsDirectory().appendingPathComponent("preflight-permission-needed.json"))
        )
        let checks = base.checks.map { check -> OnboardingCheck in
            guard check.id == .serviceDaemon else { return check }
            return OnboardingCheck(
                id: .serviceDaemon,
                state: .ok,
                detail: "后台服务已通过就绪检查。",
                blocking: false
            )
        }
        return OnboardingPreflightReport(
            ok: true,
            stage: .pair,
            configured: true,
            workspaceConfirmed: true,
            configPath: base.configPath,
            scanRoot: base.scanRoot,
            browseRoot: base.browseRoot,
            scanRootExists: true,
            recommendedNext: .networkAny,
            recommendedTransport: base.recommendedTransport,
            checks: checks
        )
    }

    private static func makeMacPairReportTailscaleReadyTailcatDisabled() throws -> OnboardingPreflightReport {
        let base = try JSONDecoder().decode(
            OnboardingPreflightReport.self,
            from: try Data(contentsOf: contractsDirectory().appendingPathComponent("preflight-all-green.json"))
        )
        let checks = base.checks.map { check -> OnboardingCheck in
            guard check.id == .networkTailcat else { return check }
            return OnboardingCheck(
                id: .networkTailcat,
                state: .optional,
                detail: "内置连接可用，可在配对设置中启用。",
                blocking: false,
                code: "tailcat_disabled",
                fix: .runFix(.enableTailcat),
                enabled: false,
                available: true
            )
        }
        return OnboardingPreflightReport(
            ok: true,
            stage: .pair,
            configured: true,
            workspaceConfirmed: true,
            configPath: base.configPath,
            scanRoot: base.scanRoot,
            browseRoot: base.browseRoot,
            scanRootExists: true,
            recommendedNext: .networkAny,
            recommendedTransport: .tailscale,
            checks: checks
        )
    }
}

private final class OnboardingGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var waiting = false
    private var released = false

    func wait() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                condition.lock()
                waiting = true
                condition.broadcast()
                while !released {
                    condition.wait()
                }
                condition.unlock()
                continuation.resume()
            }
        }
    }

    func waitUntilWaiting() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                condition.lock()
                while !waiting {
                    condition.wait()
                }
                condition.unlock()
                continuation.resume()
            }
        }
    }

    func resume() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T

    init(_ initial: T) {
        self.storage = initial
    }

    var value: T {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func modify(_ body: (inout T) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&storage)
    }
}
