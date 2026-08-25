import Darwin
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

    private struct StagingFixture {
        let root: URL
        let command: CodexDaemonSupervisorInvocation.Command
        let helper: URL
    }

    private func makeStagingFixture(includeHelper: Bool = true) throws -> StagingFixture {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let resources = root.appending(path: "ChatGPT.app/Contents/Resources")
        let nodeDirectory = resources.appending(path: "cua_node/bin")
        try FileManager.default.createDirectory(at: nodeDirectory, withIntermediateDirectories: true)

        let sourceNode = nodeDirectory.appending(path: "node")
        let sourceCodex = resources.appending(path: "codex")
        let sourceHelper = resources.appending(path: "codex-code-mode-host")
        try Data("node".utf8).write(to: sourceNode)
        try Data("codex".utf8).write(to: sourceCodex)
        if includeHelper {
            try Data("code-mode-host".utf8).write(to: sourceHelper)
        }

        return StagingFixture(
            root: root,
            command: .init(node: sourceNode.path, codex: sourceCodex.path),
            helper: sourceHelper
        )
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
            .rejected(.notInsideDesktopBundle("node supervisor"))
        )
    }

    func testValidateRejectsCodexFromAnotherBundle() {
        let mixed = CodexDaemonSupervisorInvocation.Command(
            node: node,
            codex: "/Applications/Impostor.app/Contents/Resources/codex"
        )
        XCTAssertEqual(
            CodexDaemonSupervisor.validate(mixed, verifySignature: { _, _ in true }),
            .rejected(.bundleMismatch)
        )
    }

    func testValidateRejectsUnsignedPrograms() {
        XCTAssertEqual(
            CodexDaemonSupervisor.validate(command(), verifySignature: { _, _ in false }),
            .rejected(.signatureRejected("node supervisor"))
        )
        // codex 单独被换掉时也必须拦下，不能因为 node 过了就放行整条链。
        XCTAssertEqual(
            CodexDaemonSupervisor.validate(command(), verifySignature: { _, identifier in
                identifier == CodexDaemonSupervisor.nodeSigningIdentifier
            }),
            .rejected(.signatureRejected("Codex app-server"))
        )
    }

    func testValidateAcceptsSignedDesktopPair() {
        XCTAssertEqual(
            CodexDaemonSupervisor.validate(command(), verifySignature: { _, _ in true }),
            .accepted(command())
        )
    }

    func testValidateReturnsTheCanonicalPathsItVerified() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: UUID().uuidString)
        let resources = root.appending(path: "ChatGPT.app/Contents/Resources")
        let nodeDirectory = resources.appending(path: "cua_node/bin")
        try FileManager.default.createDirectory(at: nodeDirectory, withIntermediateDirectories: true)
        let canonicalNode = nodeDirectory.appending(path: "node")
        let canonicalCodex = resources.appending(path: "codex")
        XCTAssertTrue(FileManager.default.createFile(atPath: canonicalNode.path, contents: Data()))
        XCTAssertTrue(FileManager.default.createFile(atPath: canonicalCodex.path, contents: Data()))
        defer { try? FileManager.default.removeItem(at: root) }

        let links = root.appending(path: "links")
        try FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
        let nodeLink = links.appending(path: "node")
        let codexLink = links.appending(path: "codex")
        try FileManager.default.createSymbolicLink(at: nodeLink, withDestinationURL: canonicalNode)
        try FileManager.default.createSymbolicLink(at: codexLink, withDestinationURL: canonicalCodex)

        let linked = CodexDaemonSupervisorInvocation.Command(node: nodeLink.path, codex: codexLink.path)
        XCTAssertEqual(
            CodexDaemonSupervisor.validate(linked, verifySignature: { _, _ in true }),
            .accepted(.init(
                node: canonicalNode.resolvingSymlinksInPath().path,
                codex: canonicalCodex.resolvingSymlinksInPath().path
            ))
        )
    }

    func testSanitizedEnvironmentRemovesNodeInjectionAndDesktopTransport() {
        let environment = CodexDaemonSupervisor.sanitizedEnvironment([
            "PATH": "/usr/bin:/bin",
            "CODEX_HOME": "/tmp/codex-home",
            "NODE_OPTIONS": "--require=/tmp/evil.js",
            "NODE_PATH": "/tmp/modules",
            "NODE_FUTURE_INJECTION": "hostile",
            "CODEX_APP_SERVER_USE_LOCAL_DAEMON": "1",
            "CODEX_APP_SERVER_WS_URL": "ws://127.0.0.1:1",
            "MIMI_REMOTE_CODEX_DESKTOP_OWNERSHIP_EPOCH": "stale",
        ])

        XCTAssertEqual(environment, ["PATH": "/usr/bin:/bin", "CODEX_HOME": "/tmp/codex-home"])
    }

    func testStageExecutablesRejectsMissingCodeModeHostBeforeCloning() throws {
        let fixture = try makeStagingFixture(includeHelper: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        var cloneCalled = false
        XCTAssertThrowsError(
            try CodexDaemonSupervisor.stageExecutables(
                fixture.command,
                clone: { _, _ in cloneCalled = true },
                verifySignature: { _, _ in true }
            )
        ) { error in
            XCTAssertEqual(
                error as? CodexDaemonSupervisorError,
                .helperMissing(fixture.helper.path)
            )
        }
        XCTAssertFalse(cloneCalled)
    }

    func testStageExecutablesRejectsSymbolicLinkCodeModeHostBeforeCloning() throws {
        let fixture = try makeStagingFixture(includeHelper: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let realHelper = fixture.helper.deletingLastPathComponent().appending(path: "real-code-mode-host")
        try Data("code-mode-host".utf8).write(to: realHelper)
        try FileManager.default.createSymbolicLink(at: fixture.helper, withDestinationURL: realHelper)

        var cloneCalled = false
        XCTAssertThrowsError(
            try CodexDaemonSupervisor.stageExecutables(
                fixture.command,
                clone: { _, _ in cloneCalled = true },
                verifySignature: { _, _ in true }
            )
        ) { error in
            XCTAssertEqual(
                error as? CodexDaemonSupervisorError,
                .helperMissing(fixture.helper.path)
            )
        }
        XCTAssertFalse(cloneCalled)
    }

    func testStageExecutablesRejectsUnsignedCodeModeHostAndCleansUp() throws {
        let fixture = try makeStagingFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        var stagedDirectory: URL?
        var thrownError: Error?
        XCTAssertThrowsError(
            try CodexDaemonSupervisor.stageExecutables(
                fixture.command,
                clone: { source, destination in
                    stagedDirectory = URL(fileURLWithPath: destination).deletingLastPathComponent()
                    try FileManager.default.copyItem(atPath: source, toPath: destination)
                },
                verifySignature: { _, identifier in
                    identifier != CodexDaemonSupervisor.codeModeHostSigningIdentifier
                }
            )
        ) { thrownError = $0 }
        XCTAssertEqual(
            thrownError as? CodexDaemonSupervisorError,
            .signatureRejected("一次性 codex-code-mode-host")
        )
        XCTAssertNotNil(stagedDirectory)
        if let stagedDirectory {
            XCTAssertFalse(FileManager.default.fileExists(atPath: stagedDirectory.path))
        }
    }

    func testStageExecutablesCloneFailureCleansUpPartialDirectory() throws {
        let fixture = try makeStagingFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        var stagedDirectory: URL?
        var thrownError: Error?
        XCTAssertThrowsError(
            try CodexDaemonSupervisor.stageExecutables(
                fixture.command,
                clone: { source, destination in
                    stagedDirectory = URL(fileURLWithPath: destination).deletingLastPathComponent()
                    if source == fixture.helper.path {
                        throw CodexDaemonSupervisorError.stagingFailed("simulated clone failure")
                    }
                    try FileManager.default.copyItem(atPath: source, toPath: destination)
                },
                verifySignature: { _, _ in true }
            )
        ) { thrownError = $0 }
        XCTAssertEqual(
            thrownError as? CodexDaemonSupervisorError,
            .stagingFailed("simulated clone failure")
        )
        XCTAssertNotNil(stagedDirectory)
        if let stagedDirectory {
            XCTAssertFalse(FileManager.default.fileExists(atPath: stagedDirectory.path))
        }
    }

    func testStageExecutablesVerifiesThreeIndependentCopiesAndMakesDirectoryReadOnly() throws {
        let fixture = try makeStagingFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        var verified: [String] = []
        var clonedSources: [String] = []
        let staging = try CodexDaemonSupervisor.stageExecutables(
            fixture.command,
            clone: { source, destination in
                clonedSources.append(source)
                try FileManager.default.copyItem(atPath: source, toPath: destination)
            },
            verifySignature: { path, identifier in
                verified.append(identifier + ":" + path)
                return true
            }
        )
        defer { staging.remove() }

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: staging.node)), Data("node".utf8))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: staging.codex)), Data("codex".utf8))
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: staging.codeModeHost)),
            Data("code-mode-host".utf8)
        )
        XCTAssertEqual(
            staging.codeModeHost,
            staging.directory.appending(path: "codex-code-mode-host").path
        )
        XCTAssertEqual(clonedSources, [fixture.command.node, fixture.command.codex, fixture.helper.path])
        XCTAssertEqual(
            verified.map { $0.components(separatedBy: ":").first! },
            [
                CodexDaemonSupervisor.nodeSigningIdentifier,
                CodexDaemonSupervisor.codexSigningIdentifier,
                CodexDaemonSupervisor.codeModeHostSigningIdentifier,
            ]
        )
        for path in [staging.node, staging.codex, staging.codeModeHost] {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o500)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: staging.directory.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o500)
    }

    func testStageExecutablesCleanupRemovesTheReadOnlyDirectory() throws {
        let fixture = try makeStagingFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let staging = try CodexDaemonSupervisor.stageExecutables(
            fixture.command,
            clone: { source, destination in
                try FileManager.default.copyItem(atPath: source, toPath: destination)
            },
            verifySignature: { _, _ in true }
        )
        let directory = staging.directory
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        staging.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testWaitStatusMappingMatchesSupervisorContract() {
        XCTAssertEqual(CodexDaemonSupervisor.terminationStatus(for: 0), 0)
        XCTAssertEqual(CodexDaemonSupervisor.terminationStatus(for: 42 << 8), 42)
        XCTAssertEqual(CodexDaemonSupervisor.terminationStatus(for: SIGTERM), 1)
        XCTAssertEqual(CodexDaemonSupervisor.terminationStatus(for: 0x7f), 70)
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
        XCTAssertTrue(script.contains("MIMI_REMOTE_PINNED_CODEX_PATH"))
        XCTAssertTrue(script.contains("argv0:argv[0]"))
    }
}
