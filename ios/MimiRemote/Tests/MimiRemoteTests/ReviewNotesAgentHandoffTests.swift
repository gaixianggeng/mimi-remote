import Combine
import SwiftUI
import UIKit
import XCTest
@testable import MimiRemote

/// 审查备注发给 Agent（#847）：消息格式、目标会话选择、草稿追加与重复发送。
@MainActor
final class ReviewNotesAgentHandoffTests: XCTestCase {
    private let workspace = "/Users/dev/repo"

    // MARK: - 消息格式

    func testMessageListsOneLinePerNoteInChinese() {
        withAppLanguage(.simplifiedChinese) {
            let message = GitReviewNotesAgentMessage.make(from: [
                comment(path: "ios/App.swift", header: "@@ -10,6 +10,8 @@ struct App", body: "这里需要判空"),
                comment(path: "go/main.go", header: "@@ -1,3 +1,4 @@", body: "第一行\n\n  第二行  "),
            ])

            XCTAssertEqual(message, """
            请按以下审阅意见修改：
            - `ios/App.swift` · @@ -10,6 +10,8 @@ struct App：这里需要判空
            - `go/main.go` · @@ -1,3 +1,4 @@：第一行 第二行
            """)
        }
    }

    func testMessageFollowsEnglishAppLanguage() {
        withAppLanguage(.english) {
            let message = GitReviewNotesAgentMessage.make(from: [
                comment(path: "ios/App.swift", header: "@@ -10,6 +10,8 @@", body: "Add a nil check"),
            ])

            XCTAssertEqual(message, """
            Please revise the code according to these review notes:
            - `ios/App.swift` · @@ -10,6 +10,8 @@: Add a nil check
            """)
        }
    }

    func testMessageSkipsBlankNotesAndOmitsMissingPath() {
        withAppLanguage(.simplifiedChinese) {
            XCTAssertEqual(GitReviewNotesAgentMessage.make(from: []), "")
            XCTAssertEqual(GitReviewNotesAgentMessage.make(from: [comment(body: " \n ")]), "", "只有空白备注时不生成消息")

            let message = GitReviewNotesAgentMessage.make(from: [
                comment(path: "", header: "@@ -1 +1 @@", body: "改名"),
                comment(body: "   "),
            ])
            XCTAssertEqual(message, "请按以下审阅意见修改：\n- @@ -1 +1 @@：改名")
        }
    }

    // MARK: - 目标会话

    func testTargetRequiresSelectedSessionInSameWorkspace() {
        XCTAssertEqual(resolve(session: nil), .unavailable(.noSession))
        XCTAssertEqual(
            resolve(session: session(), sessionDirectory: "/Users/dev/other"),
            .unavailable(.otherWorkspace)
        )
        XCTAssertEqual(
            resolve(session: session(), sessionDirectory: ""),
            .unavailable(.otherWorkspace),
            "没有工作目录的会话不能当成任何工作区的目标"
        )
        XCTAssertEqual(
            resolve(session: session(), sessionDirectory: workspace + "/"),
            .session("session-1"),
            "路径只按词法归一化比较，末尾斜杠不影响"
        )
    }

    func testTargetExplainsWhySessionCannotReceiveNotes() {
        let held = session(
            runtimeProvider: "claude",
            canAcceptDirectInput: false,
            claudeOwner: ClaudeSessionOwner(entrypoint: "cli", kind: "interactive", status: "idle", pid: 42)
        )
        XCTAssertEqual(resolve(session: held, canControl: false), .unavailable(.heldOnComputer))
        XCTAssertEqual(resolve(session: session(isSubagent: true), canControl: false), .unavailable(.readOnly))
        XCTAssertEqual(resolve(session: session(), canControl: false), .unavailable(.notControllable))
        XCTAssertEqual(resolve(session: session(), runtimeAvailable: false), .unavailable(.runtimeUnavailable))
        XCTAssertEqual(resolve(session: session()), .session("session-1"))
    }

    func testStoreResolvesTargetFromSelectedSession() {
        let store = makeStore()
        XCTAssertEqual(store.reviewNotesAgentTarget(workspacePath: workspace), .unavailable(.noSession))

        store.sessionsByID["session-1"] = session()
        store.selectedSessionID = "session-1"
        XCTAssertEqual(store.reviewNotesAgentTarget(workspacePath: workspace), .session("session-1"))
        XCTAssertEqual(store.reviewNotesAgentTarget(workspacePath: "/Users/dev/other"), .unavailable(.otherWorkspace))

        store.sessionsByID["session-1"] = session(runtimeProvider: "claude")
        store.availableRuntimeProviders = ["codex"]
        XCTAssertEqual(
            store.reviewNotesAgentTarget(workspacePath: workspace),
            .unavailable(.runtimeUnavailable),
            "电脑上没开 Claude 通道时不能把备注放进 Claude 会话"
        )

        store.sessionsByID["session-1"] = session(status: "running")
        XCTAssertEqual(
            store.reviewNotesAgentTarget(workspacePath: workspace),
            .unavailable(.notControllable),
            "在其他客户端运行、本机只在观察的会话不能写入"
        )
    }

    // MARK: - 草稿追加

    func testAppendWritesOnlyTargetDraftAndKeepsExistingContent() {
        let store = makeStore()
        let target = ComposerDraftScopeKey.session("session-1")
        let other = ComposerDraftScopeKey.session("session-2")
        let attachment = CodexAppServerUserInput.mention(name: "App.swift", path: "/Users/dev/repo/App.swift")
        store.saveComposerDraft(
            ComposerDraftSnapshot(text: "先看一下测试\n\n  ", attachments: [attachment], voiceDraftNeedsReview: false),
            for: target
        )
        store.saveComposerDraft(
            ComposerDraftSnapshot(text: "别的会话", attachments: [], voiceDraftNeedsReview: false),
            for: other
        )

        XCTAssertTrue(store.appendComposerDraftText("请按以下审阅意见修改：\n- a", to: target))

        XCTAssertEqual(store.composerDraft(for: target).text, "先看一下测试\n\n请按以下审阅意见修改：\n- a")
        XCTAssertEqual(store.composerDraft(for: target).attachments, [attachment], "追加文字不能动已有附件")
        XCTAssertEqual(store.composerDraft(for: other).text, "别的会话", "不能串到其他会话")
    }

    func testAppendToEmptyDraftNotifiesComposerOnce() {
        let store = makeStore()
        let target = ComposerDraftScopeKey.session("session-1")
        var events: [ComposerDraftAppendEvent] = []
        let subscription = store.composerDraftAppends.sink { events.append($0) }
        defer { subscription.cancel() }

        XCTAssertTrue(store.appendComposerDraftText("  备注  \n", to: target))
        XCTAssertFalse(store.appendComposerDraftText(" \n ", to: target), "空内容不追加")
        XCTAssertFalse(store.appendComposerDraftText("备注", to: .none), "没有作用域时不追加")

        XCTAssertEqual(store.composerDraft(for: target).text, "备注")
        XCTAssertEqual(events.map(\.text), ["备注"])
        XCTAssertEqual(events.map(\.targetScope), [target])
    }

    func testVisibleComposerShowsAppendedNotesAndKeepsThemAfterDisappearing() throws {
        let suiteName = "ReviewNotesAgentHandoffTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = makeStore()
        store.sessionsByID["session-1"] = session()
        store.selectedSessionID = "session-1"
        let scope = ComposerDraftScopeKey.session("session-1")
        store.saveComposerDraft(
            ComposerDraftSnapshot(text: "先看一下测试", attachments: [], voiceDraftNeedsReview: false),
            for: scope
        )
        let windowScene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let host = UIHostingController(
            rootView: ComposerView(availableWidth: 744)
                .environmentObject(store)
                .environmentObject(ThemeStore(defaults: defaults))
                .environment(\.horizontalSizeClass, .regular)
                .defaultAppStorage(defaults)
                .frame(width: 744, height: 360)
        )
        let window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(x: 0, y: 0, width: 744, height: 360)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        XCTAssertTrue(spin(until: { self.composerText(in: host.view) == "先看一下测试" }), "输入框先恢复已有草稿")

        XCTAssertTrue(store.appendComposerDraftText("请按以下审阅意见修改：\n- a", to: scope))

        let expected = "先看一下测试\n\n请按以下审阅意见修改：\n- a"
        XCTAssertTrue(
            spin(until: { self.composerText(in: host.view) == expected }),
            "输入框可见时直接显示追加的备注，不用切走再切回"
        )
        // 输入框离开时会把自己的内存草稿写回仓；没接住追加的话这里会被旧文本覆盖。
        // 仓里本来就是追加后的文本，只能固定等一会儿让 onDisappear 跑完再比对。
        window.rootViewController = nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(store.composerDraft(for: scope).text, expected)
    }

    func testAppendingTextKeepsUserTextAndSeparatesWithBlankLine() {
        XCTAssertEqual(ComposerDraftTextAppend.appending("B", to: ""), "B")
        XCTAssertEqual(ComposerDraftTextAppend.appending("B", to: " \n"), "B")
        XCTAssertEqual(ComposerDraftTextAppend.appending("B", to: "  A"), "  A\n\nB", "原文开头的缩进保持不变")
        XCTAssertEqual(ComposerDraftTextAppend.appending("B", to: "A\n\n\n"), "A\n\nB")
    }

    // MARK: - 重复发送

    func testSecondSendOnlyAppendsNewNotes() {
        var handoff = GitReviewNotesHandoff()
        let first = comment(body: "一")
        let second = comment(body: "二")

        XCTAssertEqual(handoff.commentsToSend(from: [first], workspacePath: workspace, sessionID: "s1"), [first])
        handoff.record([first], workspacePath: workspace, sessionID: "s1", sessionTitle: "修复登录")
        XCTAssertEqual(handoff.sentSessionTitle(for: [first], workspacePath: workspace), "修复登录")

        XCTAssertNil(handoff.sentSessionTitle(for: [first, second], workspacePath: workspace), "有新备注时不再显示已放入")
        XCTAssertEqual(handoff.commentsToSend(from: [first, second], workspacePath: workspace, sessionID: "s1"), [second])
        XCTAssertEqual(
            handoff.commentsToSend(from: [first, second], workspacePath: workspace, sessionID: "s2"),
            [first, second],
            "换了会话要整份发送"
        )

        handoff.record([second], workspacePath: workspace, sessionID: "s1", sessionTitle: "修复登录")
        XCTAssertEqual(
            handoff.commentsToSend(from: [first, second], workspacePath: workspace, sessionID: "s1"),
            [first, second],
            "全部发过后再点一次表示整份重新放入"
        )

        handoff.reset(workspacePath: workspace)
        XCTAssertNil(handoff.sentSessionTitle(for: [first, second], workspacePath: workspace))
    }

    func testCardKeepsSentFeedbackAndExplainsWhyResendIsDisabled() {
        func box(_ target: ReviewNotesAgentTarget, sent: String?) -> GitReviewNotesAgentBox {
            GitReviewNotesAgentBox(
                commentCount: 2,
                target: target,
                sentSessionTitle: sent,
                targetSessionTitle: "修复登录",
                onSend: {},
                onClear: {}
            )
        }

        XCTAssertEqual(box(.session("s1"), sent: nil).statusLines, [.ready(sessionTitle: "修复登录")])
        XCTAssertTrue(box(.session("s1"), sent: nil).canSend)
        XCTAssertEqual(box(.session("s1"), sent: "修复登录").statusLines, [.sent(sessionTitle: "修复登录")])

        let afterTargetLost = box(.unavailable(.otherWorkspace), sent: "修复登录")
        XCTAssertEqual(
            afterTargetLost.statusLines,
            [.sent(sessionTitle: "修复登录"), .unavailable(.otherWorkspace)],
            "发过之后目标不可用，仍要说明「再次发送」为什么不能点"
        )
        XCTAssertFalse(afterTargetLost.canSend)
        XCTAssertEqual(box(.unavailable(.readOnly), sent: nil).statusLines, [.unavailable(.readOnly)])
    }

    // MARK: - Helpers

    private func resolve(
        session: AgentSession?,
        sessionDirectory: String? = nil,
        canControl: Bool = true,
        runtimeAvailable: Bool = true
    ) -> ReviewNotesAgentTarget {
        ReviewNotesAgentTarget.resolve(
            workspacePath: workspace,
            session: session,
            sessionDirectory: sessionDirectory ?? workspace,
            canControlSession: canControl,
            isRuntimeAvailable: runtimeAvailable
        )
    }

    private func comment(
        path: String = "ios/App.swift",
        header: String = "@@ -1,2 +1,3 @@",
        body: String
    ) -> GitReviewComment {
        GitReviewComment(
            workspacePath: workspace,
            hunkKey: "\(path)\(header)",
            filePath: path,
            hunkHeader: header,
            body: body,
            createdAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func session(
        status: String = "idle",
        runtimeProvider: String = "codex",
        isSubagent: Bool? = nil,
        canAcceptDirectInput: Bool? = nil,
        claudeOwner: ClaudeSessionOwner? = nil
    ) -> AgentSession {
        AgentSession(
            id: "session-1",
            projectID: "project-1",
            project: "repo",
            dir: workspace,
            title: "Review",
            status: status,
            source: runtimeProvider,
            runtimeProvider: runtimeProvider,
            resumeID: "session-1",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            isSubagent: isSubagent,
            canAcceptDirectInput: canAcceptDirectInput,
            claudeOwner: claudeOwner
        )
    }

    private func composerText(in root: UIView) -> String? {
        if let textView = root as? UITextView {
            return textView.text
        }
        for child in root.subviews {
            if let text = composerText(in: child) {
                return text
            }
        }
        return nil
    }

    private func spin(until condition: () -> Bool, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private func makeStore() -> SessionStore {
        SessionStore(appStore: makeIsolatedAppStore(), conversationStore: ConversationStore(), logStore: LogStore())
    }

    private func withAppLanguage(_ language: AppLanguage, _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: AppLanguage.preferenceKey)
        defaults.set(language.rawValue, forKey: AppLanguage.preferenceKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: AppLanguage.preferenceKey)
            } else {
                defaults.removeObject(forKey: AppLanguage.preferenceKey)
            }
        }
        body()
    }
}
