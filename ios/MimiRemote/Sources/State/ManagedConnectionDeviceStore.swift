import Foundation

struct ManagedConnectionPairingAuthorization: Equatable, Sendable {
    let sessionID: String
    let grant: String
}

@MainActor
protocol ManagedConnectionPairingAuthorizing: AnyObject {
    func authorizeManagedPairing(
        macInstallationID: String,
        macTailcatPublicKey: String,
        mobileTailcatPublicKey: String
    ) async throws -> ManagedConnectionPairingAuthorization

    func didCompleteManagedPairing(_ authorization: ManagedConnectionPairingAuthorization)
}

@MainActor
final class ManagedConnectionDeviceStore: ObservableObject, ManagedConnectionPairingAuthorizing {
    static let macLimit = 3
    static let mobileLimit = 5

    @Published private(set) var devices: [ManagedConnectionDevice] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var removingDeviceID: String?
    @Published private(set) var errorMessage: String?

    private struct PendingPairingAuthorization {
        let macInstallationID: String
        let macTailcatPublicKey: String
        let mobileTailcatPublicKey: String
        let requestID: String
        let grant: String
        var session: ManagedConnectionPairingSession?
        let localExpiresAt: Date
    }

    private struct CachedManagementSession {
        let session: ManagedConnectionManagementSession
        let transactionID: UInt64
        let productID: String
    }

    private let entitlementStore: ManagedConnectionEntitlementStore
    private let api: any ManagedConnectionDeviceAPIClient
    private let identityStore: any ManagedConnectionMobileIdentityStoring
    private let now: () -> Date
    private let makeUUID: () -> UUID
    private let makeToken: () throws -> String
    private var managementSession: CachedManagementSession?
    private var pendingPairing: PendingPairingAuthorization?

    init(
        entitlementStore: ManagedConnectionEntitlementStore,
        api: any ManagedConnectionDeviceAPIClient = LiveManagedConnectionDeviceAPIClient(),
        identityStore: (any ManagedConnectionMobileIdentityStoring)? = nil,
        now: @escaping () -> Date = Date.init,
        makeUUID: @escaping () -> UUID = UUID.init,
        makeToken: @escaping () throws -> String = ManagedConnectionSecretGenerator.token
    ) {
        self.entitlementStore = entitlementStore
        self.api = api
        if let identityStore {
            self.identityStore = identityStore
        } else {
            self.identityStore = ManagedConnectionMobileIdentityStore()
        }
        self.now = now
        self.makeUUID = makeUUID
        self.makeToken = makeToken
    }

    var macCount: Int { devices.lazy.filter { $0.deviceType == .mac }.count }
    var mobileCount: Int { devices.lazy.filter { $0.deviceType == .mobile }.count }

    var currentDeviceID: String? {
        try? identityStore.loadOrCreate().registeredDeviceID
    }

    func refreshDevices() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let token = try await validManagementToken()
            let refreshedDevices = try await api.listDevices(managementToken: token)
                .sorted { $0.createdAt > $1.createdAt }
            devices = refreshedDevices
            try reconcileCurrentDeviceAfterRemoteRevocation(refreshedDevices)
            errorMessage = nil
        } catch {
            errorMessage = userFacingMessage(for: error)
        }
    }

    func removeDevice(_ device: ManagedConnectionDevice) async {
        guard removingDeviceID == nil else { return }
        removingDeviceID = device.id
        defer { removingDeviceID = nil }
        do {
            let token = try await validManagementToken()
            do {
                try await api.removeDevice(id: device.id, managementToken: token)
            } catch let error as ManagedConnectionDeviceAPIError
                where error.rejectionCode == "device_not_found" {
                // 服务端删除已完成但客户端未收到响应时，重试仍要完成本地凭证轮换。
            }
            try identityStore.rotateCredentialAfterRevocation(deviceID: device.id)
            if currentDeviceID == nil {
                pendingPairing = nil
            }
            devices.removeAll { $0.id == device.id }
            errorMessage = nil
        } catch {
            errorMessage = userFacingMessage(for: error)
        }
    }

    func authorizeManagedPairing(
        macInstallationID: String,
        macTailcatPublicKey: String,
        mobileTailcatPublicKey: String
    ) async throws -> ManagedConnectionPairingAuthorization {
        let identity = try await ensureMobileDeviceRegistered()
        let pending = try reusableOrNewPendingPairing(
            macInstallationID: macInstallationID,
            macTailcatPublicKey: macTailcatPublicKey,
            mobileTailcatPublicKey: mobileTailcatPublicKey
        )
        if let session = pending.session, session.expiresAt > now() {
            return ManagedConnectionPairingAuthorization(sessionID: session.id, grant: pending.grant)
        }

        let session = try await api.authorizePairing(
            deviceToken: identity.deviceToken,
            requestID: pending.requestID,
            macInstallationID: macInstallationID,
            mobileTailcatPublicKey: mobileTailcatPublicKey,
            macTailcatPublicKey: macTailcatPublicKey,
            managedPairingGrant: pending.grant
        )
        pendingPairing?.session = session
        return ManagedConnectionPairingAuthorization(sessionID: session.id, grant: pending.grant)
    }

    func didCompleteManagedPairing(_ authorization: ManagedConnectionPairingAuthorization) {
        guard pendingPairing?.grant == authorization.grant else { return }
        pendingPairing = nil
        Task { await refreshDevices() }
    }

    private func ensureMobileDeviceRegistered() async throws -> ManagedConnectionMobileIdentity {
        let identity = try identityStore.loadOrCreate()
        let grant = try await validEntitlementGrant()
        do {
            let result = try await api.registerMobileDevice(
                entitlementToken: grant.token,
                installationID: identity.installationID,
                deviceToken: identity.deviceToken
            )
            identityStore.rememberRegisteredDeviceID(result.device.id)
            return ManagedConnectionMobileIdentity(
                installationID: identity.installationID,
                deviceToken: identity.deviceToken,
                registeredDeviceID: result.device.id
            )
        } catch let error as ManagedConnectionDeviceAPIError where error.rejectionCode == "unauthorized" {
            await entitlementStore.refreshEntitlement()
            let refreshedGrant = try await validEntitlementGrant(refreshIfMissing: false)
            let result = try await api.registerMobileDevice(
                entitlementToken: refreshedGrant.token,
                installationID: identity.installationID,
                deviceToken: identity.deviceToken
            )
            identityStore.rememberRegisteredDeviceID(result.device.id)
            return ManagedConnectionMobileIdentity(
                installationID: identity.installationID,
                deviceToken: identity.deviceToken,
                registeredDeviceID: result.device.id
            )
        }
    }

    private func validEntitlementGrant(
        refreshIfMissing: Bool = true
    ) async throws -> ManagedConnectionEntitlementGrant {
        if let grant = entitlementStore.currentGrant,
           grant.entitlement.expiresAt > now(),
           grant.tokenExpiresAt > now()
        {
            return grant
        }
        if refreshIfMissing {
            await entitlementStore.refreshEntitlement()
            if let grant = entitlementStore.currentGrant,
               grant.entitlement.expiresAt > now(),
               grant.tokenExpiresAt > now()
            {
                return grant
            }
        }
        throw ManagedConnectionDeviceStoreError.subscriptionRequired
    }

    private func validManagementToken() async throws -> String {
        let evidence = try await entitlementStore.managementPurchaseEvidence()
        if let managementSession,
           managementSession.transactionID == evidence.transactionID,
           managementSession.productID == evidence.productID,
           managementSession.session.expiresAt.timeIntervalSince(now()) > 5
        {
            return managementSession.session.token
        }
        let session = try await api.createManagementSession(
            signedAppTransaction: evidence.signedAppTransaction,
            signedTransaction: evidence.signedTransaction
        )
        managementSession = CachedManagementSession(
            session: session,
            transactionID: evidence.transactionID,
            productID: evidence.productID
        )
        return session.token
    }

    private func reusableOrNewPendingPairing(
        macInstallationID: String,
        macTailcatPublicKey: String,
        mobileTailcatPublicKey: String
    ) throws -> PendingPairingAuthorization {
        if let pendingPairing,
           pendingPairing.macInstallationID == macInstallationID,
           pendingPairing.macTailcatPublicKey == macTailcatPublicKey,
           pendingPairing.mobileTailcatPublicKey == mobileTailcatPublicKey,
           pendingPairing.localExpiresAt > now()
        {
            return pendingPairing
        }
        let pending = PendingPairingAuthorization(
            macInstallationID: macInstallationID,
            macTailcatPublicKey: macTailcatPublicKey,
            mobileTailcatPublicKey: mobileTailcatPublicKey,
            requestID: makeUUID().uuidString.lowercased(),
            grant: try makeToken(),
            session: nil,
            localExpiresAt: now().addingTimeInterval(600)
        )
        pendingPairing = pending
        return pending
    }

    private func reconcileCurrentDeviceAfterRemoteRevocation(
        _ refreshedDevices: [ManagedConnectionDevice]
    ) throws {
        guard let currentDeviceID,
              !refreshedDevices.contains(where: { $0.id == currentDeviceID }) else {
            return
        }
        // DELETE 成功后的进程中断或 Keychain 失败会留下旧本地凭证；每次刷新都重试收敛。
        try identityStore.rotateCredentialAfterRevocation(deviceID: currentDeviceID)
        pendingPairing = nil
    }

    private func userFacingMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty
        {
            return description
        }
        return L10n.text("ui.managed_devices_network_error")
    }
}

enum ManagedConnectionDeviceStoreError: LocalizedError, Equatable {
    case subscriptionRequired
    case managedQRCodeRequired

    var errorDescription: String? {
        switch self {
        case .subscriptionRequired:
            return L10n.text("ui.managed_devices_subscription_required")
        case .managedQRCodeRequired:
            return L10n.text("ui.managed_devices_qr_required")
        }
    }
}
