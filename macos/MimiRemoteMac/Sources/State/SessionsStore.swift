import Foundation
import Observation

/// 会话窗口的数据（#991）。每次加载重新取列表，不在电脑端缓存会话。
@MainActor
@Observable
final class SessionsStore {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    enum RuntimeFilter: String, CaseIterable, Identifiable {
        case all
        case codex
        case claude

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "全部"
            case .codex: SessionRuntime.codex.title
            case .claude: SessionRuntime.claude.title
            }
        }

        func includes(_ runtime: SessionRuntime) -> Bool {
            switch self {
            case .all: true
            case .codex: runtime == .codex
            case .claude: runtime == .claude
            }
        }
    }

    /// 首次加载每个 runtime 最多取的页数（每页 50 条，子任务过滤后通常剩一半）。
    static let initialPageBudget = 4
    static let pageBudgetStep = 4

    private(set) var phase: Phase = .idle
    private(set) var sessions: [DesktopSession] = []
    /// 部分 runtime 读不到时的说明；全部失败时改用 `.failed`。
    private(set) var notices: [String] = []
    private(set) var hasMore = false
    private(set) var isRefreshing = false
    var filter: RuntimeFilter = .all
    var query = ""

    private let source: any DesktopSessionSource
    private var pageBudget = SessionsStore.initialPageBudget
    private var generation = 0

    init(source: any DesktopSessionSource = LocalGatewayClient()) {
        self.source = source
    }

    var visibleSections: [DesktopSessionGrouping.Section] {
        DesktopSessionGrouping.sections(
            sessions.filter { filter.includes($0.runtime) && $0.matches(query) }
        )
    }

    var isEmptyAfterFiltering: Bool {
        phase == .loaded && !sessions.isEmpty && visibleSections.isEmpty
    }

    /// endpoint 为空说明服务没在运行；runtimes 是电脑上已启用的助手。
    func reload(endpoint: String?, runtimes: [SessionRuntime]) async {
        pageBudget = Self.initialPageBudget
        await load(endpoint: endpoint, runtimes: runtimes)
    }

    func loadMore(endpoint: String?, runtimes: [SessionRuntime]) async {
        pageBudget += Self.pageBudgetStep
        await load(endpoint: endpoint, runtimes: runtimes)
    }

    private func load(endpoint: String?, runtimes: [SessionRuntime]) async {
        generation += 1
        let current = generation
        guard let endpoint, let port = LocalGatewayClient.port(fromEndpoint: endpoint) else {
            apply(sessions: [], notices: [], hasMore: false, phase: .failed("Mimi 服务没有运行。启动服务后再打开。"))
            return
        }
        guard !runtimes.isEmpty else {
            apply(sessions: [], notices: [], hasMore: false, phase: .failed("Codex 和 Claude 都已关闭，在菜单栏打开后再试。"))
            return
        }
        // 已有内容时保留列表，只显示刷新状态，避免每次刷新整窗闪成加载页。
        if sessions.isEmpty { phase = .loading }
        isRefreshing = true

        let source = self.source
        let budget = pageBudget
        let results = await withTaskGroup(of: (SessionRuntime, Result<DesktopSessionListing, Error>).self) { group in
            for runtime in runtimes {
                group.addTask {
                    do {
                        return (runtime, .success(try await source.listSessions(runtime: runtime, port: port, pageBudget: budget)))
                    } catch {
                        return (runtime, .failure(error))
                    }
                }
            }
            var collected: [SessionRuntime: Result<DesktopSessionListing, Error>] = [:]
            for await (runtime, result) in group { collected[runtime] = result }
            return collected
        }
        // 用户在等待期间刷新或换了服务，旧结果不能盖住新的。
        guard current == generation else { return }

        var merged: [DesktopSession] = []
        var notices: [String] = []
        var failures: [String] = []
        var hasMore = false
        for runtime in runtimes {
            switch results[runtime] {
            case .success(let listing):
                merged += listing.sessions
                hasMore = hasMore || listing.hasMore
            case .failure(let error):
                let message = error.localizedDescription
                failures.append(message)
                notices.append("暂时读不到 \(runtime.title) 会话：\(message)")
            case nil:
                break
            }
        }
        if failures.count == runtimes.count {
            apply(sessions: [], notices: [], hasMore: false, phase: .failed(failures.first ?? "无法读取会话。"))
        } else {
            apply(sessions: merged, notices: notices, hasMore: hasMore, phase: .loaded)
        }
    }

    private func apply(sessions: [DesktopSession], notices: [String], hasMore: Bool, phase: Phase) {
        self.sessions = sessions
        self.notices = notices
        self.hasMore = hasMore
        self.phase = phase
        isRefreshing = false
    }
}
