import Foundation

/// R1 迁移接缝：旧页面、测试和主机快照仍使用原属性名，但所有读写都落在同一个 Git Store。
/// 不要在这里增加业务状态或请求；后续页面可直接观察 workspaceGitStore 后删除相应转发。
extension SessionStore {
    static func makeWorkspaceGitStore(
        appStore: AppStore,
        workspaceGitClientFactory: (() throws -> any WorkspaceGitAPIClient)?,
        legacyClientFactory: (() throws -> any SessionStoreAPIClient)?
    ) -> WorkspaceGitStore {
        let gitClientFactory: () throws -> any WorkspaceGitAPIClient
        if let workspaceGitClientFactory {
            gitClientFactory = workspaceGitClientFactory
        } else if let legacyClientFactory {
            // 只兼容明确注入的旧测试替身/嵌入式调用；生产默认绝不走 runtime facade。
            gitClientFactory = { SessionClientWorkspaceGitAdapter(client: try legacyClientFactory()) }
        } else {
            // 复用主机客户端的凭据挂起、选路及 endpoint 校验，不创建/唤醒 Agent Runtime。
            gitClientFactory = { try appStore.client() }
        }
        return WorkspaceGitStore(
            currentHostScope: { appStore.activeHostScope },
            clientFactory: gitClientFactory
        )
    }

    var gitStatusByPath: [String: GitStatusResponse] {
        get { workspaceGitStore.gitStatusByPath }
        set { workspaceGitStore.gitStatusByPath = newValue }
    }

    var gitStatusErrorByPath: [String: String] {
        get { workspaceGitStore.gitStatusErrorByPath }
        set { workspaceGitStore.gitStatusErrorByPath = newValue }
    }

    var workspaceGitSummaryByPath: [String: GitStatusResponse] {
        get { workspaceGitStore.workspaceGitSummaryByPath }
        set { workspaceGitStore.workspaceGitSummaryByPath = newValue }
    }

    var workspaceGitSummaryUpdatedAtByPath: [String: Date] {
        get { workspaceGitStore.workspaceGitSummaryUpdatedAtByPath }
        set { workspaceGitStore.workspaceGitSummaryUpdatedAtByPath = newValue }
    }

    var refreshingWorkspaceGitSummaryPaths: Set<String> {
        get { workspaceGitStore.refreshingWorkspaceGitSummaryPaths }
        set { workspaceGitStore.refreshingWorkspaceGitSummaryPaths = newValue }
    }

    var isRefreshingGitStatus: Bool {
        get { workspaceGitStore.isRefreshingGitStatus }
        set { workspaceGitStore.isRefreshingGitStatus = newValue }
    }

    var gitActionErrorByPath: [String: String] {
        get { workspaceGitStore.gitActionErrorByPath }
        set { workspaceGitStore.gitActionErrorByPath = newValue }
    }

    var isRunningGitAction: Bool {
        get { workspaceGitStore.isRunningGitAction }
        set { workspaceGitStore.isRunningGitAction = newValue }
    }

    var isCommittingGitChanges: Bool {
        get { workspaceGitStore.isCommittingGitChanges }
        set { workspaceGitStore.isCommittingGitChanges = newValue }
    }

    var isPushingGitBranch: Bool {
        get { workspaceGitStore.isPushingGitBranch }
        set { workspaceGitStore.isPushingGitBranch = newValue }
    }

    var isQuickPublishingGitChanges: Bool {
        get { workspaceGitStore.isQuickPublishingGitChanges }
        set { workspaceGitStore.isQuickPublishingGitChanges = newValue }
    }

    var gitQuickPublishResultByPath: [String: GitQuickPublishResponse] {
        get { workspaceGitStore.gitQuickPublishResultByPath }
        set { workspaceGitStore.gitQuickPublishResultByPath = newValue }
    }

    var gitTestFlightStatusByPath: [String: GitTestFlightStatusResponse] {
        get { workspaceGitStore.gitTestFlightStatusByPath }
        set { workspaceGitStore.gitTestFlightStatusByPath = newValue }
    }

    var gitTestFlightErrorByPath: [String: String] {
        get { workspaceGitStore.gitTestFlightErrorByPath }
        set { workspaceGitStore.gitTestFlightErrorByPath = newValue }
    }

    var isRefreshingGitTestFlightStatus: Bool {
        get { workspaceGitStore.isRefreshingGitTestFlightStatus }
        set { workspaceGitStore.isRefreshingGitTestFlightStatus = newValue }
    }

    var isStartingGitTestFlightRelease: Bool {
        get { workspaceGitStore.isStartingGitTestFlightRelease }
        set { workspaceGitStore.isStartingGitTestFlightRelease = newValue }
    }

    var isCreatingPullRequest: Bool {
        get { workspaceGitStore.isCreatingPullRequest }
        set { workspaceGitStore.isCreatingPullRequest = newValue }
    }

    var pullRequestURLByPath: [String: String] {
        get { workspaceGitStore.pullRequestURLByPath }
        set { workspaceGitStore.pullRequestURLByPath = newValue }
    }

    var pullRequestStatusByPath: [String: GitPullRequestStatusResponse] {
        get { workspaceGitStore.pullRequestStatusByPath }
        set { workspaceGitStore.pullRequestStatusByPath = newValue }
    }

    var pullRequestStatusErrorByPath: [String: String] {
        get { workspaceGitStore.pullRequestStatusErrorByPath }
        set { workspaceGitStore.pullRequestStatusErrorByPath = newValue }
    }

    var isRefreshingPullRequestStatus: Bool {
        get { workspaceGitStore.isRefreshingPullRequestStatus }
        set { workspaceGitStore.isRefreshingPullRequestStatus = newValue }
    }

    var gitRefreshTasksByPath: [String: Task<Void, Never>] {
        get { workspaceGitStore.gitRefreshTasksByPath }
        set { workspaceGitStore.gitRefreshTasksByPath = newValue }
    }

    var gitRefreshRevisionByPath: [String: UInt64] {
        get { workspaceGitStore.gitRefreshRevisionByPath }
        set { workspaceGitStore.gitRefreshRevisionByPath = newValue }
    }

    var gitRefreshDelayNanoseconds: UInt64 {
        get { workspaceGitStore.gitRefreshDelayNanoseconds }
        set { workspaceGitStore.gitRefreshDelayNanoseconds = newValue }
    }
}
