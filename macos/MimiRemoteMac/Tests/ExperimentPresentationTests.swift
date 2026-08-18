import XCTest
@testable import MimiRemoteMac

final class ExperimentPresentationTests: XCTestCase {
    func testMenuAndSettingsShareTheExperimentWindowRoute() {
        XCTAssertEqual(ExperimentMenuRouting.menuTitle, "实验功能…")
        XCTAssertEqual(ExperimentMenuRouting.windowID, AppWindow.experiments.rawValue)
    }

    func testCodexStatusTitlesDescribeReadyEnvironmentAsConfigured() {
        XCTAssertEqual(
            ExperimentPresentation.codexStatusTitle(for: .ready),
            "环境已配置"
        )
    }

    func testCodexStatusDetailsKeepEachBoundaryActionable() {
        let disabled = ExperimentPresentation.codexStatusDetail(for: .disabled)
        XCTAssertTrue(disabled.contains("独立服务"))
        XCTAssertTrue(disabled.contains("写入冲突"))

        let pending = ExperimentPresentation.codexStatusDetail(for: .pendingRestart)
        XCTAssertEqual(pending, "保存任务后应用设置并完全重启 Codex Desktop。")

        let ready = ExperimentPresentation.codexStatusDetail(for: .ready)
        XCTAssertTrue(ready.contains("待用同一空闲会话跨端验证"))
        XCTAssertFalse(ready.contains("端到端已验证"))

        for state in [
            CodexDesktopStatusState.backendNotShared,
            .failed,
            .externalConflict,
        ] {
            let detail = ExperimentPresentation.codexStatusDetail(for: state)
            XCTAssertTrue(detail.contains("共享尚未生效"))
            XCTAssertTrue(detail.contains("先修复配置"))
            XCTAssertTrue(detail.contains("同一会话可能无法在两端打开"))
            XCTAssertFalse(detail.contains("-32600"))
        }

        let failedWithProtocolError = ExperimentPresentation.codexStatusDetail(
            for: .failed,
            error: "app-server 错误 -32600：already has an active writer"
        )
        XCTAssertTrue(failedWithProtocolError.contains("会话写入冲突"))
        XCTAssertTrue(failedWithProtocolError.contains("同一会话正在被其他端占用"))
        XCTAssertFalse(failedWithProtocolError.contains("-32600"))
        XCTAssertFalse(failedWithProtocolError.localizedCaseInsensitiveContains("active writer"))
    }

    func testMenuStatusUsesHostOwnerAndCodexStateWithoutDuplicatingControls() {
        XCTAssertEqual(
            ExperimentPresentation.menuStatusText(owner: .macApp, codexState: .pendingRestart),
            "需要重启"
        )
        XCTAssertEqual(
            ExperimentPresentation.menuStatusText(owner: .macApp, codexState: .ready),
            "已启用"
        )
        XCTAssertNil(
            ExperimentPresentation.menuStatusText(owner: .macApp, codexState: .disabled)
        )
        XCTAssertEqual(
            ExperimentPresentation.menuStatusText(owner: .homebrew, codexState: .ready),
            "不可管理"
        )
        XCTAssertEqual(
            ExperimentPresentation.menuAccessibilityLabel(owner: .macApp, codexState: .pendingRestart),
            "实验功能，需要重启"
        )
    }

    func testCodexToggleDescriptionExplainsPositiveEnabledBehavior() {
        let enabled = ExperimentPresentation.codexToggleDescription(isEnabled: true)
        XCTAssertTrue(enabled.contains("将尝试共享同一空闲会话"))
        XCTAssertTrue(enabled.contains("正在运行的任务仍只读"))
    }
}
