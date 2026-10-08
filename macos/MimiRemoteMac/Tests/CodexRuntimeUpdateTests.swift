import Foundation
import XCTest
@testable import MimiRemoteMac

@MainActor
final class CodexRuntimeUpdateTests: XCTestCase {
    private nonisolated static let pending = CodexRuntimeVersions(
        installedVersion: "0.161.0", runningVersion: "0.155.1", updateAvailable: true
    )
    private nonisolated static let current = CodexRuntimeVersions(
        installedVersion: "0.161.0", runningVersion: "0.161.0", updateAvailable: false
    )

    func testReportsSuccessOnlyAfterVerifiedVersionSwitch() async {
        var agent = AgentCommandClient.live()
        agent.codexRuntimeVersions = { Self.pending }
        agent.updateCodexRuntime = { Self.current }
        let store = CodexRuntimeUpdateStore(agent: agent)
        await store.refresh()
        XCTAssertEqual(store.versions, Self.pending)
        await store.update()
        XCTAssertEqual(store.versions, Self.current)
        XCTAssertTrue(store.notice?.contains("0.161.0") == true)
        XCTAssertNil(store.error)
        XCTAssertFalse(store.isUpdating)
    }

    func testBusyBackendKeepsVersionAndActionableError() async {
        var agent = AgentCommandClient.live()
        agent.codexRuntimeVersions = { Self.pending }
        agent.updateCodexRuntime = {
            throw AgentClientError.commandFailed("请等待任务和排队消息完成后重试。")
        }
        let store = CodexRuntimeUpdateStore(agent: agent)
        await store.refresh()
        await store.update()
        XCTAssertEqual(store.versions, Self.pending)
        XCTAssertTrue(store.error?.contains("排队消息") == true)
        XCTAssertTrue(store.updateFailed)
        XCTAssertNil(store.notice)
    }

    func testUnavailableReplacementDoesNotKeepMisleadingRunningVersion() async {
        let reads = UpdateReadSequence()
        var agent = AgentCommandClient.live()
        agent.codexRuntimeVersions = {
            if await reads.next() == 1 { return Self.pending }
            throw AgentClientError.commandFailed("无法读取版本")
        }
        agent.updateCodexRuntime = {
            throw AgentClientError.commandFailed("旧版已退出，新版尚未连接成功。")
        }
        let store = CodexRuntimeUpdateStore(agent: agent)
        await store.refresh()
        await store.update()
        XCTAssertNil(store.versions)
        XCTAssertTrue(store.error?.contains("新版尚未连接") == true)
        XCTAssertTrue(store.updateFailed)
        XCTAssertNil(store.notice)
    }

    func testWrongVersionResponseCannotClaimSuccess() async {
        var agent = AgentCommandClient.live()
        agent.codexRuntimeVersions = { Self.pending }
        agent.updateCodexRuntime = {
            CodexRuntimeVersions(installedVersion: "0.161.0", runningVersion: "0.155.1", updateAvailable: false)
        }
        let store = CodexRuntimeUpdateStore(agent: agent)
        await store.refresh()
        await store.update()
        XCTAssertNil(store.notice)
        XCTAssertTrue(store.error?.contains("尚未完成") == true)
    }

    func testRepeatedClicksAndRefreshDoNotRaceWithSwitch() async {
        let gate = RuntimeUpdateGate()
        let reads = UpdateReadSequence()
        var agent = AgentCommandClient.live()
        agent.codexRuntimeVersions = { _ = await reads.next(); return Self.pending }
        agent.updateCodexRuntime = {
            await gate.suspend()
            return Self.current
        }
        let store = CodexRuntimeUpdateStore(agent: agent)
        await store.refresh()
        let first = Task { await store.update() }
        await gate.waitUntilSuspended()
        XCTAssertTrue(store.isUpdating)
        await store.update()
        await store.refresh()
        let count = await reads.count
        XCTAssertEqual(count, 1)
        await gate.resume()
        await first.value
        XCTAssertEqual(store.versions, Self.current)
        XCTAssertFalse(store.isUpdating)
    }

    func testCurrentRuntimeDoesNotRunUpdate() async {
        var agent = AgentCommandClient.live()
        agent.codexRuntimeVersions = { Self.current }
        agent.updateCodexRuntime = { XCTFail("无需切换时不能调用管理命令"); return Self.current }
        let store = CodexRuntimeUpdateStore(agent: agent)
        await store.refresh()
        await store.update()
        XCTAssertNil(store.notice)
    }

    func testVersionResponseRequiresBothVersionsAndUpdateState() throws {
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(
            CodexRuntimeVersions.self,
            from: Data(#"{"installed_version":"0.161.0","running_version":"0.155.1","update_available":true}"#.utf8)
        ), Self.pending)
        XCTAssertThrowsError(try decoder.decode(
            CodexRuntimeVersions.self, from: Data(#"{"update_available":true}"#.utf8)
        ))
    }
}

private actor UpdateReadSequence {
    private(set) var count = 0
    func next() -> Int { count += 1; return count }
}

private actor RuntimeUpdateGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func suspend() async { await withCheckedContinuation { continuation = $0 } }
    func waitUntilSuspended() async {
        while continuation == nil { await Task.yield() }
    }
    func resume() { continuation?.resume(); continuation = nil }
}
