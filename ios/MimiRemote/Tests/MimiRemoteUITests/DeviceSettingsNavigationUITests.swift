import XCTest
import UIKit

/// 从真实 Tab 和设置入口操作，覆盖纯状态测试不能证明的呈现宿主与返回路径。
final class DeviceSettingsNavigationUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = [
            "--debug-skip-pairing", "--debug-seed-store-ui",
            "--debug-open-devices", "-app.language", "zh-Hans"
        ]
        if name.contains("ManagedConnection") {
            app.launchArguments.append("--debug-enable-managed-connection")
        }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 25))
        XCTAssertTrue(element("settings.profile.debug-store-primary").waitForExistence(timeout: 10))
    }

    override func tearDownWithError() throws {
        capture("final")
        XCUIDevice.shared.orientation = .portrait
        app.terminate()
    }

    func testNavigationUsesAvailableWidthAcrossRotation() throws {
        assertDeviceNavigation()
        capture("devices-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 2)
        assertDeviceNavigation()
        capture("devices-landscape")
        openMe()
        XCTAssertTrue(element("settings.tokenUsage").waitForExistence(timeout: 10))
        XCTAssertEqual(element("settings.connectionManagement").exists, !expectsCompactNavigation)
        openDevices()
        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 2)
        assertDeviceNavigation()
        openMe()
        capture("me-portrait")
        let appearance = element("settings.appearance")
        scrollTo(appearance)
        XCTAssertEqual(appearance.frame.height, 52, accuracy: 1)
    }

    func testPreferenceDetailAndSelectionSurviveRotation() throws {
        openMe()
        let language = element("settings.language")
        scrollTo(language)
        language.tap()
        let voice = element("settings.language.detail.voiceInput")
        XCTAssertTrue(voice.waitForExistence(timeout: 10))
        capture("language-portrait")
        let options = voice.buttons
        let original = options.allElementsBoundByIndex.first(where: { $0.isSelected })
        let originalLabel = original?.label
        let alternative = options.allElementsBoundByIndex.first(where: { !$0.isSelected })
        XCTAssertNotNil(originalLabel, "选项应公开选中状态")
        XCTAssertNotNil(alternative, "语音设置应提供可切换项")
        alternative?.tap()
        let alternativeLabel = alternative?.label

        defer {
            if let originalLabel {
                let originalOption = element("settings.language.detail.voiceInput").buttons[originalLabel]
                if originalOption.exists { originalOption.tap() }
            }
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(element("settings.language.detail.voiceInput").waitForExistence(timeout: 12), "旋转不能退回我的首页")
        if let alternativeLabel {
            XCTAssertTrue(element("settings.language.detail.voiceInput").buttons[alternativeLabel].isSelected)
        }
        capture("language-landscape")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(element("settings.language.detail.voiceInput").waitForExistence(timeout: 12))
        if expectsCompactNavigation {
            openDevices()
            XCTAssertTrue(element("settings.profile.debug-store-primary").waitForExistence(timeout: 8))
            openMe()
            XCTAssertTrue(element("settings.language.detail.voiceInput").waitForExistence(timeout: 8))
            if let alternativeLabel {
                XCTAssertTrue(element("settings.language.detail.voiceInput").buttons[alternativeLabel].isSelected)
            }
        }
    }

    func testUnavailableDeviceKeepsCurrentDeviceAndDeviceTab() throws {
        // 演示电脑不连接真实服务；这里验证切换失败时的旧设备和全局页面保护。
        element("settings.profile.switch.debug-store-secondary").tap()
        XCTAssertTrue(element("settings.connection.error").waitForExistence(timeout: 15))
        if expectsCompactNavigation { XCTAssertTrue(tab("devices").isSelected) }
        XCTAssertTrue(element("settings.profile.switch.debug-store-secondary").exists)
        XCTAssertFalse(element("settings.profile.switch.debug-store-primary").exists)
        capture("unavailable-device")
    }

    func testRenameDraftAndManualInputSurviveRotation() throws {
        let menu = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "管理", "Management")).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 8))
        menu.tap()
        let rename = element("settings.profile.rename.debug-store-primary")
        XCTAssertTrue(rename.waitForExistence(timeout: 8))
        // 真机多窗口菜单有 frame 但可能没有 AX activation point，按实际行中心点击。
        rename.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let name = element("settings.profile.rename.name")
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        name.tap()
        name.typeText(" Draft")
        let draft = name.value as? String
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(name.waitForExistence(timeout: 10), "重命名宿主不能因旋转销毁")
        XCTAssertEqual(name.value as? String, draft)
        capture("rename-landscape")
        app.buttons["取消"].tap()
        assertDeviceNavigation()
        XCTAssertEqual(element("settings.profile.debug-store-primary").label.contains("Draft"), false)

        let manual = element("settings.connection.manual")
        scrollTo(manual)
        manual.tap()
        let displayName = element("settings.profileDisplayName")
        scrollTo(displayName)
        displayName.tap()
        displayName.typeText("Rotation Draft")
        let manualDraft = displayName.value as? String
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(displayName.waitForExistence(timeout: 12))
        XCTAssertEqual(displayName.value as? String, manualDraft)
        capture("manual-draft-portrait")
    }

    func testAllSettingsDestinationsRemainReachable() throws {
        // 只检查本次样式覆盖的可达入口，不发起真实网络诊断或购买。
        openMe()
        for (entry, title) in [
            ("settings.appearance", "个性化"),
            ("settings.defaultModels", "默认模型"),
            ("settings.defaultPermissions", "默认权限"),
            ("settings.diagnostics", "诊断与支持"),
            ("settings.advancedDevelopment", "高级与开发"),
            ("settings.aboutLegal", "关于与法律")
        ] {
            let row = element(entry)
            scrollTo(row)
            row.tap()
            XCTAssertTrue(app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 8), "详情应提供返回按钮")
            capture("detail-\(entry)")
            let back = app.navigationBars.buttons.firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 6), "\(title)应可返回")
            back.tap()
            XCTAssertTrue(element("settings.tokenUsage").waitForExistence(timeout: 8))
        }
    }

    func testNestedSettingsAndDeviceToolsRemainReachable() throws {
        openMe()
        for (parent, children) in [
            ("settings.diagnostics", ["settings.doctor", "settings.support"]),
            ("settings.advancedDevelopment", ["settings.capabilities"]),
            ("settings.aboutLegal", ["settings.privacyPolicy", "settings.termsOfUse", "settings.openSourceLicense"])
        ] {
            scrollTo(element(parent))
            element(parent).tap()
            for child in children {
                scrollTo(element(child))
                element(child).tap()
                capture("nested-\(child)")
                app.navigationBars.buttons.firstMatch.tap()
                XCTAssertTrue(element(child).waitForExistence(timeout: 8))
            }
            app.navigationBars.buttons.firstMatch.tap()
        }
        openDevices()
        for entry in ["settings.connectionSpeedTest", "settings.connection.tailcat"] {
            scrollTo(element(entry))
            element(entry).tap()
            capture("device-tool-\(entry)")
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(element("settings.profile.debug-store-primary").waitForExistence(timeout: 8))
        }
    }

    func testScannerSurvivesRotationAndCanBeCancelled() throws {
        let scan = element("settings.connection.scanQRCode")
        scrollTo(scan)
        scan.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let permission = springboard.alerts.firstMatch
        if permission.waitForExistence(timeout: 3) { permission.buttons.allElementsBoundByIndex.last?.tap() }
        let close = element("qrScanner.close")
        XCTAssertTrue(close.waitForExistence(timeout: 15))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        capture("scanner-landscape")
        close.tap()
        assertDeviceNavigation()
    }

    func testInstallerAndManagedConnectionRemainReachable() throws {
        let installer = element("settings.hostInstaller.disclosure")
        scrollTo(installer)
        installer.tap()
        let platform = element("settings.hostInstaller.platform")
        scrollTo(platform)
        platform.buttons["Windows"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(platform.waitForExistence(timeout: 12))
        XCTAssertTrue(platform.buttons["Windows"].isSelected)
        capture("installer-windows-landscape")
        XCUIDevice.shared.orientation = .portrait
        let managed = element("settings.connection.managedConnection")
        scrollTo(managed)
        managed.tap()
        XCTAssertTrue(element("settings.managedSubscription.detail").waitForExistence(timeout: 12))
        capture("managed-connection")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(element("settings.profile.debug-store-primary").waitForExistence(timeout: 10))
    }

    private var expectsCompactNavigation: Bool {
        UIDevice.current.userInterfaceIdiom == .phone || app.frame.width < 860
    }

    private func assertDeviceNavigation() {
        XCTAssertTrue(element("settings.profile.debug-store-primary").waitForExistence(timeout: 12))
        if expectsCompactNavigation {
            for name in ["sessions", "workspaces", "devices", "me"] {
                XCTAssertTrue(tab(name).waitForExistence(timeout: 8))
            }
            XCTAssertFalse(element("settings.devices.backToMe").exists)
        } else {
            XCTAssertTrue(element("sidebar.me").waitForExistence(timeout: 8))
            XCTAssertTrue(element("settings.devices.backToMe").waitForExistence(timeout: 8))
        }
    }

    private func openMe() {
        let back = element("settings.devices.backToMe")
        if back.exists { back.tap() }
        else if element("sidebar.me").exists { element("sidebar.me").tap() }
        else { tab("me").tap() }
    }

    private func openDevices() {
        if expectsCompactNavigation { tab("devices").tap() }
        else {
            openMe()
            let connection = element("settings.connectionManagement")
            scrollTo(connection)
            connection.tap()
        }
        XCTAssertTrue(element("settings.profile.debug-store-primary").waitForExistence(timeout: 10))
    }

    private func tab(_ name: String) -> XCUIElement {
        let byID = element("compactTab.\(name)")
        if byID.exists { return byID }
        let labels = ["sessions": "会话", "workspaces": "工作区", "devices": "设备", "me": "我的"]
        return app.buttons[labels[name]!].firstMatch
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func scrollTo(_ item: XCUIElement) {
        if item.waitForExistence(timeout: 2), item.isHittable { return }
        let list = app.collectionViews.firstMatch
        for _ in 0..<10 {
            if item.exists, item.isHittable { return }
            if list.exists { list.swipeUp() } else { app.swipeUp() }
        }
        XCTAssertTrue(item.exists && item.isHittable, "应能滚动到 \(item.identifier)")
    }

    private func capture(_ name: String) {
        // 旋转后等待系统窗口动画落稳；App 截图会沿用过渡中的裁剪区域。
        if name.contains("landscape") { Thread.sleep(forTimeInterval: 1) }
        // 真机只采集本 App 窗口，避免把其他多任务窗口的私人内容写进附件。
        #if targetEnvironment(simulator)
        let screenshot = XCUIScreen.main.screenshot()
        #else
        let screenshot = app.screenshot()
        #endif
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "gh400-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
