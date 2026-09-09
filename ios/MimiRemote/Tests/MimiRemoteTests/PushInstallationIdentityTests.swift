import Security
import XCTest
@testable import MimiRemote

@MainActor
final class PushInstallationIdentityTests: XCTestCase {
    func testUpgradeKeepsIdentityWhenThisDeviceTicketExists() throws {
        let (defaults, suite) = try legacyDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = TestKeychainOperations()
        let ticketStore = PushTicketStore(keychain: keychain)
        try ticketStore.save("old-ticket")
        let identityStore = PushInstallationIdentityStore(keychain: keychain)
        let store = LockScreenApprovalStore(
            defaults: defaults, ticketStore: ticketStore, identityStore: identityStore
        )
        XCTAssertEqual(store.deviceID, "dev-original")
        XCTAssertEqual(store.installationID, "ins-original")
        XCTAssertEqual(try identityStore.load()?.deviceID, "dev-original")
        XCTAssertTrue(store.isEnabled)
        XCTAssertNil(defaults.string(forKey: "lockScreenApproval.deviceID"))
    }

    func testRestoredDefaultsWithoutDeviceTicketCannotReuseOldIdentity() throws {
        let (defaults, suite) = try legacyDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = TestKeychainOperations()
        let store = LockScreenApprovalStore(
            defaults: defaults, ticketStore: PushTicketStore(keychain: keychain),
            identityStore: PushInstallationIdentityStore(keychain: keychain)
        )
        XCTAssertFalse(store.deviceID.isEmpty)
        XCTAssertNotEqual(store.deviceID, "dev-original")
        XCTAssertNotEqual(store.installationID, "ins-original")
        XCTAssertFalse(store.isEnabled)
        XCTAssertNil(store.registeredProfileID)
    }

    func testLockedKeychainDoesNotMintOrOverwriteIdentity() throws {
        let (defaults, suite) = try legacyDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = TestKeychainOperations(forcedCopyStatus: errSecInteractionNotAllowed)
        let store = LockScreenApprovalStore(
            defaults: defaults, ticketStore: PushTicketStore(keychain: keychain),
            identityStore: PushInstallationIdentityStore(keychain: keychain)
        )
        XCTAssertTrue(store.deviceID.isEmpty)
        XCTAssertEqual(keychain.addCallCount, 0)
        XCTAssertEqual(keychain.updateCallCount, 0)
        XCTAssertEqual(defaults.string(forKey: "lockScreenApproval.deviceID"), "dev-original")
        guard case .failed = store.status else { return XCTFail("Keychain 锁定必须保留失败状态") }
    }

    private func legacyDefaults() throws -> (UserDefaults, String) {
        let suite = "PushInstallationIdentityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "lockScreenApproval.enabled")
        defaults.set("dev-original", forKey: "lockScreenApproval.deviceID")
        defaults.set("ins-original", forKey: "lockScreenApproval.installation")
        defaults.set("mac-a", forKey: "lockScreenApproval.registeredProfileID")
        defaults.set("https://provider.example/mimi-push", forKey: "lockScreenApproval.registeredProviderURL")
        defaults.set(Date().addingTimeInterval(3600), forKey: "lockScreenApproval.ticketExpiresAt")
        return (defaults, suite)
    }
}
