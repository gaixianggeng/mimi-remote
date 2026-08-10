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
}
