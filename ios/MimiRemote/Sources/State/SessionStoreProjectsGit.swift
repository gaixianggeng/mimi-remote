import Foundation

/// Projects/Git 请求必须把主机身份和 client 一起冻结；endpoint 切换后不能重新从全局工厂取 client。
struct ProjectsGitHostLease {
    let scope: HostScope
    let client: any SessionStoreAPIClient
}

// 文件预览、命令动作、Git、项目列表与网络恢复按工作区能力集中。
extension SessionStore {
    func captureProjectsGitHostLease() throws -> ProjectsGitHostLease {
        let scope = appStore.activeHostScope
        let client = try clientFactory()
        return ProjectsGitHostLease(scope: scope, client: client)
    }

    private func isProjectsGitHostCurrent(_ lease: ProjectsGitHostLease) -> Bool {
        appStore.activeHostScope == lease.scope
    }

    private func canApplyProjectsGitResult(_ lease: ProjectsGitHostLease) -> Bool {
        !Task.isCancelled && isProjectsGitHostCurrent(lease)
    }

    func requireCurrentProjectsGitHost(_ lease: ProjectsGitHostLease) throws {
        guard canApplyProjectsGitResult(lease) else {
            throw CancellationError()
        }
    }

    /// 媒体缓存只使用稳定 Profile ID 作为命名空间；legacy 单连接由 AppStore 提供哈希回退值。
    var mediaProfileScope: String {
        appStore.notificationRoutingProfileID
    }

    func listDirectories(path: String) async throws -> DirectoryListResponse {
        let lease = try captureProjectsGitHostLease()
        do {
            let response = try await lease.client.listDirectories(path: path)
            try requireCurrentProjectsGitHost(lease)
            return response
        } catch {
            // 旧主机的失败也属于旧结果，统一转成取消，避免 B 页面展示 A 的网络错误。
            try requireCurrentProjectsGitHost(lease)
            throw error
        }
    }

    // 文件预览同样不污染全局错误状态：后端只返回授权边界内的普通文件，客户端落到临时目录后交给 QuickLook。
    func previewFile(path: String) async throws -> URL {
        let lease = try captureProjectsGitHostLease()
        let profileID = mediaProfileScope
        let response: FileReadResponse
        do {
            response = try await lease.client.readFile(path: path)
            try requireCurrentProjectsGitHost(lease)
        } catch {
            try requireCurrentProjectsGitHost(lease)
            throw error
        }
        let url: URL
        do {
            url = try await MediaWorker.shared.previewURL(
                from: MediaPreviewPayload(response: response),
                profileID: profileID
            )
        } catch {
            try requireCurrentProjectsGitHost(lease)
            throw error
        }
        guard canApplyProjectsGitResult(lease) else {
            await MediaWorker.shared.discardPreview(at: url)
            throw CancellationError()
        }
        return url
    }

    // 历史图片走 app-server gateway 的短期缓存 ID，不阻塞会话文字首屏；点按后再落到临时文件预览。
    func previewHistoryMedia(id: String) async throws -> URL {
        let lease = try captureProjectsGitHostLease()
        let profileID = mediaProfileScope
        let response: FileReadResponse
        do {
            response = try await lease.client.readHistoryMedia(id: id)
            try requireCurrentProjectsGitHost(lease)
        } catch {
            try requireCurrentProjectsGitHost(lease)
            throw error
        }
        let url: URL
        do {
            url = try await MediaWorker.shared.previewURL(
                from: MediaPreviewPayload(response: response),
                profileID: profileID
            )
        } catch {
            try requireCurrentProjectsGitHost(lease)
            throw error
        }
        guard canApplyProjectsGitResult(lease) else {
            await MediaWorker.shared.discardPreview(at: url)
            throw CancellationError()
        }
        return url
    }

    // 超大过程输出只在用户主动打开时下载，并交给 QuickLook 渐进展示；
    // 不把几 MB 的文本放回 SwiftUI 时间线的 Text 树，避免解析与布局卡顿。
    func previewHistoryOutput(id: String) async throws -> URL {
        let lease = try captureProjectsGitHostLease()
        let profileID = mediaProfileScope
        let response: FileReadResponse
        do {
            response = try await lease.client.readHistoryOutput(id: id)
            try requireCurrentProjectsGitHost(lease)
        } catch {
            try requireCurrentProjectsGitHost(lease)
            throw error
        }
        let url: URL
        do {
            url = try await MediaWorker.shared.previewURL(
                from: MediaPreviewPayload(response: response),
                profileID: profileID
            )
        } catch {
            try requireCurrentProjectsGitHost(lease)
            throw error
        }
        guard canApplyProjectsGitResult(lease) else {
            await MediaWorker.shared.discardPreview(at: url)
            throw CancellationError()
        }
        return url
    }

    func refreshSelectedCommandActions() async {
        guard let path = selectedCommandActionPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            return
        }
        await refreshCommandActions(path: path)
    }

    func refreshCommandActions(path: String) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty else {
            return
        }
        let lease: ProjectsGitHostLease
        do {
            lease = try captureProjectsGitHostLease()
        } catch {
            commandActionsByPath[targetPath] = []
            commandActionErrorByPath[targetPath] = error.localizedDescription
            return
        }
        isRefreshingCommandActions = true
        defer {
            if isProjectsGitHostCurrent(lease) {
                isRefreshingCommandActions = false
            }
        }
        do {
            let actions = try await lease.client.commandActions(path: targetPath)
            guard canApplyProjectsGitResult(lease) else { return }
            // action 是 agentd 配置里的 allowlist，只按工作区 path 缓存，避免跨会话串结果。
            commandActionsByPath[targetPath] = actions
            commandActionErrorByPath.removeValue(forKey: targetPath)
        } catch {
            guard canApplyProjectsGitResult(lease) else { return }
            commandActionsByPath[targetPath] = []
            commandActionErrorByPath[targetPath] = error.localizedDescription
        }
    }

    func runSelectedCommandAction(_ action: AgentCommandAction) async {
        guard let path = selectedCommandActionPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            return
        }
        await runCommandAction(path: path, id: action.id, confirmed: action.requiresConfirmation)
    }

    func runCommandAction(path: String, id: String, confirmed: Bool = false) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let actionID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty, !actionID.isEmpty else {
            return
        }

        let run = QueuedCommandActionRun(path: targetPath, id: actionID, confirmed: confirmed)
        if isRunningCommandAction {
            enqueueCommandActionRun(run)
            return
        }

        await drainCommandActionRuns(startingWith: run)
    }

    func enqueueCommandActionRun(_ run: QueuedCommandActionRun) {
        queuedCommandActionRuns.append(run)
        var ids = queuedCommandActionIDsByPath[run.path] ?? []
        ids.append(run.id)
        queuedCommandActionIDsByPath[run.path] = ids
    }

    func dequeueCommandActionRun() -> QueuedCommandActionRun? {
        guard !queuedCommandActionRuns.isEmpty else {
            return nil
        }
        let run = queuedCommandActionRuns.removeFirst()
        var ids = queuedCommandActionIDsByPath[run.path] ?? []
        if let index = ids.firstIndex(of: run.id) {
            ids.remove(at: index)
        }
        if ids.isEmpty {
            queuedCommandActionIDsByPath.removeValue(forKey: run.path)
        } else {
            queuedCommandActionIDsByPath[run.path] = ids
        }
        return run
    }

    func drainCommandActionRuns(startingWith firstRun: QueuedCommandActionRun) async {
        let hostScope = appStore.activeHostScope
        var nextRun: QueuedCommandActionRun? = firstRun
        while let run = nextRun {
            guard !Task.isCancelled, appStore.activeHostScope == hostScope else { return }
            await performCommandActionRun(run)
            guard !Task.isCancelled, appStore.activeHostScope == hostScope else { return }
            nextRun = dequeueCommandActionRun()
        }
    }

    func performCommandActionRun(_ run: QueuedCommandActionRun) async {
        let lease: ProjectsGitHostLease
        do {
            lease = try captureProjectsGitHostLease()
        } catch {
            commandActionErrorByPath[run.path] = error.localizedDescription
            return
        }
        runningCommandActionPath = run.path
        runningCommandActionID = run.id
        defer {
            if isProjectsGitHostCurrent(lease) {
                runningCommandActionPath = nil
                runningCommandActionID = nil
            }
        }
        do {
            let response = try await lease.client.runCommandAction(
                path: run.path,
                id: run.id,
                confirmed: run.confirmed
            )
            guard canApplyProjectsGitResult(lease) else { return }
            commandActionResultByPath[run.path] = response
            var history = commandActionHistoryByPath[run.path] ?? []
            // 执行历史只做本地短缓存，不写后端，避免命令输出长期留存在配置服务里。
            history.insert(response, at: 0)
            if history.count > Self.commandActionHistoryLimit {
                history.removeLast(history.count - Self.commandActionHistoryLimit)
            }
            commandActionHistoryByPath[run.path] = history
            commandActionErrorByPath.removeValue(forKey: run.path)
        } catch {
            guard canApplyProjectsGitResult(lease) else { return }
            commandActionErrorByPath[run.path] = error.localizedDescription
        }
    }

    func refreshSelectedGitStatus() async {
        guard let path = selectedGitStatusPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            return
        }
        await refreshGitStatus(path: path)
    }

    func refreshGitStatus(path: String) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty else {
            return
        }
        let lease: ProjectsGitHostLease
        do {
            lease = try captureProjectsGitHostLease()
        } catch {
            gitStatusErrorByPath[targetPath] = error.localizedDescription
            return
        }
        await refreshGitStatus(path: targetPath, lease: lease)
    }

    private func refreshGitStatus(path targetPath: String, lease: ProjectsGitHostLease) async {
        guard canApplyProjectsGitResult(lease) else { return }
        isRefreshingGitStatus = true
        defer {
            if isProjectsGitHostCurrent(lease) {
                isRefreshingGitStatus = false
            }
        }
        do {
            let status = try await lease.client.gitStatus(path: targetPath)
            guard canApplyProjectsGitResult(lease) else { return }
            // path 只在当前 Profile 内唯一；完整 HostScope lease 阻止旧 Mac 的同路径结果回填。
            gitStatusByPath[targetPath] = status
            cacheWorkspaceGitSummary(status, path: targetPath)
            gitStatusErrorByPath.removeValue(forKey: targetPath)
            gitActionErrorByPath.removeValue(forKey: targetPath)
        } catch {
            guard canApplyProjectsGitResult(lease) else { return }
            gitStatusErrorByPath[targetPath] = error.localizedDescription
        }
    }

    func refreshWorkspaceGitSummaries(for projects: [AgentProject], force: Bool = false) async {
        let hostScope = appStore.activeHostScope
        var seenPaths: Set<String> = []
        let paths = projects.compactMap { project -> String? in
            let path = project.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, seenPaths.insert(path).inserted else {
                return nil
            }
            return path
        }

        // 每个摘要都会执行少量本地 Git 命令；分批并发既缩短 Tailscale 往返，
        // 又避免最近工作区较多时一次启动过多 git 子进程。
        for start in stride(from: 0, to: paths.count, by: Self.workspaceGitSummaryConcurrencyLimit) {
            guard !Task.isCancelled, appStore.activeHostScope == hostScope else { return }
            let end = min(start + Self.workspaceGitSummaryConcurrencyLimit, paths.count)
            let batch = paths[start..<end]
            await withTaskGroup(of: Void.self) { group in
                for path in batch {
                    group.addTask { @MainActor [weak self] in
                        guard let self, self.appStore.activeHostScope == hostScope else { return }
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

        let lease: ProjectsGitHostLease
        do {
            lease = try captureProjectsGitHostLease()
        } catch {
            return
        }
        refreshingWorkspaceGitSummaryPaths.insert(targetPath)
        defer {
            if isProjectsGitHostCurrent(lease) {
                refreshingWorkspaceGitSummaryPaths.remove(targetPath)
            }
        }
        do {
            let status = try await lease.client.gitStatusSummary(path: targetPath)
            guard canApplyProjectsGitResult(lease) else { return }
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

    /// Agent 回合结束后只刷新用户已经看过的 Git 状态。按 path 合并尾部事件，
    /// 避免每个 diff/patch 通知都在 Mac 上启动一组 Git 子进程。
    func scheduleGitRefreshAfterTurnCompletion(
        sessionID: SessionID,
        hostScope: HostScope
    ) {
        guard appStore.activeHostScope == hostScope,
              let path = sessionsByID[sessionID]?.dir.trimmingCharacters(in: .whitespacesAndNewlines),
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
                  self.appStore.activeHostScope == hostScope,
                  self.gitRefreshRevisionByPath[path] == revision
            else {
                return
            }

            if self.gitStatusByPath[path] != nil {
                await self.refreshGitStatus(path: path)
            } else if self.workspaceGitSummaryByPath[path] != nil {
                await self.refreshWorkspaceGitSummary(path: path, force: true)
            }

            guard self.appStore.activeHostScope == hostScope,
                  self.gitRefreshRevisionByPath[path] == revision
            else {
                return
            }
            self.gitRefreshTasksByPath.removeValue(forKey: path)
            self.gitRefreshRevisionByPath.removeValue(forKey: path)
        }
    }

    func performSelectedGitAction(_ action: GitActionKind, files: [String]) async {
        guard let path = selectedGitStatusPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            return
        }
        await performGitAction(path: path, action: action, files: files)
    }

    func performGitAction(path: String, action: GitActionKind, files: [String]) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetFiles = files
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !targetPath.isEmpty, !targetFiles.isEmpty else {
            return
        }

        let lease: ProjectsGitHostLease
        do {
            lease = try captureProjectsGitHostLease()
        } catch {
            gitActionErrorByPath[targetPath] = error.localizedDescription
            return
        }
        isRunningGitAction = true
        defer {
            if isProjectsGitHostCurrent(lease) {
                isRunningGitAction = false
            }
        }
        do {
            let status = try await lease.client.gitAction(
                path: targetPath,
                action: action,
                files: targetFiles
            )
            guard canApplyProjectsGitResult(lease) else { return }
            // 写动作成功后直接采用服务端返回的新状态，避免前端本地推断 Git index。
            gitStatusByPath[targetPath] = status
            cacheWorkspaceGitSummary(status, path: targetPath)
            gitStatusErrorByPath.removeValue(forKey: targetPath)
            gitActionErrorByPath.removeValue(forKey: targetPath)
        } catch {
            guard canApplyProjectsGitResult(lease) else { return }
            gitActionErrorByPath[targetPath] = error.localizedDescription
        }
    }

    func performSelectedGitPatchAction(_ action: GitActionKind, patch: String) async {
        guard let path = selectedGitStatusPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            return
        }
        await performGitPatchAction(path: path, action: action, patch: patch)
    }

    func performGitPatchAction(path: String, action: GitActionKind, patch: String) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetPatch = patch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty, !targetPatch.isEmpty else {
            return
        }

        let lease: ProjectsGitHostLease
        do {
            lease = try captureProjectsGitHostLease()
        } catch {
            gitActionErrorByPath[targetPath] = error.localizedDescription
            return
        }
        isRunningGitAction = true
        defer {
            if isProjectsGitHostCurrent(lease) {
                isRunningGitAction = false
            }
        }
        do {
            let status = try await lease.client.gitPatchAction(
                path: targetPath,
                action: action,
                patch: targetPatch
            )
            guard canApplyProjectsGitResult(lease) else { return }
            // hunk 操作同样以服务端返回为准，避免本地解析 patch 后再二次推断状态。
            gitStatusByPath[targetPath] = status
            cacheWorkspaceGitSummary(status, path: targetPath)
            gitStatusErrorByPath.removeValue(forKey: targetPath)
            gitActionErrorByPath.removeValue(forKey: targetPath)
        } catch {
            guard canApplyProjectsGitResult(lease) else { return }
            gitActionErrorByPath[targetPath] = error.localizedDescription
        }
    }

    func commitSelectedGitChanges(message: String) async {
        guard let path = selectedGitStatusPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            return
        }
        await commitGitChanges(path: path, message: message)
    }

    func commitGitChanges(path: String, message: String) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let commitMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty, !commitMessage.isEmpty else {
            return
        }

        let lease: ProjectsGitHostLease
        do {
            lease = try captureProjectsGitHostLease()
        } catch {
            gitActionErrorByPath[targetPath] = error.localizedDescription
            return
        }
        isCommittingGitChanges = true
        defer {
            if isProjectsGitHostCurrent(lease) {
                isCommittingGitChanges = false
            }
        }
        do {
            let status = try await lease.client.gitCommit(path: targetPath, message: commitMessage)
            guard canApplyProjectsGitResult(lease) else { return }
            // commit 只提交已暂存内容；成功后用服务端状态清理 staged diff 和文件列表。
            gitStatusByPath[targetPath] = status
            cacheWorkspaceGitSummary(status, path: targetPath)
            gitStatusErrorByPath.removeValue(forKey: targetPath)
            gitActionErrorByPath.removeValue(forKey: targetPath)
        } catch {
            guard canApplyProjectsGitResult(lease) else { return }
            gitActionErrorByPath[targetPath] = error.localizedDescription
        }
    }

    func pushSelectedGitBranch(remote: String? = nil) async {
        guard let path = selectedGitStatusPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            return
        }
        await pushGitBranch(path: path, remote: remote)
    }

    func pushGitBranch(path: String, remote: String? = nil) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetRemote = remote?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty else {
            return
        }

        let lease: ProjectsGitHostLease
        do {
            lease = try captureProjectsGitHostLease()
        } catch {
            gitActionErrorByPath[targetPath] = error.localizedDescription
            return
        }
        isPushingGitBranch = true
        defer {
            if isProjectsGitHostCurrent(lease) {
                isPushingGitBranch = false
            }
        }
        do {
            let response = try await lease.client.gitPush(
                path: targetPath,
                remote: targetRemote?.isEmpty == true ? nil : targetRemote
            )
            guard canApplyProjectsGitResult(lease) else { return }
            gitStatusByPath[targetPath] = response.status
            cacheWorkspaceGitSummary(response.status, path: targetPath)
            gitStatusErrorByPath.removeValue(forKey: targetPath)
            gitActionErrorByPath.removeValue(forKey: targetPath)
        } catch {
            guard canApplyProjectsGitResult(lease) else { return }
            gitActionErrorByPath[targetPath] = error.localizedDescription
        }
    }

    @discardableResult
    func quickPublishSelectedGitChanges(message: String, remote: String? = nil) async -> Bool {
        guard let path = selectedGitStatusPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            return false
        }
        return await quickPublishGitChanges(path: path, message: message, remote: remote)
    }

    @discardableResult
    func quickPublishGitChanges(path: String, message: String, remote: String? = nil) async -> Bool {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let commitMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetRemote = remote?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty, !commitMessage.isEmpty else {
            return false
        }

        let lease: ProjectsGitHostLease
        do {
            lease = try captureProjectsGitHostLease()
        } catch {
            gitActionErrorByPath[targetPath] = error.localizedDescription
            return false
        }
        isQuickPublishingGitChanges = true
        defer {
            if isProjectsGitHostCurrent(lease) {
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
            guard canApplyProjectsGitResult(lease) else { return false }
            gitQuickPublishResultByPath[targetPath] = response
            gitStatusByPath[targetPath] = response.status
            cacheWorkspaceGitSummary(response.status, path: targetPath)
            gitStatusErrorByPath.removeValue(forKey: targetPath)
            gitActionErrorByPath.removeValue(forKey: targetPath)
            // 后续状态读取必须复用同一 client；切换后重新取工厂会把 A 的 path 发到 B。
            await refreshGitTestFlightStatus(path: targetPath, lease: lease)
            return canApplyProjectsGitResult(lease)
        } catch {
            guard canApplyProjectsGitResult(lease) else { return false }
            gitActionErrorByPath[targetPath] = error.localizedDescription
            // 组合动作可能已经完成本地 commit 但在 push 阶段失败，失败后必须重新读取真实 Git 状态。
            await refreshGitStatus(path: targetPath, lease: lease)
            return false
        }
    }

    func refreshSelectedGitTestFlightStatus() async {
        guard let path = selectedGitStatusPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            return
        }
        await refreshGitTestFlightStatus(path: path)
    }

    func refreshGitTestFlightStatus(path: String) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty else {
            return
        }
        let lease: ProjectsGitHostLease
        do {
            lease = try captureProjectsGitHostLease()
        } catch {
            gitTestFlightErrorByPath[targetPath] = error.localizedDescription
            return
        }
        await refreshGitTestFlightStatus(path: targetPath, lease: lease)
    }

    private func refreshGitTestFlightStatus(
        path targetPath: String,
        lease: ProjectsGitHostLease
    ) async {
        guard canApplyProjectsGitResult(lease) else { return }
        isRefreshingGitTestFlightStatus = true
        defer {
            if isProjectsGitHostCurrent(lease) {
                isRefreshingGitTestFlightStatus = false
            }
        }
        do {
            let status = try await lease.client.gitTestFlightStatus(path: targetPath)
            guard canApplyProjectsGitResult(lease) else { return }
            gitTestFlightStatusByPath[targetPath] = status
            gitTestFlightErrorByPath.removeValue(forKey: targetPath)
        } catch {
            guard canApplyProjectsGitResult(lease) else { return }
            gitTestFlightErrorByPath[targetPath] = error.localizedDescription
        }
    }

    @discardableResult
    func startSelectedGitTestFlightRelease(whatToTest: String) async -> Bool {
        guard let path = selectedGitStatusPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            return false
        }
        return await startGitTestFlightRelease(path: path, whatToTest: whatToTest)
    }

    @discardableResult
    func startGitTestFlightRelease(path: String, whatToTest: String) async -> Bool {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty else {
            return false
        }
        let lease: ProjectsGitHostLease
        do {
            lease = try captureProjectsGitHostLease()
        } catch {
            gitTestFlightErrorByPath[targetPath] = error.localizedDescription
            return false
        }
        isStartingGitTestFlightRelease = true
        defer {
            if isProjectsGitHostCurrent(lease) {
                isStartingGitTestFlightRelease = false
            }
        }
        do {
            let status = try await lease.client.gitTestFlightRun(
                path: targetPath,
                whatToTest: whatToTest.trimmingCharacters(in: .whitespacesAndNewlines),
                confirmed: true
            )
            guard canApplyProjectsGitResult(lease) else { return false }
            gitTestFlightStatusByPath[targetPath] = status
            gitTestFlightErrorByPath.removeValue(forKey: targetPath)
            return true
        } catch {
            guard canApplyProjectsGitResult(lease) else { return false }
            gitTestFlightErrorByPath[targetPath] = error.localizedDescription
            return false
        }
    }

    func pollSelectedGitTestFlightRelease() async {
        guard let path = selectedGitStatusPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            return
        }
        await pollGitTestFlightRelease(path: path)
    }

    func pollGitTestFlightRelease(path: String) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty else {
            return
        }
        let lease: ProjectsGitHostLease
        do {
            lease = try captureProjectsGitHostLease()
        } catch {
            gitTestFlightErrorByPath[targetPath] = error.localizedDescription
            return
        }
        while !Task.isCancelled {
            guard canApplyProjectsGitResult(lease) else { return }
            await refreshGitTestFlightStatus(path: targetPath, lease: lease)
            guard canApplyProjectsGitResult(lease),
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

    func createSelectedPullRequest(title: String, body: String = "", draft: Bool = true) async {
        guard let path = selectedGitStatusPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            return
        }
        await createPullRequest(path: path, title: title, body: body, draft: draft)
    }

    func createPullRequest(path: String, title: String, body: String = "", draft: Bool = true) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let prTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty, !prTitle.isEmpty else {
            return
        }

        let lease: ProjectsGitHostLease
        do {
            lease = try captureProjectsGitHostLease()
        } catch {
            gitActionErrorByPath[targetPath] = error.localizedDescription
            return
        }
        isCreatingPullRequest = true
        defer {
            if isProjectsGitHostCurrent(lease) {
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
            guard canApplyProjectsGitResult(lease) else { return }
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
            guard canApplyProjectsGitResult(lease) else { return }
            gitActionErrorByPath[targetPath] = error.localizedDescription
        }
    }

    func refreshSelectedPullRequestStatus() async {
        guard let path = selectedGitStatusPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            return
        }
        await refreshPullRequestStatus(path: path)
    }

    func refreshPullRequestStatus(path: String) async {
        let targetPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetPath.isEmpty else {
            return
        }

        let lease: ProjectsGitHostLease
        do {
            lease = try captureProjectsGitHostLease()
        } catch {
            pullRequestStatusErrorByPath[targetPath] = error.localizedDescription
            return
        }
        isRefreshingPullRequestStatus = true
        defer {
            if isProjectsGitHostCurrent(lease) {
                isRefreshingPullRequestStatus = false
            }
        }
        do {
            let response = try await lease.client.gitPullRequestStatus(path: targetPath)
            guard canApplyProjectsGitResult(lease) else { return }
            pullRequestStatusByPath[targetPath] = response
            if let url = response.url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
                pullRequestURLByPath[targetPath] = url
            }
            pullRequestStatusErrorByPath.removeValue(forKey: targetPath)
        } catch {
            guard canApplyProjectsGitResult(lease) else { return }
            pullRequestStatusErrorByPath[targetPath] = error.localizedDescription
        }
    }

    func forgetWorkspace(_ project: AgentProject) {
        let next = recentWorkspaceStore.forget(
            id: project.id,
            profileID: appStore.notificationRoutingProfileID
        )
        setRecentWorkspacesIfChanged(next)
        workspaceGitSummaryByPath.removeValue(forKey: project.path)
        workspaceGitSummaryUpdatedAtByPath.removeValue(forKey: project.path)
        refreshingWorkspaceGitSummaryPaths.remove(project.path)
        removeExpandedProjectID(project.id)
        removeShowingAllSessionProjectID(project.id)
        sessionPageCursorByProjectID.removeValue(forKey: project.id)
        sessionHasMoreByProjectID.removeValue(forKey: project.id)
        sessionProjectsWithAdditionalPages.remove(project.id)
        sessionPageRequestTokenByProjectID.removeValue(forKey: project.id)
        sessionPageLoadingTokenByProjectID.removeValue(forKey: project.id)
        sessionFirstPageLoadingConsistencyByProjectID.removeValue(forKey: project.id)
        sessionFirstPageWaiterCountByProjectID.removeValue(forKey: project.id)
        let retainedWorkspaceCompletions = workspaceSessionFirstPageCompletionByKey.filter {
            $0.key.workspaceID != project.id
        }
        if retainedWorkspaceCompletions != workspaceSessionFirstPageCompletionByKey {
            workspaceSessionFirstPageCompletionByKey = retainedWorkspaceCompletions
        }
        clearSessionReminders(forProjectID: project.id)
        sessions = sessions.filter { $0.projectID != project.id }
        clearWorkspaceUnavailable(project.id)
        if selectedProjectID == project.id {
            _ = commitSelection(
                projectID: nil,
                sessionID: nil,
                reason: .invalidation
            )
            disconnectWebSocket()
        }
        setStatusMessage(L10n.format("ui.value_has_been_removed_from_the_current_device", project.name))
    }

    func toggleSessionPinned(_ session: AgentSession) {
        // 置顶是本机偏好，不能借此静默覆盖服务端归档态；必须等远端取消归档
        // 成功后才能再次置顶，pending 期间也不允许制造本地/远端分叉。
        guard !archivedSessionIDs.contains(session.id),
              !isSessionArchiveMutationPending(session.id) else {
            return
        }
        if pinnedSessionIDs.contains(session.id) {
            pinnedSessionIDs.remove(session.id)
            setStatusMessage(L10n.format("ui.unpinned_value", session.title))
        } else {
            pinnedSessionIDs.insert(session.id)
            setStatusMessage(L10n.format("ui.pinned_value", session.title))
        }
        saveSessionListPreferences()
        rebuildSessionIndexes()
    }

    func toggleSessionArchived(_ session: AgentSession) {
        setSessionArchivedLocally(
            session,
            archived: !archivedSessionIDs.contains(session.id),
            clearProjections: true
        )
    }

    @discardableResult
    func toggleSessionArchivedRemote(_ session: AgentSession) async -> Bool {
        await setSessionArchivedRemote(
            session,
            archived: !archivedSessionIDs.contains(session.id)
        )
    }

    /// 显式 target setter 让 swipe/menu 可以直接表达最终状态，避免调用方先改本地状态后
    /// 又经过 toggle 把同一操作翻转两次。
    @discardableResult
    func setSessionArchivedRemote(_ session: AgentSession, archived shouldArchive: Bool) async -> Bool {
        guard !isProtocolReadOnlySession(session) else {
            setStatusMessage(L10n.text("ui.read_only"))
            return false
        }

        let hostScope = appStore.activeHostScope
        let key = ScopedSessionID(
            profileID: appStore.notificationRoutingProfileID,
            sessionID: session.id
        )
        guard sessionArchiveMutationsByKey[key] == nil else {
            return false
        }

        let before = sessionArchivePreferenceState(for: session.id)
        let target = SessionArchivePreferenceState(
            isPinned: shouldArchive ? false : before.isPinned,
            isArchived: shouldArchive
        )
        guard before != target else {
            return true
        }

        let client: any SessionStoreAPIClient
        do {
            client = try clientFactory()
        } catch {
            setSessionArchiveError(archived: shouldArchive, error: error)
            return false
        }

        sessionArchiveMutationToken += 1
        let mutation = SessionArchiveMutation(
            token: sessionArchiveMutationToken,
            hostScope: hostScope,
            before: before,
            target: target
        )
        sessionArchiveMutationsByKey[key] = mutation
        insertPendingSessionArchiveMutationKey(key)
        // 乐观阶段只改变可见性与排序偏好；本地发送投影要等服务端确认后再释放，
        // 否则失败回滚时会丢失仍需保护的 preview / recency。
        applySessionArchivePreferenceState(target, sessionID: session.id, persist: false)

        defer {
            finishSessionArchiveMutation(key: key, token: mutation.token)
        }

        do {
            try await client.setSessionArchived(id: session.id, archived: shouldArchive)
            guard isCurrentSessionArchiveMutation(mutation, key: key) else { return false }
            guard canPersistSessionArchiveMutation(mutation, key: key) else { return false }
            let didApplyToCurrentHost = canApplySessionArchiveMutation(mutation, key: key)
            if didApplyToCurrentHost {
                // Profile 切走又切回时内存可能已从 committed 偏好重载；远端成功后恢复目标态。
                if sessionArchivePreferenceState(for: session.id) != target {
                    applySessionArchivePreferenceState(target, sessionID: session.id, persist: false)
                }
                if shouldArchive,
                   sessionArchivePreferenceState(for: session.id) == target {
                    listProjectionBySessionID.removeValue(forKey: session.id)
                    recentActivityProjectionBySessionID.removeValue(forKey: session.id)
                }
                setStatusMessage(
                    shouldArchive
                        ? L10n.format("ui.archived_remote_session_value", session.title)
                        : L10n.format("ui.remote_archiving_value_has_been_canceled", session.title)
                )
            }
            // 同步写入指定 Profile 后 defer 才释放 pending；这样任何通用偏好保存都仍会
            // 过滤其他未确认事务，同时旧 Profile 的成功不会污染当前 Profile 内存。
            persistSessionArchivePreferenceState(target, key: key)
            return didApplyToCurrentHost
        } catch {
            guard isCurrentSessionArchiveMutation(mutation, key: key) else { return false }
            // CAS 回滚：只有 pinned / archived 仍等于本事务的乐观目标时才恢复。
            // 若期间发生了更晚的本地置顶等操作，保留用户的新状态，旧失败不得覆盖。
            if appStore.notificationRoutingProfileID == key.profileID,
               sessionArchivePreferenceState(for: session.id) == target {
                applySessionArchivePreferenceState(
                    mutation.before,
                    sessionID: session.id,
                    persist: false
                )
            }
            if appStore.notificationRoutingProfileID == key.profileID {
                setSessionArchiveError(archived: shouldArchive, error: error)
            }
            return false
        }
    }

    func isSessionArchiveMutationPending(_ sessionID: SessionID) -> Bool {
        pendingSessionArchiveMutationKeys.contains(
            ScopedSessionID(
                profileID: appStore.notificationRoutingProfileID,
                sessionID: sessionID
            )
        )
    }

    func discardSessionArchiveMutationState(profileID: String) {
        let discardedKeys = sessionArchiveMutationsByKey.keys.filter { $0.profileID == profileID }
        for key in discardedKeys {
            sessionArchiveMutationsByKey.removeValue(forKey: key)
            removePendingSessionArchiveMutationKey(key)
        }
    }

    private func setSessionArchivedLocally(
        _ session: AgentSession,
        archived: Bool,
        clearProjections: Bool
    ) {
        let before = sessionArchivePreferenceState(for: session.id)
        let target = SessionArchivePreferenceState(
            isPinned: archived ? false : before.isPinned,
            isArchived: archived
        )
        guard before != target else {
            return
        }
        applySessionArchivePreferenceState(target, sessionID: session.id)
        if archived && clearProjections {
            listProjectionBySessionID.removeValue(forKey: session.id)
            recentActivityProjectionBySessionID.removeValue(forKey: session.id)
        }
        setStatusMessage(
            archived
                ? L10n.format("ui.archived_value", session.title)
                : L10n.format("ui.unarchived_value", session.title)
        )
    }

    private func sessionArchivePreferenceState(for sessionID: SessionID) -> SessionArchivePreferenceState {
        SessionArchivePreferenceState(
            isPinned: pinnedSessionIDs.contains(sessionID),
            isArchived: archivedSessionIDs.contains(sessionID)
        )
    }

    private func applySessionArchivePreferenceState(
        _ state: SessionArchivePreferenceState,
        sessionID: SessionID,
        persist: Bool = true
    ) {
        if state.isPinned {
            pinnedSessionIDs.insert(sessionID)
        } else {
            pinnedSessionIDs.remove(sessionID)
        }
        if state.isArchived {
            archivedSessionIDs.insert(sessionID)
        } else {
            archivedSessionIDs.remove(sessionID)
        }
        if persist {
            saveSessionListPreferences()
        }
        rebuildSessionIndexes()
    }

    private func canApplySessionArchiveMutation(
        _ mutation: SessionArchiveMutation,
        key: ScopedSessionID
    ) -> Bool {
        // generation 只隔离连接内事件；归档 HTTP 成功是同一安装身份上的幂等最终态。
        // 同一 Profile+Session 在 pending 期间禁止再次写入，因此 A→B→A 后可安全恢复目标态。
        appStore.activeHostScope.profileID == mutation.hostScope.profileID
            && appStore.activeHostScope.installationID == mutation.hostScope.installationID
            && isCurrentSessionArchiveMutation(mutation, key: key)
    }

    private func canPersistSessionArchiveMutation(
        _ mutation: SessionArchiveMutation,
        key: ScopedSessionID
    ) -> Bool {
        guard isCurrentSessionArchiveMutation(mutation, key: key) else {
            return false
        }
        // legacy/debug 单连接使用 endpoint 哈希作为偏好命名空间，没有 ConnectionProfile 可查；
        // 其 token 仍由 pending 表控制。持久化 Profile 则必须仍存在且绑定原安装身份，
        // 防止删除后复用相同 Profile ID 时被迟到成功重新写入。
        guard mutation.hostScope.profileID == key.profileID else {
            return true
        }
        guard let profile = appStore.connectionProfiles.first(where: { $0.id == key.profileID }) else {
            return false
        }
        guard let profileInstallationID = profile.installationID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !profileInstallationID.isEmpty else {
            return false
        }
        return profileInstallationID == mutation.hostScope.installationID
    }

    private func isCurrentSessionArchiveMutation(
        _ mutation: SessionArchiveMutation,
        key: ScopedSessionID
    ) -> Bool {
        sessionArchiveMutationsByKey[key]?.token == mutation.token
    }

    private func finishSessionArchiveMutation(key: ScopedSessionID, token: UInt64) {
        // 连接切换后同一 Profile 可能已经发起新事务；旧 defer 只能清理自己的 token。
        guard sessionArchiveMutationsByKey[key]?.token == token else {
            return
        }
        sessionArchiveMutationsByKey.removeValue(forKey: key)
        removePendingSessionArchiveMutationKey(key)
    }

    private func persistSessionArchivePreferenceState(
        _ state: SessionArchivePreferenceState,
        key: ScopedSessionID
    ) {
        var preferences = sessionListPreferenceStore.load(profileID: key.profileID)
        if state.isPinned {
            preferences.pinnedSessionIDs.insert(key.sessionID)
        } else {
            preferences.pinnedSessionIDs.remove(key.sessionID)
        }
        if state.isArchived {
            preferences.archivedSessionIDs.insert(key.sessionID)
        } else {
            preferences.archivedSessionIDs.remove(key.sessionID)
        }
        sessionListPreferenceStore.save(preferences, profileID: key.profileID)
    }

    private func setSessionArchiveError(archived: Bool, error: Error) {
        setErrorMessage(
            L10n.format(
                "ui.value_failed_value",
                L10n.text(archived ? "ui.archive" : "ui.unarchive"),
                error.localizedDescription
            )
        )
    }

    func supportsCodexThreadManagement(_ session: AgentSession) -> Bool {
        !isProtocolReadOnlySession(session)
            && !session.isLocalDraft
            && Self.normalizedRuntimeProvider(session.runtimeProvider ?? session.source) == "codex"
    }

    @discardableResult
    func renameSession(_ session: AgentSession, name: String) async -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard supportsCodexThreadManagement(session), !normalized.isEmpty else {
            setStatusMessage(L10n.text("ui.session_name_cannot_be_empty"))
            return false
        }
        guard normalized.utf8.count <= 256 else {
            setStatusMessage(L10n.text("ui.session_name_cannot_exceed_256_bytes"))
            return false
        }
        let lease: ProjectsGitHostLease
        do {
            lease = try captureProjectsGitHostLease()
        } catch {
            setStatusMessage(L10n.format("ui.rename_failed_value", error.localizedDescription))
            return false
        }
        do {
            try await lease.client.setThreadName(threadID: session.id, name: normalized)
            guard canApplyProjectsGitResult(lease) else { return false }
            // 名称由 app-server 持久化；再读一次权威 thread，立即刷新侧栏，不维护第二份本地标题。
            let refreshed = try? await lease.client.session(id: session.id, afterSeq: nil)
            guard canApplyProjectsGitResult(lease) else { return false }
            if let refreshed {
                upsert(refreshed.session)
            }
            setStatusMessage(L10n.format("ui.session_renamed_to_value", normalized))
            return true
        } catch {
            guard canApplyProjectsGitResult(lease) else { return false }
            setStatusMessage(L10n.format("ui.rename_failed_value", error.localizedDescription))
            return false
        }
    }

    @discardableResult
    func compactSessionContext(_ session: AgentSession) async -> Bool {
        guard supportsCodexThreadManagement(session) else {
            setStatusMessage(L10n.text("ui.the_current_running_channel_does_not_support_manual"))
            return false
        }
        guard !session.isRunning else {
            setStatusMessage(L10n.text("ui.please_wait_for_the_current_turn_to_complete"))
            return false
        }
        let lease: ProjectsGitHostLease
        do {
            lease = try captureProjectsGitHostLease()
        } catch {
            setStatusMessage(L10n.format("ui.context_compression_failed_value", error.localizedDescription))
            return false
        }
        do {
            try await lease.client.compactThread(threadID: session.id)
            guard canApplyProjectsGitResult(lease) else { return false }
            setStatusMessage(L10n.format("ui.compression_of_context_for_value_has_started", session.title))
            return true
        } catch {
            guard canApplyProjectsGitResult(lease) else { return false }
            setStatusMessage(L10n.format("ui.context_compression_failed_value", error.localizedDescription))
            return false
        }
    }

    @discardableResult
    func startReview(_ session: AgentSession, target: CodexAppServerReviewTarget) async -> Bool {
        let latestSession = sessionsByID[session.id] ?? session
        guard supportsCodexThreadManagement(latestSession) else {
            setStatusMessage(L10n.text("ui.the_current_running_channel_does_not_support_codex"))
            return false
        }
        guard !latestSession.isRunning else {
            setStatusMessage(L10n.text("ui.please_wait_until_the_current_turn_is_completed"))
            return false
        }

        let normalizedTarget: CodexAppServerReviewTarget
        do {
            normalizedTarget = try target.validatedInlineTarget()
        } catch {
            setStatusMessage(L10n.format("ui.review_target_is_invalid_value", error.localizedDescription))
            return false
        }

        let lease: ProjectsGitHostLease
        do {
            lease = try captureProjectsGitHostLease()
        } catch {
            setStatusMessage(L10n.format("ui.review_startup_failed_value", error.localizedDescription))
            return false
        }
        do {
            _ = try await lease.client.startReview(
                threadID: latestSession.id,
                target: normalizedTarget,
                // 产品入口始终在原会话内执行，不能由调用方切换成 detached。
                delivery: .inline
            )
            guard canApplyProjectsGitResult(lease) else { return false }
            setStatusMessage(L10n.format("ui.review_started_for_value_value", latestSession.title, reviewTargetDescription(normalizedTarget)))
            return true
        } catch {
            guard canApplyProjectsGitResult(lease) else { return false }
            setStatusMessage(L10n.format("ui.review_startup_failed_value", error.localizedDescription))
            return false
        }
    }

    /// 保留旧入口，避免已有调用方在 UI 升级期间产生行为变化。
    @discardableResult
    func reviewUncommittedChanges(_ session: AgentSession) async -> Bool {
        await startReview(session, target: .uncommittedChanges)
    }

    func reviewTargetDescription(_ target: CodexAppServerReviewTarget) -> String {
        switch target {
        case .uncommittedChanges:
            return L10n.text("ui.changes_not_committed")
        case .baseBranch(let branch):
            return L10n.format("ui.changes_from_value", branch)
        case .commit(let sha, _):
            return L10n.format("ui.submit_value", sha)
        case .custom:
            // validatedInlineTarget 已拒绝 custom；保留分支是为了让枚举扩展时编译器继续提示。
            return L10n.text("ui.custom_goal")
        }
    }

    func sessionReminder(for sessionID: SessionID) -> SessionReminder? {
        sessionRemindersByID[sessionID]
    }

    func scheduleSessionReminder(_ session: AgentSession, after interval: TimeInterval, now: Date = Date()) async {
        guard interval > 0 else {
            // 非法或已过的目标时间不能被 max(60, interval) 悄悄改成新的提醒；同时清掉同会话旧状态。
            let removed = sessionRemindersByID.removeValue(forKey: session.id) != nil
            if removed {
                saveSessionReminders()
            }
            sessionReminderScheduler.cancel(
                sessionID: session.id,
                profileID: appStore.notificationRoutingProfileID
            )
            setStatusMessage(L10n.format("ui.the_reminder_time_has_passed_and_the_reminder", session.title))
            return
        }
        let boundedInterval = max(60, interval)
        let reminder = SessionReminder(
            sessionID: session.id,
            title: session.title,
            fireAt: now.addingTimeInterval(boundedInterval),
            createdAt: now
        )
        guard !reminder.isDue(now: now) else {
            sessionRemindersByID.removeValue(forKey: session.id)
            saveSessionReminders()
            sessionReminderScheduler.cancel(
                sessionID: session.id,
                profileID: appStore.notificationRoutingProfileID
            )
            setStatusMessage(L10n.format("ui.the_reminder_time_has_passed_and_the_reminder", session.title))
            return
        }
        sessionRemindersByID[session.id] = reminder
        saveSessionReminders()

        do {
            // 先持久化，再尽力交给系统通知；即使用户未授权通知，侧栏仍能显示提醒状态。
            let route = SessionNotificationRoute.current(
                profileID: appStore.notificationRoutingProfileID,
                projectID: session.projectID,
                sessionID: session.id
            )
            switch try await sessionReminderScheduler.schedule(reminder, route: route) {
            case .scheduled:
                setStatusMessage(L10n.format("ui.reminder_value_has_been_set", session.title))
            case .permissionDenied:
                setStatusMessage(L10n.text("ui.the_in_app_reminder_has_been_saved_the"))
            }
        } catch {
            setStatusMessage(L10n.format("ui.reminder_saved_but_notification_scheduling_failed_value", error.localizedDescription))
        }
    }

    func clearSessionReminder(_ session: AgentSession) {
        sessionRemindersByID.removeValue(forKey: session.id)
        saveSessionReminders()
        sessionReminderScheduler.cancel(
            sessionID: session.id,
            profileID: appStore.notificationRoutingProfileID
        )
        setStatusMessage(L10n.format("ui.reminder_cleared_value", session.title))
    }

    func isWorkspaceUnavailable(_ projectID: String) -> Bool {
        unavailableWorkspaceIDs.contains(projectID)
    }

    // 用户在 Mac 上恢复目录或修好配置后，点“重试”重新校验并加载；resolve 通过即自动清除不可用标记。
    func retryWorkspace(_ project: AgentProject) async {
        clearWorkspaceUnavailable(project.id)
        setErrorMessage(nil)
        await refreshSessions(forProjectID: project.id)
    }

    func toggleProjectExpansion(_ project: AgentProject) async {
        let workspace = ensureWorkspace(for: project)
        if expandedProjectIDs.contains(workspace.id) {
            removeExpandedProjectID(workspace.id)
            removeShowingAllSessionProjectID(workspace.id)
            return
        }

        insertExpandedProjectID(workspace.id)
        if selectedProjectID != workspace.id {
            _ = commitSelection(
                projectID: workspace.id,
                sessionID: nil,
                reason: .invalidation
            )
            setErrorMessage(nil)
            disconnectWebSocket()
        }
#if DEBUG
        guard !isDebugWorkbenchUISeedActive else {
            setStatusMessage(L10n.format("ui.debug_ui_sample_expanded_value", project.name))
            return
        }
#endif
        await refreshSessions(forProjectID: workspace.id)
    }

    func toggleSessionListExpansion(projectID: String) async {
        let currentLimit = sessionVisibleLimit(forProjectID: projectID)
        let loadedCount = sessions(forProjectID: projectID).count
        let isFullyExpanded = currentLimit > Self.sessionPreviewLimit &&
            currentLimit >= loadedCount &&
            !canLoadMoreSessions(projectID: projectID)

        if isFullyExpanded {
            setSessionVisibleLimit(nil, forProjectID: projectID)
            return
        }

        let nextLimit = currentLimit + Self.sessionExpansionStep
        setSessionVisibleLimit(nextLimit, forProjectID: projectID)
        if canLoadMoreSessions(projectID: projectID), nextLimit >= loadedCount {
            await loadMoreSessions(projectID: projectID)
        }
    }

    func loadMoreSessions(projectID: String) async {
        var projectID = projectID
        guard let workspace = ensureWorkspaceForKnownProjectID(projectID) else {
            return
        }
        projectID = workspace.id
        guard let cursor = sessionPageCursorByProjectID[projectID],
              canLoadMoreSessions(projectID: projectID),
              sessionPageLoadingTokenByProjectID[projectID] == nil
        else {
            return
        }
        let lease: ProjectsGitHostLease
        do {
            lease = try captureProjectsGitHostLease()
        } catch {
            setErrorMessage(error.localizedDescription)
            return
        }
        var requestToken: Int?
        do {
            requestToken = beginSessionPageRequest(projectID: projectID)
            defer {
                if isProjectsGitHostCurrent(lease) {
                    finishSessionPageRequest(projectID: projectID, token: requestToken ?? 0)
                }
            }
            let page = try await sessionListPageFillingPresentationWindow(
                client: lease.client,
                workspace: workspace,
                runtimeProvider: "codex",
                cursor: cursor,
                limit: Self.expandedSessionPageLimit,
                consistency: .fastIndexed,
                source: .workspaceLoadMore,
                expectedHostScope: lease.scope,
                // 翻页要补的是新根会话；服务端边界漂移造成的重复 ID 不能占满下一页额度。
                excludingListableSessionIDs: Set(sessions(forProjectID: projectID).map(\.id)),
                // 新的刷新/分页 token 取代旧请求后，旧 cursor 链必须在下一页前停止。
                isRequestCurrent: { [weak self] in
                    guard let self, let requestToken else { return false }
                    return self.isCurrentSessionPageRequest(projectID: projectID, token: requestToken)
                }
            )
            guard canApplyProjectsGitResult(lease),
                  isCurrentSessionPageRequest(projectID: projectID, token: requestToken ?? 0) else {
                return
            }
            mergeFastIndexedSessionPagePreservingAuthoritativeFields(
                sessions(page.sessions, in: workspace),
                workspace: workspace
            )
            updateSessionPageState(projectID: projectID, page: page, requestedCursor: cursor)
            // 显示更多也可能从弱索引补认既有 root 的 child 身份。必须在推进到本轮安全
            // continuation 之后再失效首屏完成态，让视图自动用该游标补齐，而不是退回旧边界。
            invalidateAuthoritativeWorkspaceSessionPresentationCompletionIfNeeded(
                workspace: workspace
            )
            sessionProjectsWithAdditionalPages.insert(projectID)
            clearWorkspaceUnavailable(projectID)
            setErrorMessage(nil)
        } catch {
            guard canApplyProjectsGitResult(lease) else { return }
            if let requestToken,
               !isCurrentSessionPageRequest(projectID: projectID, token: requestToken) {
                return
            }
            setErrorMessage(error.localizedDescription)
        }
    }

    func refreshSelectedProjectSessions(showLoading: Bool = true) async {
        guard let selectedProjectID else {
            return
        }
        await refreshSessions(
            forProjectID: selectedProjectID,
            showLoading: showLoading,
            consistency: showLoading ? .authoritative : .fastIndexed
        )
    }

    /// 为单一全局侧栏加载跨工作区轻量索引。只取 thread/list 首屏，不读取任何消息历史。
    func refreshSessionLibraryIndex(authoritative: Bool = false) async {
        let hostScope = appStore.activeHostScope
        while !Task.isCancelled {
            if let existing = sessionLibraryIndexRefreshJob {
                guard existing.hostScope == hostScope else {
                    existing.task.cancel()
                    retireSessionLibraryIndexRefreshJob(id: existing.id)
                    continue
                }

                await existing.task.value
                retireSessionLibraryIndexRefreshJob(id: existing.id)
                guard appStore.activeHostScope == hostScope, !Task.isCancelled else { return }
                if authoritative, !existing.authoritative {
                    // 手动权威刷新可以等待正在执行的弱刷新，但不能被它冒充完成。
                    continue
                }
                return
            }

            let jobID = UUID()
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.performSessionLibraryIndexRefresh(
                    authoritative: authoritative,
                    hostScope: hostScope
                )
            }
            sessionLibraryIndexRefreshJob = SessionLibraryIndexRefreshJob(
                id: jobID,
                hostScope: hostScope,
                authoritative: authoritative,
                task: task
            )
            await task.value
            retireSessionLibraryIndexRefreshJob(id: jobID)
            return
        }
    }

    private func retireSessionLibraryIndexRefreshJob(id: UUID) {
        guard sessionLibraryIndexRefreshJob?.id == id else { return }
        sessionLibraryIndexRefreshJob = nil
    }

    private func performSessionLibraryIndexRefresh(
        authoritative: Bool,
        hostScope: HostScope
    ) async {
#if DEBUG
        guard !isDebugWorkbenchUISeedActive else { return }
#endif
        guard appStore.activeHostScope == hostScope else { return }
        let generation = appStore.connectionGeneration
        defer {
            if appStore.activeHostScope == hostScope {
                lastSessionLibraryIndexRefreshAt = sessionListNow()
            }
        }
        // 全局“最近历史”以 8 条为基础，并有界补入派生只读会话；“进行中”不能沿用数量限制。
        // 每个工作区读取标准 20 条轻量索引，不加载消息正文，在可见性和弱网成本间取 MVP 平衡。
        let workspaces = recentWorkspaces.filter { workspace in
            if authoritative {
                return true
            }
            // 当前工作区已经由 refreshAll/轮询维护完整首屏时，会话库直接复用本地投影。
            // 再发一次相同 thread/list 只会重复占用 gateway 预算。
            return !(workspace.id == selectedProjectID && !sessions(forProjectID: workspace.id).isEmpty)
        }
        let consistency: SessionListConsistency = authoritative ? .authoritative : .fastIndexed
        guard let client = try? clientFactory() else {
            return
        }

        // 先用最多 4 页、每页 50 条的有界全局发现补齐 Codex 外部 Worktree。
        // agentd 返回的每一项都已经过项目、browse_root 与 git common-dir 裁剪；
        // iOS 只消费 opaque cursor，不接触上游全局 cursor。
        if !controlledGlobalDiscoveryUnavailable {
            let controlledIDsBeforeTraversal = controlledGlobalSessionIDs
            var cursor: String?
            var discoveredSessionIDs: Set<SessionID> = []
            var reachedTraversalEnd = false
            for pageIndex in 0..<4 {
                guard appStore.activeHostScope == hostScope, !Task.isCancelled else { return }
                let hostRequestStartedAt = sessionListNow()
                do {
                    let page = try await client.controlledGlobalSessionsPage(cursor: cursor, limit: 50)
                    guard appStore.connectionGeneration == generation else { return }
                    recordCarStatusHostObservation(at: sessionListNow())
                    let pageSessionIDs = Set(page.sessions.map(\.id))
                    discoveredSessionIDs.formUnion(pageSessionIDs)
                    // 先发布授权 ID 再合并 Session；这样首次发现的外部 Worktree 在同一轮
                    // sessions 更新里即可进入根侧栏补充集，不依赖后续精确 cwd 刷新。
                    let expandedControlledIDs = controlledGlobalSessionIDs.union(pageSessionIDs)
                    if expandedControlledIDs != controlledGlobalSessionIDs {
                        controlledGlobalSessionIDs = expandedControlledIDs
                    }
                    // 全局发现只携带根项目归属；进入 canonical sessions 前先沿用 Store
                    // 已知的 workspace identity（已有同 ID 会话或 dir 命中 recent workspace）。
                    // 否则同一 session.id 的全局响应会把稳定的 workspace projectID 覆盖回
                    // root projectID，导致侧栏分组和会话头像命名空间在两种身份之间来回跳变。
                    // 未命中的外部 worktree 仍返回原始 session，保留既有受控发现行为。
                    mergeSessionPage(page.sessions.map(alignSessionToKnownWorkspace))
                    guard page.hasMore,
                          let nextCursor = page.nextCursor,
                          nextCursor != cursor else {
                        reachedTraversalEnd = !page.hasMore
                        break
                    }
                    cursor = nextCursor
                } catch {
                    guard appStore.activeHostScope == hostScope,
                          appStore.connectionGeneration == generation,
                          !Task.isCancelled else {
                        // Host 已切换或任务已取消：旧 Host 的迟到错误不得污染新 Host 证据。
                        return
                    }
                    if pageIndex == 0, isControlledGlobalDiscoveryUnavailable(error) {
                        controlledGlobalDiscoveryUnavailable = true
                    }
                    if !isCancellationError(error) {
                        if Self.carStatusHostDidRespond(to: error) {
                            recordCarStatusHostObservation(at: sessionListNow())
                        } else {
                            invalidateCarStatusHostObservation(ifNotNewerThan: hostRequestStartedAt)
                        }
                    }
                    break
                }
            }
            guard appStore.activeHostScope == hostScope,
                  appStore.connectionGeneration == generation,
                  !Task.isCancelled else { return }
            if reachedTraversalEnd {
                // 完整遍历是删除旧授权 ID 的唯一证据；分页上限、重复 cursor 或错误时
                // 只合并本次已见项，避免把尚未扫到的外部 Worktree 从列表误删。
                let revokedSessionIDs = controlledIDsBeforeTraversal.subtracting(discoveredSessionIDs)
                if !revokedSessionIDs.isEmpty {
                    let retainedSessions = sessions.filter { !revokedSessionIDs.contains($0.id) }
                    if retainedSessions != sessions {
                        // 授权撤销与列表删除必须在同一轮完成。不能等待精确 cwd 刷新：
                        // Host 可能没有工作区，外部 Worktree 也可能已经被删除。
                        sessions = retainedSessions
                    }
                    // 远端搜索是独立于 canonical sessions 的增强缓存。若不同时清理，
                    // 激活搜索后会把已撤权的外部 Worktree Thread 再投影回完整列表。
                    let retainedRemoteSearchResults = remoteSessionSearchResults.filter {
                        !revokedSessionIDs.contains($0.id)
                    }
                    if retainedRemoteSearchResults != remoteSessionSearchResults {
                        remoteSessionSearchResults = retainedRemoteSearchResults
                    }
                    for sessionID in revokedSessionIDs {
                        remoteSessionSearchSnippetByID.removeValue(forKey: sessionID)
                    }
                }
                if controlledGlobalSessionIDs != discoveredSessionIDs {
                    controlledGlobalSessionIDs = discoveredSessionIDs
                }
            } else {
                let expandedControlledIDs = controlledGlobalSessionIDs.union(discoveredSessionIDs)
                if expandedControlledIDs != controlledGlobalSessionIDs {
                    controlledGlobalSessionIDs = expandedControlledIDs
                }
            }
        }

        guard !workspaces.isEmpty else { return }
        // 全局会话库属于后台发现流量，按工作区串行读取。高负载时宁可逐步补齐侧栏，
        // 也不让多个 thread/list 与前台 resume/turn 请求同时挤压 app-server。
        for workspace in workspaces {
            guard appStore.activeHostScope == hostScope, !Task.isCancelled else { return }
            let result = await sessionLibraryPage(
                workspace: workspace,
                consistency: consistency,
                client: client,
                hostScope: hostScope
            )
            guard appStore.activeHostScope == hostScope, !Task.isCancelled else { return }
            mergeSessionLibraryPages(
                [result],
                generation: generation,
                consistency: consistency
            )
        }
    }

    func isControlledGlobalDiscoveryUnavailable(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("thread/list")
            && (message.contains("cwd")
                || message.contains("method")
                || message.contains("unsupported")
                || message.contains("not supported"))
    }

    func applyNetworkReachabilityStatus(_ update: NetworkPathStatusUpdate) {
        // MainActor 上只接收最新观察序号。即使旧 Task 晚到，也不能把较新的在线状态覆盖成离线。
        guard update.sequence > lastAppliedNetworkPathSequence else {
            return
        }
        lastAppliedNetworkPathSequence = update.sequence
        let status = update.status
        guard status != networkReachabilityStatus else {
            return
        }
        let previousStatus = networkReachabilityStatus
        networkReachabilityStatus = status
        networkPathGeneration += 1
        let generation = networkPathGeneration
        networkRecoveryTask?.cancel()
        networkRecoveryTask = nil

        if status == .unsatisfied {
            // 网络已明确不可用时立即结束搜索 loading，并用 generation 阻止 transport 的迟到响应落地。
            cancelRemoteSessionSearchRequestsPreservingResults()
            cancelWebSocketReconnect(resetAttempts: false)
            // 访问码失效是更高优先级的确定性终态，离线提示不能覆盖重新配对指引。
            guard connectionTermination == nil, !appStore.requiresRePairing else {
                return
            }
            stopAllQueuedSessionMonitoring()
            suspendWebSocketForNetworkLoss()
            setStatusMessage(L10n.text("ui.the_network_is_unavailable_and_will_automatically_reconnect_682354fa"))
            return
        }

        let shouldRecover = previousStatus == .unsatisfied
            || (previousStatus == .unknown
                && (networkSuspendedSessionID != nil || errorMessage != nil))
        guard status == .satisfied,
              shouldRecover,
              !isAppInBackground,
              connectionTermination == nil,
              !appStore.requiresRePairing else {
            return
        }
        // unknown 是 NWPathMonitor 首次回调前的正常状态；只有已经存在传输错误或挂起会话时
        // 才复用现有单次恢复任务，避免健康冷启动额外刷新，也不引入常驻 timer。
        setStatusMessage(L10n.text("ui.the_network_has_been_restored_and_is_reconnecting"))
        let hostScope = appStore.activeHostScope
        networkRecoveryTask = Task { [weak self] in
            await self?.recoverAfterNetworkBecameAvailable(
                pathGeneration: generation,
                hostScope: hostScope
            )
        }
    }

    func suspendWebSocketForNetworkLoss(sessionID: SessionID? = nil) {
        let reconnectSessionID = sessionID
            ?? connectedSessionID
            ?? (webSocketReconnectTask == nil ? nil : selectedSessionID)
            ?? appLifecycleSuspendedSessionID
        if let reconnectSessionID, sessionsByID[reconnectSessionID] != nil {
            networkSuspendedSessionID = reconnectSessionID
            appLifecycleSuspendedSessionID = nil
        }
        cancelWebSocketReconnect(resetAttempts: false)
        webSocketConnectionGeneration += 1
        let socket = webSocket
        webSocket = nil
        connectedSessionID = nil
        connectedHostScope = nil
        connectedCredentialFingerprint = nil
        socket?.disconnect()
        if let reconnectSessionID {
            markDispatchingQueuedTurnsNeedsConfirmation(
                sessionID: reconnectSessionID,
                message: L10n.text("ui.the_network_is_interrupted_and_the_sending_result")
            )
        }
        // 离线只是暂停传输：不清本地消息、running turn 排队、审批或补充信息状态。
        setWebSocketStatus(.disconnected)
    }

    func recoverAfterNetworkBecameAvailable(
        pathGeneration: Int,
        hostScope: HostScope
    ) async {
        guard pathGeneration == networkPathGeneration,
              hostScope == appStore.activeHostScope,
              networkReachabilityStatus == .satisfied,
              !isAppInBackground,
              connectionTermination == nil,
              !appStore.requiresRePairing else {
            return
        }

        let reconnectSessionID = networkSuspendedSessionID
        networkSuspendedSessionID = nil
        let recoveryGeneration = beginRecoveryHistoryGeneration()
        if let reconnectSessionID,
           selectedSessionID == reconnectSessionID,
           let session = sessionsByID[reconnectSessionID] {
            let didReconcileFullHistory = await reconcileHistoryForRecovery(
                sessionID: reconnectSessionID,
                generation: recoveryGeneration
            )
            guard pathGeneration == networkPathGeneration,
                  hostScope == appStore.activeHostScope,
                  networkReachabilityStatus == .satisfied,
                  !isAppInBackground else {
                return
            }
            // 恢复事件按 path generation 去重。历史成功后只补状态；失败时完整回放内容兜底。
            connectWebSocket(
                sessionsByID[reconnectSessionID] ?? session,
                isReconnectAttempt: true,
                replayBufferedEvents: !didReconcileFullHistory,
                allowNonRunning: true
            )
        }

        await reconcilePersistedQueuedTurns()
        guard pathGeneration == networkPathGeneration,
              hostScope == appStore.activeHostScope,
              networkReachabilityStatus == .satisfied,
              !isAppInBackground else {
            return
        }
        ensureAllQueuedSessionMonitoring()

        guard pathGeneration == networkPathGeneration,
              hostScope == appStore.activeHostScope,
              networkReachabilityStatus == .satisfied,
              connectionTermination == nil,
              !appStore.requiresRePairing,
              selectedProjectID != nil else {
            return
        }
        // 可见轮询在离线期间不会发 REST；恢复后补一次轻量刷新，不等待原轮询 sleep 到期。
        await refreshSelectedProjectSessions(showLoading: false)
    }

    func pollSelectedProjectSessionsWhileVisible() async {
        while !Task.isCancelled {
            if connectionTermination != nil || appStore.requiresRePairing {
                return
            }
            await sessionListSleep(sessionListPollingDelayNanoseconds())
            if Task.isCancelled {
                return
            }
#if DEBUG
            guard !isDebugWorkbenchUISeedActive else {
                continue
            }
#endif
            guard !isNetworkUnavailable,
                  appStore.isConfigured,
                  selectedProjectID != nil else {
                continue
            }
            await refreshSelectedProjectSessions(showLoading: false)
            await refreshSessionLibraryIndexIfStale()
        }
    }

    func refreshSessionLibraryIndexIfStale() async {
        if let lastSessionLibraryIndexRefreshAt,
           sessionListNow().timeIntervalSince(lastSessionLibraryIndexRefreshAt) < sessionLibraryIndexPollingInterval {
            return
        }
        await refreshSessionLibraryIndex()
    }

    func sessionListPollingDelayNanoseconds() -> UInt64 {
        webSocketStatus == .connected
            ? sessionListConnectedPollingDelayNanoseconds
            : sessionListDisconnectedPollingDelayNanoseconds
    }

}
