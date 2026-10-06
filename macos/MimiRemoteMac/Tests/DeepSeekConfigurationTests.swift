import XCTest
@testable import MimiRemoteMac

final class DeepSeekConfigurationTests: XCTestCase {
    func testCommandArgumentsNeverCarryStartupCredential() {
        XCTAssertEqual(
            AgentCommandClient.deepSeekConfigurationArguments(action: .connect, hasStartupURL: true),
            ["runtime", "--deepseek", "connect", "--json", "--deepseek-url-stdin"]
        )
        XCTAssertEqual(
            AgentCommandClient.deepSeekConfigurationArguments(action: .refresh, hasStartupURL: false),
            ["runtime", "--deepseek", "refresh", "--json"]
        )
    }

    func testConfigurationDecodesSanitizedCLIResult() throws {
        let result = try JSONDecoder().decode(DeepSeekConfigurationResult.self, from: Data("""
        {"enabled":false,"available":true,"discovered":true,"base_url":"http://127.0.0.1:3080",
         "message":"发现运行中的服务","restart_required":false}
        """.utf8))
        XCTAssertTrue(result.discovered)
        XCTAssertFalse(result.enabled)
        XCTAssertEqual(result.baseURL, "http://127.0.0.1:3080")
    }

    func testProcessPassesBoundedInputAndClosesPipe() async throws {
        let payload = Data("http://127.0.0.1:3080/?token=test-only".utf8)
        let result = try await ProcessExecutor().run(
            executable: URL(filePath: "/bin/cat"), arguments: [], standardInput: payload
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, payload)
    }

    func testProcessRejectsOversizedInputBeforeLaunching() async {
        do {
            _ = try await ProcessExecutor().run(
                executable: URL(filePath: "/does-not-exist"), arguments: [],
                standardInput: Data(repeating: 65, count: 16_385)
            )
            XCTFail("超限输入不能启动进程")
        } catch ProcessExecutorError.inputTooLarge {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testProcessInputAtLimitDoesNotBlockTimeoutOrNextCommand() async throws {
        let executor = ProcessExecutor()
        do {
            _ = try await executor.run(
                executable: URL(filePath: "/bin/sleep"), arguments: ["5"],
                timeout: .milliseconds(100), forceKillAfterTimeout: true,
                standardInput: Data(repeating: 65, count: 16_384)
            )
            XCTFail("不读 stdin 的子进程仍必须超时")
        } catch ProcessExecutorError.timedOut {
        }
        let result = try await executor.run(executable: URL(filePath: "/usr/bin/true"), arguments: [])
        XCTAssertEqual(result.status, 0)
    }

    func testEarlyProcessExitWithInputDoesNotTerminateApp() async throws {
        let result = try await ProcessExecutor().run(
            executable: URL(filePath: "/usr/bin/true"), arguments: [],
            standardInput: Data(repeating: 65, count: 16_384)
        )
        XCTAssertEqual(result.status, 0)
    }
}

@MainActor
extension HostStoreTests {
    func testDeepSeekLaunchDiscoversWithoutEnablingAndMenuStaysOff() async {
        let calls = DeepSeekConfigurationCalls()
        let store = makeStore(configExists: true, agentStatus: { .enabled }, configureDeepSeek: { action, _ in
            await calls.record(action)
            return Self.discoveredDeepSeek
        })
        await store.bootstrap()
        let recorded = await calls.actions
        XCTAssertEqual(recorded, [.refresh])
        XCTAssertFalse(store.deepSeekEnabled)
        XCTAssertEqual(store.deepSeekStatusTitle, "发现运行中的服务")
        // 检测到服务不等于启用：模块开关在菜单栏里必须仍是关闭。
        XCTAssertFalse(store.moduleEnabled(.deepseek))
        XCTAssertEqual(store.moduleStateTitle(.deepseek), "已关闭")
    }

    func testDeepSeekFailedConnectPreservesDisabledStateAndReleasesBusy() async {
        let store = makeStore(configExists: true, agentStatus: { .enabled }, configureDeepSeek: { action, _ in
            if action == .connect { throw AgentClientError.commandFailed("启动链接已失效") }
            return Self.discoveredDeepSeek
        })
        await store.bootstrap()
        await store.configureDeepSeek(.connect, startupURL: "http://127.0.0.1:3080/?token=test-only")
        XCTAssertFalse(store.deepSeekEnabled)
        XCTAssertFalse(store.isBusy)
        XCTAssertFalse(store.isUpdatingDeepSeek)
        XCTAssertEqual(store.deepSeekStatusTitle, "需要处理")
        XCTAssertTrue(store.deepSeekError?.contains("启动链接已失效") == true)
    }

    func testDeepSeekUnavailableConnectionKeepsUserToggleEnabled() async {
        let store = makeStore(configExists: true, agentStatus: { .enabled }, configureDeepSeek: { action, _ in
            if action == .connect {
                return DeepSeekConfigurationResult(
                    enabled: true, available: false, discovered: false,
                    baseURL: "http://127.0.0.1:3080", message: "当前连接不可用", restartRequired: false
                )
            }
            return Self.discoveredDeepSeek
        })
        await store.bootstrap()
        await store.setDeepSeekEnabled(true)
        XCTAssertTrue(store.deepSeekEnabled)
        XCTAssertTrue(store.moduleEnabled(.deepseek))
        XCTAssertEqual(store.deepSeekStatusTitle, "需要处理")
        XCTAssertEqual(store.deepSeekStatusDetail, "当前连接不可用")
    }

    func testDeepSeekMutationIsUnavailableForHomebrewOwner() async {
        let calls = DeepSeekConfigurationCalls()
        let store = makeStore(configExists: true, homebrewLoaded: true, configureDeepSeek: { action, _ in
            await calls.record(action)
            return Self.discoveredDeepSeek
        })
        await store.bootstrap()
        await store.configureDeepSeek(.connect)
        await store.inspectDeepSeek()
        let recorded = await calls.actions
        XCTAssertTrue(recorded.isEmpty)
        XCTAssertFalse(store.canChangeDeepSeek)
    }

    func testDeepSeekFailedFreshProbeOverridesOldAvailableRuntimeStatus() async {
        let store = makeStore(
            configExists: true, agentStatus: { .enabled },
            status: {
                try JSONDecoder().decode(AgentStatus.self, from: Data(#"{"process_ok":true,"service_ok":true,"version":"fixture","endpoint":"http://127.0.0.1:8787","config_path":"/tmp/fixture.json","projects":1,"doctor_ok":true,"doctor":{"ok":true,"version":"fixture","listen":"127.0.0.1:8787","checks":[]},"runtime_status":{"runtimes":[{"id":"deepseek","title":"DeepSeek Harness","enabled":true,"state":"available","reason":"ready"}]}}"#.utf8))
            },
            configureDeepSeek: { action, _ in
                DeepSeekConfigurationResult(
                    enabled: true, available: action != .inspect, discovered: false,
                    baseURL: "http://127.0.0.1:3080", message: "最新连接检查失败", restartRequired: false
                )
            }
        )
        await store.bootstrap()
        XCTAssertEqual(store.deepSeekStatusTitle, "已连接")
        await store.inspectDeepSeek()
        XCTAssertEqual(store.status?.runtimeStatus?.runtimes.first?.state, .available)
        XCTAssertEqual(store.deepSeekStatusTitle, "需要处理")
        XCTAssertEqual(store.deepSeekStatusDetail, "最新连接检查失败")
    }

    func testDeepSeekReloadFailureReportsSavedButNotConnected() async {
        let store = makeStore(
            configExists: true, agentStatus: { .enabled },
            unregisterAgent: { throw AgentClientError.commandFailed("test reload failure") },
            configureDeepSeek: { action, _ in
                if action == .connect {
                    return DeepSeekConfigurationResult(
                        enabled: true, available: true, discovered: true,
                        baseURL: "http://127.0.0.1:3080", message: "已验证", restartRequired: true
                    )
                }
                return Self.discoveredDeepSeek
            }
        )
        await store.bootstrap()
        await store.configureDeepSeek(.connect)
        XCTAssertTrue(store.deepSeekError?.contains("配置已保存") == true)
        XCTAssertEqual(store.deepSeekStatusTitle, "需要处理")
        XCTAssertFalse(store.isBusy)
        XCTAssertNotEqual(store.lifecycle, .starting)
    }

    func testDeepSeekToggleRestartsCurrentServiceWithoutReregistering() async {
        var events: [String] = []
        let store = makeStore(
            configExists: true, agentStatus: { .enabled },
            registerAgent: { events.append("register") },
            unregisterAgent: { events.append("unregister") },
            restartAgent: { events.append("restart") },
            configureDeepSeek: { action, _ in
                DeepSeekConfigurationResult(
                    enabled: action == .connect, available: action == .connect,
                    discovered: false, baseURL: "http://127.0.0.1:3080",
                    message: "fixture", restartRequired: action != .refresh
                )
            }
        )
        await store.bootstrap()
        events.removeAll()

        await store.configureDeepSeek(.connect)
        await store.configureDeepSeek(.disabled)

        XCTAssertEqual(events, ["restart", "restart"])
        XCTAssertFalse(store.deepSeekEnabled)
        XCTAssertFalse(store.isBusy)
    }

    func testDeepSeekFastRestartFailureFallsBackToFullRegistration() async {
        var events: [String] = []
        var registration: ServiceRegistrationState = .enabled
        let store = makeStore(
            configExists: true, agentStatus: { registration },
            registerAgent: { registration = .enabled; events.append("register") },
            unregisterAgent: { registration = .notRegistered; events.append("unregister") },
            restartAgent: {
                events.append("restart")
                throw AgentClientError.commandFailed("launchctl unavailable")
            },
            configureDeepSeek: { action, _ in
                DeepSeekConfigurationResult(
                    enabled: action == .connect, available: action == .connect,
                    discovered: false, baseURL: "http://127.0.0.1:3080",
                    message: "fixture", restartRequired: action == .connect
                )
            },
            healthCheck: { _ in false }
        )
        await store.bootstrap()
        events.removeAll()

        await store.configureDeepSeek(.connect)

        XCTAssertEqual(events, ["restart", "unregister", "register"])
        XCTAssertNil(store.deepSeekError)
    }

    func testDeepSeekLaunchRefreshMissDefersToRejectedCredentialRuntime() async {
        let store = makeStore(
            configExists: true, agentStatus: { .enabled },
            status: { try Self.deepSeekRuntimeStatus(state: "signed_out", reason: "credentials_rejected") },
            configureDeepSeek: { _, _ in Self.unavailableLaunchRefresh }
        )
        await store.bootstrap()
        // 开机刷新抢在 Harness 换好凭据之前不算错误；agentd 的运行态才是结论。
        XCTAssertNil(store.deepSeekError)
        XCTAssertEqual(store.deepSeekStatusTitle, "需要更新启动链接")
        XCTAssertEqual(store.moduleStateTitle(.deepseek), "需要更新启动链接")
        XCTAssertTrue(store.deepSeekStatusDetail.contains("重启 Harness 后点击重新检测"))
        let rejected = try? Self.deepSeekRuntimeStatus(
            state: "signed_out", reason: "credentials_rejected"
        ).runtimeStatus
        XCTAssertTrue(rejected?.hasRetryableFailure == true)
        var retry = RuntimeStatusFollowUpState()
        XCTAssertEqual(retry.delay(for: rejected), .seconds(32))
        retry.markRetry(for: rejected)
        XCTAssertNil(retry.delay(for: rejected))
    }

    func testDeepSeekLaunchRefreshMissDoesNotHideSelfHealedRuntime() async {
        let store = makeStore(
            configExists: true, agentStatus: { .enabled },
            status: { try Self.deepSeekRuntimeStatus(state: "available", reason: "ready") },
            configureDeepSeek: { _, _ in Self.unavailableLaunchRefresh }
        )
        await store.bootstrap()
        XCTAssertNil(store.deepSeekError)
        XCTAssertEqual(store.deepSeekStatusTitle, "已连接")
        XCTAssertEqual(store.moduleStateTitle(.deepseek), "可用")
    }

    private nonisolated static var unavailableLaunchRefresh: DeepSeekConfigurationResult {
        DeepSeekConfigurationResult(
            enabled: true, available: false, discovered: false,
            baseURL: "http://127.0.0.1:3080", message: "未能从本机取得可用的 Harness 启动信息", restartRequired: false
        )
    }

    private nonisolated static func deepSeekRuntimeStatus(state: String, reason: String) throws -> AgentStatus {
        let checkedAt = ISO8601DateFormatter().string(from: Date())
        let json = #"{"process_ok":true,"service_ok":true,"version":"fixture","endpoint":"http://127.0.0.1:8787","config_path":"/tmp/fixture.json","projects":1,"doctor_ok":true,"doctor":{"ok":true,"version":"fixture","listen":"127.0.0.1:8787","checks":[]},"runtime_status":{"checked_at":"\#(checkedAt)","runtimes":[{"id":"deepseek","title":"DeepSeek Harness","enabled":true,"state":"\#(state)","reason":"\#(reason)"}]}}"#
        return try JSONDecoder().decode(AgentStatus.self, from: Data(json.utf8))
    }

    private nonisolated static var discoveredDeepSeek: DeepSeekConfigurationResult {
        DeepSeekConfigurationResult(
            enabled: false, available: true, discovered: true,
            baseURL: "http://127.0.0.1:3080", message: "发现运行中的服务", restartRequired: false
        )
    }
}

private actor DeepSeekConfigurationCalls {
    var actions: [DeepSeekConfigurationAction] = []
    func record(_ action: DeepSeekConfigurationAction) { actions.append(action) }
}
