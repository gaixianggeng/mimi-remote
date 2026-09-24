import Foundation

/// SessionStore ←→ `HarnessSessionDirectory` 的接线。
///
/// 协调器负责"什么时候发、发什么、结果还算不算数"；这里只做三件它不该管的事：
/// **取数**（走既有 `SessionStoreAPIClient`，不新开一条网络路径）、
/// **落地**（复用既有 `mergeSessionLibraryPages`，不新写一套归并）、
/// **闸门**（构建未装配原生客户端时整段不参与；不会回退旧 app-server 路径）。
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

    /// 当前宿主的原生 Harness 目录是否可读。
    ///
    /// 正式 App 始终装配客户端；agentd channel 表示用户启用且协议受支持，
    /// `availableRuntimeProviders` 是配置判定与真实 Harness 健康探测的合并结果。
    /// 目录只在该结果成立时读取；路由归属仍始终是 native，离线不会回退旧协议。
    var isNativeHarnessDirectoryEnabled: Bool {
        availableRuntimeProviders.contains(Self.nativeHarnessRuntimeProvider)
    }

    // MARK: - 宿主级 $events

    /// 接上宿主级交互事件。
    ///
    /// `$events` 是宿主级通道（契约 D5）：别的会话、子 Agent、Harness Web 发出的审批与
    /// 追问都从这一条流下来，**可能在用户从未打开对应会话时到达**。因此它由宿主独占，
    /// 不像会话页面那样随页面开关——那样既收不到跨会话审批，退订还会关掉整条共享连接
    /// （中继规定一条移动连接只绑定一个 `$events` 生命周期）。
    ///
    /// 幂等：宿主激活、切回前台、重连都可以安全重复调用。
    func installNativeHarnessHostEvents() {
        guard isNativeHarnessDirectoryEnabled else { return }
        guard let client = appStore.nativeHarnessClientForActiveHost() else { return }
        // 旧客户端异步退役前仍可能送达尾包；归属固定为安装时的宿主与代次。
        let hostScope = appStore.activeHostScope
        client.setHostInteractionSinks(
            events: { [weak self] event in
                guard let self, self.appStore.activeHostScope == hostScope else { return }
                self.deliverNativeHostEvent(event, hostScope: hostScope)
            },
            changed: { [weak self] in
                guard let self, self.appStore.activeHostScope == hostScope else { return }
                self.objectWillChange.send()
            },
            rejected: { [weak self] sessionID, eventID, outcome, message in
                guard let self, self.appStore.activeHostScope == hostScope else { return }
                self.handleNativeInteractionRejected(
                    sessionID: sessionID,
                    eventID: eventID,
                    outcome: outcome,
                    message: message
                )
            },
            failed: { [weak self] message in
                guard let self, self.appStore.activeHostScope == hostScope else { return }
                // 通道错误没有可信会话归属，只显示宿主错误，不解锁任何会话的待办。
                self.setErrorMessage(message)
            }
        )
        // 当前方法已经在 MainActor 上。直接启动使健康探测完成与宿主观察建立保持有序，
        // 不把正式接入交给一个可能晚于首轮目录刷新才执行的游离任务。
        client.startHostEvents()
    }

    /// 宿主退役时停止观察。**页面切换不调用它。**
    func stopNativeHarnessHostEvents() {
        guard let client = appStore.nativeHarnessClientForActiveHost() else { return }
        Task { @MainActor in
            await client.stopHostEvents()
        }
    }

    /// 宿主级交互被拒绝时的统一处理。
    ///
    /// ## 为什么必须分结论处理
    ///
    /// `rejected` 是"上游明确没执行"：要清掉 Store 的**提交中标记**，否则用户
    /// 第二次点击会被自己的 pending 挡住（按钮一直停在"正在发送"）。
    /// 底层 `HarnessInteractionStore` 放回待应答**不等于**上层按钮恢复可操作——
    /// 那是两份状态，必须一起更新。
    ///
    /// `unknown` 是"可能已生效"：**不得**清锁。清了等于允许重发，
    /// 而重发可能让一次已经执行过的审批再执行一遍。
    /// 宿主回执的状态交接入口。非 private：这条路径的状态正确性必须能被
    /// 真实 Store 测试断言（"按钮是否恢复可操作"），而不是只测底层 store。
    func handleNativeInteractionRejected(
        sessionID: String,
        eventID: String,
        outcome: String,
        message: String
    ) {
        if outcome == HarnessRespondOutcome.rejected {
            // 走与页面路径同一套清理：审批清 pending 标记，追问恢复卡片。
            clearPendingApprovalDecision(sessionID: sessionID, approvalID: eventID)
            if let request = clearPendingUserInputResponse(sessionID: sessionID, requestID: eventID) {
                restoreUserInputRequestAfterFailure(request, sessionID: sessionID)
            }
        }
        setErrorMessage(message)
        objectWillChange.send()
    }

    /// 把一条宿主级交互事件送进既有事件通道。
    ///
    /// 走 `applyRuntimeEvent` 而不是另建一条 UI 路径：会话归属由事件自己的 metadata 决定
    /// （见 `HarnessInteractionProjection`），因此**无需**当前打开的是哪个会话，
    /// 未打开的会话也能正确落到它自己的待办与时间线上。
    private func deliverNativeHostEvent(_ event: AgentEvent, hostScope: HostScope) {
        guard let sessionID = metadata(for: event)?.sessionID else { return }
        let lease = HostSessionLease(hostScope: hostScope, sessionID: sessionID)
        Task { @MainActor in
            await self.applyRuntimeEvent(event, lease: lease)
        }
    }

    /// 为一个工作区发起原生目录刷新。
    func refreshNativeHarnessDirectory(
        workspace: AgentWorkspace,
        hostScope: HostScope
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
        isNativeHarnessDirectoryListVisible = isListVisible
        isNativeHarnessDirectoryForeground = isForeground
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
                // Harness list 没有分页；成功的空页也是完整目录快照，必须撤销旧成员。
                consistency: .authoritative,
                runtimeProvider: Self.nativeHarnessRuntimeProvider,
                restartsFromFirst: false
            )
        }

        let directory = HarnessSessionDirectory(
            clock: HarnessDispatchDirectoryClock(),
            fetch: fetch,
            deliver: deliver
        )
        directory.setListVisible(
            isNativeHarnessDirectoryListVisible,
            isForeground: isNativeHarnessDirectoryForeground
        )
        nativeHarnessDirectory = directory
        return directory
    }

    /// 原生通道承接的 runtime。与 `AppServerRuntimeBundle` 同源，不在这里另立字面量。
    static var nativeHarnessRuntimeProvider: String {
        AppServerRuntimeBundle.nativeRuntimeProvider
    }
}
