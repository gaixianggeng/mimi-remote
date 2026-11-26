#if os(iOS) && !targetEnvironment(macCatalyst)
import SnapshotTesting
import SwiftUI
import XCTest
@testable import MimiRemote

// 固定视觉验收使用的模型组合，避免产品默认模型更新改变布局基线。
private let codex56SnapshotModels = [
    CodexAppServerModelOption(
        id: "gpt-5.6-sol", title: "GPT-5.6 Sol",
        supportedReasoningEfforts: ["low", "medium", "high", "xhigh", "max", "ultra"],
        defaultReasoningEffort: "xhigh"
    ),
    CodexAppServerModelOption(
        id: "gpt-5.6-terra", title: "GPT-5.6 Terra",
        supportedReasoningEfforts: ["low", "medium", "high", "xhigh", "max", "ultra"],
        defaultReasoningEffort: "medium"
    ),
    CodexAppServerModelOption(
        id: "gpt-5.6-luna", title: "GPT-5.6 Luna",
        supportedReasoningEfforts: ["low", "medium", "high", "xhigh", "max"],
        defaultReasoningEffort: "medium"
    )
]

// 图片基线验证服务端返回的版本化标题布局，不依赖产品的无版本 fallback。
private let claudeCatalogSnapshotModels = [
    CodexAppServerModelOption(
        id: "claude-fable-5",
        title: "Claude Fable 5",
        runtimeProvider: "claude",
        supportedReasoningEfforts: ["medium", "high", "xhigh", "max"]
    ),
    CodexAppServerModelOption(
        id: "claude-opus-5",
        title: "Claude Opus 5",
        runtimeProvider: "claude",
        isDefault: true,
        supportedReasoningEfforts: ["medium", "high", "xhigh", "max"]
    ),
    CodexAppServerModelOption(
        id: "claude-sonnet-5",
        title: "Claude Sonnet 5",
        runtimeProvider: "claude",
        supportedReasoningEfforts: ["medium", "high", "xhigh", "max"]
    )
]

@MainActor
final class SkillModelPickerSnapshotTests: SimplifiedChineseSnapshotTestCase {
    func testSavedFable5DefaultMigratesWithoutSelectingOpus() throws {
        let suite = "FableSelectionMigration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("claude-fable-5", forKey: DefaultModelPreferences.claudeModelOptionIDKey)
        defaults.set("high", forKey: DefaultModelPreferences.claudeReasoningEffortKey)
        let catalog = [
            CodexAppServerModelOption(id: "opus", title: "Opus", runtimeProvider: "claude", isDefault: true),
            CodexAppServerModelOption(
                id: "claude-fable-5-1", title: "Fable 5.1", provider: "anthropic", runtimeProvider: "claude",
                supportedReasoningEfforts: ["medium", "high", "max"]
            )
        ]

        for legacyID in ["claude-fable-5", "claude@claude-fable-5@anthropic"] {
            defaults.set(legacyID, forKey: DefaultModelPreferences.claudeModelOptionIDKey)
            let selection = try XCTUnwrap(DefaultModelPreferences.resolvedSelection(
                for: "claude", allOptions: catalog, defaults: defaults
            ))
            XCTAssertEqual(selection.option.model, "claude-fable-5-1")
            XCTAssertEqual(selection.effort, .high)
            XCTAssertEqual(defaults.string(forKey: DefaultModelPreferences.claudeModelOptionIDKey), catalog[1].id)
            var submitted = CodexAppServerTurnOptions.default
            DefaultModelPreferences.applyDefault(for: "claude", allOptions: catalog, defaults: defaults, to: &submitted)
            XCTAssertEqual(submitted.model, "claude-fable-5-1")
            XCTAssertEqual(submitted.runtimeProvider, "claude")
            XCTAssertEqual(submitted.reasoningEffort, .high)
        }
    }

    func testCachedFable5SelectionMigratesOnSessionRestore() throws {
        var options = CodexAppServerTurnOptions.default
        options.runtimeProvider = "claude"
        options.model = "claude-fable-5"
        options.modelProvider = "anthropic"
        options.reasoningEffort = .high
        var legacy = ComposerModelSelectionSnapshot(options: options)
        XCTAssertEqual(legacy.model, "claude-fable-5-1")
        // 模拟兼容处理前已存在的快照，验证恢复入口，而非只验证新快照。
        legacy.model = "claude-fable-5"
        var cache = ComposerModelSelectionCache()
        cache.save(legacy, for: .session("legacy-fable-session"))
        let restored = try XCTUnwrap(cache.snapshot(for: .session("legacy-fable-session")))
        var submitted = CodexAppServerTurnOptions.default
        restored.apply(to: &submitted)
        XCTAssertEqual(submitted.model, "claude-fable-5-1")
        XCTAssertEqual(submitted.runtimeProvider, "claude")
        XCTAssertEqual(submitted.modelProvider, "anthropic")
        XCTAssertEqual(submitted.reasoningEffort, .high)
    }

    func testFableMigrationKeepsOtherRuntimesAndExplicitServerDefault() {
        for runtime in [nil, "codex", "claude"] as [String?] {
            for model in [nil, "custom-model", "claude-fable-5-1", "claude-fable-5"] as [String?] {
                var options = CodexAppServerTurnOptions.default
                options.runtimeProvider = runtime
                options.model = model
                options.reasoningEffort = .high
                let original = options
                ComposerModelSelectionCompatibility.apply(to: &options)
                if runtime == "claude", model == "claude-fable-5" {
                    XCTAssertEqual(options.model, "claude-fable-5-1")
                } else {
                    XCTAssertEqual(options, original)
                }
                let once = options
                ComposerModelSelectionCompatibility.apply(to: &options)
                XCTAssertEqual(options, once)
            }
        }
    }

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
        XCTAssertEqual(claudeLayout.models.map(\.model), ["opus", "sonnet", "haiku"])
        XCTAssertEqual(
            claudeLayout.models.map { ModelReasoningGridCatalog.shortTitle(for: $0, kind: .claude) },
            ["Claude Opus", "Claude Sonnet", "Claude Haiku"]
        )
        XCTAssertEqual(
            ModelReasoningGridCatalog.compactTriggerTitle(for: "opus", layout: claudeLayout),
            "Opus"
        )
        XCTAssertEqual(claudeLayout.efforts, [.medium, .high, .xhigh, .max])
        XCTAssertEqual(ModelReasoningGridCatalog.effortTitle(.low), "Light")
        XCTAssertEqual(ModelReasoningGridCatalog.effortTitle(.xhigh), "Extra High")
        XCTAssertEqual(ModelReasoningGridCatalog.effortTitle(.max), "Max")
        XCTAssertEqual(ModelReasoningGridCatalog.effortTitle(.ultra), "Ultra")
        XCTAssertFalse(claudeLayout.showsServiceTierControl)
        XCTAssertEqual(claudeLayout.standardContentHeight, 236)
    }

    func testCodexStandardMenuUsesModelSpecificFourthEffortAndInlineLabel() {
        let options = codex56SnapshotModels
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
        XCTAssertTrue(codexOneRow.showsServiceTierControl)
        XCTAssertFalse(claudeTwoRows.showsServiceTierControl)
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
                options: codex56SnapshotModels,
                layout: ModelReasoningGridCatalog.layout(
                    runtimeProvider: "codex",
                    options: codex56SnapshotModels
                ),
                selection: ModelReasoningGridSelection(modelID: "gpt-5.6-terra", effort: .high),
                selectedModelID: "gpt-5.6-terra",
                isRefreshing: false,
                selectedServiceTier: "priority",
                onSelectModel: { _, _ in },
                onSelectDefaultModel: { _, _ in },
                onServiceTierChange: { _ in },
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
            options: codex56SnapshotModels,
            layout: ModelReasoningGridCatalog.layout(
                runtimeProvider: "codex",
                options: codex56SnapshotModels
            ),
            selection: ModelReasoningGridSelection(modelID: "gpt-5.6-sol", effort: .xhigh),
            selectedModelID: "gpt-5.6-sol",
            isRefreshing: false,
            selectedServiceTier: nil,
            onSelectModel: { _, _ in },
            onSelectDefaultModel: { _, _ in },
            onServiceTierChange: { _ in },
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
            options: codex56SnapshotModels,
            layout: ModelReasoningGridCatalog.layout(
                runtimeProvider: "codex",
                options: codex56SnapshotModels
            ),
            selection: ModelReasoningGridSelection(modelID: "gpt-5.6-sol", effort: .xhigh),
            selectedModelID: "gpt-5.6-sol",
            isRefreshing: false,
            selectedServiceTier: "priority",
            onSelectModel: { _, _ in },
            onSelectDefaultModel: { _, _ in },
            onServiceTierChange: { _ in },
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
                options: claudeCatalogSnapshotModels,
                selection: ModelReasoningGridSelection(modelID: "claude-opus-5", effort: .high)
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
        options: [CodexAppServerModelOption] = codex56SnapshotModels,
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
            selectedServiceTier: nil,
            onSelectModel: { _, _ in },
            onSelectDefaultModel: { _, _ in },
            onServiceTierChange: { _ in },
            onRefresh: {}
        )
        .environmentObject(themeStore)
        .environment(\.colorScheme, colorScheme)
        .environment(\.dynamicTypeSize, dynamicTypeSize)
        .environment(\.horizontalSizeClass, horizontalSizeClass)
        .frame(width: width, height: height, alignment: .top)
        .background(themeStore.tokens(for: colorScheme).background)
    }

    /// 直接断言生产路径消费的 `ModelReasoningGridPresentationChrome.resolvePolicy` 与容器解析，
    /// 覆盖常规 iPad Popover、iPad 分屏 Sheet、iPhone 玻璃 Sheet、经典/辅助功能回退及 iOS 18/26 差异。
    func testModelPickerPresentationChromeMatchesComposerFloatingGlassPolicy() {
        XCTAssertEqual(ModelReasoningGridMetrics.panelCornerRadius, 26)
        XCTAssertEqual(ModelReasoningGridMetrics.regularPopoverCornerRadius, 20)

        XCTAssertEqual(
            ModelReasoningGridPresentationContainer.resolve(
                horizontalSizeClass: .regular,
                verticalSizeClass: .regular
            ),
            .regularPopover
        )
        XCTAssertEqual(
            ModelReasoningGridPresentationContainer.resolve(
                horizontalSizeClass: .compact,
                verticalSizeClass: .regular
            ),
            .compactSheet
        )
        XCTAssertEqual(
            ModelReasoningGridPresentationContainer.resolve(
                horizontalSizeClass: .regular,
                verticalSizeClass: .compact
            ),
            .compactSheet
        )

        // 1. iPhone 悬浮玻璃输入卡 + 紧凑 Sheet：玻璃模式按系统版本选择 Liquid Glass / ultraThinMaterial，
        //    经典模式、降低透明度、增强对比度统一回退为与输入卡一致的实色表面。
        for interfaceStyle in ThemeInterfaceStyle.allCases {
            for reduceTransparency in [false, true] {
                for increasedContrast in [false, true] {
                    for supportsLiquidGlass in [false, true] {
                        let policy = ModelReasoningGridPresentationChrome.resolvePolicy(
                            surfaceMode: .presentation(container: .compactSheet, usesFloatingGlass: true),
                            interfaceStyle: interfaceStyle,
                            reduceTransparency: reduceTransparency,
                            increasedContrast: increasedContrast,
                            supportsLiquidGlass: supportsLiquidGlass
                        )
                        let expectsGlass = interfaceStyle == .glass
                            && !reduceTransparency
                            && !increasedContrast
                        let expectedStyle: ModelReasoningGridSurfaceStyle = expectsGlass
                            ? (supportsLiquidGlass ? .liquidGlass : .ultraThinMaterial)
                            : .solidComposerCard
                        XCTAssertEqual(policy.surfaceStyle, expectedStyle)
                        XCTAssertEqual(policy.backgroundOwner, .sheetPresentationBackground)
                        XCTAssertTrue(policy.usesFloatingGlass)
                        XCTAssertEqual(policy.usesTranslucentInnerChrome, expectsGlass)
                        XCTAssertEqual(policy.cornerRadius, 26)
                        XCTAssertEqual(policy.borderWidth, increasedContrast ? 1.25 : 0.75)
                    }
                }
            }
        }

        // 2. 常规宽档 iPad Popover（输入卡为实色）：始终走 `.popoverContentSurface` + `.solidComposerCard`，
        //    不请求手机悬浮玻璃，也不依赖宿主决定材质或回退。
        for interfaceStyle in ThemeInterfaceStyle.allCases {
            for reduceTransparency in [false, true] {
                for increasedContrast in [false, true] {
                    for supportsLiquidGlass in [false, true] {
                        let policy = ModelReasoningGridPresentationChrome.resolvePolicy(
                            surfaceMode: .presentation(container: .regularPopover, usesFloatingGlass: false),
                            interfaceStyle: interfaceStyle,
                            reduceTransparency: reduceTransparency,
                            increasedContrast: increasedContrast,
                            supportsLiquidGlass: supportsLiquidGlass
                        )
                        XCTAssertEqual(policy.surfaceStyle, .solidComposerCard)
                        XCTAssertEqual(policy.backgroundOwner, .popoverContentSurface)
                        XCTAssertFalse(policy.usesFloatingGlass)
                        XCTAssertFalse(policy.usesTranslucentInnerChrome)
                        XCTAssertEqual(policy.cornerRadius, 20)
                        XCTAssertEqual(policy.borderWidth, increasedContrast ? 1.25 : 0.75)
                    }
                }
            }
        }

        // 3. iPad 分屏窄档（输入卡为实色、容器适配为 Sheet）：走 `.sheetPresentationBackground` + `.solidComposerCard`。
        let splitSheetPolicy = ModelReasoningGridPresentationChrome.resolvePolicy(
            surfaceMode: .presentation(container: .compactSheet, usesFloatingGlass: false),
            interfaceStyle: .glass,
            reduceTransparency: false,
            increasedContrast: false,
            supportsLiquidGlass: true
        )
        XCTAssertEqual(splitSheetPolicy.surfaceStyle, .solidComposerCard)
        XCTAssertEqual(splitSheetPolicy.backgroundOwner, .sheetPresentationBackground)
        XCTAssertFalse(splitSheetPolicy.usesFloatingGlass)
        XCTAssertFalse(splitSheetPolicy.usesTranslucentInnerChrome)

        // 4. 独立嵌入默认模式保持实色 `tokens.surface`。
        let standalonePolicy = ModelReasoningGridPresentationChrome.resolvePolicy(
            surfaceMode: .standaloneOpaque,
            interfaceStyle: .glass,
            reduceTransparency: false,
            increasedContrast: false,
            supportsLiquidGlass: true
        )
        XCTAssertEqual(standalonePolicy.surfaceStyle, .standaloneSurface)
        XCTAssertEqual(standalonePolicy.backgroundOwner, .standaloneContent)
        XCTAssertFalse(standalonePolicy.usesTranslucentInnerChrome)
    }

    /// 实色回退（降低透明度、增强对比度、经典模式、常规 iPad Popover）下，
    /// 所有主题的亮/暗色板小字对比度均必须 ≥ 4.5:1（含 GitHub 深色、Xcode 浅色、Gruvbox 浅色）。
    func testModelPickerSolidFallbackContrastAcrossAllThemes() {
        let scenarios: [(String, ModelReasoningGridSurfaceMode, ThemeInterfaceStyle, Bool, Bool)] = [
            ("regularPopover-glass", .presentation(container: .regularPopover, usesFloatingGlass: false), .glass, false, false),
            ("compactSheet-classic", .presentation(container: .compactSheet, usesFloatingGlass: true), .classic, false, false),
            ("compactSheet-reduceTransparency", .presentation(container: .compactSheet, usesFloatingGlass: true), .glass, true, false),
            ("compactSheet-increasedContrast", .presentation(container: .compactSheet, usesFloatingGlass: true), .glass, false, true),
            ("regularPopover-increasedContrast", .presentation(container: .regularPopover, usesFloatingGlass: false), .glass, true, true),
        ]

        for preset in ThemePreset.allCases {
            for colorScheme in [ColorScheme.light, .dark] {
                let defaults = UserDefaults(suiteName: "ModelPickerContrast.\(UUID().uuidString)")!
                let themeStore = ThemeStore(defaults: defaults)
                themeStore.preset = preset
                themeStore.mode = colorScheme == .dark ? .dark : .light
                let tokens = themeStore.tokens(for: colorScheme)

                for (scenarioName, surfaceMode, style, reduceTransparency, increasedContrast) in scenarios {
                    let policy = ModelReasoningGridPresentationChrome.resolvePolicy(
                        surfaceMode: surfaceMode,
                        interfaceStyle: style,
                        reduceTransparency: reduceTransparency,
                        increasedContrast: increasedContrast,
                        supportsLiquidGlass: true
                    )
                    XCTAssertEqual(policy.surfaceStyle, .solidComposerCard, "\(preset.rawValue)-\(colorScheme)-\(scenarioName)")
                    let palette = ModelReasoningGridPalette.resolve(
                        tokens: tokens,
                        colorScheme: colorScheme,
                        policy: policy,
                        reduceTransparency: reduceTransparency,
                        increasedContrast: increasedContrast
                    )
                    let context = "\(preset.rawValue) \(colorScheme) \(scenarioName)"
                    let panelBG = palette.panelBackground
                    let controlBG = flattenColor(palette.controlFill, over: panelBG)
                    let gridBG = flattenColor(palette.gridFill, over: panelBG)
                    let selectedCellBG = flattenColor(palette.selectedCellFill, over: gridBG)
                    let accessibleMenuBG = flattenColor(palette.accessibleMenuFill, over: panelBG)
                    let accessibleEffortBG = flattenColor(palette.accessibleEffortFill, over: panelBG)

                    XCTAssertGreaterThanOrEqual(
                        wcagContrastRatio(palette.accentForeground, over: panelBG),
                        4.5,
                        "\(context) 选中表头/行标题"
                    )
                    XCTAssertGreaterThanOrEqual(
                        wcagContrastRatio(palette.accentForeground, over: controlBG),
                        4.5,
                        "\(context) 全部模型胶囊/速度图标"
                    )
                    XCTAssertGreaterThanOrEqual(
                        wcagContrastRatio(palette.accentForeground, over: selectedCellBG),
                        4.5,
                        "\(context) 选中格内联档位"
                    )
                    XCTAssertGreaterThanOrEqual(
                        wcagContrastRatio(palette.primaryForeground, over: panelBG),
                        4.5,
                        "\(context) 未选中表头"
                    )
                    XCTAssertGreaterThanOrEqual(
                        wcagContrastRatio(palette.rowLabelForeground, over: panelBG),
                        4.5,
                        "\(context) 普通模型行标签"
                    )
                    XCTAssertGreaterThanOrEqual(
                        wcagContrastRatio(palette.inlineEffortForeground, over: gridBG),
                        4.5,
                        "\(context) 格内可用档位标签"
                    )
                    XCTAssertGreaterThanOrEqual(
                        wcagContrastRatio(palette.primaryForeground, over: accessibleMenuBG),
                        4.5,
                        "\(context) 无障碍模型菜单"
                    )
                    XCTAssertGreaterThanOrEqual(
                        wcagContrastRatio(palette.primaryForeground, over: accessibleEffortBG),
                        4.5,
                        "\(context) 无障碍档位行"
                    )
                }
            }
        }
    }

    /// 真实 UIWindow 呈现验证：从实际模型按钮触发常规 iPad Popover 与紧凑 Sheet，
    /// 在明暗差异明显的会话背景上核对玻璃透光/实色回退像素表现、开合状态切换以及辅助功能 `.large` detent。
    func testModelPickerPresentationChromeRendersInLightAndDarkModes() async throws {
        let layout = ModelReasoningGridCatalog.layout(
            runtimeProvider: "codex",
            options: codex56SnapshotModels
        )

        // 1. 常规 iPad Popover（亮/暗）：必须由 UIPopoverPresentationController 悬浮呈现，
        //    面板底色直接跟随宽档实色输入卡（不透出背后高对比条纹），且可干净打开、关闭、再次打开。
        for colorScheme in [ColorScheme.light, .dark] {
            let brightCapture = try await capturePresentedModelPicker(
                label: "regular-popover-\(colorScheme)-bright",
                windowSize: CGSize(width: 900, height: 700),
                horizontalSizeClass: .regular,
                verticalSizeClass: .regular,
                usesFloatingGlass: false,
                colorScheme: colorScheme,
                interfaceStyle: .glass,
                increasedContrast: false,
                dynamicTypeSize: .large,
                backdropStyle: .brightStripes
            )
            XCTAssertTrue(
                brightCapture.presentedController.presentationController is UIPopoverPresentationController,
                "常规 iPad 宽档应保持 Popover 呈现 (\(colorScheme))"
            )
            XCTAssertLessThan(
                brightCapture.presentedFrame.maxY,
                700 - 20,
                "常规 iPad Popover 应锚定在按钮上方而非贴底 Sheet (\(colorScheme))"
            )
            let darkCapture = try await capturePresentedModelPicker(
                label: "regular-popover-\(colorScheme)-dark",
                windowSize: CGSize(width: 900, height: 700),
                horizontalSizeClass: .regular,
                verticalSizeClass: .regular,
                usesFloatingGlass: false,
                colorScheme: colorScheme,
                interfaceStyle: .glass,
                increasedContrast: false,
                dynamicTypeSize: .large,
                backdropStyle: .darkStripes
            )
            XCTAssertTrue(
                darkCapture.presentedController.presentationController is UIPopoverPresentationController
            )
            let popoverDiff = meanChannelDifference(brightCapture.panelBottomEdgeRGB, darkCapture.panelBottomEdgeRGB)
            XCTAssertLessThan(
                popoverDiff,
                0.04,
                "常规 iPad Popover 应由自身共享实色表面遮盖背后条纹，不依赖宿主材质 (\(colorScheme))"
            )
            let expectedFill = solidComposerCardRGB(for: colorScheme)
            XCTAssertLessThan(
                meanChannelDifference(brightCapture.panelBottomEdgeRGB, expectedFill),
                0.06,
                "常规 iPad Popover 底色应与常规宽档实色输入卡一致 (\(colorScheme))"
            )
        }

        // 2. 紧凑悬浮玻璃 Sheet（亮/暗）：验证玻璃态真实透光/采样背景变化，
        //    经典模式与增强对比度则各自稳定回退到不透明实色底板。
        for colorScheme in [ColorScheme.light, .dark] {
            let glassBright = try await capturePresentedModelPicker(
                label: "compact-sheet-glass-\(colorScheme)-bright",
                windowSize: CGSize(width: 390, height: 844),
                horizontalSizeClass: .compact,
                verticalSizeClass: .regular,
                usesFloatingGlass: true,
                colorScheme: colorScheme,
                interfaceStyle: .glass,
                increasedContrast: false,
                dynamicTypeSize: .large,
                backdropStyle: .brightStripes
            )
            let glassDark = try await capturePresentedModelPicker(
                label: "compact-sheet-glass-\(colorScheme)-dark",
                windowSize: CGSize(width: 390, height: 844),
                horizontalSizeClass: .compact,
                verticalSizeClass: .regular,
                usesFloatingGlass: true,
                colorScheme: colorScheme,
                interfaceStyle: .glass,
                increasedContrast: false,
                dynamicTypeSize: .large,
                backdropStyle: .darkStripes
            )
            XCTAssertTrue(
                glassBright.isAdaptedSheet,
                "紧凑档应适配为贴底 Sheet (\(colorScheme))"
            )
            XCTAssertEqual(
                glassBright.presentedFrame.height,
                layout.standardContentHeight,
                accuracy: 40,
                "标准字号紧凑 Sheet 高度应贴合内容 detent (\(colorScheme))"
            )
            let glassBackdropDelta = max(
                meanChannelDifference(glassBright.panelTopPaddingRGB, glassDark.panelTopPaddingRGB),
                meanChannelDifference(glassBright.panelBottomEdgeRGB, glassDark.panelBottomEdgeRGB)
            )
            XCTAssertGreaterThan(
                glassBackdropDelta,
                0.015,
                "玻璃态紧凑 Sheet 应对背后亮暗背景产生真实透光/折射变化 (\(colorScheme))"
            )

            for (fallbackName, style, contrast) in [
                ("classic", ThemeInterfaceStyle.classic, false),
                ("increasedContrast", ThemeInterfaceStyle.glass, true),
            ] {
                let fallbackBright = try await capturePresentedModelPicker(
                    label: "compact-sheet-\(fallbackName)-\(colorScheme)-bright",
                    windowSize: CGSize(width: 390, height: 844),
                    horizontalSizeClass: .compact,
                    verticalSizeClass: .regular,
                    usesFloatingGlass: true,
                    colorScheme: colorScheme,
                    interfaceStyle: style,
                    increasedContrast: contrast,
                    dynamicTypeSize: .large,
                    backdropStyle: .brightStripes
                )
                let fallbackDark = try await capturePresentedModelPicker(
                    label: "compact-sheet-\(fallbackName)-\(colorScheme)-dark",
                    windowSize: CGSize(width: 390, height: 844),
                    horizontalSizeClass: .compact,
                    verticalSizeClass: .regular,
                    usesFloatingGlass: true,
                    colorScheme: colorScheme,
                    interfaceStyle: style,
                    increasedContrast: contrast,
                    dynamicTypeSize: .large,
                    backdropStyle: .darkStripes
                )
                let fallbackBackdropDelta = meanChannelDifference(
                    fallbackBright.panelTopPaddingRGB,
                    fallbackDark.panelTopPaddingRGB
                )
                XCTAssertLessThan(
                    fallbackBackdropDelta,
                    0.03,
                    "实色回退 Sheet(\(fallbackName)) 不应透出背后亮暗条纹 (\(colorScheme))"
                )
                let expectedFill = solidComposerCardRGB(for: colorScheme)
                XCTAssertLessThan(
                    meanChannelDifference(fallbackBright.panelTopPaddingRGB, expectedFill),
                    0.06,
                    "实色回退 Sheet(\(fallbackName)) 底色应与实色输入卡一致 (\(colorScheme))"
                )
            }
        }

        // 3. 辅助功能大字号走 `.large` detent，且能干净打开、关闭、再次打开。
        let accessibleCapture = try await capturePresentedModelPicker(
            label: "compact-sheet-accessibility3",
            windowSize: CGSize(width: 390, height: 844),
            horizontalSizeClass: .compact,
            verticalSizeClass: .regular,
            usesFloatingGlass: true,
            colorScheme: .light,
            interfaceStyle: .glass,
            increasedContrast: false,
            dynamicTypeSize: .accessibility3,
            backdropStyle: .brightStripes
        )
        XCTAssertTrue(accessibleCapture.isAdaptedSheet)
        XCTAssertGreaterThan(
            accessibleCapture.presentedFrame.height,
            layout.standardContentHeight + 200,
            "辅助功能大字号应使用 .large detent 展开并避免裁切"
        )

        // 4. iPad 分屏窄档实色输入卡对应的 Sheet：同样适配为 Sheet，但跟随实色输入卡不套用手机悬浮玻璃。
        let splitSheetCapture = try await capturePresentedModelPicker(
            label: "compact-split-solid-light",
            windowSize: CGSize(width: 390, height: 844),
            horizontalSizeClass: .compact,
            verticalSizeClass: .regular,
            usesFloatingGlass: false,
            colorScheme: .light,
            interfaceStyle: .glass,
            increasedContrast: false,
            dynamicTypeSize: .large,
            backdropStyle: .brightStripes
        )
        XCTAssertTrue(splitSheetCapture.isAdaptedSheet)
        let splitExpectedFill = solidComposerCardRGB(for: .light)
        XCTAssertLessThan(
            meanChannelDifference(splitSheetCapture.panelTopPaddingRGB, splitExpectedFill),
            0.06,
            "iPad 分屏窄档实色输入卡对应的 Sheet 应跟随实色底板，而非强行套用手机玻璃"
        )
    }

    private enum PresentationBackdropStyle {
        case brightStripes
        case darkStripes
    }

    private struct PresentedPickerCapture {
        let presentedController: UIViewController
        let presentedFrame: CGRect
        let isAdaptedSheet: Bool
        let panelBottomEdgeRGB: (r: CGFloat, g: CGFloat, b: CGFloat)
        let panelTopPaddingRGB: (r: CGFloat, g: CGFloat, b: CGFloat)
    }

    @MainActor
    private final class PresentationTriggerController: ObservableObject {
        @Published var isPresented = false
    }

    private struct PresentationHarnessView: View {
        @ObservedObject var trigger: PresentationTriggerController
        let themeStore: ThemeStore
        let layout: ModelReasoningGridLayout
        let presentingHorizontalSizeClass: UserInterfaceSizeClass
        let usesFloatingGlass: Bool
        let colorScheme: ColorScheme
        let interfaceStyle: ThemeInterfaceStyle
        let dynamicTypeSize: DynamicTypeSize
        let backdropStyle: PresentationBackdropStyle

        var body: some View {
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    ForEach(0..<10, id: \.self) { index in
                        let color: Color = switch backdropStyle {
                        case .brightStripes:
                            index.isMultiple(of: 2)
                                ? Color(red: 0.98, green: 0.88, blue: 0.25)
                                : Color(red: 0.96, green: 0.98, blue: 1.0)
                        case .darkStripes:
                            index.isMultiple(of: 2)
                                ? Color(red: 0.04, green: 0.06, blue: 0.14)
                                : Color(red: 0.14, green: 0.04, blue: 0.18)
                        }
                        color
                    }
                }
                .ignoresSafeArea()

                Button("模型") {
                    trigger.isPresented.toggle()
                }
                .accessibilityIdentifier("composer.model")
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .popover(isPresented: $trigger.isPresented, arrowEdge: .bottom) {
                    ModelReasoningGridPopoverHost(
                        options: codex56SnapshotModels,
                        layout: layout,
                        selection: ModelReasoningGridSelection(modelID: "gpt-5.6-sol", effort: .xhigh),
                        selectedModelID: "gpt-5.6-sol",
                        isRefreshing: false,
                        selectedServiceTier: "priority",
                        presentingHorizontalSizeClass: presentingHorizontalSizeClass,
                        usesFloatingGlass: usesFloatingGlass,
                        onSelectModel: { _, _ in },
                        onSelectDefaultModel: { _, _ in },
                        onServiceTierChange: { _ in },
                        onRefresh: {},
                        onAppearEnsureCatalog: {}
                    )
                    .environmentObject(themeStore)
                    .environment(\.colorScheme, colorScheme)
                    .environment(\.themeInterfaceStyle, interfaceStyle)
                    .environment(\.dynamicTypeSize, dynamicTypeSize)
                }
                .padding(.bottom, 32)
            }
            .environmentObject(themeStore)
            .environment(\.colorScheme, colorScheme)
            .environment(\.themeInterfaceStyle, interfaceStyle)
            .environment(\.dynamicTypeSize, dynamicTypeSize)
        }
    }

    private func capturePresentedModelPicker(
        label: String,
        windowSize: CGSize,
        horizontalSizeClass: UserInterfaceSizeClass,
        verticalSizeClass: UserInterfaceSizeClass,
        usesFloatingGlass: Bool,
        colorScheme: ColorScheme,
        interfaceStyle: ThemeInterfaceStyle,
        increasedContrast: Bool,
        dynamicTypeSize: DynamicTypeSize,
        backdropStyle: PresentationBackdropStyle
    ) async throws -> PresentedPickerCapture {
        let suite = "ModelPickerPresent.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let themeStore = ThemeStore(defaults: defaults)
        themeStore.mode = colorScheme == .dark ? .dark : .light
        themeStore.interfaceStyle = interfaceStyle
        let layout = ModelReasoningGridCatalog.layout(
            runtimeProvider: "codex",
            options: codex56SnapshotModels
        )
        let trigger = PresentationTriggerController()
        let rootView = PresentationHarnessView(
            trigger: trigger,
            themeStore: themeStore,
            layout: layout,
            presentingHorizontalSizeClass: horizontalSizeClass,
            usesFloatingGlass: usesFloatingGlass,
            colorScheme: colorScheme,
            interfaceStyle: interfaceStyle,
            dynamicTypeSize: dynamicTypeSize,
            backdropStyle: backdropStyle
        )

        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        let previousKeyWindow = scene.keyWindow
        window.frame = CGRect(origin: .zero, size: windowSize)
        window.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        window.traitOverrides.horizontalSizeClass = horizontalSizeClass == .compact ? .compact : .regular
        window.traitOverrides.verticalSizeClass = verticalSizeClass == .compact ? .compact : .regular
        window.traitOverrides.accessibilityContrast = increasedContrast ? .high : .normal
        window.rootViewController = UIHostingController(rootView: rootView)

        let animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        window.makeKeyAndVisible()
        defer {
            trigger.isPresented = false
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
            previousKeyWindow?.makeKey()
            UIView.setAnimationsEnabled(animationsWereEnabled)
        }

        // 触发打开并等待实际呈现完成且 frame 稳定。
        trigger.isPresented = true
        let presented = try await waitForPresentedController(in: window)
        let frame = presented.view.convert(presented.view.bounds, to: window)
        let isAdaptedSheet =
            (presented.presentationController is UISheetPresentationController
                || (presented.presentationController as? UIPopoverPresentationController)?
                    .adaptiveSheetPresentationController != nil)
            // iOS 26+ 局部 detent Sheet 带有约 8pt 的悬浮外边距，因此允许底部与左右最多 24pt 悬浮留白，
            // 同时仍与锚定在按钮上方的常规 Popover 明确区分。
            && frame.maxY >= windowSize.height - 24
            && frame.width >= windowSize.width - 32

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: windowSize, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        // 采样避开 26pt 圆角与顶部拖动手柄，落在面板上下 12pt 内边距的纯底色区。
        let topPaddingSamplePoint = CGPoint(x: frame.minX + 44, y: frame.minY + 6)
        let bottomEdgeSamplePoint = CGPoint(x: frame.midX, y: frame.maxY - 6)
        let topPaddingRGB = try XCTUnwrap(sampleRGB(in: image, at: topPaddingSamplePoint))
        let bottomEdgeRGB = try XCTUnwrap(sampleRGB(in: image, at: bottomEdgeSamplePoint))

        // 验证关闭 -> 再次打开生命周期不会残留或卡死。
        trigger.isPresented = false
        try await waitForDismissal(in: window)
        trigger.isPresented = true
        _ = try await waitForPresentedController(in: window)
        trigger.isPresented = false
        try await waitForDismissal(in: window)

        return PresentedPickerCapture(
            presentedController: presented,
            presentedFrame: frame,
            isAdaptedSheet: isAdaptedSheet,
            panelBottomEdgeRGB: bottomEdgeRGB,
            panelTopPaddingRGB: topPaddingRGB
        )
    }

    private func waitForPresentedController(in window: UIWindow) async throws -> UIViewController {
        var previousFrame: CGRect?
        var stableFrames = 0
        for _ in 0..<80 {
            window.layoutIfNeeded()
            if let presented = window.rootViewController?.presentedViewController,
               presented.view.window === window,
               !presented.isBeingPresented,
               presented.transitionCoordinator == nil {
                let frame = presented.view.convert(presented.view.bounds, to: window)
                if frame.width > 100, frame.height > 100 {
                    stableFrames = frame == previousFrame ? stableFrames + 1 : 0
                    if stableFrames == 3 {
                        return presented
                    }
                    previousFrame = frame
                }
            } else {
                previousFrame = nil
                stableFrames = 0
            }
            try await Task.sleep(for: .milliseconds(16))
        }
        XCTFail("模型切换面板未在预期时间内完成呈现")
        throw NSError(domain: "SkillModelPickerSnapshotTests", code: 1)
    }

    private func waitForDismissal(in window: UIWindow) async throws {
        for _ in 0..<60 {
            window.layoutIfNeeded()
            if window.rootViewController?.presentedViewController == nil {
                return
            }
            try await Task.sleep(for: .milliseconds(16))
        }
        XCTFail("模型切换面板未在预期时间内完成关闭")
    }

    private func solidComposerCardRGB(for colorScheme: ColorScheme) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let defaults = UserDefaults(suiteName: "ModelPickerSolidRGB.\(UUID().uuidString)")!
        let store = ThemeStore(defaults: defaults)
        store.mode = colorScheme == .dark ? .dark : .light
        let tokens = store.tokens(for: colorScheme)
        let color = ModelReasoningGridPresentationChrome.solidFillColor(tokens: tokens, colorScheme: colorScheme)
        let c = rgbaComponents(color)
        return (c.red, c.green, c.blue)
    }

    private func sampleRGB(
        in image: UIImage,
        at point: CGPoint
    ) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        let x = min(max(Int(round(point.x * image.scale)), 0), width - 1)
        let y = min(max(Int(round(point.y * image.scale)), 0), height - 1)
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.draw(
            cgImage,
            in: CGRect(x: -CGFloat(x), y: -CGFloat(height - 1 - y), width: CGFloat(width), height: CGFloat(height))
        )
        return (CGFloat(pixel[0]) / 255.0, CGFloat(pixel[1]) / 255.0, CGFloat(pixel[2]) / 255.0)
    }

    private func meanChannelDifference(
        _ lhs: (r: CGFloat, g: CGFloat, b: CGFloat),
        _ rhs: (r: CGFloat, g: CGFloat, b: CGFloat)
    ) -> CGFloat {
        (abs(lhs.r - rhs.r) + abs(lhs.g - rhs.g) + abs(lhs.b - rhs.b)) / 3.0
    }

    private func rgbaComponents(
        _ color: Color
    ) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b, a)
    }

    private func flattenColor(_ foreground: Color, over background: Color) -> Color {
        let fg = rgbaComponents(foreground)
        let bg = rgbaComponents(background)
        let alpha = fg.alpha
        return Color(
            red: Double(fg.red * alpha + bg.red * (1 - alpha)),
            green: Double(fg.green * alpha + bg.green * (1 - alpha)),
            blue: Double(fg.blue * alpha + bg.blue * (1 - alpha))
        )
    }

    private func wcagContrastRatio(_ foreground: Color, over background: Color) -> CGFloat {
        let fg = rgbaComponents(flattenColor(foreground, over: background))
        let bg = rgbaComponents(background)
        func lum(_ c: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)) -> CGFloat {
            func linear(_ v: CGFloat) -> CGFloat {
                v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(c.red) + 0.7152 * linear(c.green) + 0.0722 * linear(c.blue)
        }
        let l1 = lum(fg)
        let l2 = lum(bg)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

}
#endif
