import Combine
import Foundation

/// Git 请求绑定主机代次和同一个客户端；复合操作不得中途向另一台主机取客户端。
struct WorkspaceGitHostLease {
    let scope: HostScope
    let client: any WorkspaceGitAPIClient
}

/// 工作区 Git 的唯一内存状态与操作入口，不依赖会话、选中项或 Agent Runtime。
/// SessionStore 的旧属性/方法暂时只转发，供页面和主机快照分阶段迁移。
@MainActor
final class WorkspaceGitStore: ObservableObject {
    @Published var gitStatusByPath: [String: GitStatusResponse] = [:]
    @Published var gitStatusErrorByPath: [String: String] = [:]
    @Published var workspaceGitSummaryByPath: [String: GitStatusResponse] = [:]
    @Published var workspaceGitSummaryUpdatedAtByPath: [String: Date] = [:]
    @Published var refreshingWorkspaceGitSummaryPaths: Set<String> = []
    @Published var isRefreshingGitStatus = false
    @Published var gitActionErrorByPath: [String: String] = [:]
    @Published var isRunningGitAction = false
    @Published var isCommittingGitChanges = false
    @Published var isPushingGitBranch = false
    @Published var isQuickPublishingGitChanges = false
    @Published var gitQuickPublishResultByPath: [String: GitQuickPublishResponse] = [:]
    @Published var gitTestFlightStatusByPath: [String: GitTestFlightStatusResponse] = [:]
    @Published var gitTestFlightErrorByPath: [String: String] = [:]
    @Published var isRefreshingGitTestFlightStatus = false
    @Published var isStartingGitTestFlightRelease = false
    @Published var isCreatingPullRequest = false
    @Published var pullRequestURLByPath: [String: String] = [:]
    @Published var pullRequestStatusByPath: [String: GitPullRequestStatusResponse] = [:]
    @Published var pullRequestStatusErrorByPath: [String: String] = [:]
    @Published var isRefreshingPullRequestStatus = false
    var gitRefreshTasksByPath: [String: Task<Void, Never>] = [:]
    var gitRefreshRevisionByPath: [String: UInt64] = [:]
    var gitRefreshDelayNanoseconds: UInt64 = 600_000_000

    static let workspaceGitSummaryTTL: TimeInterval = 60
    static let workspaceGitSummaryConcurrencyLimit = 3

    private let currentHostScope: () -> HostScope
    private let clientFactory: () throws -> any WorkspaceGitAPIClient

    init(
        currentHostScope: @escaping () -> HostScope,
        clientFactory: @escaping () throws -> any WorkspaceGitAPIClient
    ) {
        self.currentHostScope = currentHostScope
        self.clientFactory = clientFactory
    }

    deinit {
        gitRefreshTasksByPath.values.forEach { $0.cancel() }
    }

    private func captureHostLease() throws -> WorkspaceGitHostLease {
        WorkspaceGitHostLease(scope: currentHostScope(), client: try clientFactory())
    }

    private func isHostCurrent(_ lease: WorkspaceGitHostLease) -> Bool {
        currentHostScope() == lease.scope
    }

    private func canApplyResult(_ lease: WorkspaceGitHostLease) -> Bool {
        !Task.isCancelled && isHostCurrent(lease)
    }

    func refreshGitStatus(path: String) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty else {
            return
        }
        let lease: WorkspaceGitHostLease
        do {
            lease = try captureHostLease()
        } catch {
            gitStatusErrorByPath[targetPath] = error.localizedDescription
            return
        }
        await refreshGitStatus(path: targetPath, lease: lease)
    }

    private func refreshGitStatus(path targetPath: String, lease: WorkspaceGitHostLease) async {
        guard canApplyResult(lease) else { return }
        isRefreshingGitStatus = true
        defer {
            if isHostCurrent(lease) {
                isRefreshingGitStatus = false
            }
        }
        do {
            let status = try await lease.client.gitStatus(path: targetPath)
            guard canApplyResult(lease) else { return }
            // path 只在当前 Profile 内唯一；完整 HostScope lease 阻止旧 Mac 的同路径结果回填。
            gitStatusByPath[targetPath] = status
            cacheWorkspaceGitSummary(status, path: targetPath)
            gitStatusErrorByPath.removeValue(forKey: targetPath)
            gitActionErrorByPath.removeValue(forKey: targetPath)
        } catch {
            guard canApplyResult(lease) else { return }
            gitStatusErrorByPath[targetPath] = error.localizedDescription
        }
    }

    func refreshWorkspaceGitSummaries(paths workspacePaths: [String], force: Bool = false) async {
        let hostScope = currentHostScope()
        var seenPaths: Set<String> = []
        let paths = workspacePaths.compactMap { rawPath -> String? in
            let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, seenPaths.insert(path).inserted else {
                return nil
            }
            return path
        }

        // 每个摘要都会执行少量本地 Git 命令；分批并发既缩短 Tailscale 往返，
        // 又避免最近工作区较多时一次启动过多 git 子进程。
        for start in stride(from: 0, to: paths.count, by: Self.workspaceGitSummaryConcurrencyLimit) {
            guard !Task.isCancelled, currentHostScope() == hostScope else { return }
            let end = min(start + Self.workspaceGitSummaryConcurrencyLimit, paths.count)
            let batch = paths[start..<end]
            await withTaskGroup(of: Void.self) { group in
                for path in batch {
                    group.addTask { @MainActor [weak self] in
                        guard let self, self.currentHostScope() == hostScope else { return }
                        await self.refreshWorkspaceGitSummary(path: path, force: force)
                    }
                }
            }
        }
    }

    func refreshWorkspaceGitSummary(path: String, force: Bool = false, now: Date = Date()) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty,
              !refreshingWorkspaceGitSummaryPaths.contains(targetPath)
        else {
            return
        }
        if !force,
           let updatedAt = workspaceGitSummaryUpdatedAtByPath[targetPath],
           now.timeIntervalSince(updatedAt) < Self.workspaceGitSummaryTTL {
            return
        }

        let lease: WorkspaceGitHostLease
        do {
            lease = try captureHostLease()
        } catch {
            return
        }
        refreshingWorkspaceGitSummaryPaths.insert(targetPath)
        defer {
            if isHostCurrent(lease) {
                refreshingWorkspaceGitSummaryPaths.remove(targetPath)
            }
        }
        do {
            let status = try await lease.client.gitStatusSummary(path: targetPath)
            guard canApplyResult(lease) else { return }
            workspaceGitSummaryByPath[targetPath] = status
            workspaceGitSummaryUpdatedAtByPath[targetPath] = now
        } catch {
            // 卡片摘要是渐进增强：失败时保留旧缓存，不把局部 Git 问题提升成页面错误。
        }
    }

    func cacheWorkspaceGitSummary(_ status: GitStatusResponse, path: String, now: Date = Date()) {
        let previous = workspaceGitSummaryByPath[path]
        workspaceGitSummaryByPath[path] = GitStatusResponse(
            path: status.path,
            isRepository: status.isRepository,
            branch: status.branch,
            head: status.head,
            ahead: status.ahead ?? previous?.ahead,
            behind: status.behind ?? previous?.behind,
            upstream: status.upstream ?? previous?.upstream,
            statusText: nil,
            diffStat: nil,
            unstagedDiff: nil,
            stagedDiff: nil,
            files: status.files,
            truncated: status.truncated,
            truncatedNote: status.truncatedNote
        )
        workspaceGitSummaryUpdatedAtByPath[path] = now
    }

    func scheduleRefreshAfterTurnCompletion(
        path: String,
        hostScope: HostScope
    ) {
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard currentHostScope() == hostScope,
              !path.isEmpty,
              gitStatusByPath[path] != nil || workspaceGitSummaryByPath[path] != nil
        else {
            return
        }

        gitRefreshTasksByPath[path]?.cancel()
        let revision = gitRefreshRevisionByPath[path, default: 0] &+ 1
        gitRefreshRevisionByPath[path] = revision
        gitRefreshTasksByPath[path] = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: self.gitRefreshDelayNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  self.currentHostScope() == hostScope,
                  self.gitRefreshRevisionByPath[path] == revision
            else {
                return
            }

            if self.gitStatusByPath[path] != nil {
                await self.refreshGitStatus(path: path)
            } else if self.workspaceGitSummaryByPath[path] != nil {
                await self.refreshWorkspaceGitSummary(path: path, force: true)
            }

            guard self.currentHostScope() == hostScope,
                  self.gitRefreshRevisionByPath[path] == revision
            else {
                return
            }
            self.gitRefreshTasksByPath.removeValue(forKey: path)
            self.gitRefreshRevisionByPath.removeValue(forKey: path)
        }
    }

    func performGitAction(path: String, action: GitActionKind, files: [String]) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetFiles = files
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !targetPath.isEmpty, !targetFiles.isEmpty else {
            return
        }

        let lease: WorkspaceGitHostLease
        do {
            lease = try captureHostLease()
        } catch {
            gitActionErrorByPath[targetPath] = error.localizedDescription
            return
        }
        isRunningGitAction = true
        defer {
            if isHostCurrent(lease) {
                isRunningGitAction = false
            }
        }
        do {
            let status = try await lease.client.gitAction(
                path: targetPath,
                action: action,
                files: targetFiles
            )
            guard canApplyResult(lease) else { return }
            // 写动作成功后直接采用服务端返回的新状态，避免前端本地推断 Git index。
            gitStatusByPath[targetPath] = status
            cacheWorkspaceGitSummary(status, path: targetPath)
            gitStatusErrorByPath.removeValue(forKey: targetPath)
            gitActionErrorByPath.removeValue(forKey: targetPath)
        } catch {
            guard canApplyResult(lease) else { return }
            gitActionErrorByPath[targetPath] = error.localizedDescription
        }
    }

    func performGitPatchAction(path: String, action: GitActionKind, patch: String) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetPatch = patch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty, !targetPatch.isEmpty else {
            return
        }

        let lease: WorkspaceGitHostLease
        do {
            lease = try captureHostLease()
        } catch {
            gitActionErrorByPath[targetPath] = error.localizedDescription
            return
        }
        isRunningGitAction = true
        defer {
            if isHostCurrent(lease) {
                isRunningGitAction = false
            }
        }
        do {
            let status = try await lease.client.gitPatchAction(
                path: targetPath,
                action: action,
                patch: targetPatch
            )
            guard canApplyResult(lease) else { return }
            // hunk 操作同样以服务端返回为准，避免本地解析 patch 后再二次推断状态。
            gitStatusByPath[targetPath] = status
            cacheWorkspaceGitSummary(status, path: targetPath)
            gitStatusErrorByPath.removeValue(forKey: targetPath)
            gitActionErrorByPath.removeValue(forKey: targetPath)
        } catch {
            guard canApplyResult(lease) else { return }
            gitActionErrorByPath[targetPath] = error.localizedDescription
        }
    }

    func commitGitChanges(path: String, message: String) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let commitMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty, !commitMessage.isEmpty else {
            return
        }

        let lease: WorkspaceGitHostLease
        do {
            lease = try captureHostLease()
        } catch {
            gitActionErrorByPath[targetPath] = error.localizedDescription
            return
        }
        isCommittingGitChanges = true
        defer {
            if isHostCurrent(lease) {
                isCommittingGitChanges = false
            }
        }
        do {
            let status = try await lease.client.gitCommit(path: targetPath, message: commitMessage)
            guard canApplyResult(lease) else { return }
            // commit 只提交已暂存内容；成功后用服务端状态清理 staged diff 和文件列表。
            gitStatusByPath[targetPath] = status
            cacheWorkspaceGitSummary(status, path: targetPath)
            gitStatusErrorByPath.removeValue(forKey: targetPath)
            gitActionErrorByPath.removeValue(forKey: targetPath)
        } catch {
            guard canApplyResult(lease) else { return }
            gitActionErrorByPath[targetPath] = error.localizedDescription
        }
    }

    func pushGitBranch(path: String, remote: String? = nil) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetRemote = remote?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty else {
            return
        }

        let lease: WorkspaceGitHostLease
        do {
            lease = try captureHostLease()
        } catch {
            gitActionErrorByPath[targetPath] = error.localizedDescription
            return
        }
        isPushingGitBranch = true
        defer {
            if isHostCurrent(lease) {
                isPushingGitBranch = false
            }
        }
        do {
            let response = try await lease.client.gitPush(
                path: targetPath,
                remote: targetRemote?.isEmpty == true ? nil : targetRemote
            )
            guard canApplyResult(lease) else { return }
            gitStatusByPath[targetPath] = response.status
            cacheWorkspaceGitSummary(response.status, path: targetPath)
            gitStatusErrorByPath.removeValue(forKey: targetPath)
            gitActionErrorByPath.removeValue(forKey: targetPath)
        } catch {
            guard canApplyResult(lease) else { return }
            gitActionErrorByPath[targetPath] = error.localizedDescription
        }
    }

    @discardableResult
    func quickPublishGitChanges(path: String, message: String, remote: String? = nil) async -> Bool {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let commitMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetRemote = remote?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty, !commitMessage.isEmpty else {
            return false
        }

        let lease: WorkspaceGitHostLease
        do {
            lease = try captureHostLease()
        } catch {
            gitActionErrorByPath[targetPath] = error.localizedDescription
            return false
        }
        isQuickPublishingGitChanges = true
        defer {
            if isHostCurrent(lease) {
                isQuickPublishingGitChanges = false
            }
        }
        do {
            let response = try await lease.client.gitQuickPublish(
                path: targetPath,
                message: commitMessage,
                remote: targetRemote?.isEmpty == true ? nil : targetRemote,
                confirmed: true
            )
            guard canApplyResult(lease) else { return false }
            gitQuickPublishResultByPath[targetPath] = response
            gitStatusByPath[targetPath] = response.status
            cacheWorkspaceGitSummary(response.status, path: targetPath)
            gitStatusErrorByPath.removeValue(forKey: targetPath)
            gitActionErrorByPath.removeValue(forKey: targetPath)
            // 后续状态读取必须复用同一 client；切换后重新取工厂会把 A 的 path 发到 B。
            await refreshGitTestFlightStatus(path: targetPath, lease: lease)
            return canApplyResult(lease)
        } catch {
            guard canApplyResult(lease) else { return false }
            gitActionErrorByPath[targetPath] = error.localizedDescription
            // 组合动作可能已经完成本地 commit 但在 push 阶段失败，失败后必须重新读取真实 Git 状态。
            await refreshGitStatus(path: targetPath, lease: lease)
            return false
        }
    }

    func refreshGitTestFlightStatus(path: String) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty else {
            return
        }
        let lease: WorkspaceGitHostLease
        do {
            lease = try captureHostLease()
        } catch {
            gitTestFlightErrorByPath[targetPath] = error.localizedDescription
            return
        }
        await refreshGitTestFlightStatus(path: targetPath, lease: lease)
    }

    private func refreshGitTestFlightStatus(
        path targetPath: String,
        lease: WorkspaceGitHostLease
    ) async {
        guard canApplyResult(lease) else { return }
        isRefreshingGitTestFlightStatus = true
        defer {
            if isHostCurrent(lease) {
                isRefreshingGitTestFlightStatus = false
            }
        }
        do {
            let status = try await lease.client.gitTestFlightStatus(path: targetPath)
            guard canApplyResult(lease) else { return }
            gitTestFlightStatusByPath[targetPath] = status
            gitTestFlightErrorByPath.removeValue(forKey: targetPath)
        } catch {
            guard canApplyResult(lease) else { return }
            gitTestFlightErrorByPath[targetPath] = error.localizedDescription
        }
    }

    @discardableResult
    func startGitTestFlightRelease(path: String, whatToTest: String) async -> Bool {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty else {
            return false
        }
        let lease: WorkspaceGitHostLease
        do {
            lease = try captureHostLease()
        } catch {
            gitTestFlightErrorByPath[targetPath] = error.localizedDescription
            return false
        }
        isStartingGitTestFlightRelease = true
        defer {
            if isHostCurrent(lease) {
                isStartingGitTestFlightRelease = false
            }
        }
        do {
            let status = try await lease.client.gitTestFlightRun(
                path: targetPath,
                whatToTest: whatToTest.trimmingCharacters(in: .whitespacesAndNewlines),
                confirmed: true
            )
            guard canApplyResult(lease) else { return false }
            gitTestFlightStatusByPath[targetPath] = status
            gitTestFlightErrorByPath.removeValue(forKey: targetPath)
            return true
        } catch {
            guard canApplyResult(lease) else { return false }
            gitTestFlightErrorByPath[targetPath] = error.localizedDescription
            return false
        }
    }

    func pollGitTestFlightRelease(path: String) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty else {
            return
        }
        let lease: WorkspaceGitHostLease
        do {
            lease = try captureHostLease()
        } catch {
            gitTestFlightErrorByPath[targetPath] = error.localizedDescription
            return
        }
        while !Task.isCancelled {
            guard canApplyResult(lease) else { return }
            await refreshGitTestFlightStatus(path: targetPath, lease: lease)
            guard canApplyResult(lease),
                  gitTestFlightStatusByPath[targetPath]?.job?.isRunning == true else {
                return
            }
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
        }
    }

    func createPullRequest(path: String, title: String, body: String = "", draft: Bool = true) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let prTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty, !prTitle.isEmpty else {
            return
        }

        let lease: WorkspaceGitHostLease
        do {
            lease = try captureHostLease()
        } catch {
            gitActionErrorByPath[targetPath] = error.localizedDescription
            return
        }
        isCreatingPullRequest = true
        defer {
            if isHostCurrent(lease) {
                isCreatingPullRequest = false
            }
        }
        do {
            let response = try await lease.client.gitCreatePullRequest(
                path: targetPath,
                title: prTitle,
                body: body,
                draft: draft
            )
            guard canApplyResult(lease) else { return }
            if let url = response.url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
                pullRequestURLByPath[targetPath] = url
                pullRequestStatusByPath[targetPath] = GitPullRequestStatusResponse(
                    path: targetPath,
                    branch: response.branch,
                    exists: true,
                    title: prTitle,
                    url: url,
                    isDraft: draft
                )
            }
            pullRequestStatusErrorByPath.removeValue(forKey: targetPath)
            gitActionErrorByPath.removeValue(forKey: targetPath)
        } catch {
            guard canApplyResult(lease) else { return }
            gitActionErrorByPath[targetPath] = error.localizedDescription
        }
    }

    func refreshPullRequestStatus(path: String) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty else {
            return
        }

        let lease: WorkspaceGitHostLease
        do {
            lease = try captureHostLease()
        } catch {
            pullRequestStatusErrorByPath[targetPath] = error.localizedDescription
            return
        }
        isRefreshingPullRequestStatus = true
        defer {
            if isHostCurrent(lease) {
                isRefreshingPullRequestStatus = false
            }
        }
        do {
            let response = try await lease.client.gitPullRequestStatus(path: targetPath)
            guard canApplyResult(lease) else { return }
            pullRequestStatusByPath[targetPath] = response
            if let url = response.url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
                pullRequestURLByPath[targetPath] = url
            }
            pullRequestStatusErrorByPath.removeValue(forKey: targetPath)
        } catch {
            guard canApplyResult(lease) else { return }
            pullRequestStatusErrorByPath[targetPath] = error.localizedDescription
        }
    }
}
