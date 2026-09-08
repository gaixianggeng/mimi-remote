import StoreKit
import XCTest
@testable import MimiRemote

@MainActor
final class ManagedConnectionEntitlementStoreTests: XCTestCase {
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
