import SwiftUI

struct OnboardingPermissionsStepView: View {
    let store: OnboardingStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            milestonesCard
            serviceStatusCard

            InfoCard("系统权限") {
                Text("以下权限仅在需要时生效；主应用登录项、照片和完全磁盘访问均为可选项，不会阻断普通代码目录配对。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if store.permissionChecks.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在读取本机权限状态…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    ForEach(store.permissionChecks) { check in
                        OnboardingCheckRowView(store: store, check: check)
                        if check.id == .permissionPhotos, check.state == .optional, check.code == "permission_unobserved" {
                            Button("请求照片访问权限（可选）") {
                                Task { await store.requestPhotosAccess() }
                            }
                            .controlSize(.small)
                            .padding(.leading, 24)
                        }
                        if check.id != store.permissionChecks.last?.id {
                            Divider().opacity(0.35)
                        }
                    }
                }
            }

            if let stepError = store.stepError {
                OnboardingDiagnosticBanner(
                    diagnostic: stepError,
                    isWorking: store.isStartingService || store.isCheckingPreflight,
                    onPrimaryAction: { Task { await store.performDiagnosticAction(stepError) } },
                    onRetry: { Task { await store.ensureServiceReady() } }
                )
            }

            HStack {
                Button("返回") {
                    Task { await store.goBack() }
                }
                .disabled(store.isStartingService)

                Button("重新检查") {
                    Task { await store.runPreflight(stage: store.preflightStageForCurrentStep) }
                }
                .disabled(store.isStartingService || store.isCheckingPreflight)

                Spacer()

                Button("下一步：连接手机") {
                    Task { await store.proceedToConnectStep() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.isConfigured || store.isStartingService)
            }
        }
        .confirmationDialog(
            "改为由桌面端管理后台服务？",
            isPresented: Binding(
                get: { store.confirmsHomebrewTakeover },
                set: { store.confirmsHomebrewTakeover = $0 }
            ),
            titleVisibility: .visible
        ) {
            Button("确认接管") {
                Task { await store.confirmTakeoverHomebrew() }
            }
            Button("保持 Homebrew 管理", role: .cancel) {}
        } message: {
            Text("接管会复用现有配置与配对身份，停止 Homebrew 服务并改为由 Mimi Remote Mac 启动；如失败会自动恢复 Homebrew 服务。")
        }
    }

    private var milestonesCard: some View {
        InfoCard("后台服务启动进度") {
            HStack(spacing: 12) {
                milestoneItem(
                    title: "写入配置",
                    state: store.isConfigured ? .ok : .optional
                )
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                milestoneItem(
                    title: "登记后台服务",
                    state: registrationMilestoneState
                )
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                milestoneItem(
                    title: "等待就绪",
                    state: readinessMilestoneState
                )
            }
        }
    }

    @ViewBuilder
    private var serviceStatusCard: some View {
        switch store.servicePhase {
        case .ready:
            InfoCard("后台服务已就绪") {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.mimiSuccess)
                    Text("后台服务已运行并通过认证就绪检查，可以前往下一步连接手机。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

        case .homebrewActive:
            InfoCard("检测到 Homebrew 后台服务") {
                Text("当前由 Homebrew 运行的后台服务已健康可用，您可以直接沿用它继续连接手机；只有在需要改为由桌面端管理时再手动确认接管。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("沿用现有服务并继续") {
                        Task { await store.proceedToConnectStep() }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("接管为桌面端服务…") {
                        store.confirmsHomebrewTakeover = true
                    }
                    .disabled(store.isStartingService)
                }
            }

        case .requiresApproval:
            InfoCard("需要允许后台服务运行") {
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
                        Task { await store.runPreflight(stage: store.preflightStageForCurrentStep) }
                    }
                    .disabled(store.isCheckingPreflight)
                }
            }

        case .failed(let diagnostic):
            InfoCard("后台服务尚未就绪") {
                Text(diagnostic.message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text("配置已保留，重试只会重新启动后台服务，不会重复覆盖配置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button("重试启动服务") {
                        Task { await store.ensureServiceReady() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isStartingService)

                    if diagnostic.isTrusted, let fix = diagnostic.primaryAction, fix != .retry {
                        Button(OnboardingActionLabels.primaryTitle(
                            for: fix,
                            code: diagnostic.code,
                            isConfigured: store.isConfigured
                        )) {
                            Task { await store.performDiagnosticAction(diagnostic) }
                        }
                        .disabled(store.isStartingService)
                    }
                }
            }

        case .registeringService, .waitingForReadiness:
            InfoCard("正在启动后台服务") {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在登记并等待后台服务通过就绪检查…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

        case .idle, .configSaved:
            InfoCard("启动后台服务") {
                Text("配置已保存。点击下方按钮登记并检查后台服务状态。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("登记并启动服务") {
                    Task { await store.ensureServiceReady() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.isConfigured || store.isStartingService)
            }
        }
    }

    private func milestoneItem(title: String, state: OnboardingCheckState) -> some View {
        HStack(spacing: 6) {
            OnboardingStateIcon(state: state)
            Text(title)
                .font(.caption.weight(.medium))
        }
    }

    private var registrationMilestoneState: OnboardingCheckState {
        switch store.servicePhase {
        case .ready, .homebrewActive, .waitingForReadiness: .ok
        case .registeringService: .checking
        case .requiresApproval: .actionNeeded
        case .failed: .error
        case .idle, .configSaved: .optional
        }
    }

    private var readinessMilestoneState: OnboardingCheckState {
        switch store.servicePhase {
        case .ready, .homebrewActive: .ok
        case .registeringService, .waitingForReadiness: .checking
        case .requiresApproval: .actionNeeded
        case .failed: .error
        case .idle, .configSaved: .optional
        }
    }
}
