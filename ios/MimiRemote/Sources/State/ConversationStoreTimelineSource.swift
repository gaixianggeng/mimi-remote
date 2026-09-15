import Foundation

/// 只保存每个 scope 的轻量来源版本；消息仍唯一存放在 ConversationStore。
@MainActor
final class ConversationTimelineSourceTracker {
    private var versionsBySessionID: [ScopedSessionID: ConversationTimelineSourceVersions] = [:]
    private var revision: UInt64 = 0

    func snapshot(
        scope: ScopedSessionID,
        messages: [ConversationMessage]
    ) -> ConversationTimelineSourceSnapshot {
        ConversationTimelineSourceSnapshot(
            scope: scope,
            messages: messages,
            versions: versionsBySessionID[scope] ?? .init()
        )
    }

    func record(_ reasons: ConversationTimelineChangeReasons, for scope: ScopedSessionID) {
        guard !reasons.isEmpty else { return }
        revision &+= 1
        var versions = versionsBySessionID[scope] ?? .init()
        if versions.lifetime == 0 {
            versions.lifetime = revision
        }
        versions.record(reasons, revision: revision)
        versionsBySessionID[scope] = versions
    }

    func remove(_ scope: ScopedSessionID) {
        versionsBySessionID.removeValue(forKey: scope)
    }
}
