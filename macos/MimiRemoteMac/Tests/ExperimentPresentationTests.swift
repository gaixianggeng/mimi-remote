import XCTest
@testable import MimiRemoteMac

final class ExperimentPresentationTests: XCTestCase {
    func testMenuAndSettingsShareTheExperimentWindowRoute() {
        XCTAssertEqual(ExperimentMenuRouting.menuTitle, "实验功能…")
        XCTAssertEqual(ExperimentMenuRouting.windowID, AppWindow.experiments.rawValue)
    }

}
