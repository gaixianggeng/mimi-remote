import StoreKit
import SwiftUI
import XCTest
@testable import MimiRemote

@MainActor
final class ManagedConnectionEntitlementStoreTests: XCTestCase {
    func testMeTabStatusSummaryHidesTransientStatesAndNamesEachOutcome() {
        func entitled(_ status: ManagedConnectionEntitlement.Status) -> ManagedConnectionEntitlementStore.Status {
            .entitled(ManagedConnectionEntitlement(
                id: "entitlement-id",
                productID: ManagedConnectionProductID.annual,
                status: status,
                expiresAt: Date(timeIntervalSinceNow: 3_600)
            ))
        }

        // 检查中或检查失败时首页这一行不显示状态，避免一闪而过的占位文字。
        for transient in [ManagedConnectionEntitlementStore.Status.loading, .resolving, .failed("offline")] {
            XCTAssertNil(ManagedConnectionSubscriptionView.statusSummary(transient))
        }
        let summaries: [(ManagedConnectionEntitlementStore.Status, String)] = [
            (.available, L10n.text("ui.managed_subscription_not_active")),
            (.pending, L10n.text("ui.managed_subscription_short_pending")),
            (.expired, L10n.text("ui.managed_subscription_short_expired")),
            (.revoked, L10n.text("ui.managed_subscription_short_revoked")),
            (entitled(.trial), L10n.text("ui.managed_subscription_short_trial")),
            (entitled(.grace), L10n.text("ui.managed_subscription_short_grace")),
            (entitled(.active), L10n.text("ui.managed_subscription_short_active")),
        ]
        for (status, expected) in summaries {
            XCTAssertEqual(ManagedConnectionSubscriptionView.statusSummary(status), expected)
        }
        // 宽限期与正常订阅必须能区分：扣款出问题要让用户在首页就看到。
        XCTAssertNotEqual(
            ManagedConnectionSubscriptionView.statusSummary(entitled(.grace)),
            ManagedConnectionSubscriptionView.statusSummary(entitled(.active))
        )
    }

    func testPlansListAnnualBeforeMonthly() {
        let monthly = ManagedConnectionProduct(
            id: ManagedConnectionProductID.monthly, displayName: "Monthly",
            displayPrice: "US$1.99", displayPeriod: "Month",
            isEligibleForTrial: true, displayTrialPeriod: "1 week"
        )
        let annual = ManagedConnectionProduct(
            id: ManagedConnectionProductID.annual, displayName: "Annual",
            displayPrice: "US$9.99", displayPeriod: "Year",
            isEligibleForTrial: true, displayTrialPeriod: "1 week"
        )

        XCTAssertEqual(
            ManagedConnectionSubscriptionView.displayOrder([monthly, annual]).map(\.id),
            [ManagedConnectionProductID.annual, ManagedConnectionProductID.monthly]
        )
    }

    // MARK: - 内测兑换码（#949）

    private static var redemptionGrant: ManagedConnectionEntitlementGrant {
        ManagedConnectionEntitlementGrant(
            entitlement: ManagedConnectionEntitlement(
                id: "entitlement-beta",
                productID: ManagedConnectionProductID.betaRedemption,
                status: .active,
                expiresAt: Date().addingTimeInterval(86_400 * 30)
            ),
            token: "beta-token",
            tokenExpiresAt: Date().addingTimeInterval(900)
        )
    }

    private func makeRedemptionStore(
        savedCode: String? = nil
    ) -> (
        store: ManagedConnectionEntitlementStore,
        kit: StoreKitFake,
        api: EntitlementAPIFake,
        codes: InMemoryManagedConnectionRedemptionCodeStore
    ) {
        let kit = StoreKitFake()
        let api = EntitlementAPIFake(result: .success(Self.grant))
        let codes = InMemoryManagedConnectionRedemptionCodeStore(code: savedCode)
        let store = ManagedConnectionEntitlementStore(storeKit: kit, entitlementAPI: api, redemptionCodes: codes)
        return (store, kit, api, codes)
    }

    /// 看一眼 Mimi 页不等于选择 Mimi：返回后线路和设备页显示都不能变。
    func testOpeningMimiPageDoesNotChooseMimi() async throws {
        let suite = "MimiPage.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tokenStore = TokenStore(keychain: TestKeychainOperations())
        let profile = ConnectionProfile(
            id: "studio", displayName: "Studio", endpoint: "http://127.0.0.1:18787",
            lastSuccessfulAt: Date(), installationID: "installation", hostPlatform: .apple,
            connectionRoute: .customTailcat
        )
        defaults.set(try JSONEncoder().encode([profile]), forKey: "agentd.connectionProfiles.v2")
        defaults.set(profile.id, forKey: "agentd.activeConnectionProfileID.v1")
        try tokenStore.save("token", profileID: profile.id)
        let appStore = MimiRemote.AppStore(defaults: defaults, tokenStore: tokenStore, prefersLocalConnection: false)
        appStore.connectionStatus = .connected("test")
        let controller = TailcatExperimentController(appStore: appStore, defaults: defaults, tokenStore: tokenStore)
        controller.selectRelayService(.tailcatDefault, profileID: profile.id)
        let client = MockSessionStoreClient(projects: [], sessions: [])
        let sessionStore = SessionStore(
            appStore: appStore, conversationStore: ConversationStore(), logStore: LogStore(),
            tailcatExperimentController: controller, clientFactory: { client }
        )
        let entitlements = makeRedemptionStore().store
        let themeDefaults = try XCTUnwrap(UserDefaults(suiteName: suite + ".theme"))
        defer { themeDefaults.removePersistentDomain(forName: suite + ".theme") }

        let page = NavigationStack {
            ManagedConnectionSubscriptionView(qrScannerPresentation: ConnectionQRCodeScannerPresentation())
        }
        .environmentObject(appStore)
        .environmentObject(sessionStore)
        .environmentObject(controller)
        .environmentObject(entitlements)
        .environmentObject(ThemeStore(defaults: themeDefaults))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UIHostingController(rootView: page)
        window.isHidden = false
        defer { window.isHidden = true }

        // 查到结果说明页面的 .task 确实跑过，否则后面的断言不证明任何事。
        // 状态会先经过 .resolving，必须等到最终结果；CI 上这一步可能要一两秒。
        let deadline = Date().addingTimeInterval(10)
        while entitlements.status != .available, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(entitlements.status, .available)
        XCTAssertEqual(controller.relayServiceChoice(profileID: profile.id), .tailcatDefault)
    }

    func testRedeemGrantsEntitlementAndSavesTrimmedCode() async {
        let fixture = makeRedemptionStore()
        await fixture.api.setRedeemResult(.success(Self.redemptionGrant))

        await fixture.store.redeem(code: "  MIMI-AAAA-BBBB-CCCC-DDDD\n")

        XCTAssertEqual(fixture.store.currentGrant?.token, "beta-token")
        XCTAssertTrue(fixture.store.isRedemptionEntitlement)
        XCTAssertEqual(fixture.codes.load(), "MIMI-AAAA-BBBB-CCCC-DDDD")
        XCTAssertEqual(fixture.store.managementRedemptionCode, "MIMI-AAAA-BBBB-CCCC-DDDD")
        XCTAssertNil(fixture.store.redemptionErrorMessage)
        let redeemed = await fixture.api.redeemedCodes
        XCTAssertEqual(redeemed, ["MIMI-AAAA-BBBB-CCCC-DDDD"])
    }

    func testKeychainFailureStillGrantsForThisRun() async {
        final class FailingCodeStore: ManagedConnectionRedemptionCodeStoring {
            func load() -> String? { nil }
            func save(_ code: String) throws { throw TokenStoreError.saveFailed(-34018) }
            func delete() {}
        }
        let api = EntitlementAPIFake(result: .success(Self.grant))
        await api.setRedeemResult(.success(Self.redemptionGrant))
        let store = ManagedConnectionEntitlementStore(
            storeKit: StoreKitFake(),
            entitlementAPI: api,
            redemptionCodes: FailingCodeStore()
        )

        await store.redeem(code: "MIMI-CODE")

        XCTAssertTrue(store.isRedemptionEntitlement)
        XCTAssertNil(store.redemptionErrorMessage)
        XCTAssertEqual(store.managementRedemptionCode, "MIMI-CODE")

        // 续签也必须用到内存里的码，否则 15 分钟后 Token 到期就掉线。
        await store.refreshEntitlement()
        XCTAssertTrue(store.isRedemptionEntitlement)
        let redeemed = await api.redeemedCodes
        XCTAssertEqual(redeemed, ["MIMI-CODE", "MIMI-CODE"])
    }

    func testExtractsCodeFromPastedMessage() {
        let cases: [(String, String?)] = [
            ("MIMI-AB12-CD34-EF56-GH78", "MIMI-AB12-CD34-EF56-GH78"),
            ("mimi ab12 cd34 ef56 gh78", "MIMI-AB12-CD34-EF56-GH78"),
            ("你的内测兑换码是：MIMI-AB12-CD34-EF56-GH78，有效期 90 天。", "MIMI-AB12-CD34-EF56-GH78"),
            ("MIMIAB12CD34EF56GH78", "MIMI-AB12-CD34-EF56-GH78"),
            ("MIMI-AB12", nil),
            ("今天天气不错", nil)
        ]
        for (text, expected) in cases {
            XCTAssertEqual(ManagedRedemptionCode.extract(from: text), expected, text)
        }
    }

    func testRedemptionLinkParsing() throws {
        func link(_ raw: String) throws -> ManagedRedemptionLink? {
            ManagedRedemptionLink(url: try XCTUnwrap(URL(string: raw)))
        }
        XCTAssertEqual(try link("mimi://redeem?code=MIMI-AB12-CD34-EF56-GH78")?.code, "MIMI-AB12-CD34-EF56-GH78")
        XCTAssertEqual(try link("mimiremote://redeem?code=mimi-ab12-cd34-ef56-gh78")?.code, "MIMI-AB12-CD34-EF56-GH78")
        XCTAssertNotNil(try link("mimi://redeem?code=bad"))
        XCTAssertNil(try link("mimi://redeem?code=bad")?.code)
        // 配对等其他链接不能被当成兑换链接拦下。
        XCTAssertNil(try link("mimi://pair?endpoint=x"))
        XCTAssertNil(try link("https://redeem/?code=MIMI-AB12-CD34-EF56-GH78"))
    }

    func testRedeemLinkRoutesToConnectStepOnSuccess() async throws {
        let fixture = makeRedemptionStore()
        await fixture.api.setRedeemResult(.success(Self.redemptionGrant))
        let link = try XCTUnwrap(ManagedRedemptionLink(url: XCTUnwrap(URL(string: "mimi://redeem?code=MIMI-AB12-CD34-EF56-GH78"))))

        await fixture.store.redeemFromLink(link)

        XCTAssertEqual(fixture.store.pendingRoute, .connectComputer)
        XCTAssertEqual(fixture.store.consumePendingRoute(), .connectComputer)
        XCTAssertNil(fixture.store.pendingRoute)
        XCTAssertEqual(fixture.codes.load(), "MIMI-AB12-CD34-EF56-GH78")
    }

    func testRedeemLinkFailureRoutesToErrorPage() async throws {
        let fixture = makeRedemptionStore()
        await fixture.store.load()
        let invalid = try XCTUnwrap(ManagedRedemptionLink(url: XCTUnwrap(URL(string: "mimi://redeem?code=bad"))))
        await fixture.store.redeemFromLink(invalid)
        XCTAssertEqual(fixture.store.pendingRoute, .redemption)
        XCTAssertEqual(fixture.store.redemptionErrorMessage, L10n.text("ui.managed_redemption_invalid"))
        let redeemed = await fixture.api.redeemedCodes
        XCTAssertTrue(redeemed.isEmpty, "格式错误的码不发到服务端")

        _ = fixture.store.consumePendingRoute()
        let rejected = try XCTUnwrap(ManagedRedemptionLink(url: XCTUnwrap(URL(string: "mimi://redeem?code=MIMI-AB12-CD34-EF56-GH78"))))
        await fixture.store.redeemFromLink(rejected)
        XCTAssertEqual(fixture.store.pendingRoute, .redemption)
    }

    func testPurchaseOptionsStayHiddenDuringBeta() {
        XCTAssertFalse(ManagedConnectionSubscriptionView.showsPurchaseOptions)
    }

    // MARK: - 转给另一台设备（#989）

    private final class AuthenticatorFake: DeviceOwnerAuthenticating {
        let result: DeviceOwnerAuthenticationResult
        private(set) var promptCount = 0

        init(_ result: DeviceOwnerAuthenticationResult) {
            self.result = result
        }

        func authenticate(reason: String) async -> DeviceOwnerAuthenticationResult {
            promptCount += 1
            return result
        }
    }

    func testTransferCodeIsShownOnlyAfterOwnerVerification() async {
        func outcome(_ result: DeviceOwnerAuthenticationResult) async -> ManagedConnectionTransferGate.Outcome {
            await ManagedConnectionTransferGate.requestCode(
                "MIMI-AAAA-BBBB-CCCC-DDDD", authenticator: AuthenticatorFake(result), reason: "reason"
            )
        }

        let authenticated = await outcome(.authenticated)
        XCTAssertEqual(authenticated, .reveal("MIMI-AAAA-BBBB-CCCC-DDDD"))
        let cancelled = await outcome(.cancelled)
        XCTAssertEqual(cancelled, .cancelled)
        let failed = await outcome(.failed)
        XCTAssertEqual(failed, .failed)
        // 没设锁屏密码时系统无从验证，机主本人也不能因此被挡住。
        let notConfigured = await outcome(.notConfigured)
        XCTAssertEqual(notConfigured, .reveal("MIMI-AAAA-BBBB-CCCC-DDDD"))
    }

    func testTransferWithoutSavedCodeNeverPromptsForVerification() async {
        let authenticator = AuthenticatorFake(.authenticated)
        let outcome = await ManagedConnectionTransferGate.requestCode(nil, authenticator: authenticator, reason: "reason")
        XCTAssertEqual(outcome, .codeUnavailable, "读不到码不能说成身份验证没通过")
        XCTAssertEqual(authenticator.promptCount, 0)
    }

    func testTransferIsOfferedOnlyForRedemptionEntitlement() async {
        let empty = makeRedemptionStore()
        XCTAssertFalse(empty.store.hasTransferableRedemption)
        XCTAssertNil(empty.store.transferableRedemptionCode)

        let redeemed = makeRedemptionStore()
        await redeemed.api.setRedeemResult(.success(Self.redemptionGrant))
        await redeemed.store.redeem(code: "MIMI-AAAA-BBBB-CCCC-DDDD")
        XCTAssertTrue(redeemed.store.hasTransferableRedemption)
        XCTAssertEqual(redeemed.store.transferableRedemptionCode, "MIMI-AAAA-BBBB-CCCC-DDDD")

        // 订阅靠 Apple 账户同步，没有码可转；即使本机还留着旧码也不能出示。
        let subscribed = makeRedemptionStore(savedCode: "MIMI-AAAA-BBBB-CCCC-DDDD")
        await subscribed.kit.setCurrent(.verified(Self.evidence), productID: ManagedConnectionProductID.monthly)
        await subscribed.store.load()
        XCTAssertEqual(subscribed.store.currentGrant, Self.grant)
        XCTAssertFalse(subscribed.store.hasTransferableRedemption)
        XCTAssertNil(subscribed.store.transferableRedemptionCode)
    }

    func testTransferEntryOutlivesTheShortEntitlementToken() async {
        var current = Date()
        let api = EntitlementAPIFake(result: .success(Self.grant))
        await api.setRedeemResult(.success(Self.redemptionGrant))
        let store = ManagedConnectionEntitlementStore(
            storeKit: StoreKitFake(),
            entitlementAPI: api,
            redemptionCodes: InMemoryManagedConnectionRedemptionCodeStore(),
            now: { current }
        )
        await store.redeem(code: "MIMI-AAAA-BBBB-CCCC-DDDD")

        current = current.addingTimeInterval(3_600)
        XCTAssertTrue(store.hasTransferableRedemption, "token 到期不代表资格失效")
        XCTAssertEqual(store.transferableRedemptionCode, "MIMI-AAAA-BBBB-CCCC-DDDD")

        current = current.addingTimeInterval(86_400 * 31)
        XCTAssertFalse(store.hasTransferableRedemption, "权益本身到期后不再出示")
        XCTAssertNil(store.transferableRedemptionCode)
    }

    func testTransferLinkRoundTripsThroughRedemptionParser() throws {
        let url = try XCTUnwrap(ManagedRedemptionLink.url(forCode: "MIMI-AB12-CD34-EF56-GH78"))
        XCTAssertEqual(url.absoluteString, "mimi://redeem?code=MIMI-AB12-CD34-EF56-GH78")
        XCTAssertEqual(ManagedRedemptionLink(url: url)?.code, "MIMI-AB12-CD34-EF56-GH78")
        // 扫码页直接从二维码原文取码，和粘贴走同一套解析。
        XCTAssertEqual(ManagedRedemptionCode.extract(from: url.absoluteString), "MIMI-AB12-CD34-EF56-GH78")
    }

    func testScannedRedemptionReportsOutcomeToScanner() async {
        let success = makeRedemptionStore()
        await success.api.setRedeemResult(.success(Self.redemptionGrant))
        await success.store.redeem(code: "MIMI-AAAA-BBBB-CCCC-DDDD")
        XCTAssertEqual(
            success.store.redemptionScanResult,
            .activated(L10n.text("ui.managed_transfer_success")),
            "「扫电脑」入口扫到邀请码时标题也要说开通成功"
        )

        let failure = makeRedemptionStore()
        await failure.store.redeem(code: "MIMI-AAAA-BBBB-CCCC-DDDD")
        let message = failure.store.redemptionErrorMessage
        XCTAssertNotNil(message)
        XCTAssertEqual(failure.store.redemptionScanResult, .rejected(message ?? ""))
    }

    func testRedemptionScannerHidesComputerPairingFallbacks() {
        for action in [QRCodeScannerRecoveryAction.pasteLink, .manualConnection] {
            XCTAssertFalse(QRCodeScannerPurpose.redemption.allows(action))
            XCTAssertTrue(QRCodeScannerPurpose.pairing.allows(action))
        }
        for action in [QRCodeScannerRecoveryAction.openSettings, .retryScanning] {
            XCTAssertTrue(QRCodeScannerPurpose.redemption.allows(action))
        }
    }

    func testRedeemIgnoresBlankInput() async {
        let fixture = makeRedemptionStore()

        await fixture.store.redeem(code: "   ")

        let redeemed = await fixture.api.redeemedCodes
        XCTAssertTrue(redeemed.isEmpty)
    }

    func testRejectedCodeShowsErrorAndIsNotSaved() async {
        let fixture = makeRedemptionStore()
        await fixture.store.load()
        await fixture.api.setRedeemResult(
            .failure(ManagedConnectionEntitlementAPIError.rejected(code: "invalid_redemption_code"))
        )

        await fixture.store.redeem(code: "MIMI-BAD")

        XCTAssertEqual(fixture.store.status, .available)
        XCTAssertNil(fixture.codes.load())
        XCTAssertEqual(fixture.store.redemptionErrorMessage, L10n.text("ui.managed_redemption_invalid"))
    }

    func testExpiredAndRevokedCodesUseRedemptionWording() async {
        for (code, key) in [
            ("expired", "ui.managed_redemption_expired"),
            ("revoked", "ui.managed_redemption_revoked")
        ] {
            let fixture = makeRedemptionStore()
            await fixture.store.load()
            await fixture.api.setRedeemResult(.failure(ManagedConnectionEntitlementAPIError.rejected(code: code)))

            await fixture.store.redeem(code: "MIMI-OLD")

            XCTAssertEqual(fixture.store.redemptionErrorMessage, L10n.text(key))
            XCTAssertEqual(fixture.store.status, .available)
            XCTAssertNil(fixture.codes.load())
        }
    }

    func testSubscriptionKeepsWorkingWhenRedemptionFails() async {
        let fixture = makeRedemptionStore()
        await fixture.kit.setCurrent(.verified(Self.evidence), productID: ManagedConnectionProductID.monthly)
        await fixture.store.load()
        XCTAssertEqual(fixture.store.currentGrant, Self.grant)

        await fixture.store.redeem(code: "MIMI-BAD")

        XCTAssertEqual(fixture.store.currentGrant, Self.grant)
        XCTAssertFalse(fixture.store.isRedemptionEntitlement)
        XCTAssertNil(fixture.store.managementRedemptionCode)
    }

    func testColdStartRenewsFromSavedCode() async {
        let fixture = makeRedemptionStore(savedCode: "MIMI-SAVED")
        await fixture.api.setRedeemResult(.success(Self.redemptionGrant))

        await fixture.store.load()

        XCTAssertTrue(fixture.store.isRedemptionEntitlement)
        let redeemed = await fixture.api.redeemedCodes
        XCTAssertEqual(redeemed, ["MIMI-SAVED"])
    }

    func testSubscriptionWinsOverSavedCode() async {
        let fixture = makeRedemptionStore(savedCode: "MIMI-SAVED")
        await fixture.api.setRedeemResult(.success(Self.redemptionGrant))
        await fixture.kit.setCurrent(.verified(Self.evidence), productID: ManagedConnectionProductID.monthly)

        await fixture.store.load()

        XCTAssertEqual(fixture.store.currentGrant, Self.grant)
        XCTAssertFalse(fixture.store.isRedemptionEntitlement)
        let redeemed = await fixture.api.redeemedCodes
        XCTAssertTrue(redeemed.isEmpty)
    }

    func testRefreshForgetsCodeTheServerNoLongerKnows() async {
        let fixture = makeRedemptionStore(savedCode: "MIMI-GONE")
        await fixture.api.setRedeemResult(
            .failure(ManagedConnectionEntitlementAPIError.rejected(code: "invalid_redemption_code"))
        )

        await fixture.store.load()

        XCTAssertEqual(fixture.store.status, .available)
        XCTAssertNil(fixture.codes.load())
    }

    func testRefreshReportsExpiredCodeAndKeepsItForLaterExtension() async {
        let fixture = makeRedemptionStore(savedCode: "MIMI-OLD")
        await fixture.api.setRedeemResult(.failure(ManagedConnectionEntitlementAPIError.rejected(code: "expired")))

        await fixture.store.load()

        XCTAssertEqual(fixture.store.status, .expired)
        XCTAssertNil(fixture.store.currentGrant)
        XCTAssertEqual(fixture.codes.load(), "MIMI-OLD")
    }

    func testRevokedSubscriptionUpdateKeepsValidRedemption() async {
        let fixture = makeRedemptionStore()
        await fixture.api.setRedeemResult(.success(Self.redemptionGrant))
        await fixture.store.redeem(code: "MIMI-CODE")
        await fixture.api.setResult(.failure(ManagedConnectionEntitlementAPIError.rejected(code: "revoked")))
        let observer = Task { await fixture.store.observeTransactionUpdates() }

        await fixture.kit.sendTransactionUpdate(.verified(Self.evidence))
        await waitUntil { await fixture.kit.finishedTransactionIDs.count == 1 }
        await waitUntil { await fixture.api.redeemedCodes.count == 2 }
        await waitUntil { @MainActor in fixture.store.isRedemptionEntitlement }

        XCTAssertEqual(fixture.store.currentGrant?.token, "beta-token")
        observer.cancel()
    }

    func testRevokedSubscriptionDuringRefreshFallsBackToRedemption() async {
        let fixture = makeRedemptionStore(savedCode: "MIMI-CODE")
        await fixture.api.setRedeemResult(.success(Self.redemptionGrant))
        await fixture.api.setResult(.failure(ManagedConnectionEntitlementAPIError.rejected(code: "expired")))
        await fixture.kit.setCurrent(.verified(Self.evidence), productID: ManagedConnectionProductID.monthly)

        await fixture.store.load()

        XCTAssertTrue(fixture.store.isRedemptionEntitlement)
        XCTAssertEqual(fixture.store.currentGrant?.token, "beta-token")
    }

    func testTransientSubscriptionFailureDoesNotUseRedemption() async {
        let fixture = makeRedemptionStore(savedCode: "MIMI-CODE")
        await fixture.api.setRedeemResult(.success(Self.redemptionGrant))
        await fixture.api.setResult(.failure(TestError.serverUnavailable))
        await fixture.kit.setCurrent(.verified(Self.evidence), productID: ManagedConnectionProductID.monthly)

        await fixture.store.load()

        XCTAssertFalse(fixture.store.isRedemptionEntitlement)
        let redeemed = await fixture.api.redeemedCodes
        XCTAssertTrue(redeemed.isEmpty)
    }

    func testRevocationDuringRefreshEndsRedemptionGrant() async {
        let fixture = makeRedemptionStore()
        await fixture.api.setRedeemResult(.success(Self.redemptionGrant))
        await fixture.store.redeem(code: "MIMI-CODE")
        await fixture.api.setRedeemResult(.failure(ManagedConnectionEntitlementAPIError.rejected(code: "revoked")))

        await fixture.store.refreshEntitlement()

        XCTAssertEqual(fixture.store.status, .revoked)
        XCTAssertNil(fixture.store.currentGrant)
        XCTAssertNil(fixture.store.managementRedemptionCode)
    }

    func testNetworkFailureKeepsRedemptionGrant() async {
        let fixture = makeRedemptionStore()
        await fixture.api.setRedeemResult(.success(Self.redemptionGrant))
        await fixture.store.redeem(code: "MIMI-CODE")
        await fixture.api.setRedeemResult(.failure(TestError.serverUnavailable))

        await fixture.store.refreshEntitlement()

        XCTAssertTrue(fixture.store.isRedemptionEntitlement)
        XCTAssertEqual(fixture.store.currentGrant?.token, "beta-token")
        XCTAssertEqual(fixture.codes.load(), "MIMI-CODE")
    }

    func testRestorePurchasesKeepsRedemptionEntitlement() async {
        let fixture = makeRedemptionStore()
        await fixture.api.setRedeemResult(.success(Self.redemptionGrant))
        await fixture.store.redeem(code: "MIMI-CODE")

        let result = await fixture.store.restorePurchases()

        XCTAssertEqual(result, .restored)
        XCTAssertTrue(fixture.store.isRedemptionEntitlement)
    }

    func testRedemptionRejectsGrantForAnotherProduct() async {
        let fixture = makeRedemptionStore()
        await fixture.store.load()
        await fixture.api.setRedeemResult(.success(Self.grant))

        await fixture.store.redeem(code: "MIMI-CODE")

        XCTAssertNil(fixture.store.currentGrant)
        XCTAssertNil(fixture.codes.load())
        XCTAssertNotNil(fixture.store.redemptionErrorMessage)
    }

    func testLiveClientPostsRedemptionCodeAsJSON() async throws {
        let expires = "2027-02-01T00:00:00.000Z"
        let body = #"{"entitlement":{"id":"e","productId":"com.gaixianggeng.mimi.managed.beta","status":"active","expiresAt":"\#(expires)"},"entitlementToken":"token","tokenExpiresAt":"\#(expires)"}"#
        let (client, recorder) = RedemptionURLProtocol.makeClient(status: 200, body: body)

        let grant = try await client.redeem(code: "MIMI-CODE")

        XCTAssertEqual(grant.entitlement.productID, ManagedConnectionProductID.betaRedemption)
        XCTAssertEqual(recorder.path, "/v1/redemptions/resolve")
        XCTAssertEqual(recorder.body, #"{"code":"MIMI-CODE"}"#)
    }

    func testLiveClientSurfacesRedemptionRejectionCode() async {
        let (client, _) = RedemptionURLProtocol.makeClient(
            status: 403,
            body: #"{"code":"invalid_redemption_code","message":"x"}"#
        )

        do {
            _ = try await client.redeem(code: "MIMI-BAD")
            XCTFail("应当被拒绝")
        } catch {
            XCTAssertEqual(error.localizedDescription, L10n.text("ui.managed_redemption_invalid"))
        }
    }

    func testPurchaseFinishesOnlyTerminalServerDecisions() async {
        for code in ["expired", "revoked", "no_current_entitlement", "unverified_transaction"] {
            let kit = StoreKitFake()
            let api = EntitlementAPIFake(result: .failure(
                ManagedConnectionEntitlementAPIError.rejected(code: code)
            ))
            await kit.setPurchase(.success(Self.evidence))
            let store = ManagedConnectionEntitlementStore(storeKit: kit, entitlementAPI: api)

            await store.purchase(productID: ManagedConnectionProductID.monthly)

            let finished = await kit.finishedTransactionIDs
            let resolves = await api.resolveCount
            XCTAssertEqual(resolves, 1)
            XCTAssertEqual(finished, code == "unverified_transaction" ? [] : [Self.evidence.transactionID], code)
            XCTAssertNil(store.currentGrant)
            XCTAssertFalse(store.isBusy)
        }
    }

    func testRestoreReportsNoActiveSubscriptionOnlyAfterCompletedVerification() async {
        for rejection in [nil, "expired", "revoked", "no_current_entitlement"] as [String?] {
            let kit = StoreKitFake()
            let api = EntitlementAPIFake(result: .success(Self.grant))
            if let rejection {
                await kit.setCurrent(.verified(Self.evidence), productID: ManagedConnectionProductID.monthly)
                await api.setResult(.failure(ManagedConnectionEntitlementAPIError.rejected(code: rejection)))
            }
            let store = ManagedConnectionEntitlementStore(storeKit: kit, entitlementAPI: api)

            let result = await store.restorePurchases()

            XCTAssertEqual(result, .noActiveSubscription)
            XCTAssertNil(store.currentGrant)
            XCTAssertFalse(store.isBusy)
            let syncs = await kit.syncCount
            XCTAssertEqual(syncs, 1)
        }
    }

    func testCancelledOrFailedRestoreDoesNotReportSuccessOrEmptyPurchases() async {
        for phase in ["sync", "resolve"] {
            for error in [CancellationError(), TestError.serverUnavailable] as [Error] {
                let kit = StoreKitFake()
                let api = EntitlementAPIFake(result: .success(Self.grant))
                await kit.setCurrent(.verified(Self.evidence), productID: ManagedConnectionProductID.monthly)
                let store = ManagedConnectionEntitlementStore(storeKit: kit, entitlementAPI: api)
                await store.refreshEntitlement()
                if phase == "sync" {
                    await kit.setSyncError(error)
                } else {
                    await api.setResult(.failure(error))
                }

                let result = await store.restorePurchases()

                XCTAssertNil(result, phase)
                XCTAssertEqual(store.currentGrant, Self.grant)
                XCTAssertFalse(store.isBusy)
            }
        }
    }

    func testRestoreDoesNotReportOldEmptyResultAfterNewEntitlementArrives() async {
        let kit = StoreKitFake()
        let api = EntitlementAPIFake(result: .success(Self.grant))
        let store = ManagedConnectionEntitlementStore(storeKit: kit, entitlementAPI: api)
        await store.load()
        await kit.pauseNextProductLoad()
        let restore = Task { await store.restorePurchases() }
        await waitUntil { await kit.isProductLoadPaused }
        await kit.setCurrent(.verified(Self.evidence), productID: ManagedConnectionProductID.monthly)
        await store.refreshEntitlement()
        await kit.resumeProductLoad()

        let result = await restore.value

        XCTAssertNil(result)
        XCTAssertEqual(store.currentGrant, Self.grant)
    }

    func testDeferredMaintenanceRefreshRenewsAfterPaymentExpiresAndIsCancelled() async {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let initial = Self.grant(now: base)
        let renewed = ManagedConnectionEntitlementGrant(
            entitlement: initial.entitlement, token: "renewed-token",
            tokenExpiresAt: base.addingTimeInterval(1_800)
        )
        var currentTime = base
        let kit = StoreKitFake()
        let api = EntitlementAPIFake(result: .success(initial))
        let sleeper = SleepUntilFake()
        await kit.setCurrent(.verified(Self.evidence), productID: ManagedConnectionProductID.monthly)
        let store = ManagedConnectionEntitlementStore(
            storeKit: kit, entitlementAPI: api, now: { currentTime },
            sleepUntil: { try await sleeper.sleep(until: $0) }
        )
        await store.refreshEntitlement()
        await api.setResult(.success(renewed))
        await kit.pausePurchase()
        let purchase = Task { await store.purchase(productID: ManagedConnectionProductID.annual) }
        await waitUntil { await kit.isPurchasePaused }
        let maintenance = Task { await store.maintainCurrentGrant() }
        await waitUntil { await sleeper.hasWaiter }
        currentTime = initial.tokenExpiresAt.addingTimeInterval(-60)
        await sleeper.resume()
        await waitUntil { await sleeper.scheduledDate == initial.tokenExpiresAt }
        currentTime = initial.tokenExpiresAt.addingTimeInterval(1)
        await sleeper.resume()
        await maintenance.value
        // 支付弹窗关闭的前台通知也可能先于购买回调；重复通知应合并。
        await store.refreshEntitlement()
        await kit.resumePurchase()
        await purchase.value

        let resolveCount = await api.resolveCount
        let syncCount = await kit.syncCount
        XCTAssertEqual(store.currentGrant, renewed)
        XCTAssertEqual(store.status, .entitled(renewed.entitlement))
        XCTAssertEqual(resolveCount, 2)
        XCTAssertEqual(syncCount, 0)
    }

    func testDeferredRefreshRunsAfterCancelledRestore() async {
        let kit = StoreKitFake()
        let api = EntitlementAPIFake(result: .success(Self.grant))
        await kit.pauseSync()
        await kit.setSyncError(CancellationError())
        let store = ManagedConnectionEntitlementStore(storeKit: kit, entitlementAPI: api)
        let restore = Task { await store.restorePurchases() }
        await waitUntil { await kit.isSyncPaused }
        await store.refreshEntitlement()
        await kit.setCurrent(.verified(Self.evidence), productID: ManagedConnectionProductID.monthly)
        await kit.resumeSync()
        await restore.value

        let resolveCount = await api.resolveCount
        XCTAssertEqual(store.currentGrant, Self.grant)
        XCTAssertEqual(resolveCount, 1)
    }

    func testDeferredRefreshSurvivesCancellationOfPurchaseOrRestoreTask() async {
        for operation in ["purchase", "restore"] {
            let kit = StoreKitFake()
            let api = EntitlementAPIFake(result: .success(Self.grant))
            let store = ManagedConnectionEntitlementStore(storeKit: kit, entitlementAPI: api)
            await kit.pausePurchase()
            await kit.setPurchaseError(CancellationError())
            await kit.pauseSync()
            await kit.setSyncError(CancellationError())
            let transaction = Task {
                if operation == "purchase" {
                    await store.purchase(productID: ManagedConnectionProductID.monthly)
                } else {
                    await store.restorePurchases()
                }
            }
            await waitUntil {
                if operation == "purchase" { return await kit.isPurchasePaused }
                return await kit.isSyncPaused
            }
            // 另一调用者已请求刷新并返回；取消交易任务不能顺带取消该请求。
            await store.refreshEntitlement()
            await kit.setCurrent(.verified(Self.evidence), productID: ManagedConnectionProductID.monthly)
            transaction.cancel()
            if operation == "purchase" {
                await kit.resumePurchase()
            } else {
                await kit.resumeSync()
            }
            await transaction.value

            let resolveCount = await api.resolveCount
            XCTAssertEqual(store.currentGrant, Self.grant, operation)
            XCTAssertEqual(resolveCount, 1, operation)
            XCTAssertFalse(store.isBusy, operation)
        }
    }

    func testProductLoadFailureCannotUndoConcurrentServerDecision() async {
        for error in [TestError.serverUnavailable as Error, CancellationError()] {
            let kit = StoreKitFake()
            let api = EntitlementAPIFake(result: .success(Self.grant))
            await kit.setCurrent(.verified(Self.evidence), productID: ManagedConnectionProductID.monthly)
            let store = ManagedConnectionEntitlementStore(storeKit: kit, entitlementAPI: api)
            await store.refreshEntitlement()
            await api.pauseNextResolve()
            await api.setResult(.failure(ManagedConnectionEntitlementAPIError.rejected(code: "revoked")))
            let refresh = Task { await store.refreshEntitlement() }
            await waitUntil { await api.isResolvePaused }
            await kit.pauseNextProductLoad()
            let load = Task { await store.load() }
            await waitUntil { await kit.isProductLoadPaused }
            await api.resumeResolve()
            await refresh.value
            XCTAssertEqual(store.status, .revoked)
            await kit.setProductsError(error)
            await kit.resumeProductLoad()
            await load.value

            XCTAssertEqual(store.status, .revoked)
            XCTAssertNil(store.currentGrant)
            XCTAssertNil(store.currentEvidence)
        }
    }

    func testSlowProductRefreshDoesNotBlockRevocationAndCoalescesUpdates() async {
        let kit = StoreKitFake()
        let api = EntitlementAPIFake(result: .success(Self.grant))
        let store = ManagedConnectionEntitlementStore(storeKit: kit, entitlementAPI: api)
        await store.load()
        await kit.pauseNextProductLoad()
        let observer = Task { await store.observeTransactionUpdates() }
        await kit.sendTransactionUpdate(.verified(Self.evidence))
        await waitUntil { await kit.isProductLoadPaused }
        await api.setResult(.failure(ManagedConnectionEntitlementAPIError.rejected(code: "revoked")))
        await kit.sendTransactionUpdate(.verified(Self.evidence))
        await kit.sendTransactionUpdate(.verified(Self.evidence))
        await waitUntil { await kit.finishedTransactionIDs.count == 3 }

        XCTAssertEqual(store.status, .revoked)
        XCTAssertNil(store.currentGrant)
        let pausedCount = await kit.productsCount
        XCTAssertEqual(pausedCount, 2)
        await kit.setProducts([Self.updatedProduct])
        await kit.resumeProductLoad()
        await waitUntil { store.products == [Self.updatedProduct] }
        observer.cancel()
        await observer.value
        let productsCount = await kit.productsCount
        XCTAssertEqual(productsCount, 3)
    }

    func testStoppingTransactionObserverDiscardsPausedProductResult() async {
        let kit = StoreKitFake()
        let store = ManagedConnectionEntitlementStore(
            storeKit: kit, entitlementAPI: EntitlementAPIFake(result: .success(Self.grant))
        )
        await kit.setProducts([Self.oldProduct])
        await store.load()
        await kit.setProducts([Self.updatedProduct])
        await kit.pauseNextProductLoad()
        let observer = Task { await store.observeTransactionUpdates() }
        await kit.sendTransactionUpdate(.verified(Self.evidence))
        await waitUntil { await kit.isProductLoadPaused }
        observer.cancel()
        await observer.value
        await kit.resumeProductLoad()
        // 刷新任务已取消，即使底层请求稍后返回，也不得提交商品结果。
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(store.products, [Self.oldProduct])
    }

    func testForegroundRefreshAndPageLoadCannotDiscardPurchaseSuccess() async {
        let storeKit = StoreKitFake()
        await storeKit.setPurchase(.success(Self.evidence))
        await storeKit.pausePurchase()
        let api = EntitlementAPIFake(result: .success(Self.grant))
        let store = ManagedConnectionEntitlementStore(storeKit: storeKit, entitlementAPI: api)
        let purchase = Task { await store.purchase(productID: ManagedConnectionProductID.monthly) }
        await waitUntil { await storeKit.isPurchasePaused }

        await store.refreshEntitlement()
        await store.load()
        XCTAssertEqual(store.status, .resolving)
        XCTAssertTrue(store.isBusy)
        await storeKit.resumePurchase()
        await purchase.value

        let resolveCount = await api.resolveCount
        let finished = await storeKit.finishedTransactionIDs
        XCTAssertEqual(store.currentGrant, Self.grant)
        XCTAssertEqual(store.status, .entitled(Self.grant.entitlement))
        XCTAssertEqual(resolveCount, 1)
        XCTAssertEqual(finished, [42])
        XCTAssertFalse(store.isBusy)
    }

    func testForegroundRefreshCannotDiscardManualRestore() async {
        let storeKit = StoreKitFake()
        await storeKit.pauseSync()
        let api = EntitlementAPIFake(result: .success(Self.grant))
        let store = ManagedConnectionEntitlementStore(storeKit: storeKit, entitlementAPI: api)
        let restore = Task { await store.restorePurchases() }
        await waitUntil { await storeKit.isSyncPaused }

        await store.refreshEntitlement()
        XCTAssertEqual(store.status, .resolving)
        await storeKit.setCurrent(.verified(Self.evidence), productID: ManagedConnectionProductID.monthly)
        await storeKit.resumeSync()
        await restore.value

        let syncCount = await storeKit.syncCount
        let resolveCount = await api.resolveCount
        XCTAssertEqual(syncCount, 1)
        XCTAssertEqual(resolveCount, 1)
        XCTAssertEqual(store.currentGrant, Self.grant)
        XCTAssertFalse(store.isBusy)
    }

    func testCancelledPurchaseDoesNotRestoreTokenThatExpiredWhilePaymentWasOpen() async {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let grant = Self.grant(now: base)
        var currentTime = base
        let storeKit = StoreKitFake()
        await storeKit.setCurrent(.verified(Self.evidence), productID: ManagedConnectionProductID.monthly)
        let store = ManagedConnectionEntitlementStore(
            storeKit: storeKit,
            entitlementAPI: EntitlementAPIFake(result: .success(grant)),
            now: { currentTime }
        )
        await store.refreshEntitlement()
        await storeKit.pausePurchase()
        let purchase = Task { await store.purchase(productID: ManagedConnectionProductID.annual) }
        await waitUntil { await storeKit.isPurchasePaused }
        currentTime = grant.tokenExpiresAt.addingTimeInterval(1)
        await storeKit.resumePurchase()
        await purchase.value

        XCTAssertNil(store.currentGrant)
        XCTAssertEqual(store.status, .available)
        XCTAssertFalse(store.isBusy)
    }

    func testRevocationUpdateStillWinsOverOlderPurchaseResolution() async {
        let storeKit = StoreKitFake()
        await storeKit.setPurchase(.success(Self.evidence))
        let api = DelayedEntitlementAPIFake()
        let store = ManagedConnectionEntitlementStore(storeKit: storeKit, entitlementAPI: api)
        let observer = Task { await store.observeTransactionUpdates() }
        let purchase = Task { await store.purchase(productID: ManagedConnectionProductID.monthly) }
        await waitUntil { await api.hasStartedFirstRequest }

        await storeKit.sendTransactionUpdate(.verified(Self.evidence))
        await waitUntil { store.status == .revoked }
        await store.refreshEntitlement()
        XCTAssertEqual(store.status, .revoked)
        await api.completeFirstRequest(with: Self.grant)
        await purchase.value
        observer.cancel()
        await observer.value

        XCTAssertEqual(store.status, .revoked)
        XCTAssertNil(store.currentGrant)
        XCTAssertFalse(store.isBusy)
    }

    func testPurchaseRestoreAndTransactionUpdateRefreshPricesAndTrialEligibility() async {
        for operation in ["purchase", "restore", "update"] {
            let storeKit = StoreKitFake()
            await storeKit.setProducts([Self.oldProduct])
            let store = ManagedConnectionEntitlementStore(
                storeKit: storeKit,
                entitlementAPI: EntitlementAPIFake(result: .success(Self.grant))
            )
            await store.load()
            XCTAssertEqual(store.products, [Self.oldProduct])
            await storeKit.setProducts([Self.updatedProduct])

            switch operation {
            case "purchase":
                await storeKit.setPurchase(.success(Self.evidence))
                await store.purchase(productID: ManagedConnectionProductID.monthly)
            case "restore":
                await storeKit.setCurrent(.verified(Self.evidence), productID: ManagedConnectionProductID.monthly)
                await store.restorePurchases()
            default:
                let observer = Task { await store.observeTransactionUpdates() }
                await storeKit.sendTransactionUpdate(.verified(Self.evidence))
                await waitUntil { store.products == [Self.updatedProduct] }
                observer.cancel()
                await observer.value
            }

            XCTAssertEqual(store.products, [Self.updatedProduct], operation)
            XCTAssertEqual(store.status, .entitled(Self.grant.entitlement), operation)
        }
    }

    func testStorefrontRefreshUpdatesCatalogWithoutInterruptingPurchase() async {
        let storeKit = StoreKitFake()
        await storeKit.setProducts([Self.oldProduct])
        let store = ManagedConnectionEntitlementStore(
            storeKit: storeKit,
            entitlementAPI: EntitlementAPIFake(result: .success(Self.grant))
        )
        await store.load()
        await storeKit.pausePurchase()
        let purchase = Task { await store.purchase(productID: ManagedConnectionProductID.monthly) }
        await waitUntil { await storeKit.isPurchasePaused }
        let observer = Task { await store.observeStorefrontUpdates() }
        await storeKit.setProducts([Self.updatedProduct])
        await storeKit.sendStorefrontUpdate()
        await waitUntil { store.products == [Self.updatedProduct] }

        XCTAssertEqual(store.status, .resolving)
        XCTAssertTrue(store.isBusy)
        await storeKit.resumePurchase()
        await purchase.value
        observer.cancel()
        await observer.value
        XCTAssertEqual(store.products, [Self.updatedProduct])
        XCTAssertEqual(store.status, .available)
    }

    func testLateInitialProductLoadCannotOverwriteNewStorefrontCatalog() async {
        let storeKit = StoreKitFake()
        await storeKit.setProducts([Self.oldProduct])
        await storeKit.pauseNextProductLoad()
        let store = ManagedConnectionEntitlementStore(
            storeKit: storeKit,
            entitlementAPI: EntitlementAPIFake(result: .success(Self.grant))
        )
        let initialLoad = Task { await store.load() }
        await waitUntil { await storeKit.isProductLoadPaused }
        await storeKit.setProducts([Self.updatedProduct])
        await store.refreshProducts()
        await storeKit.resumeProductLoad()
        await initialLoad.value

        XCTAssertEqual(store.products, [Self.updatedProduct])
        XCTAssertFalse(store.isBusy)
    }

    // #1006：Mimi 中转只在中国大陆 App Store 销售。其他地区拉不到商品要说明原因，不能显示成临时故障。
    func testEmptyCatalogOutsideSalesStorefrontIsExplainedAsRegion() async {
        let storeKit = StoreKitFake()
        await storeKit.setStorefrontCountryCode("USA")
        let store = ManagedConnectionEntitlementStore(
            storeKit: storeKit,
            entitlementAPI: EntitlementAPIFake(result: .success(Self.grant))
        )
        await store.load()

        XCTAssertEqual(store.storefrontCountryCode, "USA")
        XCTAssertEqual(store.productsUnavailableReason, .notSoldInStorefront)
        XCTAssertNotEqual(
            L10n.text(ManagedConnectionSubscriptionView.productsUnavailableKey(.notSoldInStorefront)),
            L10n.text(ManagedConnectionSubscriptionView.productsUnavailableKey(.temporarilyUnavailable))
        )
    }

    func testEmptyCatalogInSalesStorefrontOrUnknownRegionStaysTemporary() async {
        for countryCode in ["CHN", nil] as [String?] {
            let storeKit = StoreKitFake()
            await storeKit.setStorefrontCountryCode(countryCode)
            let store = ManagedConnectionEntitlementStore(
                storeKit: storeKit,
                entitlementAPI: EntitlementAPIFake(result: .success(Self.grant))
            )
            await store.load()

            XCTAssertEqual(store.productsUnavailableReason, .temporarilyUnavailable, "\(String(describing: countryCode))")
        }
    }

    func testLoadedCatalogHasNoUnavailableReasonInAnyRegion() async {
        let storeKit = StoreKitFake()
        await storeKit.setProducts([Self.oldProduct])
        await storeKit.setStorefrontCountryCode("USA")
        let store = ManagedConnectionEntitlementStore(
            storeKit: storeKit,
            entitlementAPI: EntitlementAPIFake(result: .success(Self.grant))
        )
        await store.load()

        XCTAssertEqual(store.products, [Self.oldProduct])
        XCTAssertNil(store.productsUnavailableReason)
    }

    func testStorefrontChangeToSalesRegionClearsRegionReason() async {
        let storeKit = StoreKitFake()
        await storeKit.setStorefrontCountryCode("JPN")
        let store = ManagedConnectionEntitlementStore(
            storeKit: storeKit,
            entitlementAPI: EntitlementAPIFake(result: .success(Self.grant))
        )
        await store.load()
        XCTAssertEqual(store.productsUnavailableReason, .notSoldInStorefront)

        let observer = Task { await store.observeStorefrontUpdates() }
        await storeKit.setProducts([Self.updatedProduct])
        await storeKit.setStorefrontCountryCode("CHN")
        await storeKit.sendStorefrontUpdate()
        await waitUntil { store.products == [Self.updatedProduct] }
        observer.cancel()
        await observer.value

        XCTAssertEqual(store.storefrontCountryCode, "CHN")
        XCTAssertNil(store.productsUnavailableReason)
    }

    func testSalesRegionMatchesMainlandStorefrontOnly() {
        XCTAssertEqual(ManagedConnectionSalesRegion.isSold(inStorefront: "CHN"), true)
        XCTAssertEqual(ManagedConnectionSalesRegion.isSold(inStorefront: "chn"), true)
        XCTAssertEqual(ManagedConnectionSalesRegion.isSold(inStorefront: "HKG"), false)
        XCTAssertNil(ManagedConnectionSalesRegion.isSold(inStorefront: nil))
        XCTAssertNil(ManagedConnectionSalesRegion.isSold(inStorefront: ""))
    }

    func testProductRefreshFailureDoesNotClearEntitlementOrCatalog() async {
        let storeKit = StoreKitFake()
        await storeKit.setProducts([Self.oldProduct])
        await storeKit.setCurrent(.verified(Self.evidence), productID: ManagedConnectionProductID.monthly)
        let store = ManagedConnectionEntitlementStore(
            storeKit: storeKit,
            entitlementAPI: EntitlementAPIFake(result: .success(Self.grant))
        )
        await store.load()
        await storeKit.setProductsError(TestError.serverUnavailable)
        await store.refreshProducts()

        XCTAssertEqual(store.products, [Self.oldProduct])
        XCTAssertEqual(store.currentGrant, Self.grant)
        XCTAssertEqual(store.status, .entitled(Self.grant.entitlement))
    }

    private static let oldProduct = ManagedConnectionProduct(
        id: ManagedConnectionProductID.monthly, displayName: "Monthly",
        displayPrice: "US$1.99", displayPeriod: "Month",
        isEligibleForTrial: true, displayTrialPeriod: "1 week"
    )
    private static let updatedProduct = ManagedConnectionProduct(
        id: ManagedConnectionProductID.monthly, displayName: "月度订阅",
        displayPrice: "¥9.90", displayPeriod: "月",
        isEligibleForTrial: false, displayTrialPeriod: nil
    )

    private func waitUntil(_ condition: @MainActor () async -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("异步操作没有在时限内到达预期阶段")
    }

    func testVerifiedPurchaseRequiresServerGrantBeforeFinishing() async {
        let storeKit = StoreKitFake()
        let api = EntitlementAPIFake(result: .success(Self.grant))
        await storeKit.setPurchase(.success(Self.evidence))
        let store = ManagedConnectionEntitlementStore(storeKit: storeKit, entitlementAPI: api)

        await store.purchase(productID: ManagedConnectionProductID.monthly)

        let finishedTransactionIDs = await storeKit.finishedTransactionIDs
        let resolveCount = await api.resolveCount
        XCTAssertEqual(store.status, .entitled(Self.grant.entitlement))
        XCTAssertEqual(store.currentGrant, Self.grant)
        XCTAssertEqual(finishedTransactionIDs, [42])
        XCTAssertEqual(resolveCount, 1)
    }

    func testServerFailureDoesNotFinishVerifiedPurchaseOrGrantAccess() async {
        let storeKit = StoreKitFake()
        let api = EntitlementAPIFake(result: .failure(TestError.serverUnavailable))
        await storeKit.setPurchase(.success(Self.evidence))
        let store = ManagedConnectionEntitlementStore(storeKit: storeKit, entitlementAPI: api)

        await store.purchase(productID: ManagedConnectionProductID.monthly)

        let finishedTransactionIDs = await storeKit.finishedTransactionIDs
        XCTAssertEqual(store.status, .failed("server unavailable"))
        XCTAssertNil(store.currentGrant)
        XCTAssertEqual(finishedTransactionIDs, [])
    }

    func testCancelledPurchaseReturnsToAvailableWithoutResolving() async {
        let storeKit = StoreKitFake()
        let api = EntitlementAPIFake(result: .success(Self.grant))
        await storeKit.setPurchase(.cancelled)
        let store = ManagedConnectionEntitlementStore(storeKit: storeKit, entitlementAPI: api)

        await store.purchase(productID: ManagedConnectionProductID.monthly)

        let resolveCount = await api.resolveCount
        XCTAssertEqual(store.status, .available)
        XCTAssertEqual(resolveCount, 0)
    }

    func testPendingPurchaseDoesNotGrantAccess() async {
        let storeKit = StoreKitFake()
        await storeKit.setPurchase(.pending)
        let store = ManagedConnectionEntitlementStore(
            storeKit: storeKit,
            entitlementAPI: EntitlementAPIFake(result: .success(Self.grant))
        )

        await store.purchase(productID: ManagedConnectionProductID.monthly)

        XCTAssertEqual(store.status, .pending)
        XCTAssertNil(store.currentGrant)
    }

    func testUnverifiedPurchaseDoesNotCallServer() async {
        let storeKit = StoreKitFake()
        let api = EntitlementAPIFake(result: .success(Self.grant))
        await storeKit.setPurchase(.unverified)
        let store = ManagedConnectionEntitlementStore(storeKit: storeKit, entitlementAPI: api)

        await store.purchase(productID: ManagedConnectionProductID.monthly)

        guard case .failed = store.status else {
            return XCTFail("unverified purchase must fail")
        }
        let resolveCount = await api.resolveCount
        XCTAssertEqual(resolveCount, 0)
    }

    func testRestoreIsTheOnlyFlowThatCallsSync() async {
        let storeKit = StoreKitFake()
        await storeKit.setCurrent(.verified(Self.evidence), productID: ManagedConnectionProductID.monthly)
        let store = ManagedConnectionEntitlementStore(
            storeKit: storeKit,
            entitlementAPI: EntitlementAPIFake(result: .success(Self.grant))
        )

        await store.refreshEntitlement()
        let syncCountBeforeRestore = await storeKit.syncCount
        XCTAssertEqual(syncCountBeforeRestore, 0)

        let restoreResult = await store.restorePurchases()
        let syncCountAfterRestore = await storeKit.syncCount
        XCTAssertEqual(syncCountAfterRestore, 1)
        XCTAssertEqual(store.status, .entitled(Self.grant.entitlement))
        XCTAssertEqual(restoreResult, .restored)
    }

    func testCurrentEntitlementFinishesOnlyAfterServerGrant() async {
        let storeKit = StoreKitFake()
        await storeKit.setCurrent(.verified(Self.evidence), productID: ManagedConnectionProductID.monthly)
        let store = ManagedConnectionEntitlementStore(
            storeKit: storeKit,
            entitlementAPI: EntitlementAPIFake(result: .success(Self.grant))
        )

        await store.refreshEntitlement()

        let finishedTransactionIDs = await storeKit.finishedTransactionIDs
        XCTAssertEqual(store.status, .entitled(Self.grant.entitlement))
        XCTAssertEqual(finishedTransactionIDs, [Self.evidence.transactionID])
    }

    func testCurrentEntitlementServerFailureDoesNotFinish() async {
        let storeKit = StoreKitFake()
        await storeKit.setCurrent(.verified(Self.evidence), productID: ManagedConnectionProductID.monthly)
        let store = ManagedConnectionEntitlementStore(
            storeKit: storeKit,
            entitlementAPI: EntitlementAPIFake(result: .failure(TestError.serverUnavailable))
        )

        await store.refreshEntitlement()

        let finishedTransactionIDs = await storeKit.finishedTransactionIDs
        XCTAssertNil(store.currentGrant)
        XCTAssertEqual(finishedTransactionIDs, [])
    }

    func testTransactionUpdateRefreshesAndFinishesOnlyAfterServerGrant() async {
        let storeKit = StoreKitFake()
        let api = EntitlementAPIFake(result: .success(Self.grant))
        let store = ManagedConnectionEntitlementStore(storeKit: storeKit, entitlementAPI: api)
        let observer = Task { await store.observeTransactionUpdates() }
        await storeKit.setCurrent(
            .verified(Self.evidence),
            productID: ManagedConnectionProductID.monthly
        )

        await storeKit.sendTransactionUpdate(.verified(Self.evidence))
        for _ in 0..<100 {
            if await api.resolveCount > 0 { break }
            await Task.yield()
        }

        observer.cancel()
        await observer.value
        let finishedTransactionIDs = await storeKit.finishedTransactionIDs
        let resolveCount = await api.resolveCount
        XCTAssertEqual(store.status, .entitled(Self.grant.entitlement))
        XCTAssertEqual(finishedTransactionIDs, [Self.evidence.transactionID])
        XCTAssertEqual(resolveCount, 1)
    }

    func testVerifiedRevocationUpdateSendsItsJWSAndFinishesAfterServerDecision() async {
        let storeKit = StoreKitFake()
        let api = EntitlementAPIFake(
            result: .failure(ManagedConnectionEntitlementAPIError.rejected(code: "revoked"))
        )
        let store = ManagedConnectionEntitlementStore(storeKit: storeKit, entitlementAPI: api)
        let observer = Task { await store.observeTransactionUpdates() }

        await storeKit.sendTransactionUpdate(.verified(Self.evidence))
        for _ in 0..<100 {
            if await api.resolveCount > 0 { break }
            await Task.yield()
        }

        observer.cancel()
        await observer.value
        let finishedTransactionIDs = await storeKit.finishedTransactionIDs
        XCTAssertEqual(store.status, .revoked)
        XCTAssertNil(store.currentGrant)
        XCTAssertEqual(finishedTransactionIDs, [Self.evidence.transactionID])
    }

    func testGrantRefreshesBeforeTokenExpiresWhileAppRemainsActive() async {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let firstGrant = Self.grant(now: base)
        let renewedGrant = ManagedConnectionEntitlementGrant(
            entitlement: firstGrant.entitlement,
            token: "renewed-token",
            tokenExpiresAt: base.addingTimeInterval(1_800)
        )
        let storeKit = StoreKitFake()
        let api = EntitlementAPIFake(result: .success(firstGrant))
        let sleeper = SleepUntilFake()
        await storeKit.setCurrent(.verified(Self.evidence), productID: ManagedConnectionProductID.monthly)
        let store = ManagedConnectionEntitlementStore(
            storeKit: storeKit,
            entitlementAPI: api,
            now: { base },
            sleepUntil: { date in try await sleeper.sleep(until: date) }
        )
        await store.refreshEntitlement()
        await api.setResult(.success(renewedGrant))

        let maintenance = Task { await store.maintainCurrentGrant() }
        for _ in 0..<100 {
            if await sleeper.hasWaiter { break }
            await Task.yield()
        }
        let scheduledDate = await sleeper.scheduledDate
        await sleeper.resume()
        await maintenance.value

        let resolveCount = await api.resolveCount
        XCTAssertEqual(scheduledDate, firstGrant.tokenExpiresAt.addingTimeInterval(-60))
        XCTAssertEqual(store.currentGrant, renewedGrant)
        XCTAssertEqual(resolveCount, 2)
    }

    func testOlderSuccessCannotReviveGrantAfterNewerRevocation() async {
        let storeKit = StoreKitFake()
        await storeKit.setCurrent(.verified(Self.evidence), productID: ManagedConnectionProductID.monthly)
        let api = DelayedEntitlementAPIFake()
        let store = ManagedConnectionEntitlementStore(storeKit: storeKit, entitlementAPI: api)

        let olderRefresh = Task { await store.refreshEntitlement() }
        while !(await api.hasStartedFirstRequest) {
            await Task.yield()
        }
        await store.refreshEntitlement()
        await api.completeFirstRequest(with: Self.grant)
        await olderRefresh.value

        let finishedTransactionIDs = await storeKit.finishedTransactionIDs
        XCTAssertEqual(store.status, .revoked)
        XCTAssertNil(store.currentGrant)
        XCTAssertEqual(finishedTransactionIDs, [])
    }

    func testCancellingOrPendingPlanChangeKeepsExistingGrant() async {
        let storeKit = StoreKitFake()
        let api = EntitlementAPIFake(result: .success(Self.grant))
        await storeKit.setCurrent(.verified(Self.evidence), productID: ManagedConnectionProductID.monthly)
        let store = ManagedConnectionEntitlementStore(storeKit: storeKit, entitlementAPI: api)
        await store.refreshEntitlement()

        await storeKit.setPurchase(.cancelled)
        await store.purchase(productID: ManagedConnectionProductID.annual)
        XCTAssertEqual(store.status, .entitled(Self.grant.entitlement))
        XCTAssertEqual(store.currentGrant, Self.grant)

        await storeKit.setPurchase(.pending)
        await store.purchase(productID: ManagedConnectionProductID.annual)
        XCTAssertEqual(store.status, .entitled(Self.grant.entitlement))
        XCTAssertEqual(store.currentGrant, Self.grant)
    }

    func testRestoreSyncFailureKeepsExistingGrant() async {
        let storeKit = StoreKitFake()
        let api = EntitlementAPIFake(result: .success(Self.grant))
        await storeKit.setCurrent(.verified(Self.evidence), productID: ManagedConnectionProductID.monthly)
        let store = ManagedConnectionEntitlementStore(storeKit: storeKit, entitlementAPI: api)
        await store.refreshEntitlement()
        await storeKit.setSyncError(TestError.serverUnavailable)

        await store.restorePurchases()

        XCTAssertEqual(store.status, .entitled(Self.grant.entitlement))
        XCTAssertEqual(store.currentGrant, Self.grant)
    }

    func testExplicitPurchaseRejectionClearsExistingGrant() async {
        for code in ["expired", "revoked", "unverified_transaction"] {
            let storeKit = StoreKitFake()
            let api = EntitlementAPIFake(result: .success(Self.grant))
            await storeKit.setCurrent(.verified(Self.evidence), productID: ManagedConnectionProductID.monthly)
            await storeKit.setPurchase(.success(Self.evidence))
            let store = ManagedConnectionEntitlementStore(storeKit: storeKit, entitlementAPI: api)
            await store.refreshEntitlement()
            await api.setResult(.failure(ManagedConnectionEntitlementAPIError.rejected(code: code)))

            await store.purchase(productID: ManagedConnectionProductID.annual)

            XCTAssertNil(store.currentGrant, "server rejection must clear grant: \(code)")
            if code == "expired" {
                XCTAssertEqual(store.status, .expired)
            } else if code == "revoked" {
                XCTAssertEqual(store.status, .revoked)
            } else {
                guard case .failed = store.status else {
                    return XCTFail("unverified transaction must fail")
                }
            }
        }
    }

    func testNoCurrentEntitlementClearsExistingGrantDuringRefreshAndPurchase() async {
        for operation in ["refresh", "purchase"] {
            let storeKit = StoreKitFake()
            let api = EntitlementAPIFake(result: .success(Self.grant))
            await storeKit.setCurrent(.verified(Self.evidence), productID: ManagedConnectionProductID.monthly)
            await storeKit.setPurchase(.success(Self.evidence))
            let store = ManagedConnectionEntitlementStore(storeKit: storeKit, entitlementAPI: api)
            await store.refreshEntitlement()
            await api.setResult(
                .failure(ManagedConnectionEntitlementAPIError.rejected(code: "no_current_entitlement"))
            )

            if operation == "refresh" {
                await store.refreshEntitlement()
            } else {
                await store.purchase(productID: ManagedConnectionProductID.annual)
            }

            XCTAssertNil(store.currentGrant, operation)
            XCTAssertEqual(store.status, .available, operation)
        }
    }

    func testProductLoadFailureKeepsExistingGrant() async {
        let storeKit = StoreKitFake()
        let api = EntitlementAPIFake(result: .success(Self.grant))
        await storeKit.setCurrent(.verified(Self.evidence), productID: ManagedConnectionProductID.monthly)
        let store = ManagedConnectionEntitlementStore(storeKit: storeKit, entitlementAPI: api)
        await store.refreshEntitlement()
        await storeKit.setProductsError(TestError.serverUnavailable)

        await store.load()

        XCTAssertEqual(store.status, .entitled(Self.grant.entitlement))
        XCTAssertEqual(store.currentGrant, Self.grant)
    }

    func testCancellationNeverLeavesStoreBusy() async {
        let loadStoreKit = StoreKitFake()
        await loadStoreKit.setProductsError(CancellationError())
        let loadStore = ManagedConnectionEntitlementStore(
            storeKit: loadStoreKit,
            entitlementAPI: EntitlementAPIFake(result: .success(Self.grant))
        )
        await loadStore.load()
        XCTAssertEqual(loadStore.status, .available)

        let refreshStoreKit = StoreKitFake()
        await refreshStoreKit.setCurrent(.verified(Self.evidence), productID: ManagedConnectionProductID.monthly)
        let refreshStore = ManagedConnectionEntitlementStore(
            storeKit: refreshStoreKit,
            entitlementAPI: EntitlementAPIFake(result: .failure(CancellationError()))
        )
        await refreshStore.refreshEntitlement()
        XCTAssertEqual(refreshStore.status, .available)

        let purchaseStoreKit = StoreKitFake()
        await purchaseStoreKit.setPurchaseError(CancellationError())
        let purchaseStore = ManagedConnectionEntitlementStore(
            storeKit: purchaseStoreKit,
            entitlementAPI: EntitlementAPIFake(result: .success(Self.grant))
        )
        await purchaseStore.purchase(productID: ManagedConnectionProductID.monthly)
        XCTAssertEqual(purchaseStore.status, .available)

        let restoreStoreKit = StoreKitFake()
        await restoreStoreKit.setSyncError(CancellationError())
        let restoreStore = ManagedConnectionEntitlementStore(
            storeKit: restoreStoreKit,
            entitlementAPI: EntitlementAPIFake(result: .success(Self.grant))
        )
        await restoreStore.restorePurchases()
        XCTAssertEqual(restoreStore.status, .available)
    }

    func testTransientRefreshFailureKeepsGrantWhileTokenIsValid() async {
        let storeKit = StoreKitFake()
        let api = EntitlementAPIFake(result: .success(Self.grant))
        await storeKit.setCurrent(.verified(Self.evidence), productID: ManagedConnectionProductID.monthly)
        let store = ManagedConnectionEntitlementStore(storeKit: storeKit, entitlementAPI: api)
        await store.refreshEntitlement()
        await api.setResult(.failure(TestError.serverUnavailable))

        await store.refreshEntitlement()

        XCTAssertEqual(store.status, .entitled(Self.grant.entitlement))
        XCTAssertEqual(store.currentGrant, Self.grant)
    }

    func testTransientRefreshFailureClearsExpiredToken() async {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var now = base
        let grant = Self.grant(now: base)
        let storeKit = StoreKitFake()
        let api = EntitlementAPIFake(result: .success(grant))
        await storeKit.setCurrent(.verified(Self.evidence), productID: ManagedConnectionProductID.monthly)
        let store = ManagedConnectionEntitlementStore(
            storeKit: storeKit,
            entitlementAPI: api,
            now: { now }
        )
        await store.refreshEntitlement()
        now = base.addingTimeInterval(901)
        await api.setResult(.failure(TestError.serverUnavailable))

        await store.refreshEntitlement()

        XCTAssertNil(store.currentGrant)
        XCTAssertEqual(store.status, .failed("server unavailable"))
    }

    func testExpiredServerDecisionProducesExpiredState() async {
        let storeKit = StoreKitFake()
        await storeKit.setCurrent(.verified(Self.evidence), productID: ManagedConnectionProductID.monthly)
        let store = ManagedConnectionEntitlementStore(
            storeKit: storeKit,
            entitlementAPI: EntitlementAPIFake(
                result: .failure(ManagedConnectionEntitlementAPIError.rejected(code: "expired"))
            )
        )

        await store.refreshEntitlement()

        XCTAssertEqual(store.status, .expired)
        XCTAssertNil(store.currentGrant)
    }

    func testRevokedServerDecisionProducesRevokedState() async {
        let storeKit = StoreKitFake()
        await storeKit.setPurchase(.success(Self.evidence))
        let store = ManagedConnectionEntitlementStore(
            storeKit: storeKit,
            entitlementAPI: EntitlementAPIFake(
                result: .failure(ManagedConnectionEntitlementAPIError.rejected(code: "revoked"))
            )
        )

        await store.purchase(productID: ManagedConnectionProductID.monthly)

        let finishedTransactionIDs = await storeKit.finishedTransactionIDs
        XCTAssertEqual(store.status, .revoked)
        XCTAssertNil(store.currentGrant)
        XCTAssertEqual(finishedTransactionIDs, [Self.evidence.transactionID])
    }

    func testOnlyFreeTrialOfferIsPresentedAsTrial() {
        XCTAssertTrue(
            ManagedConnectionTrialEligibility.isFreeTrial(
                eligible: true,
                paymentMode: .freeTrial
            )
        )
        XCTAssertFalse(
            ManagedConnectionTrialEligibility.isFreeTrial(
                eligible: true,
                paymentMode: .payAsYouGo
            )
        )
        XCTAssertFalse(
            ManagedConnectionTrialEligibility.isFreeTrial(
                eligible: true,
                paymentMode: .payUpFront
            )
        )
        XCTAssertFalse(
            ManagedConnectionTrialEligibility.isFreeTrial(
                eligible: false,
                paymentMode: .freeTrial
            )
        )
    }

    private static let evidence = ManagedConnectionTransactionEvidence(
        transactionID: 42,
        productID: ManagedConnectionProductID.monthly,
        signedTransaction: "signed-transaction"
    )

    private static let grant = ManagedConnectionEntitlementGrant(
        entitlement: ManagedConnectionEntitlement(
            id: "entitlement-id",
            productID: ManagedConnectionProductID.monthly,
            status: .active,
            expiresAt: Date(timeIntervalSinceNow: 3_600)
        ),
        token: "in-memory-token",
        tokenExpiresAt: Date(timeIntervalSinceNow: 900)
    )

    private static func grant(now: Date) -> ManagedConnectionEntitlementGrant {
        ManagedConnectionEntitlementGrant(
            entitlement: ManagedConnectionEntitlement(
                id: "entitlement-id",
                productID: ManagedConnectionProductID.monthly,
                status: .active,
                expiresAt: now.addingTimeInterval(3_600)
            ),
            token: "in-memory-token",
            tokenExpiresAt: now.addingTimeInterval(900)
        )
    }
}

final class ManagedConnectionEntitlementAPIClientTests: XCTestCase {
    override func tearDown() {
        ManagedConnectionEntitlementURLProtocol.reset()
        super.tearDown()
    }

    func testResolvePostsBothAppleJWSValuesAndParsesGrant() async throws {
        ManagedConnectionEntitlementURLProtocol.respond(
            statusCode: 200,
            body: #"""
            {
                "entitlement": {
                    "id": "entitlement-id",
                    "productId": "com.gaixianggeng.mimi.managed.monthly",
                    "status": "trial",
                    "expiresAt": "2026-09-11T00:00:00.000Z"
                },
                "entitlementToken": "short-lived-token",
                "tokenExpiresAt": "2026-09-04T00:15:00Z"
            }
            """#
        )
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = LiveManagedConnectionEntitlementAPIClient(session: session)

        let grant = try await client.resolve(
            signedAppTransaction: "signed-app-transaction",
            signedTransaction: "signed-transaction"
        )

        let request = try XCTUnwrap(ManagedConnectionEntitlementURLProtocol.capturedRequest())
        XCTAssertEqual(request.url?.absoluteString, "https://mimi.code89757.com/v1/entitlements/resolve")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(ManagedConnectionEntitlementURLProtocol.capturedBody())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json["signedAppTransaction"], "signed-app-transaction")
        XCTAssertEqual(json["signedTransaction"], "signed-transaction")
        XCTAssertEqual(grant.entitlement.id, "entitlement-id")
        XCTAssertEqual(grant.entitlement.status, .trial)
        XCTAssertEqual(grant.entitlement.productID, ManagedConnectionProductID.monthly)
        XCTAssertEqual(grant.token, "short-lived-token")
    }

    func testResolvePreservesServerRejectionCode() async throws {
        ManagedConnectionEntitlementURLProtocol.respond(
            statusCode: 403,
            body: #"{"code":"no_current_entitlement"}"#
        )
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = LiveManagedConnectionEntitlementAPIClient(session: session)

        do {
            _ = try await client.resolve(
                signedAppTransaction: "signed-app-transaction",
                signedTransaction: "signed-transaction"
            )
            XCTFail("server rejection must not grant access")
        } catch {
            XCTAssertEqual(
                error as? ManagedConnectionEntitlementAPIError,
                .rejected(code: "no_current_entitlement")
            )
        }
    }

    func testResolveRejectsMalformedSuccessPayload() async throws {
        ManagedConnectionEntitlementURLProtocol.respond(
            statusCode: 200,
            body: #"{"entitlement":{"id":"missing-fields"}}"#
        )
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = LiveManagedConnectionEntitlementAPIClient(session: session)

        do {
            _ = try await client.resolve(
                signedAppTransaction: "signed-app-transaction",
                signedTransaction: "signed-transaction"
            )
            XCTFail("malformed response must not grant access")
        } catch {
            XCTAssertEqual(error as? ManagedConnectionEntitlementAPIError, .invalidResponse)
        }
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ManagedConnectionEntitlementURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private actor StoreKitFake: ManagedConnectionStoreKitClient {
    nonisolated private let updates: AsyncStream<ManagedConnectionTransactionUpdate>
    nonisolated private let updatesContinuation: AsyncStream<ManagedConnectionTransactionUpdate>.Continuation
    nonisolated private let storefrontEvents: AsyncStream<Void>
    nonisolated private let storefrontContinuation: AsyncStream<Void>.Continuation
    private var purchaseOutcome: ManagedConnectionPurchaseOutcome = .cancelled
    private var currentByProductID: [String: ManagedConnectionCurrentEntitlementOutcome] = [:]
    private(set) var finishedTransactionIDs: [UInt64] = []
    private(set) var syncCount = 0
    private var syncError: Error?
    private var productsError: Error?
    private var purchaseError: Error?
    private(set) var productsCount = 0
    private var productValues: [ManagedConnectionProduct] = []
    private var countryCode: String?
    private var shouldPausePurchase = false
    private var purchaseContinuation: CheckedContinuation<Void, Never>?
    private var shouldPauseSync = false
    private var syncContinuation: CheckedContinuation<Void, Never>?
    private var shouldPauseProductLoad = false
    private var productContinuation: CheckedContinuation<Void, Never>?

    var isPurchasePaused: Bool { purchaseContinuation != nil }
    var isSyncPaused: Bool { syncContinuation != nil }
    var isProductLoadPaused: Bool { productContinuation != nil }

    init() {
        let (stream, continuation) = AsyncStream<ManagedConnectionTransactionUpdate>.makeStream()
        updates = stream
        updatesContinuation = continuation
        (storefrontEvents, storefrontContinuation) = AsyncStream<Void>.makeStream()
    }

    func setProducts(_ products: [ManagedConnectionProduct]) { productValues = products }
    func setStorefrontCountryCode(_ code: String?) { countryCode = code }
    func storefrontCountryCode() async -> String? { countryCode }
    func pausePurchase() { shouldPausePurchase = true }
    func resumePurchase() { purchaseContinuation?.resume(); purchaseContinuation = nil }
    func pauseSync() { shouldPauseSync = true }
    func resumeSync() { syncContinuation?.resume(); syncContinuation = nil }
    func pauseNextProductLoad() { shouldPauseProductLoad = true }
    func resumeProductLoad() { productContinuation?.resume(); productContinuation = nil }

    func setPurchase(_ outcome: ManagedConnectionPurchaseOutcome) {
        purchaseOutcome = outcome
    }

    func setCurrent(_ outcome: ManagedConnectionCurrentEntitlementOutcome, productID: String) {
        currentByProductID[productID] = outcome
    }

    func setSyncError(_ error: Error?) {
        syncError = error
    }

    func setProductsError(_ error: Error?) {
        productsError = error
    }

    func setPurchaseError(_ error: Error?) {
        purchaseError = error
    }

    func products() async throws -> [ManagedConnectionProduct] {
        productsCount += 1
        let result = productValues
        if shouldPauseProductLoad {
            shouldPauseProductLoad = false
            await withCheckedContinuation { productContinuation = $0 }
        }
        if let productsError { throw productsError }
        return result
    }

    func purchase(productID: String) async throws -> ManagedConnectionPurchaseOutcome {
        if shouldPausePurchase {
            shouldPausePurchase = false
            await withCheckedContinuation { purchaseContinuation = $0 }
        }
        if let purchaseError { throw purchaseError }
        return purchaseOutcome
    }

    func currentEntitlement(productID: String) async -> ManagedConnectionCurrentEntitlementOutcome {
        currentByProductID[productID] ?? .none
    }

    nonisolated func transactionUpdates() -> AsyncStream<ManagedConnectionTransactionUpdate> {
        updates
    }

    nonisolated func storefrontUpdates() -> AsyncStream<Void> { storefrontEvents }
    func sendStorefrontUpdate() { storefrontContinuation.yield(()) }

    func sendTransactionUpdate(_ update: ManagedConnectionTransactionUpdate) {
        updatesContinuation.yield(update)
    }

    func signedAppTransaction() async throws -> String { "signed-app-transaction" }

    func finish(transactionID: UInt64) async {
        finishedTransactionIDs.append(transactionID)
    }

    func syncPurchases() async throws {
        syncCount += 1
        if shouldPauseSync {
            shouldPauseSync = false
            await withCheckedContinuation { syncContinuation = $0 }
        }
        if let syncError { throw syncError }
    }
}

private actor SleepUntilFake {
    private(set) var scheduledDate: Date?
    private var continuation: CheckedContinuation<Void, Error>?

    var hasWaiter: Bool { continuation != nil }

    func sleep(until date: Date) async throws {
        scheduledDate = date
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }

    private func cancel() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}

private actor EntitlementAPIFake: ManagedConnectionEntitlementAPIClient {
    private var result: Result<ManagedConnectionEntitlementGrant, Error>
    private(set) var resolveCount = 0
    private var shouldPauseResolve = false
    private var resolveContinuation: CheckedContinuation<Void, Never>?
    var isResolvePaused: Bool { resolveContinuation != nil }
    func pauseNextResolve() { shouldPauseResolve = true }
    func resumeResolve() { resolveContinuation?.resume(); resolveContinuation = nil }

    init(result: Result<ManagedConnectionEntitlementGrant, Error>) {
        self.result = result
    }

    func setResult(_ result: Result<ManagedConnectionEntitlementGrant, Error>) {
        self.result = result
    }

    func resolve(
        signedAppTransaction: String,
        signedTransaction: String
    ) async throws -> ManagedConnectionEntitlementGrant {
        try Task.checkCancellation()
        resolveCount += 1
        if shouldPauseResolve {
            shouldPauseResolve = false
            await withCheckedContinuation { resolveContinuation = $0 }
        }
        return try result.get()
    }

    private var redeemResult: Result<ManagedConnectionEntitlementGrant, Error> =
        .failure(ManagedConnectionEntitlementAPIError.rejected(code: "invalid_redemption_code"))
    private(set) var redeemedCodes: [String] = []

    func setRedeemResult(_ result: Result<ManagedConnectionEntitlementGrant, Error>) {
        redeemResult = result
    }

    func redeem(code: String) async throws -> ManagedConnectionEntitlementGrant {
        redeemedCodes.append(code)
        return try redeemResult.get()
    }
}

private actor DelayedEntitlementAPIFake: ManagedConnectionEntitlementAPIClient {
    private var requestCount = 0
    private var firstContinuation: CheckedContinuation<ManagedConnectionEntitlementGrant, Error>?

    var hasStartedFirstRequest: Bool { firstContinuation != nil }

    func resolve(
        signedAppTransaction: String,
        signedTransaction: String
    ) async throws -> ManagedConnectionEntitlementGrant {
        requestCount += 1
        if requestCount == 1 {
            return try await withCheckedThrowingContinuation { continuation in
                firstContinuation = continuation
            }
        }
        throw ManagedConnectionEntitlementAPIError.rejected(code: "revoked")
    }

    func redeem(code: String) async throws -> ManagedConnectionEntitlementGrant {
        throw ManagedConnectionEntitlementAPIError.rejected(code: "invalid_redemption_code")
    }

    func completeFirstRequest(with grant: ManagedConnectionEntitlementGrant) {
        firstContinuation?.resume(returning: grant)
        firstContinuation = nil
    }
}

private enum TestError: LocalizedError {
    case serverUnavailable

    var errorDescription: String? { "server unavailable" }
}

private final class ManagedConnectionEntitlementURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var statusCode = 500
    private static var responseBody = Data()
    private static var lastRequest: URLRequest?
    private static var lastBody: Data?

    static func respond(statusCode: Int, body: String) {
        lock.lock()
        self.statusCode = statusCode
        responseBody = Data(body.utf8)
        lastRequest = nil
        lastBody = nil
        lock.unlock()
    }

    static func capturedRequest() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return lastRequest
    }

    static func capturedBody() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return lastBody
    }

    static func reset() {
        lock.lock()
        statusCode = 500
        responseBody = Data()
        lastRequest = nil
        lastBody = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        var requestBody = request.httpBody
        if requestBody == nil, let stream = request.httpBodyStream {
            requestBody = Self.readAll(from: stream)
        }

        Self.lock.lock()
        Self.lastRequest = request
        Self.lastBody = requestBody
        let statusCode = Self.statusCode
        let responseBody = Self.responseBody
        Self.lock.unlock()

        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readAll(from stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4 * 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class RedemptionRequestRecorder: @unchecked Sendable {
    var path: String?
    var body: String?
}

private final class RedemptionURLProtocol: URLProtocol {
    nonisolated(unsafe) private static var respond: ((URLRequest) -> (Int, String))?

    static func makeClient(
        status: Int,
        body: String
    ) -> (LiveManagedConnectionEntitlementAPIClient, RedemptionRequestRecorder) {
        let recorder = RedemptionRequestRecorder()
        respond = { request in
            recorder.path = request.url?.path
            recorder.body = Self.bodyString(of: request)
            return (status, body)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedemptionURLProtocol.self]
        let client = LiveManagedConnectionEntitlementAPIClient(
            baseURL: URL(string: "https://example.invalid")!,
            session: URLSession(configuration: configuration)
        )
        return (client, recorder)
    }

    private static func bodyString(of request: URLRequest) -> String? {
        if let data = request.httpBody { return String(data: data, encoding: .utf8) }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return String(data: data, encoding: .utf8)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, body) = Self.respond?(request) ?? (500, "")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
