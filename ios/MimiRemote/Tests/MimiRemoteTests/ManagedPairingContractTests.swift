import Foundation
import XCTest
@testable import MimiRemote

@MainActor
final class ManagedPairingContractTests: XCTestCase {
    func testTailcatPairingLinkCarriesManagedHostMetadataAndGrant() throws {
        let url = try XCTUnwrap(URL(string: "mimiremote://pair?endpoint=http%3A%2F%2F127.0.0.1%3A8787&issued_at=2026-09-01T00%3A00%3A00Z&expires_at=4102444800&pair_sig=abcdef&transport=tailcat&tailcat_pair_address=tc%3Atest-address&managed_mac_installation_id=20000000-0000-4000-8000-000000000001&managed_mac_tailcat_public_key=nodekey%3Amac-public&managed_pair_tailcat_public_key=nodekey%3Apair-public"))
        let link = try XCTUnwrap(TailcatPairingLink.parse(url))

        XCTAssertEqual(link.managedMacInstallationID, "20000000-0000-4000-8000-000000000001")
        XCTAssertEqual(link.managedMacTailcatPublicKey, "nodekey:mac-public")
        XCTAssertEqual(link.managedPairTailcatPublicKey, "nodekey:pair-public")
        let request = link.ticket.managedClaimRequest(
            tailcatClientKey: "nodekey:mobile-public",
            pairingSessionID: "30000000-0000-4000-8000-000000000001",
            managedPairingGrant: "grant"
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: String]
        )
        XCTAssertEqual(object["managed_pairing_session_id"], "30000000-0000-4000-8000-000000000001")
        XCTAssertEqual(object["managed_pairing_grant"], "grant")
    }

    func testTailcatPairingLinkRejectsPartialManagedHostMetadata() throws {
        let url = try XCTUnwrap(URL(string: "mimiremote://pair?endpoint=http%3A%2F%2F127.0.0.1%3A8787&issued_at=2026-09-01T00%3A00%3A00Z&expires_at=4102444800&pair_sig=abcdef&transport=tailcat&tailcat_pair_address=tc%3Atest-address&managed_mac_installation_id=20000000-0000-4000-8000-000000000001"))

        XCTAssertThrowsError(try TailcatPairingLink.parse(url)) { error in
            XCTAssertEqual(error as? PairingLinkError, .unsupportedURL)
        }
    }
}
