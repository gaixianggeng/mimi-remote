import AppKit
import Foundation
import Observation

struct DiagnosticsDependencies {
    var configExists: @MainActor () -> Bool
    var preflight: @Sendable (
        _ options: OnboardingPreflightOptions,
        _ onProgress: (@Sendable (OnboardingCheck) -> Void)?
    ) async throws -> OnboardingPreflightReport
    var runReadOnlyDoctor: @Sendable () async throws -> AgentDoctorResults
    var runSafeDoctorFix: @MainActor () async throws -> [String]
    var enableAssistant: @MainActor (_ runtimeID: String) async throws -> Void
    var enableTransport: @MainActor (_ transport: OnboardingTransport) async throws -> Void
    var restartService: @MainActor () async throws -> Void
    var registerOrStartService: @MainActor () async throws -> HostStore.OnboardingServiceStartOutcome
    var setRuntimePath: @Sendable (_ runtimeID: String, _ value: String) async throws -> Void
    var updateWorkspace: @Sendable (_ scanRoot: URL, _ browseRoot: URL?) async throws -> Void
    var agentRegistrationState: @MainActor () -> ServiceRegistrationState
    var mainAppRegistrationState: @MainActor () -> ServiceRegistrationState
    var photosAccessState: @MainActor () -> PhotosAccessState
    var localNetworkAccessDenied: @MainActor () -> Bool
    var openURL: @MainActor (URL) -> Void
    var openSettings: @MainActor (OnboardingSettingsTarget) -> Void

    @MainActor
    static func live(
        hostStore: HostStore,
        openSettingsTarget: @escaping @MainActor (OnboardingSettingsTarget) -> Void
    ) -> DiagnosticsDependencies {
        let agent = hostStore.agent
        return DiagnosticsDependencies(
            configExists: { hostStore.hasConfiguration() },
            preflight: { options, onProgress in
                try await agent.preflight(options, onProgress)
            },
            runReadOnlyDoctor: {
                try await agent.doctor(false).results
            },
            runSafeDoctorFix: {
                try await hostStore.runSafeDoctorFixAndReload()
            },
            enableAssistant: { runtimeID in
                try await hostStore.enableAssistantForOnboarding(runtimeID)
            },
            enableTransport: { transport in
                try await hostStore.enableTransportForOnboarding(transport)
            },
            restartService: {
                try await hostStore.restartServiceForOnboarding()
            },
            registerOrStartService: {
                try await hostStore.registerOrStartServiceForOnboarding()
            },
            setRuntimePath: { runtimeID, value in
                try await agent.setRuntimePath(runtimeID, value)
            },
            updateWorkspace: { scanRoot, browseRoot in
                try await agent.updateWorkspace(scanRoot, browseRoot)
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
            openSettings: openSettingsTarget
        )
    }
}

/// 诊断窗口状态机：
/// - 所有可点击修复严格仅来自经契约校验的 `preflight`；
/// - `doctor --json` 仅作只读中文标题与折叠详情展示，绝不产生任何可点击修复按钮；
/// - `config_invalid` / `config_recovery_required` / `token_rotation_requires_approval` /
///   `legacy_codex_residue` 指向只读 `host_recovery` 卡片（脱敏路径、保留原文件）；
/// - `doctor_fix` 仅在明确验证为 BE-3+ 宿主（`identity_preserving_doctor_fix`）且诊断码为
///   `config_permissions_unsafe` 且已配置时允许点击，完成后立即重跑预检；
/// - 零 `rotates_token` 按钮、零确认框、零未知安全参数执行。
@MainActor
@Observable
final class DiagnosticsStore {
    static let hostRecoveryCodes: Set<String> = [
        "config_invalid",
        "config_recovery_required",
        "token_rotation_requires_approval",
        "legacy_codex_residue",
    ]

    private(set) var report: OnboardingPreflightReport?
    private(set) var checks: [OnboardingCheck] = []
    private(set) var resolvedDiagnostics: [OnboardingCheckID: OnboardingResolvedDiagnostic] = [:]
    private(set) var doctorChecks: [DoctorDisplayCheck] = []
    private(set) var recoveryDiagnostic: OnboardingResolvedDiagnostic?
    private(set) var preflightError: OnboardingResolvedDiagnostic?
    private(set) var actionError: OnboardingResolvedDiagnostic?
    private(set) var appliedFixes: [String] = []
    private(set) var skippedCheckIDs: Set<OnboardingCheckID> = []
    private(set) var isChecking = false
    private(set) var isApplyingFix = false
    private(set) var pendingPathPicker: OnboardingPathPickerRequest?
    var isPathPickerPresented = false

    let verifiedCapability: String?

    private let deps: DiagnosticsDependencies
    private var preflightGeneration: UInt64 = 0
    private var preflightTask: Task<Void, Never>?

    init(
        dependencies: DiagnosticsDependencies,
        verifiedCapability: String? = nil
    ) {
        self.deps = dependencies
        self.verifiedCapability = verifiedCapability
    }

    var isBE3DoctorFixSupported: Bool {
        verifiedCapability == OnboardingSchema.doctorFixCapability
    }

    func check(for id: OnboardingCheckID) -> OnboardingCheck? {
        checks.first { $0.id == id }
    }

    func diagnostic(for check: OnboardingCheck) -> OnboardingResolvedDiagnostic? {
        resolvedDiagnostics[check.id]
    }

    /// 只有已验证为 BE-3+ 宿主且 `config_store` 明确报告 `config_permissions_unsafe`
    /// 且预检已配置并校验为受信任的 `doctor_fix` 时才允许点击。
    func canClickDoctorFix(for check: OnboardingCheck) -> Bool {
        guard isBE3DoctorFixSupported,
              let report,
              report.configured,
              check.id == .configStore,
              check.code == "config_permissions_unsafe",
              let resolved = resolvedDiagnostics[check.id],
              resolved.isTrusted,
              resolved.primaryAction == .runFix(.doctorFix)
        else {
            return false
        }
        return true
    }

    func clickablePrimaryFix(for check: OnboardingCheck) -> OnboardingFix? {
        guard let resolved = resolvedDiagnostics[check.id],
              resolved.isTrusted,
              let fix = resolved.primaryAction
        else {
            return nil
        }
        if case .runFix(.doctorFix) = fix {
            return canClickDoctorFix(for: check) ? fix : nil
        }
        if case .runFix(let action) = fix, action.requiresConfig, report?.configured != true {
            return nil
        }
        return fix
    }

    func clickableSecondaryFix(for check: OnboardingCheck) -> (fix: OnboardingFix, label: String)? {
        guard let resolved = resolvedDiagnostics[check.id],
              resolved.isTrusted,
              let secondary = resolved.secondaryAction
        else {
            return nil
        }
        let label = resolved.secondaryLabel ?? OnboardingActionLabels.primaryTitle(
            for: secondary,
            code: resolved.code,
            isConfigured: report?.configured ?? false
        )
        return (secondary, label)
    }

    func refreshAll() async {
        await runPreflight()
        await runReadOnlyDoctor()
    }

    func runPreflight() async {
        preflightTask?.cancel()
        preflightGeneration &+= 1
        let generation = preflightGeneration
        isChecking = true
        preflightError = nil
        actionError = nil
        let stage: OnboardingStage = deps.configExists() ? .pair : .setup
        let options = OnboardingPreflightOptions(
            stage: stage,
            progressJSON: true,
            verifiedConfigured: deps.configExists(),
            verifiedCapability: verifiedCapability
        )

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let rawReport = try await self.deps.preflight(options, nil)
                guard !Task.isCancelled, self.preflightGeneration == generation else { return }
                let overlaid = MacNativePreflightOverlay.apply(to: rawReport, evidence: self.currentNativeEvidence())
                switch OnboardingCopyCatalog.validateReport(
                    overlaid,
                    platform: .macos,
                    expectedStage: stage,
                    nativeOverlay: true,
                    verifiedCapability: self.verifiedCapability
                ) {
                case .success(let resolvedMap):
                    self.report = overlaid
                    self.checks = overlaid.checks
                    self.resolvedDiagnostics = resolvedMap
                    self.preflightError = nil
                    self.updateRecoveryDiagnostic(from: overlaid, resolvedMap: resolvedMap)
                case .failure:
                    self.report = nil
                    self.checks = []
                    self.resolvedDiagnostics = [:]
                    self.recoveryDiagnostic = nil
                    self.preflightError = OnboardingResolvedDiagnostic(
                        code: nil,
                        step: .configStore,
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
                self.isChecking = false
            } catch is CancellationError {
                if self.preflightGeneration == generation {
                    self.isChecking = false
                }
            } catch {
                guard !Task.isCancelled, self.preflightGeneration == generation else { return }
                self.isChecking = false
                let diag = self.diagnosticFromError(error, defaultStep: .configStore)
                self.preflightError = diag
                if diag.isTrusted,
                   diag.primaryAction == .openSettings(.hostRecovery),
                   let code = diag.code,
                   Self.hostRecoveryCodes.contains(code)
                {
                    self.recoveryDiagnostic = diag
                }
            }
        }
        preflightTask = task
        await task.value
    }

    func runReadOnlyDoctor() async {
        do {
            let results = try await deps.runReadOnlyDoctor()
            doctorChecks = results.checks.map(DoctorCheckPresentation.make(from:))
        } catch is CancellationError {
            return
        } catch {
            doctorChecks = []
        }
    }

    func cancel() {
        preflightTask?.cancel()
        preflightTask = nil
        preflightGeneration &+= 1
        isChecking = false
    }

    func performCheckPrimaryAction(for check: OnboardingCheck) async {
        guard let fix = clickablePrimaryFix(for: check),
              let resolved = resolvedDiagnostics[check.id]
        else {
            return
        }
        await dispatchTrustedFix(fix, checkID: check.id, code: resolved.code, diagnostic: resolved)
    }

    func performCheckSecondaryAction(for check: OnboardingCheck) async {
        guard let secondary = clickableSecondaryFix(for: check),
              let resolved = resolvedDiagnostics[check.id]
        else {
            return
        }
        await dispatchTrustedFix(secondary.fix, checkID: check.id, code: resolved.code, diagnostic: resolved)
    }

    func performDiagnosticAction(_ diagnostic: OnboardingResolvedDiagnostic) async {
        guard diagnostic.isTrusted, let fix = diagnostic.primaryAction else { return }
        if case .runFix(.doctorFix) = fix {
            guard isBE3DoctorFixSupported,
                  report?.configured == true,
                  diagnostic.code == "config_permissions_unsafe"
            else {
                return
            }
        }
        await dispatchTrustedFix(
            fix,
            checkID: diagnostic.step ?? .configStore,
            code: diagnostic.code,
            diagnostic: diagnostic
        )
    }

    func completePathPicker(with url: URL?) async {
        let request = pendingPathPicker
        pendingPathPicker = nil
        isPathPickerPresented = false
        guard let request, let url else { return }
        isApplyingFix = true
        actionError = nil
        defer { isApplyingFix = false }
        do {
            switch request {
            case .workspaceRoot:
                try await deps.updateWorkspace(url, nil)
            case .runtimeBinary(let runtimeID, _):
                try await deps.setRuntimePath(runtimeID, url.path)
            }
            await runPreflight()
        } catch is CancellationError {
            return
        } catch {
            actionError = diagnosticFromError(error, defaultStep: .workspaceRoot)
        }
    }

    private func updateRecoveryDiagnostic(
        from report: OnboardingPreflightReport,
        resolvedMap: [OnboardingCheckID: OnboardingResolvedDiagnostic]
    ) {
        if let configCheck = report.checks.first(where: { $0.id == .configStore }),
           let code = configCheck.code,
           Self.hostRecoveryCodes.contains(code),
           let diag = resolvedMap[.configStore],
           diag.isTrusted,
           diag.primaryAction == .openSettings(.hostRecovery)
        {
            recoveryDiagnostic = diag
        } else {
            recoveryDiagnostic = nil
        }
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
            if target == .hostRecovery {
                recoveryDiagnostic = diagnostic
            } else {
                deps.openSettings(target)
            }
        case .choosePath(let target):
            switch target {
            case .workspaceRoot:
                pendingPathPicker = .workspaceRoot
            case .codexBin:
                pendingPathPicker = .runtimeBinary(runtimeID: "codex", target: .codexBin)
            case .claudeBin:
                pendingPathPicker = .runtimeBinary(runtimeID: "claude", target: .claudeBin)
            case .agyBin:
                pendingPathPicker = .runtimeBinary(runtimeID: "agy", target: .agyBin)
            }
            isPathPickerPresented = true
        case .runFix(let action):
            await dispatchRunFixAction(action, checkID: checkID, code: code)
        case .retry:
            await runPreflight()
        case .skip:
            skippedCheckIDs.insert(checkID)
        }
    }

    private func dispatchRunFixAction(
        _ action: OnboardingRunFixAction,
        checkID: OnboardingCheckID,
        code: String?
    ) async {
        guard !isApplyingFix else { return }
        if action.requiresConfig && report?.configured != true {
            return
        }
        if action == .doctorFix {
            guard isBE3DoctorFixSupported,
                  report?.configured == true,
                  checkID == .configStore,
                  code == "config_permissions_unsafe"
            else {
                return
            }
            isApplyingFix = true
            actionError = nil
            do {
                let fixes = try await deps.runSafeDoctorFix()
                appliedFixes = fixes.map(DiagnosticLogSanitizer.sanitizeLine)
                isApplyingFix = false
                // 修复权限后立即重跑预检核验结果。
                await runPreflight()
            } catch is CancellationError {
                isApplyingFix = false
            } catch {
                isApplyingFix = false
                actionError = diagnosticFromError(error, defaultStep: .configStore)
            }
            return
        }

        switch action {
        case .saveSetup:
            deps.openSettings(.connections)
        case .enableCodex, .enableClaude, .enableAgy:
            let runtimeID = switch action {
            case .enableCodex: "codex"
            case .enableClaude: "claude"
            case .enableAgy: "agy"
            default: ""
            }
            isApplyingFix = true
            actionError = nil
            defer { isApplyingFix = false }
            do {
                try await deps.enableAssistant(runtimeID)
                await runPreflight()
            } catch is CancellationError {
                return
            } catch {
                actionError = diagnosticFromError(error, defaultStep: checkID)
            }
        case .enableTailscale:
            await runTransportFix(.tailscale)
        case .enableTailcat:
            await runTransportFix(.tailcat)
        case .enableLAN:
            await runTransportFix(.lan)
        case .connectDeepSeek:
            deps.openSettings(.assistants)
        case .restartService:
            isApplyingFix = true
            actionError = nil
            defer { isApplyingFix = false }
            do {
                try await deps.restartService()
                await runPreflight()
            } catch is CancellationError {
                return
            } catch {
                actionError = diagnosticFromError(error, defaultStep: .serviceDaemon)
            }
        case .registerService:
            isApplyingFix = true
            actionError = nil
            defer { isApplyingFix = false }
            do {
                _ = try await deps.registerOrStartService()
                await runPreflight()
            } catch is CancellationError {
                return
            } catch {
                actionError = diagnosticFromError(error, defaultStep: .serviceDaemon)
            }
        case .takeoverHomebrew:
            // 健康 Homebrew 服务不自动接管；交由概览/向导中明确确认。
            deps.openSettings(.connections)
        case .doctorFix:
            break
        }
    }

    private func runTransportFix(_ transport: OnboardingTransport) async {
        isApplyingFix = true
        actionError = nil
        defer { isApplyingFix = false }
        do {
            try await deps.enableTransport(transport)
            await runPreflight()
        } catch is CancellationError {
            return
        } catch {
            actionError = diagnosticFromError(error, defaultStep: transport.checkID)
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

    private func diagnosticFromError(_ error: Error, defaultStep: OnboardingCheckID) -> OnboardingResolvedDiagnostic {
        if let clientError = error as? AgentClientError, let diag = clientError.onboardingDiagnostic {
            return diag
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
