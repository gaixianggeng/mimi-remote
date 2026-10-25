import Foundation
import XCTest
@testable import MimiRemoteMac

/// Tailcat 中继、托管模式与状态刷新的 HostStore 用例（#896 从 HostStoreTests 拆出，复用其 makeStore）。
extension HostStoreTests {
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

    func testEnteringAndExitingManagedConnectionUpdatesModeAndClearsTailcatPairing() async {
        let events = EventRecorder()
        let selfHosted = TailcatStatus(
            enabled: true, running: true, version: "v0.7.0",
            derpMapURL: nil, pairedDeviceCount: 2, error: nil, mode: "self_hosted"
        )
        let managed = TailcatStatus(
            enabled: true, running: true, version: "v0.7.0",
            derpMapURL: "https://relay.example/derpmap/managed", pairedDeviceCount: 0, error: nil,
            mode: "managed"
        )
        let tailcatPairing = PairingInfo(
            endpoint: "http://127.0.0.1:8787",
            network: .tailcat,
            pairURL: "mimiremote://pair?transport=tailcat",
            expiresAt: "2026-10-22T02:00:00Z",
            warnings: []
        )
        let store = makeStore(
            configExists: true,
            agentStatus: { .enabled },
            pair: { _ in tailcatPairing },
            tailcatStatus: { selfHosted },
            setTailcatManagedMode: { managedMode in
                events.append(managedMode ? "enter" : "exit")
                return managedMode ? managed : selfHosted
            }
        )

        await store.bootstrap()
        await store.refreshTailcatStatus()
        XCTAssertFalse(store.tailcatIsManaged)
        await store.refreshPairing(network: .tailcat)

        await store.setTailcatManagedMode(true)
        XCTAssertTrue(store.tailcatIsManaged)
        // 进入托管模式会重建身份，旧的 Tailcat 二维码不能继续展示。
        XCTAssertNil(store.pairing)
        XCTAssertEqual(store.pairingNetwork, .tailscale)
        XCTAssertEqual(store.tailcatNotice, "已改用 Mimi 托管连接。请在手机的「Mimi 托管连接」里扫码接入这台电脑。")

        await store.setTailcatManagedMode(false)
        XCTAssertFalse(store.tailcatIsManaged)
        XCTAssertEqual(store.tailcatNotice, "已退出托管连接并恢复原中继。需要用 Tailcat 的设备请重新扫码。")
        XCTAssertEqual(events.values, ["enter", "exit"])
        XCTAssertFalse(store.isBusy)
    }

    func testManagedConnectionFailureShowsAgentError() async {
        let store = makeStore(
            configExists: true,
            agentStatus: { .enabled },
            tailcatStatus: {
                TailcatStatus(
                    enabled: true, running: true, version: nil,
                    derpMapURL: nil, pairedDeviceCount: 0, error: nil
                )
            },
            setTailcatManagedMode: { _ in
                throw AgentClientError.commandFailed("托管模式下不能手动修改中继，请先退出托管模式")
            }
        )

        await store.bootstrap()
        await store.refreshTailcatStatus()
        await store.setTailcatManagedMode(true)

        XCTAssertFalse(store.tailcatIsManaged)
        XCTAssertNotNil(store.tailcatError)
        XCTAssertNil(store.tailcatNotice)
        XCTAssertFalse(store.isBusy)
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
}
