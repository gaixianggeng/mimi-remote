import XCTest
@testable import MimiRemote

/// 系统相机扫码等外部配对链接由 App 层配对。还没有任何电脑时，首次配对页不读全局
/// `lastError`，只能靠 `pairingLinkAttempt` 看到进度和失败原因（#728）。
@MainActor
final class ExternalPairingLinkTests: XCTestCase {
    private static let expiredTicketLink = URL(
        string: "mimiremote://pair?endpoint=http%3A%2F%2F100.64.0.1%3A8787"
            + "&issued_at=2020-01-01T00%3A00%3A00Z&expires_at=2020-01-01T00%3A10%3A00Z&pair_sig=test-signature"
    )!
    private static let tokenLink = URL(
        string: "mimiremote://pair?endpoint=http%3A%2F%2F100.64.0.1%3A8787&token=test-token"
    )!

    func testFirstConnectionFailurePublishesReasonForFirstConnectionPage() async throws {
        let (store, appStore) = makeStores(routeProbe: { _, _, _ in })

        await store.openPairingLink(Self.expiredTicketLink)

        let expected = PairingLinkError.expired.localizedDescription
        XCTAssertEqual(store.pairingLinkAttempt, .failed(expected), "首次配对页要拿到原始原因，再按本页规则友好化")
        XCTAssertEqual(appStore.lastError, expected, "全局错误照旧记录，已有电脑的页面还在读它")
    }

    func testFirstConnectionReportsConnectingUntilPreparationFails() async throws {
        let gate = RouteProbeGate()
        let (store, _) = makeStores(routeProbe: { _, _, _ in try await gate.wait() })

        let opening = Task { await store.openPairingLink(Self.tokenLink) }
        try await waitUntil { gate.isWaiting }
        XCTAssertEqual(store.pairingLinkAttempt, .connecting, "验证进行中，首次配对页要能禁用按钮并显示正在连接")

        gate.fail(URLError(.cannotConnectToHost))
        await opening.value

        guard case .failed = store.pairingLinkAttempt else {
            return XCTFail("验证失败后必须交出失败原因，而不是停在连接中：\(store.pairingLinkAttempt)")
        }
    }

    func testFirstConnectionSuccessReturnsToIdle() async throws {
        let (store, appStore) = makeStores(routeProbe: { _, _, _ in })

        await store.openPairingLink(Self.tokenLink)

        XCTAssertEqual(store.pairingLinkAttempt, .idle)
        XCTAssertEqual(appStore.connectionProfiles.count, 1)
    }

    func testConfiguredAppLeavesFirstConnectionPageStateUntouched() async throws {
        let (store, appStore) = makeStores(routeProbe: { _, _, _ in })
        _ = try await appStore.commitConnectionSettings(PreparedConnectionSettings(
            endpoint: "http://100.64.0.30:8787",
            token: "existing-token"
        ))

        await store.openPairingLink(Self.expiredTicketLink)

        XCTAssertEqual(store.pairingLinkAttempt, .idle, "已有电脑时由设备页显示全局错误，首次配对页的状态不能残留")
        XCTAssertEqual(appStore.lastError, PairingLinkError.expired.localizedDescription)
    }

    private func makeStores(routeProbe: @escaping ConnectionRouteProbe) -> (SessionStore, AppStore) {
        let suiteName = "ExternalPairingLinkTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("无法创建隔离测试 UserDefaults suite: \(suiteName)")
        }
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let appStore = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations()),
            prefersLocalConnection: false,
            routeProbe: routeProbe
        )
        let client = MockSessionStoreClient(projects: [], sessions: [], messagesResult: [])
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            webSocketFactory: { MockWebSocketClient() },
            webSocketReconnectDelayNanoseconds: { _ in 0 }
        )
        return (store, appStore)
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !condition() {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                return XCTFail("等待条件超时")
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

/// 让路由探测停住直到测试放行；放行为失败后，后续候选地址的探测也立即失败，避免挂住。
@MainActor
private final class RouteProbeGate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private(set) var isWaiting = false

    func wait() async throws {
        if let failure {
            throw failure
        }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            isWaiting = true
        }
    }

    func fail(_ error: Error) {
        failure = error
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
