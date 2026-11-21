import XCTest
@testable import MimiRemote

@MainActor
final class RuntimeFoundationTests: XCTestCase {
    func testSessionNotificationRoutePreservesAllKnownRuntimesAndRejectsUnknown() throws {
        for raw in ["codex", "Claude", "DEEPSEEK", "claude-code"] {
            let route = SessionNotificationRoute.current(
                profileID: "host-1",
                projectID: "proj-1",
                sessionID: "sess-1",
                runtimeProvider: raw
            )
            let roundTrip = try XCTUnwrap(SessionNotificationRoute(userInfo: route.userInfo))
            XCTAssertEqual(
                roundTrip.runtimeProvider,
                CodexAppServerSessionRuntime.normalizedRuntimeProvider(raw)
            )
        }

        let unknown = SessionNotificationRoute.current(
            profileID: "host-1",
            projectID: "proj-1",
            sessionID: "sess-1",
            runtimeProvider: "unregistered-agent"
        )
        XCTAssertNil(unknown.runtimeProvider)
    }

    func testRuntimeBundleRoutesAdditionalAppServerRuntimesDynamically() throws {
        let codex = CodexAppServerSessionRuntime(endpoint: "http://127.0.0.1:8787", token: "test", runtimeProvider: "codex")
        let claude = CodexAppServerSessionRuntime(endpoint: "http://127.0.0.1:8787", token: "test", runtimeProvider: "claude")
        let agy = CodexAppServerSessionRuntime(endpoint: "http://127.0.0.1:8787", token: "test", runtimeProvider: "agy")
        let bundle = AppServerRuntimeBundle(
            codexRuntime: codex,
            claudeRuntime: claude,
            additionalRuntimes: ["agy": agy]
        )

        XCTAssertTrue(try bundle.runtime(for: "codex") === codex)
        XCTAssertTrue(try bundle.runtime(for: "claude") === claude)
        XCTAssertTrue(try bundle.runtime(for: "agy") === agy)
        XCTAssertThrowsError(try bundle.runtime(for: "deepseek"))
        XCTAssertEqual(
            bundle.secondaryRuntimeEntries.map(\.provider),
            ["claude", "agy", "deepseek"]
        )
    }

    func testSlashCommandCatalogKeySeparatesRuntimeProviders() {
        let scope = HostScope(profileID: "p1", installationID: "i1", generation: 1)
        let claudeKey = ClaudeSlashCommandCatalogKey(
            hostScope: scope,
            runtimeProvider: "claude",
            cwd: "/repo",
            fullAccess: false
        )
        let agyKey = ClaudeSlashCommandCatalogKey(
            hostScope: scope,
            runtimeProvider: "agy",
            cwd: "/repo",
            fullAccess: false
        )
        XCTAssertNotEqual(claudeKey, agyKey)
    }
}
