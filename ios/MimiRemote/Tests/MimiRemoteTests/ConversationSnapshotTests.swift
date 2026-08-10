import XCTest
import SwiftUI
import UIKit
import SnapshotTesting
@testable import MimiRemote

enum SnapshotTestEnvironment {
    static let requiredSimulatorName = "iPad Pro 13-inch (M5)"

    static func requireFixedSimulator() throws {
        let actualName = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"]
            ?? UIDevice.current.name
        guard actualName == requiredSimulatorName else {
            throw NSError(
                domain: "MimiRemoteSnapshotEnvironment",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "视觉快照必须在 \(requiredSimulatorName) 运行；当前目标是 \(actualName)。"
                ]
            )
        }
    }
}

@MainActor
class SimplifiedChineseSnapshotTestCase: XCTestCase {
    private var hadStoredAppLanguage = false
    private var previousAppLanguageRawValue: String?
    private var didOverrideAppLanguage = false

    override func setUpWithError() throws {
        try super.setUpWithError()
        try SnapshotTestEnvironment.requireFixedSimulator()
        let defaults = UserDefaults.standard
        hadStoredAppLanguage = defaults.object(forKey: AppLanguage.preferenceKey) != nil
        previousAppLanguageRawValue = defaults.string(forKey: AppLanguage.preferenceKey)
        defaults.set(AppLanguage.simplifiedChinese.rawValue, forKey: AppLanguage.preferenceKey)
        didOverrideAppLanguage = true
    }

    override func tearDownWithError() throws {
        if didOverrideAppLanguage {
            let defaults = UserDefaults.standard
            if hadStoredAppLanguage {
                defaults.set(previousAppLanguageRawValue, forKey: AppLanguage.preferenceKey)
            } else {
                defaults.removeObject(forKey: AppLanguage.preferenceKey)
            }
            didOverrideAppLanguage = false
        }
        try super.tearDownWithError()
    }
}

@MainActor
final class ConversationSnapshotTests: SimplifiedChineseSnapshotTestCase {
    // 快照只验证布局和样式，消息时间固定，避免每次运行因当前分钟变化产生视觉误报。
    private let snapshotMessageDate = Date(timeIntervalSince1970: 1_782_879_660)

    override func setUpWithError() throws {
        try super.setUpWithError()
        // 目标名称已固定到 M5 iPad；这里再保护 iPad trait，避免 Universal
        // 目标从 Xcode 直接运行时把 iPhone 结果当成快照基线。
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "Snapshot 基线按 iPad 设备录制，iPhone 目标跳过这组视觉基线。"
        )
    }

    func testWorkspaceOpenCurrentDirectoryButton() {
        let view = WorkspaceOpenCurrentDirectoryButton(
            directoryName: "gaixiaotongxue",
            isOpening: false,
            isDisabled: false,
            action: {}
        )
        .environmentObject(makeThemeStore())
        .environment(\.colorScheme, .light)
        .padding(20)
        .frame(width: 390, height: 110)
        .background(Color(uiColor: .systemGroupedBackground))

        assertSnapshot(
            of: view,
            as: .image(precision: 0.98, layout: .fixed(width: 390, height: 110))
        )
    }

    // 固定尺寸 + 固定内容，专门锁住气泡对齐这类纯视觉回归（user 贴右、assistant/system 贴左）。
    // 默认保持浅色基线；需要验证深色配色时显式传入 colorScheme，避免依赖 Simulator 当前外观。
    // 首次运行会自动录制参考图到 __Snapshots__/，之后逐像素对比。
    private func makeSeededConversation(colorScheme: ColorScheme = .light) -> some View {
        let sessionID = "snapshot_session"
        let appStore = makeSnapshotAppStore()
        let conversationStore = makeSnapshotConversationStore(appStore: appStore)
        let themeStore = makeThemeStore()

        conversationStore.appendSystem("Codex 交互式会话已启动。", sessionID: sessionID, createdAt: snapshotMessageDate)
        conversationStore.appendUser("2216", sessionID: sessionID, createdAt: snapshotMessageDate)
        conversationStore.applyAssistantDelta(
            AgentDelta(text: "这是助手的回复，应当靠左对齐，使用低对比中性气泡。", role: .assistant, kind: .message),
            metadata: AgentEventMetadata(
                seq: 1,
                sessionID: sessionID,
                turnID: "turn_1",
                itemID: "item_1",
                messageID: nil,
                clientMessageID: nil,
                revision: 1,
                createdAt: snapshotMessageDate
            ),
            fallbackSessionID: sessionID
        )
        conversationStore.appendUser(
            "这是一条比较长的用户消息，用来验证多行情况下中性气泡依然贴右对齐，而不是漂到屏幕中间。",
            sessionID: sessionID,
            createdAt: snapshotMessageDate
        )
        // 发送失败：验证红色状态标记出现在用户气泡左侧。
        conversationStore.appendLocalUser(
            "这条发送失败了",
            sessionID: sessionID,
            clientMessageID: "failed-1",
            sendStatus: .failed,
            createdAt: snapshotMessageDate
        )

        let sessionStore = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore()
        )
        sessionStore.selectedSessionID = sessionID

        return ConversationView()
            .environmentObject(sessionStore)
            .environmentObject(conversationStore)
            .environmentObject(themeStore)
            .environment(\.colorScheme, colorScheme)
            .frame(width: 1024, height: 768)
    }

    private func makeEmptyConversation(
        workspacePath: String,
        colorScheme: ColorScheme,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        let project = AgentProject(
            id: "snapshot-empty-workspace",
            name: URL(fileURLWithPath: workspacePath).lastPathComponent,
            path: workspacePath
        )
        let appStore = makeSnapshotAppStore()
        let conversationStore = makeSnapshotConversationStore(appStore: appStore)
        let themeStore = makeThemeStore()
        let sessionStore = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore()
        )
        sessionStore.projects = [project]
        sessionStore.sidebarProjects = [project]
        sessionStore.selectedProjectID = project.id

        return ConversationView()
            .environmentObject(sessionStore)
            .environmentObject(conversationStore)
            .environmentObject(themeStore)
            .environment(\.colorScheme, colorScheme)
            .environment(\.horizontalSizeClass, width < 560 ? .compact : .regular)
            .frame(width: width, height: height)
    }

    private func makeRichMarkdownConversation() -> some View {
        let sessionID = "snapshot_markdown_session"
        let appStore = makeSnapshotAppStore()
        let conversationStore = makeSnapshotConversationStore(appStore: appStore)
        let themeStore = makeThemeStore()
        let markdown = """
        # Markdown 验收

        这段包含 **粗体**、*斜体*、~~删除线~~、`inline code` 和 [安全链接](https://example.com)。

        - [x] 已完成任务
        - 普通列表项
        - [ ] 待处理任务

        > 引用内容保持克制缩进，不应该压迫主文本。

        | 指标 | 数值 | 状态 |
        |:---|---:|:---:|
        | latency | 42 | ok |
        | tokens | 1280 | warn |

        ```swift
        let message = "hello markdown"
        print(message)
        ```
        """

        conversationStore.applyAssistantDelta(
            AgentDelta(text: markdown, role: .assistant, kind: .message),
            metadata: AgentEventMetadata(
                seq: 1,
                sessionID: sessionID,
                turnID: "turn_markdown",
                itemID: "item_markdown",
                messageID: nil,
                clientMessageID: nil,
                revision: 1,
                createdAt: snapshotMessageDate
            ),
            fallbackSessionID: sessionID
        )

        let sessionStore = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore()
        )
        sessionStore.selectedSessionID = sessionID

        return ConversationView()
            .environmentObject(sessionStore)
            .environmentObject(conversationStore)
            .environmentObject(themeStore)
            .environment(\.colorScheme, .light)
            .frame(width: 1024, height: 768)
    }

    private func makeCrossSessionContinuationConversation() -> some View {
        let sessionID = "snapshot_cross_session_continuation"
        let appStore = makeSnapshotAppStore()
        let conversationStore = makeSnapshotConversationStore(appStore: appStore)
        let themeStore = makeThemeStore()
        let issueURL = "https://linear.app/code89757/issue/MIM-24/在-ios-中查看并进入-codex-子-agent-会话"

        conversationStore.appendUser(
            "[\(issueURL)](\(issueURL)) 帮我继续修复一下这个问题。\n[$delegate-to-chatgpt-pro](/Users/demo/.codex/skills/delegate-to-chatgpt-pro/SKILL.md)",
            sessionID: sessionID,
            createdAt: snapshotMessageDate
        )
        conversationStore.applyAssistantDelta(
            AgentDelta(
                text: """
                已完成 MIM-24 的本地修复，问题来自继承会话历史的投影逻辑。

                验证结果：
                - 固定 M5 iPad 模拟器测试通过
                - 普通会话消息排版保持不变

                ::git-stage{cwd="/Users/demo/code/codex-ipad-agent"}
                ::git-commit{cwd="/Users/demo/code/codex-ipad-agent"}
                ::git-push{cwd="/Users/demo/code/codex-ipad-agent" branch="codex/mim-24-fix"}
                """,
                role: .assistant,
                kind: .message
            ),
            metadata: AgentEventMetadata(
                seq: 1,
                sessionID: sessionID,
                turnID: "turn_cross_session",
                itemID: "item_cross_session",
                messageID: nil,
                clientMessageID: nil,
                revision: 1,
                createdAt: snapshotMessageDate
            ),
            fallbackSessionID: sessionID
        )

        let sessionStore = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore()
        )
        sessionStore.selectedSessionID = sessionID

        return ConversationView()
            .environmentObject(sessionStore)
            .environmentObject(conversationStore)
            .environmentObject(themeStore)
            .environment(\.colorScheme, .dark)
            .frame(width: 1024, height: 768)
    }

    private func makeMixedActivityConversation() async -> some View {
        let sessionID = "snapshot_mixed_activity"
        let turnID = "turn_mixed_activity"
        let appStore = makeSnapshotAppStore()
        let conversationStore = makeSnapshotConversationStore(appStore: appStore)
        let themeStore = makeThemeStore()
        let landscapeImage = snapshotImageDataURL(size: CGSize(width: 420, height: 210), accent: .systemPurple)
        let portraitImage = snapshotImageDataURL(size: CGSize(width: 240, height: 360), accent: .systemOrange)
        // 生产视图仍通过 `.task(id:)` 异步解码；快照先填充同一缓存，确保捕获的是稳定完成态。
        _ = await DataURLImageDecoder.image(
            from: landscapeImage,
            cacheKey: ConversationImageSource.markdown(landscapeImage).id,
            profileID: appStore.notificationRoutingProfileID,
            maxPixelSize: 1_600
        )
        _ = await DataURLImageDecoder.image(
            from: portraitImage,
            cacheKey: ConversationImageSource.markdown(portraitImage).id,
            profileID: appStore.notificationRoutingProfileID,
            maxPixelSize: 1_600
        )
        let history = [
            CodexHistoryMessage(
                id: "mixed-user",
                role: "user",
                content: "请检查这两张 iPad 截图 [图片] [图片]",
                turnPayload: CodexAppServerTurnPayload(input: [
                    .text("请检查这两张 iPad 截图"),
                    .image(url: landscapeImage),
                    .image(url: portraitImage)
                ]),
                createdAt: snapshotMessageDate,
                turnID: turnID,
                sendStatus: .confirmed
            ),
            CodexHistoryMessage(
                id: "mixed-reasoning",
                role: "system",
                kind: .reasoningSummary,
                content: "先核对输入框和过程时间线的层级。",
                activityPayload: ConversationActivityPayload(
                    category: .thinking,
                    displayTitle: "推理摘要",
                    subtitle: "先核对输入框和过程时间线的层级。"
                ),
                createdAt: snapshotMessageDate.addingTimeInterval(1),
                turnID: turnID,
                sendStatus: .confirmed
            ),
            CodexHistoryMessage(
                id: "mixed-read",
                role: "system",
                kind: .commandSummary,
                content: "命令：sed -n 1,180p ConversationView.swift",
                activityPayload: ConversationActivityPayload(
                    category: .runCommand,
                    displayTitle: "查看 ConversationView.swift",
                    status: "completed",
                    command: "sed -n 1,180p ConversationView.swift"
                ),
                createdAt: snapshotMessageDate.addingTimeInterval(2),
                turnID: turnID,
                sendStatus: .confirmed
            ),
            CodexHistoryMessage(
                id: "mixed-search",
                role: "system",
                kind: .commandSummary,
                content: "命令：rg ProcessedTurnRow",
                activityPayload: ConversationActivityPayload(
                    category: .runCommand,
                    displayTitle: "搜索 ProcessedTurnRow",
                    status: "completed",
                    command: "rg ProcessedTurnRow"
                ),
                createdAt: snapshotMessageDate.addingTimeInterval(3),
                turnID: turnID,
                sendStatus: .confirmed
            ),
            CodexHistoryMessage(
                id: "mixed-build",
                role: "system",
                kind: .commandSummary,
                content: "命令：xcodebuild test",
                activityPayload: ConversationActivityPayload(
                    category: .runCommand,
                    displayTitle: "运行 xcodebuild test",
                    status: "completed",
                    command: "xcodebuild test",
                    cwd: "/Users/me/code/codex-ipad-agent",
                    exitCode: 0,
                    outputPreview: "Testing started\n** TEST SUCCEEDED **"
                ),
                createdAt: snapshotMessageDate.addingTimeInterval(4),
                turnID: turnID,
                sendStatus: .confirmed
            ),
            CodexHistoryMessage(
                id: "mixed-diff",
                role: "system",
                kind: .fileChangeSummary,
                content: "文件变更：ConversationView.swift modified",
                activityPayload: ConversationActivityPayload(
                    category: .editFile,
                    displayTitle: "修改 ConversationView.swift",
                    status: "completed",
                    filePaths: ["ios/MimiRemote/Sources/Features/Conversation/ConversationView.swift"]
                ),
                createdAt: snapshotMessageDate.addingTimeInterval(5),
                turnID: turnID,
                sendStatus: .confirmed
            ),
            CodexHistoryMessage(
                id: "mixed-input",
                role: "system",
                kind: .userInput,
                content: "补充信息已提交：固定中文",
                createdAt: snapshotMessageDate.addingTimeInterval(6),
                turnID: turnID,
                sendStatus: .confirmed
            ),
            CodexHistoryMessage(
                id: "mixed-final",
                role: "assistant",
                content: "已按 iPad 高频操作方式整理完成。",
                createdAt: snapshotMessageDate.addingTimeInterval(7),
                turnID: turnID,
                sendStatus: .confirmed
            )
        ]
        conversationStore.setHistory(history, sessionID: sessionID)

        let sessionStore = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore()
        )
        sessionStore.selectedSessionID = sessionID

        return ConversationView()
            .environmentObject(sessionStore)
            .environmentObject(conversationStore)
            .environmentObject(themeStore)
            .environment(\.colorScheme, .light)
            .frame(width: 1024, height: 900)
    }

    private func makeSingleImageMessage(
        containerWidth: CGFloat,
        imageSize: CGSize,
        accent: UIColor,
        usesRemoteURL: Bool = false
    ) async -> some View {
        let appStore = makeSnapshotAppStore()
        let conversationStore = makeSnapshotConversationStore(appStore: appStore)
        let themeStore = makeThemeStore()
        let imageURL = usesRemoteURL
            ? "https://example.com/snapshot-\(Int(imageSize.width))x\(Int(imageSize.height)).png"
            : snapshotImageDataURL(size: imageSize, accent: accent)
        let imageSource = ConversationImageSource.markdown(imageURL)
        // 生产视图会异步解码图片；快照预热对应来源的缓存，确保只比较完成态布局。
        if usesRemoteURL {
            RemoteURLImageLoader.storeImageForTesting(
                snapshotImage(size: imageSize, accent: accent),
                cacheKey: imageSource.id,
                profileID: appStore.notificationRoutingProfileID,
                maxPixelSize: 1_600
            )
        } else {
            _ = await DataURLImageDecoder.image(
                from: imageURL,
                cacheKey: imageSource.id,
                profileID: appStore.notificationRoutingProfileID,
                maxPixelSize: 1_600
            )
        }

        let sessionStore = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore()
        )
        let message = ConversationMessage(
            stableID: "snapshot-single-image-\(Int(containerWidth))-\(Int(imageSize.width))x\(Int(imageSize.height))",
            role: .user,
            content: "[图片]",
            createdAt: snapshotMessageDate,
            sendStatus: .confirmed,
            turnPayload: CodexAppServerTurnPayload(input: [.image(url: imageURL)])
        )
        let horizontalSizeClass: UserInterfaceSizeClass = containerWidth < 560 ? .compact : .regular
        let layout = ConversationLayout(
            containerWidth: containerWidth,
            horizontalSizeClass: horizontalSizeClass
        )

        return VStack(spacing: 0) {
            MessageRow(
                message: message,
                themeVersion: themeStore.themeVersion,
                layout: layout,
                showsActiveDeliveryStatus: false,
                showsCrossSessionOrigin: false,
                skills: [],
                retry: { _ in },
                stop: {},
                previewFile: { URL(fileURLWithPath: $0) }
            )
            .padding(layout.messageRowInsets)

            Spacer(minLength: 0)
        }
        .environmentObject(sessionStore)
        .environmentObject(conversationStore)
        .environmentObject(themeStore)
        .environment(\.colorScheme, .light)
        .background(themeStore.tokens(for: .light).background)
        .frame(width: containerWidth, height: 390)
    }

    private func makeUnavailableUserImageGallery() -> some View {
        let sessionID = "snapshot_unavailable_user_images"
        let appStore = makeSnapshotAppStore()
        let conversationStore = makeSnapshotConversationStore(appStore: appStore)
        let themeStore = makeThemeStore()
        let unavailableImages = [
            "codex-clipboard-9ba62714-bcfb-4693-805b-1be6e284e924.png",
            "codex-clipboard-fcc85816-9d5f-4ea6-919a-ea89b639a5d9.png",
            "codex-clipboard-15031bdc-111a-4669-b3e6-4ef5f2094829.png",
            "codex-clipboard-f64f3119-46f6-479a-b93d-abc5d81f879f.png"
        ]
        let imageInput = unavailableImages.map { CodexAppServerUserInput.image(url: $0) }

        conversationStore.setHistory([
            CodexHistoryMessage(
                id: "unavailable-images-user",
                role: "user",
                content: "请评估这四张封面",
                turnPayload: CodexAppServerTurnPayload(
                    input: [.text("请评估这四张封面")] + imageInput
                ),
                createdAt: snapshotMessageDate,
                turnID: "turn_unavailable_images",
                sendStatus: .confirmed
            )
        ], sessionID: sessionID)

        let sessionStore = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore()
        )
        sessionStore.selectedSessionID = sessionID

        return ConversationView()
            .environmentObject(sessionStore)
            .environmentObject(conversationStore)
            .environmentObject(themeStore)
            .environment(\.colorScheme, .light)
            .frame(width: 1024, height: 900)
    }

    private func makeExpandedProcessGroup() -> some View {
        let themeStore = makeThemeStore()
        let turnID = "snapshot-process-group"
        let reasoning = ConversationMessage(
            stableID: "snapshot-process-reasoning",
            turnID: turnID,
            role: .system,
            kind: .reasoningSummary,
            content: "Planning backend migration testing with Docker",
            createdAt: snapshotMessageDate,
            sendStatus: .confirmed,
            activityPayload: ConversationActivityPayload(
                category: .thinking,
                displayTitle: "推理摘要",
                subtitle: "Planning backend migration testing with Docker"
            )
        )
        let command = ConversationMessage(
            stableID: "snapshot-process-command",
            turnID: turnID,
            role: .system,
            kind: .commandSummary,
            content: "命令：docker compose run --rm api go test ./...",
            createdAt: snapshotMessageDate.addingTimeInterval(1),
            sendStatus: .confirmed,
            activityPayload: ConversationActivityPayload(
                category: .runCommand,
                displayTitle: "运行后端迁移测试",
                status: "completed",
                command: "docker compose run --rm api go test ./...",
                cwd: "/Users/me/code/chat-archive",
                exitCode: 0
            )
        )
        let file = ConversationMessage(
            stableID: "snapshot-process-file",
            turnID: turnID,
            role: .system,
            kind: .fileChangeSummary,
            content: "文件变更：internal/config/config_test.go modified",
            createdAt: snapshotMessageDate.addingTimeInterval(2),
            sendStatus: .confirmed,
            activityPayload: ConversationActivityPayload(
                category: .editFile,
                displayTitle: "修改 config_test.go",
                status: "completed",
                filePaths: ["internal/config/config_test.go"]
            )
        )
        let group = ConversationProcessGroup(
            id: "snapshot-process-group",
            turnID: turnID,
            header: reasoning,
            activities: [command, file],
            status: .completed
        )
        let layout = ConversationLayout(containerWidth: 820, horizontalSizeClass: .regular)

        return VStack {
            ConversationProcessGroupRow(
                group: group,
                layout: layout,
                isExpanded: true,
                expandedActivityIDs: [],
                toggleGroup: {},
                toggleActivity: { _ in }
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .environmentObject(themeStore)
            .environment(\.colorScheme, .light)
        .background(themeStore.tokens(for: .light).background)
        .frame(width: 820, height: 260)
    }

    private func makeWorkGroup(isExpanded: Bool) -> some View {
        let themeStore = makeThemeStore()
        let turnID = "snapshot-work-group"
        let commentary = ConversationMessage(
            stableID: "snapshot-work-commentary",
            turnID: turnID,
            role: .assistant,
            kind: .commentary,
            content: "我会先检查当前实现，再运行测试确认行为。",
            createdAt: snapshotMessageDate,
            sendStatus: .confirmed,
            turnLifecycle: .completed
        )
        let command = ConversationMessage(
            stableID: "snapshot-work-command",
            turnID: turnID,
            role: .system,
            kind: .commandSummary,
            content: "命令：xcodebuild test",
            createdAt: snapshotMessageDate.addingTimeInterval(3),
            sendStatus: .confirmed,
            activityPayload: ConversationActivityPayload(
                category: .runCommand,
                displayTitle: "运行 iOS 单元测试",
                status: "completed",
                command: "xcodebuild test",
                exitCode: 0
            ),
            turnLifecycle: .completed
        )
        let batch = ConversationActivityBatch(
            id: "snapshot-work-batch",
            messages: [command],
            kind: .execution,
            status: .completed
        )
        let group = ConversationWorkGroup(
            id: "snapshot-work-group",
            turnID: turnID,
            entries: [
                .commentary(commentary),
                .activityBatch(batch)
            ],
            status: .completed,
            startedAt: snapshotMessageDate,
            endedAt: snapshotMessageDate.addingTimeInterval(74)
        )
        let layout = ConversationLayout(containerWidth: 820, horizontalSizeClass: .regular)

        return VStack {
            ConversationWorkGroupRow(
                group: group,
                layout: layout,
                isExpanded: isExpanded,
                toggleGroup: {}
            ) {
                Text(commentary.content)
                    .font(themeStore.uiFont(size: 14))
                    .foregroundStyle(themeStore.tokens(for: .light).primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ConversationActivityBatchRow(
                    group: batch,
                    layout: layout,
                    isExpanded: false,
                    expandedActivityIDs: [],
                    toggleGroup: {},
                    toggleActivity: { _ in }
                )
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .environmentObject(themeStore)
        .environment(\.colorScheme, .light)
        .background(themeStore.tokens(for: .light).background)
        .frame(width: 820, height: isExpanded ? 260 : 110)
    }

    private func makeCommentaryAndTrailingProcessConversation() -> some View {
        let sessionID = "snapshot-commentary"
        let turnID = "turn-commentary"
        let appStore = makeSnapshotAppStore()
        let conversationStore = makeSnapshotConversationStore(appStore: appStore)
        let themeStore = makeThemeStore()
        conversationStore.setHistory([
            CodexHistoryMessage(
                id: "commentary-user",
                role: "user",
                content: "继续排查企微原文查看失败。",
                createdAt: snapshotMessageDate,
                turnID: turnID,
                sendStatus: .confirmed
            ),
            CodexHistoryMessage(
                id: "commentary-old-reasoning",
                role: "system",
                kind: .reasoningSummary,
                content: "Inspecting login chain",
                activityPayload: ConversationActivityPayload(
                    category: .thinking,
                    displayTitle: "推理摘要",
                    subtitle: "Inspecting login chain"
                ),
                createdAt: snapshotMessageDate.addingTimeInterval(1),
                turnID: turnID,
                sendStatus: .confirmed,
                isTimestampFallback: true
            ),
            CodexHistoryMessage(
                id: "commentary-old-command",
                role: "system",
                kind: .commandSummary,
                content: "命令：检查线上请求",
                activityPayload: ConversationActivityPayload(
                    category: .runCommand,
                    displayTitle: "检查线上请求",
                    status: "completed"
                ),
                createdAt: snapshotMessageDate.addingTimeInterval(2),
                turnID: turnID,
                sendStatus: .confirmed,
                isTimestampFallback: true
            ),
            CodexHistoryMessage(
                id: "commentary-visible",
                role: "assistant",
                kind: .commentary,
                content: """
                链路已经进一步确认：主站扫码登录和原文 ticket 都是 `200`，真正失败发生在凭证解密阶段。

                - 统一登录 Cookie 已生效
                - 生产 RSA 私钥文件不存在

                我会继续只读检查备份位置，不修改线上配置。
                """,
                createdAt: snapshotMessageDate.addingTimeInterval(3),
                turnID: turnID,
                sendStatus: .confirmed,
                isTimestampFallback: true
            ),
            CodexHistoryMessage(
                id: "commentary-trailing-reasoning-old",
                role: "system",
                kind: .reasoningSummary,
                content: "Searching workspace for private keys",
                activityPayload: ConversationActivityPayload(
                    category: .thinking,
                    displayTitle: "推理摘要",
                    subtitle: "Searching workspace for private keys",
                    status: "inProgress"
                ),
                createdAt: snapshotMessageDate.addingTimeInterval(4),
                turnID: turnID,
                sendStatus: .confirmed,
                isTimestampFallback: true
            ),
            CodexHistoryMessage(
                id: "commentary-trailing-command",
                role: "system",
                kind: .commandSummary,
                content: "命令：find /opt/chat-archive -name '*.pem'",
                activityPayload: ConversationActivityPayload(
                    category: .runCommand,
                    displayTitle: "搜索私钥备份",
                    status: "running"
                ),
                createdAt: snapshotMessageDate.addingTimeInterval(5),
                turnID: turnID,
                sendStatus: .confirmed,
                isTimestampFallback: true
            ),
            CodexHistoryMessage(
                id: "commentary-trailing-reasoning-latest",
                role: "system",
                kind: .reasoningSummary,
                content: "Planning credential recovery checks",
                activityPayload: ConversationActivityPayload(
                    category: .thinking,
                    displayTitle: "推理摘要",
                    subtitle: "Planning credential recovery checks",
                    status: "inProgress"
                ),
                createdAt: snapshotMessageDate.addingTimeInterval(6),
                turnID: turnID,
                sendStatus: .confirmed,
                isTimestampFallback: true
            )
        ], sessionID: sessionID)

        let sessionStore = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore()
        )
        sessionStore.selectedSessionID = sessionID

        return ConversationView()
            .environmentObject(sessionStore)
            .environmentObject(conversationStore)
            .environmentObject(themeStore)
            .environment(\.colorScheme, .light)
            .frame(width: 430, height: 900)
    }

    func testConversationBubbleAlignment() {
        assertSnapshot(
            of: makeSeededConversation(),
            as: .wait(
                for: 0.8,
                on: .image(
                    precision: 0.98,
                    layout: .fixed(width: 1024, height: 768)
                )
            )
        )
    }

    func testDefaultDarkConversationPalette() {
        assertSnapshot(
            of: makeSeededConversation(colorScheme: .dark),
            as: .wait(
                for: 0.8,
                on: .image(
                    precision: 0.98,
                    layout: .fixed(width: 1024, height: 768)
                )
            )
        )
    }

    func testEmptyConversationShowsCurrentDirectoryAcrossAppearances() {
        assertSnapshot(
            of: makeEmptyConversation(
                workspacePath: "/Users/demo/Projects/Clients/2026/Mimi Remote/codex-ipad-agent",
                colorScheme: .light,
                width: 390,
                height: 700
            ),
            as: .image(
                precision: 0.98,
                layout: .fixed(width: 390, height: 700),
                traits: UITraitCollection(displayScale: 2)
            ),
            named: "iphone-long-path-light"
        )

        assertSnapshot(
            of: makeEmptyConversation(
                workspacePath: "/Users/demo/code/codex-ipad-agent",
                colorScheme: .dark,
                width: 1024,
                height: 768
            ),
            as: .image(
                precision: 0.98,
                layout: .fixed(width: 1024, height: 768),
                traits: UITraitCollection(displayScale: 2)
            ),
            named: "ipad-dark"
        )
    }

    func testRichMarkdownConversationRendering() {
        assertSnapshot(
            of: makeRichMarkdownConversation(),
            as: .image(precision: 0.98, layout: .fixed(width: 1024, height: 768))
        )
    }

    func testCrossSessionContinuationHidesInternalAddresses() {
        assertSnapshot(
            of: makeCrossSessionContinuationConversation(),
            as: .wait(
                for: 0.8,
                on: .image(
                    precision: 0.98,
                    layout: .fixed(width: 1024, height: 768)
                )
            )
        )
    }

    func testMixedActivityAndImageConversationRendering() async {
        let view = await makeMixedActivityConversation()

        assertSnapshot(
            of: view,
            as: .wait(
                for: 0.8,
                on: .image(
                    precision: 0.98,
                    layout: .fixed(width: 1024, height: 900)
                )
            )
        )
    }

    func testSingleImageMediaCardAlignmentAcrossLayouts() async {
        for (name, width) in [
            ("iphone-390", CGFloat(390)),
            ("ipad-narrow-700", CGFloat(700)),
            ("ipad-wide-1024", CGFloat(1024))
        ] {
            let view = await makeSingleImageMessage(
                containerWidth: width,
                imageSize: CGSize(width: 240, height: 360),
                accent: .systemOrange
            )
            assertSnapshot(
                of: view,
                as: .image(
                    precision: 0.98,
                    layout: .fixed(width: width, height: 390),
                    traits: UITraitCollection(displayScale: 2)
                ),
                named: name
            )
        }

        let landscapeView = await makeSingleImageMessage(
            containerWidth: 700,
            imageSize: CGSize(width: 420, height: 210),
            accent: .systemPurple
        )
        assertSnapshot(
            of: landscapeView,
            as: .image(
                precision: 0.98,
                layout: .fixed(width: 700, height: 390),
                traits: UITraitCollection(displayScale: 2)
            ),
            named: "ipad-narrow-landscape"
        )

        let remoteView = await makeSingleImageMessage(
            containerWidth: 390,
            imageSize: CGSize(width: 240, height: 360),
            accent: .systemTeal,
            usesRemoteURL: true
        )
        assertSnapshot(
            of: remoteView,
            as: .image(
                precision: 0.98,
                layout: .fixed(width: 390, height: 390),
                traits: UITraitCollection(displayScale: 2)
            ),
            named: "iphone-390-remote-url"
        )
    }

    func testUnavailableUserImageGalleryRemainsLegibleInLightTheme() {
        assertSnapshot(
            of: makeUnavailableUserImageGallery(),
            as: .image(precision: 0.98, layout: .fixed(width: 1024, height: 900))
        )
    }

    func testExpandedProcessGroupRendering() {
        assertSnapshot(
            of: makeExpandedProcessGroup(),
            as: .image(precision: 0.98, layout: .fixed(width: 820, height: 260))
        )
    }

    func testCollapsedWorkGroupRendering() {
        assertSnapshot(
            of: makeWorkGroup(isExpanded: false),
            as: .image(precision: 0.98, layout: .fixed(width: 820, height: 110))
        )
    }

    func testExpandedWorkGroupRendering() {
        assertSnapshot(
            of: makeWorkGroup(isExpanded: true),
            as: .image(precision: 0.98, layout: .fixed(width: 820, height: 260))
        )
    }

    func testCommentaryAndTrailingProcessRendering() {
        assertSnapshot(
            of: makeCommentaryAndTrailingProcessConversation(),
            as: .image(precision: 0.98, layout: .fixed(width: 430, height: 900))
        )
    }

    func testEmptyConversationState() {
        let appStore = makeSnapshotAppStore()
        let conversationStore = makeSnapshotConversationStore(appStore: appStore)
        let themeStore = makeThemeStore()
        let sessionStore = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore()
        )
        // 未选中会话 → 空状态占位。
        let view = ConversationView()
            .environmentObject(sessionStore)
            .environmentObject(conversationStore)
            .environmentObject(themeStore)
            .environment(\.colorScheme, .light)
            .frame(width: 1024, height: 768)

        assertSnapshot(
            of: view,
            as: .wait(
                for: 0.8,
                on: .image(
                    precision: 0.98,
                    layout: .fixed(width: 1024, height: 768)
                )
            )
        )
    }

    func testConversationLayoutUsesVisibleIPadSplitViewWidth() {
        // iPad mini 横屏中 NavigationSplitView 可能把 1133pt 整窗宽度交给 detail，
        // 同时以 300pt leading safe area 表达侧栏；composer 必须只消费剩余的 833pt。
        let layout = ConversationLayout(
            containerWidth: 1133,
            horizontalSizeClass: .regular,
            safeAreaInsets: EdgeInsets(top: 0, leading: 300, bottom: 0, trailing: 0)
        )

        XCTAssertEqual(layout.horizontalInset, 24)
        XCTAssertEqual(layout.composerAvailableWidth, 785)
        XCTAssertEqual(layout.composerMaxWidth, 785)
        XCTAssertFalse(
            ConversationLayout.usesCompactComposerMetrics(
                availableWidth: layout.composerMaxWidth,
                horizontalSizeClass: .regular
            ),
            "regular size class 的 iPad 分栏使用标准输入指标"
        )
        XCTAssertLessThanOrEqual(
            layout.composerMaxWidth + layout.horizontalInset * 2,
            833,
            "输入卡和目标栏不能超过实际 detail 列宽"
        )
    }

    func testConversationLayoutKeepsIPadMiniComposerInsideConversationTrack() {
        let layout = ConversationLayout(
            containerWidth: 744,
            horizontalSizeClass: .regular
        )

        XCTAssertEqual(layout.horizontalInset, 16)
        XCTAssertEqual(layout.composerAvailableWidth, 712)
        XCTAssertEqual(layout.composerMaxWidth, 712)
        XCTAssertEqual(layout.composerMaxWidth + layout.horizontalInset * 2, 744)
        XCTAssertFalse(
            ConversationLayout.usesCompactComposerMetrics(
                availableWidth: layout.composerMaxWidth,
                horizontalSizeClass: .regular
            ),
            "iPad mini 竖屏仍使用标准输入尺寸"
        )
    }

    func testConversationLayoutUsesStandardMetricsForMeasuredLandscapeDetailTrack() {
        // 真机横屏：1133pt 整窗减去约 300pt 侧栏后，内容测量宽度约 832pt。
        // 布局直接采用测量值，不再做 safe area 减法，因此不会重复扣除侧栏
        // 被误算成 528pt 而落入紧凑分支、隐藏快捷行开关。
        let layout = ConversationLayout(
            containerWidth: 832,
            horizontalSizeClass: .regular
        )

        XCTAssertFalse(
            ConversationLayout.usesCompactComposerMetrics(
                availableWidth: min(layout.composerAvailableWidth, layout.composerMaxWidth),
                horizontalSizeClass: .regular
            ),
            "横屏 detail 列必须使用标准输入指标"
        )
    }

    func testConversationLayoutUsesCompactMetricsOnPhone() {
        XCTAssertTrue(
            ConversationLayout.usesCompactComposerMetrics(
                availableWidth: 390,
                horizontalSizeClass: .compact
            ),
            "手机端继续使用紧凑指标"
        )
    }

    func testConversationLayoutFallsBackToWidthWithoutSizeClass() {
        XCTAssertTrue(
            ConversationLayout.usesCompactComposerMetrics(
                availableWidth: 390,
                horizontalSizeClass: nil
            )
        )
        XCTAssertFalse(
            ConversationLayout.usesCompactComposerMetrics(
                availableWidth: 744,
                horizontalSizeClass: nil
            )
        )
    }

    func testConversationLayoutForcesCompactMetricsInExtremelyNarrowRegularSplit() {
        XCTAssertTrue(
            ConversationLayout.usesCompactComposerMetrics(
                availableWidth: 520,
                horizontalSizeClass: .regular
            )
        )
    }

    func testComposerStatusTrayCrowdedState() async {
        let view = await makeComposerStatusTrayCrowdedView(width: 1024, height: 768)

        assertSnapshot(
            of: view,
            as: .wait(
                for: 0.8,
                on: .image(
                    precision: 0.98,
                    layout: .fixed(width: 1024, height: 768)
                )
            )
        )
    }

    func testComposerStatusTrayIPadMiniPortraitWidth() async {
        let view = await makeComposerStatusTrayCrowdedView(
            width: 744,
            height: 1133,
            usesCompactIPadDefault: true
        )

        assertSnapshot(
            of: view,
            as: .wait(
                for: 0.8,
                on: .image(
                    precision: 0.98,
                    layout: .fixed(width: 744, height: 1133)
                )
            )
        )
    }

    func testComposerSurfaceIPadMiniIncreasedContrast() async {
        let view = await makeComposerStatusTrayCrowdedView(
            width: 744,
            height: 1133,
            usesCompactIPadDefault: true
        )

        assertSnapshot(
            of: view,
            as: .wait(
                for: 0.8,
                on: .image(
                    precision: 0.98,
                    layout: .fixed(width: 744, height: 1133),
                    traits: UITraitCollection(accessibilityContrast: .high)
                )
            )
        )
    }

    func testComposerStatusTrayIPadMiniLandscapeDetailWidth() async {
        // 横屏回归：1133pt 整窗减去约 300pt 侧栏后，detail 列约 832pt。
        // Composer 按内容测量宽度必须用标准指标（快捷行、按钮文字标签都在），
        // 不允许被 safe area 提案算术把宽度算小而退化成紧凑布局。
        // NavigationSplitView 在快照宿主中的列宽提案与真机不一致，无法直接包装；
        // 这里固定为真实 detail 列宽，真机横屏行为仍需设备验收。
        let view = await makeComposerStatusTrayCrowdedView(
            width: 832,
            height: 744,
            usesCompactIPadDefault: true
        )

        assertSnapshot(
            of: view,
            as: .wait(
                for: 0.8,
                on: .image(
                    precision: 0.98,
                    layout: .fixed(width: 832, height: 744)
                )
            )
        )
    }

    func testComposerStatusTrayIPadMiniSplitViewWidth() async {
        let view = await makeComposerStatusTrayCrowdedView(
            width: 375,
            height: 744,
            usesCompactIPadDefault: true
        )

        assertSnapshot(
            of: view,
            as: .wait(
                for: 0.8,
                on: .image(
                    precision: 0.98,
                    layout: .fixed(width: 375, height: 744)
                )
            )
        )
    }

    func testComposerStatusTrayCrowdedCompactWidth() async {
        let view = await makeComposerStatusTrayCrowdedView(width: 420, height: 768)

        assertSnapshot(
            of: view,
            as: .wait(
                for: 0.8,
                on: .image(
                    precision: 0.98,
                    layout: .fixed(width: 420, height: 768)
                )
            )
        )
    }

    func testComposerStatusTrayExtremelyNarrowCompactWidth() async {
        let view = await makeComposerStatusTrayCrowdedView(width: 320, height: 700)

        assertSnapshot(
            of: view,
            as: .wait(
                for: 0.8,
                on: .image(
                    precision: 0.98,
                    layout: .fixed(width: 320, height: 700)
                )
            )
        )
    }

    func testComposerStatusTrayCollapsedBlockedObserveDark() {
        let themeStore = makeThemeStore()
        let goal = ThreadGoal(
            threadID: "thread-collapsed-blocked",
            objective: "等待用户补充权限后继续执行。",
            status: .blocked,
            tokenBudget: 2_000_000,
            tokensUsed: 640_000,
            timeUsedSeconds: 820,
            createdAt: snapshotMessageDate,
            updatedAt: snapshotMessageDate
        )
        let tray = ComposerStatusTray(
            sessionControlNotice: "当前由 Mac 端控制，仅观察。",
            quotaNotice: nil,
            usage: nil,
            goal: goal,
            placement: .standalone,
            isGoalExpanded: false,
            isGoalUpdating: false,
            // 收起态只展示状态摘要，错误细节必须留到展开后再显示。
            goalErrorMessage: "缺少所需权限，等待用户处理后重试。",
            isRefreshDisabled: false,
            allowsTakeOver: true,
            onTakeOver: {},
            onRefreshUsage: {},
            onEditGoal: {},
            onTogglePauseGoal: {},
            onCompleteGoal: {},
            onClearGoal: {},
            onToggleGoalExpanded: {}
        )

        let view = VStack {
            Spacer()
            tray
                .padding(16)
        }
        .environmentObject(themeStore)
        .environment(\.colorScheme, .dark)
        .environment(\.locale, Locale(identifier: "zh-Hans"))
        .background(themeStore.tokens(for: .dark).background)
        .frame(width: 390, height: 110)

        assertSnapshot(
            of: view,
            as: .image(precision: 0.98, layout: .fixed(width: 390, height: 110))
        )
    }

    func testComposerStatusTrayExpandedCrowdedState() async {
        let view = await makeComposerStatusTrayCrowdedView(width: 420, height: 768, goalExpanded: true)

        assertSnapshot(
            of: view,
            as: .wait(
                for: 0.8,
                on: .image(
                    precision: 0.98,
                    layout: .fixed(width: 420, height: 768)
                )
            )
        )
    }

    func testComposerStatusTrayExpandedWideState() async {
        // iPad 宽屏展开态必须继续和输入卡共用整条 composer 轨道，防止状态栏退回旧的 680pt 上限。
        let view = await makeComposerStatusTrayCrowdedView(width: 1024, height: 768, goalExpanded: true)

        assertSnapshot(
            of: view,
            as: .wait(
                for: 0.8,
                on: .image(
                    precision: 0.98,
                    layout: .fixed(width: 1024, height: 768)
                )
            )
        )
    }

    func testCompletedGoalStatusTrayRemainsVisibleAfterTurnFinishes() async {
        let view = await makeComposerStatusTrayCrowdedView(
            width: 744,
            height: 768,
            usesCompactIPadDefault: true,
            goalStatus: .complete,
            sessionStatus: SessionStatus.completed.rawValue
        )

        assertSnapshot(
            of: view,
            as: .wait(
                for: 0.8,
                on: .image(
                    precision: 0.98,
                    layout: .fixed(width: 744, height: 768)
                )
            )
        )
    }

    func testComposerSendModeLabelsUseConsistentModeSuffix() {
        XCTAssertEqual(L10n.text("ui.planning_mode"), "计划模式")
        XCTAssertEqual(L10n.text("ui.target_task"), "目标模式")
        XCTAssertEqual(L10n.text("ui.turn_off_planning_mode"), "关闭计划模式")
        XCTAssertEqual(L10n.text("ui.close_target_task"), "关闭目标模式")
    }

    func testGoalTraySurfaceStyleMatchesFlatComposerHierarchy() {
        let collapsed = ComposerStatusTraySurfaceStyle.resolve(
            isExpanded: false,
            scheme: .dark,
            reduceTransparency: false
        )
        let expanded = ComposerStatusTraySurfaceStyle.resolve(
            isExpanded: true,
            scheme: .dark,
            reduceTransparency: false
        )

        XCTAssertEqual(collapsed.materialStrength, .thin)
        XCTAssertEqual(expanded.materialStrength, .regular)
        XCTAssertEqual(collapsed.surfaceTintOpacity, 0.46)
        XCTAssertEqual(expanded.surfaceTintOpacity, collapsed.surfaceTintOpacity)
        XCTAssertEqual(collapsed.borderOpacity, 0.58)
        XCTAssertEqual(expanded.borderOpacity, collapsed.borderOpacity)
    }

    func testGoalTrayLightSurfaceUsesOpaqueSharedComposerColor() {
        for isExpanded in [false, true] {
            let style = ComposerStatusTraySurfaceStyle.resolve(
                isExpanded: isExpanded,
                scheme: .light,
                reduceTransparency: false
            )

            XCTAssertEqual(style.materialStrength, .opaque)
            XCTAssertEqual(style.surfaceTintOpacity, 1)
            XCTAssertEqual(style.borderOpacity, 0.05)
        }
    }

    /// 「仅观察」展开前后渲染的内容完全一样，那颗 chevron 点下去什么也不会发生。
    /// 目标、额度这类真的有下文的状态必须继续保留开合。
    func testStatusTrayOnlyOffersDisclosureWhenExpandingRevealsSomething() {
        func makeTray(
            sessionControlNotice: String? = nil,
            quotaNotice: CodexQuotaNotice? = nil,
            usage: CodexUsageDisplaySummary? = nil,
            goal: ThreadGoal? = nil
        ) -> ComposerStatusTray {
            ComposerStatusTray(
                sessionControlNotice: sessionControlNotice,
                quotaNotice: quotaNotice,
                usage: usage,
                goal: goal,
                placement: .embedded,
                isGoalExpanded: false,
                isGoalUpdating: false,
                goalErrorMessage: nil,
                isRefreshDisabled: false,
                allowsTakeOver: true,
                onTakeOver: {},
                onRefreshUsage: {},
                onEditGoal: {},
                onTogglePauseGoal: {},
                onCompleteGoal: {},
                onClearGoal: {},
                onToggleGoalExpanded: {}
            )
        }

        XCTAssertFalse(
            makeTray(sessionControlNotice: "当前由 Mac 端控制，仅观察。").hasExpandableDetail,
            "只有观察状态时不应该提供展开入口"
        )

        let goal = ThreadGoal(
            threadID: "thread-disclosure",
            objective: "继续推进海报编辑体验。",
            status: .active,
            tokenBudget: 2_000_000,
            tokensUsed: 120_000,
            timeUsedSeconds: 240,
            createdAt: snapshotMessageDate,
            updatedAt: snapshotMessageDate
        )
        XCTAssertTrue(makeTray(goal: goal).hasExpandableDetail)
        XCTAssertTrue(
            makeTray(sessionControlNotice: "当前由 Mac 端控制，仅观察。", goal: goal).hasExpandableDetail,
            "观察态叠加目标时仍要能展开目标详情"
        )
    }

    func testEmbeddedGoalTrayUsesComposerSurfaceAndAlignedPadding() {
        XCTAssertFalse(ComposerStatusTrayPlacement.embedded.usesIndependentSurface)
        XCTAssertTrue(ComposerStatusTrayPlacement.embedded.usesEmbeddedStatusChip)
        XCTAssertEqual(ComposerStatusTrayPlacement.embedded.expandedContentPadding, 2)
        XCTAssertEqual(ComposerStatusTrayPlacement.embedded.collapsedLeadingPadding, 0)

        XCTAssertTrue(ComposerStatusTrayPlacement.standalone.usesIndependentSurface)
        XCTAssertFalse(ComposerStatusTrayPlacement.standalone.usesEmbeddedStatusChip)
        XCTAssertEqual(ComposerStatusTrayPlacement.standalone.expandedContentPadding, 10)
        XCTAssertEqual(ComposerStatusTrayPlacement.standalone.collapsedLeadingPadding, 10)
    }

    func testGoalTrayLightSurfaceKeepsExplicitBorderForAccessibility() {
        let reducedTransparency = ComposerStatusTraySurfaceStyle.resolve(
            isExpanded: false,
            scheme: .light,
            reduceTransparency: true
        )
        let increasedContrast = ComposerStatusTraySurfaceStyle.resolve(
            isExpanded: false,
            scheme: .light,
            reduceTransparency: false,
            increasedContrast: true
        )

        XCTAssertEqual(reducedTransparency.materialStrength, .opaque)
        XCTAssertEqual(reducedTransparency.borderOpacity, 0.08)
        XCTAssertEqual(increasedContrast.materialStrength, .opaque)
        XCTAssertEqual(increasedContrast.borderOpacity, 0.5)
    }

    /// iPhone 恒定使用 `.embedded`，那条路径完全不绘制 `traySurface`。
    /// 这里锁住这个前提，避免以后又给 `resolve` 加一条真机永远走不到的 phone 分支。
    func testEmbeddedGoalTrayNeverDrawsIndependentTraySurface() {
        XCTAssertFalse(ComposerStatusTrayPlacement.embedded.usesIndependentSurface)

        // 浅色下 `.thin` 只可能来自已删除的 phone 分支；独立托盘必须始终是实色。
        for isExpanded in [false, true] {
            for reduceTransparency in [false, true] {
                for increasedContrast in [false, true] {
                    let style = ComposerStatusTraySurfaceStyle.resolve(
                        isExpanded: isExpanded,
                        scheme: .light,
                        reduceTransparency: reduceTransparency,
                        increasedContrast: increasedContrast
                    )
                    XCTAssertEqual(style.materialStrength, .opaque)
                    XCTAssertEqual(style.surfaceTintOpacity, 1)
                }
            }
        }
    }

    func testGoalTraySurfaceStyleBecomesOpaqueWhenReduceTransparencyIsEnabled() {
        for isExpanded in [false, true] {
            let style = ComposerStatusTraySurfaceStyle.resolve(
                isExpanded: isExpanded,
                scheme: .dark,
                reduceTransparency: true
            )

            XCTAssertEqual(style.materialStrength, .opaque)
            XCTAssertEqual(style.surfaceTintOpacity, 1)
            XCTAssertEqual(style.borderOpacity, 0.58)
        }
    }

    func testExpandedGoalTrayDarkMaterialSeparatesBackdropContent() {
        let themeStore = makeThemeStore()
        let goal = ThreadGoal(
            threadID: "thread-dark-material",
            objective: "更新 Apple Design skill，并验证目标浮层不会和后方卡片内容发生视觉冲突。",
            status: .active,
            tokenBudget: 2_000_000,
            tokensUsed: 820_000,
            timeUsedSeconds: 1_420,
            createdAt: snapshotMessageDate,
            updatedAt: snapshotMessageDate
        )
        let tray = ComposerStatusTray(
            sessionControlNotice: nil,
            quotaNotice: nil,
            usage: nil,
            goal: goal,
            placement: .standalone,
            isGoalExpanded: true,
            isGoalUpdating: false,
            goalErrorMessage: nil,
            isRefreshDisabled: false,
            allowsTakeOver: true,
            onTakeOver: {},
            onRefreshUsage: {},
            onEditGoal: {},
            onTogglePauseGoal: {},
            onCompleteGoal: {},
            onClearGoal: {},
            onToggleGoalExpanded: {}
        )

        let view = ZStack(alignment: .bottom) {
            Color(red: 0.063, green: 0.067, blue: 0.078)
            VStack(alignment: .leading, spacing: 10) {
                Text("$apple-design")
                    .font(.title2.bold())
                Text("Use this skill to review typography, spacing, interaction states, and platform conventions.")
                    .font(.body)
                Text("⌘  Update skill")
                    .font(.callout.monospaced())
            }
            .foregroundStyle(.white)
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(red: 0.141, green: 0.153, blue: 0.180),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .padding(28)

            tray
                .padding(20)
        }
        .environmentObject(themeStore)
        .environment(\.colorScheme, .dark)
        .environment(\.locale, Locale(identifier: "zh-Hans"))
        .frame(width: 760, height: 360)

        assertSnapshot(
            of: view,
            as: .image(precision: 0.98, layout: .fixed(width: 760, height: 360))
        )
    }

    private func makeComposerStatusTrayCrowdedView(
        width: CGFloat,
        height: CGFloat,
        goalExpanded: Bool = false,
        usesCompactIPadDefault: Bool = false,
        goalStatus: ThreadGoalStatus = .active,
        sessionStatus: String = "running"
    ) async -> some View {
        let project = AgentProject(id: "tray-project", name: "tray-project", path: "/Users/me/code/tray-project")
        let sessionID = "crowded"
        let threadID = "thread-\(sessionID)"
        let goal = ThreadGoal(
            threadID: threadID,
            objective: "你是 Mimi Remote 的多 Agent 产品研发团队主控，需要把目标、接管和额度状态压缩到输入框上方。",
            status: goalStatus,
            tokenBudget: 12_000_000,
            tokensUsed: 10_200_000,
            timeUsedSeconds: 25_740,
            createdAt: snapshotMessageDate,
            updatedAt: snapshotMessageDate
        )
        let session = makeSnapshotSession(
            id: sessionID,
            project: project,
            title: "Composer 状态托盘",
            status: sessionStatus,
            preview: "验证接管、额度和目标同时出现时的底部 composer 布局。",
            activeTurnID: SessionStore.isRunningStatus(sessionStatus) ? "turn-crowded" : nil,
            rateLimit: RateLimitSummary(limitName: "Codex", primaryUsedPercent: 85, primaryResetsAt: 1_782_883_260),
            goal: goal
        )
        let appStore = makeSnapshotAppStore()
        let conversationStore = makeSnapshotConversationStore(appStore: appStore)
        conversationStore.applyAssistantDelta(
            AgentDelta(
                text: "这条消息用于把 composer 推到真实会话底部；状态托盘应该保持紧凑，不要把输入框挤出首屏。",
                role: .assistant,
                kind: .message
            ),
            metadata: AgentEventMetadata(
                seq: 1,
                sessionID: sessionID,
                turnID: "turn-crowded",
                itemID: "item-crowded",
                messageID: nil,
                clientMessageID: nil,
                revision: 1,
                createdAt: snapshotMessageDate
            ),
            fallbackSessionID: sessionID
        )
        let themeStore = makeThemeStore()
        if usesCompactIPadDefault {
            themeStore.applyDeviceDefaultFontScale(
                isPad: true,
                screenSize: CGSize(width: 744, height: 1_133)
            )
        }
        let sessionStore = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(
                workspaces: [AgentWorkspace(project: project, lastOpenedAt: Date(timeIntervalSince1970: 10))],
                endpoint: appStore.endpoint
            ),
            clientFactory: {
                SnapshotSessionAPIClient(projects: [project], sessions: [session])
            }
        )
        // 固定一个明确支持 xhigh 的默认模型，避免异步 model/list 刷新后把推理强度
        // 归一化掉，导致快照取决于首帧与 `.task` 谁先完成。
        sessionStore.appServerModelOptions = [
            CodexAppServerModelOption(
                id: "gpt-5.5",
                title: "GPT-5.5",
                isDefault: true,
                supportedReasoningEfforts: ["xhigh"],
                defaultReasoningEffort: "xhigh"
            )
        ]
        await sessionStore.refreshAll(autoAttach: false)
        await sessionStore.toggleProjectExpansion(project)
        sessionStore.selectedSessionID = sessionID

        let composerDefaultsSuite = "ConversationSnapshotTests.Composer.\(UUID().uuidString)"
        let composerDefaults = UserDefaults(suiteName: composerDefaultsSuite)!
        composerDefaults.removePersistentDomain(forName: composerDefaultsSuite)
        composerDefaults.set(true, forKey: "composer.shortcuts.expanded")

        return ConversationView(initialGoalStatusExpanded: goalExpanded)
            .environmentObject(sessionStore)
            .environmentObject(conversationStore)
            .environmentObject(themeStore)
            // 快照固定为浅色，避免运行测试前手动切过模拟器外观就整组误报。
            .environment(\.colorScheme, .light)
            // 同时固定语言，避免开发机或 Simulator 语言变化把纯视觉回归误录成文案变更。
            .environment(\.locale, Locale(identifier: "zh-Hans"))
            .defaultAppStorage(composerDefaults)
            .frame(width: width, height: height)
    }

    func testProjectSessionDashboard() async {
        let project = AgentProject(id: "mimi-remote", name: "mimi-remote", path: "/Users/me/code/mimi-remote")
        let themeStore = makeThemeStore()
        let appStore = makeSnapshotAppStore()
        let sessions = [
            makeSnapshotSession(
                id: "running",
                project: project,
                title: "接入 Codex app-server runtime",
                status: "running",
                preview: "正在把 assistant_delta 合并到稳定消息气泡里。",
                activeTurnID: "turn-running",
                usage: UsageSummary(inputTokens: 4_200, outputTokens: 960, totalTokens: 5_160, costUSD: Decimal(string: "0.0312")),
                rateLimit: RateLimitSummary(remainingRequests: 18, remainingTokens: nil, resetAt: nil)
            ),
            makeSnapshotSession(
                id: "approval",
                project: project,
                title: "确认文件变更审批",
                status: "waiting_for_approval",
                preview: "agentd 捕获到 patchUpdated，需要在 iPad 上明确批准。",
                pendingApproval: ApprovalSummary(id: "approval-1", title: "写入 diff", kind: "file_change", count: 2)
            ),
            makeSnapshotSession(
                id: "history",
                project: project,
                title: "历史会话分页加载",
                status: "history",
                preview: "只加载最近消息，向上滚动时再按 cursor 补旧内容。",
                runtimeProvider: "claude"
            ),
            makeSnapshotSession(
                id: "done",
                project: project,
                title: "README 迁移说明",
                status: "completed",
                preview: "记录 Tailscale、Token 和 app-server 本机监听。"
            )
        ]
        let sessionStore = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(
                workspaces: [AgentWorkspace(project: project, lastOpenedAt: Date(timeIntervalSince1970: 10))],
                endpoint: appStore.endpoint
            ),
            clientFactory: {
                SnapshotSessionAPIClient(projects: [project], sessions: sessions)
            }
        )
        await sessionStore.refreshAll(autoAttach: false)
        await sessionStore.toggleProjectExpansion(project)

        let view = NavigationStack {
            ProjectSidebarView(showsSessions: true)
                .toolbar(.hidden, for: .navigationBar)
        }
        .environmentObject(sessionStore)
        .environmentObject(themeStore)
        .environment(\.colorScheme, .light)
        // 固定尺寸在不同 iOS Runtime 下可能推导出不同 size class；
        // 这里明确验证 iPad regular 侧栏，避免系统推导差异改变头部结构。
        .environment(\.horizontalSizeClass, .regular)
        .frame(width: 420, height: 768)

        assertSnapshot(
            of: view,
            as: .image(precision: 0.98, layout: .fixed(width: 420, height: 768))
        )
    }

    func testSessionRuntimeBadgesInConversationList() {
        let project = AgentProject(id: "runtime-badges", name: "runtime-badges", path: "/Users/me/code/runtime-badges")
        let themeStore = makeThemeStore()
        let codex = makeSnapshotSession(
            id: "runtime-codex",
            project: project,
            title: "从当前 main 分支创建新的 worktree 并优化会话列表中的分支信息展示",
            status: "completed",
            preview: "Codex 会话",
            context: SessionContextSnapshot(
                git: SessionContextGitInfo(branch: "feature/session-git-branch-indicator")
            )
        )
        let claude = makeSnapshotSession(
            id: "runtime-claude",
            project: project,
            title: "检查兼容性",
            status: "history",
            preview: "Claude Code 会话",
            runtimeProvider: "claude"
        )

        let view = VStack(spacing: 8) {
            SessionIndexRow(
                session: codex,
                foregroundActivity: nil,
                isSelected: true,
                isPinned: false,
                isArchived: false,
                reminder: nil,
                isObserving: false,
                isExternalReadOnly: false,
                density: .compact
            )
            SessionIndexRow(
                session: claude,
                foregroundActivity: nil,
                isSelected: false,
                isPinned: false,
                isArchived: false,
                reminder: nil,
                isObserving: false,
                isExternalReadOnly: false,
                density: .compact
            )
        }
        .padding(16)
        .environmentObject(themeStore)
        .environment(\.colorScheme, .light)
        .background(themeStore.tokens(for: .light).background)
        .frame(width: 460, height: 190)

        assertSnapshot(
            of: view,
            as: .image(precision: 0.98, layout: .fixed(width: 460, height: 190))
        )
    }

    func testSessionMetadataPrefersWorkingDirectoryOverProjectName() {
        let project = AgentProject(
            id: "shared-project",
            name: "codex-ipad-agent",
            path: "/Users/me/worktrees/codex-ipad-agent/mim-96"
        )
        let session = makeSnapshotSession(
            id: "worktree-session",
            project: project,
            title: "验证 worktree 目录",
            status: "history",
            preview: ""
        )

        XCTAssertEqual(
            SessionIndexRow.metadataDirectoryText(for: session),
            "/Users/me/worktrees/codex-ipad-agent/mim-96"
        )
    }

    func testSessionRuntimeMetadataInDarkConversationList() {
        let project = AgentProject(
            id: "runtime-dark",
            name: "codex-ipad-agent",
            path: "/Users/me/code/codex-ipad-agent"
        )
        let themeStore = makeThemeStore()
        let codex = makeSnapshotSession(
            id: "runtime-dark-codex",
            project: project,
            title: "Review MIM-96 会话列表细节",
            status: "completed",
            preview: "Codex 会话",
            context: SessionContextSnapshot(
                git: SessionContextGitInfo(branch: "codex/mim-96-refine-session-ui")
            )
        )
        let claude = makeSnapshotSession(
            id: "runtime-dark-claude",
            project: project,
            title: "检查深色模式下的目录对齐",
            status: "history",
            preview: "Claude Code 会话",
            runtimeProvider: "claude"
        )

        let view = VStack(spacing: 8) {
            SessionIndexRow(
                session: codex,
                foregroundActivity: nil,
                isSelected: true,
                isPinned: true,
                isArchived: false,
                reminder: nil,
                isObserving: false,
                isExternalReadOnly: false,
                isUnread: true,
                density: .compact
            )
            SessionIndexRow(
                session: claude,
                foregroundActivity: nil,
                isSelected: false,
                isPinned: false,
                isArchived: false,
                reminder: nil,
                isObserving: false,
                isExternalReadOnly: false,
                density: .compact
            )
        }
        .padding(16)
        .environmentObject(themeStore)
        .environment(\.colorScheme, .dark)
        .background(themeStore.tokens(for: .dark).background)
        .frame(width: 460, height: 190)

        assertSnapshot(
            of: view,
            as: .image(precision: 0.98, layout: .fixed(width: 460, height: 190))
        )
    }

    func testSessionLibraryDensityAndAccessibilityLayouts() {
        let scenarios: [(
            name: String,
            width: CGFloat,
            height: CGFloat,
            colorScheme: ColorScheme,
            prefersTable: Bool,
            bottomContentMargin: CGFloat,
            dynamicTypeSize: DynamicTypeSize,
            increasedContrast: Bool
        )] = [
            ("iphone-390-light", 390, 844, .light, false, 84, .large, false),
            ("ipad-mini-744-light", 744, 980, .light, true, 84, .large, false),
            ("ipad-pro-1366-dark-contrast", 1_366, 900, .dark, true, 16, .large, true),
            ("split-375-light", 375, 812, .light, false, 84, .large, false),
            ("ipad-pro-1366-ax3", 1_366, 900, .light, true, 16, .accessibility3, false),
        ]

        for scenario in scenarios {
            let view = makeSessionLibrarySnapshot(
                width: scenario.width,
                height: scenario.height,
                colorScheme: scenario.colorScheme,
                prefersTable: scenario.prefersTable,
                bottomContentMargin: scenario.bottomContentMargin,
                dynamicTypeSize: scenario.dynamicTypeSize
            )

            assertSnapshot(
                of: view,
                as: .wait(
                    for: 0.3,
                    on: .image(
                        precision: 0.98,
                        layout: .fixed(width: scenario.width, height: scenario.height),
                        traits: UITraitCollection(
                            accessibilityContrast: scenario.increasedContrast ? .high : .normal
                        )
                    )
                ),
                named: scenario.name
            )
        }
    }

    func testUnifiedWorkbenchSidebarNavigationChrome() {
        let themeStore = makeThemeStore()
        let tokens = themeStore.tokens(for: .light)
        let project = AgentProject(
            id: "sidebar-monitor-project",
            name: "codex-ipad-agent",
            path: "/Users/me/code/codex-ipad-agent"
        )
        let needYou = makeSnapshotSession(
            id: "sidebar-needs-you",
            project: project,
            title: "确认 MIM-104 交互细节",
            status: SessionStatus.waitingForInput.rawValue,
            preview: ""
        )
        let running = makeSnapshotSession(
            id: "sidebar-running",
            project: project,
            title: "重新录制五档视觉快照",
            status: SessionStatus.running.rawValue,
            preview: "",
            activeTurnID: "sidebar-turn",
            updatedAt: Date().addingTimeInterval(-12 * 60)
        )
        let completed = makeSnapshotSession(
            id: "sidebar-completed",
            project: project,
            title: "整理最新设计补充",
            status: SessionStatus.completed.rawValue,
            preview: "",
            recencyAt: Date().addingTimeInterval(-3 * 60)
        )
        let completedObservedAt = Date().addingTimeInterval(-3 * 60)

        let view = VStack(spacing: 0) {
            List {
                Section {
                    WorkbenchSidebarDestinationButton(
                        title: "会话",
                        icon: .sessions,
                        isSelected: true,
                        tokens: tokens,
                        action: {}
                    )
                    WorkbenchSidebarDestinationButton(
                        title: "工作区",
                        icon: .workspaces,
                        isSelected: false,
                        tokens: tokens,
                        action: {}
                    )
                }

                Section("需要你 1") {
                    SessionSidebarMonitorRow(
                        session: needYou,
                        kind: .needYou,
                        isSelected: false,
                        isRecentlyCompleted: false,
                        completionObservedAt: nil,
                        projectIcon: .emoji("🐱"),
                        runtimeActivitySnapshot: nil
                    )
                    .listRowInsets(.init(top: 0, leading: 8, bottom: 0, trailing: 8))
                    .listRowBackground(Color.clear)
                }

                Section("进行中 1") {
                    SessionSidebarMonitorRow(
                        session: running,
                        kind: .running,
                        isSelected: true,
                        isRecentlyCompleted: false,
                        completionObservedAt: nil,
                        projectIcon: .emoji("🐱"),
                        runtimeActivitySnapshot: RuntimeActivitySnapshot(
                            turnStartedAt: Date().addingTimeInterval(-12 * 60),
                            lastActivityAt: Date()
                        )
                    )
                    .listRowInsets(.init(top: 0, leading: 8, bottom: 0, trailing: 8))
                    .listRowBackground(Color.clear)
                }

                Section("刚完成 1") {
                    SessionSidebarMonitorRow(
                        session: completed,
                        kind: .justCompleted,
                        isSelected: false,
                        isRecentlyCompleted: true,
                        completionObservedAt: completedObservedAt,
                        projectIcon: .emoji("🐱"),
                        runtimeActivitySnapshot: nil
                    )
                    .listRowInsets(.init(top: 0, leading: 8, bottom: 0, trailing: 8))
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .contentMargins(.leading, 0, for: .scrollContent)
            .environment(\.defaultMinListRowHeight, 34)
            .frame(maxHeight: .infinity)

            // 直接渲染生产组件，避免 NavigationSplitView 在测试宿主中自动折叠侧栏。
            WorkbenchSidebarFooter(tokens: tokens, onOpenSettings: {}, onNewSession: {})
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environmentObject(themeStore)
        .environment(\.colorScheme, .light)
        .background(tokens.sidebarBackground)
        .frame(width: 340, height: 768)

        assertSnapshot(
            of: view,
            as: .wait(
                for: 0.8,
                on: .image(
                    precision: 0.98,
                    layout: .fixed(width: 340, height: 768)
                )
            )
        )
    }

    func testWorkbenchNavigationIconPairs() {
        XCTAssertEqual(
            WorkbenchNavigationIcon.sessions.systemName(isSelected: false),
            "bubble.left.and.bubble.right"
        )
        XCTAssertEqual(
            WorkbenchNavigationIcon.sessions.systemName(isSelected: true),
            "bubble.left.and.bubble.right.fill"
        )
        XCTAssertEqual(
            WorkbenchNavigationIcon.workspaces.systemName(isSelected: false),
            "folder"
        )
        XCTAssertEqual(
            WorkbenchNavigationIcon.workspaces.systemName(isSelected: true),
            "folder.fill"
        )
        XCTAssertEqual(
            WorkbenchNavigationIcon.me.systemName(isSelected: false),
            "person.crop.circle"
        )
        XCTAssertEqual(
            WorkbenchNavigationIcon.me.systemName(isSelected: true),
            "person.crop.circle.fill"
        )
    }

    func testAppearancePreview() {
        let defaults = UserDefaults(suiteName: "ConversationSnapshotTests.Appearance.\(UUID().uuidString)")!
        let themeStore = ThemeStore(defaults: defaults)
        let workspaceAppearanceStore = WorkspaceAppearanceStore(defaults: defaults)
        themeStore.mode = .dark
        themeStore.preset = .gruvbox
        themeStore.uiFontPreset = .rounded
        themeStore.codeFontPreset = .menlo
        themeStore.setFontScale(1.1)

        let view = NavigationStack {
            AppearanceView(profileID: "snapshot-profile")
        }
        .environmentObject(themeStore)
        .environmentObject(workspaceAppearanceStore)
        .environment(\.colorScheme, .dark)
        .frame(width: 560, height: 1180)

        assertSnapshot(
            of: view,
            as: .image(precision: 0.98, layout: .fixed(width: 560, height: 1180))
        )
    }

    private func makeThemeStore() -> ThemeStore {
        let suiteName = "ConversationSnapshotTests.Theme.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return ThemeStore(defaults: defaults)
    }

    /// 用真实 SessionListView 锁住扁平日期列表、项目锚点、三档密度与辅助功能回退。
    private func makeSessionLibrarySnapshot(
        width: CGFloat,
        height: CGFloat,
        colorScheme: ColorScheme,
        prefersTable: Bool,
        bottomContentMargin: CGFloat,
        dynamicTypeSize: DynamicTypeSize
    ) -> some View {
        let appStore = makeSnapshotAppStore()
        let conversationStore = makeSnapshotConversationStore(appStore: appStore)
        let themeStore = makeThemeStore()
        let appearanceDefaults = UserDefaults(
            suiteName: "ConversationSnapshotTests.WorkspaceAppearance.\(UUID().uuidString)"
        )!
        let workspaceAppearanceStore = WorkspaceAppearanceStore(defaults: appearanceDefaults)
        let sessionStore = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore()
        )
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let project = AgentProject(
            id: "session-list-project",
            name: "codex-ipad-agent",
            path: "/Users/me/worktrees/codex-ipad-agent/mim-104"
        )
        let secondProject = AgentProject(
            id: "session-list-second-project",
            name: "poster-studio",
            path: "/Users/me/code/xhs-poster-studio"
        )

        func localDate(dayOffset: Int, hour: Int, minute: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: today) ?? today
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }

        workspaceAppearanceStore.setCustomEmoji(
            "🐱",
            profileID: appStore.activeHostScope.profileID,
            projectID: project.id
        )
        workspaceAppearanceStore.setCustomEmoji(
            "🎨",
            profileID: appStore.activeHostScope.profileID,
            projectID: secondProject.id
        )
        workspaceAppearanceStore.setStyle(
            .emoji,
            profileID: appStore.activeHostScope.profileID
        )

        let active = makeSnapshotSession(
            id: "session-list-active",
            project: project,
            title: "正在整理 **MIM-104** 会话列表",
            status: SessionStatus.running.rawValue,
            preview: "同步核对侧边栏状态和扁平列表",
            activeTurnID: "turn-active",
            recencyAt: localDate(dayOffset: 0, hour: 10, minute: 18)
        )
        let pinned = makeSnapshotSession(
            id: "session-list-pinned",
            project: project,
            title: "固定在顶部的发布检查",
            status: SessionStatus.history.rawValue,
            preview: "检查真机安装与回归结果",
            runtimeProvider: "claude"
        )
        let historyRows: [AgentSession] = [
            makeSnapshotSession(
                id: "session-list-today-1",
                project: project,
                title: "## 宽屏列对齐\n并压平标题换行",
                status: SessionStatus.history.rawValue,
                preview: "预览紧跟标题，右侧只保留紧凑元数据",
                recencyAt: localDate(dayOffset: 0, hour: 9, minute: 55)
            ),
            makeSnapshotSession(
                id: "session-list-today-2",
                project: project,
                title: "恢复侧边栏最近会话",
                status: SessionStatus.completed.rawValue,
                preview: "按需要你、进行中、刚完成、置顶和最近分层",
                recencyAt: localDate(dayOffset: 0, hour: 9, minute: 42)
            ),
            makeSnapshotSession(
                id: "session-list-today-3",
                project: project,
                title: "检查 project anchor 连续显示",
                status: SessionStatus.history.rawValue,
                preview: "同一项目后续行保留空槽，不重复 Emoji",
                recencyAt: localDate(dayOffset: 0, hour: 9, minute: 30)
            ),
            makeSnapshotSession(
                id: "session-list-today-4",
                project: project,
                title: "清理 Markdown 与换行",
                status: SessionStatus.history.rawValue,
                preview: "**标题** 和预览都保持单行可扫读",
                recencyAt: localDate(dayOffset: 0, hour: 9, minute: 18)
            ),
            makeSnapshotSession(
                id: "session-list-today-5",
                project: project,
                title: "验证发丝分隔线",
                status: SessionStatus.history.rawValue,
                preview: "分隔线从标题区域开始，组末不再绘制",
                recencyAt: localDate(dayOffset: 0, hour: 9, minute: 6)
            ),
            makeSnapshotSession(
                id: "session-list-today-other-project",
                project: secondProject,
                title: "生成小红书视觉素材",
                status: SessionStatus.history.rawValue,
                preview: "项目切换时立即出现新的图标锚点",
                runtimeProvider: "claude",
                recencyAt: localDate(dayOffset: 0, hour: 8, minute: 54)
            ),
            makeSnapshotSession(
                id: "session-list-today-7",
                project: project,
                title: "检查 compact 顶栏与安全区",
                status: SessionStatus.failed.rawValue,
                preview: "窄屏回退两行布局，不使用固定列宽",
                recencyAt: localDate(dayOffset: 0, hour: 8, minute: 42)
            ),
            makeSnapshotSession(
                id: "session-list-today-8",
                project: project,
                title: "保留 Inspector 完整路径",
                status: SessionStatus.history.rawValue,
                preview: "主列表只显示项目名称，详情仍有完整目录",
                recencyAt: localDate(dayOffset: 0, hour: 8, minute: 30)
            ),
            makeSnapshotSession(
                id: "session-list-today-9",
                project: project,
                title: "完成 MIM-104 快照验收",
                status: SessionStatus.history.rawValue,
                preview: "使用 90% 同项目的实机数据分布验证密度",
                recencyAt: localDate(dayOffset: 0, hour: 8, minute: 18)
            ),
        ]

        sessionStore.projects = [project, secondProject]
        sessionStore.sidebarProjects = [project, secondProject]
        sessionStore.sessions = [active, pinned] + historyRows
        sessionStore.pinnedSessionIDs = [pinned.id]
        // 主列表继续验证 Mimi 本地未读；浮动侧栏的“刚完成”使用独立的完成观察时间。
        sessionStore.setUnreadHistorySessionIDs([historyRows[1].id, historyRows[5].id])
        sessionStore.selectedSessionID = historyRows[0].id

        return NavigationStack {
            SessionListView(
                manageConnections: width < WorkbenchSidebarSurfaceMetrics.minimumContainerWidth ? {} : nil,
                prefersTableDensity: prefersTable,
                // 与生产布局一致：iPhone / iPad mini 竖屏使用紧凑导航，宽屏才显示完整搜索框。
                usesCompactNavigation: width < WorkbenchSidebarSurfaceMetrics.minimumContainerWidth,
                bottomContentMargin: bottomContentMargin
            )
        }
        .environmentObject(appStore)
        .environmentObject(sessionStore)
        .environmentObject(themeStore)
        .environmentObject(workspaceAppearanceStore)
        .environment(\.colorScheme, colorScheme)
        .environment(\.dynamicTypeSize, dynamicTypeSize)
        .frame(width: width, height: height)
    }

    private func snapshotImageDataURL(size: CGSize, accent: UIColor) -> String {
        let data = snapshotImage(size: size, accent: accent).pngData() ?? Data()
        return "data:image/png;base64,\(data.base64EncodedString())"
    }

    private func snapshotImage(size: CGSize, accent: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemBackground.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            accent.withAlphaComponent(0.16).setFill()
            context.fill(CGRect(x: 12, y: 12, width: size.width - 24, height: size.height - 24))
            accent.setStroke()
            context.cgContext.setLineWidth(6)
            context.cgContext.stroke(CGRect(x: 24, y: 24, width: size.width - 48, height: size.height - 48))
        }
    }

    /// 快照不能读取模拟器里真实配对过的 Mac；隔离偏好与 Keychain 后，composer 的默认状态才可复现。
    private func makeSnapshotAppStore() -> AppStore {
        let suiteName = "ConversationSnapshotTests.AppStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppStore(defaults: defaults, tokenStore: TokenStore(keychain: TestKeychainOperations()))
    }

    private func makeSnapshotConversationStore(appStore: AppStore) -> ConversationStore {
        let store = ConversationStore()
        // 快照在 SessionStore 初始化前预置数据，必须明确写入同一个 HostScope；
        // 否则 Profile 隔离会正确地隐藏空命名空间中的旧测试数据。
        store.activate(profileID: appStore.activeHostScope.profileID)
        return store
    }

    private func makeRecentWorkspaceStore(workspaces: [AgentWorkspace], endpoint: String) -> RecentWorkspaceStore {
        let suiteName = "ConversationSnapshotTests.RecentWorkspaces.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = RecentWorkspaceStore(defaults: defaults)
        store.save(workspaces, endpoint: endpoint)
        return store
    }

    private func makeSnapshotSession(
        id: String,
        project: AgentProject,
        title: String,
        status: String,
        preview: String,
        activeTurnID: TurnID? = nil,
        usage: UsageSummary? = nil,
        rateLimit: RateLimitSummary? = nil,
        pendingApproval: ApprovalSummary? = nil,
        goal: ThreadGoal? = nil,
        runtimeProvider: String? = nil,
        context: SessionContextSnapshot? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        recencyAt: Date? = nil
    ) -> AgentSession {
        AgentSession(
            id: id,
            projectID: project.id,
            project: project.name,
            dir: project.path,
            title: title,
            status: status,
            source: "codex",
            runtimeProvider: runtimeProvider,
            resumeID: "thread-\(id)",
            createdAt: createdAt,
            updatedAt: updatedAt,
            recencyAt: recencyAt,
            preview: preview,
            activeTurnID: activeTurnID,
            lastSeq: 42,
            revision: 3,
            usage: usage,
            rateLimit: rateLimit,
            pendingApproval: pendingApproval,
            goal: goal,
            context: context
        )
    }
}

@MainActor
final class PendingApprovalCardSnapshotTests: SimplifiedChineseSnapshotTestCase {
    private let longCommand = """
    echo "=== find agentd logs ==="; ls -lat /private/tmp/*agentd* /private/tmp/mimi* /tmp/*agentd* 2>/dev/null | head
    echo "=== app LaunchAgent log config ==="; plutil -p "/Applications/Mimi Remote Mac.app/Contents/Library/LaunchAgents/com.gaixianggeng.mimi.mac.agentd.plist"
    echo "=== user logs ==="; ls -lat "$HOME/Library/Logs/" 2>/dev/null | grep -i mimi | head
    """

    func testPendingApprovalCardFitsIPhoneTouchLayout() {
        let view = makeCard(horizontalSizeClass: .compact)
            .padding(16)
            .frame(width: 390, height: 500, alignment: .top)
            .background(Color(uiColor: .systemGroupedBackground))

        assertSnapshot(
            of: view,
            as: .image(precision: 0.98, layout: .fixed(width: 390, height: 500))
        )
    }

    func testPendingApprovalCardUsesWiderIPadPreview() {
        let view = makeCard(horizontalSizeClass: .regular)
            .padding(20)
            .frame(width: 760, height: 500, alignment: .top)
            .background(Color(uiColor: .systemGroupedBackground))

        assertSnapshot(
            of: view,
            as: .image(precision: 0.98, layout: .fixed(width: 760, height: 500))
        )
    }

    private func makeCard(horizontalSizeClass: UserInterfaceSizeClass) -> some View {
        let suiteName = "PendingApprovalCardSnapshotTests.Theme.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let themeStore = ThemeStore(defaults: defaults)
        let approval = ApprovalSummary(
            id: "approval-touch-layout",
            title: L10n.format("ui.agent_requests_execution_command_value", longCommand),
            body: longCommand,
            kind: "command",
            risk: "high",
            count: nil
        )

        return PendingApprovalActionCard(
            approval: approval,
            runtimePresentation: SessionRuntimePresentation(
                runtimeProvider: horizontalSizeClass == .compact ? "codex" : "claude",
                source: "codex"
            ),
            isSendingDecision: false,
            onDecision: { _ in }
        )
        .environmentObject(themeStore)
        .environment(\.colorScheme, .light)
        .environment(\.horizontalSizeClass, horizontalSizeClass)
    }
}

@MainActor
final class PendingUserInputSheetSnapshotTests: SimplifiedChineseSnapshotTestCase {
    func testInlineUserInputCardMatchesApprovalChromeOnIPad() {
        let request = AgentUserInputRequest(
            id: "inline-style-request",
            threadID: "inline-style-thread",
            turnID: "inline-style-turn",
            itemID: "inline-style-item",
            questions: [
                AgentUserInputQuestion(
                    id: "implementation",
                    header: "实现方式",
                    question: "你希望接下来按哪一种方式继续？",
                    isOther: false,
                    isSecret: false,
                    options: [
                        AgentUserInputOption(label: "直接实现", description: "按当前方案完成修改"),
                        AgentUserInputOption(label: "先看预览", description: "确认界面后再继续")
                    ]
                )
            ]
        )
        let suiteName = "PendingUserInputInlineSnapshotTests.Theme.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let themeStore = ThemeStore(defaults: defaults)
        let view = PendingUserInputActionCard(
            request: request,
            runtimePresentation: SessionRuntimePresentation(runtimeProvider: "codex", source: "codex"),
            isSubmitting: false,
            draft: .constant(PendingUserInputDraft()),
            onSubmit: { _ in true }
        )
        .environmentObject(themeStore)
        .environment(\.colorScheme, .light)
        .padding(20)
        .frame(width: 760, height: 360, alignment: .top)
        .background(Color(uiColor: .systemGroupedBackground))

        assertSnapshot(
            of: view,
            as: .image(precision: 0.98, layout: .fixed(width: 760, height: 360))
        )
    }

    func testLongMultiSelectFormKeepsBottomActionsVisibleOnIPhone() {
        let options = (1...6).map { index in
            AgentUserInputOption(
                label: "选项 \(index)",
                description: "这是用于验证小屏长表单滚动与文字换行的说明。"
            )
        }
        let questions = (1...5).map { index in
            AgentUserInputQuestion(
                id: "question-\(index)",
                header: "问题 \(index)",
                question: "请选择这一组里所有需要继续执行的优化项。",
                isOther: index == 5,
                isSecret: false,
                options: options,
                multiSelect: true
            )
        }
        let request = AgentUserInputRequest(
            id: "snapshot-request",
            threadID: "snapshot-thread",
            turnID: "snapshot-turn",
            itemID: "snapshot-item",
            questions: questions
        )
        let suiteName = "PendingUserInputSheetSnapshotTests.Theme.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let themeStore = ThemeStore(defaults: defaults)
        let view = PendingUserInputSheet(
            presentation: PendingUserInputPresentation(
                request: request,
                runtimePresentation: SessionRuntimePresentation(runtimeProvider: "claude", source: "codex")
            ),
            isSubmitting: false,
            draft: .constant(PendingUserInputDraft()),
            onSubmit: { _ in true }
        )
        .environmentObject(themeStore)
        .environment(\.colorScheme, .light)
        .frame(width: 390, height: 844)

        assertSnapshot(
            of: view,
            as: .wait(
                for: 0.8,
                on: .image(precision: 0.98, layout: .fixed(width: 390, height: 844))
            )
        )
    }
}

private enum SnapshotAPIError: Error {
    case unimplemented
}

private struct SnapshotSessionAPIClient: SessionStoreAPIClient {
    let projects: [AgentProject]
    let sessions: [AgentSession]

    func projects() async throws -> [AgentProject] {
        projects
    }

    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] {
        let filtered = projectID.map { id in sessions.filter { $0.projectID == id } } ?? sessions
        guard let limit else {
            return filtered
        }
        return Array(filtered.prefix(limit))
    }

    func sessionsPage(projectID: String?, cursor: String?, limit: Int?) async throws -> SessionsPage {
        SessionsPage(sessions: try await sessions(projectID: projectID, cursor: cursor, limit: limit))
    }

    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        throw SnapshotAPIError.unimplemented
    }

    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse {
        throw SnapshotAPIError.unimplemented
    }

    func stopSession(id: String) async throws {
        throw SnapshotAPIError.unimplemented
    }

    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage] {
        throw SnapshotAPIError.unimplemented
    }

    func messagesPage(sessionID: String, before: String?, limit: Int?) async throws -> HistoryMessagesPage {
        throw SnapshotAPIError.unimplemented
    }
}
