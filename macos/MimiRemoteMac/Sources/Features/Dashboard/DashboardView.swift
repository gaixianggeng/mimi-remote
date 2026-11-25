import AppKit
import SwiftUI

enum DashboardRemediationAction: Equatable, Identifiable, Sendable {
    case openLoginItems
    case openHostRecovery
    case openDesktopRelease
    case repairAndStartService
    case recheck
    case openDiagnostics
    case returnToOnboarding

    var id: String {
        switch self {
        case .openLoginItems: "open_login_items"
        case .openHostRecovery: "open_host_recovery"
        case .openDesktopRelease: "open_desktop_release"
        case .repairAndStartService: "repair_and_start_service"
        case .recheck: "recheck"
        case .openDiagnostics: "open_diagnostics"
        case .returnToOnboarding: "return_to_onboarding"
        }
    }

    var title: String {
        switch self {
        case .openLoginItems: "打开登录项设置…"
        case .openHostRecovery: "查看恢复信息…"
        case .openDesktopRelease: "下载桌面端"
        case .repairAndStartService: "修复并启动服务"
        case .recheck: "重新检查"
        case .openDiagnostics: "运行诊断…"
        case .returnToOnboarding: "返回首次设置"
        }
    }
}

struct DashboardRemediation: Equatable, Sendable {
    let title: String
    let message: String
    let primaryAction: DashboardRemediationAction
    let primaryButtonTitle: String
    let secondaryActions: [DashboardRemediationAction]
}

/// 概览页展示规约：统一收敛单一错误文案（消除双份红字），并为 `.degraded` / `.stopped` / `.failed`
/// 提供基于原生证据与被动预检的类型化修复入口。
enum DashboardPresentation {
    static func remediation(
        lifecycle: HostLifecycleState,
        owner: ServiceOwner,
        agentRegistrationState: ServiceRegistrationState,
        hasConfiguration: Bool,
        preflightReport: OnboardingPreflightReport? = nil,
        preflightDiagnostics: [OnboardingCheckID: OnboardingResolvedDiagnostic] = [:]
    ) -> DashboardRemediation? {
        switch lifecycle {
        case .loading, .notConfigured, .migrationRequired, .starting, .ready:
            return nil
        case .degraded(let detail):
            return typedRemediation(
                fallbackTitle: "服务需要处理",
                fallbackMessage: detail,
                primaryStartTitle: "修复并启动服务",
                owner: owner,
                agentRegistrationState: agentRegistrationState,
                hasConfiguration: hasConfiguration,
                preflightReport: preflightReport,
                preflightDiagnostics: preflightDiagnostics
            )
        case .stopped:
            return typedRemediation(
                fallbackTitle: "后台服务已停止",
                fallbackMessage: "服务当前未运行，已有配置和手机配对均已保留。",
                primaryStartTitle: "启动服务",
                owner: owner,
                agentRegistrationState: agentRegistrationState,
                hasConfiguration: hasConfiguration,
                preflightReport: preflightReport,
                preflightDiagnostics: preflightDiagnostics
            )
        case .failed(let detail):
            return typedRemediation(
                fallbackTitle: "服务启动失败",
                fallbackMessage: detail,
                primaryStartTitle: "重试启动服务",
                owner: owner,
                agentRegistrationState: agentRegistrationState,
                hasConfiguration: hasConfiguration,
                preflightReport: preflightReport,
                preflightDiagnostics: preflightDiagnostics
            )
        }
    }

    /// 避免在标题副文/修复卡片已经呈现同一报错时，在概览页底部再打印第二份红字报错。
    static func additionalErrorBanner(
        lifecycle: HostLifecycleState,
        lastError: String?,
        remediation: DashboardRemediation?
    ) -> String? {
        guard let trimmed = lastError?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        if let detail = lifecycle.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
           detail == trimmed
        {
            return nil
        }
        let message = DiagnosticLogSanitizer.serviceMessage(trimmed)
        return remediation?.message == message ? nil : message
    }

    private static func typedRemediation(
        fallbackTitle: String,
        fallbackMessage: String,
        primaryStartTitle: String,
        owner: ServiceOwner,
        agentRegistrationState: ServiceRegistrationState,
        hasConfiguration: Bool,
        preflightReport: OnboardingPreflightReport?,
        preflightDiagnostics: [OnboardingCheckID: OnboardingResolvedDiagnostic]
    ) -> DashboardRemediation {
        let configCheck = preflightReport?.checks.first(where: { $0.id == .configStore })
        if let configCheck,
           let code = configCheck.code,
           DiagnosticsStore.hostRecoveryCodes.contains(code)
        {
            let msg = preflightDiagnostics[.configStore]?.message
                ?? OnboardingCopyCatalog.localizedMessage(code: code, step: .configStore)
            return DashboardRemediation(
                title: "配置需要只读恢复",
                message: msg,
                primaryAction: .openHostRecovery,
                primaryButtonTitle: DashboardRemediationAction.openHostRecovery.title,
                secondaryActions: [.recheck]
            )
        }

        if configCheck?.code == "config_requires_newer_version"
            || preflightReport?.checks.first(where: { $0.id == .serviceDaemon })?.code == "service_install_incomplete"
        {
            let code = configCheck?.code == "config_requires_newer_version"
                ? "config_requires_newer_version"
                : "service_install_incomplete"
            let step: OnboardingCheckID = code == "config_requires_newer_version" ? .configStore : .serviceDaemon
            let msg = preflightDiagnostics[step]?.message
                ?? OnboardingCopyCatalog.localizedMessage(code: code, step: step)
            return DashboardRemediation(
                title: "需要更新桌面端",
                message: msg,
                primaryAction: .openDesktopRelease,
                primaryButtonTitle: DashboardRemediationAction.openDesktopRelease.title,
                secondaryActions: [.openDiagnostics]
            )
        }

        let serviceCheck = preflightReport?.checks.first(where: { $0.id == .serviceDaemon })
        if serviceCheck?.code == "service_requires_approval"
            || (agentRegistrationState == .requiresApproval && owner != .homebrew)
        {
            return DashboardRemediation(
                title: "需要允许后台服务运行",
                message: OnboardingCopyCatalog.localizedMessage(
                    code: "service_requires_approval",
                    step: .serviceDaemon
                ),
                primaryAction: .openLoginItems,
                primaryButtonTitle: DashboardRemediationAction.openLoginItems.title,
                secondaryActions: [.recheck, .openDiagnostics]
            )
        }

        let resolvedMessage: String
        if let blocker = preflightReport?.checks.first(where: \.blocking),
           let diag = preflightDiagnostics[blocker.id]
        {
            resolvedMessage = diag.message
        } else {
            resolvedMessage = DiagnosticLogSanitizer.serviceMessage(fallbackMessage)
        }

        var secondary: [DashboardRemediationAction] = [.recheck, .openDiagnostics]
        if !hasConfiguration {
            secondary.insert(.returnToOnboarding, at: 0)
        }

        return DashboardRemediation(
            title: fallbackTitle,
            message: resolvedMessage,
            primaryAction: .repairAndStartService,
            primaryButtonTitle: primaryStartTitle,
            secondaryActions: secondary
        )
    }
}

struct DashboardView: View {
    let store: HostStore
    /// 首次启动时由系统直接弹出这个窗口；菜单栏 App 不会自动切到前台，窗口会落在别的 App 后面。
    var activatesOnAppear = false

    @State private var preflightReport: OnboardingPreflightReport?
    @State private var preflightDiagnostics: [OnboardingCheckID: OnboardingResolvedDiagnostic] = [:]

    var body: some View {
        let remediation = showsOnboardingWizard ? nil : DashboardPresentation.remediation(
            lifecycle: store.lifecycle,
            owner: store.owner,
            agentRegistrationState: store.agentRegistrationState,
            hasConfiguration: store.hasConfiguration(),
            preflightReport: preflightReport,
            preflightDiagnostics: preflightDiagnostics
        )
        let extraError = showsOnboardingWizard ? nil : DashboardPresentation.additionalErrorBanner(
            lifecycle: store.lifecycle,
            lastError: store.lastError,
            remediation: remediation
        )

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !showsOnboardingWizard {
                    HostStatusHeader(lifecycle: store.lifecycle, showsDetail: remediation == nil)
                }

                if showsOnboardingWizard {
                    OnboardingView(store: store)
                } else if store.lifecycle == .migrationRequired {
                    MigrationView(store: store)
                } else {
                    ServiceOverviewView(
                        store: store,
                        remediation: remediation,
                        recheckPreflight: { await loadPassivePreflightIfNeeded() }
                    )
                }

                if !showsOnboardingWizard, let loginWarning = store.loginItemWarning {
                    Label(loginWarning, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }

                if let extraError {
                    Text(extraError)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .padding(24)
        }
        .navigationTitle("Mimi Remote Mac")
        .onAppear {
            guard activatesOnAppear else { return }
            DispatchQueue.main.async {
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }
        .task(id: store.lifecycle) {
            await loadPassivePreflightIfNeeded()
        }
    }

    private var showsOnboardingWizard: Bool {
        store.lifecycle == .notConfigured || store.isOnboardingInProgress
    }

    private func loadPassivePreflightIfNeeded() async {
        guard !showsOnboardingWizard else {
            preflightReport = nil
            preflightDiagnostics = [:]
            return
        }
        switch store.lifecycle {
        case .degraded, .stopped, .failed:
            break
        default:
            preflightReport = nil
            preflightDiagnostics = [:]
            return
        }
        let stage: OnboardingStage = store.hasConfiguration() ? .pair : .setup
        let options = OnboardingPreflightOptions(
            stage: stage,
            progressJSON: false,
            verifiedConfigured: store.hasConfiguration(),
            verifiedCapability: store.verifiedOnboardingCapability
        )
        preflightReport = nil
        preflightDiagnostics = [:]
        guard let raw = try? await store.agent.preflight(options, nil), !Task.isCancelled else { return }
        let evidence = MacNativePreflightEvidence(
            agentRegistrationState: store.agentRegistrationState,
            mainAppRegistrationState: store.mainAppRegistrationState,
            photosAccessState: store.currentPhotosAccessState,
            localNetworkAccessDenied: false
        )
        let overlaid = MacNativePreflightOverlay.apply(to: raw, evidence: evidence)
        if case .success(let resolved) = OnboardingCopyCatalog.validateReport(
            overlaid,
            platform: .macos,
            expectedStage: stage,
            nativeOverlay: true,
            verifiedCapability: store.verifiedOnboardingCapability
        ) {
            preflightReport = overlaid
            preflightDiagnostics = resolved
        }
    }
}

private struct ServiceOverviewView: View {
    let store: HostStore
    let remediation: DashboardRemediation?
    let recheckPreflight: () async -> Void
    @Environment(\.openWindow) private var openWindow
    @State private var confirmsRestore = false

    var body: some View {
        VStack(spacing: 14) {
            if let remediation {
                InfoCard(remediation.title) {
                    Text(remediation.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)

                    HStack(spacing: 10) {
                        Button(remediation.primaryButtonTitle) {
                            perform(remediation.primaryAction)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.isBusy)

                        ForEach(remediation.secondaryActions) { action in
                            Button(action.title) {
                                perform(action)
                            }
                            .disabled(store.isBusy)
                        }
                    }
                }
            }

            if let status = store.status {
                InfoCard("连接") {
                    KeyValueRow(key: "Endpoint", value: status.endpoint)
                    KeyValueRow(key: "版本", value: status.version)
                    KeyValueRow(key: "已授权项目", value: "\(status.projects)")
                    KeyValueRow(key: "运行方式", value: store.owner == .macApp ? "Mimi Remote Mac" : "Homebrew")
                }
            }

            HStack {
                if remediation == nil {
                    // 服务就绪时把配对二维码作为主按钮，不必回菜单栏找。
                    Button("显示配对二维码") { openWindow(id: AppWindow.pairing.rawValue) }
                        .buttonStyle(.borderedProminent)
                    Button("刷新状态") { Task { await store.refresh() } }
                } else {
                    Button("配对设备…") { openWindow(id: AppWindow.pairing.rawValue) }
                }
                Button("重启服务") { Task { await store.restartService() } }
                    .disabled(store.owner != .macApp || store.isBusy)
                Spacer()
                if store.canRestoreHomebrew {
                    Button("恢复 Homebrew…", role: .destructive) {
                        confirmsRestore = true
                    }
                }
            }
            CodexRuntimeUpdateNotice(store: store, showsCurrentVersion: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("恢复 Homebrew 服务？", isPresented: $confirmsRestore) {
            Button("取消", role: .cancel) {}
            Button("停止 App 服务并恢复", role: .destructive) {
                Task { await store.restoreHomebrew() }
            }
        } message: {
            Text("切换期间移动设备会短暂断开；Homebrew 启动失败时会自动恢复 App 服务。")
        }
    }

    private func perform(_ action: DashboardRemediationAction) {
        switch action {
        case .openLoginItems:
            store.openLoginItemsSettings()
        case .openHostRecovery:
            store.requestedDiagnosticsFocus = .hostRecovery
            openWindow(id: AppWindow.diagnostics.rawValue)
        case .openDesktopRelease:
            NSWorkspace.shared.open(OnboardingFixURL.desktop.url)
        case .repairAndStartService:
            Task {
                await store.repairAndStartService()
                await recheckPreflight()
            }
        case .recheck:
            Task {
                await recheckPreflight()
            }
        case .openDiagnostics:
            store.requestedDiagnosticsFocus = .overview
            openWindow(id: AppWindow.diagnostics.rawValue)
        case .returnToOnboarding:
            store.beginOnboarding()
        }
    }
}

private struct MigrationView: View {
    let store: HostStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsTakeover = false

    var body: some View {
        InfoCard("发现现有 Homebrew 服务") {
            Text("接管会复用现有配置和 iPad Token，停止 Homebrew 后台服务，再启动 App 内签名的 agentd。Homebrew formula 会保留，接管失败时自动恢复。")
                .foregroundStyle(.secondary)
            HStack {
                Button("确认并接管") { confirmsTakeover = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isBusy)
                Button("先保持现状") { dismiss() }
            }
        }
        .alert("接管 Homebrew 服务？", isPresented: $confirmsTakeover) {
            Button("取消", role: .cancel) {}
            Button("开始接管") {
                Task { await store.takeOverHomebrew() }
            }
        } message: {
            Text("切换期间 iPhone 和 iPad 会短暂断开；失败时会自动恢复旧服务。")
        }
    }
}

#if DEBUG
    #Preview("服务可用") {
        DashboardView(store: .preview(.ready))
    }

    #Preview("首次设置") {
        DashboardView(store: .preview(.notConfigured))
    }
#endif
