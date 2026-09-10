import Foundation
import UserNotifications
import XCTest
@testable import MimiRemote

final class NotificationContentRewriterTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

    private static let chinese: [String: String] = [
        "push.message.body.completed.titled": "已回复，点按查看。",
        "push.message.body.failed.titled": "任务未能完成，点按查看原因。",
        "push.message.body.interrupted.titled": "任务已停止，点按查看。",
        "push.approval.body.command.titled": "运行命令",
        "push.approval.body.patch.titled": "修改文件",
        "push.approval.body.permission.titled": "授予权限",
        "push.approval.body.user_input.titled": "需要你补充输入",
        "push.approval.body.elicitation.titled": "工具正在提问",
    ]

    private static let english: [String: String] = [
        "push.message.body.completed.titled": "Replied. Tap to view.",
        "push.message.body.failed.titled": "The task could not finish. Tap to see why.",
        "push.message.body.interrupted.titled": "The task has stopped. Tap to view.",
        "push.approval.body.command.titled": "Run a command",
        "push.approval.body.patch.titled": "Change files",
        "push.approval.body.permission.titled": "Grant a permission",
        "push.approval.body.user_input.titled": "Needs your input",
        "push.approval.body.elicitation.titled": "A tool is asking a question",
    ]

    private func localizeChinese(_ key: String) -> String { Self.chinese[key] ?? key }
    private func localizeEnglish(_ key: String) -> String { Self.english[key] ?? key }

    func testMessageRewriteInChineseKeepsRoutingFieldsUntouched() throws {
        let content = systemContent(title: "Codex 消息", body: "AI 已回复，点按查看。", event: "turn.completed", sessionTag: messageTag)
        let notification = try XCTUnwrap(LockScreenApprovalNotification(userInfo: content.userInfo))
        let entry = makeEntry(title: "重构登录页", project: "mimi-remote")

        XCTAssertTrue(
            NotificationContentRewriter.rewrite(content, notification: notification, entry: entry, localize: localizeChinese)
        )
        XCTAssertEqual(content.title, "重构登录页")
        XCTAssertEqual(content.subtitle, "Codex · mimi-remote")
        XCTAssertEqual(content.body, "已回复，点按查看。")
        XCTAssertEqual(content.threadIdentifier, messageTag)
        XCTAssertEqual(content.categoryIdentifier, "MIMI_APPROVAL_DETAILS")
        XCTAssertNotNil(content.sound, "声音配置不能被改写清掉")
        XCTAssertEqual(content.interruptionLevel, .timeSensitive)
        let mimi = try XCTUnwrap(content.userInfo["mimi"] as? [String: Any])
        XCTAssertEqual(mimi["event"] as? String, "turn.completed")
        XCTAssertEqual(mimi["session_tag"] as? String, messageTag)
    }

    func testFailedAndInterruptedUseTheirOwnBodies() throws {
        for (event, expected) in [("turn.failed", "任务未能完成，点按查看原因。"), ("turn.interrupted", "任务已停止，点按查看。")] {
            let content = systemContent(title: "Claude 消息", body: "旧正文", event: event, runtime: "claude", sessionTag: messageTag)
            let notification = try XCTUnwrap(LockScreenApprovalNotification(userInfo: content.userInfo))
            XCTAssertTrue(
                NotificationContentRewriter.rewrite(content, notification: notification, entry: makeEntry(), localize: localizeChinese)
            )
            XCTAssertEqual(content.body, expected, event)
            XCTAssertEqual(content.subtitle, "Claude Code · mimi-remote", event)
        }
    }

    func testApprovalRewriteInEnglishDropsSessionSuffix() throws {
        let content = systemContent(
            title: "Claude Code needs approval on A1C3",
            body: "Run a command · session 9E61",
            event: "approval.pending",
            runtime: "claude",
            kind: "command",
            sessionTag: approvalTag,
            category: "MIMI_APPROVAL"
        )
        let notification = try XCTUnwrap(LockScreenApprovalNotification(userInfo: content.userInfo))
        let entry = makeEntry(title: "Fix flaky CI", project: "agentd")

        XCTAssertTrue(
            NotificationContentRewriter.rewrite(content, notification: notification, entry: entry, localize: localizeEnglish)
        )
        XCTAssertEqual(content.title, "Fix flaky CI")
        XCTAssertEqual(content.subtitle, "Claude Code · agentd")
        XCTAssertEqual(content.body, "Run a command")
        XCTAssertFalse(content.body.contains("9E61"), "标题已标识会话，正文不再带会话标签后缀")
        XCTAssertEqual(content.categoryIdentifier, "MIMI_APPROVAL", "审批动作分类必须保留")
        XCTAssertEqual(content.threadIdentifier, approvalTag)
    }

    func testEveryApprovalKindHasTitledBodyKey() throws {
        for kind in ["command", "patch", "permission", "user_input", "elicitation"] {
            let content = systemContent(title: "t", body: "b", event: "approval.pending", kind: kind, sessionTag: approvalTag)
            let notification = try XCTUnwrap(LockScreenApprovalNotification(userInfo: content.userInfo))
            XCTAssertEqual(
                NotificationContentRewriter.bodyLocalizationKey(for: notification),
                "push.approval.body.\(kind).titled"
            )
            XCTAssertTrue(
                NotificationContentRewriter.rewrite(content, notification: notification, entry: makeEntry(), localize: localizeEnglish)
            )
            XCTAssertEqual(content.body, Self.english["push.approval.body.\(kind).titled"], kind)
        }
    }

    func testCacheMissLeavesContentUntouched() throws {
        let content = systemContent(title: "Codex 消息", body: "AI 已回复，点按查看。", event: "turn.completed", sessionTag: messageTag)
        let notification = try XCTUnwrap(LockScreenApprovalNotification(userInfo: content.userInfo))

        XCTAssertFalse(
            NotificationContentRewriter.rewrite(content, notification: notification, entry: nil, localize: localizeChinese)
        )
        XCTAssertEqual(content.title, "Codex 消息")
        XCTAssertEqual(content.subtitle, "")
        XCTAssertEqual(content.body, "AI 已回复，点按查看。")
        XCTAssertEqual(content.threadIdentifier, messageTag)
    }

    func testEmptyTitleEntryDoesNotRewrite() throws {
        let content = systemContent(title: "Codex 消息", body: "旧正文", event: "turn.completed", sessionTag: messageTag)
        let notification = try XCTUnwrap(LockScreenApprovalNotification(userInfo: content.userInfo))
        let entry = NotificationTitleCache.Entry(title: "   ", project: "p", runtime: "codex", hostName: "h", updatedAt: referenceDate)

        XCTAssertFalse(
            NotificationContentRewriter.rewrite(content, notification: notification, entry: entry, localize: localizeChinese)
        )
        XCTAssertEqual(content.title, "Codex 消息")
        XCTAssertEqual(content.body, "旧正文")
    }

    func testSubtitleIncludesHostNameOnlyWhenRequested() throws {
        let entry = makeEntry(title: "重构登录页", project: "mimi-remote", hostName: "Studio")
        XCTAssertEqual(
            NotificationContentRewriter.subtitle(entry: entry, runtime: .codex, showsHostName: false),
            "Codex · mimi-remote"
        )
        XCTAssertEqual(
            NotificationContentRewriter.subtitle(entry: entry, runtime: .codex, showsHostName: true),
            "Codex · mimi-remote · Studio"
        )
        XCTAssertEqual(
            NotificationContentRewriter.subtitle(entry: makeEntry(project: "", hostName: ""), runtime: .claude, showsHostName: true),
            "Claude Code",
            "项目与主机为空时不留悬空分隔符"
        )

        let content = systemContent(title: "Codex 消息", body: "b", event: "turn.completed", sessionTag: messageTag)
        let notification = try XCTUnwrap(LockScreenApprovalNotification(userInfo: content.userInfo))
        XCTAssertTrue(
            NotificationContentRewriter.rewrite(
                content, notification: notification, entry: entry, showsHostName: true, localize: localizeChinese
            )
        )
        XCTAssertEqual(content.subtitle, "Codex · mimi-remote · Studio")
    }

    func testResolvedEventIsNeverRewritten() throws {
        let content = systemContent(title: "", body: "", event: "approval.resolved", kind: "command", sessionTag: approvalTag)
        let notification = try XCTUnwrap(LockScreenApprovalNotification(userInfo: content.userInfo))
        XCTAssertNil(NotificationContentRewriter.bodyLocalizationKey(for: notification))
        XCTAssertFalse(
            NotificationContentRewriter.rewrite(content, notification: notification, entry: makeEntry(), localize: localizeChinese)
        )
        XCTAssertEqual(content.title, "")
    }

    func testMissingLocalizationKeepsSystemRenderedBody() throws {
        let content = systemContent(title: "Codex 消息", body: "AI 已回复，点按查看。", event: "turn.completed", sessionTag: messageTag)
        let notification = try XCTUnwrap(LockScreenApprovalNotification(userInfo: content.userInfo))

        XCTAssertTrue(
            NotificationContentRewriter.rewrite(content, notification: notification, entry: makeEntry(title: "重构登录页"), localize: { $0 })
        )
        XCTAssertEqual(content.title, "重构登录页", "标题仍改写")
        XCTAssertEqual(content.body, "AI 已回复，点按查看。", "文案缺失时保留系统渲染的正文而不是裸 key")
    }

    func testRuntimeDisplayNames() {
        XCTAssertEqual(NotificationContentRewriter.runtimeDisplayName(.codex), "Codex")
        XCTAssertEqual(NotificationContentRewriter.runtimeDisplayName(.claude), "Claude Code")
    }

    // MARK: - Helpers

    private var messageTag: String { NotificationSessionTag.messageTag(threadID: "thread-1") }
    private var approvalTag: String { NotificationSessionTag.approvalTag(threadID: "thread-1") }

    private func makeEntry(
        title: String = "重构登录页",
        project: String = "mimi-remote",
        runtime: String = "codex",
        hostName: String = "Studio"
    ) -> NotificationTitleCache.Entry {
        NotificationTitleCache.Entry(title: title, project: project, runtime: runtime, hostName: hostName, updatedAt: referenceDate)
    }

    /// 模拟 APNs 已按 loc-key 渲染完毕、交给服务扩展时的内容。
    private func systemContent(
        title: String,
        body: String,
        event: String,
        runtime: String = "codex",
        kind: String? = nil,
        sessionTag: String,
        category: String = "MIMI_APPROVAL_DETAILS"
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = sessionTag
        content.categoryIdentifier = category
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        var mimi: [String: Any] = [
            "version": 1,
            "event": event,
            "action_id": "act-0123456789abcdef",
            "device_id": "dev-abc123",
            "profile_id": NotificationSessionTag.profileTag(installationID: "installation-1"),
            "runtime": runtime,
            "host_tag": "A1C3",
            "session_tag": sessionTag,
            "expires_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(300)),
        ]
        if let kind {
            mimi["approval_kind"] = kind
        }
        content.userInfo = ["mimi": mimi]
        return content
    }
}
