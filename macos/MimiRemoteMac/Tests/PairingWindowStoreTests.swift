import Foundation
import XCTest
@testable import MimiRemoteMac

@MainActor
final class PairingWindowStoreTests: XCTestCase {
    private nonisolated static func formatUTC(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    // MARK: - Transport ordering & zero auto-enable

    func testTransportOrderIsD2AndAutoSelectionNeverMutatesAnyChannel() async {
        let enableCalls = EventRecorder()
        let pairCalls = EventRecorder()
        let report = Self.makePairReport(
            tailscaleEnabled: false,
            tailscaleAvailable: true,
            tailcatEnabled: false,
            tailcatAvailable: true,
            lanEnabled: false,
            lanAvailable: true,
            recommendedTransport: .tailscale
        )
        var deps = Self.makeDependencies(report: report)
        deps.enableTransport = { transport in
            enableCalls.append(transport.rawValue)
        }
        deps.pair = { network in
            pairCalls.append(network.rawValue)
            return Self.makePairing(network: network, expiresAt: Self.formatUTC(Date().addingTimeInterval(300)))
        }

        let store = PairingWindowStore(dependencies: deps)
        await store.handleAppear()

        XCTAssertEqual(store.orderedTransports, [.tailscale, .tailcat, .lan])
        XCTAssertEqual(store.selectedTransport, .tailscale)
        XCTAssertEqual(enableCalls.values, [], "自动推荐选中严禁开启任何通道")
        XCTAssertEqual(pairCalls.values, [], "未启用通道不得调用 pair")
        XCTAssertFalse(store.canIssuePairingQR)
        XCTAssertTrue(store.canExplicitlyEnable(.tailscale))

        // 手动切换到内置连接与局域网同样零自动写入。
        store.selectTransport(.tailcat)
        store.selectTransport(.lan)
        store.selectTransport(.tailscale)
        // 前台刷新也零自动写入。
        store.handleApplicationDidBecomeActive()
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(enableCalls.values, [])
        XCTAssertEqual(pairCalls.values, [])
        XCTAssertNil(store.activePairing)
    }

    func testRecommendedTransportTailcatIsDefaultSelectedWithoutMutation() async {
        let enableCalls = EventRecorder()
        let report = Self.makePairReport(
            tailscaleEnabled: false,
            tailscaleAvailable: false,
            tailcatEnabled: false,
            tailcatAvailable: true,
            lanEnabled: false,
            lanAvailable: true,
            recommendedTransport: .tailcat
        )
        var deps = Self.makeDependencies(report: report)
        deps.enableTransport = { enableCalls.append($0.rawValue) }

        let store = PairingWindowStore(dependencies: deps)
        await store.handleAppear()

        XCTAssertEqual(store.orderedTransports, [.tailscale, .tailcat, .lan])
        XCTAssertEqual(store.selectedTransport, .tailcat)
        XCTAssertEqual(enableCalls.values, [])
    }

    // MARK: - Explicit Tailscale enable -> single reload -> preflight re-verify -> QR

    func testExplicitTailscaleEnableVerifiesAppliedRouteBeforeIssuingQR() async {
        let events = EventRecorder()
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let tsEnabled = MutablePairingState(false)
        var deps = Self.makeDependencies(
            report: Self.makePairReport(tailscaleEnabled: false, tailscaleAvailable: true, recommendedTransport: .tailscale),
            now: { now }
        )
        deps.preflight = { _, _ in
            let enabled = tsEnabled.value
            events.append("preflight(ts=\(enabled))")
            return Self.makePairReport(
                tailscaleEnabled: enabled,
                tailscaleAvailable: true,
                tailcatEnabled: false,
                tailcatAvailable: true,
                lanEnabled: false,
                lanAvailable: false,
                recommendedTransport: .tailscale
            )
        }
        deps.enableTransport = { transport in
            events.append("enable(\(transport.rawValue))")
            tsEnabled.value = true
        }
        deps.pair = { network in
            events.append("pair(\(network.rawValue))")
            return Self.makePairing(network: network, expiresAt: Self.formatUTC(now.addingTimeInterval(180)))
        }

        let store = PairingWindowStore(dependencies: deps)
        await store.handleAppear()
        XCTAssertEqual(events.values, ["preflight(ts=false)"])
        XCTAssertNil(store.activePairing)

        await store.enableSelectedTransport(.tailscale)

        XCTAssertEqual(events.values, [
            "preflight(ts=false)",
            "enable(tailscale)",
            "preflight(ts=true)",
            "pair(tailscale)",
        ])
        XCTAssertTrue(store.canIssuePairingQR)
        XCTAssertEqual(store.activePairing?.network, .tailscale)
        XCTAssertTrue(store.canCopyPairingLink)
    }

    func testExplicitTailscaleEnableDoesNotIssueQRWhenReverifyStillReportsNotReady() async {
        let events = EventRecorder()
        var deps = Self.makeDependencies(
            report: Self.makePairReport(tailscaleEnabled: false, tailscaleAvailable: true, recommendedTransport: .tailscale)
        )
        deps.preflight = { _, _ in
            events.append("preflight")
            // 复核仍返回未应用/未就绪
            return Self.makePairReport(
                tailscaleEnabled: false,
                tailscaleAvailable: true,
                tailcatEnabled: false,
                tailcatAvailable: false,
                lanEnabled: false,
                lanAvailable: false,
                recommendedTransport: .tailscale
            )
        }
        deps.enableTransport = { transport in
            events.append("enable(\(transport.rawValue))")
        }
        deps.pair = { network in
            events.append("pair(\(network.rawValue))")
            return Self.makePairing(network: network, expiresAt: Self.formatUTC(Date().addingTimeInterval(180)))
        }

        let store = PairingWindowStore(dependencies: deps)
        await store.handleAppear()
        await store.enableSelectedTransport(.tailscale)

        XCTAssertEqual(events.values, ["preflight", "enable(tailscale)", "preflight"])
        XCTAssertNil(store.activePairing)
        XCTAssertFalse(store.canCopyPairingLink)
    }

    // MARK: - Issuance gates: assistant_any, network_any, service_daemon, approval vs main-app login item

    func testIssuanceRequiresAssistantAnyNetworkAnyAndServiceDaemonOK() async {
        let pairCalls = CallCounter()
        let cases: [(String, OnboardingPreflightReport)] = [
            ("missing_assistant", Self.makePairReport(assistantReady: false)),
            ("missing_network", Self.makePairReport(tailscaleEnabled: false, tailscaleAvailable: false, tailcatEnabled: false, tailcatAvailable: false, lanEnabled: false, lanAvailable: false, recommendedTransport: nil)),
            ("service_not_running", Self.makePairReport(serviceReady: false)),
        ]
        for (name, report) in cases {
            var deps = Self.makeDependencies(report: report)
            deps.pair = { network in
                _ = pairCalls.increment()
                return Self.makePairing(network: network, expiresAt: Self.formatUTC(Date().addingTimeInterval(180)))
            }
            let store = PairingWindowStore(dependencies: deps)
            await store.handleAppear()
            await store.issuePairingQR()
            XCTAssertFalse(store.canIssuePairingQR, name)
            XCTAssertNil(store.activePairing, name)
            XCTAssertFalse(store.canCopyPairingLink, name)
        }
        XCTAssertEqual(pairCalls.current, 0)
    }

    func testBackgroundAgentRequiresApprovalBlocksQRUntilApprovedWhileMainAppLoginItemDisabledStillAllowsQR() async {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let agentState = MutablePairingState<ServiceRegistrationState>(.requiresApproval)
        let pairCalls = CallCounter()

        var deps = Self.makeDependencies(
            report: Self.makePairReport(serviceReady: false),
            now: { now }
        )
        deps.agentRegistrationState = { agentState.value }
        deps.mainAppRegistrationState = { .notRegistered }
        deps.preflight = { _, _ in
            Self.makePairReport(serviceReady: agentState.value == .enabled)
        }
        deps.pair = { network in
            _ = pairCalls.increment()
            return Self.makePairing(network: network, expiresAt: Self.formatUTC(now.addingTimeInterval(240)))
        }

        let store = PairingWindowStore(dependencies: deps)
        await store.handleAppear()

        // 后台 agent 审批中：禁止出码与复制。
        XCTAssertTrue(store.isServiceRequiresApproval)
        XCTAssertFalse(store.canIssuePairingQR)
        XCTAssertNil(store.activePairing)
        XCTAssertFalse(store.copyPairingLink())
        XCTAssertEqual(pairCalls.current, 0)

        // 批准后台 agent 并复检后，即使主应用登录项仍关闭，仍可正常出码并显示非阻断提醒。
        agentState.value = .enabled
        await store.runPreflight()
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertFalse(store.isServiceRequiresApproval)
        XCTAssertNotNil(store.mainAppLoginItemWarning)
        XCTAssertTrue(store.canIssuePairingQR)
        XCTAssertEqual(pairCalls.current, 1)
        XCTAssertEqual(store.activePairing?.network, .tailscale)
        XCTAssertTrue(store.canCopyPairingLink)
    }

    // MARK: - Real pair_expires_at expiry clearing, switch/failure/leave clearing, late-response discard

    func testRealExpiryClearsQRAndPreventsCopyImmediately() async {
        let clock = MutablePairingClock(Date(timeIntervalSince1970: 1_900_000_000))
        let clipboard = EventRecorder()
        let expiresAt = Self.formatUTC(clock.now.addingTimeInterval(45))

        var deps = Self.makeDependencies(report: Self.makePairReport(), now: { clock.now })
        deps.pair = { network in
            Self.makePairing(network: network, expiresAt: expiresAt)
        }
        deps.copyToClipboard = { value in
            clipboard.append(value)
            return true
        }

        let store = PairingWindowStore(dependencies: deps)
        await store.handleAppear()
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertNotNil(store.activePairing)
        XCTAssertTrue(store.copyPairingLink())
        XCTAssertEqual(clipboard.values.count, 1)

        // 推进时钟至过期瞬间：点击复制或周期检查立即清空 QR 且不写入剪贴板。
        clock.advance(by: 45)
        XCTAssertFalse(store.copyPairingLink())
        XCTAssertNil(store.issuedPairing)
        XCTAssertNil(store.activePairing)
        XCTAssertFalse(store.canCopyPairingLink)
        XCTAssertTrue(store.didExpireCurrentPairing)
        XCTAssertEqual(clipboard.values.count, 1)
    }

    func testSwitchFailureLeaveAndLateResponseDiscardNeverLeaveStaleQR() async {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let firstGate = PairingTestGate()
        let callCounter = CallCounter()

        var deps = Self.makeDependencies(report: Self.makePairReport(), now: { now })
        deps.pair = { network in
            let n = callCounter.increment()
            if n == 1 {
                // 第 1 次（tailscale）故意延迟，在用户切到 tailcat 后迟到返回
                await firstGate.wait()
                return Self.makePairing(
                    network: .tailscale,
                    pairURL: "mimiremote://pair?pair_sig=stale-tailscale",
                    expiresAt: Self.formatUTC(now.addingTimeInterval(300))
                )
            }
            if n == 2 {
                return Self.makePairing(
                    network: .tailcat,
                    pairURL: "mimiremote://pair?pair_sig=fresh-tailcat",
                    expiresAt: Self.formatUTC(now.addingTimeInterval(300))
                )
            }
            throw AgentClientError.onboarding(
                OnboardingCopyCatalog.synthesizeLocal(code: "command_timeout", step: .networkAny)
            )
        }

        let store = PairingWindowStore(dependencies: deps)
        await store.handleAppear()
        await firstGate.waitUntilWaiting()

        // 切换通道立即清旧态并发起新请求
        store.selectTransport(.tailcat)
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(store.activePairing?.pairURL, "mimiremote://pair?pair_sig=fresh-tailcat")

        // 释放迟到的 tailscale 响应：必须被丢弃，不能覆盖当前 tailcat 二维码。
        firstGate.resume()
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(store.selectedTransport, .tailcat)
        XCTAssertEqual(store.activePairing?.pairURL, "mimiremote://pair?pair_sig=fresh-tailcat")

        // 刷新失败立即清 QR 与可复制状态。
        await store.issuePairingQR(for: .tailcat)
        XCTAssertNil(store.issuedPairing)
        XCTAssertNil(store.activePairing)
        XCTAssertFalse(store.canCopyPairingLink)
        XCTAssertNotNil(store.pairingError)

        // 重新拿到有效码后，离开页面立即清空并禁用复制。
        deps.pair = { network in
            Self.makePairing(network: network, expiresAt: Self.formatUTC(now.addingTimeInterval(300)))
        }
        let leaveStore = PairingWindowStore(dependencies: deps)
        await leaveStore.handleAppear()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertNotNil(leaveStore.activePairing)

        leaveStore.handleDisappear()
        XCTAssertNil(leaveStore.issuedPairing)
        XCTAssertNil(leaveStore.activePairing)
        XCTAssertFalse(leaveStore.canCopyPairingLink)
    }

    func testManualRefreshRechecksServiceBeforeIssuingAnotherTicket() async {
        let ready = MutablePairingState(true)
        let calls = CallCounter()
        var deps = Self.makeDependencies(report: Self.makePairReport())
        deps.preflight = { _, _ in Self.makePairReport(serviceReady: ready.value) }
        deps.pair = { network in
            _ = calls.increment()
            return Self.makePairing(network: network, expiresAt: Self.formatUTC(Date().addingTimeInterval(60)))
        }
        let store = PairingWindowStore(dependencies: deps)
        await store.handleAppear()
        await store.issuePairingQR()
        XCTAssertNotNil(store.activePairing)
        let issued = calls.current
        ready.value = false
        await store.issuePairingQR()
        XCTAssertEqual(calls.current, issued)
        XCTAssertFalse(store.canCopyPairingLink)
        XCTAssertNil(store.issuedPairing)
    }

    // MARK: - Helpers

    private nonisolated static func makePairing(
        network: PairingNetwork,
        pairURL: String = "mimiremote://pair?pair_sig=fixture",
        expiresAt: String
    ) -> PairingInfo {
        PairingInfo(
            endpoint: network == .tailcat ? "http://127.0.0.1:8787" : "http://100.64.0.10:8787",
            network: network,
            pairURL: pairURL,
            expiresAt: expiresAt,
            warnings: []
        )
    }

    private static func makeDependencies(
        report: OnboardingPreflightReport,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> PairingWindowDependencies {
        PairingWindowDependencies(
            preflight: { _, _ in report },
            enableTransport: { _ in },
            enableAssistant: { _ in },
            pair: { network in
                Self.makePairing(network: network, expiresAt: Self.formatUTC(now().addingTimeInterval(300)))
            },
            restartService: {},
            registerOrStartService: { .ready },
            agentRegistrationState: { .enabled },
            mainAppRegistrationState: { .enabled },
            photosAccessState: { .notDetermined },
            localNetworkAccessDenied: { false },
            openURL: { _ in },
            openSettings: { _ in },
            copyToClipboard: { _ in true },
            now: now
        )
    }

    nonisolated static func makePairReport(
        serviceReady: Bool = true,
        assistantReady: Bool = true,
        tailscaleEnabled: Bool = true,
        tailscaleAvailable: Bool = true,
        tailcatEnabled: Bool = true,
        tailcatAvailable: Bool = true,
        lanEnabled: Bool = true,
        lanAvailable: Bool = true,
        recommendedTransport: OnboardingTransport? = .tailscale
    ) -> OnboardingPreflightReport {
        let serviceCheck: OnboardingCheck = serviceReady
            ? OnboardingCheck(id: .serviceDaemon, state: .ok, detail: "后台服务已就绪。", blocking: false)
            : OnboardingCheck(
                id: .serviceDaemon,
                state: .actionNeeded,
                detail: "后台服务尚未运行。",
                blocking: true,
                code: "service_not_running",
                fix: .runFix(.restartService)
            )
        let codexCheck: OnboardingCheck = assistantReady
            ? OnboardingCheck(
                id: .assistantCodex, state: .ok, detail: "Codex 已就绪。", blocking: false,
                enabled: true, available: true,
                candidates: [OnboardingCandidate(path: "/fixture/bin/codex", outcome: .selected, version: "0.150.0")],
                source: .auto, detectedVersion: "0.150.0"
            )
            : OnboardingCheck(
                id: .assistantCodex, state: .optional, detail: "未找到 Codex。", blocking: false,
                code: "codex_not_found", fix: .openURL(.codex),
                enabled: false, available: false, candidates: []
            )
        let assistantAnyCheck: OnboardingCheck = assistantReady
            ? OnboardingCheck(id: .assistantAny, state: .ok, detail: "至少有一个可用助手。", blocking: false)
            : OnboardingCheck(
                id: .assistantAny, state: .actionNeeded, detail: "请启用至少一个可用助手。",
                blocking: true, code: "no_enabled_assistant", fix: .openURL(.guide)
            )

        func makeTransportCheck(
            id: OnboardingCheckID,
            enabled: Bool,
            available: Bool,
            disabledCode: String,
            enableAction: OnboardingRunFixAction,
            unavailableState: OnboardingCheckState = .optional,
            unavailableCode: String,
            unavailableFix: OnboardingFix
        ) -> OnboardingCheck {
            if enabled && available {
                return OnboardingCheck(id: id, state: .ok, detail: "已就绪。", blocking: false, enabled: true, available: true)
            }
            if !enabled && available {
                return OnboardingCheck(
                    id: id, state: .actionNeeded, detail: "可启用。", blocking: false,
                    code: disabledCode, fix: .runFix(enableAction),
                    enabled: false, available: true
                )
            }
            return OnboardingCheck(
                id: id, state: unavailableState, detail: "不可用。", blocking: false,
                code: unavailableCode, fix: unavailableFix,
                enabled: enabled, available: false
            )
        }

        let tsCheck = makeTransportCheck(
            id: .networkTailscale, enabled: tailscaleEnabled, available: tailscaleAvailable,
            disabledCode: "tailscale_disabled", enableAction: .enableTailscale,
            unavailableCode: "tailscale_not_connected", unavailableFix: .retry
        )
        let tcCheck = makeTransportCheck(
            id: .networkTailcat, enabled: tailcatEnabled, available: tailcatAvailable,
            disabledCode: "tailcat_disabled", enableAction: .enableTailcat,
            unavailableState: .error,
            unavailableCode: "tailcat_relay_unreachable", unavailableFix: .retry
        )
        let lanCheck = makeTransportCheck(
            id: .networkLAN, enabled: lanEnabled, available: lanAvailable,
            disabledCode: "lan_disabled", enableAction: .enableLAN,
            unavailableCode: "lan_unavailable", unavailableFix: .retry
        )

        let networkReady = (tailscaleEnabled && tailscaleAvailable)
            || (tailcatEnabled && tailcatAvailable)
            || (lanEnabled && lanAvailable)
        let networkAnyCheck: OnboardingCheck
        if networkReady {
            networkAnyCheck = OnboardingCheck(id: .networkAny, state: .ok, detail: "已有可用连接方式。", blocking: false)
        } else if let rec = recommendedTransport {
            let enableAction: OnboardingRunFixAction = switch rec {
            case .tailscale: .enableTailscale
            case .tailcat: .enableTailcat
            case .lan: .enableLAN
            }
            networkAnyCheck = OnboardingCheck(
                id: .networkAny, state: .actionNeeded, detail: "请选择要用于配对的连接方式。",
                blocking: true, code: "network_selection_required", fix: .runFix(enableAction)
            )
        } else {
            networkAnyCheck = OnboardingCheck(
                id: .networkAny, state: .actionNeeded, detail: "暂无可用的连接方式。",
                blocking: true, code: "no_network_available", fix: .retry
            )
        }

        let checks: [OnboardingCheck] = [
            OnboardingCheck(id: .configStore, state: .ok, detail: "配置文件可安全读写。", blocking: false),
            OnboardingCheck(id: .workspaceRoot, state: .ok, detail: "目录可读取。", blocking: false),
            OnboardingCheck(id: .serviceOwnerConflict, state: .ok, detail: "归属已确认。", blocking: false),
            serviceCheck,
            codexCheck,
            OnboardingCheck(
                id: .assistantClaude, state: .optional, detail: "未找到 Claude。", blocking: false,
                code: "claude_not_found", fix: .openURL(.claude),
                enabled: false, available: false, candidates: []
            ),
            OnboardingCheck(
                id: .assistantAgy, state: .optional, detail: "未找到 Antigravity。", blocking: false,
                code: "agy_not_found", fix: .openURL(.agy),
                enabled: false, available: false, candidates: []
            ),
            OnboardingCheck(
                id: .assistantDeepSeek, state: .optional, detail: "未找到 DeepSeek。", blocking: false,
                code: "deepseek_not_running", fix: .openURL(.harness),
                enabled: false, available: false
            ),
            assistantAnyCheck,
            tsCheck,
            tcCheck,
            lanCheck,
            networkAnyCheck,
            OnboardingCheck(id: .permissionLoginItem, state: .ok, detail: "已允许登录时启动。", blocking: false),
            OnboardingCheck(id: .permissionFolderAccess, state: .ok, detail: "已允许访问所选目录。", blocking: false),
            OnboardingCheck(id: .permissionLocalNetwork, state: .ok, detail: "已允许访问本地网络。", blocking: false),
            OnboardingCheck(id: .permissionPhotos, state: .optional, detail: "尚未获得状态。", blocking: false, code: "permission_unobserved", fix: .skip),
            OnboardingCheck(id: .permissionFullDisk, state: .optional, detail: "尚未获得状态。", blocking: false, code: "permission_unobserved", fix: .skip),
        ]
        let firstBlocker = checks.first(where: \.blocking)?.id
        return OnboardingPreflightReport(
            ok: firstBlocker == nil,
            stage: .pair,
            configured: true,
            workspaceConfirmed: true,
            configPath: "/fixture/config/config.json",
            scanRoot: "/fixture/workspace",
            browseRoot: "/fixture/workspace",
            scanRootExists: true,
            recommendedNext: firstBlocker ?? .networkAny,
            recommendedTransport: recommendedTransport,
            checks: checks
        )
    }
}

private final class MutablePairingState<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T

    init(_ initial: T) {
        self.storage = initial
    }

    var value: T {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private final class MutablePairingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ date: Date) {
        self.current = date
    }

    var now: Date {
        lock.withLock { current }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

private final class PairingTestGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var waiting = false
    private var resumed = false

    func wait() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                condition.lock()
                waiting = true
                condition.broadcast()
                while !resumed {
                    condition.wait()
                }
                condition.unlock()
                continuation.resume()
            }
        }
    }

    func waitUntilWaiting() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                condition.lock()
                while !waiting {
                    condition.wait()
                }
                condition.unlock()
                continuation.resume()
            }
        }
    }

    func resume() {
        condition.lock()
        resumed = true
        condition.broadcast()
        condition.unlock()
    }
}
