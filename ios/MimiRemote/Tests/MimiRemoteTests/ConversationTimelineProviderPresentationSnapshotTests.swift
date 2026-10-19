import SnapshotTesting
import SwiftUI
import XCTest
@testable import MimiRemote

@MainActor
final class ConversationTimelineProviderPresentationSnapshotTests: SimplifiedChineseSnapshotTestCase {
    func testThreeLayerConversationAcrossLayouts() async throws {
        for (name, width, detailed, scheme) in [
            ("phone-default", 390.0, false, ColorScheme.light),
            ("phone-detailed-dark", 390.0, true, ColorScheme.dark),
            ("ipad-default", 820.0, false, ColorScheme.light)
        ] {
            try await assertStabilizedConversationSnapshot(
                of: processConversation(width: width, detailed: detailed, scheme: scheme),
                size: CGSize(width: width, height: 640), named: name
            )
        }
    }

    /// #779 / #537：运行中的过程步骤紧凑排列，思考行直接显示内容，成功与进行中不再写成文字；
    /// 实时状态行固定在本轮所有步骤之后，分组头只保留静态标题。
    func testRunningProcessStepsStayCompactAboveLiveStatus() async throws {
        for (name, scheme) in [("phone-dark", ColorScheme.dark), ("phone-light", ColorScheme.light)] {
            try await assertStabilizedConversationSnapshot(
                of: runningClaudeConversation(width: 390, scheme: scheme),
                size: CGSize(width: 390, height: 480), named: name
            )
        }
    }

    private func runningClaudeConversation(width: CGFloat, scheme: ColorScheme) -> some View {
        let dependencies = makeDependencies()
        let store = dependencies.sessionStore.conversationStore
        let date = Date(timeIntervalSince1970: 1_782_879_660)
        func step(
            _ category: ConversationActivityCategory, _ title: String, subtitle: String? = nil,
            status: String, content: String, preview: String? = nil, command: String? = nil
        ) -> CodexHistoryMessage {
            CodexHistoryMessage(
                role: "system",
                kind: category == .thinking ? .reasoningSummary : .commandSummary,
                content: content,
                activityPayload: ConversationActivityPayload(
                    category: category, displayTitle: title, subtitle: subtitle, status: status,
                    command: command, outputPreview: preview
                ),
                createdAt: date, turnID: "turn-live"
            )
        }
        let firstThought = "先读问题归档规则，再看模型列表从哪里合并了 Codex 模型。\n\n规则要求先查重。"
        let secondThought = "规则要求先查重，然后按关键词搜索相关问题。"
        let read = "cd /Users/me/code/mimi && cat docs/operations/agent-guides/issues.md && git log --oneline -3"
        let search = "git fetch -q origin && gh issue list --search 模型列表 --json number,title"
        store.setHistory([
            CodexHistoryMessage(role: "user", content: "模型列表里混进了 Codex 的模型，帮我查一下", createdAt: date, turnID: "turn-live"),
            step(.thinking, L10n.text("ui.reasoning_summary"), subtitle: firstThought, status: "completed", content: firstThought),
            step(.runCommand, L10n.format("ui.run_value", read), status: "completed",
                 content: "# GitHub 问题归档与执行\n\n### 目标", preview: "# GitHub 问题归档与执行", command: read),
            step(.thinking, L10n.text("ui.reasoning_summary"), subtitle: secondThought, status: "completed", content: secondThought),
            step(.runCommand, L10n.format("ui.run_value", search), status: "inProgress", content: "", command: search)
        ], sessionID: "snapshot-running")
        // 未被选中的会话只读观察：状态行文案与图形都不随时间变化，快照稳定。
        dependencies.sessionStore.sessions = [AgentSession(
            id: "snapshot-running", projectID: "mimi", project: "mimi", dir: "/Users/me/code/mimi",
            title: "模型列表混入 Codex 模型", status: "running", source: "claude", runtimeProvider: "claude",
            resumeID: "thread-snapshot-running", createdAt: date, updatedAt: date, activeTurnID: "turn-live"
        )]
        return ConversationTimelineView(
            layout: ConversationLayout(containerWidth: width, horizontalSizeClass: .compact),
            sessionID: "snapshot-running"
        )
        .environmentObject(dependencies.sessionStore)
        .environmentObject(store)
        .environmentObject(dependencies.themeStore)
        .environment(\.conversationDetailedTranscript, .constant(false))
        .environment(\.colorScheme, scheme)
        .background(dependencies.themeStore.tokens(for: scheme).conversationCanvasBackground)
        .hidingTopScrollEdgeForSnapshot()
        .frame(width: width, height: 480)
    }

    private func processConversation(width: CGFloat, detailed: Bool, scheme: ColorScheme) -> some View {
        let dependencies = makeDependencies()
        let store = dependencies.sessionStore.conversationStore
        let date = Date(timeIntervalSince1970: 1_782_879_660)
        let messages = [
            CodexHistoryMessage(role: "user", content: "简化会话展示，并保留完整过程。", createdAt: date, turnID: "turn"),
            CodexHistoryMessage(role: "assistant", kind: .commentary, content: "已检查会话结构，开始调整过程入口。", createdAt: date, turnID: "turn"),
            CodexHistoryMessage(role: "system", kind: .commandSummary, content: "所有定向测试通过。", activityPayload: ConversationActivityPayload(
                category: .runCommand, displayTitle: "验证会话展示", status: "completed", outputPreview: "测试通过"
            ), createdAt: date, turnID: "turn"),
            CodexHistoryMessage(role: "system", kind: .fileChangeSummary, content: "@@ -1 +1 @@\n-显示全部过程\n+按需展开过程", activityPayload: ConversationActivityPayload(
                category: .editFile, displayTitle: "修改 ConversationView.swift", status: "completed", filePaths: ["ConversationView.swift"]
            ), createdAt: date, turnID: "turn"),
            CodexHistoryMessage(role: "assistant", content: "已完成会话展示调整。\n\n默认保留答复，点击过程入口可查看每一步。", createdAt: date, turnID: "turn")
        ]
        store.setHistory(messages, sessionID: "snapshot-process")
        dependencies.sessionStore.selectedSessionID = "snapshot-process"
        return ConversationTimelineView(layout: ConversationLayout(
            containerWidth: width, horizontalSizeClass: width < 600 ? .compact : .regular
        ))
        .environmentObject(dependencies.sessionStore)
        .environmentObject(store)
        .environmentObject(dependencies.themeStore)
        .environment(\.conversationDetailedTranscript, .constant(detailed))
        .environment(\.colorScheme, scheme)
        .hidingTopScrollEdgeForSnapshot()
        .frame(width: width, height: 640)
    }

    /// #585：Desktop 异步提问的答复经真实历史投影后显示为“已回答”精简气泡，
    /// 不出现协议载荷，并排在紧随其后的普通引导消息之前。只渲染消息行本身，
    /// 不含滚动边缘和输入框材质，避免不同 Simulator 系统版本的合成差异。
    func testAsyncQuestionReplyRendersAsAnswerBubble() async throws {
        let dependencies = makeDependencies()
        let store = dependencies.sessionStore.conversationStore
        store.replaceHistorySnapshot(
            try await QuestionReplyFixture.fullHistory(),
            sessionID: QuestionReplyFixture.threadID
        )
        let rows = store.messages(for: QuestionReplyFixture.threadID).filter {
            ["call_async_question", "user_reply", "user_follow_up"].contains($0.itemID ?? "")
        }
        XCTAssertEqual(rows.map(\.kind), [.message, .questionReply, .message])
        let layout = ConversationLayout(containerWidth: 820, horizontalSizeClass: .regular)
        let view = VStack(spacing: 0) {
            ForEach(rows) { message in
                MessageRow(
                    message: message,
                    themeVersion: dependencies.themeStore.themeVersion,
                    layout: layout,
                    showsActiveDeliveryStatus: false,
                    showsCrossSessionOrigin: false,
                    skills: [],
                    retry: { _ in },
                    stop: {},
                    previewFile: { URL(fileURLWithPath: $0) }
                )
                .padding(layout.messageRowInsets)
            }
            Spacer(minLength: 0)
        }
        .environmentObject(dependencies.sessionStore)
        .environmentObject(store)
        .environmentObject(dependencies.themeStore)
        .environment(\.colorScheme, .light)
        .background(dependencies.themeStore.tokens(for: .light).background)

        assertSnapshot(
            of: view,
            as: .image(
                precision: 0.98,
                layout: .fixed(width: 820, height: 460),
                traits: UITraitCollection(displayScale: 2)
            )
        )
    }

    func testCodexCompactAndDetailedActivityRows() {
        assertSnapshot(
            of: activityRows(provider: .codex),
            as: .image(
                precision: 0.98,
                layout: .fixed(width: 820, height: 560),
                traits: UITraitCollection(displayScale: 2)
            )
        )
    }

    func testClaudeCompactAndDetailedActivityRows() {
        assertSnapshot(
            of: activityRows(provider: .claude),
            as: .image(
                precision: 0.98,
                layout: .fixed(width: 820, height: 560),
                traits: UITraitCollection(displayScale: 2)
            )
        )
    }

    private func activityRows(provider: ConversationTimelineProvider) -> some View {
        let dependencies = makeDependencies()
        let layout = ConversationLayout(containerWidth: 772, horizontalSizeClass: .regular)
        let reasoning = message(
            id: "\(provider.rawValue)-reasoning",
            category: .thinking,
            title: "确认会话状态映射",
            content: "先核对 provider 与消息来源。\n\n然后逐项验证工具状态、完整输出和最终回答的顺序。",
            status: "completed"
        )
        let tool = message(
            id: "\(provider.rawValue)-tool",
            category: .toolCall,
            title: "读取远端配置",
            content: "配置读取完成。\nfeature_flag = enabled\ntimeout = 30",
            status: "completed",
            preview: "配置读取完成 · feature_flag = enabled"
        )
        let file = message(
            id: "\(provider.rawValue)-file",
            category: .editFile,
            title: "修改 ConversationView.swift",
            content: "@@ -42,2 +42,2 @@\n-旧展示\n+新展示",
            status: "completed",
            paths: ["ios/MimiRemote/ConversationView.swift"]
        )
        let failure = message(
            id: "\(provider.rawValue)-failure",
            category: .toolCall,
            title: "调用 MCP 工具",
            content: "permission denied\n请检查当前工具授权。",
            status: "failed",
            preview: "permission denied"
        )

        return VStack(alignment: .leading, spacing: 8) {
            ConversationActivityRow(
                message: reasoning,
                layout: layout,
                provider: provider,
                showsDetailedTranscript: false,
                isExpanded: false,
                toggle: {}
            )
            ConversationActivityRow(
                message: tool,
                layout: layout,
                provider: provider,
                showsDetailedTranscript: false,
                isExpanded: false,
                toggle: {}
            )
            ConversationActivityRow(
                message: provider == .codex ? file : failure,
                layout: layout,
                provider: provider,
                showsDetailedTranscript: false,
                isExpanded: true,
                toggle: {}
            )
            ConversationActivityRow(
                message: reasoning,
                layout: layout,
                provider: provider,
                showsDetailedTranscript: true,
                isExpanded: true,
                toggle: {}
            )
            Spacer(minLength: 0)
        }
        .padding(24)
        .environmentObject(dependencies.sessionStore)
        .environmentObject(dependencies.themeStore)
        .environment(\.colorScheme, .light)
        .background(dependencies.themeStore.tokens(for: .light).background)
    }

    private func message(
        id: String,
        category: ConversationActivityCategory,
        title: String,
        content: String,
        status: String,
        preview: String? = nil,
        paths: [String] = []
    ) -> ConversationMessage {
        ConversationMessage(
            stableID: id,
            turnID: "snapshot-turn",
            role: .system,
            kind: category == .editFile ? .fileChangeSummary : category == .thinking ? .reasoningSummary : .commandSummary,
            content: content,
            sendStatus: .confirmed,
            activityPayload: ConversationActivityPayload(
                category: category,
                displayTitle: title,
                subtitle: category == .thinking ? title : nil,
                status: status,
                filePaths: paths,
                outputPreview: preview
            ),
            turnLifecycle: .completed
        )
    }

    private func makeDependencies() -> (sessionStore: SessionStore, themeStore: ThemeStore) {
        let suiteName = "ConversationTimelineProviderSnapshots.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let appStore = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations())
        )
        let conversationStore = ConversationStore()
        conversationStore.activate(profileID: appStore.activeHostScope.profileID)
        return (
            SessionStore(appStore: appStore, conversationStore: conversationStore, logStore: LogStore()),
            ThemeStore(defaults: defaults)
        )
    }
}

private extension View {
    /// PR Gate 的 iOS 26.2 静止时不画顶部滚动边缘虚化，本机 iOS 27.2 会画；时间线快照只比对
    /// 正文与行距，关掉顶部边缘效果，两个版本录出的基线才能互相通过。
    @ViewBuilder
    func hidingTopScrollEdgeForSnapshot() -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectHidden(true, for: .top)
        } else {
            self
        }
    }
}
