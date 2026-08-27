import XCTest
@testable import MimiRemoteMac

final class ExperimentPresentationTests: XCTestCase {
    func testMenuAndSettingsShareTheExperimentWindowRoute() {
        XCTAssertEqual(ExperimentMenuRouting.menuTitle, "实验功能…")
        XCTAssertEqual(ExperimentMenuRouting.windowID, AppWindow.experiments.rawValue)
    }

    func testAllDesktopSyncStatesHaveActionableTitles() {
        let states: [CodexDesktopSyncState] = [
            .disabled, .notInstalled, .desktopNotRunning, .connecting, .ready,
            .unsupportedBuild, .socketUnavailable, .protocolError, .legacyCleanupRequired,
        ]
        for state in states {
            XCTAssertFalse(ExperimentPresentation.codexStatusTitle(for: state).isEmpty)
            XCTAssertFalse(ExperimentPresentation.codexStatusDetail(for: state).isEmpty)
        }
    }

    func testUnsupportedBuildExplainsThePinnedAllowlist() {
        let detail = ExperimentPresentation.codexStatusDetail(
            for: .unsupportedBuild,
            version: "26.900.1",
            build: "9001"
        )
        XCTAssertTrue(detail.contains("26.820.60940 (7119)"))
        XCTAssertTrue(detail.contains("26.900.1 / 9001"))
    }

    func testToggleDescriptionNamesDesktopIPCAndKeepsIndependentServerBoundary() {
        XCTAssertTrue(
            ExperimentPresentation.codexToggleDescription(isEnabled: true).contains("Desktop IPC")
        )
        XCTAssertTrue(
            ExperimentPresentation.codexToggleDescription(isEnabled: false).contains("独立 App Server")
        )
    }

    func testMenuStatusUsesHostOwnerAndSyncState() {
        XCTAssertEqual(
            ExperimentPresentation.menuStatusText(owner: .macApp, codexState: .ready),
            "已连接"
        )
        XCTAssertEqual(
            ExperimentPresentation.menuStatusText(owner: .macApp, codexState: .unsupportedBuild),
            "版本不支持"
        )
        XCTAssertNil(
            ExperimentPresentation.menuStatusText(owner: .macApp, codexState: .disabled)
        )
        XCTAssertEqual(
            ExperimentPresentation.menuStatusText(owner: .homebrew, codexState: .ready),
            "不可管理"
        )
    }
}
