import Foundation

enum WriterConflictForkAvailability: Hashable {
    case checking
    case available(lastTurnID: TurnID?)
    case unavailableNoTerminalTurn
    case failed
}

enum WriterConflictSharedGuideStatus: Equatable {
    case activeConflict
    case retrying
    case duplicating
    case offline
    case connectionTerminated(ConnectionTerminationStatus)
    case unavailable
}

struct WriterConflictForkPreparationID: Hashable {
    let lease: HostSessionLease
    let revision: UInt64
    let sourceIsRunning: Bool
    let writerRetryIsRunning: Bool
}

extension SessionStore {
    var activeHostPlatform: HostPlatform {
        appStore.activeConnectionProfile?.hostPlatform ?? .unknown
    }

    var selectedWriterConflictLease: HostSessionLease? {
        guard let selectedSessionID else { return nil }
        return writerConflictForkLease(for: selectedSessionID)
    }

    var selectedWriterConflictForkAvailability: WriterConflictForkAvailability? {
        guard let session = selectedSession,
              hasActiveWriterConflict(sessionID: session.id),
              supportsCodexThreadManagement(session)
        else { return nil }

        let lease = writerConflictForkLease(for: session.id)
        if let availability = writerConflictForkAvailabilityByLease[lease] {
            // 空闲时缓存的 .available(lastTurnID: nil) 不能复用于刚转入运行中的会话；
            // 在重新探测到最近已完成回合前统一映射为 .checking，避免界面短暂承诺可分支。
            if session.isRunning, availability == .available(lastTurnID: nil) {
                return .checking
            }
            return availability
        }
        return session.isRunning ? .checking : .available(lastTurnID: nil)
    }

    /// 引导弹层打开期间实时判定当前引导状态：连接终止（例如凭据失效）、断网、正在重试或复制中
    /// 都不能误报为「可马上分支」；冲突提示消失后也不断言写入权已恢复，统一退回 `.unavailable`
    /// 提示返回会话页查看最新连接与锁定状态。
    func writerConflictSharedGuideStatus(
        originLease: HostSessionLease?
    ) -> WriterConflictSharedGuideStatus {
        if let connectionTermination {
            return .connectionTerminated(connectionTermination)
        }
        if appStore.requiresRePairing {
            return .connectionTerminated(.credentialsInvalid)
        }
        if isNetworkUnavailable {
            return .offline
        }
        if let originLease,
           let session = selectedSession,
           writerConflictForkLease(for: session.id) != originLease {
            return .unavailable
        }
        if selectedSessionShowsWriterConflictCard {
            if isDuplicatingSelectedWriterConflictSession {
                return .duplicating
            }
            if isRetryingSelectedWriterConflict {
                return .retrying
            }
            return .activeConflict
        }
        guard let session = selectedSession else {
            return .unavailable
        }
        if case .unavailable(let reason) = conversationReadiness(for: session) {
            return .connectionTerminated(reason)
        }
        return .unavailable
    }

    var selectedWriterConflictForkErrorMessage: String? {
        guard let selectedSessionID else { return nil }
        return writerConflictForkErrorByLease[writerConflictForkLease(for: selectedSessionID)]
    }

    var selectedWriterConflictForkPreparationID: WriterConflictForkPreparationID? {
        guard let session = selectedSession,
              hasActiveWriterConflict(sessionID: session.id),
              supportsCodexThreadManagement(session)
        else { return nil }

        return WriterConflictForkPreparationID(
            lease: writerConflictForkLease(for: session.id),
            revision: writerConflictForkPreparationRevision,
            sourceIsRunning: session.isRunning,
            writerRetryIsRunning: webSocketStatus == .connecting
        )
    }

    var isDuplicatingSelectedWriterConflictSession: Bool {
        guard let selectedSessionID else { return false }
        return duplicatingSessionIDs.contains(selectedSessionID)
    }

    var isRetryingSelectedWriterConflict: Bool {
        selectedSessionHasActiveWriterConflict
            && (isRefreshingSelectedSession || webSocketStatus == .connecting)
    }

    func retrySelectedSessionWriterAccess() async {
        guard let session = selectedSession,
              hasActiveWriterConflict(sessionID: session.id),
              !isRefreshingSelectedSession,
              webSocketStatus != .connecting
        else { return }

        let selectionLease = currentSelectionLease()
        setErrorMessage(nil)
        clearSelectedWriterConflictForkError()
        disconnectWebSocket()

        // 用户点“重试”也表示要看 Desktop 侧刚产生的最新消息。先强制刷新历史，
        // 再用 thread/resume 重判 writer，避免连接先恢复后仍展示旧快照。
        let didRefresh = await refreshSelectedSessionContent(
            session,
            successStatusMessage: nil,
            reason: .writerRetry
        )

        guard !Task.isCancelled,
              isSelectionLeaseCurrent(selectionLease),
              hasActiveWriterConflict(sessionID: session.id)
        else { return }
        guard didRefresh else {
            writerConflictForkErrorByLease[writerConflictForkLease(for: session.id)] = L10n.text(
                "ui.writer_conflict_retry_refresh_failed"
            )
            return
        }

        // thread/resume 是公开协议中唯一可信的 writer 检查。必须强制建立新连接，
        // 不能复用曾在发送阶段返回冲突的 connected socket。
        let refreshedSession = sessionsByID[session.id] ?? session
        connectWebSocket(
            refreshedSession,
            replayBufferedEvents: false,
            allowNonRunning: true
        )
    }

    func prepareSelectedWriterConflictForkAvailability(force: Bool = false) async {
        guard let session = selectedSession,
              hasActiveWriterConflict(sessionID: session.id),
              supportsCodexThreadManagement(session),
              webSocketStatus != .connecting,
              !duplicatingSessionIDs.contains(session.id)
        else { return }

        let lease = writerConflictForkLease(for: session.id)
        if !session.isRunning {
            writerConflictForkAvailabilityByLease[lease] = .available(lastTurnID: nil)
            writerConflictForkErrorByLease.removeValue(forKey: lease)
            return
        }

        if !force, let cached = writerConflictForkAvailabilityByLease[lease] {
            // idle 时的 nil 表示“复制最新状态”，不能复用于随后开始运行的 source；
            // running 必须重新读取最近的终态 Turn，避免按钮可点但复制被安全门禁拒绝。
            if cached != .available(lastTurnID: nil) {
                return
            }
            writerConflictForkAvailabilityByLease.removeValue(forKey: lease)
        }

        let hostScope = appStore.activeHostScope
        let sourceThreadID = normalizedOptional(session.resumeID) ?? session.id
        writerConflictForkAvailabilityByLease[lease] = .checking
        writerConflictForkErrorByLease.removeValue(forKey: lease)

        do {
            let client = try clientFactory()
            // economy 只读取最近 Turn 的 summary，不加载大图片或工具明细。
            // latestForkableTurnID 直接来自原始 Turn，即使该轮没有可见消息也不会丢失边界。
            let page = try await client.messagesPage(
                sessionID: sourceThreadID,
                before: nil,
                limit: 2,
                loadMode: .economy
            )
            guard appStore.activeHostScope == hostScope,
                  hasActiveWriterConflict(sessionID: session.id)
            else { return }

            // 网络返回期间 source 可能已经结束运行。此时应复制最新状态，
            // 不能继续使用请求发出时捕获的旧 Turn 边界。
            let currentSource = sessions.first(where: { $0.id == session.id }) ?? session
            if !currentSource.isRunning {
                writerConflictForkAvailabilityByLease[lease] = .available(lastTurnID: nil)
            } else if let lastTurnID = page.latestForkableTurnID {
                writerConflictForkAvailabilityByLease[lease] = .available(lastTurnID: lastTurnID)
            } else {
                writerConflictForkAvailabilityByLease[lease] = .unavailableNoTerminalTurn
            }
        } catch {
            guard !Task.isCancelled,
                  appStore.activeHostScope == hostScope,
                  hasActiveWriterConflict(sessionID: session.id)
            else { return }
            writerConflictForkAvailabilityByLease[lease] = .failed
            writerConflictForkErrorByLease[lease] = L10n.format(
                "ui.writer_conflict_fork_check_failed_value",
                error.localizedDescription
            )
        }
    }

    @discardableResult
    func duplicateSelectedWriterConflictSession() async -> Bool {
        guard let session = selectedSession,
              hasActiveWriterConflict(sessionID: session.id),
              supportsCodexThreadManagement(session),
              case .available(let lastTurnID) = selectedWriterConflictForkAvailability
        else { return false }

        // 运行中的 source 只能从明确的终态 Turn 分叉。nil 只表示 source 已经空闲，
        // 此时 App Server 按最新持久化状态复制。
        guard !session.isRunning || lastTurnID != nil else { return false }
        return await duplicateSessionInCurrentWorkspace(
            session,
            lastTurnID: lastTurnID,
            allowActiveWriterConflict: true
        )
    }

    func clearSelectedWriterConflictForkError() {
        guard let selectedSessionID else { return }
        writerConflictForkErrorByLease.removeValue(
            forKey: writerConflictForkLease(for: selectedSessionID)
        )
    }

    func clearAllWriterConflictForkState() {
        writerConflictForkAvailabilityByLease.removeAll()
        writerConflictForkErrorByLease.removeAll()
        writerConflictForkPreparationRevision &+= 1
    }

    private func writerConflictForkLease(for sessionID: SessionID) -> HostSessionLease {
        HostSessionLease(hostScope: appStore.activeHostScope, sessionID: sessionID)
    }
}
