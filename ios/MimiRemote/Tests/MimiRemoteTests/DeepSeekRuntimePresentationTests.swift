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
        XCTAssertEqual(presentation.brandMark.assetName, "terminal.fill")
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
        let option = CodexAppServerModelOption(
            id: "deepseek-chat",
            provider: "provider-a",
            runtimeProvider: "deepseek",
            supportedReasoningEfforts: ["low", "high"]
        )

        let layout = ModelReasoningGridCatalog.layout(
            runtimeProvider: "deepseek",
            options: [option]
        )

        XCTAssertEqual(layout.kind, .deepSeek)
        XCTAssertEqual(layout.models.map(\.model), ["deepseek-chat"])
        XCTAssertEqual(layout.efforts, [.low, .high])
        XCTAssertFalse(layout.showsFastMode)
    }
}
