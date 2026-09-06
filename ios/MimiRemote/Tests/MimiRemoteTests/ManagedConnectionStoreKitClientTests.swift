import StoreKit
import StoreKitTest
import XCTest
@testable import MimiRemote

@MainActor
final class ManagedConnectionStoreKitClientTests: XCTestCase {
    func testCurrentEntitlementRejectsRefundedTransaction() async throws {
        let (session, client) = try makeSessionAndClient()
        let revoked = try await session.buyProduct(identifier: ManagedConnectionProductID.monthly)
        try session.disableAutoRenewForTransaction(identifier: UInt(revoked.id))
        try await waitUntilVerified(client, transactionID: revoked.id)
        try session.refundTransaction(identifier: UInt(revoked.id))
        try await waitUntilNotVerified(client, productID: ManagedConnectionProductID.monthly)
    }

    private func makeSessionAndClient() throws -> (
        SKTestSession,
        LiveManagedConnectionStoreKitClient
    ) {
        let configurationURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "MimiRemote", withExtension: "storekit")
        )
        let session = try SKTestSession(contentsOf: configurationURL)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        addTeardownBlock {
            session.resetToDefaultState()
            session.clearTransactions()
        }
        return (session, LiveManagedConnectionStoreKitClient())
    }

    private func waitUntilNotVerified(
        _ client: LiveManagedConnectionStoreKitClient,
        productID: String
    ) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let outcome = await client.currentEntitlement(productID: productID)
            if case .verified = outcome {
                try await Task.sleep(for: .milliseconds(100))
                continue
            }
            return
        }
        throw StoreKitTestError.timedOut("过期或撤销交易仍被识别为有效权益")
    }

    private func waitUntilVerified(
        _ client: LiveManagedConnectionStoreKitClient,
        transactionID: UInt64
    ) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if case .verified(let evidence) = await client.currentEntitlement(
                productID: ManagedConnectionProductID.monthly
            ), evidence.transactionID == transactionID {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw StoreKitTestError.timedOut("新交易没有先成为当前有效权益")
    }
}

private enum StoreKitTestError: Error {
    case timedOut(String)
}
