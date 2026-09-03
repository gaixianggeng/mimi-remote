import StoreKit
import XCTest
@testable import MimiRemote

@MainActor
final class ManagedConnectionEntitlementStoreTests: XCTestCase {
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

        await store.restorePurchases()
        let syncCountAfterRestore = await storeKit.syncCount
        XCTAssertEqual(syncCountAfterRestore, 1)
        XCTAssertEqual(store.status, .entitled(Self.grant.entitlement))
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

        await storeKit.sendTransactionUpdate()
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
        XCTAssertEqual(finishedTransactionIDs, [])
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
        let client = LiveManagedConnectionEntitlementAPIClient(
            baseURL: URL(string: "https://api.code89757.com")!,
            session: session
        )

        let grant = try await client.resolve(
            signedAppTransaction: "signed-app-transaction",
            signedTransaction: "signed-transaction"
        )

        let request = try XCTUnwrap(ManagedConnectionEntitlementURLProtocol.capturedRequest())
        XCTAssertEqual(request.url?.absoluteString, "https://api.code89757.com/v1/entitlements/resolve")
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
    nonisolated private let updates: AsyncStream<Void>
    nonisolated private let updatesContinuation: AsyncStream<Void>.Continuation
    private var purchaseOutcome: ManagedConnectionPurchaseOutcome = .cancelled
    private var currentByProductID: [String: ManagedConnectionCurrentEntitlementOutcome] = [:]
    private(set) var finishedTransactionIDs: [UInt64] = []
    private(set) var syncCount = 0
    private var syncError: Error?
    private var productsError: Error?
    private var purchaseError: Error?

    init() {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        updates = stream
        updatesContinuation = continuation
    }

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
        if let productsError { throw productsError }
        return []
    }

    func purchase(productID: String) async throws -> ManagedConnectionPurchaseOutcome {
        if let purchaseError { throw purchaseError }
        return purchaseOutcome
    }

    func currentEntitlement(productID: String) async -> ManagedConnectionCurrentEntitlementOutcome {
        currentByProductID[productID] ?? .none
    }

    nonisolated func transactionUpdates() -> AsyncStream<Void> {
        updates
    }

    func sendTransactionUpdate() {
        updatesContinuation.yield(())
    }

    func signedAppTransaction() async throws -> String { "signed-app-transaction" }

    func finish(transactionID: UInt64) async {
        finishedTransactionIDs.append(transactionID)
    }

    func syncPurchases() async throws {
        syncCount += 1
        if let syncError { throw syncError }
    }
}

private actor EntitlementAPIFake: ManagedConnectionEntitlementAPIClient {
    private var result: Result<ManagedConnectionEntitlementGrant, Error>
    private(set) var resolveCount = 0

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
        resolveCount += 1
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
