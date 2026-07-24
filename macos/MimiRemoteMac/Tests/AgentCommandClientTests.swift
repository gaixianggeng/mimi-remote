import XCTest
@testable import MimiRemoteMac

final class AgentCommandClientTests: XCTestCase {
    func testSetupUsesSeparateProjectScanAndHomeBrowseRoots() {
        let arguments = AgentCommandClient.setupArguments(
            workspaceRoot: URL(filePath: "/test-user/code"),
            browseRoot: URL(filePath: "/test-user")
        )

        XCTAssertEqual(arguments, [
            "setup", "--json", "--qr-only",
            "--scan-root", "/test-user/code",
            "--browse-root", "/test-user",
        ])
    }
}
