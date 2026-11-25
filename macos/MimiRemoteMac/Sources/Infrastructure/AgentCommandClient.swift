import Foundation

enum AgentCommandTimeouts {
    static let preflight: Duration = .seconds(35)
    static let setup: Duration = .seconds(60)
    static let pair: Duration = .seconds(45)
    static let runtime: Duration = .seconds(60)
    static let deepSeekRuntime: Duration = .seconds(45)
    static let network: Duration = .seconds(45)
    static let workspace: Duration = .seconds(45)
    static let doctorFix: Duration = .seconds(90)
    static let tailcatControl: Duration = .seconds(45)
    static let serviceWait: Duration = .seconds(110)

    static func duration(for command: String) -> Duration {
        switch command {
        case "preflight": preflight
        case "setup": setup
        case "pair", "tailcat pair": pair
        case "runtime": runtime
        case "network": network
        case "workspace": workspace
        case "doctor --fix": doctorFix
        case "up", "start", "restart": serviceWait
        default: .seconds(45)
        }
    }
}

struct OnboardingPreflightOptions: Equatable, Sendable {
    var stage: OnboardingStage = .setup
    var configPath: String? = nil
    var scanRoot: URL? = nil
    var browseRoot: URL? = nil
    var progressJSON: Bool = true
    var runtimePaths: [(id: String, value: String)] = []
    var assistants: [(id: String, value: String)] = []
    var verifiedConfigured: Bool? = nil
    var verifiedCapability: String? = nil

    static func == (lhs: OnboardingPreflightOptions, rhs: OnboardingPreflightOptions) -> Bool {
        lhs.stage == rhs.stage
            && lhs.configPath == rhs.configPath
            && lhs.scanRoot == rhs.scanRoot
            && lhs.browseRoot == rhs.browseRoot
            && lhs.progressJSON == rhs.progressJSON
            && lhs.runtimePaths.map { "\($0.id)=\($0.value)" } == rhs.runtimePaths.map { "\($0.id)=\($0.value)" }
            && lhs.assistants.map { "\($0.id)=\($0.value)" } == rhs.assistants.map { "\($0.id)=\($0.value)" }
            && lhs.verifiedConfigured == rhs.verifiedConfigured
            && lhs.verifiedCapability == rhs.verifiedCapability
    }
}

struct OnboardingSetupOptions: Equatable, Sendable {
    var browseRoot: URL? = nil
    var runtimePaths: [(id: String, value: String)] = []
    var assistants: [(id: String, value: String)] = []
    var verifiedConfigured: Bool? = nil

    static func == (lhs: OnboardingSetupOptions, rhs: OnboardingSetupOptions) -> Bool {
        lhs.browseRoot == rhs.browseRoot
            && lhs.runtimePaths.map { "\($0.id)=\($0.value)" } == rhs.runtimePaths.map { "\($0.id)=\($0.value)" }
            && lhs.assistants.map { "\($0.id)=\($0.value)" } == rhs.assistants.map { "\($0.id)=\($0.value)" }
            && lhs.verifiedConfigured == rhs.verifiedConfigured
    }
}

struct CodexSessionReleaseResult: Decodable, Equatable, Sendable {
    let released: Bool
    let message: String
}

struct AgentCommandClient: Sendable {
    var configExists: @Sendable () -> Bool
    var setup: @Sendable (_ workspaceRoot: URL) async throws -> PairingInfo
    var preflight: @Sendable (
        _ options: OnboardingPreflightOptions,
        _ onProgress: (@Sendable (OnboardingCheck) -> Void)?
    ) async throws -> OnboardingPreflightReport = { _, _ in
        throw AgentClientError.commandFailed("当前 agentd 不支持预检命令，请更新 App。")
    }
    var setupNoPair: @Sendable (
        _ workspaceRoot: URL,
        _ options: OnboardingSetupOptions
    ) async throws -> SetupReceipt = { _, _ in
        throw AgentClientError.commandFailed("当前 agentd 不支持无票保存设置，请更新 App。")
    }
    var up: @Sendable (_ waitSeconds: Int) async throws -> UpReadinessReceipt = { _ in
        throw AgentClientError.commandFailed("当前 agentd 不支持就绪启动检查，请更新 App。")
    }
    var status: @Sendable () async throws -> AgentStatus
    var readiness: @Sendable () async throws -> AgentStatus
    var statusAt: @Sendable (_ binary: URL) async throws -> AgentStatus
    var doctor: @Sendable (_ fix: Bool) async throws -> DoctorFixResults
    /// 生成在本机终端继续会话的命令（#991）。旧版内嵌 agentd 没有这个子命令。
    var terminalHandoffCommand: @Sendable (
        _ runtime: SessionRuntime,
        _ threadID: String,
        _ cwd: String
    ) async throws -> TerminalHandoffCommand = { _, _, _ in
        throw AgentClientError.commandFailed("请更新 Mimi Remote Mac 后再在终端继续。")
    }
    var releaseCodexSession: @Sendable () async throws -> CodexSessionReleaseResult = {
        throw AgentClientError.commandFailed("当前 agentd 不支持共享运行环境修复，请更新 App。")
    }
    var uninstallCodexFrontDoor: @Sendable () async throws -> Void = {}
    var codexRuntimeVersions: @Sendable () async throws -> CodexRuntimeVersions = {
        throw AgentClientError.commandFailed("请更新 Mimi Remote Mac 后检查 Codex 版本。")
    }
    var updateCodexRuntime: @Sendable (_ restart: Bool) async throws -> CodexRuntimeVersions = { _ in
        throw AgentClientError.commandFailed("请更新 Mimi Remote Mac 后切换 Codex 版本。")
    }
    var configureClaude: @Sendable (
        _ preference: ClaudeActivationPreference,
        _ restoreEnabled: Bool?
    ) async throws -> ClaudeConfigurationResult
    var restoreClaude: @Sendable (ClaudeConfigurationResult) async throws -> ClaudeConfigurationResult = { _ in
        throw AgentClientError.commandFailed("当前 agentd 不支持 Claude 配置恢复。")
    }
    var configureClaudeTurnHints: @Sendable (Bool) async throws -> ClaudeTurnHintsConfigurationResult = { _ in
        throw AgentClientError.commandFailed("当前 agentd 不支持 Claude 提示卡设置。")
    }
    var restoreClaudeTurnHints: @Sendable (ClaudeTurnHintsConfigurationResult) async throws -> ClaudeTurnHintsConfigurationResult = { _ in
        throw AgentClientError.commandFailed("当前 agentd 不支持 Claude 提示卡设置恢复。")
    }
    var configureAgy: @Sendable (
        _ preference: ClaudeActivationPreference,
        _ restoreEnabled: Bool?
    ) async throws -> AgyConfigurationResult = { _, _ in
        throw AgentClientError.commandFailed("当前 agentd 不支持 Antigravity 模块控制，请更新并重启服务。")
    }
    var restoreAgy: @Sendable (AgyConfigurationResult) async throws -> AgyConfigurationResult = { _ in
        throw AgentClientError.commandFailed("当前 agentd 不支持 Antigravity 配置恢复。")
    }
    var setLANAccess: @Sendable (_ enabled: Bool) async throws -> NetworkConfigurationResult
    var pair: @Sendable (_ network: PairingNetwork) async throws -> PairingInfo
    var tailcatStatus: @Sendable () async throws -> TailcatStatus = {
        throw AgentClientError.commandFailed("当前 agentd 不支持 Tailcat 实验。")
    }
    var setTailcatEnabled: @Sendable (_ enabled: Bool) async throws -> TailcatStatus = { _ in
        throw AgentClientError.commandFailed("当前 agentd 不支持 Tailcat 实验。")
    }
    var configureTailcatDERPMap: @Sendable (_ derpMapURL: String) async throws -> TailcatStatus = { _ in
        throw AgentClientError.commandFailed("当前 agentd 不支持 Tailcat 中继配置。")
    }
    var resetTailcat: @Sendable () async throws -> TailcatStatus = {
        throw AgentClientError.commandFailed("当前 agentd 不支持 Tailcat 实验。")
    }
    var setTailcatManagedMode: @Sendable (_ managed: Bool) async throws -> TailcatStatus = { _ in
        throw AgentClientError.commandFailed("当前电脑端不支持 Mimi 中转，请更新后重试。")
    }
    var setTailcatRelay: @Sendable (_ choice: String, _ url: String) async throws -> TailcatStatus = { _, _ in
        throw AgentClientError.commandFailed("当前电脑端不支持统一中转设置，请更新后重试。")
    }
    var configureDeepSeek: @Sendable (
        _ action: DeepSeekConfigurationAction,
        _ startupURL: String?
    ) async throws -> DeepSeekConfigurationResult = { _, _ in
        throw AgentClientError.commandFailed("当前 agentd 不支持 DeepSeek 配置。")
    }
    var version: @Sendable () async throws -> String
    var configureCodex: @Sendable (String) async throws -> CodexConfigurationResult = { _ in
        throw AgentClientError.commandFailed("当前 agentd 不支持 Codex 模块控制，请更新并重启服务。")
    }
    var restoreCodex: @Sendable (CodexConfigurationResult) async throws -> CodexConfigurationResult = { _ in
        throw AgentClientError.commandFailed("当前 agentd 不支持 Codex 配置恢复。")
    }
    var configureNetwork: @Sendable (PairingNetwork, Bool) async throws -> NetworkConfigurationResult = { _, _ in
        throw AgentClientError.commandFailed("当前 agentd 不支持独立连接控制，请更新并重启服务。")
    }
    var restoreNetwork: @Sendable (NetworkConfigurationResult) async throws -> NetworkConfigurationResult = { _ in
        throw AgentClientError.commandFailed("当前 agentd 不支持连接配置恢复。")
    }
    var diagnosticsStatus: @Sendable () async throws -> AgentDiagnosticsStatus = {
        throw AgentClientError.commandFailed("当前 agentd 不支持诊断日志，请更新 App。")
    }
    var setDetailedDiagnostics: @Sendable (_ enabled: Bool) async throws -> AgentDiagnosticsStatus = { _ in
        throw AgentClientError.commandFailed("当前 agentd 不支持诊断日志，请更新 App。")
    }
    var clearDiagnostics: @Sendable () async throws -> AgentDiagnosticsStatus = {
        throw AgentClientError.commandFailed("当前 agentd 不支持诊断日志，请更新 App。")
    }
    var exportDiagnostics: @Sendable () async throws -> AgentDiagnosticsExport = {
        throw AgentClientError.commandFailed("当前 agentd 不支持诊断日志，请更新 App。")
    }
}

extension AgentCommandClient {
    static func live(
        executor: ProcessExecutor = .shared,
        bundle: Bundle = .main,
        binaryOverride: URL? = nil
    ) -> AgentCommandClient {
        let embeddedBinary = binaryOverride ?? bundle.url(forResource: "agentd", withExtension: nil)
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let configURL = homeDirectory
            .appending(path: "Library/Application Support/mimi-remote/config.json")
        let environment = ProcessEnvironment.userTooling

        @Sendable func requireEmbeddedBinary() throws -> URL {
            guard let embeddedBinary else {
                throw AgentClientError.embeddedBinaryMissing
            }
            return embeddedBinary
        }

        @Sendable func execute(
            binary: URL,
            arguments: [String],
            allowFailure: Bool = false,
            timeout: Duration = .seconds(15),
            forceKillAfterTimeout: Bool = false,
            standardInput: Data? = nil,
            outputLimit: Int = 1_048_576,
            errorContext: OnboardingValidationContext? = nil,
            activeStep: OnboardingCheckID = .serviceDaemon,
            onStderrLine: (@Sendable (String) -> Void)? = nil
        ) async throws -> CommandResult {
            let result: CommandResult
            do {
                result = try await executor.run(
                    executable: binary,
                    arguments: arguments,
                    timeout: timeout,
                    outputLimit: outputLimit,
                    environment: environment,
                    forceKillAfterTimeout: forceKillAfterTimeout,
                    standardInput: standardInput,
                    onStderrLine: onStderrLine
                )
            } catch ProcessExecutorError.timedOut {
                throw AgentClientError.onboarding(
                    OnboardingCopyCatalog.synthesizeLocal(code: "command_timeout", step: activeStep)
                )
            }
            if result.status != 0 && !allowFailure {
                let context = errorContext ?? OnboardingValidationContext(
                    surface: .cli,
                    platform: .macos,
                    stage: resolveStage(for: arguments),
                    configured: false
                )
                if let resolved = OnboardingCopyCatalog.resolveCLIError(
                    stdout: result.stdout,
                    stderr: result.stderr,
                    context: context
                ) {
                    throw AgentClientError.onboarding(resolved)
                }
                throw AgentClientError.onboarding(
                    OnboardingCopyCatalog.unknownCommandFallback(
                        exitCode: result.status,
                        step: activeStep,
                        rawStderr: result.stderrText
                    )
                )
            }
            return result
        }

        @Sendable func decode<T: Decodable>(_ type: T.Type, from result: CommandResult) throws -> T {
            do {
                return try JSONDecoder().decode(type, from: result.stdout)
            } catch {
                throw AgentClientError.invalidResponse(error.localizedDescription)
            }
        }

        @Sendable func runSetup(workspaceRoot: URL) async throws -> PairingInfo {
            let binary = try requireEmbeddedBinary()
            let result = try await execute(
                binary: binary,
                arguments: setupArguments(
                    workspaceRoot: workspaceRoot,
                    browseRoot: workspaceRoot
                ),
                timeout: AgentCommandTimeouts.setup,
                errorContext: OnboardingValidationContext(
                    surface: .cli,
                    platform: .macos,
                    stage: .setup,
                    configured: false
                ),
                activeStep: .configStore
            )
            let receipt = try decode(SetupReceipt.self, from: result)
            return receipt.asPairingInfo
        }

        @Sendable func runPreflight(
            options: OnboardingPreflightOptions,
            onProgress: (@Sendable (OnboardingCheck) -> Void)?
        ) async throws -> OnboardingPreflightReport {
            let binary = try requireEmbeddedBinary()
            let verifiedConfigured = options.verifiedConfigured ?? false
            let progressContext = OnboardingValidationContext(
                surface: .check,
                platform: .macos,
                stage: options.stage,
                configured: verifiedConfigured,
                verifiedCapability: options.verifiedCapability
            )
            let accumulator = OnboardingProgressAccumulator(generation: 1, context: progressContext)
            let stderrHandler: (@Sendable (String) -> Void)?
            if options.progressJSON {
                stderrHandler = { line in
                    guard let validated = accumulator.applyValidatedLine(line, generation: 1) else {
                        return
                    }
                    onProgress?(validated)
                }
            } else {
                stderrHandler = nil
            }
            let result = try await execute(
                binary: binary,
                arguments: preflightArguments(options: options),
                timeout: AgentCommandTimeouts.preflight,
                forceKillAfterTimeout: true,
                errorContext: OnboardingValidationContext(
                    surface: .cli,
                    platform: .macos,
                    stage: options.stage,
                    configured: verifiedConfigured,
                    verifiedCapability: options.verifiedCapability
                ),
                activeStep: .serviceDaemon,
                onStderrLine: stderrHandler
            )
            let report = try decode(OnboardingPreflightReport.self, from: result)
            switch OnboardingCopyCatalog.validateReport(
                report,
                platform: .macos,
                expectedStage: options.stage,
                verifiedCapability: options.verifiedCapability
            ) {
            case .success:
                accumulator.complete(with: report, generation: 1)
                return report
            case .failure(let error):
                throw AgentClientError.invalidResponse(error.localizedDescription)
            }
        }

        @Sendable func runSetupNoPair(
            workspaceRoot: URL,
            options: OnboardingSetupOptions
        ) async throws -> SetupReceipt {
            let binary = try requireEmbeddedBinary()
            let result = try await execute(
                binary: binary,
                arguments: setupNoPairArguments(workspaceRoot: workspaceRoot, options: options),
                timeout: AgentCommandTimeouts.setup,
                errorContext: OnboardingValidationContext(
                    surface: .cli,
                    platform: .macos,
                    stage: .setup,
                    configured: options.verifiedConfigured ?? false
                ),
                activeStep: .configStore
            )
            return try decode(SetupReceipt.self, from: result)
        }

        @Sendable func runUp(waitSeconds: Int) async throws -> UpReadinessReceipt {
            let binary = try requireEmbeddedBinary()
            let result = try await execute(
                binary: binary,
                arguments: upArguments(waitSeconds: waitSeconds),
                timeout: AgentCommandTimeouts.serviceWait,
                errorContext: OnboardingValidationContext(
                    surface: .cli,
                    platform: .macos,
                    stage: .pair,
                    configured: false
                ),
                activeStep: .serviceDaemon
            )
            return try decode(UpReadinessReceipt.self, from: result)
        }

        @Sendable func runPair(network: PairingNetwork) async throws -> PairingInfo {
            let binary = try requireEmbeddedBinary()
            let result = try await execute(
                binary: binary,
                arguments: pairArguments(network: network),
                timeout: AgentCommandTimeouts.pair,
                errorContext: OnboardingValidationContext(
                    surface: .cli,
                    platform: .macos,
                    stage: .pair,
                    configured: false
                ),
                activeStep: .networkAny
            )
            let receipt = try decode(PairingTicketReceipt.self, from: result)
            return receipt.asPairingInfo
        }

        return AgentCommandClient(
            configExists: {
                FileManager.default.fileExists(atPath: configURL.path)
            },
            setup: runSetup,
            preflight: runPreflight,
            setupNoPair: runSetupNoPair,
            up: runUp,
            status: {
                let binary = try requireEmbeddedBinary()
                return try decode(AgentStatus.self, from: try await execute(
                    binary: binary,
                    arguments: statusArguments(includeRuntime: true),
                    timeout: .seconds(8)
                ))
            },
            readiness: {
                let binary = try requireEmbeddedBinary()
                return try decode(AgentStatus.self, from: try await execute(
                    binary: binary,
                    arguments: statusArguments(includeRuntime: false),
                    timeout: .seconds(8)
                ))
            },
            statusAt: { binary in
                try decode(AgentStatus.self, from: try await execute(
                    binary: binary,
                    arguments: statusArguments(includeRuntime: false),
                    timeout: .seconds(8)
                ))
            },
            doctor: { fix in
                let binary = try requireEmbeddedBinary()
                var arguments = ["doctor", "--json"]
                if fix { arguments.append("--fix") }
                let result = try await execute(
                    binary: binary,
                    arguments: arguments,
                    allowFailure: true,
                    // Doctor --fix 可能等待服务诊断和配置提交，并在提交后重新跑
                    // 完整检查；给它覆盖事务上界的时间，避免配置已提交却因
                    // 客户端过早终止而漏掉 restart_required。
                    timeout: AgentCommandTimeouts.doctorFix,
                    activeStep: .configStore
                )
                if result.status != 0, OnboardingCopyCatalog.looksLikeErrorEnvelopeJSON(result.stdout) {
                    let doctorContext = OnboardingValidationContext(
                        surface: .cli,
                        platform: .macos,
                        stage: .pair,
                        configured: false
                    )
                    if let resolved = OnboardingCopyCatalog.resolveCLIError(
                        stdout: result.stdout,
                        stderr: result.stderr,
                        context: doctorContext
                    ) {
                        throw AgentClientError.onboarding(resolved)
                    }
                }
                if fix {
                    do {
                        return try decode(DoctorFixResults.self, from: result)
                    } catch {
                        if result.status != 0 {
                            let doctorContext = OnboardingValidationContext(
                                surface: .cli,
                                platform: .macos,
                                stage: .pair,
                                configured: false
                            )
                            if let resolved = OnboardingCopyCatalog.resolveCLIError(
                                stdout: result.stdout,
                                stderr: result.stderr,
                                context: doctorContext
                            ) {
                                throw AgentClientError.onboarding(resolved)
                            }
                            throw AgentClientError.onboarding(
                                OnboardingCopyCatalog.unknownCommandFallback(
                                    exitCode: result.status,
                                    step: .configStore,
                                    rawStderr: result.stderrText
                                )
                            )
                        }
                        throw error
                    }
                }
                let results = try decode(AgentDoctorResults.self, from: result)
                return DoctorFixResults(fixes: [], results: results)
            },
            terminalHandoffCommand: { runtime, threadID, cwd in
                let binary = try requireEmbeddedBinary()
                return try decode(TerminalHandoffCommand.self, from: try await execute(
                    binary: binary,
                    arguments: handoffCommandArguments(runtime: runtime, threadID: threadID, cwd: cwd)
                ))
            },
            releaseCodexSession: {
                let binary = try requireEmbeddedBinary()
                return try decode(CodexSessionReleaseResult.self, from: try await execute(
                    binary: binary,
                    arguments: codexSessionRepairArguments(),
                    timeout: .seconds(30),
                    forceKillAfterTimeout: true
                ))
            },
            uninstallCodexFrontDoor: {
                let binary = try requireEmbeddedBinary()
                _ = try await execute(
                    binary: binary,
                    arguments: ["codex-front", "uninstall", "--stop-idle-backend"],
                    timeout: .seconds(40)
                )
            },
            codexRuntimeVersions: {
                let binary = try requireEmbeddedBinary()
                return try decode(CodexRuntimeVersions.self, from: try await execute(
                    binary: binary, arguments: ["codex-front", "runtime"], timeout: .seconds(10)
                ))
            },
            updateCodexRuntime: { restart in
                let binary = try requireEmbeddedBinary()
                return try decode(CodexRuntimeVersions.self, from: try await execute(
                    binary: binary, arguments: ["codex-front", "update"] + (restart ? ["--restart"] : []), timeout: .seconds(60)
                ))
            },
            configureClaude: { preference, restoreEnabled in
                let binary = try requireEmbeddedBinary()
                return try decode(ClaudeConfigurationResult.self, from: try await execute(
                    binary: binary,
                    arguments: claudeConfigurationArguments(
                        preference: preference,
                        restoreEnabled: restoreEnabled
                    ),
                    timeout: .seconds(60)
                ))
            },
            restoreClaude: { previous in
                let binary = try requireEmbeddedBinary()
                guard previous.previous != nil, previous.applied != nil else {
                    throw AgentClientError.commandFailed("缺少原始 Claude 配置，不能安全回滚。")
                }
                let payload = String(decoding: try JSONEncoder().encode(previous), as: UTF8.self)
                return try decode(ClaudeConfigurationResult.self, from: try await execute(
                    binary: binary,
                    arguments: ["runtime", "--restore-claude", payload, "--json"],
                    timeout: .seconds(60)
                ))
            },
            configureClaudeTurnHints: { enabled in
                let binary = try requireEmbeddedBinary()
                return try decode(ClaudeTurnHintsConfigurationResult.self, from: try await execute(
                    binary: binary,
                    arguments: claudeTurnHintsConfigurationArguments(enabled: enabled),
                    timeout: .seconds(60)
                ))
            },
            restoreClaudeTurnHints: { previous in
                let binary = try requireEmbeddedBinary()
                let payload = String(decoding: try JSONEncoder().encode(previous), as: UTF8.self)
                return try decode(ClaudeTurnHintsConfigurationResult.self, from: try await execute(
                    binary: binary,
                    arguments: ["runtime", "--restore-claude-turn-hints", payload, "--json"],
                    timeout: .seconds(60)
                ))
            },
            configureAgy: { preference, restoreEnabled in
                let binary = try requireEmbeddedBinary()
                var arguments = ["runtime", "--agy=\(preference.rawValue)", "--json"]
                if let restoreEnabled {
                    arguments.append("--restore-enabled=\(restoreEnabled)")
                }
                return try decode(AgyConfigurationResult.self, from: try await execute(
                    binary: binary,
                    arguments: arguments,
                    timeout: .seconds(60)
                ))
            },
            restoreAgy: { previous in
                let binary = try requireEmbeddedBinary()
                guard previous.previous != nil, previous.applied != nil else {
                    throw AgentClientError.commandFailed("缺少原始 Antigravity 配置，不能安全回滚。")
                }
                let payload = String(decoding: try JSONEncoder().encode(previous), as: UTF8.self)
                return try decode(AgyConfigurationResult.self, from: try await execute(
                    binary: binary,
                    arguments: ["runtime", "--restore-agy", payload, "--json"],
                    timeout: .seconds(60)
                ))
            },
            setLANAccess: { enabled in
                let binary = try requireEmbeddedBinary()
                return try decode(NetworkConfigurationResult.self, from: try await execute(
                    binary: binary,
                    arguments: [
                        "network",
                        "--lan-enabled=\(enabled)",
                        "--json",
                    ],
                    timeout: AgentCommandTimeouts.network
                ))
            },
            pair: runPair,
            tailcatStatus: {
                let binary = try requireEmbeddedBinary()
                return try decode(TailcatStatus.self, from: try await execute(
                    binary: binary,
                    arguments: tailcatArguments(action: "status"),
                    timeout: .seconds(8)
                ))
            },
            setTailcatEnabled: { enabled in
                let binary = try requireEmbeddedBinary()
                return try decode(TailcatStatus.self, from: try await execute(
                    binary: binary,
                    arguments: tailcatArguments(action: enabled ? "enable" : "disable"),
                    timeout: AgentCommandTimeouts.tailcatControl
                ))
            },
            configureTailcatDERPMap: { derpMapURL in
                let binary = try requireEmbeddedBinary()
                return try decode(TailcatStatus.self, from: try await execute(
                    binary: binary,
                    arguments: tailcatArguments(action: "configure", derpMapURL: derpMapURL),
                    timeout: .seconds(55)
                ))
            },
            resetTailcat: {
                let binary = try requireEmbeddedBinary()
                return try decode(TailcatStatus.self, from: try await execute(
                    binary: binary,
                    arguments: tailcatArguments(action: "reset"),
                    timeout: .seconds(15)
                ))
            },
            setTailcatManagedMode: { managed in
                let binary = try requireEmbeddedBinary()
                return try decode(TailcatStatus.self, from: try await execute(
                    binary: binary,
                    arguments: tailcatArguments(action: managed ? "enter-managed" : "exit-managed"),
                    // 切换模式会验证新 sidecar，失败时恢复原中继，与修改中继同一量级。
                    timeout: .seconds(55)
                ))
            },
            setTailcatRelay: { choice, url in
                let binary = try requireEmbeddedBinary()
                return try decode(TailcatStatus.self, from: try await execute(
                    binary: binary,
                    arguments: tailcatRelayArguments(choice: choice, url: url),
                    timeout: .seconds(55)
                ))
            },
            configureDeepSeek: { action, startupURL in
                let binary = try requireEmbeddedBinary()
                let arguments = deepSeekConfigurationArguments(action: action, hasStartupURL: startupURL != nil)
                return try decode(DeepSeekConfigurationResult.self, from: try await execute(
                    binary: binary,
                    arguments: arguments,
                    timeout: AgentCommandTimeouts.deepSeekRuntime,
                    forceKillAfterTimeout: true,
                    standardInput: startupURL.map { Data($0.utf8) }
                ))
            },
            version: {
                let binary = try requireEmbeddedBinary()
                let result = try await execute(binary: binary, arguments: ["version"])
                return result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            },
            configureCodex: { preference in
                let binary = try requireEmbeddedBinary()
                return try decode(CodexConfigurationResult.self, from: try await execute(
                    binary: binary, arguments: ["runtime", "--codex=\(preference)", "--json"],
                    timeout: AgentCommandTimeouts.runtime
                ))
            },
            restoreCodex: { previous in
                let binary = try requireEmbeddedBinary()
                let payload = String(decoding: try JSONEncoder().encode(previous), as: UTF8.self)
                return try decode(CodexConfigurationResult.self, from: try await execute(
                    binary: binary, arguments: ["runtime", "--restore-codex", payload, "--json"],
                    timeout: AgentCommandTimeouts.runtime
                ))
            },
            configureNetwork: { network, enabled in
                let binary = try requireEmbeddedBinary()
                guard network == .tailscale || network == .localNetwork else {
                    throw AgentClientError.commandFailed("这个连接方式不使用系统网络开关。")
                }
                let flag = network == .tailscale ? "--tailscale-enabled" : "--lan-enabled"
                return try decode(NetworkConfigurationResult.self, from: try await execute(
                    binary: binary, arguments: ["network", "\(flag)=\(enabled)", "--json"],
                    timeout: AgentCommandTimeouts.network
                ))
            },
            restoreNetwork: { previous in
                let binary = try requireEmbeddedBinary()
                guard previous.previous != nil, previous.applied != nil else {
                    throw AgentClientError.commandFailed("缺少原始连接配置，不能安全回滚。")
                }
                let payload = String(decoding: try JSONEncoder().encode(previous), as: UTF8.self)
                return try decode(NetworkConfigurationResult.self, from: try await execute(
                    binary: binary, arguments: ["network", "--restore-state", payload, "--json"],
                    timeout: AgentCommandTimeouts.network
                ))
            },
            diagnosticsStatus: {
                let binary = try requireEmbeddedBinary()
                return try decode(AgentDiagnosticsStatus.self, from: try await execute(
                    binary: binary,
                    arguments: diagnosticsArguments(action: .status)
                ))
            },
            setDetailedDiagnostics: { enabled in
                let binary = try requireEmbeddedBinary()
                return try decode(AgentDiagnosticsStatus.self, from: try await execute(
                    binary: binary,
                    arguments: diagnosticsArguments(action: enabled ? .start : .stop)
                ))
            },
            clearDiagnostics: {
                let binary = try requireEmbeddedBinary()
                return try decode(AgentDiagnosticsStatus.self, from: try await execute(
                    binary: binary,
                    arguments: diagnosticsArguments(action: .clear)
                ))
            },
            exportDiagnostics: {
                let binary = try requireEmbeddedBinary()
                return try decode(AgentDiagnosticsExport.self, from: try await execute(
                    binary: binary,
                    arguments: diagnosticsArguments(action: .export),
                    outputLimit: 24 * 1_048_576
                ))
            }
        )
    }

    static func deepSeekConfigurationArguments(
        action: DeepSeekConfigurationAction,
        hasStartupURL: Bool
    ) -> [String] {
        var arguments = ["runtime", "--deepseek", action.rawValue, "--json"]
        if hasStartupURL { arguments.append("--deepseek-url-stdin") }
        return arguments
    }

    static func resolveStage(for arguments: [String]) -> OnboardingStage {
        guard let first = arguments.first else { return .setup }
        if first == "setup" {
            return .setup
        }
        if first == "preflight" {
            var index = 1
            while index < arguments.count {
                let arg = arguments[index]
                if arg == "--stage", index + 1 < arguments.count {
                    return OnboardingStage(rawValue: arguments[index + 1]) ?? .setup
                }
                if arg.hasPrefix("--stage=") {
                    let raw = String(arg.dropFirst("--stage=".count))
                    return OnboardingStage(rawValue: raw) ?? .setup
                }
                index += 1
            }
            return .setup
        }
        return .pair
    }

    static func setupArguments(workspaceRoot: URL, browseRoot: URL? = nil) -> [String] {
        let resolvedBrowseRoot = browseRoot ?? workspaceRoot
        return [
            "setup", "--json", "--qr-only",
            // 按最小权限原则，首次设置默认将用户所选代码目录同时作为扫描与浏览根目录，不默认开放整个 Home。
            "--scan-root", workspaceRoot.path,
            "--browse-root", resolvedBrowseRoot.path,
        ]
    }

    static func preflightArguments(options: OnboardingPreflightOptions) -> [String] {
        var args = ["preflight", "--json", "--stage", options.stage.rawValue]
        if let configPath = options.configPath {
            args.append(contentsOf: ["--config", configPath])
        }
        if let scanRoot = options.scanRoot {
            args.append(contentsOf: ["--scan-root", scanRoot.path])
        }
        if let browseRoot = options.browseRoot {
            args.append(contentsOf: ["--browse-root", browseRoot.path])
        }
        if options.progressJSON {
            args.append("--progress-json")
        }
        for pair in options.runtimePaths {
            args.append(contentsOf: ["--runtime-path", "\(pair.id)=\(pair.value)"])
        }
        for pair in options.assistants {
            args.append(contentsOf: ["--assistant", "\(pair.id)=\(pair.value)"])
        }
        return args
    }

    static func setupNoPairArguments(workspaceRoot: URL, options: OnboardingSetupOptions = .init()) -> [String] {
        let browseRoot = options.browseRoot ?? workspaceRoot
        var args = [
            "setup", "--no-pair", "--json",
            "--scan-root", workspaceRoot.path,
            "--browse-root", browseRoot.path,
        ]
        for pair in options.runtimePaths {
            args.append(contentsOf: ["--runtime-path", "\(pair.id)=\(pair.value)"])
        }
        for pair in options.assistants {
            args.append(contentsOf: ["--assistant", "\(pair.id)=\(pair.value)"])
        }
        return args
    }

    static func upArguments(waitSeconds: Int = 60) -> [String] {
        ["up", "--no-pair", "--json", "--wait", "\(waitSeconds)s"]
    }

    static func statusArguments(includeRuntime: Bool) -> [String] {
        var arguments = ["status", "--json"]
        if includeRuntime {
            arguments.append("--runtime")
        }
        return arguments
    }

    static func handoffCommandArguments(runtime: SessionRuntime, threadID: String, cwd: String) -> [String] {
        ["handoff-command", "--runtime", runtime.rawValue, "--thread", threadID, "--cwd", cwd]
    }

    static func codexSessionRepairArguments() -> [String] {
        ["repair-codex-session", "--confirm-disconnected", "--json"]
    }

    static func claudeConfigurationArguments(
        preference: ClaudeActivationPreference,
        restoreEnabled: Bool? = nil
    ) -> [String] {
        var arguments = [
            "runtime",
            "--claude=\(preference.rawValue)",
            "--json",
        ]
        if let restoreEnabled {
            arguments.append("--restore-enabled=\(restoreEnabled)")
        }
        return arguments
    }

    static func claudeTurnHintsConfigurationArguments(enabled: Bool) -> [String] {
        ["runtime", "--claude-turn-hints=\(enabled ? "enabled" : "disabled")", "--json"]
    }

    static func pairArguments(network: PairingNetwork) -> [String] {
        if network == .tailcat {
            return ["tailcat", "pair", "--json", "--qr-only"]
        }
        return [
            "pair",
            "--network", network.rawValue,
            "--json",
            "--qr-only",
        ]
    }

    static func tailcatRelayArguments(choice: String, url: String) -> [String] {
        ["tailcat", "relay", "set", "--choice", choice, "--derp-map-url", choice == "custom" ? url : "", "--json"]
    }

    static func tailcatArguments(action: String, derpMapURL: String? = nil) -> [String] {
        var arguments = ["tailcat", action, "--json"]
        if let derpMapURL {
            arguments.append("--derp-map-url=\(derpMapURL)")
        }
        return arguments
    }

    enum DiagnosticsAction: String {
        case status, start, stop, clear, export
    }

    static func diagnosticsArguments(action: DiagnosticsAction) -> [String] {
        ["diagnostics", action.rawValue, "--json"]
    }

}

enum AgentClientError: LocalizedError, Equatable {
    case embeddedBinaryMissing
    case commandFailed(String)
    case invalidResponse(String)
    case onboarding(OnboardingResolvedDiagnostic)

    var onboardingDiagnostic: OnboardingResolvedDiagnostic? {
        switch self {
        case .onboarding(let diagnostic):
            diagnostic
        case .embeddedBinaryMissing:
            OnboardingCopyCatalog.synthesizeLocal(code: "embedded_binary_missing", step: .serviceDaemon)
        case .commandFailed, .invalidResponse:
            nil
        }
    }

    var errorDescription: String? {
        switch self {
        case .embeddedBinaryMissing:
            "App 内没有找到 agentd，请重新构建或安装 Mimi Remote Mac。"
        case .commandFailed(let detail):
            detail.isEmpty ? "agentd 命令执行失败" : detail
        case .invalidResponse(let detail):
            "无法解析 agentd 返回结果：\(detail)"
        case .onboarding(let diagnostic):
            diagnostic.message
        }
    }
}
