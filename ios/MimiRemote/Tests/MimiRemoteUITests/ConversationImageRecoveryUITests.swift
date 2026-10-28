import XCTest

/// 点击真实 SwiftUI 图片卡；不靠数组断言或重建视图掩盖失败后的死路。
final class ConversationImageRecoveryUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--debug-image-recovery-fixture", "--debug-seed-store-ui", "-app.language", "zh-Hans"]
        if name.contains("Denied") { app.launchArguments.append("--debug-image-recovery-denied") }
        app.launch()
    }

    override func tearDownWithError() throws {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }

    func testLocalImageRetriesAndOpensPreviewWithoutRecreatingView() {
        waitForReadCount(1)
        let retry = app.buttons["重试"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5), "自动加载失败后，唯一图片卡必须提供重试")
        retry.tap()
        waitForReadCount(2)
        let preview = app.buttons["预览图片"]
        XCTAssertTrue(preview.waitForExistence(timeout: 8))
        XCTAssertTrue(preview.isEnabled)
        XCTAssertFalse(retry.exists)
        preview.tap()
        let quickLook = app.otherElements["QLPreviewControllerView"]
        XCTAssertTrue(quickLook.waitForExistence(timeout: 8), "成功后的入口必须实际打开 Quick Look")
        XCTAssertGreaterThan(quickLook.frame.width, 0)
    }

    func testLocalImageRetryStillRespectsDeniedFileAccess() {
        waitForReadCount(1)
        let retry = app.buttons["重试"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        retry.tap()
        waitForReadCount(2)
        XCTAssertTrue(retry.waitForExistence(timeout: 8), "授权拒绝后应保留错误和重试入口")
        XCTAssertFalse(app.buttons["预览图片"].exists)
        retry.tap()
        waitForReadCount(3)
        XCTAssertTrue(retry.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["预览图片"].exists)
    }

    private func waitForReadCount(_ count: Int) {
        let label = app.staticTexts["image.fixture.reads"]
        let predicate = NSPredicate(format: "label == %@", String(count))
        expectation(for: predicate, evaluatedWith: label)
        waitForExpectations(timeout: 10)
    }
}
