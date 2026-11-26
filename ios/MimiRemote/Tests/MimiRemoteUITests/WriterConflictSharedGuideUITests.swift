import XCTest

/// 点击真实 SwiftUI 冲突卡「如何共享」与引导弹层「完成」按钮，验证动作绑定和返回后的原冲突卡操作。
final class WriterConflictSharedGuideUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "--debug-writer-conflict-guide-fixture",
            "--debug-seed-store-ui",
            "-app.language", "zh-Hans"
        ]
        if name.contains("ConversationView") {
            app.launchArguments.append("--debug-writer-conflict-conversation")
        }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 25))
    }

    override func tearDownWithError() throws {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }

    func testTapSharedGuideAndDoneOnConflictCardReturnsToOriginalActions() {
        let guideButton = button("writerConflict.sharedGuideButton")
        XCTAssertTrue(guideButton.waitForExistence(timeout: 10), "冲突卡应渲染可点击的「如何共享」按钮")
        XCTAssertEqual(guideButton.label, "如何共享")
        XCTAssertGreaterThanOrEqual(guideButton.frame.width, 43.5)
        XCTAssertGreaterThanOrEqual(guideButton.frame.height, 43.5)

        tapHittable(guideButton)

        let guideTitle = app.navigationBars["与电脑共享同一会话"]
        XCTAssertTrue(guideTitle.waitForExistence(timeout: 8), "点击「如何共享」应弹出共享引导页")
        XCTAssertTrue(
            app.staticTexts["如何与电脑实时共享（Mac）"].waitForExistence(timeout: 5),
            "共享引导应展示 Mac 共享说明标题"
        )
        let macSetupPredicate = NSPredicate(format: "label CONTAINS %@", "打开 Codex SSH 设置")
        XCTAssertTrue(
            app.staticTexts.containing(macSetupPredicate).firstMatch.waitForExistence(timeout: 5),
            "共享引导正文应对齐 Mac 一键配置成功后的「打开 Codex SSH 设置」按钮文案"
        )

        let doneButton = button("writerConflict.sharedGuideDoneButton")
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5), "共享引导页应展示「完成」按钮")
        tapHittable(doneButton)

        let dismissed = NSPredicate(format: "exists == false")
        expectation(for: dismissed, evaluatedWith: doneButton)
        waitForExpectations(timeout: 8)

        let retryButton = button("writerConflict.retryButton")
        let primaryButton = button("writerConflict.primaryButton")
        XCTAssertTrue(retryButton.waitForExistence(timeout: 5), "关闭引导后原冲突卡「重试」按钮应继续可用")
        XCTAssertTrue(primaryButton.waitForExistence(timeout: 5), "关闭引导后原冲突卡「分支到新聊天」按钮应继续可用")

        tapHittable(retryButton)
        waitForCounter("writerConflict.fixture.retryCount", equals: "1")

        tapHittable(primaryButton)
        waitForCounter("writerConflict.fixture.forkCount", equals: "1")
    }

    func testTapSharedGuideAndDoneInConversationViewKeepsCardInteractive() {
        let guideButton = button("writerConflict.sharedGuideButton")
        XCTAssertTrue(guideButton.waitForExistence(timeout: 10), "会话页冲突卡应渲染可点击的「如何共享」按钮")
        tapHittable(guideButton)

        let guideTitle = app.navigationBars["与电脑共享同一会话"]
        XCTAssertTrue(guideTitle.waitForExistence(timeout: 8), "在真实会话页点击「如何共享」应弹出引导弹层")

        let doneButton = button("writerConflict.sharedGuideDoneButton")
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5), "会话页引导弹层应展示「完成」按钮")
        tapHittable(doneButton)

        let dismissed = NSPredicate(format: "exists == false")
        expectation(for: dismissed, evaluatedWith: doneButton)
        waitForExpectations(timeout: 8)

        let retryButton = button("writerConflict.retryButton")
        XCTAssertTrue(retryButton.waitForExistence(timeout: 5), "关闭会话页引导后冲突卡「重试」按钮应继续可用")
        tapHittable(retryButton)
        waitForCounter("writerConflict.fixture.conversationRetryCount", equals: "1")
    }

    private func button(_ identifier: String) -> XCUIElement {
        app.buttons.matching(identifier: identifier).firstMatch
    }

    private func tapHittable(_ element: XCUIElement) {
        let hittable = NSPredicate(format: "hittable == true")
        expectation(for: hittable, evaluatedWith: element)
        waitForExpectations(timeout: 5)
        element.tap()
    }

    private func waitForCounter(_ identifier: String, equals expected: String) {
        let label = app.staticTexts[identifier]
        let predicate = NSPredicate(format: "label == %@", expected)
        expectation(for: predicate, evaluatedWith: label)
        waitForExpectations(timeout: 8)
    }
}
