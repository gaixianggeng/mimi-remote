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
        .frame(width: width, height: 640)
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
