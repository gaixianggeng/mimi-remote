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
                        let expectedCardSurface = ComposerCardResolvedSurface.resolve(
                            usesFloatingGlass: true,
                            interfaceStyle: interfaceStyle,
                            reduceTransparency: reduceTransparency,
                            increasedContrast: increasedContrast,
                            supportsLiquidGlass: supportsLiquidGlass
                        )
                        XCTAssertEqual(policy.surfaceStyle, expectedStyle)
                        XCTAssertEqual(policy.surfaceStyle.composerCardSurface, expectedCardSurface)
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
                        XCTAssertEqual(policy.surfaceStyle.composerCardSurface, .solidCard)
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
    /// 所有主题的亮/暗色板小字对比度均必须 ≥ 4.5:1（含 GitHub 深色、Xcode 浅色、Gruvbox 浅色），
    /// 且选中带内联档位标签的格子（GPT-5.6 Luna `max`）时，选中圆点与光晕必须完全避开标签文字，
    /// 避免不透明覆盖层遮挡文字导致真实对比度失真。
    func testModelPickerSolidFallbackContrastAcrossAllThemes() throws {
        let codexLayout = ModelReasoningGridCatalog.layout(
            runtimeProvider: "codex",
            options: codex56SnapshotModels
        )
        let lunaMax = ModelReasoningGridSelection(modelID: "gpt-5.6-luna", effort: .max)
        let gridHeight = CGFloat(codexLayout.modelRowCount) * ModelReasoningGridMetrics.modelRowHeight
        for panelWidth in [CGFloat(320), CGFloat(390), CGFloat(420)] {
            let gridWidth = panelWidth
                - ModelReasoningGridMetrics.contentPadding * 2
                - ModelReasoningGridMetrics.modelLabelWidth
                - ModelReasoningGridMetrics.gridSpacing
            let gridSize = CGSize(width: gridWidth, height: gridHeight)
            let lens = try XCTUnwrap(codexLayout.selectionLensGeometry(for: lunaMax, size: gridSize))
            let labelFrame = try XCTUnwrap(
                codexLayout.inlineEffortLabelFrame(for: lunaMax, isSelected: true, size: gridSize)
            )
            XCTAssertTrue(lens.avoidsInlineLabel, "选中 Luna max 时圆点应切换到避让内联标签模式 (width=\(panelWidth))")
            XCTAssertFalse(
                lens.lensFrame.intersects(labelFrame),
                "不透明选中圆点不得与 Luna max 内联标签重叠 (width=\(panelWidth))"
            )
            XCTAssertFalse(
                lens.haloFrame.intersects(labelFrame),
                "选中圆点外环光晕不得覆盖 Luna max 内联标签 (width=\(panelWidth))"
            )
            XCTAssertGreaterThanOrEqual(
                labelFrame.minY - lens.lensFrame.maxY,
                8,
                "选中圆点底部与内联标签顶部之间应保留清晰留白 (width=\(panelWidth))"
            )

            // 网格拖出取消边界外（超过 12pt）必须返回 nil，松手时取消本次拖拽并恢复原选择。
            XCTAssertEqual(
                codexLayout.dragCandidate(at: CGPoint(x: gridSize.width - 8, y: gridSize.height - 8), size: gridSize),
                lunaMax
            )
            XCTAssertNil(
                codexLayout.dragCandidate(at: CGPoint(x: gridSize.width + 20, y: gridSize.height / 2), size: gridSize),
                "拖出网格右侧取消边界外应取消候选"
            )
            XCTAssertNil(
                codexLayout.dragCandidate(at: CGPoint(x: gridSize.width / 2, y: -20), size: gridSize),
                "拖出网格顶部取消边界外应取消候选"
            )
        }

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

    /// 选中 GPT-5.6 Luna `max` 时的实色回退快照与像素非遮挡验证（浅色 Codex 与深色 GitHub）。
    func testModelPickerLunaMaxSelectedSolidFallbackAppearance() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad)
        let lunaMax = ModelReasoningGridSelection(modelID: "gpt-5.6-luna", effort: .max)
        let layout = ModelReasoningGridCatalog.layout(
            runtimeProvider: "codex",
            options: codex56SnapshotModels
        )
        let cases: [(name: String, preset: ThemePreset, colorScheme: ColorScheme)] = [
            ("luna-max-solid-light", .codex, .light),
            ("luna-max-solid-github-dark", .github, .dark),
        ]

        for testCase in cases {
            let defaults = UserDefaults(suiteName: "LunaMaxSnapshot.\(UUID().uuidString)")!
            let themeStore = ThemeStore(defaults: defaults)
            themeStore.preset = testCase.preset
            themeStore.mode = testCase.colorScheme == .dark ? .dark : .light
            themeStore.interfaceStyle = .classic
            let tokens = themeStore.tokens(for: testCase.colorScheme)

            let pickerView = ModelReasoningGridPicker(
                options: codex56SnapshotModels,
                layout: layout,
                selection: lunaMax,
                selectedModelID: lunaMax.modelID,
                isRefreshing: false,
                selectedServiceTier: "priority",
                surfaceMode: .presentation(container: .regularPopover, usesFloatingGlass: false),
                onSelectModel: { _, _ in },
                onSelectDefaultModel: { _, _ in },
                onServiceTierChange: { _ in },
                onRefresh: {}
            )
            .environmentObject(themeStore)
            .environment(\.colorScheme, testCase.colorScheme)
            .environment(\.themeInterfaceStyle, .classic)
            .environment(\.horizontalSizeClass, .regular)
            .frame(width: 400, height: layout.standardContentHeight, alignment: .top)

            assertSnapshot(
                of: pickerView,
                as: .image(
                    precision: 0.98,
                    layout: .fixed(width: 400, height: layout.standardContentHeight),
                    traits: UITraitCollection(displayScale: 2)
                ),
                named: testCase.name
            )

            // 通过真实 UIWindow + UIHostingController 渲染采样（SwiftUI ImageRenderer 会跳过 ScrollView），
            // 确认 Luna max 格顶部是强调色圆点、底部标签区域未被不透明圆点涂成实心强调色。
            let scene = try XCTUnwrap(
                UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            )
            let renderSize = CGSize(width: 400, height: layout.standardContentHeight)
            let window = UIWindow(windowScene: scene)
            let previousKeyWindow = scene.keyWindow
            window.frame = CGRect(origin: .zero, size: renderSize)
            window.overrideUserInterfaceStyle = testCase.colorScheme == .dark ? .dark : .light
            let host = UIHostingController(rootView: pickerView)
            host.safeAreaRegions = []
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                previousKeyWindow?.makeKey()
            }
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            let rendered = renderWindowImage(window, scale: 2)
            exportDebugImageIfRequested(rendered, name: testCase.name)
            let gridOriginX = ModelReasoningGridMetrics.contentPadding
                + ModelReasoningGridMetrics.modelLabelWidth
                + ModelReasoningGridMetrics.gridSpacing
            let gridOriginY = ModelReasoningGridMetrics.contentPadding
                + ModelReasoningGridMetrics.effortHeaderHeight
            let gridWidth = 400 - gridOriginX - ModelReasoningGridMetrics.contentPadding
            let gridHeight = CGFloat(layout.modelRowCount) * ModelReasoningGridMetrics.modelRowHeight
            let gridSize = CGSize(width: gridWidth, height: gridHeight)
            let lens = try XCTUnwrap(layout.selectionLensGeometry(for: lunaMax, size: gridSize))
            let labelFrame = try XCTUnwrap(layout.inlineEffortLabelFrame(for: lunaMax, isSelected: true, size: gridSize))

            let dotSample = try XCTUnwrap(
                sampleRGB(in: rendered, at: CGPoint(x: gridOriginX + lens.center.x, y: gridOriginY + lens.center.y))
            )
            // 采样底部标签行左右留白处（避开字形笔画本身），确认该区域落回浅色调的选中格底色而非不透明强调色圆点。
            let labelClearSample = try XCTUnwrap(
                sampleRGB(
                    in: rendered,
                    at: CGPoint(x: gridOriginX + labelFrame.minX + 4, y: gridOriginY + labelFrame.midY)
                )
            )
            let accentRGBA = rgbaComponents(tokens.accent)
            let accentRGB = (accentRGBA.red, accentRGBA.green, accentRGBA.blue)
            XCTAssertLessThan(
                meanChannelDifference(dotSample, accentRGB),
                0.28,
                "\(testCase.name) 顶部圆点中心应呈现主题强调色"
            )
            XCTAssertGreaterThan(
                meanChannelDifference(labelClearSample, dotSample),
                0.15,
                "\(testCase.name) 底部内联标签区域不得被不透明强调色圆点覆盖"
            )
        }
    }

    /// 策略矩阵解析出的 `.liquidGlass`、`.ultraThinMaterial` 与 `.solidComposerCard` 直接驱动
    /// `ModelReasoningGridPresentationBackground` 渲染：验证两个系统材质分支都能对锐利条纹边界产生真实模糊，
    /// 而实色回退完全遮蔽背后条纹。
    func testModelPickerPresentationBackgroundRendersResolvedMaterialStyles() async throws {
        let windowSize = CGSize(width: 390, height: 420)
        let stripeSplitY: CGFloat = 210
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )

        struct MaterialProbe {
            let name: String
            let supportsLiquidGlass: Bool
            let interfaceStyle: ThemeInterfaceStyle
            let expectedStyle: ModelReasoningGridSurfaceStyle
        }

        let probes: [MaterialProbe] = [
            MaterialProbe(name: "liquidGlass", supportsLiquidGlass: true, interfaceStyle: .glass, expectedStyle: .liquidGlass),
            MaterialProbe(name: "ultraThinMaterial", supportsLiquidGlass: false, interfaceStyle: .glass, expectedStyle: .ultraThinMaterial),
            MaterialProbe(name: "solidComposerCard", supportsLiquidGlass: true, interfaceStyle: .classic, expectedStyle: .solidComposerCard),
        ]

        for probe in probes {
            let suite = "MaterialDrive.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            let themeStore = ThemeStore(defaults: defaults)
            themeStore.mode = .light
            themeStore.interfaceStyle = probe.interfaceStyle
            let tokens = themeStore.tokens(for: .light)
            let policy = ModelReasoningGridPresentationChrome.resolvePolicy(
                surfaceMode: .presentation(container: .compactSheet, usesFloatingGlass: true),
                interfaceStyle: probe.interfaceStyle,
                reduceTransparency: false,
                increasedContrast: false,
                supportsLiquidGlass: probe.supportsLiquidGlass
            )
            XCTAssertEqual(policy.surfaceStyle, probe.expectedStyle)

            let root = ZStack {
                // 锐利的高对比黑白双色边界横穿面板中部，用于同时测量透光性与条纹边界模糊度。
                VStack(spacing: 0) {
                    Color(red: 0.99, green: 0.99, blue: 0.96)
                        .frame(height: stripeSplitY)
                    Color(red: 0.04, green: 0.06, blue: 0.14)
                        .frame(maxHeight: .infinity)
                }
                .ignoresSafeArea()

                ModelReasoningGridPresentationBackground(
                    policy: policy,
                    tokens: tokens,
                    colorScheme: .light,
                    reduceTransparency: false,
                    increasedContrast: false
                )
                .environment(\.themeInterfaceStyle, probe.interfaceStyle)
                .frame(width: 220, height: 180)
                .position(x: windowSize.width / 2, y: stripeSplitY)
            }

            let window = UIWindow(windowScene: scene)
            let previousKeyWindow = scene.keyWindow
            window.frame = CGRect(origin: .zero, size: windowSize)
            window.overrideUserInterfaceStyle = .light
            window.rootViewController = UIHostingController(rootView: root)
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                previousKeyWindow?.makeKey()
            }

            try await Task.sleep(for: .milliseconds(80))
            window.layoutIfNeeded()
            let image = renderWindowImage(window, scale: 1)
            exportDebugImageIfRequested(image, name: "material-\(probe.name)")

            // 左侧裸露条纹边界（x = 24）作为锐利未模糊基准。
            let exposedGradient = maxVerticalGradient(
                in: image,
                x: 24,
                yRange: Int(stripeSplitY - 24)...Int(stripeSplitY + 24)
            )
            XCTAssertGreaterThan(exposedGradient, 0.55, "\(probe.name) 裸露条纹边界应锐利")

            // 面板内部同一水平边界（x = 195）测量透光差值与 1px 垂直梯度（模糊程度）。
            let panelTopRGB = try XCTUnwrap(sampleRGB(in: image, at: CGPoint(x: windowSize.width / 2, y: stripeSplitY - 40)))
            let panelBottomRGB = try XCTUnwrap(sampleRGB(in: image, at: CGPoint(x: windowSize.width / 2, y: stripeSplitY + 40)))
            let panelTranslucencyDelta = meanChannelDifference(panelTopRGB, panelBottomRGB)
            let panelBoundaryGradient = maxVerticalGradient(
                in: image,
                x: windowSize.width / 2,
                yRange: Int(stripeSplitY - 24)...Int(stripeSplitY + 24)
            )

            switch probe.expectedStyle {
            case .liquidGlass, .ultraThinMaterial:
                XCTAssertGreaterThan(
                    panelTranslucencyDelta,
                    0.04,
                    "\(probe.name) 应透出背后亮暗条纹差异"
                )
                XCTAssertLessThan(
                    panelBoundaryGradient,
                    exposedGradient * 0.45,
                    "\(probe.name) 必须对条纹边界产生真实模糊柔化，而不仅是半透明叠色 (panel=\(panelBoundaryGradient), raw=\(exposedGradient))"
                )
            case .solidComposerCard, .standaloneSurface:
                XCTAssertLessThan(panelTranslucencyDelta, 0.02, "实色回退不应透出背后条纹")
                XCTAssertLessThan(panelBoundaryGradient, 0.02, "实色回退边界处不应出现条纹突变")
            }
        }
    }

    /// 真实 `ComposerView` 入口呈现验证：不关闭动画、直接触发真实的 `composer.model` 控件，
    /// 对照同一窗口内真实输入框实测底色核对实色回退，测量玻璃态对锐利条纹边界的模糊程度，
    /// 验证常规 Popover 20pt 圆角与箭头、紧凑 Sheet 拖拽取消支持与关闭重开生命周期，以及辅助功能 `.large` detent。
    func testModelPickerPresentationChromeRendersInLightAndDarkModes() async throws {
        let layout = ModelReasoningGridCatalog.layout(
            runtimeProvider: "codex",
            options: codex56SnapshotModels
        )

        // 1. 常规 iPad Popover（亮/暗）：从真实 `ComposerView` 的 `composer.model` 触发，
        //    面板底色直接对照同一窗口内真实渲染的输入框底色，不依赖 Picker 自己的填色函数，并验证 20pt 圆角与关闭重开。
        for colorScheme in [ColorScheme.light, .dark] {
            let capture = try await captureRealComposerModelPicker(
                label: "real-regular-popover-\(colorScheme)",
                windowSize: CGSize(width: 900, height: 700),
                horizontalSizeClass: .regular,
                verticalSizeClass: .regular,
                phoneKeyboardVisible: nil,
                colorScheme: colorScheme,
                interfaceStyle: .glass,
                increasedContrast: false,
                dynamicTypeSize: .large
            )
            XCTAssertTrue(
                capture.presentedController.presentationController is UIPopoverPresentationController,
                "常规 iPad 宽档应保持 Popover 呈现 (\(colorScheme))"
            )
            XCTAssertLessThan(
                capture.presentedFrame.maxY,
                700 - 20,
                "常规 iPad Popover 应锚定在按钮上方而非贴底 Sheet (\(colorScheme))"
            )
            XCTAssertLessThan(
                capture.panelAcrossStripeDelta,
                0.04,
                "常规 iPad Popover 应由自身共享实色表面遮盖背后锐利条纹 (\(colorScheme))"
            )
            XCTAssertLessThan(
                meanChannelDifference(capture.panelSampleRGB, capture.actualComposerCardRGB),
                0.06,
                "常规 iPad Popover 底色应与真实渲染的宽档输入卡底色一致 (\(colorScheme))"
            )
            if let arrowRGB = capture.popoverArrowRGB {
                // 深色模式下系统 Popover 箭头边缘带有轻微高光描边，允许 0.12 容差以区分真正的底色失配。
                XCTAssertLessThan(
                    meanChannelDifference(arrowRGB, capture.panelSampleRGB),
                    0.12,
                    "常规 iPad Popover 箭头与面板交界底色应保持一致 (\(colorScheme))"
                )
            } else {
                XCTFail("未能采样到常规 iPad Popover 箭头像素 (\(colorScheme))")
            }
            XCTAssertTrue(capture.reopenedAfterDismiss, "常规 iPad Popover 关闭后经真实入口必须可干净重开 (\(colorScheme))")
        }

        // 2. 紧凑悬浮玻璃 Sheet（亮/暗）：从真实展开态 iPhone `ComposerView`（`phoneKeyboardVisible = true`）的 `composer.model` 触发，
        //    同时验证透光性与锐利条纹边界模糊柔化、拖拽取消能力与关闭重开；经典模式与增强对比度对照真实输入卡底色回退实色。
        for colorScheme in [ColorScheme.light, .dark] {
            let glassCapture = try await captureRealComposerModelPicker(
                label: "real-compact-glass-\(colorScheme)",
                windowSize: CGSize(width: 390, height: 844),
                horizontalSizeClass: .compact,
                verticalSizeClass: .regular,
                phoneKeyboardVisible: true,
                colorScheme: colorScheme,
                interfaceStyle: .glass,
                increasedContrast: false,
                dynamicTypeSize: .large
            )
            XCTAssertTrue(glassCapture.isAdaptedSheet, "紧凑档应适配为贴底 Sheet (\(colorScheme))")
            XCTAssertEqual(
                glassCapture.presentedFrame.height,
                layout.standardContentHeight,
                accuracy: 40,
                "标准字号紧凑 Sheet 高度应贴合内容 detent (\(colorScheme))"
            )
            XCTAssertTrue(glassCapture.supportsInteractiveDragDismiss, "紧凑 Sheet 应支持拖拽取消与显示拖动手柄 (\(colorScheme))")
            XCTAssertTrue(glassCapture.reopenedAfterDismiss, "紧凑 Sheet 取消关闭后经真实入口必须可干净重开 (\(colorScheme))")
            XCTAssertGreaterThan(
                glassCapture.exposedStripeEdgeGradient,
                0.35,
                "裸露背景条纹边界应足够锐利以作为模糊对照基准 (\(colorScheme))"
            )
            XCTAssertGreaterThan(
                glassCapture.panelAcrossStripeDelta,
                0.015,
                "玻璃态紧凑 Sheet 应对背后亮暗条纹产生真实透光差异 (\(colorScheme))"
            )
            XCTAssertLessThan(
                glassCapture.panelStripeEdgeGradient,
                glassCapture.exposedStripeEdgeGradient * 0.55,
                "玻璃态紧凑 Sheet 必须柔化背后锐利条纹边界，体现真实模糊/折射而非纯透明叠色 (\(colorScheme))"
            )

            for (fallbackName, style, contrast) in [
                ("classic", ThemeInterfaceStyle.classic, false),
                ("increasedContrast", ThemeInterfaceStyle.glass, true),
            ] {
                let fallbackCapture = try await captureRealComposerModelPicker(
                    label: "real-compact-\(fallbackName)-\(colorScheme)",
                    windowSize: CGSize(width: 390, height: 844),
                    horizontalSizeClass: .compact,
                    verticalSizeClass: .regular,
                    phoneKeyboardVisible: true,
                    colorScheme: colorScheme,
                    interfaceStyle: style,
                    increasedContrast: contrast,
                    dynamicTypeSize: .large
                )
                XCTAssertTrue(fallbackCapture.isAdaptedSheet)
                XCTAssertLessThan(
                    fallbackCapture.panelAcrossStripeDelta,
                    0.03,
                    "实色回退 Sheet(\(fallbackName)) 不应透出背后锐利条纹 (\(colorScheme))"
                )
                XCTAssertLessThan(
                    meanChannelDifference(fallbackCapture.panelSampleRGB, fallbackCapture.actualComposerCardRGB),
                    0.06,
                    "实色回退 Sheet(\(fallbackName)) 底色应与同一窗口内真实输入卡一致 (\(colorScheme))"
                )
            }
        }

        // 3. 辅助功能大字号经真实入口触发走 `.large` detent，且关闭后可再次打开。
        let accessibleCapture = try await captureRealComposerModelPicker(
            label: "real-compact-accessibility3",
            windowSize: CGSize(width: 390, height: 844),
            horizontalSizeClass: .compact,
            verticalSizeClass: .regular,
            phoneKeyboardVisible: true,
            colorScheme: .light,
            interfaceStyle: .glass,
            increasedContrast: false,
            dynamicTypeSize: .accessibility3
        )
        XCTAssertTrue(accessibleCapture.isAdaptedSheet)
        XCTAssertGreaterThan(
            accessibleCapture.presentedFrame.height,
            layout.standardContentHeight + 200,
            "辅助功能大字号应使用 .large detent 展开并避免裁切"
        )
        XCTAssertTrue(accessibleCapture.reopenedAfterDismiss)

        // 4. iPad 分屏窄档（`phoneKeyboardVisible == nil`）：真实 `ComposerView` 使用实色输入卡，
        //    打开的模型 Sheet 也跟随同一实色输入卡底板，不强套手机悬浮玻璃。
        let splitSheetCapture = try await captureRealComposerModelPicker(
            label: "real-compact-split-solid-light",
            windowSize: CGSize(width: 390, height: 844),
            horizontalSizeClass: .compact,
            verticalSizeClass: .regular,
            phoneKeyboardVisible: nil,
            colorScheme: .light,
            interfaceStyle: .glass,
            increasedContrast: false,
            dynamicTypeSize: .large
        )
        XCTAssertTrue(splitSheetCapture.isAdaptedSheet)
        XCTAssertLessThan(splitSheetCapture.panelAcrossStripeDelta, 0.03)
        XCTAssertLessThan(
            meanChannelDifference(splitSheetCapture.panelSampleRGB, splitSheetCapture.actualComposerCardRGB),
            0.06,
            "iPad 分屏窄档 Sheet 应匹配同一窗口内真实实色输入卡底色"
        )
    }

    private struct RealComposerPickerCapture {
        let presentedController: UIViewController
        let presentedFrame: CGRect
        let isAdaptedSheet: Bool
        let supportsInteractiveDragDismiss: Bool
        let reopenedAfterDismiss: Bool
        let actualComposerCardRGB: (r: CGFloat, g: CGFloat, b: CGFloat)
        let panelSampleRGB: (r: CGFloat, g: CGFloat, b: CGFloat)
        let popoverArrowRGB: (r: CGFloat, g: CGFloat, b: CGFloat)?
        let panelAcrossStripeDelta: CGFloat
        let exposedStripeEdgeGradient: CGFloat
        let panelStripeEdgeGradient: CGFloat
    }

    private struct RealComposerHarnessView: View {
        let sessionStore: SessionStore
        let themeStore: ThemeStore
        let defaults: UserDefaults
        let triggerBridge: ComposerModelEntryTriggerBridge
        let availableWidth: CGFloat
        let horizontalSizeClass: UserInterfaceSizeClass
        let phoneKeyboardVisible: Bool?
        let colorScheme: ColorScheme
        let interfaceStyle: ThemeInterfaceStyle
        let dynamicTypeSize: DynamicTypeSize
        let stripeSplitX: CGFloat
        let stripeSplitY: CGFloat

        var body: some View {
            ZStack(alignment: .bottom) {
                // 高对比双色条纹：竖向边界 `stripeSplitX` 穿过面板水平中轴，
                // 便于在面板纯内边距区同时采样明/暗背景两侧的透光差与边界模糊度。
                GeometryReader { proxy in
                    let leftWidth = min(max(stripeSplitX, 40), proxy.size.width - 40)
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            Color(red: 0.99, green: 0.99, blue: 0.96)
                                .frame(width: leftWidth)
                            Color(red: 0.04, green: 0.06, blue: 0.14)
                                .frame(maxWidth: .infinity)
                        }
                        .frame(height: stripeSplitY)
                        HStack(spacing: 0) {
                            Color(red: 0.04, green: 0.06, blue: 0.14)
                                .frame(width: leftWidth)
                            Color(red: 0.99, green: 0.99, blue: 0.96)
                                .frame(maxWidth: .infinity)
                        }
                        .frame(maxHeight: .infinity)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
                .ignoresSafeArea()

                ComposerView(availableWidth: availableWidth)
                    .environmentObject(sessionStore)
                    .environmentObject(themeStore)
                    .environment(\.horizontalSizeClass, horizontalSizeClass)
                    .environment(\.phoneConversationKeyboardVisible, phoneKeyboardVisible)
                    .environment(\.colorScheme, colorScheme)
                    .environment(\.themeInterfaceStyle, interfaceStyle)
                    .environment(\.dynamicTypeSize, dynamicTypeSize)
                    .environment(\.composerModelEntryTriggerBridge, triggerBridge)
                    .defaultAppStorage(defaults)
                    .padding(.bottom, 16)
            }
            .environmentObject(sessionStore)
            .environmentObject(themeStore)
            .environment(\.horizontalSizeClass, horizontalSizeClass)
            .environment(\.colorScheme, colorScheme)
            .environment(\.themeInterfaceStyle, interfaceStyle)
            .environment(\.dynamicTypeSize, dynamicTypeSize)
        }
    }

    private func captureRealComposerModelPicker(
        label: String,
        windowSize: CGSize,
        horizontalSizeClass: UserInterfaceSizeClass,
        verticalSizeClass: UserInterfaceSizeClass,
        phoneKeyboardVisible: Bool?,
        colorScheme: ColorScheme,
        interfaceStyle: ThemeInterfaceStyle,
        increasedContrast: Bool,
        dynamicTypeSize: DynamicTypeSize
    ) async throws -> RealComposerPickerCapture {
        let suite = "RealComposerPicker.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let themeStore = ThemeStore(defaults: defaults)
        themeStore.mode = colorScheme == .dark ? .dark : .light
        themeStore.interfaceStyle = interfaceStyle

        let sessionStore = SessionStore(
            appStore: AppStore(
                defaults: defaults,
                tokenStore: TokenStore(keychain: TestKeychainOperations())
            ),
            conversationStore: ConversationStore(),
            logStore: LogStore()
        )
        let session = makeSession(
            id: "picker-presentation-\(UUID().uuidString)",
            projectID: "picker-presentation-project",
            title: "模型面板呈现回归",
            status: SessionStatus.completed.rawValue,
            source: "codex"
        )
        sessionStore.sessionsByID[session.id] = session
        sessionStore.selectedSessionID = session.id
        sessionStore.sessionControlStateByID[session.id] = .takenOver
        sessionStore.appServerModelOptions = codex56SnapshotModels

        let triggerBridge = ComposerModelEntryTriggerBridge()
        let stripeSplitX: CGFloat = horizontalSizeClass == .compact ? (windowSize.width / 2) : 210
        let stripeSplitY: CGFloat = horizontalSizeClass == .compact ? 220 : 280
        let rootView = RealComposerHarnessView(
            sessionStore: sessionStore,
            themeStore: themeStore,
            defaults: defaults,
            triggerBridge: triggerBridge,
            availableWidth: windowSize.width,
            horizontalSizeClass: horizontalSizeClass,
            phoneKeyboardVisible: phoneKeyboardVisible,
            colorScheme: colorScheme,
            interfaceStyle: interfaceStyle,
            dynamicTypeSize: dynamicTypeSize,
            stripeSplitX: stripeSplitX,
            stripeSplitY: stripeSplitY
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
        window.traitOverrides.preferredContentSizeCategory =
            dynamicTypeSize == .accessibility3 ? .accessibilityLarge : .large
        window.rootViewController = UIHostingController(rootView: rootView)

        // 保留系统真实开合动画（不再全局关闭 UIView animations）。
        window.makeKeyAndVisible()
        defer {
            if window.rootViewController?.presentedViewController != nil {
                window.rootViewController?.dismiss(animated: false)
            }
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }

        try await waitForTriggerBridge(triggerBridge, in: window)
        let beforeImage = renderWindowImage(window, scale: 1)
        let triggerFrame = triggerBridge.triggerFrameInGlobal
        exportDebugImageIfRequested(beforeImage, name: "\(label)-before")
        // 从同一窗口内真实渲染的 Composer 输入卡采样实际底色：避开模型按钮本身，取输入卡内侧空白处。
        let composerCardSamplePoint = CGPoint(
            x: min(max(triggerFrame.maxX + 24, 36), windowSize.width - 36),
            y: min(max(triggerFrame.midY, 20), windowSize.height - 24)
        )
        let actualComposerCardRGB = try XCTUnwrap(sampleRGB(in: beforeImage, at: composerCardSamplePoint))

        // 真实激活 `composer.model` 打开模型切换面板。
        XCTAssertTrue(triggerBridge.activate(), "未能激活真实 composer.model 入口 (\(label))")
        let presented = try await waitForPresentedController(in: window)
        let frame = presented.view.convert(presented.view.bounds, to: window)
        let sheetController = (presented.presentationController as? UISheetPresentationController)
            ?? (presented.presentationController as? UIPopoverPresentationController)?.adaptiveSheetPresentationController
        let isAdaptedSheet = sheetController != nil
            && frame.maxY >= windowSize.height - 24
            && frame.width >= windowSize.width - 32
        let supportsInteractiveDragDismiss = !presented.isModalInPresentation
            && (sheetController?.prefersGrabberVisible == true)

        let presentedImage = renderWindowImage(window, scale: 1)
        exportDebugImageIfRequested(presentedImage, name: label)

        // 面板纯内边距区横跨竖向条纹边界 `stripeSplitX`：
        // 左侧背后是深色条纹、右侧背后是亮色条纹，一次采样同时测得面板底色、左右透光差和竖向边界模糊度。
        // 紧凑 Sheet 底部紧贴真实的 `ComposerView` 输入卡，背后条纹会被输入卡自身遮挡；
        // 因此改在拖动手柄下方、顶部控件上方的纯留白带（`frame.minY + 18`）采样未被遮挡的背景条纹。
        let sampleY = isAdaptedSheet ? (frame.minY + 18) : (frame.minY + 6)
        let leftSampleX = max(frame.minX + 52, min(stripeSplitX - 48, frame.midX - 36))
        let rightSampleX = min(frame.maxX - 52, max(stripeSplitX + 48, frame.midX + 36))
        let panelLeftRGB = try XCTUnwrap(sampleRGB(in: presentedImage, at: CGPoint(x: leftSampleX, y: sampleY)))
        let panelRightRGB = try XCTUnwrap(sampleRGB(in: presentedImage, at: CGPoint(x: rightSampleX, y: sampleY)))
        let panelAcrossStripeDelta = meanChannelDifference(panelLeftRGB, panelRightRGB)

        let popoverArrowRGB: (r: CGFloat, g: CGFloat, b: CGFloat)? = isAdaptedSheet
            ? nil
            : sampleRGB(
                in: presentedImage,
                at: CGPoint(
                    x: min(max(triggerFrame.midX, frame.minX + 32), frame.maxX - 32),
                    y: min(frame.maxY + 3, windowSize.height - 4)
                )
            )

        // 裸露条纹竖向边界（位于面板上方）与面板内边缘同一 x 边界的水平 1px 梯度比较。
        let boundaryX = Int(stripeSplitX)
        let exposedStripeEdgeGradient = maxHorizontalGradient(
            in: presentedImage,
            y: max(40, min(frame.minY - 40, stripeSplitY - 40)),
            xRange: (boundaryX - 24)...(boundaryX + 24)
        )
        let panelStripeEdgeGradient = maxHorizontalGradient(
            in: presentedImage,
            y: sampleY,
            xRange: (boundaryX - 24)...(boundaryX + 24)
        )

        // 模拟交互式关闭（Sheet 拖拽关闭 / Popover 点外部关闭）：经 UIKit presentation 层关闭并触发 delegate，
        // 确认 SwiftUI `$showsModelGridPicker` 同步归零后，再次点击真实 `composer.model` 能够干净重开。
        let presentationController = presented.presentationController
        presented.dismiss(animated: true)
        try await waitForDismissal(in: window)
        if let presentationController {
            presentationController.delegate?.presentationControllerDidDismiss?(presentationController)
        }
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertTrue(triggerBridge.activate(), "关闭后未能再次激活真实 composer.model 入口 (\(label))")
        let reopened = try await waitForPresentedController(in: window)
        let reopenedAfterDismiss = reopened.view.window === window
        reopened.dismiss(animated: true)
        try await waitForDismissal(in: window)

        return RealComposerPickerCapture(
            presentedController: presented,
            presentedFrame: frame,
            isAdaptedSheet: isAdaptedSheet,
            supportsInteractiveDragDismiss: supportsInteractiveDragDismiss,
            reopenedAfterDismiss: reopenedAfterDismiss,
            actualComposerCardRGB: actualComposerCardRGB,
            panelSampleRGB: panelLeftRGB,
            popoverArrowRGB: popoverArrowRGB,
            panelAcrossStripeDelta: panelAcrossStripeDelta,
            exposedStripeEdgeGradient: exposedStripeEdgeGradient,
            panelStripeEdgeGradient: panelStripeEdgeGradient
        )
    }

    private func waitForTriggerBridge(
        _ bridge: ComposerModelEntryTriggerBridge,
        in window: UIWindow
    ) async throws {
        for _ in 0..<80 {
            window.layoutIfNeeded()
            if bridge.isRegistered {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("未在真实 ComposerView 中挂载 composer.model 触发入口")
        throw NSError(domain: "SkillModelPickerSnapshotTests", code: 2)
    }

    private func renderWindowImage(_ window: UIWindow, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    private func exportDebugImageIfRequested(_ image: UIImage, name: String) {
        guard let dir = ProcessInfo.processInfo.environment["MIMI_EXPORT_PICKER_DEBUG_DIR"],
              !dir.isEmpty,
              let data = image.pngData()
        else {
            return
        }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: url)
    }

    private func maxVerticalGradient(in image: UIImage, x: CGFloat, yRange: ClosedRange<Int>) -> CGFloat {
        var maxDelta: CGFloat = 0
        var previous: (r: CGFloat, g: CGFloat, b: CGFloat)?
        for y in yRange {
            guard let current = sampleRGB(in: image, at: CGPoint(x: x, y: CGFloat(y))) else { continue }
            if let prev = previous {
                maxDelta = max(maxDelta, meanChannelDifference(prev, current))
            }
            previous = current
        }
        return maxDelta
    }

    private func maxHorizontalGradient(in image: UIImage, y: CGFloat, xRange: ClosedRange<Int>) -> CGFloat {
        var maxDelta: CGFloat = 0
        var previous: (r: CGFloat, g: CGFloat, b: CGFloat)?
        for x in xRange {
            guard let current = sampleRGB(in: image, at: CGPoint(x: CGFloat(x), y: y)) else { continue }
            if let prev = previous {
                maxDelta = max(maxDelta, meanChannelDifference(prev, current))
            }
            previous = current
        }
        return maxDelta
    }

    private func waitForPresentedController(in window: UIWindow) async throws -> UIViewController {
        var previousFrame: CGRect?
        var stableFrames = 0
        for _ in 0..<120 {
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
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("模型切换面板未在预期时间内完成呈现")
        throw NSError(domain: "SkillModelPickerSnapshotTests", code: 1)
    }

    private func waitForDismissal(in window: UIWindow) async throws {
        for _ in 0..<120 {
            window.layoutIfNeeded()
            if window.rootViewController?.presentedViewController == nil {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("模型切换面板未在预期时间内完成关闭")
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
