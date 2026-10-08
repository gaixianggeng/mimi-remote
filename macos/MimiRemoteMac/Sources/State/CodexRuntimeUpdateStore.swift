import Foundation
import Observation

struct CodexRuntimeVersions: Decodable, Equatable, Sendable {
    let installedVersion: String
    let runningVersion: String
    let updateAvailable: Bool
    let connections: CodexRuntimeConnections?

    init(installedVersion: String, runningVersion: String, updateAvailable: Bool,
         connections: CodexRuntimeConnections? = nil) {
        self.installedVersion = installedVersion
        self.runningVersion = runningVersion
        self.updateAvailable = updateAvailable
        self.connections = connections
    }

    enum CodingKeys: String, CodingKey {
        case installedVersion = "installed_version"
        case runningVersion = "running_version"
        case updateAvailable = "update_available"
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
        guard !isChecking, !isUpdating, (!hasSharedConnections || restart), versions?.updateAvailable == true else { return }
        isUpdating = true
        error = nil
        notice = nil
        updateFailed = false
        defer { isUpdating = false }
        do {
            let result = try await agent.updateCodexRuntime(restart)
            // 只有实际握手版本一致才呈现成功，不能把命令退出或旧快照当成更新完成。
            guard !result.updateAvailable, result.installedVersion == result.runningVersion else {
                throw AgentClientError.commandFailed("Codex 尚未完成版本切换，请刷新状态后重试。")
            }
            versions = result
            notice = "已切换到 Codex \(result.runningVersion)，可以继续使用。"
        } catch {
            self.error = error.localizedDescription
            updateFailed = true
            // 旧后台可能已退出而新版尚未就绪；保留失败提示，同时重读真实版本。
            versions = try? await agent.codexRuntimeVersions()
        }
    }
}
