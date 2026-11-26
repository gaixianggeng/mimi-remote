import Foundation

extension HostStore {
#if DEBUG
    static func preview(_ lifecycle: HostLifecycleState) -> HostStore {
        let check = AgentCheck(name: "codex", ok: true, level: "", message: "Codex CLI 可执行", fix: nil)
        let doctor = AgentDoctorResults(ok: true, version: "0.1.0", listen: "mimi-demo.local:8787", checks: [check])
        let status = AgentStatus(
            processOK: true,
            serviceOK: true,
            processError: nil,
            serviceError: nil,
            version: "0.1.0+mac.240",
            serverVersion: "0.1.0+mac.240",
            endpoint: "http://mimi-demo.local:8787",
            configPath: "~/Library/Application Support/mimi-remote/config.json",
            projects: 12,
            doctorOK: true,
            doctor: doctor,
            pairExpires: nil,
            runtimeStatus: AgentRuntimeStatusSnapshot(
                checkedAt: ISO8601DateFormatter().string(from: Date()),
                runtimes: [
                    AgentRuntimeStatus(
                        id: "codex",
                        title: "Codex",
                        enabled: true,
                        state: .connected,
                        version: "0.146.0-alpha.3.1",
                        startedAt: ISO8601DateFormatter().string(
                            from: Date().addingTimeInterval(-49 * 60 * 60)
                        ),
                        authMode: "chatgpt",
                        planType: "plus",
                        reason: nil,
                        rateLimits: AgentRuntimeRateLimits(
                            limitID: "codex",
                            limitName: "Codex",
                            planType: "plus",
                            reachedType: nil,
                            availability: "available",
                            unavailableReason: nil,
                            primary: AgentRuntimeRateLimitWindow(
                                usedPercent: 62,
                                windowDurationMins: 300,
                                resetsAt: Int64(Date().addingTimeInterval(80 * 60).timeIntervalSince1970)
                            ),
                            secondary: AgentRuntimeRateLimitWindow(
                                usedPercent: 31,
                                windowDurationMins: 10_080,
                                resetsAt: Int64(Date().addingTimeInterval(4 * 24 * 60 * 60).timeIntervalSince1970)
                            ),
                            hasCredits: true,
                            creditsUnlimited: false,
                            creditBalance: "12.34"
                        )
                    ),
                    AgentRuntimeStatus(
                        id: "claude",
                        title: "Claude",
                        enabled: true,
                        state: .connected,
                        version: "0.2.6",
                        startedAt: ISO8601DateFormatter().string(
                            from: Date().addingTimeInterval(-7.5 * 60 * 60)
                        ),
                        authMode: "oauth",
                        planType: "pro",
                        reason: nil,
                        rateLimits: AgentRuntimeRateLimits(
                            limitID: "claude",
                            limitName: "Claude",
                            planType: "pro",
                            reachedType: nil,
                            availability: "available",
                            unavailableReason: nil,
                            primary: AgentRuntimeRateLimitWindow(
                                usedPercent: 24,
                                windowDurationMins: 300,
                                resetsAt: Int64(Date().addingTimeInterval(3 * 60 * 60).timeIntervalSince1970)
                            ),
                            secondary: AgentRuntimeRateLimitWindow(
                                usedPercent: 48,
                                windowDurationMins: 10_080,
                                resetsAt: Int64(Date().addingTimeInterval(5 * 24 * 60 * 60).timeIntervalSince1970)
                            ),
                            hasCredits: nil,
                            creditsUnlimited: nil,
                            creditBalance: nil
                        )
                    ),
                ]
            )
        )
        let previewExpiresAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(5 * 60))
        let agent = AgentCommandClient(
            configExists: { lifecycle != .notConfigured },
            setup: { _ in PairingInfo(endpoint: status.endpoint, pairURL: "mimiremote://pair?pair_sig=preview", expiresAt: previewExpiresAt, warnings: []) },
            status: { status },
            readiness: { status },
            statusAt: { _ in status },
            doctor: { _ in DoctorFixResults(fixes: [], results: doctor) },
            configureClaude: { preference, restoreEnabled in
                let enabled = restoreEnabled ?? (preference != .disabled)
                return ClaudeConfigurationResult(
                    enabled: enabled,
                    available: enabled,
                    preference: preference,
                    previousEnabled: true,
                    previousPreference: .enabled,
                    changed: false,
                    restartRequired: false,
                    reason: enabled ? "ready" : "disabled_by_user",
                    message: enabled
                        ? "已检测到 Claude Code 和兼容的 Claude bridge。"
                        : "Claude Code 模块已关闭。"
                )
            },
            setLANAccess: { enabled in
                NetworkConfigurationResult(
                    lanEnabled: enabled,
                    changed: false,
                    restartRequired: false
                )
            },
            pair: { network in
                let endpoint = network == .localNetwork ? "http://192.168.31.20:8787" : status.endpoint
                return PairingInfo(
                    endpoint: endpoint,
                    pairURL: "mimiremote://pair?pair_sig=preview-\(network.rawValue)",
                    expiresAt: previewExpiresAt,
                    warnings: network == .localNetwork ? ["局域网配对仅适用于与这台 Mac 位于同一局域网的设备"] : []
                )
            },
            version: { status.version },
            diagnosticsStatus: {
                AgentDiagnosticsStatus(
                    enabled: true,
                    expiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(12 * 60)),
                    currentBytes: 18_432,
                    previousBytes: 64_128,
                    totalBytes: 82_560,
                    maxTotalBytes: 10 * 1_048_576,
                    retentionDays: 7
                )
            },
            setDetailedDiagnostics: { enabled in
                AgentDiagnosticsStatus(
                    enabled: enabled,
                    expiresAt: enabled
                        ? ISO8601DateFormatter().string(from: Date().addingTimeInterval(15 * 60))
                        : nil,
                    currentBytes: 18_432,
                    previousBytes: 64_128, totalBytes: 82_560,
                    maxTotalBytes: 10 * 1_048_576, retentionDays: 7
                )
            },
            clearDiagnostics: {
                AgentDiagnosticsStatus(
                    enabled: false, expiresAt: nil, currentBytes: 0, previousBytes: 0,
                    totalBytes: 0, maxTotalBytes: 10 * 1_048_576, retentionDays: 7
                )
            }
        )
        let services = ServiceManagementClient(
            agentStatus: { .enabled },
            agentConfigurationError: { nil },
            isAgentRegistrationCurrent: { true },
            markAgentRegistrationCurrent: {},
            registerAgent: {},
            unregisterAgent: {},
            agentLaunchFailure: { nil },
            mainAppStatus: { .enabled }, registerMainApp: {}, unregisterMainApp: {},
            openLoginItemsSettings: {}
        )
        let homebrew = HomebrewServiceClient(
            isLoaded: { lifecycle == .migrationRequired }, installedAgentBinary: { nil },
            start: {}, stop: {}
        )
        let store = HostStore(
            agent: agent,
            services: services,
            homebrew: homebrew,
            health: HealthClient(check: { _ in true }, checkDirect: { _ in true }),
            logs: AgentLogClient(
                recentLines: { _ in [#"{"stage":"request","outcome":"failed","operation":"status"}"#] },
                exportLines: { [#"{"stage":"request","outcome":"failed","operation":"status"}"#] }
            )
        )
        store.lifecycle = lifecycle
        if lifecycle != .notConfigured {
            store.status = status
            store.doctor = doctor
            store.owner = lifecycle == .migrationRequired ? .homebrew : .macApp
        }
        return store
    }
#endif

}
