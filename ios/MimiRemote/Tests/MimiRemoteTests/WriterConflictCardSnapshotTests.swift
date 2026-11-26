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
                height: 112,
                colorScheme: .light,
                sourceIsRunning: false,
                availability: .available(lastTurnID: nil)
            ),
            as: .image(precision: 0.98, layout: .fixed(width: 820, height: 112))
        )
    }

    func testRunningConflictCardCompactDark() {
        assertSnapshot(
            of: makeCard(
                width: 390,
                height: 164,
                colorScheme: .dark,
                sourceIsRunning: true,
                availability: .available(lastTurnID: "turn-terminal")
            ),
            as: .image(precision: 0.98, layout: .fixed(width: 390, height: 164))
        )
    }

    func testIdleConflictCardIPhone390Light() {
        assertSnapshot(
            of: makeCard(
                width: 390,
                height: 164,
                colorScheme: .light,
                sourceIsRunning: false,
                availability: .available(lastTurnID: nil)
            ),
            as: .image(precision: 0.98, layout: .fixed(width: 390, height: 164))
        )
    }

    func testRunningConflictCardIPhone320Dark() {
        assertSnapshot(
            of: makeCard(
                width: 320,
                height: 196,
                colorScheme: .dark,
                sourceIsRunning: true,
                availability: .available(lastTurnID: "turn-terminal")
            ),
            as: .image(precision: 0.98, layout: .fixed(width: 320, height: 196))
        )
    }

    func testNoTerminalTurnUsesAccessibleLayeredLayout() {
        assertSnapshot(
            of: makeCard(
                width: 390,
                height: 520,
                colorScheme: .light,
                dynamicTypeSize: .accessibility3,
                sourceIsRunning: true,
                availability: .unavailableNoTerminalTurn
            ),
            as: .image(precision: 0.98, layout: .fixed(width: 390, height: 520))
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
                height: 256,
                colorScheme: .dark,
                sourceIsRunning: true,
                availability: .failed,
                errorMessage: "Could not verify the last completed turn because the shared App Server did not respond."
            ),
            as: .image(precision: 0.98, layout: .fixed(width: 390, height: 256))
        )
    }

    func testSharedGuideSheetCompactLight() async throws {
        let image = try await renderGuideSheetInWindow(
            size: CGSize(width: 390, height: 600),
            sourceIsRunning: false,
            availability: .available(lastTurnID: nil)
        )
        assertSnapshot(of: image, as: .image(precision: 0.98))
    }

    func testSharedGuideSheetNarrowAccessibility3() async throws {
        let image = try await renderGuideSheetInWindow(
            size: CGSize(width: 320, height: 640),
            dynamicTypeSize: .accessibility3,
            sourceIsRunning: true,
            availability: .available(lastTurnID: "turn-terminal")
        )
        assertSnapshot(of: image, as: .image(precision: 0.98))
    }

    private func renderGuideSheetInWindow(
        size: CGSize,
        dynamicTypeSize: DynamicTypeSize = .large,
        sourceIsRunning: Bool,
        availability: WriterConflictForkAvailability?
    ) async throws -> UIImage {
        let suiteName = "WriterConflictCardSnapshotTests.Guide.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let themeStore = ThemeStore(defaults: defaults)
        themeStore.mode = .light

        let view = WriterConflictSharedGuideSheet(
            sourceIsRunning: sourceIsRunning,
            availability: availability
        )
        .environmentObject(themeStore)
        .environment(\.colorScheme, .light)
        .environment(\.dynamicTypeSize, dynamicTypeSize)
        .environment(\.horizontalSizeClass, .compact)

        // NavigationStack + Toolbar 在 iOS 26 离屏快照下无法稳定同步导航栏浅色外观与完成按钮；
        // 放进显式浅色 UIWindow 并以 drawHierarchy 截取，确保 iOS 26/27 导航栏与按钮一致。
        let host = UIHostingController(rootView: view)
        host.overrideUserInterfaceStyle = .light
        host.safeAreaRegions = []
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .light
        window.traitOverrides.horizontalSizeClass = .compact
        window.rootViewController = host
        let animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
            UIView.setAnimationsEnabled(animationsWereEnabled)
        }

        host.view.frame = window.bounds
        for _ in 0..<20 {
            window.layoutIfNeeded()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(16))
        }
        return UIGraphicsImageRenderer(size: size).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
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
