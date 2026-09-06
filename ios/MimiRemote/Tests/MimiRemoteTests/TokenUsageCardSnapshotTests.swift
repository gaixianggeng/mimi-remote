import SnapshotTesting
import SwiftUI
import UIKit
import XCTest
@testable import MimiRemote

/// Token 卡片的四个状态各自有独立布局分支，最容易在改动中回归成空白或跳高。
/// 这里只拍卡片本体，不拍整页——「我的」页后续还要重排，整页基线会被无关改动打翻。
@MainActor
final class TokenUsageCardSnapshotTests: XCTestCase {
    /// iPhone 15/17 Pro 竖屏下卡片的实际可用宽度：屏宽 393 减去列表左右各 16。
    private let compactCardWidth: CGFloat = 361
    /// iPad detail 列里卡片会走宽屏左右分栏分支。
    private let regularCardWidth: CGFloat = 700

    override func setUpWithError() throws {
        try super.setUpWithError()
        try SnapshotTestEnvironment.requireFixedSimulator()
    }

    func testLoadedActivityOnCompactWidth() {
        assertCard(
            named: "loaded-compact",
            activity: .loaded(buckets: Self.sampleBuckets, asOf: Self.referenceDate),
            snapshot: Self.sampleSnapshot,
            width: compactCardWidth
        )
    }

    func testLoadedActivityOnRegularWidth() {
        assertCard(
            named: "loaded-regular",
            activity: .loaded(buckets: Self.sampleBuckets, asOf: Self.referenceDate),
            snapshot: Self.sampleSnapshot,
            width: regularCardWidth
        )
    }

    /// 只接入 Codex 时配额退化成进度条。这是一条独立分支，窄宽都要守住。
    func testSingleWindowUsesProgressBarOnCompactWidth() {
        assertCard(
            named: "single-window-compact",
            activity: .loaded(buckets: Self.sampleBuckets, asOf: Self.referenceDate),
            snapshot: Self.sampleSnapshot,
            includesClaude: false,
            width: compactCardWidth
        )
    }

    /// 宽屏下单窗口必须仍然上下排：一条进度条撑不起左右分栏的左栏。
    func testSingleWindowStaysStackedOnRegularWidth() {
        assertCard(
            named: "single-window-regular",
            activity: .loaded(buckets: Self.sampleBuckets, asOf: Self.referenceDate),
            snapshot: Self.sampleSnapshot,
            includesClaude: false,
            width: regularCardWidth
        )
    }

    func testLoadingActivityKeepsCardHeight() {
        assertCard(
            named: "loading-compact",
            activity: .loading,
            snapshot: nil,
            isRefreshing: true,
            width: compactCardWidth
        )
    }

    func testEmptyActivityDrawsInactiveGrid() {
        assertCard(
            named: "empty-compact",
            activity: .empty(asOf: Self.referenceDate),
            snapshot: Self.sampleSnapshot,
            width: compactCardWidth
        )
    }

    /// 主机不提供历史时不能画出任何格子，否则等于暗示“有历史但都是空的”。
    func testUnsupportedActivityShowsExplanation() {
        assertCard(
            named: "unsupported-compact",
            activity: .unsupported,
            snapshot: Self.sampleSnapshot,
            width: compactCardWidth
        )
    }

    /// 失败但手上有旧数据时继续画旧网格，并且必须带过期标注。
    func testFailedActivityWithPreviousResultMarksStale() {
        assertCard(
            named: "failed-stale-compact",
            activity: .failed(
                previous: AccountTokenActivityState.Previous(
                    buckets: Self.sampleBuckets,
                    asOf: Self.referenceDate
                )
            ),
            snapshot: Self.sampleSnapshot,
            width: compactCardWidth
        )
    }

    /// 从没成功过就失败：只给失败态，不能显示伪造的空网格或零值累计。
    func testFailedActivityWithoutPreviousResult() {
        assertCard(
            named: "failed-empty-compact",
            activity: .failed(previous: nil),
            snapshot: nil,
            width: compactCardWidth
        )
    }

    func testLoadedActivityInDarkAppearance() {
        assertCard(
            named: "loaded-compact-dark",
            activity: .loaded(buckets: Self.sampleBuckets, asOf: Self.referenceDate),
            snapshot: Self.sampleSnapshot,
            width: compactCardWidth,
            colorScheme: .dark
        )
    }

    private func assertCard(
        named name: String,
        activity: AccountTokenActivityState,
        snapshot: AccountTokenUsageSnapshot?,
        isRefreshing: Bool = false,
        includesClaude: Bool = true,
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

        let view = AccountTokenUsageCard(
            codexDisplay: Self.codexDisplay,
            claudeDisplay: Self.claudeDisplay,
            includesClaude: includesClaude,
            snapshot: snapshot,
            activity: activity,
            isRefreshing: isRefreshing,
            onRefresh: {}
        )
        .environmentObject(ThemeStore(defaults: themeDefaults))
        .environment(\.colorScheme, colorScheme)
        .environment(\.horizontalSizeClass, horizontalSizeClass)
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)

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

    private static let referenceDate = Date(timeIntervalSince1970: 1_785_105_600)

    private static let sampleSnapshot = AccountTokenUsageSnapshot(
        summary: AccountTokenUsageSummary(lifetimeTokens: 50_160_000_000),
        dailyUsageBuckets: sampleBuckets
    )

    /// 固定日期与用量，基线不随运行日期漂移。
    private static let sampleBuckets: [AccountTokenUsageDailyBucket] = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        return (0..<120).compactMap { daysAgo in
            guard daysAgo % 7 != 3,
                  let date = calendar.date(
                      byAdding: .day,
                      value: -daysAgo,
                      to: referenceDate
                  )
            else {
                return nil
            }
            let wave = Int64((daysAgo * 37) % 11 + 1)
            return AccountTokenUsageDailyBucket(
                startDate: formatter.string(from: date),
                tokens: wave * wave * 1_800_000
            )
        }
    }()

    // 17% / 99% / 88% 对应 Issue 截图里的实际读数，方便比对改版前后的信息层级。
    private static let codexDisplay = CodexUsageWindowsDisplay(
        displayName: "Codex",
        creditText: "",
        windows: [
            window(kind: .secondary, durationMinutes: 7 * 24 * 60, label: "7d", progress: 0.83, providerName: "Codex")
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
