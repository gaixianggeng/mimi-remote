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

    func testDefaultCodexPresetUsesWarmLightAndNeutralDarkPalette() {
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

        XCTAssertEqual(ThemePreset.codex.title, L10n.text("ui.warm_sun"))
        XCTAssertEqual(ThemePreset.codex.subtitle, L10n.text("ui.neutral_warm_white_with_a_single_main_color"))

        assertRGB(lightBackground, red: 250, green: 247, blue: 241)
        assertRGB(lightSidebarBackground, red: 250, green: 247, blue: 241)
        assertRGB(lightSidebarSurfaceBackground, red: 255, green: 255, blue: 255)
        assertRGB(lightSelectionFill, red: 239, green: 236, blue: 237)
        assertRGB(lightSidebarHoverFill, red: 240, green: 239, blue: 237)
        assertRGB(lightInputBackground, red: 255, green: 255, blue: 255)
        assertRGB(lightConversationCanvasBackground, red: 250, green: 250, blue: 248)
        assertRGB(lightConversationPrimaryText, red: 16, green: 16, blue: 16)
        assertRGB(lightConversationSecondaryText, red: 112, green: 112, blue: 110)
        assertRGB(lightConversationTertiaryText, red: 142, green: 142, blue: 139)
        assertRGB(lightComposerControlSurface, red: 242, green: 241, blue: 238)
        assertRGB(lightComposerInactiveActionSurface, red: 234, green: 218, blue: 210)
        assertRGB(lightPlanCardBackground, red: 255, green: 255, blue: 255)
        assertRGB(lightPlanCardBorder, red: 230, green: 227, blue: 224)
        assertRGB(lightBorder, red: 229, green: 226, blue: 223)
        assertRGB(lightSecondaryText, red: 142, green: 142, blue: 147)
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

        // 用户内容使用中性表面；品牌深紫只保留给操作和色卡。
        assertRGB(lightUserBubble, red: 244, green: 243, blue: 240)
        assertRGB(rgba(lightTokens.primaryAction), red: 74, green: 20, blue: 74)
        let darkPrimaryAction = rgba(darkTokens.primaryAction)
        assertRGB(darkPrimaryAction, red: 155, green: 87, blue: 157)
        XCTAssertGreaterThan(colorDistance(darkAccent, darkPrimaryAction), 0.1)
        XCTAssertGreaterThan(lightUserBubble.alpha, 0.99)
        XCTAssertEqual(codexSwatchForeground.red, lightAccent.red, accuracy: 0.001)
        XCTAssertEqual(codexSwatchForeground.green, lightAccent.green, accuracy: 0.001)
        XCTAssertEqual(codexSwatchForeground.blue, lightAccent.blue, accuracy: 0.001)

        // 大面积表面使用暖石墨，紫色集中在操作与明确的选中反馈。
        assertRGB(darkBackground, red: 18, green: 17, blue: 18)
        assertRGB(darkSurface, red: 31, green: 29, blue: 30)
        assertRGB(darkElevatedSurface, red: 42, green: 39, blue: 41)
        assertRGB(darkSidebarBackground, red: 23, green: 21, blue: 22)
        assertRGB(darkSidebarSurfaceBackground, red: 25, green: 23, blue: 25)
        assertRGB(darkSidebarHoverFill, red: 42, green: 39, blue: 41)
        assertRGB(darkInputBackground, red: 35, green: 33, blue: 36)
        assertRGB(darkConversationCanvasBackground, red: 18, green: 17, blue: 18)
        assertRGB(darkComposerControlSurface, red: 45, green: 42, blue: 45)
        assertRGB(darkComposerInactiveActionSurface, red: 79, green: 65, blue: 72)
        assertRGB(darkPlanCardBackground, red: 35, green: 33, blue: 36)
        assertRGB(darkPlanCardBorder, red: 75, green: 69, blue: 73)
        assertRGB(darkBorder, red: 64, green: 59, blue: 63)
        assertRGB(darkSelectionFill, red: 43, green: 37, blue: 42)
        assertRGB(darkContentPanelBackground, red: 42, green: 39, blue: 41)
        assertRGB(darkWorkspaceCardSelectionFill, red: 53, green: 38, blue: 53)
        assertRGB(darkPrimaryText, red: 244, green: 241, blue: 239)
        assertRGB(darkSecondaryText, red: 180, green: 173, blue: 168)
        assertRGB(darkTertiaryText, red: 153, green: 145, blue: 140)
        XCTAssertLessThan(abs(darkBackground.red - darkBackground.blue), 0.02)
        XCTAssertLessThan(abs(darkSurface.red - darkSurface.blue), 0.04)
        XCTAssertLessThan(abs(darkElevatedSurface.red - darkElevatedSurface.blue), 0.04)
        XCTAssertGreaterThan(darkAccent.red, 0.70)
        XCTAssertGreaterThan(darkAccent.green, 0.45)
        XCTAssertGreaterThan(darkAccent.blue, 0.75)
        XCTAssertGreaterThan(darkAccent.blue, darkAccent.green)
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
        XCTAssertLessThan(darkSidebarSurfaceBackground.red, darkContentPanelBackground.red - 0.03)
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

    func testPrimaryColorPresetsKeepVoiceRecordingAlignedWithAccent() {
        let store = ThemeStore(defaults: defaults)

        for preset in [ThemePreset.codex, .github, .xcode] {
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
        // iPhone 竖屏与 iPad 竖屏共用同一套会话行结构，项目锚点不再按设备缩小。
        XCTAssertTrue(layout.prefersSessionTableDensity)
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

    func testSessionTableDensityFallsBackOnlyBelowSlideOverWidth() {
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

        // 只有 Slide Over 这类真正窄的窗口才放弃锚点列；手机与分屏都保留同一套结构。
        XCTAssertFalse(slideOverPad.prefersSessionTableDensity)
        XCTAssertTrue(phonePortrait.prefersSessionTableDensity)
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
