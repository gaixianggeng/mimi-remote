import Darwin
import Foundation
import XCTest
@testable import MimiRemoteMac

@MainActor
final class HostStoreTests: XCTestCase {
    func testMonitoringUsesLightReadinessEveryMinuteAndFullStatusEveryFiveMinutes() async {
        let fullCalls = CallCounter()
        let readinessCalls = CallCounter()
        let healthCalls = CallCounter()
        let store = makeStore(
            configExists: true,
            agentStatus: { .enabled },
            status: {
                _ = fullCalls.increment()
                return Self.readyStatus
            },
            readiness: {
                _ = readinessCalls.increment()
                return Self.readyStatus
            },
            healthCheck: { _ in
                _ = healthCalls.increment()
                return true
            }
        )
        await store.bootstrap()
        let now = Date()

        await store.performMonitoringTick(5, now: now)
        XCTAssertEqual(readinessCalls.current, 0)
        XCTAssertEqual(fullCalls.current, 1)

        await store.performMonitoringTick(6, now: now.addingTimeInterval(60))
        XCTAssertEqual(readinessCalls.current, 1)
        XCTAssertEqual(fullCalls.current, 1)

        await store.performMonitoringTick(30, now: now.addingTimeInterval(300))
        XCTAssertEqual(readinessCalls.current, 1, "完整 status 轮次不得重复轻量 readiness")
        XCTAssertEqual(fullCalls.current, 2)
        XCTAssertEqual(healthCalls.current, 3, "每个 10 秒 monitoring tick 都必须先检查 healthz")
    }

    func testMonitoringDegradesImmediatelyWhenReadinessReportsServiceUnavailable() async {
        let store = makeStore(
            configExists: true,
            agentStatus: { .enabled },
            readiness: { Self.stoppedStatus }
        )
        await store.bootstrap()

        await store.performMonitoringTick(6, now: Date().addingTimeInterval(60))

        XCTAssertEqual(store.lifecycle, .degraded("readyz 不可用"))
    }

    func testMonitoringKeepsLiveProcessOutOfStoppedWhileReadinessIsStaleAndRecovers() async {
        let readinessCalls = CallCounter()
        let store = makeStore(
            configExists: true,
            agentStatus: { .enabled },
            readiness: {
                if readinessCalls.increment() == 1 {
                    throw AgentClientError.commandFailed("temporary failure")
                }
                return Self.readyStatus
            }
        )
        await store.bootstrap()
        let baseline = Date()

        await store.performMonitoringTick(6, now: baseline.addingTimeInterval(89))
        XCTAssertEqual(store.lifecycle, .ready)

        await store.performMonitoringTick(9, now: baseline.addingTimeInterval(91))
        XCTAssertEqual(
            store.lifecycle,
            .degraded("进程存活，但 Codex 服务状态暂时无法确认")
        )

        await store.performMonitoringTick(12, now: baseline.addingTimeInterval(120))
        XCTAssertEqual(store.lifecycle, .ready)
    }

    func testMonitoringFullStatusKeepsHealthConfirmedProcessDegradedInsteadOfStopped() async {
        let fullCalls = CallCounter()
        let store = makeStore(
            configExists: true,
            agentStatus: { .enabled },
            status: {
                fullCalls.increment() == 1 ? Self.readyStatus : Self.stoppedStatus
            }
        )
        await store.bootstrap()

        await store.performMonitoringTick(30, now: Date().addingTimeInterval(300))

        XCTAssertEqual(store.lifecycle, .degraded("readyz 不可用"))
    }

    func testOlderReadinessCannotOverwriteNewerFullStatus() async {
        let readinessGate = SuspendedStatusGate()
        let store = makeStore(
            configExists: true,
            agentStatus: { .enabled },
            readiness: {
                await readinessGate.suspendReturning(Self.stoppedStatus)
            }
        )
        await store.bootstrap()
        let baseline = Date()

        let readinessTask = Task { @MainActor in
            await store.performMonitoringTick(6, now: baseline.addingTimeInterval(60))
        }
        await readinessGate.waitUntilSuspended()
        await store.performMonitoringTick(30, now: baseline.addingTimeInterval(300))
        readinessGate.resume()
        await readinessTask.value

        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertEqual(store.status?.serviceOK, true)
    }

    func testReadinessStalenessStartsAtFirstFailureWhenNoSuccessExists() {
        let store = makeStore(configExists: false)
        let firstFailure = Date()

        store.applyReadinessStalenessIfNeeded(now: firstFailure)
        XCTAssertEqual(store.lifecycle, .loading)

        store.applyReadinessStalenessIfNeeded(now: firstFailure.addingTimeInterval(90))
        XCTAssertEqual(
            store.lifecycle,
            .degraded("进程存活，但 Codex 服务状态暂时无法确认")
        )
    }

    func testBootstrapRegistersBundledAgentWhenServiceRecordIsNotFound() async {
        let events = EventRecorder()
        var registrationState = ServiceRegistrationState.notFound
        let store = makeStore(
            configExists: true,
            agentStatus: { registrationState },
            registerAgent: {
                events.append("register-mac")
                registrationState = .enabled
            }
        )

        await store.bootstrap()

        XCTAssertEqual(events.values, ["register-mac"])
        XCTAssertEqual(store.owner, .macApp)
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertNil(store.lastError)
    }

    func testBootstrapReportsMissingBundledConfigurationWithoutRegistering() async {
        let events = EventRecorder()
        let store = makeStore(
            configExists: true,
            agentStatus: { .notFound },
            agentConfigurationError: { "App 包内缺少 LaunchAgent 配置，请重新安装正式版本。" },
            registerAgent: { events.append("register-mac") }
        )

        await store.bootstrap()

        XCTAssertEqual(events.values, [])
        XCTAssertEqual(store.owner, .none)
        XCTAssertEqual(
            store.lifecycle,
            .failed("App 包内缺少 LaunchAgent 配置，请重新安装正式版本。")
        )
    }

    func testBootstrapRejectsAdHocSnapshotBeforeTouchingRegisteredAgent() async {
        let events = EventRecorder()
        let message = "当前 App 是未签名或 ad-hoc 结构快照，不能启动 macOS 后台服务。"
        let store = makeStore(
            configExists: true,
            agentStatus: { .enabled },
            agentConfigurationError: { message },
            status: {
                events.append("status")
                return Self.stoppedStatus
            },
            registerAgent: { events.append("register-mac") },
            unregisterAgent: { events.append("unregister-mac") }
        )

        await store.bootstrap()

        XCTAssertEqual(events.values, [])
        XCTAssertEqual(store.owner, .none)
        XCTAssertEqual(store.lifecycle, .failed(message))
        XCTAssertEqual(store.lastError, message)
    }

    func testPartialRegistrationFailureTriggersOneBoundedReregistration() async {
        let events = EventRecorder()
        var registrationState = ServiceRegistrationState.notRegistered
        var registrationAttempts = 0
        let store = makeStore(
            configExists: true,
            agentStatus: { registrationState },
            registerAgent: {
                registrationAttempts += 1
                events.append("register-\(registrationAttempts)")
                registrationState = .enabled
                if registrationAttempts == 1 {
                    throw TestError.expected
                }
            },
            unregisterAgent: {
                events.append("unregister-mac")
                registrationState = .notRegistered
            }
        )

        await store.bootstrap()

        XCTAssertEqual(events.values, ["register-1", "unregister-mac", "register-2"])
        XCTAssertEqual(registrationAttempts, 2)
        XCTAssertEqual(store.owner, .macApp)
        XCTAssertEqual(store.lifecycle, .ready)
    }

    func testUnregisterTimeoutRetriesOnceThenRegistersAfterStateConverges() async {
        let events = EventRecorder()
        let unregisterCalls = CallCounter()
        let statusCalls = CallCounter()
        var registrationState = ServiceRegistrationState.enabled
        let store = makeStore(
            configExists: true,
            agentStatus: { registrationState },
            status: {
                statusCalls.increment() == 1 ? Self.stoppedStatus : Self.readyStatus
            },
            registerAgent: {
                events.append("register-mac")
                registrationState = .enabled
            },
            unregisterAgent: {
                let call = unregisterCalls.increment()
                events.append("unregister-\(call)")
                if call == 2 {
                    registrationState = .notRegistered
                }
            },
            healthCheck: { _ in false }
        )

        await store.bootstrap()

        XCTAssertEqual(events.values, [
            "unregister-1", "unregister-2", "register-mac",
        ])
        XCTAssertEqual(unregisterCalls.current, 2)
        XCTAssertEqual(statusCalls.current, 2)
        XCTAssertEqual(store.owner, .macApp)
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertNil(store.lastError)
    }

    func testSecondUnregisterTimeoutFailsWithoutThirdUnregisterOrRegister() async {
        let events = EventRecorder()
        let unregisterCalls = CallCounter()
        let registrationState = ServiceRegistrationState.enabled
        let store = makeStore(
            configExists: true,
            agentStatus: { registrationState },
            status: { Self.stoppedStatus },
            registerAgent: { events.append("register-mac") },
            unregisterAgent: {
                let call = unregisterCalls.increment()
                events.append("unregister-\(call)")
            },
            healthCheck: { _ in false }
        )

        await store.bootstrap()

        XCTAssertEqual(events.values, ["unregister-1", "unregister-2"])
        XCTAssertEqual(unregisterCalls.current, 2)
        XCTAssertEqual(registrationState, .enabled)
        XCTAssertEqual(store.owner, .macApp)
        XCTAssertEqual(store.lifecycle, .failed(store.lastError ?? ""))
        XCTAssertTrue(store.lastError?.contains("服务停止超时") == true)
    }

    func testUnregisterRequiresApprovalDoesNotRetry() async {
        let events = EventRecorder()
        let unregisterCalls = CallCounter()
        var registrationState = ServiceRegistrationState.enabled
        let store = makeStore(
            configExists: true,
            agentStatus: { registrationState },
            status: { Self.stoppedStatus },
            registerAgent: { events.append("register-mac") },
            unregisterAgent: {
                unregisterCalls.increment()
                events.append("unregister-1")
                registrationState = .requiresApproval
            }
        )

        await store.bootstrap()

        XCTAssertEqual(events.values, ["unregister-1"])
        XCTAssertEqual(unregisterCalls.current, 1)
        XCTAssertFalse(events.values.contains("register-mac"))
        XCTAssertTrue(store.lastError?.contains("登录项") == true)
    }

    func testUnregisterCancellationDoesNotRetry() async {
        let events = EventRecorder()
        let unregisterCalls = CallCounter()
        let firstUnregister = expectation(description: "first unregister called")
        let store = makeStore(
            configExists: true,
            agentStatus: { .enabled },
            status: { Self.stoppedStatus },
            registerAgent: { events.append("register-mac") },
            unregisterAgent: {
                unregisterCalls.increment()
                events.append("unregister-1")
                firstUnregister.fulfill()
            }
        )

        let bootstrapTask = Task { await store.bootstrap() }
        await fulfillment(of: [firstUnregister], timeout: 1)
        bootstrapTask.cancel()
        await bootstrapTask.value

        XCTAssertEqual(events.values, ["unregister-1"])
        XCTAssertEqual(unregisterCalls.current, 1)
        XCTAssertFalse(events.values.contains("register-mac"))
    }

    func testEnabledAgentStatusFailureTriggersOneBoundedReregistration() async {
        let events = EventRecorder()
        let statusEvents = EventRecorder()
        var registrationState = ServiceRegistrationState.enabled
        let store = makeStore(
            configExists: true,
            agentStatus: { registrationState },
            status: {
                statusEvents.append("status")
                if statusEvents.values.count == 1 {
                    throw TestError.expected
                }
                return Self.readyStatus
            },
            registerAgent: {
                events.append("register-mac")
                registrationState = .enabled
            },
            unregisterAgent: {
                events.append("unregister-mac")
                registrationState = .notRegistered
            }
        )

        await store.bootstrap()

        XCTAssertEqual(events.values, ["unregister-mac", "register-mac"])
        XCTAssertEqual(statusEvents.values, ["status", "status"])
        XCTAssertEqual(store.owner, .macApp)
        XCTAssertEqual(store.lifecycle, .ready)
    }

    func testEnabledRegistrationWithStoppedProcessRepairsWithoutUserAction() async {
        let events = EventRecorder()
        let statusCalls = CallCounter()
        var registrationState = ServiceRegistrationState.enabled
        let store = makeStore(
            configExists: true,
            agentStatus: { registrationState },
            status: {
                statusCalls.increment() == 1 ? Self.stoppedStatus : Self.readyStatus
            },
            registerAgent: {
                events.append("register-mac")
                registrationState = .enabled
            },
            unregisterAgent: {
                events.append("unregister-mac")
                registrationState = .notRegistered
            },
            healthCheck: { _ in false }
        )

        await store.bootstrap()

        XCTAssertEqual(events.values, ["unregister-mac", "register-mac"])
        XCTAssertEqual(statusCalls.current, 2)
        XCTAssertEqual(store.owner, .macApp)
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertNil(store.lastError)
    }

    /// 覆盖安装后 launchd 可能沿用旧 Launch Constraint，每 3 秒 spawn 失败一次。
    /// 只要 launchd 自己已报告反复失败，就应在少量轮询后立即换代，而不是等满整轮。
    func testLaunchdSpawnFailureTriggersImmediateReregistration() async {
        let events = EventRecorder()
        let statusCalls = CallCounter()
        let launchFailureCalls = CallCounter()
        let registrationAttempts = CallCounter()
        var registrationState = ServiceRegistrationState.notRegistered
        let store = makeStore(
            configExists: true,
            agentStatus: { registrationState },
            status: {
                _ = statusCalls.increment()
                return registrationAttempts.current >= 2 ? Self.readyStatus : Self.stoppedStatus
            },
            registerAgent: {
                let attempt = registrationAttempts.increment()
                events.append("register-\(attempt)")
                registrationState = .enabled
            },
            unregisterAgent: {
                events.append("unregister-mac")
                registrationState = .notRegistered
            },
            agentLaunchFailure: {
                _ = launchFailureCalls.increment()
                return registrationAttempts.current == 1
                    ? "launchd 无法启动 agentd，已连续尝试 3 次，最近退出码 78"
                    : nil
            },
            healthCheck: { _ in false }
        )

        await store.bootstrap()

        XCTAssertEqual(events.values, ["register-1", "unregister-mac", "register-2"])
        XCTAssertEqual(registrationAttempts.current, 2)
        // 第一次登记只轮询一次 status 就发现 launchd 已在失败循环里，随后换代成功。
        XCTAssertEqual(statusCalls.current, 2)
        XCTAssertEqual(launchFailureCalls.current, 1)
        XCTAssertEqual(store.owner, .macApp)
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertNil(store.startingDetail)
        XCTAssertNil(store.lastError)
    }

    /// 进程存活但尚未就绪的慢启动不会被误判：launchd 没有报告失败时继续等待，
    /// 不做多余的注销与重新登记。
    func testSlowStartWithoutLaunchdFailureKeepsWaitingWithoutRepair() async {
        let events = EventRecorder()
        let statusCalls = CallCounter()
        var registrationState = ServiceRegistrationState.notRegistered
        let store = makeStore(
            configExists: true,
            agentStatus: { registrationState },
            status: {
                statusCalls.increment() >= 3 ? Self.readyStatus : Self.stoppedStatus
            },
            registerAgent: {
                events.append("register-mac")
                registrationState = .enabled
            },
            unregisterAgent: {
                events.append("unregister-mac")
                registrationState = .notRegistered
            },
            agentLaunchFailure: { nil },
            healthCheck: { _ in false }
        )

        await store.bootstrap()

        XCTAssertEqual(events.values, ["register-mac"])
        XCTAssertEqual(statusCalls.current, 3)
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertNil(store.startingDetail)
    }

    /// 自动换代期间菜单栏应显示正在重新登记的说明，而不是“服务已停止”。
    func testAutomaticRepairExposesStartingDetailWhileReregistering() async {
        let observed = EventRecorder()
        let registrationAttempts = CallCounter()
        var registrationState = ServiceRegistrationState.notRegistered
        var store: HostStore?
        let capture = { @MainActor in
            observed.append("\(store?.lifecycle == .starting)|\(store?.startingDetail ?? "nil")")
        }
        store = makeStore(
            configExists: true,
            agentStatus: { registrationState },
            status: {
                registrationAttempts.current >= 2 ? Self.readyStatus : Self.stoppedStatus
            },
            registerAgent: {
                _ = registrationAttempts.increment()
                registrationState = .enabled
            },
            unregisterAgent: {
                await capture()
                registrationState = .notRegistered
            },
            agentLaunchFailure: {
                registrationAttempts.current == 1 ? "launchd 无法启动 agentd，已连续尝试 2 次" : nil
            },
            healthCheck: { _ in false }
        )

        await store?.bootstrap()

        XCTAssertEqual(observed.values, ["true|覆盖安装后正在重新登记后台服务…"])
        XCTAssertEqual(store?.lifecycle, .ready)
        XCTAssertNil(store?.startingDetail)
    }

    /// 启动等待期间每轮 status 都可能返回"未就绪"。这些结果只用于判断是否继续等，
    /// 不能把菜单栏从"正在启动"改成"服务需要处理"或"服务已停止"。
    func testStartupWaitKeepsStartingLifecycleUntilReady() async {
        let observed = EventRecorder()
        let statusCalls = CallCounter()
        var registrationState = ServiceRegistrationState.notRegistered
        var store: HostStore?
        let capture = { @MainActor in
            observed.append(store?.lifecycle.title ?? "nil")
        }
        store = makeStore(
            configExists: true,
            agentStatus: { registrationState },
            status: {
                await capture()
                return statusCalls.increment() >= 3 ? Self.readyStatus : Self.stoppedStatus
            },
            registerAgent: { registrationState = .enabled },
            healthCheck: { _ in false }
        )

        await store?.bootstrap()

        XCTAssertEqual(statusCalls.current, 3)
        XCTAssertEqual(observed.values, ["正在启动", "正在启动", "正在启动"])
        XCTAssertEqual(store?.lifecycle, .ready)
    }

    /// 自动换代后仍拉不起进程时，结果必须是明确的"启动失败"，而不是停留在
    /// 启动中，也不是被轮询结果写成"服务已停止"。
    func testStartupRepairFailureEndsInFailedLifecycle() async {
        let observed = EventRecorder()
        let registrationAttempts = CallCounter()
        var registrationState = ServiceRegistrationState.notRegistered
        var store: HostStore?
        let capture = { @MainActor in
            observed.append(store?.lifecycle.title ?? "nil")
        }
        store = makeStore(
            configExists: true,
            agentStatus: { registrationState },
            status: {
                await capture()
                return Self.stoppedStatus
            },
            registerAgent: {
                _ = registrationAttempts.increment()
                registrationState = .enabled
            },
            unregisterAgent: { registrationState = .notRegistered },
            agentLaunchFailure: { "launchd 无法启动 agentd，已连续尝试 2 次，最近退出码 78" },
            healthCheck: { _ in false }
        )

        await store?.bootstrap()

        XCTAssertEqual(registrationAttempts.current, 2)
        XCTAssertEqual(observed.values, ["正在启动", "正在启动"])
        guard case .failed(let message)? = store?.lifecycle else {
            return XCTFail("换代后仍失败应进入 failed，实际 \(String(describing: store?.lifecycle))")
        }
        XCTAssertTrue(message.contains("自动重新登记后仍未恢复"), message)
        XCTAssertNil(store?.startingDetail)
    }

    /// 配置由更新版本写入时，agentd 会在 3 秒一次的拉起里一直退出码 1。这时必须报
    /// agentd 的真实原因并引导升级安装包，不能改成"服务记录过期"，也不能白做一次换代。
    func testConfigRequiresNewerVersionSkipsRepairAndSurfacesUpgradeHint() async {
        let registrationAttempts = CallCounter()
        var registrationState = ServiceRegistrationState.notRegistered
        var unregisterAttempts = 0
        let store = makeStore(
            configExists: true,
            agentStatus: { registrationState },
            status: { Self.stoppedStatus },
            registerAgent: {
                _ = registrationAttempts.increment()
                registrationState = .enabled
            },
            unregisterAgent: {
                unregisterAttempts += 1
                registrationState = .notRegistered
            },
            agentLaunchFailure: { "launchd 无法启动 agentd，已连续尝试 40 次，最近退出码 1，当前状态 spawn scheduled" },
            configCheck: AgentdConfigCheckClient(
                check: {
                    AgentdConfigCheckResult(
                        ok: false,
                        code: AgentdConfigCheckResult.requiresNewerVersionCode,
                        message: "旧 app_server.transport=\"local\" 不能自动迁移：请升级到最新发布包后重试"
                    )
                },
                agentdURL: URL(filePath: "/tmp/agentd")
            ),
            healthCheck: { _ in false }
        )

        await store.bootstrap()

        guard case .failed(let message) = store.lifecycle else {
            return XCTFail("必须进入 failed，实际 \(String(describing: store.lifecycle))")
        }
        XCTAssertTrue(message.contains("请升级到最新发布包"), message)
        XCTAssertTrue(message.contains("旧 app_server.transport"), message)
        XCTAssertFalse(message.contains("服务记录可能已过期"), message)
        XCTAssertEqual(unregisterAttempts, 0, "配置不可用时换代毫无意义，不得注销已有登记")
        XCTAssertEqual(registrationAttempts.current, 1)
    }

    /// 其它配置坏掉（例如被移除的 stdio transport）时，agentd 的报错才是可执行的下一步。
    /// 这时既不能谎称升级安装包能修好，也不能白做一次换代。
    func testConfigFailureWithoutUpgradeCodeShowsAgentdReasonAndSkipsRepair() async {
        var registrationState = ServiceRegistrationState.notRegistered
        var unregisterAttempts = 0
        let store = makeStore(
            configExists: true,
            agentStatus: { registrationState },
            status: { Self.stoppedStatus },
            registerAgent: { registrationState = .enabled },
            unregisterAgent: {
                unregisterAttempts += 1
                registrationState = .notRegistered
            },
            agentLaunchFailure: { "launchd 无法启动 agentd，已连续尝试 40 次，最近退出码 1" },
            configCheck: AgentdConfigCheckClient(
                check: {
                    AgentdConfigCheckResult(
                        ok: false,
                        code: "config_invalid",
                        message: "app_server.transport=\"stdio\" 已被移除；请执行 agentd setup --force 重置配置"
                    )
                },
                agentdURL: URL(filePath: "/tmp/agentd")
            ),
            healthCheck: { _ in false }
        )

        await store.bootstrap()

        guard case .failed(let message) = store.lifecycle else {
            return XCTFail("必须进入 failed，实际 \(String(describing: store.lifecycle))")
        }
        XCTAssertTrue(message.contains("setup --force"), message)
        XCTAssertFalse(message.contains("请升级到最新发布包"), "最新安装包同样不支持已移除的 transport")
        XCTAssertEqual(unregisterAttempts, 0, "配置不可用时不得注销已有登记")
    }

    func testLaunchFailureDescriptionIgnoresRunningJob() {
        let output = """
        gui/501/com.gaixianggeng.mimi.mac.agentd = {
        \tactive count = 1
        \tpath = /Applications/Mimi Remote Mac.app/Contents/Library/LaunchAgents/com.gaixianggeng.mimi.mac.agentd.plist
        \tstate = running
        \tparent bundle identifier = com.gaixianggeng.mimi.mac
        \truns = 1
        \tpid = 3856
        \tlast exit code = (never exited)
        \tendpoints = {
        \t\t"com.gaixianggeng.mimi.mac.agentd" = {
        \t\t\tstate = active
        \t\t}
        \t}
        \tjob state = running
        }
        """
        XCTAssertNil(ServiceManagementClient.launchFailureDescription(fromLaunchctlOutput: output))
    }

    func testLaunchFailureDescriptionDetectsSpawnFailureLoop() throws {
        let output = """
        gui/501/com.gaixianggeng.mimi.mac.agentd = {
        \tactive count = 0
        \tstate = spawn scheduled
        \tparent bundle identifier = com.gaixianggeng.mimi.mac
        \truns = 17
        \tlast exit code = 78
        \tendpoints = {
        \t\t"com.gaixianggeng.mimi.mac.agentd" = {
        \t\t\tstate = active
        \t\t}
        \t}
        \tjob state = spawn scheduled
        }
        """
        let detail = try XCTUnwrap(
            ServiceManagementClient.launchFailureDescription(fromLaunchctlOutput: output)
        )
        XCTAssertTrue(detail.contains("17 次"), detail)
        XCTAssertTrue(detail.contains("78"), detail)
        XCTAssertEqual(
            ServiceLifecycleError.agentSpawnFailed(detail).errorDescription?.contains("请升级到最新发布包后重试"),
            true
        )
    }

    func testLaunchFailureDescriptionIgnoresFirstSpawnAndMissingJob() {
        let firstSpawn = """
        gui/501/com.gaixianggeng.mimi.mac.agentd = {
        \tstate = spawn scheduled
        \truns = 1
        \tlast exit code = (never exited)
        }
        """
        XCTAssertNil(ServiceManagementClient.launchFailureDescription(fromLaunchctlOutput: firstSpawn))
        XCTAssertNil(
            ServiceManagementClient.launchFailureDescription(
                fromLaunchctlOutput: "Could not find service \"com.gaixianggeng.mimi.mac.agentd\" in domain for login: 100015",
                exitStatus: 113
            )
        )
        XCTAssertNil(ServiceManagementClient.launchFailureDescription(fromLaunchctlOutput: ""))
    }

    /// KeepAlive 服务有序退出（退出码 0）后到下一次拉起之间也没有 pid；只跑过一次时
    /// 不能当成失败循环，否则会把一次正常退出变成不必要的注销与重新登记。
    func testLaunchFailureDescriptionIgnoresSingleCleanExit() throws {
        let cleanExit = """
        gui/501/com.gaixianggeng.mimi.mac.agentd = {
        \tstate = not running
        \truns = 1
        \tlast exit code = 0
        }
        """
        XCTAssertNil(ServiceManagementClient.launchFailureDescription(fromLaunchctlOutput: cleanExit))

        let abnormalFirstExit = """
        gui/501/com.gaixianggeng.mimi.mac.agentd = {
        \tstate = spawn scheduled
        \truns = 1
        \tlast exit code = 78: EX_CONFIG
        }
        """
        let detail = try XCTUnwrap(
            ServiceManagementClient.launchFailureDescription(fromLaunchctlOutput: abnormalFirstExit)
        )
        XCTAssertTrue(detail.contains("78"), detail)

        let cleanExitLoop = """
        gui/501/com.gaixianggeng.mimi.mac.agentd = {
        \tstate = spawn scheduled
        \truns = 4
        \tlast exit code = 0
        }
        """
        let loopDetail = try XCTUnwrap(
            ServiceManagementClient.launchFailureDescription(fromLaunchctlOutput: cleanExitLoop)
        )
        XCTAssertTrue(loopDetail.contains("4 次"), loopDetail)
        XCTAssertFalse(loopDetail.contains("退出码"), loopDetail)
    }

    func testAgentConfigurationValidatorChecksPlistAndExecutable() throws {
        let fileManager = FileManager.default
        let bundleURL = fileManager.temporaryDirectory
            .appending(path: "mimi-agent-bundle-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: bundleURL) }

        XCTAssertTrue(
            ServiceManagementClient.validateAgentConfiguration(bundleURL: bundleURL)?
                .contains("缺少 LaunchAgent 配置") == true
        )

        let launchAgentsURL = bundleURL.appending(
            path: "Contents/Library/LaunchAgents",
            directoryHint: .isDirectory
        )
        let resourcesURL = bundleURL.appending(path: "Contents/Resources", directoryHint: .isDirectory)
        let macOSURL = bundleURL.appending(path: "Contents/MacOS", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: launchAgentsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: macOSURL, withIntermediateDirectories: true)

        let propertyList: [String: Any] = [
            "Label": "com.gaixianggeng.mimi.mac.agentd",
            "BundleProgram": "Contents/MacOS/Mimi Remote Mac",
            "ProgramArguments": ["Mimi Remote Mac", "--agentd-supervisor"],
            "LimitLoadToSessionType": "Aqua",
        ]
        let propertyListData = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )
        try propertyListData.write(
            to: launchAgentsURL.appending(path: "com.gaixianggeng.mimi.mac.agentd.plist")
        )

        let executableURL = resourcesURL.appending(path: "agentd")
        try Data().write(to: executableURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        let supervisorURL = macOSURL.appending(path: "Mimi Remote Mac")
        try Data().write(to: supervisorURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: supervisorURL.path)

        let signingIdentity: (URL) -> CodeSigningIdentity? = { url in
            if url == bundleURL {
                return CodeSigningIdentity(
                    identifier: "com.gaixianggeng.mimi.mac",
                    teamIdentifier: "9HZ89R58PZ"
                )
            }
            if url == executableURL {
                return CodeSigningIdentity(
                    identifier: "com.gaixianggeng.mimi.mac.agentd",
                    teamIdentifier: "9HZ89R58PZ"
                )
            }
            return nil
        }
        XCTAssertNil(
            ServiceManagementClient.validateAgentConfiguration(
                bundleURL: bundleURL,
                signingIdentityProvider: signingIdentity
            )
        )
        var missingSessionType = propertyList
        missingSessionType.removeValue(forKey: "LimitLoadToSessionType")
        try PropertyListSerialization.data(
            fromPropertyList: missingSessionType,
            format: .xml,
            options: 0
        ).write(to: launchAgentsURL.appending(path: "com.gaixianggeng.mimi.mac.agentd.plist"))
        XCTAssertTrue(
            ServiceManagementClient.validateAgentConfiguration(
                bundleURL: bundleURL,
                signingIdentityProvider: signingIdentity
            )?.contains("配置无效") == true
        )
        try propertyListData.write(
            to: launchAgentsURL.appending(path: "com.gaixianggeng.mimi.mac.agentd.plist")
        )
        XCTAssertTrue(
            ServiceManagementClient.validateAgentConfiguration(
                bundleURL: bundleURL,
                signingIdentityProvider: { url in
                    if url == bundleURL {
                        return CodeSigningIdentity(
                            identifier: "com.gaixianggeng.mimi.mac",
                            teamIdentifier: nil
                        )
                    }
                    return signingIdentity(url)
                }
            )?.contains("ad-hoc") == true
        )
        XCTAssertTrue(
            ServiceManagementClient.validateAgentConfiguration(
                bundleURL: bundleURL,
                signingIdentityProvider: { url in
                    if url == executableURL {
                        return CodeSigningIdentity(
                            identifier: "com.gaixianggeng.mimi.mac.agentd",
                            teamIdentifier: "OTHERTEAM"
                        )
                    }
                    return signingIdentity(url)
                }
            )?.contains("签名团队不一致") == true
        )

        // 旧定义直接启动裸 agentd，主 App 无法承担隐私授权责任，必须视为无效安装。
        for legacyDefinition in [
            ["BundleProgram": "Contents/Resources/agentd", "ProgramArguments": ["agentd", "serve"]],
            ["BundleProgram": "Contents/MacOS/Mimi Remote Mac", "ProgramArguments": ["Mimi Remote Mac", "--agentd-supervisor", "extra"]],
        ] as [[String: Any]] {
            var invalidPropertyList = propertyList
            invalidPropertyList.merge(legacyDefinition) { _, new in new }
            try PropertyListSerialization.data(
                fromPropertyList: invalidPropertyList,
                format: .xml,
                options: 0
            ).write(to: launchAgentsURL.appending(path: "com.gaixianggeng.mimi.mac.agentd.plist"))
            XCTAssertTrue(
                ServiceManagementClient.validateAgentConfiguration(
                    bundleURL: bundleURL,
                    signingIdentityProvider: signingIdentity
                )?.contains("配置无效") == true,
                "\(legacyDefinition)"
            )
        }
    }

    func testAgentdSupervisorOnlyAcceptsExactInvocationAndBuildsFixedCommand() {
        XCTAssertTrue(AgentdSupervisorInvocation.matches(["app", "--agentd-supervisor"]))
        XCTAssertFalse(AgentdSupervisorInvocation.matches(["app", "--agentd-supervisor", "extra"]))
        XCTAssertFalse(AgentdSupervisorInvocation.matches(["app", "--other"]))
        XCTAssertTrue(AgentdSupervisorInvocation.isRequested(["app", "--other", "--agentd-supervisor"]))
        XCTAssertFalse(AgentdSupervisorInvocation.isRequested(["--agentd-supervisor"]))

        let command = AgentdSupervisorCommand.fixed(
            bundleURL: URL(fileURLWithPath: "/Applications/Mimi Remote Mac.app"),
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester")
        )
        XCTAssertEqual(
            command.executableURL.path,
            "/Applications/Mimi Remote Mac.app/Contents/Resources/agentd"
        )
        XCTAssertEqual(command.arguments, [
            "/Applications/Mimi Remote Mac.app/Contents/Resources/agentd",
            "serve",
            "--log-file",
            "/Users/tester/Library/Logs/mimi-remote/agentd.log",
        ])
    }

    func testAgentLaunchDefinitionMatchesBundledPlist() throws {
        // 仓库里的 LaunchAgent 与校验器、supervisor 入口必须保持同一份定义。
        let plistURL = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Resources/LaunchAgents/com.gaixianggeng.mimi.mac.agentd.plist")
        let data = try Data(contentsOf: plistURL)
        let dictionary = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(dictionary["BundleProgram"] as? String, ServiceManagementClient.supervisorBundleProgram)
        XCTAssertEqual(dictionary["ProgramArguments"] as? [String], ServiceManagementClient.supervisorProgramArguments)
        XCTAssertEqual(dictionary["LimitLoadToSessionType"] as? String, ServiceManagementClient.agentSessionType)
        XCTAssertEqual(ServiceManagementClient.agentLaunchDefinitionRevision, "agentd-supervisor-v2-aqua")
    }

    func testAgentdSupervisorMapsChildExitAndSignalStatus() {
        XCTAssertEqual(AgentdSupervisor.exitCode(forWaitStatus: 7 << 8), 7)
        XCTAssertEqual(AgentdSupervisor.exitCode(forWaitStatus: SIGTERM), 128 + SIGTERM)
        XCTAssertEqual(AgentdSupervisor.exitCode(forWaitStatus: SIGINT), 128 + SIGINT)
    }

    func testAgentdSupervisorKillsSuspendedChildWhenSignalArrivesBeforeAttach() {
        let events = EventRecorder()
        let relay = AgentdSupervisorSignalRelay(
            installSystemSignals: false,
            signalSender: { pid, signalNumber in
                events.append("\(pid):\(signalNumber)")
            }
        )

        relay.receive(SIGTERM)
        XCTAssertEqual(relay.attach(childPID: 42), SIGTERM)
        XCTAssertEqual(events.values, ["42:\(SIGKILL)"])

        relay.receive(SIGINT)
        XCTAssertEqual(events.values, ["42:\(SIGKILL)", "42:\(SIGINT)"])
        relay.detach(childPID: 42)
        relay.receive(SIGHUP)
        XCTAssertEqual(events.values, ["42:\(SIGKILL)", "42:\(SIGINT)"])
    }

    func testAgentdSupervisorBuildsMinimalTrustedEnvironment() {
        let environment = AgentdSupervisorEnvironment.sanitized(
            homeDirectory: "/Users/tester",
            temporaryDirectory: "/var/folders/trusted/T/",
            userName: "tester",
            shell: "/bin/zsh",
            parentEnvironment: [
                "SSH_AUTH_SOCK": "/private/tmp/ssh-agent.sock",
                "LANG": "zh_CN.UTF-8",
                "AGENTD_BROWSE_ROOTS": "/",
                "AGENTD_DEV_INSECURE": "1",
                "NODE_OPTIONS": "--require=/tmp/inject.js",
                "CLAUDE_BRIDGE_CLAUDE_BIN": "/tmp/fake-claude",
                "MIMI_REMOTE_TCC_OWNER": "com.example.spoofed",
            ]
        )
        XCTAssertEqual(environment, [
            "HOME=/Users/tester",
            "PATH=/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR=/var/folders/trusted/T/",
            "USER=tester",
            "LOGNAME=tester",
            "SHELL=/bin/zsh",
            "MIMI_REMOTE_TCC_OWNER=com.gaixianggeng.mimi.mac",
            "SSH_AUTH_SOCK=/private/tmp/ssh-agent.sock",
            "LANG=zh_CN.UTF-8",
        ])
        for forbiddenKey in [
            "AGENTD_BROWSE_ROOTS",
            "AGENTD_DEV_INSECURE",
            "NODE_OPTIONS",
            "CLAUDE_BRIDGE_CLAUDE_BIN",
        ] {
            XCTAssertFalse(environment.contains { $0.hasPrefix("\(forbiddenKey)=") })
        }
    }

    func testAgentdSupervisorRejectsSymlinkedAgentd() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appending(
            path: "mimi-supervisor-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? fileManager.removeItem(at: directory) }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let executableURL = directory.appending(path: "real-agentd")
        try Data().write(to: executableURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        let symlinkURL = directory.appending(path: "agentd")
        try fileManager.createSymbolicLink(at: symlinkURL, withDestinationURL: executableURL)

        let identity: (URL) -> CodeSigningIdentity? = { _ in
            CodeSigningIdentity(
                identifier: "com.gaixianggeng.mimi.mac.agentd",
                teamIdentifier: "9HZ89R58PZ"
            )
        }
        XCTAssertTrue(AgentdSupervisor.validateAgentd(
            at: executableURL,
            teamIdentifier: "9HZ89R58PZ",
            identityProvider: identity
        ))
        XCTAssertFalse(AgentdSupervisor.validateAgentd(
            at: symlinkURL,
            teamIdentifier: "9HZ89R58PZ",
            identityProvider: identity
        ))
        XCTAssertFalse(AgentdSupervisor.validateAgentd(
            at: executableURL,
            teamIdentifier: "OTHERTEAM",
            identityProvider: identity
        ))
    }

    func testPhotosAccessRequestsOnlyWhenUndeterminedAndOpensSettingsAfterDenial() async {
        let events = EventRecorder()
        var current: PhotosAccessState = .notDetermined
        let privacy = SystemPrivacySettingsClient(
            openFullDiskAccessSettings: { events.append("fda") },
            photosAccessState: { current },
            requestPhotosAccess: {
                events.append("request")
                current = .authorized
                return .authorized
            },
            openPhotosPrivacySettings: { events.append("settings") }
        )
        let store = makeStore(configExists: true, systemPrivacySettings: privacy)

        store.refreshPhotosAccess()
        XCTAssertEqual(store.photosAccess, .notDetermined)
        await store.requestPhotosAccess()
        XCTAssertEqual(store.photosAccess, .authorized)
        XCTAssertEqual(events.values, ["request"])

        // 已允许时不再重复请求。
        await store.requestPhotosAccess()
        XCTAssertEqual(events.values, ["request"])

        // 拒绝后系统不会再弹框，只能打开隐私设置。
        current = .denied
        await store.requestPhotosAccess()
        XCTAssertEqual(store.photosAccess, .denied)
        XCTAssertEqual(events.values, ["request", "settings"])
    }

    func testFileAccessPresentationFollowsTheServiceThatReadsFiles() {
        // App 托管：照片状态与操作来自 Mimi Remote Mac 的授权。
        let appUndetermined = FileAccessSettingsPresentation.make(owner: .macApp, photosAccess: .notDetermined)
        XCTAssertEqual(appUndetermined.photosStatus, "尚未请求")
        XCTAssertEqual(appUndetermined.photosAction, .requestPhotosAccess)
        XCTAssertEqual(
            FileAccessSettingsPresentation.make(owner: .macApp, photosAccess: .denied).photosAction,
            .openPhotosPrivacySettings
        )
        XCTAssertNil(FileAccessSettingsPresentation.make(owner: .macApp, photosAccess: .authorized).photosAction)
        XCTAssertTrue(appUndetermined.fullDiskAccessCaption.contains("Mimi Remote Mac"))

        // Homebrew：无论 App 自己的照片授权是什么，都不展示“已允许”或照片授权操作。
        for appState in [PhotosAccessState.notDetermined, .authorized, .limited, .denied, .restricted] {
            let homebrew = FileAccessSettingsPresentation.make(owner: .homebrew, photosAccess: appState)
            XCTAssertNil(homebrew.photosAction, "\(appState)")
            XCTAssertNotEqual(homebrew.photosStatus, appState.title, "\(appState)")
            XCTAssertEqual(homebrew.photosStatus, "由完全磁盘访问控制")
            XCTAssertTrue(homebrew.photosCaption.contains("完全磁盘访问"))
            XCTAssertTrue(homebrew.fullDiskAccessCaption.contains(FileAccessSettingsPresentation.homebrewAgentdPath))
        }
    }

    func testHomebrewOwnerNeverRequestsAppPhotosAuthorization() async {
        let events = EventRecorder()
        let privacy = SystemPrivacySettingsClient(
            openFullDiskAccessSettings: { events.append("fda") },
            photosAccessState: { .notDetermined },
            requestPhotosAccess: {
                events.append("request")
                return .authorized
            },
            openPhotosPrivacySettings: { events.append("settings") }
        )
        let store = makeStore(
            configExists: true,
            homebrewLoaded: true,
            status: { Self.readyStatus },
            systemPrivacySettings: privacy
        )
        await store.bootstrap()
        XCTAssertEqual(store.owner, .homebrew)

        await store.requestPhotosAccess()

        XCTAssertEqual(events.values, ["fda"])
    }

    func testBootstrapRequiresSetupWhenConfigIsMissing() async {
        let store = makeStore(configExists: false)

        await store.bootstrap()

        XCTAssertEqual(store.lifecycle, .notConfigured)
        XCTAssertEqual(store.owner, .none)
    }

    func testBootstrapAutoEnablesClaudeAndReloadsRunningMacAgent() async {
        let events = EventRecorder()
        let registration = LaggingAgentRegistration()
        let store = makeStore(
            configExists: true,
            agentStatus: { registration.nextStatus() },
            registerAgent: { events.append("register-mac") },
            unregisterAgent: { events.append("unregister-mac") },
            configureClaude: { preference, _ in
                events.append("configure-\(preference.rawValue)")
                return Self.claudeConfiguration(
                    enabled: true,
                    preference: .automatic,
                    previousEnabled: false,
                    previousPreference: .automatic,
                    changed: true,
                    restartRequired: true
                )
            },
            healthCheck: { _ in false }
        )

        await store.bootstrap()

        XCTAssertEqual(events.values, [
            "configure-auto", "unregister-mac", "register-mac",
        ])
        XCTAssertTrue(store.claudeEnabled)
        XCTAssertEqual(store.owner, .macApp)
        XCTAssertEqual(store.lifecycle, .ready)
    }

    func testFirstLaunchConfiguresClaudeBeforeSingleAgentRegistration() async {
        let events = EventRecorder()
        var registrationState = ServiceRegistrationState.notRegistered
        let store = makeStore(
            configExists: true,
            agentStatus: { registrationState },
            status: { Self.statusWithClaude(enabled: true, state: .connected) },
            registerAgent: {
                events.append("register-mac")
                registrationState = .enabled
            },
            configureClaude: { preference, _ in
                events.append("configure-\(preference.rawValue)")
                return Self.claudeConfiguration(
                    enabled: true,
                    preference: .automatic,
                    previousEnabled: false,
                    previousPreference: .automatic,
                    changed: true,
                    restartRequired: true
                )
            }
        )

        await store.bootstrap()

        XCTAssertEqual(events.values, ["configure-auto", "register-mac"])
        XCTAssertEqual(store.owner, .macApp)
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertTrue(store.claudeEnabled)
        XCTAssertEqual(store.status?.runtimeStatus?.runtimes.first?.state, .connected)
    }

    func testDisablingClaudeReloadsServiceAndWaitsForDisabledRuntime() async {
        let events = EventRecorder()
        let disabledStatus = Self.statusWithClaude(enabled: false, state: .disabled)
        let store = makeStore(
            configExists: true,
            status: { disabledStatus },
            registerAgent: { events.append("register-mac") },
            configureClaude: { preference, restoreEnabled in
                events.append("configure-\(preference.rawValue)")
                if preference == .automatic {
                    return Self.claudeConfiguration(enabled: true, preference: .enabled)
                }
                return Self.claudeConfiguration(
                    enabled: restoreEnabled ?? false,
                    preference: preference,
                    previousEnabled: true,
                    previousPreference: .enabled,
                    changed: true,
                    restartRequired: true
                )
            }
        )
        await store.bootstrap()

        await store.setClaudeEnabled(false)

        XCTAssertEqual(events.values, [
            "configure-auto", "register-mac", "configure-disabled", "register-mac",
        ])
        XCTAssertFalse(store.claudeEnabled)
        XCTAssertNil(store.claudeError)
        XCTAssertEqual(store.lifecycle, .ready)
    }

    func testClaudeServiceReloadFailureRestoresPreviousConfiguration() async {
        let events = EventRecorder()
        let registrations = CallCounter()
        let enabledStatus = Self.statusWithClaude(enabled: true, state: .connected)
        let store = makeStore(
            configExists: true,
            status: { enabledStatus },
            registerAgent: {
                let call = registrations.increment()
                events.append("register-\(call)")
                if call == 2 {
                    throw TestError.expected
                }
            },
            configureClaude: { preference, _ in
                events.append("configure-\(preference.rawValue)")
                if preference == .automatic {
                    return Self.claudeConfiguration(enabled: true, preference: .enabled)
                }
                return Self.claudeConfiguration(
                    enabled: false,
                    preference: .disabled,
                    previousEnabled: true,
                    previousPreference: .enabled,
                    changed: true,
                    restartRequired: true
                )
            },
            restoreClaude: { _ in
                events.append("restore-claude")
                return Self.claudeConfiguration(
                    enabled: true,
                    preference: .enabled,
                    previousEnabled: false,
                    previousPreference: .disabled,
                    changed: true,
                    restartRequired: true,
                    reason: "restored"
                )
            }
        )
        await store.bootstrap()

        await store.setClaudeEnabled(false)

        XCTAssertEqual(events.values, [
            "configure-auto",
            "register-1",
            "configure-disabled",
            "register-2",
            "restore-claude",
            "register-3",
        ])
        XCTAssertTrue(store.claudeEnabled)
        XCTAssertTrue(store.claudeError?.contains("已恢复修改前") == true)
        XCTAssertEqual(store.lifecycle, .ready)
    }

    func testBootstrapDetectsRunningHomebrewServiceWithoutChangingIt() async {
        let store = makeStore(configExists: true, homebrewLoaded: true)

        await store.bootstrap()

        XCTAssertEqual(store.lifecycle, .migrationRequired)
        XCTAssertEqual(store.owner, .homebrew)
        XCTAssertTrue(store.homebrewLoaded)
    }

    func testTakeoverRejectsInvalidAppBeforeStoppingHomebrew() async {
        let events = EventRecorder()
        let message = "当前 App 是未签名或 ad-hoc 结构快照，不能启动 macOS 后台服务。"
        let store = makeStore(
            configExists: true,
            homebrewLoaded: true,
            agentConfigurationError: { message },
            registerAgent: { events.append("register-mac") },
            homebrewStop: { events.append("stop-homebrew") }
        )
        await store.bootstrap()

        await store.takeOverHomebrew()

        XCTAssertEqual(events.values, [])
        XCTAssertEqual(store.owner, .homebrew)
        XCTAssertEqual(store.lifecycle, .migrationRequired)
        XCTAssertEqual(store.lastError, message)
    }

    func testFailedTakeoverRestoresHomebrewAutomatically() async {
        let events = EventRecorder()
        let store = makeStore(
            configExists: true,
            homebrewLoaded: true,
            registerAgent: {
                events.append("register-mac")
                throw TestError.expected
            },
            unregisterAgent: { events.append("unregister-mac") },
            homebrewStart: { events.append("start-homebrew") },
            homebrewStop: { events.append("stop-homebrew") }
        )
        await store.bootstrap()

        await store.takeOverHomebrew()

        XCTAssertEqual(events.values, [
            "stop-homebrew", "register-mac", "unregister-mac", "start-homebrew",
        ])
        XCTAssertEqual(store.owner, .homebrew)
        XCTAssertEqual(store.lifecycle, .migrationRequired)
        XCTAssertTrue(store.lastError?.contains("已恢复 Homebrew 服务") == true)
    }

    func testPairingFailureDoesNotRollBackSuccessfulTakeover() async {
        let events = EventRecorder()
        let store = makeStore(
            configExists: true,
            homebrewLoaded: true,
            registerAgent: { events.append("register-mac") },
            homebrewStart: { events.append("start-homebrew") },
            homebrewStop: { events.append("stop-homebrew") },
            pair: { _ in throw TestError.expected }
        )
        await store.bootstrap()

        await store.takeOverHomebrew()

        XCTAssertEqual(events.values, ["stop-homebrew", "register-mac"])
        XCTAssertEqual(store.owner, .macApp)
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertTrue(store.lastError?.contains("服务接管成功") == true)
    }

    func testSelectingDisabledLANDoesNotMutateAccessOrRestartService() async {
        let events = EventRecorder()
        let store = makeStore(
            configExists: true,
            registerAgent: { events.append("register") },
            unregisterAgent: { events.append("unregister") },
            setLANAccess: { enabled in
                events.append("lan-\(enabled)")
                return NetworkConfigurationResult(lanEnabled: enabled, changed: true, restartRequired: true)
            },
            pair: { network in
                events.append("pair-\(network.rawValue)")
                return Self.pairing
            }
        )
        await store.bootstrap()
        await store.refreshPairing(network: .localNetwork)
        XCTAssertEqual(events.values, ["register"])
        XCTAssertNil(store.pairing)
        XCTAssertNotNil(store.lastError)
    }

    func testAutomaticPairingFailureDoesNotEnableLAN() async {
        let events = EventRecorder()
        let store = makeStore(
            configExists: true,
            registerAgent: { events.append("register") },
            setLANAccess: { enabled in
                events.append("lan-\(enabled)")
                return NetworkConfigurationResult(lanEnabled: enabled, changed: true, restartRequired: true)
            },
            pair: { network in
                events.append("pair-\(network.rawValue)")
                throw TestError.expected
            }
        )
        await store.bootstrap()
        await store.refreshPairing()
        XCTAssertEqual(events.values, ["register", "pair-auto"])
        XCTAssertNil(store.pairing)
        XCTAssertNotNil(store.lastError)
    }

    func testLatestPairingRefreshWinsWhenAutomaticRequestFinishesLast() async {
        let gate = SuspendedStatusGate()
        let automaticCalls = CallCounter()
        let automaticPairing = PairingInfo(
            endpoint: "http://100.64.0.8:8787",
            network: .tailscale,
            pairURL: "mimiremote://pair?pair_sig=automatic",
            expiresAt: "2026-09-03T12:00:00Z",
            warnings: []
        )
        let tailcatPairing = PairingInfo(
            endpoint: "http://127.0.0.1:8787",
            network: .tailcat,
            pairURL: "mimiremote://pair?transport=tailcat",
            expiresAt: "2026-09-03T12:00:00Z",
            warnings: []
        )
        let store = makeStore(
            configExists: true,
            pair: { network in
                if network == .automatic {
                    _ = automaticCalls.increment()
                    return await gate.suspendReturning(automaticPairing)
                }
                return tailcatPairing
            }
        )
        await store.bootstrap()

        let automaticRefresh = Task { await store.refreshPairing() }
        await gate.waitUntilSuspended()
        await store.refreshPairing(network: .tailcat)
        gate.resume()
        await automaticRefresh.value

        XCTAssertEqual(store.pairingNetwork, .tailcat)
        XCTAssertEqual(store.pairing, tailcatPairing)
    }

    func testConfiguringTailcatRelayUpdatesStatusAndClearsOldPairing() async {
        let events = EventRecorder()
        let defaultStatus = TailcatStatus(
            enabled: true,
            running: true,
            version: "v0.3.0",
            derpMapURL: nil,
            pairedDeviceCount: 1,
            error: nil
        )
        let customStatus = TailcatStatus(
            enabled: true,
            running: true,
            version: "v0.3.0",
            derpMapURL: "https://relay.example/derpmap/default",
            pairedDeviceCount: 0,
            error: nil
        )
        let tailcatPairing = PairingInfo(
            endpoint: "http://127.0.0.1:8787",
            network: .tailcat,
            pairURL: "mimiremote://pair?transport=tailcat",
            expiresAt: "2026-09-02T02:00:00Z",
            warnings: []
        )
        let store = makeStore(
            configExists: true,
            agentStatus: { .enabled },
            pair: { _ in tailcatPairing },
            tailcatStatus: { defaultStatus },
            configureTailcatDERPMap: { url in
                events.append(url)
                return customStatus
            }
        )

        await store.bootstrap()
        await store.refreshTailcatStatus()
        await store.refreshPairing(network: .tailcat)
        await store.configureTailcatDERPMap("https://relay.example/derpmap/default")

        XCTAssertEqual(events.values, ["https://relay.example/derpmap/default"])
        XCTAssertEqual(store.tailcatDERPMapURL, "https://relay.example/derpmap/default")
        XCTAssertEqual(store.tailcatStatus?.pairedDeviceCount, 0)
        XCTAssertNil(store.pairing)
        XCTAssertEqual(store.pairingNetwork, .tailscale)
        XCTAssertEqual(store.tailcatNotice, "中继已更新。请重新生成二维码，并在移动设备上扫码。")
    }

    func testRefreshingTailcatStatusClearsRelayNoticeAndShowsRuntimeError() async {
        let customStatus = TailcatStatus(
            enabled: true,
            running: true,
            version: "v0.3.0",
            derpMapURL: "https://relay.example/derpmap/default",
            pairedDeviceCount: 0,
            error: nil
        )
        let failedStatus = TailcatStatus(
            enabled: true,
            running: false,
            version: "v0.3.0",
            derpMapURL: "https://relay.example/derpmap/default",
            pairedDeviceCount: 0,
            error: "Tailcat sidecar 已退出"
        )
        let statusCalls = CallCounter()
        let store = makeStore(
            configExists: true,
            agentStatus: { .enabled },
            tailcatStatus: {
                statusCalls.increment() == 1 ? customStatus : failedStatus
            },
            configureTailcatDERPMap: { _ in customStatus }
        )

        await store.bootstrap()
        await store.refreshTailcatStatus()
        await store.configureTailcatDERPMap("https://relay.example/derpmap/default")
        XCTAssertNotNil(store.tailcatNotice)

        await store.refreshTailcatStatus()

        XCTAssertNil(store.tailcatNotice)
        XCTAssertEqual(store.tailcatStatusDetail, "Tailcat sidecar 已退出")
    }

    func testTailcatRefreshCannotStartWhileToggleIsInFlight() async {
        let mutationGate = SuspendedStatusGate()
        let statusCalls = CallCounter()
        let enabledStatus = TailcatStatus(
            enabled: true, running: true, version: "v0.3.0",
            derpMapURL: nil, pairedDeviceCount: 1, error: nil
        )
        let disabledStatus = TailcatStatus(
            enabled: false, running: false, version: "v0.3.0",
            derpMapURL: nil, pairedDeviceCount: 1, error: nil
        )
        let store = makeStore(
            configExists: true,
            agentStatus: { .enabled },
            tailcatStatus: {
                _ = statusCalls.increment()
                return enabledStatus
            },
            setTailcatEnabled: { _ in
                await mutationGate.suspendReturning(disabledStatus)
            }
        )
        await store.bootstrap()
        await store.refreshTailcatStatus()

        let toggle = Task { await store.setTailcatEnabled(false) }
        await mutationGate.waitUntilSuspended()
        await store.refreshTailcatStatus()
        XCTAssertEqual(statusCalls.current, 1, "修改期间不得启动会覆盖结果的状态读取")
        mutationGate.resume()
        await toggle.value

        XCTAssertFalse(store.tailcatEnabled)
        XCTAssertEqual(store.tailcatStatus?.running, false)
    }

    func testTailcatMutationRejectsOlderRefreshResult() async {
        let staleRefreshGate = SuspendedStatusGate()
        let enabledStatus = TailcatStatus(
            enabled: true, running: true, version: "v0.3.0",
            derpMapURL: nil, pairedDeviceCount: 1, error: nil
        )
        let disabledStatus = TailcatStatus(
            enabled: false, running: false, version: "v0.3.0",
            derpMapURL: nil, pairedDeviceCount: 1, error: nil
        )
        let store = makeStore(
            configExists: true,
            agentStatus: { .enabled },
            tailcatStatus: { await staleRefreshGate.suspendReturning(enabledStatus) },
            setTailcatEnabled: { _ in disabledStatus }
        )
        await store.bootstrap()

        let staleRefresh = Task { await store.refreshTailcatStatus() }
        await staleRefreshGate.waitUntilSuspended()
        await store.setTailcatEnabled(false)
        staleRefreshGate.resume()
        await staleRefresh.value

        XCTAssertFalse(store.tailcatEnabled)
        XCTAssertFalse(store.availablePairingNetworks.contains(.tailcat))
    }

    func testLatestTailcatRefreshWinsWhenOlderFailureFinishesLast() async {
        let staleRefreshGate = SuspendedStatusGate()
        let latestRefreshGate = SuspendedStatusGate()
        let calls = CallCounter()
        let latestStatus = TailcatStatus(
            enabled: false, running: false, version: "v0.3.0",
            derpMapURL: nil, pairedDeviceCount: 1, error: nil
        )
        let store = makeStore(
            configExists: true,
            agentStatus: { .enabled },
            tailcatStatus: {
                if calls.increment() == 1 {
                    _ = await staleRefreshGate.suspendReturning(false)
                    throw TestError.expected
                }
                return await latestRefreshGate.suspendReturning(latestStatus)
            }
        )
        await store.bootstrap()

        let staleRefresh = Task { await store.refreshTailcatStatus() }
        await staleRefreshGate.waitUntilSuspended()
        let latestRefresh = Task { await store.refreshTailcatStatus() }
        await latestRefreshGate.waitUntilSuspended()
        latestRefreshGate.resume()
        await latestRefresh.value
        staleRefreshGate.resume()
        await staleRefresh.value

        XCTAssertEqual(store.tailcatStatus, latestStatus)
        XCTAssertNil(store.tailcatError)
    }

    func testDoctorKeepsHomebrewMigrationState() async {
        let store = makeStore(configExists: true, homebrewLoaded: true)
        await store.bootstrap()

        await store.runDoctor(fix: false)

        XCTAssertEqual(store.owner, .homebrew)
        XCTAssertEqual(store.lifecycle, .migrationRequired)
    }

    func testDoctorRestartsMacAgentAfterConfigurationRepair() async {
        let events = EventRecorder()
        var registrationState = ServiceRegistrationState.notRegistered
        let store = makeStore(
            configExists: true,
            agentStatus: { registrationState },
            status: {
                events.append("status")
                return Self.readyStatus
            },
            doctor: { fix in
                events.append("doctor-\(fix)")
                return DoctorFixResults(
                    fixes: ["已恢复 Codex CLI 路径"],
                    results: Self.readyStatus.doctor,
                    restartRequired: true
                )
            },
            registerAgent: {
                events.append("register-mac")
                registrationState = .enabled
            },
            unregisterAgent: {
                events.append("unregister-mac")
                registrationState = .notRegistered
            },
            healthCheck: { _ in false }
        )
        await store.bootstrap()

        await store.runDoctor(fix: true)

        XCTAssertEqual(store.owner, .macApp)
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(events.values, [
            "register-mac", "status",
            "doctor-true", "unregister-mac", "register-mac", "status",
        ])
    }

    func testDoctorRestartsHomebrewAfterConfigurationRepair() async {
        let events = EventRecorder()
        let store = makeStore(
            configExists: true,
            homebrewLoaded: true,
            doctor: { fix in
                events.append("doctor-\(fix)")
                return DoctorFixResults(
                    fixes: ["已恢复 Codex CLI 路径"],
                    results: Self.readyStatus.doctor,
                    restartRequired: true
                )
            },
            homebrewStart: { events.append("start-homebrew") },
            homebrewStop: { events.append("stop-homebrew") }
        )
        await store.bootstrap()

        await store.runDoctor(fix: true)

        XCTAssertEqual(store.owner, .homebrew)
        XCTAssertEqual(store.lifecycle, .migrationRequired)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(events.values, [
            "doctor-true", "stop-homebrew", "start-homebrew",
        ])
    }

    func testFailedHomebrewRestoreReturnsToMacAgent() async {
        let events = EventRecorder()
        let store = makeStore(
            configExists: true,
            homebrewLoaded: true,
            registerAgent: { events.append("register-mac") },
            unregisterAgent: { events.append("unregister-mac") },
            homebrewStart: {
                events.append("start-homebrew")
                throw TestError.expected
            },
            homebrewStop: { events.append("stop-homebrew") },
            healthCheck: { _ in false }
        )
        await store.bootstrap()
        await store.takeOverHomebrew()

        await store.restoreHomebrew()

        XCTAssertEqual(store.owner, .macApp)
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertTrue(store.lastError?.contains("已继续使用 App 服务") == true)
        XCTAssertEqual(events.values, [
            "stop-homebrew", "register-mac", "unregister-mac", "start-homebrew",
            "stop-homebrew", "register-mac",
        ])
    }

    func testRestartWaitsForAgentToFinishUnregisteringBeforeRegisteringAgain() async {
        let events = EventRecorder()
        let registration = LaggingAgentRegistration()
        let store = makeStore(
            configExists: true,
            agentStatus: { registration.nextStatus() },
            registerAgent: {
                // 模拟真实 SMAppService：状态仍为 enabled 时，registerAgent 会直接跳过。
                guard registration.nextStatus() != .enabled else { return }
                events.append("register-mac")
            },
            unregisterAgent: { events.append("unregister-mac") },
            healthCheck: { _ in
                events.append("health-stopped")
                return false
            }
        )
        await store.bootstrap()

        await store.restartService()

        XCTAssertEqual(events.values, [
            "unregister-mac", "health-stopped", "register-mac",
        ])
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertEqual(store.owner, .macApp)
    }

    func testStopAndQuitRequestSurvivesMenuDismissalAndWaitsForAgentShutdown() async {
        let events = EventRecorder()
        let terminated = expectation(description: "App terminates after agent shutdown")
        let store = makeStore(
            configExists: true,
            registerAgent: { events.append("register-mac") },
            unregisterAgent: { events.append("unregister-mac") },
            healthCheck: { _ in
                events.append("health-stopped")
                return false
            },
            terminateApplication: {
                events.append("terminate-app")
                terminated.fulfill()
            }
        )
        await store.bootstrap()

        store.requestStopServiceAndQuit()

        XCTAssertTrue(store.isBusy)
        XCTAssertTrue(store.isStoppingForQuit)
        await fulfillment(of: [terminated], timeout: 1)
        XCTAssertEqual(events.values, [
            "register-mac", "unregister-mac", "health-stopped", "terminate-app",
        ])
        XCTAssertEqual(store.lifecycle, .stopped)
        XCTAssertEqual(store.owner, .none)
    }

    func testBootstrapReplacesOutdatedBundledAgentBeforeReportingReady() async {
        let events = EventRecorder()
        let registration = LaggingAgentRegistration()
        let outdated = AgentStatus(
            processOK: true,
            serviceOK: false,
            processError: nil,
            serviceError: "运行中的 agentd 仍是旧构建",
            version: "0.1.5+mac.240",
            serverVersion: "0.1.5+mac.239",
            endpoint: Self.readyStatus.endpoint,
            configPath: Self.readyStatus.configPath,
            projects: Self.readyStatus.projects,
            doctorOK: false,
            doctor: Self.readyStatus.doctor,
            pairExpires: nil
        )
        let store = makeStore(
            configExists: true,
            agentStatus: { registration.nextStatus() },
            status: {
                events.values.contains("register-mac") ? Self.readyStatus : outdated
            },
            registerAgent: { events.append("register-mac") },
            unregisterAgent: { events.append("unregister-mac") },
            healthCheck: { _ in
                events.append("health-stopped")
                return false
            }
        )

        await store.bootstrap()

        XCTAssertEqual(events.values, [
            "unregister-mac", "health-stopped", "register-mac",
        ])
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertEqual(store.owner, .macApp)
    }

    func testBootstrapReregistersEnabledAgentWhenRegistrationRevisionIsStale() async {
        let events = EventRecorder()
        let registration = LaggingAgentRegistration()
        let store = makeStore(
            configExists: true,
            agentStatus: { registration.nextStatus() },
            isAgentRegistrationCurrent: { false },
            markAgentRegistrationCurrent: { events.append("mark-registration") },
            registerAgent: { events.append("register-mac") },
            unregisterAgent: { events.append("unregister-mac") }
        )

        await store.bootstrap()

        XCTAssertEqual(events.values, [
            "unregister-mac", "register-mac", "mark-registration",
        ])
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertEqual(store.owner, .macApp)
    }

    /// 2026-09-14 本机实测：LaunchAgent 从裸 agentd 改为主 App supervisor 后，版本变更路径的
    /// 第一次登记落到带旧 Launch Constraint 的 BTM 记录上，launchd 一直报找不到程序。
    /// 必须自动再换代一次，而不是停在失败循环里等用户重启 App。
    func testStaleRegistrationRevisionRepairsLaunchConstraintFailureOnce() async {
        let events = EventRecorder()
        let registrationAttempts = CallCounter()
        var registrationState = ServiceRegistrationState.enabled
        let store = makeStore(
            configExists: true,
            agentStatus: { registrationState },
            isAgentRegistrationCurrent: { false },
            markAgentRegistrationCurrent: { events.append("mark-registration") },
            status: {
                registrationAttempts.current >= 2 ? Self.readyStatus : Self.stoppedStatus
            },
            registerAgent: {
                let attempt = registrationAttempts.increment()
                events.append("register-\(attempt)")
                registrationState = .enabled
            },
            unregisterAgent: {
                events.append("unregister-mac")
                registrationState = .notRegistered
            },
            agentLaunchFailure: {
                registrationAttempts.current == 1
                    ? "launchd 无法启动 agentd，已连续尝试 2 次，最近退出码 78"
                    : nil
            },
            healthCheck: { _ in false }
        )

        await store.bootstrap()

        XCTAssertEqual(events.values, [
            "unregister-mac", "register-1", "unregister-mac", "register-2", "mark-registration",
        ])
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertEqual(store.owner, .macApp)
        XCTAssertNil(store.lastError)
    }

    func testBootstrapReusesEnabledAgentWhenRegistrationRevisionIsCurrent() async {
        let events = EventRecorder()
        let store = makeStore(
            configExists: true,
            agentStatus: { .enabled },
            isAgentRegistrationCurrent: { true },
            markAgentRegistrationCurrent: { events.append("mark-registration") },
            status: {
                events.append("status")
                return Self.readyStatus
            },
            registerAgent: { events.append("register-mac") },
            unregisterAgent: { events.append("unregister-mac") }
        )

        await store.bootstrap()

        XCTAssertEqual(events.values, ["status"])
        XCTAssertEqual(store.lifecycle, .ready)
        XCTAssertEqual(store.owner, .macApp)
    }

    func testMenuAppearanceReusesRecentBootstrapStatus() async {
        let events = EventRecorder()
        let current = AgentStatus(
            processOK: Self.readyStatus.processOK,
            serviceOK: Self.readyStatus.serviceOK,
            processError: Self.readyStatus.processError,
            serviceError: Self.readyStatus.serviceError,
            version: Self.readyStatus.version,
            serverVersion: Self.readyStatus.serverVersion,
            endpoint: Self.readyStatus.endpoint,
            configPath: Self.readyStatus.configPath,
            projects: Self.readyStatus.projects,
            doctorOK: Self.readyStatus.doctorOK,
            doctor: Self.readyStatus.doctor,
            pairExpires: Self.readyStatus.pairExpires,
            runtimeStatus: AgentRuntimeStatusSnapshot(
                checkedAt: "2026-07-28T02:00:00Z",
                runtimes: [],
                refreshing: false,
                stale: false
            )
        )
        let store = makeStore(
            configExists: true,
            agentStatus: { .enabled },
            status: {
                events.append("status")
                return current
            }
        )

        await store.bootstrap()
        await store.refreshIfNeeded()

        XCTAssertEqual(events.values, ["status"])
        XCTAssertEqual(store.lifecycle, .ready)
    }

    func testTransientMissingRuntimeStatusPreservesPreviousSnapshotAsStale() async {
        let events = EventRecorder()
        let snapshot = AgentRuntimeStatusSnapshot(
            checkedAt: "2026-07-28T02:00:00Z",
            runtimes: [
                AgentRuntimeStatus(
                    id: "codex",
                    title: "Codex",
                    enabled: true,
                    state: .connected,
                    authMode: "chatgpt",
                    planType: "pro",
                    reason: nil,
                    rateLimits: nil
                ),
            ],
            refreshing: false,
            stale: false
        )
        let statusWithRuntime = AgentStatus(
            processOK: Self.readyStatus.processOK,
            serviceOK: Self.readyStatus.serviceOK,
            processError: Self.readyStatus.processError,
            serviceError: Self.readyStatus.serviceError,
            version: Self.readyStatus.version,
            serverVersion: Self.readyStatus.serverVersion,
            endpoint: Self.readyStatus.endpoint,
            configPath: Self.readyStatus.configPath,
            projects: Self.readyStatus.projects,
            doctorOK: Self.readyStatus.doctorOK,
            doctor: Self.readyStatus.doctor,
            pairExpires: Self.readyStatus.pairExpires,
            runtimeStatus: snapshot
        )
        let store = makeStore(
            configExists: true,
            agentStatus: { .enabled },
            status: {
                events.append("status")
                return events.values.count == 1 ? statusWithRuntime : Self.readyStatus
            }
        )

        await store.bootstrap()
        await store.refresh()

        XCTAssertEqual(events.values, ["status", "status"])
        XCTAssertEqual(store.status?.runtimeStatus?.runtimes.map(\.id), ["codex"])
        XCTAssertEqual(store.status?.runtimeStatus?.stale, true)
    }

    func testTransientModuleStatusFailurePreservesSnapshotWithoutLegacyInference() async {
        let calls = CallCounter()
        let modules = AgentModuleStatus(
            codexEnabled: true,
            claudeEnabled: false,
            tailscaleEnabled: true,
            lanEnabled: false,
            tailscaleAvailable: true,
            lanAvailable: true
        )
        let statusWithModules = AgentStatus(
            processOK: true, serviceOK: true, processError: nil, serviceError: nil,
            version: Self.readyStatus.version, endpoint: Self.readyStatus.endpoint,
            configPath: Self.readyStatus.configPath, projects: Self.readyStatus.projects,
            doctorOK: true, doctor: Self.readyStatus.doctor, pairExpires: nil,
            networkStatus: AgentNetworkStatus(
                mode: "loopback", allowLAN: false, policyChecked: true, policyOK: true
            ),
            moduleStatus: modules,
            moduleStatusState: .available
        )
        let unavailableStatus = AgentStatus(
            processOK: true, serviceOK: true, processError: nil, serviceError: nil,
            version: Self.readyStatus.version, endpoint: Self.readyStatus.endpoint,
            configPath: Self.readyStatus.configPath, projects: Self.readyStatus.projects,
            doctorOK: true, doctor: Self.readyStatus.doctor, pairExpires: nil,
            networkStatus: AgentNetworkStatus(
                mode: "lan", allowLAN: true, policyChecked: true, policyOK: true
            ),
            moduleStatus: nil,
            moduleStatusState: .unavailable
        )
        let store = makeStore(
            configExists: true,
            agentStatus: { .enabled },
            status: { calls.increment() == 1 ? statusWithModules : unavailableStatus }
        )

        await store.bootstrap()
        await store.refresh()

        XCTAssertEqual(store.status?.moduleStatus, modules)
        XCTAssertEqual(store.status?.moduleStatusState, .unavailable)
        XCTAssertTrue(store.tailscaleEnabled)
        XCTAssertEqual(store.moduleStateTitle(.tailscale), "等待状态更新")
        XCTAssertTrue(store.canChangeModule(.tailscale), "明确标旧的上次快照仍可作为显式操作基线")
        XCTAssertEqual(store.availablePairingNetworks, [])
    }

    func testReadinessModuleFailurePreservesSnapshotThenLaterSuccessReplacesIt() async {
        let readinessCalls = CallCounter()
        let initialModules = AgentModuleStatus(
            codexEnabled: true,
            claudeEnabled: false,
            tailscaleEnabled: true,
            lanEnabled: false,
            tailscaleAvailable: true,
            lanAvailable: true
        )
        let replacementModules = AgentModuleStatus(
            codexEnabled: false,
            claudeEnabled: true,
            tailscaleEnabled: false,
            lanEnabled: true,
            tailscaleAvailable: true,
            lanAvailable: true
        )
        func status(modules: AgentModuleStatus?, state: AgentModuleStatusState) -> AgentStatus {
            AgentStatus(
                processOK: true, serviceOK: true, processError: nil, serviceError: nil,
                version: Self.readyStatus.version, endpoint: Self.readyStatus.endpoint,
                configPath: Self.readyStatus.configPath, projects: Self.readyStatus.projects,
                doctorOK: true, doctor: Self.readyStatus.doctor, pairExpires: nil,
                moduleStatus: modules,
                moduleStatusState: state
            )
        }
        let initialStatus = status(modules: initialModules, state: .available)
        let unavailableStatus = status(modules: nil, state: .unavailable)
        let replacementStatus = status(modules: replacementModules, state: .available)
        let store = makeStore(
            configExists: true,
            agentStatus: { .enabled },
            status: { initialStatus },
            readiness: {
                readinessCalls.increment() == 1 ? unavailableStatus : replacementStatus
            }
        )
        await store.bootstrap()
        let baseline = Date()

        await store.performMonitoringTick(6, now: baseline.addingTimeInterval(60))

        XCTAssertEqual(store.status?.moduleStatus, initialModules)
        XCTAssertEqual(store.status?.moduleStatusState, .unavailable)
        XCTAssertTrue(store.tailscaleEnabled)
        XCTAssertTrue(store.canChangeModule(.tailscale))

        await store.performMonitoringTick(12, now: baseline.addingTimeInterval(120))

        XCTAssertEqual(store.status?.moduleStatus, replacementModules)
        XCTAssertEqual(store.status?.moduleStatusState, .available)
        XCTAssertFalse(store.tailscaleEnabled)
        XCTAssertTrue(store.lanEnabled)
    }

    func testInitialUnavailableModuleStatusDisablesAmbiguousNetworkToggles() async {
        let unavailableStatus = AgentStatus(
            processOK: true, serviceOK: true, processError: nil, serviceError: nil,
            version: Self.readyStatus.version, endpoint: Self.readyStatus.endpoint,
            configPath: Self.readyStatus.configPath, projects: Self.readyStatus.projects,
            doctorOK: true, doctor: Self.readyStatus.doctor, pairExpires: nil,
            networkStatus: AgentNetworkStatus(
                mode: "lan", allowLAN: true, policyChecked: true, policyOK: true
            ),
            moduleStatus: nil,
            moduleStatusState: .unavailable
        )
        let store = makeStore(
            configExists: true,
            agentStatus: { .enabled },
            status: { unavailableStatus }
        )

        await store.bootstrap()

        XCTAssertFalse(store.tailscaleEnabled)
        XCTAssertFalse(store.lanEnabled)
        XCTAssertEqual(store.moduleStateTitle(.tailscale), "等待状态更新")
        XCTAssertFalse(store.canChangeModule(.tailscale))
        XCTAssertFalse(store.canChangeModule(.lan))
        XCTAssertTrue(store.availablePairingNetworks.isEmpty)
    }

    func testNetworkModulesCannotChangeBeforeFirstStatusSnapshot() {
        let store = makeStore(configExists: true, agentStatus: { .enabled })

        XCTAssertFalse(store.canChangeModule(.tailscale))
        XCTAssertFalse(store.canChangeModule(.lan))
    }


    func makeStore(
        configExists: Bool,
        homebrewLoaded: Bool = false,
        agentStatus: @escaping @MainActor () -> ServiceRegistrationState = { .notRegistered },
        agentConfigurationError: @escaping @MainActor () -> String? = { nil },
        isAgentRegistrationCurrent: @escaping @MainActor () -> Bool = { true },
        markAgentRegistrationCurrent: @escaping @MainActor () -> Void = {},
        status: @escaping @Sendable () async throws -> AgentStatus = {
            HostStoreTests.readyStatus
        },
        readiness: (@Sendable () async throws -> AgentStatus)? = nil,
        doctor: @escaping @Sendable (Bool) async throws -> DoctorFixResults = { _ in
            DoctorFixResults(fixes: [], results: HostStoreTests.readyStatus.doctor)
        },
        registerAgent: @escaping @MainActor () throws -> Void = {},
        unregisterAgent: @escaping @MainActor () async throws -> Void = {},
        agentLaunchFailure: @escaping @MainActor () async -> String? = { nil },
        configCheck: AgentdConfigCheckClient = .disabled,
        homebrewStart: @escaping @Sendable () async throws -> Void = {},
        homebrewStop: @escaping @Sendable () async throws -> Void = {},
        configureClaude: @escaping @Sendable (
            ClaudeActivationPreference,
            Bool?
        ) async throws -> ClaudeConfigurationResult = { preference, restoreEnabled in
            HostStoreTests.claudeConfiguration(
                enabled: restoreEnabled ?? false,
                preference: preference,
                previousEnabled: false,
                previousPreference: .automatic
            )
        },
        restoreClaude: @escaping @Sendable (ClaudeConfigurationResult) async throws -> ClaudeConfigurationResult = { _ in
            throw TestError.expected
        },
        setLANAccess: @escaping @Sendable (Bool) async throws -> NetworkConfigurationResult = {
            NetworkConfigurationResult(lanEnabled: $0, changed: false, restartRequired: false)
        },
        pair: (@Sendable (PairingNetwork) async throws -> PairingInfo)? = nil,
        tailcatStatus: @escaping @Sendable () async throws -> TailcatStatus = {
            TailcatStatus(
                enabled: false,
                running: false,
                version: nil,
                derpMapURL: nil,
                pairedDeviceCount: 0,
                error: nil
            )
        },
        setTailcatEnabled: @escaping @Sendable (Bool) async throws -> TailcatStatus = { _ in
            throw TestError.expected
        },
        configureTailcatDERPMap: @escaping @Sendable (String) async throws -> TailcatStatus = { _ in
            TailcatStatus(
                enabled: false,
                running: false,
                version: nil,
                derpMapURL: nil,
                pairedDeviceCount: 0,
                error: nil
            )
        },
        healthCheck: @escaping @Sendable (String) async -> Bool = { _ in true },
        systemPrivacySettings: SystemPrivacySettingsClient = .noop,
        terminateApplication: @escaping @MainActor () -> Void = {}
    ) -> HostStore {
        let readyStatus = Self.readyStatus
        let agent = AgentCommandClient(
            configExists: { configExists },
            setup: { _ in Self.pairing },
            status: status,
            readiness: readiness ?? status,
            statusAt: { _ in readyStatus },
            doctor: doctor,
            configureClaude: configureClaude,
            restoreClaude: restoreClaude,
            setLANAccess: setLANAccess,
            pair: pair ?? { _ in Self.pairing },
            tailcatStatus: tailcatStatus,
            setTailcatEnabled: setTailcatEnabled,
            configureTailcatDERPMap: configureTailcatDERPMap,
            version: { readyStatus.version }
        )
        let services = ServiceManagementClient(
            agentStatus: agentStatus,
            agentConfigurationError: agentConfigurationError,
            isAgentRegistrationCurrent: isAgentRegistrationCurrent,
            markAgentRegistrationCurrent: markAgentRegistrationCurrent,
            registerAgent: registerAgent,
            unregisterAgent: unregisterAgent,
            agentLaunchFailure: agentLaunchFailure,
            mainAppStatus: { .enabled },
            registerMainApp: {},
            unregisterMainApp: {},
            openLoginItemsSettings: {}
        )
        let homebrew = HomebrewServiceClient(
            isLoaded: { homebrewLoaded },
            installedAgentBinary: { URL(filePath: "/opt/homebrew/bin/agentd") },
            start: homebrewStart,
            stop: homebrewStop
        )
        return HostStore(
            agent: agent,
            services: services,
            configCheck: configCheck,
            homebrew: homebrew,
            health: HealthClient(check: healthCheck, checkDirect: { _ in true }),
            logs: AgentLogClient(
                recentLines: { _ in [] },
                exportLines: { [] }
            ),
            systemPrivacySettings: systemPrivacySettings,
            terminateApplication: terminateApplication
        )
    }

    private nonisolated static let pairing = PairingInfo(
        endpoint: "http://127.0.0.1:8787",
        pairURL: "mimiremote://pair?pair_sig=test",
        expiresAt: "2026-07-22T12:00:00Z",
        warnings: []
    )

    private nonisolated static let readyStatus: AgentStatus = {
        let doctor = AgentDoctorResults(
            ok: true,
            version: "0.1.0",
            listen: "127.0.0.1:8787",
            checks: []
        )
        return AgentStatus(
            processOK: true,
            serviceOK: true,
            processError: nil,
            serviceError: nil,
            version: "0.1.0",
            endpoint: "http://100.64.0.8:8787",
            configPath: "/tmp/config.json",
            projects: 1,
            doctorOK: true,
            doctor: doctor,
            pairExpires: nil
        )
    }()

    private nonisolated static let stoppedStatus = AgentStatus(
        processOK: false,
        serviceOK: false,
        processError: "agentd 未运行",
        serviceError: "readyz 不可用",
        version: "0.1.0",
        endpoint: "http://127.0.0.1:8787",
        configPath: "/tmp/config.json",
        projects: 1,
        doctorOK: true,
        doctor: readyStatus.doctor,
        pairExpires: nil
    )

    private nonisolated static func statusWithClaude(
        enabled: Bool,
        state: AgentRuntimeConnectionState
    ) -> AgentStatus {
        AgentStatus(
            processOK: readyStatus.processOK,
            serviceOK: readyStatus.serviceOK,
            processError: readyStatus.processError,
            serviceError: readyStatus.serviceError,
            version: readyStatus.version,
            endpoint: readyStatus.endpoint,
            configPath: readyStatus.configPath,
            projects: readyStatus.projects,
            doctorOK: readyStatus.doctorOK,
            doctor: readyStatus.doctor,
            pairExpires: nil,
            runtimeStatus: AgentRuntimeStatusSnapshot(
                checkedAt: "2026-08-03T03:00:00Z",
                runtimes: [
                    AgentRuntimeStatus(
                        id: "claude",
                        title: "Claude",
                        enabled: enabled,
                        state: state,
                        authMode: enabled ? "oauth" : nil,
                        planType: enabled ? "pro" : nil,
                        reason: enabled ? nil : "disabled",
                        rateLimits: nil
                    ),
                ]
            )
        )
    }

    private nonisolated static func claudeConfiguration(
        enabled: Bool,
        preference: ClaudeActivationPreference,
        previousEnabled: Bool = false,
        previousPreference: ClaudeActivationPreference = .automatic,
        changed: Bool = false,
        restartRequired: Bool = false,
        reason: String? = nil
    ) -> ClaudeConfigurationResult {
        ClaudeConfigurationResult(
            enabled: enabled,
            available: enabled,
            preference: preference,
            previousEnabled: previousEnabled,
            previousPreference: previousPreference,
            changed: changed,
            restartRequired: restartRequired,
            reason: reason ?? (enabled ? "ready" : "disabled_by_user"),
            message: enabled
                ? "已检测到 Claude Code 和兼容的 Claude bridge。"
                : "Claude 实验通道已关闭。"
        )
    }
}

@MainActor
private final class LaggingAgentRegistration {
    private var statusChecks = 0

    func nextStatus() -> ServiceRegistrationState {
        statusChecks += 1
        // bootstrap 读取两次；重启后的第一次读取仍返回 enabled，随后才完成注销。
        return statusChecks <= 3 ? .enabled : .notRegistered
    }
}

enum TestError: LocalizedError {
    case expected

    var errorDescription: String? { "预期的测试错误" }
}

final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class SuspendedStatusGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var suspended = false
    private var released = false

    func suspendReturning<T: Sendable>(_ value: T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                condition.lock()
                suspended = true
                condition.broadcast()
                while !released {
                    condition.wait()
                }
                condition.unlock()
                continuation.resume(returning: value)
            }
        }
    }

    func waitUntilSuspended() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                condition.lock()
                while !suspended {
                    condition.wait()
                }
                condition.unlock()
                continuation.resume()
            }
        }
    }

    func resume() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

final class MacInstallationLocationTests: XCTestCase {
    func testTranslocatedCopyIsRejectedBeforeSigningOrServiceWork() {
        let bundle = URL(filePath: "/private/var/folders/test/T/AppTranslocation/test-id/d/Mimi Remote Mac.app")
        let message = ServiceManagementClient.installationLocationError(bundleURL: bundle)
        XCTAssertTrue(message?.contains("Finder") == true)
        XCTAssertEqual(ServiceManagementClient.validateAgentConfiguration(
            bundleURL: bundle,
            signingIdentityProvider: { _ in
                XCTFail("临时副本不应继续签名和服务检查")
                return nil
            }
        ), message)
    }

    func testWritableDevelopmentAndApplicationsLocationsRemainAllowed() {
        for path in ["/Applications/Mimi Remote Mac.app", "/tmp/DerivedData/Build/Products/Release/Mimi Remote Mac.app", "/tmp/AppTranslocationNotes/Mimi Remote Mac.app"] {
            XCTAssertNil(ServiceManagementClient.installationLocationError(bundleURL: URL(filePath: path)))
        }
    }
}
