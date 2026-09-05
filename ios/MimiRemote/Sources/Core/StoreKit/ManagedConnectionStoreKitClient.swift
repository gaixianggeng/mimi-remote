import Foundation
import StoreKit

enum ManagedConnectionProductID {
    static let monthly = "com.gaixianggeng.mimi.managed.monthly"
    static let annual = "com.gaixianggeng.mimi.managed.annual"
    static let all = [monthly, annual]
}

struct ManagedConnectionProduct: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let displayPrice: String
    let displayPeriod: String
    let isEligibleForTrial: Bool
    let displayTrialPeriod: String?
}

struct ManagedConnectionTransactionEvidence: Equatable, Sendable {
    let transactionID: UInt64
    let productID: String
    let signedTransaction: String
}

enum ManagedConnectionPurchaseOutcome: Equatable, Sendable {
    case success(ManagedConnectionTransactionEvidence)
    case pending
    case cancelled
    case unverified
}

enum ManagedConnectionCurrentEntitlementOutcome: Equatable, Sendable {
    case none
    case verified(ManagedConnectionTransactionEvidence)
    case unverified
}

enum ManagedConnectionTransactionUpdate: Equatable, Sendable {
    case verified(ManagedConnectionTransactionEvidence)
    case unverified
}

protocol ManagedConnectionStoreKitClient: Sendable {
    func products() async throws -> [ManagedConnectionProduct]
    func purchase(productID: String) async throws -> ManagedConnectionPurchaseOutcome
    func currentEntitlement(productID: String) async -> ManagedConnectionCurrentEntitlementOutcome
    func transactionUpdates() -> AsyncStream<ManagedConnectionTransactionUpdate>
    func signedAppTransaction() async throws -> String
    func finish(transactionID: UInt64) async
    func syncPurchases() async throws
}

actor LiveManagedConnectionStoreKitClient: ManagedConnectionStoreKitClient {
    private var productsByID: [String: Product] = [:]
    private var unfinishedTransactions: [UInt64: Transaction] = [:]

    func products() async throws -> [ManagedConnectionProduct] {
        let products = try await Product.products(for: ManagedConnectionProductID.all)
        productsByID = Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0) })

        var result: [ManagedConnectionProduct] = []
        for product in products {
            guard let subscription = product.subscription else { continue }
            let eligible = await subscription.isEligibleForIntroOffer
            let freeTrialOffer = subscription.introductoryOffer.flatMap { offer in
                ManagedConnectionTrialEligibility.isFreeTrial(
                    eligible: eligible,
                    paymentMode: offer.paymentMode
                ) ? offer : nil
            }
            let trialPeriod = freeTrialOffer.map {
                Self.displayPeriod($0.period, product: product)
            }
            result.append(
                ManagedConnectionProduct(
                    id: product.id,
                    displayName: product.displayName,
                    displayPrice: product.displayPrice,
                    displayPeriod: Self.displayPeriod(subscription.subscriptionPeriod, product: product),
                    isEligibleForTrial: eligible && freeTrialOffer != nil,
                    displayTrialPeriod: trialPeriod
                )
            )
        }
        return result.sorted { lhs, rhs in
            ManagedConnectionProductID.all.firstIndex(of: lhs.id) ?? .max
                < ManagedConnectionProductID.all.firstIndex(of: rhs.id) ?? .max
        }
    }

    func purchase(productID: String) async throws -> ManagedConnectionPurchaseOutcome {
        let product: Product
        if let cached = productsByID[productID] {
            product = cached
        } else {
            guard let loaded = try await Product.products(for: [productID]).first else {
                throw ManagedConnectionStoreKitError.productUnavailable
            }
            productsByID[productID] = loaded
            product = loaded
        }

        switch try await product.purchase() {
        case .success(let verification):
            guard case .verified(let transaction) = verification,
                  transaction.revocationDate == nil,
                  transaction.expirationDate.map({ $0 > Date() }) ?? true
            else {
                return .unverified
            }
            unfinishedTransactions[transaction.id] = transaction
            return .success(Self.evidence(from: verification, transaction: transaction))
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .unverified
        }
    }

    func currentEntitlement(productID: String) async -> ManagedConnectionCurrentEntitlementOutcome {
        if #available(iOS 18.4, macCatalyst 18.4, *) {
            for await verification in Transaction.currentEntitlements(for: productID) {
                return currentOutcome(from: verification)
            }
            return .none
        }

        // 项目最低支持 iOS 18.0；18.4 之前没有新的 per-product 序列 API。
        // 旧系统只查询两个固定商品之一，不遍历 App 的其他交易。
        guard let verification = await Transaction.currentEntitlement(for: productID) else {
            return .none
        }
        return currentOutcome(from: verification)
    }

    nonisolated func transactionUpdates() -> AsyncStream<ManagedConnectionTransactionUpdate> {
        AsyncStream { continuation in
            let listener = Task {
                for await verification in Transaction.updates {
                    switch verification {
                    case .verified(let transaction):
                        guard ManagedConnectionProductID.all.contains(transaction.productID) else {
                            continue
                        }
                        await rememberUnfinished(transaction)
                        continuation.yield(
                            .verified(Self.evidence(from: verification, transaction: transaction))
                        )
                    case .unverified(let transaction, _):
                        guard ManagedConnectionProductID.all.contains(transaction.productID) else {
                            continue
                        }
                        continuation.yield(.unverified)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                listener.cancel()
            }
        }
    }

    private func rememberUnfinished(_ transaction: Transaction) {
        unfinishedTransactions[transaction.id] = transaction
    }

    private func currentOutcome(
        from verification: VerificationResult<Transaction>
    ) -> ManagedConnectionCurrentEntitlementOutcome {
        guard case .verified(let transaction) = verification,
              transaction.revocationDate == nil,
              !transaction.isUpgraded
        else {
            return .unverified
        }
        // currentEntitlements 已按 StoreKit 的订阅状态筛选，并会返回宽限期交易。
        // 宽限期内原服务期可能已过，不能再次按 expirationDate 把它降为无权益。
        // 冷启动可能恢复到尚未 finish 的已验证交易；服务端授权后再幂等 finish。
        unfinishedTransactions[transaction.id] = transaction
        return .verified(Self.evidence(from: verification, transaction: transaction))
    }

    func signedAppTransaction() async throws -> String {
        let verification = try await AppTransaction.shared
        guard case .verified = verification else {
            throw ManagedConnectionStoreKitError.unverifiedAppTransaction
        }
        return verification.jwsRepresentation
    }

    func finish(transactionID: UInt64) async {
        guard let transaction = unfinishedTransactions.removeValue(forKey: transactionID) else { return }
        await transaction.finish()
    }

    func syncPurchases() async throws {
        try await StoreKit.AppStore.sync()
    }

    private static func evidence(
        from verification: VerificationResult<Transaction>,
        transaction: Transaction
    ) -> ManagedConnectionTransactionEvidence {
        ManagedConnectionTransactionEvidence(
            transactionID: transaction.id,
            productID: transaction.productID,
            signedTransaction: verification.jwsRepresentation
        )
    }

    private static func displayPeriod(
        _ period: Product.SubscriptionPeriod,
        product: Product
    ) -> String {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let components = DateComponents(subscriptionPeriod: period)
        let calendar = Calendar(identifier: .gregorian)
        guard let end = calendar.date(byAdding: components, to: start) else {
            return period.unit.formatted(product.subscriptionPeriodUnitFormatStyle)
        }
        return (start..<end).formatted(product.subscriptionPeriodFormatStyle)
    }
}

enum ManagedConnectionTrialEligibility {
    static func isFreeTrial(
        eligible: Bool,
        paymentMode: Product.SubscriptionOffer.PaymentMode?
    ) -> Bool {
        eligible && paymentMode == .freeTrial
    }
}

enum ManagedConnectionStoreKitError: LocalizedError {
    case productUnavailable
    case unverifiedAppTransaction

    var errorDescription: String? {
        switch self {
        case .productUnavailable:
            return L10n.text("ui.managed_subscription_product_unavailable")
        case .unverifiedAppTransaction:
            return L10n.text("ui.managed_subscription_unverified")
        }
    }
}
