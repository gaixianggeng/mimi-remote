import Foundation

struct ManagedConnectionPurchaseEvidence: Equatable, Sendable {
    let transactionID: UInt64
    let productID: String
    let signedAppTransaction: String
    let signedTransaction: String
}

@MainActor
final class ManagedConnectionEntitlementStore: ObservableObject {
    enum Status: Equatable {
        case loading
        case available
        case resolving
        case entitled(ManagedConnectionEntitlement)
        case pending
        case expired
        case revoked
        case failed(String)
    }

    @Published private(set) var products: [ManagedConnectionProduct] = []
    @Published private(set) var status: Status = .loading {
        didSet { stateRevision &+= 1 }
    }
    @Published private(set) var currentGrant: ManagedConnectionEntitlementGrant?
    private(set) var currentEvidence: ManagedConnectionTransactionEvidence?

    private let storeKit: any ManagedConnectionStoreKitClient
    private let entitlementAPI: any ManagedConnectionEntitlementAPIClient
    private let now: () -> Date
    private let sleepUntil: @Sendable (Date) async throws -> Void
    private var operationGeneration = 0
    private var productGeneration = 0
    // 操作开始序号不能识别同一操作稍后提交的结果；页面回滚还须检查状态版本。
    private var stateRevision = 0
    private var authoritativeGeneration: Int?
    private var needsEntitlementRefresh = false
    // 购买等待期间仍须处理撤销事件，因此用计数覆盖这两个操作的重叠区间。
    @Published private var activeTransactionOperations = 0

    init(
        storeKit: any ManagedConnectionStoreKitClient,
        entitlementAPI: any ManagedConnectionEntitlementAPIClient,
        now: @escaping () -> Date = Date.init,
        sleepUntil: @escaping @Sendable (Date) async throws -> Void = { date in
            let delay = max(0, date.timeIntervalSinceNow)
            if delay > 0 {
                try await Task.sleep(for: .seconds(delay))
            }
        }
    ) {
        self.storeKit = storeKit
        self.entitlementAPI = entitlementAPI
        self.now = now
        self.sleepUntil = sleepUntil
    }

    func load() async {
        let generation = operationGeneration
        let previousGrant = usableCurrentGrant
        let previousStatus = status
        if activeTransactionOperations == 0 { status = .loading }
        let revision = stateRevision
        do {
            try await reloadProducts()
            guard isLatest(generation), stateRevision == revision,
                  activeTransactionOperations == 0 else { return }
            await refreshEntitlement()
        } catch is CancellationError {
            guard isLatest(generation), stateRevision == revision,
                  activeTransactionOperations == 0 else { return }
            restoreAfterCancellation(previousGrant, previousStatus: previousStatus)
        } catch {
            guard isLatest(generation), stateRevision == revision,
                  activeTransactionOperations == 0 else { return }
            restore(previousGrant, otherwise: .failed(userFacingMessage(for: error)))
        }
    }

    func refreshProducts() async {
        guard productGeneration > 0 else { return }
        // 商品刷新失败保留已显示的价格；它不能清除已确认的订阅权益。
        try? await reloadProducts()
    }

    func observeStorefrontUpdates() async {
        for await _ in storeKit.storefrontUpdates() {
            guard !Task.isCancelled else { return }
            await refreshProducts()
        }
    }

    private func reloadProducts() async throws {
        productGeneration &+= 1
        let generation = productGeneration
        do {
            let loadedProducts = try await storeKit.products()
            try Task.checkCancellation()
            guard generation == productGeneration else { return }
            products = loadedProducts
        } catch {
            guard generation == productGeneration else { return }
            throw error
        }
    }

    func refreshEntitlement() async {
        // 系统支付/恢复弹窗也会触发前台刷新；普通读取不能抢占交易处理。
        guard activeTransactionOperations == 0 else {
            needsEntitlementRefresh = true
            return
        }
        let generation = beginOperation()
        await refreshEntitlement(generation: generation)
    }

    func observeTransactionUpdates() async {
        // Ask to Buy、另一设备购买等交易会在 App 运行期间异步完成。
        // 收到变化后仍走统一的服务端校验路径，监听器本身不直接授予权益。
        // 单个商品任务合并重复通知，慢商品请求不会挡住撤销事件；监听结束时一起取消。
        let refreshes = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let productRefresh = Task {
            for await _ in refreshes.stream {
                guard !Task.isCancelled else { return }
                await refreshProducts()
            }
        }
        defer {
            refreshes.continuation.finish()
            productRefresh.cancel()
        }
        for await update in storeKit.transactionUpdates() {
            guard !Task.isCancelled else { return }
            switch update {
            case .verified(let evidence):
                await resolveTransactionUpdate(evidence)
                await refreshDeferredEntitlement()
                refreshes.continuation.yield(())
            case .unverified:
                // 未验证事件本身不能改变权益；重新读取 Apple 当前已验证权益。
                await refreshEntitlement()
            }
        }
    }

    func maintainCurrentGrant() async {
        guard let scheduledGrant = usableCurrentGrant else { return }
        var refreshAt = scheduledGrant.tokenExpiresAt.addingTimeInterval(-60)

        while !Task.isCancelled {
            do {
                try await sleepUntil(max(refreshAt, now()))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  currentGrant?.token == scheduledGrant.token,
                  currentGrant?.tokenExpiresAt == scheduledGrant.tokenExpiresAt
            else {
                return
            }

            await refreshEntitlement()

            guard currentGrant?.token == scheduledGrant.token,
                  currentGrant?.tokenExpiresAt == scheduledGrant.tokenExpiresAt,
                  now() < scheduledGrant.tokenExpiresAt
            else {
                return
            }
            // 提前刷新遇到瞬时故障时，最迟在旧 Token 到期时再尝试一次。
            refreshAt = scheduledGrant.tokenExpiresAt
        }
    }

    private func resolveTransactionUpdate(_ evidence: ManagedConnectionTransactionEvidence) async {
        activeTransactionOperations += 1
        defer { activeTransactionOperations -= 1 }
        let generation = beginOperation()
        let previousGrant = usableCurrentGrant
        status = .resolving
        do {
            let grant = try await resolve(evidence)
            guard isLatest(generation) else { return }
            currentGrant = grant
            currentEvidence = evidence
            authoritativeGeneration = generation
            status = .entitled(grant.entitlement)
            await storeKit.finish(transactionID: evidence.transactionID)
        } catch is CancellationError {
            guard isLatest(generation) else { return }
            restore(previousGrant, otherwise: .available)
        } catch {
            guard isLatest(generation) else { return }
            applyFailure(error, fallbackGrant: previousGrant)
            if isTerminalServerDecision(error) {
                await storeKit.finish(transactionID: evidence.transactionID)
            }
        }
    }

    private func refreshEntitlement(generation: Int) async {
        let previousGrant = usableCurrentGrant
        let previousStatus = status
        status = .resolving

        for productID in ManagedConnectionProductID.all.reversed() {
            let outcome = await storeKit.currentEntitlement(productID: productID)
            guard isLatest(generation) else { return }
            switch outcome {
            case .none:
                continue
            case .unverified:
                currentGrant = nil
                currentEvidence = nil
                authoritativeGeneration = generation
                status = .failed(L10n.text("ui.managed_subscription_unverified"))
                return
            case .verified(let evidence):
                do {
                    let grant = try await resolve(evidence)
                    guard isLatest(generation) else { return }
                    currentGrant = grant
                    currentEvidence = evidence
                    authoritativeGeneration = generation
                    status = .entitled(grant.entitlement)
                    await storeKit.finish(transactionID: evidence.transactionID)
                    return
                } catch is CancellationError {
                    guard isLatest(generation) else { return }
                    restoreAfterCancellation(previousGrant, previousStatus: previousStatus)
                    return
                } catch {
                    guard isLatest(generation) else { return }
                    applyRefreshFailure(error)
                    return
                }
            }
        }

        currentGrant = nil
        currentEvidence = nil
        authoritativeGeneration = generation
        status = .available
    }

    func purchase(productID: String) async {
        guard activeTransactionOperations == 0,
              ManagedConnectionProductID.all.contains(productID) else { return }
        await performPurchase(productID: productID)
        await refreshDeferredEntitlement()
        await refreshProducts()
    }

    private func performPurchase(productID: String) async {
        activeTransactionOperations += 1
        defer { activeTransactionOperations -= 1 }
        let generation = beginOperation()
        let previousGrant = usableCurrentGrant
        let previousStatus = status
        status = .resolving
        do {
            let outcome = try await storeKit.purchase(productID: productID)
            guard isLatest(generation) else { return }
            switch outcome {
            case .cancelled:
                restore(previousGrant, otherwise: .available)
            case .pending:
                restore(previousGrant, otherwise: .pending)
            case .unverified:
                restore(
                    previousGrant,
                    otherwise: .failed(L10n.text("ui.managed_subscription_unverified"))
                )
            case .success(let evidence):
                do {
                    let grant = try await resolve(evidence)
                    guard isLatest(generation) else { return }
                    currentGrant = grant
                    currentEvidence = evidence
                    authoritativeGeneration = generation
                    status = .entitled(grant.entitlement)
                    // 服务端是权益事实来源。只有它接受两份 JWS 后，才结束 StoreKit 交易。
                    await storeKit.finish(transactionID: evidence.transactionID)
                } catch is CancellationError {
                    guard isLatest(generation) else { return }
                    restoreAfterCancellation(previousGrant, previousStatus: previousStatus)
                } catch {
                    guard isLatest(generation) else { return }
                    applyFailure(error, fallbackGrant: previousGrant)
                }
            }
        } catch is CancellationError {
            guard isLatest(generation) else { return }
            restoreAfterCancellation(previousGrant, previousStatus: previousStatus)
        } catch {
            guard isLatest(generation) else { return }
            restore(previousGrant, otherwise: .failed(userFacingMessage(for: error)))
        }
    }

    func restorePurchases() async {
        guard activeTransactionOperations == 0 else { return }
        await performRestore()
        await refreshDeferredEntitlement()
        await refreshProducts()
    }

    private func performRestore() async {
        activeTransactionOperations += 1
        defer { activeTransactionOperations -= 1 }
        let generation = beginOperation()
        let previousGrant = usableCurrentGrant
        let previousStatus = status
        status = .resolving
        do {
            // AppStore.sync 会弹出系统鉴权，只能由用户明确点击“恢复购买”触发。
            try await storeKit.syncPurchases()
            guard isLatest(generation) else { return }
            await refreshEntitlement(generation: generation)
        } catch is CancellationError {
            guard isLatest(generation) else { return }
            restoreAfterCancellation(previousGrant, previousStatus: previousStatus)
        } catch {
            guard isLatest(generation) else { return }
            restore(previousGrant, otherwise: .failed(userFacingMessage(for: error)))
        }
    }

    private func refreshDeferredEntitlement() async {
        guard activeTransactionOperations == 0, needsEntitlementRefresh else { return }
        // 刷新由另一调用者请求，不能继承已取消的购买或恢复任务的取消状态。
        await Task { @MainActor in
            // 排队期间可能有新交易开始或提交结果，必须在实际消费前重新判断。
            guard activeTransactionOperations == 0, needsEntitlementRefresh else { return }
            needsEntitlementRefresh = false
            // 当前操作已提交授权或拒绝时，不用旧的前台通知再次读取并覆盖它。
            guard authoritativeGeneration != operationGeneration else { return }
            await refreshEntitlement()
        }.value
    }

    var isBusy: Bool {
        activeTransactionOperations > 0 || status == .loading || status == .resolving
    }

    func managementPurchaseEvidence() async throws -> ManagedConnectionPurchaseEvidence {
        guard let currentGrant = usableCurrentGrant,
              let currentEvidence,
              currentEvidence.productID == currentGrant.entitlement.productID
        else {
            throw ManagedConnectionDeviceStoreError.subscriptionRequired
        }
        return ManagedConnectionPurchaseEvidence(
            transactionID: currentEvidence.transactionID,
            productID: currentEvidence.productID,
            signedAppTransaction: try await storeKit.signedAppTransaction(),
            signedTransaction: currentEvidence.signedTransaction
        )
    }

    private func beginOperation() -> Int {
        operationGeneration &+= 1
        return operationGeneration
    }

    private func isLatest(_ generation: Int) -> Bool {
        operationGeneration == generation
    }

    private func resolve(
        _ evidence: ManagedConnectionTransactionEvidence
    ) async throws -> ManagedConnectionEntitlementGrant {
        let signedAppTransaction = try await storeKit.signedAppTransaction()
        let grant = try await entitlementAPI.resolve(
            signedAppTransaction: signedAppTransaction,
            signedTransaction: evidence.signedTransaction
        )
        guard grant.entitlement.productID == evidence.productID,
              grant.entitlement.expiresAt > now(),
              grant.tokenExpiresAt > now()
        else {
            throw ManagedConnectionEntitlementAPIError.invalidResponse
        }
        return grant
    }

    private func userFacingMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty
        {
            return description
        }
        return L10n.text("ui.managed_subscription_network_error")
    }

    private func status(for error: Error) -> Status {
        guard let apiError = error as? ManagedConnectionEntitlementAPIError,
              case .rejected(let code) = apiError
        else {
            return .failed(userFacingMessage(for: error))
        }
        switch code {
        case "expired":
            return .expired
        case "revoked":
            return .revoked
        case "no_current_entitlement":
            return .available
        default:
            return .failed(userFacingMessage(for: error))
        }
    }

    private func isTerminalServerDecision(_ error: Error) -> Bool {
        guard let apiError = error as? ManagedConnectionEntitlementAPIError,
              case .rejected(let code) = apiError
        else {
            return false
        }
        return ["expired", "revoked", "no_current_entitlement"].contains(code)
    }

    private var usableCurrentGrant: ManagedConnectionEntitlementGrant? {
        guard let currentGrant,
              currentGrant.entitlement.expiresAt > now(),
              currentGrant.tokenExpiresAt > now()
        else {
            return nil
        }
        return currentGrant
    }

    private func restore(_ grant: ManagedConnectionEntitlementGrant?, otherwise status: Status) {
        if let grant, grant.entitlement.expiresAt > now(), grant.tokenExpiresAt > now() {
            currentGrant = grant
            self.status = .entitled(grant.entitlement)
        } else {
            currentGrant = nil
            self.status = status
        }
    }

    private func applyRefreshFailure(_ error: Error) {
        applyFailure(error, fallbackGrant: usableCurrentGrant)
    }

    private func applyFailure(
        _ error: Error,
        fallbackGrant: ManagedConnectionEntitlementGrant?
    ) {
        let failureStatus = status(for: error)
        switch failureStatus {
        case .available, .expired, .revoked:
            currentGrant = nil
            currentEvidence = nil
            authoritativeGeneration = operationGeneration
            status = failureStatus
        case .failed:
            if let apiError = error as? ManagedConnectionEntitlementAPIError,
               case .rejected(let code) = apiError,
               code == "unverified_transaction"
            {
                currentGrant = nil
                currentEvidence = nil
                authoritativeGeneration = operationGeneration
                status = failureStatus
            } else {
                restore(fallbackGrant, otherwise: failureStatus)
            }
        default:
            restore(fallbackGrant, otherwise: failureStatus)
        }
    }

    private func restoreAfterCancellation(
        _ grant: ManagedConnectionEntitlementGrant?,
        previousStatus: Status
    ) {
        if let grant {
            restore(grant, otherwise: .available)
            return
        }
        currentGrant = nil
        switch previousStatus {
        case .available, .pending, .expired, .revoked, .failed:
            status = previousStatus
        case .entitled(let entitlement) where entitlement.expiresAt > now():
            status = .entitled(entitlement)
        case .loading, .resolving, .entitled:
            status = .available
        }
    }
}
