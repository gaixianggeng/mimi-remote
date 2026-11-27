import Foundation

/// 跨运行时唯一会话身份键：避免同一主机下不同运行时（如 Codex/X 与 Claude/X）或跨主机同 ID 互相覆盖。
struct CanonicalSessionKey: Hashable, Sendable {
    let hostProfileID: String
    let installationID: String
    let runtimeProvider: String
    let sessionID: SessionID

    init(
        hostProfileID: String = "",
        installationID: String = "",
        runtimeProvider: String,
        sessionID: SessionID
    ) {
        self.hostProfileID = hostProfileID
        self.installationID = installationID
        self.runtimeProvider = CodexAppServerSessionRuntime.normalizedRuntimeProvider(runtimeProvider)
        self.sessionID = sessionID
    }

    init(hostScope: HostScope, runtimeProvider: String, sessionID: SessionID) {
        self.init(
            hostProfileID: hostScope.profileID,
            installationID: hostScope.installationID,
            runtimeProvider: runtimeProvider,
            sessionID: sessionID
        )
    }

    init(session: AgentSession, hostScope: HostScope? = nil) {
        self.init(
            hostProfileID: hostScope?.profileID ?? "",
            installationID: hostScope?.installationID ?? "",
            runtimeProvider: session.runtimeProvider ?? session.source,
            sessionID: session.id
        )
    }

    /// 跨运行时并列时间稳定打破顺序：codex(0) < claude(1) < agy(2) < deepseek(3) < 其他(4)。
    var runtimeTieRank: Int {
        Self.runtimeTieRank(for: runtimeProvider)
    }

    static func runtimeTieRank(for runtimeProvider: String) -> Int {
        switch CodexAppServerSessionRuntime.normalizedRuntimeProvider(runtimeProvider) {
        case "codex": return 0
        case "claude": return 1
        case "agy": return 2
        case "deepseek": return 3
        default: return 4
        }
    }

    var renderIdentifier: String {
        "\(runtimeProvider)::\(sessionID)"
    }
}

/// 网关 `thread/list` 页推进语义（Phase 1b 契约 + P1-3d 跨版本降级矩阵）。
enum SessionListPageDisposition: Equatable, Sendable {
    case advance
    case samePageRetry(reason: String?)
    /// Controlled Global 响应缺 `pageDisposition`：安全仅预览，不推进水位线、不判倒挂、不判可信耗尽、不撤权。
    case unverifiedGlobalDisposition
}

/// `thread/list` 顶层 `listMeta` 强类型白名单结构（schemaVersion == 1）。
struct SessionListMeta: Equatable, Sendable {
    let schemaVersion: Int
    let complete: Bool?
    let sources: [String]
    let degradedReason: String?
    let degradedSources: [String]
    let rawPageDisposition: String?
    let retryReason: String?

    init(
        schemaVersion: Int = 1,
        complete: Bool? = nil,
        sources: [String] = [],
        degradedReason: String? = nil,
        degradedSources: [String] = [],
        rawPageDisposition: String? = nil,
        retryReason: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.complete = complete
        self.sources = sources
        self.degradedReason = degradedReason
        self.degradedSources = degradedSources
        self.rawPageDisposition = rawPageDisposition
        self.retryReason = retryReason
    }

    init?(json: CodexAppServerJSONValue?) {
        guard let object = json?.objectValue else { return nil }
        let version: Int
        if let intVal = object["schemaVersion"]?.intValue {
            version = intVal
        } else if case let .double(doubleVal) = object["schemaVersion"],
                  doubleVal.isFinite,
                  doubleVal == floor(doubleVal) {
            version = Int(doubleVal)
        } else {
            return nil
        }
        guard version == 1 else { return nil }
        self.schemaVersion = version
        self.complete = object["complete"]?.boolValue
        self.sources = (object["sources"]?.arrayValue ?? []).compactMap(\.stringValue)
        self.degradedReason = object["degradedReason"]?.stringValue
        self.degradedSources = (object["degradedSources"]?.arrayValue ?? []).compactMap(\.stringValue)
        self.rawPageDisposition = object["pageDisposition"]?.stringValue
        self.retryReason = object["retryReason"]?.stringValue
    }

    /// 按查询模式解析页推进语义（P1-3d）：
    /// - Controlled Global 仅本页显式 `"advance"` 可推进水位；缺字段一律 `.unverifiedGlobalDisposition`；
    /// - Scoped 缺 `pageDisposition` 视为 `.advance`。
    static func resolvedDisposition(
        from listMeta: SessionListMeta?,
        isControlledGlobal: Bool
    ) -> SessionListPageDisposition {
        if let raw = listMeta?.rawPageDisposition?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            switch raw {
            case "advance":
                return .advance
            case "same_page_retry":
                return .samePageRetry(reason: listMeta?.retryReason)
            default:
                return isControlledGlobal ? .unverifiedGlobalDisposition : .advance
            }
        }
        return isControlledGlobal ? .unverifiedGlobalDisposition : .advance
    }

    /// 解析本页健康可信度：
    /// - Agy（`agy`）显式输出 `complete`：缺 `listMeta` 或缺 `complete` 判 `.unverifiedHealth`；`complete == false` 判 `.degraded`；
    /// - 其他运行时若存在 `complete == false` 同样判 `.degraded`；
    /// - Controlled Global 缺 `pageDisposition` 判 `.unverifiedGlobalDisposition`。
    static func resolvedIntegrity(
        from listMeta: SessionListMeta?,
        runtimeProvider: String,
        isControlledGlobal: Bool
    ) -> RuntimeSessionListIntegrity {
        let disposition = resolvedDisposition(from: listMeta, isControlledGlobal: isControlledGlobal)
        if case .unverifiedGlobalDisposition = disposition {
            return .unverifiedGlobalDisposition
        }
        if let listMeta, listMeta.complete == false {
            return .degraded(reason: listMeta.degradedReason ?? "partial_source_degraded")
        }
        let normalized = CodexAppServerSessionRuntime.normalizedRuntimeProvider(runtimeProvider)
        if normalized == "agy" {
            guard let listMeta, listMeta.complete == true else {
                return .unverifiedHealth
            }
        }
        return .trusted
    }
}

/// 单页响应健康完整度状态。
enum RuntimeSessionListIntegrity: Equatable, Sendable {
    case trusted
    case degraded(reason: String)
    case unverifiedHealth
    case unverifiedGlobalDisposition

    var isTrusted: Bool {
        self == .trusted
    }
}

/// 原始服务端排序证据（隔离本地 `recencyFloor` 与 Date 精度，区分秒/毫秒/不透明服务端序）。
enum RawSortEvidence: Equatable, Sendable {
    case epochMs(Int64)
    case missing
    case opaqueServerOrder
    case unverifiedUnit

    var epochMsValue: Int64? {
        if case let .epochMs(ms) = self { return ms }
        return nil
    }

    /// 从单条上游 JSON 对象解析原始排序时间戳证据。
    static func fromWireThread(
        _ object: [String: CodexAppServerJSONValue],
        runtimeProvider: String
    ) -> RawSortEvidence {
        let normalizedRuntime = CodexAppServerSessionRuntime.normalizedRuntimeProvider(runtimeProvider)
        let cliVersion = object["cliVersion"]?.stringValue ?? ""
        let isLegacyRustClaude = normalizedRuntime == "claude"
            && cliVersion.hasPrefix("alleycat-claude-bridge/")

        // Codex 若显式返回 recencyAt: null（无可用 recency 排序证据）且无其他有效时间字段，标记不透明序。
        let hasExplicitNullRecency = object["recencyAt"] == .null
        let primaryNumber = numericTimestamp(object["recencyAt"])
            ?? numericTimestamp(object["updatedAt"])
            ?? numericTimestamp(object["createdAt"])

        guard let rawNumber = primaryNumber else {
            return hasExplicitNullRecency ? .opaqueServerOrder : .missing
        }
        guard rawNumber.isFinite, rawNumber >= 0 else {
            return .unverifiedUnit
        }
        if rawNumber == 0 {
            return .missing
        }

        // DeepSeek（Harness Native）与 Rust Legacy Claude 使用毫秒时间戳；
        // Codex / Claude SDK / Antigravity 使用秒时间戳（兼容异常超大毫秒值的启发式防双重乘 1000）。
        if normalizedRuntime == "deepseek" || isLegacyRustClaude {
            return .epochMs(Int64(rawNumber.rounded()))
        }
        if rawNumber >= 100_000_000_000 {
            return .epochMs(Int64(rawNumber.rounded()))
        }
        return .epochMs(Int64((rawNumber * 1000.0).rounded()))
    }

    /// 从已解码的 `AgentSession` 回退构造排序证据（如 DeepSeek HTTP 或本地 Store 预览）。
    static func fromSession(_ session: AgentSession) -> RawSortEvidence {
        let date = session.recencyAt ?? session.updatedAt ?? session.createdAt
        guard let date else { return .missing }
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite, seconds > 0 else { return .missing }
        return .epochMs(Int64((seconds * 1000.0).rounded()))
    }

    private static func numericTimestamp(_ value: CodexAppServerJSONValue?) -> Double? {
        guard let value else { return nil }
        switch value {
        case let .int(intVal):
            return Double(intVal)
        case let .double(doubleVal):
            return doubleVal
        case let .string(raw):
            let strVal = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !strVal.isEmpty else { return nil }
            if let numeric = Double(strVal), numeric.isFinite {
                return numeric
            }
            if let iso = ISO8601DateFormatter().date(from: strVal) {
                return iso.timeIntervalSince1970
            }
            return nil
        default:
            return nil
        }
    }
}

/// 复用 `AgentSession.isSubagentThread` 语义的子会话归属证据（P1-2a / P1-2b）。
struct SubagentOwnershipEvidence: Equatable, Sendable {
    let isSubagentFlag: Bool
    let parentThreadID: String?

    init(isSubagentFlag: Bool = false, parentThreadID: String? = nil) {
        let trimmed = parentThreadID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedParent = (trimmed?.isEmpty == false) ? trimmed : nil
        self.parentThreadID = normalizedParent
        self.isSubagentFlag = isSubagentFlag || normalizedParent != nil
    }

    init(session: AgentSession) {
        let parent = session.parentThreadID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let contextParent = session.context?.parentThreadID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedParent = (parent?.isEmpty == false ? parent : nil)
            ?? (contextParent?.isEmpty == false ? contextParent : nil)
        self.init(
            isSubagentFlag: session.isSubagentThread,
            parentThreadID: resolvedParent
        )
    }

    var isSubagent: Bool {
        isSubagentFlag || parentThreadID != nil
    }

    func merged(with other: SubagentOwnershipEvidence?) -> SubagentOwnershipEvidence {
        guard let other else { return self }
        return SubagentOwnershipEvidence(
            isSubagentFlag: isSubagentFlag || other.isSubagentFlag,
            parentThreadID: parentThreadID ?? other.parentThreadID
        )
    }
}

/// 跨运行时会话列表 RPC 原子并发预算账本（P1-6b）：
/// 同一同步锁保护单路上限、总预算上限与最大并发度，确保 15/16 两路并发就绪最多再发 1 次。
final class SessionListRPCBudgetLedger: @unchecked Sendable {
    enum ReserveOutcome: Equatable, Sendable {
        case reserved
        case concurrencyLimitReached
        case perRuntimeLimitReached
        case totalBudgetExhausted
    }

    let maxPerRuntimeRPCs: Int
    let maxTotalRPCs: Int
    let maxConcurrentRPCs: Int

    private let lock = NSLock()
    private var totalRPCs = 0
    private var perRuntimeRPCs: [String: Int] = [:]
    private var inFlightCount = 0

    init(
        maxPerRuntimeRPCs: Int = 12,
        maxTotalRPCs: Int = 16,
        maxConcurrentRPCs: Int = 2
    ) {
        self.maxPerRuntimeRPCs = max(1, maxPerRuntimeRPCs)
        self.maxTotalRPCs = max(1, maxTotalRPCs)
        self.maxConcurrentRPCs = max(1, maxConcurrentRPCs)
    }

    func reserve(runtimeProvider: String) -> ReserveOutcome {
        let runtime = CodexAppServerSessionRuntime.normalizedRuntimeProvider(runtimeProvider)
        lock.lock()
        defer { lock.unlock() }
        if totalRPCs >= maxTotalRPCs {
            return .totalBudgetExhausted
        }
        if perRuntimeRPCs[runtime, default: 0] >= maxPerRuntimeRPCs {
            return .perRuntimeLimitReached
        }
        if inFlightCount >= maxConcurrentRPCs {
            return .concurrencyLimitReached
        }
        totalRPCs += 1
        perRuntimeRPCs[runtime, default: 0] += 1
        inFlightCount += 1
        return .reserved
    }

    func finish(runtimeProvider: String) {
        lock.lock()
        defer { lock.unlock() }
        if inFlightCount > 0 {
            inFlightCount -= 1
        }
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        totalRPCs = 0
        perRuntimeRPCs.removeAll()
        inFlightCount = 0
    }

    var snapshot: (total: Int, inFlight: Int, perRuntime: [String: Int]) {
        lock.lock()
        defer { lock.unlock() }
        return (totalRPCs, inFlightCount, perRuntimeRPCs)
    }

    var isTotalBudgetExhausted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return totalRPCs >= maxTotalRPCs
    }
}

/// 工作区会话列表浏览范围（M8）：与创建偏好 `WorkspaceSessionRuntimeChoice` 解耦。
enum WorkspaceSessionBrowseScope: Hashable, Sendable, Identifiable {
    case all
    case single(WorkspaceSessionRuntimeChoice)

    static let defaultShowAllRuntimesPreferenceKey = "workspace.defaultShowAllRuntimes"

    var id: String {
        switch self {
        case .all:
            return "all"
        case let .single(choice):
            return choice.rawValue
        }
    }

    var singleRuntimeChoice: WorkspaceSessionRuntimeChoice? {
        if case let .single(choice) = self { return choice }
        return nil
    }

    var isAll: Bool {
        self == .all
    }

    var listTitle: String {
        switch self {
        case .all:
            return L10n.text("ui.workspace_runtime_all")
        case let .single(choice):
            return choice.listTitle
        }
    }

    var listSubtitle: String {
        switch self {
        case .all:
            return L10n.text("ui.runtime_subtitle_all")
        case let .single(choice):
            return choice.listSubtitle
        }
    }
}

/// 合并视图全局完整度五态（M10）。
enum WorkspaceMergedCompleteness: Equatable, Sendable {
    case cachedPreview
    case allUnavailable
    case partial
    case complete
    case completeExhausted
}

/// 合并视图下的部分不可用/降级提示摘要。
struct WorkspaceMergedPartialNotice: Equatable, Sendable {
    let unavailableRuntimes: [WorkspaceSessionRuntimeChoice]
    let degradedRuntimes: [WorkspaceSessionRuntimeChoice]

    var isEmpty: Bool {
        unavailableRuntimes.isEmpty && degradedRuntimes.isEmpty
    }

    var localizedTitle: String {
        if !unavailableRuntimes.isEmpty && degradedRuntimes.isEmpty {
            return L10n.text("ui.workspace_merged_partial_unavailable_title")
        }
        return L10n.text("ui.workspace_merged_partial_degraded_title")
    }

    var localizedMessage: String {
        let names = (unavailableRuntimes + degradedRuntimes)
            .map(\.listTitle)
            .joined(separator: " / ")
        if !unavailableRuntimes.isEmpty && degradedRuntimes.isEmpty {
            return L10n.format("ui.workspace_merged_partial_unavailable_message", names)
        }
        return L10n.format("ui.workspace_merged_partial_degraded_message", names)
    }
}
