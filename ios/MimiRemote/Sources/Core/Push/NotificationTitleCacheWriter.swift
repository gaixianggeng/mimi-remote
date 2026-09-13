import Combine
import Foundation

/// 观察会话列表与连接档案，把「短标签 → 会话标题」缓存写进 App Group，供通知扩展改写锁屏通知。
///
/// 只有锁屏提醒开启时才维护缓存；关闭后文件即被删除，设备上不留下没有用途的会话标题副本。
/// 会话列表在流式回复与轮询期间持续变化，因此写入按约 1 秒节流并取最新值：防抖会被持续变化
/// 一再推迟、永远等不到落盘。摘要计算与文件 IO 都在后台队列完成，相同内容不重复写。
@MainActor
final class NotificationTitleCacheWriter: ObservableObject {
    /// 只在 `queue` 上访问：记录上一次落盘的内容，相同内容不重复写文件，
    /// 避免流式回复期间每次事件推进都改写缓存。状态由串行队列保护，
    /// 因此标成 `@unchecked Sendable` 以便从主线程投递到队列。
    private final class Worker: @unchecked Sendable {
        private var lastWritten: (profileCount: Int, entries: [String: NotificationTitleCache.Entry])?
        /// 只在 `queue` 上访问：上一次写进诊断的结论。结论不变不重复记录，避免每秒一条。
        private var lastRecorded: String?

        /// 结论只含枚举式短语与条目数、错误码，不含标题、路径或会话标识。
        func record(_ outcome: String, reason: String?) {
            let key = outcome + "|" + (reason ?? "")
            guard key != lastRecorded else { return }
            lastRecorded = key
            NotificationRouteDiagnostics.record(
                stage: NotificationRouteDiagnostics.Stage.titleCache,
                outcome: outcome,
                reason: reason
            )
        }

        func clear(fileURL: URL, reason: String) {
            lastWritten = nil
            NotificationTitleCache.clear(fileURL: fileURL)
            record("cleared", reason: reason)
        }

        func synchronize(
            sessions: [AgentSession],
            installationID: String,
            hostName: String,
            profileCount: Int,
            fileURL: URL
        ) {
            let profileTag = NotificationSessionTag.profileTag(installationID: installationID)
            let fresh = NotificationTitleCacheWriter.entries(sessions: sessions, profileTag: profileTag, hostName: hostName)
            let existing = NotificationTitleCache.load(fileURL: fileURL).entries
            let merged = NotificationTitleCacheWriter.merge(existing: existing, fresh: fresh, profileTag: profileTag)
            if let lastWritten, lastWritten.profileCount == profileCount, lastWritten.entries == merged {
                return
            }
            do {
                try NotificationTitleCache.write(entries: merged, profileCount: profileCount, fileURL: fileURL)
                lastWritten = (profileCount, merged)
                record("written", reason: "entries=\(merged.count)")
            } catch {
                // 写失败只影响这一次；下一次会话变化会再试，通知则回退到通用文案。
                lastWritten = nil
                let nsError = error as NSError
                record("failed", reason: "\(nsError.domain)#\(nsError.code)")
            }
        }
    }

    private let fileURL: URL?
    private let debounceInterval: TimeInterval
    private let queue: DispatchQueue
    private let worker = Worker()
    private var cancellable: AnyCancellable?

    init(
        fileURL: URL? = NotificationTitleCache.defaultFileURL,
        debounceInterval: TimeInterval = 1,
        queue: DispatchQueue = DispatchQueue(label: "com.gaixianggeng.mimi.notification-title-cache", qos: .utility)
    ) {
        self.fileURL = fileURL
        self.debounceInterval = debounceInterval
        self.queue = queue
    }

    func attach(
        sessionStore: SessionStore,
        appStore: AppStore,
        lockScreenApprovalStore: LockScreenApprovalStore
    ) {
        // `@Published` 在 willSet 发布，所以只用管道里带过来的值，不回头读 Store 属性。
        // 开关状态通过 `status` 触发重算，具体是否启用在节流结束后再问一次 defaults。
        //
        // 切换 Mac 时 AppStore 先发布新档案，中间经过 await，SessionStore 才清掉旧会话；
        // 这段时间里的组合是「旧会话 + 新档案」。给每次会话发布编号，档案切换后只接受更新
        // 编号的会话，避免把上一台 Mac 的标题写到新档案名下。
        let coherence = NotificationTitleCacheCoherenceBox()
        cancellable = Publishers.CombineLatest4(
            sessionStore.$sessions.map { sessions -> ([AgentSession], UInt64) in
                (sessions, coherence.sessionsDidPublish())
            },
            appStore.$connectionProfiles,
            appStore.$activeConnectionProfileID.map { profileID -> (String?, UInt64) in
                (profileID, coherence.profileDidPublish(profileID))
            },
            lockScreenApprovalStore.$status.removeDuplicates()
        )
        .throttle(for: .seconds(debounceInterval), scheduler: DispatchQueue.main, latest: true)
        .sink { [weak self, weak lockScreenApprovalStore] sessionsState, profiles, profileState, _ in
            guard let self else { return }
            guard NotificationTitleCacheCoherence.isCoherent(
                sessionsGeneration: sessionsState.1,
                requiredGeneration: profileState.1
            ) else {
                // 档案刚切换、会话列表还属于上一台 Mac：跳过，等新会话列表发布后再写。
                self.recordSkip("awaiting_sessions_after_switch")
                return
            }
            let isEnabled = lockScreenApprovalStore?.isEnabled ?? false
            self.synchronize(
                sessions: sessionsState.0,
                profiles: profiles,
                activeProfileID: profileState.0,
                isEnabled: isEnabled
            )
        }
    }

    private func recordSkip(_ reason: String) {
        let worker = worker
        queue.async { worker.record("skipped", reason: reason) }
    }

    func synchronize(
        sessions: [AgentSession],
        profiles: [ConnectionProfile],
        activeProfileID: String?,
        isEnabled: Bool
    ) {
        let worker = worker
        guard let fileURL else {
            // App Group 容器不可用（entitlement 缺失）时读写都会静默降级，这里至少留下诊断。
            queue.async { worker.record("unavailable", reason: "no_app_group_container") }
            return
        }
        let profile = profiles.first(where: { $0.id == activeProfileID })
        let installationID = profile?.installationID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let skipReason: String? = !isEnabled ? "disabled"
            : profile == nil ? "no_active_profile"
            : installationID.isEmpty ? "no_installation_id"
            : nil
        guard skipReason == nil, let profile else {
            // 未开启、没有当前档案或档案尚未配对（无 installationID）时，本机没有
            // 任何推送能命中缓存，直接清掉。
            let reason = skipReason ?? "no_active_profile"
            queue.async { worker.clear(fileURL: fileURL, reason: reason) }
            return
        }
        let hostName = profile.displayName
        let profileCount = profiles.count
        // 会话结构体拷贝到后台串行队列，SHA256 与文件 IO 都不占用主线程。
        queue.async {
            worker.synchronize(
                sessions: sessions,
                installationID: installationID,
                hostName: hostName,
                profileCount: profileCount,
                fileURL: fileURL
            )
        }
    }

    /// 测试用：等待队列上已排队的写入完成。
    func waitForPendingWrites() {
        queue.sync {}
    }

    /// 把当前档案的会话映射成缓存条目。本地草稿没有远端 thread，不会有推送；
    /// 没有标题的会话改写后也无从辨认，同样跳过。`id` 与 `resumeID` 不同时两者都登记，
    /// 因为 agentd 发推送时用的 thread id 可能是任一个。
    nonisolated static func entries(
        sessions: [AgentSession],
        profileTag: String,
        hostName: String
    ) -> [String: NotificationTitleCache.Entry] {
        var result: [String: NotificationTitleCache.Entry] = [:]
        for session in sessions where !session.isLocalDraft {
            let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let entry = NotificationTitleCache.Entry(
                title: title,
                project: session.project,
                runtime: session.runtimeProvider == "claude" ? "claude" : "codex",
                hostName: hostName,
                updatedAt: session.updatedAt ?? session.recencyAt ?? session.createdAt ?? .distantPast
            )
            var threadIDs = [session.id]
            if let resumeID = session.resumeID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !resumeID.isEmpty, resumeID != session.id {
                threadIDs.append(resumeID)
            }
            for threadID in threadIDs {
                let key = NotificationSessionTag.cacheKey(
                    profileTag: profileTag,
                    sessionTag: NotificationSessionTag.messageTag(threadID: threadID)
                )
                result[key] = entry
            }
        }
        return result
    }

    /// 当前档案的条目整体替换（消失的会话随之移除），其它 Mac 的条目原样保留，
    /// 这样切换主机后另一台的推送仍能显示标题；超限部分交给 `capped` 按时间淘汰。
    nonisolated static func merge(
        existing: [String: NotificationTitleCache.Entry],
        fresh: [String: NotificationTitleCache.Entry],
        profileTag: String
    ) -> [String: NotificationTitleCache.Entry] {
        let prefix = profileTag.lowercased() + ":"
        // 空列表几乎总是「还没加载」：冷启动或切换 Mac 后刚清空。不能拿它抹掉这台 Mac 已有的标题，
        // 否则加载完成前到达的推送只能显示通用文案。
        guard !fresh.isEmpty else { return NotificationTitleCache.capped(existing) }
        var merged = existing.filter { !$0.key.hasPrefix(prefix) }
        merged.merge(fresh) { _, new in new }
        return NotificationTitleCache.capped(merged)
    }
}

/// 会话列表与活动档案的一致性。每次会话发布编一个号；活动档案变化后，只有编号不小于
/// 「变化时刻的下一个编号」的会话才属于新档案。首次档案发布视为与当前会话一致，
/// 因为启动时两者来自同一份持久化状态。
struct NotificationTitleCacheCoherence: Equatable {
    private(set) var sessionsGeneration: UInt64 = 0
    private(set) var requiredGeneration: UInt64 = 0
    private var profileID: String?
    private var hasProfile = false

    mutating func sessionsDidPublish() -> UInt64 {
        sessionsGeneration &+= 1
        return sessionsGeneration
    }

    mutating func profileDidPublish(_ id: String?) -> UInt64 {
        defer {
            hasProfile = true
            profileID = id
        }
        guard hasProfile else {
            requiredGeneration = 0
            return requiredGeneration
        }
        if id != profileID {
            requiredGeneration = sessionsGeneration &+ 1
        }
        return requiredGeneration
    }

    static func isCoherent(sessionsGeneration: UInt64, requiredGeneration: UInt64) -> Bool {
        sessionsGeneration >= requiredGeneration
    }
}

/// Combine 的 map 闭包不受主线程隔离约束；这些发布实际都在主线程，这里再加锁兜底。
final class NotificationTitleCacheCoherenceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var state = NotificationTitleCacheCoherence()

    func sessionsDidPublish() -> UInt64 {
        lock.withLock { state.sessionsDidPublish() }
    }

    func profileDidPublish(_ id: String?) -> UInt64 {
        lock.withLock { state.profileDidPublish(id) }
    }
}
