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
        XCTAssertEqual(store.tailcatNotice, "中转已更新，请在手机上重新扫码。")
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
        XCTAssertEqual(store.tailcatNotice, "本机已启用 Mimi 中转。已开通的手机可使用中转，免费连接继续可用。")

        await store.setTailcatManagedMode(false)
        XCTAssertFalse(store.tailcatIsManaged)
        XCTAssertEqual(store.tailcatNotice, "本机已停用 Mimi 中转。手机会尝试免费备用线路；旧设备可能需要重新扫码。")
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
                throw AgentClientError.commandFailed("正在使用 Mimi 中转，不能手动修改中继；请先在「中转服务」里改回默认或自建中转")
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

    func testRelayModeFollowsActualConfiguration() {
        XCTAssertEqual(TailcatRelayPresentation.mode(isManaged: false, derpMapURL: ""), .tailcatDefault)
        XCTAssertEqual(TailcatRelayPresentation.mode(isManaged: false, derpMapURL: "https://relay.example/map.json"), .custom)
        XCTAssertEqual(TailcatRelayPresentation.mode(isManaged: true, derpMapURL: "https://relay.example/map.json"), .mimi)
    }

    /// 选中即生效，所以确认框只能出现在真的会影响正在使用的手机时。
    func testRelayChangeOnlyConfirmsWhenItCanInterruptPhones() {
        func needsConfirmation(_ mode: TailcatRelayMode, url: String = "", enabled: Bool = true, managed: Bool = false, current: String = "") -> Bool {
            TailcatRelayPresentation.needsReconnectionConfirmation(
                mode: mode, url: url, tailcatEnabled: enabled, isManaged: managed, currentURL: current
            )
        }
        XCTAssertFalse(needsConfirmation(.mimi), "改用 Mimi 不影响免费线路")
        XCTAssertFalse(needsConfirmation(.custom, url: "https://a.example/map.json", enabled: false), "内置连接未开启时没有手机受影响")
        XCTAssertFalse(needsConfirmation(.custom, url: "https://a.example/map.json", current: "https://a.example/map.json"))
        XCTAssertTrue(needsConfirmation(.custom, url: "https://b.example/map.json", current: "https://a.example/map.json"))
        XCTAssertTrue(needsConfirmation(.tailcatDefault, current: "https://a.example/map.json"))
        XCTAssertTrue(needsConfirmation(.tailcatDefault, managed: true), "退出 Mimi 可能让旧设备重新扫码")
    }

    func testCustomRelayURLValidationBlocksUnusableAddresses() {
        XCTAssertNil(TailcatRelayPresentation.customURLValidationMessage("https://relay.example/map.json"))
        for invalid in [
            "", "http://relay.example/map.json", "https://user:pass@relay.example/map.json",
            "https://relay.example/map.json#frag", "relay.example",
            "https://api.code89757.com/v1/relay/tailcat-derp-map.json"
        ] {
            XCTAssertNotNil(TailcatRelayPresentation.customURLValidationMessage(invalid), invalid)
        }
    }

    /// 选 Mimi 后已开通的手机会自动跟随，说明不能再把扫码写成必经步骤。
    func testMimiCaptionDoesNotRequireScanning() {
        let caption = TailcatRelayPresentation.caption(mode: .mimi, derpMapURL: "")
        XCTAssertTrue(caption.contains("自动切换"))
        XCTAssertFalse(caption.contains("扫码"))
    }

    func testSelfHostedGuidePointsToPublicDocument() {
        XCTAssertEqual(TailcatRelayPresentation.selfHostedGuideURL.scheme, "https")
        XCTAssertTrue(TailcatRelayPresentation.selfHostedGuideURL.path.hasSuffix("docs/self-hosted-relay.md"))
    }

    func testRelayCaptionNeverExposesFullCustomAddress() {
        let caption = TailcatRelayPresentation.caption(mode: .custom, derpMapURL: "https://relay.example/secret/map.json")
        XCTAssertTrue(caption.contains("relay.example"))
        XCTAssertFalse(caption.contains("secret"))
    }
}
