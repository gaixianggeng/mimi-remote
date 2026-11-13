import Foundation
import XCTest
@testable import MimiRemote

final class ManagedNodeOwnershipTests: XCTestCase {
    func testCrossPlatformProofVector() throws {
        let challenge = ManagedNodeOwnershipChallenge(
            challengeId: "10000000-0000-4000-8000-000000000001",
            challengePublicKey: "V9tLNZ8jrl4Ubk4lEgVnBHIlBjSMFQwUdT0Mkz0E1CE", expiresAt: .distantFuture
        )
        let proof = try ManagedNodeOwnership.mobileProof(
            privateKey: "privkey:" + String(repeating: "07", count: 32),
            publicKey: "nodekey:13be4feaeaf204c7fd3358fc9c00721881d174278128227ec674f37f7fe97b6d", challenge: challenge
        )
        XCTAssertEqual(proof, "1a9e6c5ea905d95f2e008ef909e577f4f2771d0bb3337dbf17dab8c942e041dd")
        XCTAssertThrowsError(try ManagedNodeOwnership.mobileProof(privateKey: "bad", publicKey: "bad", challenge: challenge))
        XCTAssertThrowsError(try ManagedNodeOwnership.mobileProof(privateKey: "privkey:" + String(repeating: "07", count: 32), publicKey: "wrong-node", challenge: challenge))
    }
}
