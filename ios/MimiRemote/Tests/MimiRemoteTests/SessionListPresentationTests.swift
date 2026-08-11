import Foundation
import SwiftUI
import XCTest
@testable import MimiRemote

final class SessionListPresentationTests: XCTestCase {
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
        XCTAssertEqual(sections[0].sessions.map(\.id), ["need-approval", "need-input"])
        XCTAssertEqual(sections[1].sessions.map(\.id), ["running", "waiting-without-payload"])
        XCTAssertEqual(sections[2].sessions.map(\.id), ["completed"])
        XCTAssertEqual(sections[3].sessions.map(\.id), ["pinned"])
        XCTAssertEqual(sections[4].sessions.map(\.id), ["recent"])
        XCTAssertEqual(sections.flatMap(\.sessions).map(\.id), [
            "need-approval", "need-input", "running", "waiting-without-payload", "completed", "pinned", "recent",
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

    func testSidebarUsesOneGroupHeaderForAdjacentProjectsInRunningAndJustCompleted() {
        let first = makeSession(id: "project-a-first", projectID: "project-a")
        let adjacentSameProject = makeSession(id: "project-a-second", projectID: "project-a")
        let differentProject = makeSession(id: "project-b", projectID: "project-b")
        let separatedSameProject = makeSession(id: "project-a-third", projectID: "project-a")
        let missingProject = makeSession(id: "missing-project", projectID: "")

        XCTAssertTrue(
            SessionListPresentation.startsSidebarProjectGroup(
                for: first,
                previousSession: nil,
                in: .running
            )
        )
        XCTAssertFalse(
            SessionListPresentation.startsSidebarProjectGroup(
                for: adjacentSameProject,
                previousSession: first,
                in: .running
            ),
            "运行中的相邻同项目只在第一行展示菊花和头像"
        )
        XCTAssertFalse(
            SessionListPresentation.startsSidebarProjectGroup(
                for: adjacentSameProject,
                previousSession: first,
                in: .justCompleted
            ),
            "刚完成的相邻同项目也应合并头像"
        )
        XCTAssertTrue(
            SessionListPresentation.startsSidebarProjectGroup(
                for: differentProject,
                previousSession: adjacentSameProject,
                in: .running
            )
        )
        XCTAssertTrue(
            SessionListPresentation.startsSidebarProjectGroup(
                for: separatedSameProject,
                previousSession: differentProject,
                in: .running
            ),
            "同项目被其他项目隔开后要重新展示头像"
        )
        for kind in [
            SessionSidebarSectionKind.needYou,
            .pinned,
            .recent,
        ] {
            XCTAssertTrue(
                SessionListPresentation.startsSidebarProjectGroup(
                    for: adjacentSameProject,
                    previousSession: first,
                    in: kind
                ),
                "\(kind.rawValue) 不在本次合并范围，仍应逐行展示项目身份"
            )
        }
        XCTAssertTrue(
            SessionListPresentation.startsSidebarProjectGroup(
                for: missingProject,
                previousSession: missingProject,
                in: .running
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

    func testStatusUsesSmallerTypeThanSiblingMetadata() {
        XCTAssertEqual(SessionIndexRowDensity.table.metadataFontSize, 11.5)
        XCTAssertEqual(SessionIndexRowDensity.table.statusFontSize, 10.5)
        XCTAssertEqual(SessionIndexRowDensity.compact.metadataFontSize, 10)
        XCTAssertEqual(SessionIndexRowDensity.compact.statusFontSize, 9)
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
