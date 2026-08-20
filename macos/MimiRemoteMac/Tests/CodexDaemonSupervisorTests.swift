import XCTest
@testable import MimiRemoteMac

/// supervisor 是共享 daemon 的 TCC 责任进程：它能拉起什么，决定了同用户进程能借
/// Mimi 的授权做什么。这些用例守住的是那条边界，而不是参数解析的便利性。
final class CodexDaemonSupervisorTests: XCTestCase {
    private let node = "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node"
    private let codex = "/Applications/ChatGPT.app/Contents/Resources/codex"

    private func command() -> CodexDaemonSupervisorInvocation.Command {
        CodexDaemonSupervisorInvocation.Command(node: node, codex: codex)
    }

    func testParseAcceptsOnlyTheExactSupervisorShape() {
        let flag = CodexDaemonSupervisorInvocation.flag
        XCTAssertEqual(
            CodexDaemonSupervisorInvocation.parse(["/Mimi", flag, node, codex]),
            command()
        )
        // 少一个、多一个、相对路径、旗标不在第一位都必须拒绝：参数面越窄越好。
        XCTAssertNil(CodexDaemonSupervisorInvocation.parse(["/Mimi", flag, node]))
        XCTAssertNil(CodexDaemonSupervisorInvocation.parse(["/Mimi", flag, node, codex, "--extra"]))
        XCTAssertNil(CodexDaemonSupervisorInvocation.parse(["/Mimi", flag, "cua_node/bin/node", codex]))
        XCTAssertNil(CodexDaemonSupervisorInvocation.parse(["/Mimi", node, flag, codex]))
        XCTAssertNil(CodexDaemonSupervisorInvocation.parse(["/Mimi"]))
    }

    func testNormalAppLaunchIsNotMistakenForSupervisorMode() {
        XCTAssertNil(CodexDaemonSupervisorInvocation.parse(["/Applications/Mimi Remote Mac.app/Contents/MacOS/Mimi Remote Mac"]))
        XCTAssertNil(CodexDaemonSupervisorInvocation.parse(["/Mimi", "--debug-seed-ui"]))
    }

    func testValidateRejectsProgramsOutsideDesktopBundle() {
        let rogue = CodexDaemonSupervisorInvocation.Command(node: "/tmp/node", codex: codex)
        XCTAssertEqual(
            CodexDaemonSupervisor.validate(rogue, verifySignature: { _, _ in true }),
            .notInsideDesktopBundle("node supervisor")
        )
    }

    func testValidateRejectsCodexFromAnotherBundle() {
        let mixed = CodexDaemonSupervisorInvocation.Command(
            node: node,
            codex: "/Applications/Impostor.app/Contents/Resources/codex"
        )
        XCTAssertEqual(
            CodexDaemonSupervisor.validate(mixed, verifySignature: { _, _ in true }),
            .bundleMismatch
        )
    }

    func testValidateRejectsUnsignedPrograms() {
        XCTAssertEqual(
            CodexDaemonSupervisor.validate(command(), verifySignature: { _, _ in false }),
            .signatureRejected("node supervisor")
        )
        // codex 单独被换掉时也必须拦下，不能因为 node 过了就放行整条链。
        XCTAssertEqual(
            CodexDaemonSupervisor.validate(command(), verifySignature: { _, identifier in
                identifier == CodexDaemonSupervisor.nodeSigningIdentifier
            }),
            .signatureRejected("Codex app-server")
        )
    }

    func testValidateAcceptsSignedDesktopPair() {
        XCTAssertNil(CodexDaemonSupervisor.validate(command(), verifySignature: { _, _ in true }))
    }

    func testChildArgumentsMatchTheShapeAgentdVerifiesAtRuntime() {
        // Go 侧 validateSharedDaemonNodeSupervisorProcess 按这个形态验收 node 进程命令行，
        // 任何一处顺序或字面量变化都会让运行态验签失败。
        XCTAssertEqual(
            CodexDaemonSupervisor.childArguments(node: node, codex: codex),
            [node, "-e", CodexDaemonSupervisor.nodeSupervisorScript, "--", codex, "app-server", "--listen", "unix://"]
        )
    }

    func testSupervisorScriptStaysSingleLineAndSelfContained() {
        let script = CodexDaemonSupervisor.nodeSupervisorScript
        // launchd 会把 plist 里带换行的 ProgramArguments 截断在第一处换行实体。
        XCTAssertFalse(script.contains("\n"))
        XCTAssertTrue(script.hasPrefix("'use strict';"))
        XCTAssertTrue(script.contains("require('node:child_process')"))
    }
}
