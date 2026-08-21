import Foundation
import XCTest
@testable import MimiRemoteMac

// MIM-168 的实验性共享/独立 App Server 流程需要较长的重启和失败恢复场景。
// 这些测试仍属于 HostStoreTests，便于复用原有 HostStore 测试夹具，但单独放置以控制文件大小。
@MainActor
extension HostStoreTests {
    func testPendingEnableRetryReopensDesktopAfterFirstRestartFailure() async {
        let events = EventRecorder()
        let sharing = SharingFlag()
        sharing.set(true)
        var enabled = false
        var appRunning = true
        var pendingEnabled: Bool?
        var restartAttempts = 0
        let snapshot: () -> CodexDesktopEnvironmentSnapshot = {
            CodexDesktopEnvironmentSnapshot(
                hasLocalPreference: true,
                enabled: enabled,
                environmentValue: enabled ? "1" : nil,
                codexHome: enabled ? "/tmp/codex" : nil,
                appInstalled: true,
                appRunning: appRunning,
                pendingEnabled: pendingEnabled
            )
        }
        let desktop = CodexDesktopIntegrationClient(
            inspect: { snapshot() },
            bootstrap: { snapshot() },
            setEnabled: { next, _ in
                events.append("desktop-\(next)")
                enabled = next
                pendingEnabled = next ? true : nil
                return snapshot()
            },
            restartAndApply: { snapshot() },
            restartAndApplyWithPreparation: { _, _, preparation in
                restartAttempts += 1
                events.append("restart-\(restartAttempts)")
                appRunning = false
                try await preparation()
                if restartAttempts == 1 {
                    throw TestError.expected
                }
                enabled = true
                appRunning = true
                pendingEnabled = nil
                events.append("open")
                return snapshot()
            }
        )
        let store = makeStore(
            configExists: true,
            agentStatus: { .enabled },
            status: { Self.statusWithCodex(shared: sharing.value) },
            configureCodexSharing: { next in
                sharing.set(next)
                return CodexSharingConfigurationResult(
                    enabled: next,
                    changed: true,
                    transport: "unix",
                    codexHome: "/tmp/codex"
                )
            },
            codexDesktop: desktop
        )

        await store.bootstrap()
        await store.setCodexDesktopEnabled(true)
        XCTAssertEqual(store.codexDesktopStatus.environment.pendingEnabled, true)
        XCTAssertTrue(store.canRestartCodexDesktop)

        await store.restartCodexDesktop()
        XCTAssertEqual(store.codexDesktopStatus.environment.pendingEnabled, true)
        XCTAssertTrue(store.canRestartCodexDesktop)

        await store.restartCodexDesktop()

        XCTAssertEqual(events.values, ["desktop-true", "restart-1", "restart-2", "open"])
        XCTAssertEqual(restartAttempts, 2)
        XCTAssertTrue(store.codexDesktopEnabled)
        XCTAssertNil(store.codexDesktopStatus.environment.pendingEnabled)
        XCTAssertFalse(store.canRestartCodexDesktop)
        XCTAssertNil(store.codexDesktopError)
    }

    func testLegacyHalfRollbackWithMimiMarkerRemainsActionable() async {
        let orphaned = CodexDesktopEnvironmentSnapshot(
            hasLocalPreference: true,
            enabled: false,
            environmentValue: "1",
            codexHome: "/tmp/codex",
            sessionEpoch: "legacy-mimi-epoch",
            appInstalled: true,
            appRunning: true
        )
        let desktop = CodexDesktopIntegrationClient(
            inspect: { orphaned },
            bootstrap: { orphaned },
            setEnabled: { _, _ in orphaned },
            restartAndApply: { orphaned }
        )
        let store = makeStore(
            configExists: true,
            agentStatus: { .enabled },
            status: { Self.statusWithCodex(shared: false) },
            codexDesktop: desktop
        )

        await store.bootstrap()

        XCTAssertEqual(store.codexDesktopStatus.state, .pendingRestart)
        XCTAssertTrue(store.canRestartCodexDesktop)
        XCTAssertTrue(store.codexDesktopStatusDetail.contains("应用设置"))
    }

    func testConfirmedDisableStopsSharedBackendBetweenDesktopTerminateAndOpen() async {
        let events = EventRecorder()
        let sharing = SharingFlag()
        sharing.set(true)
        var enabled = true
        var appRunning = true
        let snapshot: () -> CodexDesktopEnvironmentSnapshot = {
            CodexDesktopEnvironmentSnapshot(
                hasLocalPreference: true,
                enabled: enabled,
                environmentValue: enabled ? "1" : nil,
                codexHome: enabled ? "/tmp/codex" : nil,
                appInstalled: true,
                appRunning: appRunning
            )
        }
        let desktop = CodexDesktopIntegrationClient(
            inspect: { snapshot() },
            bootstrap: { snapshot() },
            setEnabled: { next, _ in
                events.append("desktop-\(next)")
                enabled = next
                return snapshot()
            },
            restartAndApply: { snapshot() },
            restartAndApplyWithPreparation: { desiredEnabled, _, preparation in
                events.append("terminate")
                appRunning = false
                try await preparation()
                if let desiredEnabled {
                    events.append("desktop-\(desiredEnabled)")
                    enabled = desiredEnabled
                }
                events.append("open")
                appRunning = true
                return snapshot()
            }
        )
        let store = makeStore(
            configExists: true,
            agentStatus: { .enabled },
            status: { Self.statusWithCodex(shared: sharing.value) },
            disableCodexSharingAfterDesktopExit: {
                events.append("backend-disable-confirmed")
                sharing.set(false)
                return CodexSharingConfigurationResult(
                    enabled: false,
                    changed: true,
                    transport: "ws"
                )
            },
            codexDesktop: desktop
        )

        await store.bootstrap()
        await store.setCodexDesktopEnabled(false)

        XCTAssertEqual(events.values, [
            "terminate",
            "backend-disable-confirmed",
            "desktop-false",
            "open",
        ])
        XCTAssertFalse(sharing.value)
        XCTAssertNil(store.codexDesktopError)
        XCTAssertEqual(store.codexDesktopStatus.state, .disabled)
    }

    func testConfirmedDisableExplainsDrainWithoutPromisingReopen() async {
        let drainGate = CodexTransitionGate()
        let completionGate = CodexTransitionGate()
        let sharing = SharingFlag()
        sharing.set(true)
        var enabled = true
        var appRunning = true
        let snapshot: () -> CodexDesktopEnvironmentSnapshot = {
            CodexDesktopEnvironmentSnapshot(
                hasLocalPreference: true,
                enabled: enabled,
                environmentValue: enabled ? "1" : nil,
                codexHome: enabled ? "/tmp/codex" : nil,
                appInstalled: true,
                appRunning: appRunning
            )
        }
        let desktop = CodexDesktopIntegrationClient(
            inspect: { snapshot() },
            bootstrap: { snapshot() },
            setEnabled: { _, _ in snapshot() },
            restartAndApply: { snapshot() },
            restartAndApplyWithPreparation: { _, _, preparation in
                appRunning = false
                try await preparation()
                await completionGate.suspend()
                enabled = false
                return snapshot()
            }
        )
        let store = makeStore(
            configExists: true,
            agentStatus: { .enabled },
            status: { Self.statusWithCodex(shared: sharing.value) },
            disableCodexSharingAfterDesktopExit: {
                await drainGate.suspend()
                sharing.set(false)
                return CodexSharingConfigurationResult(
                    enabled: false,
                    changed: true,
                    transport: "ws"
                )
            },
            codexDesktop: desktop
        )

        await store.bootstrap()
        let transition = Task { await store.setCodexDesktopEnabled(false) }

        await drainGate.waitUntilSuspended()
        XCTAssertEqual(store.codexDesktopTransitionPhase, .waitingForRunningTasks)
        XCTAssertEqual(store.codexDesktopStatusTitle, "正在结束运行中的任务")
        XCTAssertTrue(store.codexDesktopStatusDetail.contains("任务较长时"))

        await drainGate.resume()
        await completionGate.waitUntilSuspended()
        XCTAssertNotEqual(store.codexDesktopStatusTitle, "正在重新打开 Codex Desktop")
        XCTAssertFalse(store.codexDesktopStatusDetail.contains("重新打开"))

        await completionGate.resume()
        await transition.value
        XCTAssertNil(store.codexDesktopTransitionPhase)
        XCTAssertEqual(store.codexDesktopStatus.state, .disabled)
    }

    func testConfirmedDisableFailureKeepsDesktopClosedAndRetryAvailable() async {
        let events = EventRecorder()
        let sharing = SharingFlag()
        sharing.set(true)
        var enabled = true
        var appRunning = true
        var pendingEnabled: Bool?
        let snapshot: () -> CodexDesktopEnvironmentSnapshot = {
            CodexDesktopEnvironmentSnapshot(
                hasLocalPreference: true,
                enabled: enabled,
                environmentValue: enabled ? "1" : nil,
                codexHome: enabled ? "/tmp/codex" : nil,
                appInstalled: true,
                appRunning: appRunning,
                restartRequired: !enabled && appRunning,
                pendingEnabled: pendingEnabled
            )
        }
        let desktop = CodexDesktopIntegrationClient(
            inspect: { snapshot() },
            bootstrap: { snapshot() },
            setEnabled: { next, _ in
                enabled = next
                return snapshot()
            },
            restartAndApply: { snapshot() },
            restartAndApplyWithPreparation: { desiredEnabled, _, preparation in
                pendingEnabled = desiredEnabled
                events.append("terminate")
                appRunning = false
                try await preparation()
                if let desiredEnabled {
                    enabled = desiredEnabled
                }
                events.append("open")
                appRunning = true
                pendingEnabled = nil
                return snapshot()
            }
        )
        let store = makeStore(
            configExists: true,
            agentStatus: { .enabled },
            status: { Self.statusWithCodex(shared: sharing.value) },
            disableCodexSharingAfterDesktopExit: {
                events.append("backend-disable-confirmed")
                throw TestError.expected
            },
            codexDesktop: desktop
        )

        await store.bootstrap()
        await store.setCodexDesktopEnabled(false)

        XCTAssertEqual(events.values, ["terminate", "backend-disable-confirmed"])
        XCTAssertFalse(appRunning)
        XCTAssertTrue(sharing.value)
        XCTAssertNotNil(store.codexDesktopError)
        XCTAssertEqual(store.codexDesktopStatus.state, .pendingRestart)
        XCTAssertTrue(store.canRestartCodexDesktop)
    }

    func testConfirmedDisableReloadFailureKeepsPersistentRetryState() async {
        let events = EventRecorder()
        let sharing = SharingFlag()
        sharing.set(true)
        var enabled = true
        var appRunning = true
        var pendingEnabled: Bool?
        var disableCalls = 0
        var registerCalls = 0
        var registrationState: ServiceRegistrationState = .enabled
        let snapshot: () -> CodexDesktopEnvironmentSnapshot = {
            CodexDesktopEnvironmentSnapshot(
                hasLocalPreference: true,
                enabled: enabled,
                environmentValue: enabled ? "1" : nil,
                codexHome: enabled ? "/tmp/codex" : nil,
                sessionEpoch: enabled ? "mimi-epoch" : nil,
                appInstalled: true,
                appRunning: appRunning,
                pendingEnabled: pendingEnabled
            )
        }
        let desktop = CodexDesktopIntegrationClient(
            inspect: { snapshot() },
            bootstrap: { snapshot() },
            setEnabled: { _, _ in snapshot() },
            restartAndApply: { snapshot() },
            restartAndApplyWithPreparation: { desiredEnabled, _, preparation in
                if let desiredEnabled {
                    pendingEnabled = desiredEnabled
                    events.append("terminate")
                    appRunning = false
                }
                try await preparation()
                let finalEnabled = desiredEnabled ?? false
                events.append("desktop-\(finalEnabled)")
                enabled = finalEnabled
                events.append("open")
                appRunning = true
                pendingEnabled = nil
                return snapshot()
            }
        )
        let store = makeStore(
            configExists: true,
            agentStatus: { registrationState },
            status: { Self.statusWithCodex(shared: sharing.value) },
            registerAgent: {
                registerCalls += 1
                events.append("register-\(registerCalls)")
                guard registerCalls != 1 else { throw TestError.expected }
                registrationState = .enabled
            },
            unregisterAgent: {
                events.append("unregister")
                registrationState = .notRegistered
            },
            disableCodexSharingAfterDesktopExit: {
                disableCalls += 1
                sharing.set(false)
                return CodexSharingConfigurationResult(
                    enabled: false,
                    changed: true,
                    restartRequired: disableCalls == 1,
                    transport: "ws"
                )
            },
            healthCheck: { _ in false },
            codexDesktop: desktop
        )

        await store.bootstrap()
        await store.setCodexDesktopEnabled(false)

        XCTAssertFalse(sharing.value, "Go 事务已经提交 WS，reload 失败不能伪装成未提交")
        XCTAssertEqual(store.codexDesktopStatus.environment.pendingEnabled, false)
        XCTAssertEqual(store.codexDesktopStatus.state, CodexDesktopStatusState.pendingRestart)
        XCTAssertTrue(store.canRestartCodexDesktop)
        XCTAssertNotNil(store.codexDesktopError)
        XCTAssertFalse(appRunning)

        await store.restartCodexDesktop()

        XCTAssertEqual(events.values, [
            "terminate",
            "unregister",
            "register-1",
            "register-2",
            "desktop-false",
            "open",
        ])
        XCTAssertEqual(disableCalls, 2)
        XCTAssertEqual(registerCalls, 2)
        XCTAssertNil(store.codexDesktopStatus.environment.pendingEnabled)
        XCTAssertEqual(store.codexDesktopStatus.state, CodexDesktopStatusState.disabled)
        XCTAssertFalse(store.canRestartCodexDesktop)
        XCTAssertNil(store.codexDesktopError)
        XCTAssertTrue(appRunning)
    }
}

private actor CodexTransitionGate {
    private var isSuspended = false
    private var isReleased = false
    private var suspension: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        isSuspended = true
        observers.forEach { $0.resume() }
        observers.removeAll()
        guard !isReleased else { return }
        await withCheckedContinuation { suspension = $0 }
    }

    func waitUntilSuspended() async {
        guard !isSuspended else { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func resume() {
        isReleased = true
        suspension?.resume()
        suspension = nil
    }
}
