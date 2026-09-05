import StoreKit
import StoreKitTest
import XCTest
@testable import MimiRemote

@MainActor
final class ManagedConnectionStoreKitClientTests: XCTestCase {
    func testProductsUseCompactChineseBillingUnits() async throws {
        let (session, client) = try makeSessionAndClient()
        session.locale = Locale(identifier: "zh_CN")
        session.storefront = "CHN"
        let products = try await client.products()
        let monthly = try XCTUnwrap(products.first { $0.id == ManagedConnectionProductID.monthly })
        let annual = try XCTUnwrap(products.first { $0.id == ManagedConnectionProductID.annual })

        XCTAssertEqual(monthly.displayPeriod, "月")
        XCTAssertEqual(annual.displayPeriod, "年")
        let template = L10n.text("ui.managed_subscription_price_period", language: .simplifiedChinese)
        XCTAssertEqual(L10n.formatTemplate(template, arguments: ["¥9.90", monthly.displayPeriod]), "¥9.90/月")
        XCTAssertEqual(L10n.formatTemplate(template, arguments: ["¥99.00", annual.displayPeriod]), "¥99.00/年")
        XCTAssertEqual(monthly.displayTrialPeriod, "一周")
    }

    func testProductsKeepLocalizedEnglishBillingUnits() async throws {
        let (session, client) = try makeSessionAndClient()
        session.locale = Locale(identifier: "en_US")
        session.storefront = "USA"
        let products = try await client.products()
        let monthly = try XCTUnwrap(products.first { $0.id == ManagedConnectionProductID.monthly })
        let annual = try XCTUnwrap(products.first { $0.id == ManagedConnectionProductID.annual })

        XCTAssertEqual(monthly.displayPeriod, "Month")
        XCTAssertEqual(annual.displayPeriod, "Year")
        let template = L10n.text("ui.managed_subscription_price_period", language: .english)
        XCTAssertEqual(L10n.formatTemplate(template, arguments: ["$1.99", monthly.displayPeriod]), "$1.99/Month")
        XCTAssertEqual(L10n.formatTemplate(template, arguments: ["$19.99", annual.displayPeriod]), "$19.99/Year")
    }

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
