import Foundation
import Security
import SnapshotTesting
import SwiftUI
import UIKit
import XCTest
@testable import MimiRemote

final class SessionListPresentationTests: XCTestCase {
    func testWorkspaceIdentityAppearsOnlyWhenDirectoriesDiffer() {
        let main = makeSession(id: "main", project: "mimi", dir: "/work/mimi")
        let another = makeSession(id: "another", project: "mimi", dir: "/work/mimi")
        let worktree = makeSession(id: "worktree", project: "mimi", dir: "/work/mimi-fix")

        XCTAssertEqual(SessionListPresentation.workspaceIdentityFallback(among: []), .none)
        XCTAssertEqual(SessionListPresentation.workspaceIdentityFallback(among: [main, another]), .none)
        XCTAssertEqual(SessionListPresentation.workspaceIdentityFallback(among: [main, worktree]), .directory)
        XCTAssertEqual(SessionIndexRow.identityFallbackText(for: main, fallback: .none), "")
        XCTAssertEqual(SessionIndexRow.identityFallbackText(for: worktree, fallback: .directory), "mimi-fix")
    }

    @MainActor
    func testFirstConnectionWithoutOpenedWorkspaceFinishesLoading() async {
        let appStore = makeIsolatedAppStore()
        let candidate = makeProject(id: "unopened-candidate")
        let client = MockSessionStoreClient(projects: [candidate], sessions: [])
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: makeRecentWorkspaceStore(workspaces: [], endpoint: appStore.endpoint),
            clientFactory: { client }
        )
        func presentation() -> SessionListPresentationState {
            SessionListPresentationState.resolve(
                hasVisibleSessions: !store.sessions.isEmpty,
                hasOpenedWorkspace: !store.sidebarProjects.isEmpty,
                isLoading: store.isLoading,
                isSearching: false,
                isFiltering: false,
                isNetworkUnavailable: store.isNetworkUnavailable,
                errorMessage: store.errorMessage,
                connectionStatus: appStore.connectionStatus,
                hasLoadedWorkspaceCatalog: store.loadedWorkspaceCatalogScope == appStore.activeHostScope
            )
        }

        XCTAssertEqual(presentation(), .loading)
        await store.refreshAll(autoAttach: true)

        XCTAssertEqual(appStore.connectionStatus, .idle)
        XCTAssertFalse(store.isLoading)
        XCTAssertTrue(store.sidebarProjects.isEmpty, "后端候选目录不应自动成为已打开工作区")
        XCTAssertEqual(presentation(), .needsWorkspace)

        _ = store.ensureWorkspaceForKnownProjectID(candidate.id)
        await store.refreshAll(autoAttach: true)
        XCTAssertFalse(store.sidebarProjects.isEmpty)
        XCTAssertEqual(presentation(), .noSessions)
    }

    func testLoadedWorkspaceCatalogPreservesLoadingErrorsAndContent() {
        func state(
            loading: Bool = false,
            connection: ConnectionStatus = .idle,
            error: String? = nil,
            offline: Bool = false,
            visible: Bool = false,
            catalogLoaded: Bool = true
        ) -> SessionListPresentationState {
            SessionListPresentationState.resolve(
                hasVisibleSessions: visible,
                hasOpenedWorkspace: false,
                isLoading: loading,
                isSearching: false,
                isFiltering: false,
                isNetworkUnavailable: offline,
                errorMessage: error,
                connectionStatus: connection,
                hasLoadedWorkspaceCatalog: catalogLoaded
            )
        }

        XCTAssertEqual(state(), .needsWorkspace)
        XCTAssertEqual(state(catalogLoaded: false), .loading)
        XCTAssertEqual(state(loading: true), .loading)
        XCTAssertEqual(state(connection: .testing), .loading)
        XCTAssertEqual(state(connection: .failed("unavailable")), .runtimeUnavailable("unavailable"))
        XCTAssertEqual(state(error: "load failed"), .loadFailed("load failed"))
        XCTAssertEqual(state(offline: true), .networkUnavailable)
        XCTAssertEqual(state(visible: true), .content)
    }

    func testOnlyInProgressStatesAskTheHostSwitcherToStepAside() {
        for state in [SessionListPresentationState.connecting, .loading] {
            XCTAssertTrue(
                state.showsInPlaceConnectionProgress,
                "\(state) 正文自己在转，设备入口必须让位"
            )
        }

        // 结论型与内容态由正文之外的地方表达，徽标要照常出现。
        for state in [
            SessionListPresentationState.content,
            .searching,
            .needsWorkspace,
            .noSessions,
            .noMatches,
            .networkUnavailable,
            .runtimeUnavailable("gateway down"),
            .loadFailed("timeout")
        ] {
            XCTAssertFalse(
                state.showsInPlaceConnectionProgress,
                "\(state) 不是进行中，顶栏徽标不该被按下去"
            )
        }
    }

    func testWaitingStatesAreCenteredOnThePageInsteadOfTheFirstRow() {
        for state in [SessionListPresentationState.connecting, .loading, .searching] {
            XCTAssertTrue(state.showsCenteredLoading, "\(state) 是在等内容，圆环要铺在整页正中")
        }

        for state in [
            SessionListPresentationState.content,
            .needsWorkspace,
            .noSessions,
            .noMatches,
            .networkUnavailable,
            .runtimeUnavailable("gateway down"),
            .loadFailed("timeout")
        ] {
            XCTAssertFalse(state.showsCenteredLoading, "\(state) 不是等待态，仍走列表内的空态")
        }
    }

    func testConnectionWarmUpOutranksTransientFailuresButNotDefiniteStates() {
        func state(
            connection: ConnectionStatus = .idle,
            error: String? = nil,
            offline: Bool = false,
            visible: Bool = false,
            establishing: Bool
        ) -> SessionListPresentationState {
            SessionListPresentationState.resolve(
                hasVisibleSessions: visible,
                hasOpenedWorkspace: false,
                isLoading: false,
                isSearching: false,
                isFiltering: false,
                isNetworkUnavailable: offline,
                errorMessage: error,
                connectionStatus: connection,
                hasLoadedWorkspaceCatalog: true,
                isEstablishingConnection: establishing
            )
        }

        // 预热窗口内的 preflight 与列表失败都还会自动重试，不能先渲染成结论。
        XCTAssertEqual(state(connection: .failed("tunnel not ready"), establishing: true), .connecting)
        XCTAssertEqual(state(error: "load failed", establishing: true), .connecting)
        XCTAssertEqual(state(establishing: true), .connecting)

        // 已经有内容时不退回过渡；设备本身离线是明确结论，必须压过预热。
        XCTAssertEqual(state(visible: true, establishing: true), .content)
        XCTAssertEqual(state(offline: true, establishing: true), .networkUnavailable)

        // 窗口结束后原有错误态与重试入口原样接管。
        XCTAssertEqual(
            state(connection: .failed("tunnel not ready"), establishing: false),
            .runtimeUnavailable("tunnel not ready")
        )
        XCTAssertEqual(state(error: "load failed", establishing: false), .loadFailed("load failed"))
    }

    @MainActor
    func testBootstrapKeepsConnectionWarmUpActiveAcrossTransientFailures() async {
        let project = makeProject(id: "proj_warm_up")
        let client = FlakyBootstrapClient(failuresBeforeSuccess: 2, projects: [project], sessions: [])
        let appStore = makeIsolatedAppStore()
        appStore.token = "warm-up-token"
        var observedDuringBackoff: [Bool] = []
        var observedPresentationDuringBackoff: [SessionListPresentationState] = []
        var store: SessionStore? = nil
        let created = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { client },
            sessionListSleep: { _ in
                // 退避间隙就是用户真正看到的那一帧：此时必须仍在连接过渡，而不是错误态。
                guard let store else { return }
                observedDuringBackoff.append(store.isEstablishingConnection)
                observedPresentationDuringBackoff.append(
                    SessionListPresentationState.resolve(
                        hasVisibleSessions: false,
                        hasOpenedWorkspace: false,
                        isLoading: store.isLoading,
                        isSearching: false,
                        isFiltering: false,
                        isNetworkUnavailable: store.isNetworkUnavailable,
                        errorMessage: store.errorMessage,
                        connectionStatus: appStore.connectionStatus,
                        hasLoadedWorkspaceCatalog: store.loadedWorkspaceCatalogScope == appStore.activeHostScope,
                        isEstablishingConnection: store.isEstablishingConnection
                    )
                )
            }
        )
        store = created

        await created.bootstrap()

        XCTAssertGreaterThanOrEqual(observedDuringBackoff.count, 2, "应至少经历两次退避重试")
        XCTAssertTrue(observedDuringBackoff.allSatisfy { $0 }, "每一次退避重试期间都应停留在连接过渡")
        XCTAssertTrue(
            observedPresentationDuringBackoff.allSatisfy { $0 == .connecting },
            "退避期间首屏不能渲染成运行时不可用或加载失败"
        )
        XCTAssertNil(created.errorMessage, "重试成功后不应留下错误")
        XCTAssertFalse(created.isEstablishingConnection, "首屏数据到手后必须退出连接过渡")
        XCTAssertFalse(created.isConnectionWarmUpActive)
    }

    @MainActor
    func testConnectionWarmUpYieldsToDefiniteConnectionOutcomes() {
        let appStore = makeIsolatedAppStore()
        appStore.token = "warm-up-token"
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [], sessions: []) }
        )

        let token = store.beginConnectionWarmUp()
        XCTAssertTrue(store.isEstablishingConnection)

        // 访问码失效是终态，继续播放连接过渡只会把用户困在不会好的动画里。
        store.connectionTermination = .credentialsInvalid
        XCTAssertFalse(store.isEstablishingConnection)
        store.connectionTermination = nil
        XCTAssertTrue(store.isEstablishingConnection)

        store.endConnectionWarmUp(token)
        XCTAssertFalse(store.isEstablishingConnection)

        // 已经归还过的令牌再释放一次不得影响新一轮预热。
        let newerToken = store.beginConnectionWarmUp()
        store.endConnectionWarmUp(token)
        XCTAssertTrue(store.isEstablishingConnection)
        store.endConnectionWarmUp(newerToken)
        XCTAssertFalse(store.isEstablishingConnection)
    }

    /// 共享的 errorMessage 同时承载探测失败和用户操作失败。预热窗口只能压住前者：
    /// 把用户刚点的发送/审批失败一起吞掉，会变成"点了没反应"，比一闪而过的错误更糟。
    @MainActor
    func testConnectionWarmUpOnlySuppressesConnectionProbeErrors() {
        let appStore = makeIsolatedAppStore()
        appStore.token = "warm-up-token"
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [], sessions: []) }
        )
        let warmUp = store.beginConnectionWarmUp()
        XCTAssertTrue(store.isEstablishingConnection)

        func conversationShowsError() -> Bool {
            // 与 ConversationView 顶部错误条同一判定。
            !(store.isEstablishingConnection && store.errorMessageOrigin == .connectionProbe)
        }

        store.setErrorMessage("无法连接服务器。", origin: .connectionProbe)
        XCTAssertEqual(store.errorMessageOrigin, .connectionProbe)
        XCTAssertFalse(conversationShowsError(), "探测失败在预热窗口内仍会自动重试，不该弹错误条")

        store.setErrorMessage("发送失败：WebSocket 未连接")
        XCTAssertEqual(store.errorMessageOrigin, .userAction)
        XCTAssertTrue(conversationShowsError(), "用户主动发送的失败必须照常展示")

        // 同一条文案先由探测写入、随后被用户操作再次触发时，也要回到可见。
        store.setErrorMessage(nil)
        store.setErrorMessage("无法连接服务器。", origin: .connectionProbe)
        XCTAssertFalse(conversationShowsError())
        store.setErrorMessage("无法连接服务器。")
        XCTAssertTrue(conversationShowsError())

        store.endConnectionWarmUp(warmUp)
        store.setErrorMessage("无法连接服务器。", origin: .connectionProbe)
        XCTAssertTrue(conversationShowsError(), "窗口结束后探测失败也要如实展示")
    }

    /// 冷启动会有 RootView 启动任务、bootstrap 和一到多个退避循环同时持有窗口。
    /// 先结束的持有者不得替仍在重试的那个下结论。
    @MainActor
    func testConnectionWarmUpStaysOpenUntilTheLastHolderFinishes() {
        let appStore = makeIsolatedAppStore()
        appStore.token = "warm-up-token"
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [], sessions: []) }
        )

        let outer = store.beginConnectionWarmUp()
        let inner = store.beginConnectionWarmUp()
        let concurrentRetryLoop = store.beginConnectionWarmUp()

        store.endConnectionWarmUp(concurrentRetryLoop)
        XCTAssertTrue(store.isEstablishingConnection)
        store.endConnectionWarmUp(inner)
        XCTAssertTrue(store.isEstablishingConnection)
        store.endConnectionWarmUp(outer)
        XCTAssertFalse(store.isEstablishingConnection)
    }

    @MainActor
    func testConnectionWarmUpStaysClosedWithoutConfiguredConnection() {
        let appStore = makeIsolatedAppStore()
        let store = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            clientFactory: { MockSessionStoreClient(projects: [], sessions: []) }
        )

        XCTAssertFalse(appStore.isConfigured)
        store.beginConnectionWarmUp()
        XCTAssertFalse(store.isConnectionWarmUpActive, "初次配对页不应出现连接过渡")
        XCTAssertFalse(store.isEstablishingConnection)
    }

    func testDateBucketsPreferTodayAndYesterdayAtLocalMidnight() {
        let calendar = makeCalendar(timeZone: "Asia/Shanghai")
        let now = makeDate(calendar, year: 2025, month: 6, day: 2, hour: 0, minute: 15)

        XCTAssertEqual(
            SessionListPresentation.dateBucket(
                for: makeDate(calendar, year: 2025, month: 6, day: 2, hour: 0, minute: 1),
                now: now,
                calendar: calendar
            ),
            .today
        )
        XCTAssertEqual(
            SessionListPresentation.dateBucket(
                for: makeDate(calendar, year: 2025, month: 6, day: 1, hour: 23, minute: 59),
                now: now,
                calendar: calendar
            ),
            .yesterday
        )
    }

    func testDateBucketsRespectWeekMonthBoundariesAndExplicitTimeZone() {
        var calendar = makeCalendar(timeZone: "America/Los_Angeles")
        calendar.firstWeekday = 2 // Monday, independent of the machine locale.
        calendar.minimumDaysInFirstWeek = 1

        let now = makeDate(calendar, year: 2025, month: 1, day: 8, hour: 12)
        let thisWeek = makeDate(calendar, year: 2025, month: 1, day: 6, hour: 9)
        let previousWeekSameMonth = makeDate(calendar, year: 2025, month: 1, day: 5, hour: 9)
        let thisMonth = makeDate(calendar, year: 2025, month: 1, day: 20, hour: 9)
        let earlier = makeDate(calendar, year: 2024, month: 12, day: 31, hour: 9)

        XCTAssertEqual(SessionListPresentation.dateBucket(for: thisWeek, now: now, calendar: calendar), .thisWeek)
        XCTAssertEqual(SessionListPresentation.dateBucket(for: previousWeekSameMonth, now: now, calendar: calendar), .thisMonth)
        XCTAssertEqual(SessionListPresentation.dateBucket(for: thisMonth, now: now, calendar: calendar), .thisMonth)
        XCTAssertEqual(SessionListPresentation.dateBucket(for: earlier, now: now, calendar: calendar), .earlier)

        // 同一个绝对时刻在 UTC 可能落入另一日；判定必须使用显式 Calendar 的本地时区。
        let localLateNight = makeDate(calendar, year: 2025, month: 1, day: 7, hour: 23, minute: 30)
        XCTAssertEqual(SessionListPresentation.dateBucket(for: localLateNight, now: now, calendar: calendar), .yesterday)
    }

    func testDateBucketUsesRecencyUpdatedCreatedFallbackAndKeepsNilDates() {
        let calendar = makeCalendar(timeZone: "Asia/Shanghai")
        let now = makeDate(calendar, year: 2025, month: 4, day: 10, hour: 12)
        let today = makeDate(calendar, year: 2025, month: 4, day: 10, hour: 10)
        let yesterday = makeDate(calendar, year: 2025, month: 4, day: 9, hour: 10)
        let earlier = makeDate(calendar, year: 2025, month: 3, day: 31, hour: 10)

        let recencyWins = makeSession(
            id: "recency",
            createdAt: today,
            updatedAt: yesterday,
            recencyAt: earlier
        )
        let updatedWins = makeSession(
            id: "updated",
            createdAt: today,
            updatedAt: yesterday,
            recencyAt: nil
        )
        let createdWins = makeSession(
            id: "created",
            createdAt: today,
            updatedAt: nil,
            recencyAt: nil
        )
        let missingDate = makeSession(id: "missing", createdAt: nil, updatedAt: nil, recencyAt: nil)

        XCTAssertEqual(SessionListPresentation.dateBucket(for: recencyWins, now: now, calendar: calendar), .earlier)
        XCTAssertEqual(SessionListPresentation.dateBucket(for: updatedWins, now: now, calendar: calendar), .yesterday)
        XCTAssertEqual(SessionListPresentation.dateBucket(for: createdWins, now: now, calendar: calendar), .today)
        XCTAssertEqual(SessionListPresentation.dateBucket(for: missingDate, now: now, calendar: calendar), .earlier)
    }

    func testHistoryGroupsOmitEmptyBucketsAndPreserveInputOrder() {
        var calendar = makeCalendar(timeZone: "Asia/Shanghai")
        calendar.firstWeekday = 2
        let now = makeDate(calendar, year: 2025, month: 4, day: 9, hour: 12)
        let firstToday = makeSession(
            id: "today-1",
            createdAt: makeDate(calendar, year: 2025, month: 4, day: 9, hour: 9)
        )
        let secondToday = makeSession(
            id: "today-2",
            createdAt: makeDate(calendar, year: 2025, month: 4, day: 9, hour: 10)
        )
        let yesterday = makeSession(
            id: "yesterday",
            createdAt: makeDate(calendar, year: 2025, month: 4, day: 8, hour: 10)
        )
        let earlier = makeSession(
            id: "earlier",
            createdAt: makeDate(calendar, year: 2025, month: 3, day: 1, hour: 10)
        )

        let groups = SessionListPresentation.historyGroups(
            [firstToday, secondToday, yesterday, earlier],
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(groups.map(\.bucket), [.today, .yesterday, .earlier])
        XCTAssertEqual(groups.flatMap(\.sessions).map(\.id), ["today-1", "today-2", "yesterday", "earlier"])
        XCTAssertFalse(groups.contains { $0.bucket == .thisWeek || $0.bucket == .thisMonth })
    }

    func testDisplayTitleFlattensWhitespaceAndRemovesMarkdownPrefixes() {
        let original = "  ## **Hello**\n> - __world__\tand `code`  "
        let session = makeSession(id: "title", title: original)

        XCTAssertEqual(SessionListPresentation.displayTitle(original), "Hello world and code")
        XCTAssertEqual(SessionListPresentation.displayTitle(for: session), "Hello world and code")
        XCTAssertEqual(session.title, original)
    }

    func testPreviewDisplayTextFlattensMarkdownWithoutMutatingSession() {
        let original = " **A preview**\n> `second`\t  line "
        let session = makeSession(id: "preview", preview: original)

        XCTAssertEqual(SessionListPresentation.previewDisplayText(for: session), "A preview second line")
        XCTAssertEqual(SessionListPresentation.previewDisplayText(original), "A preview second line")
        XCTAssertEqual(session.preview, original)
    }

    func testDistinctPreviewDropsTheTitlePrefixItRepeats() {
        // 真实数据：标题和 preview 都由首条用户消息派生，preview 只是多带一段。
        let session = makeSession(
            id: "redundant",
            title: "我在测试 App的权限。",
            preview: "我在测试 App的权限。 帮我在 Linear 上使用 MCP 查一下"
        )

        XCTAssertEqual(
            SessionListPresentation.distinctPreviewDisplayText(for: session),
            "帮我在 Linear 上使用 MCP 查一下"
        )
        XCTAssertEqual(session.preview, "我在测试 App的权限。 帮我在 Linear 上使用 MCP 查一下")
    }

    func testDistinctPreviewIsEmptyWhenItOnlyRepeatsTheTitle() {
        let identical = makeSession(
            id: "identical",
            title: "更新 Windows 安装包部署",
            preview: "更新 Windows 安装包部署"
        )
        XCTAssertEqual(SessionListPresentation.distinctPreviewDisplayText(for: identical), "")

        // 标题被省略号截断时，省略号不该阻止前缀判定。
        let truncatedTitle = makeSession(
            id: "truncated-title",
            title: "嗯，目前 windows 应该还不止…",
            preview: "嗯，目前 windows 应该还不止"
        )
        XCTAssertEqual(SessionListPresentation.distinctPreviewDisplayText(for: truncatedTitle), "")

        // 反向：preview 是更早的截断版本，标题反而更长。
        let truncatedPreview = makeSession(
            id: "truncated-preview",
            title: "清理已经无关的 worktree 分支",
            preview: "清理已经无关的 worktree…"
        )
        XCTAssertEqual(SessionListPresentation.distinctPreviewDisplayText(for: truncatedPreview), "")

        // 去掉标题前缀后只剩标点，第二行没有信息量。
        let punctuationOnly = makeSession(
            id: "punctuation",
            title: "拉取最新代码",
            preview: "拉取最新代码。"
        )
        XCTAssertEqual(SessionListPresentation.distinctPreviewDisplayText(for: punctuationOnly), "")
    }

    func testDistinctPreviewKeepsGenuinelyDifferentText() {
        let session = makeSession(
            id: "distinct",
            title: "PR #232 CI flow error",
            preview: "已经定位到 verify-windows 的 shutdown 抖动"
        )
        XCTAssertEqual(
            SessionListPresentation.distinctPreviewDisplayText(for: session),
            "已经定位到 verify-windows 的 shutdown 抖动"
        )

        // 前缀太短的"撞头"是巧合，不是重复。
        let shortStem = makeSession(id: "short", title: "修", preview: "修一下 CI 的超时时间")
        XCTAssertEqual(
            SessionListPresentation.distinctPreviewDisplayText(for: shortStem),
            "修一下 CI 的超时时间"
        )

        // Markdown 清洗规则与 previewDisplayText 保持一致。
        let markdown = makeSession(id: "markdown", title: "Alpha", preview: " **Beta**\n> `gamma`\t  delta ")
        XCTAssertEqual(
            SessionListPresentation.distinctPreviewDisplayText(for: markdown),
            "Beta gamma delta"
        )

        let missing = makeSession(id: "missing", title: "Alpha", preview: nil)
        XCTAssertEqual(SessionListPresentation.distinctPreviewDisplayText(for: missing), "")
    }

    func testDistinctPreviewKeepsOrdinaryWordPrefixesInBothDirections() {
        XCTAssertEqual(
            SessionListPresentation.distinctPreviewDisplayText(
                title: "Swift",
                preview: "SwiftUI navigation bug"
            ),
            "SwiftUI navigation bug"
        )
        XCTAssertEqual(
            SessionListPresentation.distinctPreviewDisplayText(
                title: "工作区会话",
                preview: "工作区会话列表需要优化"
            ),
            "工作区会话列表需要优化"
        )
        XCTAssertEqual(
            SessionListPresentation.distinctPreviewDisplayText(
                title: "修复输入区布局",
                preview: "修复"
            ),
            "修复"
        )
        XCTAssertEqual(
            SessionListPresentation.distinctPreviewDisplayText(
                title: "工作区会话列表需要优化",
                preview: "工作区会话"
            ),
            "工作区会话"
        )

        XCTAssertEqual(
            SessionListPresentation.distinctPreviewDisplayText(
                title: "工作区会话",
                preview: "工作区会话：列表需要优化"
            ),
            "列表需要优化"
        )
    }

    func testWorkspaceBranchIdentityOnlyShowsWhenMultipleValidBranchesExist() {
        XCTAssertNil(SessionListPresentation.branchToDisplay("main", among: ["main", " main ", nil, " "]))
        XCTAssertEqual(
            SessionListPresentation.branchToDisplay(" feature/login ", among: ["main", " feature/login ", nil]),
            "feature/login"
        )
        XCTAssertNil(SessionListPresentation.branchToDisplay(" ", among: ["main", "feature/login"]))
    }

    func testSessionLibraryProjectLabelsHiddenOutsideWideIPadRows() {
        let sessions = [
            makeSession(id: "a", projectID: "first", project: "app"),
            makeSession(id: "b", projectID: "second", project: "web")
        ]
        XCTAssertEqual(SessionListPresentation.sessionLibraryProjectLabels(
            visibleSessions: sessions, workspaces: [], selectedWorkspaceID: "all", usesWideIPadRow: false
        ), [:])
    }

    func testSessionLibraryProjectLabelsRequireAllWorkspacesAndMultipleVisibleProjects() {
        let first = makeSession(id: "a", projectID: "first", project: " app ")
        let second = makeSession(id: "b", projectID: "second", project: "web")
        let workspaces = [
            AgentWorkspace(id: "first", name: "app", path: "/tmp/work/app"),
            AgentWorkspace(id: "second", name: "web", path: "/tmp/work/web")
        ]
        XCTAssertEqual(SessionListPresentation.sessionLibraryProjectLabels(
            visibleSessions: [first, second], workspaces: workspaces,
            selectedWorkspaceID: "first", usesWideIPadRow: true
        ), [:])
        // 打开多个工作区不等于当前筛选结果中有多个项目。
        XCTAssertEqual(SessionListPresentation.sessionLibraryProjectLabels(
            visibleSessions: [first, first], workspaces: workspaces,
            selectedWorkspaceID: "all", usesWideIPadRow: true
        ), [:])
        XCTAssertEqual(SessionListPresentation.sessionLibraryProjectLabels(
            visibleSessions: [first, first, second], workspaces: workspaces,
            selectedWorkspaceID: "all", usesWideIPadRow: true
        ), ["first": "app", "second": "web"])
    }

    func testSessionLibraryProjectLabelsDisambiguateSameNamedProjects() {
        let sessions = [
            makeSession(id: "a", projectID: "work", project: " app "),
            makeSession(id: "b", projectID: "personal", project: "app"),
            makeSession(id: "c", projectID: "web", project: "web")
        ]
        let workspaces = [
            AgentWorkspace(id: "work", name: "app", path: "/tmp/work/app"),
            AgentWorkspace(id: "personal", name: "app", path: "/tmp/personal/app"),
            AgentWorkspace(id: "web", name: "web", path: "/tmp/work/web")
        ]
        XCTAssertEqual(SessionListPresentation.sessionLibraryProjectLabels(
            visibleSessions: sessions + [sessions[0]], workspaces: workspaces,
            selectedWorkspaceID: "all", usesWideIPadRow: true
        ), ["work": "work/app", "personal": "personal/app", "web": "web"])
        // 缺工作区或路径不足两段时仍保留项目名，不凭空生成路径。
        XCTAssertEqual(SessionListPresentation.sessionLibraryProjectLabels(
            visibleSessions: sessions,
            workspaces: [AgentWorkspace(id: "work", name: "app", path: "/app")],
            selectedWorkspaceID: "all", usesWideIPadRow: true
        ), ["work": "app", "personal": "app", "web": "web"])
    }

    func testSessionLibraryProjectLabelsSkipBlankNames() {
        let blank = makeSession(id: "blank", projectID: "blank", project: " \n\t ")
        let first = makeSession(id: "a", projectID: "first", project: "app")
        let second = makeSession(id: "b", projectID: "second", project: "web")
        XCTAssertEqual(SessionListPresentation.sessionLibraryProjectLabels(
            visibleSessions: [blank, first], workspaces: [],
            selectedWorkspaceID: "all", usesWideIPadRow: true
        ), [:])
        XCTAssertEqual(SessionListPresentation.sessionLibraryProjectLabels(
            visibleSessions: [blank, first, second], workspaces: [],
            selectedWorkspaceID: "all", usesWideIPadRow: true
        ), ["first": "app", "second": "web"])
    }

    func testProjectPathSuffix() {
        XCTAssertEqual(SessionListPresentation.projectPathSuffix("/tmp/a/b"), "a/b")
        XCTAssertNil(SessionListPresentation.projectPathSuffix("/b"))
        XCTAssertEqual(SessionListPresentation.projectPathSuffix("/tmp/a/b/"), "a/b")
        XCTAssertEqual(SessionListPresentation.projectPathSuffix("//tmp//a//b//"), "a/b")
        XCTAssertNil(SessionListPresentation.projectPathSuffix(""))
    }

    func testSessionLibrarySupportingTextKeepsSearchSnippetAndEmptyPreview() {
        XCTAssertEqual(
            SessionIndexRow.librarySupportingText(
                searchSnippet: " matched token ",
                ordinaryPreview: "ordinary preview"
            ),
            "matched token"
        )
        XCTAssertEqual(
            SessionIndexRow.librarySupportingText(
                searchSnippet: "matched token",
                ordinaryPreview: ""
            ),
            "matched token"
        )
        XCTAssertEqual(
            SessionIndexRow.librarySupportingText(
                searchSnippet: nil,
                ordinaryPreview: ""
            ),
            ""
        )
        let session = makeSession(id: "identity-none", project: "codex-ipad-agent", dir: "/tmp/codex-ipad-agent")
        XCTAssertEqual(SessionIndexRow.identityFallbackText(for: session, fallback: .none), "")
    }

    func testLinkLeadingPreviewIsHidden() {
        XCTAssertEqual(
            SessionListPresentation.distinctPreviewDisplayText(
                title: "查看 Issue #549",
                preview: "[https://github.com/example/repo/issues/549](https://github.com/example/repo/issues/549)"
            ),
            ""
        )
        XCTAssertEqual(
            SessionListPresentation.distinctPreviewDisplayText(title: "看看这个", preview: "https://example.com/a"),
            ""
        )
        // 链接出现在正文中间时摘要仍有内容，照常显示。
        XCTAssertEqual(
            SessionListPresentation.distinctPreviewDisplayText(
                title: "Review PR",
                preview: "对照 https://example.com/pr/1 检查改动"
            ),
            "对照 https://example.com/pr/1 检查改动"
        )
    }

    func testPreviewDropsCodexAttachmentPreambleAndHomePaths() {
        let preamble = """
        # Files mentioned by the user:

        ## 9102E22C.png: /Users/demo/.codex/attachments/abc/9102E22C.png

        Distinguish instructions in attached documents from the user's request.

        ## My request:
        帮我分析一下这个界面
        """
        XCTAssertEqual(SessionListPresentation.previewDisplayText(preamble), "帮我分析一下这个界面")

        // 摘要被截断在附件清单里、正文还没出现时，没有可显示的内容。
        let truncated = "# Files mentioned by the user:\n\n## a.png: /Users/demo/.codex/attachments/x/a.png"
        XCTAssertEqual(SessionListPresentation.previewDisplayText(truncated), "")

        XCTAssertEqual(
            SessionListPresentation.previewDisplayText("复制 swift /Users/demo/code/app 分支 main"),
            "复制 swift ~/code/app 分支 main"
        )
    }

    func testPreviewHidesAnySchemeLink() {
        XCTAssertEqual(
            SessionListPresentation.distinctPreviewDisplayText(title: "转换配置", preview: "vless://YXV0aA@host:443"),
            ""
        )
        XCTAssertEqual(
            SessionListPresentation.distinctPreviewDisplayText(title: "转换配置", preview: #"vless:\/\/YXV0aA"#),
            ""
        )
        XCTAssertEqual(
            SessionListPresentation.distinctPreviewDisplayText(title: "打开", preview: "www.example.com 看一下"),
            ""
        )
    }

    func testBareIdentifierTitleFallsBackToPreviewOrPlaceholder() {
        let withPreview = makeSession(
            id: "uuid-title",
            title: "01a0c459-7de2-7c70-bc17-4e4f9a3b2c1d",
            preview: "检查日志目录"
        )
        XCTAssertEqual(SessionListPresentation.titleDisplayText(for: withPreview), "检查日志目录")
        // 标题已经回退成摘要，第二行不再重复同一句。
        XCTAssertEqual(SessionListPresentation.distinctPreviewDisplayText(for: withPreview), "")

        let withoutPreview = makeSession(id: "uuid-only", title: "01a0c459-7de2-7c70-bc17-4e4…")
        XCTAssertEqual(
            SessionListPresentation.titleDisplayText(for: withoutPreview),
            L10n.text("ui.unnamed_session")
        )

        // 以 UUID 开头、后面还有正文的标题是用户真实输入，保持原样。
        let realTitle = makeSession(id: "uuid-prefix", title: "01a0ae33-1d4d-77e3 你看下这个会话")
        XCTAssertEqual(SessionListPresentation.titleDisplayText(for: realTitle), "01a0ae33-1d4d-77e3 你看下这个会话")
    }

    func testWorkspaceIdentityFallsBackToDirectoryWithoutChangingGlobalProjectFallback() {
        let directory = "/Users/me/worktrees/codex-ipad-agent/mim-202"
        let session = makeSession(
            id: "directory-fallback",
            project: "codex-ipad-agent",
            dir: directory
        )

        XCTAssertEqual(
            SessionIndexRow.identityFallbackText(for: session, fallback: .directory),
            "mim-202"
        )
        XCTAssertTrue(
            SessionIndexRow.identityFallbackAccessibilityLabel(
                for: session,
                fallback: .directory
            ).contains(directory)
        )
        XCTAssertEqual(
            SessionIndexRow.identityFallbackText(for: session, fallback: .project),
            "codex-ipad-agent"
        )
    }

    func testTimestampTextUsesInjectedNowAndCalendar() {
        let calendar = makeCalendar(timeZone: "Asia/Shanghai")
        let now = makeDate(calendar, year: 2025, month: 4, day: 9, hour: 12, minute: 0)
        let today = makeDate(calendar, year: 2025, month: 4, day: 9, hour: 9, minute: 30)
        let yesterday = makeDate(calendar, year: 2025, month: 4, day: 8, hour: 23, minute: 59)
        let earlier = makeDate(calendar, year: 2025, month: 3, day: 1, hour: 10)

        XCTAssertEqual(
            SessionListPresentation.timestampText(
                for: today,
                now: now,
                calendar: calendar,
                locale: Locale(identifier: "en_US_POSIX")
            ),
            "09:30"
        )
        XCTAssertEqual(
            SessionListPresentation.timestampText(for: yesterday, now: now, calendar: calendar),
            L10n.text("ui.yesterday")
        )
        XCTAssertEqual(
            SessionListPresentation.timestampText(
                for: earlier,
                now: now,
                calendar: calendar,
                locale: Locale(identifier: "en_US_POSIX")
            ),
            "3/1"
        )
        XCTAssertEqual(SessionListPresentation.timestampText(for: nil, now: now, calendar: calendar), "")
    }

    func testCompactSupplementaryPreviewLineLimitPrioritizesSearchSnippet() {
        XCTAssertEqual(
            SessionIndexRow.compactSupplementaryPreviewLineLimit(
                hasSearchSnippet: true,
                dynamicTypeSize: .large
            ),
            2
        )
        XCTAssertEqual(
            SessionIndexRow.compactSupplementaryPreviewLineLimit(
                hasSearchSnippet: false,
                dynamicTypeSize: .large
            ),
            1
        )
        XCTAssertNil(
            SessionIndexRow.compactSupplementaryPreviewLineLimit(
                hasSearchSnippet: true,
                dynamicTypeSize: .accessibility3
            )
        )
        XCTAssertNil(
            SessionIndexRow.compactSupplementaryPreviewLineLimit(
                hasSearchSnippet: false,
                dynamicTypeSize: .accessibility3
            )
        )
    }

    func testSidebarSectionsUsePriorityOrderAndStableDeduplication() {
        let approval = ApprovalSummary(
            id: "approval",
            title: "Approve command",
            kind: "command",
            count: nil
        )
        let inputRequest = AgentUserInputRequest(
            id: "input",
            threadID: "need-input",
            turnID: nil,
            itemID: "item",
            questions: []
        )
        let needApproval = makeSession(
            id: "need-approval",
            status: SessionStatus.waitingForApproval.rawValue,
            pendingApproval: approval
        )
        let needInput = makeSession(
            id: "need-input",
            status: SessionStatus.waitingForInput.rawValue,
            pendingUserInput: inputRequest
        )
        let running = makeSession(id: "running", status: SessionStatus.running.rawValue)
        let waitingWithoutPayload = makeSession(
            id: "waiting-without-payload",
            status: SessionStatus.waitingForInput.rawValue
        )
        let justCompleted = makeSession(id: "completed")
        let pinned = makeSession(id: "pinned")
        let recent = makeSession(id: "recent")
        let duplicatePinned = makeSession(id: "pinned", status: SessionStatus.running.rawValue)
        let now = Date(timeIntervalSince1970: 10_000)

        let sections = SessionListPresentation.sidebarSections(
            sessions: [needApproval, needInput, running, waitingWithoutPayload, justCompleted, pinned, recent, duplicatePinned],
            pinnedIDs: Set(["need-approval", "pinned"]),
            completionObservedAtByID: [justCompleted.id: now.addingTimeInterval(-60)],
            now: now
        )

        XCTAssertEqual(
            sections.map(\.kind),
            [.needYou, .running, .justCompleted, .pinned, .recent]
        )
        XCTAssertEqual(Set(sections.map(\.kind)).count, sections.count)
        XCTAssertEqual(sections.map(\.id), sections.map { $0.kind.rawValue })
        // 等待输入但还没拿到请求载荷的会话也归「待你处理」：三个表面对它的读法必须一致（#683）。
        XCTAssertEqual(sections[0].sessions.map(\.id), ["need-approval", "need-input", "waiting-without-payload"])
        XCTAssertEqual(sections[1].sessions.map(\.id), ["running"])
        XCTAssertEqual(sections[2].sessions.map(\.id), ["completed"])
        XCTAssertEqual(sections[3].sessions.map(\.id), ["pinned"])
        XCTAssertEqual(sections[4].sessions.map(\.id), ["recent"])
        XCTAssertEqual(sections.flatMap(\.sessions).map(\.id), [
            "need-approval", "need-input", "waiting-without-payload", "running", "completed", "pinned", "recent",
        ])
    }

    func testSidebarJustCompletedKeepsFiveAndLetsOverflowContinueIntoPinnedAndRecent() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let completed = (0..<7).map { index in
            makeSession(
                id: "completed-\(index)",
                recencyAt: now.addingTimeInterval(-Double(index))
            )
        }
        // 输入重复 ID 后仍只占一个槽；第 6、7 个完成候选不能被静默吞掉。
        let sessions = completed + [completed[2]]
        let sections = SessionListPresentation.sidebarSections(
            sessions,
            pinnedIDs: [completed[5].id],
            completionObservedAtByID: Dictionary(
                uniqueKeysWithValues: completed.map { ($0.id, now.addingTimeInterval(-60)) }
            ),
            now: now
        )

        let justCompleted = try XCTUnwrap(sections.first { $0.kind == .justCompleted })
        let pinned = try XCTUnwrap(sections.first { $0.kind == .pinned })
        let recent = try XCTUnwrap(sections.first { $0.kind == .recent })
        XCTAssertEqual(justCompleted.sessions.map(\.id), (0..<5).map { "completed-\($0)" })
        XCTAssertEqual(justCompleted.overflowCount, 0)
        XCTAssertEqual(pinned.sessions.map(\.id), ["completed-5"])
        XCTAssertEqual(recent.sessions.map(\.id), ["completed-6"])
        XCTAssertTrue(sections.allSatisfy { $0.overflowCount == 0 })
    }

    func testSidebarJustCompletedUsesTwoHourWindowBoundaryAndOldTasksBecomeRecent() throws {
        let now = Date(timeIntervalSince1970: 20_000)
        let inside = makeSession(
            id: "inside-window",
            recencyAt: now.addingTimeInterval(-60)
        )
        let atBoundary = makeSession(
            id: "at-boundary",
            recencyAt: now.addingTimeInterval(-120)
        )
        let outside = makeSession(
            id: "outside-window",
            recencyAt: now.addingTimeInterval(-180)
        )
        let completionObservedAtByID: [SessionID: Date] = [
            inside.id: now.addingTimeInterval(-60 * 60),
            atBoundary.id: now.addingTimeInterval(-2 * 60 * 60),
            outside.id: now.addingTimeInterval(-(2 * 60 * 60 + 1)),
        ]

        let sections = SessionListPresentation.sidebarSections(
            [inside, atBoundary, outside],
            completionObservedAtByID: completionObservedAtByID,
            now: now,
            justCompletedWindow: 2 * 60 * 60
        )

        let justCompleted = try XCTUnwrap(sections.first { $0.kind == .justCompleted })
        let recent = try XCTUnwrap(sections.first { $0.kind == .recent })
        XCTAssertEqual(justCompleted.sessions.map(\.id), [inside.id, atBoundary.id])
        XCTAssertEqual(recent.sessions.map(\.id), [outside.id])
    }

    func testSidebarJustCompletedRanksByObservedCompletionTimeNotSessionRecency() throws {
        let now = Date(timeIntervalSince1970: 30_000)
        // 活动时间故意反向：较新的完成观察对应较旧的会话 recency，避免排序规则被混淆。
        let olderSession = makeSession(
            id: "older-session",
            recencyAt: now.addingTimeInterval(-60)
        )
        let newerCompletion = makeSession(
            id: "newer-completion",
            recencyAt: now.addingTimeInterval(-600)
        )
        let oldestCompletion = makeSession(
            id: "oldest-completion",
            recencyAt: now.addingTimeInterval(-1)
        )

        let sections = SessionListPresentation.sidebarSections(
            [olderSession, newerCompletion, oldestCompletion],
            completionObservedAtByID: [
                olderSession.id: now.addingTimeInterval(-30 * 60),
                newerCompletion.id: now.addingTimeInterval(-5 * 60),
                oldestCompletion.id: now.addingTimeInterval(-60 * 60),
            ],
            now: now,
            justCompletedLimit: 2
        )

        let justCompleted = try XCTUnwrap(sections.first { $0.kind == .justCompleted })
        XCTAssertEqual(
            justCompleted.sessions.map(\.id),
            [newerCompletion.id, olderSession.id],
            "刚完成候选和输出都应按本地观察时间倒序，而不是复用会话活动时间排序"
        )
        let recent = try XCTUnwrap(sections.first { $0.kind == .recent })
        XCTAssertEqual(recent.sessions.map(\.id), [oldestCompletion.id])
    }

    func testSidebarRecentIsFallbackWhenAllEarlierGroupsAreEmpty() {
        let sessions = (0..<10).map { makeSession(id: "recent-\($0)") }
        let sections = SessionListPresentation.sidebarSections(sessions)

        XCTAssertEqual(sections.map(\.kind), [.recent])
        XCTAssertEqual(sections[0].sessions.map(\.id), (0..<8).map { "recent-\($0)" })
        XCTAssertEqual(sections[0].overflowCount, 0)
    }

    func testSidebarDutyBoardCoversOnlyAttentionRunningAndJustCompleted() {
        XCTAssertEqual(
            SessionSidebarSectionKind.displayOrder.filter(\.isDutyBoard),
            [.needYou, .running, .justCompleted]
        )
        XCTAssertEqual(
            SessionSidebarSectionKind.displayOrder.filter { !$0.isDutyBoard },
            [.pinned, .recent],
            "置顶与最近属于跳转器，降权显示但条数不减（#547）"
        )
    }

    func testSidebarShowsQuietStateOnlyWhenDutyBoardIsEmptyAndRecentHasSessions() {
        let historyOnly = SessionListPresentation.sidebarSections((0..<3).map { makeSession(id: "recent-\($0)") })
        XCTAssertTrue(
            WorkbenchSidebarDutyBoardLayout.showsQuietState(sectionKinds: historyOnly.map(\.kind)),
            "值班表全空时显示「一切安静」，最近照常列出"
        )
        XCTAssertEqual(historyOnly.first?.sessions.count, 3, "静默态不占用最近的条数")

        let withRunning = SessionListPresentation.sidebarSections([
            makeSession(id: "running", status: SessionStatus.running.rawValue),
            makeSession(id: "recent"),
        ])
        XCTAssertFalse(WorkbenchSidebarDutyBoardLayout.showsQuietState(sectionKinds: withRunning.map(\.kind)))

        XCTAssertFalse(
            WorkbenchSidebarDutyBoardLayout.showsQuietState(sectionKinds: []),
            "一条会话都没有时多半还在加载或新配对，不能说「一切安静」"
        )
        XCTAssertFalse(WorkbenchSidebarDutyBoardLayout.showsQuietState(sectionKinds: [.running]))
    }

    func testSidebarDividerSitsAboveFirstJumpListSection() {
        XCTAssertEqual(
            WorkbenchSidebarDutyBoardLayout.dividerKind(sectionKinds: [.needYou, .running, .pinned, .recent]),
            .pinned
        )
        XCTAssertEqual(WorkbenchSidebarDutyBoardLayout.dividerKind(sectionKinds: [.justCompleted, .recent]), .recent)
        XCTAssertEqual(
            WorkbenchSidebarDutyBoardLayout.dividerKind(sectionKinds: [.recent]),
            .recent,
            "值班表全空时细线分开「一切安静」与最近"
        )
        XCTAssertNil(
            WorkbenchSidebarDutyBoardLayout.dividerKind(sectionKinds: [.needYou, .running]),
            "没有跳转器时不画多余的细线"
        )
    }

    func testSidebarUsesOneProjectAvatarForAdjacentSessions() {
        let first = makeSession(id: "project-a-first", projectID: "project-a")
        let adjacentSameProject = makeSession(id: "project-a-second", projectID: "project-a")
        let differentProject = makeSession(id: "project-b", projectID: "project-b")
        let separatedSameProject = makeSession(id: "project-a-third", projectID: "project-a")
        let missingProject = makeSession(id: "missing-project", projectID: "")

        XCTAssertTrue(
            SessionListPresentation.startsSidebarProjectGroup(
                for: first,
                previousSession: nil
            )
        )
        XCTAssertFalse(
            SessionListPresentation.startsSidebarProjectGroup(
                for: adjacentSameProject,
                previousSession: first
            ),
            "各分区的相邻同项目会话都只在第一行展示头像"
        )
        XCTAssertTrue(
            SessionListPresentation.startsSidebarProjectGroup(
                for: differentProject,
                previousSession: adjacentSameProject
            )
        )
        XCTAssertTrue(
            SessionListPresentation.startsSidebarProjectGroup(
                for: separatedSameProject,
                previousSession: differentProject
            ),
            "同项目被其他项目隔开后要重新展示头像"
        )
        XCTAssertTrue(
            SessionListPresentation.startsSidebarProjectGroup(
                for: missingProject,
                previousSession: missingProject
            ),
            "缺少项目 ID 时不能把未知会话误合并"
        )
    }

    func testSidebarKeepsLocalDraftInRunningSection() throws {
        let localDraft = makeSession(
            id: "local-draft",
            status: "draft",
            source: "local"
        )
        let recentSessions = (0..<10).map { makeSession(id: "recent-\($0)") }

        let sections = SessionListPresentation.sidebarSections([localDraft] + recentSessions)
        let running = try XCTUnwrap(sections.first { $0.kind == .running })
        let recent = try XCTUnwrap(sections.first { $0.kind == .recent })

        XCTAssertEqual(running.sessions.map(\.id), [localDraft.id])
        XCTAssertFalse(recent.sessions.contains { $0.id == localDraft.id })
    }

    func testSidebarDynamicSectionsIgnorePinnedFirstStoreOrder() throws {
        let olderPinned = makeSession(
            id: "older-pinned-running",
            status: SessionStatus.running.rawValue,
            recencyAt: Date(timeIntervalSince1970: 100)
        )
        let newer = makeSession(
            id: "newer-running",
            status: SessionStatus.running.rawValue,
            recencyAt: Date(timeIntervalSince1970: 200)
        )

        // 模拟 sortedAllSessions 的置顶优先输入；动态分区仍须恢复为纯时间倒序。
        let sections = SessionListPresentation.sidebarSections(
            [olderPinned, newer],
            pinnedIDs: [olderPinned.id]
        )
        let running = try XCTUnwrap(sections.first { $0.kind == .running })

        XCTAssertEqual(running.sessions.map(\.id), [newer.id, olderPinned.id])
    }

    func testDirectoryTailPrefersDirFallsBackToProjectAndHandlesTrailingSlashes() {
        XCTAssertEqual(
            SessionListPresentation.directoryTail(
                for: makeSession(id: "dir", project: "Fallback", dir: "/Users/me/project///")
            ),
            "project"
        )
        XCTAssertEqual(
            SessionListPresentation.directoryTail(
                for: makeSession(id: "trimmed-dir", project: "Fallback", dir: " /Users/me/project///  ")
            ),
            "project"
        )
        XCTAssertEqual(
            SessionListPresentation.directoryTail(
                for: makeSession(id: "project", project: "Fallback", dir: "")
            ),
            "Fallback"
        )
        XCTAssertEqual(
            SessionListPresentation.directoryTail(
                for: makeSession(id: "root", project: "Fallback", dir: "/")
            ),
            "/"
        )
        XCTAssertEqual(
            SessionListPresentation.directoryTail(
                for: makeSession(id: "empty", project: "", dir: "")
            ),
            ""
        )
    }

    func testTableDensityFallsBackAtAccessibilitySizes() {
        XCTAssertEqual(
            SessionIndexRowDensity.resolved(prefersTable: true, dynamicTypeSize: .large),
            .table
        )
        XCTAssertEqual(
            SessionIndexRowDensity.resolved(prefersTable: true, dynamicTypeSize: .accessibility3),
            .compact
        )
        XCTAssertEqual(
            SessionIndexRowDensity.resolved(prefersTable: false, dynamicTypeSize: .large),
            .compact
        )
    }

    func testSessionRowAccessibilityValueKeepsHiddenStatusAndUnreadSemantics() {
        let completed = AgentSessionDisplayStatus(
            title: "Completed",
            systemImage: "checkmark.circle",
            tone: .complete,
            showsSpinner: false
        )
        let active = AgentSessionDisplayStatus(
            title: "Running",
            systemImage: "circle",
            tone: .active,
            showsSpinner: false
        )

        XCTAssertEqual(
            SessionIndexRow.accessibilityValue(
                status: completed,
                sessionStatus: SessionStatus.completed.rawValue,
                isUnread: true,
                showsNeutralHistoryStatus: false
            ),
            "Completed, \(L10n.text("ui.unread_result"))"
        )
        XCTAssertEqual(
            SessionIndexRow.accessibilityValue(
                status: active,
                sessionStatus: SessionStatus.running.rawValue,
                isUnread: false,
                showsNeutralHistoryStatus: false
            ),
            ""
        )
        XCTAssertEqual(
            SessionIndexRow.accessibilityValue(
                status: completed,
                sessionStatus: SessionStatus.completed.rawValue,
                isUnread: false,
                showsNeutralHistoryStatus: false,
                identity: "Branch main"
            ),
            "Completed, Branch main"
        )
        XCTAssertEqual(
            SessionIndexRow.accessibilityValue(
                status: active,
                sessionStatus: SessionStatus.running.rawValue,
                isUnread: true,
                showsNeutralHistoryStatus: false,
                statusIsVisible: false,
                runtime: "Codex",
                identity: "Project example"
            ),
            "Codex, Running, \(L10n.text("ui.unread_result")), Project example"
        )
    }

    func testSessionRowStateResolutionUsesStatusPriorityBeforeUnread() {
        let cases: [(
            name: String,
            tone: AgentSessionStatusTone,
            isUnread: Bool,
            expected: SessionRowState?
        )] = [
            ("danger", .danger, true, .failed),
            ("warning", .warning, true, .waiting),
            ("active", .active, false, .running),
            ("complete-unread", .complete, true, .unread),
            ("complete-read", .complete, false, nil),
            ("neutral-unread", .neutral, true, .unread),
            ("neutral-read", .neutral, false, nil),
            // 运行中与未读同时存在时，前导槽必须保留运行中状态。
            ("active-unread", .active, true, .running),
        ]

        for testCase in cases {
            let status = AgentSessionDisplayStatus(
                title: testCase.name,
                systemImage: "circle",
                tone: testCase.tone,
                showsSpinner: false
            )

            XCTAssertEqual(
                SessionRowState.resolve(status: status, isUnread: testCase.isUnread),
                testCase.expected,
                testCase.name
            )
        }
    }

    func testRunningStateAnimationHonorsReduceMotion() {
        XCTAssertTrue(SessionRowStateGlyph.shouldAnimate(state: .running, reduceMotion: false))
        XCTAssertFalse(SessionRowStateGlyph.shouldAnimate(state: .running, reduceMotion: true))
        XCTAssertFalse(SessionRowStateGlyph.shouldAnimate(state: .unread, reduceMotion: false))
    }

    func testRunningStateAnimationUsesOneStableTimeDerivedRotation() {
        let quarterCycle = Date(
            timeIntervalSinceReferenceDate: SessionRowStateGlyph.runningCycleDuration / 4
        )

        // 重复出现只会读取同一个时间角度，不会像 repeatForever 那样累计动画事务。
        for _ in 0 ..< 20 {
            XCTAssertEqual(
                SessionRowStateGlyph.runningRotation(at: quarterCycle, animates: true),
                90,
                accuracy: 0.001
            )
        }

        XCTAssertEqual(
            SessionRowStateGlyph.runningRotation(
                at: Date(timeIntervalSinceReferenceDate: SessionRowStateGlyph.runningCycleDuration),
                animates: true
            ),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            SessionRowStateGlyph.runningRotation(at: quarterCycle, animates: false),
            0
        )
    }

    /// 被电脑上的 Codex 占着时不能和普通历史一样省略状态：用户会以为会话已结束且能直接继续。
    /// 也不能归到进行中：共享 App Server 看不到另一个实例里的回合。
    func testSessionHeldElsewhereShowsItsOwnStatusInsteadOfHistory() {
        var session = makeSession(id: "held")
        let history = session.displayStatus(foregroundActivity: nil)
        XCTAssertEqual(history.title, L10n.text("ui.history"))
        // 行内省略的状态才交给 VoiceOver，所以这里能反映状态是否显示在行内。
        func hiddenStatusAnnouncement(_ status: AgentSessionDisplayStatus) -> String {
            SessionIndexRow.accessibilityValue(
                status: status,
                sessionStatus: session.status,
                isUnread: false,
                showsNeutralHistoryStatus: false
            )
        }
        XCTAssertEqual(hiddenStatusAnnouncement(history), history.title, "普通历史默认省略")

        session.writerHeldElsewhere = true
        let held = session.displayStatus(foregroundActivity: nil)
        XCTAssertEqual(held.title, L10n.text("ui.session_open_on_computer"))
        XCTAssertEqual(held.tone, .neutral)
        XCTAssertFalse(held.showsSpinner)
        XCTAssertEqual(hiddenStatusAnnouncement(held), "", "占用状态必须显示在行内")
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.activityState, .idle)

        session.writerHeldElsewhere = false
        XCTAssertEqual(session.displayStatus(foregroundActivity: nil).title, L10n.text("ui.history"))

        // 真正在这边跑的回合优先：标记滞后时不能把进行中的会话说成“电脑上已打开”。
        session.writerHeldElsewhere = true
        session.status = SessionStatus.running.rawValue
        XCTAssertEqual(session.displayStatus(foregroundActivity: nil).title, L10n.text("ui.running"))
    }

    func testNoHostConfiguredTakesPriorityOverLoadingConnectingAndFailureStates() {
        let states: [SessionListPresentationState] = [
            SessionListPresentationState.resolve(
                hasNoConfiguredHost: true,
                hasVisibleSessions: true,
                hasOpenedWorkspace: true,
                isLoading: true,
                isSearching: true,
                isFiltering: true,
                isNetworkUnavailable: true,
                errorMessage: "boom",
                connectionStatus: .failed("offline"),
                hasLoadedWorkspaceCatalog: false,
                isEstablishingConnection: true,
                awaitsInitialSessionLibrary: true
            ),
            SessionListPresentationState.resolve(
                hasNoConfiguredHost: true,
                hasVisibleSessions: false,
                hasOpenedWorkspace: false,
                isLoading: false,
                isSearching: false,
                isFiltering: false,
                isNetworkUnavailable: false,
                errorMessage: nil,
                connectionStatus: .idle
            ),
        ]

        for state in states {
            XCTAssertEqual(state, .noHostConfigured)
            XCTAssertFalse(state.showsInPlaceConnectionProgress)
            XCTAssertFalse(state.showsCenteredLoading)
        }

        // 已配对（hasNoConfiguredHost == false）仍按原优先级呈现加载与错误态。
        XCTAssertEqual(
            SessionListPresentationState.resolve(
                hasNoConfiguredHost: false,
                hasVisibleSessions: false,
                hasOpenedWorkspace: false,
                isLoading: false,
                isSearching: false,
                isFiltering: false,
                isNetworkUnavailable: false,
                errorMessage: nil,
                connectionStatus: .idle,
                hasLoadedWorkspaceCatalog: false
            ),
            .loading
        )
        XCTAssertEqual(
            SessionListPresentationState.resolve(
                hasNoConfiguredHost: false,
                hasVisibleSessions: false,
                hasOpenedWorkspace: false,
                isLoading: false,
                isSearching: false,
                isFiltering: false,
                isNetworkUnavailable: false,
                errorMessage: nil,
                connectionStatus: .failed("offline")
            ),
            .runtimeUnavailable("offline")
        )
    }

    @MainActor
    func testHasNoConfiguredHostPredicateDistinguishesEmptyFromKeychainRecoveryAndLegacyStates() async throws {
        // 1. 全新启动（0 档案、无 Keychain 项、无旧凭据）→ hasNoConfiguredHost == true。
        let freshStore = makeIsolatedAppStore()
        XCTAssertTrue(freshStore.hasLoadedLocalHostState)
        XCTAssertTrue(freshStore.hasNoConfiguredHost)
        XCTAssertFalse(freshStore.hasKeychainRecoveryPath)
        XCTAssertFalse(freshStore.hasValidLegacySingleHostCredential)

        freshStore.suspendCredentialsForBackground()
        XCTAssertFalse(freshStore.isCredentialMemorySuspended)
        try await freshStore.restoreCredentialsForForeground()
        _ = try await freshStore.commitConnectionSettings(
            PreparedConnectionSettings(endpoint: "http://paired.local:8787", token: "paired-token")
        )
        XCTAssertNotNil(freshStore.authenticatedCredentialFingerprint)

        // 2. 无 Keychain entitlement 且 0 档案 → 视为无主机，不误判为锁屏待恢复。
        let missingEntitlementSuite = "SessionListPresentationTests.MissingEntitlement.\(UUID().uuidString)"
        let missingEntitlementDefaults = try XCTUnwrap(UserDefaults(suiteName: missingEntitlementSuite))
        missingEntitlementDefaults.removePersistentDomain(forName: missingEntitlementSuite)
        addTeardownBlock { missingEntitlementDefaults.removePersistentDomain(forName: missingEntitlementSuite) }
        let missingEntitlementStore = AppStore(
            defaults: missingEntitlementDefaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations(forcedCopyStatus: errSecMissingEntitlement)),
            prefersLocalConnection: false
        )
        XCTAssertTrue(missingEntitlementStore.hasNoConfiguredHost)
        XCTAssertFalse(missingEntitlementStore.hasPendingKeychainRecovery)

        // 3. 冷启动 Keychain 锁屏（errSecInteractionNotAllowed）且 0 档案 → 存在恢复路径，不得判定为无主机空态。
        let lockedLegacySuite = "SessionListPresentationTests.LockedLegacy.\(UUID().uuidString)"
        let lockedLegacyDefaults = try XCTUnwrap(UserDefaults(suiteName: lockedLegacySuite))
        lockedLegacyDefaults.removePersistentDomain(forName: lockedLegacySuite)
        addTeardownBlock { lockedLegacyDefaults.removePersistentDomain(forName: lockedLegacySuite) }
        let lockedLegacyKeychain = TestKeychainOperations(forcedCopyStatus: errSecInteractionNotAllowed)
        let lockedLegacyStore = AppStore(
            defaults: lockedLegacyDefaults,
            tokenStore: TokenStore(keychain: lockedLegacyKeychain),
            prefersLocalConnection: false
        )
        XCTAssertTrue(lockedLegacyStore.hasPendingKeychainRecovery)
        XCTAssertTrue(lockedLegacyStore.hasKeychainRecoveryPath)
        XCTAssertFalse(lockedLegacyStore.hasNoConfiguredHost)
        // 解锁后确认 Keychain 为空，恢复完成后才转为无主机空态。
        lockedLegacyKeychain.forcedCopyStatus = nil
        try await lockedLegacyStore.restoreCredentialsForForeground()
        XCTAssertFalse(lockedLegacyStore.hasPendingKeychainRecovery)
        XCTAssertTrue(lockedLegacyStore.hasNoConfiguredHost)

        // 4. 旧版单主机迁移失败（0 档案但内存有有效 endpoint + token）→ 不是无主机；切前后台仍保留恢复路径。
        let legacySuite = "SessionListPresentationTests.Legacy.\(UUID().uuidString)"
        let legacyDefaults = try XCTUnwrap(UserDefaults(suiteName: legacySuite))
        legacyDefaults.removePersistentDomain(forName: legacySuite)
        addTeardownBlock { legacyDefaults.removePersistentDomain(forName: legacySuite) }
        let legacyKeychain = TestKeychainOperations(
            itemData: Data("legacy-token".utf8),
            forcedAddStatus: errSecAuthFailed
        )
        let legacyStore = AppStore(
            defaults: legacyDefaults,
            tokenStore: TokenStore(keychain: legacyKeychain),
            prefersLocalConnection: false
        )
        XCTAssertTrue(legacyStore.connectionProfiles.isEmpty)
        XCTAssertTrue(legacyStore.hasValidLegacySingleHostCredential)
        XCTAssertFalse(legacyStore.hasNoConfiguredHost)
        legacyStore.suspendCredentialsForBackground()
        XCTAssertTrue(legacyStore.isCredentialMemorySuspended)
        XCTAssertTrue(legacyStore.hasPendingKeychainRecovery)
        XCTAssertFalse(legacyStore.hasNoConfiguredHost)
        XCTAssertTrue(legacyStore.canEnterWorkbench)
        try await legacyStore.restoreCredentialsForForeground()
        XCTAssertEqual(legacyStore.token, "legacy-token")
        XCTAssertFalse(legacyStore.hasNoConfiguredHost)

        // 5. 已保存单台电脑：前后台清空内存凭据、前台恢复遇锁屏失败、重连/凭据失效均不得进入无主机空态；
        //    唯有清空最后一台电脑后才进入无主机空态。
        let pairedSuite = "SessionListPresentationTests.Paired.\(UUID().uuidString)"
        let pairedDefaults = try XCTUnwrap(UserDefaults(suiteName: pairedSuite))
        pairedDefaults.removePersistentDomain(forName: pairedSuite)
        addTeardownBlock { pairedDefaults.removePersistentDomain(forName: pairedSuite) }
        let pairedKeychain = TestKeychainOperations()
        let pairedStore = AppStore(
            defaults: pairedDefaults,
            tokenStore: TokenStore(keychain: pairedKeychain),
            prefersLocalConnection: false
        )
        _ = try await pairedStore.commitConnectionSettings(
            PreparedConnectionSettings(endpoint: "http://host-one.local:8787", token: "token-1")
        )
        XCTAssertFalse(pairedStore.hasNoConfiguredHost)

        pairedStore.suspendCredentialsForBackground()
        XCTAssertFalse(pairedStore.isConfigured)
        XCTAssertFalse(pairedStore.hasNoConfiguredHost, "切后台临时清空内存 token 不得误判为无主机空态")

        pairedKeychain.forcedCopyStatus = errSecInteractionNotAllowed
        do {
            try await pairedStore.restoreCredentialsForForeground()
            XCTFail("锁屏状态下前台恢复应抛出 Keychain 错误")
        } catch {}
        XCTAssertTrue(pairedStore.hasPendingKeychainRecovery)
        XCTAssertFalse(pairedStore.hasNoConfiguredHost, "Keychain 锁屏恢复失败不得误判为无主机空态")

        pairedKeychain.forcedCopyStatus = nil
        try await pairedStore.restoreCredentialsForForeground()
        pairedStore.markCredentialsInvalid()
        XCTAssertTrue(pairedStore.requiresRePairing)
        XCTAssertFalse(pairedStore.hasNoConfiguredHost, "凭据失效重连态不得误判为无主机空态")

        // 6. 冷启动存在已保存档案但 Keychain 锁屏 → 保留已保存档案恢复路径，hasNoConfiguredHost == false。
        pairedKeychain.forcedCopyStatus = errSecInteractionNotAllowed
        let relaunchedLockedStore = AppStore(
            defaults: pairedDefaults,
            tokenStore: TokenStore(keychain: pairedKeychain),
            prefersLocalConnection: false
        )
        XCTAssertEqual(relaunchedLockedStore.connectionProfiles.count, 1)
        XCTAssertNil(relaunchedLockedStore.activeConnectionProfileID)
        XCTAssertTrue(relaunchedLockedStore.hasPendingKeychainRecovery)
        XCTAssertFalse(relaunchedLockedStore.hasNoConfiguredHost)
        pairedKeychain.forcedCopyStatus = nil

        // 7. 两台电脑删除当前电脑 → 仍剩 1 台已保存电脑，hasNoConfiguredHost == false；删空最后一台 → true。
        _ = try await pairedStore.commitConnectionSettings(
            PreparedConnectionSettings(
                endpoint: "http://host-two.local:8787",
                token: "token-2",
                profileTarget: .newProfile(id: "host-two", displayName: "Host Two")
            )
        )
        XCTAssertEqual(pairedStore.connectionProfiles.count, 2)
        try await pairedStore.clearPairing()
        XCTAssertEqual(pairedStore.connectionProfiles.count, 1)
        XCTAssertFalse(pairedStore.hasNoConfiguredHost)

        if let remainingID = pairedStore.connectionProfiles.first?.id {
            try await pairedStore.deleteConnectionProfile(id: remainingID)
        }
        XCTAssertTrue(pairedStore.connectionProfiles.isEmpty)
        XCTAssertTrue(pairedStore.hasNoConfiguredHost)

        let inactiveID = try XCTUnwrap(relaunchedLockedStore.connectionProfiles.first?.id)
        try await relaunchedLockedStore.deleteConnectionProfile(id: inactiveID)
        XCTAssertTrue(relaunchedLockedStore.hasNoConfiguredHost)
    }

    @MainActor
    func testNoHostEmptyStatesIssueZeroBackgroundRequestsAndStopAfterClearingLastHost() async throws {
        let suiteName = "SessionListPresentationTests.ZeroRequests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        let appStore = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations()),
            prefersLocalConnection: false
        )
        XCTAssertTrue(appStore.hasNoConfiguredHost)

        let probeGate = PreparedConnectionGate()
        let client = NoHostCountingSessionClient(firstProbeGate: probeGate)
        let sessionStore = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: RecentWorkspaceStore(defaults: defaults),
            clientFactory: { client }
        )
        let themeStore = ThemeStore(defaults: defaults)

        try await hostViewBriefly(
            NavigationStack {
                SessionListView(onConnectComputer: {})
            }
            .environmentObject(appStore)
            .environmentObject(sessionStore)
            .environmentObject(themeStore)
        )
        XCTAssertEqual(client.requestCount, 0, "SessionListView 在无主机空态不应发起任何后台请求")

        try await hostViewBriefly(
            WorkspaceRootView(
                selectedSessionRuntime: .constant(.codex),
                onStartSession: { _, _ in },
                onConnectComputer: {},
                embedsNavigationStack: false
            )
            .environmentObject(appStore)
            .environmentObject(sessionStore)
            .environmentObject(themeStore)
        )
        XCTAssertEqual(client.requestCount, 0, "WorkspaceRootView 在无主机空态不应发起任何后台请求")

        try await hostViewBriefly(
            ProjectSidebarView(showsSessions: true, onConnectComputer: {})
                .environmentObject(sessionStore)
                .environmentObject(themeStore)
        )
        XCTAssertEqual(client.requestCount, 0, "ProjectSidebarView 在无主机空态不应发起任何后台请求")

        let hostStatusStore = HostStatusStore()
        hostStatusStore.refreshIfNeeded(appStore: appStore, sessionStore: sessionStore)
        await hostStatusStore.waitForRefreshForTesting()
        XCTAssertTrue(hostStatusStore.statusesByProfileID.isEmpty)

        // 先配对一台电脑再删空最后一台：切回无主机空态后三处入口仍必须保持零请求。
        _ = try await appStore.commitConnectionSettings(
            PreparedConnectionSettings(endpoint: "http://paired.local:8787", token: "paired-token")
        )
        XCTAssertFalse(appStore.hasNoConfiguredHost)
        let probing = Task { await sessionStore.refreshAppServerModelOptions() }
        await probeGate.waitUntilStarted()
        try await sessionStore.clearCurrentConnectionProfile()
        XCTAssertTrue(appStore.hasNoConfiguredHost)
        client.resetCount()
        await probeGate.release()
        await probing.value
        XCTAssertEqual(client.requestCount, 0, "已退役的客户端不可继续探测其他运行时")

        sessionStore.sidebarProjects = [
            AgentProject(id: "cached", name: "Cached", path: "/workspace/cached")
        ]

        try await hostViewBriefly(
            VStack(spacing: 0) {
                SessionListView(onConnectComputer: {})
                WorkspaceRootView(
                    selectedSessionRuntime: .constant(.codex),
                    onStartSession: { _, _ in },
                    onConnectComputer: {},
                    embedsNavigationStack: false
                )
                ProjectSidebarView(showsSessions: false, onConnectComputer: {})
            }
            .environmentObject(appStore)
            .environmentObject(sessionStore)
            .environmentObject(themeStore)
        )
        XCTAssertEqual(client.requestCount, 0, "删空最后一台电脑进入无主机空态后不得再发后台请求")
    }

    @MainActor
    func testRetiringHostCancelsItsInFlightConfigurationRequest() async {
        let started = expectation(description: "configuration request started")
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://paired.local:8787", token: "fixture",
            configProvider: {
                started.fulfill()
                try await Task.sleep(for: .seconds(3))
                throw MockError.unimplemented
            }
        )
        let bundle = AppServerRuntimeBundle(codexRuntime: runtime, claudeRuntime: runtime)
        let request = Task { try await bundle.readConfiguration() }
        await fulfillment(of: [started], timeout: 2)
        await bundle.shutdownForHostSwitch()
        do {
            _ = try await request.value
            XCTFail("退役主机的配置请求应被取消")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    @MainActor
    func testPairedNeedsWorkspacePreservesSuggestionsAndAllowsOpeningEmptyAuthorizedRoot() async throws {
        let suiteName = "SessionListPresentationTests.PairedEmptyRoot.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        let appStore = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations()),
            prefersLocalConnection: false
        )
        _ = try await appStore.commitConnectionSettings(
            PreparedConnectionSettings(endpoint: "http://paired-root.local:8787", token: "paired-root-token")
        )
        appStore.connectionStatus = .connected("ok")
        XCTAssertFalse(appStore.hasNoConfiguredHost)

        let emptyRootPath = "/Users/me/empty-authorized-root"
        let resolvedEmptyRoot = AgentWorkspace(
            id: "ws-empty-root",
            name: "empty-authorized-root",
            path: emptyRootPath,
            rootProjectID: "ws-empty-root",
            rootProjectName: "empty-authorized-root",
            rootProjectPath: emptyRootPath,
            lastOpenedAt: Date()
        )
        let client = NoHostCountingSessionClient(
            directoryListResponse: DirectoryListResponse(
                path: emptyRootPath,
                parentPath: nil,
                entries: [],
                truncated: false
            ),
            resolvedWorkspace: resolvedEmptyRoot
        )
        let sessionStore = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            recentWorkspaceStore: RecentWorkspaceStore(defaults: defaults),
            clientFactory: { client }
        )

        // 已配对但未打开工作区时保持 .needsWorkspace（不会落入 .noHostConfigured）。
        let presentationState = SessionListPresentationState.resolve(
            hasNoConfiguredHost: appStore.hasNoConfiguredHost,
            hasVisibleSessions: false,
            hasOpenedWorkspace: !sessionStore.sidebarProjects.isEmpty,
            isLoading: false,
            isSearching: false,
            isFiltering: false,
            isNetworkUnavailable: false,
            errorMessage: nil,
            connectionStatus: appStore.connectionStatus,
            hasLoadedWorkspaceCatalog: true
        )
        XCTAssertEqual(presentationState, .needsWorkspace)

        // 即使授权根目录没有任何子目录（entries == []），仍允许通过 OpenWorkspaceSheetModel 直接打开根目录本身。
        let model = OpenWorkspaceSheetModel()
        model.attach(sessionStore: sessionStore)
        await model.startInitialBrowseIfNeeded()
        XCTAssertEqual(model.browsePath, emptyRootPath)
        XCTAssertTrue(model.browseEntries.isEmpty)

        let openedID = await model.openCurrentBrowsePath()
        XCTAssertEqual(openedID, resolvedEmptyRoot.id)
        XCTAssertEqual(sessionStore.sidebarProjects.map(\.path), [emptyRootPath])
    }

    @MainActor
    private func hostViewBriefly<V: View>(_ view: V) async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: view)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 250_000_000)
    }

    private func makeSession(
        id: SessionID,
        projectID: String = "project-id",
        project: String = "Project",
        dir: String = "/tmp/project",
        title: String? = nil,
        preview: String? = nil,
        status: String = SessionStatus.history.rawValue,
        source: String = "codex",
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        recencyAt: Date? = nil,
        pendingApproval: ApprovalSummary? = nil,
        pendingUserInput: AgentUserInputRequest? = nil
    ) -> AgentSession {
        AgentSession(
            id: id,
            projectID: projectID,
            project: project,
            dir: dir,
            title: title ?? id,
            status: status,
            source: source,
            resumeID: nil,
            createdAt: createdAt,
            updatedAt: updatedAt,
            recencyAt: recencyAt,
            preview: preview,
            pendingApproval: pendingApproval,
            pendingUserInput: pendingUserInput
        )
    }

    private func makeCalendar(timeZone identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    private func makeDate(
        _ calendar: Calendar,
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int = 0
    ) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }
}

@MainActor
final class SessionStatusIndicatorSnapshotTests: SimplifiedChineseSnapshotTestCase {
    func testSessionRuntimeIconAndUnreadIndicatorCombinations() {
        let project = AgentProject(
            id: "runtime-indicator-combinations",
            name: "codex-ipad-agent",
            path: "/Users/me/code/codex-ipad-agent"
        )
        let themeStore = makeThemeStore()
        let fixedNow = Date(timeIntervalSince1970: 1_782_879_660)
        let scenarios: [(source: String, isUnread: Bool)] = [
            ("codex", true),
            ("codex", false),
            ("claude", true),
            ("claude", false),
        ]
        let appearances: [(name: String, colorScheme: ColorScheme)] = [
            ("light", .light),
            ("dark", .dark),
        ]

        for appearance in appearances {
            let view = VStack(spacing: 4) {
                ForEach(Array(scenarios.enumerated()), id: \.offset) { index, scenario in
                    self.makeRow(
                        session: self.makeSession(
                            id: "indicator-\(index)",
                            project: project,
                            title: "来源图标与未读状态组合 \(index + 1)",
                            status: SessionStatus.completed.rawValue,
                            preview: "手机会话行不显示这段摘要",
                            source: scenario.source,
                            recencyAt: fixedNow.addingTimeInterval(TimeInterval(-index * 60))
                        ),
                        isUnread: scenario.isUnread,
                        leadingSlot: .runtimeIcon,
                        currentDate: fixedNow
                    )
                }
            }
            .padding(16)
            .environmentObject(themeStore)
            .environment(\.colorScheme, appearance.colorScheme)
            .background(themeStore.tokens(for: appearance.colorScheme).background)
            .frame(width: 460, height: 330)

            assertSnapshot(
                of: view,
                // 快照覆盖矢量来源标记、小点位置及标题同字重；精确色值由 ThemeStoreTests 断言。
                as: .image(precision: 0.995, layout: .fixed(width: 460, height: 330)),
                named: appearance.name
            )
        }
    }

    func testSessionStateRingSemanticsAndAlignment() {
        let project = AgentProject(
            id: "state-ring-semantics",
            name: "codex-ipad-agent",
            path: "/Users/me/code/codex-ipad-agent"
        )
        let themeStore = makeThemeStore()
        let fixedNow = Date(timeIntervalSince1970: 1_782_879_660)
        let running = makeSession(
            id: "state-ring-running",
            project: project,
            title: "运行中的会话",
            status: SessionStatus.running.rawValue,
            preview: "缺口环表示任务正在运行",
            activeTurnID: "turn-state-ring",
            recencyAt: fixedNow
        )
        let completedUnread = makeSession(
            id: "state-ring-unread",
            project: project,
            title: "已完成但尚未阅读",
            status: SessionStatus.completed.rawValue,
            preview: "仅用小点表示结果未读",
            recencyAt: fixedNow.addingTimeInterval(-60)
        )
        let readHistory = makeSession(
            id: "state-ring-history",
            project: project,
            title: "已经阅读的历史会话",
            status: SessionStatus.history.rawValue,
            preview: "灰色虚线环表示普通历史记录",
            recencyAt: fixedNow.addingTimeInterval(-120)
        )

        let appearances: [(name: String, colorScheme: ColorScheme)] = [
            ("light", .light),
            ("dark", .dark),
        ]

        for appearance in appearances {
            let view = VStack(spacing: 4) {
                makeRow(
                    session: running,
                    leadingSlot: .state,
                    showsIdleStateGlyph: true,
                    currentDate: fixedNow
                )
                makeRow(
                    session: completedUnread,
                    isUnread: true,
                    leadingSlot: .state,
                    showsIdleStateGlyph: true,
                    currentDate: fixedNow
                )
                makeRow(
                    session: readHistory,
                    leadingSlot: .state,
                    showsIdleStateGlyph: true,
                    currentDate: fixedNow
                )
            }
            .padding(16)
            .environmentObject(themeStore)
            .environment(\.colorScheme, appearance.colorScheme)
            // 快照只验证缺口环的静态形状和位置，关闭事务动画以固定渲染帧。
            .transaction { $0.disablesAnimations = true }
            .background(themeStore.tokens(for: appearance.colorScheme).background)
            .frame(width: 460, height: 260)

            assertSnapshot(
                of: view,
                as: .image(precision: 0.98, layout: .fixed(width: 460, height: 260)),
                named: appearance.name
            )
        }
    }

    private func makeRow(
        session: AgentSession,
        isUnread: Bool = false,
        leadingSlot: SessionIndexRowLeadingSlot,
        showsIdleStateGlyph: Bool = false,
        currentDate: Date
    ) -> SessionIndexRow {
        SessionIndexRow(
            session: session,
            foregroundActivity: nil,
            isSelected: false,
            isPinned: false,
            isArchived: false,
            reminder: nil,
            isObserving: false,
            isUnread: isUnread,
            density: .compact,
            leadingSlot: leadingSlot,
            showsIdleStateGlyph: showsIdleStateGlyph,
            currentDate: { currentDate }
        )
    }

    private func makeSession(
        id: SessionID,
        project: AgentProject,
        title: String,
        status: String,
        preview: String,
        source: String = "codex",
        activeTurnID: TurnID? = nil,
        recencyAt: Date
    ) -> AgentSession {
        AgentSession(
            id: id,
            projectID: project.id,
            project: project.name,
            dir: project.path,
            title: title,
            status: status,
            source: source,
            resumeID: "thread-\(id)",
            createdAt: nil,
            updatedAt: nil,
            recencyAt: recencyAt,
            preview: preview,
            activeTurnID: activeTurnID
        )
    }

    private func makeThemeStore() -> ThemeStore {
        let suiteName = "SessionStatusIndicatorSnapshotTests.Theme.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return ThemeStore(defaults: defaults)
    }
}

private final class NoHostCountingSessionClient: SessionStoreAPIClient {
    private let lock = NSLock()
    private var requestCountStorage = 0
    private var didStartProbe = false
    private let firstProbeGate: PreparedConnectionGate?
    private let directoryListResponse: DirectoryListResponse?
    private let resolvedWorkspace: AgentWorkspace?

    init(
        firstProbeGate: PreparedConnectionGate? = nil,
        directoryListResponse: DirectoryListResponse? = nil,
        resolvedWorkspace: AgentWorkspace? = nil
    ) {
        self.firstProbeGate = firstProbeGate
        self.directoryListResponse = directoryListResponse
        self.resolvedWorkspace = resolvedWorkspace
    }

    var requestCount: Int {
        lock.withLock { requestCountStorage }
    }

    func resetCount() {
        lock.withLock { requestCountStorage = 0 }
    }

    private func record() {
        lock.withLock { requestCountStorage += 1 }
    }

    func projects() async throws -> [AgentProject] {
        record()
        return []
    }

    func modelOptions() async throws -> [CodexAppServerModelOption] {
        record()
        return []
    }

    func modelOptions(runtimeProvider: String) async throws -> [CodexAppServerModelOption] {
        record()
        return []
    }

    func runtimeChannelAvailable(runtimeProvider: String) async throws -> Bool {
        record()
        let isFirstProbe = lock.withLock {
            defer { didStartProbe = true }
            return !didStartProbe
        }
        if isFirstProbe, let firstProbeGate {
            await firstProbeGate.wait()
            return true
        }
        return false
    }

    func listDirectories(path: String) async throws -> DirectoryListResponse {
        record()
        if let directoryListResponse {
            return directoryListResponse
        }
        return DirectoryListResponse(path: path, parentPath: nil, entries: [], truncated: false)
    }

    func resolveWorkspace(path: String) async throws -> AgentWorkspace {
        record()
        if let resolvedWorkspace {
            return resolvedWorkspace
        }
        throw MockError.unimplemented
    }

    func gitStatus(path: String) async throws -> GitStatusResponse {
        record()
        throw MockError.unimplemented
    }

    func gitStatusSummary(path: String) async throws -> GitStatusResponse {
        record()
        throw MockError.unimplemented
    }

    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] {
        record()
        return []
    }

    func sessionsPage(projectID: String?, cursor: String?, limit: Int?) async throws -> SessionsPage {
        record()
        return SessionsPage(sessions: [])
    }

    func sessionsPage(workspace: AgentWorkspace, cursor: String?, limit: Int?) async throws -> SessionsPage {
        record()
        return SessionsPage(sessions: [])
    }

    func sessionsPage(
        projectID: String?,
        cursor: String?,
        limit: Int?,
        consistency: SessionListConsistency
    ) async throws -> SessionsPage {
        record()
        return SessionsPage(sessions: [])
    }

    func sessionsPage(
        workspace: AgentWorkspace,
        cursor: String?,
        limit: Int?,
        consistency: SessionListConsistency
    ) async throws -> SessionsPage {
        record()
        return SessionsPage(sessions: [])
    }

    func controlledGlobalSessionsPage(cursor: String?, limit: Int?) async throws -> SessionsPage {
        record()
        return SessionsPage(sessions: [])
    }

    func controlledGlobalSessionsPage(runtimeProvider: String, cursor: String?, limit: Int?) async throws -> SessionsPage {
        record()
        return SessionsPage(sessions: [])
    }

    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        record()
        throw MockError.unimplemented
    }

    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse {
        record()
        throw MockError.unimplemented
    }

    func stopSession(id: String) async throws {
        record()
    }

    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage] {
        record()
        return []
    }

    func refreshRateLimit(sessionID: String?) async throws -> RateLimitSummary? {
        record()
        return nil
    }

    func refreshRateLimit(runtimeProvider: String) async throws -> RateLimitSummary? {
        record()
        return nil
    }

    func refreshAccountTokenUsage() async throws -> AccountTokenUsageFetch {
        record()
        throw MockError.unimplemented
    }

    func refreshAccountTokenUsage(forceRefresh: Bool) async throws -> AccountTokenUsageFetch {
        record()
        throw MockError.unimplemented
    }
}
