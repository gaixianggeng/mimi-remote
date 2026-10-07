import Foundation
import XCTest
@testable import MimiRemoteMac

final class CodexFrontDoorInvocationTests: XCTestCase {
    func testFrontDoorOnlyAcceptsFixedFlagOrAbsoluteConfig() {
        XCTAssertTrue(CodexFrontDoorInvocation.isRequested(["app", "--codex-front-door"]))
        XCTAssertFalse(CodexFrontDoorInvocation.isRequested(["--codex-front-door"]))

        XCTAssertEqual(CodexFrontDoorInvocation.configuration(["app", "--codex-front-door"]), .standard)
        XCTAssertEqual(
            CodexFrontDoorInvocation.configuration(["app", "--codex-front-door", "--config", "/tmp/agentd.json"]),
            .explicit("/tmp/agentd.json")
        )
        XCTAssertNil(CodexFrontDoorInvocation.configuration(["app", "--codex-front-door", "--config", "relative.json"]))
        XCTAssertNil(CodexFrontDoorInvocation.configuration(["app", "--codex-front-door", "extra"]))
        XCTAssertNil(CodexFrontDoorInvocation.configuration(["app", "--agentd-supervisor", "--codex-front-door"]))
    }

    func testFrontDoorCommandRunsBundledAgentdWithFixedArguments() {
        let bundle = URL(fileURLWithPath: "/Applications/Mimi Remote Mac.app")
        let home = URL(fileURLWithPath: "/Users/tester")
        let agentd = "/Applications/Mimi Remote Mac.app/Contents/Resources/agentd"
        let log = "/Users/tester/Library/Logs/mimi-remote/codex-front.log"

        let standard = AgentdSupervisorCommand.frontDoor(bundleURL: bundle, homeDirectoryURL: home, configPath: nil)
        XCTAssertEqual(standard.executableURL.path, agentd)
        XCTAssertEqual(standard.arguments, [agentd, "codex-front", "serve", "--log-file", log])

        let isolated = AgentdSupervisorCommand.frontDoor(
            bundleURL: bundle,
            homeDirectoryURL: home,
            configPath: "/tmp/agentd.json"
        )
        XCTAssertEqual(isolated.arguments, [agentd, "codex-front", "serve", "--log-file", log, "--config", "/tmp/agentd.json"])
    }
}
