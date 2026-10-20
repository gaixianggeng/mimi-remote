import Foundation

/// 改动面板里写在某个 hunk 上的审查备注。只存在面板内存里，不落盘。
struct GitReviewComment: Identifiable, Hashable {
    let id = UUID()
    let workspacePath: String
    let hunkKey: String
    let filePath: String
    let hunkHeader: String
    let body: String
    let createdAt: Date

    var hunkTitle: String {
        filePath.isEmpty ? hunkHeader : "\(filePath) · \(hunkHeader)"
    }
}

/// 把审查备注整理成一条交给 Agent 的修改请求。格式要稳定：首行说明意图，
/// 之后每条备注一行「`路径` · hunk 标题：备注」，Agent 不必再猜是哪个文件哪段代码。
enum GitReviewNotesAgentMessage {
    /// 语言跟随 App 设置，和用户在界面上看到的一致。
    static func make(from comments: [GitReviewComment]) -> String {
        let lines = comments.compactMap(line(for:))
        guard !lines.isEmpty else {
            return ""
        }
        return ([L10n.text("ui.review_notes_agent_intro")] + lines).joined(separator: "\n")
    }

    private static func line(for comment: GitReviewComment) -> String? {
        let note = singleLine(comment.body)
        guard !note.isEmpty else {
            return nil
        }
        let header = singleLine(comment.hunkHeader)
        let path = singleLine(comment.filePath)
        let item = path.isEmpty
            ? L10n.format("ui.review_notes_agent_line_without_path", header, note)
            : L10n.format("ui.review_notes_agent_line", path, header, note)
        return "- \(item)"
    }

    /// 多行备注压成一行，保证「一条备注一行」，Agent 和用户都能按行对照。
    private static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// 记录每个工作区哪些备注已经放进过哪个会话的输入框。再次发送时只补新写的备注，
/// 草稿里不会重复；全部发过时再点一次表示整份重新放入（例如用户删掉了草稿）。
struct GitReviewNotesHandoff: Equatable {
    private struct Delivery: Equatable {
        let sessionID: SessionID
        var sessionTitle: String
        var commentIDs: Set<UUID>
    }

    private var deliveriesByWorkspace: [String: Delivery] = [:]

    func commentsToSend(
        from comments: [GitReviewComment],
        workspacePath: String,
        sessionID: SessionID
    ) -> [GitReviewComment] {
        guard let delivery = deliveriesByWorkspace[workspacePath], delivery.sessionID == sessionID else {
            return comments
        }
        let unsent = comments.filter { !delivery.commentIDs.contains($0.id) }
        return unsent.isEmpty ? comments : unsent
    }

    /// 当前备注全部放进过输入框时返回那个会话的标题，用来显示「已放入」反馈。
    func sentSessionTitle(for comments: [GitReviewComment], workspacePath: String) -> String? {
        guard let delivery = deliveriesByWorkspace[workspacePath],
              !comments.isEmpty,
              comments.allSatisfy({ delivery.commentIDs.contains($0.id) })
        else {
            return nil
        }
        return delivery.sessionTitle
    }

    mutating func record(
        _ comments: [GitReviewComment],
        workspacePath: String,
        sessionID: SessionID,
        sessionTitle: String
    ) {
        let sentIDs = Set(comments.map(\.id))
        if var delivery = deliveriesByWorkspace[workspacePath], delivery.sessionID == sessionID {
            delivery.sessionTitle = sessionTitle
            delivery.commentIDs.formUnion(sentIDs)
            deliveriesByWorkspace[workspacePath] = delivery
        } else {
            deliveriesByWorkspace[workspacePath] = Delivery(
                sessionID: sessionID,
                sessionTitle: sessionTitle,
                commentIDs: sentIDs
            )
        }
    }

    mutating func reset(workspacePath: String) {
        deliveriesByWorkspace.removeValue(forKey: workspacePath)
    }
}

enum ReviewNotesAgentUnavailableReason: Equatable {
    case noSession
    case otherWorkspace
    case heldOnComputer
    case readOnly
    case notControllable
    case runtimeUnavailable

    var message: String {
        switch self {
        case .noSession:
            return L10n.text("ui.review_notes_agent_unavailable_no_session")
        case .otherWorkspace:
            return L10n.text("ui.review_notes_agent_unavailable_other_workspace")
        case .heldOnComputer:
            return L10n.text("ui.review_notes_agent_unavailable_held_on_computer")
        case .readOnly:
            return L10n.text("ui.review_notes_agent_unavailable_read_only")
        case .notControllable:
            return L10n.text("ui.review_notes_agent_unavailable_not_controllable")
        case .runtimeUnavailable:
            return L10n.text("ui.review_notes_agent_unavailable_runtime")
        }
    }
}

/// 备注只发给「当前选中、且工作目录就是这个工作区」的会话；其余情况给出不能发的原因。
enum ReviewNotesAgentTarget: Equatable {
    case session(SessionID)
    case unavailable(ReviewNotesAgentUnavailableReason)

    static func resolve(
        workspacePath: String,
        session: AgentSession?,
        sessionDirectory: String,
        canControlSession: Bool,
        isRuntimeAvailable: Bool
    ) -> ReviewNotesAgentTarget {
        guard let session else {
            return .unavailable(.noSession)
        }
        let workspace = WorkspacePathIdentity.normalizedPath(workspacePath)
        guard !workspace.isEmpty, WorkspacePathIdentity.normalizedPath(sessionDirectory) == workspace else {
            return .unavailable(.otherWorkspace)
        }
        // 被电脑持有也是一种只读，但原因不同、可接管，先单独说明。
        if session.isHeldOnComputer {
            return .unavailable(.heldOnComputer)
        }
        if !session.allowsDirectInput {
            return .unavailable(.readOnly)
        }
        if !canControlSession {
            return .unavailable(.notControllable)
        }
        if !isRuntimeAvailable {
            return .unavailable(.runtimeUnavailable)
        }
        return .session(session.id)
    }
}

extension SessionStore {
    func reviewNotesAgentTarget(workspacePath: String) -> ReviewNotesAgentTarget {
        let session = selectedSession
        return .resolve(
            workspacePath: workspacePath,
            session: session,
            sessionDirectory: session.map(workingDirectory(of:)) ?? "",
            canControlSession: canControlSession(session),
            isRuntimeAvailable: isRuntimeAvailable(runtimeProviderForTurn(session: session) ?? "codex")
        )
    }

    /// 会话没带目录时退回它所属工作区的路径，与改动面板取 Git 路径的兜底一致。
    private func workingDirectory(of session: AgentSession) -> String {
        if !session.dir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return session.dir
        }
        return (sidebarProjectsByID[session.projectID] ?? projectsByID[session.projectID])?.path ?? ""
    }
}
