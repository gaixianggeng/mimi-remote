import XCTest
@testable import MimiRemoteMac

@MainActor
extension HostStoreTests {
    func testHomebrewRestoreUninstallsFrontDoorBeforeStartingService() async {
        let events = EventRecorder()
        let store = makeStore(
            configExists: true,
            homebrewLoaded: true,
            registerAgent: { events.append("register-mac") },
            unregisterAgent: { events.append("unregister-mac") },
            uninstallCodexFrontDoor: { events.append("uninstall-front") },
            homebrewStart: { events.append("start-homebrew") },
            homebrewStop: { events.append("stop-homebrew") },
            healthCheck: { _ in false }
        )
        await store.bootstrap()
        await store.takeOverHomebrew()
        await store.restoreHomebrew()

        XCTAssertEqual(events.values, [
            "stop-homebrew", "register-mac", "unregister-mac", "uninstall-front", "start-homebrew",
        ])
        XCTAssertEqual(store.owner, .homebrew)
        XCTAssertEqual(store.lifecycle, .migrationRequired)
    }

    func testHomebrewRestoreDoesNotStartServiceWhenFrontDoorCannotUninstall() async {
        let events = EventRecorder()
        let store = makeStore(
            configExists: true,
            homebrewLoaded: true,
            registerAgent: { events.append("register-mac") },
            unregisterAgent: { events.append("unregister-mac") },
            uninstallCodexFrontDoor: {
                events.append("uninstall-front")
                throw TestError.expected
            },
            homebrewStart: { events.append("start-homebrew") },
            homebrewStop: { events.append("stop-homebrew") },
            healthCheck: { _ in false }
        )
        await store.bootstrap()
        await store.takeOverHomebrew()
        await store.restoreHomebrew()

        XCTAssertEqual(events.values, [
            "stop-homebrew", "register-mac", "unregister-mac", "uninstall-front",
            "stop-homebrew", "register-mac",
        ])
        XCTAssertEqual(store.owner, .macApp)
        XCTAssertTrue(store.lastError?.contains("已继续使用 App 服务") == true)
    }
}
