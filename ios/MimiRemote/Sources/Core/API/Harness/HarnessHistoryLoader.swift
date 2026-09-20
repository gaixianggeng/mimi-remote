import Foundation

/// 历史装载的顺序编排：**先 follow，再按 snapshot 的 cursor 读历史**。
///
/// 契约 §5.5 与 D3 规定了这个顺序，理由不是性能而是正确性：
///
/// - `session/page` 的 `throughSeq` **必须**取自本次 follow 的 opening snapshot 的
///   `cursor`。它不是"随便一个游标"——传 0 只会读到 seq 0 一条，传一个远超当前 cursor
///   的值（如 999999）返回**空 records**。所以历史读取在 follow 之前不可能发生：
///   那时还没有合法的 throughSeq。
/// - snapshot 建立期间到达的 live 帧**不能丢**：它们属于本次订阅，必须按原生顺序
///   交接给 journal。否则"打开会话的瞬间"和"历史读完"之间会留下一条缝，
///   缝里的正文永远不会出现。
///
/// 这个类型只做编排，不持有会话集合：记录都落进调用方给的 journal。
@MainActor
final class HarnessHistoryLoader {

    /// 历史页拉取。由调用方注入真实 client 或测试替身。
    typealias FetchPage = @MainActor (HarnessHistoryPageRequest) async throws -> HarnessHistoryPage

    /// 一次分页请求。`throughSeq` 恒为本次 snapshot 的 cursor（见类型注释）。
    struct HarnessHistoryPageRequest: Equatable {
        let sessionID: String
        /// 本次 follow 的 opening snapshot 提供的闭区间切点。
        let throughSeq: Int
        /// 更早历史的位置。首屏为 nil。
        let beforeSeq: Int?
        let maxMessages: Int
    }

    struct HarnessHistoryPage: Equatable {
        let records: [HarnessSnapshotRecord]
        let hasMore: Bool
        /// 下一页的 beforeSeq。为 nil 表示上游没给位置——此时必须停止，
        /// 不能拿"已展示条数"编一个游标出来。
        let nextBeforeSeq: Int?
    }

    /// 分页上限。防御上游永不返回 hasMore=false 时把 UI 拖死。
    let maxPages: Int
    /// 每页条数。
    let pageSize: Int

    private let fetchPage: FetchPage

    init(pageSize: Int = 100, maxPages: Int = 20, fetchPage: @escaping FetchPage) {
        self.pageSize = pageSize
        self.maxPages = maxPages
        self.fetchPage = fetchPage
    }

    /// 分页终止结果。
    enum LoadOutcome: Equatable {
        /// 正常读到没有更多。
        case reachedEnd(pages: Int)
        /// 命中页数上限。**不是**"读完了"——必须如实说出来。
        case cappedAtMaxPages(pages: Int)
        /// 某页没有带来任何新记录：无进展。继续读只会无限循环。
        case noProgress(pages: Int)
        /// 上游没有给出下一页位置。无法继续，但也不是错误。
        case missingCursor(pages: Int)
    }

    /// 按 opening snapshot 的 cursor 读更早的历史，prepend 进 journal。
    ///
    /// 调用前提：journal 已经 `apply(snapshot:)` 过——否则这里没有合法的 throughSeq。
    /// 违反前提时抛错而不是猜一个游标。
    @discardableResult
    func loadEarlierHistory(
        sessionID: String,
        into journal: inout HarnessSessionJournal
    ) async throws -> LoadOutcome {
        guard let throughSeq = journal.snapshotCursor else {
            // 没有本次 snapshot 的 cursor，就没有合法的 throughSeq。
            // 猜一个（比如用 latestSeq 或 0）会产生静默错误的结果——契约 §5.5 明确禁止。
            throw HarnessTransportError.malformedResponse(
                "历史读取缺少本次 follow 的 snapshot.cursor，无法确定 throughSeq"
            )
        }

        var pages = 0
        var beforeSeq: Int? = journal.orderedRecords.first?.seq
        // 首屏历史从"现有最早记录之前"开始。若 journal 还是空的，beforeSeq 为 nil，
        // 由上游返回快照尾部之前的记录。
        while pages < maxPages {
            let request = HarnessHistoryPageRequest(
                sessionID: sessionID,
                throughSeq: throughSeq,
                beforeSeq: beforeSeq,
                maxMessages: pageSize
            )
            let page = try await fetchPage(request)
            pages += 1

            let progressed = journal.prependHistoryPage(records: page.records)
            guard progressed else {
                // 这一页没有任何新 seq。要么上游在重复返回同一页，要么 beforeSeq 没推进。
                // 继续读就是死循环——契约要求"分页遇无进展必须停止或明确错误"。
                return .noProgress(pages: pages)
            }
            guard page.hasMore else { return .reachedEnd(pages: pages) }
            guard let next = page.nextBeforeSeq else {
                // 上游说还有更多，却没给位置。不编造游标。
                return .missingCursor(pages: pages)
            }
            beforeSeq = next
        }
        return .cappedAtMaxPages(pages: pages)
    }
}
