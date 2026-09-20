import Foundation

/// SessionStore ←→ `HarnessSessionDirectory` 的接线。
///
/// 协调器负责"什么时候发、发什么、结果还算不算数"；这里只做三件它不该管的事：
/// **取数**（走既有 `SessionStoreAPIClient`，不新开一条网络路径）、
/// **落地**（复用既有 `mergeSessionLibraryPages`，不新写一套归并）、
/// **闸门**（未启用时整段不参与，deepseek 继续走既有 app-server 路径）。
///
/// 两条承重约束：
///
/// 1. 协调器**不**自己维护会话集合。它是"取数 + 时序"的壳：目录事实由 `session/list`
///    对账、由既有归并写进 `sessions`。再建一份会话索引会让两套列表各自漂移——
///    契约 D1 明确禁止再建一个持久 Harness 数据库。
/// 2. 闭包**不捕获**调用当时的 workspace / generation，而是每次按 `query` 现查。
///    协调器实例被复用，若闭包捕获首轮的值，第二次刷新就会把结果交付到上一个
///    工作区、或用一个早已过期的代次去合并——那正是"旧回调污染新上下文"。
extension SessionStore {

    /// deepseek 是否由原生通道承接。
    ///
    /// 判据只看 `nativeHarnessRollout`：它关闭时 `AppServerRuntimeBundle.harness` 恒为
    /// `nil`，因此不存在"原生已承接但开关说没开"的中间态。不拿"通道探测成功"当开关——
    /// 探测失败是运行时事实，不该改变"用哪条协议"这个构建期决策。
    var isNativeHarnessDirectoryEnabled: Bool {
        nativeHarnessRollout.isEnabled
    }

    /// 为一个工作区发起原生目录刷新。
    func refreshNativeHarnessDirectory(
        workspace: AgentWorkspace,
        consistency: SessionListConsistency,
        restartFromFirst: Bool,
        hostScope: HostScope,
        generation: Int
    ) async {
        guard isNativeHarnessDirectoryEnabled else { return }
        guard isCurrentWorkspaceIdentity(workspace, hostScope: hostScope) else { return }

        let directory = nativeHarnessDirectoryInstance()
        directory.activate(query: HarnessSessionDirectoryQuery(
            hostScope: hostScope,
            runtimeProvider: Self.nativeHarnessRuntimeProvider,
            scope: .workspace(id: workspace.id, path: standardizedSessionListPath(workspace.path))
        ))
        // 触发即返回，等一个确定的完成点：调用方（含测试）才能断言"刷新真的拿到了结果"，
        // 而不是靠 sleep 赌时序。
        await directory.waitForInFlightRequest()
    }

    /// 停下当前原生目录刷新：离开列表 / 切 host / 断连。
    ///
    /// 停表而不只是取消任务：只取消会让兜底定时器继续按 5 秒打请求，退化成后台轮询。
    func stopNativeHarnessDirectory() {
        nativeHarnessDirectory?.deactivate()
    }

    /// 列表可见性与前后台变化。两个都为真才允许 5 秒兜底跑。
    func updateNativeHarnessDirectoryVisibility(isListVisible: Bool, isForeground: Bool) {
        nativeHarnessDirectory?.setListVisible(isListVisible, isForeground: isForeground)
    }

    /// 控制流 / `$events` 提示目录可能变了。只作触发，不拿控制流 baseline 当目录事实来源。
    func notifyNativeHarnessDirectoryMayHaveChanged() {
        nativeHarnessDirectory?.notifyDirectoryMayHaveChanged()
    }

    /// 懒建协调器。闭包只捕获 `self`（弱引用），每个值都在调用时现取。
    private func nativeHarnessDirectoryInstance() -> HarnessSessionDirectory {
        if let existing = nativeHarnessDirectory { return existing }

        let fetch: HarnessSessionDirectory.Fetch = { [weak self] query in
            guard let self else { throw CancellationError() }
            // 每次现查：工作区可能已被移除，或 host 已切走。
            guard case .workspace(let workspaceID, _) = query.scope,
                  let workspace = self.workspacesByID[workspaceID],
                  self.isCurrentWorkspaceIdentity(workspace, hostScope: query.hostScope) else {
                throw CancellationError()
            }
            // 只读查询，走既有 client 与既有 `cwd` 授权提示（不进上游 args）。
            let client = try self.clientFactory()
            return try await client.sessionsPage(
                workspace: workspace,
                runtimeProvider: query.runtimeProvider,
                cursor: nil,
                limit: nil,
                consistency: .fastIndexed
            )
        }

        let deliver: HarnessSessionDirectory.Deliver = { [weak self] query, page in
            guard let self else { return }
            guard case .workspace(let workspaceID, _) = query.scope,
                  let workspace = self.workspacesByID[workspaceID],
                  self.isCurrentWorkspaceIdentity(workspace, hostScope: query.hostScope) else { return }
            // 连接代次在交付时现取：协调器的 generation 管"查询身份有没有变"，
            // 连接代次管"host 有没有换"。两者不是同一件事，不能互相替代。
            self.mergeSessionLibraryPages(
                [(workspace: workspace, page: page, requestedCursor: nil, requestLineage: nil)],
                generation: self.appStore.connectionGeneration,
                runtimeProvider: Self.nativeHarnessRuntimeProvider,
                restartsFromFirst: false
            )
        }

        let directory = HarnessSessionDirectory(
            clock: HarnessDispatchDirectoryClock(),
            fetch: fetch,
            deliver: deliver
        )
        nativeHarnessDirectory = directory
        return directory
    }

    /// 原生通道承接的 runtime。与 `AppServerRuntimeBundle` 同源，不在这里另立字面量。
    static var nativeHarnessRuntimeProvider: String {
        AppServerRuntimeBundle.nativeRuntimeProvider
    }
}
