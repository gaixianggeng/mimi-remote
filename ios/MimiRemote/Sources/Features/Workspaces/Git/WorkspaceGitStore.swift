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
            gitStatusErrorByPath[targetPath] = UserFacingError.hostOperationMessage(for: error)
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
            gitStatusErrorByPath[targetPath] = UserFacingError.hostOperationMessage(for: error)
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
        // catalog 的子任务可能在主 actor 获得执行机会之前已被页面取消。
        // 不能先启动 Git 再丢弃结果，否则下一次有效刷新还会重复请求。
        guard !Task.isCancelled,
              !targetPath.isEmpty,
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
            gitActionErrorByPath[targetPath] = UserFacingError.hostOperationMessage(for: error)
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
            gitActionErrorByPath[targetPath] = UserFacingError.hostOperationMessage(for: error)
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
            gitActionErrorByPath[targetPath] = UserFacingError.hostOperationMessage(for: error)
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
            gitActionErrorByPath[targetPath] = UserFacingError.hostOperationMessage(for: error)
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
            gitActionErrorByPath[targetPath] = UserFacingError.hostOperationMessage(for: error)
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
            gitActionErrorByPath[targetPath] = UserFacingError.hostOperationMessage(for: error)
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
            gitActionErrorByPath[targetPath] = UserFacingError.hostOperationMessage(for: error)
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
            gitActionErrorByPath[targetPath] = UserFacingError.hostOperationMessage(for: error)
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
            gitActionErrorByPath[targetPath] = UserFacingError.hostOperationMessage(for: error)
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
            gitActionErrorByPath[targetPath] = UserFacingError.hostOperationMessage(for: error)
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
            gitTestFlightErrorByPath[targetPath] = UserFacingError.hostOperationMessage(for: error)
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
            gitTestFlightErrorByPath[targetPath] = UserFacingError.hostOperationMessage(for: error)
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
            gitTestFlightErrorByPath[targetPath] = UserFacingError.hostOperationMessage(for: error)
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
            gitTestFlightErrorByPath[targetPath] = UserFacingError.hostOperationMessage(for: error)
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
            gitTestFlightErrorByPath[targetPath] = UserFacingError.hostOperationMessage(for: error)
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
            gitActionErrorByPath[targetPath] = UserFacingError.hostOperationMessage(for: error)
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
            gitActionErrorByPath[targetPath] = UserFacingError.hostOperationMessage(for: error)
            if Self.isExistingPullRequestError(error) {
                // 已有 PR 时错误原文里的链接不上主界面；刷新状态让面板直接显示那个 PR。
                await refreshPullRequestStatus(path: targetPath)
            }
        }
    }

    static func isExistingPullRequestError(_ error: Error) -> Bool {
        guard case AgentAPIError.server(_, let message) = error else {
            return false
        }
        return UserFacingError.gitOperationMessage(for: message) == L10n.text("ui.git_pull_request_already_exists")
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
            pullRequestStatusErrorByPath[targetPath] = UserFacingError.hostOperationMessage(for: error)
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
            pullRequestStatusErrorByPath[targetPath] = UserFacingError.hostOperationMessage(for: error)
        }
    }
}

extension UserFacingError {
    /// Git / Worktree 等电脑端操作的失败文案（#508）。
    ///
    /// agentd 会原样回传 git 的 stderr（多行、带远端地址和路径）。高频场景先按 git 的固定说法
    /// 映射成可操作的本地化文案（推送被拒需先拉取、已存在、有未提交改动、合并冲突、没有可提交的改动），
    /// 不受原文里地址 / 路径的影响；其余只有 4xx 且通过与 #691 同一套门槛的原文才直接展示，
    /// 5xx、多行、HTML 错误页或带敏感信息的一律用分类文案。
    static func hostOperationMessage(for error: Error) -> String {
        guard case AgentAPIError.server(let status, let message) = error, status != 401 else {
            return UserFacingError(error).message
        }
        if let known = gitOperationMessage(for: message) {
            return known
        }
        if (400...499).contains(status), let reason = presentableComputerReason(message) {
            return reason
        }
        return UserFacingError(error).message
    }

    static func gitOperationMessage(for output: String) -> String? {
        let lowered = output.lowercased()
        func containsAny(_ needles: [String]) -> Bool {
            needles.contains { lowered.contains($0) }
        }
        // 服务端钩子 / 受保护分支拒绝：拉取解决不了，不能说成「远端有新提交」。
        if containsAny(["[remote rejected]", "hook declined", "protected branch"]) {
            return L10n.text("ui.git_push_remote_rejected")
        }
        // 只认 git 关于标签已存在的固定说法，分支名或路径里带 tag 字样不算。
        if lowered.range(of: "\\btag '[^']+' already exists", options: .regularExpression) != nil
            || lowered.range(of: "refs/tags/\\S+[^\\n]*\\(already exists\\)", options: .regularExpression) != nil
            // advice.pushUpdateRejected=false 时没有 hint，只剩标准推送状态行。
            || lowered.range(of: #"(?m)^\s*! \[rejected\]\s+\S+ -> \S+ \(already exists\)$"#, options: .regularExpression) != nil
            || lowered.contains("the tag already exists in the remote") {
            return L10n.text("ui.git_tag_already_exists")
        }
        // 只有明确的「落后于远端」信号才提示先拉取。
        if containsAny([
            "non-fast-forward",
            "fetch first",
            "remote contains work",
            "tip of your current branch is behind"
        ]) {
            return L10n.text("ui.git_push_rejected_pull_first")
        }
        if containsAny(["merge conflict", "conflict (content)", "fix conflicts", "unmerged files"]) {
            return L10n.text("ui.git_merge_conflict")
        }
        if containsAny([
            "contains modified or untracked files",
            "would be overwritten",
            "commit your changes or stash them",
            "uncommitted changes",
            "local changes"
        ]) {
            return L10n.text("ui.git_local_changes_block")
        }
        // 分支正被另一个 Worktree 使用时，换名字或拉取都不能解除占用；也不暴露电脑路径。
        if lowered.range(of: #"(?m)^fatal: '[^'\n]+' is already (?:checked out|used by worktree) at '[^\n]+'$"#, options: .regularExpression) != nil {
            return L10n.text("ui.git_branch_in_use")
        }
        // gh pr create 对已有 PR 的分支报「a pull request for branch … already exists」，与同名分支无关。
        if lowered.contains("a pull request for branch"), lowered.contains("already exists") {
            return L10n.text("ui.git_pull_request_already_exists")
        }
        // 只认 git 关于分支 / Worktree 已存在的固定说法；「remote origin already exists」这类
        // 远端配置或其他工具的「already exists」不算，退回通用处理。
        if lowered.range(of: #"fatal: (?:a branch named '[^'\n]+'|'[^'\n]+') already exists"#, options: .regularExpression) != nil {
            return L10n.text("ui.git_already_exists")
        }
        if lowered.contains("nothing to commit") {
            return L10n.text("ui.git_nothing_to_commit")
        }
        return nil
    }
}
