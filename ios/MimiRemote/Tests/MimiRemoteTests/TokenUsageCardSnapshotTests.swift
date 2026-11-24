import SnapshotTesting
import SwiftUI
import UIKit
import XCTest
@testable import MimiRemote

/// Token 使用量卡片只展示多运行时配额环（或单窗口进度条）。
/// 这里只拍卡片本体，覆盖双/三运行时圆环、纯 Gemini 两环、单窗口进度条、空态及深色模式。
@MainActor
final class TokenUsageCardSnapshotTests: XCTestCase {
    /// iPhone 15/17 Pro 竖屏下卡片的实际可用宽度：屏宽 393 减去列表左右各 16。
    private let compactCardWidth: CGFloat = 361
    /// iPad detail 列下卡片的宽屏展示宽度。
    private let regularCardWidth: CGFloat = 700

    override func setUpWithError() throws {
        try super.setUpWithError()
        try SnapshotTestEnvironment.requireFixedSimulator()
    }

    func testMultiAgentRingsOnCompactWidth() {
        assertCard(
            named: "multi-agent-compact",
            includesCodex: true,
            includesClaude: true,
            includesAgy: true,
            width: compactCardWidth
        )
    }

    func testMultiAgentRingsOnRegularWidth() {
        assertCard(
            named: "multi-agent-regular",
            includesCodex: true,
            includesClaude: true,
            includesAgy: true,
            width: regularCardWidth
        )
    }

    func testCodexAndGeminiRingsOnCompactWidth() {
        assertCard(
            named: "codex-gemini-compact",
            includesCodex: true,
            includesClaude: false,
            includesAgy: true,
            width: compactCardWidth
        )
    }

    /// 仅启用 Gemini 时画两环，不留多余的空灰内轨。
    func testGeminiOnlyTwoRingsOnCompactWidth() {
        assertCard(
            named: "gemini-only-compact",
            includesCodex: false,
            includesClaude: false,
            includesAgy: true,
            width: compactCardWidth
        )
    }

    /// 只接入 Codex 单窗口时退化成一条占满宽度的进度条。
    func testSingleWindowUsesProgressBarOnCompactWidth() {
        assertCard(
            named: "single-window-compact",
            includesCodex: true,
            includesClaude: false,
            includesAgy: false,
            width: compactCardWidth
        )
    }

    func testSingleWindowUsesProgressBarOnRegularWidth() {
        assertCard(
            named: "single-window-regular",
            includesCodex: true,
            includesClaude: false,
            includesAgy: false,
            width: regularCardWidth
        )
    }

    func testEmptyQuotaShowsFallbackText() {
        assertCard(
            named: "empty-quota-compact",
            codexDisplay: Self.emptyDisplay(name: "Codex"),
            claudeDisplay: Self.emptyDisplay(name: "Claude"),
            agyDisplay: Self.emptyDisplay(name: "Gemini"),
            includesCodex: true,
            includesClaude: false,
            includesAgy: true,
            width: compactCardWidth
        )
    }

    func testMultiAgentRingsInDarkAppearance() {
        assertCard(
            named: "multi-agent-compact-dark",
            includesCodex: true,
            includesClaude: true,
            includesAgy: true,
            width: compactCardWidth,
            colorScheme: .dark
        )
    }

    private func assertCard(
        named name: String,
        codexDisplay: CodexUsageWindowsDisplay = codexDisplay,
        claudeDisplay: CodexUsageWindowsDisplay = claudeDisplay,
        agyDisplay: CodexUsageWindowsDisplay = agyDisplay,
        includesCodex: Bool = true,
        includesClaude: Bool = true,
        includesAgy: Bool = false,
        isRefreshing: Bool = false,
        width: CGFloat,
        colorScheme: ColorScheme = .light,
        file: StaticString = #file,
        testName: String = #function,
        line: UInt = #line
    ) {
        let themeDefaultsSuite = "TokenUsageCardSnapshotTests.Theme.\(UUID().uuidString)"
        let themeDefaults = UserDefaults(suiteName: themeDefaultsSuite)!
        themeDefaults.removePersistentDomain(forName: themeDefaultsSuite)
        // 固定 frame 宽度不会改变 iPad 继承的 trait；快照必须显式模拟目标尺寸类别。
        let horizontalSizeClass: UserInterfaceSizeClass = width == compactCardWidth
            ? .compact
            : .regular

        let themeStore = ThemeStore(defaults: themeDefaults)
        let view = AccountTokenUsageCard(
            codexDisplay: codexDisplay,
            claudeDisplay: claudeDisplay,
            includesCodex: includesCodex,
            includesClaude: includesClaude,
            agyDisplay: agyDisplay,
            includesAgy: includesAgy,
            isRefreshing: isRefreshing,
            onRefresh: {}
        )
        .environmentObject(themeStore)
        .environment(\.colorScheme, colorScheme)
        .environment(\.horizontalSizeClass, horizontalSizeClass)
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        // 「我的」页里这张卡的底色由所在分组给出（#615），快照补上同一块卡片底色。
        .background(themeStore.tokens(for: colorScheme).settingsGroupBackground)

        if let failure = verifySnapshot(
            of: view,
            as: .wait(
                for: 0.5,
                on: .image(
                    drawHierarchyInKeyWindow: true,
                    precision: 0.98,
                    layout: .sizeThatFits
                )
            ),
            named: name,
            snapshotDirectory: Self.referenceSnapshotDirectory,
            file: file,
            testName: testName,
            line: line
        ) {
            XCTFail(failure, file: file, line: line)
        }
    }

    private static let codexDisplay = CodexUsageWindowsDisplay(
        displayName: "Codex",
        creditText: "",
        windows: [
            window(kind: .secondary, durationMinutes: 7 * 24 * 60, label: "7d", progress: 0.72, providerName: "Codex")
        ],
        hasLiveData: true
    )

    private static let claudeDisplay = CodexUsageWindowsDisplay(
        displayName: "Claude",
        creditText: "",
        windows: [
            window(kind: .primary, durationMinutes: 5 * 60, label: "5h", progress: 0.12, providerName: "Claude"),
            window(kind: .secondary, durationMinutes: 7 * 24 * 60, label: "7d", progress: 0.01, providerName: "Claude")
        ],
        hasLiveData: true
    )

    private static let agyDisplay = CodexUsageWindowsDisplay(
        displayName: "Gemini",
        creditText: "",
        windows: [
            window(kind: .primary, durationMinutes: 5 * 60, label: "5h", progress: 0.02, providerName: "Gemini"),
            window(kind: .secondary, durationMinutes: 7 * 24 * 60, label: "7d", progress: 0.29, providerName: "Gemini")
        ],
        hasLiveData: true
    )

    private static func emptyDisplay(name: String) -> CodexUsageWindowsDisplay {
        CodexUsageWindowsDisplay.make(rateLimit: nil, fallbackDisplayName: name)
    }

    private static func window(
        kind: CodexUsageWindowKind,
        durationMinutes: Int,
        label: String,
        progress: Double,
        providerName: String
    ) -> CodexUsageWindowDisplay {
        CodexUsageWindowDisplay(
            kind: kind,
            durationMinutes: durationMinutes,
            label: label,
            title: label,
            usedPercentText: "\(Int((progress * 100).rounded()))%",
            progress: progress,
            resetDate: nil,
            // 重置时间会和窗口名同排一行；留空的话这条布局就没有基线守着。
            resetText: "8/12 18:12 重置",
            isNearLimit: progress >= CodexUsageWindowDisplay.nearLimitThreshold,
            isExhausted: false,
            providerName: providerName
        )
    }

    private static var referenceSnapshotDirectory: String? {
        #if targetEnvironment(simulator)
        // 模拟器保留源码目录路径，方便本地重新录制基线。
        nil
        #else
        // 真机不能访问 Mac 源码目录；Xcode 会把基线平铺复制进测试 Bundle。
        Bundle(for: Self.self).bundlePath
        #endif
    }
}
