import XCTest
@testable import MimiRemote

/// Runtime 可用性与模型目录共用一次刷新：一次没探成或某个通道缺席，
/// 不能把可用通道标成不可用（#777），也不能让菜单落到内置兜底（#778）。
@MainActor
final class RuntimeCatalogRefreshTests: XCTestCase {
    func testThrowingProbeKeepsPreviouslyAvailableRuntime() async {
        let client = MockSessionStoreClient(
            projects: [], sessions: [],
            runtimeChannelAvailability: ["codex": true, "claude": true, "deepseek": true]
        )
        let store = makeStore(client: client)
        await store.refreshAppServerModelOptions()
        XCTAssertEqual(store.availableRuntimeProviders, ["codex", "claude", "deepseek"])

        client.runtimeChannelErrors = ["codex", "deepseek"]
        await store.refreshAppServerModelOptions()
        XCTAssertEqual(
            store.availableRuntimeProviders, ["codex", "claude", "deepseek"],
            "探测抛错只说明这次没探成，不能撤下已确认可用的通道"
        )

        client.runtimeChannelErrors = []
        client.runtimeChannelAvailability["deepseek"] = false
        await store.refreshAppServerModelOptions()
        XCTAssertEqual(store.availableRuntimeProviders, ["codex", "claude"], "明确返回 false 才撤下")
    }

    func testThrowingProbeDoesNotConfirmUnseenRuntimeButRecheckRecovers() async {
        let client = MockSessionStoreClient(
            projects: [], sessions: [],
            runtimeChannelAvailability: ["codex": true, "claude": true, "deepseek": true]
        )
        client.runtimeChannelErrors = ["deepseek"]
        let store = makeStore(client: client)
        await store.refreshAppServerModelOptions()
        XCTAssertFalse(store.isRuntimeAvailable("deepseek"), "从未确认可用的通道不能因为抛错被当成可用")

        client.runtimeChannelErrors = []
        await WorkspaceSessionRuntimeChoice.recheckUnavailable(in: store.availableRuntimeProviders) {
            await store.retryRuntimeAvailability($0.runtimeProvider)
        }

        XCTAssertEqual(store.availableRuntimeProviders, ["codex", "claude", "deepseek"])
    }

    func testRecheckOnlyProbesUnavailableRuntimes() async {
        var probed: [WorkspaceSessionRuntimeChoice] = []
        await WorkspaceSessionRuntimeChoice.recheckUnavailable(in: ["codex", "claude"]) {
            probed.append($0)
            return false
        }
        XCTAssertEqual(probed, [.deepseek])

        probed = []
        await WorkspaceSessionRuntimeChoice.recheckUnavailable(in: []) {
            probed.append($0)
            return false
        }
        XCTAssertEqual(probed, [.claude, .deepseek], "空集合时 Codex 是兜底可用项，不需要重探")
    }

    func testRuntimeMissingFromAggregateIsFilledByTargetedFetch() async {
        let client = MockSessionStoreClient(
            projects: [], sessions: [],
            modelOptions: [Self.codexOption],
            runtimeChannelAvailability: ["codex": true, "claude": true]
        )
        client.modelOptionsByRuntime["claude"] = [Self.claudeOption]
        let store = makeStore(client: client)

        await store.refreshAppServerModelOptions()
        XCTAssertEqual(store.appServerModelOptions.map(\.model), ["gpt-live"])

        await store.prepareTurnModelOptions(runtimeProvider: "claude", hostScope: store.appStore.activeHostScope)

        XCTAssertEqual(client.targetedModelOptionsRequests, ["claude"], "聚合目录缺 Claude 时不能记成已刷新")
        XCTAssertEqual(Set(store.appServerModelOptions.map(\.model)), ["gpt-live", "opus"])
    }

    func testRefreshKeepsPreviousCatalogOfRuntimeMissingFromAggregate() async {
        let client = MockSessionStoreClient(
            projects: [], sessions: [],
            modelOptions: [Self.codexOption, Self.claudeOption],
            runtimeChannelAvailability: ["codex": true, "claude": true]
        )
        let store = makeStore(client: client)
        await store.refreshAppServerModelOptions(force: true)
        XCTAssertEqual(Set(store.appServerModelOptions.map(\.model)), ["gpt-live", "opus"])

        client.modelOptionsResult = [Self.codexOption]
        await store.refreshAppServerModelOptions(force: true)
        XCTAssertEqual(
            Set(store.appServerModelOptions.map(\.model)), ["gpt-live", "opus"],
            "Claude 这一半这次没拉成时保留上一份目录，菜单不能退回内置兜底"
        )

        client.runtimeChannelAvailability["claude"] = false
        await store.refreshAppServerModelOptions(force: true)
        XCTAssertEqual(store.appServerModelOptions.map(\.model), ["gpt-live"], "通道已关闭时不再保留旧目录")
    }

    func testRetainedCatalogIsRecheckedAndClearedWhenRuntimeNowReturnsEmpty() async {
        let client = MockSessionStoreClient(
            projects: [], sessions: [],
            modelOptions: [Self.codexOption, Self.claudeOption],
            runtimeChannelAvailability: ["codex": true, "claude": true]
        )
        let store = makeStore(client: client)
        await store.refreshAppServerModelOptions(force: true)

        // Claude 这次成功返回空目录：聚合结果里看不出来，只能先沿用，再由定向补拉确认。
        client.modelOptionsResult = [Self.codexOption]
        client.modelOptionsByRuntime["claude"] = []
        await store.refreshAppServerModelOptions(force: true)
        await store.prepareTurnModelOptions(runtimeProvider: "claude", hostScope: store.appStore.activeHostScope)

        XCTAssertEqual(client.targetedModelOptionsRequests, ["claude"], "沿用的旧目录不能挡住定向补拉")
        XCTAssertEqual(store.appServerModelOptions.map(\.model), ["gpt-live"], "电脑端已移除的模型不能一直可选")

        await store.prepareTurnModelOptions(runtimeProvider: "codex", hostScope: store.appStore.activeHostScope)
        XCTAssertEqual(client.targetedModelOptionsRequests, ["claude"], "聚合目录已确认的 Runtime 不重复补拉")
    }

    private static let codexOption = CodexAppServerModelOption(
        id: "gpt-live", provider: "openai", runtimeProvider: "codex", isDefault: true
    )
    private static let claudeOption = CodexAppServerModelOption(
        id: "opus", provider: "anthropic", runtimeProvider: "claude", isDefault: true
    )

    private func makeStore(client: MockSessionStoreClient) -> SessionStore {
        SessionStore(appStore: makeIsolatedAppStore(), conversationStore: ConversationStore(),
                     logStore: LogStore(), clientFactory: { client })
    }
}
