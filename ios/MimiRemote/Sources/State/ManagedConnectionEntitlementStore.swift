import Foundation

struct ManagedConnectionPurchaseEvidence: Equatable, Sendable {
    let transactionID: UInt64
    let productID: String
    let signedAppTransaction: String
    let signedTransaction: String
}

/// 兑换码的文本解析：用户可能粘贴整段消息，也可能点链接打开 App（#949）。
enum ManagedRedemptionCode {
    /// 从任意文本里取出第一个兑换码，统一成 MIMI-XXXX-XXXX-XXXX-XXXX。
    static func extract(from text: String) -> String? {
        let pattern = "MIMI[-\\s]*((?:[0-9A-Z][-\\s]*){16})"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        let body = text[range].uppercased().filter { $0.isLetter || $0.isNumber }
        var groups: [String] = []
        var rest = Substring(body)
        while !rest.isEmpty {
            groups.append(String(rest.prefix(4)))
            rest = rest.dropFirst(4)
        }
        return "MIMI-" + groups.joined(separator: "-")
    }
}

/// `mimi://redeem?code=...`：网页上的「打开 App 兑换」按钮跳到这里。
struct ManagedRedemptionLink: Equatable {
    let code: String?

    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "mimi" || scheme == "mimiremote",
              url.host?.lowercased() == "redeem"
        else {
            return nil
        }
        let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "code" }?.value
        code = value.flatMap(ManagedRedemptionCode.extract(from:))
    }
}

@MainActor
final class ManagedConnectionEntitlementStore: ObservableObject {
    /// 从兑换链接进来后，工作台该带用户去哪一页。首次连接时工作台还不存在，所以先记下来。
    enum PendingRoute: Equatable {
        case connectComputer
        case redemption
    }

    enum RestoreResult: Equatable {
        case restored
        case noActiveSubscription
    }

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
    @Published private(set) var redemptionErrorMessage: String?
    @Published private(set) var pendingRoute: PendingRoute?
    private(set) var currentEvidence: ManagedConnectionTransactionEvidence?

    private let storeKit: any ManagedConnectionStoreKitClient
    private let entitlementAPI: any ManagedConnectionEntitlementAPIClient
    private let redemptionCodes: any ManagedConnectionRedemptionCodeStoring
    // Keychain 写入失败时兜底：服务端已接受这个码，本次运行仍要能续签和管理设备。
    private var unsavedRedemptionCode: String?
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
        redemptionCodes: any ManagedConnectionRedemptionCodeStoring = InMemoryManagedConnectionRedemptionCodeStore(),
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
        self.redemptionCodes = redemptionCodes
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
        let previousStatus = status
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
            if await fallBackToRedemption(
                after: error,
                evidence: evidence,
                generation: generation,
                previousGrant: previousGrant,
                previousStatus: previousStatus
            ) {
                return
            }
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
                    if await fallBackToRedemption(
                        after: error,
                        evidence: nil,
                        generation: generation,
                        previousGrant: previousGrant,
                        previousStatus: previousStatus
                    ) {
                        return
                    }
                    applyRefreshFailure(error)
                    return
                }
            }
        }

        // 真实订阅优先；没有订阅时才用保存的内测兑换码续签（#949）。
        if let code = savedRedemptionCode {
            await refreshRedemption(code: code, generation: generation, previousGrant: previousGrant, previousStatus: previousStatus)
            return
        }

        currentGrant = nil
        currentEvidence = nil
        authoritativeGeneration = generation
        status = .available
    }

    /// Apple 交易被判定失效只说明这笔交易不可用，不代表兑换码失效：结束交易后重新核对保存的码。
    /// 没有保存的码或不是明确的失效决定时返回 false，由调用方走原有失败处理。
    private func fallBackToRedemption(
        after error: Error,
        evidence: ManagedConnectionTransactionEvidence?,
        generation: Int,
        previousGrant: ManagedConnectionEntitlementGrant?,
        previousStatus: Status
    ) async -> Bool {
        guard isTerminalServerDecision(error), let code = savedRedemptionCode else { return false }
        if let evidence {
            await storeKit.finish(transactionID: evidence.transactionID)
        }
        guard isLatest(generation) else { return true }
        await refreshRedemption(
            code: code,
            generation: generation,
            previousGrant: previousGrant,
            previousStatus: previousStatus
        )
        return true
    }

    private func refreshRedemption(
        code: String,
        generation: Int,
        previousGrant: ManagedConnectionEntitlementGrant?,
        previousStatus: Status
    ) async {
        do {
            let grant = try await redeemedGrant(code: code)
            guard isLatest(generation) else { return }
            acceptRedemption(grant, generation: generation)
        } catch is CancellationError {
            guard isLatest(generation) else { return }
            restoreAfterCancellation(previousGrant, previousStatus: previousStatus)
        } catch {
            guard isLatest(generation) else { return }
            if Self.isInvalidRedemptionCode(error) {
                // 服务端已不认这个码，继续保存只会让每次刷新都失败。
                redemptionCodes.delete()
                unsavedRedemptionCode = nil
                currentGrant = nil
                currentEvidence = nil
                authoritativeGeneration = generation
                status = .available
            } else {
                applyRefreshFailure(error)
            }
        }
    }

    /// 输入兑换码开通内测权益。失败只显示错误，不改变已有状态；过期或撤销的提示也不会覆盖原有订阅。
    func redeem(code: String) async {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard activeTransactionOperations == 0, !trimmed.isEmpty else { return }
        await performRedemption(code: trimmed)
        await refreshDeferredEntitlement()
    }

    /// 点兑换链接：结果要带用户到对应页面，否则开通了也不知道下一步。
    func redeemFromLink(_ link: ManagedRedemptionLink) async {
        guard let code = link.code else {
            redemptionErrorMessage = L10n.text("ui.managed_redemption_invalid")
            pendingRoute = .redemption
            return
        }
        await redeem(code: code)
        pendingRoute = isRedemptionEntitlement ? .connectComputer : .redemption
    }

    func consumePendingRoute() -> PendingRoute? {
        defer { pendingRoute = nil }
        return pendingRoute
    }

    func setRedemptionError(_ message: String) {
        redemptionErrorMessage = message
    }

    private func performRedemption(code: String) async {
        activeTransactionOperations += 1
        defer { activeTransactionOperations -= 1 }
        let generation = beginOperation()
        let previousGrant = usableCurrentGrant
        let previousStatus = status
        redemptionErrorMessage = nil
        status = .resolving
        do {
            let grant = try await redeemedGrant(code: code)
            guard isLatest(generation) else { return }
            do {
                try redemptionCodes.save(code)
                unsavedRedemptionCode = nil
            } catch {
                // 保存失败只影响下次启动是否要重新输入，不能把服务端已接受的兑换判为失败。
                unsavedRedemptionCode = code
            }
            acceptRedemption(grant, generation: generation)
        } catch is CancellationError {
            guard isLatest(generation) else { return }
            restoreAfterCancellation(previousGrant, previousStatus: previousStatus)
        } catch {
            guard isLatest(generation) else { return }
            redemptionErrorMessage = redemptionMessage(for: error)
            restoreAfterCancellation(previousGrant, previousStatus: previousStatus)
        }
    }

    private func redeemedGrant(code: String) async throws -> ManagedConnectionEntitlementGrant {
        let grant = try await entitlementAPI.redeem(code: code)
        guard grant.entitlement.productID == ManagedConnectionProductID.betaRedemption,
              grant.entitlement.expiresAt > now(),
              grant.tokenExpiresAt > now()
        else {
            throw ManagedConnectionEntitlementAPIError.invalidResponse
        }
        return grant
    }

    private func acceptRedemption(_ grant: ManagedConnectionEntitlementGrant, generation: Int) {
        currentGrant = grant
        currentEvidence = nil
        redemptionErrorMessage = nil
        authoritativeGeneration = generation
        status = .entitled(grant.entitlement)
    }

    private static func isInvalidRedemptionCode(_ error: Error) -> Bool {
        guard let apiError = error as? ManagedConnectionEntitlementAPIError,
              case .rejected(let code) = apiError
        else {
            return false
        }
        return code == "invalid_redemption_code"
    }

    private func redemptionMessage(for error: Error) -> String {
        if let apiError = error as? ManagedConnectionEntitlementAPIError,
           case .rejected(let code) = apiError
        {
            switch code {
            case "expired":
                return L10n.text("ui.managed_redemption_expired")
            case "revoked":
                return L10n.text("ui.managed_redemption_revoked")
            default:
                break
            }
        }
        return userFacingMessage(for: error)
    }

    /// 当前权益来自兑换码时返回这个码，设备管理用它换取管理凭证。
    var managementRedemptionCode: String? {
        guard usableCurrentGrant?.entitlement.productID == ManagedConnectionProductID.betaRedemption else {
            return nil
        }
        return savedRedemptionCode
    }

    private var savedRedemptionCode: String? {
        unsavedRedemptionCode ?? redemptionCodes.load()
    }

    /// 过期或撤销时用兑换码的说法：内测用户没有买过订阅。
    var hasSavedRedemptionCode: Bool {
        savedRedemptionCode != nil
    }

    /// 权益来自内测兑换码时，订阅管理和购买入口没有意义。
    var isRedemptionEntitlement: Bool {
        guard case .entitled(let entitlement) = status else { return false }
        return entitlement.productID == ManagedConnectionProductID.betaRedemption
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
                    // 服务端确认授权后结束交易；明确的失效决定在错误分支处理。
                    await storeKit.finish(transactionID: evidence.transactionID)
                } catch is CancellationError {
                    guard isLatest(generation) else { return }
                    restoreAfterCancellation(previousGrant, previousStatus: previousStatus)
                } catch {
                    guard isLatest(generation) else { return }
                    if await fallBackToRedemption(
                        after: error,
                        evidence: evidence,
                        generation: generation,
                        previousGrant: previousGrant,
                        previousStatus: previousStatus
                    ) {
                        return
                    }
                    applyFailure(error, fallbackGrant: previousGrant)
                    if isTerminalServerDecision(error) {
                        // 旧交易已被服务端确认失效，必须结束，否则后续购买仍可能重放它。
                        await storeKit.finish(transactionID: evidence.transactionID)
                    }
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

    @discardableResult
    func restorePurchases() async -> RestoreResult? {
        guard activeTransactionOperations == 0 else { return nil }
        let result = await performRestore()
        let generation = operationGeneration
        let revision = stateRevision
        await refreshDeferredEntitlement()
        await refreshProducts()
        // 等待商品期间的新交易决定优先，不能再弹出旧的恢复结果。
        guard isLatest(generation), stateRevision == revision, !Task.isCancelled else { return nil }
        return result
    }

    private func performRestore() async -> RestoreResult? {
        activeTransactionOperations += 1
        defer { activeTransactionOperations -= 1 }
        let generation = beginOperation()
        let previousGrant = usableCurrentGrant
        let previousStatus = status
        status = .resolving
        do {
            // AppStore.sync 会弹出系统鉴权，只能由用户明确点击“恢复购买”触发。
            try await storeKit.syncPurchases()
            guard isLatest(generation) else { return nil }
            await refreshEntitlement(generation: generation)
            // 校验取消或失败时不能把保留的旧状态误当成本次恢复成功。
            guard isLatest(generation), authoritativeGeneration == generation,
                  !Task.isCancelled else { return nil }
            switch status {
            case .entitled:
                return .restored
            case .available, .expired, .revoked:
                return .noActiveSubscription
            default:
                return nil
            }
        } catch is CancellationError {
            guard isLatest(generation) else { return nil }
            restoreAfterCancellation(previousGrant, previousStatus: previousStatus)
        } catch {
            guard isLatest(generation) else { return nil }
            restore(previousGrant, otherwise: .failed(userFacingMessage(for: error)))
        }
        return nil
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
