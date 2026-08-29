import SnapshotTesting
import SwiftUI
import UIKit
import XCTest
@testable import MimiRemote

@MainActor
final class WriterConflictCardSnapshotTests: SimplifiedChineseSnapshotTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "Writer 冲突卡快照只在固定 M5 iPad 宿主录制。"
        )
    }

    func testIdleConflictCardWideLight() {
        assertSnapshot(
            of: makeCard(
                width: 820,
                height: 128,
                colorScheme: .light,
                sourceIsRunning: false,
                availability: .available(lastTurnID: nil)
            ),
            as: .image(precision: 0.98, layout: .fixed(width: 820, height: 128))
        )
    }

    func testRunningConflictCardCompactDark() {
        assertSnapshot(
            of: makeCard(
                width: 390,
                height: 196,
                colorScheme: .dark,
                sourceIsRunning: true,
                availability: .available(lastTurnID: "turn-terminal")
            ),
            as: .image(precision: 0.98, layout: .fixed(width: 390, height: 196))
        )
    }

    func testIdleConflictCardIPhone390Light() {
        assertSnapshot(
            of: makeCard(
                width: 390,
                height: 196,
                colorScheme: .light,
                sourceIsRunning: false,
                availability: .available(lastTurnID: nil)
            ),
            as: .image(precision: 0.98, layout: .fixed(width: 390, height: 196))
        )
    }

    func testRunningConflictCardIPhone320Dark() {
        assertSnapshot(
            of: makeCard(
                width: 320,
                height: 240,
                colorScheme: .dark,
                sourceIsRunning: true,
                availability: .available(lastTurnID: "turn-terminal")
            ),
            as: .image(precision: 0.98, layout: .fixed(width: 320, height: 240))
        )
    }

    func testNoTerminalTurnUsesAccessibleLayeredLayout() {
        assertSnapshot(
            of: makeCard(
                width: 390,
                height: 330,
                colorScheme: .light,
                dynamicTypeSize: .accessibility3,
                sourceIsRunning: true,
                availability: .unavailableNoTerminalTurn
            ),
            as: .image(precision: 0.98, layout: .fixed(width: 390, height: 330))
        )
    }

    func testLongEnglishFailureRemainsInline() {
        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: AppLanguage.preferenceKey)
        defer {
            UserDefaults.standard.set(
                AppLanguage.simplifiedChinese.rawValue,
                forKey: AppLanguage.preferenceKey
            )
        }

        assertSnapshot(
            of: makeCard(
                width: 390,
                height: 292,
                colorScheme: .dark,
                sourceIsRunning: true,
                availability: .failed,
                errorMessage: "Could not verify the last completed turn because the shared App Server did not respond."
            ),
            as: .image(precision: 0.98, layout: .fixed(width: 390, height: 292))
        )
    }

    private func makeCard(
        width: CGFloat,
        height: CGFloat,
        colorScheme: ColorScheme,
        dynamicTypeSize: DynamicTypeSize = .large,
        sourceIsRunning: Bool,
        availability: WriterConflictForkAvailability?,
        errorMessage: String? = nil
    ) -> some View {
        let suiteName = "WriterConflictCardSnapshotTests.Theme.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let themeStore = ThemeStore(defaults: defaults)
        themeStore.mode = colorScheme == .dark ? .dark : .light
        let tokens = themeStore.tokens(for: colorScheme)

        return WriterConflictCard(
            sourceIsRunning: sourceIsRunning,
            availability: availability,
            errorMessage: errorMessage,
            isDuplicating: false,
            isRetrying: false,
            onFork: {},
            onRecheck: {},
            onRetry: {}
        )
        .environmentObject(themeStore)
        .environment(\.colorScheme, colorScheme)
        .environment(\.dynamicTypeSize, dynamicTypeSize)
        .environment(\.horizontalSizeClass, width < 600 ? .compact : .regular)
        .padding(20)
        .frame(width: width, height: height, alignment: .top)
        .background(tokens.background)
    }
}
