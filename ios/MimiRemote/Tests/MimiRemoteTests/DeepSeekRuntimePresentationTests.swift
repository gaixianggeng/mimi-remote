import XCTest
@testable import MimiRemote

final class DeepSeekRuntimePresentationTests: XCTestCase {
    func testDeepSeekSessionUsesDedicatedPresentation() {
        let presentation = SessionRuntimePresentation(
            runtimeProvider: "deepseek",
            source: "codex"
        )

        XCTAssertEqual(presentation.kind, .deepSeek)
        XCTAssertEqual(presentation.title, "DeepSeek")
        XCTAssertEqual(presentation.brandMark, .deepSeek)
        XCTAssertEqual(presentation.brandMark.assetName, "DeepSeek")
    }

    func testDeepSeekHarnessAliasesUseDedicatedPresentation() {
        for provider in ["deepseek-harness", "deepseek_harness_service", "dsh"] {
            XCTAssertEqual(
                SessionRuntimePresentation(runtimeProvider: provider, source: "local").kind,
                .deepSeek
            )
            XCTAssertEqual(
                ConversationTimelineProvider(runtimeProvider: provider),
                .deepseek
            )
        }
    }

    func testDeepSeekDefaultPreferencesUseIndependentKeysWithoutGPTFallback() {
        XCTAssertFalse(RuntimeFeatureSupport.supportsPlanningAndGoals(for: "deepseek"))
        XCTAssertTrue(RuntimeFeatureSupport.supportsPlanningAndGoals(for: "codex"))
        XCTAssertEqual(DefaultModelRuntime.deepseek.payloadRuntimeProvider, "deepseek")
        XCTAssertEqual(
            DefaultModelPreferences.modelOptionIDKey(for: "deepseek"),
            DefaultModelPreferences.deepSeekModelOptionIDKey
        )
        XCTAssertEqual(
            DefaultModelPreferences.reasoningEffortKey(for: "deepseek"),
            DefaultModelPreferences.deepSeekReasoningEffortKey
        )
        XCTAssertTrue(
            DefaultModelPreferences.options(for: "deepseek", allOptions: []).isEmpty
        )
    }

    func testDeepSeekModelLayoutUsesDeclaredEffortsAndHidesFastMode() {
        XCTAssertEqual(CodexAppServerReasoningEffort(rawValue: "off"), .off)
        XCTAssertNotEqual(CodexAppServerReasoningEffort.off, .none)

        let option = CodexAppServerModelOption(
            id: "deepseek-chat",
            provider: "provider-a",
            runtimeProvider: "deepseek",
            supportedReasoningEfforts: ["off", "low", "high", "max"],
            defaultReasoningEffort: "off"
        )

        let layout = ModelReasoningGridCatalog.layout(
            runtimeProvider: "deepseek",
            options: [option]
        )

        XCTAssertEqual(layout.kind, .deepSeek)
        XCTAssertEqual(layout.models.map(\.model), ["deepseek-chat"])
        XCTAssertEqual(layout.efforts, [.off, .low, .high, .max])
        XCTAssertEqual(
            ModelReasoningGridCatalog.preferredDefaultEffort(
                runtimeProvider: "deepseek",
                option: option,
                layout: layout
            ),
            .off
        )
        XCTAssertEqual(
            layout.efforts.map { ModelReasoningGridCatalog.effortTitle($0, kind: layout.kind) },
            ["Off", "Low", "High", "Max"]
        )
        XCTAssertEqual(ModelReasoningGridCatalog.effortTitle(.low), "Light")
        XCTAssertEqual(
            ModelReasoningGridCatalog.effortTitle(.low, runtimeProvider: "deepseek"),
            "Low"
        )
        XCTAssertEqual(
            ModelReasoningGridCatalog.effortTitle(.low, runtimeProvider: "codex"),
            "Light"
        )
        XCTAssertFalse(layout.showsFastMode)
    }

    func testAdvancedOptionsKeepsOffOnlyForDeepSeekOrExistingSelection() {
        XCTAssertFalse(AdvancedTurnOptionsSheet.reasoningEfforts(
            runtimeProvider: "codex",
            selection: nil
        ).contains(.off))
        XCTAssertTrue(AdvancedTurnOptionsSheet.reasoningEfforts(
            runtimeProvider: "deepseek",
            selection: nil
        ).contains(.off))
        XCTAssertTrue(AdvancedTurnOptionsSheet.reasoningEfforts(
            runtimeProvider: nil,
            selection: .off
        ).contains(.off))
    }
}
