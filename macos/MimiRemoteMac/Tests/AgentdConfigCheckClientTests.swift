import Foundation
import XCTest
@testable import MimiRemoteMac

final class AgentdConfigCheckClientTests: XCTestCase {
    func testDecodesUpgradeFindingFromCheckConfigStdout() throws {
        let stdout = """
        {
          "ok": false,
          "code": "config_requires_newer_version",
          "message": "旧 app_server.transport=\\"local\\" 不能自动迁移：请升级到最新发布包后重试"
        }
        """

        let result = try XCTUnwrap(AgentdConfigCheckClient.decode(stdout))

        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.requiresNewerVersion)
        XCTAssertEqual(
            result.message?.contains("请升级到最新发布包"),
            true,
            "升级结论必须带上 agentd 的原始原因"
        )
    }

    func testDecodesHealthyConfig() throws {
        let result = try XCTUnwrap(AgentdConfigCheckClient.decode(#"{"ok": true, "code": "ok"}"#))

        XCTAssertTrue(result.ok)
        XCTAssertFalse(result.requiresNewerVersion)
        XCTAssertNil(result.message)
    }

    /// 旧包没有 check-config 子命令时 stdout 不是 JSON。这时必须回退到原有诊断，
    /// 绝不能把「看不懂的输出」当成「需要升级安装包」。
    func testUnparseableStdoutFallsBackToNoFinding() {
        XCTAssertNil(AgentdConfigCheckClient.decode("未知命令 \"check-config\""))
        XCTAssertNil(AgentdConfigCheckClient.decode(""))
    }

    /// 有结论但没带升级码时同样不算升级：只有明确的码才允许引导用户换安装包。
    func testFailureWithoutUpgradeCodeIsNotTreatedAsUpgrade() throws {
        let result = try XCTUnwrap(AgentdConfigCheckClient.decode(#"{"ok": false}"#))

        XCTAssertFalse(result.ok)
        XCTAssertFalse(result.requiresNewerVersion)
    }

    func testOtherConfigFailureIsNotTreatedAsUpgrade() throws {
        let result = try XCTUnwrap(
            AgentdConfigCheckClient.decode(#"{"ok": false, "code": "config_invalid", "message": "auth.token 不能为空"}"#)
        )

        XCTAssertFalse(result.requiresNewerVersion, "只有明确的不兼容码才允许引导升级")
    }

    func testUpgradeMessageSurfacesAgentdReasonAndPointsAtUpgrading() throws {
        let error = ServiceLifecycleError.configRequiresNewerVersion(
            "旧 app_server.transport=\"local\" 不能自动迁移：请升级到最新发布包后重试"
        )

        let message = try XCTUnwrap(error.errorDescription)

        XCTAssertTrue(error.isConfigurationFailure, "配置不兼容必须跳过换代登记")
        XCTAssertTrue(message.contains("请升级到最新发布包"), message)
        XCTAssertTrue(message.contains("旧 app_server.transport"), message)
        XCTAssertFalse(message.contains("服务记录可能已过期"), message)
    }

    func testInvalidConfigurationAlsoSkipsRepair() throws {
        let error = ServiceLifecycleError.invalidConfiguration(
            "app_server.transport=\"stdio\" 已被移除；请执行 agentd setup --force 重置配置"
        )

        XCTAssertTrue(error.isConfigurationFailure, "配置坏掉时换多少次登记都不会变")
        XCTAssertEqual(error.errorDescription?.contains("setup --force"), true)
    }

    func testSpawnFailureKeepsRepairPathAndDropsStaleRecordClaim() throws {
        let error = ServiceLifecycleError.agentSpawnFailed("launchd 无法启动 agentd，最近退出码 78")

        let message = try XCTUnwrap(error.errorDescription)

        XCTAssertFalse(error.isConfigurationFailure, "覆盖安装后的换代恢复路径必须保留")
        XCTAssertFalse(message.contains("服务记录可能已过期"), message)
        XCTAssertTrue(message.contains("请升级到最新发布包"), message)
    }

    func testAutomaticRepairFailureDoesNotRepeatIdenticalDetail() throws {
        let detail = "macOS 无法启动后台服务（launchd 无法启动 agentd，最近退出码 1）。"

        let repeated = try XCTUnwrap(
            ServiceLifecycleError.automaticRepairFailed(initial: detail, recovery: detail).errorDescription
        )
        let distinct = try XCTUnwrap(
            ServiceLifecycleError
                .automaticRepairFailed(initial: detail, recovery: "登记超时")
                .errorDescription
        )

        XCTAssertEqual(repeated.components(separatedBy: detail).count - 1, 1, repeated)
        XCTAssertEqual(distinct.components(separatedBy: detail).count - 1, 1, distinct)
        XCTAssertTrue(distinct.contains("登记超时"), distinct)
    }
}
