import Foundation
import os
import UserNotifications

extension SessionStore {
    func refreshSettingsAccountOverview() async {
        // Token 活动在 agentd 已有 12 小时快照，必须先发请求才能立即命中。
        // 模型目录和额度查询可能较慢，不能把低频活动快照排在它们之后。
        async let tokenActivity: Void = refreshAccountTokenUsage()

        await refreshAppServerModelOptions()
        await refreshCodexUsage()
        if hasClaudeRuntimeChannel {
            await refreshClaudeUsage()
        }
        await tokenActivity
    }

    func refreshAccountTokenUsage(forceRefresh: Bool = false) async {
        let hostScope = appStore.activeHostScope
        guard accountTokenUsageRefreshHostScope != hostScope else {
            return
        }

        accountTokenUsageRefreshHostScope = hostScope
        isRefreshingAccountTokenActivity = true
        // 只有手上没有可显示的历史时才进首屏加载态；已经有网格就保持原样、只让刷新按钮转，
        // 避免每次刷新都把网格闪成骨架。
        if accountTokenActivity.displayBuckets == nil {
            accountTokenActivity = .loading
        }
        defer {
            if accountTokenUsageRefreshHostScope == hostScope {
                accountTokenUsageRefreshHostScope = nil
                isRefreshingAccountTokenActivity = false
            }
        }

        guard !Task.isCancelled else { return }
        let fetch: AccountTokenUsageFetch
        do {
            fetch = try await clientFactory().refreshAccountTokenUsage(forceRefresh: forceRefresh)
        } catch is CancellationError {
            return
        } catch {
            fetch = .failed
        }
        guard !Task.isCancelled,
              appStore.activeHostScope == hostScope,
              accountTokenUsageRefreshHostScope == hostScope
        else {
            return
        }

        switch fetch {
        case .snapshot(let snapshot):
            accountTokenUsage = snapshot
            // summary 可用不代表日粒度历史可用；nil bucket 归一成 unsupported，
            // 同时仍保留 lifetimeTokens 供卡片展示。
            accountTokenActivity = .resolved(buckets: snapshot.dailyUsageBuckets, asOf: Date())
        case .unsupported:
            accountTokenActivity = .unsupported
        case .failed:
            // 保留上一次成功的结果，让展示层能画出旧网格并标注它是旧的。
            accountTokenActivity = .failed(previous: accountTokenActivity.lastSuccessful)
        }
    }
}

// SessionStore 的持久化、队列、提醒和历史预算辅助类型，不构成公开 API。
struct QueuedCommandActionRun: Equatable {
    let path: String
    let id: String
    let confirmed: Bool
}

struct HistoryFirstPageRequestKey: Hashable {
    let profileID: String
    let sessionID: SessionID
    let limit: Int
    let loadMode: HistoryMessagesPage.LoadMode
}

struct SessionListFirstPageRequestKey: Hashable {
    let profileID: String
    let connectionGeneration: Int
    let workspaceID: String
    let workspacePath: String
    let limit: Int
    let consistency: SessionListConsistency
    /// nil 表示真正首屏；非 nil 表示权威展示窗口从已提交边界续跑。
    let cursor: String?
}

/// “已经有几条缓存”与“当前主机代次已完成精确首屏”是两个状态。
/// key 必须包含完整 HostScope 和 canonical workspace path，避免切换 Mac、重连或目录身份迁移后误复用旧结论。
struct WorkspaceSessionFirstPageKey: Hashable {
    let hostScope: HostScope
    let workspaceID: String
    let workspacePath: String
}

struct WorkspaceSessionFirstPageCompletion: Equatable {
    let consistency: SessionListConsistency
    let isPresentationWindowComplete: Bool
    /// 权威展示窗口达到单批预算但仍欠填时，保存下一批唯一允许继续的 opaque cursor。
    let continuationCursor: String?
    /// 仅记录当前权威 cursor 链实际扫描过的有序 ID；不能用整个工作区缓存冒充权威种子。
    let scannedSessionIDs: [SessionID]
    let completedAt: Date
}

struct SessionListFirstPageResult {
    let page: SessionsPage
    let requestedCursor: String?
}

enum SessionListRequestSource: String {
    case bootstrap
    case libraryIndex
    case restore
    case selectedProject
    case workspaceForeground
    case workspaceLoadMore
}

enum SessionListRequestDelivery: String {
    case cache
    case largerInFlight
    case network
    case sharedInFlight
    case staleCache
}

enum SessionListDiagnostics {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.gaixianggeng.mimi",
        category: "SessionList"
    )

    static func completed(
        source: SessionListRequestSource,
        consistency: SessionListConsistency,
        delivery: SessionListRequestDelivery,
        count: Int,
        duration: TimeInterval
    ) {
        let consistencyName = consistency == .authoritative ? "authoritative" : "fastIndexed"
        let durationMilliseconds = max(0, Int((duration * 1_000).rounded()))
        // 只记录固定枚举和计数，不写 workspace path、标题或任何用户内容。
        logger.info(
            "source=\(source.rawValue, privacy: .public) page=1 consistency=\(consistencyName, privacy: .public) delivery=\(delivery.rawValue, privacy: .public) count=\(count) duration_ms=\(durationMilliseconds)"
        )
    }

    static func presentationWindowCompleted(
        source: SessionListRequestSource,
        consistency: SessionListConsistency,
        rawCount: Int,
        listableCount: Int,
        pagesScanned: Int,
        hasMore: Bool
    ) {
        let consistencyName = consistency == .authoritative ? "authoritative" : "fastIndexed"
        // 这里只记录分页形态，不记录 workspace、标题、session ID 或任何用户内容。
        logger.info(
            "source=\(source.rawValue, privacy: .public) presentation_fill consistency=\(consistencyName, privacy: .public) raw_count=\(rawCount) listable_count=\(listableCount) pages_scanned=\(pagesScanned) has_more=\(hasMore)"
        )
    }
}

struct SessionListBudgetKey: Hashable {
    let profileID: String
    let connectionGeneration: Int
    let cwd: String
}

struct SessionListFirstPageInFlight {
    let id: UUID
    let task: Task<SessionsPage, Error>
}

struct SessionListFirstPageCacheEntry {
    let page: SessionsPage
    let loadedAt: Date
}

struct SessionLibraryIndexRefreshJob {
    let id: UUID
    let hostScope: HostScope
    let authoritative: Bool
    let task: Task<Void, Never>
}

struct HistoryFirstPageInFlight {
    let token: Int
    let task: Task<HistoryMessagesPage, Error>
}

struct HistoryFirstPageCacheEntry {
    let page: HistoryMessagesPage
    let loadedAt: Date
    let token: Int
}

struct HistoryFirstPageResult {
    let page: HistoryMessagesPage
    let token: Int
}

struct HistoryFirstPageFetchFailure: LocalizedError {
    let underlying: Error
    let token: Int

    var errorDescription: String? {
        underlying.localizedDescription
    }
}

struct HistoryPolicyFailure: Equatable {
    let reason: String?
    let method: String?
    let retryAfterNanoseconds: UInt64?
    let retryAfterSeconds: Int?
    /// gateway 阻断的完整响应体量与 cap（history_response_too_large 时非空），
    /// 用于向用户展示“完整历史约 9.3 MB，超过 5.0 MB 上限”这类结构化量级。
    let responseBytes: Int?
    let maxResponseBytes: Int?
    let itemsView: String?

    init(
        reason: String?,
        method: String? = nil,
        retryAfterNanoseconds: UInt64?,
        retryAfterSeconds: Int?,
        responseBytes: Int? = nil,
        maxResponseBytes: Int? = nil,
        itemsView: String? = nil
    ) {
        self.reason = reason
        self.method = method
        self.retryAfterNanoseconds = retryAfterNanoseconds
        self.retryAfterSeconds = retryAfterSeconds
        self.responseBytes = responseBytes
        self.maxResponseBytes = maxResponseBytes
        self.itemsView = itemsView
    }
}

struct SessionListPolicyFailure: Equatable {
    let retryAfterNanoseconds: UInt64
    let retryAfterSeconds: Int
}

enum HistoryFirstPageCachePolicy: Equatable {
    case reuseRecent
    case bypass
}

enum HistoryLoadReason: Equatable {
    case automatic
    case authoritativeReopen
    case manualFull
    case summaryChoice
    case writerRetry
}

enum HistoryLoadQuality: Equatable {
    case full
    case summary
}

struct HistoryLoadSignature: Equatable {
    let updatedAt: Date?
    let revision: ModelRevision?
    let lastSeq: EventSequence?

    init(session: AgentSession) {
        self.updatedAt = session.updatedAt
        self.revision = session.revision
        self.lastSeq = session.lastSeq
    }
}

// 会话首屏历史按 session 维度复用，而不是按选中动作复用。
// 用户来回切会话、前台恢复、手动刷新可能同时触发 before=nil 请求；
// 这里保留一轮加载的 task 和 session 快照，用来避免同一个大 session 反复请求。
struct HistoryLoadJob {
    let token: Int
    let sessionSignature: HistoryLoadSignature
    let loadMode: HistoryMessagesPage.LoadMode
    /// 恢复代次要求 bypass 时，不能加入一个更早创建的 reuseRecent job。
    let cachePolicy: HistoryFirstPageCachePolicy
    /// 非 nil 表示此 job 属于一次明确的前台/网络恢复代次。
    let recoveryGeneration: UInt64?
    let allowPolicyRetry: Bool
    /// full 自适应缩页时本次尝试使用的 turn 页大小；nil 表示默认首屏（等价 ladder 顶端）。
    /// 供 history_response_too_large 回退时决定下一级更小的 full 页。
    let fullTurnPageLimit: Int?
    let task: Task<HistoryFirstPageResult, Error>
    /// 与 foreground reporting 解耦：quiet 会话也可能需要在现有消息尾部显示轻量进度。
    /// 同一 job 被可见 waiter 加入后会提升为 true，并沿策略重试链传给替代 job。
    var showsProgress: Bool
    var requiresForegroundReporting: Bool
    var foregroundSuccessStatusMessage: String?
    var foregroundSelectionLease: SessionSelectionLease?
}

struct ProjectSessionListSnapshot: Equatable {
    let projectID: String
    let isExpanded: Bool
    let isShowingAll: Bool
    let visibleSessions: [AgentSession]
    let allSessionCount: Int
    let hiddenCount: Int
    let canLoadMore: Bool
    let isLoadingMore: Bool
    let hasCollapsedPreview: Bool

    var isEmpty: Bool {
        allSessionCount == 0
    }

    var shouldShowActionRow: Bool {
        hiddenCount > 0 || canLoadMore || isShowingAll && hasCollapsedPreview
    }

    var actionTitle: String {
        if isLoadingMore {
            return L10n.text("ui.loading_514c33af")
        }
        if isShowingAll && visibleSessions.count >= allSessionCount && !canLoadMore {
            return L10n.text("ui.show_less")
        }
        return L10n.text("ui.show_more")
    }
}

struct SessionListPreferences: Codable, Equatable {
    var pinnedSessionIDs: Set<SessionID> = []
    var archivedSessionIDs: Set<SessionID> = []
    var sessionWorkspaceIDs: Set<String>? = nil
}

/// V2 持久化同时保留只读的 endpoint 旧数据与新的 Profile 命名空间。
///
/// 旧键不会在本版本删除；迁移成功后用 endpoint marker 保证只复制一次，删除 Profile 后也不会
/// 因重新添加同地址的另一台 Mac 而把旧数据复活。
struct ProfileScopedStorage<Value: Codable>: Codable {
    var byEndpoint: [String: Value] = [:]
    var byProfileID: [String: Value] = [:]
    var migratedLegacyEndpoints: Set<String> = []

    private enum CodingKeys: String, CodingKey {
        case byEndpoint
        case byProfileID
        case migratedLegacyEndpoints
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        byEndpoint = try container.decodeIfPresent([String: Value].self, forKey: .byEndpoint) ?? [:]
        byProfileID = try container.decodeIfPresent([String: Value].self, forKey: .byProfileID) ?? [:]
        migratedLegacyEndpoints = try container.decodeIfPresent(
            Set<String>.self,
            forKey: .migratedLegacyEndpoints
        ) ?? []
    }

    mutating func migrateLegacyValueIfUnique(
        profileID: String,
        endpoint: String,
        profiles: [ConnectionProfile]
    ) -> Bool {
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID),
              byProfileID[profileKey] == nil
        else {
            return false
        }
        let endpointKey = AgentAPIClient.normalizedEndpoint(endpoint)
        guard !migratedLegacyEndpoints.contains(endpointKey),
              ProfileScopedPersistence.isUniqueEndpointMatch(
                  profileID: profileKey,
                  normalizedEndpoint: endpointKey,
                  profiles: profiles
              ),
              let legacyValue = byEndpoint[endpointKey]
        else {
            return false
        }

        byProfileID[profileKey] = legacyValue
        migratedLegacyEndpoints.insert(endpointKey)
        return true
    }
}

enum ProfileScopedPersistence {
    static func normalizedProfileID(_ profileID: String) -> String? {
        let normalized = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    static func isUniqueEndpointMatch(
        profileID: String,
        normalizedEndpoint: String,
        profiles: [ConnectionProfile]
    ) -> Bool {
        let matches = profiles.filter {
            AgentAPIClient.normalizedEndpoint($0.endpoint) == normalizedEndpoint
        }
        return matches.count == 1 && matches[0].id == profileID
    }
}

/// 历史会话的“完成版本”只使用服务端会话快照里稳定、可跨刷新恢复的水位。
///
/// 比较时优先使用双方都具备的最高等级信号，而不是把所有字段拼成哈希：
/// app-server 的轻量列表和实时事件携带字段不同，同一次完成在后续补齐 recencyAt / revision
/// 时仍应视为同一版本；排序、分页和重连本身不会改变这些值。
struct SessionCompletionVersion: Codable, Equatable {
    var turnID: TurnID?
    var recencyAt: Date?
    var revision: ModelRevision?
    var lastSeq: EventSequence?
    var updatedAt: Date?

    init(session: AgentSession, completedTurnID: TurnID? = nil) {
        turnID = Self.normalizedID(completedTurnID)
        recencyAt = session.recencyAt
        revision = session.revision.flatMap { $0 > 0 ? $0 : nil }
        lastSeq = session.lastSeq.flatMap { $0 > 0 ? $0 : nil }
        updatedAt = session.updatedAt
    }

    var hasStableSignal: Bool {
        turnID != nil || recencyAt != nil || revision != nil || lastSeq != nil || updatedAt != nil
    }

    func representsSameCompletion(as other: SessionCompletionVersion) -> Bool {
        if let turnID, let otherTurnID = other.turnID {
            return turnID == otherTurnID
        }
        if let recencyAt, let otherRecencyAt = other.recencyAt {
            return recencyAt == otherRecencyAt
        }
        if let revision, let otherRevision = other.revision {
            return revision == otherRevision
        }
        if let lastSeq, let otherLastSeq = other.lastSeq {
            return lastSeq == otherLastSeq
        }
        if let updatedAt, let otherUpdatedAt = other.updatedAt {
            return updatedAt == otherUpdatedAt
        }
        return false
    }

    /// 同一次完成从实时态过渡到完整列表快照时，把新出现的稳定字段并入同一水位。
    func merging(_ other: SessionCompletionVersion) -> SessionCompletionVersion {
        SessionCompletionVersion(
            turnID: other.turnID ?? turnID,
            recencyAt: other.recencyAt ?? recencyAt,
            revision: other.revision ?? revision,
            lastSeq: other.lastSeq ?? lastSeq,
            updatedAt: other.updatedAt ?? updatedAt
        )
    }

    private init(
        turnID: TurnID?,
        recencyAt: Date?,
        revision: ModelRevision?,
        lastSeq: EventSequence?,
        updatedAt: Date?
    ) {
        self.turnID = turnID
        self.recencyAt = recencyAt
        self.revision = revision
        self.lastSeq = lastSeq
        self.updatedAt = updatedAt
    }

    private static func normalizedID(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized?.isEmpty == false ? normalized : nil
    }
}

struct SessionHistoryReadState: Codable, Equatable {
    var latestCompletion: SessionCompletionVersion?
    var readCompletion: SessionCompletionVersion?
    /// 区分用户显式“标为未读”和新完成自然产生的未读，避免选中态同步把前者覆盖。
    var manualUnreadCompletion: SessionCompletionVersion?
    /// Mimi 首次确认当前完成版本进入终态的本地时间。它不表示跨 App 已读状态，
    /// 只让“刚完成”在重启后仍能维持一个短而稳定的展示窗口。
    var completionObservedAt: Date?
    var observedRunning = false
    var pendingTurnID: TurnID?

    var isUnread: Bool {
        guard let latestCompletion else {
            return false
        }
        if manualUnreadCompletion?.representsSameCompletion(as: latestCompletion) == true {
            return true
        }
        guard let readCompletion else {
            return true
        }
        return !readCompletion.representsSameCompletion(as: latestCompletion)
    }
}

/// 已读水位按连接 Profile 隔离，避免不同 Mac 上碰巧相同的 thread ID 串读。
/// UserDefaults 只保存每个会话的几个标量水位，不引入数据库或服务端协议。
struct SessionHistoryReadStateStore {
    typealias Storage = ProfileScopedStorage<[SessionID: SessionHistoryReadState]>

    let defaults: UserDefaults
    let key: String

    init(defaults: UserDefaults = .standard, key: String = "agentd.sessionHistoryReadStates") {
        self.defaults = defaults
        self.key = key
    }

    func load(
        profileID: String,
        legacyEndpoint: String,
        profiles: [ConnectionProfile]
    ) -> [SessionID: SessionHistoryReadState] {
        var storage = storage()
        let didMigrate = storage.migrateLegacyValueIfUnique(
            profileID: profileID,
            endpoint: legacyEndpoint,
            profiles: profiles
        )
        if didMigrate {
            persist(storage)
        }
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) else {
            return profiles.isEmpty
                ? storage.byEndpoint[AgentAPIClient.normalizedEndpoint(legacyEndpoint)] ?? [:]
                : [:]
        }
        if let value = storage.byProfileID[profileKey] {
            return value
        }
        if profiles.isEmpty {
            return storage.byEndpoint[AgentAPIClient.normalizedEndpoint(legacyEndpoint)] ?? [:]
        }
        return [:]
    }

    func save(_ states: [SessionID: SessionHistoryReadState], profileID: String) {
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) else {
            return
        }
        var storage = storage()
        storage.byProfileID[profileKey] = states
        persist(storage)
    }

    func remove(profileID: String) {
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) else {
            return
        }
        var storage = storage()
        guard storage.byProfileID.removeValue(forKey: profileKey) != nil else {
            return
        }
        persist(storage)
    }

    private func storage() -> Storage {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(Storage.self, from: data)
        else {
            return Storage()
        }
        return decoded
    }

    private func persist(_ storage: Storage) {
        guard let data = try? JSONEncoder().encode(storage) else {
            return
        }
        defaults.set(data, forKey: key)
    }
}

struct SessionListPreferenceStore {
    typealias Storage = ProfileScopedStorage<SessionListPreferences>

    let defaults: UserDefaults
    let key: String

    init(defaults: UserDefaults = .standard, key: String = "agentd.sessionListPreferences") {
        self.defaults = defaults
        self.key = key
    }

    func load(endpoint: String) -> SessionListPreferences {
        storage().byEndpoint[normalizedEndpoint(endpoint)] ?? SessionListPreferences()
    }

    func save(_ preferences: SessionListPreferences, endpoint: String) {
        var storage = storage()
        storage.byEndpoint[normalizedEndpoint(endpoint)] = preferences
        persist(storage)
    }

    func load(
        profileID: String,
        legacyEndpoint: String,
        profiles: [ConnectionProfile]
    ) -> SessionListPreferences {
        var storage = storage()
        let didMigrate = storage.migrateLegacyValueIfUnique(
            profileID: profileID,
            endpoint: legacyEndpoint,
            profiles: profiles
        )
        if didMigrate {
            persist(storage)
        }
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) else {
            return SessionListPreferences()
        }
        if let value = storage.byProfileID[profileKey] {
            return value
        }
        // 无 Profile 的 legacy/debug 单连接只读旧值，不把“0 个匹配”伪装成正式迁移。
        if profiles.isEmpty {
            return storage.byEndpoint[normalizedEndpoint(legacyEndpoint)] ?? SessionListPreferences()
        }
        return SessionListPreferences()
    }

    func load(profileID: String) -> SessionListPreferences {
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) else {
            return SessionListPreferences()
        }
        return storage().byProfileID[profileKey] ?? SessionListPreferences()
    }

    func save(_ preferences: SessionListPreferences, profileID: String) {
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) else {
            return
        }
        var storage = storage()
        storage.byProfileID[profileKey] = preferences
        persist(storage)
    }

    func remove(profileID: String) {
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) else {
            return
        }
        var storage = storage()
        guard storage.byProfileID.removeValue(forKey: profileKey) != nil else {
            return
        }
        persist(storage)
    }

    func storage() -> Storage {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(Storage.self, from: data)
        else {
            return Storage()
        }
        return decoded
    }

    func persist(_ storage: Storage) {
        guard let data = try? JSONEncoder().encode(storage) else {
            return
        }
        defaults.set(data, forKey: key)
    }

    func normalizedEndpoint(_ endpoint: String) -> String {
        AgentAPIClient.normalizedEndpoint(endpoint)
    }
}

enum SessionControlState: String, Codable, Equatable {
    case ipadOwned
    case takenOver
    case observing

    var isControllable: Bool {
        self == .ipadOwned || self == .takenOver
    }
}

struct SessionControlStateStore {
    typealias Storage = ProfileScopedStorage<[SessionID: SessionControlState]>

    let defaults: UserDefaults
    let key: String

    init(defaults: UserDefaults = .standard, key: String = "agentd.sessionControlStates") {
        self.defaults = defaults
        self.key = key
    }

    func load(endpoint: String) -> [SessionID: SessionControlState] {
        storage().byEndpoint[normalizedEndpoint(endpoint)] ?? [:]
    }

    func save(_ states: [SessionID: SessionControlState], endpoint: String) {
        var storage = storage()
        storage.byEndpoint[normalizedEndpoint(endpoint)] = states
        persist(storage)
    }

    func load(
        profileID: String,
        legacyEndpoint: String,
        profiles: [ConnectionProfile]
    ) -> [SessionID: SessionControlState] {
        var storage = storage()
        let didMigrate = storage.migrateLegacyValueIfUnique(
            profileID: profileID,
            endpoint: legacyEndpoint,
            profiles: profiles
        )
        if didMigrate {
            persist(storage)
        }
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) else {
            return [:]
        }
        if let value = storage.byProfileID[profileKey] {
            return value
        }
        if profiles.isEmpty {
            return storage.byEndpoint[normalizedEndpoint(legacyEndpoint)] ?? [:]
        }
        return [:]
    }

    func load(profileID: String) -> [SessionID: SessionControlState] {
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) else {
            return [:]
        }
        return storage().byProfileID[profileKey] ?? [:]
    }

    func save(_ states: [SessionID: SessionControlState], profileID: String) {
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) else {
            return
        }
        var storage = storage()
        storage.byProfileID[profileKey] = states
        persist(storage)
    }

    func remove(profileID: String) {
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) else {
            return
        }
        var storage = storage()
        guard storage.byProfileID.removeValue(forKey: profileKey) != nil else {
            return
        }
        persist(storage)
    }

    func storage() -> Storage {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(Storage.self, from: data)
        else {
            return Storage()
        }
        return decoded
    }

    func persist(_ storage: Storage) {
        guard let data = try? JSONEncoder().encode(storage) else {
            return
        }
        defaults.set(data, forKey: key)
    }

    func normalizedEndpoint(_ endpoint: String) -> String {
        AgentAPIClient.normalizedEndpoint(endpoint)
    }
}

struct SessionReminder: Codable, Equatable, Identifiable {
    let sessionID: SessionID
    var title: String
    var fireAt: Date
    var createdAt: Date

    var id: SessionID { sessionID }

    func isDue(now: Date = Date()) -> Bool {
        fireAt <= now
    }
}

struct SessionRuntimeNotification: Equatable {
    enum Kind: String {
        case approval
        case completed
        case failed
    }

    let id: String
    let sessionID: SessionID
    let title: String
    let body: String
    let kind: Kind
}

struct SessionReminderStore {
    typealias Storage = ProfileScopedStorage<[SessionID: SessionReminder]>

    let defaults: UserDefaults
    let key: String

    init(defaults: UserDefaults = .standard, key: String = "agentd.sessionReminders") {
        self.defaults = defaults
        self.key = key
    }

    func load(endpoint: String) -> [SessionID: SessionReminder] {
        storage().byEndpoint[normalizedEndpoint(endpoint)] ?? [:]
    }

    func save(_ reminders: [SessionID: SessionReminder], endpoint: String) {
        var storage = storage()
        storage.byEndpoint[normalizedEndpoint(endpoint)] = reminders
        persist(storage)
    }

    func load(
        profileID: String,
        legacyEndpoint: String,
        profiles: [ConnectionProfile]
    ) -> [SessionID: SessionReminder] {
        var storage = storage()
        let didMigrate = storage.migrateLegacyValueIfUnique(
            profileID: profileID,
            endpoint: legacyEndpoint,
            profiles: profiles
        )
        if didMigrate {
            persist(storage)
        }
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) else {
            return [:]
        }
        if let value = storage.byProfileID[profileKey] {
            return value
        }
        if profiles.isEmpty {
            return storage.byEndpoint[normalizedEndpoint(legacyEndpoint)] ?? [:]
        }
        return [:]
    }

    func load(profileID: String) -> [SessionID: SessionReminder] {
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) else {
            return [:]
        }
        return storage().byProfileID[profileKey] ?? [:]
    }

    func save(_ reminders: [SessionID: SessionReminder], profileID: String) {
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) else {
            return
        }
        var storage = storage()
        storage.byProfileID[profileKey] = reminders
        persist(storage)
    }

    func remove(profileID: String) {
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) else {
            return
        }
        var storage = storage()
        guard storage.byProfileID.removeValue(forKey: profileKey) != nil else {
            return
        }
        persist(storage)
    }

    func storage() -> Storage {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(Storage.self, from: data)
        else {
            return Storage()
        }
        return decoded
    }

    func persist(_ storage: Storage) {
        guard let data = try? JSONEncoder().encode(storage) else {
            return
        }
        defaults.set(data, forKey: key)
    }

    func normalizedEndpoint(_ endpoint: String) -> String {
        AgentAPIClient.normalizedEndpoint(endpoint)
    }
}

struct HistorySavingsNotice: Equatable {
    enum Kind: Equatable {
        case loadingFull
        case fullFailed
        case loadingSummary
        case summaryLoaded
        case summaryFailed
    }

    let sessionID: SessionID
    let kind: Kind
    let message: String
}

struct HistorySavingsNoticeStore {
    struct Storage: Codable {
        var dismissedEndpoints: Set<String> = []
    }

    let defaults: UserDefaults
    let key: String

    init(defaults: UserDefaults = .standard, key: String = "agentd.historySavingsNotice") {
        self.defaults = defaults
        self.key = key
    }

    func loadDismissedEndpoints() -> Set<String> {
        storage().dismissedEndpoints
    }

    func dismiss(endpoint: String) -> Set<String> {
        var storage = storage()
        storage.dismissedEndpoints.insert(normalizedEndpoint(endpoint))
        persist(storage)
        return storage.dismissedEndpoints
    }

    func storage() -> Storage {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(Storage.self, from: data)
        else {
            return Storage()
        }
        return decoded
    }

    func persist(_ storage: Storage) {
        guard let data = try? JSONEncoder().encode(storage) else {
            return
        }
        defaults.set(data, forKey: key)
    }

    func normalizedEndpoint(_ endpoint: String) -> String {
        AgentAPIClient.normalizedEndpoint(endpoint)
    }
}

enum SessionReminderScheduleOutcome: Equatable {
    case scheduled
    case permissionDenied
}

protocol SessionReminderScheduling {
    func schedule(
        _ reminder: SessionReminder,
        route: SessionNotificationRoute
    ) async throws -> SessionReminderScheduleOutcome
    func notify(
        _ notification: SessionRuntimeNotification,
        route: SessionNotificationRoute
    ) async throws
    func cancel(sessionID: SessionID, profileID: String)
    func cancel(profileID: String)
}

struct UserNotificationSessionReminderScheduler: SessionReminderScheduling {
    static let runtimeNotificationIDPrefix = "mimi.sessionRuntime."

    let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func schedule(
        _ reminder: SessionReminder,
        route: SessionNotificationRoute
    ) async throws -> SessionReminderScheduleOutcome {
        let granted = try await requestAuthorizationIfNeeded()
        guard granted else {
            return .permissionDenied
        }

        let content = UNMutableNotificationContent()
        content.title = L10n.text("ui.session_reminder")
        content.body = reminder.title
        content.sound = .default
        content.userInfo = route.userInfo

        let interval = max(reminder.fireAt.timeIntervalSinceNow, 1)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let notificationID = Self.notificationID(
            profileID: route.profileID,
            sessionID: reminder.sessionID
        )
        let request = UNNotificationRequest(
            identifier: notificationID,
            content: content,
            trigger: trigger
        )
        center.removePendingNotificationRequests(withIdentifiers: [notificationID])
        try await add(request)
        return .scheduled
    }

    func notify(
        _ notification: SessionRuntimeNotification,
        route: SessionNotificationRoute
    ) async throws {
        let granted = try await requestAuthorizationIfNeeded()
        guard granted else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.userInfo = route.userInfo

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let notificationID = Self.runtimeNotificationID(
            profileID: route.profileID,
            id: notification.id
        )
        let request = UNNotificationRequest(
            identifier: notificationID,
            content: content,
            trigger: trigger
        )
        center.removePendingNotificationRequests(withIdentifiers: [notificationID])
        try await add(request)
    }

    func cancel(sessionID: SessionID, profileID: String) {
        let identifier = Self.notificationID(profileID: profileID, sessionID: sessionID)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    func cancel(profileID: String) {
        let profilePrefix = Self.profileNotificationPrefix(profileID)
        let reminderPrefix = "mimi.sessionReminder.\(profilePrefix)"
        let runtimePrefix = "\(Self.runtimeNotificationIDPrefix)\(profilePrefix)"
        let belongsToProfile: (String) -> Bool = {
            $0.hasPrefix(reminderPrefix) || $0.hasPrefix(runtimePrefix)
        }
        center.getPendingNotificationRequests { requests in
            let identifiers = requests.map(\.identifier).filter(belongsToProfile)
            guard !identifiers.isEmpty else { return }
            center.removePendingNotificationRequests(withIdentifiers: identifiers)
        }
        center.getDeliveredNotifications { notifications in
            let identifiers = notifications.map(\.request.identifier).filter(belongsToProfile)
            guard !identifiers.isEmpty else { return }
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
    }

    func requestAuthorizationIfNeeded() async throws -> Bool {
        let settings = await notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            return try await requestAuthorization()
        @unknown default:
            return false
        }
    }

    func notificationSettings() async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    static func notificationID(profileID: String, sessionID: SessionID) -> String {
        "mimi.sessionReminder.\(profileNotificationPrefix(profileID))\(sessionID)"
    }

    static func runtimeNotificationID(profileID: String, id: String) -> String {
        "\(runtimeNotificationIDPrefix)\(profileNotificationPrefix(profileID))\(id)"
    }

    static func isRuntimeNotificationID(_ identifier: String) -> Bool {
        identifier.hasPrefix(runtimeNotificationIDPrefix)
    }

    private static func profileNotificationPrefix(_ profileID: String) -> String {
        "\(profileID.utf8.count):\(profileID):"
    }
}

struct NoopSessionReminderScheduler: SessionReminderScheduling {
    func schedule(
        _ reminder: SessionReminder,
        route: SessionNotificationRoute
    ) async throws -> SessionReminderScheduleOutcome { .scheduled }
    func notify(
        _ notification: SessionRuntimeNotification,
        route: SessionNotificationRoute
    ) async throws {}
    func cancel(sessionID: SessionID, profileID: String) {}
    func cancel(profileID: String) {}
}

enum FilePreviewStoreError: LocalizedError {
    case invalidPayload

    var errorDescription: String? {
        switch self {
        case .invalidPayload:
            return L10n.text("ui.file_preview_content_is_invalid")
        }
    }
}

enum WorktreeCleanupSelectionError: LocalizedError, Equatable {
    case emptySelection
    case containsBlockedPath
    case missingPlan

    var errorDescription: String? {
        switch self {
        case .emptySelection:
            return L10n.text("ui.please_select_at_least_one_worktree_that_can")
        case .containsBlockedPath:
            return L10n.text("ui.the_cleanup_selection_is_expired_or_contains_a")
        case .missingPlan:
            return L10n.text("ui.clean_preview_is_missing_plan_id_please_regenerate")
        }
    }
}

enum WorkspaceSessionRefreshError: LocalizedError, Equatable {
    case workspaceUnavailable

    var errorDescription: String? {
        switch self {
        case .workspaceUnavailable:
            return L10n.text("ui.the_workspace_has_expired_please_reopen_it")
        }
    }
}

struct SessionListProjection: Equatable {
    enum Source: Equatable {
        case localUser
        case localAssistant
    }

    let preview: String
    let updatedAt: Date
    let baseRemoteUpdatedAt: Date?
    let basePreview: String?
    let source: Source
    let clientMessageID: ClientMessageID?
}

struct SessionRecentActivityProjection: Equatable {
    let recencyAt: Date
    let baseRemoteOrderingAt: Date?
    let baseDisplayedRecencyAt: Date?
    let clientMessageID: ClientMessageID?
}

enum RunningTurnDelivery {
    case queued
    case guided
}

enum QueuedTurnIntent: Codable, Equatable {
    case standard
    case plan
    case goal(objective: String, tokenBudget: Int64?)

    var title: String {
        switch self {
        case .standard:
            return L10n.text("ui.next_round")
        case .plan:
            return L10n.text("ui.plan")
        case .goal:
            return L10n.text("ui.target")
        }
    }

    var canGuideCurrentTurn: Bool {
        if case .standard = self {
            return true
        }
        return false
    }

    var startsGoal: Bool {
        if case .goal = self {
            return true
        }
        return false
    }
}

enum QueuedTurnDispatchState: String, Codable, Equatable {
    case waiting
    case dispatching
    case needsConfirmation
}

/// 权限选择改变后，必须等同一条消息真正开始新的 turn 才能解除边界。
/// 只保存提交时的快照，迟到的旧事件不能清掉用户后来选择的权限。
struct PendingPermissionTurnBoundary: Codable, Equatable {
    let sessionID: SessionID
    let clientMessageID: ClientMessageID
    let permissionSelection: ComposerPermissionSelectionSnapshot
}

struct QueuedTurnEntry: Codable, Equatable, Identifiable {
    var id: ClientMessageID { clientMessageID }

    let sessionID: SessionID
    let projectID: String?
    var payload: CodexAppServerTurnPayload
    let clientMessageID: ClientMessageID
    var intent: QueuedTurnIntent
    let createdAt: Date
    var dispatchState: QueuedTurnDispatchState
    var expectedTurnID: TurnID?
    // true 表示该队列项不能被 steer 到旧 turn，必须作为新的 turn/start 派发。
    // Optional 保持旧 v1 队列 JSON 缺少该字段时仍可解码。
    var requiresFreshTurn: Bool?
    // 上一条 turn/start 已获接受、但 started 事件尚未到达时，后续项必须跨重启继续等待；
    // blockedCompletionID 用来识别并忽略触发上一条派发的重复 completed 事件。
    var waitsForAcceptedTurnStart: Bool?
    var blockedCompletionID: TurnID?
    // SSH shared queue 的 durable receipt。只有同一 client id 的 started 事件才能释放下一项。
    var serverSubmissionID: String?
    var serverStartedTurnID: TurnID?
    var lastAttemptAt: Date?
    var lastError: String?

    init(
        sessionID: SessionID,
        projectID: String? = nil,
        payload: CodexAppServerTurnPayload,
        clientMessageID: ClientMessageID,
        intent: QueuedTurnIntent,
        createdAt: Date = Date(),
        dispatchState: QueuedTurnDispatchState = .waiting,
        expectedTurnID: TurnID? = nil,
        requiresFreshTurn: Bool? = nil,
        waitsForAcceptedTurnStart: Bool? = nil,
        blockedCompletionID: TurnID? = nil,
        serverSubmissionID: String? = nil,
        serverStartedTurnID: TurnID? = nil,
        lastAttemptAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.sessionID = sessionID
        self.projectID = projectID
        self.payload = payload
        self.clientMessageID = clientMessageID
        self.intent = intent
        self.createdAt = createdAt
        self.dispatchState = dispatchState
        self.expectedTurnID = expectedTurnID
        self.requiresFreshTurn = requiresFreshTurn
        self.waitsForAcceptedTurnStart = waitsForAcceptedTurnStart
        self.blockedCompletionID = blockedCompletionID
        self.serverSubmissionID = serverSubmissionID
        self.serverStartedTurnID = serverStartedTurnID
        self.lastAttemptAt = lastAttemptAt
        self.lastError = lastError
    }

    var previewText: String {
        payload.previewText
    }

    var imageCount: Int {
        payload.input.reduce(into: 0) { count, input in
            switch input {
            case .image, .localImage:
                count += 1
            default:
                break
            }
        }
    }
}

struct QueuedTurnProfileSnapshot: Codable, Equatable {
    static let schemaVersion = 1

    var version = Self.schemaVersion
    let profileID: String
    var queuesBySessionID: [SessionID: [QueuedTurnEntry]]
    var pendingPermissionTurnBoundariesBySessionID: [SessionID: [PendingPermissionTurnBoundary]]
    /// 明确拒绝的权限消息已离开队列，但重试时仍必须恢复 fresh-turn 约束。
    var permissionTurnRetryRequirementsByClientMessageID: [ClientMessageID: PendingPermissionTurnBoundary]

    init(
        version: Int = Self.schemaVersion,
        profileID: String,
        queuesBySessionID: [SessionID: [QueuedTurnEntry]],
        pendingPermissionTurnBoundariesBySessionID: [SessionID: [PendingPermissionTurnBoundary]] = [:],
        permissionTurnRetryRequirementsByClientMessageID: [ClientMessageID: PendingPermissionTurnBoundary] = [:]
    ) {
        self.version = version
        self.profileID = profileID
        self.queuesBySessionID = queuesBySessionID
        self.pendingPermissionTurnBoundariesBySessionID = pendingPermissionTurnBoundariesBySessionID
        self.permissionTurnRetryRequirementsByClientMessageID = permissionTurnRetryRequirementsByClientMessageID
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case profileID
        case queuesBySessionID
        case pendingPermissionTurnBoundariesBySessionID
        case permissionTurnRetryRequirementsByClientMessageID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        profileID = try container.decode(String.self, forKey: .profileID)
        queuesBySessionID = try container.decode(
            [SessionID: [QueuedTurnEntry]].self,
            forKey: .queuesBySessionID
        )
        // 已发布的 v1 文件没有这些字段。早期 MIM-189 开发版还把每个 Session 编码成单条边界。
        if let boundaries = try? container.decode(
            [SessionID: [PendingPermissionTurnBoundary]].self,
            forKey: .pendingPermissionTurnBoundariesBySessionID
        ) {
            pendingPermissionTurnBoundariesBySessionID = boundaries
        } else if let legacyBoundaries = try? container.decode(
            [SessionID: PendingPermissionTurnBoundary].self,
            forKey: .pendingPermissionTurnBoundariesBySessionID
        ) {
            pendingPermissionTurnBoundariesBySessionID = legacyBoundaries.mapValues { [$0] }
        } else {
            pendingPermissionTurnBoundariesBySessionID = [:]
        }
        permissionTurnRetryRequirementsByClientMessageID = try container.decodeIfPresent(
            [ClientMessageID: PendingPermissionTurnBoundary].self,
            forKey: .permissionTurnRetryRequirementsByClientMessageID
        ) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(profileID, forKey: .profileID)
        try container.encode(queuesBySessionID, forKey: .queuesBySessionID)
        try container.encode(
            pendingPermissionTurnBoundariesBySessionID,
            forKey: .pendingPermissionTurnBoundariesBySessionID
        )
        try container.encode(
            permissionTurnRetryRequirementsByClientMessageID,
            forKey: .permissionTurnRetryRequirementsByClientMessageID
        )
    }
}

enum QueuedTurnStoreError: LocalizedError {
    case invalidProfile
    case unsupportedVersion(Int)
    case storageTooLarge(maximumBytes: Int)

    var errorDescription: String? {
        switch self {
        case .invalidProfile:
            return L10n.text("ui.the_local_queue_does_not_belong_to_the")
        case .unsupportedVersion(let version):
            return L10n.format("ui.the_local_queue_version_is_not_supported_v", version)
        case .storageTooLarge(let maximumBytes):
            return L10n.format("ui.the_local_queue_exceeds_value_mb_please_delete", maximumBytes / 1_024 / 1_024)
        }
    }
}

protocol QueuedTurnPersisting {
    func load(profileID: String) throws -> QueuedTurnProfileSnapshot
    func save(_ snapshot: QueuedTurnProfileSnapshot) throws
    func remove(profileID: String) throws
}

struct FileQueuedTurnStore: QueuedTurnPersisting {
    static let maximumEncodedByteCount = 64 * 1_024 * 1_024

    let directoryURL: URL
    let fileManager: FileManager
    let maximumEncodedByteCount: Int

    init(
        directoryURL: URL? = nil,
        fileManager: FileManager = .default,
        maximumEncodedByteCount: Int = Self.maximumEncodedByteCount
    ) {
        self.fileManager = fileManager
        self.maximumEncodedByteCount = maximumEncodedByteCount
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.directoryURL = applicationSupport
                .appendingPathComponent("MimiRemote", isDirectory: true)
                .appendingPathComponent("QueuedTurns", isDirectory: true)
                .appendingPathComponent("v1", isDirectory: true)
        }
    }

    func load(profileID: String) throws -> QueuedTurnProfileSnapshot {
        let url = fileURL(profileID: profileID)
        guard fileManager.fileExists(atPath: url.path) else {
            return QueuedTurnProfileSnapshot(profileID: profileID, queuesBySessionID: [:])
        }
        let snapshot = try JSONDecoder().decode(QueuedTurnProfileSnapshot.self, from: Data(contentsOf: url))
        guard snapshot.version == QueuedTurnProfileSnapshot.schemaVersion else {
            throw QueuedTurnStoreError.unsupportedVersion(snapshot.version)
        }
        guard snapshot.profileID == profileID else {
            throw QueuedTurnStoreError.invalidProfile
        }
        return snapshot
    }

    func save(_ snapshot: QueuedTurnProfileSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= maximumEncodedByteCount else {
            throw QueuedTurnStoreError.storageTooLarge(maximumBytes: maximumEncodedByteCount)
        }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        var directoryValues = URLResourceValues()
        directoryValues.isExcludedFromBackup = true
        var mutableDirectoryURL = directoryURL
        try? mutableDirectoryURL.setResourceValues(directoryValues)

        let url = fileURL(profileID: snapshot.profileID)
        try data.write(to: url, options: [.atomic])
        var fileValues = URLResourceValues()
        fileValues.isExcludedFromBackup = true
        var mutableFileURL = url
        try? mutableFileURL.setResourceValues(fileValues)
#if os(iOS)
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
#endif
    }

    func remove(profileID: String) throws {
        let url = fileURL(profileID: profileID)
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        try fileManager.removeItem(at: url)
    }

    func fileURL(profileID: String) -> URL {
        directoryURL.appendingPathComponent(Self.stableDigest(profileID) + ".json", isDirectory: false)
    }

    static func stableDigest(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

struct HistoryLoadProgress: Equatable {
    let sessionID: SessionID
    var title: String
    var fraction: Double

    var percentText: String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }
}

struct SessionRestoreSnapshot: Codable, Equatable {
    let profileID: String?
    let endpoint: String
    let session: AgentSession

    init(profileID: String, endpoint: String, session: AgentSession) {
        self.profileID = profileID
        self.endpoint = endpoint
        self.session = session
    }

    /// 兼容 V1 测试和旧 SceneStorage；新写入一律使用 profileID。
    init(endpoint: String, session: AgentSession) {
        profileID = nil
        self.endpoint = endpoint
        self.session = session
    }

    func matches(profileID currentProfileID: String?, endpoint currentEndpoint: String) -> Bool {
        if let profileID,
           !profileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // V2 身份只认稳定 Profile；同一台 Mac 更换 Tailscale/IP 路由后仍可恢复。
            return profileID == currentProfileID
        }
        // V1 SceneStorage 没有 Profile，只能继续使用一次 endpoint 兼容匹配。
        return AgentAPIClient.normalizedEndpoint(endpoint) ==
            AgentAPIClient.normalizedEndpoint(currentEndpoint)
    }
}

/// 跨 await 的前台选择凭证。除了代次，还同时校验项目和会话，避免同一 ID
/// 在工作区切换、身份替换等场景下被误认为仍是当前选择。
struct SessionSelectionLease: Equatable {
    let hostScope: HostScope
    let generation: UInt64
    let projectID: String?
    let sessionID: SessionID?
}

struct SessionSelectionCommit: Equatable {
    enum Reason: Equatable {
        case userOpen
        case notification
        case restoration
        case identityReplacement(previousID: SessionID)
        case invalidation
    }

    let sequence: UInt64
    let projectID: String?
    let sessionID: SessionID?
    let reason: Reason
}

enum WorkbenchRootPage: String, Codable, Equatable {
    case sessions
    case workspaces
}

/// SceneStorage 只保存工作台的轻量导航意图；详情数据仍由 SessionRestoreSnapshot 提供。
/// 这样运行中会话可以继续刷新和监控，但不会因为 selectedSessionID 的后台变化抢走页面。
enum WorkbenchRestorationRoute: Codable, Equatable {
    case sessions
    case workspaces
    case session(id: SessionID, source: WorkbenchRootPage)

    static let defaultStorageValue = WorkbenchRestorationRoute.sessions.storageValue

    init(storageValue: String) {
        guard let data = Data(base64Encoded: storageValue),
              let decoded = try? JSONDecoder().decode(Self.self, from: data)
        else {
            self = .sessions
            return
        }
        self = decoded
    }

    var storageValue: String {
        guard let data = try? JSONEncoder().encode(self) else {
            return ""
        }
        return data.base64EncodedString()
    }

    var detailSessionID: SessionID? {
        guard case .session(let id, _) = self else { return nil }
        return id
    }

    var rootPage: WorkbenchRootPage {
        switch self {
        case .sessions:
            return .sessions
        case .workspaces:
            return .workspaces
        case .session(_, let source):
            return source
        }
    }

    func restoreSnapshot(
        from storageValue: String,
        currentProfileID: String?,
        currentEndpoint: String
    ) -> SessionRestoreSnapshot? {
        guard let detailSessionID,
              !detailSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = Data(base64Encoded: storageValue),
              let snapshot = try? JSONDecoder().decode(SessionRestoreSnapshot.self, from: data),
              snapshot.session.id == detailSessionID
        else {
            return nil
        }
        guard snapshot.matches(profileID: currentProfileID, endpoint: currentEndpoint) else {
            return nil
        }
        return snapshot
    }

    func restoreSnapshot(from storageValue: String, currentEndpoint: String) -> SessionRestoreSnapshot? {
        restoreSnapshot(from: storageValue, currentProfileID: nil, currentEndpoint: currentEndpoint)
    }
}

enum SessionNotificationOpenOutcome: Equatable {
    case opened
    case requiresProfileSwitch(displayName: String?)
    case unavailable(message: String)
    case ignored
}

// 列表预览与最近活动投影属于本地状态保护：服务端确认前保留用户刚刚创建或更新的会话，
// 避免旧缓存、single-flight 响应或秒级时间戳让列表短暂回跳。
extension SessionStore {
    static func promptTitle(_ prompt: String) -> String {
        let collapsed = prompt
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !collapsed.isEmpty else {
            return L10n.text("ui.new_session")
        }
        if collapsed.count <= 42 {
            return collapsed
        }
        return String(collapsed.prefix(42)) + "..."
    }

    func setSessionRecentActivityProjection(sessionID: SessionID, clientMessageID: ClientMessageID?) {
        let existingProjection = recentActivityProjectionBySessionID[sessionID]
        let existingSession = sessionsByID[sessionID]
        let now = sessionListNow()
        let projectedAt = max(existingProjection?.recencyAt ?? .distantPast, now)
        let isOptimisticPlaceholder = existingSession?.source == Self.optimisticSessionSource
        let existingRemoteOrderingAt = existingSession.flatMap { session in
            session.recencyAt ?? session.updatedAt ?? session.createdAt
        }
        let projection = SessionRecentActivityProjection(
            recencyAt: projectedAt,
            baseRemoteOrderingAt: existingProjection?.baseRemoteOrderingAt
                ?? (isOptimisticPlaceholder ? nil : existingRemoteOrderingAt),
            baseDisplayedRecencyAt: existingProjection?.baseDisplayedRecencyAt
                ?? (isOptimisticPlaceholder ? nil : existingSession?.recencyAt),
            clientMessageID: clientMessageID
        )
        recentActivityProjectionBySessionID[sessionID] = projection
        updateSession(sessionID) { item in
            item.recencyAt = max(item.recencyAt ?? .distantPast, projection.recencyAt)
        }
    }

    func clearSessionRecentActivityProjection(sessionID: SessionID, clientMessageID: ClientMessageID?) {
        guard let projection = recentActivityProjectionBySessionID[sessionID] else {
            return
        }
        if let clientMessageID,
           let projectionClientID = projection.clientMessageID,
           projectionClientID != clientMessageID {
            return
        }
        recentActivityProjectionBySessionID.removeValue(forKey: sessionID)
        updateSession(sessionID) { item in
            item.recencyAt = projection.baseDisplayedRecencyAt
        }
    }

    func moveSessionRecentActivityProjection(
        from sourceSessionID: SessionID,
        to targetSessionID: SessionID,
        clientMessageID: ClientMessageID?
    ) {
        guard sourceSessionID != targetSessionID,
              let projection = recentActivityProjectionBySessionID[sourceSessionID] else {
            return
        }
        if let clientMessageID,
           let projectionClientID = projection.clientMessageID,
           projectionClientID != clientMessageID {
            return
        }
        recentActivityProjectionBySessionID.removeValue(forKey: sourceSessionID)
        recentActivityProjectionBySessionID[targetSessionID] = projection
    }

    func acknowledgeRecentActivityProjections(in remoteSessions: [AgentSession]) {
        for remote in remoteSessions {
            guard let projection = recentActivityProjectionBySessionID[remote.id],
                  let remoteOrderingAt = remote.recencyAt ?? remote.updatedAt else {
                continue
            }
            if projection.baseRemoteOrderingAt == nil
                || remoteOrderingAt > (projection.baseRemoteOrderingAt ?? .distantPast) {
                recentActivityProjectionBySessionID.removeValue(forKey: remote.id)
            }
        }
    }

    func sessionPreparedForStorage(_ incoming: AgentSession) -> AgentSession {
        let ownershipPreserved = sessionPreservingSubagentOwnership(incoming)
        let preserved = sessionPreservingLocalCompletedGoal(
            sessionPreservingLocalCompletedStatus(sessionPreservingActiveApproval(ownershipPreserved))
        )
        let previewProjected = sessionApplyingListProjection(preserved)
        let monotonicRecency = sessionPreservingRecencyFloor(previewProjected)
        return sessionApplyingRecentActivityProjection(monotonicRecency)
    }

    /// 子 Agent ownership 和创建时间属于线程身份，而非一次列表响应的瞬时字段。
    /// REST / DataFlow 的稀疏同 ID 更新也必须单调保留，避免刷新后 child 被重新平铺为 root，
    /// 或历史过滤因为 createdAt 丢失而放回父会话前缀。
    func sessionPreservingSubagentOwnership(_ incoming: AgentSession) -> AgentSession {
        guard let existing = sessionsByID[incoming.id] else {
            return incoming
        }
        return sessionPreservingSubagentOwnership(incoming, withKnown: existing)
    }

    /// 同一 cursor 链也可能重复同一 ID，且后一页才携带完整 parent/source。
    /// 分页结果尚未进入 Store 时，用当前链已知行执行同样的单调 ownership 合并。
    func sessionPreservingSubagentOwnership(
        _ incoming: AgentSession,
        withKnown existing: AgentSession
    ) -> AgentSession {
        var result = incoming
        result.createdAt = result.createdAt ?? existing.createdAt ?? existing.context?.createdAt

        let incomingParent = result.parentThreadID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if incomingParent?.isEmpty != false {
            let existingParent = existing.parentThreadID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            result.parentThreadID = existingParent?.isEmpty == false
                ? existingParent
                : existing.context?.parentThreadID
        }
        if existing.isSubagentThread || result.isSubagentThread {
            result.isSubagent = true
        }
        return result
    }

    func sessionPreservingRecencyFloor(_ incoming: AgentSession) -> AgentSession {
        guard let existing = sessionsByID[incoming.id],
              let existingRecency = existing.recencyAt,
              existingRecency > (incoming.recencyAt ?? .distantPast) else {
            return incoming
        }
        var result = incoming
        // 最近用户活动在单次 App 生命周期内只前进不后退，避免服务端秒级时间或设备时钟差造成回跳。
        result.recencyAt = existingRecency
        return result
    }

    func sessionApplyingRecentActivityProjection(_ incoming: AgentSession) -> AgentSession {
        guard let projection = recentActivityProjectionBySessionID[incoming.id] else {
            return incoming
        }
        var projected = incoming
        projected.recencyAt = max(incoming.recencyAt ?? .distantPast, projection.recencyAt)
        return projected
    }

    func sessionApplyingListProjection(_ incoming: AgentSession) -> AgentSession {
        guard let projection = listProjectionBySessionID[incoming.id] else {
            return incoming
        }
        if shouldClearListProjection(projection, remoteUpdatedAt: incoming.updatedAt) {
            listProjectionBySessionID.removeValue(forKey: incoming.id)
            return incoming
        }
        var projected = incoming
        projected.preview = projection.preview
        projected.updatedAt = projection.updatedAt
        return projected
    }

    func shouldClearListProjection(_ projection: SessionListProjection, remoteUpdatedAt: Date?) -> Bool {
        guard let remoteUpdatedAt else {
            return false
        }
        guard let baseRemoteUpdatedAt = projection.baseRemoteUpdatedAt else {
            return true
        }
        return remoteUpdatedAt > baseRemoteUpdatedAt
    }
}
