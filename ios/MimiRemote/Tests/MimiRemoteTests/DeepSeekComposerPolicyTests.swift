import XCTest
@testable import MimiRemote

@MainActor
final class DeepSeekComposerPolicyTests: XCTestCase {
    func testHarnessFullAccessKeepsInteractiveApprovalAndProvider() {
        let options = CodexAppServerTurnOptions(
            runtimeProvider: "deepseek", model: "shared-model", modelProvider: "provider-b",
            serviceTier: "priority", approvalPolicy: .never
        ).sanitizedForRuntimePolicy()
        XCTAssertEqual(options.approvalPolicy, .onRequest)
        XCTAssertNil(options.serviceTier)
        XCTAssertEqual(options.modelProvider, "provider-b")
        XCTAssertEqual(options.sanitizedForStandardComposer().modelProvider, "provider-b")
        XCTAssertNil(CodexAppServerTurnOptions(modelProvider: "openai")
            .turnParams(projectPath: "/tmp/project")["modelProvider"] ?? nil)
    }

    func testRestrictedPermissionsAreRejectedWithoutEscalation() {
        for mode in [CodexAppServerSandboxMode.readOnly, .workspaceWrite] {
            let options = CodexAppServerTurnOptions(runtimeProvider: "deepseek", sandboxMode: mode)
                .sanitizedForRuntimePolicy()
            XCTAssertEqual(options.sandboxMode, mode)
            XCTAssertNotNil(RuntimeFeatureSupport.submissionError(for: .init(prompt: "test", options: options)))
        }
        XCTAssertEqual(RuntimeFeatureSupport.permissionModes(for: "deepseek"), [.fullAccess])
        XCTAssertFalse(RuntimeFeatureSupport.supportsAttachments(for: "deepseek"))
        XCTAssertFalse(RuntimeFeatureSupport.supportsSkills(for: "deepseek"))
        XCTAssertFalse(RuntimeFeatureSupport.supportsArchive(for: "deepseek"))
    }

    func testHarnessRejectsNonTextAndAcceptsExistingThreadPermissions() {
        let options = CodexAppServerTurnOptions(runtimeProvider: "deepseek", model: "harness-model")
        let payload = CodexAppServerTurnPayload(input: [.image(url: "https://example.invalid/image")], options: options)
        XCTAssertNotNil(RuntimeFeatureSupport.submissionError(for: payload))
        var inherited = options
        inherited.preservesThreadPermissionSettings = true
        inherited.sandboxMode = .readOnly
        XCTAssertNil(RuntimeFeatureSupport.submissionError(for: .init(prompt: "test", options: inherited)))
    }

    func testUnavailableHarnessCatalogDoesNotUseCodexModels() async {
        let store = makeStore(client: MockSessionStoreClient(projects: [], sessions: []))
        store.appServerModelOptions = CodexAppServerModelOption.builtInFallback
        let resolved = await store.payloadResolvingRequiredModel(.init(
            prompt: "test", options: .init(runtimeProvider: "deepseek")
        ))
        XCTAssertNil(resolved.options.model)
        XCTAssertNotNil(RuntimeFeatureSupport.submissionError(for: resolved))
    }

    func testModelResolutionPreservesProviderAndClampsEffortToCatalog() async {
        let store = makeStore(client: MockSessionStoreClient(projects: [], sessions: []))
        store.appServerModelOptions = ["provider-a", "provider-b"].map {
            CodexAppServerModelOption(id: "shared-model", provider: $0, runtimeProvider: "deepseek",
                                     supportedReasoningEfforts: ["low"], defaultReasoningEffort: "low")
        }
        let resolved = await store.payloadResolvingRequiredModel(.init(
            prompt: "test", options: .init(runtimeProvider: "deepseek", model: "shared-model",
                                          modelProvider: "provider-b", reasoningEffort: .high)
        ))
        XCTAssertEqual(resolved.options.modelProvider, "provider-b")
        XCTAssertEqual(resolved.options.reasoningEffort, .low)
    }

    func testAvailabilityUsesChannelEvenWhenCatalogIsEmpty() async {
        // 该替身的 channel 字典是**整体替换**默认值，不是合并；要断言 codex 仍可用必须显式列出。
        let store = makeStore(client: MockSessionStoreClient(
            projects: [], sessions: [], runtimeChannelAvailability: ["codex": true, "deepseek": true]
        ))
        await store.refreshAppServerModelOptions()
        XCTAssertEqual(store.availableRuntimeProviders, ["codex", "deepseek"])
        XCTAssertTrue(store.isRuntimeAvailable("deepseek"))
        XCTAssertFalse(store.isClaudeRuntimeChannelAvailable)
    }

    func testUnavailableHarnessCanRecoverOnRuntimeTapWithoutRestartingStore() async {
        let client = MockSessionStoreClient(
            projects: [], sessions: [], runtimeChannelAvailability: ["codex": true, "deepseek": false]
        )
        let store = makeStore(client: client)
        await store.refreshAppServerModelOptions()
        XCTAssertFalse(store.isRuntimeAvailable("deepseek"))
        let stillUnavailable = await store.retryRuntimeAvailability("deepseek")
        XCTAssertFalse(stillUnavailable, "Mac 端未启用或 Harness 仍离线时不能误选")

        client.runtimeChannelAvailability["deepseek"] = true
        let recovered = await store.retryRuntimeAvailability("deepseek")

        XCTAssertTrue(recovered)
        XCTAssertTrue(store.isRuntimeAvailable("deepseek"))
        XCTAssertTrue(store.isRuntimeAvailable("codex"), "重探 DeepSeek 不应撤销其他通道")
    }

    func testCreateSendsHarnessModelAndInteractiveApproval() async throws {
        let project = makeProject(id: "project-harness-create")
        let created = makeSession(id: "session-harness-create", projectID: project.id,
                                  title: "Harness", status: "running", source: "deepseek", runtimeProvider: "deepseek")
        let client = MockSessionStoreClient(
            projects: [project], sessions: [], createSessionResponse: try makeCreateSessionResponse(session: created),
            modelOptions: [.init(id: "harness-model", provider: "provider-a", runtimeProvider: "deepseek", isDefault: true)]
        )
        let store = makeStore(client: client)
        await store.refreshAll(autoAttach: false)
        store.selectedProjectID = project.id
        let accepted = await store.sendTurn(.init(prompt: "test", options: .init(runtimeProvider: "deepseek")))
        XCTAssertTrue(accepted)
        let options = try XCTUnwrap(client.createPayloads.first).turnOptions
        XCTAssertEqual(options.runtimeProvider, "deepseek")
        XCTAssertEqual(options.model, "harness-model")
        XCTAssertEqual(options.modelProvider, "provider-a")
        XCTAssertEqual(options.approvalPolicy, .onRequest)
        XCTAssertNil(options.reasoningEffort)
    }

    func testStoreRejectsRestrictedHarnessSendBeforeCreatingRemoteSession() async {
        let project = makeProject(id: "project-harness-restricted")
        let client = MockSessionStoreClient(projects: [project], sessions: [], modelOptions: [
            .init(id: "harness-model", runtimeProvider: "deepseek", isDefault: true)
        ])
        let store = makeStore(client: client)
        await store.refreshAll(autoAttach: false)
        store.selectedProjectID = project.id
        let accepted = await store.sendTurn(.init(
            prompt: "test", options: .init(runtimeProvider: "deepseek", sandboxMode: .readOnly)
        ))
        XCTAssertFalse(accepted)
        XCTAssertTrue(client.createPayloads.isEmpty)
        XCTAssertNotNil(store.errorMessage)
    }

    private func makeStore(client: MockSessionStoreClient) -> SessionStore {
        SessionStore(appStore: makeIsolatedAppStore(), conversationStore: ConversationStore(),
                     logStore: LogStore(), clientFactory: { client })
    }
}
