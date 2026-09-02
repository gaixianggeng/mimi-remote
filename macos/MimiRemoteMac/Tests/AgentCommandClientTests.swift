import XCTest
@testable import MimiRemoteMac

final class AgentCommandClientTests: XCTestCase {
    func testSetupUsesSeparateProjectScanAndHomeBrowseRoots() {
        let arguments = AgentCommandClient.setupArguments(
            workspaceRoot: URL(filePath: "/test-user/code"),
            browseRoot: URL(filePath: "/test-user")
        )

        XCTAssertEqual(arguments, [
            "setup", "--json", "--qr-only",
            "--scan-root", "/test-user/code",
            "--browse-root", "/test-user",
        ])
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
}
