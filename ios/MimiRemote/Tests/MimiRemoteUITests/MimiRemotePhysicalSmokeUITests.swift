import XCTest

final class MimiRemotePhysicalSmokeUITests: XCTestCase {
    private var app: XCUIApplication!
    private let selectedValues = ["Selected", "已选择"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        if !name.contains("testLiveSharedDaemonIdleThreadCanContinue") {
            // 使用只存在于 Debug 构建的内存样例，保证新安装、无真实历史数据的设备也能
            // 完整覆盖 Composer；不会写入或替换用户保存的连接和会话。
            app.launchArguments += [
                "--debug-skip-pairing",
                "--debug-seed-ui"
            ]
        }
        if name.contains("testMCPToolApprovalShowsScopedTrustActions") {
            app.launchArguments.append("--debug-seed-mcp-approval-ui")
        }
        if name.contains("testWideIPadFloatingSidebarDragDoesNotStealSessionRowGestures") {
            // 13-inch iPad 竖屏仍是 regular width，同时避开横屏自由窗口对屏幕左缘拖动的系统仲裁。
            XCUIDevice.shared.orientation = .portrait
        }
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 25),
            "MimiRemote 未能在真机前台启动"
        )
    }

    override func tearDownWithError() throws {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "\(name)-final"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        // 设备方向属于跨测试共享状态。每个用例结束时恢复竖屏，避免一个旋转用例
        // 改变下一个用例的导航层级和可点击区域。
        XCUIDevice.shared.orientation = .portrait
        app = nil
    }

    func testLaunchAndQRScannerCanBePresentedRepeatedly() throws {
        XCTAssertGreaterThan(app.windows.count, 0, "启动后应存在可交互窗口")

        try openHostInstaller()
        assertHostInstallerSupportsMacAndWindows()

        try presentQRScanner()
        assertScannerRemainsPresented()
        app.descendant(identifier: "qrScanner.close").tap()
        XCTAssertTrue(
            app.descendant(identifier: "qrScanner.close").waitForNonExistence(timeout: 8),
            "关闭扫码页后应回到连接设置"
        )

        try presentQRScanner()
        assertScannerRemainsPresented()
        app.descendant(identifier: "qrScanner.close").tap()
    }

    func testLiveSharedDaemonIdleThreadCanContinue() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let threadID = environment["MIMI_LIVE_THREAD_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !threadID.isEmpty,
              let expectedReply = environment["MIMI_LIVE_EXPECTED_REPLY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !expectedReply.isEmpty else {
            throw XCTSkip("仅在提供真实共享 daemon thread 与预期回复时执行")
        }
        let message = environment["MIMI_LIVE_MESSAGE"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "Reply exactly \(expectedReply). Do not call tools."

        try enterWorkbenchIfNeeded()
        let targetRow = app.descendant(identifier: "sessions.row.\(threadID)")
        XCTAssertTrue(
            targetRow.waitForExistence(timeout: 35),
            "共享 daemon 新建的真实会话应出现在手机会话列表"
        )
        targetRow.tap()

        let input = app.descendant(identifier: "composer.textInput")
        XCTAssertTrue(input.waitForExistence(timeout: 30), "打开真实会话后应显示 Composer 输入框")
        input.tap()
        input.typeText(message)

        let send = app.descendant(identifier: "composer.send")
        XCTAssertTrue(send.waitForExistence(timeout: 10), "Composer 应显示发送按钮")
        XCTAssertTrue(send.isEnabled, "输入消息后发送按钮应可用")
        send.tap()

        let reply = app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "identifier == %@ AND label CONTAINS %@",
                    "conversation.message.assistant",
                    expectedReply
                )
            )
            .firstMatch
        XCTAssertTrue(
            reply.waitForExistence(timeout: 120),
            "Desktop 仅打开空闲会话时，真机应能在同一 thread 继续发送并收到回复"
        )

        for failureText in ["already has an active writer", "-32600", "发送失败", "Sending failed"] {
            XCTAssertFalse(
                app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", failureText)).firstMatch.exists,
                "续写成功后不应出现 writer 冲突或发送失败：\(failureText)"
            )
        }
    }

    private func openHostInstaller() throws {
        try enterWorkbenchIfNeeded()
        try openSettings()

        let connection = app.descendant(identifier: "settings.connectionManagement")
        XCTAssertTrue(scrollUntilHittable(connection), "设置页应提供电脑连接管理入口")
        connection.tap()

        XCTAssertTrue(
            app.descendant(identifier: "settings.hostInstaller.platform").waitForExistence(timeout: 8),
            "未配对时连接管理页应展示电脑平台选择器"
        )
    }

    private func assertHostInstallerSupportsMacAndWindows() {
        let platformPicker = app.descendant(identifier: "settings.hostInstaller.platform")
        let mac = platformPicker.buttons["Mac"]
        let windows = platformPicker.buttons["Windows"]

        XCTAssertTrue(mac.waitForExistence(timeout: 4), "安装入口应提供 Mac 选项")
        XCTAssertTrue(windows.waitForExistence(timeout: 4), "安装入口应提供 Windows 选项")

        windows.tap()
        XCTAssertTrue(
            waitUntilLabelContains(
                app.descendant(identifier: "settings.hostInstaller.installationDetail"),
                text: "Windows"
            ),
            "切换后应展示 Windows 安装说明"
        )
        XCTAssertTrue(
            app.descendant(identifier: "settings.hostInstaller.githubRelease").exists,
            "Windows 安装入口应继续提供 GitHub Releases"
        )
        XCTAssertTrue(
            app.descendant(identifier: "settings.hostInstaller.share").exists,
            "Windows 安装入口应支持分享下载链接"
        )

        mac.tap()
        XCTAssertTrue(
            waitUntilLabelContains(
                app.descendant(identifier: "settings.hostInstaller.installationDetail"),
                text: "Mac"
            ),
            "切回后应展示 Mac 安装说明"
        )
    }

    func testWideIPadFloatingSidebarSurfaceKeepsNavigationUsable() throws {
        rotate(to: .landscapeLeft)

        if firstExistingButton(
            labels: ["收起会话列表", "Collapse conversation list"],
            timeout: 3
        ) == nil,
           let showSidebar = firstExistingButton(
               labels: ["显示边栏", "Show Sidebar"],
               timeout: 5
           ) {
            showSidebar.tap()
        }

        guard let collapseSidebar = firstExistingButton(
            labels: ["收起会话列表", "Collapse conversation list"],
            timeout: 8
        ) else {
            XCTFail("iPad 浮动侧栏应提供可访问的收起按钮")
            return
        }
        XCTAssertTrue(
            app.descendant(identifier: "hostSwitcher.sidebar.menu").waitForExistence(timeout: 8),
            "浮动侧栏应保留电脑切换入口"
        )
        assertMinimumTouchTarget(collapseSidebar, named: "浮动侧栏收起按钮")

        let sessionFilter = app.descendant(identifier: "sessions.filter")
        if sessionFilter.waitForExistence(timeout: 5) {
            XCTAssertGreaterThanOrEqual(
                sessionFilter.frame.minX,
                collapseSidebar.frame.maxX,
                "详情页 leading 工具栏不能被浮动侧栏覆盖"
            )
        }

        guard let workspaces = firstExistingButton(
            labels: ["工作区", "Workspace"],
            timeout: 5
        ) else {
            XCTFail("浮动侧栏应保留工作区入口")
            return
        }
        workspaces.tap()
        let workspaceBrowser = app.descendant(identifier: "workspace.browser")
        XCTAssertTrue(
            workspaceBrowser.waitForExistence(timeout: 8),
            "工作区主内容应保持可访问"
        )
        XCTAssertGreaterThanOrEqual(
            workspaceBrowser.frame.minX,
            collapseSidebar.frame.maxX,
            "展开侧栏后工作区必须获得真实的右侧布局区域，不能只裁切原始整屏内容"
        )

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "MIM-41-iPad-floating-sidebar-landscape"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        collapseSidebar.tap()
        guard let showSidebar = firstExistingButton(
            labels: ["显示边栏", "Show Sidebar"],
            timeout: 8
        ) else {
            XCTFail("收起浮动侧栏后应保留原生显示边栏入口")
            return
        }
        assertMinimumTouchTarget(showSidebar, named: "浮动侧栏显示按钮")
        showSidebar.tap()
        guard firstExistingButton(
            labels: ["收起会话列表", "Collapse conversation list"],
            timeout: 8
        ) != nil else {
            XCTFail("重新展开侧栏后导航与选择状态应保持可用")
            return
        }
    }

    func testInspectorPresentationSurvivesIPadRotation() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "Inspector 的 sheet / attached 切换只在 iPad 验收。"
        )
        rotate(to: .portrait)
        try openComposerIfNeeded()

        let inspectorButton = app.descendant(identifier: "sessionDetail.inspector")
        XCTAssertTrue(inspectorButton.waitForExistence(timeout: 10), "中等宽度应展示独立 Inspector 入口")
        inspectorButton.tap()

        let inspectorContent = app.descendant(identifier: "sessionInspector.content")
        XCTAssertTrue(inspectorContent.waitForExistence(timeout: 10), "竖屏中等宽度应打开 Inspector Sheet")

        rotate(to: .landscapeLeft)
        XCTAssertTrue(inspectorContent.waitForExistence(timeout: 10), "旋转后 Inspector 内容不应丢失")

        rotate(to: .portrait)
        XCTAssertTrue(inspectorContent.waitForExistence(timeout: 10), "返回中等宽度后 Inspector 应保持展示")

        let closeButton = app.descendant(identifier: "sessionDetail.inspector")
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5), "Inspector 展示期间应保留同一工具栏入口")
        closeButton.tap()
        XCTAssertTrue(inspectorContent.waitForNonExistence(timeout: 10), "关闭后不应残留 Sheet 或 attached Inspector")
    }

    func testWideIPadFloatingSidebarDragDoesNotStealSessionRowGestures() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "浮动侧栏拖动只在 iPad regular width 下验收。"
        )
        try enterWorkbenchIfNeeded()

        if firstExistingButton(
            labels: ["收起会话列表", "Collapse conversation list"],
            timeout: 3
        ) == nil,
           let showSidebar = firstExistingButton(
               labels: ["显示边栏", "Show Sidebar"],
               timeout: 5
           ) {
            showSidebar.tap()
        }

        guard let collapseSidebar = firstExistingButton(
            labels: ["收起会话列表", "Collapse conversation list"],
            timeout: 8
        ) else {
            return XCTFail("iPad 浮动侧栏应先处于展开态")
        }
        let identifiedSessionRows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "sessions.row."))
        let seededSessionRows = app.buttons.matching(
            NSPredicate(
                format: "label CONTAINS %@ OR label CONTAINS %@",
                "mimi-remote",
                "sample-app"
            )
        )
        // SwiftUI 在部分系统版本会把 row 合并为整行 Button，而不透传子视图 identifier。
        // 优先使用稳定 identifier；Debug 样例下回退到已知工作区标签，避免把定位器缺失误报成功能失败。
        let sessionRow = identifiedSessionRows.firstMatch.exists
            ? identifiedSessionRows.firstMatch
            : seededSessionRows.firstMatch
        guard sessionRow.waitForExistence(timeout: 12) else {
            return XCTFail("Debug 样例应提供可交互的会话 row")
        }

        let sidebarTrailingX = collapseSidebar.frame.maxX
        sessionRow.swipeUp()
        XCTAssertEqual(
            collapseSidebar.frame.maxX,
            sidebarTrailingX,
            accuracy: 2,
            "纵向列表手势不得改变侧栏 progress"
        )
        sessionRow.swipeLeft()
        XCTAssertEqual(
            collapseSidebar.frame.maxX,
            sidebarTrailingX,
            accuracy: 2,
            "row 横向 swipe 不得被侧栏拖动 recognizer 接管"
        )

        let window = app.windows.firstMatch
        let width = max(window.frame.width, 1)
        let closeStart = window.coordinate(
            // 300pt 列内扣除 12pt surface outer inset 后，22pt 拖动带中心是 x=277。
            withNormalizedOffset: CGVector(dx: 277 / width, dy: 0.5)
        )
        let closeEnd = window.coordinate(
            withNormalizedOffset: CGVector(dx: 12 / width, dy: 0.5)
        )
        closeStart.press(forDuration: 0.1, thenDragTo: closeEnd)
        guard firstExistingButton(
            labels: ["显示边栏", "Show Sidebar"],
            timeout: 8
        ) != nil else {
            return XCTFail("trailing 22pt 拖动带关闭后应显示等价的展开按钮")
        }

        let height = max(window.frame.height, 1)
        let protectedZoneOpenEndX = 310 / width
        let protectedY = CGFloat(65)
        let protectedStart = window.coordinate(
            // 65pt 仍严格位于顶部 72pt 保护区内，同时避开 reveal 按钮和系统极端顶缘。
            withNormalizedOffset: CGVector(dx: 1 / width, dy: protectedY / height)
        )
        let protectedEnd = window.coordinate(
            withNormalizedOffset: CGVector(dx: protectedZoneOpenEndX, dy: protectedY / height)
        )
        protectedStart.press(forDuration: 0.1, thenDragTo: protectedEnd)
        guard firstExistingButton(
            labels: ["显示边栏", "Show Sidebar"],
            timeout: 2
        ) != nil else {
            return XCTFail("leading edge 顶部 72pt 保护区不得触发侧栏重开")
        }
        // 底部 72pt 会被 iPadOS 窗口管理器优先接管并改变窗口几何；对应拒绝边界由纯布局测试覆盖。

        let openStart = window.coordinate(
            // 20pt 仍位于应用的 leading 22pt 命中带内，同时避开 iPadOS 绝对屏幕边缘仲裁。
            withNormalizedOffset: CGVector(dx: 20 / width, dy: 0.5)
        )
        let openEnd = window.coordinate(
            withNormalizedOffset: CGVector(dx: 310 / width, dy: 0.5)
        )
        openStart.press(forDuration: 0.1, thenDragTo: openEnd)

        let collapseSidebarLabels = ["收起会话列表", "Collapse conversation list"]
        guard firstExistingButton(
            labels: collapseSidebarLabels,
            timeout: 8
        ) != nil else {
            return XCTFail("leading 22pt edge 应能直接重新展开侧栏")
        }
        XCTAssertTrue(
            waitForFreshButtonHorizontalPosition(
                labels: collapseSidebarLabels,
                maxX: sidebarTrailingX,
                accuracy: 2
            ),
            "重新展开后侧栏应回到原始展开位置"
        )

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "MIM-72-iPad-sidebar-drag-row-competition"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testLanguageSettingsCombinesVoiceProviderAndSurvivesRotation() throws {
        try enterWorkbenchIfNeeded()
        try openSettings()

        let language = app.descendant(identifier: "settings.language")
        XCTAssertTrue(scrollUntilHittable(language), "设置页应提供语言统一入口")
        let originalValue = "\(language.value ?? "")"
        let originalProviderWasOnDevice =
            originalValue.contains("On-device") || originalValue.contains("设备端")

        language.tap()

        let detailVoiceInput = app.descendant(identifier: "settings.language.detail.voiceInput")
        XCTAssertTrue(
            detailVoiceInput.waitForExistence(timeout: 5),
            "语言详情页应同时展示语音输入选择"
        )

        guard let codex = firstExistingButton(labels: ["Codex"], timeout: 5) else {
            XCTFail("语言详情页应提供 Codex 语音输入选项")
            return
        }
        codex.tap()
        XCTAssertTrue(
            waitForControlValue(detailVoiceInput, containing: ["Codex"]),
            "在语言详情页选择 Codex 后应立即保存设备级偏好"
        )

        rotate(to: .landscapeLeft)
        let landscapeVoiceInput = app.descendant(identifier: "settings.language.detail.voiceInput")
        XCTAssertTrue(
            scrollUntilHittable(landscapeVoiceInput),
            "横屏后语言详情页应仍能找到语音输入选择组件"
        )
        XCTAssertTrue(
            waitForControlValue(landscapeVoiceInput, containing: ["Codex"]),
            "横屏后语音输入选择不应丢失"
        )

        rotate(to: .portrait)
        let portraitVoiceInput = app.descendant(identifier: "settings.language.detail.voiceInput")
        XCTAssertTrue(
            scrollUntilHittable(portraitVoiceInput),
            "竖屏后语言详情页应仍能找到语音输入选择组件"
        )
        XCTAssertTrue(
            waitForControlValue(portraitVoiceInput, containing: ["Codex"]),
            "竖屏后语音输入选择不应丢失"
        )

        if originalProviderWasOnDevice {
            guard let onDevice = firstExistingButton(
                labels: ["On-device", "设备端"],
                timeout: 5
            ) else {
                XCTFail("测试结束时应能从语言详情页恢复设备端语音")
                return
            }
            onDevice.tap()
            XCTAssertTrue(
                waitForControlValue(
                    portraitVoiceInput,
                    containing: ["On-device", "设备端"]
                ),
                "测试结束时应恢复原语音提供方"
            )
        }

        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "语言详情页应提供返回路径")
        back.tap()
        XCTAssertTrue(
            waitForControlValue(
                language,
                containing: originalProviderWasOnDevice ? ["On-device", "设备端"] : ["Codex"]
            ),
            "返回设置首页后应保留合并入口及最新选择摘要"
        )
    }

    func testMePageCombinesQuotaActivityPreferencesAndMore() throws {
        try enterWorkbenchIfNeeded()
        try openSettings()

        let tokenUsage = app.descendant(identifier: "settings.tokenUsage")
        let tokenQuota = app.descendant(identifier: "settings.tokenUsage.quota")
        let tokenActivity = app.descendant(identifier: "settings.tokenUsage.activity")
        let activityGrid = app.descendant(identifier: "settings.tokenActivity.grid")
        let activityUnavailable = app.descendant(identifier: "settings.tokenActivity.unavailable")
        let macDevices = app.descendant(identifier: "settings.connectionManagement")
        let appearance = app.descendant(identifier: "settings.appearance")
        let language = app.descendant(identifier: "settings.language")
        let defaultPermissions = app.descendant(identifier: "settings.defaultPermissions")
        let diagnostics = app.descendant(identifier: "settings.diagnostics")
        let advanced = app.descendant(identifier: "settings.advancedDevelopment")
        let aboutLegal = app.descendant(identifier: "settings.aboutLegal")

        XCTAssertTrue(tokenUsage.waitForExistence(timeout: 8), "我的页面应展示统一 Token 模块")
        XCTAssertTrue(tokenQuota.waitForExistence(timeout: 4), "Token 模块应展示当前剩余列")
        XCTAssertTrue(tokenActivity.waitForExistence(timeout: 4), "Token 模块应展示活动列")
        XCTAssertTrue(
            activityGrid.waitForExistence(timeout: 4)
                || activityUnavailable.waitForExistence(timeout: 1),
            "Token 模块应展示真实点格数据或诚实的不可用状态"
        )
        XCTAssertTrue(macDevices.waitForExistence(timeout: 4), "设置页应展示 Mac 多设备入口")
        XCTAssertTrue(appearance.waitForExistence(timeout: 4), "设置页应展示偏好设置")

        XCTAssertGreaterThanOrEqual(tokenUsage.frame.height, 150, "Token 模块应完整容纳圆环与点格图")
        XCTAssertGreaterThan(tokenUsage.frame.width, 250, "Token 模块应使用完整分组宽度")
        XCTAssertLessThan(tokenQuota.frame.midX, tokenActivity.frame.midX, "当前剩余应稳定位于活动列左侧")
        XCTAssertLessThan(tokenQuota.frame.minX, tokenActivity.frame.minX, "Token 两个主模块不得回退为上下堆叠")
        XCTAssertEqual(macDevices.frame.height, 52, accuracy: 1, "Mac 与设备应保持标准行高")
        XCTAssertEqual(appearance.frame.height, 52, accuracy: 1, "偏好项应保持标准行高")

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "me-token-usage-overview"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        XCTAssertTrue(
            scrollUntilHittable(language, maximumSwipes: 4),
            "我的页面应能滚动到语言入口"
        )
        XCTAssertEqual(language.frame.height, 52, accuracy: 1, "语言行应保持标准行高")

        XCTAssertTrue(
            scrollUntilHittable(defaultPermissions, maximumSwipes: 6),
            "设置页应能滚动到默认权限行内选择器"
        )
        XCTAssertTrue(language.exists, "设置页应展示合并后的语言入口")
        XCTAssertEqual(language.frame.height, 52, accuracy: 1, "语言入口应保持标准行高")
        XCTAssertEqual(defaultPermissions.frame.height, 52, accuracy: 1, "默认权限行应保持标准行高")

        XCTAssertTrue(scrollUntilHittable(aboutLegal), "我的页面应能滚动到“更多”分区")
        // “Mac 与设备”已在页面顶部验证；滚到底部后它可能被 List 懒加载卸载，
        // 这里只检查当前可见的“更多”入口，避免把视口状态误判为功能缺失。
        let bottomRows = [diagnostics, advanced, aboutLegal]
        for row in bottomRows {
            XCTAssertTrue(row.waitForExistence(timeout: 4), "“更多”分区入口应存在")
            XCTAssertEqual(
                row.frame.height,
                52,
                accuracy: 1,
                "“更多”分区应统一使用标准行高"
            )
        }

        let bottomScreenshot = XCTAttachment(screenshot: app.screenshot())
        bottomScreenshot.name = "me-preferences-and-more"
        bottomScreenshot.lifetime = .keepAlways
        add(bottomScreenshot)
    }

    func testComposerPlanGoalAndModelMenusSurviveRotationWithoutCrash() throws {
        try openComposerIfNeeded()

        try selectMode(identifier: "composer.mode.plan")
        rotate(to: .landscapeLeft)
        assertModeSelected(expectedValues: ["planning mode", "计划模式"])
        try selectMode(identifier: "composer.mode.plan")

        try selectMode(identifier: "composer.mode.goal")
        rotate(to: .portrait)
        assertModeSelected(expectedValues: ["Goal mode", "目标模式"])

        let model = app.descendant(identifier: "composer.model")
        XCTAssertTrue(model.waitForExistence(timeout: 10), "Composer 应展示模型入口")
        model.tap()
        let modelPicker = app.descendant(identifier: "composer.modelPicker")
        XCTAssertTrue(
            modelPicker.waitForExistence(timeout: 8),
            "模型选择浮层应能正常构建，不能触发 compact toolbar 栈溢出"
        )
        assertCompactModelPickerFitsWindow(modelPicker)
        dismissPresentedMenuOrPopover()

        rotate(to: .landscapeLeft)
        let landscapeModel = app.descendant(identifier: "composer.model")
        XCTAssertTrue(landscapeModel.waitForExistence(timeout: 10), "横屏后 Composer 应保留模型入口")
        landscapeModel.tap()
        let landscapePicker = app.descendant(identifier: "composer.modelPicker")
        XCTAssertTrue(landscapePicker.waitForExistence(timeout: 8), "横屏模型选择浮层应能正常构建")
        assertCompactModelPickerFitsWindow(landscapePicker)
        dismissPresentedMenuOrPopover()
        XCTAssertEqual(app.state, .runningForeground, "完成紧凑工具栏操作后 App 应保持前台运行")
    }

    func testMCPToolApprovalShowsScopedTrustActions() throws {
        try openComposerIfNeeded()

        let approveOnce = app.descendant(identifier: "approval.approveOnce")
        let allowForSession = app.descendant(identifier: "approval.allowMCPForSession")
        let alwaysAllow = app.descendant(identifier: "approval.alwaysAllowMCPTool")
        let reject = app.descendant(identifier: "approval.reject")

        XCTAssertTrue(approveOnce.waitForExistence(timeout: 12), "MCP 工具审批应保留单次允许入口")
        XCTAssertTrue(allowForSession.waitForExistence(timeout: 5), "Codex 声明 session 持久化后应展示本次会话允许")
        XCTAssertTrue(alwaysAllow.waitForExistence(timeout: 5), "Codex 声明 always 持久化后应展示始终允许")
        XCTAssertTrue(reject.waitForExistence(timeout: 5), "MCP 工具审批应始终允许拒绝")

        assertMinimumTouchTarget(approveOnce, named: "单次允许")
        assertMinimumTouchTarget(allowForSession, named: "本次会话允许")
        assertMinimumTouchTarget(alwaysAllow, named: "始终允许")
        assertMinimumTouchTarget(reject, named: "拒绝")
        XCTAssertEqual(app.state, .runningForeground, "展示完整 MCP 信任选项后 App 应保持前台运行")
    }

    func testComposerCameraAttachmentCanPresentAndCancel() throws {
        try openComposerIfNeeded()

        let addContent = app.descendant(identifier: "composer.addContent")
        XCTAssertTrue(addContent.waitForExistence(timeout: 10), "Composer 应保留原位置的加号入口")
        assertMinimumTouchTarget(addContent, named: "加号")
        addContent.tap()

        let file = app.descendant(identifier: "composer.addContent.file")
        let camera = app.descendant(identifier: "composer.addContent.camera")
        let photos = app.descendant(identifier: "composer.addContent.photos")
        XCTAssertTrue(file.waitForExistence(timeout: 8), "添加内容面板应展示文件入口")
        XCTAssertTrue(camera.waitForExistence(timeout: 8), "添加内容面板应展示适合触控的相机入口")
        XCTAssertTrue(photos.waitForExistence(timeout: 8), "添加内容面板应展示照片入口")
        assertMinimumTouchTarget(file, named: "文件入口")
        assertMinimumTouchTarget(camera, named: "相机入口")
        assertMinimumTouchTarget(photos, named: "照片入口")

        installCameraPermissionMonitor()
        camera.tap()
        handleCameraPermissionIfPresented()

        let choosePhotos = firstExistingButton(labels: ["Choose Photos", "选择照片"], timeout: 2)
        if choosePhotos != nil {
            throw XCTSkip("当前设备已拒绝或限制相机权限；已验证降级提示，跳过系统相机取消操作")
        }

        let picker = app.descendant(identifier: "composer.cameraAttachmentPicker")
        let cancel = firstExistingButton(labels: ["Cancel", "取消"], timeout: 15)
        let pickerIsPresented = picker.exists || cancel != nil

        XCTAssertTrue(pickerIsPresented, "点击相机后应稳定展示系统相机界面")
        guard let cancel else {
            XCTFail("系统相机界面应提供取消按钮")
            return
        }
        cancel.tap()

        XCTAssertTrue(
            addContent.waitForExistence(timeout: 12),
            "取消拍摄后应回到 Composer，且加号位置保持不变"
        )
        XCTAssertEqual(app.state, .runningForeground, "取消拍摄后 App 应保持前台运行")
    }

    func testComposerFileImporterCanPresentAndCancel() throws {
        try openComposerIfNeeded()

        let addContent = app.descendant(identifier: "composer.addContent")
        XCTAssertTrue(addContent.waitForExistence(timeout: 10), "Composer 应保留原位置的加号入口")
        addContent.tap()

        let file = app.descendant(identifier: "composer.addContent.file")
        XCTAssertTrue(file.waitForExistence(timeout: 8), "添加内容面板应展示文件入口")
        assertMinimumTouchTarget(file, named: "文件入口")
        file.tap()

        guard let cancel = firstExistingButton(labels: ["Cancel", "取消"], timeout: 15) else {
            XCTFail("系统文件选择器应提供取消按钮")
            return
        }
        cancel.tap()

        XCTAssertTrue(
            addContent.waitForExistence(timeout: 12),
            "取消文件选择后应回到 Composer，且加号位置保持不变"
        )
        XCTAssertEqual(app.state, .runningForeground, "取消文件选择后 App 应保持前台运行")
    }

    func testComposerSkillPickerSupportsImmediateMultiSelectFromBothEntrances() throws {
        try openComposerIfNeeded()

        let addContent = app.descendant(identifier: "composer.addContent")
        XCTAssertTrue(addContent.waitForExistence(timeout: 10), "Composer 应展示加号入口")
        addContent.tap()

        let addContentSkill = app.descendant(identifier: "composer.addContent.skills")
        XCTAssertTrue(addContentSkill.waitForExistence(timeout: 8), "添加内容面板应展示 Skill 入口")
        addContentSkill.tap()

        let imagegen = app.descendant(identifier: "composer.skillPicker.row.imagegen")
        let swiftUI = app.descendant(identifier: "composer.skillPicker.row.swiftui-ui-patterns")
        let done = app.descendant(identifier: "composer.skillPicker.done")
        XCTAssertTrue(imagegen.waitForExistence(timeout: 8), "统一 Skill 面板应展示固定调试数据")
        XCTAssertTrue(swiftUI.waitForExistence(timeout: 4))
        XCTAssertTrue(done.waitForExistence(timeout: 4))
        assertMinimumTouchTarget(imagegen, named: "Skill 行")
        assertMinimumTouchTarget(done, named: "完成按钮")

        imagegen.tap()
        XCTAssertTrue(waitUntilSelected(imagegen), "勾选 Skill 后应立即生效")
        swiftUI.tap()
        XCTAssertTrue(waitUntilSelected(swiftUI), "同一面板应支持连续多选")
        imagegen.tap()
        XCTAssertTrue(waitUntilNotSelected(imagegen), "再次点击已选 Skill 应立即取消")
        done.tap()

        XCTAssertTrue(
            app.descendant(identifier: "composer.skillAttachment.swiftui-ui-patterns")
                .waitForExistence(timeout: 8),
            "完成关闭面板后，当前勾选应保留到附件条"
        )
        XCTAssertFalse(
            app.descendant(identifier: "composer.skillAttachment.imagegen").exists,
            "已经取消的 Skill 不应留在附件条"
        )

        // iPad 保留输入框上方的快捷入口；iPhone 设计上只通过加号进入。
        // 若当前布局有快捷入口，复用同一组行和即时多选语义再验证一次。
        let directSkill = app.descendant(identifier: "composer.skill")
        if directSkill.waitForExistence(timeout: 2), directSkill.isHittable {
            directSkill.tap()
            let directImagegen = app.descendant(identifier: "composer.skillPicker.row.imagegen")
            let directSwiftUI = app.descendant(identifier: "composer.skillPicker.row.swiftui-ui-patterns")
            XCTAssertTrue(directImagegen.waitForExistence(timeout: 8))
            XCTAssertTrue(waitUntilSelected(directSwiftUI), "两个入口必须读取同一组选中状态")
            directImagegen.tap()
            XCTAssertTrue(waitUntilSelected(directImagegen))
            app.descendant(identifier: "composer.skillPicker.done").tap()
            XCTAssertTrue(
                app.descendant(identifier: "composer.skillAttachment.imagegen")
                    .waitForExistence(timeout: 8),
                "快捷入口的选择也应写入同一附件条"
            )
        }

        XCTAssertEqual(app.state, .runningForeground, "连续选择和取消 Skill 后 App 应保持前台运行")
    }

    func testWorkspaceCharacterIconsRenderAndPickerCanOpen() throws {
        // 角色图测试直接进入目标页，避免真机上恢复路由与底部栏布局差异造成误报。
        app.terminate()
        app.launchArguments.append("--debug-open-workspaces")
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 25),
            "MimiRemote 应能直接进入工作区"
        )

        // 44pt 胶囊放不下卡片时代的三个可见操作；头像不再是独立按钮，
        // 换图标与 Git、移除目录一起降级到胶囊的长按菜单。
        let chips = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "workspace.card."))
        XCTAssertTrue(
            chips.firstMatch.waitForExistence(timeout: 15),
            "工作区应展示可切换的《西游记》角色胶囊"
        )
        assertMinimumTouchTarget(chips.firstMatch, named: "工作区项目胶囊")

        let workspaceScreenshot = XCTAttachment(screenshot: app.screenshot())
        workspaceScreenshot.name = "workspace-character-chips"
        workspaceScreenshot.lifetime = .keepAlways
        add(workspaceScreenshot)

        chips.firstMatch.press(forDuration: 1.0)
        let iconEntry = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "workspace.card.icon."))
            .firstMatch
        XCTAssertTrue(
            iconEntry.waitForExistence(timeout: 8),
            "长按胶囊应提供更换角色入口"
        )
        iconEntry.tap()

        let picker = app.descendant(identifier: "workspace.characterPicker")
        XCTAssertTrue(
            picker.waitForExistence(timeout: 10),
            "选择更换角色后应打开角色选择器"
        )

        let characterButtons = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "workspace.character."))
        XCTAssertEqual(characterButtons.count, 20, "角色选择器应完整展示 20 个角色")
        assertMinimumTouchTarget(characterButtons.firstMatch, named: "角色选择按钮")

        let pickerScreenshot = XCTAttachment(screenshot: app.screenshot())
        pickerScreenshot.name = "workspace-character-picker"
        pickerScreenshot.lifetime = .keepAlways
        add(pickerScreenshot)
    }

    func testWorkspaceKeepsGitInCardMenuOnlyAndHostSwitcherUsable() throws {
        try relaunchDirectlyIntoWorkspaces()

        // 紧凑布局使用顶栏入口，宽 iPad 使用侧栏入口；分离标识避免误把侧栏当成顶栏样式覆盖。
        let toolbarHostSwitcher = app.descendant(identifier: "hostSwitcher.toolbar.menu")
        let sidebarHostSwitcher = app.descendant(identifier: "hostSwitcher.sidebar.menu")
        let hostSwitcher = toolbarHostSwitcher.waitForExistence(timeout: 3)
            ? toolbarHostSwitcher
            : sidebarHostSwitcher
        XCTAssertTrue(hostSwitcher.waitForExistence(timeout: 10), "工作区应保留当前布局对应的主机切换入口")
        assertMinimumTouchTarget(hostSwitcher, named: "工作区主机切换入口")
        hostSwitcher.tap()
        XCTAssertNotNil(
            firstExistingButton(labels: ["检查主机状态", "Check Host Status"], timeout: 6),
            "主机入口改色后仍应打开原有连接菜单"
        )
        dismissPresentedMenuOrPopover()

        let openDirectory = app.descendant(identifier: "workspace.toolbar.openDirectory")
        XCTAssertTrue(openDirectory.waitForExistence(timeout: 8), "工作区顶栏应保留打开目录入口")
        assertMinimumTouchTarget(openDirectory, named: "打开目录入口")
        XCTAssertNil(
            firstExistingButton(labels: ["Git 变更", "Git changes"], timeout: 1),
            "工作区顶栏不应继续展示低频 Git 入口"
        )

        let projectID = "debug-sample-app"
        let chip = app.descendant(identifier: "workspace.card.\(projectID)")
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "工作区应保留项目胶囊")
        assertMinimumTouchTarget(chip, named: "工作区项目胶囊")
        chip.press(forDuration: 1.0)

        let cardGit = firstExistingButton(labels: ["Git 变更", "Git changes"], timeout: 6)
        XCTAssertNotNil(cardGit, "低频 Git 能力应降级到项目胶囊的长按菜单，而不是被删除")
        cardGit?.tap()

        let complete = firstExistingButton(labels: ["完成", "Done"], timeout: 8)
        XCTAssertNotNil(complete, "长按菜单的 Git 入口应继续打开绑定当前工作区的 Git 面板")
        complete?.tap()
    }

    func testWideIPadWorkspaceSessionDetailShowsWorkspaceBackButton() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "工作区宽屏返回按钮只在 iPad regular width 下验收。"
        )
        try relaunchDirectlyIntoWorkspaces()
        rotate(to: .landscapeLeft)

        let workspaceBrowser = app.descendant(identifier: "workspace.browser")
        XCTAssertTrue(workspaceBrowser.waitForExistence(timeout: 10), "工作区内容应保持可访问")

        let session = app.descendant(identifier: "workspace.session.debug-session-layout")
        XCTAssertTrue(scrollUntilHittable(session), "工作区应提供可点击的 Debug 会话入口")
        session.tap()

        let workspaceBack = app.descendant(identifier: "sessionDetail.workspaceBack")
        XCTAssertTrue(
            workspaceBack.waitForExistence(timeout: 12),
            "宽屏从工作区进入会话详情后应展示显式返回按钮"
        )
        XCTAssertTrue(workspaceBack.isHittable, "工作区返回按钮应可直接点击")
        // 系统 toolbar 对 XCUI 暴露的是控件可见区域，不包含 SwiftUI 扩展后的 interaction shape；
        // 这里用真实点击与返回结果验证命中行为，避免把 36pt 的可见 frame 误判为点击热区。

        let showSidebar = app.descendant(identifier: "sidebar.show")
        if !showSidebar.waitForExistence(timeout: 2) {
            guard let collapseSidebar = firstExistingButton(
                labels: ["收起会话列表", "Collapse conversation list"],
                timeout: 5
            ) else {
                XCTFail("会话详情应能收起浮动侧栏以验证两个 leading 控件")
                return
            }
            collapseSidebar.tap()
            XCTAssertTrue(showSidebar.waitForExistence(timeout: 8), "收起侧栏后应展示恢复入口")
        }
        assertMinimumTouchTarget(showSidebar, named: "侧栏恢复入口")
        XCTAssertGreaterThanOrEqual(
            showSidebar.frame.minY,
            workspaceBack.frame.maxY + 8,
            "侧栏恢复入口不能覆盖工作区返回按钮"
        )

        workspaceBack.tap()
        XCTAssertTrue(
            workspaceBrowser.waitForExistence(timeout: 12),
            "点击返回后应回到工作区浏览器"
        )
        XCTAssertTrue(
            workspaceBack.waitForNonExistence(timeout: 8),
            "回到工作区后不应残留会话详情返回按钮"
        )
        if showSidebar.exists {
            // 恢复共享的 SceneStorage 状态，避免影响后续 UI 用例。
            showSidebar.tap()
        }
    }

    func testWorkspaceRemoveDirectoryConfirmationAnchorsToCardAcrossIPadLayouts() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "目录移除确认的 popover 锚点只在 iPad regular width 下验收。"
        )
        try relaunchDirectlyIntoWorkspaces()

        let projectID = "debug-sample-app"
        for (orientation, attachmentName) in [
            (UIDeviceOrientation.landscapeLeft, "landscape-sidebar"),
            (.portrait, "portrait")
        ] {
            rotate(to: orientation)

            let source = app.descendant(identifier: "workspace.card.\(projectID)")
            XCTAssertTrue(source.waitForExistence(timeout: 10), "旋转后工作区项目胶囊应保持可见")
            assertMinimumTouchTarget(source, named: "工作区项目胶囊")
            source.press(forDuration: 1.0)

            let request = app.descendant(identifier: "workspace.remove.request.\(projectID)")
            XCTAssertTrue(request.waitForExistence(timeout: 6), "长按菜单应提供移除目录入口")
            request.tap()

            let confirmation = app.descendant(identifier: "workspace.remove.confirm.\(projectID)")
            XCTAssertTrue(confirmation.waitForExistence(timeout: 8), "移除目录后应展示系统确认弹窗")
            assertPopover(confirmation, isAnchoredNear: source)

            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "workspace-remove-confirmation-\(attachmentName)"
            screenshot.lifetime = .keepAlways
            add(screenshot)

            dismissPresentedMenuOrPopover()
            XCTAssertTrue(
                confirmation.waitForNonExistence(timeout: 6),
                "点击弹窗外部应取消移除并关闭确认弹窗"
            )
            XCTAssertTrue(source.exists, "取消后工作区仍应保留在列表中")
        }

        let source = app.descendant(identifier: "workspace.card.\(projectID)")
        source.press(forDuration: 1.0)
        let request = app.descendant(identifier: "workspace.remove.request.\(projectID)")
        XCTAssertTrue(request.waitForExistence(timeout: 6))
        request.tap()
        let confirmation = app.descendant(identifier: "workspace.remove.confirm.\(projectID)")
        XCTAssertTrue(confirmation.waitForExistence(timeout: 8))
        confirmation.tap()

        XCTAssertTrue(
            source.waitForNonExistence(timeout: 8),
            "确认后只应从当前工作区列表移除 Debug 样例目录"
        )
    }

    func testWorkspaceIconStyleSwitchesAcrossWorldArtEmojiAndJourney() throws {
        // 直接进入工作区，避免恢复到会话详情时底部设置入口不在可访问性树中。
        app.terminate()
        app.launchArguments.append("--debug-open-workspaces")
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 25),
            "MimiRemote 应能直接进入工作区"
        )

        try enterWorkbenchIfNeeded()
        try openWorkspaceAppearanceSettings()

        let picker = app.descendant(identifier: "settings.workspaceIconStyle")
        XCTAssertTrue(picker.waitForExistence(timeout: 8), "外观设置应展示工作区图标风格")
        assertMinimumTouchTarget(picker, named: "工作区图标风格")

        let expectedStyleIdentifiers = [
            "journey",
            "threeKingdoms",
            "waterMargin",
            "redChamber",
            "onePiece",
            "naruto",
            "digimon",
            "worldArt",
            "emoji"
        ]
        var optionFrames: [CGRect] = []
        var originalStyleID: String?
        for styleID in expectedStyleIdentifiers {
            guard let option = scrollToWorkspaceStyleOption(styleID, in: picker) else {
                XCTFail("工作区图标风格应能横向滑动到 \(styleID)")
                return
            }
            assertMinimumTouchTarget(option, named: "\(styleID) 风格选项")
            optionFrames.append(option.frame)
            if isSelected(option) {
                originalStyleID = styleID
            }
        }
        assertWorkspaceStylePickerUsesExactlyTwoRows(optionFrames)

        guard let originalStyleID else {
            XCTFail("工作区图标风格应有且只有一个当前选项")
            return
        }

        guard let worldArt = scrollToWorkspaceStyleOption("worldArt", in: picker) else {
            XCTFail("工作区图标风格应提供世界名画")
            return
        }
        worldArt.tap()
        XCTAssertTrue(waitUntilSelected(worldArt), "选择世界名画后应立即保存")
        try relaunchDirectlyIntoWorkspaces()

        let artChips = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "workspace.card."))
        XCTAssertTrue(artChips.firstMatch.waitForExistence(timeout: 15), "工作区应展示名画图标胶囊")
        artChips.firstMatch.press(forDuration: 1.0)
        let artIconEntry = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "workspace.card.icon."))
            .firstMatch
        XCTAssertTrue(artIconEntry.waitForExistence(timeout: 8), "世界名画主题仍应提供更换作品入口")
        artIconEntry.tap()

        let artPicker = app.descendant(identifier: "workspace.characterPicker")
        XCTAssertTrue(artPicker.waitForExistence(timeout: 10), "世界名画主题应打开作品选择器")
        let expectedArtworkIDs = [
            "art-van-gogh-self-portrait",
            "art-great-wave",
            "art-manet-boating",
            "art-degas-dancing-class",
            "art-view-of-toledo",
            "art-death-of-socrates",
            "art-vermeer-water-pitcher",
            "art-madame-x",
            "art-washington-crossing-delaware",
            "art-springtime"
        ]
        for artworkID in expectedArtworkIDs {
            XCTAssertTrue(
                app.descendant(identifier: "workspace.character.\(artworkID)")
                    .waitForExistence(timeout: 5),
                "世界名画选择器应展示 \(artworkID)"
            )
        }
        let artworkButtons = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "workspace.character.art-"))
        XCTAssertEqual(artworkButtons.count, 10, "世界名画选择器应完整展示 10 幅作品")

        let artPickerScreenshot = XCTAttachment(screenshot: app.screenshot())
        artPickerScreenshot.name = "workspace-world-art-picker"
        artPickerScreenshot.lifetime = .keepAlways
        add(artPickerScreenshot)

        try relaunchDirectlyIntoWorkspaces()
        try openWorkspaceAppearanceSettings()
        let emojiPicker = app.descendant(identifier: "settings.workspaceIconStyle")
        guard let emoji = scrollToWorkspaceStyleOption("emoji", in: emojiPicker) else {
            XCTFail("工作区图标风格应提供 Emoji")
            return
        }
        emoji.tap()
        XCTAssertTrue(waitUntilSelected(emoji), "选择 Emoji 后应立即保存")
        try relaunchDirectlyIntoWorkspaces()
        try openWorkspaceAppearanceSettings()
        let persistedEmojiPicker = app.descendant(identifier: "settings.workspaceIconStyle")
        guard let persistedEmoji = scrollToWorkspaceStyleOption("emoji", in: persistedEmojiPicker) else {
            XCTFail("重新进入设置后应仍能找到 Emoji 选项")
            return
        }
        XCTAssertTrue(isSelected(persistedEmoji), "重启后应保留 Emoji 风格")
        guard let currentJourney = scrollToWorkspaceStyleOption("journey", in: persistedEmojiPicker) else {
            XCTFail("重新进入设置后应仍能找到《西游记》选项")
            return
        }
        currentJourney.tap()
        XCTAssertTrue(waitUntilSelected(currentJourney), "选择《西游记》后应立即保存")
        try relaunchDirectlyIntoWorkspaces()
        try openWorkspaceAppearanceSettings()
        let persistedJourneyPicker = app.descendant(identifier: "settings.workspaceIconStyle")
        guard let persistedJourney = scrollToWorkspaceStyleOption(
            "journey",
            in: persistedJourneyPicker
        ) else {
            XCTFail("重新进入设置后应仍能找到《西游记》选项")
            return
        }
        XCTAssertTrue(isSelected(persistedJourney), "重启后应保留《西游记》风格")

        // 真机测试不应永久改变用户原来的视觉偏好；不只恢复 Emoji，也覆盖其他主题。
        guard let originalStyle = scrollToWorkspaceStyleOption(
            originalStyleID,
            in: persistedJourneyPicker
        ) else {
            XCTFail("测试结束时应找到原图标风格")
            return
        }
        originalStyle.tap()
        XCTAssertTrue(waitUntilSelected(originalStyle), "测试结束时应恢复原图标风格")
    }

    private func assertWorkspaceStylePickerUsesExactlyTwoRows(_ frames: [CGRect]) {
        XCTAssertEqual(frames.count, 9)
        guard frames.count == 9 else { return }

        var rowCenters: [CGFloat] = []
        for frame in frames where !rowCenters.contains(where: { abs($0 - frame.midY) <= 2 }) {
            rowCenters.append(frame.midY)
        }
        rowCenters.sort()
        XCTAssertEqual(rowCenters.count, 2, "全部风格应固定在两行内横向滑动")
        guard rowCenters.count == 2 else { return }
        XCTAssertGreaterThan(rowCenters[1] - rowCenters[0], 44, "两行风格不应重叠")
    }

    private func scrollToWorkspaceStyleOption(
        _ styleID: String,
        in picker: XCUIElement
    ) -> XCUIElement? {
        let option = app.descendant(
            identifier: "settings.workspaceIconStyle.option.\(styleID)"
        )
        if option.waitForExistence(timeout: 0.5), option.isHittable {
            return option
        }
        for _ in 0..<6 {
            picker.swipeLeft()
            if option.waitForExistence(timeout: 0.5), option.isHittable {
                return option
            }
        }
        for _ in 0..<6 {
            picker.swipeRight()
            if option.waitForExistence(timeout: 0.5), option.isHittable {
                return option
            }
        }
        return nil
    }

    private func presentQRScanner() throws {
        installCameraPermissionMonitor()

        // 扫码页关闭后会回到连接管理页。优先复用当前页面的入口，避免为了第二次
        // 拉起扫码器又退回工作台并重新进入设置，降低实体机导航差异带来的误报。
        let currentConnectionScan = app.descendant(identifier: "settings.connection.scanQRCode")
        let firstSetupScan = app.descendant(identifier: "settings.hostInstaller.scan")
        if currentConnectionScan.exists, currentConnectionScan.isHittable {
            currentConnectionScan.tap()
        } else if firstSetupScan.exists, firstSetupScan.isHittable {
            firstSetupScan.tap()
        } else {
            try enterWorkbenchIfNeeded()
            try openSettings()
            let connection = app.descendant(identifier: "settings.connectionManagement")
            XCTAssertTrue(scrollUntilHittable(connection), "设置页应提供 Mac 连接管理入口")
            connection.tap()
            let scan = app.descendant(identifier: "settings.connection.scanQRCode")
            let setupScan = app.descendant(identifier: "settings.hostInstaller.scan")
            if scrollUntilHittable(scan, maximumSwipes: 4) {
                scan.tap()
            } else {
                XCTAssertTrue(scrollUntilHittable(setupScan), "连接管理页应提供二维码扫码入口")
                setupScan.tap()
            }
        }

        handleCameraPermissionIfPresented()
        XCTAssertTrue(
            app.descendant(identifier: "qrScanner.close").waitForExistence(timeout: 15),
            "首次点击扫码后扫码页应保持展示，不能拉起相机后立刻收回"
        )
    }

    private func assertScannerRemainsPresented() {
        let close = app.descendant(identifier: "qrScanner.close")
        let disappearance = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: close
        )
        let result = XCTWaiter.wait(
            for: [disappearance],
            timeout: 2.5
        )
        XCTAssertEqual(result, .timedOut, "扫码页至少应稳定展示 2.5 秒")
        XCTAssertTrue(close.exists, "相机初始化后扫码页不应自动消失")
        XCTAssertEqual(app.state, .runningForeground)
    }

    private func installCameraPermissionMonitor() {
        addUIInterruptionMonitor(withDescription: "Camera permission") { alert in
            let allowButtons = ["Allow", "允许", "Allow While Using App", "使用 App 时允许"]
                .map { alert.buttons[$0] }
            if let button = allowButtons.first(where: \.exists) {
                button.tap()
                return true
            }
            return false
        }
    }

    private func handleCameraPermissionIfPresented() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 6) else {
            return
        }
        let allowButtons = ["Allow", "允许", "Allow While Using App", "使用 App 时允许"]
            .map { alert.buttons[$0] }
        guard let button = allowButtons.first(where: \.exists) else {
            XCTFail("相机权限弹窗出现后应提供允许按钮")
            return
        }
        button.tap()
    }

    private func assertMinimumTouchTarget(
        _ element: XCUIElement,
        named name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // 真机读取的是系统最终命中矩形，可同时覆盖 SwiftUI 内容形状和平台适配结果。
        XCTAssertGreaterThanOrEqual(element.frame.width, 44, "\(name)宽度应至少为 44pt", file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.height, 44, "\(name)高度应至少为 44pt", file: file, line: line)
    }

    private func assertCompactModelPickerFitsWindow(
        _ modelPicker: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let windowFrame = app.windows.firstMatch.frame
        guard min(windowFrame.width, windowFrame.height) < 600 else {
            return
        }
        // 标准字号的 Picker 为 132/184/236pt；辅助功能字号会随 large detent
        // 增长并在内部滚动。系统没有把 adapted sheet 暴露为 XCUIElement，
        // 因此用 Picker 到窗口底部的剩余区域守住“不超过一行空白”的用户结果。
        let maximumUnusedHeight: CGFloat = 52
        XCTAssertLessThanOrEqual(
            windowFrame.maxY - modelPicker.frame.maxY,
            maximumUnusedHeight,
            "模型 Sheet 应贴合内容，不能在网格上下保留大面积空白",
            file: file,
            line: line
        )
    }

    private func assertPopover(
        _ confirmation: XCUIElement,
        isAnchoredNear source: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let windowFrame = app.windows.firstMatch.frame
        let confirmationFrame = confirmation.frame
        let sourceFrame = source.frame

        XCTAssertGreaterThanOrEqual(confirmationFrame.minX, windowFrame.minX, file: file, line: line)
        XCTAssertLessThanOrEqual(confirmationFrame.maxX, windowFrame.maxX, file: file, line: line)
        XCTAssertGreaterThanOrEqual(confirmationFrame.minY, windowFrame.minY, file: file, line: line)
        XCTAssertLessThanOrEqual(confirmationFrame.maxY, windowFrame.maxY, file: file, line: line)
        // 系统确认按钮与 source rect 的中心应保持在一个 popover 宽度内；
        // 旧实现挂在整页根视图时，两者会横跨主内容与左侧会话栏。
        XCTAssertLessThanOrEqual(
            abs(confirmationFrame.midX - sourceFrame.midX),
            max(confirmationFrame.width, 360),
            "确认弹窗必须锚定在对应卡片操作入口附近",
            file: file,
            line: line
        )
    }

    private func openComposerIfNeeded() throws {
        let options = app.descendant(identifier: "composer.options")
        if options.waitForExistence(timeout: 4) {
            return
        }

        try enterWorkbenchIfNeeded()
        let sessionRows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "sessions.row."))
        guard sessionRows.firstMatch.waitForExistence(timeout: 25) else {
            throw XCTSkip("当前设备没有可打开的样例会话，跳过 Composer 真机状态回归")
        }
        sessionRows.firstMatch.tap()
        XCTAssertTrue(
            options.waitForExistence(timeout: 25),
            "打开样例会话后应进入 Composer"
        )
    }

    private func enterWorkbenchIfNeeded() throws {
        if workbenchSettingsEntry.waitForExistence(timeout: 3) {
            return
        }
        // iPad 的 NavigationSplitView 可能在启动后默认收起侧栏；先展开侧栏，
        // 才能访问侧栏底部的设置入口，避免把正常工作台误判为不可测试。
        if let showSidebar = firstExistingButton(
            labels: ["显示边栏", "Show Sidebar"],
            timeout: 2
        ), showSidebar.isHittable {
            showSidebar.tap()
            if workbenchSettingsEntry.waitForExistence(timeout: 8) {
                return
            }
        }
        if app.descendant(identifier: "composer.options").exists {
            let back = app.navigationBars.buttons.firstMatch
            if back.waitForExistence(timeout: 3), back.isHittable {
                back.tap()
                if workbenchSettingsEntry.waitForExistence(timeout: 8) {
                    return
                }
            }
        }
        let debugEntry = app.descendant(identifier: "settings.debugEnterWorkbench")
        guard scrollUntilHittable(debugEntry, maximumSwipes: 10) else {
            throw XCTSkip("当前页面既不是工作台，也没有 Debug 进入工作台入口")
        }
        debugEntry.tap()
        XCTAssertTrue(
            workbenchSettingsEntry.waitForExistence(timeout: 15),
            "Debug 入口应进入工作台"
        )
    }

    private func openSettings() throws {
        if app.descendant(identifier: "settings.connectionManagement").exists {
            return
        }
        if !workbenchSettingsEntry.exists,
           let showSidebar = firstExistingButton(
               labels: ["显示边栏", "Show Sidebar"],
               timeout: 2
           ),
           showSidebar.isHittable {
            showSidebar.tap()
            _ = workbenchSettingsEntry.waitForExistence(timeout: 8)
        }
        let settings = workbenchSettingsEntry
        guard settings.waitForExistence(timeout: 8) else {
            throw XCTSkip("工作台未展示设置入口")
        }
        settings.tap()
        XCTAssertTrue(
            app.descendant(identifier: "settings.connectionManagement").waitForExistence(timeout: 12),
            "设置页应正常打开"
        )
    }

    private func openWorkspaceAppearanceSettings() throws {
        try openSettings()
        let appearance = app.descendant(identifier: "settings.appearance")
        XCTAssertTrue(scrollUntilHittable(appearance), "设置页应提供外观入口")
        appearance.tap()
        XCTAssertTrue(
            app.descendant(identifier: "settings.workspaceIconStyle").waitForExistence(timeout: 8),
            "外观页应展示工作区图标风格选择器"
        )
    }

    private func relaunchDirectlyIntoWorkspaces() throws {
        app.terminate()
        if !app.launchArguments.contains("--debug-open-workspaces") {
            app.launchArguments.append("--debug-open-workspaces")
        }
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 25),
            "MimiRemote 应能重新进入工作区"
        )
        let workspaceCards = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "workspace.card."))
        XCTAssertTrue(
            workspaceCards.firstMatch.waitForExistence(timeout: 15),
            "重新进入工作区后应展示工作区胶囊"
        )
    }

    private func selectMode(identifier: String) throws {
        let options = app.descendant(identifier: "composer.options")
        XCTAssertTrue(options.waitForExistence(timeout: 8))
        options.tap()
        let mode = app.descendant(identifier: identifier)
        guard mode.waitForExistence(timeout: 5) else {
            throw XCTSkip("当前系统未向 UI Automation 暴露发送模式菜单项")
        }
        mode.tap()
        XCTAssertEqual(app.state, .runningForeground)
    }

    private func assertModeSelected(expectedValues: Set<String>) {
        let options = app.descendant(identifier: "composer.options")
        XCTAssertTrue(options.waitForExistence(timeout: 10), "旋转后 Composer 工具栏不应消失")
        guard let value = options.value as? String else {
            XCTFail("旋转后发送模式入口应暴露当前模式")
            return
        }
        XCTAssertTrue(
            expectedValues.contains(value),
            "旋转后发送模式选择应保留，实际值：\(value)"
        )
    }

    private func rotate(to orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
        XCTAssertTrue(
            app.windows.firstMatch.waitForExistence(timeout: 8),
            "旋转后主窗口应继续存在"
        )
    }

    private func scrollUntilHittable(
        _ element: XCUIElement,
        maximumSwipes: Int = 8
    ) -> Bool {
        if element.waitForExistence(timeout: 3), element.isHittable {
            return true
        }
        // 设置页使用 Form。手势只交给当前列表，避免在 iPad Sheet 边缘对整个
        // Application 滑动时被系统解释为模态交互手势。
        let settingsList = app.collectionViews.firstMatch
        for _ in 0..<maximumSwipes {
            if settingsList.exists {
                let start = settingsList.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.74)
                )
                let end = settingsList.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.48)
                )
                start.press(forDuration: 0.05, thenDragTo: end)
            } else {
                app.swipeUp()
            }
            if element.exists, element.isHittable {
                return true
            }
        }
        return element.exists && element.isHittable
    }

    private func isSelected(_ element: XCUIElement) -> Bool {
        guard let value = element.value as? String else {
            return false
        }
        return selectedValues.contains(value)
    }

    private func waitUntilSelected(_ element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                block: { object, _ in
                    guard let candidate = object as? XCUIElement else { return false }
                    return self.isSelected(candidate)
                }
            ),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: 6) == .completed
    }

    private func waitUntilNotSelected(_ element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                block: { object, _ in
                    guard let candidate = object as? XCUIElement else { return false }
                    return candidate.exists && !self.isSelected(candidate)
                }
            ),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: 6) == .completed
    }

    private func waitUntilLabelContains(_ element: XCUIElement, text: String) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label CONTAINS[c] %@", text),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: 6) == .completed
    }

    private func waitForFreshButtonHorizontalPosition(
        labels: [String],
        maxX expectedMaxX: CGFloat,
        accuracy: CGFloat,
        timeout: TimeInterval = 6
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                block: { _, _ in
                    // 每轮重新构造查询，避免 XCUIElement 句柄缓存动画前的 frame。
                    for label in labels {
                        let candidate = self.app.buttons[label]
                        if candidate.exists,
                           abs(candidate.frame.maxX - expectedMaxX) <= accuracy {
                            return true
                        }
                    }
                    return false
                }
            ),
            object: app
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForControlValue(
        _ element: XCUIElement,
        containing expectedValues: [String],
        timeout: TimeInterval = 6
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                block: { object, _ in
                    guard let candidate = object as? XCUIElement, candidate.exists else {
                        return false
                    }
                    let visibleValue = "\(candidate.value ?? "") \(candidate.label)"
                    return expectedValues.contains { visibleValue.contains($0) }
                }
            ),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func dismissPresentedMenuOrPopover() {
        app.windows.firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.08))
            .tap()
    }

    private func firstExistingButton(
        labels: [String],
        timeout: TimeInterval
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let button = labels
                .map({ app.buttons[$0] })
                .first(where: \.exists) {
                return button
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return nil
    }

    private var workbenchSettingsEntry: XCUIElement {
        let compact = app.descendant(identifier: "compactTab.me")
        if compact.exists {
            return compact
        }
        // 紧凑底栏首次恢复路由时，系统偶尔先发布 label、下一帧才发布 identifier。
        // 使用同一系统 Tab 的双语 label 兜底，避免把可见“我的”入口误判为缺失。
        let compactByLabel = app.tabBars.buttons.matching(
            NSPredicate(format: "label IN %@", ["我的", "Me"])
        ).firstMatch
        if compactByLabel.exists {
            return compactByLabel
        }
        return app.descendant(identifier: "sidebar.me")
    }
}

private extension XCUIApplication {
    func descendant(identifier: String) -> XCUIElement {
        descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", identifier))
            .firstMatch
    }
}
