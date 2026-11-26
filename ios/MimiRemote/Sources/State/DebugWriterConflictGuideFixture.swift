#if DEBUG
import Foundation
import SwiftUI

/// 离线 UI 回归：使用真实 WriterConflictCard 与 ConversationView，点击真实「如何共享」「完成」
/// 及原冲突卡「重试」「分支到新聊天」按钮，不连接真实 agentd。
struct DebugWriterConflictGuideFixture: View {
    private let conversationMode: Bool
    @StateObject private var conversationHost: WriterConflictGuideConversationFixtureHost
    @State private var retryCount = 0
    @State private var forkCount = 0

    init(appStore: AppStore) {
        let args = ProcessInfo.processInfo.arguments
        conversationMode = args.contains("--debug-writer-conflict-conversation")
        _conversationHost = StateObject(
            wrappedValue: WriterConflictGuideConversationFixtureHost(appStore: appStore)
        )
    }

    var body: some View {
        if conversationMode {
            ZStack(alignment: .topTrailing) {
                ConversationView()
                    .environmentObject(conversationHost.sessionStore)
                    .environmentObject(conversationHost.conversationStore)

                Text(conversationHost.retryTriggerCount, format: .number.grouping(.never))
                    .accessibilityIdentifier("writerConflict.fixture.conversationRetryCount")
                    .padding(6)
            }
            .task {
                while !Task.isCancelled {
                    conversationHost.syncRetryTriggerCount()
                    try? await Task.sleep(for: .milliseconds(80))
                }
            }
        } else {
            VStack(spacing: 16) {
                WriterConflictCard(
                    sourceIsRunning: false,
                    availability: .available(lastTurnID: nil),
                    errorMessage: nil,
                    isDuplicating: false,
                    isRetrying: false,
                    hostPlatform: .apple,
                    onFork: { forkCount += 1 },
                    onRecheck: {},
                    onRetry: { retryCount += 1 }
                )
                .padding(.horizontal, 16)

                HStack(spacing: 12) {
                    Text(retryCount, format: .number.grouping(.never))
                        .accessibilityIdentifier("writerConflict.fixture.retryCount")
                    Text(forkCount, format: .number.grouping(.never))
                        .accessibilityIdentifier("writerConflict.fixture.forkCount")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 24)
        }
    }
}

@MainActor
private final class WriterConflictGuideConversationFixtureHost: ObservableObject {
    let sessionStore: SessionStore
    let conversationStore: ConversationStore
    @Published private(set) var retryTriggerCount = 0

    init(appStore: AppStore) {
        WriterConflictGuideFixtureCounter.reset()
        let conversationStore = ConversationStore()
        let sessionStore = SessionStore(
            appStore: appStore,
            conversationStore: conversationStore,
            logStore: LogStore(),
            clientFactory: {
                WriterConflictGuideFixtureCounter.recordRetryAttempt()
                throw URLError(.notConnectedToInternet)
            }
        )
        let project = AgentProject(
            id: "proj-writer-guide-ui",
            name: "Fixture Workspace",
            path: "/tmp/writer-guide-ui"
        )
        let sessionJSON = """
        {
          "id": "source-writer-guide-ui",
          "project_id": "proj-writer-guide-ui",
          "project": "Fixture Workspace",
          "dir": "/tmp/writer-guide-ui",
          "title": "Desktop Conflict Fixture",
          "status": "history",
          "source": "codex",
          "resume_id": "source-writer-guide-ui",
          "can_accept_direct_input": true
        }
        """
        let session = try! JSONDecoder().decode(AgentSession.self, from: Data(sessionJSON.utf8))
        sessionStore.projects = [project]
        sessionStore.sidebarProjects = [project]
        sessionStore.sessions = [session]
        sessionStore.selectedProjectID = project.id
        sessionStore.selectedSessionID = session.id
        sessionStore.setActiveWriterConflict(true, sessionID: session.id)

        self.sessionStore = sessionStore
        self.conversationStore = conversationStore
    }

    func syncRetryTriggerCount() {
        let count = WriterConflictGuideFixtureCounter.retryAttempts
        if retryTriggerCount != count {
            retryTriggerCount = count
        }
    }
}

private enum WriterConflictGuideFixtureCounter {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var attempts = 0

    static var retryAttempts: Int {
        lock.withLock { attempts }
    }

    static func reset() {
        lock.withLock { attempts = 0 }
    }

    static func recordRetryAttempt() {
        lock.withLock { attempts += 1 }
    }
}
#endif
