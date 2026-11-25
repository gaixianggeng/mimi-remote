import AppKit
import Foundation
import Observation

struct PairingWindowDependencies {
    var preflight: @Sendable (
        _ options: OnboardingPreflightOptions,
        _ onProgress: (@Sendable (OnboardingCheck) -> Void)?
    ) async throws -> OnboardingPreflightReport
    var enableTransport: @MainActor (_ transport: OnboardingTransport) async throws -> Void
    var enableAssistant: @MainActor (_ runtimeID: String) async throws -> Void
    var pair: @Sendable (_ network: PairingNetwork) async throws -> PairingInfo
    var restartService: @MainActor () async throws -> Void
    var registerOrStartService: @MainActor () async throws -> HostStore.OnboardingServiceStartOutcome
    var agentRegistrationState: @MainActor () -> ServiceRegistrationState
    var mainAppRegistrationState: @MainActor () -> ServiceRegistrationState
    var photosAccessState: @MainActor () -> PhotosAccessState
    var localNetworkAccessDenied: @MainActor () -> Bool
    var openURL: @MainActor (URL) -> Void
    var openSettings: @MainActor (OnboardingSettingsTarget) -> Void
    var copyToClipboard: @MainActor (String) -> Bool
    var now: @Sendable () -> Date

    @MainActor
    static func live(
        hostStore: HostStore,
        openSettingsTarget: @escaping @MainActor (OnboardingSettingsTarget) -> Void
    ) -> PairingWindowDependencies {
        let agent = hostStore.agent
        return PairingWindowDependencies(
            preflight: { options, onProgress in
                try await agent.preflight(options, onProgress)
            },
            enableTransport: { transport in
                try await hostStore.enableTransportForOnboarding(transport)
            },
            enableAssistant: { runtimeID in
                try await hostStore.enableAssistantForOnboarding(runtimeID)
            },
            pair: { network in
                try await agent.pair(network)
            },
            restartService: {
                try await hostStore.restartServiceForOnboarding()
            },
            registerOrStartService: {
                try await hostStore.registerOrStartServiceForOnboarding()
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
            localNetworkAccessDenied: {
                false
            },
            openURL: { url in
                NSWorkspace.shared.open(url)
            },
            openSettings: openSettingsTarget,
            copyToClipboard: { value in
                NSPasteboard.general.clearContents()
                return NSPasteboard.general.setString(value, forType: .string)
            },
            now: { Date() }
        )
    }
}

/// 独立配对窗口状态机：
/// - 固定按 D2 推荐顺序展示 `[Tailscale, 内置连接（Tailcat）, 同一局域网]`；
/// - 自动选中与布局刷新严格零写操作，绝不隐式开启任何通道；
/// - 仅在 `assistant_any == ok && network_any == ok && service_daemon == ok` 且所选通道已启用并可用时才签发 QR；
/// - 显式点击开启（含 Tailscale）走 `enable_<transport>` + 单次服务重载 + 预检复核后再出码；
/// - 按真实 `pair_expires_at` 倒计时，到期/切通道/失败/离页立即清码并丢弃迟到响应。
@MainActor
@Observable
final class PairingWindowStore {
    static let orderedTransports: [OnboardingTransport] = [.tailscale, .tailcat, .lan]

    private(set) var report: OnboardingPreflightReport?
    private(set) var checks: [OnboardingCheck] = []
    private(set) var resolvedDiagnostics: [OnboardingCheckID: OnboardingResolvedDiagnostic] = [:]
    private(set) var isCheckingPreflight = false
    private(set) var preflightError: OnboardingResolvedDiagnostic?

    private(set) var selectedTransport: OnboardingTransport = .tailscale
    private(set) var hasUserSelectedTransport = false
    private(set) var isEnablingTransport = false
    private(set) var isApplyingFix = false
    private(set) var isIssuingPairing = false
    private(set) var issuedPairing: PairingInfo?
    private(set) var pairingError: OnboardingResolvedDiagnostic?
    private(set) var didCopyPairingLink = false
    private(set) var didExpireCurrentPairing = false
    private(set) var isVisible = false

    let verifiedCapability: String?

    private let deps: PairingWindowDependencies
    private var preflightGeneration: UInt64 = 0
    private var activePreflightGeneration: UInt64?
    private var preflightTask: Task<Void, Never>?
    private var pairingGeneration: UInt64 = 0
    private var pairingTask: Task<Void, Never>?
    private var copyFeedbackTask: Task<Void, Never>?

    init(
        dependencies: PairingWindowDependencies,
        verifiedCapability: String? = nil
    ) {
        self.deps = dependencies
        self.verifiedCapability = verifiedCapability
    }

    // MARK: - Derived state

    var orderedTransports: [OnboardingTransport] {
        Self.orderedTransports
    }

    var recommendedTransport: OnboardingTransport? {
        report?.recommendedTransport
    }

    func check(for id: OnboardingCheckID) -> OnboardingCheck? {
        checks.first { $0.id == id }
    }

    func diagnostic(for check: OnboardingCheck) -> OnboardingResolvedDiagnostic? {
        resolvedDiagnostics[check.id]
    }

    /// 后台 LaunchAgent 审批中：仅展示审批与复检引导，严禁出码与复制。
    var isServiceRequiresApproval: Bool {
        if check(for: .serviceDaemon)?.code == "service_requires_approval" {
            return true
        }
        return deps.agentRegistrationState() == .requiresApproval
            && !(check(for: .serviceOwnerConflict)?.code == "homebrew_service_active"
                && check(for: .serviceDaemon)?.state == .ok)
    }

    /// 主应用登录项关闭为非阻断提醒，不阻断健康服务出码。
    var mainAppLoginItemWarning: String? {
        guard let loginCheck = check(for: .permissionLoginItem),
              loginCheck.code == "permission_login_item_disabled"
        else {
            return nil
        }
        return resolvedDiagnostics[.permissionLoginItem]?.message
            ?? OnboardingCopyCatalog.localizedMessage(
                code: "permission_login_item_disabled",
                step: .permissionLoginItem
            )
    }

    /// 严格实时出码门槛：必须通过 `--stage pair` 预检，且 `assistant_any`、`network_any`、
    /// `service_daemon` 均为 `ok` 且配置/目录已确认、无后台审批阻断。
    var canIssuePairingQR: Bool {
        guard !isCheckingPreflight,
              !isEnablingTransport,
              preflightError == nil,
              let report,
              report.stage == .pair,
              report.ok,
              report.configured,
              report.workspaceConfirmed,
              !isServiceRequiresApproval,
              check(for: .serviceDaemon)?.state == .ok,
              check(for: .assistantAny)?.state == .ok,
              check(for: .networkAny)?.state == .ok
        else {
            return false
        }
        return true
    }

    /// 除所选通道本身未启用外，其余配对前置（配置、目录、服务、至少一个可用助手）是否均已就绪。
    var corePrerequisitesReady: Bool {
        guard !isCheckingPreflight,
              preflightError == nil,
              let report,
              report.stage == .pair,
              report.configured,
              report.workspaceConfirmed,
              !isServiceRequiresApproval,
              check(for: .configStore)?.state == .ok,
              check(for: .workspaceRoot)?.state == .ok,
              check(for: .serviceDaemon)?.state == .ok,
              check(for: .assistantAny)?.state == .ok
        else {
            return false
        }
        return true
    }

    func isTransportReady(_ transport: OnboardingTransport) -> Bool {
        guard let row = check(for: transport.checkID) else { return false }
        return row.state == .ok && row.enabled == true && row.available == true
    }

    func isTransportAvailableButDisabled(_ transport: OnboardingTransport) -> Bool {
        guard let row = check(for: transport.checkID) else { return false }
        return row.enabled == false && row.available == true
    }

    func canExplicitlyEnable(_ transport: OnboardingTransport) -> Bool {
        guard !isEnablingTransport,
              !isApplyingFix,
              !isServiceRequiresApproval,
              let report,
              report.stage == .pair,
              report.configured,
              isTransportAvailableButDisabled(transport)
        else {
            return false
        }
        return true
    }

    var issuedPairingExpiryDate: Date? {
        guard let expiresAt = issuedPairing?.expiresAt, !expiresAt.isEmpty else { return nil }
        return OnboardingDateParser.parseRFC3339(expiresAt)
    }

    var isIssuedPairingExpired: Bool {
        guard let expiryDate = issuedPairingExpiryDate else {
            return issuedPairing != nil
        }
        return expiryDate <= deps.now()
    }

    var activePairing: PairingInfo? {
        guard canIssuePairingQR,
              isTransportReady(selectedTransport),
              let pairing = issuedPairing,
              pairing.hasTicket,
              pairing.network == selectedTransport.pairingNetwork,
              !isIssuedPairingExpired
        else {
            return nil
        }
        return pairing
    }

    var canCopyPairingLink: Bool {
        activePairing != nil
    }

    var blockingChecks: [OnboardingCheck] {
        checks.filter(\.blocking)
    }

    var assistantChecks: [OnboardingCheck] {
        checks.filter { $0.id.isIndividualAssistant }
    }

    var networkChecks: [OnboardingCheck] {
        checks.filter { $0.id.isIndividualNetwork }
    }

    // MARK: - Lifecycle

    func handleAppear(preferredTransport: OnboardingTransport? = nil) async {
        isVisible = true
        if let preferredTransport {
            hasUserSelectedTransport = true
            selectedTransport = preferredTransport
        }
        invalidateIssuedPairing()
        await runPreflight()
    }

    /// 离开配对窗口立即取消在途请求、清空 QR 与可复制态，确保迟到响应被丢弃。
    func handleDisappear() {
        isVisible = false
        cancelPreflight()
        invalidateIssuedPairing()
        copyFeedbackTask?.cancel()
        copyFeedbackTask = nil
    }

    /// 回到前台仅执行被动预检，绝不自动启用通道或启动服务。
    func handleApplicationDidBecomeActive() {
        guard isVisible, !isEnablingTransport, !isApplyingFix else { return }
        startPreflight()
    }

    /// 选中通道仅更新本地选择并立即清空旧码与可复制态，严格零写操作。
    func selectTransport(_ transport: OnboardingTransport) {
        hasUserSelectedTransport = true
        guard selectedTransport != transport else { return }
        selectedTransport = transport
        didExpireCurrentPairing = false
        invalidateIssuedPairing()
        if isVisible, canIssuePairingQR, isTransportReady(transport) {
            startIssuingPairingQR(for: transport)
        }
    }

    // MARK: - Explicit Transport Enable (Single Reload + Re-verify Before QR)

    func enableSelectedTransport(_ transport: OnboardingTransport) async {
        guard isVisible, canExplicitlyEnable(transport) else { return }
        selectedTransport = transport
        hasUserSelectedTransport = true
        isEnablingTransport = true
        pairingError = nil
        didExpireCurrentPairing = false
        invalidateIssuedPairing()

        do {
            try await deps.enableTransport(transport)
        } catch is CancellationError {
            isEnablingTransport = false
            return
        } catch {
            isEnablingTransport = false
            pairingError = diagnosticFromError(error, defaultStep: transport.checkID)
            return
        }

        isEnablingTransport = false
        guard isVisible else { return }
        // 显式开启并重载后必须先跑一次被动预检复核生效路由与全量门槛，再决定是否出码。
        await runPreflight()
        if let task = pairingTask {
            await task.value
        }
    }

    // MARK: - Preflight (Single-flight, Passive)

    func cancelPreflight() {
        preflightTask?.cancel()
        preflightTask = nil
        preflightGeneration &+= 1
        activePreflightGeneration = nil
        isCheckingPreflight = false
    }

    func startPreflight() {
        guard isVisible else { return }
        preflightTask?.cancel()
        preflightGeneration &+= 1
        let generation = preflightGeneration
        activePreflightGeneration = generation
        isCheckingPreflight = true
        preflightError = nil
        invalidateIssuedPairing()
        preflightTask = Task { [weak self] in
            guard let self else { return }
            await self.executePreflight(generation: generation)
        }
    }

    func runPreflight() async {
        startPreflight()
        if let task = preflightTask {
            await task.value
        }
    }

    private func executePreflight(generation: UInt64) async {
        let options = OnboardingPreflightOptions(
            stage: .pair,
            progressJSON: true,
            verifiedConfigured: report?.configured ?? true,
            verifiedCapability: verifiedCapability
        )
        do {
            let rawReport = try await deps.preflight(options, nil)
            guard isVisible,
                  !Task.isCancelled,
                  preflightGeneration == generation,
                  activePreflightGeneration == generation
            else {
                return
            }
            activePreflightGeneration = nil
            let overlaid = MacNativePreflightOverlay.apply(to: rawReport, evidence: currentNativeEvidence())
            switch OnboardingCopyCatalog.validateReport(
                overlaid,
                platform: .macos,
                expectedStage: .pair,
                nativeOverlay: true,
                verifiedCapability: verifiedCapability
            ) {
            case .success(let resolvedMap):
                report = overlaid
                checks = overlaid.checks
                resolvedDiagnostics = resolvedMap
                preflightError = nil
                isCheckingPreflight = false
                syncAfterPreflight(overlaid)
            case .failure:
                invalidateIssuedPairing()
                report = nil
                checks = []
                resolvedDiagnostics = [:]
                isCheckingPreflight = false
                preflightError = OnboardingResolvedDiagnostic(
                    code: nil,
                    step: .networkAny,
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
            guard isVisible,
                  !Task.isCancelled,
                  preflightGeneration == generation,
                  activePreflightGeneration == generation
            else {
                return
            }
            activePreflightGeneration = nil
            isCheckingPreflight = false
            invalidateIssuedPairing()
            preflightError = diagnosticFromError(error, defaultStep: .networkAny)
        }
    }

    private func syncAfterPreflight(_ report: OnboardingPreflightReport) {
        // 自动选中推荐通道严格不执行任何写入；用户手动选择后保持用户选择。
        if !hasUserSelectedTransport, let recommended = report.recommendedTransport {
            selectedTransport = recommended
        }
        if canIssuePairingQR, isTransportReady(selectedTransport) {
            startIssuingPairingQR(for: selectedTransport)
        } else {
            invalidateIssuedPairing()
        }
    }

    private func currentNativeEvidence() -> MacNativePreflightEvidence {
        MacNativePreflightEvidence(
            agentRegistrationState: deps.agentRegistrationState(),
            mainAppRegistrationState: deps.mainAppRegistrationState(),
            photosAccessState: deps.photosAccessState(),
            localNetworkAccessDenied: deps.localNetworkAccessDenied()
        )
    }

    // MARK: - QR Issuance & Expiry

    func startIssuingPairingQR(for transport: OnboardingTransport? = nil) {
        pairingTask?.cancel()
        pairingGeneration &+= 1
        let generation = pairingGeneration
        let target = transport ?? selectedTransport
        didExpireCurrentPairing = false
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
        guard isVisible,
              !Task.isCancelled,
              pairingGeneration == generation,
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
        didCopyPairingLink = false

        do {
            let pairing = try await deps.pair(transport.pairingNetwork)
            guard isVisible,
                  !Task.isCancelled,
                  pairingGeneration == generation,
                  selectedTransport == transport,
                  canIssuePairingQR,
                  isTransportReady(transport)
            else {
                return
            }
            isIssuingPairing = false
            guard pairing.hasTicket,
                  pairing.network == transport.pairingNetwork,
                  let expiryDate = OnboardingDateParser.parseRFC3339(pairing.expiresAt)
            else {
                issuedPairing = nil
                pairingError = OnboardingResolvedDiagnostic(
                    code: nil,
                    step: .networkAny,
                    message: "当前未返回有效的配对链接或过期时间，请重新检查后刷新二维码。",
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
            if expiryDate <= deps.now() {
                issuedPairing = nil
                didExpireCurrentPairing = true
                return
            }
            issuedPairing = pairing
        } catch is CancellationError {
            if pairingGeneration == generation {
                isIssuingPairing = false
            }
        } catch {
            guard isVisible, !Task.isCancelled, pairingGeneration == generation else { return }
            isIssuingPairing = false
            issuedPairing = nil
            didCopyPairingLink = false
            pairingError = diagnosticFromError(error, defaultStep: .networkAny)
        }
    }

    @discardableResult
    func copyPairingLink() -> Bool {
        clearIssuedPairingIfExpired()
        guard let pairing = activePairing, let pairURL = pairing.pairURL else {
            return false
        }
        guard deps.copyToClipboard(pairURL) else { return false }
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
        guard issuedPairing != nil, isIssuedPairingExpired else { return }
        issuedPairing = nil
        didCopyPairingLink = false
        didExpireCurrentPairing = true
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

    // MARK: - Trusted Preflight Fix Dispatch

    func performCheckPrimaryAction(for check: OnboardingCheck) async {
        guard report != nil,
              self.check(for: check.id) == check,
              let resolved = resolvedDiagnostics[check.id],
              resolved.isTrusted,
              let fix = resolved.primaryAction
        else {
            return
        }
        await dispatchTrustedFix(fix, checkID: check.id)
    }

    func performCheckSecondaryAction(for check: OnboardingCheck) async {
        guard report != nil,
              self.check(for: check.id) == check,
              let resolved = resolvedDiagnostics[check.id],
              resolved.isTrusted,
              let secondary = resolved.secondaryAction
        else {
            return
        }
        await dispatchTrustedFix(secondary, checkID: check.id)
    }

    func performDiagnosticAction(_ diagnostic: OnboardingResolvedDiagnostic) async {
        guard diagnostic.isTrusted, let fix = diagnostic.primaryAction else { return }
        await dispatchTrustedFix(fix, checkID: diagnostic.step ?? .networkAny)
    }

    private func dispatchTrustedFix(_ fix: OnboardingFix, checkID: OnboardingCheckID) async {
        switch fix {
        case .openURL(let allowedURL):
            deps.openURL(allowedURL.url)
        case .openSettings(let target):
            deps.openSettings(target)
        case .retry:
            await runPreflight()
        case .runFix(let action):
            await dispatchRunFixAction(action, checkID: checkID)
        case .choosePath, .skip:
            break
        }
    }

    private func dispatchRunFixAction(_ action: OnboardingRunFixAction, checkID: OnboardingCheckID) async {
        guard !isApplyingFix, !isEnablingTransport, let report else { return }
        if action.requiresConfig && !report.configured { return }
        switch action {
        case .enableTailscale:
            await enableSelectedTransport(.tailscale)
        case .enableTailcat:
            await enableSelectedTransport(.tailcat)
        case .enableLAN:
            await enableSelectedTransport(.lan)
        case .enableCodex, .enableClaude, .enableAgy:
            let runtimeID = switch action {
            case .enableCodex: "codex"
            case .enableClaude: "claude"
            case .enableAgy: "agy"
            default: ""
            }
            isApplyingFix = true
            defer { isApplyingFix = false }
            do {
                try await deps.enableAssistant(runtimeID)
                await runPreflight()
            } catch is CancellationError {
                return
            } catch {
                pairingError = diagnosticFromError(error, defaultStep: checkID)
            }
        case .restartService:
            isApplyingFix = true
            defer { isApplyingFix = false }
            do {
                try await deps.restartService()
                await runPreflight()
            } catch is CancellationError {
                return
            } catch {
                pairingError = diagnosticFromError(error, defaultStep: .serviceDaemon)
            }
        case .registerService:
            isApplyingFix = true
            defer { isApplyingFix = false }
            do {
                _ = try await deps.registerOrStartService()
                await runPreflight()
            } catch is CancellationError {
                return
            } catch {
                pairingError = diagnosticFromError(error, defaultStep: .serviceDaemon)
            }
        case .connectDeepSeek:
            deps.openSettings(.assistants)
        case .saveSetup, .doctorFix, .takeoverHomebrew:
            // 配对窗口不执行配置保存、doctor_fix 或 Homebrew 接管；交由向导/诊断页面处理。
            break
        }
    }

    private func diagnosticFromError(_ error: Error, defaultStep: OnboardingCheckID) -> OnboardingResolvedDiagnostic {
        if let clientError = error as? AgentClientError, let diag = clientError.onboardingDiagnostic {
            return diag
        }
        if let lifecycleError = error as? ServiceLifecycleError, case .requiresApproval = lifecycleError {
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
}
