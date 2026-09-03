import SwiftUI
import UIKit
import XCTest
@testable import MimiRemote

@MainActor
extension ConversationDataFlowTests {
    func testComposerTurnSettingsPolicyFollowsWriterControl() {
        XCTAssertEqual(ComposerTurnSettingsPolicy.resolve(canControlSession: true), .editable)
        XCTAssertEqual(ComposerTurnSettingsPolicy.resolve(canControlSession: false), .unavailable)
        XCTAssertTrue(ComposerTurnSettingsPolicy.editable.allowsTurnSettingsEditing)
        XCTAssertFalse(ComposerTurnSettingsPolicy.unavailable.allowsTurnSettingsEditing)
        XCTAssertEqual(
            ComposerTurnSettingsPolicy.unavailableMenuNotice,
            "当前设备拥有会话控制权时，才能修改模型或计划模式"
        )
    }

    func testComposerTurnSettingsPolicyUsesSessionControlState() {
        let store = SessionStore(
            appStore: makeIsolatedAppStore(),
            conversationStore: ConversationStore(),
            logStore: LogStore()
        )
        let running = makeSession(
            id: "composer-control-running",
            projectID: "composer-control-project",
            title: "控制权测试",
            status: "running",
            source: "codex",
            activeTurnID: "composer-control-turn"
        )

        for state in [SessionControlState.ipadOwned, .takenOver] {
            store.sessionControlStateByID[running.id] = state
            XCTAssertEqual(
                ComposerTurnSettingsPolicy.resolve(canControlSession: store.canControlSession(running)),
                .editable
            )
        }

        store.sessionControlStateByID[running.id] = .observing
        XCTAssertEqual(
            ComposerTurnSettingsPolicy.resolve(canControlSession: store.canControlSession(running)),
            .unavailable
        )

        store.sessionControlStateByID[running.id] = .takenOver
        store.setActiveWriterConflict(true, sessionID: running.id)
        XCTAssertEqual(
            ComposerTurnSettingsPolicy.resolve(canControlSession: store.canControlSession(running)),
            .unavailable
        )

        store.setActiveWriterConflict(false, sessionID: running.id)
        var readOnly = running
        readOnly.canAcceptDirectInput = false
        XCTAssertEqual(
            ComposerTurnSettingsPolicy.resolve(canControlSession: store.canControlSession(readOnly)),
            .unavailable
        )

        var idle = running
        idle.status = SessionStatus.completed.rawValue
        idle.activeTurnID = nil
        XCTAssertEqual(
            ComposerTurnSettingsPolicy.resolve(canControlSession: store.canControlSession(idle)),
            .editable
        )
    }

    func testCompactComposerModelTitleUsesDeterministicWidthPolicy() {
        XCTAssertFalse(ConversationLayout.compactComposerShowsModelTitle(availableWidth: nil))
        XCTAssertFalse(ConversationLayout.compactComposerShowsModelTitle(availableWidth: 379))
        XCTAssertTrue(ConversationLayout.compactComposerShowsModelTitle(availableWidth: 380))
        XCTAssertTrue(ConversationLayout.compactComposerShowsModelTitle(availableWidth: 520))
        XCTAssertFalse(ConversationLayout.phoneComposerShowsModelTitle(availableWidth: nil))
        XCTAssertTrue(ConversationLayout.phoneComposerShowsModelTitle(availableWidth: 296))
        XCTAssertTrue(ConversationLayout.phoneComposerShowsModelTitle(availableWidth: 320))
        XCTAssertEqual(ConversationLayout.compactComposerModelTitleMaxWidth(availableWidth: 296), 36)
        XCTAssertEqual(ConversationLayout.compactComposerModelTitleMaxWidth(availableWidth: 320), 48)
        XCTAssertEqual(ConversationLayout.compactComposerModelTitleMaxWidth(availableWidth: 350), 64)
        XCTAssertEqual(ConversationLayout.compactComposerModelTitleMaxWidth(availableWidth: 380), 88)
        XCTAssertFalse(
            ConversationLayout.compactComposerShowsInlineDeliveryControl(
                isPhone: true,
                availableWidth: 390,
                canChooseDelivery: true
            )
        )
        XCTAssertFalse(
            ConversationLayout.compactComposerShowsInlineDeliveryControl(
                isPhone: false,
                availableWidth: 320,
                canChooseDelivery: true
            )
        )
        XCTAssertFalse(
            ConversationLayout.compactComposerShowsInlineDeliveryControl(
                isPhone: false,
                availableWidth: 439,
                canChooseDelivery: true
            )
        )
        XCTAssertTrue(
            ConversationLayout.compactComposerShowsInlineDeliveryControl(
                isPhone: false,
                availableWidth: 440,
                canChooseDelivery: true
            )
        )
        XCTAssertFalse(
            ConversationLayout.compactComposerShowsFastModeIndicator(
                usesCompactMetrics: true,
                isFastModeSelected: true
            )
        )
        XCTAssertTrue(
            ConversationLayout.compactComposerShowsFastModeIndicator(
                usesCompactMetrics: false,
                isFastModeSelected: true
            )
        )

        // 320pt 小屏：Fast 状态不另占图标，运行态投递方式收进设置；+、受控模型名、
        // 设置、语音和发送都保留 44pt 命中区，
        // 组间/组内 6pt 后仍不能超过卡片 8pt 内边距以内的可用宽度。
        let narrowLayout = ConversationLayout(containerWidth: 320, horizontalSizeClass: .compact)
        let modelControlWidth: CGFloat = max(44, 48 + 24)
        let leadingControlsWidth = 44 + 6 + modelControlWidth
        let toolControlsWidth: CGFloat = 44 + 6 + 44
        let requiredToolbarWidth = leadingControlsWidth + toolControlsWidth + 44 + 18
        XCTAssertLessThanOrEqual(requiredToolbarWidth, narrowLayout.composerAvailableWidth - 16)
    }

    func testPhoneComposerTextStartsAtOneLineAndGrowsToBoundedHeight() {
        let minimum = ComposerTextLayoutPolicy.minimumHeight(
            isPhone: true,
            usesCompactMetrics: true,
            fontLineHeight: 20
        )
        let maximum = ComposerTextLayoutPolicy.maximumHeight(
            isPhone: true,
            usesCompactMetrics: true,
            fontLineHeight: 20
        )

        XCTAssertEqual(minimum, 36)
        XCTAssertGreaterThan(maximum, minimum)
        XCTAssertLessThanOrEqual(maximum, 180)
        XCTAssertEqual(
            ComposerTextLayoutPolicy.minimumHeight(
                isPhone: false,
                usesCompactMetrics: true,
                fontLineHeight: 20
            ),
            72
        )
    }

    func testCompactComposerToolbarRendersWithoutGenericMetadataStackOverflow() throws {
        let defaultsSuite = "CompactComposerToolbarTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defaults.removePersistentDomain(forName: defaultsSuite)
        defer {
            defaults.removePersistentDomain(forName: defaultsSuite)
        }

        let conversationStore = ConversationStore()
        let sessionStore = SessionStore(
            appStore: AppStore(
                defaults: defaults,
                tokenStore: TokenStore(keychain: TestKeychainOperations())
            ),
            conversationStore: conversationStore,
            logStore: LogStore()
        )
        let runningSession = makeSession(
            id: "compact-toolbar-running",
            projectID: "compact-toolbar-project",
            title: "紧凑工具栏回归",
            status: "running",
            source: "codex",
            activeTurnID: "compact-toolbar-turn"
        )
        sessionStore.sessionsByID[runningSession.id] = runningSession
        sessionStore.selectedSessionID = runningSession.id
        sessionStore.sessionControlStateByID[runningSession.id] = .takenOver
        let themeStore = ThemeStore(defaults: defaults)
        let rootView: (CGFloat, CGFloat) -> AnyView = { width, height in
            AnyView(
                ComposerView(availableWidth: width)
                    .environmentObject(sessionStore)
                    .environmentObject(themeStore)
                    .environment(\.horizontalSizeClass, .compact)
                    .defaultAppStorage(defaults)
                    .frame(width: width, height: height)
            )
        }
        let host = UIHostingController(rootView: rootView(320, 520))

        // 同一个 Host 反复切换窄/宽与横竖尺寸，覆盖模型标题显隐和旋转后的重建。
        let layoutScenarios: [(width: CGFloat, height: CGFloat)] = [
            (320, 520),
            (390, 360),
            (667, 300),
            (390, 360)
        ]
        for (width, height) in layoutScenarios {
            host.rootView = rootView(width, height)
            host.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            XCTAssertGreaterThan(host.sizeThatFits(in: CGSize(width: width, height: height)).height, 0)
        }

        // 运行态会增加“排队/引导”菜单；完成态移除它。来回切换验证两个泛型分支
        // 都只通过浅层 shell 构建，不会再次把巨大 Menu 类型聚合进同一栈帧。
        var completedSession = runningSession
        completedSession.status = SessionStatus.completed.rawValue
        completedSession.activeTurnID = nil
        for session in [completedSession, runningSession, completedSession, runningSession] {
            sessionStore.sessionsByID[session.id] = session
            host.rootView = rootView(390, 360)
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            XCTAssertGreaterThan(host.sizeThatFits(in: CGSize(width: 390, height: 360)).height, 0)
        }

        XCTAssertGreaterThan(host.view.bounds.width, 0)
    }

    func testIPadComposerDefaultsExpandedAndExplicitCollapseUsesSingleRow() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("该布局回归仅在 iPad 目标上验证")
        }

        let defaultsSuite = "IPadComposerCollapseTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defaults.removePersistentDomain(forName: defaultsSuite)
        defer {
            defaults.removePersistentDomain(forName: defaultsSuite)
        }

        let conversationStore = ConversationStore()
        let sessionStore = SessionStore(
            appStore: AppStore(
                defaults: defaults,
                tokenStore: TokenStore(keychain: TestKeychainOperations())
            ),
            conversationStore: conversationStore,
            logStore: LogStore()
        )
        let session = makeSession(
            id: "ipad-composer-collapse",
            projectID: "ipad-composer-project",
            title: "iPad Composer 收起回归",
            status: SessionStatus.completed.rawValue,
            source: "local"
        )
        sessionStore.sessionsByID[session.id] = session
        sessionStore.selectedSessionID = session.id
        let themeStore = ThemeStore(defaults: defaults)

        let measuredHeight: (Bool?) -> CGFloat = { initiallyCollapsed in
            let host = UIHostingController(
                rootView: AnyView(
                    ComposerView(
                        availableWidth: 900,
                        initialComposerCollapsed: initiallyCollapsed
                    )
                    .environmentObject(sessionStore)
                    .environmentObject(themeStore)
                    .environment(\.horizontalSizeClass, .regular)
                    .defaultAppStorage(defaults)
                    .frame(width: 900)
                )
            )
            host.view.frame = CGRect(x: 0, y: 0, width: 900, height: 1_000)
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            return host.sizeThatFits(in: CGSize(width: 900, height: 1_000)).height
        }

        // 两个独立 Host 避免 SwiftUI 在替换同类型根视图时复用上一棵树的 @State，
        // 同时用 nil 覆盖生产默认值，确认 iPad 首次进入仍然保持展开。
        let expandedHeight = measuredHeight(nil)
        let collapsedHeight = measuredHeight(true)

        XCTAssertGreaterThan(expandedHeight, collapsedHeight)
        XCTAssertGreaterThanOrEqual(collapsedHeight, 60, "收起态必须保留 44pt 触控行和卡片内边距")
        XCTAssertLessThanOrEqual(collapsedHeight, 72, "收起态加上 Composer 既有固定间距后仍只能占一行")
    }

    func testComposerRetiredTextViewDropsLateInputMethodCallbacks() {
        var boundText = ""
        var focusRequestID: UUID?
        let bridge = ComposerTextSubmitBridge()
        let representable = ComposerTextView(
            text: Binding(
                get: { boundText },
                set: { boundText = $0 }
            ),
            submitBridge: bridge,
            font: .preferredFont(forTextStyle: .body),
            textColor: .label,
            tintColor: .systemBlue,
            externalTextRevision: 0,
            focusRequestID: Binding(
                get: { focusRequestID },
                set: { focusRequestID = $0 }
            ),
            minHeight: 72,
            maxHeight: 220,
            onSubmit: { true },
            onContentHeightChange: { _ in },
            onCompositionStateChange: { _ in },
            onVoiceShortcutPressChanged: { _ in },
            skillAutocompleteActive: false,
            onSkillQueryChange: { _ in },
            onSkillAutocompleteMove: { _ in },
            onSkillAutocompleteCommit: {},
            onSkillAutocompleteDismiss: {}
        )
        let coordinator = representable.makeCoordinator()
        let textView = CommandSubmitTextView()
        textView.delegate = coordinator
        textView.onRetireFromComposer = { coordinator.retireFromComposer() }
        textView.text = String(repeating: "很长的中文正文", count: 80)
        bridge.attach(textView)

        // 模拟 iPhone 发送后清空附件并折叠输入卡，再由输入法补发旧文本回调。
        boundText = ""
        bridge.prepareForRemoval(text: "")
        XCTAssertTrue(textView.isRetiredFromComposer)
        XCTAssertNil(bridge.snapshotForSubmit(), "折叠态重试不能再读取已退休编辑器")
        textView.text = "迟到的输入法旧文本"
        coordinator.textViewDidChange(textView)
        coordinator.textViewDidChangeSelection(textView)
        coordinator.textViewDidEndEditing(textView)

        XCTAssertEqual(boundText, "", "已退休编辑器的迟到回调不能复活已发送正文")
    }

    func testComposerCoordinatorDropsDelegateWritesDuringSwiftUISynchronization() {
        var boundText = "SwiftUI 草稿"
        var focusRequestID: UUID?
        let representable = makeComposerTextView(
            text: Binding(
                get: { boundText },
                set: { boundText = $0 }
            ),
            focusRequestID: Binding(
                get: { focusRequestID },
                set: { focusRequestID = $0 }
            )
        )
        let coordinator = representable.makeCoordinator()
        let textView = CommandSubmitTextView()
        textView.text = "UIKit 系统同步"

        coordinator.performSwiftUISynchronization {
            coordinator.textViewDidChange(textView)
            coordinator.textViewDidChangeSelection(textView)
            coordinator.textViewDidEndEditing(textView)
        }

        XCTAssertFalse(coordinator.isSynchronizingFromSwiftUI)
        XCTAssertEqual(boundText, "SwiftUI 草稿", "SwiftUI 更新事务中的 delegate 回调不能反向写 Binding")
    }

    func testComposerCoordinatorPublishesRealUserInputOutsideSwiftUISynchronization() {
        var boundText = ""
        var focusRequestID: UUID?
        let representable = makeComposerTextView(
            text: Binding(
                get: { boundText },
                set: { boundText = $0 }
            ),
            focusRequestID: Binding(
                get: { focusRequestID },
                set: { focusRequestID = $0 }
            )
        )
        let coordinator = representable.makeCoordinator()
        let textView = CommandSubmitTextView()
        textView.text = "真实用户输入"

        coordinator.textViewDidChange(textView)

        XCTAssertEqual(boundText, "真实用户输入", "保护期外的真实输入仍需立即写回草稿")
    }

    func testComposerCoordinatorCoalescesSkillQueryToLatestInput() async {
        var boundText = ""
        var focusRequestID: UUID?
        var reportedQueries: [String?] = []
        let reported = expectation(description: "只发布最新 Skill 查询")
        let representable = makeComposerTextView(
            text: Binding(
                get: { boundText },
                set: { boundText = $0 }
            ),
            focusRequestID: Binding(
                get: { focusRequestID },
                set: { focusRequestID = $0 }
            ),
            onSkillQueryChange: { query in
                reportedQueries.append(query?.query)
                reported.fulfill()
            }
        )
        let coordinator = representable.makeCoordinator()
        let textView = CommandSubmitTextView()

        textView.text = "$a"
        textView.selectedRange = NSRange(location: 2, length: 0)
        coordinator.textViewDidChange(textView)
        textView.text = "$apple"
        textView.selectedRange = NSRange(location: 6, length: 0)
        coordinator.textViewDidChange(textView)

        XCTAssertTrue(reportedQueries.isEmpty, "Skill 查询不能在 UIKit delegate 调用栈里同步发布")
        await fulfillment(of: [reported], timeout: 1)
        XCTAssertEqual(reportedQueries, ["apple"])
    }

    func testComposerSubmissionRevisionProtectsNextDraftWithImage() throws {
        var composerState = ComposerState()
        composerState.draft = String(repeating: "长文本", count: 120)
        composerState.addAttachment(.image(url: "data:image/jpeg;base64,AA==", detail: .auto))

        let submitted = try XCTUnwrap(composerState.takeDraftForSubmit(isLoading: false))

        XCTAssertTrue(composerState.canRestore(submitted), "用户尚未继续编辑时允许恢复明确失败的发送")
        composerState.draft = "发送期间输入的下一条消息"
        XCTAssertFalse(composerState.canRestore(submitted), "迟到失败回调不能覆盖下一条草稿")
        XCTAssertEqual(composerState.draft, "发送期间输入的下一条消息")
        XCTAssertTrue(composerState.attachments.isEmpty)
    }

    func testPendingUserInputDraftBuildsStableSingleMultiAndFreeformPayload() {
        let single = AgentUserInputQuestion(
            id: "strategy",
            header: "策略",
            question: "选择一种策略",
            isOther: false,
            isSecret: false,
            options: [
                AgentUserInputOption(label: "快速", description: nil),
                AgentUserInputOption(label: "稳妥", description: nil)
            ]
        )
        let multiple = AgentUserInputQuestion(
            id: "checks",
            header: "检查项",
            question: "选择需要执行的检查",
            isOther: true,
            isSecret: false,
            options: [
                AgentUserInputOption(label: "单测", description: nil),
                AgentUserInputOption(label: "快照", description: nil),
                AgentUserInputOption(label: "真机", description: nil)
            ],
            multiSelect: true
        )
        let request = AgentUserInputRequest(
            id: "request-1",
            threadID: "thread-1",
            turnID: "turn-1",
            itemID: "item-1",
            questions: [single, multiple]
        )
        var draft = PendingUserInputDraft()

        XCTAssertFalse(draft.canSubmit(request))
        draft.toggleOption("快速", for: single)
        draft.toggleOption("稳妥", for: single)
        draft.toggleOption("快照", for: multiple)
        draft.toggleOption("单测", for: multiple)
        draft.setFreeformAnswer("  弱网  ", for: multiple.id)

        XCTAssertTrue(draft.canSubmit(request))
        XCTAssertEqual(draft.answerPayload(for: request)[single.id], ["稳妥"])
        XCTAssertEqual(draft.answerPayload(for: request)[multiple.id], ["单测", "快照", "弱网"])

        draft.toggleOption("快照", for: multiple)
        XCTAssertEqual(draft.answerPayload(for: request)[multiple.id], ["单测", "弱网"])
    }

    func testPendingUserInputFormStatePreservesSameRequestAndResetsDifferentThreadRequest() {
        var state = PendingUserInputFormState()
        let question = AgentUserInputQuestion(
            id: "scope",
            header: "范围",
            question: "选择范围",
            isOther: false,
            isSecret: false,
            options: [AgentUserInputOption(label: "当前会话", description: nil)]
        )

        state.activate("thread-a:request-1")
        state.draft.toggleOption("当前会话", for: question)
        let savedDraft = state.draft
        state.activate("thread-a:request-1")
        XCTAssertEqual(state.draft, savedDraft, "关闭并重新打开同一请求时必须保留答案")

        var recreatedState = state
        XCTAssertFalse(
            recreatedState.resetIfSessionChanged(from: nil, to: "thread-a"),
            "横竖屏重建时没有 previous session，不能把它误判成会话切换"
        )
        XCTAssertEqual(recreatedState.draft, savedDraft, "View 重建后应从 SessionStore 内存缓存恢复答案")

        XCTAssertTrue(recreatedState.resetIfSessionChanged(from: "thread-a", to: "thread-b"))
        XCTAssertEqual(recreatedState.draft, PendingUserInputDraft(), "真正切换会话时必须清理旧答案")

        state.activate("thread-b:request-1")
        XCTAssertEqual(state.draft, PendingUserInputDraft(), "相同 request ID 出现在另一 thread 时不能继承旧答案")
        XCTAssertEqual(state.activePresentationID, "thread-b:request-1")

        state.resetForSessionChange()
        XCTAssertNil(state.activePresentationID)
        XCTAssertEqual(state.draft, PendingUserInputDraft())
    }

    func testTerminalTurnClearsMcpFormAndReattachDoesNotReplayIt() async {
        let runtime = CodexAppServerSessionRuntime(endpoint: "http://127.0.0.1:8787", token: "test")
        let request = CodexAppServerServerRequest(
            id: .string("mcp-terminal-form"),
            method: "mcpServer/elicitation/request",
            params: .object([
                "threadId": .string("thr_terminal_form"),
                "turnId": .string("turn_terminal_form"),
                "serverName": .string("linear"),
                "mode": .string("form"),
                "message": .string("请选择目标状态"),
                "requestedSchema": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "state": .object([
                            "type": .string("string"),
                            "enum": .array([.string("Todo"), .string("Done")])
                        ])
                    ])
                ])
            ])
        )

        await runtime.handle(request)
        let livePending = await runtime.pendingInteractionEvents(sessionID: "thr_terminal_form")
        XCTAssertTrue(livePending.contains {
            if case .userInputRequest(let input, _) = $0 {
                return input.id == "mcp-terminal-form"
            }
            return false
        })

        await runtime.handle(CodexAppServerNotification(
            method: "turn/completed",
            params: .object([
                "threadId": .string("thr_terminal_form"),
                "turnId": .string("turn_terminal_form")
            ])
        ))
        // terminal 之后迟到的 resolved 也不能再投影“恢复为 running”。
        await runtime.handle(CodexAppServerNotification(
            method: "serverRequest/resolved",
            params: .object([
                "threadId": .string("thr_terminal_form"),
                "turnId": .string("turn_terminal_form"),
                "requestId": .string("mcp-terminal-form")
            ])
        ))

        let pendingAfterTerminal = await runtime.pendingInteractionEvents(sessionID: "thr_terminal_form")
        XCTAssertTrue(pendingAfterTerminal.isEmpty)

        // 模拟切页后重新订阅：backlog 只应包含终态，不得重新投递旧 MCP form。
        let reattached = await runtime.attachEvents(
            sessionID: "thr_terminal_form",
            replayPolicy: .stateOnly
        )
        var iterator = reattached.makeAsyncIterator()
        var replayed: [AgentEvent] = []
        for _ in 0..<2 {
            if let event = await iterator.next() {
                replayed.append(event)
            }
        }
        reattached.cancel()
        XCTAssertFalse(replayed.contains {
            if case .userInputRequest = $0 {
                return true
            }
            return false
        })
        XCTAssertTrue(replayed.contains {
            if case .turnCompleted(let metadata) = $0 {
                return metadata.sessionID == "thr_terminal_form"
            }
            return false
        })
    }

    func testRetryableErrorKeepsPendingMcpFormsUntilTerminalError() async {
        let runtime = CodexAppServerSessionRuntime(endpoint: "http://127.0.0.1:8787", token: "test")
        func request(_ id: String) -> CodexAppServerServerRequest {
            CodexAppServerServerRequest(
                id: .string(id),
                method: "mcpServer/elicitation/request",
                params: .object([
                    "threadId": .string("thr_retryable_error"),
                    "turnId": .string("turn_retryable_error"),
                    "serverName": .string("linear"),
                    "mode": .string("form"),
                    "message": .string("请选择重试后的操作"),
                    "requestedSchema": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "choice": .object([
                                "type": .string("string"),
                                "enum": .array([.string("one"), .string("two")])
                            ])
                        ])
                    ])
                ])
            )
        }

        await runtime.handle(request("mcp-before-retry"))
        await runtime.handle(CodexAppServerNotification(
            method: "error",
            params: .object([
                "threadId": .string("thr_retryable_error"),
                "turnId": .string("turn_retryable_error"),
                "willRetry": .bool(true),
                "error": .object(["message": .string("temporary failure")])
            ])
        ))
        await runtime.handle(request("mcp-after-retry"))

        let pendingAfterRetry = await runtime.pendingInteractionEvents(sessionID: "thr_retryable_error")
        let retryIDs = Set(pendingAfterRetry.compactMap { event -> String? in
            guard case .userInputRequest(let input, _) = event else {
                return nil
            }
            return input.id
        })
        XCTAssertEqual(retryIDs, ["mcp-before-retry", "mcp-after-retry"])

        await runtime.handle(CodexAppServerNotification(
            method: "error",
            params: .object([
                "threadId": .string("thr_retryable_error"),
                "turnId": .string("turn_retryable_error"),
                "willRetry": .bool(false),
                "error": .object(["message": .string("terminal failure")])
            ])
        ))
        let pendingAfterTerminalError = await runtime.pendingInteractionEvents(sessionID: "thr_retryable_error")
        XCTAssertTrue(pendingAfterTerminalError.isEmpty)
    }

    func testTerminalBarrierKeepsTurnIndependentMcpURLRequests() async {
        let runtime = CodexAppServerSessionRuntime(endpoint: "http://127.0.0.1:8787", token: "test")
        func request(_ id: String) -> CodexAppServerServerRequest {
            CodexAppServerServerRequest(
                id: .string(id),
                method: "mcpServer/elicitation/request",
                params: .object([
                    "threadId": .string("thr_independent_url"),
                    "serverName": .string("calendar"),
                    "mode": .string("url"),
                    "message": .string("请完成授权"),
                    "url": .string("https://example.test/oauth")
                ])
            )
        }

        await runtime.handle(request("mcp-url-before-terminal"))
        await runtime.handle(CodexAppServerNotification(
            method: "turn/completed",
            params: .object([
                "threadId": .string("thr_independent_url"),
                "turnId": .string("turn_completed")
            ])
        ))
        await runtime.handle(request("mcp-url-after-terminal"))

        let pending = await runtime.pendingInteractionEvents(sessionID: "thr_independent_url")
        let approvalIDs = Set(pending.compactMap { event -> String? in
            guard case .approvalRequest(let approval, _) = event else {
                return nil
            }
            return approval.id
        })
        XCTAssertEqual(approvalIDs, ["mcp-url-before-terminal", "mcp-url-after-terminal"])
    }

    func testResolvedBeforeServerRequestDoesNotCreateOrphanUserInput() async {
        let runtime = CodexAppServerSessionRuntime(endpoint: "http://127.0.0.1:8787", token: "test")
        await runtime.handle(CodexAppServerNotification(
            method: "serverRequest/resolved",
            params: .object([
                "threadId": .string("thr_resolved_first"),
                "requestId": .string("mcp-resolved-first")
            ])
        ))
        await runtime.handle(CodexAppServerServerRequest(
            id: .string("mcp-resolved-first"),
            method: "mcpServer/elicitation/request",
            params: .object([
                "threadId": .string("thr_resolved_first"),
                "turnId": .string("turn_resolved_first"),
                "serverName": .string("linear"),
                "mode": .string("form"),
                "message": .string("请选择操作"),
                "requestedSchema": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "choice": .object([
                            "type": .string("string"),
                            "enum": .array([.string("one"), .string("two")])
                        ])
                    ])
                ])
            ])
        ))

        let pending = await runtime.pendingInteractionEvents(sessionID: "thr_resolved_first")
        XCTAssertTrue(pending.isEmpty)
        let buffered = await runtime.bufferedEvents(
            sessionID: "thr_resolved_first",
            replayPolicy: .stateOnly
        )
        XCTAssertFalse(buffered.contains {
            if case .userInputRequest = $0 {
                return true
            }
            return false
        })
    }

    func testTerminalBeforeNoTurnMcpConfirmationDoesNotCreateOrphanApproval() async {
        let runtime = CodexAppServerSessionRuntime(endpoint: "http://127.0.0.1:8787", token: "test")
        await runtime.handle(CodexAppServerNotification(
            method: "turn/completed",
            params: .object([
                "threadId": .string("thr_terminal_first"),
                "turnId": .string("turn_terminal_first")
            ])
        ))
        await runtime.handle(CodexAppServerServerRequest(
            id: .string("mcp-terminal-first"),
            method: "mcpServer/elicitation/request",
            params: .object([
                "threadId": .string("thr_terminal_first"),
                "serverName": .string("linear"),
                "mode": .string("form"),
                "message": .string("Allow the linear MCP server to run tool \"save_issue\"?"),
                "requestedSchema": .object([
                    "type": .string("object"),
                    "properties": .object([:])
                ])
            ])
        ))

        let pending = await runtime.pendingInteractionEvents(sessionID: "thr_terminal_first")
        XCTAssertTrue(pending.isEmpty)
    }

    private func makeComposerTextView(
        text: Binding<String>,
        focusRequestID: Binding<UUID?>,
        onSkillQueryChange: @escaping (ComposerSkillQuery?) -> Void = { _ in }
    ) -> ComposerTextView {
        ComposerTextView(
            text: text,
            submitBridge: ComposerTextSubmitBridge(),
            font: .preferredFont(forTextStyle: .body),
            textColor: .label,
            tintColor: .systemBlue,
            externalTextRevision: 0,
            focusRequestID: focusRequestID,
            minHeight: 72,
            maxHeight: 220,
            onSubmit: { true },
            onContentHeightChange: { _ in },
            onCompositionStateChange: { _ in },
            onVoiceShortcutPressChanged: { _ in },
            skillAutocompleteActive: false,
            onSkillQueryChange: onSkillQueryChange,
            onSkillAutocompleteMove: { _ in },
            onSkillAutocompleteCommit: {},
            onSkillAutocompleteDismiss: {}
        )
    }
}

@MainActor
final class ComposerStatusTrayBehaviorTests: XCTestCase {
    func testTakeoverCapableObservationOffersDisclosure() {
        let notice = "Takeover is available."

        XCTAssertTrue(
            makeTray(
                sessionControlNotice: notice,
                allowsTakeOver: true
            ).hasExpandableDetail,
            "A takeover-capable observation must reveal the existing takeover action"
        )
        XCTAssertFalse(
            makeTray(
                sessionControlNotice: notice,
                allowsTakeOver: false
            ).hasExpandableDetail,
            "A read-only observation must not reveal an empty disclosure"
        )
        XCTAssertFalse(
            makeTray(allowsTakeOver: true).hasExpandableDetail,
            "Takeover capability alone must not create an empty disclosure"
        )
    }

    /// 「仅观察」展开前后没有更多内容时，不应该展示无效的 disclosure。
    func testStatusTrayOnlyOffersDisclosureWhenExpandingRevealsSomething() {
        XCTAssertFalse(
            makeTray(sessionControlNotice: "当前由 Mac 端控制，仅观察。").hasExpandableDetail,
            "只有观察状态时不应该提供展开入口"
        )

        let messageDate = Date(timeIntervalSince1970: 1_782_879_660)
        let goal = ThreadGoal(
            threadID: "thread-disclosure",
            objective: "继续推进海报编辑体验。",
            status: .active,
            tokenBudget: 2_000_000,
            tokensUsed: 120_000,
            timeUsedSeconds: 240,
            createdAt: messageDate,
            updatedAt: messageDate
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
        XCTAssertEqual(ComposerStatusTrayPlacement.embedded.visualHeight, 36)

        XCTAssertTrue(ComposerStatusTrayPlacement.standalone.usesIndependentSurface)
        XCTAssertFalse(ComposerStatusTrayPlacement.standalone.usesEmbeddedStatusChip)
        XCTAssertEqual(ComposerStatusTrayPlacement.standalone.expandedContentPadding, 10)
        XCTAssertEqual(ComposerStatusTrayPlacement.standalone.collapsedLeadingPadding, 10)
        XCTAssertEqual(ComposerStatusTrayPlacement.standalone.visualHeight, 44)
    }

    /// disclosure 两种放置都必须给满 44×44，并且命中框中心要压在首行视觉高度的中点上。
    /// 内嵌状态条只有 36pt 高，命中框靠 -4pt 偏移上下各溢出 4pt；overlay 不参与布局，
    /// 溢出落在输入卡的 8pt 内距和 VStack 的 4pt spacing 里，不会撑高状态条。
    func testStatusTrayDisclosureKeepsFullTouchTargetInBothPlacements() {
        for placement in [ComposerStatusTrayPlacement.standalone, .embedded] {
            XCTAssertEqual(
                placement.disclosureHitSize,
                CGSize(width: 44, height: 44),
                "disclosure 必须始终满足 44×44 触控目标，不能为了迁就状态条高度缩水"
            )

            // 命中框中心 = 偏移 + 半个命中框，必须落在首行视觉高度的中点。
            let hitCenter = placement.disclosureVerticalOffset + placement.disclosureHitSize.height / 2
            XCTAssertEqual(
                hitCenter,
                placement.visualHeight / 2,
                "箭头中心必须压在首行中点，否则收起态和展开态会错位"
            )
        }

        XCTAssertEqual(ComposerStatusTrayPlacement.standalone.disclosureVerticalOffset, 0)
        XCTAssertEqual(
            ComposerStatusTrayPlacement.embedded.disclosureVerticalOffset,
            -4,
            "36pt 状态条上 44pt 命中框要上下各溢出 4pt"
        )
    }

    /// disclosure 现在锚在托盘右上角，收起态和展开态共用同一个内距，箭头不再平移。
    /// 让位宽度必须真的能容下命中框：收起态内容从托盘边缘算起，展开态内容已经被
    /// `expandedContentPadding` 内缩过一次，两边算完都不能压到按钮下面。
    func testStatusTrayDisclosureReservesEnoughRoomInBothStates() {
        let trayWidth: CGFloat = 400

        for placement in [ComposerStatusTrayPlacement.standalone, .embedded] {
            XCTAssertEqual(
                placement.disclosureTrailingInset,
                placement.expandedContentPadding,
                "disclosure 内距必须与展开态内容内距同源，否则两态之间箭头会横向平移"
            )

            let buttonLeadingEdge = trayWidth
                - placement.disclosureTrailingInset
                - placement.disclosureHitSize.width

            let collapsedContentTrailingEdge = trayWidth
                - placement.disclosureTrailingInset
                - placement.disclosureClearance
            let expandedContentTrailingEdge = trayWidth
                - placement.expandedContentPadding
                - placement.disclosureClearance

            XCTAssertLessThanOrEqual(
                collapsedContentTrailingEdge,
                buttonLeadingEdge,
                "收起态的 chip 不能压到 disclosure 命中框下面"
            )
            XCTAssertLessThanOrEqual(
                expandedContentTrailingEdge,
                buttonLeadingEdge,
                "展开态的状态模块不能压到 disclosure 命中框下面"
            )
            XCTAssertEqual(
                collapsedContentTrailingEdge,
                expandedContentTrailingEdge,
                "两态的内容右边界必须落在同一处，否则展开时状态模块会横向跳一下"
            )
        }
    }

    func testGoalTrayLightSurfaceKeepsExplicitBorderForAccessibility() {
        let reducedTransparency = ComposerStatusTraySurfaceStyle.resolve(
            scheme: .light,
            reduceTransparency: true
        )
        let increasedContrast = ComposerStatusTraySurfaceStyle.resolve(
            scheme: .light,
            reduceTransparency: false,
            increasedContrast: true
        )

        XCTAssertEqual(reducedTransparency.materialStrength, .opaque)
        XCTAssertEqual(reducedTransparency.borderOpacity, 0.08)
        XCTAssertEqual(increasedContrast.materialStrength, .opaque)
        XCTAssertEqual(increasedContrast.borderOpacity, 0.5)
    }

    /// iPhone 恒定使用 `.embedded`，这条路径不绘制独立的 `traySurface`。
    func testEmbeddedGoalTrayNeverDrawsIndependentTraySurface() {
        XCTAssertFalse(ComposerStatusTrayPlacement.embedded.usesIndependentSurface)

        for reduceTransparency in [false, true] {
            for increasedContrast in [false, true] {
                let style = ComposerStatusTraySurfaceStyle.resolve(
                    scheme: .light,
                    reduceTransparency: reduceTransparency,
                    increasedContrast: increasedContrast
                )
                XCTAssertEqual(style.materialStrength, .opaque)
                XCTAssertEqual(style.surfaceTintOpacity, 1)
            }
        }
    }

    func testComposerSendModeLabelsUseConsistentModeSuffix() {
        XCTAssertEqual(L10n.text("ui.planning_mode"), "计划模式")
        XCTAssertEqual(L10n.text("ui.target_task"), "目标模式")
        XCTAssertEqual(L10n.text("ui.turn_off_planning_mode"), "关闭计划模式")
        XCTAssertEqual(L10n.text("ui.close_target_task"), "关闭目标模式")
    }

    /// 展开与收起必须是同一种质感：托盘曾按展开状态在 thin / regular 之间切换，
    /// 展开时比旁边的输入卡还浓，一屏出现两种模糊浓度。
    func testGoalTraySurfaceStyleUsesOneMaterialAcrossExpansion() {
        let style = ComposerStatusTraySurfaceStyle.resolve(
            scheme: .dark,
            reduceTransparency: false
        )

        XCTAssertEqual(style.materialStrength, .frosted)
        XCTAssertEqual(style.surfaceTintOpacity, 0.46)
        XCTAssertEqual(style.borderOpacity, 0.58)
    }

    func testGoalTrayLightSurfaceUsesOpaqueSharedComposerColor() {
        let style = ComposerStatusTraySurfaceStyle.resolve(
            scheme: .light,
            reduceTransparency: false
        )

        XCTAssertEqual(style.materialStrength, .opaque)
        XCTAssertEqual(style.surfaceTintOpacity, 1)
        XCTAssertEqual(style.borderOpacity, 0.05)
    }

    func testGoalTraySurfaceStyleBecomesOpaqueWhenReduceTransparencyIsEnabled() {
        let style = ComposerStatusTraySurfaceStyle.resolve(
            scheme: .dark,
            reduceTransparency: true
        )

        XCTAssertEqual(style.materialStrength, .opaque)
        XCTAssertEqual(style.surfaceTintOpacity, 1)
        XCTAssertEqual(style.borderOpacity, 0.58)
    }

    private func makeTray(
        sessionControlNotice: String? = nil,
        quotaNotice: CodexQuotaNotice? = nil,
        usage: CodexUsageDisplaySummary? = nil,
        goal: ThreadGoal? = nil,
        allowsTakeOver: Bool = false
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
            allowsTakeOver: allowsTakeOver,
            onTakeOver: {},
            onRefreshUsage: {},
            onEditGoal: {},
            onTogglePauseGoal: {},
            onCompleteGoal: {},
            onClearGoal: {},
            onToggleGoalExpanded: {}
        )
    }
}

extension ConversationDataFlowTests {
    /// MIM-247：Claude 的 item/tool/requestUserInput 从投影到提交必须走通同一套 key。
    /// 卡片能出现却提交报「请求已失效」，说明注册与查找在某一层错位。
    func testClaudeToolRequestUserInputRegistersLookupKeysForSubmit() async throws {
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "test",
            runtimeProvider: "claude"
        )
        let request = CodexAppServerServerRequest(
            id: .string("claude-req-1"),
            method: "item/tool/requestUserInput",
            params: .object([
                "threadId": .string("thr_claude_input"),
                "turnId": .string("turn_claude_input"),
                "itemId": .string("toolu_014MPNAn1XapgUZpDWR5odD6"),
                "questions": .array([
                    .object([
                        "id": .string("question-0"),
                        "header": .string("目标平台"),
                        "question": .string("先做哪个平台？"),
                        "options": .array([
                            .object(["label": .string("iOS")]),
                            .object(["label": .string("Server")])
                        ])
                    ])
                ])
            ])
        )

        await runtime.handle(request)

        // 1) 卡片确实产出，且 UI 侧 id 用的是 itemId（截图里的报错就是这个 id）
        let pending = await runtime.pendingInteractionEvents(sessionID: "thr_claude_input")
        let card = pending.compactMap { event -> AgentUserInputRequest? in
            if case .userInputRequest(let input, _) = event { return input }
            return nil
        }.first
        let unwrapped = try XCTUnwrap(card, "补充信息卡片必须产出")
        XCTAssertEqual(unwrapped.id, "toolu_014MPNAn1XapgUZpDWR5odD6")

        // 2) 用卡片上的 id 提交，必须能查到请求，不能抛 userInputRequestNotFound
        do {
            try await runtime.respondToUserInput(
                sessionID: "thr_claude_input",
                requestID: unwrapped.id,
                answers: ["question-0": ["iOS"]]
            )
            XCTFail("未连接时应该因连接不可用失败，而不是静默成功")
        } catch let error as CodexAppServerSessionRuntimeError {
            if case .userInputRequestNotFound(let id) = error {
                XCTFail("请求应已注册，却报已失效：\(id)")
            }
            // 其它错误（如连接不可用）是预期的：本用例只验证查找不失败。
        } catch {
            // 同上：非 runtime 错误说明已经越过查找这一步。
        }
    }
}
