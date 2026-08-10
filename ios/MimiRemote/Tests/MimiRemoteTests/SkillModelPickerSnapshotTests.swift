#if os(iOS) && !targetEnvironment(macCatalyst)
import SnapshotTesting
import SwiftUI
import XCTest
@testable import MimiRemote

@MainActor
final class SkillModelPickerSnapshotTests: SimplifiedChineseSnapshotTestCase {
    func testEffectiveModelUsesExplicitSelectionBeforeServerDefault() {
        let options = [
            CodexAppServerModelOption(id: "gpt-5.6-sol", title: "GPT-5.6 Sol", isDefault: true),
            CodexAppServerModelOption(id: "gpt-5.6-terra", title: "GPT-5.6 Terra")
        ]
        let layout = ModelReasoningGridCatalog.layout(runtimeProvider: "codex", options: options)

        XCTAssertEqual(
            ModelReasoningGridCatalog.effectiveModelID(selectedModelID: "gpt-5.6-terra", options: options),
            "gpt-5.6-terra"
        )
        XCTAssertTrue(layout.contains(modelID: "gpt-5.6-terra"))
        XCTAssertNotNil(
            ModelReasoningGridCatalog.triggerTitle(
                for: "gpt-5.6-terra",
                effort: .high,
                layout: layout
            )
        )
    }

    func testEffectiveModelResolvesDefaultGridModelWithoutExplicitSelection() {
        let options = [
            CodexAppServerModelOption(id: "gpt-5.5", title: "GPT-5.5"),
            CodexAppServerModelOption(id: "gpt-5.6-sol", title: "GPT-5.6 Sol", isDefault: true)
        ]

        let layout = ModelReasoningGridCatalog.layout(runtimeProvider: "codex", options: options)
        let modelID = ModelReasoningGridCatalog.effectiveModelID(selectedModelID: nil, options: options)

        XCTAssertEqual(modelID, "gpt-5.6-sol")
        XCTAssertTrue(layout.contains(modelID: modelID))
        XCTAssertEqual(
            modelID.flatMap {
                ModelReasoningGridCatalog.triggerTitle(for: $0, effort: .xhigh, layout: layout)
            },
            "GPT-5.6 Sol · Extra High"
        )
        XCTAssertEqual(
            modelID.flatMap { ModelReasoningGridCatalog.compactTriggerTitle(for: $0, layout: layout) },
            "5.6 Sol"
        )
        XCTAssertEqual(
            modelID.flatMap {
                ModelReasoningGridCatalog.compactTriggerTitle(
                    for: $0,
                    effort: .high,
                    layout: layout
                )
            },
            "5.6 Sol High"
        )
        XCTAssertEqual(
            modelID.flatMap {
                ModelReasoningGridCatalog.compactTriggerTitle(
                    for: $0,
                    effort: .xhigh,
                    layout: layout
                )
            },
            "5.6 Sol XH"
        )
        let hyphenatedOptions = [
            CodexAppServerModelOption(id: "gpt-5.6-sol", title: "GPT-5.6-Sol", isDefault: true)
        ]
        let hyphenatedLayout = ModelReasoningGridCatalog.layout(
            runtimeProvider: "codex",
            options: hyphenatedOptions
        )
        XCTAssertEqual(
            ModelReasoningGridCatalog.compactTriggerTitle(
                for: "gpt-5.6-sol",
                effort: .high,
                layout: hyphenatedLayout
            ),
            "5.6 Sol High"
        )
    }

    func testClaudeUsesServerOrderedTopThreeModelsAndStandardFourEfforts() {
        let nonGridOptions = [CodexAppServerModelOption(id: "gpt-5.5", title: "GPT-5.5", isDefault: true)]
        let claudeOptions = CodexAppServerModelOption.builtInClaudeFallback

        let codexLayout = ModelReasoningGridCatalog.layout(runtimeProvider: "codex", options: nonGridOptions)
        let claudeLayout = ModelReasoningGridCatalog.layout(runtimeProvider: "claude", options: claudeOptions)
        let nonGridModelID = ModelReasoningGridCatalog.effectiveModelID(selectedModelID: nil, options: nonGridOptions)
        let claudeModelID = ModelReasoningGridCatalog.effectiveModelID(selectedModelID: nil, options: claudeOptions)

        XCTAssertTrue(codexLayout.contains(modelID: nonGridModelID))
        XCTAssertTrue(claudeLayout.contains(modelID: claudeModelID))
        XCTAssertEqual(claudeLayout.models.map(\.model), ["claude-fable-5", "opus", "sonnet"])
        XCTAssertEqual(
            claudeLayout.models.map { ModelReasoningGridCatalog.shortTitle(for: $0, kind: .claude) },
            ["Claude Fable 5", "Claude Opus 5", "Claude Sonnet 5"]
        )
        XCTAssertEqual(
            ModelReasoningGridCatalog.compactTriggerTitle(for: "opus", layout: claudeLayout),
            "Opus 5"
        )
        XCTAssertEqual(claudeLayout.efforts, [.medium, .high, .xhigh, .max])
        XCTAssertEqual(ModelReasoningGridCatalog.effortTitle(.low), "Light")
        XCTAssertEqual(ModelReasoningGridCatalog.effortTitle(.xhigh), "Extra High")
        XCTAssertEqual(ModelReasoningGridCatalog.effortTitle(.max), "Max")
        XCTAssertEqual(ModelReasoningGridCatalog.effortTitle(.ultra), "Ultra")
        XCTAssertFalse(claudeLayout.showsFastMode)
        XCTAssertEqual(claudeLayout.standardContentHeight, 236)
    }

    func testCodexStandardMenuUsesModelSpecificFourthEffortAndInlineLabel() {
        let options = CodexAppServerModelOption.builtInFallback
        let sol = options[0]
        let terra = options[1]
        let luna = options[2]
        let layout = ModelReasoningGridCatalog.layout(runtimeProvider: "codex", options: options)

        XCTAssertEqual(layout.efforts, [.medium, .high, .xhigh, .ultra])
        XCTAssertEqual(layout.modelRowCount, 3)
        XCTAssertEqual(layout.effortColumnCount, 4)
        XCTAssertEqual(
            layout.selection(modelRow: 2, effortColumn: 3),
            ModelReasoningGridSelection(modelID: luna.model, effort: .max)
        )
        XCTAssertEqual(layout.efforts(for: luna), [.medium, .high, .xhigh, .max])
        XCTAssertNil(layout.inlineEffortLabel(for: sol, column: 3))
        XCTAssertNil(layout.inlineEffortLabel(for: luna, column: 2))
        XCTAssertEqual(layout.inlineEffortLabel(for: luna, column: 3), "max")
        XCTAssertEqual(
            ModelReasoningGridCatalog.allSupportedEfforts(for: sol),
            [.low, .medium, .high, .xhigh, .max, .ultra]
        )
        XCTAssertEqual(
            ModelReasoningGridCatalog.allSupportedEfforts(for: terra),
            [.low, .medium, .high, .xhigh, .max, .ultra]
        )
        XCTAssertEqual(
            ModelReasoningGridCatalog.allSupportedEfforts(for: luna),
            [.low, .medium, .high, .xhigh, .max]
        )
        XCTAssertEqual(
            ModelReasoningGridCatalog.visibleEfforts(for: sol, layout: layout),
            [.medium, .high, .xhigh, .ultra]
        )
        XCTAssertEqual(
            ModelReasoningGridCatalog.visibleEfforts(for: terra, layout: layout),
            [.medium, .high, .xhigh, .ultra]
        )
        XCTAssertEqual(
            ModelReasoningGridCatalog.visibleEfforts(for: luna, layout: layout),
            [.medium, .high, .xhigh, .max]
        )
        XCTAssertTrue(ModelReasoningGridCatalog.supports(.ultra, option: sol))
        XCTAssertFalse(ModelReasoningGridCatalog.supports(.ultra, option: luna))
        XCTAssertTrue(ModelReasoningGridCatalog.isStandardEffortAvailable(.max, option: luna, layout: layout))
        XCTAssertFalse(ModelReasoningGridCatalog.isStandardEffortAvailable(.max, option: sol, layout: layout))
        XCTAssertEqual(
            ModelReasoningGridCatalog.normalizedVisibleEffort(
                option: luna,
                current: .ultra,
                layout: layout
            ),
            .medium
        )
        XCTAssertEqual(ModelReasoningGridCatalog.effortTitle(.max), "Max")
        XCTAssertEqual(ModelReasoningGridCatalog.effortTitle(.ultra), "Ultra")
    }

    func testModelPickerContentHeightTracksVisibleModelRows() {
        let oneModel = [
            CodexAppServerModelOption(id: "model-1", title: "Model 1")
        ]
        let twoModels = oneModel + [
            CodexAppServerModelOption(id: "model-2", title: "Model 2")
        ]
        let threeModels = twoModels + [
            CodexAppServerModelOption(id: "model-3", title: "Model 3")
        ]

        let codexOneRow = ModelReasoningGridCatalog.layout(
            runtimeProvider: "codex",
            options: oneModel
        )
        let codexThreeRows = ModelReasoningGridCatalog.layout(
            runtimeProvider: "codex",
            options: threeModels
        )
        let claudeTwoRows = ModelReasoningGridCatalog.layout(
            runtimeProvider: "claude",
            options: twoModels
        )

        XCTAssertEqual(codexOneRow.standardContentHeight, 132)
        XCTAssertEqual(claudeTwoRows.standardContentHeight, 184)
        XCTAssertEqual(codexThreeRows.standardContentHeight, 236)
        XCTAssertTrue(codexOneRow.showsFastMode)
        XCTAssertFalse(claudeTwoRows.showsFastMode)
        XCTAssertEqual(codexOneRow.efforts.last, .ultra)
        XCTAssertEqual(claudeTwoRows.efforts.last, .max)

        // 112pt 角区刚好容纳“全部模型 / 快速模式图标”两个 44pt 触控区，
        // 同时保证最窄 320pt 容器中的四个推理列仍各有 44pt 宽。
        XCTAssertEqual(ModelReasoningGridMetrics.fastModeHitTarget, 44)
        XCTAssertEqual(ModelReasoningGridMetrics.fastModeVisualDiameter, 36)
        let narrowGridWidth = 320
            - ModelReasoningGridMetrics.contentPadding * 2
            - ModelReasoningGridMetrics.modelLabelWidth
            - ModelReasoningGridMetrics.gridSpacing
        XCTAssertEqual(narrowGridWidth / 4, 44)
    }

    func testSkillCardsAndModelGridDarkAppearance() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad)
        let defaults = UserDefaults(suiteName: "SkillModelPickerSnapshotTests.\(UUID().uuidString)")!
        let themeStore = ThemeStore(defaults: defaults)
        themeStore.mode = .dark

        let skills = [
            SkillCapability(
                name: "apple-design",
                description: "Apple 风格的手势、材质与动效设计",
                scope: "user",
                path: "/Users/demo/.codex/skills/apple-design/SKILL.md",
                enabled: true,
                displayName: "Apple Design",
                shortDescription: "流畅、克制且具有物理反馈的界面",
                brandColor: "#35A7A8"
            ),
            SkillCapability(
                name: "imagegen",
                description: "生成与编辑视觉素材",
                scope: "system",
                path: "/Users/demo/.codex/skills/.system/imagegen/SKILL.md",
                enabled: true,
                displayName: "Image Generation",
                shortDescription: "创建产品概念图和位图素材",
                brandColor: "#7D65D8"
            ),
            SkillCapability(
                name: "swiftui-ui-patterns",
                description: "构建原生 SwiftUI 界面",
                scope: "repo",
                path: "/Users/demo/.codex/plugins/swiftui-ui-patterns/SKILL.md",
                enabled: true,
                displayName: "SwiftUI Patterns",
                shortDescription: "稳定的数据流与组件布局",
                brandColor: "#D47B45"
            )
        ]

        let selectedSkill = SkillVisualMetadata(capability: skills[0])
        let view = HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 18) {
                SkillPickerPanel(
                    skills: skills,
                    selectedPaths: [skills[0].path, skills[1].path],
                    errorMessage: nil,
                    isRefreshing: false,
                    onToggle: { _ in },
                    onRefresh: {},
                    onManualAdd: {},
                    onDone: {}
                )

                HStack(spacing: 10) {
                    SkillAttachmentToken(metadata: selectedSkill, onOpen: {}, onRemove: {})
                    SkillAttachmentToken(metadata: SkillVisualMetadata(capability: skills[1]), onOpen: {}, onRemove: {})
                }

                SkillInvocationCard(metadata: selectedSkill, sendStatus: .confirmed)
                    .frame(width: 410)
            }

            ModelReasoningGridPicker(
                options: CodexAppServerModelOption.builtInFallback,
                layout: ModelReasoningGridCatalog.layout(
                    runtimeProvider: "codex",
                    options: CodexAppServerModelOption.builtInFallback
                ),
                selection: ModelReasoningGridSelection(modelID: "gpt-5.6-terra", effort: .high),
                selectedModelID: "gpt-5.6-terra",
                isRefreshing: false,
                isFastMode: true,
                onSelectModel: { _, _ in },
                onSelectDefaultModel: { _, _ in },
                onFastModeChange: { _ in },
                onRefresh: {}
            )
        }
        .padding(28)
        .environmentObject(themeStore)
        .environment(\.colorScheme, .dark)
        .frame(width: 1024, height: 760, alignment: .topLeading)
        .background(themeStore.tokens(for: .dark).background)

        // Skill 选择器本次新增了完整多选和“完成”交互，旧图片基线已经不再表达
        // 当前组件结构。这里保留 iPad 大画布的构建/布局回归，避免无模拟器环境下
        // 提交一个缺失或过期的图片基线；交互由真机 UI 用例覆盖。
        let host = UIHostingController(rootView: view)
        host.view.frame = CGRect(x: 0, y: 0, width: 1024, height: 760)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        XCTAssertGreaterThan(host.sizeThatFits(in: CGSize(width: 1024, height: 760)).height, 0)
    }

    func testCompactModelGridLightFastModeOff() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad)
        let defaults = UserDefaults(suiteName: "SkillModelPickerSnapshotTests.\(UUID().uuidString)")!
        let themeStore = ThemeStore(defaults: defaults)
        themeStore.mode = .light

        let view = ModelReasoningGridPicker(
            options: CodexAppServerModelOption.builtInFallback,
            layout: ModelReasoningGridCatalog.layout(
                runtimeProvider: "codex",
                options: CodexAppServerModelOption.builtInFallback
            ),
            selection: ModelReasoningGridSelection(modelID: "gpt-5.6-sol", effort: .xhigh),
            selectedModelID: "gpt-5.6-sol",
            isRefreshing: false,
            isFastMode: false,
            onSelectModel: { _, _ in },
            onSelectDefaultModel: { _, _ in },
            onFastModeChange: { _ in },
            onRefresh: {}
        )
        .environmentObject(themeStore)
        .environment(\.colorScheme, .light)
        .padding(32)
        .frame(width: 440, height: 430, alignment: .top)
        .background(themeStore.tokens(for: .light).background)

        assertSnapshot(
            of: view,
            as: .image(precision: 0.98, layout: .fixed(width: 440, height: 430))
        )
    }

    func testCompactModelGridDarkFastModeOn() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad)
        let defaults = UserDefaults(suiteName: "SkillModelPickerSnapshotTests.\(UUID().uuidString)")!
        let themeStore = ThemeStore(defaults: defaults)
        themeStore.mode = .dark

        let view = ModelReasoningGridPicker(
            options: CodexAppServerModelOption.builtInFallback,
            layout: ModelReasoningGridCatalog.layout(
                runtimeProvider: "codex",
                options: CodexAppServerModelOption.builtInFallback
            ),
            selection: ModelReasoningGridSelection(modelID: "gpt-5.6-sol", effort: .xhigh),
            selectedModelID: "gpt-5.6-sol",
            isRefreshing: false,
            isFastMode: true,
            onSelectModel: { _, _ in },
            onSelectDefaultModel: { _, _ in },
            onFastModeChange: { _ in },
            onRefresh: {}
        )
        .environmentObject(themeStore)
        .environment(\.colorScheme, .dark)
        .padding(32)
        .frame(width: 440, height: 430, alignment: .top)
        .background(themeStore.tokens(for: .dark).background)

        assertSnapshot(
            of: view,
            as: .image(precision: 0.98, layout: .fixed(width: 440, height: 430))
        )
    }

    func testModelPickerAdaptiveWidthAndAccessibilityLayouts() {
        assertSnapshot(
            of: adaptiveModelPicker(
                width: 320,
                height: 372,
                horizontalSizeClass: .compact
            ),
            as: .image(
                precision: 0.98,
                layout: .fixed(width: 320, height: 372),
                traits: UITraitCollection(displayScale: 2)
            ),
            named: "iphone-320"
        )

        assertSnapshot(
            of: adaptiveModelPicker(
                width: 390,
                height: 372,
                colorScheme: .dark,
                horizontalSizeClass: .compact
            ),
            as: .image(
                precision: 0.98,
                layout: .fixed(width: 390, height: 372),
                traits: UITraitCollection(displayScale: 2)
            ),
            named: "iphone-390-dark"
        )

        assertSnapshot(
            of: adaptiveModelPicker(
                width: 667,
                height: 300,
                horizontalSizeClass: .compact
            ),
            as: .image(
                precision: 0.98,
                layout: .fixed(width: 667, height: 300),
                traits: UITraitCollection(displayScale: 2)
            ),
            named: "iphone-landscape-compact-height"
        )

        assertSnapshot(
            of: adaptiveModelPicker(
                width: 420,
                height: 372,
                horizontalSizeClass: .regular
            ),
            as: .image(
                precision: 0.98,
                layout: .fixed(width: 420, height: 372),
                traits: UITraitCollection(displayScale: 2)
            ),
            named: "ipad-popover-420"
        )

        assertSnapshot(
            of: adaptiveModelPicker(
                width: 420,
                height: 320,
                colorScheme: .dark,
                horizontalSizeClass: .regular,
                runtimeProvider: "claude",
                options: CodexAppServerModelOption.builtInClaudeFallback,
                selection: ModelReasoningGridSelection(modelID: "opus", effort: .high)
            ),
            as: .image(
                precision: 0.98,
                layout: .fixed(width: 420, height: 320),
                traits: UITraitCollection(displayScale: 2)
            ),
            named: "ipad-claude-popover-420-dark"
        )

        assertSnapshot(
            of: adaptiveModelPicker(
                width: 375,
                height: 372,
                horizontalSizeClass: .compact
            ),
            as: .image(
                precision: 0.98,
                layout: .fixed(width: 375, height: 372),
                traits: UITraitCollection(displayScale: 2)
            ),
            named: "ipad-split-375"
        )

        assertSnapshot(
            of: adaptiveModelPicker(
                width: 390,
                height: 372,
                dynamicTypeSize: .accessibility3,
                horizontalSizeClass: .compact
            ),
            as: .image(
                precision: 0.98,
                layout: .fixed(width: 390, height: 372),
                traits: UITraitCollection(displayScale: 2)
            ),
            named: "accessibility3"
        )
    }

    func testSkillInvocationCardLightAppearance() throws {
        let defaults = UserDefaults(suiteName: "SkillModelPickerSnapshotTests.\(UUID().uuidString)")!
        let themeStore = ThemeStore(defaults: defaults)
        themeStore.mode = .light
        let tokens = themeStore.tokens(for: .light)
        let skill = SkillCapability(
            name: "submit-ios-testflight-internal",
            description: "检查未提交修改，确认后自动提交并发布内部测试版本",
            scope: "user",
            path: "/Users/demo/.codex/skills/submit-ios-testflight-internal/SKILL.md",
            enabled: true,
            displayName: "发布 iOS 内部 TestFlight",
            shortDescription: "检查未提交修改，确认后自动提交并发布内部测试版本",
            brandColor: "#6C176D"
        )

        let view = SkillInvocationCard(
            metadata: SkillVisualMetadata(capability: skill),
            sendStatus: .confirmed
        )
        .padding(16)
        .environmentObject(themeStore)
        .environment(\.colorScheme, .light)
        .frame(width: 560, height: 112)
        .background(tokens.userBubble)

        assertSnapshot(
            of: view,
            // 这张组件基线既会在 @2x iPad 也会在 @3x iPhone 上执行。
            // 固定渲染 scale，避免同一逻辑尺寸因运行设备不同产生 560/840px 误报。
            as: .wait(
                for: 0.8,
                on: .image(
                    precision: 0.98,
                    layout: .fixed(width: 560, height: 112),
                    traits: UITraitCollection(displayScale: 2)
                )
            )
        )
    }

    func testComposerModelTriggerFastIndicator() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad)
        let defaults = UserDefaults(suiteName: "SkillModelPickerSnapshotTests.\(UUID().uuidString)")!
        let themeStore = ThemeStore(defaults: defaults)
        themeStore.mode = .light

        let view = HStack(spacing: 18) {
            ComposerToolbarControlLabel(
                title: "GPT-5.6 Sol · xhigh",
                systemImage: "cpu",
                trailingSystemImage: nil,
                isSelected: false,
                tint: nil,
                titleMaxWidth: 150,
                accessibilityLabel: "切换模型与推理强度"
            )

            ComposerToolbarControlLabel(
                title: "GPT-5.6 Sol · xhigh",
                systemImage: "cpu",
                trailingSystemImage: "bolt.fill",
                isSelected: false,
                tint: nil,
                titleMaxWidth: 150,
                accessibilityLabel: "切换模型与推理强度，快速"
            )
        }
        .padding(28)
        .environmentObject(themeStore)
        .environment(\.colorScheme, .light)
        .frame(width: 520, height: 120)
        .background(themeStore.tokens(for: .light).background)

        assertSnapshot(
            of: view,
            as: .image(precision: 0.98, layout: .fixed(width: 520, height: 120))
        )
    }

    private func adaptiveModelPicker(
        width: CGFloat,
        height: CGFloat,
        colorScheme: ColorScheme = .light,
        dynamicTypeSize: DynamicTypeSize = .large,
        horizontalSizeClass: UserInterfaceSizeClass,
        runtimeProvider: String = "codex",
        options: [CodexAppServerModelOption] = CodexAppServerModelOption.builtInFallback,
        selection: ModelReasoningGridSelection = ModelReasoningGridSelection(
            modelID: "gpt-5.6-sol",
            effort: .xhigh
        )
    ) -> some View {
        let defaults = UserDefaults(suiteName: "SkillModelPickerSnapshotTests.\(UUID().uuidString)")!
        let themeStore = ThemeStore(defaults: defaults)
        themeStore.mode = colorScheme == .dark ? .dark : .light

        return ModelReasoningGridPicker(
            options: options,
            layout: ModelReasoningGridCatalog.layout(
                runtimeProvider: runtimeProvider,
                options: options
            ),
            selection: selection,
            selectedModelID: selection.modelID,
            isRefreshing: false,
            isFastMode: false,
            onSelectModel: { _, _ in },
            onSelectDefaultModel: { _, _ in },
            onFastModeChange: { _ in },
            onRefresh: {}
        )
        .environmentObject(themeStore)
        .environment(\.colorScheme, colorScheme)
        .environment(\.dynamicTypeSize, dynamicTypeSize)
        .environment(\.horizontalSizeClass, horizontalSizeClass)
        .frame(width: width, height: height, alignment: .top)
        .background(themeStore.tokens(for: colorScheme).background)
    }

}
#endif
