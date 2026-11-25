import XCTest
@testable import MimiRemoteMac

final class AgentCommandClientTests: XCTestCase {
    func testSharedHostCliRelayContract() throws {
        struct RelayCase: Decodable {
            struct Current: Decodable {
                let enabled: Bool
                let mode: String
                let derpMapUrl: String
            }
            let id: String
            let choice: String
            let url: String
            let current: Current
            let needsConfirmation: Bool
            let valid: Bool
        }
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let data = try Data(contentsOf: root.appendingPathComponent("contracts/host-cli/relay-cases.json"))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        for item in try decoder.decode([RelayCase].self, from: data) {
            let mode: TailcatRelayMode
            if item.choice == "default" { mode = .tailcatDefault }
            else { mode = try XCTUnwrap(TailcatRelayMode(rawValue: item.choice)) }
            XCTAssertEqual(TailcatRelayPresentation.needsReconnectionConfirmation(
                mode: mode, url: item.url, tailcatEnabled: item.current.enabled,
                isManaged: item.current.mode == "managed", currentURL: item.current.derpMapUrl
            ), item.needsConfirmation, item.id)
            if item.choice == "custom" {
                XCTAssertEqual(TailcatRelayPresentation.customURLValidationMessage(item.url) == nil, item.valid, item.id)
            }
            XCTAssertEqual(AgentCommandClient.tailcatRelayArguments(choice: item.choice, url: item.url),
                ["tailcat", "relay", "set", "--choice", item.choice, "--derp-map-url", item.url, "--json"], item.id)
        }
    }

    func testSetupDefaultsBrowseRootToWorkspaceAndAllowsExplicitOverride() {
        let defaultArgs = AgentCommandClient.setupArguments(
            workspaceRoot: URL(filePath: "/test-user/code")
        )
        XCTAssertEqual(defaultArgs, [
            "setup", "--json", "--qr-only",
            "--scan-root", "/test-user/code",
            "--browse-root", "/test-user/code",
        ])

        let explicitArgs = AgentCommandClient.setupArguments(
            workspaceRoot: URL(filePath: "/test-user/code"),
            browseRoot: URL(filePath: "/test-user/custom-browse")
        )
        XCTAssertEqual(explicitArgs, [
            "setup", "--json", "--qr-only",
            "--scan-root", "/test-user/code",
            "--browse-root", "/test-user/custom-browse",
        ])
    }

    func testResolveStageParsesPreflightStageFlag() {
        XCTAssertEqual(AgentCommandClient.resolveStage(for: ["preflight", "--json", "--stage", "pair"]), .pair)
        XCTAssertEqual(AgentCommandClient.resolveStage(for: ["preflight", "--json", "--stage=pair"]), .pair)
        XCTAssertEqual(AgentCommandClient.resolveStage(for: ["preflight", "--json", "--stage", "setup"]), .setup)
        XCTAssertEqual(AgentCommandClient.resolveStage(for: ["preflight", "--json"]), .setup)
        XCTAssertEqual(AgentCommandClient.resolveStage(for: ["preflight", "--stage", "unknown"]), .setup)
        XCTAssertEqual(AgentCommandClient.resolveStage(for: ["setup", "--no-pair", "--json"]), .setup)
        XCTAssertEqual(AgentCommandClient.resolveStage(for: ["pair", "--json"]), .pair)
    }

    func testStatusOnlyRequestsRuntimeFromBundledAgent() {
        XCTAssertEqual(
            AgentCommandClient.statusArguments(includeRuntime: true),
            ["status", "--json", "--runtime"]
        )
        XCTAssertEqual(
            AgentCommandClient.statusArguments(includeRuntime: false),
            ["status", "--json"]
        )
    }

    func testCodexSessionRepairUsesFixedExplicitCommand() {
        XCTAssertEqual(
            AgentCommandClient.codexSessionRepairArguments(),
            ["repair-codex-session", "--confirm-disconnected", "--json"]
        )
    }

    func testDiagnosticsCommandsUseLocalJSONInterface() {
        XCTAssertEqual(
            AgentCommandClient.diagnosticsArguments(action: .status),
            ["diagnostics", "status", "--json"]
        )
        XCTAssertEqual(
            AgentCommandClient.diagnosticsArguments(action: .start),
            ["diagnostics", "start", "--json"]
        )
        XCTAssertEqual(
            AgentCommandClient.diagnosticsArguments(action: .stop),
            ["diagnostics", "stop", "--json"]
        )
        XCTAssertEqual(
            AgentCommandClient.diagnosticsArguments(action: .clear),
            ["diagnostics", "clear", "--json"]
        )
        XCTAssertEqual(
            AgentCommandClient.diagnosticsArguments(action: .export),
            ["diagnostics", "export", "--json"]
        )
    }

    func testCodexSessionRepairResultRequiresBothFields() throws {
        XCTAssertEqual(
            try JSONDecoder().decode(
                CodexSessionReleaseResult.self,
                from: Data(#"{"released":false,"message":"无需释放"}"#.utf8)
            ),
            CodexSessionReleaseResult(released: false, message: "无需释放")
        )
        XCTAssertThrowsError(try JSONDecoder().decode(
            CodexSessionReleaseResult.self,
            from: Data(#"{"message":"结果不完整"}"#.utf8)
        ))
        XCTAssertThrowsError(try JSONDecoder().decode(
            CodexSessionReleaseResult.self,
            from: Data(#"{"released":true}"#.utf8)
        ))
    }

    func testClaudeConfigurationArgumentsKeepNormalAndRollbackCallsExplicit() {
        XCTAssertEqual(
            AgentCommandClient.claudeConfigurationArguments(preference: .automatic),
            ["runtime", "--claude=auto", "--json"]
        )
        XCTAssertEqual(
            AgentCommandClient.claudeConfigurationArguments(
                preference: .disabled,
                restoreEnabled: true
            ),
            ["runtime", "--claude=disabled", "--json", "--restore-enabled=true"]
        )
    }

    func testClaudeTurnHintsConfigurationArgumentsAreIndependentFromModuleActivation() {
        XCTAssertEqual(
            AgentCommandClient.claudeTurnHintsConfigurationArguments(enabled: true),
            ["runtime", "--claude-turn-hints=enabled", "--json"]
        )
        XCTAssertEqual(
            AgentCommandClient.claudeTurnHintsConfigurationArguments(enabled: false),
            ["runtime", "--claude-turn-hints=disabled", "--json"]
        )
    }

    func testTailcatUsesDedicatedExperimentalCommands() {
        XCTAssertEqual(
            AgentCommandClient.pairArguments(network: .tailcat),
            ["tailcat", "pair", "--json", "--qr-only"]
        )
        XCTAssertEqual(
            AgentCommandClient.pairArguments(network: .tailscale),
            ["pair", "--network", "tailscale", "--json", "--qr-only"]
        )
        XCTAssertEqual(
            AgentCommandClient.tailcatArguments(action: "enable"),
            ["tailcat", "enable", "--json"]
        )
        XCTAssertEqual(
            AgentCommandClient.tailcatArguments(
                action: "configure",
                derpMapURL: "https://relay.example/derpmap/default"
            ),
            [
                "tailcat", "configure", "--json",
                "--derp-map-url=https://relay.example/derpmap/default",
            ]
        )
        XCTAssertEqual(
            AgentCommandClient.tailcatArguments(action: "configure", derpMapURL: ""),
            ["tailcat", "configure", "--json", "--derp-map-url="]
        )
        XCTAssertEqual(
            AgentCommandClient.tailcatArguments(action: "enter-managed"),
            ["tailcat", "enter-managed", "--json"]
        )
    }

    func testProcessCancellationIsReportedAsCancellation() async {
        let executor = ProcessExecutor()
        let task = Task {
            try await executor.run(
                executable: URL(filePath: "/bin/sleep"),
                arguments: ["5"],
                timeout: .seconds(10)
            )
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("取消后不应返回成功结果")
        } catch is CancellationError {
            // 视图关闭导致的正常取消不能被 HostStore 当成服务故障。
        } catch {
            XCTFail("取消应保留 CancellationError 语义，实际为 \(error)")
        }
    }

    func testProcessTimeoutReapsControlCommandThatIgnoresTerminate() async {
        let executor = ProcessExecutor()
        let startedAt = ContinuousClock.now
        do {
            _ = try await executor.run(
                executable: URL(filePath: "/bin/sh"),
                // 让 shell 本身忽略 SIGTERM，且不派生会继承 stdout/stderr pipe 的
                // 子进程；否则测试测到的是后代等待 pipe EOF，而不是目标是否回收。
                arguments: ["-c", "trap '' TERM; while :; do :; done"],
                timeout: .milliseconds(100),
                forceKillAfterTimeout: true
            )
            XCTFail("忽略 SIGTERM 的 control command 必须超时")
        } catch ProcessExecutorError.timedOut {
            XCTAssertLessThan(
                startedAt.duration(to: .now),
                .seconds(4),
                "timeout 后必须在 grace period 内回收 control command，不能让 UI 永久 busy"
            )
        } catch {
            XCTFail("超时应保留 timedOut 语义，实际为 \(error)")
        }
    }

    func testCancelReapsAnUnresponsivePairCommand() async throws {
        let files = FileManager.default
        let dir = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: dir) }
        let script = dir.appendingPathComponent("pair")
        try """
        #!/bin/sh
        trap '' TERM
        touch "$0.ready"
        exec /bin/sleep 10
        """.write(to: script, atomically: true, encoding: .utf8)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let client = AgentCommandClient.live(binaryOverride: script)
        let task = Task { try await client.pair(.tailscale) }
        let ready = script.path + ".ready"
        let launchDeadline = ContinuousClock.now + .seconds(3)
        while !files.fileExists(atPath: ready), ContinuousClock.now < launchDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(files.fileExists(atPath: ready))
        let cancelledAt = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled pairing returned a ticket")
        } catch is CancellationError {
            XCTAssertLessThan(cancelledAt.duration(to: .now), .seconds(5))
        }
    }

    func testOnboardingCommandArgumentsAndTimeouts() {
        let preflightArgs = AgentCommandClient.preflightArguments(
            options: OnboardingPreflightOptions(
                stage: .setup,
                configPath: "/fixture/config/config.json",
                scanRoot: URL(filePath: "/fixture/workspace"),
                browseRoot: URL(filePath: "/fixture/workspace"),
                progressJSON: true,
                runtimePaths: [(id: "codex", value: "auto")],
                assistants: [(id: "claude", value: "enabled")]
            )
        )
        XCTAssertEqual(preflightArgs, [
            "preflight", "--json", "--stage", "setup",
            "--config", "/fixture/config/config.json",
            "--scan-root", "/fixture/workspace",
            "--browse-root", "/fixture/workspace",
            "--progress-json",
            "--runtime-path", "codex=auto",
            "--assistant", "claude=enabled",
        ])

        XCTAssertEqual(
            AgentCommandClient.setupNoPairArguments(workspaceRoot: URL(filePath: "/fixture/workspace")),
            ["setup", "--no-pair", "--json", "--scan-root", "/fixture/workspace", "--browse-root", "/fixture/workspace"]
        )
        XCTAssertEqual(AgentCommandClient.upArguments(waitSeconds: 60), ["up", "--no-pair", "--json", "--wait", "60s"])
        XCTAssertGreaterThanOrEqual(AgentCommandTimeouts.preflight, .seconds(35))
        XCTAssertGreaterThanOrEqual(AgentCommandTimeouts.setup, .seconds(60))
        XCTAssertGreaterThanOrEqual(AgentCommandTimeouts.pair, .seconds(45))
        XCTAssertGreaterThanOrEqual(AgentCommandTimeouts.network, .seconds(45))
        XCTAssertGreaterThanOrEqual(AgentCommandTimeouts.runtime, .seconds(45))
        XCTAssertGreaterThanOrEqual(AgentCommandTimeouts.deepSeekRuntime, .seconds(45))
        XCTAssertGreaterThanOrEqual(AgentCommandTimeouts.workspace, .seconds(45))
        XCTAssertGreaterThanOrEqual(AgentCommandTimeouts.doctorFix, .seconds(45))
        XCTAssertGreaterThanOrEqual(AgentCommandTimeouts.tailcatControl, .seconds(45))
        XCTAssertGreaterThanOrEqual(AgentCommandTimeouts.tailcatReconfigure, .seconds(85))
        for command in ["tailcat configure", "tailcat enter-managed", "tailcat exit-managed", "tailcat relay set", "tailcat relay-set"] {
            XCTAssertGreaterThanOrEqual(AgentCommandTimeouts.duration(for: command), .seconds(85), command)
        }
        XCTAssertGreaterThanOrEqual(AgentCommandTimeouts.serviceWait, .seconds(110))
    }

    func testProcessExecutorStreamsStderrLinesBeforeExit() async throws {
        let executor = ProcessExecutor()
        let lock = NSLock()
        var arrivalTimes: [(String, ContinuousClock.Instant)] = []
        let finishedAt: ContinuousClock.Instant
        let result = try await executor.run(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", "echo first >&2; sleep 0.25; echo second >&2; echo done"],
            timeout: .seconds(5),
            onStderrLine: { line in
                lock.lock()
                arrivalTimes.append((line, ContinuousClock.now))
                lock.unlock()
            }
        )
        finishedAt = ContinuousClock.now
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines), "done")
        lock.lock()
        let captured = arrivalTimes
        lock.unlock()
        XCTAssertEqual(captured.map(\.0), ["first", "second"])
        XCTAssertGreaterThanOrEqual(captured[0].1.duration(to: finishedAt), .milliseconds(150))
    }

    func testProcessTimeoutBoundsPipeDrainWhenDescendantHoldsWriteHandle() async {
        let executor = ProcessExecutor()
        let startedAt = ContinuousClock.now
        do {
            _ = try await executor.run(
                executable: URL(filePath: "/bin/sh"),
                // 主 shell 立即输出并退出，但后台 sleep 继承并保持 stdout/stderr 写端打开；
                // 管道排空必须受总 deadline 约束，不能因为主进程已退出而无限期挂起。
                arguments: ["-c", "printf unfinished >&2; /bin/sleep 4 & echo done"],
                timeout: .milliseconds(250),
                onStderrLine: { _ in XCTFail("Deadline must discard an unfinished progress line") }
            )
            XCTFail("后代进程持有写端句柄超过 deadline 时必须超时")
        } catch ProcessExecutorError.timedOut {
            XCTAssertLessThan(
                startedAt.duration(to: .now),
                .seconds(2),
                "deadline 到期后必须立即终止管道排空，不能等待后代退出"
            )
        } catch {
            XCTFail("应保留 timedOut 语义，实际为 \(error)")
        }
    }
}
