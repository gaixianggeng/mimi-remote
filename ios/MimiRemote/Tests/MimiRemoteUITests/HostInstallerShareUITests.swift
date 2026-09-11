import XCTest

/// 「Mac 连接」页的「发送下载链接」必须真的弹出系统分享面板。
/// 此前的 UI 测试只检查按钮存在，从没点过它，所以 #424 一直没有被拦住。
final class HostInstallerShareUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        // --debug-skip-pairing 不写 endpoint，干净模拟器上是首次连接态，「首次安装」默认展开。
        // --debug-open-mac-connection 直达连接页，避开 Tab 导航在 UI 测试里的时序抖动。
        app.launchArguments = [
            "--debug-skip-pairing", "--debug-seed-ui",
            "--debug-open-mac-connection", "-app.language", "zh-Hans",
        ]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 25))
    }

    override func tearDownWithError() throws {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "\(name)-final"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCUIDevice.shared.orientation = .portrait
        app.terminate()
    }

    func testShareDownloadLinkPresentsActivitySheet() throws {
        let platform = element("settings.hostInstaller.platform")
        if !platform.waitForExistence(timeout: 3) {
            // 只有没展开时才点标题；已展开时再点反而会把内容收起。
            let disclosure = element("settings.hostInstaller.disclosure")
            XCTAssertTrue(disclosure.waitForExistence(timeout: 10), "连接页应提供「首次安装」入口")
            scrollTo(disclosure)
            disclosure.tap()
            XCTAssertTrue(platform.waitForExistence(timeout: 5), "展开后应出现平台选择器")
        }

        let share = element("settings.hostInstaller.share")
        XCTAssertTrue(share.waitForExistence(timeout: 5), "展开后应出现「发送下载链接」按钮")
        scrollTo(share)
        share.tap()

        let activitySheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(
            activitySheet.waitForExistence(timeout: 8),
            "点击「发送下载链接」后应弹出系统分享面板；当前元素树：\(app.debugDescription.prefix(4000))"
        )
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
}
