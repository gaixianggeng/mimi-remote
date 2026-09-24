import Foundation

// MARK: - 查询身份

/// 一次目录查询的身份（D2：hostScope + runtime + workspace/cwd + 查询条件 + refresh generation）。
///
/// 前三项在这里；generation 由 `HarnessSessionDirectory` 单独持有——它每变一次都必须让
/// 旧的在途请求作废，所以不能和"查什么"混成同一个值。
struct HarnessSessionDirectoryQuery: Hashable {
    enum Scope: Hashable {
        /// 受控全局发现：**不带** cwd，agentd 按既有 canonical scope 返回全部已授权会话。
        case global
        /// 工作区目录：带 cwd，由 agentd 用 canonical 逻辑裁剪。
        ///
        /// 工作区成员**只能**由这条查询确认。全局发现拿到的 ID 不得直接当成某工作区成员——
        /// 那正是"全局会话 ID 被当成工作区成员"这条错误的发生方式。
        case workspace(id: String, path: String)
    }

    let hostScope: HostScope
    let runtimeProvider: String
    let scope: Scope

    /// 中继 URL 的授权提示。全局发现传 nil，工作区查询传工作区路径。
    /// 它**不进**上游 Harness 的 args。
    var cwd: String? {
        switch scope {
        case .global:
            return nil
        case .workspace(_, let path):
            return path
        }
    }

    var workspaceID: String? {
        switch scope {
        case .global:
            return nil
        case .workspace(let id, _):
            return id
        }
    }
}

/// 目录状态。失败**不表示空列表**——这是两个必须分开的事实。
enum HarnessSessionDirectoryState: Equatable {
    case idle
    case loading
    /// 最近一次请求成功。
    case loaded
    /// 最近一次请求失败。上一次的会话仍然保留，UI 显示旧页 + 失败原因。
    case failed(String)

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

// MARK: - 解码：原生 wire → 共用展示模型

/// 把原生 list / modelCatalog / search 的结果解成既有 UI 数据。
///
/// 三条纪律：
/// - 形状不符**显式失败**，不返回空列表冒充"没有会话 / 没有模型"；
/// - 缺身份的条目整页失败，不静默丢一条——目录是授权事实来源，少一条和"已撤权"长得一样；
/// - 协议常量取自 `contracts/harness-native` 冻结夹具，不按字段名猜语义。
enum HarnessSessionDirectoryDecoding {

    /// `session/list` 结果：`{items: SessionSummary[]}`。
    ///
    /// 上游**没有服务端分页**（`list()` 不消费 cursor，一次读全部按 `updatedAt` 倒序）。
    /// 所以首屏就是全量，`nextCursor` 恒为 nil，不做"假装有服务端分页"的事；
    /// 展示分页由 UI 在该快照上做。
    static func sessionsPage(
        from value: HarnessJSONValue,
        runtimeProvider: String,
        workspace: AgentWorkspace?
    ) throws -> SessionsPage {
        guard let items = value["items"]?.arrayValue else {
            throw HarnessTransportError.malformedResponse("session/list result is missing items")
        }
        var sessions: [AgentSession] = []
        var seen: Set<SessionID> = []
        for item in items {
            let session = try session(from: item, runtimeProvider: runtimeProvider, workspace: workspace)
            // 同 ID 重复出现（夹具里就有）只保留第一条：上游按 updatedAt 倒序，首条最新。
            if seen.insert(session.id).inserted {
                sessions.append(session)
            }
        }
        return SessionsPage(sessions: sessions, nextCursor: nil, hasMore: false)
    }

    /// `session/modelCatalog` 结果：`{default, routableProviders, groups, failures}`。
    ///
    /// `groups[].models[].reasoning.efforts[]` 是**真实**推理档位来源：必须原样进
    /// `supportedReasoningEfforts`，不能按模型名推断，也不能拿 Codex 的固定档位表顶上。
    static func modelOptions(
        from value: HarnessJSONValue,
        runtimeProvider: String
    ) throws -> [CodexAppServerModelOption] {
        // 缺 groups 就不是模型目录。返回空数组会让上层显示"Harness 没有可用模型"，
        // 把一次形状错误伪装成一个业务结论。
        guard let groups = value["groups"]?.arrayValue else {
            throw HarnessTransportError.malformedResponse("session/modelCatalog result is missing groups")
        }
        let defaultSelection = value["default"]
        let defaultProvider = defaultSelection?["provider"]?.stringValue
        let defaultModel = defaultSelection?["model"]?.stringValue
        let defaultEffort = defaultSelection?["reasoningEffort"]?.stringValue

        var options: [CodexAppServerModelOption] = []
        var seen: Set<String> = []
        for group in groups {
            guard let provider = group["id"]?.stringValue?.trimmedNonEmpty else {
                throw HarnessTransportError.malformedResponse("session/modelCatalog group is missing id")
            }
            guard let models = group["models"]?.arrayValue else {
                throw HarnessTransportError.malformedResponse("session/modelCatalog group is missing models")
            }
            for model in models {
                guard let modelID = model["id"]?.stringValue?.trimmedNonEmpty else {
                    throw HarnessTransportError.malformedResponse("session/modelCatalog model is missing id")
                }
                let reasoning = model["reasoning"]
                let efforts = (reasoning?["efforts"]?.arrayValue ?? []).compactMap {
                    $0["id"]?.stringValue?.trimmedNonEmpty
                }
                let isDefault = defaultProvider == provider && defaultModel == modelID
                let option = CodexAppServerModelOption(
                    id: modelID,
                    title: model["name"]?.stringValue,
                    provider: provider,
                    runtimeProvider: runtimeProvider,
                    description: model["description"]?.stringValue,
                    isDefault: isDefault,
                    supportedReasoningEfforts: efforts,
                    // 模型自己的默认档位优先；只有它就是目录默认项时才回退到 default.reasoningEffort。
                    defaultReasoningEffort: reasoning?["defaultEffort"]?.stringValue
                        ?? (isDefault ? defaultEffort : nil)
                )
                if seen.insert(option.id).inserted {
                    options.append(option)
                }
            }
        }
        return options
    }

    /// `session/search` 结果：`{items: [{sessionId, snippet}], hasMore}`。
    ///
    /// 冻结形状里**只有 ID 与片段**，没有标题和路径。这里就只给 ID 建条目：
    /// 标题与工作区归属由 canonical 目录对账补齐（`sessionsIncludingRemoteSearch`
    /// 对同 ID 保留基础会话的权威状态），不在这层凭空编造。
    static func searchPage(
        from value: HarnessJSONValue,
        runtimeProvider: String,
        workspace: AgentWorkspace?
    ) throws -> ThreadSearchPage {
        guard let items = value["items"]?.arrayValue else {
            throw HarnessTransportError.malformedResponse("session/search result is missing items")
        }
        var results: [ThreadSearchResult] = []
        var seen: Set<SessionID> = []
        for item in items {
            guard let sessionID = item["sessionId"]?.stringValue?.trimmedNonEmpty else {
                throw HarnessTransportError.malformedResponse("session/search item is missing sessionId")
            }
            guard seen.insert(sessionID).inserted else { continue }
            results.append(ThreadSearchResult(
                session: makeSession(
                    sessionID: sessionID,
                    cwd: nil,
                    title: nil,
                    running: false,
                    updatedAt: nil,
                    runtimeProvider: runtimeProvider,
                    workspace: workspace
                ),
                snippet: item["snippet"]?.stringValue ?? ""
            ))
        }
        return ThreadSearchPage(results: results)
    }

    // MARK: 单项

    private static func session(
        from item: HarnessJSONValue,
        runtimeProvider: String,
        workspace: AgentWorkspace?
    ) throws -> AgentSession {
        guard let sessionID = item["sessionId"]?.stringValue?.trimmedNonEmpty else {
            throw HarnessTransportError.malformedResponse("session/list item is missing sessionId")
        }
        let values = item["projections"]?["values"]
        // 标题不在顶层，在 projections.values.title（夹具 itemShapeNote 明确记录）。
        let title = values?["title"]?.stringValue
        let parentSessionID = item["parentSessionId"]?.stringValue?.trimmedNonEmpty
        let isSubagent = parentSessionID != nil || item["origin"]?.stringValue == "subagent"
        return makeSession(
            sessionID: sessionID,
            cwd: item["cwd"]?.stringValue?.trimmedNonEmpty,
            title: title,
            running: item["running"]?.boolValue ?? false,
            updatedAt: item["updatedAt"]?.intValue.map {
                Date(timeIntervalSince1970: Double($0) / 1000)
            },
            runtimeProvider: runtimeProvider,
            workspace: workspace,
            parentSessionID: parentSessionID,
            isSubagent: isSubagent
        )
    }

    private static func makeSession(
        sessionID: String,
        cwd: String?,
        title: String?,
        running: Bool,
        updatedAt: Date?,
        runtimeProvider: String,
        workspace: AgentWorkspace?,
        parentSessionID: String? = nil,
        isSubagent: Bool = false
    ) -> AgentSession {
        AgentSession(
            id: sessionID,
            // 全局发现没有工作区归属：projectID 留空，由 dir 经 workspaceForPath 对账。
            // 绝不能拿全局结果直接当成某个工作区成员。
            projectID: workspace?.id ?? "",
            project: workspace?.name ?? "",
            dir: cwd ?? workspace?.path ?? "",
            title: title ?? "",
            // 与既有列表语义对齐：running 才是可继续的活动会话，其余按历史条目处理。
            status: running ? "running" : "history",
            source: runtimeProvider,
            runtimeProvider: runtimeProvider,
            // Harness 的历史会话直接按同一个 sessionId 续聊；缺失它会误走 session/create。
            resumeID: sessionID,
            createdAt: nil,
            updatedAt: updatedAt,
            recencyAt: updatedAt,
            parentThreadID: parentSessionID,
            isSubagent: isSubagent
        )
    }
}

// MARK: - 兜底定时器时钟

/// 目录兜底定时器用的时钟。
///
/// 抽出来的唯一目的：让"仅列表可见且前台时每 5 秒最多一次"这条策略可以被 **fake 时钟**
/// 确定性验证。用真实 `sleep` 去赌时序，测出来的只是机器的忙闲。
@MainActor
protocol HarnessDirectoryClock: AnyObject {
    var now: Date { get }
    /// `delay` 秒后回调一次。返回的 token 用来取消尚未触发的回调。
    func schedule(after delay: TimeInterval, _ body: @escaping @MainActor () -> Void) -> HarnessDirectoryClockToken
}

@MainActor
protocol HarnessDirectoryClockToken: AnyObject {
    func cancel()
}

/// 生产实现：主队列上的延迟回调。
@MainActor
final class HarnessDispatchDirectoryClock: HarnessDirectoryClock {
    var now: Date { Date() }

    func schedule(
        after delay: TimeInterval,
        _ body: @escaping @MainActor () -> Void
    ) -> HarnessDirectoryClockToken {
        let item = DispatchWorkItem { Task { @MainActor in body() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return HarnessDispatchDirectoryClockToken(item: item)
    }
}

@MainActor
final class HarnessDispatchDirectoryClockToken: HarnessDirectoryClockToken {
    private let item: DispatchWorkItem

    init(item: DispatchWorkItem) {
        self.item = item
    }

    func cancel() {
        item.cancel()
    }
}

// MARK: - 目录协调器

/// Harness 会话目录协调器（D2）。
///
/// 负责的是**顺序与新鲜度**，不是连接：连接代次、在途 RPC、心跳仍只有
/// `HarnessSessionRuntime` 一个负责人，这里不另建持久会话索引。
///
/// 四条承重规则：
/// 1. **refresh generation**：查询身份每变一次（切 host、切工作区、手动刷新）就自增，
///    在途请求回来自报的 generation 对不上就丢弃——晚到的旧结果不能覆盖新页。
/// 2. **single-flight + dirty 尾随**：并发触发合并成一个在途请求；在途期间来的新失效信号
///    记成 dirty，结束后**最多补一次**。直接吞掉最后一次变化会让列表停在旧快照上。
/// 3. **失败保留旧页**：失败只改状态，不动 `sessions`。把失败显示成空列表等于告诉用户
///    "会话都没了"。
/// 4. **前台 5 秒兜底**：仅列表可见且 App 前台时，每 5 秒最多发起一次合并后的列表请求。
///    这是产品参数（可经测量调整），不是 Harness 的保证——因为跨连接的新会话推送未获证实。
@MainActor
final class HarnessSessionDirectory {
    /// 产品参数：前台目录兜底间隔。`$events` 能可靠跨连接推送 `api-session/added` 之后，
    /// 它可以降级成安全网，但当前不能拿未证明的推送取代它。
    static let foregroundFallbackInterval: TimeInterval = 5

    typealias Fetch = @MainActor (HarnessSessionDirectoryQuery) async throws -> SessionsPage
    typealias Deliver = @MainActor (HarnessSessionDirectoryQuery, SessionsPage) -> Void

    private let fetch: Fetch
    private let deliver: Deliver
    private let clock: HarnessDirectoryClock
    private let fallbackInterval: TimeInterval

    private(set) var query: HarnessSessionDirectoryQuery?
    private(set) var state: HarnessSessionDirectoryState = .idle
    private(set) var sessions: [AgentSession] = []
    /// 查询身份代次。只有它相等的结果才允许落地。
    private(set) var generation: UInt64 = 0

    private var inFlight: Task<Void, Never>?
    /// 在途请求的代次快照，用来判断回来的结果还算不算数。
    private var inFlightGeneration: UInt64 = 0
    private var inFlightTaskID: UInt64 = 0
    private var nextTaskID: UInt64 = 0
    private var dirty = false
    private var fallbackToken: HarnessDirectoryClockToken?
    private var isListVisible = false
    private var isForeground = false

    /// `clock` 不给默认值：`HarnessDirectoryClock` 是 `@MainActor` 隔离的，
    /// 而默认实参表达式在**非隔离**上下文里求值，写成 `= HarnessDispatchDirectoryClock()`
    /// 会直接编译失败。调用方本来就在主 actor 上（生产接线与测试都是），由它自己构造更诚实——
    /// 也让"这个协调器到底用了哪个时钟"在调用点一眼可见，而不是藏在一个隐式默认里。
    init(
        clock: HarnessDirectoryClock,
        fallbackInterval: TimeInterval = HarnessSessionDirectory.foregroundFallbackInterval,
        fetch: @escaping Fetch,
        deliver: @escaping Deliver
    ) {
        self.clock = clock
        self.fallbackInterval = fallbackInterval
        self.fetch = fetch
        self.deliver = deliver
    }

    // MARK: 生命周期

    /// 进入某个查询身份。身份变了就作废在途请求并清空旧页——另一个作用域的会话不是本页。
    func activate(query newQuery: HarnessSessionDirectoryQuery) {
        guard query != newQuery else {
            refresh(manual: false)
            return
        }
        query = newQuery
        generation &+= 1
        dirty = false
        sessions = []
        state = .loading
        cancelInFlight()
        cancelFallback()
        startRequest()
    }

    /// 离开列表 / 断开：停表、停请求、清空。
    func deactivate() {
        query = nil
        generation &+= 1
        dirty = false
        sessions = []
        state = .idle
        cancelInFlight()
        cancelFallback()
    }

    /// 列表可见性与前后台。两者任一为假都必须**立刻停表**，否则兜底会变成后台轮询。
    func setListVisible(_ visible: Bool, isForeground foreground: Bool) {
        guard isListVisible != visible || isForeground != foreground else { return }
        isListVisible = visible
        isForeground = foreground
        guard visible, foreground else {
            cancelFallback()
            return
        }
        scheduleFallback()
    }

    // MARK: 触发

    /// 手动刷新：**必须真的发新请求**，不复用近期结果。
    ///
    /// 做法是自增代次，让任何在途请求作废，再发一条新的。合并进在途请求等于把
    /// "刷新"变成"等上一次的结果"，用户点了没反应。
    func refresh(manual: Bool) {
        guard query != nil else { return }
        if manual {
            generation &+= 1
            dirty = false
            cancelInFlight()
        }
        startRequest()
    }

    /// 控制流 / `$events` 提示目录可能变了。只作触发，不拿控制流 baseline 当目录事实来源。
    func notifyDirectoryMayHaveChanged() {
        refresh(manual: false)
    }

    /// 等待当前在途请求走完（含 dirty 尾随补发的那一次）。
    ///
    /// 给调用方一个可观察的完成点：`activate` / `refresh` 都是触发即返回，
    /// 而"手动刷新真的拿到了新结果"这类断言需要一个确定的结束时刻。没有它，
    /// 调用方只能靠 sleep 去赌时序——那测出来的只是机器忙闲。
    ///
    /// 循环而不是等一次：`finish` 遇到 dirty 会立刻补发下一轮，只等第一轮会提前返回。
    /// 有界是因为尾随刷新最多补一次。
    func waitForInFlightRequest() async {
        var awaited = 0
        while let task = inFlight {
            _ = await task.value
            awaited += 1
            if awaited > 8 { return }
        }
    }

    // MARK: 请求

    private func startRequest() {
        guard query != nil else { return }
        guard inFlight == nil else {
            // 并发触发合并成一个在途请求；期间的失效信号留到结束后补一次。
            dirty = true
            return
        }
        cancelFallback()
        let requestQuery = query!
        let requestGeneration = generation
        nextTaskID &+= 1
        let taskID = nextTaskID
        inFlightTaskID = taskID
        inFlightGeneration = requestGeneration
        if sessions.isEmpty, state != .failed(state.failureMessage ?? "") {
            state = .loading
        }
        inFlight = Task { @MainActor [weak self] in
            guard let self else { return }
            let result: Result<SessionsPage, Error>
            do {
                result = .success(try await self.fetch(requestQuery))
            } catch {
                result = .failure(error)
            }
            self.finish(taskID: taskID, generation: requestGeneration, query: requestQuery, result: result)
        }
    }

    private func finish(
        taskID: UInt64,
        generation requestGeneration: UInt64,
        query requestQuery: HarnessSessionDirectoryQuery,
        result: Result<SessionsPage, Error>
    ) {
        // 已经被更新的请求取代：整条结果丢弃，不落地、不改状态、不碰 dirty。
        // 这就是"晚到旧结果不能覆盖新页"的落点。
        guard taskID == inFlightTaskID else { return }
        inFlight = nil
        guard requestGeneration == generation, requestQuery == query else { return }

        switch result {
        case .success(let page):
            sessions = page.sessions
            state = .loaded
            deliver(requestQuery, page)
        case .failure(let error):
            if error is CancellationError { return }
            // 失败保留旧页：只换状态，不动 sessions。
            state = .failed(error.localizedDescription)
        }

        if dirty {
            dirty = false
            startRequest()
            return
        }
        scheduleFallback()
    }

    private func cancelInFlight() {
        inFlight?.cancel()
        inFlight = nil
        // 任务 ID 前进一位，被取消任务的完成回调不再算数。
        nextTaskID &+= 1
        inFlightTaskID = nextTaskID
    }

    // MARK: 前台兜底

    private func scheduleFallback() {
        cancelFallback()
        guard isListVisible, isForeground, query != nil else { return }
        let token = clock.schedule(after: fallbackInterval) { [weak self] in
            guard let self else { return }
            self.fallbackToken = nil
            guard self.isListVisible, self.isForeground else { return }
            self.refresh(manual: false)
        }
        fallbackToken = token
    }

    private func cancelFallback() {
        fallbackToken?.cancel()
        fallbackToken = nil
    }
}

// 注意：`String.trimmedNonEmpty` 已由 `AgentRuntimeModels.swift` 以 module-internal
// 扩展提供，这里**不要**再声明一份——同模块内重名就是 `invalid redeclaration`。
