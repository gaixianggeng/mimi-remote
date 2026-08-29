import Foundation

extension CodexAppServerSessionRuntime {
    func turnDeliveryMode() async throws -> TurnDeliveryMode {
        let config = try await ensureConfig()
        return runtimeProvider == "codex"
            && config.runtime.transport.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ssh"
            ? .sharedServerQueue
            : .direct
    }

    func submitTurnOutcome(
        sessionID: SessionID,
        payload: CodexAppServerTurnPayload,
        clientMessageID: ClientMessageID?
    ) async throws -> CodexAppServerTurnSubmissionOutcome {
        guard try await turnDeliveryMode() == .sharedServerQueue else {
            return .direct(try await startTurnOutcome(
                sessionID: sessionID,
                payload: payload,
                clientMessageID: clientMessageID
            ))
        }
        let receipt = try await submitSharedServerQueuedTurn(
            sessionID: sessionID,
            payload: payload,
            clientMessageID: clientMessageID
        )
        return .serverQueued(
            submissionID: receipt.submissionID,
            startedTurnID: receipt.startedTurnID
        )
    }

    func submitSharedServerQueuedTurn(
        sessionID: SessionID,
        payload: CodexAppServerTurnPayload,
        clientMessageID: ClientMessageID?
    ) async throws -> (submissionID: String, startedTurnID: TurnID?) {
        guard let clientMessageID,
              !clientMessageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexAppServerSessionRuntimeError.serverQueueUnavailable("clientUserMessageId")
        }
        guard payload.options.outputSchema == nil else {
            throw CodexAppServerSessionRuntimeError.serverQueueOutputSchemaUnsupported
        }
        guard let context = contextsBySessionID[sessionID] else {
            throw CodexAppServerSessionRuntimeError.sessionNotFound(sessionID)
        }
        guard serverQueueSubmissionSessionIDs.insert(sessionID).inserted else {
            throw CodexAppServerSessionRuntimeError.serverQueueSubmissionInFlight(sessionID)
        }
        defer { serverQueueSubmissionSessionIDs.remove(sessionID) }

        let config = try await ensureConfig()
        let requiredMethods = [
            "thread/queue/add",
            "thread/queue/list",
            "thread/items/list"
        ]
        for method in requiredMethods where !config.policy.allowedMethods.contains(method) {
            throw CodexAppServerSessionRuntimeError.serverQueueUnavailable(method)
        }

        let builder = CodexAppServerRequestBuilder(
            allowlistedProjects: projectsIncludingSessionContext(config.projects, context: context)
        )
        let connection = try await ensureConnection()
        try await ensureThreadResumedOnConnection(
            sessionID: sessionID,
            cwd: context.cwd,
            builder: builder,
            connection: connection
        )

        do {
            let result = try await connection.send(
                try builder.threadQueueAdd(
                    threadID: sessionID,
                    cwd: context.cwd,
                    payload: payload,
                    clientMessageID: clientMessageID
                ),
                timeout: longRunningRequestTimeout
            )
            guard let submission = result?["queuedSubmission"]?.objectValue,
                  let submissionID = submission["id"]?.stringValue,
                  !submissionID.isEmpty,
                  submission["clientUserMessageId"]?.stringValue == clientMessageID else {
                throw AgentAPIError.invalidResponse
            }
            return (submissionID, nil)
        } catch {
            if let method = serverQueueUnavailableMethod(from: error) {
                throw CodexAppServerSessionRuntimeError.serverQueueUnavailable(method)
            }
            // queue/add 是写请求，任何错误都不能直接重发。只允许以同一 client id 做只读三段核对。
            await retireCurrentConnectionAfterRecoverableError(connection, error: error)
            if let reconciliation = try? await reconcileSharedServerQueueSubmission(
                sessionID: sessionID,
                cwd: context.cwd,
                clientMessageID: clientMessageID,
                projects: config.projects
            ) {
                switch reconciliation {
                case .queued(let submissionID):
                    return (submissionID, nil)
                case .started(let turnID):
                    return ("reconciled:\(clientMessageID)", turnID)
                case .notFound:
                    break
                }
            }
            throw error
        }
    }

    func serverQueueUnavailableMethod(from error: Error) -> String? {
        guard case CodexAppServerConnectionError.appServer(let appError) = error else {
            return nil
        }
        let message = appError.message.lowercased()
        if appError.code == -32601
            || message.contains("experimentalapi")
            || message.contains("experimental api")
            || (message.contains("thread/queue/add")
                && (message.contains("unsupported")
                    || message.contains("not supported")
                    || message.contains("not found")
                    || message.contains("not allowed"))) {
            return "thread/queue/add"
        }
        return nil
    }
}

private enum SharedServerQueueReconciliation {
    case queued(submissionID: String)
    case started(turnID: TurnID)
    case notFound
}

private extension CodexAppServerSessionRuntime {
    func reconcileSharedServerQueueSubmission(
        sessionID: SessionID,
        cwd: String,
        clientMessageID: ClientMessageID,
        projects: [AgentProject]
    ) async throws -> SharedServerQueueReconciliation {
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: projects)
        let connection = try await ensureConnection()
        try await ensureThreadResumedOnConnection(
            sessionID: sessionID,
            cwd: cwd,
            builder: builder,
            connection: connection
        )
        if let submissionID = try await queuedSubmissionID(
            sessionID: sessionID,
            clientMessageID: clientMessageID,
            builder: builder,
            connection: connection
        ) {
            return .queued(submissionID: submissionID)
        }
        if let turnID = try await persistedUserItemTurnID(
            sessionID: sessionID,
            clientMessageID: clientMessageID,
            builder: builder,
            connection: connection
        ) {
            return .started(turnID: turnID)
        }
        if let submissionID = try await queuedSubmissionID(
            sessionID: sessionID,
            clientMessageID: clientMessageID,
            builder: builder,
            connection: connection
        ) {
            return .queued(submissionID: submissionID)
        }
        return .notFound
    }

    func queuedSubmissionID(
        sessionID: SessionID,
        clientMessageID: ClientMessageID,
        builder: CodexAppServerRequestBuilder,
        connection: CodexAppServerConnection
    ) async throws -> String? {
        var cursor: String?
        repeat {
            let result = try await connection.send(
                builder.threadQueueList(threadID: sessionID, cursor: cursor),
                timeout: longRunningRequestTimeout
            )
            let object = result?.objectValue ?? [:]
            for entry in object["data"]?.arrayValue?.compactMap(\.objectValue) ?? []
            where entry["clientUserMessageId"]?.stringValue == clientMessageID {
                return entry["id"]?.stringValue
            }
            cursor = object["nextCursor"]?.stringValue
        } while cursor?.isEmpty == false
        return nil
    }

    func persistedUserItemTurnID(
        sessionID: SessionID,
        clientMessageID: ClientMessageID,
        builder: CodexAppServerRequestBuilder,
        connection: CodexAppServerConnection
    ) async throws -> TurnID? {
        var cursor: String?
        repeat {
            let result = try await connection.send(
                builder.threadItemsList(threadID: sessionID, cursor: cursor),
                timeout: longRunningRequestTimeout
            )
            let object = result?.objectValue ?? [:]
            for entry in object["data"]?.arrayValue?.compactMap(\.objectValue) ?? [] {
                guard let item = entry["item"]?.objectValue,
                      item["type"]?.stringValue == "userMessage",
                      item["clientId"]?.stringValue == clientMessageID else { continue }
                guard let turnID = entry["turnId"]?.stringValue,
                      !turnID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AgentAPIError.invalidResponse
                }
                return turnID
            }
            cursor = object["nextCursor"]?.stringValue
        } while cursor?.isEmpty == false
        return nil
    }
}
