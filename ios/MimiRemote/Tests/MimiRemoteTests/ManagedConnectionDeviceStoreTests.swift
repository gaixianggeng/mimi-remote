import Foundation
import XCTest
@testable import MimiRemote

@MainActor
final class ManagedConnectionDeviceStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testMobileIdentityPersistsAcrossLaunchAndRotatesOnlyAfterThisDeviceIsRevoked() throws {
        let suiteName = "ManagedConnectionDeviceStoreTests.Identity.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tokenStore = TokenStore(keychain: TestKeychainOperations())
        let tokens = TokenSequence([Self.token(byte: 1), Self.token(byte: 2)])
        let installationID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
        let store = ManagedConnectionMobileIdentityStore(
            defaults: defaults,
            tokenStore: tokenStore,
            makeUUID: { installationID },
            makeToken: { try tokens.next() }
        )

        let first = try store.loadOrCreate()
        store.rememberRegisteredDeviceID("mobile-device-id")
        let relaunched = ManagedConnectionMobileIdentityStore(
            defaults: defaults,
            tokenStore: tokenStore,
            makeToken: { try tokens.next() }
        )
        let restored = try relaunched.loadOrCreate()
        try relaunched.rotateCredentialAfterRevocation(deviceID: "another-device")
        let unchanged = try relaunched.loadOrCreate()
        try relaunched.rotateCredentialAfterRevocation(deviceID: "mobile-device-id")
        let rotated = try relaunched.loadOrCreate()

        XCTAssertEqual(first.installationID, installationID.uuidString.lowercased())
        XCTAssertEqual(restored.installationID, first.installationID)
        XCTAssertEqual(restored.deviceToken, first.deviceToken)
        XCTAssertEqual(restored.registeredDeviceID, "mobile-device-id")
        XCTAssertEqual(unchanged.deviceToken, first.deviceToken)
        XCTAssertEqual(rotated.installationID, first.installationID)
        XCTAssertNotEqual(rotated.deviceToken, first.deviceToken)
        XCTAssertNil(rotated.registeredDeviceID)
    }

    func testManagedPairingRegistersMobileAndReusesAuthorizationDuringRetry() async throws {
        let fixture = await makeFixture()

        let first = try await fixture.store.authorizeManagedPairing(
            macInstallationID: "20000000-0000-4000-8000-000000000001",
            macTailcatPublicKey: "nodekey:mac",
            pairingMacTailcatPublicKey: "nodekey:pair",
            mobileTailcatPublicKey: "nodekey:mobile"
        )
        let retry = try await fixture.store.authorizeManagedPairing(
            macInstallationID: "20000000-0000-4000-8000-000000000001",
            macTailcatPublicKey: "nodekey:mac",
            pairingMacTailcatPublicKey: "nodekey:pair",
            mobileTailcatPublicKey: "nodekey:mobile"
        )

        let registrationCount = await fixture.api.registrationCount
        let authorizationCount = await fixture.api.authorizationCount
        let authorizedRequest = await fixture.api.lastAuthorizedRequest
        XCTAssertEqual(first, retry)
        XCTAssertEqual(first.sessionID, "30000000-0000-4000-8000-000000000001")
        XCTAssertEqual(registrationCount, 2, "登记接口本身幂等，每次配对都重新确认设备仍有效")
        XCTAssertEqual(authorizationCount, 1, "响应丢失后的同一逻辑配对应复用授权")
        XCTAssertEqual(authorizedRequest?.mobileKey, "nodekey:mobile")
        XCTAssertEqual(authorizedRequest?.macKey, "nodekey:mac")
        XCTAssertEqual(authorizedRequest?.pairingMacKey, "nodekey:pair")
        XCTAssertEqual(fixture.identity.registeredDeviceID, "mobile-device-id")
    }

    func testMacKeyRotationDoesNotReusePairingAuthorization() async throws {
        let fixture = await makeFixture()

        _ = try await fixture.store.authorizeManagedPairing(
            macInstallationID: "20000000-0000-4000-8000-000000000001",
            macTailcatPublicKey: "nodekey:mac-old",
            pairingMacTailcatPublicKey: "nodekey:pair",
            mobileTailcatPublicKey: "nodekey:mobile"
        )
        _ = try await fixture.store.authorizeManagedPairing(
            macInstallationID: "20000000-0000-4000-8000-000000000001",
            macTailcatPublicKey: "nodekey:mac-new",
            pairingMacTailcatPublicKey: "nodekey:pair",
            mobileTailcatPublicKey: "nodekey:mobile"
        )

        let authorizationCount = await fixture.api.authorizationCount
        let authorizedRequest = await fixture.api.lastAuthorizedRequest
        XCTAssertEqual(authorizationCount, 2)
        XCTAssertEqual(authorizedRequest?.macKey, "nodekey:mac-new")
    }

    func testTemporaryPairKeyRotationDoesNotReusePairingAuthorization() async throws {
        let fixture = await makeFixture()

        _ = try await fixture.store.authorizeManagedPairing(
            macInstallationID: "20000000-0000-4000-8000-000000000001",
            macTailcatPublicKey: "nodekey:mac",
            pairingMacTailcatPublicKey: "nodekey:pair-old",
            mobileTailcatPublicKey: "nodekey:mobile"
        )
        _ = try await fixture.store.authorizeManagedPairing(
            macInstallationID: "20000000-0000-4000-8000-000000000001",
            macTailcatPublicKey: "nodekey:mac",
            pairingMacTailcatPublicKey: "nodekey:pair-new",
            mobileTailcatPublicKey: "nodekey:mobile"
        )

        let authorizationCount = await fixture.api.authorizationCount
        let authorizedRequest = await fixture.api.lastAuthorizedRequest
        XCTAssertEqual(authorizationCount, 2)
        XCTAssertEqual(authorizedRequest?.pairingMacKey, "nodekey:pair-new")
    }

    func testMobileQuotaFailureStopsBeforePairingAuthorization() async {
        let fixture = await makeFixture()
        await fixture.api.setRegistrationFailure(
            .rejected(code: "device_limit_reached", deviceType: .mobile, limit: 5)
        )

        do {
            _ = try await fixture.store.authorizeManagedPairing(
                macInstallationID: "20000000-0000-4000-8000-000000000001",
                macTailcatPublicKey: "nodekey:mac",
                pairingMacTailcatPublicKey: "nodekey:pair",
                mobileTailcatPublicKey: "nodekey:mobile"
            )
            XCTFail("第六台移动设备必须被名额门禁拒绝")
        } catch let error as ManagedConnectionDeviceAPIError {
            XCTAssertEqual(
                error,
                .rejected(code: "device_limit_reached", deviceType: .mobile, limit: 5)
            )
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let authorizationCount = await fixture.api.authorizationCount
        XCTAssertEqual(authorizationCount, 0)
    }

    func testDeviceManagementUsesStoreKitEvidenceAndRevokingCurrentDeviceRotatesToken() async {
        let fixture = await makeFixture()
        let current = ManagedConnectionDevice(
            id: "mobile-device-id",
            deviceType: .mobile,
            createdAt: now.addingTimeInterval(-60)
        )
        fixture.identity.rememberRegisteredDeviceID(current.id)
        await fixture.api.setDevices([
            current,
            ManagedConnectionDevice(
                id: "mac-device-id",
                deviceType: .mac,
                createdAt: now.addingTimeInterval(-120)
            )
        ])

        await fixture.store.refreshDevices()
        await fixture.store.removeDevice(current)

        let evidence = await fixture.api.lastManagementEvidence
        let removed = await fixture.api.removedDeviceIDs
        XCTAssertEqual(evidence?.app, "signed-app-transaction")
        XCTAssertEqual(evidence?.transaction, "signed-transaction")
        XCTAssertEqual(removed, ["mobile-device-id"])
        XCTAssertEqual(fixture.identity.rotatedDeviceIDs, ["mobile-device-id"])
        XCTAssertEqual(fixture.store.macCount, 1)
        XCTAssertEqual(fixture.store.mobileCount, 0)
    }

    func testManagementSessionIsRecreatedWhenVerifiedTransactionChanges() async {
        let fixture = await makeFixture()

        await fixture.store.refreshDevices()
        await fixture.store.refreshDevices()
        await fixture.storeKit.setEvidence(
            ManagedConnectionTransactionEvidence(
                transactionID: 43,
                productID: ManagedConnectionProductID.monthly,
                signedTransaction: "signed-transaction-new-account"
            )
        )
        await fixture.entitlementStore.refreshEntitlement()
        await fixture.store.refreshDevices()

        let sessionCount = await fixture.api.managementSessionCount
        let evidence = await fixture.api.lastManagementEvidence
        XCTAssertEqual(sessionCount, 2, "同一交易复用会话，交易身份变化后必须重新创建")
        XCTAssertEqual(evidence?.transaction, "signed-transaction-new-account")
    }

    func testRevocationReconcilesAfterLocalCredentialRotationInitiallyFails() async {
        let fixture = await makeFixture()
        let current = ManagedConnectionDevice(
            id: "mobile-device-id",
            deviceType: .mobile,
            createdAt: now
        )
        fixture.identity.rememberRegisteredDeviceID(current.id)
        fixture.identity.failNextCredentialRotations()
        await fixture.api.setDevices([current])

        await fixture.store.refreshDevices()
        await fixture.store.removeDevice(current)
        XCTAssertEqual(fixture.identity.registeredDeviceID, current.id)

        await fixture.store.refreshDevices()

        XCTAssertNil(fixture.identity.registeredDeviceID)
        XCTAssertEqual(fixture.identity.rotatedDeviceIDs, [current.id])
        XCTAssertTrue(fixture.store.devices.isEmpty)
        XCTAssertNil(fixture.store.errorMessage)
    }

    func testAlreadyMissingRemoteDeviceStillRotatesLocalCredential() async {
        let fixture = await makeFixture()
        let current = ManagedConnectionDevice(
            id: "mobile-device-id",
            deviceType: .mobile,
            createdAt: now
        )
        fixture.identity.rememberRegisteredDeviceID(current.id)
        await fixture.api.setRemovalFailure(
            .rejected(code: "device_not_found", deviceType: nil, limit: nil)
        )

        await fixture.store.removeDevice(current)

        XCTAssertNil(fixture.identity.registeredDeviceID)
        XCTAssertEqual(fixture.identity.rotatedDeviceIDs, [current.id])
        XCTAssertNil(fixture.store.errorMessage)
    }

    private func makeFixture() async -> (
        store: ManagedConnectionDeviceStore,
        api: MIM260DeviceAPIFake,
        identity: MIM260IdentityFake,
        entitlementStore: ManagedConnectionEntitlementStore,
        storeKit: MIM260StoreKitFake
    ) {
        let storeKit = MIM260StoreKitFake(evidence: Self.evidence)
        let entitlementAPI = MIM260EntitlementAPIFake(grant: grant)
        let entitlementStore = ManagedConnectionEntitlementStore(
            storeKit: storeKit,
            entitlementAPI: entitlementAPI,
            now: { self.now }
        )
        await entitlementStore.refreshEntitlement()
        let api = MIM260DeviceAPIFake(now: now)
        let identity = MIM260IdentityFake(
            identity: ManagedConnectionMobileIdentity(
                installationID: "10000000-0000-4000-8000-000000000001",
                deviceToken: Self.token(byte: 3),
                registeredDeviceID: nil
            )
        )
        let store = ManagedConnectionDeviceStore(
            entitlementStore: entitlementStore,
            api: api,
            identityStore: identity,
            now: { self.now },
            makeUUID: {
                UUID(uuidString: "30000000-0000-4000-8000-000000000002")!
            },
            makeToken: { Self.token(byte: 4) }
        )
        return (store, api, identity, entitlementStore, storeKit)
    }

    private var grant: ManagedConnectionEntitlementGrant {
        ManagedConnectionEntitlementGrant(
            entitlement: ManagedConnectionEntitlement(
                id: "entitlement-id",
                productID: ManagedConnectionProductID.monthly,
                status: .active,
                expiresAt: now.addingTimeInterval(3_600)
            ),
            token: "entitlement-token-that-is-long-enough",
            tokenExpiresAt: now.addingTimeInterval(900)
        )
    }

    private static let evidence = ManagedConnectionTransactionEvidence(
        transactionID: 42,
        productID: ManagedConnectionProductID.monthly,
        signedTransaction: "signed-transaction"
    )

    fileprivate static func token(byte: UInt8) -> String {
        Data(repeating: byte, count: 32).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private final class TokenSequence {
    private var tokens: [String]

    init(_ tokens: [String]) {
        self.tokens = tokens
    }

    func next() throws -> String {
        guard !tokens.isEmpty else { throw URLError(.unknown) }
        return tokens.removeFirst()
    }
}

private actor MIM260StoreKitFake: ManagedConnectionStoreKitClient {
    private var evidence: ManagedConnectionTransactionEvidence

    init(evidence: ManagedConnectionTransactionEvidence) {
        self.evidence = evidence
    }

    func setEvidence(_ evidence: ManagedConnectionTransactionEvidence) {
        self.evidence = evidence
    }

    func products() async throws -> [ManagedConnectionProduct] { [] }
    func purchase(productID: String) async throws -> ManagedConnectionPurchaseOutcome { .cancelled }
    func currentEntitlement(productID: String) async -> ManagedConnectionCurrentEntitlementOutcome {
        productID == evidence.productID ? .verified(evidence) : .none
    }
    nonisolated func transactionUpdates() -> AsyncStream<ManagedConnectionTransactionUpdate> {
        AsyncStream { $0.finish() }
    }
    func signedAppTransaction() async throws -> String { "signed-app-transaction" }
    func finish(transactionID: UInt64) async {}
    func syncPurchases() async throws {}
}

private actor MIM260EntitlementAPIFake: ManagedConnectionEntitlementAPIClient {
    let grant: ManagedConnectionEntitlementGrant

    init(grant: ManagedConnectionEntitlementGrant) {
        self.grant = grant
    }

    func resolve(
        signedAppTransaction: String,
        signedTransaction: String
    ) async throws -> ManagedConnectionEntitlementGrant {
        grant
    }
}

@MainActor
private final class MIM260IdentityFake: ManagedConnectionMobileIdentityStoring {
    private var identity: ManagedConnectionMobileIdentity
    private(set) var rotatedDeviceIDs: [String] = []
    private var remainingRotationFailures = 0

    var registeredDeviceID: String? { identity.registeredDeviceID }

    init(identity: ManagedConnectionMobileIdentity) {
        self.identity = identity
    }

    func loadOrCreate() throws -> ManagedConnectionMobileIdentity { identity }

    func rememberRegisteredDeviceID(_ id: String) {
        identity = ManagedConnectionMobileIdentity(
            installationID: identity.installationID,
            deviceToken: identity.deviceToken,
            registeredDeviceID: id
        )
    }

    func failNextCredentialRotations(_ count: Int = 1) {
        remainingRotationFailures = count
    }

    func rotateCredentialAfterRevocation(deviceID: String) throws {
        guard identity.registeredDeviceID == deviceID else { return }
        if remainingRotationFailures > 0 {
            remainingRotationFailures -= 1
            throw URLError(.cannotWriteToFile)
        }
        rotatedDeviceIDs.append(deviceID)
        identity = ManagedConnectionMobileIdentity(
            installationID: identity.installationID,
            deviceToken: ManagedConnectionDeviceStoreTests.token(byte: 9),
            registeredDeviceID: nil
        )
    }
}

private actor MIM260DeviceAPIFake: ManagedConnectionDeviceAPIClient {
    struct AuthorizedRequest: Equatable, Sendable {
        let requestID: String
        let mobileKey: String
        let macKey: String
        let pairingMacKey: String
        let grant: String
    }

    let now: Date
    private(set) var registrationCount = 0
    private(set) var authorizationCount = 0
    private(set) var lastAuthorizedRequest: AuthorizedRequest?
    private(set) var lastManagementEvidence: (app: String, transaction: String)?
    private(set) var removedDeviceIDs: [String] = []
    private(set) var managementSessionCount = 0
    private var registrationFailure: ManagedConnectionDeviceAPIError?
    private var removalFailure: ManagedConnectionDeviceAPIError?
    private var devices: [ManagedConnectionDevice] = []

    init(now: Date) {
        self.now = now
    }

    func setRegistrationFailure(_ error: ManagedConnectionDeviceAPIError) {
        registrationFailure = error
    }

    func setDevices(_ devices: [ManagedConnectionDevice]) {
        self.devices = devices
    }

    func setRemovalFailure(_ error: ManagedConnectionDeviceAPIError?) {
        removalFailure = error
    }

    func registerMobileDevice(
        entitlementToken: String,
        installationID: String,
        deviceToken: String
    ) async throws -> ManagedConnectionDeviceRegistration {
        registrationCount += 1
        if let registrationFailure { throw registrationFailure }
        return ManagedConnectionDeviceRegistration(
            device: ManagedConnectionDevice(
                id: "mobile-device-id",
                deviceType: .mobile,
                createdAt: now
            ),
            created: registrationCount == 1
        )
    }

    func authorizePairing(
        deviceToken: String,
        requestID: String,
        macInstallationID: String,
        mobileTailcatPublicKey: String,
        macTailcatPublicKey: String,
        pairingMacTailcatPublicKey: String,
        managedPairingGrant: String
    ) async throws -> ManagedConnectionPairingSession {
        authorizationCount += 1
        lastAuthorizedRequest = AuthorizedRequest(
            requestID: requestID,
            mobileKey: mobileTailcatPublicKey,
            macKey: macTailcatPublicKey,
            pairingMacKey: pairingMacTailcatPublicKey,
            grant: managedPairingGrant
        )
        return ManagedConnectionPairingSession(
            id: "30000000-0000-4000-8000-000000000001",
            expiresAt: now.addingTimeInterval(600),
            macSlot: .reserved,
            created: true
        )
    }

    func createManagementSession(
        signedAppTransaction: String,
        signedTransaction: String
    ) async throws -> ManagedConnectionManagementSession {
        managementSessionCount += 1
        lastManagementEvidence = (signedAppTransaction, signedTransaction)
        return ManagedConnectionManagementSession(
            token: "management-token-\(managementSessionCount)-that-is-long-enough",
            expiresAt: now.addingTimeInterval(600)
        )
    }

    func listDevices(managementToken: String) async throws -> [ManagedConnectionDevice] {
        devices
    }

    func removeDevice(id: String, managementToken: String) async throws {
        if let removalFailure { throw removalFailure }
        removedDeviceIDs.append(id)
        devices.removeAll { $0.id == id }
    }
}
