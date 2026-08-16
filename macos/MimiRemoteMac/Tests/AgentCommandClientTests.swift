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

    func testCodexSharingConfigurationArgumentsUseOfficialSwitchOnly() {
        XCTAssertEqual(
            AgentCommandClient.codexSharingConfigurationArguments(enabled: true),
            ["runtime", "--codex-sharing=enabled", "--json"]
        )
        XCTAssertEqual(
            AgentCommandClient.codexSharingConfigurationArguments(enabled: false),
            ["runtime", "--codex-sharing=disabled", "--json"]
        )
        XCTAssertEqual(
            AgentCommandClient.codexSharingRestartArguments(),
            [
                "runtime",
                "--codex-sharing-restart",
                "--codex-sharing-restart-confirmed",
            ]
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

    func testRunToCompletionObservesCommittedSideEffectAfterCallerCancellation() async throws {
        let executor = ProcessExecutor()
        let directory = FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appending(component: "committed")

        let task = Task {
            try await executor.runToCompletion(
                executable: URL(filePath: "/bin/sh"),
                arguments: [
                    "-c",
                    "sleep 0.1; printf committed > \"$1\"",
                    "mimi-process-test",
                    marker.path(),
                ],
                timeout: .seconds(2)
            )
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()

        let result = try await task.value
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(
            try String(contentsOf: marker, encoding: .utf8),
            "committed"
        )
    }

    func testProcessTimeoutReapsControlCommandThatIgnoresTerminate() async {
        let executor = ProcessExecutor()
        let startedAt = ContinuousClock.now
        do {
            _ = try await executor.run(
                executable: URL(filePath: "/bin/sh"),
                // 用 exec 保持同一个 PID 忽略 SIGTERM，避免循环派生的 sleep 子进程
                // 在父 shell 被杀后继续持有 stdout/stderr pipe，让 CI 错把 pipe EOF
                // 等待当成 ProcessExecutor 没有回收目标进程。
                arguments: ["-c", "trap '' TERM; exec /bin/sleep 60"],
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
