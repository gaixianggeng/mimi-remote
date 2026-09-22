import Foundation
import XCTest
@testable import MimiRemoteMac

@MainActor
final class HostStoreCodexSessionRepairTests: XCTestCase {
    func testRepairStopsAgentReleasesSessionThenStartsNewResident() async {
        let events = RepairEventRecorder()
        let fixture = makeStore(events: events) {
            events.append("release")
            return CodexSessionReleaseResult(released: true, message: "已释放旧共享运行环境。")
        }
        await fixture.store.bootstrap()

        await fixture.store.repairSharedCodexRuntime()

        XCTAssertEqual(events.values, ["unregister", "release", "register"])
        XCTAssertEqual(fixture.store.lifecycle, .ready)
        XCTAssertEqual(
            fixture.store.codexSessionRepairNotice,
            "已释放旧共享运行环境。Mimi Remote Mac 服务已重新启动。"
        )
        XCTAssertNil(fixture.store.lastError)
    }

    func testIdempotentNoReleaseStillRestartsAquaResidentWithoutMigrationClaim() async {
        let events = RepairEventRecorder()
        let fixture = makeStore(events: events) {
            events.append("release")
            return CodexSessionReleaseResult(released: false, message: "当前没有需要释放的旧服务。")
        }
        await fixture.store.bootstrap()

        await fixture.store.repairSharedCodexRuntime()

        XCTAssertEqual(events.values, ["unregister", "release", "register"])
        XCTAssertEqual(
            fixture.store.codexSessionRepairNotice,
            "当前没有需要释放的旧服务。Mimi Remote Mac 服务已重新启动。"
        )
        XCTAssertNil(fixture.store.lastError)
    }

    func testRejectedRepairRestoresOriginallyEnabledService() async {
        let events = RepairEventRecorder()
        let fixture = makeStore(events: events) {
            events.append("release")
            throw AgentClientError.commandFailed("仍有活动任务")
        }
        await fixture.store.bootstrap()

        await fixture.store.repairSharedCodexRuntime()

        XCTAssertEqual(events.values, ["unregister", "release", "register"])
        XCTAssertEqual(fixture.store.lifecycle, .ready)
        XCTAssertTrue(fixture.store.lastError?.contains("已恢复 Mimi Remote Mac 服务") == true)
        XCTAssertTrue(fixture.store.lastError?.contains("仍有活动任务") == true)
        XCTAssertNil(fixture.store.codexSessionRepairNotice)
    }

    func testUnknownRepairResultRestoresServiceAndDoesNotReportSuccess() async {
        let events = RepairEventRecorder()
        let fixture = makeStore(events: events) {
            events.append("release")
            throw AgentClientError.invalidResponse("缺少 released 或 message")
        }
        await fixture.store.bootstrap()

        await fixture.store.repairSharedCodexRuntime()

        XCTAssertEqual(events.values, ["unregister", "release", "register"])
        XCTAssertEqual(fixture.store.lifecycle, .ready)
        XCTAssertTrue(fixture.store.lastError?.contains("无法解析 agentd 返回结果") == true)
        XCTAssertNil(fixture.store.codexSessionRepairNotice)
    }

    func testEnabledButNotReadyRecoveryKeepsMacOwnerSoRepairCanBeRetried() async {
        let events = RepairEventRecorder()
        let configCheck = AgentdConfigCheckClient(
            check: {
                AgentdConfigCheckResult(ok: false, code: "config_invalid", message: "resident 未就绪")
            },
            agentdURL: URL(filePath: "/tmp/agentd")
        )
        let fixture = makeStore(
            events: events,
            status: {
                if events.values.contains("release") {
                    throw AgentClientError.commandFailed("Background resident 仍被占用")
                }
                return Self.readyStatus
            },
            agentLaunchFailure: {
                events.values.contains("release") ? "resident 启动失败" : nil
            },
            configCheck: configCheck
        ) {
            events.append("release")
            throw AgentClientError.commandFailed("仍有其它连接")
        }
        await fixture.store.bootstrap()

        await fixture.store.repairSharedCodexRuntime()

        XCTAssertEqual(fixture.store.owner, .macApp)
        XCTAssertEqual(events.values, ["unregister", "release", "register"])
        XCTAssertTrue(fixture.store.lifecycle.detail?.contains("未能恢复就绪") == true)
        XCTAssertTrue(fixture.store.lastError?.contains("恢复错误") == true)

        await fixture.store.repairSharedCodexRuntime()
        XCTAssertEqual(events.values, [
            "unregister", "release", "register",
            "unregister", "release", "register",
        ])
    }

    func testRepeatedRepairWhileBusyDoesNotStartSecondRelease() async {
        let events = RepairEventRecorder()
        let gate = RepairSuspensionGate()
        let fixture = makeStore(events: events) {
            events.append("release")
            await gate.suspend()
            return CodexSessionReleaseResult(released: true, message: "已释放。")
        }
        await fixture.store.bootstrap()

        let firstRepair = Task { @MainActor in
            await fixture.store.repairSharedCodexRuntime()
        }
        await gate.waitUntilSuspended()
        XCTAssertTrue(fixture.store.isBusy)

        await fixture.store.repairSharedCodexRuntime()
        XCTAssertEqual(events.values, ["unregister", "release"])

        await gate.resume()
        await firstRepair.value
        XCTAssertEqual(events.values, ["unregister", "release", "register"])
        XCTAssertFalse(fixture.store.isBusy)
    }

    func testRetryClearsPreviousNoticeAndFailureBeforeStartingNextRepair() async {
        let events = RepairEventRecorder()
        let failingRetryGate = RepairSuspensionGate()
        let succeedingRetryGate = RepairSuspensionGate()
        let fixture = makeStore(events: events) {
            events.append("release")
            let releaseCount = events.values.filter { $0 == "release" }.count
            switch releaseCount {
            case 1:
                return CodexSessionReleaseResult(released: true, message: "首次修复完成。")
            case 2:
                await failingRetryGate.suspend()
                throw AgentClientError.commandFailed("仍有活动任务")
            default:
                await succeedingRetryGate.suspend()
                return CodexSessionReleaseResult(released: true, message: "重试完成。")
            }
        }
        await fixture.store.bootstrap()
        await fixture.store.repairSharedCodexRuntime()
        XCTAssertNotNil(fixture.store.codexSessionRepairNotice)

        let failingRetry = Task { @MainActor in
            await fixture.store.repairSharedCodexRuntime()
        }
        await failingRetryGate.waitUntilSuspended()

        XCTAssertNil(fixture.store.lastError)
        XCTAssertNil(fixture.store.codexSessionRepairNotice)
        await failingRetryGate.resume()
        await failingRetry.value
        XCTAssertNotNil(fixture.store.lastError)

        let succeedingRetry = Task { @MainActor in
            await fixture.store.repairSharedCodexRuntime()
        }
        await succeedingRetryGate.waitUntilSuspended()

        XCTAssertNil(fixture.store.lastError)
        XCTAssertNil(fixture.store.codexSessionRepairNotice)
        await succeedingRetryGate.resume()
        await succeedingRetry.value
        XCTAssertEqual(
            fixture.store.codexSessionRepairNotice,
            "重试完成。Mimi Remote Mac 服务已重新启动。"
        )
    }

    private func makeStore(
        events: RepairEventRecorder,
        status statusOverride: (@Sendable () async throws -> AgentStatus)? = nil,
        agentLaunchFailure: @escaping @MainActor () async -> String? = { nil },
        configCheck: AgentdConfigCheckClient = .disabled,
        release: @escaping @Sendable () async throws -> CodexSessionReleaseResult
    ) -> RepairStoreFixture {
        var registrationState = ServiceRegistrationState.enabled
        let status = Self.readyStatus
        let statusProvider = statusOverride ?? { status }
        let agent = AgentCommandClient(
            configExists: { true },
            setup: { _ in throw RepairTestError.unexpected },
            status: statusProvider,
            readiness: statusProvider,
            statusAt: { _ in status },
            doctor: { _ in DoctorFixResults(fixes: [], results: status.doctor) },
            releaseCodexSession: release,
            configureClaude: { _, _ in
                ClaudeConfigurationResult(
                    enabled: false,
                    available: false,
                    preference: .disabled,
                    previousEnabled: false,
                    previousPreference: .disabled,
                    changed: false,
                    restartRequired: false,
                    reason: "test",
                    message: ""
                )
            },
            setLANAccess: { _ in throw RepairTestError.unexpected },
            pair: { _ in throw RepairTestError.unexpected },
            version: { status.version }
        )
        let services = ServiceManagementClient(
            agentStatus: { registrationState },
            agentConfigurationError: { nil },
            isAgentRegistrationCurrent: { true },
            markAgentRegistrationCurrent: {},
            registerAgent: {
                events.append("register")
                registrationState = .enabled
            },
            unregisterAgent: {
                events.append("unregister")
                registrationState = .notRegistered
            },
            agentLaunchFailure: agentLaunchFailure,
            mainAppStatus: { .enabled },
            registerMainApp: {},
            unregisterMainApp: {},
            openLoginItemsSettings: {}
        )
        let store = HostStore(
            agent: agent,
            services: services,
            configCheck: configCheck,
            homebrew: HomebrewServiceClient(
                isLoaded: { false },
                installedAgentBinary: { nil },
                start: {},
                stop: {}
            ),
            health: HealthClient(check: { _ in false }, checkDirect: { _ in true }),
            logs: AgentLogClient(
                recentLines: { _ in [] },
                reveal: {},
                fileURL: URL(filePath: "/tmp/mimi-codex-session-repair-test.log")
            )
        )
        return RepairStoreFixture(store: store)
    }

    private nonisolated static let readyStatus: AgentStatus = {
        let doctor = AgentDoctorResults(
            ok: true,
            version: "test",
            listen: "127.0.0.1:8787",
            checks: []
        )
        return AgentStatus(
            processOK: true,
            serviceOK: true,
            processError: nil,
            serviceError: nil,
            version: "test",
            endpoint: "http://127.0.0.1:8787",
            configPath: "/tmp/config.json",
            projects: 0,
            doctorOK: true,
            doctor: doctor,
            pairExpires: nil
        )
    }()
}

@MainActor
private struct RepairStoreFixture {
    let store: HostStore
}

private enum RepairTestError: Error {
    case unexpected
}

private final class RepairEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func append(_ value: String) {
        lock.withLock { storage.append(value) }
    }
}

private actor RepairSuspensionGate {
    private var suspended = false
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        suspended = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilSuspended() async {
        while !suspended {
            await Task.yield()
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
