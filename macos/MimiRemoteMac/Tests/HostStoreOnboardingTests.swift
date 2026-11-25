import XCTest
@testable import MimiRemoteMac

@MainActor
extension HostStoreTests {
    func testCompleteSetupFailureKeepsNotConfiguredAndSplitsLoginItemWarning() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: "mimi-host-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let failingStore = makeStore(
            configExists: false,
            agentConfigurationError: { "签名未就绪" }
        )
        await failingStore.bootstrap()
        await failingStore.completeSetup(workspaceRoot: tempDir)
        XCTAssertEqual(failingStore.lifecycle, .notConfigured)
        XCTAssertEqual(failingStore.lastError, "签名未就绪")

        let warningStore = makeStore(
            configExists: true,
            agentStatus: { .enabled },
            mainAppStatus: { .notRegistered },
            registerMainApp: { throw TestError.expected }
        )
        await warningStore.bootstrap()
        XCTAssertEqual(warningStore.lifecycle, .ready)
        XCTAssertNil(warningStore.lastError)
        XCTAssertNotNil(warningStore.loginItemWarning)
    }

    func testOnboardingLifecycleKeepsNotConfiguredUntilFinishedAndReusesHomebrew() async throws {
        let events = EventRecorder()
        let store = makeStore(
            configExists: false,
            homebrewLoaded: true,
            registerAgent: { events.append("register-mac") },
            homebrewStart: { events.append("start-homebrew") },
            homebrewStop: { events.append("stop-homebrew") }
        )
        await store.bootstrap()
        store.beginOnboarding()
        let outcome = try await store.registerOrStartServiceForOnboarding()
        XCTAssertEqual(outcome, .homebrewHealthy)
        XCTAssertEqual(store.lifecycle, .notConfigured)
        XCTAssertEqual(events.values, [])
        XCTAssertTrue(store.onboardingWizard() === store.onboardingWizard())
        XCTAssertFalse(store.canPair)
        try await store.restartServiceForOnboarding()
        XCTAssertEqual(events.values, ["stop-homebrew", "start-homebrew"])
        XCTAssertEqual(store.lifecycle, .notConfigured)

        await store.finishOnboarding(owner: .homebrew)
        XCTAssertFalse(store.isOnboardingInProgress)
        XCTAssertEqual(store.lifecycle, .migrationRequired)
    }

    func testFailedHomebrewRestartRetriesSameOwner() async throws {
        let events = EventRecorder()
        let starts = CallCounter()
        let store = makeStore(
            configExists: false,
            isHomebrewLoaded: { !events.values.contains("stop") },
            registerAgent: { events.append("register-mac") },
            homebrewStart: {
                events.append("start")
                if starts.increment() == 1 { throw TestError.expected }
            },
            homebrewStop: { events.append("stop") }
        )
        await store.bootstrap()
        store.beginOnboarding()
        _ = try await store.registerOrStartServiceForOnboarding()
        do {
            try await store.restartServiceForOnboarding()
            XCTFail("Expected the first Homebrew start to fail")
        } catch TestError.expected {}
        let outcome = try await store.registerOrStartServiceForOnboarding()
        XCTAssertEqual(outcome, .homebrewHealthy)
        XCTAssertEqual(events.values, ["stop", "start", "start"])
        XCTAssertEqual(store.owner, .homebrew)
        XCTAssertEqual(store.lifecycle, .notConfigured)
    }
}
