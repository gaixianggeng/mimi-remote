import CryptoKit
import Foundation

/// 推送里出现的会话与档案标识都是不可逆短摘要，算法与 `internal/pushbridge/tags.go`
/// 保持一致。App 与通知扩展要靠同一套算法把本地会话映射回这些标签，才能在
/// 设备上把「Codex 消息」改写成会话标题；Provider 与 APNs 全程只见摘要。
///
/// 这个文件同时编译进通知扩展，只允许依赖 Foundation 与 CryptoKit。
enum NotificationSessionTag {
    /// `profile_id`：SHA256("mimi-profile:" + installationID) 的前 16 位小写十六进制。
    static func profileTag(installationID: String) -> String {
        let value = "mimi-profile:" + installationID.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(hexDigest(value).prefix(16)).lowercased()
    }

    /// 回复类事件（turn.completed / failed / interrupted）的 `session_tag`：
    /// SHA256("mimi-tag:session:" + threadID) 的前 16 位大写十六进制。
    static func messageTag(threadID: String) -> String {
        String(hexDigest(sessionSeed(threadID)).prefix(16)).uppercased()
    }

    /// 审批类事件的 `session_tag` 只有 4 位，且正好是 `messageTag` 的前缀。
    /// 缓存按 16 位键存储，4 位标签靠前缀匹配找回。
    static func approvalTag(threadID: String) -> String {
        String(messageTag(threadID: threadID).prefix(4))
    }

    /// 缓存键：`profileTag:messageTag`。冒号把两段定长十六进制分开，
    /// 前缀匹配 4 位审批标签时不会跨档案误命中。
    static func cacheKey(profileTag: String, sessionTag: String) -> String {
        profileTag.lowercased() + ":" + sessionTag.uppercased()
    }

    private static func sessionSeed(_ threadID: String) -> String {
        "mimi-tag:session:" + threadID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hexDigest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
