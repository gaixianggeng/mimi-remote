import XCTest
@testable import MimiRemote

final class NewSessionPresentationSourceTests: XCTestCase {
    func testStableSourcesUseDistinctPresentationIdentities() {
        let toolbar = WorkbenchSheetPresentation(
            destination: .newSession,
            source: .sessionsToolbarNewSession
        )
        let sidebar = WorkbenchSheetPresentation(
            destination: .newSession,
            source: .sidebarNewSession
        )

        XCTAssertEqual(NewSessionPresentationSource.allCases.count, 2)
        XCTAssertNotEqual(
            NewSessionPresentationSource.sessionsToolbarNewSession.transitionSourceID,
            NewSessionPresentationSource.sidebarNewSession.transitionSourceID
        )
        XCTAssertNotEqual(toolbar.id, sidebar.id)
    }

    func testFallbackPresentationKeepsSourceNil() {
        var state = WorkbenchSheetPresentationState()

        state.present(.newSession)

        XCTAssertEqual(state.presentation?.destination, .newSession)
        XCTAssertNil(state.presentation?.source)
        XCTAssertEqual(state.presentation?.transition, .systemSheet)
    }

    func testDismissAndBindingResetClearPreviousSource() {
        var state = WorkbenchSheetPresentationState()
        state.present(.newSession, source: .sidebarNewSession)

        state.dismiss()
        XCTAssertNil(state.presentation)

        state.present(.newSession)
        XCTAssertNil(state.presentation?.source)

        state.present(.newSession, source: .sessionsToolbarNewSession)
        state.replace(with: nil)
        XCTAssertNil(state.presentation)
    }

    func testReduceMotionIsLockedForCurrentPresentationAndAppliedNextTime() throws {
        var state = WorkbenchSheetPresentationState()
        state.present(
            .newSession,
            source: .sessionsToolbarNewSession,
            reduceMotion: true
        )

        XCTAssertEqual(state.presentation?.transition, .systemSheet)
        XCTAssertEqual(state.presentation?.source, .sessionsToolbarNewSession)

        state.dismiss()
        state.present(
            .newSession,
            source: .sessionsToolbarNewSession,
            reduceMotion: false
        )
        XCTAssertEqual(
            state.presentation?.transition,
            .zoom(
                sourceID: NewSessionPresentationSource
                    .sessionsToolbarNewSession
                    .transitionSourceID
            )
        )
    }

    func testNonNewSessionDestinationCannotRetainNewSessionSource() {
        var state = WorkbenchSheetPresentationState()

        state.present(.settings, source: .sidebarNewSession)

        XCTAssertEqual(state.presentation?.destination, .settings)
        XCTAssertNil(state.presentation?.source)
    }

    func testActivePresentationCannotBeReenteredWithAnotherSource() {
        var state = WorkbenchSheetPresentationState()
        state.present(.newSession, source: .sessionsToolbarNewSession)

        state.present(.newSession, source: .sidebarNewSession)
        state.replace(
            with: WorkbenchSheetPresentation(
                destination: .settings,
                source: nil
            )
        )

        XCTAssertEqual(state.presentation?.destination, .newSession)
        XCTAssertEqual(state.presentation?.source, .sessionsToolbarNewSession)
    }

    func testToolbarWithoutNamespaceFailsClosedToSystemSheet() {
        XCTAssertEqual(
            NewSessionPresentationSource.sessionsToolbar(hasNamespace: true),
            .sessionsToolbarNewSession
        )
        XCTAssertNil(
            NewSessionPresentationSource.sessionsToolbar(hasNamespace: false)
        )
    }

    func testPhoneInlineNewSessionButtonGatesZoomSourceOnIOS26Availability() throws {
        let sessionListURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Features/Sessions/SessionListView.swift")
        let source = try String(contentsOf: sessionListURL, encoding: .utf8)

        let functionMarker = "private func phoneInlineNewSessionButton(tokens: ThemeTokens) -> some View {"
        let nextFunctionMarker = "private func phoneInlineNewSessionButtonContent("
        let startRange = try XCTUnwrap(
            source.range(of: functionMarker),
            "SessionListView.swift 应包含 phoneInlineNewSessionButton"
        )
        let endRange = try XCTUnwrap(
            source.range(of: nextFunctionMarker, range: startRange.upperBound..<source.endIndex),
            "phoneInlineNewSessionButton 应通过辅助视图分离 iOS 26+ 与旧系统分支"
        )
        let body = String(source[startRange.upperBound..<endRange.lowerBound])

        let availableBranch = try XCTUnwrap(
            body.range(of: "if let newSessionPresentationNamespace, #available(iOS 26.0, *) {"),
            "phoneInlineNewSessionButton 必须按 iOS 26+ 与 namespace 同时门控 zoom source"
        )
        let elseBranch = try XCTUnwrap(
            body.range(of: "} else {", range: availableBranch.upperBound..<body.endIndex),
            "phoneInlineNewSessionButton 必须保留 iOS 18–25 / 无 namespace 的回退分支"
        )

        let availableBody = String(body[availableBranch.upperBound..<elseBranch.lowerBound])
        let fallbackBody = String(body[elseBranch.upperBound...])

        XCTAssertTrue(
            availableBody.contains("source: .sessionsToolbar(hasNamespace: true)"),
            "iOS 26+ 且已安装 matchedTransitionSource 时才上报 zoom source"
        )
        XCTAssertTrue(
            availableBody.contains(".matchedTransitionSource("),
            "iOS 26+ 分支必须安装 matchedTransitionSource"
        )
        XCTAssertTrue(
            fallbackBody.contains("source: .sessionsToolbar(hasNamespace: false)"),
            "iOS 18–25 回退分支必须传入 hasNamespace: false 以回退系统 sheet"
        )
        XCTAssertFalse(
            fallbackBody.contains("hasNamespace: true"),
            "回退分支不得上报 zoom source"
        )
        XCTAssertFalse(
            fallbackBody.contains(".matchedTransitionSource("),
            "回退分支不得安装 matchedTransitionSource"
        )
    }

    func testSourceCanChangeOnlyAfterDismissInBothDirections() {
        var state = WorkbenchSheetPresentationState()

        state.present(.newSession, source: .sessionsToolbarNewSession)
        state.dismiss()
        state.present(.newSession, source: .sidebarNewSession)
        XCTAssertEqual(state.presentation?.source, .sidebarNewSession)

        state.dismiss()
        state.present(.newSession, source: .sessionsToolbarNewSession)
        XCTAssertEqual(state.presentation?.source, .sessionsToolbarNewSession)
    }

    func testInspectorMediumToolbarWithNamespaceUsesZoom() {
        var state = InspectorPresentationState()

        state.present(
            on: .mediumSheet,
            source: .sessionToolbarInspector,
            hasNamespace: true
        )

        XCTAssertEqual(state.context?.host, .mediumSheet)
        XCTAssertEqual(state.context?.source, .sessionToolbarInspector)
        XCTAssertEqual(
            state.context?.transition,
            .zoom(
                sourceID: InspectorPresentationSource
                    .sessionToolbarInspector
                    .transitionSourceID
            )
        )
    }

    func testInspectorFallbackHostsAndMissingNamespaceUseSystemSheet() {
        for host in [
            InspectorPresentationHost.compactSheet,
            .attached,
        ] {
            var state = InspectorPresentationState()
            state.present(
                on: host,
                source: .sessionToolbarInspector,
                hasNamespace: true
            )

            XCTAssertNil(state.context?.source, "Unexpected source for \(host)")
            XCTAssertEqual(state.context?.transition, .systemSheet)
        }

        var missingNamespaceState = InspectorPresentationState()
        missingNamespaceState.present(
            on: .mediumSheet,
            source: .sessionToolbarInspector,
            hasNamespace: false
        )
        XCTAssertNil(missingNamespaceState.context?.source)
        XCTAssertEqual(missingNamespaceState.context?.transition, .systemSheet)

        var programmaticState = InspectorPresentationState()
        programmaticState.present(on: .mediumSheet)
        XCTAssertNil(programmaticState.context?.source)
        XCTAssertEqual(programmaticState.context?.transition, .systemSheet)
    }

    func testInspectorReduceMotionIsLockedForCurrentPresentation() {
        var state = InspectorPresentationState()
        state.present(
            on: .mediumSheet,
            source: .sessionToolbarInspector,
            hasNamespace: true,
            reduceMotion: true
        )

        state.present(
            on: .mediumSheet,
            source: .sessionToolbarInspector,
            hasNamespace: true,
            reduceMotion: false
        )
        XCTAssertEqual(state.context?.source, .sessionToolbarInspector)
        XCTAssertEqual(state.context?.transition, .systemSheet)

        state.dismiss()
        state.present(
            on: .mediumSheet,
            source: .sessionToolbarInspector,
            hasNamespace: true,
            reduceMotion: false
        )
        XCTAssertEqual(
            state.context?.transition,
            .zoom(
                sourceID: InspectorPresentationSource
                    .sessionToolbarInspector
                    .transitionSourceID
            )
        )
    }

    func testInspectorActivePresentationRejectsReentryReplacement() {
        var state = InspectorPresentationState()
        state.present(
            on: .mediumSheet,
            source: .sessionToolbarInspector,
            hasNamespace: true
        )

        state.present(on: .mediumSheet, reduceMotion: true)

        XCTAssertEqual(state.context?.host, .mediumSheet)
        XCTAssertEqual(state.context?.source, .sessionToolbarInspector)
        XCTAssertEqual(
            state.context?.transition,
            .zoom(
                sourceID: InspectorPresentationSource
                    .sessionToolbarInspector
                    .transitionSourceID
            )
        )
    }

    func testInspectorDismissClearsContext() {
        var state = InspectorPresentationState()
        state.present(
            on: .mediumSheet,
            source: .sessionToolbarInspector,
            hasNamespace: true
        )

        state.dismiss()

        XCTAssertNil(state.context)
    }

    func testInspectorToolbarFallbackToolbarSequenceDoesNotLeakSource() {
        var state = InspectorPresentationState()

        state.present(
            on: .mediumSheet,
            source: .sessionToolbarInspector,
            hasNamespace: true
        )
        XCTAssertEqual(state.context?.source, .sessionToolbarInspector)
        state.dismiss()

        state.present(on: .mediumSheet)
        XCTAssertNil(state.context?.source)
        XCTAssertEqual(state.context?.transition, .systemSheet)
        state.dismiss()

        state.present(
            on: .mediumSheet,
            source: .sessionToolbarInspector,
            hasNamespace: true
        )
        XCTAssertEqual(state.context?.source, .sessionToolbarInspector)
        XCTAssertEqual(
            state.context?.transition,
            .zoom(
                sourceID: InspectorPresentationSource
                    .sessionToolbarInspector
                    .transitionSourceID
            )
        )
    }

    func testInspectorLayoutHostChangeClearsOldTransitionContext() {
        var state = InspectorPresentationState()
        state.present(
            on: .mediumSheet,
            source: .sessionToolbarInspector,
            hasNamespace: true
        )

        state.layoutHostDidChange(to: .attached)

        XCTAssertNil(state.context)
    }
}
