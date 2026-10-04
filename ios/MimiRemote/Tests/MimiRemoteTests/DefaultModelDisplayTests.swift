import XCTest
@testable import MimiRemote

final class DefaultModelDisplayTests: XCTestCase {
    func testDisplayMatchesEffectiveDefaultWithoutSavingSelection() throws {
        let suite = "DefaultModelDisplayTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = [
            CodexAppServerModelOption(id: "gpt-custom", title: "Custom GPT", isDefault: true),
            CodexAppServerModelOption(id: "opus", title: "Claude Opus 9.2", runtimeProvider: "claude", isDefault: true),
            CodexAppServerModelOption(id: "deepseek-chat", title: "DeepSeek Chat", provider: "local", runtimeProvider: "deepseek", isDefault: true)
        ]
        for runtime in DefaultModelRuntime.allCases {
            let selection = try XCTUnwrap(DefaultModelPreferences.resolvedSelection(
                for: runtime.rawValue, allOptions: catalog, defaults: defaults
            ))
            XCTAssertEqual(DefaultModelDisplay.title(for: runtime, allOptions: catalog, isRefreshing: false), selection.option.menuTitle)
            var submitted = CodexAppServerTurnOptions.default
            DefaultModelPreferences.applyDefault(for: runtime.rawValue, allOptions: catalog, defaults: defaults, to: &submitted)
            XCTAssertEqual(submitted.model, selection.option.model)
            XCTAssertNil(defaults.string(forKey: DefaultModelPreferences.modelOptionIDKey(for: runtime.rawValue)))
        }
    }

    func testCodexDisplayUsesExistingRecommendationRatherThanServerDefault() {
        let catalog = [
            CodexAppServerModelOption(id: "gpt-custom", isDefault: true),
            CodexAppServerModelOption(id: "gpt-6-astra", title: "Catalog Astra")
        ]
        XCTAssertEqual(DefaultModelDisplay.title(for: .codex, allOptions: catalog, isRefreshing: false), "Catalog Astra")
    }

    func testUnknownAndLoadingDoNotInventClaudeOrHarnessModels() {
        for runtime in [DefaultModelRuntime.claude, .deepseek] {
            XCTAssertEqual(DefaultModelDisplay.title(for: runtime, allOptions: [], isRefreshing: false), L10n.text("ui.default_model_unconfirmed"))
            XCTAssertEqual(DefaultModelDisplay.title(for: runtime, allOptions: [], isRefreshing: true), L10n.text("ui.default_model_loading"))
        }
        XCTAssertEqual(DefaultModelDisplay.title(for: .claude, allOptions: CodexAppServerModelOption.builtInClaudeFallback, isRefreshing: false), L10n.text("ui.default_model_unconfirmed"))
        for alias in ["default", "opus"] {
            let unresolved = CodexAppServerModelOption(id: alias, runtimeProvider: "claude", isDefault: true)
            XCTAssertEqual(DefaultModelDisplay.title(for: .claude, allOptions: [unresolved], isRefreshing: false), L10n.text("ui.default_model_unconfirmed"))
        }
        XCTAssertEqual(DefaultModelDisplay.title(for: .codex, allOptions: [], isRefreshing: false), ModelReasoningGridCatalog.preferredDefaultOption(runtimeProvider: "codex", options: [])?.menuTitle)
    }
}
