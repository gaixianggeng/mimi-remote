import Combine
import Foundation

/// 观察会话列表与连接档案，把「短标签 → 会话标题」缓存写进 App Group，供通知扩展改写锁屏通知。
///
/// 只有锁屏提醒开启时才维护缓存；关闭后文件即被删除，设备上不留下没有用途的会话标题副本。
/// 会话列表在流式回复期间会高频变化，因此写入做约 1 秒防抖，摘要计算与文件 IO 都在后台队列完成。
@MainActor
final class NotificationTitleCacheWriter: ObservableObject {
    /// 只在 `queue` 上访问：记录上一次落盘的内容，相同内容不重复写文件，
    /// 避免流式回复期间每次事件推进都改写缓存。状态由串行队列保护，
    /// 因此标成 `@unchecked Sendable` 以便从主线程投递到队列。
    private final class Worker: @unchecked Sendable {
        private var lastWritten: (profileCount: Int, entries: [String: NotificationTitleCache.Entry])?

        func clear(fileURL: URL) {
            lastWritten = nil
            NotificationTitleCache.clear(fileURL: fileURL)
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
            } catch {
                // 写失败只影响这一次；下一次会话变化会再试，通知则回退到通用文案。
                lastWritten = nil
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
        // 开关状态通过 `status` 触发重算，具体是否启用在防抖结束后再问一次 defaults。
        cancellable = Publishers.CombineLatest4(
            sessionStore.$sessions,
            appStore.$connectionProfiles,
            appStore.$activeConnectionProfileID,
            lockScreenApprovalStore.$status.removeDuplicates()
        )
        .debounce(for: .seconds(debounceInterval), scheduler: DispatchQueue.main)
        .sink { [weak self, weak lockScreenApprovalStore] sessions, profiles, activeProfileID, _ in
            guard let self else { return }
            let isEnabled = lockScreenApprovalStore?.isEnabled ?? false
            self.synchronize(
                sessions: sessions,
                profiles: profiles,
                activeProfileID: activeProfileID,
                isEnabled: isEnabled
            )
        }
    }

    func synchronize(
        sessions: [AgentSession],
        profiles: [ConnectionProfile],
        activeProfileID: String?,
        isEnabled: Bool
    ) {
        guard let fileURL else { return }
        let worker = worker
        guard isEnabled,
              let profile = profiles.first(where: { $0.id == activeProfileID }),
              let installationID = profile.installationID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !installationID.isEmpty else {
            // 未开启、没有当前档案或档案尚未配对（无 installationID）时，本机没有
            // 任何推送能命中缓存，直接清掉。
            queue.async { worker.clear(fileURL: fileURL) }
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
        var merged = existing.filter { !$0.key.hasPrefix(prefix) }
        merged.merge(fresh) { _, new in new }
        return NotificationTitleCache.capped(merged)
    }
}
