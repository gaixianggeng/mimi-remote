import XCTest
import Combine
import Security
import SwiftUI
import UIKit
@testable import MimiRemote

/// XCTest 的同步断言不能包裹 async Keychain/Vault 事务；这里确保测试等待 actor 提交完成。
@MainActor
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail(message().isEmpty ? "Expected expression to throw an error." : message(), file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

// 多个测试领域共享的网络、WebSocket、API client 与等待工具。
final class TestNetworkPathStatusSource: NetworkPathStatusSource {
    private(set) var currentStatus: NetworkReachabilityStatus
    var onStatusChange: ((NetworkPathStatusUpdate) -> Void)?
    private var nextSequence: UInt64 = 0

    init(initialStatus: NetworkReachabilityStatus) {
        self.currentStatus = initialStatus
    }

    func start() {}

    func stop() {
        onStatusChange = nil
    }

    func emit(_ status: NetworkReachabilityStatus) {
        currentStatus = status
        nextSequence &+= 1
        onStatusChange?(NetworkPathStatusUpdate(sequence: nextSequence, status: status))
    }

    func deliver(_ status: NetworkReachabilityStatus, sequence: UInt64) {
        // 不改 currentStatus：该入口模拟 monitor 已观察到新状态，但旧 MainActor Task 才刚迟到。
        nextSequence = max(nextSequence, sequence)
        onStatusChange?(NetworkPathStatusUpdate(sequence: sequence, status: status))
    }
}

actor ReconnectDelayRecorder {
    private var delays: [UInt64] = []

    func record(_ delay: UInt64) {
        delays.append(delay)
    }

    func snapshot() -> [UInt64] {
        delays
    }
}

final class MockWebSocketClient: SessionWebSocketClient {
    var turnDeliveryMode: TurnDeliveryMode = .direct
    var onEvent: (@MainActor (AgentEvent) -> Void)?
    var onStatus: ((WebSocketStatus) -> Void)?
    var onSendAccepted: ((ClientMessageID?) -> Void)?
    var onSendFailure: ((ClientMessageID?, String) -> Void)?
    var onTurnSendOutcome: ((ClientMessageID?, TurnSendOutcome) -> Void)?
    var onApprovalDecisionFailure: ((String, String) -> Void)?
    var onUserInputResponseFailure: ((String, String) -> Void)?
    var onControlFailure: ((String) -> Void)?

    private(set) var connectedSessionIDs: [SessionID] = []
    private(set) var replayBufferedEventsByConnect: [Bool] = []
    private(set) var sentInputs: [(text: String, clientMessageID: ClientMessageID?)] = []
    private(set) var sentTurns: [(payload: CodexAppServerTurnPayload, clientMessageID: ClientMessageID?)] = []
    private(set) var sentGuidance: [(payload: CodexAppServerTurnPayload, clientMessageID: ClientMessageID?, expectedTurnID: TurnID)] = []
    private(set) var sentCtrlCCount = 0
    private(set) var sentCtrlCTurnIDs: [TurnID] = []
    private(set) var sentApprovals: [(approvalID: String, decision: String, message: String?)] = []
    private(set) var sentUserInputResponses: [(requestID: String, answers: [String: [String]])] = []
    private(set) var disconnectCallCount = 0
    private(set) var acknowledgedEvents: [AgentEvent] = []
    var sendTurnResult = true
    var sendGuidanceResult = true
    var sendCtrlCResult = true

    func connect(sessionID: SessionID) {
        connectedSessionIDs.append(sessionID)
        replayBufferedEventsByConnect.append(true)
        onStatus?(.connecting)
    }

    func connect(sessionID: SessionID, replayBufferedEvents: Bool) {
        connectedSessionIDs.append(sessionID)
        replayBufferedEventsByConnect.append(replayBufferedEvents)
        onStatus?(.connecting)
    }

    func disconnect() {
        disconnectCallCount += 1
        onStatus?(.disconnected)
    }

    func acknowledgeAppliedEvent(_ event: AgentEvent) {
        acknowledgedEvents.append(event)
    }

    func sendInput(_ text: String, clientMessageID: ClientMessageID?) -> Bool {
        sentInputs.append((text, clientMessageID))
        return true
    }

    func sendTurn(_ payload: CodexAppServerTurnPayload, clientMessageID: ClientMessageID?) -> Bool {
        sentTurns.append((payload, clientMessageID))
        return sendTurnResult
    }

    func sendGuidance(_ payload: CodexAppServerTurnPayload, clientMessageID: ClientMessageID?, expectedTurnID: TurnID) -> Bool {
        sentGuidance.append((payload, clientMessageID, expectedTurnID))
        return sendGuidanceResult
    }

    func sendCtrlC(expectedTurnID: TurnID) -> Bool {
        sentCtrlCCount += 1
        sentCtrlCTurnIDs.append(expectedTurnID)
        return sendCtrlCResult
    }

    func sendApprovalDecision(approvalID: String, decision: String, message: String?) -> Bool {
        sentApprovals.append((approvalID, decision, message))
        return true
    }

    func sendUserInputResponse(requestID: String, answers: [String: [String]]) -> Bool {
        sentUserInputResponses.append((requestID, answers))
        return true
    }

    func emitStatus(_ status: WebSocketStatus) {
        onStatus?(status)
    }

    @MainActor
    func emitEvent(_ event: AgentEvent) {
        onEvent?(event)
    }
}

final class DelayedCreateSessionClient: SessionStoreAPIClient {
    let projectsResult: [AgentProject]
    let sessionsResult: [AgentSession]
    private var createContinuations: [CheckedContinuation<CreateSessionResponse, Error>] = []
    private var requestCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    var createPayloads: [CreateSessionRequest] = []
    private(set) var modelOptionsCallCount = 0

    init(projects: [AgentProject], sessions: [AgentSession]) {
        self.projectsResult = projects
        self.sessionsResult = sessions
    }

    func projects() async throws -> [AgentProject] {
        projectsResult
    }

    func modelOptions() async throws -> [CodexAppServerModelOption] {
        modelOptionsCallCount += 1
        return []
    }

    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] {
        sessionsResult
    }

    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        throw MockError.unimplemented
    }

    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse {
        createPayloads.append(payload)
        return try await withCheckedThrowingContinuation { continuation in
            createContinuations.append(continuation)
            notifyRequestCountWaiters()
        }
    }

    func stopSession(id: String) async throws {
        throw MockError.unimplemented
    }

    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage] {
        []
    }

    func waitForCreateRequestCount(_ count: Int) async {
        guard createReadyCount < count else {
            return
        }
        await withCheckedContinuation { continuation in
            guard createReadyCount < count else {
                continuation.resume()
                return
            }
            requestCountWaiters.append((count, continuation))
        }
    }

    func resolveCreate(with result: Result<CreateSessionResponse, Error>, at index: Int = 0) {
        switch result {
        case .success(let response):
            createContinuations[index].resume(returning: response)
        case .failure(let error):
            createContinuations[index].resume(throwing: error)
        }
    }

    private func notifyRequestCountWaiters() {
        var pending: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in requestCountWaiters {
            if createReadyCount >= waiter.0 {
                waiter.1.resume()
            } else {
                pending.append(waiter)
            }
        }
        requestCountWaiters = pending
    }

    private var createReadyCount: Int {
        min(createPayloads.count, createContinuations.count)
    }
}

struct RequestedGitAction: Equatable {
    let path: String
    let action: GitActionKind
    let files: [String]
}

struct RequestedGitPatchAction: Equatable {
    let path: String
    let action: GitActionKind
    let patch: String
}

struct RequestedGitCommit: Equatable {
    let path: String
    let message: String
}

struct RequestedGitPush: Equatable {
    let path: String
    let remote: String?
}

struct RequestedGitPullRequest: Equatable {
    let path: String
    let title: String
    let body: String
    let draft: Bool
}

struct RequestedCommandActionRun: Equatable {
    let path: String
    let id: String
    let confirmed: Bool
}

struct RequestedWorktreeCreate: Equatable {
    let path: String
    let name: String?
    let base: String?
    let branch: String?
}

struct RequestedWorktreeDelete: Equatable {
    let path: String
    let force: Bool
}

struct RequestedSessionArchive: Equatable {
    let id: String
    let archived: Bool
}

struct RequestedSessionFork: Equatable {
    let threadID: String
    let workspaceID: String
    let reason: AgentSessionForkReason
}

struct RequestedThreadName: Equatable {
    let threadID: String
    let name: String
}

struct RequestedThreadGoalSet: Equatable {
    let threadID: String
    let objective: String?
    let status: ThreadGoalStatus?
    let tokenBudget: Int64?
}

struct RequestedSessionReview: Equatable {
    let threadID: String
    let target: CodexAppServerReviewTarget
    let delivery: CodexAppServerReviewDelivery?
}

final class FakeSessionReminderScheduler: SessionReminderScheduling {
    private(set) var scheduled: [SessionReminder] = []
    private(set) var reminderRoutes: [SessionNotificationRoute] = []
    private(set) var runtimeNotifications: [SessionRuntimeNotification] = []
    private(set) var runtimeNotificationRoutes: [SessionNotificationRoute] = []
    private(set) var canceledSessionIDs: [SessionID] = []
    private(set) var canceledProfileIDs: [String] = []
    var scheduleOutcome: SessionReminderScheduleOutcome

    init(scheduleOutcome: SessionReminderScheduleOutcome = .scheduled) {
        self.scheduleOutcome = scheduleOutcome
    }

    func schedule(
        _ reminder: SessionReminder,
        route: SessionNotificationRoute
    ) async throws -> SessionReminderScheduleOutcome {
        scheduled.append(reminder)
        reminderRoutes.append(route)
        return scheduleOutcome
    }

    func notify(
        _ notification: SessionRuntimeNotification,
        route: SessionNotificationRoute
    ) async throws {
        runtimeNotifications.append(notification)
        runtimeNotificationRoutes.append(route)
    }

    func cancel(sessionID: SessionID, profileID: String) {
        canceledSessionIDs.append(sessionID)
    }

    func cancel(profileID: String) {
        canceledProfileIDs.append(profileID)
    }
}

struct ThreadSearchGateRequest: Hashable {
    let query: String
    let cursor: String?
}

final class ThreadSearchResponseGate {
    private let lock = NSLock()
    private var requestsStorage: [ThreadSearchGateRequest] = []
    private var continuations: [ThreadSearchGateRequest: [CheckedContinuation<ThreadSearchPage, Error>]] = [:]

    var queries: [String] {
        lock.withLock { requestsStorage.map(\.query) }
    }

    var requests: [ThreadSearchGateRequest] {
        lock.withLock { requestsStorage }
    }

    func search(query: String, cursor: String? = nil) async throws -> ThreadSearchPage {
        let request = ThreadSearchGateRequest(query: query, cursor: cursor)
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                requestsStorage.append(request)
                continuations[request, default: []].append(continuation)
            }
        }
    }

    func resolve(query: String, cursor: String? = nil, page: ThreadSearchPage) {
        let continuation = takeContinuation(query: query, cursor: cursor)
        continuation?.resume(returning: page)
    }

    func fail(query: String, cursor: String? = nil, error: Error) {
        let continuation = takeContinuation(query: query, cursor: cursor)
        continuation?.resume(throwing: error)
    }

    private func takeContinuation(
        query: String,
        cursor: String?
    ) -> CheckedContinuation<ThreadSearchPage, Error>? {
        let request = ThreadSearchGateRequest(query: query, cursor: cursor)
        return lock.withLock {
            guard var pending = continuations[request], !pending.isEmpty else {
                return nil
            }
            let continuation = pending.removeFirst()
            if pending.isEmpty {
                continuations.removeValue(forKey: request)
            } else {
                continuations[request] = pending
            }
            return continuation
        }
    }
}

final class SessionResponseGate {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SessionResponse, Error>?
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []

    func response() async throws -> SessionResponse {
        try await withCheckedThrowingContinuation { continuation in
            let waiters = lock.withLock {
                self.continuation = continuation
                let waiters = requestWaiters
                requestWaiters.removeAll()
                return waiters
            }
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilRequested() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                guard self.continuation == nil else { return true }
                requestWaiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func resolve(_ response: SessionResponse) {
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(returning: response)
    }
}

final class MockSessionStoreClient: SessionStoreAPIClient {
    private let requestLogLock = NSLock()
    private var requestedProjectIDsStorage: [String?] = []
    private var requestedWorkspaceIDsStorage: [String] = []

    let projectsResult: [AgentProject]
    let projectsHandler: (() async throws -> [AgentProject])?
    let sessionsResult: [AgentSession]
    let sessionHandler: ((String, EventSequence?) async throws -> SessionResponse)?
    let projectSessions: [String: [AgentSession]]
    let workspaceSessions: [String: [AgentSession]]
    let projectPages: [String: SessionsPage]
    let workspacePages: [String: SessionsPage]
    let cursorPages: [String: SessionsPage]
    let createSessionResponse: CreateSessionResponse?
    var createSessionResults: [Result<CreateSessionResponse, Error>]
    let sessionArchiveResults: [String: Result<Void, Error>]
    let sessionArchiveHandler: ((String, Bool) async throws -> Void)?
    let sessionForkResults: [String: Result<AgentSession, Error>]
    let threadGoalSetResults: [String: Result<ThreadGoal, Error>]
    let sessionResponses: [String: SessionResponse]
    let messagesResult: [CodexHistoryMessage]
    let historyPages: [String: HistoryMessagesPage]
    let historyCursorPages: [String: HistoryMessagesPage]
    let workspaceSessionsError: [String: Error]
    let capabilityResults: [String: Result<CapabilityListResponse, Error>]
    let resolveResults: [String: Result<AgentWorkspace, Error>]
    let resolveWorkspaceHandler: ((String) async throws -> AgentWorkspace)?
    let worktreeCreateResults: [String: Result<WorktreeCreateResponse, Error>]
    let worktreeBranchResults: [String: Result<WorktreeBranchListResponse, Error>]
    let worktreeListResult: Result<[WorktreeListItem], Error>?
    let worktreeDeleteResults: [String: Result<WorktreeDeleteResponse, Error>]
    let worktreePruneResult: Result<WorktreePruneResponse, Error>?
    let worktreeCleanupPreviewResult: Result<WorktreeCleanupResponse, Error>?
    let worktreeCleanupExecutionResult: Result<WorktreeCleanupResponse, Error>?
    let directoryListResults: [String: Result<DirectoryListResponse, Error>]
    let fileReadResults: [String: Result<FileReadResponse, Error>]
    let historyMediaResults: [String: Result<FileReadResponse, Error>]
    let historyOutputResults: [String: Result<FileReadResponse, Error>]
    let commandActionResults: [String: Result<[AgentCommandAction], Error>]
    let commandActionRunResults: [String: Result<CommandActionRunResponse, Error>]
    let gitStatusResults: [String: Result<GitStatusResponse, Error>]
    let gitStatusHandler: ((String) async throws -> GitStatusResponse)?
    let gitActionResults: [String: Result<GitStatusResponse, Error>]
    let gitPatchActionResults: [String: Result<GitStatusResponse, Error>]
    let gitCommitResults: [String: Result<GitStatusResponse, Error>]
    let gitPushResults: [String: Result<GitPushResponse, Error>]
    let gitPullRequestResults: [String: Result<GitPullRequestResponse, Error>]
    let gitPullRequestStatusResults: [String: Result<GitPullRequestStatusResponse, Error>]
    let messagesError: Error?
    let modelOptionsResult: [CodexAppServerModelOption]
    let modelOptionsError: Error?
    let runtimeChannelAvailability: [String: Bool]
    let rateLimitsByRuntime: [String: RateLimitSummary]
    let rateLimitHandler: ((String) async throws -> RateLimitSummary?)?
    let controlledGlobalSessionsHandler: ((String?, Int?) async throws -> SessionsPage)?
    let accountTokenUsageHandler: (() async throws -> AccountTokenUsageSnapshot?)?
    /// 需要区分 unsupported / failed 时用这个；它优先于 snapshot 便捷 handler。
    let accountTokenUsageFetchHandler: (() async throws -> AccountTokenUsageFetch)?
    let threadSearchHandler: ((String, String?, Int?) async throws -> ThreadSearchPage)?
    let supportsLatestTurnHistoryPage: Bool
    var requestedProjectIDs: [String?] {
        requestLogLock.withLock { requestedProjectIDsStorage }
    }
    var requestedWorkspaceIDs: [String] {
        requestLogLock.withLock { requestedWorkspaceIDsStorage }
    }
    var requestedThreadSearchQueries: [String] {
        requestLogLock.withLock { requestedThreadSearchQueriesStorage }
    }
    private var requestedThreadSearchQueriesStorage: [String] = []
    var requestedThreadSearchCursors: [String?] {
        requestLogLock.withLock { requestedThreadSearchCursorsStorage }
    }
    private var requestedThreadSearchCursorsStorage: [String?] = []
    var requestedControlledGlobalCursors: [String?] {
        requestLogLock.withLock { requestedControlledGlobalCursorsStorage }
    }
    private var requestedControlledGlobalCursorsStorage: [String?] = []
    var requestedCapabilityPaths: [String?] = []
    var requestedCapabilityForceReloads: [Bool] = []
    var requestedResolvePaths: [String] = []
    var requestedWorktreeCreates: [RequestedWorktreeCreate] = []
    var requestedWorktreeBranchPaths: [String] = []
    var requestedWorktreeDeletes: [RequestedWorktreeDelete] = []
    private(set) var worktreePruneCallCount = 0
    private(set) var worktreeCleanupPreviewCallCount = 0
    private(set) var requestedWorktreeCleanupPaths: [[String]] = []
    private(set) var requestedWorktreeCleanupPlanIDs: [String] = []
    var requestedDirectoryPaths: [String] = []
    var requestedFileReadPaths: [String] = []
    var requestedHistoryMediaIDs: [String] = []
    var requestedHistoryOutputIDs: [String] = []
    var requestedCommandActionPaths: [String] = []
    var requestedCommandActionRuns: [RequestedCommandActionRun] = []
    var requestedGitStatusPaths: [String] = []
    var requestedGitActions: [RequestedGitAction] = []
    var requestedGitPatchActions: [RequestedGitPatchAction] = []
    var requestedGitCommits: [RequestedGitCommit] = []
    var requestedGitPushes: [RequestedGitPush] = []
    var requestedGitPullRequests: [RequestedGitPullRequest] = []
    var requestedGitPullRequestStatusPaths: [String] = []
    var requestedSessionIDs: [String] = []
    var requestedSessionAfterSeqs: [EventSequence?] = []
    var requestedSessionArchives: [RequestedSessionArchive] {
        requestLogLock.withLock { requestedSessionArchivesStorage }
    }
    private var requestedSessionArchivesStorage: [RequestedSessionArchive] = []
    var requestedSessionForks: [RequestedSessionFork] = []
    var requestedThreadNames: [RequestedThreadName] = []
    var requestedThreadGoalSets: [RequestedThreadGoalSet] = []
    var requestedSessionReviews: [RequestedSessionReview] = []
    var requestedMessageSessionIDs: [String] = []
    var requestedMessageCursors: [String?] = []
    var requestedMessageLimits: [Int?] = []
    var createPayloads: [CreateSessionRequest] = []
    private(set) var worktreeListCallCount = 0
    private(set) var modelOptionsCallCount = 0
    private(set) var requestedRateLimitProviders: [String] = []

    init(
        projects: [AgentProject],
        sessions: [AgentSession],
        projectsHandler: (() async throws -> [AgentProject])? = nil,
        projectSessions: [String: [AgentSession]] = [:],
        workspaceSessions: [String: [AgentSession]] = [:],
        projectPages: [String: SessionsPage] = [:],
        workspacePages: [String: SessionsPage] = [:],
        cursorPages: [String: SessionsPage] = [:],
        createSessionResponse: CreateSessionResponse? = nil,
        createSessionResults: [Result<CreateSessionResponse, Error>] = [],
        sessionArchiveResults: [String: Result<Void, Error>] = [:],
        sessionArchiveHandler: ((String, Bool) async throws -> Void)? = nil,
        sessionForkResults: [String: Result<AgentSession, Error>] = [:],
        threadGoalSetResults: [String: Result<ThreadGoal, Error>] = [:],
        sessionResponses: [String: SessionResponse] = [:],
        sessionHandler: ((String, EventSequence?) async throws -> SessionResponse)? = nil,
        messagesResult: [CodexHistoryMessage]? = nil,
        historyPages: [String: HistoryMessagesPage] = [:],
        historyCursorPages: [String: HistoryMessagesPage] = [:],
        workspaceSessionsError: [String: Error] = [:],
        capabilityResults: [String: Result<CapabilityListResponse, Error>] = [:],
        resolveResults: [String: Result<AgentWorkspace, Error>] = [:],
        resolveWorkspaceHandler: ((String) async throws -> AgentWorkspace)? = nil,
        worktreeCreateResults: [String: Result<WorktreeCreateResponse, Error>] = [:],
        worktreeBranchResults: [String: Result<WorktreeBranchListResponse, Error>] = [:],
        worktreeListResult: Result<[WorktreeListItem], Error>? = nil,
        worktreeDeleteResults: [String: Result<WorktreeDeleteResponse, Error>] = [:],
        worktreePruneResult: Result<WorktreePruneResponse, Error>? = nil,
        worktreeCleanupPreviewResult: Result<WorktreeCleanupResponse, Error>? = nil,
        worktreeCleanupExecutionResult: Result<WorktreeCleanupResponse, Error>? = nil,
        directoryListResults: [String: Result<DirectoryListResponse, Error>] = [:],
        fileReadResults: [String: Result<FileReadResponse, Error>] = [:],
        historyMediaResults: [String: Result<FileReadResponse, Error>] = [:],
        historyOutputResults: [String: Result<FileReadResponse, Error>] = [:],
        commandActionResults: [String: Result<[AgentCommandAction], Error>] = [:],
        commandActionRunResults: [String: Result<CommandActionRunResponse, Error>] = [:],
        gitStatusResults: [String: Result<GitStatusResponse, Error>] = [:],
        gitStatusHandler: ((String) async throws -> GitStatusResponse)? = nil,
        gitActionResults: [String: Result<GitStatusResponse, Error>] = [:],
        gitPatchActionResults: [String: Result<GitStatusResponse, Error>] = [:],
        gitCommitResults: [String: Result<GitStatusResponse, Error>] = [:],
        gitPushResults: [String: Result<GitPushResponse, Error>] = [:],
        gitPullRequestResults: [String: Result<GitPullRequestResponse, Error>] = [:],
        gitPullRequestStatusResults: [String: Result<GitPullRequestStatusResponse, Error>] = [:],
        messagesError: Error? = nil,
        modelOptions: [CodexAppServerModelOption] = [],
        modelOptionsError: Error? = nil,
        runtimeChannelAvailability: [String: Bool] = [:],
        rateLimitsByRuntime: [String: RateLimitSummary] = [:],
        rateLimitHandler: ((String) async throws -> RateLimitSummary?)? = nil,
        controlledGlobalSessionsHandler: ((String?, Int?) async throws -> SessionsPage)? = nil,
        accountTokenUsageHandler: (() async throws -> AccountTokenUsageSnapshot?)? = nil,
        accountTokenUsageFetchHandler: (() async throws -> AccountTokenUsageFetch)? = nil,
        threadSearchHandler: ((String, String?, Int?) async throws -> ThreadSearchPage)? = nil,
        supportsLatestTurnHistoryPage: Bool = true
    ) {
        self.projectsResult = projects
        self.projectsHandler = projectsHandler
        self.sessionsResult = sessions
        self.projectSessions = projectSessions
        self.workspaceSessions = workspaceSessions
        self.projectPages = projectPages
        self.workspacePages = workspacePages
        self.cursorPages = cursorPages
        self.createSessionResponse = createSessionResponse
        self.createSessionResults = createSessionResults
        self.sessionArchiveResults = sessionArchiveResults
        self.sessionArchiveHandler = sessionArchiveHandler
        self.sessionForkResults = sessionForkResults
        self.threadGoalSetResults = threadGoalSetResults
        self.sessionResponses = sessionResponses
        self.sessionHandler = sessionHandler
        self.messagesResult = messagesResult ?? [
            CodexHistoryMessage(role: "user", content: "历史问题", createdAt: Date(timeIntervalSince1970: 1)),
            CodexHistoryMessage(role: "assistant", content: "历史回答", createdAt: Date(timeIntervalSince1970: 2))
        ]
        self.historyPages = historyPages
        self.historyCursorPages = historyCursorPages
        self.workspaceSessionsError = workspaceSessionsError
        self.capabilityResults = capabilityResults
        self.resolveResults = resolveResults
        self.resolveWorkspaceHandler = resolveWorkspaceHandler
        self.worktreeCreateResults = worktreeCreateResults
        self.worktreeBranchResults = worktreeBranchResults
        self.worktreeListResult = worktreeListResult
        self.worktreeDeleteResults = worktreeDeleteResults
        self.worktreePruneResult = worktreePruneResult
        self.worktreeCleanupPreviewResult = worktreeCleanupPreviewResult
        self.worktreeCleanupExecutionResult = worktreeCleanupExecutionResult
        self.directoryListResults = directoryListResults
        self.fileReadResults = fileReadResults
        self.historyMediaResults = historyMediaResults
        self.historyOutputResults = historyOutputResults
        self.commandActionResults = commandActionResults
        self.commandActionRunResults = commandActionRunResults
        self.gitStatusResults = gitStatusResults
        self.gitStatusHandler = gitStatusHandler
        self.gitActionResults = gitActionResults
        self.gitPatchActionResults = gitPatchActionResults
        self.gitCommitResults = gitCommitResults
        self.gitPushResults = gitPushResults
        self.gitPullRequestResults = gitPullRequestResults
        self.gitPullRequestStatusResults = gitPullRequestStatusResults
        self.messagesError = messagesError
        self.modelOptionsResult = modelOptions
        self.modelOptionsError = modelOptionsError
        self.runtimeChannelAvailability = runtimeChannelAvailability
        self.rateLimitsByRuntime = rateLimitsByRuntime
        self.rateLimitHandler = rateLimitHandler
        self.controlledGlobalSessionsHandler = controlledGlobalSessionsHandler
        self.accountTokenUsageHandler = accountTokenUsageHandler
        self.accountTokenUsageFetchHandler = accountTokenUsageFetchHandler
        self.threadSearchHandler = threadSearchHandler
        self.supportsLatestTurnHistoryPage = supportsLatestTurnHistoryPage
    }

    func projects() async throws -> [AgentProject] {
        if let projectsHandler {
            return try await projectsHandler()
        }
        return projectsResult
    }

    func modelOptions() async throws -> [CodexAppServerModelOption] {
        modelOptionsCallCount += 1
        if let modelOptionsError {
            throw modelOptionsError
        }
        return modelOptionsResult
    }

    func runtimeChannelAvailable(runtimeProvider: String) async throws -> Bool {
        runtimeChannelAvailability[runtimeProvider] ?? false
    }

    func refreshRateLimit(runtimeProvider: String) async throws -> RateLimitSummary? {
        requestedRateLimitProviders.append(runtimeProvider)
        if let rateLimitHandler {
            return try await rateLimitHandler(runtimeProvider)
        }
        return rateLimitsByRuntime[runtimeProvider]
    }

    func refreshAccountTokenUsage() async throws -> AccountTokenUsageFetch {
        if let accountTokenUsageFetchHandler {
            return try await accountTokenUsageFetchHandler()
        }
        guard let accountTokenUsageHandler else { return .unsupported }
        guard let snapshot = try await accountTokenUsageHandler() else { return .unsupported }
        return .snapshot(snapshot)
    }

    func capabilities(path: String?, forceReload: Bool) async throws -> CapabilityListResponse {
        requestedCapabilityPaths.append(path)
        requestedCapabilityForceReloads.append(forceReload)
        let key = path ?? ""
        switch capabilityResults[key] {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func resolveWorkspace(path: String) async throws -> AgentWorkspace {
        requestedResolvePaths.append(path)
        if let resolveWorkspaceHandler {
            return try await resolveWorkspaceHandler(path)
        }
        switch resolveResults[path] {
        case .success(let workspace):
            return workspace
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func createWorktree(path: String, name: String?, base: String?, branch: String?) async throws -> WorktreeCreateResponse {
        requestedWorktreeCreates.append(RequestedWorktreeCreate(path: path, name: name, base: base, branch: branch))
        switch worktreeCreateResults[path] {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func worktreeBranches(path: String) async throws -> WorktreeBranchListResponse {
        requestedWorktreeBranchPaths.append(path)
        switch worktreeBranchResults[path] {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func listWorktrees() async throws -> [WorktreeListItem] {
        worktreeListCallCount += 1
        switch worktreeListResult {
        case .success(let items):
            return items
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func deleteWorktree(path: String, force: Bool) async throws -> WorktreeDeleteResponse {
        requestedWorktreeDeletes.append(RequestedWorktreeDelete(path: path, force: force))
        switch worktreeDeleteResults[path] {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func pruneMissingWorktrees() async throws -> WorktreePruneResponse {
        worktreePruneCallCount += 1
        switch worktreePruneResult {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func previewWorktreeCleanup() async throws -> WorktreeCleanupResponse {
        worktreeCleanupPreviewCallCount += 1
        switch worktreeCleanupPreviewResult {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func executeWorktreeCleanup(paths: [String], planID: String) async throws -> WorktreeCleanupResponse {
        requestedWorktreeCleanupPaths.append(paths)
        requestedWorktreeCleanupPlanIDs.append(planID)
        switch worktreeCleanupExecutionResult {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func listDirectories(path: String) async throws -> DirectoryListResponse {
        requestedDirectoryPaths.append(path)
        switch directoryListResults[path] {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func readFile(path: String) async throws -> FileReadResponse {
        requestedFileReadPaths.append(path)
        switch fileReadResults[path] {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func readHistoryMedia(id: String) async throws -> FileReadResponse {
        requestedHistoryMediaIDs.append(id)
        switch historyMediaResults[id] {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func readHistoryOutput(id: String) async throws -> FileReadResponse {
        requestedHistoryOutputIDs.append(id)
        switch historyOutputResults[id] {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func commandActions(path: String) async throws -> [AgentCommandAction] {
        requestedCommandActionPaths.append(path)
        switch commandActionResults[path] {
        case .success(let actions):
            return actions
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func runCommandAction(path: String, id: String, confirmed: Bool) async throws -> CommandActionRunResponse {
        requestedCommandActionRuns.append(RequestedCommandActionRun(path: path, id: id, confirmed: confirmed))
        let key = "\(path)#\(id)"
        switch commandActionRunResults[key] ?? commandActionRunResults[id] {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func gitStatus(path: String) async throws -> GitStatusResponse {
        requestedGitStatusPaths.append(path)
        if let gitStatusHandler {
            return try await gitStatusHandler(path)
        }
        switch gitStatusResults[path] {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func gitAction(path: String, action: GitActionKind, files: [String]) async throws -> GitStatusResponse {
        requestedGitActions.append(RequestedGitAction(path: path, action: action, files: files))
        switch gitActionResults[path] {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func gitPatchAction(path: String, action: GitActionKind, patch: String) async throws -> GitStatusResponse {
        requestedGitPatchActions.append(RequestedGitPatchAction(path: path, action: action, patch: patch))
        switch gitPatchActionResults[path] {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func gitCommit(path: String, message: String) async throws -> GitStatusResponse {
        requestedGitCommits.append(RequestedGitCommit(path: path, message: message))
        switch gitCommitResults[path] {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func gitPush(path: String, remote: String?) async throws -> GitPushResponse {
        requestedGitPushes.append(RequestedGitPush(path: path, remote: remote))
        switch gitPushResults[path] {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func gitCreatePullRequest(path: String, title: String, body: String, draft: Bool) async throws -> GitPullRequestResponse {
        requestedGitPullRequests.append(RequestedGitPullRequest(path: path, title: title, body: body, draft: draft))
        switch gitPullRequestResults[path] {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func gitPullRequestStatus(path: String) async throws -> GitPullRequestStatusResponse {
        requestedGitPullRequestStatusPaths.append(path)
        switch gitPullRequestStatusResults[path] {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func sessionsPage(workspace: AgentWorkspace, cursor: String?, limit: Int?) async throws -> SessionsPage {
        // 最近会话会并发读取多个工作区；测试请求日志也必须保证线程安全，
        // 否则并发 append 会让 Array 内存损坏并掩盖真实业务结果。
        requestLogLock.withLock {
            requestedWorkspaceIDsStorage.append(workspace.id)
        }
        if let error = workspaceSessionsError[workspace.id] {
            throw error
        }
        if let page = workspacePages[workspace.id] {
            return page
        }
        if let sessions = workspaceSessions[workspace.id] {
            return SessionsPage(sessions: sessions)
        }
        // 没有注入错误时沿用 projectID 路径，保持既有 workspace→rootProjectID 映射测试不变。
        return try await sessionsPage(projectID: workspace.rootProjectID ?? workspace.id, cursor: cursor, limit: limit)
    }

    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] {
        requestLogLock.withLock {
            requestedProjectIDsStorage.append(projectID)
        }
        if let projectID, let sessions = projectSessions[projectID] {
            return sessions
        }
        return sessionsResult
    }

    func sessionsPage(projectID: String?, cursor: String?, limit: Int?) async throws -> SessionsPage {
        requestLogLock.withLock {
            requestedProjectIDsStorage.append(projectID)
        }
        if let cursor, let page = cursorPages[cursor] {
            return page
        }
        if let projectID, let page = projectPages[projectID] {
            return page
        }
        if let projectID, let sessions = projectSessions[projectID] {
            return SessionsPage(sessions: sessions)
        }
        return SessionsPage(sessions: sessionsResult)
    }

    func controlledGlobalSessionsPage(cursor: String?, limit: Int?) async throws -> SessionsPage {
        requestLogLock.withLock {
            requestedControlledGlobalCursorsStorage.append(cursor)
        }
        guard let controlledGlobalSessionsHandler else {
            return SessionsPage(sessions: [])
        }
        return try await controlledGlobalSessionsHandler(cursor, limit)
    }

    func searchSessions(query: String, cursor: String?, limit: Int?) async throws -> ThreadSearchPage {
        requestLogLock.withLock {
            requestedThreadSearchQueriesStorage.append(query)
            requestedThreadSearchCursorsStorage.append(cursor)
        }
        guard let threadSearchHandler else {
            throw MockError.unimplemented
        }
        return try await threadSearchHandler(query, cursor, limit)
    }

    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        requestedSessionIDs.append(id)
        requestedSessionAfterSeqs.append(afterSeq)
        if let sessionHandler {
            return try await sessionHandler(id, afterSeq)
        }
        guard let response = sessionResponses[id] else {
            throw MockError.unimplemented
        }
        return response
    }

    func setThreadGoal(
        threadID: String,
        objective: String?,
        status: ThreadGoalStatus?,
        tokenBudget: Int64?
    ) async throws -> ThreadGoal {
        requestedThreadGoalSets.append(RequestedThreadGoalSet(
            threadID: threadID,
            objective: objective,
            status: status,
            tokenBudget: tokenBudget
        ))
        switch threadGoalSetResults[threadID] {
        case .success(let goal):
            return goal
        case .failure(let error):
            throw error
        case .none:
            return ThreadGoal(
                threadID: threadID,
                objective: objective ?? "测试目标",
                status: status ?? .active,
                tokenBudget: tokenBudget
            )
        }
    }

    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse {
        createPayloads.append(payload)
        if !createSessionResults.isEmpty {
            return try createSessionResults.removeFirst().get()
        }
        guard let createSessionResponse else {
            throw MockError.unimplemented
        }
        return createSessionResponse
    }

    func stopSession(id: String) async throws {
        throw MockError.unimplemented
    }

    func setSessionArchived(id: String, archived: Bool) async throws {
        requestLogLock.withLock {
            requestedSessionArchivesStorage.append(RequestedSessionArchive(id: id, archived: archived))
        }
        if let sessionArchiveHandler {
            try await sessionArchiveHandler(id, archived)
            return
        }
        switch sessionArchiveResults[id] {
        case .success:
            return
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func setThreadName(threadID: String, name: String) async throws {
        requestedThreadNames.append(RequestedThreadName(threadID: threadID, name: name))
    }

    func startReview(
        threadID: String,
        target: CodexAppServerReviewTarget,
        delivery: CodexAppServerReviewDelivery?
    ) async throws -> CodexAppServerReviewStartResult {
        requestedSessionReviews.append(RequestedSessionReview(
            threadID: threadID,
            target: target,
            delivery: delivery
        ))
        return CodexAppServerReviewStartResult(reviewThreadID: threadID, turnID: "turn-review")
    }

    func forkSession(
        threadID: String,
        workspace: AgentWorkspace,
        reason: AgentSessionForkReason
    ) async throws -> AgentSession {
        requestedSessionForks.append(
            RequestedSessionFork(threadID: threadID, workspaceID: workspace.id, reason: reason)
        )
        switch sessionForkResults[threadID] {
        case .success(let session):
            return session
        case .failure(let error):
            throw error
        case .none:
            throw MockError.unimplemented
        }
    }

    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage] {
        requestedMessageSessionIDs.append(sessionID)
        requestedMessageCursors.append(before)
        requestedMessageLimits.append(limit)
        if let before, let page = historyCursorPages[before] {
            return page.messages
        }
        if let page = historyPages[sessionID] {
            return page.messages
        }
        if let messagesError {
            throw messagesError
        }
        return messagesResult
    }

    func messagesPage(sessionID: String, before: String?, limit: Int?) async throws -> HistoryMessagesPage {
        requestedMessageSessionIDs.append(sessionID)
        requestedMessageCursors.append(before)
        requestedMessageLimits.append(limit)
        if let before, let page = historyCursorPages[before] {
            return page
        }
        if let page = historyPages[sessionID] {
            return page
        }
        if let messagesError {
            throw messagesError
        }
        return HistoryMessagesPage(messages: messagesResult)
    }

    func latestTurnHistoryPage(sessionID: String) async throws -> HistoryMessagesPage? {
        guard supportsLatestTurnHistoryPage else {
            return nil
        }
        requestedMessageSessionIDs.append(sessionID)
        requestedMessageCursors.append(nil)
        requestedMessageLimits.append(1)
        if let page = historyPages[sessionID] {
            return page
        }
        if let messagesError {
            throw messagesError
        }
        return HistoryMessagesPage(messages: messagesResult)
    }
}

final class MutableSessionPageClient: SessionStoreAPIClient {
    let projectsResult: [AgentProject]
    var page: SessionsPage
    var projectPages: [String: SessionsPage]
    var cursorPages: [String: SessionsPage]
    var historyPages: [SessionID: HistoryMessagesPage]
    var historyCursorPages: [String: HistoryMessagesPage]
    var requestedMessageCursors: [String?] = []
    var requestedSessionCursors: [String?] = []
    var requestedSessionLimits: [Int?] = []
    var requestedSessionListConsistencies: [SessionListConsistency] = []
    var onSessionPageRequest: ((String?) -> Void)?

    init(
        projects: [AgentProject],
        page: SessionsPage,
        projectPages: [String: SessionsPage] = [:],
        cursorPages: [String: SessionsPage] = [:],
        historyPages: [SessionID: HistoryMessagesPage] = [:],
        historyCursorPages: [String: HistoryMessagesPage] = [:]
    ) {
        self.projectsResult = projects
        self.page = page
        self.projectPages = projectPages
        self.cursorPages = cursorPages
        self.historyPages = historyPages
        self.historyCursorPages = historyCursorPages
    }

    func projects() async throws -> [AgentProject] {
        projectsResult
    }

    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] {
        if let projectID, let page = projectPages[projectID] {
            return page.sessions
        }
        return page.sessions
    }

    func sessionsPage(projectID: String?, cursor: String?, limit: Int?) async throws -> SessionsPage {
        requestedSessionCursors.append(cursor)
        requestedSessionLimits.append(limit)
        onSessionPageRequest?(cursor)
        if let cursor, let page = cursorPages[cursor] {
            return page
        }
        if let projectID, let page = projectPages[projectID] {
            return page
        }
        return page
    }

    func sessionsPage(
        workspace: AgentWorkspace,
        cursor: String?,
        limit: Int?,
        consistency: SessionListConsistency
    ) async throws -> SessionsPage {
        requestedSessionListConsistencies.append(consistency)
        return try await sessionsPage(
            projectID: workspace.rootProjectID ?? workspace.id,
            cursor: cursor,
            limit: limit
        )
    }

    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        throw MockError.unimplemented
    }

    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse {
        throw MockError.unimplemented
    }

    func stopSession(id: String) async throws {
        throw MockError.unimplemented
    }

    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage] {
        let page = try await messagesPage(sessionID: sessionID, before: before, limit: limit)
        return page.messages
    }

    func messagesPage(sessionID: String, before: String?, limit: Int?) async throws -> HistoryMessagesPage {
        requestedMessageCursors.append(before)
        if let before, let page = historyCursorPages[before] {
            return page
        }
        if let page = historyPages[sessionID] {
            return page
        }
        return HistoryMessagesPage(messages: [])
    }
}

final class BlockingSessionListRefreshClient: SessionStoreAPIClient {
    let projectsResult: [AgentProject]
    let page: SessionsPage
    let blockOnCall: Int
    let blockedError: Error?
    private(set) var requestedMessageCursors: [String?] = []
    private(set) var requestedSessionCursors: [String?] = []
    private(set) var sessionsPageCallCount = 0
    private(set) var requestedSessionListConsistencies: [SessionListConsistency] = []
    private var blockedListRefreshCount = 0
    private var blockedListContinuations: [CheckedContinuation<SessionsPage, Error>] = []
    private var blockedListWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        projects: [AgentProject],
        page: SessionsPage,
        blockOnCall: Int = 2,
        blockedError: Error? = nil
    ) {
        self.projectsResult = projects
        self.page = page
        self.blockOnCall = blockOnCall
        self.blockedError = blockedError
    }

    func projects() async throws -> [AgentProject] {
        projectsResult
    }

    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] {
        page.sessions
    }

    func sessionsPage(projectID: String?, cursor: String?, limit: Int?) async throws -> SessionsPage {
        sessionsPageCallCount += 1
        requestedSessionCursors.append(cursor)
        guard sessionsPageCallCount >= blockOnCall else {
            return page
        }
        // 默认从第二次开始模拟慢 thread/list；指定 blockOnCall=1 时可复现 refreshAll 与轮询竞态。
        return try await withCheckedThrowingContinuation { continuation in
            blockedListContinuations.append(continuation)
            blockedListRefreshCount += 1
            notifyBlockedListWaiters()
        }
    }

    func sessionsPage(
        workspace: AgentWorkspace,
        cursor: String?,
        limit: Int?,
        consistency: SessionListConsistency
    ) async throws -> SessionsPage {
        requestedSessionListConsistencies.append(consistency)
        return try await sessionsPage(
            projectID: workspace.rootProjectID ?? workspace.id,
            cursor: cursor,
            limit: limit
        )
    }

    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        throw MockError.unimplemented
    }

    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse {
        throw MockError.unimplemented
    }

    func stopSession(id: String) async throws {
        throw MockError.unimplemented
    }

    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage] {
        let page = try await messagesPage(sessionID: sessionID, before: before, limit: limit)
        return page.messages
    }

    func messagesPage(sessionID: String, before: String?, limit: Int?) async throws -> HistoryMessagesPage {
        requestedMessageCursors.append(before)
        return HistoryMessagesPage(
            messages: [
                CodexHistoryMessage(id: "rollout:100", role: "assistant", content: "历史回答", createdAt: Date(timeIntervalSince1970: 2))
            ]
        )
    }

    func waitForBlockedSessionListRefresh() async {
        guard blockedListRefreshCount == 0 else {
            return
        }
        await withCheckedContinuation { continuation in
            guard blockedListRefreshCount == 0 else {
                continuation.resume()
                return
            }
            blockedListWaiters.append(continuation)
        }
    }

    func releaseBlockedSessionListRefresh() {
        if let blockedError {
            blockedListContinuations.forEach { $0.resume(throwing: blockedError) }
        } else {
            blockedListContinuations.forEach { $0.resume(returning: page) }
        }
        blockedListContinuations = []
    }

    private func notifyBlockedListWaiters() {
        blockedListWaiters.forEach { $0.resume() }
        blockedListWaiters = []
    }
}

final class SequencedSessionListClient: SessionStoreAPIClient {
    private let projectsResult: [AgentProject]
    private let results: [Result<SessionsPage, Error>]
    private(set) var sessionsPageCallCount = 0

    init(projects: [AgentProject], results: [Result<SessionsPage, Error>]) {
        self.projectsResult = projects
        self.results = results
    }

    func projects() async throws -> [AgentProject] {
        projectsResult
    }

    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] {
        try await sessionsPage(projectID: projectID, cursor: cursor, limit: limit).sessions
    }

    func sessionsPage(projectID: String?, cursor: String?, limit: Int?) async throws -> SessionsPage {
        let index = min(sessionsPageCallCount, max(0, results.count - 1))
        sessionsPageCallCount += 1
        guard !results.isEmpty else {
            return SessionsPage(sessions: [])
        }
        return try results[index].get()
    }

    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        throw MockError.unimplemented
    }

    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse {
        throw MockError.unimplemented
    }

    func stopSession(id: String) async throws {
        throw MockError.unimplemented
    }

    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage] {
        []
    }
}

final class DelayedCommandActionClient: SessionStoreAPIClient {
    let projectsResult: [AgentProject]
    let sessionsResult: [AgentSession]
    let actionsByPath: [String: [AgentCommandAction]]
    let runResults: [String: Result<CommandActionRunResponse, Error>]
    var requestedCommandActionPaths: [String] = []
    var requestedCommandActionRuns: [RequestedCommandActionRun] = []
    private var runContinuations: [CheckedContinuation<CommandActionRunResponse, Error>] = []
    private var requestCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(
        projects: [AgentProject],
        sessions: [AgentSession],
        actionsByPath: [String: [AgentCommandAction]],
        runResults: [String: Result<CommandActionRunResponse, Error>]
    ) {
        self.projectsResult = projects
        self.sessionsResult = sessions
        self.actionsByPath = actionsByPath
        self.runResults = runResults
    }

    func projects() async throws -> [AgentProject] {
        projectsResult
    }

    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] {
        sessionsResult
    }

    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        throw MockError.unimplemented
    }

    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse {
        throw MockError.unimplemented
    }

    func stopSession(id: String) async throws {
        throw MockError.unimplemented
    }

    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage] {
        []
    }

    func commandActions(path: String) async throws -> [AgentCommandAction] {
        requestedCommandActionPaths.append(path)
        return actionsByPath[path] ?? []
    }

    func runCommandAction(path: String, id: String, confirmed: Bool) async throws -> CommandActionRunResponse {
        requestedCommandActionRuns.append(RequestedCommandActionRun(path: path, id: id, confirmed: confirmed))
        return try await withCheckedThrowingContinuation { continuation in
            runContinuations.append(continuation)
            notifyRequestCountWaiters()
        }
    }

    func waitForRunRequestCount(_ count: Int) async {
        guard runContinuations.count < count else {
            return
        }
        await withCheckedContinuation { continuation in
            guard runContinuations.count < count else {
                continuation.resume()
                return
            }
            requestCountWaiters.append((count, continuation))
        }
    }

    func resolveRun(at index: Int) {
        guard runContinuations.indices.contains(index), requestedCommandActionRuns.indices.contains(index) else {
            return
        }
        let request = requestedCommandActionRuns[index]
        let key = "\(request.path)#\(request.id)"
        switch runResults[key] ?? .failure(MockError.unimplemented) {
        case .success(let response):
            runContinuations[index].resume(returning: response)
        case .failure(let error):
            runContinuations[index].resume(throwing: error)
        }
    }

    private func notifyRequestCountWaiters() {
        var pending: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in requestCountWaiters {
            if runContinuations.count >= waiter.0 {
                waiter.1.resume()
            } else {
                pending.append(waiter)
            }
        }
        requestCountWaiters = pending
    }
}

final class OrderedHistoryPageClient: SessionStoreAPIClient {
    let projectsResult: [AgentProject]
    let page: SessionsPage
    let supportsLatestTurnHistoryPage: Bool
    private let lock = NSLock()
    private var requestedMessageCursorsStorage: [String?] = []
    private var requestedMessageLimitsStorage: [Int?] = []
    private var requestedMessageLoadModesStorage: [HistoryMessagesPage.LoadMode] = []
    private var historyContinuations: [CheckedContinuation<HistoryMessagesPage, Error>?] = []
    private var requestCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(
        projects: [AgentProject],
        page: SessionsPage,
        supportsLatestTurnHistoryPage: Bool = true
    ) {
        self.projectsResult = projects
        self.page = page
        self.supportsLatestTurnHistoryPage = supportsLatestTurnHistoryPage
    }

    var requestedMessageCursors: [String?] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return requestedMessageCursorsStorage
    }

    var requestedMessageLimits: [Int?] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return requestedMessageLimitsStorage
    }

    var requestedMessageLoadModes: [HistoryMessagesPage.LoadMode] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return requestedMessageLoadModesStorage
    }

    func projects() async throws -> [AgentProject] {
        projectsResult
    }

    func sessions(projectID: String?, cursor: String?, limit: Int?) async throws -> [AgentSession] {
        page.sessions
    }

    func sessionsPage(projectID: String?, cursor: String?, limit: Int?) async throws -> SessionsPage {
        page
    }

    func session(id: String, afterSeq: EventSequence?) async throws -> SessionResponse {
        throw MockError.unimplemented
    }

    func createSession(_ payload: CreateSessionRequest) async throws -> CreateSessionResponse {
        throw MockError.unimplemented
    }

    func stopSession(id: String) async throws {
        throw MockError.unimplemented
    }

    func messages(sessionID: String, before: String?, limit: Int?) async throws -> [CodexHistoryMessage] {
        let page = try await messagesPage(sessionID: sessionID, before: before, limit: limit)
        return page.messages
    }

    func messagesPage(sessionID: String, before: String?, limit: Int?) async throws -> HistoryMessagesPage {
        try await messagesPage(sessionID: sessionID, before: before, limit: limit, loadMode: .full)
    }

    func messagesPage(
        sessionID: String,
        before: String?,
        limit: Int?,
        loadMode: HistoryMessagesPage.LoadMode
    ) async throws -> HistoryMessagesPage {
        try await withCheckedThrowingContinuation { continuation in
            let waiters = appendHistoryRequest(before: before, limit: limit, loadMode: loadMode, continuation: continuation)
            waiters.forEach { $0.resume() }
        }
    }

    func latestTurnHistoryPage(sessionID: String) async throws -> HistoryMessagesPage? {
        guard supportsLatestTurnHistoryPage else {
            return nil
        }
        return try await messagesPage(sessionID: sessionID, before: nil, limit: 1, loadMode: .full)
    }

    func waitForHistoryRequestCount(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let shouldResumeNow = appendRequestCountWaiter(count: count, continuation: continuation)
            if shouldResumeNow {
                continuation.resume()
            }
        }
    }

    func resolveHistoryRequest(
        at index: Int,
        with page: HistoryMessagesPage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let continuation = takeHistoryContinuation(at: index) else {
            XCTFail("No pending history request at index \(index)", file: file, line: line)
            return
        }
        continuation.resume(returning: page)
    }

    func failHistoryRequest(
        at index: Int,
        with error: Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let continuation = takeHistoryContinuation(at: index) else {
            XCTFail("No pending history request at index \(index)", file: file, line: line)
            return
        }
        continuation.resume(throwing: error)
    }

    private func appendHistoryRequest(
        before: String?,
        limit: Int?,
        loadMode: HistoryMessagesPage.LoadMode,
        continuation: CheckedContinuation<HistoryMessagesPage, Error>
    ) -> [CheckedContinuation<Void, Never>] {
        lock.lock()
        defer {
            lock.unlock()
        }
        historyContinuations.append(continuation)
        requestedMessageCursorsStorage.append(before)
        requestedMessageLimitsStorage.append(limit)
        requestedMessageLoadModesStorage.append(loadMode)
        return takeReadyRequestCountWaitersLocked()
    }

    private func appendRequestCountWaiter(
        count: Int,
        continuation: CheckedContinuation<Void, Never>
    ) -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard historyContinuations.count < count else {
            return true
        }
        requestCountWaiters.append((count, continuation))
        return false
    }

    private func takeHistoryContinuation(at index: Int) -> CheckedContinuation<HistoryMessagesPage, Error>? {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard historyContinuations.indices.contains(index) else {
            return nil
        }
        let continuation = historyContinuations[index]
        historyContinuations[index] = nil
        return continuation
    }

    private func takeReadyRequestCountWaitersLocked() -> [CheckedContinuation<Void, Never>] {
        var ready: [CheckedContinuation<Void, Never>] = []
        var pending: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in requestCountWaiters {
            if historyContinuations.count >= waiter.0 {
                ready.append(waiter.1)
            } else {
                pending.append(waiter)
            }
        }
        requestCountWaiters = pending
        return ready
    }
}

func queryValue(_ name: String, in url: URL?) -> String? {
    guard let url else {
        return nil
    }
    return URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?
        .first { $0.name == name }?
        .value
}

func payloadContainsInlineImage(_ payload: CodexAppServerTurnPayload?) -> Bool {
    payload?.input.contains { item in
        if case .image(let url, _) = item {
            return url.trimmingCharacters(in: .whitespacesAndNewlines)
                .range(of: "data:image/", options: [.anchored, .caseInsensitive]) != nil
        }
        return false
    } ?? false
}

func payloadContainsImageURL(_ payload: CodexAppServerTurnPayload?, url expectedURL: String) -> Bool {
    payload?.input.contains { item in
        if case .image(let url, _) = item {
            return url == expectedURL
        }
        return false
    } ?? false
}

func payloadContainsMention(_ payload: CodexAppServerTurnPayload?, name expectedName: String) -> Bool {
    payload?.input.contains { item in
        if case .mention(let name, _) = item {
            return name == expectedName
        }
        return false
    } ?? false
}

func payloadContainsSkill(_ payload: CodexAppServerTurnPayload?, name expectedName: String) -> Bool {
    payload?.input.contains { item in
        if case .skill(let name, _) = item {
            return name == expectedName
        }
        return false
    } ?? false
}

/// 等待流式 delta 的合并缓冲真正 flush 落地。
///
/// 不能用固定 sleep 代替：ConversationStore 的 80ms flush 和测试自己的等待是两个
/// 独立定时器，落地先后没有任何保证。真机满负载跑全量时调度会停顿到秒级，足以让
/// 测试先醒来读到未 flush 的旧内容（实测正常余量只有约 84ms）。
@MainActor
func waitForPendingAssistantDeltaFlush(
    in store: ConversationStore,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws {
    for _ in 0..<500 {
        if !store.hasPendingAssistantDeltasForTesting {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("流式 delta 合并缓冲未在 5s 内 flush", file: file, line: line)
}

@MainActor
func waitForConversationMessages(
    in store: ConversationStore,
    sessionID: SessionID,
    matching predicate: ([ConversationMessage]) -> Bool
) async throws -> [ConversationMessage] {
    for _ in 0..<300 {
        let messages = store.messages(for: sessionID)
        if predicate(messages) {
            return messages
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    let messages = store.messages(for: sessionID)
    XCTFail("会话消息未在超时内达到预期，当前消息数：\(messages.count)")
    return messages
}

func valuesOrTimeout(
    _ task: Task<[Int], Never>,
    expectedCount: Int,
    timeoutNanoseconds: UInt64 = 1_000_000_000
) async throws -> [Int] {
    try await withThrowingTaskGroup(of: [Int]?.self) { group in
        group.addTask {
            await task.value
        }
        group.addTask {
            try await Task.sleep(nanoseconds: timeoutNanoseconds)
            return nil
        }
        guard let result = try await group.next() else {
            task.cancel()
            return []
        }
        group.cancelAll()
        guard let values = result else {
            task.cancel()
            XCTFail("事件流在超时前未拿齐 \(expectedCount) 条")
            return []
        }
        if values.count < expectedCount {
            XCTFail("事件流数量不足：expected=\(expectedCount), actual=\(values.count)")
        }
        return values
    }
}

@MainActor
func waitForWebSocketStatus(_ expected: WebSocketStatus, store: SessionStore) async throws {
    for _ in 0..<80 {
        if store.webSocketStatus == expected {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("WebSocket 状态未变为 \(expected)，当前为 \(store.webSocketStatus)")
}

@MainActor
func waitForNetworkReachability(
    _ expected: NetworkReachabilityStatus,
    store: SessionStore
) async throws {
    for _ in 0..<80 {
        if store.networkReachabilityStatus == expected {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("网络状态未变为 \(expected)，当前为 \(store.networkReachabilityStatus)")
}

@MainActor
func waitForStatus(
    _ expected: WebSocketStatus,
    in statuses: () -> [WebSocketStatus]
) async throws {
    for _ in 0..<100 {
        if statuses().contains(expected) {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("WebSocket 状态序列未出现 \(expected)，当前为 \(statuses())")
}

@MainActor
func waitForSentTurnCount(_ expected: Int, socket: MockWebSocketClient) async throws {
    for _ in 0..<80 {
        if socket.sentTurns.count == expected {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("turn/start 数量未在超时前变为 \(expected)，当前为 \(socket.sentTurns.count)")
}

@MainActor
func waitForRuntimeActivity(
    in store: SessionStore,
    sessionID: SessionID,
    matching predicate: (RuntimeActivitySnapshot) -> Bool = { _ in true }
) async throws -> RuntimeActivitySnapshot {
    for _ in 0..<80 {
        if let snapshot = store.runtimeActivitySnapshot(for: sessionID), predicate(snapshot) {
            return snapshot
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("runtime activity snapshot 未在超时前更新")
    throw MockError.timeout
}

@MainActor
func waitForRuntimeActivityCleared(in store: SessionStore, sessionID: SessionID) async throws {
    for _ in 0..<80 {
        if store.runtimeActivitySnapshot(for: sessionID) == nil {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("runtime activity snapshot 未在超时前清理")
}

@MainActor
func waitForSelectedActiveTurnID(_ expected: TurnID?, store: SessionStore) async throws {
    for _ in 0..<80 {
        if store.selectedSession?.activeTurnID == expected {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("activeTurnID 未在超时前变为 \(expected ?? "nil")，当前为 \(store.selectedSession?.activeTurnID ?? "nil")")
}

@MainActor
func waitForSelectedSessionStatus(_ expected: String, store: SessionStore) async throws {
    for _ in 0..<80 {
        if store.selectedSession?.status == expected {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("session status 未在超时前变为 \(expected)，当前为 \(store.selectedSession?.status ?? "nil")")
}

@MainActor
func waitForSelectedThreadGoalStatus(_ expected: ThreadGoalStatus, store: SessionStore) async throws {
    for _ in 0..<80 {
        if store.selectedThreadGoal?.status == expected {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("目标状态未在超时前变为 \(expected.rawValue)，当前为 \(store.selectedThreadGoal?.status.rawValue ?? "nil")")
}

@MainActor
extension ConversationDataFlowTests {
}
