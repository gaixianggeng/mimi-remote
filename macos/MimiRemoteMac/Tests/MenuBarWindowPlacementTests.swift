import XCTest
@testable import MimiRemoteMac

final class MenuBarWindowPlacementTests: XCTestCase {
    func testMovesOverlappingWindowBelowMenuBar() {
        let screen = CGRect(x: 0, y: 0, width: 2_560, height: 1_440)
        let window = CGRect(x: 1_000, y: 827, width: 356, height: 610)

        let correctedY = MenuBarWindowPlacement.correctedOriginY(
            windowFrame: window,
            screenFrame: screen,
            menuBarHeight: 30
        )

        XCTAssertEqual(correctedY, 800)
    }

    func testKeepsAlreadyValidSystemPosition() {
        let screen = CGRect(x: 2_560, y: 0, width: 2_560, height: 1_440)
        let window = CGRect(x: 3_600, y: 780, width: 356, height: 600)

        let correctedY = MenuBarWindowPlacement.correctedOriginY(
            windowFrame: window,
            screenFrame: screen,
            menuBarHeight: 30
        )

        XCTAssertEqual(correctedY, window.minY)
    }
}
