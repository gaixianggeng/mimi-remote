import SwiftUI

struct OnboardingChecklistStepView: View {
    let store: OnboardingStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            summaryBanner

            if let preflightError = store.preflightError {
                OnboardingDiagnosticBanner(
                    diagnostic: preflightError,
                    isWorking: store.isCheckingPreflight || store.isApplyingFix,
                    onPrimaryAction: { Task { await store.performDiagnosticAction(preflightError) } },
                    onRetry: { Task { await store.runPreflight(stage: .setup) } }
                )
            }

            if let stepError = store.stepError {
                OnboardingDiagnosticBanner(
                    diagnostic: stepError,
                    isWorking: store.isCheckingPreflight || store.isApplyingFix,
                    onPrimaryAction: { Task { await store.performDiagnosticAction(stepError) } },
                    onRetry: { Task { await store.runPreflight(stage: .setup) } }
                )
            }

            if let configCheck = store.check(for: .configStore), configCheck.state != .ok {
                InfoCard("配置文件") {
                    OnboardingCheckRowView(store: store, check: configCheck)
                }
            }

            InfoCard("AI 编程助手") {
                if let summary = store.check(for: .assistantAny) {
                    OnboardingAggregateBadgeRow(store: store, check: summary)
                    Divider().opacity(0.4)
                }
                if store.assistantChecks.isEmpty {
                    loadingPlaceholder("正在检查已安装的 AI 编程助手…")
                } else {
                    ForEach(store.assistantChecks) { check in
                        OnboardingCheckRowView(store: store, check: check)
                        if check.id != store.assistantChecks.last?.id {
                            Divider().opacity(0.35)
                        }
                    }
                }
            }

            InfoCard("手机连接方式") {
                if let summary = store.check(for: .networkAny) {
                    OnboardingAggregateBadgeRow(store: store, check: summary)
                    Divider().opacity(0.4)
                }
                if store.networkChecks.isEmpty {
                    loadingPlaceholder("正在检查可用的网络连接方式…")
                } else {
                    ForEach(store.networkChecks) { check in
                        OnboardingCheckRowView(store: store, check: check)
                        if check.id != store.networkChecks.last?.id {
                            Divider().opacity(0.35)
                        }
                    }
                }
            }

            if let recovery = store.recoveryDiagnostic {
                OnboardingRecoveryCard(diagnostic: recovery)
            }

            HStack {
                Button("重新检查") {
                    Task { await store.runPreflight(stage: .setup) }
                }
                .disabled(store.isCheckingPreflight || store.isApplyingFix)

                Spacer()

                Button("下一步：选择代码目录") {
                    Task { await store.proceedToWorkspaceStep() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.canProceedFromEnvironmentCheck || store.isApplyingFix)
            }
        }
    }

    private var summaryBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            if store.isCheckingPreflight {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 2)
            } else {
                Image(systemName: store.canProceedFromEnvironmentCheck ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(store.canProceedFromEnvironmentCheck ? Color.mimiSuccess : Color.orange)
                    .padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(store.isCheckingPreflight ? "正在逐项检查本机环境…" : "环境检查结果")
                    .font(.headline)
                Text(summaryCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var summaryCaption: String {
        if store.isCheckingPreflight {
            return "每项检查完成后会立即更新，不会修改本机配置或启动后台服务。"
        }
        if let configCheck = store.check(for: .configStore), configCheck.blocking {
            return "请先处理配置文件问题，再继续选择代码目录。"
        }
        if store.check(for: .assistantAny)?.state != .ok {
            return "当前还没有就绪的助手。您仍可先保存代码目录并启动后台服务，稍后再安装或登录任一助手。"
        }
        return "只要有任意一个助手就绪即可配对手机；未使用的助手可以直接跳过。"
    }

    private func loadingPlaceholder(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct OnboardingAggregateBadgeRow: View {
    let store: OnboardingStore
    let check: OnboardingCheck

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            OnboardingStateIcon(state: check.state)
            Text(displayMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if check.blocking {
                Text("阻断")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red.opacity(0.12), in: Capsule())
            }
        }
    }

    private var displayMessage: String {
        if check.state == .ok {
            return check.id == .assistantAny ? "至少有一个可用助手已就绪。" : "至少有一种可用连接方式已就绪。"
        }
        if check.state == .checking {
            return "正在汇总\(check.id.localizedTitle)…"
        }
        return store.diagnostic(for: check)?.message ?? OnboardingCopyCatalog.safeFallbackCopy
    }
}

struct OnboardingCheckRowView: View {
    let store: OnboardingStore
    let check: OnboardingCheck
    @State private var expandsCandidates = false

    var body: some View {
        let resolved = store.diagnostic(for: check)
        let isSkipped = store.skippedCheckIDs.contains(check.id)

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                OnboardingStateIcon(state: check.state)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(check.id.localizedTitle)
                            .font(.callout.weight(.semibold))
                        if let version = check.selectedOrDetectedVersion, !version.isEmpty {
                            Text("v\(version)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.1), in: Capsule())
                        }
                        if check.source == .pin {
                            Text("已手动指定")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.blue.opacity(0.1), in: Capsule())
                        }
                        if check.blocking {
                            Text("需先处理")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.red)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.red.opacity(0.12), in: Capsule())
                        } else if isSkipped {
                            Text("已跳过")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.1), in: Capsule())
                        }
                    }

                    Text(rowMessage(resolved: resolved))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    actionBar(resolved: resolved)
                }

                Spacer(minLength: 0)
            }

            if let candidates = check.candidates, !candidates.isEmpty {
                DisclosureGroup("已检查的位置（\(candidates.count)）", isExpanded: $expandsCandidates) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(candidates.enumerated()), id: \.offset) { _, candidate in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(candidate.path)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 6)
                                if let version = candidate.version, !version.isEmpty {
                                    Text(version)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.tertiary)
                                }
                                Text(OnboardingActionLabels.candidateOutcome(candidate.outcome))
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(candidate.outcome == .selected ? Color.mimiSuccess : .secondary)
                            }
                        }
                    }
                    .padding(.top, 4)
                    .padding(.leading, 22)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func rowMessage(resolved: OnboardingResolvedDiagnostic?) -> String {
        if check.state == .checking {
            return "正在检查\(check.id.localizedTitle)…"
        }
        if check.state == .ok {
            return resolved?.message ?? "\(check.id.localizedTitle)已就绪。"
        }
        return resolved?.message ?? OnboardingCopyCatalog.safeFallbackCopy
    }

    @ViewBuilder
    private func actionBar(resolved: OnboardingResolvedDiagnostic?) -> some View {
        let primaryFix = (resolved?.isTrusted == true) ? resolved?.primaryAction : nil
        let secondaryFix = (resolved?.isTrusted == true) ? resolved?.secondaryAction : nil
        let canResetPin = store.canResetRuntimePin(for: check)
        let manualRuntimeTarget = manualPathTarget(primaryFix: primaryFix)

        if primaryFix != nil || secondaryFix != nil || canResetPin || manualRuntimeTarget != nil {
            HStack(spacing: 8) {
                if let primaryFix {
                    Button(OnboardingActionLabels.primaryTitle(
                        for: primaryFix,
                        code: resolved?.code,
                        isConfigured: store.isConfigured
                    )) {
                        Task { await store.performCheckPrimaryAction(for: check) }
                    }
                    .controlSize(.small)
                    .disabled(store.isApplyingFix || store.isSavingSetup)
                }

                if let secondaryFix {
                    Button(resolved?.secondaryLabel ?? OnboardingActionLabels.primaryTitle(
                        for: secondaryFix,
                        code: resolved?.code,
                        isConfigured: store.isConfigured
                    )) {
                        Task { await store.performCheckSecondaryAction(for: check) }
                    }
                    .controlSize(.small)
                    .disabled(store.isCheckingPreflight || store.isApplyingFix)
                }

                if canResetPin, let runtimeID = OnboardingStore.runtimeID(for: check.id) {
                    Button("恢复自动检测") {
                        Task { await store.resetRuntimePathToAuto(for: runtimeID) }
                    }
                    .controlSize(.small)
                    .disabled(store.isCheckingPreflight || store.isApplyingFix)
                }

                if let target = manualRuntimeTarget, let runtimeID = OnboardingStore.runtimeID(for: check.id) {
                    Button("手动选择路径…") {
                        store.pendingPathPicker = .runtimeBinary(runtimeID: runtimeID, target: target)
                    }
                    .controlSize(.small)
                    .disabled(store.isCheckingPreflight || store.isApplyingFix)
                }
            }
            .padding(.top, 2)
        }
    }

    private func manualPathTarget(primaryFix: OnboardingFix?) -> OnboardingPathTarget? {
        guard check.id.isCLIAssistant, check.state != .ok, check.state != .checking else {
            return nil
        }
        if case .choosePath = primaryFix {
            return nil
        }
        switch check.id {
        case .assistantCodex: return .codexBin
        case .assistantClaude: return .claudeBin
        case .assistantAgy: return .agyBin
        default: return nil
        }
    }
}

struct OnboardingStateIcon: View {
    let state: OnboardingCheckState

    var body: some View {
        switch state {
        case .checking:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 14, height: 14)
        case .ok:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.mimiSuccess)
        case .optional:
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
        case .actionNeeded:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
}

struct OnboardingDiagnosticBanner: View {
    let diagnostic: OnboardingResolvedDiagnostic
    let isWorking: Bool
    let onPrimaryAction: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .padding(.top, 1)
                Text(diagnostic.message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                if diagnostic.isTrusted, let fix = diagnostic.primaryAction {
                    Button(OnboardingActionLabels.primaryTitle(
                        for: fix,
                        code: diagnostic.code,
                        isConfigured: true
                    ), action: onPrimaryAction)
                    .controlSize(.small)
                    .disabled(isWorking)
                }
                if diagnostic.primaryAction != .retry {
                    Button("重新检查", action: onRetry)
                        .controlSize(.small)
                        .disabled(isWorking)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.22), lineWidth: 1)
        }
    }
}

struct OnboardingRecoveryCard: View {
    let diagnostic: OnboardingResolvedDiagnostic

    var body: some View {
        InfoCard("只读配置恢复信息") {
            Text(diagnostic.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let configPath = diagnostic.configPath {
                KeyValueRow(key: "保留的配置", value: configPath)
            }
            if let recoveryPath = diagnostic.recoveryPath {
                KeyValueRow(key: "恢复参考位置", value: recoveryPath)
            }
            Text("当前向导不会自动覆盖配置或轮换宿主配对身份，原文件已保留。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

enum OnboardingActionLabels {
    static func primaryTitle(
        for fix: OnboardingFix,
        code: String?,
        isConfigured: Bool
    ) -> String {
        switch fix {
        case .openURL(let url):
            if code?.hasSuffix("_signed_out") == true {
                return "打开登录说明"
            }
            switch url {
            case .desktop: return "下载桌面端"
            case .guide: return "打开快速开始说明"
            case .tailscale: return "打开 Tailscale 说明"
            default: return "打开安装说明"
            }
        case .openSettings(let target):
            switch target {
            case .loginItems: return "打开登录项设置…"
            case .filesAndFolders: return "打开文件与文件夹设置…"
            case .localNetwork: return "打开本地网络设置…"
            case .photos: return "打开照片权限设置…"
            case .fullDiskAccess: return "打开完全磁盘访问设置…"
            case .dateTime: return "打开日期与时间设置…"
            case .connections: return "前往连接手机"
            case .assistants: return "查看助手检查"
            case .hostRecovery: return "查看恢复信息"
            case .windowsFirewall, .windowsNetworkProfile, .managedConnection: return "查看设置"
            }
        case .choosePath(let target):
            switch target {
            case .workspaceRoot: return "选择代码目录…"
            case .codexBin, .claudeBin, .agyBin: return "选择程序路径…"
            }
        case .runFix(let action):
            switch action {
            case .saveSetup: return "前往保存设置"
            case .enableCodex, .enableClaude, .enableAgy:
                return isConfigured ? "启用助手" : "设为默认启用"
            case .enableTailscale: return "启用 Tailscale"
            case .enableTailcat: return "启用内置连接"
            case .enableLAN: return "启用同一局域网"
            case .connectDeepSeek: return "连接 DeepSeek…"
            case .registerService: return "登记并启动服务"
            case .restartService: return "重新启动服务"
            case .doctorFix: return "修复配置权限"
            case .takeoverHomebrew: return "接管为桌面端服务…"
            }
        case .retry:
            return "重新检查"
        case .skip:
            return "跳过此项"
        }
    }

    static func candidateOutcome(_ outcome: OnboardingCandidateOutcome) -> String {
        switch outcome {
        case .missing: "未找到"
        case .unusable: "不可执行"
        case .unsupported: "版本不支持"
        case .compatible: "兼容"
        case .selected: "已选中"
        case .timeout: "检测超时"
        }
    }
}
