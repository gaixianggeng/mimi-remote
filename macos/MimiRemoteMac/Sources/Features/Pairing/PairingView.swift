import AppKit
import Foundation
import SwiftUI

struct PairingView: View {
    let store: HostStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var pairingStore: PairingWindowStore?
    @State private var contentOverflows = false
    @State private var isApplyingRelay = false

    /// 窗口可以被拉宽，但这一页只有一件事：扫码。内容始终是一列固定宽度，不跟着窗口摊开。
    static let columnWidth: CGFloat = 340

    var body: some View {
        VStack(spacing: 10) {
            if let pairingStore {
                PairingNetworkPicker(
                    selection: Binding(
                        get: { pairingStore.selectedTransport },
                        set: { pairingStore.selectTransport($0) }
                    ),
                    recommended: pairingStore.recommendedTransport,
                    isDisabled: pairingStore.isEnablingTransport || pairingStore.isApplyingFix || isApplyingRelay,
                    transports: pairingStore.orderedTransports
                )
                .padding(.top, 14)

                if isApplyingRelay {
                    PairingLoadingState(title: "正在切换中转服务", message: "完成后将重新检查配对条件。")
                } else {
                    mainContent(pairingStore)
                }
            } else {
                PairingLoadingState()
            }
        }
        .frame(minWidth: 440, minHeight: 580)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let pairingStore {
                pairingFooter(pairingStore)
            }
        }
        // macOS 26 的玻璃材质留给窗口 chrome 和操作控件，二维码内容层保持安静、稳定。
        .containerBackground(for: .window) {
            PairingWindowBackdrop()
        }
        .task {
            let controller = ensurePairingStore()
            let preferred = store.preferredPairingTransport
            store.preferredPairingTransport = nil
            await controller.handleAppear(preferredTransport: preferred)
        }
        .onChange(of: store.preferredPairingTransport) { _, preferred in
            guard let preferred, let pairingStore else { return }
            store.preferredPairingTransport = nil
            pairingStore.selectTransport(preferred)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !isApplyingRelay { pairingStore?.handleApplicationDidBecomeActive() }
        }
        .task(id: pairingStore?.issuedPairing?.expiresAt) {
            guard let pairingStore, pairingStore.issuedPairing != nil else { return }
            while !Task.isCancelled && pairingStore.issuedPairing != nil {
                pairingStore.clearIssuedPairingIfExpired()
                if pairingStore.issuedPairing == nil { break }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: isApplyingRelay) { _, applying in
            if applying {
                pairingStore?.cancelPreflight()
                pairingStore?.invalidateIssuedPairing()
            }
        }
        .onChange(of: store.canPair) { _, ready in
            if !ready, !isApplyingRelay, pairingStore?.issuedPairing != nil {
                pairingStore?.startPreflight()
            }
        }
        .onDisappear {
            pairingStore?.handleDisappear()
        }
    }

    static func showsEndpoint(for pairing: PairingInfo) -> Bool {
        guard pairing.network != .tailcat else { return false }
        return !pairing.endpoint.isEmpty
    }

    static func visibleWarnings(for pairing: PairingInfo, lastError: String?) -> [String] {
        // 内置连接的有效期已由二维码下方的倒计时胶囊展示，不再重复渲染静态实验提示框挤压页面。
        let filtered = pairing.warnings.filter { warning in
            !(pairing.network == .tailcat && warning.hasPrefix("Tailcat 二维码"))
        }
        return filtered + [lastError].compactMap { $0 }
    }

    private func ensurePairingStore() -> PairingWindowStore {
        if let pairingStore { return pairingStore }
        let created = PairingWindowStore(
            dependencies: .live(hostStore: store, openWindow: { window in
                openWindow(id: window.rawValue)
                activateApplication()
            }) { target in
                handleOpenSettings(target)
            },
            verifiedCapability: store.verifiedOnboardingCapability
        )
        pairingStore = created
        return created
    }

    private func handleOpenSettings(_ target: OnboardingSettingsTarget) {
        switch target {
        case .loginItems:
            store.openLoginItemsSettings()
        case .filesAndFolders:
            store.openFilesAndFoldersSettings()
        case .localNetwork:
            store.openLocalNetworkSettings()
        case .photos:
            store.openPhotosPrivacySettings()
        case .fullDiskAccess:
            store.openFullDiskAccessSettings()
        case .dateTime:
            store.openDateTimeSettings()
        case .assistants:
            store.requestedSettingsSection = .assistants
            openSettings()
            activateApplication()
        case .managedConnection:
            store.requestedSettingsSection = .connections
            openSettings()
            activateApplication()
        case .hostRecovery:
            store.requestedDiagnosticsFocus = .hostRecovery
            openWindow(id: AppWindow.diagnostics.rawValue)
            activateApplication()
        case .connections, .windowsFirewall, .windowsNetworkProfile:
            break
        }
    }

    private func activateApplication() {
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    @ViewBuilder
    private func mainContent(_ pairingStore: PairingWindowStore) -> some View {
        if pairingStore.isServiceRequiresApproval {
            serviceApprovalGateView(pairingStore)
        } else if pairingStore.isCheckingPreflight && pairingStore.report == nil {
            PairingLoadingState(
                title: "正在检查配对条件",
                message: "正在核对后台服务、可用助手与连接方式，不会自动开启任何通道。"
            )
        } else if let preflightError = pairingStore.preflightError {
            PairingPreflightBlockedView(
                title: "暂时无法确认配对条件",
                diagnostic: preflightError,
                isWorking: pairingStore.isCheckingPreflight,
                onPrimaryAction: { Task { await pairingStore.performDiagnosticAction(preflightError) } },
                onRetry: { Task { await pairingStore.runPreflight() } }
            )
        } else if !pairingStore.canIssuePairingQR
            && !(pairingStore.corePrerequisitesReady
                && pairingStore.canExplicitlyEnable(pairingStore.selectedTransport))
        {
            prerequisitesBlockedView(pairingStore)
        } else if !pairingStore.isTransportReady(pairingStore.selectedTransport) {
            selectedTransportCardView(pairingStore)
        } else if let activePairing = pairingStore.activePairing,
                  let pairURL = activePairing.pairURL
        {
            pairingContent(pairingStore, pairing: activePairing, pairURL: pairURL)
        } else if pairingStore.isIssuingPairing {
            PairingLoadingState()
        } else if let pairingError = pairingStore.pairingError {
            PairingPreflightBlockedView(
                title: "暂时无法生成二维码",
                diagnostic: pairingError,
                isWorking: pairingStore.isIssuingPairing || pairingStore.isCheckingPreflight,
                onPrimaryAction: { Task { await pairingStore.performDiagnosticAction(pairingError) } },
                onRetry: { Task { await pairingStore.issuePairingQR(for: pairingStore.selectedTransport) } }
            )
        } else if pairingStore.didExpireCurrentPairing {
            PairingUnavailableState(
                title: "二维码已过期",
                description: OnboardingCopyCatalog.localizedMessage(
                    code: "pair_ticket_expired",
                    step: .networkAny
                ),
                buttonTitle: "刷新二维码",
                isRetrying: pairingStore.isIssuingPairing,
                retry: { Task { await pairingStore.issuePairingQR(for: pairingStore.selectedTransport) } }
            )
        } else {
            PairingUnavailableState(
                title: "准备就绪",
                description: "点击下方按钮生成新的短期配对二维码。",
                buttonTitle: "生成二维码",
                isRetrying: pairingStore.isIssuingPairing,
                retry: { Task { await pairingStore.issuePairingQR(for: pairingStore.selectedTransport) } }
            )
        }
    }

    private func serviceApprovalGateView(_ pairingStore: PairingWindowStore) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                InfoCard("需要先允许后台服务运行") {
                    Text(OnboardingCopyCatalog.localizedMessage(
                        code: "service_requires_approval",
                        step: .serviceDaemon
                    ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        Button("打开登录项设置…") {
                            store.openLoginItemsSettings()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("重新检查") {
                            Task { await pairingStore.runPreflight() }
                        }
                        .disabled(pairingStore.isCheckingPreflight)
                    }
                }
            }
            .frame(width: Self.columnWidth)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }

    private func prerequisitesBlockedView(_ pairingStore: PairingWindowStore) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                InfoCard("配对前需要完成以下检查") {
                    ForEach(pairingStore.blockingChecks) { check in
                        PairingCheckItemRow(
                            check: check,
                            resolved: pairingStore.diagnostic(for: check),
                            isConfigured: pairingStore.report?.configured ?? false,
                            isWorking: pairingStore.isCheckingPreflight || pairingStore.isApplyingFix || pairingStore.isEnablingTransport,
                            onPrimary: { Task { await pairingStore.performCheckPrimaryAction(for: check) } },
                            onSecondary: { Task { await pairingStore.performCheckSecondaryAction(for: check) } }
                        )
                        if check.id == .assistantAny {
                            ForEach(pairingStore.assistantChecks.filter { $0.state != .ok }) { assistant in
                                PairingCheckItemRow(
                                    check: assistant,
                                    resolved: pairingStore.diagnostic(for: assistant),
                                    isConfigured: pairingStore.report?.configured ?? false,
                                    isWorking: pairingStore.isCheckingPreflight || pairingStore.isApplyingFix,
                                    onPrimary: { Task { await pairingStore.performCheckPrimaryAction(for: assistant) } },
                                    onSecondary: { Task { await pairingStore.performCheckSecondaryAction(for: assistant) } }
                                )
                                .padding(.leading, 12)
                            }
                        }
                        if check.id == .networkAny {
                            ForEach(pairingStore.networkChecks.filter { $0.state != .ok }) { network in
                                PairingCheckItemRow(
                                    check: network,
                                    resolved: pairingStore.diagnostic(for: network),
                                    isConfigured: pairingStore.report?.configured ?? false,
                                    isWorking: pairingStore.isCheckingPreflight || pairingStore.isEnablingTransport,
                                    onPrimary: { Task { await pairingStore.performCheckPrimaryAction(for: network) } },
                                    onSecondary: { Task { await pairingStore.performCheckSecondaryAction(for: network) } }
                                )
                                .padding(.leading, 12)
                            }
                        }
                        if check.id != pairingStore.blockingChecks.last?.id {
                            Divider().opacity(0.35)
                        }
                    }

                    HStack(spacing: 10) {
                        Button("重新检查") {
                            Task { await pairingStore.runPreflight() }
                        }
                        .disabled(pairingStore.isCheckingPreflight || pairingStore.isEnablingTransport)

                        if pairingStore.canExplicitlyEnable(pairingStore.selectedTransport) {
                            Button("启用\(pairingStore.selectedTransport.localizedTitle)") {
                                Task { await pairingStore.enableSelectedTransport(pairingStore.selectedTransport) }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(pairingStore.isEnablingTransport)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .frame(width: Self.columnWidth)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }

    private func selectedTransportCardView(_ pairingStore: PairingWindowStore) -> some View {
        let transport = pairingStore.selectedTransport
        let transportCheck = pairingStore.check(for: transport.checkID)
        let resolved = transportCheck.flatMap { pairingStore.diagnostic(for: $0) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                InfoCard("\(transport.localizedTitle) 尚未就绪") {
                    if let transportCheck {
                        PairingCheckItemRow(
                            check: transportCheck,
                            resolved: resolved,
                            isConfigured: pairingStore.report?.configured ?? false,
                            isWorking: pairingStore.isCheckingPreflight || pairingStore.isEnablingTransport,
                            hidesPrimaryAction: pairingStore.canExplicitlyEnable(transport),
                            onPrimary: { Task { await pairingStore.performCheckPrimaryAction(for: transportCheck) } },
                            onSecondary: { Task { await pairingStore.performCheckSecondaryAction(for: transportCheck) } }
                        )
                    } else {
                        Text("该连接方式当前未启用或不可用。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    if let pairingError = pairingStore.pairingError {
                        Text(pairingError.message)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 10) {
                        if pairingStore.canExplicitlyEnable(transport) {
                            Button(pairingStore.isEnablingTransport ? "正在启用并复核…" : "启用\(transport.localizedTitle)") {
                                Task { await pairingStore.enableSelectedTransport(transport) }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(pairingStore.isEnablingTransport)
                        }

                        Button("重新检查") {
                            Task { await pairingStore.runPreflight() }
                        }
                        .disabled(pairingStore.isCheckingPreflight || pairingStore.isEnablingTransport)
                    }
                }
            }
            .frame(width: Self.columnWidth)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
    }

    private func pairingContent(
        _ pairingStore: PairingWindowStore,
        pairing: PairingInfo,
        pairURL: String
    ) -> some View {
        let visibleWarnings = Self.visibleWarnings(for: pairing, lastError: pairingStore.pairingError?.message)
        let showsEndpoint = Self.showsEndpoint(for: pairing)
        return ScrollView {
            VStack(spacing: 0) {
                if let warning = pairingStore.mainAppLoginItemWarning {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(warning)
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("打开登录项设置…") {
                                store.openLoginItemsSettings()
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.bottom, 12)
                }

                PairingIntroduction()
                    .padding(.bottom, 14)

                PairingCodeCard(value: pairURL, isRefreshing: pairingStore.isIssuingPairing)
                    .padding(.bottom, 12)

                if showsEndpoint {
                    Text(pairing.endpoint)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                if !pairing.expiresAt.isEmpty {
                    PairingExpiryStatus(rawValue: pairing.expiresAt)
                        .padding(.top, showsEndpoint ? 8 : 0)
                }

                if !visibleWarnings.isEmpty {
                    PairingWarningList(warnings: visibleWarnings)
                        .padding(.top, 12)
                }
            }
            .frame(width: Self.columnWidth)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, contentOverflows ? 22 : 12)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            let available = geometry.containerSize.height
                - geometry.contentInsets.top
                - geometry.contentInsets.bottom
            return geometry.contentSize.height > available + 1
        } action: { _, overflows in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                contentOverflows = overflows
            }
        }
    }

    private func pairingFooter(_ pairingStore: PairingWindowStore) -> some View {
        VStack(spacing: 12) {
            if pairingStore.selectedTransport == .tailcat, pairingStore.report?.configured == true {
                TailcatRelayPicker(store: store, showsCaption: false, isApplying: $isApplyingRelay) {
                    await pairingStore.runPreflight()
                }
                .disabled(pairingStore.isIssuingPairing || pairingStore.isEnablingTransport)
                .accessibilityElement(children: .contain)
            }
            if !isApplyingRelay, pairingStore.activePairing != nil {
                PairingActionBar(
                    didCopy: pairingStore.didCopyPairingLink,
                    canCopy: pairingStore.canCopyPairingLink,
                    isRefreshing: pairingStore.isIssuingPairing,
                    copy: { _ = pairingStore.copyPairingLink() },
                    refresh: { Task { await pairingStore.issuePairingQR(for: pairingStore.selectedTransport) } }
                )
            }
        }
        .frame(width: Self.columnWidth)
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .background(alignment: .top) {
            if contentOverflows {
                PairingScrollEdge()
            }
        }
    }
}

private struct PairingCheckItemRow: View {
    let check: OnboardingCheck
    let resolved: OnboardingResolvedDiagnostic?
    let isConfigured: Bool
    let isWorking: Bool
    var hidesPrimaryAction = false
    let onPrimary: () -> Void
    let onSecondary: () -> Void

    var body: some View {
        let visiblePrimary = hidesPrimaryAction || resolved?.primaryAction == .skip ? nil : resolved?.primaryAction
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                OnboardingStateIcon(state: check.state)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(check.id.localizedTitle)
                        .font(.callout.weight(.semibold))
                    Text(resolved?.message ?? OnboardingCopyCatalog.safeFallbackCopy)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if resolved?.isTrusted == true,
                       visiblePrimary != nil || resolved?.secondaryAction != nil
                    {
                        HStack(spacing: 8) {
                            if let primary = visiblePrimary {
                                Button(primaryTitle(primary), action: onPrimary)
                                .controlSize(.small)
                                .disabled(isWorking)
                            }
                            if let secondary = resolved?.secondaryAction {
                                Button(resolved?.secondaryLabel ?? OnboardingActionLabels.primaryTitle(
                                    for: secondary,
                                    code: resolved?.code,
                                    isConfigured: isConfigured
                                ), action: onSecondary)
                                .controlSize(.small)
                                .disabled(isWorking)
                            }
                        }
                        .padding(.top, 2)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
    private func primaryTitle(_ action: OnboardingFix) -> String {
        switch action {
        case .choosePath, .runFix(.doctorFix): "打开诊断…"
        case .runFix(.takeoverHomebrew): "查看服务归属…"
        case .runFix(.saveSetup): "继续首次设置…"
        default: OnboardingActionLabels.primaryTitle(for: action, code: resolved?.code, isConfigured: isConfigured)
        }
    }

}

private struct PairingPreflightBlockedView: View {
    let title: String
    let diagnostic: OnboardingResolvedDiagnostic
    let isWorking: Bool
    let onPrimaryAction: () -> Void
    let onRetry: () -> Void

    var body: some View {
        PairingPlaceholder(
            symbol: "exclamationmark.triangle",
            symbolColor: .orange,
            title: title,
            message: diagnostic.message,
            isMessageSelectable: true
        ) {
            HStack(spacing: 10) {
                if diagnostic.isTrusted, let fix = diagnostic.primaryAction, fix != .retry {
                    Button(OnboardingActionLabels.primaryTitle(
                        for: fix,
                        code: diagnostic.code,
                        isConfigured: true
                    ), action: onPrimaryAction)
                    .modifier(PairingActionButtonStyleModifier(isProminent: true))
                    .disabled(isWorking)
                }
                Button("重新检查", action: onRetry)
                    .modifier(PairingActionButtonStyleModifier(isProminent: diagnostic.primaryAction == nil || diagnostic.primaryAction == .retry))
                    .disabled(isWorking)
            }
            .controlSize(.large)
        }
    }
}

private struct PairingIntroduction: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.accentColor.gradient))
                .shadow(color: Color.accentColor.opacity(0.3), radius: 10, y: 4)
                .accessibilityHidden(true)

            VStack(spacing: 5) {
                Text("扫描二维码")
                    .font(.system(size: 24, weight: .bold))
                    .tracking(-0.5)

                Text("在 iPhone 或 iPad 上打开 mimi（App Store 里叫 Mimi Remote），扫描下方二维码。扫不了码就点「复制配对链接」，在手机上粘贴。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 320)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PairingNetworkPicker: View {
    @Binding var selection: OnboardingTransport
    let recommended: OnboardingTransport?
    let isDisabled: Bool
    let transports: [OnboardingTransport]

    var body: some View {
        VStack(spacing: 6) {
            Picker("连接方式", selection: $selection) {
                ForEach(transports, id: \.self) { transport in
                    Text(label(for: transport))
                        .tag(transport)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            .frame(maxWidth: 340)
            .disabled(isDisabled)
            .accessibilityHint("选择用于生成配对二维码的连接网络")

            Label(hint, systemImage: hintSymbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .id(selection)
                .frame(minHeight: 18)
        }
        .accessibilityElement(children: .contain)
    }

    private func label(for transport: OnboardingTransport) -> String {
        if recommended == transport {
            return "\(transport.localizedTitle)（推荐）"
        }
        return transport.localizedTitle
    }

    private var hint: String {
        switch selection {
        case .tailscale:
            "已连接时优先推荐 · 支持跨网络直连"
        case .tailcat:
            "\(HostStore.tailcatTagline)，无需安装其他工具"
        case .lan:
            "手机和电脑需要处于同一受信任局域网"
        }
    }

    private var hintSymbol: String {
        switch selection {
        case .tailscale: "network"
        case .lan: "wifi"
        case .tailcat: "point.3.connected.trianglepath.dotted"
        }
    }
}

private struct PairingCodeCard: View {
    let value: String
    let isRefreshing: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        QRCodeView(value: value, size: 216)
            .padding(14)
            .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.black.opacity(0.06), lineWidth: 1)
            }
            .overlay {
                if isRefreshing {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.white.opacity(0.7))
                        .overlay {
                            ProgressView()
                                .controlSize(.large)
                        }
                }
            }
            .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isRefreshing)
            .accessibilityValue(isRefreshing ? "正在生成新的二维码" : "可扫描")
    }
}

struct PairingExpiryStatus: View {
    let rawValue: String

    var body: some View {
        if let expiryDate = Self.expiryDate(from: rawValue) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                statusLabel(at: context.date, expiryDate: expiryDate)
            }
        } else {
            Label(Self.fallbackText(for: rawValue), systemImage: "lock.shield")
                .pairingStatusCapsule(foregroundColor: .secondary)
                .accessibilityLabel("配对二维码有效期")
                .accessibilityValue(Self.fallbackText(for: rawValue))
        }
    }

    private func statusLabel(at now: Date, expiryDate: Date) -> some View {
        let expired = expiryDate <= now
        let text = statusText(at: now, expiryDate: expiryDate)
        return Label(
            text,
            systemImage: expired ? "exclamationmark.lock" : "clock.badge.checkmark"
        )
        .pairingStatusCapsule(foregroundColor: expired ? .orange : .secondary)
        .accessibilityLabel("配对二维码有效期")
        .accessibilityValue(text)
    }

    static func expiryDate(from rawValue: String) -> Date? {
        OnboardingDateParser.parseRFC3339(rawValue)
    }

    static func fallbackText(for rawValue: String) -> String {
        if rawValue.contains("后") || rawValue.contains("有效") || rawValue.contains("失效") {
            return rawValue
        }
        return "有效至 \(rawValue)"
    }

    func statusText(at now: Date, expiryDate: Date) -> String {
        let remaining = expiryDate.timeIntervalSince(now)
        if remaining <= 0 {
            return "二维码已失效"
        }
        if remaining < 60 {
            return "\(max(1, Int(ceil(remaining)))) 秒后失效"
        }
        if remaining < 60 * 60 {
            return "\(Int(ceil(remaining / 60))) 分钟后失效"
        }
        if Calendar.current.isDate(expiryDate, inSameDayAs: now) {
            return "有效至 \(expiryDate.formatted(date: .omitted, time: .shortened))"
        }
        return "有效至 \(expiryDate.formatted(date: .abbreviated, time: .shortened))"
    }
}

private extension View {
    func pairingStatusCapsule(foregroundColor: Color) -> some View {
        font(.caption.weight(.medium))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.055), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
    }
}

private struct PairingWarningList: View {
    let warnings: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(warnings, id: \.self) { warning in
                Label {
                    Text(warning)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.16), lineWidth: 1)
        }
    }
}

private struct PairingScrollEdge: View {
    var body: some View {
        Rectangle()
            .fill(.thinMaterial)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.5), location: 0.35),
                        .init(color: .black, location: 0.66),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}

private struct PairingActionBar: View {
    let didCopy: Bool
    let canCopy: Bool
    let isRefreshing: Bool
    let copy: () -> Void
    let refresh: () -> Void

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 10) {
                    actionButtons
                }
            } else {
                actionButtons
            }
        }
        .controlSize(.large)
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button(action: copy) {
                Label(
                    didCopy ? "已复制" : "复制配对链接",
                    systemImage: didCopy ? "checkmark" : "doc.on.doc"
                )
                .frame(maxWidth: .infinity, minHeight: 22)
                .contentShape(Rectangle())
            }
            .modifier(PairingActionButtonStyleModifier(isProminent: false))
            .disabled(!canCopy)
            .help("复制当前有效的短期配对链接")
            .accessibilityLabel(didCopy ? "配对链接已复制" : "复制配对链接")
            .accessibilityHint("将当前有效的配对链接复制到剪贴板")

            Button(action: refresh) {
                HStack(spacing: 6) {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(isRefreshing ? "正在刷新" : "刷新二维码")
                }
                .frame(maxWidth: .infinity, minHeight: 22)
                .contentShape(Rectangle())
            }
            .modifier(PairingActionButtonStyleModifier(isProminent: true))
            .disabled(isRefreshing)
            .keyboardShortcut("r", modifiers: .command)
            .help("生成一张新的短期配对二维码（⌘R）")
            .accessibilityLabel(isRefreshing ? "正在刷新二维码" : "刷新二维码")
            .accessibilityHint("生成一张新的短期配对二维码")
            .accessibilityValue(isRefreshing ? "进行中" : "就绪")
        }
    }
}

private struct PairingLoadingState: View {
    var title = "正在生成二维码"
    var message = "配对码仅在短时间内有效。"

    var body: some View {
        PairingPlaceholder(
            symbol: "qrcode.viewfinder",
            symbolColor: .accentColor,
            title: title,
            message: message
        ) {
            ProgressView()
                .controlSize(.small)
        }
    }
}

private struct PairingUnavailableState: View {
    let title: String
    let description: String
    var buttonTitle = "重新生成"
    let isRetrying: Bool
    let retry: () -> Void

    var body: some View {
        PairingPlaceholder(
            symbol: "qrcode",
            symbolColor: .secondary,
            title: title,
            message: description,
            isMessageSelectable: true
        ) {
            Button(action: retry) {
                HStack(spacing: 6) {
                    if isRetrying {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(isRetrying ? "正在重新生成" : buttonTitle)
                }
                .frame(minWidth: 132, minHeight: 22)
                .contentShape(Rectangle())
            }
            .modifier(PairingActionButtonStyleModifier(isProminent: true))
            .controlSize(.large)
            .disabled(isRetrying)
            .keyboardShortcut("r", modifiers: .command)
            .accessibilityLabel(isRetrying ? "正在重新生成二维码" : buttonTitle)
            .accessibilityHint("重试生成一张新的短期配对二维码")
            .accessibilityValue(isRetrying ? "进行中" : "可重试")
        }
    }
}

private struct PairingPlaceholder<Action: View>: View {
    let symbol: String
    let symbolColor: Color
    let title: String
    let message: String
    var isMessageSelectable = false
    @ViewBuilder let action: () -> Action

    @ViewBuilder private var messageText: some View {
        let base = Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        if isMessageSelectable {
            base.textSelection(.enabled)
        } else {
            base
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 38, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(symbolColor)

            VStack(spacing: 7) {
                Text(title)
                    .font(.title3.weight(.semibold))

                messageText
            }

            action()
                .padding(.top, 2)
        }
        .frame(width: PairingView.columnWidth)
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PairingActionButtonStyleModifier: ViewModifier {
    let isProminent: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if isProminent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else if isProminent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

private struct PairingWindowBackdrop: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)

            RadialGradient(
                colors: [Color.accentColor.opacity(0.16), .clear],
                center: UnitPoint(x: 0.5, y: 0),
                startRadius: 0,
                endRadius: 420
            )

            LinearGradient(
                colors: [.clear, Color.black.opacity(0.05)],
                startPoint: .center,
                endPoint: .bottom
            )
        }
    }
}

#if DEBUG
    #Preview {
        PairingView(store: .preview(.ready))
            .frame(width: 520, height: 720)
    }
#endif
