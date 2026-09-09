import SnapshotTesting
import SwiftUI
import UIKit
import XCTest
@testable import MimiRemote

/// 偏好设置行的两种形态各拍一张：行内胶囊要能就地看出当前值和可选项，
/// 整页选择器要能逐条读到说明。
@MainActor
final class SettingsChoiceRowSnapshotTests: XCTestCase {
    private let cardWidth: CGFloat = 361

    override func setUpWithError() throws {
        try super.setUpWithError()
        try SnapshotTestEnvironment.requireFixedSimulator()
    }

    func testInlineChoiceRowsOnCompactWidth() {
        let themeStore = makeThemeStore()

        let view = VStack(alignment: .leading, spacing: 0) {
            StatefulChoiceRow(
                title: "语言",
                systemImage: "globe",
                options: AppLanguage.allCases,
                initial: AppLanguage.system
            )
            Divider().padding(.leading, 40)
            StatefulChoiceRow(
                title: "语音输入",
                systemImage: "waveform",
                options: VoiceInputProvider.allCases,
                initial: VoiceInputProvider.apple
            )
        }
        .padding(.horizontal, 16)
        // 行本身不画底色，靠 Form 的页面底色。快照必须补上同一块底色，
        // 否则深色基线会变成「深色文字色画在白画布上」，看着全是错的。
        .background(themeStore.tokens(for: .light).background)
        .environmentObject(themeStore)
        .environment(\.colorScheme, .light)
        .frame(width: cardWidth)
        .fixedSize(horizontal: false, vertical: true)

        assert(view, named: "inline-rows-compact")
    }

    /// 默认权限的四个模式带 detail，是这次改造要救回来的核心文案。
    func testPermissionOptionPageShowsEveryDetail() {
        let themeStore = makeThemeStore()

        let view = NavigationStack {
            StatefulOptionList(
                title: "默认权限",
                options: ComposerPermissionMode.allCases,
                initial: ComposerPermissionMode.fullAccess
            )
        }
        .environmentObject(themeStore)
        .environment(\.colorScheme, .light)
        .frame(width: 402, height: 560)

        assert(view, named: "permission-page-compact", layout: .fixed(width: 402, height: 560))
    }

    func testInlineChoiceRowsInDarkAppearance() {
        let themeStore = makeThemeStore()

        let view = StatefulChoiceRow(
            title: "语音输入",
            systemImage: "waveform",
            options: VoiceInputProvider.allCases,
            initial: VoiceInputProvider.codex
        )
        .padding(.horizontal, 16)
        .background(themeStore.tokens(for: .dark).background)
        .environmentObject(themeStore)
        .environment(\.colorScheme, .dark)
        .frame(width: cardWidth)
        .fixedSize(horizontal: false, vertical: true)

        assert(view, named: "inline-rows-dark")
    }

    func testLongTitlesAndValuesAtAccessibilitySize() {
        let themeStore = makeThemeStore()
        let view = VStack(alignment: .leading, spacing: 0) {
            SettingsValueLabel(
                title: "Default model for new conversations",
                value: "A model with a deliberately long display name",
                systemImage: "sparkles"
            )
            Divider()
            SettingsValueLabel(
                title: "新会话的默认权限设置",
                value: "允许访问当前工作区中的全部文件",
                systemImage: "lock.shield"
            )
            Divider()
            StatefulChoiceRow(
                title: "语音输入",
                systemImage: "waveform",
                options: VoiceInputProvider.allCases,
                initial: VoiceInputProvider.apple
            )
        }
        .padding(.horizontal, 16)
        .background(themeStore.tokens(for: .dark).background)
        .environmentObject(themeStore)
        .environment(\.colorScheme, .dark)
        .environment(\.dynamicTypeSize, .accessibility2)
        .frame(width: cardWidth)
        .fixedSize(horizontal: false, vertical: true)

        assert(view, named: "long-text-accessibility-dark")
    }

    private func makeThemeStore() -> ThemeStore {
        let suite = "SettingsChoiceRowSnapshotTests.Theme.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return ThemeStore(defaults: defaults)
    }

    private func assert<V: View>(
        _ view: V,
        named name: String,
        layout: SwiftUISnapshotLayout = .sizeThatFits,
        file: StaticString = #file,
        testName: String = #function,
        line: UInt = #line
    ) {
        if let failure = verifySnapshot(
            of: view,
            as: .wait(
                for: 0.5,
                on: .image(
                    drawHierarchyInKeyWindow: true,
                    precision: 0.98,
                    layout: layout
                )
            ),
            named: name,
            snapshotDirectory: referenceSnapshotDirectory,
            file: file,
            testName: testName,
            line: line
        ) {
            XCTFail(failure, file: file, line: line)
        }
    }

    private var referenceSnapshotDirectory: String? {
        #if targetEnvironment(simulator)
        // 模拟器保留源码目录路径，方便本地重新录制基线。
        nil
        #else
        // 真机不能访问 Mac 源码目录；Xcode 会把基线平铺复制进测试 Bundle。
        Bundle(for: Self.self).bundlePath
        #endif
    }
}

/// SettingsChoiceRow 取 Binding；快照里用一层薄壳持有选中态。
private struct StatefulChoiceRow<Option: SettingsChoiceOption>: View {
    let title: String
    let systemImage: String
    let options: [Option]
    @State var selection: Option

    init(title: String, systemImage: String, options: [Option], initial: Option) {
        self.title = title
        self.systemImage = systemImage
        self.options = options
        _selection = State(initialValue: initial)
    }

    var body: some View {
        SettingsChoiceRow(
            title: title,
            systemImage: systemImage,
            options: options,
            selection: $selection
        )
    }
}

private struct StatefulOptionList<Option: SettingsChoiceOption>: View {
    let title: String
    let options: [Option]
    @State var selection: Option

    init(title: String, options: [Option], initial: Option) {
        self.title = title
        self.options = options
        _selection = State(initialValue: initial)
    }

    var body: some View {
        SettingsOptionListView(
            title: title,
            options: options,
            selection: $selection
        )
    }
}
