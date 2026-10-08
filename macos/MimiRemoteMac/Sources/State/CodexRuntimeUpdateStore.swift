import Foundation
import Observation

struct CodexRuntimeVersions: Decodable, Equatable, Sendable {
    let installedVersion: String
    let runningVersion: String
    let updateAvailable: Bool
    let featureMismatch: Bool?
    let connections: CodexRuntimeConnections?

    init(installedVersion: String, runningVersion: String, updateAvailable: Bool,
         featureMismatch: Bool? = nil, connections: CodexRuntimeConnections? = nil) {
        self.installedVersion = installedVersion
        self.runningVersion = runningVersion
        self.updateAvailable = updateAvailable
        self.featureMismatch = featureMismatch
        self.connections = connections
    }

    // 旧版 agentd 不返回 feature_mismatch；nil 表示没有已知的连接设置冲突。
    var needsRecovery: Bool { updateAvailable || featureMismatch == true }

    enum CodingKeys: String, CodingKey {
        case installedVersion = "installed_version"
        case runningVersion = "running_version"
        case updateAvailable = "update_available"
        case featureMismatch = "feature_mismatch"
        case connections
    }
}

struct CodexRuntimeConnections: Decodable, Equatable, Sendable {
    let mimi: Int
    let codex: Int
    let other: Int
    var total: Int { mimi + codex + other }
}

@MainActor
@Observable
final class CodexRuntimeUpdateStore {
    private(set) var versions: CodexRuntimeVersions?
    private(set) var isChecking = false
    private(set) var isUpdating = false
    private(set) var error: String?
    private(set) var notice: String?
    private(set) var updateFailed = false
    private let agent: AgentCommandClient

    var hasSharedConnections: Bool { (versions?.connections?.total ?? 0) > 0 }

    init(agent: AgentCommandClient) {
        self.agent = agent
    }

    func refresh() async {
        guard !isChecking, !isUpdating else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            versions = try await agent.codexRuntimeVersions()
            error = nil
            notice = nil
            updateFailed = false
        } catch {
            self.error = error.localizedDescription
        }
    }

    func update(restart: Bool = false) async {
        guard !isChecking, !isUpdating, (!hasSharedConnections || restart),
              let pending = versions, pending.needsRecovery else { return }
        let repairsConnectionSettings = !pending.updateAvailable && pending.featureMismatch == true
        isUpdating = true
        error = nil
        notice = nil
        updateFailed = false
        defer { isUpdating = false }
        do {
            let result = try await agent.updateCodexRuntime(restart)
            // 修复结果必须同时清除版本和连接设置异常，不能把命令退出或旧快照当成成功。
            guard result.installedVersion == result.runningVersion, !result.updateAvailable else {
                throw AgentClientError.commandFailed("Codex 尚未完成版本切换，请刷新状态后重试。")
            }
            // 已确认的连接设置冲突必须由新版后台显式报告为 false；旧响应缺字段不能证明修复成功。
            let featureMismatchRemains = result.featureMismatch == true
                || (pending.featureMismatch == true && result.featureMismatch == nil)
            guard !featureMismatchRemains else {
                throw AgentClientError.commandFailed("Codex 连接设置尚未修复，请刷新状态后重试。")
            }
            versions = result
            notice = repairsConnectionSettings
                ? "Codex 连接已修复，可以继续使用。"
                : "已切换到 Codex \(result.runningVersion)，可以继续使用。"
        } catch {
            self.error = error.localizedDescription
            updateFailed = true
            // 修复或切换期间后台可能短暂退出；保留失败提示，同时重读真实状态。
            versions = try? await agent.codexRuntimeVersions()
        }
    }
}
