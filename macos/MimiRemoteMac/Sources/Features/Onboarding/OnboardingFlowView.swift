import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct OnboardingFlowView: View {
    let store: OnboardingStore
    @State private var deepSeekStartupURL = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader

            switch store.currentStep {
            case .environmentCheck:
                OnboardingChecklistStepView(store: store)
            case .workspaceSelection:
                workspaceStepView
            case .serviceAndPermissions:
                OnboardingPermissionsStepView(store: store)
            case .connectPhone:
                connectPhoneStepView
            }
        }
        .task {
            await store.start()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // 回到前台只执行被动预检，绝不调用会隐式启动服务的 HostStore.refresh()。
            store.handleApplicationDidBecomeActive()
        }
        .fileImporter(
            isPresented: Binding(
                get: { store.pendingPathPicker != nil },
                set: { if !$0 { store.pendingPathPicker = nil } }
            ),
            allowedContentTypes: allowedPickerTypes,
            allowsMultipleSelection: false
        ) { result in
            let request = store.pendingPathPicker
            store.pendingPathPicker = nil
            guard case .success(let urls) = result, let url = urls.first, let request else { return }
            Task {
                switch request {
                case .workspaceRoot:
                    await store.selectWorkspaceRoot(url)
                case .runtimeBinary(let runtimeID, _):
                    await store.selectRuntimeBinaryPath(for: runtimeID, url: url)
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { store.presentsDeepSeekConnectForm },
            set: { store.presentsDeepSeekConnectForm = $0 }
        )) {
            deepSeekConnectSheet
        }
        .task(id: store.issuedPairing?.expiresAt) {
            guard let expiryDate = store.issuedPairingExpiryDate else { return }
            let remaining = expiryDate.timeIntervalSinceNow
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining + 0.25))
            }
            guard !Task.isCancelled else { return }
            store.clearIssuedPairingIfExpired()
        }
    }

    private var allowedPickerTypes: [UTType] {
        switch store.pendingPathPicker {
        case .workspaceRoot, .none:
            [.folder]
        case .runtimeBinary:
            [.item]
        }
    }

    // MARK: - Step Header

    private var stepHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("欢迎使用 Mimi Remote Mac")
                .font(.title2.weight(.semibold))

            HStack(spacing: 6) {
                ForEach(OnboardingWizardStep.allCases) { step in
                    let isActive = step == store.currentStep
                    let isPast = step.rawValue < store.currentStep.rawValue
                    HStack(spacing: 4) {
                        Image(systemName: isPast ? "checkmark.circle.fill" : "\(step.rawValue).circle.fill")
                            .font(.caption)
                            .foregroundStyle(isActive ? Color.accentColor : (isPast ? Color.mimiSuccess : .secondary))
                        Text(step.title)
                            .font(.caption.weight(isActive ? .semibold : .regular))
                            .foregroundStyle(isActive ? .primary : .secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        isActive ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04),
                        in: Capsule()
                    )
                }
            }
        }
    }

    // MARK: - Step 2: Workspace Selection

    private var workspaceStepView: some View {
        VStack(alignment: .leading, spacing: 14) {
            InfoCard("选择代码目录") {
                Text("选择要让手机浏览和协作的代码目录（空目录也可以先保存）。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(store.selectedScanRoot?.path ?? "尚未选择目录")
                        .font(.callout.monospaced())
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button("选择…") {
                        store.pendingPathPicker = .workspaceRoot
                    }
                    .disabled(store.isSavingSetup)
                }

                Divider().opacity(0.4)

                VStack(alignment: .leading, spacing: 4) {
                    if let browseRoot = store.effectiveBrowseRoot {
                        KeyValueRow(key: "手机可浏览范围", value: browseRoot.path)
                    }
                    Text(store.persistedBrowseRoot == nil
                         ? "按最小权限原则，新安装默认只授权手机访问所选代码目录，不会开放整个个人目录。完成后可在“设置”中按需扩大范围。"
                         : "已保留原有配置中的代码浏览范围；不会覆盖既有授权或宿主配对身份。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if store.needsCreateDirectoryConfirmation, let path = store.selectedScanRoot?.path {
                InfoCard("目录尚未创建") {
                    Text("所选路径 \(path) 目前还不存在。是否现在创建该文件夹并继续保存配置？")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button("创建并保存") {
                            Task { await store.saveWorkspaceAndContinue(confirmCreateMissingDirectory: true) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.isSavingSetup)

                        Button("取消") {
                            store.cancelCreateDirectoryConfirmation()
                        }
                        .disabled(store.isSavingSetup)
                    }
                }
            }

            if let stepError = store.stepError {
                OnboardingDiagnosticBanner(
                    diagnostic: stepError,
                    isWorking: store.isSavingSetup || store.isCheckingPreflight,
                    onPrimaryAction: { Task { await store.performDiagnosticAction(stepError) } },
                    onRetry: { Task { await store.runPreflight(stage: .setup) } }
                )
            }

            if let recovery = store.recoveryDiagnostic {
                OnboardingRecoveryCard(diagnostic: recovery)
            }

            HStack {
                Button("返回") {
                    Task { await store.goBack() }
                }
                .disabled(store.isSavingSetup)

                Button("重新检查") {
                    Task { await store.runPreflight(stage: .setup) }
                }
                .disabled(store.isSavingSetup || store.isCheckingPreflight)

                Spacer()

                Button(store.hasCommittedCurrentDraft ? "继续：后台服务与权限" : "保存并继续") {
                    Task { await store.saveWorkspaceAndContinue() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.canProceedFromWorkspaceSelection)
            }
        }
    }

    // MARK: - Step 4: Connect Phone

    private var connectPhoneStepView: some View {
        VStack(alignment: .leading, spacing: 14) {
            if store.isServiceRequiresApproval {
                // 后台 agent 审批中：仅展示「打开登录项设置…」与「重新检查」，严禁显示二维码、复制链接或跳过出码。
                serviceApprovalGateCard
            } else {
                if let warning = store.mainAppLoginItemWarning {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(warning)
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("打开登录项设置…") {
                                Task {
                                    await store.performDiagnosticAction(OnboardingResolvedDiagnostic(
                                        code: "permission_login_item_disabled",
                                        step: .permissionLoginItem,
                                        message: warning,
                                        primaryAction: .openSettings(.loginItems),
                                        secondaryAction: nil,
                                        secondaryLabel: nil,
                                        configPath: nil,
                                        recoveryPath: nil,
                                        isTrusted: true,
                                        isLegacyHost: false
                                    ))
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                InfoCard("选择手机连接方式") {
                    Picker(
                        "连接方式",
                        selection: Binding(
                            get: { store.selectedTransport },
                            set: { store.selectTransport($0) }
                        )
                    ) {
                        ForEach(store.orderedTransports, id: \.self) { transport in
                            Text(transportLabel(transport)).tag(transport)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(store.isEnablingTransport)

                    Text(transportCaption(store.selectedTransport))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if store.isCheckingPreflight && store.report == nil {
                    InfoCard("正在检查配对条件") {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在核对服务、助手与连接通道状态…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if !store.canIssuePairingQR {
                    pairPrerequisitesRepairCard
                } else if !store.isTransportReady(store.selectedTransport) {
                    selectedTransportActionCard
                } else {
                    pairingQRCard
                }
            }

            if let preflightError = store.preflightError {
                OnboardingDiagnosticBanner(
                    diagnostic: preflightError,
                    isWorking: store.isCheckingPreflight,
                    onPrimaryAction: { Task { await store.performDiagnosticAction(preflightError) } },
                    onRetry: { Task { await store.runPreflight(stage: .pair) } }
                )
            }

            HStack {
                Button("返回") {
                    Task { await store.goBack() }
                }
                .disabled(store.isEnablingTransport || store.isIssuingPairing)

                Button("重新检查") {
                    Task { await store.runPreflight(stage: .pair) }
                }
                .disabled(store.isCheckingPreflight || store.isEnablingTransport)

                Spacer()

                if store.canCompleteWizard {
                    Button("完成设置") {
                        Task { await store.finishWizard() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var serviceApprovalGateCard: some View {
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
                    Task {
                        await store.performDiagnosticAction(OnboardingResolvedDiagnostic(
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
                        ))
                    }
                }
                .buttonStyle(.borderedProminent)

                Button("重新检查") {
                    Task { await store.runPreflight(stage: .pair) }
                }
                .disabled(store.isCheckingPreflight)
            }
        }
    }

    private var pairPrerequisitesRepairCard: some View {
        InfoCard("配对前需要完成以下检查") {
            ForEach(store.blockingPairChecks) { check in
                OnboardingCheckRowView(store: store, check: check)
                if check.id == .assistantAny {
                    ForEach(store.assistantChecks.filter { $0.state != .ok }) { assistant in
                        OnboardingCheckRowView(store: store, check: assistant)
                            .padding(.leading, 14)
                    }
                }
                if check.id == .networkAny {
                    ForEach(store.networkChecks.filter { $0.state != .ok }) { network in
                        OnboardingCheckRowView(store: store, check: network)
                            .padding(.leading, 14)
                    }
                }
                if check.id != store.blockingPairChecks.last?.id {
                    Divider().opacity(0.35)
                }
            }
            if store.check(for: .networkAny)?.blocking == true,
               store.isTransportAvailableButDisabled(store.selectedTransport) {
                Divider().opacity(0.35)
                Button("启用\(store.selectedTransport.localizedTitle)") {
                    Task { await store.enableSelectedTransportAndIssueQR(store.selectedTransport) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isEnablingTransport)
            }
        }
    }

    private var selectedTransportActionCard: some View {
        InfoCard("\(store.selectedTransport.localizedTitle) 尚未启用") {
            if let transportCheck = store.check(for: store.selectedTransport.checkID) {
                OnboardingCheckRowView(store: store, check: transportCheck)
            }
            if store.isTransportAvailableButDisabled(store.selectedTransport) {
                Button("启用\(store.selectedTransport.localizedTitle)") {
                    Task { await store.enableSelectedTransportAndIssueQR(store.selectedTransport) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isEnablingTransport)
            }
        }
    }

    private var pairingQRCard: some View {
        InfoCard("扫码连接手机") {
            if store.isIssuingPairing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在生成配对二维码…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 12)
            } else if let pairing = store.issuedPairing, let pairURL = pairing.pairURL, !pairURL.isEmpty, !store.isIssuedPairingExpired {
                VStack(spacing: 12) {
                    Text("在 iPhone 或 iPad 上打开 mimi（App Store 里叫 Mimi Remote），扫描下方二维码；也可以复制配对链接到手机粘贴。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    QRCodeView(value: pairURL, size: 204)
                        .padding(12)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(.black.opacity(0.08), lineWidth: 1)
                        }

                    if !pairing.expiresAt.isEmpty {
                        PairingExpiryStatus(rawValue: pairing.expiresAt)
                    }

                    HStack(spacing: 10) {
                        Button(store.didCopyPairingLink ? "已复制" : "复制配对链接") {
                            _ = store.copyPairingLink()
                        }
                        .disabled(!store.canCopyPairingLink)

                        Button("刷新二维码") {
                            Task { await store.issuePairingQR(for: store.selectedTransport) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.isIssuingPairing)
                    }
                }
                .frame(maxWidth: .infinity)
            } else if let pairingError = store.pairingError {
                OnboardingDiagnosticBanner(
                    diagnostic: pairingError,
                    isWorking: store.isIssuingPairing,
                    onPrimaryAction: { Task { await store.performDiagnosticAction(pairingError) } },
                    onRetry: { Task { await store.issuePairingQR(for: store.selectedTransport) } }
                )
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(store.isIssuedPairingExpired ? "当前二维码已过期，请点击刷新重新生成。" : "服务与通道已就绪，点击生成配对二维码。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("生成二维码") {
                        Task { await store.issuePairingQR(for: store.selectedTransport) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isIssuingPairing)
                }
            }
        }
    }

    // MARK: - DeepSeek Connect Sheet

    private var deepSeekConnectSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("连接 DeepSeek Harness")
                .font(.headline)
            Text("粘贴终端中 `dsh web` 输出的启动链接，链接仅通过标准输入传给 agentd 验证。")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Harness 启动链接（可选，留空则自动检测）", text: $deepSeekStartupURL)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") {
                    deepSeekStartupURL = ""
                    store.presentsDeepSeekConnectForm = false
                }
                Button("验证并连接") {
                    let link = deepSeekStartupURL
                    deepSeekStartupURL = ""
                    Task { await store.submitDeepSeekConnection(startupURL: link) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isApplyingFix)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func transportLabel(_ transport: OnboardingTransport) -> String {
        if store.report?.recommendedTransport == transport {
            return "\(transport.localizedTitle)（推荐）"
        }
        return transport.localizedTitle
    }

    private func transportCaption(_ transport: OnboardingTransport) -> String {
        switch transport {
        case .tailscale:
            "已连接 Tailscale 时优先推荐，支持跨网络稳定直连。"
        case .tailcat:
            "内置连接免费可用，支持跨网穿透，无需安装其他工具。"
        case .lan:
            "手机和电脑需处于同一受信任局域网。"
        }
    }
}
