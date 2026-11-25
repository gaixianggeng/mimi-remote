import AppKit
import Foundation
import Observation

enum OnboardingWizardStep: Int, CaseIterable, Equatable, Hashable, Identifiable, Sendable {
    case environmentCheck = 1
    case workspaceSelection = 2
    case serviceAndPermissions = 3
    case connectPhone = 4

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .environmentCheck: "检查环境"
        case .workspaceSelection: "选择代码目录"
        case .serviceAndPermissions: "后台服务与权限"
        case .connectPhone: "连接手机"
        }
    }

    var shortLabel: String {
        "\(rawValue). \(title)"
    }
}

enum OnboardingServicePhase: Equatable, Sendable {
    case idle
    case configSaved
    case registeringService
    case waitingForReadiness
    case ready
    case requiresApproval
    case homebrewActive
    case failed(OnboardingResolvedDiagnostic)
}

enum OnboardingPathPickerRequest: Equatable, Identifiable, Sendable {
    case workspaceRoot
    case runtimeBinary(runtimeID: String, target: OnboardingPathTarget)

    var id: String {
        switch self {
        case .workspaceRoot: "workspace_root"
        case .runtimeBinary(let runtimeID, _): "runtime_\(runtimeID)"
        }
    }
}

struct OnboardingDependencies {
    var preflight: @Sendable (
        _ options: OnboardingPreflightOptions,
        _ onProgress: (@Sendable (OnboardingCheck) -> Void)?
    ) async throws -> OnboardingPreflightReport
    var setupNoPair: @Sendable (
        _ workspaceRoot: URL,
        _ options: OnboardingSetupOptions
    ) async throws -> SetupReceipt
    var setRuntimePath: @Sendable (_ runtimeID: String, _ value: String) async throws -> Void
    var updateWorkspace: @Sendable (_ scanRoot: URL, _ browseRoot: URL?) async throws -> Void
    var pair: @Sendable (_ network: PairingNetwork) async throws -> PairingInfo
    var enableAssistant: @MainActor (_ runtimeID: String) async throws -> Void
    var enableTransport: @MainActor (_ transport: OnboardingTransport) async throws -> Void
    var connectDeepSeek: @MainActor (_ startupURL: String?) async throws -> Void
    var registerOrStartService: @MainActor (_ onRegistered: @MainActor () -> Void) async throws -> HostStore.OnboardingServiceStartOutcome
    var restartService: @MainActor () async throws -> Void
    var takeoverHomebrew: @MainActor () async throws -> Void
    var runSafeDoctorFix: @MainActor () async throws -> Void
    var agentRegistrationState: @MainActor () -> ServiceRegistrationState
    var mainAppRegistrationState: @MainActor () -> ServiceRegistrationState
    var photosAccessState: @MainActor () -> PhotosAccessState
    var requestPhotosAccess: @MainActor () async -> PhotosAccessState
    var localNetworkAccessDenied: @MainActor () -> Bool
    var openURL: @MainActor (URL) -> Void
    var openSettings: @MainActor (OnboardingSettingsTarget) -> Void
    var directoryExists: @Sendable (URL) -> Bool
    var createDirectory: @Sendable (URL) throws -> Void
    var copyToClipboard: @MainActor (String) -> Bool
    var notifyOnboardingStarted: @MainActor () -> Void
    var notifyOnboardingCompleted: @MainActor (_ owner: ServiceOwner) async -> Void
    var now: @Sendable () -> Date

    @MainActor
    static func live(
        hostStore: HostStore
    ) -> OnboardingDependencies {
        OnboardingDependencies(
            preflight: { options, onProgress in
                try await hostStore.agent.preflight(options, onProgress)
            },
            setupNoPair: { workspaceRoot, options in
                try await hostStore.agent.setupNoPair(workspaceRoot, options)
            },
            setRuntimePath: { runtimeID, value in
                try await hostStore.agent.setRuntimePath(runtimeID, value)
            },
            updateWorkspace: { scanRoot, browseRoot in
                try await hostStore.agent.updateWorkspace(scanRoot, browseRoot)
            },
            pair: { network in
                try await hostStore.agent.pair(network)
            },
            enableAssistant: { runtimeID in
                try await hostStore.enableAssistantForOnboarding(runtimeID)
            },
            enableTransport: { transport in
                try await hostStore.enableTransportForOnboarding(transport)
            },
            connectDeepSeek: { startupURL in
                try await hostStore.connectDeepSeekForOnboarding(startupURL: startupURL)
            },
            registerOrStartService: { onRegistered in
                try await hostStore.registerOrStartServiceForOnboarding(onRegistered: onRegistered)
            },
            restartService: {
                try await hostStore.restartServiceForOnboarding()
            },
            takeoverHomebrew: {
                try await hostStore.takeOverHomebrewForOnboarding()
            },
            runSafeDoctorFix: {
                _ = try await hostStore.agent.doctor(true)
            },
            agentRegistrationState: {
                hostStore.agentRegistrationState
            },
            mainAppRegistrationState: {
                hostStore.mainAppRegistrationState
            },
            photosAccessState: {
                hostStore.currentPhotosAccessState
            },
            requestPhotosAccess: {
                await hostStore.requestPhotosAccess()
                return hostStore.currentPhotosAccessState
            },
            localNetworkAccessDenied: {
                false
            },
            openURL: { url in
                NSWorkspace.shared.open(url)
            },
            openSettings: { target in
                switch target {
                case .loginItems:
                    hostStore.openLoginItemsSettings()
                case .filesAndFolders:
                    hostStore.openFilesAndFoldersSettings()
                case .localNetwork:
                    hostStore.openLocalNetworkSettings()
                case .photos:
                    hostStore.openPhotosPrivacySettings()
                case .fullDiskAccess:
                    hostStore.openFullDiskAccessSettings()
                case .dateTime:
                    hostStore.openDateTimeSettings()
                case .hostRecovery, .assistants, .connections, .windowsFirewall, .windowsNetworkProfile, .managedConnection:
                    break
                }
            },
            directoryExists: { url in
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
            },
            createDirectory: { url in
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            },
            copyToClipboard: { value in
                NSPasteboard.general.clearContents()
                return NSPasteboard.general.setString(value, forType: .string)
            },
            notifyOnboardingStarted: {
                hostStore.beginOnboarding()
            },
            notifyOnboardingCompleted: { owner in
                await hostStore.finishOnboarding(owner: owner)
            },
            now: { Date() }
        )
    }
}

@MainActor
@Observable
final class OnboardingStore {
    private(set) var currentStep: OnboardingWizardStep = .environmentCheck
    private(set) var report: OnboardingPreflightReport?
    private(set) var checks: [OnboardingCheck] = []
    private(set) var resolvedDiagnostics: [OnboardingCheckID: OnboardingResolvedDiagnostic] = [:]
    private(set) var isCheckingPreflight = false
    private(set) var preflightError: OnboardingResolvedDiagnostic?

    /// 向导在 `!configured` 阶段保存在内存中的助手启用与自定义路径草稿，绝不提前改写 `config.json`。
    private(set) var draftRuntimePaths: [String: String] = [:]
    private(set) var draftAssistants: [String: String] = [:]
    private(set) var skippedCheckIDs: Set<OnboardingCheckID> = []

    /// 步骤 2：目录选择与事务保存状态。
    private(set) var selectedScanRoot: URL?
    private(set) var persistedBrowseRoot: URL?
    private(set) var scanRootExists = false
    private(set) var hasUserEditedScanRoot = false
    private(set) var needsCreateDirectoryConfirmation = false
    private(set) var isSavingSetup = false
    private(set) var committedSetupReceipt: SetupReceipt?
    private(set) var hasCommittedCurrentDraft = false
    private(set) var stepError: OnboardingResolvedDiagnostic?
    private(set) var recoveryDiagnostic: OnboardingResolvedDiagnostic?

    /// 步骤 3：服务登记与权限。
    private(set) var servicePhase: OnboardingServicePhase = .idle
    private(set) var isStartingService = false
    private(set) var activeServiceOwner: ServiceOwner = .none
    var confirmsHomebrewTakeover = false

    /// 步骤 4：连接手机与二维码。
    private(set) var selectedTransport: OnboardingTransport = .tailscale
    private(set) var hasUserSelectedTransport = false
    private(set) var isEnablingTransport = false
    private(set) var isIssuingPairing = false
    private(set) var issuedPairing: PairingInfo?
    private(set) var pairingError: OnboardingResolvedDiagnostic?
    private(set) var didCopyPairingLink = false

    /// 跨步骤内联交互态。
    private(set) var isConfigured = false
    private(set) var workspaceConfirmed = false
    private(set) var isApplyingFix = false
    private(set) var isCompleted = false
    private(set) var pendingPathPicker: OnboardingPathPickerRequest?
    var isPathPickerPresented = false
    var presentsRecovery = false

    func presentPathPicker(_ request: OnboardingPathPickerRequest) {
        pendingPathPicker = request
        isPathPickerPresented = true
    }

    func completePathPicker(with url: URL?) async {
        let request = pendingPathPicker
        pendingPathPicker = nil
        isPathPickerPresented = false
        guard let request, let url else { return }
        switch request {
        case .workspaceRoot:
            await selectWorkspaceRoot(url)
        case .runtimeBinary(let runtimeID, _):
            await selectRuntimeBinaryPath(for: runtimeID, url: url)
        }
    }

    var presentsDeepSeekConnectForm = false

    let verifiedCapability: String?

    private let deps: OnboardingDependencies
    private var hasStarted = false
    private enum SaveReadback {
        case concurrentChange
        case uncertain(scanRoot: String, browseRoot: String)
    }
    private var pendingSaveReadback: SaveReadback?
    private var hasPersistedConfigFromWizard = false
    private var committedScanRootPath: String?
    private var preflightGeneration: UInt64 = 0
    private var activePreflightGeneration: UInt64?
    private var streamingChecksByID: [OnboardingCheckID: OnboardingCheck] = [:]
    private var preflightTask: Task<Void, Never>?
    private var pairingGeneration: UInt64 = 0
    private var pairingTask: Task<Void, Never>?
    private var copyFeedbackTask: Task<Void, Never>?

    init(
        dependencies: OnboardingDependencies,
        verifiedCapability: String? = nil
    ) {
        self.deps = dependencies
        self.verifiedCapability = verifiedCapability
    }

    // MARK: - Derived state

    /// 新装默认按最小权限将所选代码目录同时作为扫描和浏览根目录；
    /// 已有配置或升级重进时保留原有不同的浏览目录。
    var effectiveBrowseRoot: URL? {
        if !isConfigured {
            return selectedScanRoot
        }
        return persistedBrowseRoot ?? selectedScanRoot
    }

    var preflightStageForCurrentStep: OnboardingStage {
        switch currentStep {
        case .environmentCheck, .workspaceSelection:
            .setup
        case .serviceAndPermissions:
            isConfigured ? .pair : .setup
        case .connectPhone:
            .pair
        }
    }

    var sortedDraftRuntimePaths: [(id: String, value: String)] {
        draftRuntimePaths.keys.sorted().compactMap { key in
            guard let value = draftRuntimePaths[key] else { return nil }
            return (id: key, value: value)
        }
    }

    var sortedDraftAssistants: [(id: String, value: String)] {
        draftAssistants.keys.sorted().compactMap { key in
            guard let value = draftAssistants[key] else { return nil }
            return (id: key, value: value)
        }
    }

    var canProceedFromEnvironmentCheck: Bool {
        guard report?.stage == .setup, !isCheckingPreflight, preflightError == nil else { return false }
        if let configCheck = check(for: .configStore), configCheck.blocking {
            return false
        }
        return true
    }

    var canProceedFromWorkspaceSelection: Bool {
        guard !isCheckingPreflight, !isSavingSetup, preflightError == nil,
              pendingSaveReadback == nil, let report, report.stage == .setup,
              selectedScanRoot?.path == report.scanRoot else { return false }
        return report.checks.allSatisfy { check in
            !check.blocking || (check.id == .workspaceRoot && check.code == "workspace_not_found" && !report.scanRootExists)
        }
    }

    /// 后台 LaunchAgent 处于系统登录项审批中：步骤 4 仅展示「打开登录项设置…」与「重新检查」，
    /// 严禁生成二维码或复制链接。
    var isServiceRequiresApproval: Bool {
        if check(for: .serviceDaemon)?.code == "service_requires_approval" {
            return true
        }
        if case .requiresApproval = servicePhase, check(for: .serviceDaemon)?.state != .ok {
            return true
        }
        return deps.agentRegistrationState() == .requiresApproval
            && !(check(for: .serviceOwnerConflict)?.code == "homebrew_service_active" && check(for: .serviceDaemon)?.state == .ok)
    }

    /// 主应用开机启动项关闭属于非阻断警告，不阻断健康服务出码。
    var mainAppLoginItemWarning: String? {
        guard let loginCheck = check(for: .permissionLoginItem),
              loginCheck.code == "permission_login_item_disabled"
        else {
            return nil
        }
        return resolvedDiagnostics[.permissionLoginItem]?.message
            ?? OnboardingCopyCatalog.localizedMessage(code: "permission_login_item_disabled", step: .permissionLoginItem)
    }

    var canIssuePairingQR: Bool {
        guard !isCheckingPreflight, preflightError == nil,
              let report, report.stage == .pair, report.ok else { return false }
        return !isServiceRequiresApproval
    }

    var issuedPairingExpiryDate: Date? {
        guard let expiresAt = issuedPairing?.expiresAt, !expiresAt.isEmpty else { return nil }
        return OnboardingDateParser.parseRFC3339(expiresAt)
    }

    var isIssuedPairingExpired: Bool {
        guard let expiryDate = issuedPairingExpiryDate else { return false }
        return expiryDate <= deps.now()
    }

    var canCopyPairingLink: Bool {
        guard canIssuePairingQR,
              !isServiceRequiresApproval,
              let pairing = issuedPairing,
              isTransportReady(selectedTransport),
              pairing.hasTicket,
              !isIssuedPairingExpired
        else {
            return false
        }
        return true
    }

    var canCompleteWizard: Bool {
        !isCompleted && report?.stage == .pair && report?.workspaceConfirmed == true && !isCheckingPreflight
            && preflightError == nil && check(for: .serviceDaemon)?.state == .ok
            && !isSavingSetup && !isStartingService && !isApplyingFix && !isEnablingTransport && !isServiceRequiresApproval
    }

    var orderedTransports: [OnboardingTransport] {
        // D2 统一展示顺序：Tailscale > 内置连接（Tailcat）> 同一局域网。
        [.tailscale, .tailcat, .lan]
    }

    var assistantChecks: [OnboardingCheck] {
        checks.filter { $0.id.isIndividualAssistant }
    }

    var networkChecks: [OnboardingCheck] {
        checks.filter { $0.id.isIndividualNetwork }
    }

    var permissionChecks: [OnboardingCheck] {
        checks.filter { $0.id.isPermission }
    }

    var blockingPairChecks: [OnboardingCheck] {
        checks.filter { $0.blocking }
    }

    func check(for id: OnboardingCheckID) -> OnboardingCheck? {
        checks.first { $0.id == id }
    }

    func diagnostic(for check: OnboardingCheck) -> OnboardingResolvedDiagnostic? {
        resolvedDiagnostics[check.id]
    }

    func isTransportReady(_ transport: OnboardingTransport) -> Bool {
        guard let row = check(for: transport.checkID) else { return false }
        return row.state == .ok && row.enabled == true && row.available == true
    }

    func isTransportAvailableButDisabled(_ transport: OnboardingTransport) -> Bool {
        guard let row = check(for: transport.checkID) else { return false }
        return row.enabled == false && row.available == true
    }

    func canResetRuntimePin(for check: OnboardingCheck) -> Bool {
        guard let runtimeID = Self.runtimeID(for: check.id) else { return false }
        if check.source == .pin || check.code == "runtime_path_invalid" {
            return true
        }
        if let draftValue = draftRuntimePaths[runtimeID], draftValue != "auto" {
            return true
        }
        return false
    }

    // MARK: - Lifecycle & Navigation

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        deps.notifyOnboardingStarted()
        await runPreflight(stage: .setup)
    }

    func goToStep(_ step: OnboardingWizardStep) async {
        guard !isCompleted, !isApplyingFix, !isSavingSetup, !isStartingService, !isEnablingTransport, step != currentStep else { return }
        if currentStep == .connectPhone {
            invalidateIssuedPairing()
        }
        cancelPreflight()
        stepError = nil
        needsCreateDirectoryConfirmation = false
        currentStep = step

        let targetStage = preflightStageForCurrentStep
        if report?.stage != targetStage {
            report = nil
            checks = []
            resolvedDiagnostics = [:]
        }
        await runPreflight(stage: targetStage)
    }

    func goBack() async {
        guard let previous = OnboardingWizardStep(rawValue: currentStep.rawValue - 1) else { return }
        await goToStep(previous)
    }

    func proceedToWorkspaceStep() async {
        await goToStep(.workspaceSelection)
    }

    func proceedToConnectStep() async {
        await goToStep(.connectPhone)
    }

    /// 回到前台仅触发被动单飞预检，绝不调用会隐式启动服务的 `HostStore.refresh()`。
    func handleApplicationDidBecomeActive() {
        guard !isCompleted,
              !isSavingSetup,
              !isStartingService,
              !isEnablingTransport,
              !isApplyingFix
        else {
            return
        }
        startPreflight(stage: preflightStageForCurrentStep)
    }

    func finishWizard() async {
        guard canCompleteWizard else { return }
        cancelPreflight()
        invalidateIssuedPairing()
        let resolvedOwner: ServiceOwner
        if activeServiceOwner != .none {
            resolvedOwner = activeServiceOwner
        } else if check(for: .serviceOwnerConflict)?.code == "homebrew_service_active" {
            resolvedOwner = .homebrew
        } else {
            resolvedOwner = .macApp
        }
        isCompleted = true
        await deps.notifyOnboardingCompleted(resolvedOwner)
    }

    // MARK: - Single-flight Preflight

    func cancelPreflight() {
        preflightTask?.cancel()
        preflightTask = nil
        preflightGeneration &+= 1
        activePreflightGeneration = nil
        isCheckingPreflight = false
    }

    func startPreflight(stage: OnboardingStage? = nil) {
        guard !isCompleted else { return }
        let targetStage = stage ?? preflightStageForCurrentStep
        preflightTask?.cancel()
        preflightGeneration &+= 1
        let generation = preflightGeneration
        activePreflightGeneration = generation
        streamingChecksByID = [:]
        isCheckingPreflight = true
        preflightError = nil
        report = nil
        checks = []
        resolvedDiagnostics = [:]
        if isIssuingPairing { invalidateIssuedPairing() }
        preflightTask = Task { [weak self] in
            guard let self else { return }
            await self.executePreflight(stage: targetStage, generation: generation)
        }
    }

    func runPreflight(stage: OnboardingStage? = nil) async {
        startPreflight(stage: stage)
        if let task = preflightTask {
            await task.value
        }
    }

    private func buildPreflightOptions(for stage: OnboardingStage) -> OnboardingPreflightOptions {
        var options = OnboardingPreflightOptions(
            stage: stage,
            progressJSON: true,
            verifiedConfigured: isConfigured,
            verifiedCapability: verifiedCapability
        )
        if stage == .setup, pendingSaveReadback == nil {
            if let selectedScanRoot {
                options.scanRoot = selectedScanRoot
                options.browseRoot = effectiveBrowseRoot
            }
            if !isConfigured {
                options.runtimePaths = sortedDraftRuntimePaths
                options.assistants = sortedDraftAssistants
            }
        }
        return options
    }

    private func executePreflight(stage: OnboardingStage, generation: UInt64) async {
        let options = buildPreflightOptions(for: stage)
        do {
            let rawReport = try await deps.preflight(options) { [weak self] streamedCheck in
                Task { @MainActor [weak self] in
                    self?.applyStreamedCheck(streamedCheck, stage: stage, generation: generation)
                }
            }
            guard !Task.isCancelled,
                  preflightGeneration == generation,
                  activePreflightGeneration == generation
            else {
                return
            }
            activePreflightGeneration = nil
            let overlaid = applyNativeOverlay(to: rawReport)
            switch OnboardingCopyCatalog.validateReport(
                overlaid,
                platform: .macos,
                expectedStage: stage,
                nativeOverlay: true,
                verifiedCapability: verifiedCapability
            ) {
            case .success(let resolvedMap):
                report = overlaid
                checks = overlaid.checks
                resolvedDiagnostics = resolvedMap
                preflightError = nil
                isCheckingPreflight = false
                if case .uncertain = pendingSaveReadback, stage == .setup, !overlaid.configured {
                    pendingSaveReadback = nil
                    isConfigured = false
                    workspaceConfirmed = false
                    hasPersistedConfigFromWizard = false
                    hasCommittedCurrentDraft = false
                    committedSetupReceipt = nil
                    await runPreflight(stage: .setup)
                } else {
                    syncStateFromReport(overlaid)
                }
            case .failure:
                invalidateIssuedPairing()
                report = nil
                checks = []
                resolvedDiagnostics = [:]
                isCheckingPreflight = false
                preflightError = OnboardingResolvedDiagnostic(
                    code: nil,
                    step: .serviceDaemon,
                    message: OnboardingCopyCatalog.safeFallbackCopy,
                    primaryAction: nil,
                    secondaryAction: nil,
                    secondaryLabel: nil,
                    configPath: nil,
                    recoveryPath: nil,
                    isTrusted: false,
                    isLegacyHost: false
                )
            }
        } catch is CancellationError {
            if preflightGeneration == generation {
                activePreflightGeneration = nil
                isCheckingPreflight = false
            }
        } catch {
            guard !Task.isCancelled,
                  preflightGeneration == generation,
                  activePreflightGeneration == generation
            else {
                return
            }
            activePreflightGeneration = nil
            isCheckingPreflight = false
            invalidateIssuedPairing()
            preflightError = diagnosticFromError(error, defaultStep: .serviceDaemon)
        }
    }

    private func applyStreamedCheck(
        _ rawCheck: OnboardingCheck,
        stage: OnboardingStage,
        generation: UInt64
    ) {
        guard preflightGeneration == generation,
              activePreflightGeneration == generation
        else {
            return
        }
        let check = applyNativeOverlay(to: rawCheck, stage: stage)
        streamingChecksByID[check.id] = check
        let ordered = OnboardingCheckID.applicable(for: .macos).compactMap { streamingChecksByID[$0] }
        checks = ordered

        let surface: OnboardingSurface = (check.id.isPermission
            || (check.id == .serviceDaemon && check.code == "service_requires_approval"))
            ? .native
            : .check
        let context = OnboardingValidationContext(
            surface: surface,
            platform: .macos,
            stage: stage,
            configured: isConfigured,
            verifiedCapability: verifiedCapability
        )
        if case .success(let resolved) = OnboardingCopyCatalog.validateCheck(check, context: context) {
            resolvedDiagnostics[check.id] = resolved
        } else if check.state == .checking {
            resolvedDiagnostics[check.id] = OnboardingResolvedDiagnostic(
                code: nil,
                step: check.id,
                message: "正在检查\(check.id.localizedTitle)。",
                primaryAction: nil,
                secondaryAction: nil,
                secondaryLabel: nil,
                configPath: nil,
                recoveryPath: nil,
                isTrusted: true,
                isLegacyHost: false
            )
        }
    }

    private func syncStateFromReport(_ report: OnboardingPreflightReport) {
        isConfigured = report.configured
        workspaceConfirmed = report.workspaceConfirmed
        if report.stage == .setup, let readback = pendingSaveReadback {
            pendingSaveReadback = nil
            hasUserEditedScanRoot = false
            hasCommittedCurrentDraft = false
            if case .uncertain(let scanRoot, let browseRoot) = readback, report.configured {
                // An existing configuration must only be updated through workspace after an ambiguous write.
                hasPersistedConfigFromWizard = true
                committedScanRootPath = report.scanRoot
                hasCommittedCurrentDraft = report.workspaceConfirmed && report.ok
                    && scanRoot == report.scanRoot && browseRoot == report.browseRoot
            }
            if report.configured {
                draftRuntimePaths.removeAll()
                draftAssistants.removeAll()
            }
        }

        if !hasUserEditedScanRoot || selectedScanRoot == nil {
            selectedScanRoot = URL(filePath: report.scanRoot, directoryHint: .isDirectory)
        }
        if report.configured, report.browseRoot != report.scanRoot {
            persistedBrowseRoot = URL(filePath: report.browseRoot, directoryHint: .isDirectory)
        } else {
            persistedBrowseRoot = nil
        }
        if selectedScanRoot?.path == report.scanRoot {
            scanRootExists = report.scanRootExists
        } else if let selectedScanRoot {
            scanRootExists = deps.directoryExists(selectedScanRoot)
        }

        if let configCheck = check(for: .configStore),
           configCheck.fix == .openSettings(.hostRecovery),
           let diag = resolvedDiagnostics[.configStore] {
            recoveryDiagnostic = diag
        } else {
            recoveryDiagnostic = nil
        }

        // 根据被动预检更新步骤 3 的服务阶段，绝不主动起服。
        if let serviceCheck = check(for: .serviceDaemon) {
            if serviceCheck.code == "service_requires_approval" {
                servicePhase = .requiresApproval
                invalidateIssuedPairing()
            } else if serviceCheck.state == .ok {
                if check(for: .serviceOwnerConflict)?.code == "homebrew_service_active" {
                    activeServiceOwner = .homebrew
                    servicePhase = .homebrewActive
                } else {
                    if activeServiceOwner == .none {
                        activeServiceOwner = .macApp
                    }
                    servicePhase = .ready
                }
            } else if servicePhase == .ready || servicePhase == .homebrewActive || servicePhase == .requiresApproval {
                servicePhase = isConfigured ? .configSaved : .idle
            }
        }

        // 步骤 4：默认选中推荐通道但不触发任何写操作；仅在条件齐全且已选通道就绪时出码。
        if !hasUserSelectedTransport, let recommended = report.recommendedTransport, selectedTransport != recommended {
            invalidateIssuedPairing()
            selectedTransport = recommended
        }

        if currentStep == .connectPhone {
            if !canIssuePairingQR || !isTransportReady(selectedTransport) {
                invalidateIssuedPairing()
            } else if issuedPairing == nil, !isIssuingPairing {
                startIssuingPairingQR(for: selectedTransport)
            }
        }
    }

    // MARK: - macOS Native Overlay

    private func applyNativeOverlay(to report: OnboardingPreflightReport) -> OnboardingPreflightReport {
        let usesHomebrew = report.checks.contains { $0.id == .serviceOwnerConflict && $0.code == "homebrew_service_active" }
        let overlaidChecks = report.checks.map { check in
            if usesHomebrew, check.id == .permissionPhotos { return check }
            return applyNativeOverlay(to: check, stage: report.stage)
        }
        let firstBlocker = overlaidChecks.first(where: \.blocking)?.id
        let recomputedOK = firstBlocker == nil
        let recomputedNext: OnboardingCheckID = firstBlocker
            ?? (report.stage == .setup && !report.configured ? .configStore : .networkAny)
        return OnboardingPreflightReport(
            schema: report.schema,
            ok: recomputedOK,
            stage: report.stage,
            configured: report.configured,
            workspaceConfirmed: report.workspaceConfirmed,
            configPath: report.configPath,
            scanRoot: report.scanRoot,
            browseRoot: report.browseRoot,
            scanRootExists: report.scanRootExists,
            recommendedNext: recomputedNext,
            recommendedTransport: report.recommendedTransport,
            checks: overlaidChecks
        )
    }

    private func applyNativeOverlay(to check: OnboardingCheck, stage: OnboardingStage) -> OnboardingCheck {
        switch check.id {
        case .serviceDaemon:
            if deps.agentRegistrationState() == .requiresApproval,
               check.code == "service_not_running" {
                return OnboardingCheck(
                    id: .serviceDaemon,
                    state: .actionNeeded,
                    detail: OnboardingCopyCatalog.localizedMessage(
                        code: "service_requires_approval",
                        step: .serviceDaemon
                    ),
                    blocking: stage == .pair,
                    code: "service_requires_approval",
                    fix: .openSettings(.loginItems)
                )
            }
            return check

        case .permissionLoginItem:
            switch deps.mainAppRegistrationState() {
            case .enabled:
                return OnboardingCheck(
                    id: .permissionLoginItem,
                    state: .ok,
                    detail: "已允许登录时启动。",
                    blocking: false
                )
            case .notRegistered, .requiresApproval:
                return OnboardingCheck(
                    id: .permissionLoginItem,
                    state: .optional,
                    detail: OnboardingCopyCatalog.localizedMessage(
                        code: "permission_login_item_disabled",
                        step: .permissionLoginItem
                    ),
                    blocking: false,
                    code: "permission_login_item_disabled",
                    fix: .openSettings(.loginItems)
                )
            case .notFound:
                return check
            }

        case .permissionPhotos:
            switch deps.photosAccessState() {
            case .authorized, .limited:
                return OnboardingCheck(
                    id: .permissionPhotos,
                    state: .ok,
                    detail: "已允许访问照片。",
                    blocking: false
                )
            case .denied, .restricted:
                return OnboardingCheck(
                    id: .permissionPhotos,
                    state: .optional,
                    detail: OnboardingCopyCatalog.localizedMessage(
                        code: "permission_photos_denied",
                        step: .permissionPhotos
                    ),
                    blocking: false,
                    code: "permission_photos_denied",
                    fix: .openSettings(.photos)
                )
            case .notDetermined:
                // 未知状态必须保持 optional（permission_unobserved），绝不主动弹窗或反推。
                return check
            }

        case .permissionLocalNetwork:
            if deps.localNetworkAccessDenied() {
                return OnboardingCheck(
                    id: .permissionLocalNetwork,
                    state: .actionNeeded,
                    detail: OnboardingCopyCatalog.localizedMessage(
                        code: "permission_local_network_denied",
                        step: .permissionLocalNetwork
                    ),
                    blocking: false,
                    code: "permission_local_network_denied",
                    fix: .openSettings(.localNetwork)
                )
            }
            return check

        default:
            return check
        }
    }

    // MARK: - Step 1 & Runtime Pin / Assistant Actions

    func selectRuntimeBinaryPath(for runtimeID: String, url: URL) async {
        let path = url.path
        guard path.hasPrefix("/") else {
            stepError = OnboardingResolvedDiagnostic(
                code: "invalid_request",
                step: Self.checkID(forRuntimeID: runtimeID),
                message: "请选择程序的绝对路径。",
                primaryAction: .retry,
                secondaryAction: nil,
                secondaryLabel: nil,
                configPath: nil,
                recoveryPath: nil,
                isTrusted: true,
                isLegacyHost: false
            )
            return
        }
        await applyRuntimePath(path, for: runtimeID)
    }

    func resetRuntimePathToAuto(for runtimeID: String) async {
        await applyRuntimePath("auto", for: runtimeID)
    }

    private func applyRuntimePath(_ path: String, for runtimeID: String) async {
        if isConfigured, isCheckingPreflight { await preflightTask?.value }
        guard !isCompleted, !isApplyingFix, !isConfigured || report?.configured == true else { return }
        stepError = nil
        if !isConfigured {
            draftRuntimePaths[runtimeID] = path
            await runPreflight(stage: preflightStageForCurrentStep)
            return
        }
        isApplyingFix = true
        defer { isApplyingFix = false }
        do {
            try await deps.setRuntimePath(runtimeID, path)
            await runPreflight(stage: preflightStageForCurrentStep)
        } catch is CancellationError {
            return
        } catch {
            stepError = diagnosticFromError(error, defaultStep: Self.checkID(forRuntimeID: runtimeID))
        }
    }

    func performCheckPrimaryAction(for check: OnboardingCheck) async {
        guard report != nil, self.check(for: check.id) == check, let resolved = resolvedDiagnostics[check.id],
              resolved.isTrusted,
              let fix = resolved.primaryAction
        else {
            return
        }
        await dispatchTrustedFix(fix, checkID: check.id, code: resolved.code, diagnostic: resolved)
    }

    func performCheckSecondaryAction(for check: OnboardingCheck) async {
        guard report != nil, self.check(for: check.id) == check, let resolved = resolvedDiagnostics[check.id],
              resolved.isTrusted,
              let secondary = resolved.secondaryAction
        else {
            return
        }
        await dispatchTrustedFix(secondary, checkID: check.id, code: resolved.code, diagnostic: resolved)
    }

    func performDiagnosticAction(_ diagnostic: OnboardingResolvedDiagnostic) async {
        guard diagnostic.isTrusted, let fix = diagnostic.primaryAction else { return }
        await dispatchTrustedFix(
            fix,
            checkID: diagnostic.step ?? .serviceDaemon,
            code: diagnostic.code,
            diagnostic: diagnostic
        )
    }

    private func dispatchTrustedFix(
        _ fix: OnboardingFix,
        checkID: OnboardingCheckID,
        code: String?,
        diagnostic: OnboardingResolvedDiagnostic
    ) async {
        switch fix {
        case .openURL(let allowedURL):
            deps.openURL(allowedURL.url)

        case .openSettings(let target):
            switch target {
            case .connections:
                await goToStep(.connectPhone)
            case .assistants:
                await goToStep(.environmentCheck)
            case .hostRecovery:
                recoveryDiagnostic = diagnostic
                presentsRecovery = true
            case .loginItems, .filesAndFolders, .localNetwork, .photos, .fullDiskAccess, .dateTime:
                deps.openSettings(target)
            case .windowsFirewall, .windowsNetworkProfile, .managedConnection:
                break
            }

        case .choosePath(let target):
            switch target {
            case .workspaceRoot:
                if currentStep != .workspaceSelection {
                    await goToStep(.workspaceSelection)
                }
                presentPathPicker(.workspaceRoot)
            case .codexBin:
                presentPathPicker(.runtimeBinary(runtimeID: "codex", target: .codexBin))
            case .claudeBin:
                presentPathPicker(.runtimeBinary(runtimeID: "claude", target: .claudeBin))
            case .agyBin:
                presentPathPicker(.runtimeBinary(runtimeID: "agy", target: .agyBin))
            }

        case .runFix(let action):
            await dispatchRunFixAction(action, checkID: checkID, code: code)

        case .retry:
            stepError = nil
            await runPreflight(stage: preflightStageForCurrentStep)

        case .skip:
            skippedCheckIDs.insert(checkID)
        }
    }

    private func dispatchRunFixAction(
        _ action: OnboardingRunFixAction,
        checkID: OnboardingCheckID,
        code: String?
    ) async {
        guard !isApplyingFix, !isCompleted, let report else { return }
        if action.requiresConfig && !report.configured {
            return
        }
        if action.isTransportEnable && currentStep != .connectPhone {
            return
        }
        if action == .doctorFix {
            guard verifiedCapability == OnboardingSchema.doctorFixCapability,
                  code == "config_permissions_unsafe"
            else {
                return
            }
        }

        switch action {
        case .saveSetup:
            await goToStep(.workspaceSelection)

        case .enableCodex, .enableClaude, .enableAgy:
            let runtimeID = switch action {
            case .enableCodex: "codex"
            case .enableClaude: "claude"
            case .enableAgy: "agy"
            default: ""
            }
            if !isConfigured {
                draftAssistants[runtimeID] = "enabled"
                await runPreflight(stage: preflightStageForCurrentStep)
                return
            }
            isApplyingFix = true
            defer { isApplyingFix = false }
            do {
                try await deps.enableAssistant(runtimeID)
                await runPreflight(stage: preflightStageForCurrentStep)
            } catch is CancellationError {
                return
            } catch {
                stepError = diagnosticFromError(error, defaultStep: checkID)
            }

        case .enableTailscale:
            await enableSelectedTransportAndIssueQR(.tailscale)

        case .enableTailcat:
            await enableSelectedTransportAndIssueQR(.tailcat)

        case .enableLAN:
            await enableSelectedTransportAndIssueQR(.lan)

        case .connectDeepSeek:
            presentsDeepSeekConnectForm = true

        case .registerService:
            if currentStep != .serviceAndPermissions {
                await goToStep(.serviceAndPermissions)
            }
            await ensureServiceReady()

        case .restartService:
            isApplyingFix = true
            defer { isApplyingFix = false }
            do {
                try await deps.restartService()
                await runPreflight(stage: preflightStageForCurrentStep)
            } catch is CancellationError {
                return
            } catch {
                stepError = diagnosticFromError(error, defaultStep: .serviceDaemon)
            }

        case .doctorFix:
            isApplyingFix = true
            defer { isApplyingFix = false }
            do {
                try await deps.runSafeDoctorFix()
                await runPreflight(stage: preflightStageForCurrentStep)
            } catch is CancellationError {
                return
            } catch {
                stepError = diagnosticFromError(error, defaultStep: .configStore)
            }

        case .takeoverHomebrew:
            confirmsHomebrewTakeover = true
        }
    }

    func submitDeepSeekConnection(startupURL: String?) async {
        guard !isApplyingFix, report?.configured == true else { return }
        isApplyingFix = true
        stepError = nil
        defer { isApplyingFix = false }
        do {
            let trimmed = startupURL?.trimmingCharacters(in: .whitespacesAndNewlines)
            try await deps.connectDeepSeek(trimmed?.isEmpty == true ? nil : trimmed)
            presentsDeepSeekConnectForm = false
            await runPreflight(stage: preflightStageForCurrentStep)
        } catch is CancellationError {
            return
        } catch {
            stepError = diagnosticFromError(error, defaultStep: .assistantDeepSeek)
        }
    }

    // MARK: - Step 2: Workspace Selection & Save

    func selectWorkspaceRoot(_ url: URL) async {
        selectedScanRoot = url
        hasUserEditedScanRoot = true
        needsCreateDirectoryConfirmation = false
        stepError = nil
        if !isConfigured {
            persistedBrowseRoot = nil
        }
        scanRootExists = deps.directoryExists(url)
        await runPreflight(stage: .setup)
    }

    func cancelCreateDirectoryConfirmation() {
        needsCreateDirectoryConfirmation = false
    }

    func saveWorkspaceAndContinue(confirmCreateMissingDirectory: Bool = false) async {
        guard !isSavingSetup else { return }
        if pendingSaveReadback != nil {
            await runPreflight(stage: .setup)
            return
        }
        guard canProceedFromWorkspaceSelection, let scanRoot = selectedScanRoot else { return }
        let browseRoot = effectiveBrowseRoot ?? scanRoot

        let existsNow: Bool
        if report?.scanRoot == scanRoot.path {
            existsNow = report?.scanRootExists ?? deps.directoryExists(scanRoot)
        } else {
            existsNow = deps.directoryExists(scanRoot)
        }
        scanRootExists = existsNow

        if !existsNow {
            guard confirmCreateMissingDirectory else {
                needsCreateDirectoryConfirmation = true
                return
            }
            needsCreateDirectoryConfirmation = false
            do {
                try deps.createDirectory(scanRoot)
                scanRootExists = true
            } catch {
                stepError = OnboardingResolvedDiagnostic(
                    code: "workspace_unreadable",
                    step: .workspaceRoot,
                    message: "无法创建所选代码目录。请检查位置权限或重新选择目录。",
                    primaryAction: .choosePath(.workspaceRoot),
                    secondaryAction: nil,
                    secondaryLabel: nil,
                    configPath: nil,
                    recoveryPath: nil,
                    isTrusted: true,
                    isLegacyHost: false
                )
                return
            }
        }

        needsCreateDirectoryConfirmation = false
        isSavingSetup = true
        stepError = nil
        cancelPreflight()
        defer { isSavingSetup = false }

        // 提交成功后绝不重放 setup 保存：同一目录直接前往下一步或重试启动。
        if hasCommittedCurrentDraft, committedScanRootPath == scanRoot.path {
            stepError = nil
            currentStep = .serviceAndPermissions
            await ensureServiceReady()
            return
        }

        // 已提交过一次配置且用户显式更换了目录：走 workspace 更新，绝不重放 setup --no-pair。
        if committedSetupReceipt != nil || hasPersistedConfigFromWizard {
            do {
                try await deps.updateWorkspace(scanRoot, browseRoot)
                committedScanRootPath = scanRoot.path
                hasCommittedCurrentDraft = true
                workspaceConfirmed = true
                currentStep = .serviceAndPermissions
                await ensureServiceReady()
            } catch is CancellationError {
                await rereadAfterUncertainSave(scanRoot: scanRoot, browseRoot: browseRoot)
            } catch {
                await handleSetupCommitFailure(error, scanRoot: scanRoot, browseRoot: browseRoot)
            }
            return
        }

        let setupOptions = OnboardingSetupOptions(
            browseRoot: browseRoot,
            runtimePaths: sortedDraftRuntimePaths,
            assistants: sortedDraftAssistants,
            verifiedConfigured: isConfigured
        )

        do {
            let receipt = try await deps.setupNoPair(scanRoot, setupOptions)
            committedSetupReceipt = receipt
            hasPersistedConfigFromWizard = true
            committedScanRootPath = receipt.scanRoot
            hasCommittedCurrentDraft = true
            isConfigured = receipt.configured
            workspaceConfirmed = true
            selectedScanRoot = URL(filePath: receipt.scanRoot, directoryHint: .isDirectory)
            if receipt.browseRoot != receipt.scanRoot {
                persistedBrowseRoot = URL(filePath: receipt.browseRoot, directoryHint: .isDirectory)
            } else {
                persistedBrowseRoot = nil
            }
            draftRuntimePaths.removeAll()
            draftAssistants.removeAll()
            servicePhase = .configSaved
            currentStep = .serviceAndPermissions
            await ensureServiceReady()
        } catch is CancellationError {
            await rereadAfterUncertainSave(scanRoot: scanRoot, browseRoot: browseRoot)
        } catch {
            await handleSetupCommitFailure(error, scanRoot: scanRoot, browseRoot: browseRoot)
        }
    }

    private func handleSetupCommitFailure(_ error: Error, scanRoot: URL, browseRoot: URL) async {
        let diag = diagnosticFromError(error, defaultStep: .configStore)
        stepError = diag
        if diag.code == "config_concurrent_change" {
            // 配置并发变更：重读最新配置并展示给用户重新确认，绝不静默重放保存。
            pendingSaveReadback = .concurrentChange
            await runPreflight(stage: .setup)
            return
        }
        if diag.code == "command_timeout" || !diag.isTrusted {
            await rereadAfterUncertainSave(scanRoot: scanRoot, browseRoot: browseRoot)
        }
        if diag.primaryAction == .openSettings(.hostRecovery) {
            recoveryDiagnostic = diag
        }
    }

    private func rereadAfterUncertainSave(scanRoot: URL, browseRoot: URL) async {
        pendingSaveReadback = .uncertain(scanRoot: scanRoot.path, browseRoot: browseRoot.path)
        // runPreflight starts an independent task so cancellation of the save cannot cancel its readback.
        await runPreflight(stage: .setup)
    }

    // MARK: - Step 3: Service & Permissions

    func ensureServiceReady() async {
        guard !isStartingService else { return }
        guard isConfigured else {
            stepError = OnboardingCopyCatalog.validateDiagnostic(
                code: "config_missing",
                step: .configStore,
                fix: .runFix(.saveSetup),
                context: OnboardingValidationContext(surface: .cli, platform: .macos, stage: .setup, configured: false)
            ).value
            return
        }

        isStartingService = true
        stepError = nil
        servicePhase = .registeringService

        do {
            let outcome = try await deps.registerOrStartService {
                self.servicePhase = .waitingForReadiness
            }
            switch outcome {
            case .ready:
                activeServiceOwner = .macApp
                servicePhase = .ready
            case .requiresApproval:
                activeServiceOwner = .none
                servicePhase = .requiresApproval
            case .homebrewHealthy:
                activeServiceOwner = .homebrew
                servicePhase = .homebrewActive
            }
        } catch is CancellationError {
            isStartingService = false
            return
        } catch {
            if deps.agentRegistrationState() == .requiresApproval {
                activeServiceOwner = .none
                servicePhase = .requiresApproval
            } else {
                servicePhase = .failed(diagnosticFromError(error, defaultStep: .serviceDaemon))
            }
        }

        isStartingService = false
        await runPreflight(stage: .pair)
    }

    func confirmTakeoverHomebrew() async {
        guard isConfigured, !isStartingService else { return }
        confirmsHomebrewTakeover = false
        isStartingService = true
        stepError = nil
        servicePhase = .registeringService
        do {
            try await deps.takeoverHomebrew()
            activeServiceOwner = .macApp
            servicePhase = .ready
        } catch is CancellationError {
            isStartingService = false
            return
        } catch {
            servicePhase = .failed(diagnosticFromError(error, defaultStep: .serviceDaemon))
        }
        isStartingService = false
        await runPreflight(stage: .pair)
    }

    func requestPhotosAccess() async {
        _ = await deps.requestPhotosAccess()
        await runPreflight(stage: preflightStageForCurrentStep)
    }

    // MARK: - Step 4: Connect Phone & Pairing QR

    /// 选中通道仅更新本地选择并清除旧票，绝不自动写入或启用任何网络通道。
    func selectTransport(_ transport: OnboardingTransport) {
        hasUserSelectedTransport = true
        guard selectedTransport != transport else { return }
        selectedTransport = transport
        invalidateIssuedPairing()
        if currentStep == .connectPhone, canIssuePairingQR, isTransportReady(transport) {
            startIssuingPairingQR(for: transport)
        }
    }

    func enableSelectedTransportAndIssueQR(_ transport: OnboardingTransport) async {
        guard currentStep == .connectPhone, !isEnablingTransport, !isServiceRequiresApproval,
              report?.stage == .pair, report?.configured == true,
              isTransportAvailableButDisabled(transport) else { return }
        selectedTransport = transport
        hasUserSelectedTransport = true
        isEnablingTransport = true
        pairingError = nil
        invalidateIssuedPairing()
        defer { isEnablingTransport = false }

        do {
            try await deps.enableTransport(transport)
        } catch is CancellationError {
            return
        } catch {
            pairingError = diagnosticFromError(error, defaultStep: transport.checkID)
            return
        }

        await runPreflight(stage: .pair)
        await pairingTask?.value
    }

    func startIssuingPairingQR(for transport: OnboardingTransport? = nil) {
        pairingTask?.cancel()
        pairingGeneration &+= 1
        let generation = pairingGeneration
        let target = transport ?? selectedTransport
        pairingTask = Task { [weak self] in
            guard let self else { return }
            await self.executeIssuePairingQR(for: target, generation: generation)
        }
    }

    func issuePairingQR(for transport: OnboardingTransport? = nil) async {
        startIssuingPairingQR(for: transport)
        if let task = pairingTask {
            await task.value
        }
    }

    private func executeIssuePairingQR(for transport: OnboardingTransport, generation: UInt64) async {
        guard !isCompleted, !Task.isCancelled, generation == pairingGeneration, currentStep == .connectPhone,
              selectedTransport == transport,
              canIssuePairingQR,
              isTransportReady(transport)
        else {
            if pairingGeneration == generation {
                issuedPairing = nil
                isIssuingPairing = false
            }
            return
        }

        isIssuingPairing = true
        pairingError = nil
        issuedPairing = nil

        do {
            let pairing = try await deps.pair(transport.pairingNetwork)
            guard !Task.isCancelled,
                  pairingGeneration == generation,
                  currentStep == .connectPhone,
                  selectedTransport == transport,
                  isTransportReady(transport),
                  canIssuePairingQR
            else {
                return
            }
            isIssuingPairing = false
            guard pairing.hasTicket, pairing.network == transport.pairingNetwork else {
                issuedPairing = nil
                pairingError = OnboardingResolvedDiagnostic(
                    code: nil,
                    step: .networkAny,
                    message: "当前未返回有效的配对链接，请重新检查后刷新二维码。",
                    primaryAction: .retry,
                    secondaryAction: nil,
                    secondaryLabel: nil,
                    configPath: nil,
                    recoveryPath: nil,
                    isTrusted: true,
                    isLegacyHost: false
                )
                return
            }
            issuedPairing = pairing
        } catch is CancellationError {
            if pairingGeneration == generation {
                isIssuingPairing = false
            }
        } catch {
            guard !Task.isCancelled, pairingGeneration == generation else { return }
            isIssuingPairing = false
            issuedPairing = nil
            pairingError = diagnosticFromError(error, defaultStep: .networkAny)
        }
    }

    @discardableResult
    func copyPairingLink() -> Bool {
        clearIssuedPairingIfExpired()
        guard canCopyPairingLink, let pairURL = issuedPairing?.pairURL else {
            return false
        }
        let copied = deps.copyToClipboard(pairURL)
        guard copied else { return false }
        didCopyPairingLink = true
        copyFeedbackTask?.cancel()
        copyFeedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard let self, !Task.isCancelled else { return }
            self.didCopyPairingLink = false
        }
        return true
    }

    func clearIssuedPairingIfExpired() {
        if issuedPairing != nil, isIssuedPairingExpired {
            issuedPairing = nil
            didCopyPairingLink = false
        }
    }

    func invalidateIssuedPairing() {
        pairingTask?.cancel()
        pairingTask = nil
        pairingGeneration &+= 1
        isIssuingPairing = false
        issuedPairing = nil
        pairingError = nil
        didCopyPairingLink = false
    }

    // MARK: - Helpers

    private func diagnosticFromError(_ error: Error, defaultStep: OnboardingCheckID) -> OnboardingResolvedDiagnostic {
        if let clientError = error as? AgentClientError, let diag = clientError.onboardingDiagnostic {
            return diag
        }
        if let lifecycleError = error as? ServiceLifecycleError {
            switch lifecycleError {
            case .requiresApproval:
                return OnboardingResolvedDiagnostic(
                    code: "service_requires_approval",
                    step: .serviceDaemon,
                    message: OnboardingCopyCatalog.localizedMessage(
                        code: "service_requires_approval",
                        step: .serviceDaemon
                    ),
                    primaryAction: .openSettings(.loginItems),
                    secondaryAction: .retry,
                    secondaryLabel: "重新检查",
                    configPath: nil,
                    recoveryPath: nil,
                    isTrusted: true,
                    isLegacyHost: false
                )
            case .configRequiresNewerVersion:
                return OnboardingResolvedDiagnostic(
                    code: "config_requires_newer_version",
                    step: .configStore,
                    message: OnboardingCopyCatalog.localizedMessage(
                        code: "config_requires_newer_version",
                        step: .configStore
                    ),
                    primaryAction: .openURL(.desktop),
                    secondaryAction: nil,
                    secondaryLabel: nil,
                    configPath: nil,
                    recoveryPath: nil,
                    isTrusted: true,
                    isLegacyHost: false
                )
            case .invalidConfiguration:
                return OnboardingResolvedDiagnostic(
                    code: "service_install_incomplete",
                    step: .serviceDaemon,
                    message: lifecycleError.localizedDescription,
                    primaryAction: .openURL(.desktop),
                    secondaryAction: nil,
                    secondaryLabel: nil,
                    configPath: nil,
                    recoveryPath: nil,
                    isTrusted: true,
                    isLegacyHost: false
                )
            default:
                return OnboardingResolvedDiagnostic(
                    code: "service_start_failed",
                    step: .serviceDaemon,
                    message: OnboardingCopyCatalog.localizedMessage(
                        code: "service_start_failed",
                        step: .serviceDaemon
                    ),
                    primaryAction: .retry,
                    secondaryAction: nil,
                    secondaryLabel: nil,
                    configPath: nil,
                    recoveryPath: nil,
                    isTrusted: true,
                    isLegacyHost: false
                )
            }
        }
        return OnboardingResolvedDiagnostic(
            code: nil,
            step: defaultStep,
            message: OnboardingCopyCatalog.safeFallbackCopy,
            primaryAction: nil,
            secondaryAction: nil,
            secondaryLabel: nil,
            configPath: nil,
            recoveryPath: nil,
            isTrusted: false,
            isLegacyHost: false
        )
    }

    static func runtimeID(for checkID: OnboardingCheckID) -> String? {
        switch checkID {
        case .assistantCodex: "codex"
        case .assistantClaude: "claude"
        case .assistantAgy: "agy"
        default: nil
        }
    }

    static func checkID(forRuntimeID runtimeID: String) -> OnboardingCheckID {
        switch runtimeID.lowercased() {
        case "codex": .assistantCodex
        case "claude": .assistantClaude
        case "agy": .assistantAgy
        case "deepseek": .assistantDeepSeek
        default: .assistantAny
        }
    }
}

private extension Result {
    var value: Success? {
        if case .success(let success) = self { return success }
        return nil
    }
}
