import SwiftUI
import UIKit
import XCTest
@testable import MimiRemote

@MainActor
final class ThemeStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ThemeStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultAppearanceStateUsesSafeMVPValues() {
        let store = ThemeStore(defaults: defaults)

        XCTAssertEqual(store.mode, .system)
        XCTAssertEqual(store.mode.subtitle, L10n.text("ui.follow_the_current_device_appearance"))
        XCTAssertEqual(store.preset, .codex)
        XCTAssertEqual(store.uiFontPreset, .system)
        XCTAssertEqual(store.codeFontPreset, .systemMono)
        XCTAssertEqual(store.fontScale, ThemeStore.defaultFontScale)
        XCTAssertNil(store.preferredColorScheme)

        let tokens = store.tokens(for: .light)
        XCTAssertEqual(tokens.preset, .codex)
        XCTAssertEqual(tokens.resolvedScheme, .light)
    }

    func testPersistsAppearancePreferences() {
        let store = ThemeStore(defaults: defaults)

        store.mode = .dark
        store.preset = .gruvbox
        store.uiFontPreset = .rounded
        store.codeFontPreset = .menlo
        store.setFontScale(1.20)

        let restored = ThemeStore(defaults: defaults)
        XCTAssertEqual(restored.mode, .dark)
        XCTAssertEqual(restored.preset, .gruvbox)
        XCTAssertEqual(restored.uiFontPreset, .rounded)
        XCTAssertEqual(restored.codeFontPreset, .menlo)
        XCTAssertEqual(restored.fontScale, 1.20, accuracy: 0.001)
        XCTAssertEqual(restored.preferredColorScheme, .dark)
    }

    func testInvalidStoredValuesFallBackToDefaults() {
        defaults.set("broken", forKey: "appearance.theme.mode")
        defaults.set("unknown", forKey: "appearance.theme.preset")
        defaults.set("comic-sans", forKey: "appearance.theme.uiFont")
        defaults.set("terminal", forKey: "appearance.theme.codeFont")
        defaults.set(99.0, forKey: "appearance.theme.fontScale")

        let store = ThemeStore(defaults: defaults)

        XCTAssertEqual(store.mode, .system)
        XCTAssertEqual(store.preset, .codex)
        XCTAssertEqual(store.uiFontPreset, .system)
        XCTAssertEqual(store.codeFontPreset, .systemMono)
        XCTAssertEqual(store.fontScale, ThemeStore.maximumFontScale)
    }

    func testFontScaleClampsToSupportedRange() {
        let store = ThemeStore(defaults: defaults)

        store.setFontScale(0.1)
        XCTAssertEqual(store.fontScale, ThemeStore.minimumFontScale)

        store.setFontScale(9.0)
        XCTAssertEqual(store.fontScale, ThemeStore.maximumFontScale)
    }

    func testCompactIPadUsesLargerDefaultWhenNoPreferenceWasSaved() {
        let store = ThemeStore(defaults: defaults)
        let originalVersion = store.themeVersion

        store.applyDeviceDefaultFontScale(
            isPad: true,
            screenSize: CGSize(width: 744, height: 1_133)
        )

        XCTAssertEqual(store.fontScale, ThemeStore.compactIPadDefaultFontScale, accuracy: 0.001)
        XCTAssertNil(defaults.object(forKey: ThemeStore.fontScaleStorageKey))
        XCTAssertGreaterThan(store.themeVersion, originalVersion)
    }

    func testDeviceDefaultOnlyAppliesToCompactPhysicalIPadScreen() {
        XCTAssertEqual(
            ThemeStore.defaultFontScale(isPad: true, screenSize: CGSize(width: 768, height: 1_024)),
            ThemeStore.compactIPadDefaultFontScale,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ThemeStore.defaultFontScale(isPad: true, screenSize: CGSize(width: 820, height: 1_180)),
            ThemeStore.defaultFontScale,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ThemeStore.defaultFontScale(isPad: false, screenSize: CGSize(width: 744, height: 1_133)),
            ThemeStore.defaultFontScale,
            accuracy: 0.001
        )
    }

    func testSavedFontScaleWinsOverCompactIPadDefault() {
        defaults.set(1.0, forKey: ThemeStore.fontScaleStorageKey)
        let store = ThemeStore(defaults: defaults)

        store.applyDeviceDefaultFontScale(
            isPad: true,
            screenSize: CGSize(width: 744, height: 1_133)
        )

        XCTAssertEqual(store.fontScale, 1.0, accuracy: 0.001)
    }

    func testResetReturnsToResolvedCompactIPadDefaultWithoutSavingAnOverride() {
        let store = ThemeStore(defaults: defaults)
        store.applyDeviceDefaultFontScale(
            isPad: true,
            screenSize: CGSize(width: 744, height: 1_133)
        )
        store.setFontScale(0.9)

        store.reset()

        XCTAssertEqual(store.fontScale, ThemeStore.compactIPadDefaultFontScale, accuracy: 0.001)
        XCTAssertNil(defaults.object(forKey: ThemeStore.fontScaleStorageKey))
    }

    func testResetPersistsDefaults() {
        let store = ThemeStore(defaults: defaults)
        store.mode = .dark
        store.preset = .xcode
        store.uiFontPreset = .serif
        store.codeFontPreset = .menlo
        store.setFontScale(1.25)

        store.reset()

        let restored = ThemeStore(defaults: defaults)
        XCTAssertEqual(restored.mode, .system)
        XCTAssertEqual(restored.preset, .codex)
        XCTAssertEqual(restored.uiFontPreset, .system)
        XCTAssertEqual(restored.codeFontPreset, .systemMono)
        XCTAssertEqual(restored.fontScale, ThemeStore.defaultFontScale)
    }

    func testResetResolvesToCurrentSystemColorScheme() {
        let store = ThemeStore(defaults: defaults)
        store.mode = .light

        store.reset()

        XCTAssertNil(store.preferredColorScheme)
        XCTAssertEqual(store.resolvedColorScheme(for: .dark), .dark)
        XCTAssertEqual(store.tokens(for: .dark).resolvedScheme, .dark)
    }

    func testTokenSelectionUsesPresetAndResolvedScheme() {
        let store = ThemeStore(defaults: defaults)
        store.mode = .system
        store.preset = .xcode

        XCTAssertEqual(store.tokens(for: .light).preset, .xcode)
        XCTAssertEqual(store.tokens(for: .light).resolvedScheme, .light)
        XCTAssertEqual(store.tokens(for: .dark).resolvedScheme, .dark)

        store.mode = .light
        XCTAssertEqual(store.tokens(for: .dark).resolvedScheme, .light)

        store.mode = .dark
        XCTAssertEqual(store.tokens(for: .light).resolvedScheme, .dark)
    }

    func testDefaultCodexPresetUsesNotionNeutralPalettes() {
        let store = ThemeStore(defaults: defaults)

        let lightTokens = store.tokens(for: .light)
        let darkTokens = store.tokens(for: .dark)
        let lightBackground = rgba(lightTokens.background)
        let lightSurface = rgba(lightTokens.surface)
        let lightElevatedSurface = rgba(lightTokens.elevatedSurface)
        let lightAccent = rgba(lightTokens.accent)
        let lightSuccess = rgba(lightTokens.success)
        let lightUserBubble = rgba(lightTokens.userBubble)
        let lightSidebarBackground = rgba(lightTokens.sidebarBackground)
        let lightSidebarSurfaceBackground = rgba(lightTokens.sidebarSurfaceBackground)
        let lightSidebarHoverFill = rgba(lightTokens.sidebarHoverFill)
        let lightInputBackground = rgba(lightTokens.inputBackground)
        let lightConversationCanvasBackground = rgba(lightTokens.conversationCanvasBackground)
        let lightConversationPrimaryText = rgba(lightTokens.conversationPrimaryText)
        let lightConversationSecondaryText = rgba(lightTokens.conversationSecondaryText)
        let lightConversationTertiaryText = rgba(lightTokens.conversationTertiaryText)
        let lightComposerControlSurface = rgba(lightTokens.composerControlSurface)
        let lightComposerInactiveActionSurface = rgba(lightTokens.composerInactiveActionSurface)
        let lightPlanCardBackground = rgba(lightTokens.planCardBackground)
        let lightPlanCardBorder = rgba(lightTokens.planCardBorder)
        let lightBorder = rgba(lightTokens.border)
        let lightSelectionFill = rgba(lightTokens.selectionFill)
        let lightSecondaryText = rgba(lightTokens.secondaryText)
        let codexSwatchForeground = rgba(ThemePreset.codex.swatchForeground)
        let codexSwatchBackground = rgba(ThemePreset.codex.swatchBackground)
        let darkBackground = rgba(darkTokens.background)
        let darkSurface = rgba(darkTokens.surface)
        let darkElevatedSurface = rgba(darkTokens.elevatedSurface)
        let darkAccent = rgba(darkTokens.accent)
        let darkSuccess = rgba(darkTokens.success)
        let darkUserBubble = rgba(darkTokens.userBubble)
        let darkSidebarBackground = rgba(darkTokens.sidebarBackground)
        let darkSidebarSurfaceBackground = rgba(darkTokens.sidebarSurfaceBackground)
        let darkSidebarHoverFill = rgba(darkTokens.sidebarHoverFill)
        let darkInputBackground = rgba(darkTokens.inputBackground)
        let darkConversationCanvasBackground = rgba(darkTokens.conversationCanvasBackground)
        let darkComposerControlSurface = rgba(darkTokens.composerControlSurface)
        let darkComposerInactiveActionSurface = rgba(darkTokens.composerInactiveActionSurface)
        let darkPlanCardBackground = rgba(darkTokens.planCardBackground)
        let darkPlanCardBorder = rgba(darkTokens.planCardBorder)
        let darkBorder = rgba(darkTokens.border)
        let darkSelectionFill = rgba(darkTokens.selectionFill)
        let darkContentPanelBackground = rgba(darkTokens.contentPanelBackground)
        let darkWorkspaceCardSelectionFill = rgba(darkTokens.workspaceCardSelectionFill)
        let darkPrimaryText = rgba(darkTokens.primaryText)
        let darkSecondaryText = rgba(darkTokens.secondaryText)
        let darkTertiaryText = rgba(darkTokens.tertiaryText)

        XCTAssertEqual(ThemePreset.codex.title, L10n.text("ui.default"))
        XCTAssertEqual(ThemePreset.codex.subtitle, L10n.text("ui.notion_style_neutral_grays_without_accent_color"))

        // 取自 Notion iOS 浅色截图：页面、胶囊、选中与文字；侧栏和会话画布与页面同底。
        assertRGB(lightBackground, red: 250, green: 248, blue: 246)
        assertRGB(lightSidebarBackground, red: 250, green: 248, blue: 246)
        assertRGB(lightSidebarSurfaceBackground, red: 255, green: 255, blue: 255)
        assertRGB(lightSelectionFill, red: 236, green: 234, blue: 232)
        assertRGB(lightSidebarHoverFill, red: 240, green: 238, blue: 237)
        assertRGB(lightInputBackground, red: 255, green: 255, blue: 255)
        assertRGB(lightConversationCanvasBackground, red: 250, green: 248, blue: 246)
        assertRGB(lightConversationPrimaryText, red: 46, green: 44, blue: 42)
        assertRGB(lightConversationSecondaryText, red: 120, green: 119, blue: 116)
        assertRGB(lightConversationTertiaryText, red: 155, green: 154, blue: 151)
        assertRGB(lightComposerControlSurface, red: 240, green: 238, blue: 237)
        assertRGB(lightComposerInactiveActionSurface, red: 236, green: 234, blue: 232)
        assertRGB(lightPlanCardBackground, red: 255, green: 255, blue: 255)
        assertRGB(lightPlanCardBorder, red: 232, green: 230, blue: 227)
        assertRGB(lightBorder, red: 232, green: 230, blue: 227)
        assertRGB(lightSecondaryText, red: 120, green: 119, blue: 116)
        assertRGB(rgba(lightTokens.codeBlock), red: 240, green: 238, blue: 237)
        assertRGB(rgba(lightTokens.codeText), red: 46, green: 44, blue: 42)
        XCTAssertGreaterThan(lightSurface.red, 0.99)
        XCTAssertGreaterThan(lightSurface.green, 0.99)
        XCTAssertGreaterThan(lightSurface.blue, 0.99)
        XCTAssertEqual(lightTokens.assistantBubble, .white)
        XCTAssertGreaterThan(lightElevatedSurface.red, lightElevatedSurface.blue)
        XCTAssertLessThan(abs(lightElevatedSurface.red - lightElevatedSurface.blue), 0.12)

        XCTAssertEqual(lightElevatedSurface.red, lightUserBubble.red, accuracy: 0.001)
        XCTAssertEqual(lightElevatedSurface.green, lightUserBubble.green, accuracy: 0.001)
        XCTAssertEqual(lightElevatedSurface.blue, lightUserBubble.blue, accuracy: 0.001)
        XCTAssertEqual(codexSwatchBackground.red, lightBackground.red, accuracy: 0.001)
        XCTAssertEqual(codexSwatchBackground.green, lightBackground.green, accuracy: 0.001)
        XCTAssertEqual(codexSwatchBackground.blue, lightBackground.blue, accuracy: 0.001)
        XCTAssertGreaterThan(lightSuccess.green, lightSuccess.red)
        XCTAssertGreaterThan(lightSuccess.green, lightSuccess.blue)

        // 浅色主操作恢复产品紫色，用户气泡仍是中性的 Notion 胶囊灰。
        assertRGB(lightUserBubble, red: 240, green: 238, blue: 237)
        assertRGB(rgba(lightTokens.primaryAction), red: 74, green: 20, blue: 74)
        assertRGB(lightAccent, red: 74, green: 20, blue: 74)
        assertRGB(rgba(lightTokens.primaryActionForeground), red: 255, green: 255, blue: 255)
        // 列表标题：深色照 Notion 侧栏用浅灰，浅色与正文同色。
        assertRGB(rgba(darkTokens.listTitleText), red: 190, green: 189, blue: 187)
        assertRGB(rgba(lightTokens.listTitleText), red: 46, green: 44, blue: 42)
        // 浅色用原主色，深色用灰紫；用量图表和未读点保持同一档语义色。
        assertRGB(rgba(lightTokens.tokenActivityAccent), red: 74, green: 20, blue: 74)
        assertRGB(rgba(darkTokens.tokenActivityAccent), red: 119, green: 113, blue: 127)
        assertRGB(rgba(lightTokens.sessionUnreadAccent), red: 74, green: 20, blue: 74)
        assertRGB(rgba(darkTokens.sessionUnreadAccent), red: 119, green: 113, blue: 127)
        assertRGB(rgba(lightTokens.tokenActivityAxisText), red: 106, green: 105, blue: 102)
        // 默认深色照 Notion AI 圆钮：主操作与强调色同为无色相浅灰，配黑色前景。
        let darkPrimaryAction = rgba(darkTokens.primaryAction)
        assertRGB(darkPrimaryAction, red: 211, green: 211, blue: 211)
        assertRGB(darkAccent, red: 211, green: 211, blue: 211)
        assertRGB(rgba(darkTokens.primaryActionForeground), red: 0, green: 0, blue: 0)
        XCTAssertGreaterThan(lightUserBubble.alpha, 0.99)
        XCTAssertEqual(codexSwatchForeground.red, lightAccent.red, accuracy: 0.001)
        XCTAssertEqual(codexSwatchForeground.green, lightAccent.green, accuracy: 0.001)
        XCTAssertEqual(codexSwatchForeground.blue, lightAccent.blue, accuracy: 0.001)

        // 取自 Notion iOS 深色截图：页面、未选中胶囊、选中胶囊和两级文字直接对齐；
        // 卡片、输入/浮层和控件保留明确层级。
        assertRGB(darkBackground, red: 31, green: 31, blue: 31)
        assertRGB(darkSurface, red: 43, green: 43, blue: 41)
        assertRGB(darkElevatedSurface, red: 50, green: 50, blue: 50)
        assertRGB(darkSidebarBackground, red: 31, green: 31, blue: 31)
        assertRGB(darkSidebarSurfaceBackground, red: 35, green: 35, blue: 35)
        assertRGB(darkSidebarHoverFill, red: 43, green: 43, blue: 41)
        assertRGB(darkInputBackground, red: 50, green: 50, blue: 50)
        assertRGB(darkConversationCanvasBackground, red: 31, green: 31, blue: 31)
        assertRGB(darkComposerControlSurface, red: 61, green: 61, blue: 61)
        assertRGB(darkComposerInactiveActionSurface, red: 61, green: 61, blue: 61)
        assertRGB(darkPlanCardBackground, red: 43, green: 43, blue: 41)
        assertRGB(darkPlanCardBorder, red: 55, green: 55, blue: 53)
        assertRGB(darkBorder, red: 55, green: 55, blue: 53)
        assertRGB(darkSelectionFill, red: 55, green: 55, blue: 53)
        assertRGB(darkContentPanelBackground, red: 43, green: 43, blue: 41)
        assertRGB(darkWorkspaceCardSelectionFill, red: 55, green: 55, blue: 53)
        assertRGB(darkPrimaryText, red: 239, green: 239, blue: 237)
        assertRGB(darkSecondaryText, red: 171, green: 170, blue: 166)
        assertRGB(darkTertiaryText, red: 161, green: 160, blue: 157)
        XCTAssertLessThan(abs(darkBackground.red - darkBackground.blue), 0.02)
        XCTAssertLessThan(abs(darkSurface.red - darkSurface.blue), 0.04)
        XCTAssertLessThan(abs(darkElevatedSurface.red - darkElevatedSurface.blue), 0.04)
        XCTAssertGreaterThan(darkSuccess.green, darkSuccess.red)
        XCTAssertGreaterThan(darkSuccess.green, darkSuccess.blue)

        XCTAssertEqual(darkUserBubble.red, darkElevatedSurface.red, accuracy: 0.001)
        XCTAssertEqual(darkUserBubble.green, darkElevatedSurface.green, accuracy: 0.001)
        XCTAssertEqual(darkUserBubble.blue, darkElevatedSurface.blue, accuracy: 0.001)
        XCTAssertGreaterThan(darkUserBubble.alpha, 0.99)

        // 浅色下侧栏仍与普通工作区卡共用同一内容表面，避免出现第三种灰白。
        XCTAssertEqual(lightSidebarSurfaceBackground.red, lightSurface.red, accuracy: 0.001)
        XCTAssertEqual(lightSidebarSurfaceBackground.green, lightSurface.green, accuracy: 0.001)
        XCTAssertEqual(lightSidebarSurfaceBackground.blue, lightSurface.blue, accuracy: 0.001)

        // 深色下侧栏刻意脱离内容表面：它是结构分区而不是内容卡片，
        // 跟内容区差一整级亮度会让整屏出现两块明显不同的深色。
        // 这里只比背景高一点点，层级交给留白和字重表达，因此断言的是
        // “贴近背景、明显低于内容表面”，而不是与内容表面相等。
        XCTAssertLessThan(darkSidebarSurfaceBackground.red, darkContentPanelBackground.red - 0.02)
        XCTAssertGreaterThan(darkSidebarSurfaceBackground.red, darkBackground.red)
        XCTAssertLessThan(darkSidebarSurfaceBackground.red - darkBackground.red, 0.05)
    }

    func testXcodePresetKeepsEditorInspiredContrastAndAccents() {
        let store = ThemeStore(defaults: defaults)
        store.preset = .xcode

        let lightTokens = store.tokens(for: .light)
        let darkTokens = store.tokens(for: .dark)
        let lightBackground = rgba(lightTokens.background)
        let lightUserBubble = rgba(lightTokens.userBubble)
        let lightCodeBlock = rgba(lightTokens.codeBlock)
        let lightCodeText = rgba(lightTokens.codeText)
        let darkBackground = rgba(darkTokens.background)
        let darkElevatedSurface = rgba(darkTokens.elevatedSurface)
        let darkUserBubble = rgba(darkTokens.userBubble)
        let darkCodeBlock = rgba(darkTokens.codeBlock)
        let darkBorder = rgba(darkTokens.border)
        let accent = rgba(lightTokens.accent)
        let warning = rgba(lightTokens.warning)
        let success = rgba(darkTokens.success)
        let swatchBackground = rgba(ThemePreset.xcode.swatchBackground)
        let swatchForeground = rgba(ThemePreset.xcode.swatchForeground)

        // Xcode 浅色编辑器是纯白代码区，外层 markup 区为 #F5F5F5，当前行使用 #E8F2FF。
        assertRGB(lightBackground, red: 245, green: 245, blue: 245)
        assertRGB(lightCodeBlock, red: 255, green: 255, blue: 255)
        assertRGB(lightUserBubble, red: 232, green: 242, blue: 255)
        XCTAssertLessThan(lightCodeText.red, 0.15)
        XCTAssertLessThan(lightCodeText.green, 0.15)
        XCTAssertLessThan(lightCodeText.blue, 0.18)

        // 深色层级来自 Xcode Default (Dark)：编辑器 #1F1F24、markup #303239、选区 #515B70。
        assertRGB(darkBackground, red: 31, green: 31, blue: 36)
        assertRGB(darkCodeBlock, red: 31, green: 31, blue: 36)
        assertRGB(darkElevatedSurface, red: 48, green: 50, blue: 57)
        assertRGB(darkUserBubble, red: 81, green: 91, blue: 112)
        assertRGB(darkBorder, red: 65, green: 66, blue: 73)

        XCTAssertGreaterThan(accent.blue, 0.95)
        XCTAssertGreaterThan(accent.green, 0.45)
        XCTAssertGreaterThan(warning.red, 0.90)
        XCTAssertGreaterThan(warning.green, 0.65)
        XCTAssertGreaterThan(success.green, success.red)
        XCTAssertGreaterThan(success.green, success.blue)

        // 色卡用 Xcode 深色编辑器 + keyword 粉色，避免看起来像普通蓝色主题。
        assertRGB(swatchBackground, red: 31, green: 31, blue: 36)
        assertRGB(swatchForeground, red: 252, green: 95, blue: 163)
    }

    func testGitHubPresetProvidesLightAndDarkTokens() {
        let store = ThemeStore(defaults: defaults)
        store.preset = .github

        let lightTokens = store.tokens(for: .light)
        let darkTokens = store.tokens(for: .dark)

        XCTAssertTrue(ThemePreset.allCases.contains(.github))
        XCTAssertEqual(ThemePreset.github.title, "GitHub")
        XCTAssertEqual(lightTokens.preset, .github)
        XCTAssertEqual(lightTokens.resolvedScheme, .light)
        XCTAssertEqual(darkTokens.preset, .github)
        XCTAssertEqual(darkTokens.resolvedScheme, .dark)
    }

    /// 青草主题的约束是「绿只落在有意义的位置」，所以这里断言的是规则而不是一组色号：
    /// 大面积的底、浮层、系统气泡、描边和整套文字必须是中性的，绿只允许出现在
    /// 主操作、用户气泡、代码块和语义色上。这样以后谁把绿又铺回背景里，这条会红。
    func testMeadowPresetKeepsGreenOffLargeBackgrounds() {
        let store = ThemeStore(defaults: defaults)
        store.preset = .meadow

        XCTAssertTrue(ThemePreset.allCases.contains(.meadow))

        store.mode = .light
        let light = store.tokens(for: .dark)
        XCTAssertEqual(light.preset, .meadow)
        XCTAssertEqual(light.resolvedScheme, .light)

        let lightNeutral: [(String, Color)] = [
            ("background", light.background),
            ("elevatedSurface", light.elevatedSurface),
            ("systemBubble", light.systemBubble),
            ("border", light.border),
            ("primaryText", light.primaryText),
            ("secondaryText", light.secondaryText),
            ("tertiaryText", light.tertiaryText)
        ]
        for (name, color) in lightNeutral {
            assertNeutral(color, context: "meadow light \(name)")
        }

        let lightGreen: [(String, Color)] = [
            ("accent", light.accent),
            ("userBubble", light.userBubble),
            ("codeBlock", light.codeBlock),
            ("success", light.success),
            ("goalActive", light.goalActive)
        ]
        for (name, color) in lightGreen {
            assertGreen(color, context: "meadow light \(name)")
        }

        XCTAssertGreaterThanOrEqual(contrastRatio(light.codeText, light.codeBlock), 7.0)
        XCTAssertGreaterThanOrEqual(contrastRatio(light.primaryActionForeground, light.primaryAction), 7.0)
        for surface in [light.background, light.surface, light.elevatedSurface, light.userBubble, light.selectionFill] {
            XCTAssertGreaterThanOrEqual(contrastRatio(light.primaryText, surface), 7.0)
            XCTAssertGreaterThanOrEqual(contrastRatio(light.secondaryText, surface), 4.5)
        }

        store.mode = .dark
        let dark = store.tokens(for: .light)
        XCTAssertEqual(dark.preset, .meadow)
        XCTAssertEqual(dark.resolvedScheme, .dark)

        let darkNeutral: [(String, Color)] = [
            ("background", dark.background),
            ("surface", dark.surface),
            ("elevatedSurface", dark.elevatedSurface),
            ("systemBubble", dark.systemBubble),
            ("border", dark.border),
            ("primaryText", dark.primaryText),
            ("secondaryText", dark.secondaryText),
            ("tertiaryText", dark.tertiaryText)
        ]
        for (name, color) in darkNeutral {
            assertNeutral(color, context: "meadow dark \(name)")
        }
        for (name, color) in [("accent", dark.accent), ("userBubble", dark.userBubble)] {
            assertGreen(color, context: "meadow dark \(name)")
        }

        // 深色主操作是鼠尾草绿，白字压不出对比，主按钮和冲突卡都改用黑字；
        // 同时主操作自身要在底色上可读。这三条互相牵制：压暗按钮能救白字，
        // 但会让最后一条掉下去，所以只能从前景色解决。
        XCTAssertGreaterThanOrEqual(contrastRatio(dark.primaryActionForeground, dark.primaryAction), 4.5)
        XCTAssertGreaterThanOrEqual(contrastRatio(dark.writerConflictPrimaryActionForeground, dark.primaryAction), 4.5)
        XCTAssertGreaterThanOrEqual(contrastRatio(dark.primaryAction, dark.background), 4.5)
        for surface in [dark.background, dark.surface, dark.elevatedSurface, dark.userBubble] {
            XCTAssertGreaterThanOrEqual(contrastRatio(dark.primaryText, surface), 7.0)
            XCTAssertGreaterThanOrEqual(contrastRatio(dark.secondaryText, surface), 4.5)
        }
        XCTAssertGreaterThanOrEqual(contrastRatio(dark.codeText, dark.codeBlock), 7.0)
    }

    /// 中性：三个通道彼此相差不超过 4/255。留一点余量给暖白这类极轻微的偏色。
    private func assertNeutral(
        _ color: Color,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let c = rgba(color)
        let channels = [c.red, c.green, c.blue].map { $0 * 255 }
        let spread = (channels.max() ?? 0) - (channels.min() ?? 0)
        XCTAssertLessThanOrEqual(
            spread,
            4.0,
            "\(context) 应保持中性，当前通道极差 \(String(format: "%.1f", spread))",
            file: file,
            line: line
        )
    }

    /// 带绿：绿通道明显高于红蓝，确保这一处确实在表达主题色而不是碰巧偏绿。
    private func assertGreen(
        _ color: Color,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let c = rgba(color)
        let green = c.green * 255
        let others = max(c.red, c.blue) * 255
        XCTAssertGreaterThan(
            green - others,
            6.0,
            "\(context) 应带绿，当前绿通道只高出 \(String(format: "%.1f", green - others))",
            file: file,
            line: line
        )
    }

    func testPrimaryColorPresetsKeepVoiceRecordingAlignedWithAccent() {
        let store = ThemeStore(defaults: defaults)

        for preset in [ThemePreset.codex, .github, .xcode, .meadow] {
            store.preset = preset

            for scheme in [ColorScheme.light, .dark] {
                let tokens = store.tokens(for: scheme)
                let voice = rgba(tokens.voiceRecording)
                let accent = rgba(tokens.accent)
                let warning = rgba(tokens.warning)

                if preset == .codex, scheme == .light {
                    assertRGB(voice, red: 74, green: 20, blue: 74)
                    assertRGB(rgba(tokens.tint(for: .active)), red: 74, green: 20, blue: 74)
                    continue
                }

                // 语音录音态要保留“正在听”的差异感，但默认/代码主题里应贴近主色，而不是跳成警告色。
                XCTAssertLessThan(
                    colorDistance(voice, accent),
                    colorDistance(voice, warning),
                    "\(preset.title) \(scheme) voice color should stay closer to accent than warning"
                )
            }
        }
    }

    func testCodexDarkTokensKeepTextAndActionsReadable() {
        let store = ThemeStore(defaults: defaults)
        store.mode = .dark
        store.preset = .codex
        let tokens = store.tokens(for: .light)

        // 直接约束对比度而不是锁死 RGB，后续微调配色时仍能防止深紫重新沉入暗色背景。
        XCTAssertGreaterThanOrEqual(contrastRatio(tokens.primaryAction, tokens.background), 3.0)
        XCTAssertGreaterThanOrEqual(contrastRatio(tokens.primaryText, tokens.background), 4.5)
        XCTAssertGreaterThanOrEqual(contrastRatio(tokens.secondaryText, tokens.background), 4.5)
        XCTAssertGreaterThanOrEqual(contrastRatio(tokens.tertiaryText, tokens.background), 4.5)
        XCTAssertGreaterThanOrEqual(contrastRatio(tokens.primaryText, tokens.contentPanelBackground), 4.5)
        XCTAssertGreaterThanOrEqual(contrastRatio(tokens.secondaryText, tokens.contentPanelBackground), 4.5)
        XCTAssertGreaterThanOrEqual(contrastRatio(tokens.tertiaryText, tokens.contentPanelBackground), 4.5)
        XCTAssertGreaterThanOrEqual(contrastRatio(tokens.userBubbleForeground, tokens.userBubble), 4.5)
        XCTAssertGreaterThanOrEqual(contrastRatio(tokens.primaryActionForeground, tokens.primaryAction), 4.5)
        XCTAssertGreaterThanOrEqual(contrastRatio(tokens.primaryText, tokens.workspaceCardSelectionFill), 4.5)
        XCTAssertGreaterThanOrEqual(contrastRatio(tokens.secondaryText, tokens.workspaceCardSelectionFill), 4.5)
        XCTAssertGreaterThanOrEqual(contrastRatio(tokens.tertiaryText, tokens.workspaceCardSelectionFill), 4.5)
        XCTAssertGreaterThanOrEqual(contrastRatio(tokens.accent, tokens.workspaceCardSelectionFill), 3.0)
    }

    func testCodexDarkDerivedSurfacesAndTextAreNeutralAndOpaque() {
        let store = ThemeStore(defaults: defaults)
        let tokens = store.tokens(for: .dark)
        // 深色下除成功/警告外不再有任何色相：表面、文字、强调、选中、录音与波形
        // 都是灰阶，最多带 Notion 原有的极轻暖灰（红 ≥ 绿 ≥ 蓝，差值不超过 5）。
        let neutralColors = [
            tokens.background, tokens.surface, tokens.elevatedSurface,
            tokens.sidebarBackground, tokens.sidebarSurfaceBackground, tokens.sidebarHoverFill,
            tokens.inputBackground, tokens.composerControlSurface, tokens.composerInactiveActionSurface,
            tokens.planCardBackground, tokens.planCardBorder, tokens.contentPanelBackground,
            tokens.border, tokens.codeBlock,
            tokens.primaryText, tokens.secondaryText, tokens.tertiaryText, tokens.codeText,
            tokens.accent, tokens.accentSoft, tokens.primaryAction, tokens.selectionFill,
            tokens.goalActive, tokens.voiceRecording,
            tokens.sessionPinActionTint, tokens.sessionUnpinActionTint
        ] + tokens.voiceWaveformGradient
        for color in neutralColors {
            let value = rgba(color)
            XCTAssertGreaterThanOrEqual(value.red, value.green - 0.0001)
            XCTAssertGreaterThanOrEqual(value.green, value.blue - 0.0001)
            XCTAssertLessThanOrEqual(value.red - value.blue, 5.0 / 255.0 + 0.0001)
            XCTAssertEqual(value.alpha, 1, accuracy: 0.0001)
        }
        assertRGB(rgba(tokens.accentSoft), red: 55, green: 55, blue: 53)
        // 成功/警告是状态语义，不随主题去色。
        assertRGB(rgba(tokens.success), red: 101, green: 197, blue: 142)
        assertRGB(rgba(tokens.warning), red: 240, green: 181, blue: 98)
    }

    func testDefaultDarkColorOverridesDoNotLeakIntoOtherSchemesOrPresets() {
        let store = ThemeStore(defaults: defaults)
        for preset in ThemePreset.allCases {
            store.preset = preset
            for scheme in [ColorScheme.light, .dark] {
                let tokens = store.tokens(for: scheme)
                let isDefaultDark = preset == .codex && scheme == .dark
                let active = rgba(tokens.tint(for: .active))
                let expectedActive = rgba(isDefaultDark ? tokens.accent : tokens.primaryAction)
                XCTAssertLessThan(colorDistance(active, expectedActive), 0.0001)
                XCTAssertEqual(active.alpha, expectedActive.alpha, accuracy: 0.0001)
            }
        }
        store.preset = .codex
        store.mode = .light
        let forcedLight = store.tokens(for: .dark)
        assertRGB(rgba(forcedLight.background), red: 250, green: 248, blue: 246)
        assertRGB(rgba(forcedLight.tint(for: .active)), red: 74, green: 20, blue: 74)
    }

    func testCodexDarkForegroundsRemainReadableOnEveryStaticSurface() {
        let store = ThemeStore(defaults: defaults)
        let tokens = store.tokens(for: .dark)
        let surfaces = [
            tokens.background, tokens.contentPanelBackground,
            tokens.elevatedSurface, tokens.inputBackground, tokens.userBubble,
            tokens.selectionFill, tokens.workspaceCardSelectionFill
        ]
        for surface in surfaces {
            for text in [tokens.primaryText, tokens.secondaryText, tokens.tertiaryText] {
                XCTAssertGreaterThanOrEqual(contrastRatio(flatten(text, over: surface), surface), 4.5)
            }
            XCTAssertGreaterThanOrEqual(contrastRatio(tokens.tint(for: .active), surface), 4.5)
            XCTAssertGreaterThanOrEqual(contrastRatio(tokens.success, surface), 4.5)
            XCTAssertGreaterThanOrEqual(contrastRatio(tokens.warning, surface), 4.5)
        }
        XCTAssertGreaterThanOrEqual(contrastRatio(tokens.primaryAction, tokens.elevatedSurface), 3.0)
        XCTAssertGreaterThanOrEqual(contrastRatio(tokens.primaryActionForeground, tokens.primaryAction), 4.5)
        XCTAssertGreaterThanOrEqual(contrastRatio(tokens.codeText, tokens.codeBlock), 4.5)
    }

    func testCodexDarkKnownOpacityLayersKeepUsedForegroundsReadable() {
        let store = ThemeStore(defaults: defaults)
        let tokens = store.tokens(for: .dark)
        let canvas = tokens.conversationCanvasBackground
        // ConversationMessageContent 的整组 sending opacity 同时作用于文字与气泡。
        // MessageTimestampCaption 的最终渲染仍须由会话快照覆盖。
        let sendingBubble = flatten(tokens.userBubble.opacity(0.72), over: canvas)
        let sendingTimestamp = flatten(
            tokens.userMessageTimestampForeground(isSending: true).opacity(0.72),
            over: canvas
        )
        XCTAssertGreaterThanOrEqual(contrastRatio(sendingTimestamp, sendingBubble), 4.5)
        XCTAssertGreaterThanOrEqual(contrastRatio(sendingTimestamp, canvas), 4.5)
        let sentTimestamp = tokens.userMessageTimestampForeground(isSending: false)
        XCTAssertGreaterThanOrEqual(contrastRatio(sentTimestamp, tokens.userBubble), 4.5)
        XCTAssertGreaterThanOrEqual(contrastRatio(sentTimestamp, canvas), 4.5)
        // WorkbenchChromeMaterial 的 Reduce Transparency 有可确定的合成底色。
        // 未选中的胶囊/按钮用次级文字；完整选中时文字过渡到主文字（工作区胶囊）
        // 或主操作色（「我的」按钮），次级文字不会落在完整选中底上。
        let restingChrome = tokens.elevatedSurface
        XCTAssertGreaterThanOrEqual(contrastRatio(tokens.secondaryText, restingChrome), 4.5)
        let selectedChrome = flatten(tokens.primaryText.opacity(0.14), over: tokens.elevatedSurface)
        for text in [tokens.primaryText, tokens.primaryAction] {
            XCTAssertGreaterThanOrEqual(contrastRatio(text, selectedChrome), 4.5)
        }
        let inactiveFill = tokens.composerInactiveActionSurface
        let inactiveGlyph = flatten(tokens.composerInactiveActionForeground, over: inactiveFill)
        XCTAssertGreaterThanOrEqual(contrastRatio(inactiveGlyph, inactiveFill), 3.0)
    }

    func testWriterConflictCardStaysReadableInEveryPreset() {
        let store = ThemeStore(defaults: defaults)
        for preset in ThemePreset.allCases {
            store.preset = preset
            for scheme in [ColorScheme.light, .dark] {
                store.mode = scheme == .light ? .light : .dark
                let tokens = store.tokens(for: scheme)
                let context = "\(preset.rawValue) \(scheme)"
                let surface = tokens.elevatedSurface

                XCTAssertGreaterThanOrEqual(
                    contrastRatio(flatten(tokens.primaryText, over: surface), surface),
                    4.5,
                    "\(context) title"
                )
                XCTAssertGreaterThanOrEqual(
                    contrastRatio(flatten(tokens.writerConflictBodyText, over: surface), surface),
                    4.5,
                    "\(context) body"
                )
                XCTAssertGreaterThanOrEqual(
                    contrastRatio(flatten(tokens.writerConflictWarningIcon, over: surface), surface),
                    3.0,
                    "\(context) lock icon"
                )
                XCTAssertGreaterThanOrEqual(
                    contrastRatio(flatten(tokens.writerConflictErrorText, over: surface), surface),
                    4.5,
                    "\(context) inline error"
                )
                let actionFill = flatten(tokens.primaryAction, over: surface)
                XCTAssertGreaterThanOrEqual(
                    contrastRatio(
                        flatten(tokens.writerConflictPrimaryActionForeground, over: actionFill),
                        actionFill
                    ),
                    4.5,
                    "\(context) primary action"
                )
            }
        }
    }

    /// 空草稿是进入会话的默认状态，禁用态发送按钮必须仍然看得清箭头。
    /// 之前浅色下用 primaryActionForeground（纯白）压在 composerInactiveActionSurface
    /// 上只有约 1.3:1，图标会整个消失在色块里。
    func testComposerInactiveSendGlyphStaysVisibleInEveryPreset() {
        let store = ThemeStore(defaults: defaults)
        for preset in ThemePreset.allCases {
            store.preset = preset
            for scheme in [ColorScheme.light, ColorScheme.dark] {
                store.mode = scheme == .light ? .light : .dark
                let tokens = store.tokens(for: scheme)
                // 两个 token 都可能带 alpha，必须先合成到真实底色再比对比度。
                let fill = flatten(tokens.composerInactiveActionSurface, over: tokens.conversationCanvasBackground)
                let glyph = flatten(tokens.composerInactiveActionForeground, over: fill)

                XCTAssertGreaterThanOrEqual(
                    contrastRatio(glyph, fill),
                    3.0,
                    "\(preset.title) \(scheme) 禁用发送图标与底色对比度不足"
                )
            }
        }
    }

    func testCodexLightInactiveSendGlyphMeetsTextContrast() {
        let store = ThemeStore(defaults: defaults)
        store.preset = .codex
        store.mode = .light
        let tokens = store.tokens(for: .light)
        let fill = flatten(tokens.composerInactiveActionSurface, over: tokens.conversationCanvasBackground)

        XCTAssertGreaterThanOrEqual(
            contrastRatio(flatten(tokens.composerInactiveActionForeground, over: fill), fill),
            4.5
        )
        // 禁用态必须明显弱于启用态，否则两种状态在底栏上分不出来。
        XCTAssertLessThan(
            contrastRatio(flatten(tokens.composerInactiveActionForeground, over: fill), fill),
            contrastRatio(tokens.primaryActionForeground, tokens.primaryAction)
        )
    }

    func testThemeVersionIncrementsWhenVisualStateChanges() {
        let store = ThemeStore(defaults: defaults)
        let originalVersion = store.themeVersion

        store.preset = .gruvbox

        XCTAssertGreaterThan(store.themeVersion, originalVersion)
    }

    private func rgba(_ color: Color) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        return (red, green, blue, alpha)
    }

    private func assertRGB(
        _ color: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat),
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat,
        accuracy: CGFloat = 0.003
    ) {
        XCTAssertEqual(color.red, red / 255.0, accuracy: accuracy)
        XCTAssertEqual(color.green, green / 255.0, accuracy: accuracy)
        XCTAssertEqual(color.blue, blue / 255.0, accuracy: accuracy)
        XCTAssertGreaterThan(color.alpha, 0.99)
    }

    private func colorDistance(
        _ lhs: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat),
        _ rhs: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)
    ) -> CGFloat {
        let red = lhs.red - rhs.red
        let green = lhs.green - rhs.green
        let blue = lhs.blue - rhs.blue
        return sqrt(red * red + green * green + blue * blue)
    }

    /// 把带 alpha 的颜色合成到不透明底色上。对比度公式只对不透明色成立，
    /// 直接拿半透明 token 去算会得出偏乐观的结果。
    private func flatten(_ color: Color, over base: Color) -> Color {
        let top = rgba(color)
        let bottom = rgba(base)
        let alpha = top.alpha
        return Color(
            red: Double(top.red * alpha + bottom.red * (1 - alpha)),
            green: Double(top.green * alpha + bottom.green * (1 - alpha)),
            blue: Double(top.blue * alpha + bottom.blue * (1 - alpha))
        )
    }

    private func contrastRatio(_ foreground: Color, _ background: Color) -> CGFloat {
        let foregroundLuminance = relativeLuminance(rgba(foreground))
        let backgroundLuminance = relativeLuminance(rgba(background))
        return (max(foregroundLuminance, backgroundLuminance) + 0.05)
            / (min(foregroundLuminance, backgroundLuminance) + 0.05)
    }

    private func relativeLuminance(
        _ color: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)
    ) -> CGFloat {
        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.03928
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red)
            + 0.7152 * linear(color.green)
            + 0.0722 * linear(color.blue)
    }
}

@MainActor
final class ResponsiveLayoutTests: XCTestCase {
    func testWorkbenchLayoutUsesCompactNavigationOnPhoneWidth() {
        let layout = WorkbenchLayout(
            containerWidth: 390,
            horizontalSizeClass: .compact,
            isPad: false,
            isPhone: true
        )

        XCTAssertTrue(layout.usesCompactNavigation)
        XCTAssertTrue(layout.usesCompactPhoneNavigationTypography)
        XCTAssertFalse(WorkspaceRootView.shouldEmbedNavigationStack(
            usesCompactNavigation: layout.usesCompactNavigation
        ))
        XCTAssertTrue(layout.prefersDetailOnly)
        XCTAssertFalse(layout.usesAttachedInspector)
        XCTAssertFalse(layout.usesSheetInspectorNavigation)
        XCTAssertFalse(layout.usesFloatingSidebarSurface)
        // 390pt 的 iPhone 使用 compact 身份列，避免 table 的固定列挤压摘要。
        XCTAssertFalse(layout.prefersSessionTableDensity)
        XCTAssertLessThanOrEqual(layout.titleMaxWidth, 230)
        XCTAssertGreaterThanOrEqual(layout.titleMaxWidth, 160)
    }

    func testWorkbenchLayoutUsesCompactNavigationOnLegacyIPadMiniPortraitWidth() {
        let layout = WorkbenchLayout(
            containerWidth: 768,
            horizontalSizeClass: .regular,
            isPad: true
        )

        XCTAssertTrue(layout.usesCompactNavigation)
        XCTAssertFalse(layout.usesCompactPhoneNavigationTypography)
        XCTAssertFalse(WorkspaceRootView.shouldEmbedNavigationStack(
            usesCompactNavigation: layout.usesCompactNavigation
        ))
        XCTAssertTrue(layout.prefersDetailOnly)
        XCTAssertFalse(layout.usesAttachedInspector)
        XCTAssertFalse(layout.usesSheetInspectorNavigation)
        XCTAssertFalse(layout.usesFloatingSidebarSurface)
        XCTAssertTrue(layout.prefersSessionTableDensity)
    }

    func testWorkbenchLayoutUsesSheetNavigationOnMediumIPadWidth() {
        let layout = WorkbenchLayout(
            containerWidth: 1_032,
            horizontalSizeClass: .regular,
            isPad: true
        )

        XCTAssertFalse(layout.usesCompactNavigation)
        XCTAssertFalse(layout.prefersDetailOnly)
        XCTAssertFalse(layout.usesAttachedInspector)
        XCTAssertTrue(layout.usesSheetInspectorNavigation)
        XCTAssertTrue(layout.usesFloatingSidebarSurface)
        XCTAssertTrue(layout.prefersSessionTableDensity)
    }

    func testWorkbenchLayoutKeepsSplitNavigationOnWidePadWidth() {
        let layout = WorkbenchLayout(
            containerWidth: 1180,
            horizontalSizeClass: .regular,
            isPad: true
        )

        XCTAssertFalse(layout.usesCompactNavigation)
        XCTAssertTrue(WorkspaceRootView.shouldEmbedNavigationStack(
            usesCompactNavigation: layout.usesCompactNavigation
        ))
        XCTAssertFalse(layout.prefersDetailOnly)
        XCTAssertTrue(layout.usesAttachedInspector)
        XCTAssertFalse(layout.usesSheetInspectorNavigation)
        XCTAssertTrue(layout.usesFloatingSidebarSurface)
        XCTAssertTrue(layout.prefersSessionTableDensity)
        XCTAssertEqual(layout.projectColumn.ideal, 330)
        XCTAssertEqual(layout.titleMaxWidth, 340)
    }

    func testFloatingSidebarSurfaceStartsAtWideIPadBoundaryOnly() {
        let narrowPad = WorkbenchLayout(
            containerWidth: 859,
            horizontalSizeClass: .regular,
            isPad: true
        )
        let widePad = WorkbenchLayout(
            containerWidth: 860,
            horizontalSizeClass: .regular,
            isPad: true
        )
        let widePhone = WorkbenchLayout(
            containerWidth: 1_024,
            horizontalSizeClass: .regular,
            isPad: false
        )

        XCTAssertFalse(narrowPad.usesFloatingSidebarSurface)
        XCTAssertTrue(widePad.usesFloatingSidebarSurface)
        XCTAssertFalse(widePhone.usesFloatingSidebarSurface)
        XCTAssertTrue(narrowPad.prefersSessionTableDensity)
        XCTAssertTrue(widePad.prefersSessionTableDensity)
        XCTAssertTrue(widePhone.prefersSessionTableDensity)
    }

    func testFloatingSidebarHidesDuplicateNewSessionButton() {
        XCTAssertFalse(
            WorkbenchSidebarFooter.showsNewSessionButton(usesFloatingSurface: true)
        )
        XCTAssertTrue(
            WorkbenchSidebarFooter.showsNewSessionButton(usesFloatingSurface: false)
        )
    }

    func testSessionTableDensityUsesSharedWidthThreshold() {
        let slideOverPad = WorkbenchLayout(
            containerWidth: 320,
            horizontalSizeClass: .compact,
            isPad: true
        )
        let phonePortrait = WorkbenchLayout(
            containerWidth: 390,
            horizontalSizeClass: .compact,
            isPad: false
        )
        let splitViewPad = WorkbenchLayout(
            containerWidth: 699,
            horizontalSizeClass: .compact,
            isPad: true
        )
        let portraitPad = WorkbenchLayout(
            containerWidth: 744,
            horizontalSizeClass: .regular,
            isPad: true
        )

        // iPhone 与 Slide Over 都使用 compact；达到共享阈值的 iPad 分栏才使用 table。
        XCTAssertFalse(slideOverPad.prefersSessionTableDensity)
        XCTAssertFalse(phonePortrait.prefersSessionTableDensity)
        XCTAssertTrue(splitViewPad.prefersSessionTableDensity)
        XCTAssertTrue(portraitPad.prefersSessionTableDensity)
    }

    func testConversationLayoutFitsPhonePortraitWidth() {
        let layout = ConversationLayout(containerWidth: 390, horizontalSizeClass: .compact)

        XCTAssertEqual(layout.horizontalInset, 16)
        XCTAssertEqual(layout.composerHorizontalInset, 8)
        XCTAssertEqual(layout.composerAvailableWidth, 374)
        XCTAssertEqual(layout.composerMaxWidth, .infinity)
        XCTAssertEqual(layout.composerBottomPadding, 0)
        XCTAssertLessThanOrEqual(layout.userBubbleMaxWidth, 354)
        XCTAssertLessThanOrEqual(layout.assistantBubbleMaxWidth, 354)
        XCTAssertLessThanOrEqual(layout.runtimeCardMaxWidth, 366)
    }

    func testConversationLayoutCapsPhoneLandscapeComposerWidth() {
        let layout = ConversationLayout(containerWidth: 844, horizontalSizeClass: .compact)

        XCTAssertEqual(layout.composerHorizontalInset, 8)
        XCTAssertEqual(layout.composerAvailableWidth, 828)
        XCTAssertEqual(layout.composerMaxWidth, 680)
        XCTAssertEqual(layout.assistantBubbleMaxWidth, 660)
        XCTAssertLessThan(layout.composerMaxWidth, layout.composerAvailableWidth)
    }

    func testConversationLayoutKeepsPadComposerCloseToBottomSafeArea() {
        let layout = ConversationLayout(containerWidth: 716, horizontalSizeClass: .regular)

        XCTAssertEqual(layout.composerHorizontalInset, layout.horizontalInset)
        XCTAssertEqual(layout.composerTopPadding, 12)
        XCTAssertEqual(layout.composerBottomPadding, 8)
    }

    func testConversationLayoutGivesWidePadComposerMoreWorkingRoom() {
        let layout = ConversationLayout(containerWidth: 1_180, horizontalSizeClass: .regular)

        XCTAssertEqual(layout.composerAvailableWidth, 1_132)
        XCTAssertEqual(layout.composerMaxWidth, 940)
        XCTAssertGreaterThan(layout.composerMaxWidth, layout.assistantBubbleMaxWidth)
    }
}
