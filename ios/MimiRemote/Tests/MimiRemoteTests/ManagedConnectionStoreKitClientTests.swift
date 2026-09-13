import StoreKit
import StoreKitTest
import XCTest
@testable import MimiRemote

@MainActor
final class ManagedConnectionStoreKitClientTests: XCTestCase {
    func testReplayedExpiredPurchaseRemainsVerifiedAndCanBeFinished() async throws {
        let (session, client) = try await makeSessionAndClient()
        session.timeRate = .oneRenewalEveryTwoSeconds
        let transaction = try await session.buyProduct(identifier: ManagedConnectionProductID.monthly)
        try session.disableAutoRenewForTransaction(identifier: UInt(transaction.id))
        let expiresAt = try XCTUnwrap(transaction.expirationDate)
        guard expiresAt.timeIntervalSinceNow < 10 else {
            return XCTFail("StoreKit 未使用测试设置的加速续期时间")
        }
        // 保留同一笔已签名交易直到实际到期，不依赖 currentEntitlements 的缓存失效时机。
        try await Task.sleep(for: .seconds(max(0, expiresAt.timeIntervalSinceNow) + 0.1))
        var storedVerification: VerificationResult<Transaction>?
        for await result in Transaction.all {
            if case .verified(let value) = result, value.id == transaction.id {
                storedVerification = result
                break
            }
        }
        let verification = try XCTUnwrap(storedVerification)
        XCTAssertLessThanOrEqual(expiresAt, Date())

        // 使用 StoreKit 产生的真实过期交易，复现真机 purchase 重放的返回值。
        let outcome = await client.purchaseOutcome(from: verification)
        guard case .success(let evidence) = outcome else {
            return XCTFail("过期交易必须交给服务端确认，不能误报签名失败")
        }
        XCTAssertEqual(evidence.transactionID, transaction.id)
        XCTAssertEqual(evidence.signedTransaction, verification.jwsRepresentation)
        await client.finish(transactionID: evidence.transactionID)
        let finishDeadline = Date().addingTimeInterval(10)
        while Date() < finishDeadline {
            var isUnfinished = false
            for await unfinished in Transaction.unfinished {
                if case .verified(let value) = unfinished, value.id == transaction.id {
                    isUnfinished = true
                }
            }
            if !isUnfinished { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("确认失效后 StoreKit 仍保留未完成的旧交易")
    }

    func testProductsUseCompactChineseBillingUnits() async throws {
        let (session, client) = try await makeSessionAndClient()
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
        let (session, client) = try await makeSessionAndClient()
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

    func testProductsUseStoreKitDisplayPrices() async throws {
        let (_, client) = try await makeSessionAndClient()
        let storeKitProducts = try await Product.products(for: ManagedConnectionProductID.all)
        let expectedPrices = Dictionary(
            uniqueKeysWithValues: storeKitProducts.map { ($0.id, $0.displayPrice) }
        )

        let products = try await client.products()

        XCTAssertEqual(products.count, ManagedConnectionProductID.all.count)
        for product in products {
            XCTAssertEqual(product.displayPrice, expectedPrices[product.id])
        }
    }

    func testProductsRefreshTrialEligibilityAfterPurchaseInSubscriptionGroup() async throws {
        let (session, client) = try await makeSessionAndClient()
        let initialProducts = try await client.products()
        XCTAssertEqual(initialProducts.count, ManagedConnectionProductID.all.count)
        XCTAssertTrue(initialProducts.allSatisfy(\.isEligibleForTrial))

        _ = try await session.buyProduct(identifier: ManagedConnectionProductID.monthly)

        let refreshedProducts = try await waitUntilTrialIneligible(client)
        XCTAssertEqual(refreshedProducts.count, ManagedConnectionProductID.all.count)
        XCTAssertTrue(refreshedProducts.allSatisfy { !$0.isEligibleForTrial })
    }

    func testCurrentEntitlementRejectsRefundedTransaction() async throws {
        let (session, client) = try await makeSessionAndClient()
        let revoked = try await session.buyProduct(identifier: ManagedConnectionProductID.monthly)
        try session.disableAutoRenewForTransaction(identifier: UInt(revoked.id))
        try await waitUntilVerified(client, transactionID: revoked.id)
        try session.refundTransaction(identifier: UInt(revoked.id))
        try await waitUntilNotVerified(client, productID: ManagedConnectionProductID.monthly)
    }

    private func makeSessionAndClient() async throws -> (
        SKTestSession,
        LiveManagedConnectionStoreKitClient
    ) {
        let configurationURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "MimiRemote", withExtension: "storekit")
        )
        let session = try SKTestSession(contentsOf: configurationURL)
        session.resetToDefaultState()
        try deleteAllTransactions(in: session)
        session.disableDialogs = true
        addTeardownBlock {
            session.resetToDefaultState()
            for transaction in session.allTransactions() {
                try session.deleteTransaction(identifier: transaction.identifier)
            }
        }
        let client = LiveManagedConnectionStoreKitClient()
        _ = try await waitUntilTrialEligible(client)
        return (session, client)
    }

    private func deleteAllTransactions(in session: SKTestSession) throws {
        // 删除消费试用的测试交易，避免后续测试继承同一订阅组的购买记录。
        for transaction in session.allTransactions() {
            try session.deleteTransaction(identifier: transaction.identifier)
        }
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

    private func waitUntilTrialIneligible(
        _ client: LiveManagedConnectionStoreKitClient
    ) async throws -> [ManagedConnectionProduct] {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let products = try await client.products()
            if products.allSatisfy({ !$0.isEligibleForTrial }) {
                return products
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw StoreKitTestError.timedOut("购买同一订阅组商品后仍显示免费试用资格")
    }

    private func waitUntilTrialEligible(
        _ client: LiveManagedConnectionStoreKitClient
    ) async throws -> [ManagedConnectionProduct] {
        // 删除交易后 StoreKit 的资格仍可能保留约 15 秒，等待实际恢复再开始测试。
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let products = try await client.products()
            if products.count == ManagedConnectionProductID.all.count,
               products.allSatisfy(\.isEligibleForTrial)
            {
                return products
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw StoreKitTestError.timedOut("清理交易后免费试用资格没有恢复")
    }
}

private enum StoreKitTestError: Error {
    case timedOut(String)
}
