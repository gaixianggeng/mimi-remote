import XCTest
@testable import MimiRemote

final class CodexAppServerProtocolTests: XCTestCase {
    func testFullHistoryTurnPageLimitUsesAdaptiveLadderValuesExactly() {
        // MIM-48：默认首屏的 20 条消息仍折算为 10 个 turn；进入超限恢复后，
        // 5/2/1 必须作为精确 turn 数下发，否则会被旧的最小 10 turn 规则吞掉，
        // 自适应缩页看似重试、实际却持续请求同一大页。
        XCTAssertEqual(
            CodexAppServerSessionRuntime.threadTurnPageLimit(forMessageLimit: 20, loadMode: .full),
            10
        )
        XCTAssertEqual(
            CodexAppServerSessionRuntime.threadTurnPageLimit(forMessageLimit: 5, loadMode: .full),
            5
        )
        XCTAssertEqual(
            CodexAppServerSessionRuntime.threadTurnPageLimit(forMessageLimit: 2, loadMode: .full),
            2
        )
        XCTAssertEqual(
            CodexAppServerSessionRuntime.threadTurnPageLimit(forMessageLimit: 1, loadMode: .full),
            1
        )
    }

    func testLiveWindowsHostHealthFromPhysicalDevice() async throws {
        guard let rawEndpoint = ProcessInfo.processInfo.environment["MIMI_LIVE_WINDOWS_ENDPOINT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawEndpoint.isEmpty
        else {
            throw XCTSkip("仅在显式提供 Windows 宿主 Endpoint 时运行真机网络验证")
        }
        let endpoint = try EndpointTransportPolicy.validatedEndpoint(rawEndpoint)
        guard var components = URLComponents(string: endpoint) else {
            return XCTFail("Windows 宿主 Endpoint 无法解析")
        }
        components.path = "/healthz"
        components.query = nil
        components.fragment = nil
        guard let healthURL = components.url else {
            return XCTFail("Windows 宿主 health URL 无法构造")
        }

        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 12
        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 200)
        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(payload?["ok"] as? Bool, true)
        XCTAssertFalse((payload?["version"] as? String ?? "").isEmpty)
    }

    @MainActor
    func testLivePersistedWindowsConnectionFromPhysicalDevice() async throws {
        guard let expectedPath = ProcessInfo.processInfo.environment["MIMI_LIVE_WINDOWS_EXPECTED_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !expectedPath.isEmpty
        else {
            throw XCTSkip("仅在显式提供 Windows 工作区原始路径时验证真机持久化配对")
        }

        // 直接从 App 的 UserDefaults 与 Keychain 恢复现有配对，验证冷启动不是只显示
        // 缓存的“已连接”，同时避免把 Token、配对码或二维码写入测试输出。
        let appStore = AppStore()
        XCTAssertNotNil(appStore.activeConnectionProfile)
        XCTAssertFalse(appStore.token.isEmpty, "冷启动应从 Keychain 恢复当前 Windows 凭据")
        XCTAssertTrue(appStore.isConfigured)

        let client = try appStore.makeSessionStoreAPIClient()
        let projects = try await client.projects()
        let project = try XCTUnwrap(
            projects.first(where: { $0.path == expectedPath }),
            "项目发现应返回并原样保留 Windows 路径：\(expectedPath)"
        )
        let page = try await client.sessionsPage(
            projectID: project.id,
            cursor: nil,
            limit: 20,
            consistency: .authoritative
        )
        XCTAssertFalse(page.sessions.isEmpty, "Windows thread/list 应返回至少一个会话")
        XCTAssertTrue(
            page.sessions.allSatisfy { $0.dir == expectedPath },
            "thread/list cwd 必须保留原始 Windows 路径"
        )
    }

    @MainActor
    func testLivePersistedWindowsCreateResumeAndSendFromPhysicalDevice() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let expectedPath = environment["MIMI_LIVE_WINDOWS_EXPECTED_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !expectedPath.isEmpty,
            let prompt = environment["MIMI_LIVE_WINDOWS_MESSAGE"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !prompt.isEmpty,
            let expectedReply = environment["MIMI_LIVE_WINDOWS_EXPECTED_REPLY"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !expectedReply.isEmpty
        else {
            throw XCTSkip("仅在显式提供 Windows 路径、测试消息和预期回复时运行端到端真机验证")
        }

        let appStore = AppStore()
        let client = try appStore.makeSessionStoreAPIClient()
        let projects = try await client.projects()
        let project = try XCTUnwrap(projects.first(where: { $0.path == expectedPath }))
        let modelOptions = try await client.modelOptions()
        let model = try XCTUnwrap(
            modelOptions.first(where: {
                $0.isDefault && $0.runtimeProvider?.lowercased() != "claude"
            }) ?? modelOptions.first(where: {
                !$0.hidden && $0.runtimeProvider?.lowercased() != "claude"
            }),
            "Windows Codex 应返回至少一个可用模型"
        )
        let turnOptions = CodexAppServerTurnOptions(
            runtimeProvider: model.runtimeProvider,
            model: model.model,
            modelProvider: model.provider,
            reasoningEffort: model.defaultReasoningEffort
                .flatMap(CodexAppServerReasoningEffort.init(rawValue:)) ?? .xhigh
        )
        let existingPage = try await client.sessionsPage(
            projectID: project.id,
            cursor: nil,
            limit: 50,
            consistency: .authoritative
        )
        let existingSession = existingPage.sessions.first {
            $0.dir == expectedPath &&
                ($0.preview?.contains(prompt) == true || $0.title.contains(prompt))
        }
        let sessionID: String
        if let existingSession {
            // 真机验证可能因设备连接或服务端限流而重跑。复用同一验收会话，避免每次
            // 都向用户的 Windows thread store 写入一条重复记录。
            sessionID = existingSession.id
        } else {
            // createSession 会经同一 app-server runtime 依次发送 thread/start 与首个
            // turn/start；使用独立会话避免把验收消息写入用户已有上下文。
            let created = try await client.createSession(
                CreateSessionRequest(
                    projectID: project.id,
                    projectPath: project.path,
                    projectName: project.name,
                    prompt: prompt,
                    turnOptions: turnOptions,
                    resumeID: "",
                    clientMessageID: "mim13-\(UUID().uuidString)"
                )
            )
            XCTAssertEqual(created.session.dir, expectedPath)
            XCTAssertFalse(created.session.id.isEmpty)
            sessionID = created.session.id
        }

        var observedMessages: [CodexHistoryMessage] = []
        var lastHistoryError: Error?
        for _ in 0..<36 {
            do {
                // economy 使用 summary itemsView；5 秒间隔既覆盖异步回复，又不会触发
                // Windows app-server 对 thread/turns/list full 查询的临时限流。
                observedMessages = try await client.messagesPage(
                    sessionID: sessionID,
                    before: nil,
                    limit: 20,
                    loadMode: .economy
                ).messages
                lastHistoryError = nil
            } catch {
                // Windows 上 thread/start 先创建 rollout 文件，再异步写入首条元数据；
                // 文件存在但仍为空的极短窗口不能让端到端验收提前失败。
                lastHistoryError = error
                try await Task.sleep(for: .seconds(5))
                continue
            }
            let sentMessageExists = observedMessages.contains {
                $0.role == MessageRole.user.rawValue && $0.content.contains(prompt)
            }
            let replyExists = observedMessages.contains {
                $0.role == MessageRole.assistant.rawValue && $0.content.contains(expectedReply)
            }
            if sentMessageExists && replyExists {
                break
            }
            try await Task.sleep(for: .seconds(5))
        }
        XCTAssertTrue(
            observedMessages.contains {
                $0.role == MessageRole.user.rawValue && $0.content.contains(prompt)
            },
            "新建会话应持久化 iPad 发出的测试消息，最后错误：\(lastHistoryError?.localizedDescription ?? "无")"
        )
        XCTAssertTrue(
            observedMessages.contains {
                $0.role == MessageRole.assistant.rawValue && $0.content.contains(expectedReply)
            },
            "Windows Codex 应返回预期验收回复，最后错误：\(lastHistoryError?.localizedDescription ?? "无")"
        )

        let resumed = try await client.session(id: sessionID, afterSeq: nil)
        XCTAssertEqual(resumed.session.id, sessionID)
        XCTAssertEqual(resumed.session.dir, expectedPath)

        let page = try await client.sessionsPage(
            projectID: project.id,
            cursor: nil,
            limit: 50,
            consistency: .authoritative
        )
        XCTAssertTrue(
            page.sessions.contains(where: { $0.id == sessionID && $0.dir == expectedPath }),
            "新会话应能通过 Windows thread/list 恢复"
        )
    }

    func testWorktreeDeleteResponseDecodesLegacyAndRegistryCleanupWarning() throws {
        let legacyJSON = #"{"deleted_path":"/tmp/worktree-a","worktrees":[]}"#
        let legacy = try AgentAPIClient.decoder.decode(WorktreeDeleteResponse.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(legacy.deletedPath, "/tmp/worktree-a")
        XCTAssertNil(legacy.registryCleanupError)

        let warningJSON = #"{"deleted_path":"/tmp/worktree-a","worktrees":[],"registry_cleanup_error":"registry 文件只读"}"#
        let warning = try AgentAPIClient.decoder.decode(WorktreeDeleteResponse.self, from: Data(warningJSON.utf8))
        XCTAssertEqual(warning.registryCleanupError, "registry 文件只读")
    }

    func testWorktreePruneResponseDecodesLegacyAndPartialFailures() throws {
        let legacyJSON = #"{"pruned_paths":["/tmp/worktree-a"],"worktrees":[]}"#
        let legacy = try AgentAPIClient.decoder.decode(WorktreePruneResponse.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(legacy.prunedPaths, ["/tmp/worktree-a"])
        XCTAssertNil(legacy.failedPaths)

        let partialJSON = #"{"pruned_paths":["/tmp/worktree-a"],"worktrees":[],"failed_paths":{"/tmp/worktree-b":"permission denied"}}"#
        let partial = try AgentAPIClient.decoder.decode(WorktreePruneResponse.self, from: Data(partialJSON.utf8))
        XCTAssertEqual(partial.failedPaths, ["/tmp/worktree-b": "permission denied"])
    }

    func testWorktreeCleanupResponseDecodesPolicyCandidatesAndBlockers() throws {
        let json = #"""
        {
          "dry_run": true,
          "plan_id": "wtc_preview_1",
          "policy": {
            "auto_delete": false,
            "candidate_after_days": 30,
            "keep_latest_per_project": 3
          },
          "generated_at": "2027-01-15T08:30:00Z",
          "worktrees": [
            {
              "workspace": {
                "id": "ws_cleanup",
                "name": "old-review",
                "path": "/tmp/mimi-worktrees/proj/old-review",
                "root_project_id": "proj",
                "root_project_name": "Project",
                "root_project_path": "/tmp/proj"
              },
              "worktree": {
                "path": "/tmp/mimi-worktrees/proj/old-review",
                "repository_path": "/tmp/proj",
                "base": "main",
                "branch": "mimi/old-review",
                "git_state": "dirty",
                "dirty": true,
                "root_project_id": "proj",
                "root_project_name": "Project",
                "root_project_path": "/tmp/proj"
              },
              "created_at": "2026-10-01T08:00:00Z",
              "last_used_at": "2026-10-10T09:00:00Z",
              "eligible": false,
              "blockers": [
                "git_dirty"
              ]
            }
          ],
          "candidate_paths": [],
          "deleted_paths": []
        }
        """#

        let response = try AgentAPIClient.decoder.decode(WorktreeCleanupResponse.self, from: Data(json.utf8))

        XCTAssertFalse(response.policy.autoDelete)
        XCTAssertTrue(response.dryRun)
        XCTAssertEqual(response.planID, "wtc_preview_1")
        XCTAssertEqual(response.policy.candidateAfterDays, 30)
        XCTAssertEqual(response.policy.keepLatestPerProject, 3)
        XCTAssertEqual(response.worktrees.first?.worktree.gitState, "dirty")
        XCTAssertEqual(response.worktrees.first?.blockers, [
            WorktreeCleanupBlocker(rawValue: "git_dirty")
        ])
        XCTAssertEqual(response.worktrees.first?.blockers.first?.message, L10n.text("ui.contains_uncommitted_changes"))
        XCTAssertEqual(WorktreeCleanupBlocker(rawValue: "future_guard").message, L10n.text("ui.agentd_returned_a_new_protection_reason"))
        XCTAssertTrue(response.candidatePaths.isEmpty)
        XCTAssertTrue(response.deletedPaths.isEmpty)
        XCTAssertNil(response.failedPath)
        XCTAssertNil(response.error)
        XCTAssertFalse(response.hasPartialFailure)
    }

    func testWorktreeCleanupResponseDecodesStructuredPartialFailure() throws {
        let json = #"""
        {
          "dry_run": false,
          "plan_id": "wtc_consumed",
          "policy": {
            "auto_delete": false,
            "candidate_after_days": 30,
            "keep_latest_per_project": 3
          },
          "generated_at": "2027-01-15T08:30:00Z",
          "worktrees": [],
          "candidate_paths": [],
          "deleted_paths": ["/tmp/worktree-a"],
          "failed_path": "/tmp/worktree-b",
          "error": "git worktree remove 失败"
        }
        """#

        let response = try AgentAPIClient.decoder.decode(WorktreeCleanupResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.deletedPaths, ["/tmp/worktree-a"])
        XCTAssertEqual(response.failedPath, "/tmp/worktree-b")
        XCTAssertEqual(response.error, "git worktree remove 失败")
        XCTAssertTrue(response.hasPartialFailure)
        XCTAssertEqual(
            response.partialFailureMessage,
            L10n.format(
                "ui.worktree_cleanup_partial_failure",
                L10n.plural("ui.worktrees_deleted_count", count: 1),
                "/tmp/worktree-b",
                "git worktree remove 失败"
            )
        )
    }

    func testWorktreeCleanupRequestKeepsPreviewEmptyAndExecutionExplicit() throws {
        let previewData = try JSONEncoder().encode(WorktreeCleanupRequest.preview)
        let preview = try XCTUnwrap(JSONSerialization.jsonObject(with: previewData) as? [String: Any])
        XCTAssertTrue(preview.isEmpty, "dry_run 缺省应由服务端解释为 true")

        let executionData = try JSONEncoder().encode(WorktreeCleanupRequest.confirmed(
            paths: ["/tmp/worktree-a"],
            planID: "wtc_preview_1"
        ))
        let execution = try XCTUnwrap(JSONSerialization.jsonObject(with: executionData) as? [String: Any])
        XCTAssertEqual(execution["dry_run"] as? Bool, false)
        XCTAssertEqual(execution["confirm"] as? Bool, true)
        XCTAssertEqual(execution["paths"] as? [String], ["/tmp/worktree-a"])
        XCTAssertEqual(execution["plan_id"] as? String, "wtc_preview_1")
        XCTAssertNil(execution["force"])
    }

    func testWireMessageClassifiesResponseNotificationAndServerRequest() throws {
        let decoder = JSONDecoder()

        let response = try decoder.decode(CodexAppServerMessage.self, from: Data(#"{"id":1,"result":{"ok":true}}"#.utf8))
        XCTAssertEqual(response, .response(CodexAppServerResponse(id: .int(1), result: .object(["ok": .bool(true)]), error: nil)))

        let notification = try decoder.decode(CodexAppServerMessage.self, from: Data(#"{"method":"turn/started","params":{"threadId":"t1"},"_alleycat_seq":17}"#.utf8))
        XCTAssertEqual(notification, .notification(CodexAppServerNotification(
            method: "turn/started",
            params: .object(["threadId": .string("t1")]),
            replaySequence: 17
        )))

        let serverRequest = try decoder.decode(CodexAppServerMessage.self, from: Data(#"{"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"t1"},"_alleycat_seq":18}"#.utf8))
        XCTAssertEqual(serverRequest, .serverRequest(CodexAppServerServerRequest(
            id: .string("approval-1"),
            method: "item/commandExecution/requestApproval",
            params: .object(["threadId": .string("t1")]),
            replaySequence: 18
        )))
    }

    func testTurnSendOutcomeOnlyTreatsExplicitPreAcceptanceErrorsAsRejected() {
        let rejectedByData = CodexAppServerConnectionError.appServer(CodexAppServerError(
            code: -32603,
            message: "runtime override rejected",
            data: .object(["accepted": .bool(false)])
        ))
        let invalidParams = CodexAppServerConnectionError.appServer(CodexAppServerError(
            code: -32602,
            message: "invalid params",
            data: nil
        ))
        let ambiguousInternalError = CodexAppServerConnectionError.appServer(CodexAppServerError(
            code: -32603,
            message: "internal error",
            data: nil
        ))
        let activeTurnConflict = CodexAppServerConnectionError.appServer(CodexAppServerError(
            code: -32602,
            message: "thread already has active turn",
            data: .object([
                "accepted": .bool(false),
                "reason": .string("active_turn"),
                "activeTurnId": .string("turn-live")
            ])
        ))

        XCTAssertEqual(
            CodexAppServerSessionWebSocketClient.turnSendOutcome(for: activeTurnConflict),
            .activeTurnConflict(
                activeTurnID: "turn-live",
                message: activeTurnConflict.localizedDescription
            )
        )
        XCTAssertEqual(
            CodexAppServerSessionWebSocketClient.turnSendOutcome(for: rejectedByData),
            .rejected(message: rejectedByData.localizedDescription)
        )
        XCTAssertEqual(
            CodexAppServerSessionWebSocketClient.turnSendOutcome(for: invalidParams),
            .rejected(message: invalidParams.localizedDescription)
        )
        XCTAssertEqual(
            CodexAppServerSessionWebSocketClient.turnSendOutcome(for: ambiguousInternalError),
            .uncertain(message: ambiguousInternalError.localizedDescription)
        )
        XCTAssertEqual(
            CodexAppServerSessionWebSocketClient.turnSendOutcome(
                for: CodexAppServerConnectionError.timeout(method: "turn/start", id: .int(7))
            ),
            .uncertain(message: CodexAppServerConnectionError.timeout(method: "turn/start", id: .int(7)).localizedDescription)
        )
    }

    func testTurnStartBuilderUsesRemoteSafeDefaults() throws {
        let project = AgentProject(id: "repo", name: "Repo", path: "/Users/me/repo")
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [project])
        let request = try builder.turnStart(
            threadID: "thread-1",
            projectID: "repo",
            prompt: "帮我看一下",
            clientMessageID: "client-1"
        )
        let params = try XCTUnwrap(request.params?.objectValue)
        XCTAssertEqual(request.method, "turn/start")
        XCTAssertEqual(params["cwd"]?.stringValue, "/Users/me/repo")
        XCTAssertNil(params["model"]?.stringValue)
        XCTAssertEqual(params["effort"]?.stringValue, "xhigh")
        XCTAssertEqual(params["approvalPolicy"]?.stringValue, "on-request")
        XCTAssertEqual(params["clientUserMessageId"]?.stringValue, "client-1")
        XCTAssertEqual(params["collaborationMode"]?.objectValue?["mode"]?.stringValue, "default")

        let sandbox = try XCTUnwrap(params["sandboxPolicy"]?.objectValue)
        XCTAssertEqual(sandbox["type"]?.stringValue, "dangerFullAccess")
        XCTAssertEqual(sandbox["networkAccess"]?.boolValue, false)
        XCTAssertNil(sandbox["writableRoots"])
    }

    func testAccountTokenUsageBuilderAndParserPreserveInt64AndNullableBuckets() async throws {
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [])
        XCTAssertEqual(builder.accountUsageRead().method, "account/usage/read")
        XCTAssertNil(builder.accountUsageRead().params)
        XCTAssertEqual(
            builder.accountUsageRead(forceRefresh: true).params?.objectValue?["mimiForceRefresh"]?.boolValue,
            true
        )

        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "test"
        )
        let payload = CodexAppServerJSONValue.object([
            "summary": .object([
                "lifetimeTokens": .int(50_160_000_000)
            ]),
            "dailyUsageBuckets": .array([
                .object([
                    "startDate": .string("2026-07-30"),
                    "tokens": .int(9_223_372_036)
                ]),
                .object([
                    "startDate": .string("2026-07-29"),
                    "tokens": .int(-10)
                ])
            ])
        ])

        let parsedSnapshot = await runtime.accountTokenUsageSnapshot(fromPayload: payload)
        let snapshot = try XCTUnwrap(parsedSnapshot)
        XCTAssertEqual(snapshot.summary.lifetimeTokens, 50_160_000_000)
        XCTAssertEqual(
            snapshot.dailyUsageBuckets,
            [
                AccountTokenUsageDailyBucket(
                    startDate: "2026-07-30",
                    tokens: 9_223_372_036
                ),
                AccountTokenUsageDailyBucket(startDate: "2026-07-29", tokens: 0)
            ]
        )

        let parsedNullBuckets = await runtime.accountTokenUsageSnapshot(
            fromPayload: .object([
                "summary": .object([:]),
                "dailyUsageBuckets": .null
            ])
        )
        let nullBuckets = try XCTUnwrap(parsedNullBuckets)
        XCTAssertNil(nullBuckets.summary.lifetimeTokens)
        XCTAssertNil(nullBuckets.dailyUsageBuckets)

        let parsedEmptyBuckets = await runtime.accountTokenUsageSnapshot(
            fromPayload: .object([
                "summary": .object([:]),
                "dailyUsageBuckets": .array([])
            ])
        )
        let emptyBuckets = try XCTUnwrap(parsedEmptyBuckets)
        XCTAssertEqual(emptyBuckets.dailyUsageBuckets, [])
    }

    func testAccountTokenUsageRefreshDistinguishesConfigFailureFromUnsupported() async {
        let configFailureRuntime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "test",
            configProvider: { throw MockError.unimplemented }
        )
        let configFailure = await configFailureRuntime.performAccountTokenUsageRefresh()
        XCTAssertEqual(configFailure, .failed)

        let unsupportedRuntime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "test",
            configProvider: {
                makeDirectAppServerConfig(
                    project: AgentProject(id: "usage", name: "Usage", path: "/tmp/usage"),
                    allowedMethods: ["thread/list"]
                )
            }
        )
        let unsupported = await unsupportedRuntime.performAccountTokenUsageRefresh()
        XCTAssertEqual(unsupported, .unsupported)
    }

    func testDeterministicGatewayPolicyFailureStopsReconnectOnlyForHardPolicyErrors() {
        // 硬策略拒绝：重连必然复现，应停止自动重连。
        XCTAssertTrue(SessionStore.isDeterministicGatewayPolicyFailure(
            "app-server 错误 -32080：dangerFullAccess 不允许用于 Claude experimental runtime"
        ))
        XCTAssertTrue(SessionStore.isDeterministicGatewayPolicyFailure(
            "app-server 错误 -32080：thread/resume.cwd 必须来自 projects allowlist 或 browse_roots"
        ))
        // 历史预算/限流类是时间窗资源，恢复后可成功，必须继续走重试路径。
        XCTAssertFalse(SessionStore.isDeterministicGatewayPolicyFailure(
            "app-server 错误 -32080：thread/turns/list 同一 thread/method 正在临时限流，请稍后重试或降低 limit/itemsView"
        ))
        XCTAssertFalse(SessionStore.isDeterministicGatewayPolicyFailure(
            "app-server 错误 -32080：gateway pending history 请求过多"
        ))
        XCTAssertFalse(SessionStore.isDeterministicGatewayPolicyFailure(
            "app-server 错误 -32080：thread/list 相同历史或列表请求仍在执行，请稍后重试"
        ))
        // 非 -32080 的普通断线仍然自动重连。
        XCTAssertFalse(SessionStore.isDeterministicGatewayPolicyFailure("连接已断开"))
        XCTAssertFalse(SessionStore.isDeterministicGatewayPolicyFailure(
            "app-server 错误 -32081：CLAUDE_BRIDGE_EXITED: Claude bridge 已退出，本轮连接已中断"
        ))
    }

    func testSanitizedForRuntimePolicyDowngradesClaudeFullAccess() {
        var options = CodexAppServerTurnOptions.default
        options.runtimeProvider = "claude"
        let sanitized = options.sanitizedForRuntimePolicy()
        XCTAssertEqual(sanitized.sandboxMode, .workspaceWrite)
        XCTAssertFalse(sanitized.networkAccess)

        var codexOptions = CodexAppServerTurnOptions.default
        codexOptions.runtimeProvider = "codex"
        XCTAssertEqual(codexOptions.sanitizedForRuntimePolicy().sandboxMode, .dangerFullAccess,
                       "Codex 通道保持默认完全访问，不能因 Claude 修复回归")
    }

    func testThreadListBuilderUsesStableSidebarSortParams() throws {
        let project = AgentProject(id: "repo", name: "Repo", path: "/Users/me/repo")
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [project])

        let request = try builder.threadList(cwd: project.path, limit: 20, cursor: "older")
        let params = try XCTUnwrap(request.params?.objectValue)

        XCTAssertEqual(request.method, "thread/list")
        XCTAssertEqual(params["cwd"]?.stringValue, project.path)
        XCTAssertEqual(params["limit"]?.intValue, 20)
        XCTAssertEqual(params["cursor"]?.stringValue, "older")
        XCTAssertEqual(params["sortKey"]?.stringValue, "recency_at")
        XCTAssertEqual(params["sortDirection"]?.stringValue, "desc")
        XCTAssertEqual(params["archived"]?.boolValue, false)
        XCTAssertEqual(params["useStateDbOnly"]?.boolValue, true)
        XCTAssertNil(params["refreshHistory"])
    }

    func testControlledGlobalThreadListOmitsCWDAndCarriesOpaqueCursor() throws {
        let project = AgentProject(id: "repo", name: "Repo", path: "/Users/me/repo")
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [project])

        let request = builder.controlledGlobalThreadList(limit: 50, cursor: "mimi_opaque")
        let params = try XCTUnwrap(request.params?.objectValue)

        XCTAssertEqual(request.method, "thread/list")
        XCTAssertNil(params["cwd"], "受控全局发现不能伪造项目 cwd")
        XCTAssertEqual(params["cursor"]?.stringValue, "mimi_opaque")
        XCTAssertEqual(params["sortKey"]?.stringValue, "updated_at")
        XCTAssertEqual(params["sortDirection"]?.stringValue, "desc")
        XCTAssertEqual(
            params["sourceKinds"]?.arrayValue?.compactMap(\.stringValue),
            ["cli", "vscode", "appServer", "subAgent"]
        )
        XCTAssertEqual(params["archived"]?.boolValue, false)
        XCTAssertEqual(params["useStateDbOnly"]?.boolValue, false)
    }

    func testGlobalThreadProjectionRestoresStableRelationAndAuthorizedProject() async throws {
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "test"
        )
        let project = AgentProject(
            id: "repo",
            name: "Repo",
            path: "/Users/me/repo"
        )
        let thread: [String: CodexAppServerJSONValue] = [
            "id": .string("child-thread"),
            "sessionId": .string("session-child"),
            "cwd": .string("/Users/me/.codex/worktrees/09f4/repo"),
            "name": .string("Child"),
            "status": .object(["type": .string("idle")]),
            "parentThreadId": .string("parent-thread"),
            "agentNickname": .string("Euler"),
            "agentRole": .string("worker"),
            "canAcceptDirectInput": .bool(false),
            "mimiRemote": .object([
                "projectId": .string(project.id),
                "projectName": .string(project.name),
                "projectPath": .string(project.path),
                "discovery": .string("global"),
                "readOnly": .bool(true),
            ]),
        ]

        let session = try await runtime.agentSession(
            from: thread,
            projects: [project],
            fallbackProject: nil
        )

        XCTAssertEqual(session.projectID, project.id)
        XCTAssertEqual(session.parentThreadID, "parent-thread")
        XCTAssertEqual(session.isSubagent, true)
        XCTAssertTrue(session.isSubagentThread)
        XCTAssertEqual(session.appServerSessionID, "session-child")
        XCTAssertEqual(session.agentNickname, "Euler")
        XCTAssertEqual(session.agentRole, "worker")
        XCTAssertEqual(session.canAcceptDirectInput, false)
        XCTAssertFalse(session.allowsDirectInput)
        XCTAssertEqual(session.context?.parentThreadID, "parent-thread")
        XCTAssertEqual(session.context?.isSubagent, true)
        XCTAssertEqual(session.context?.subagents.first?.id, "child-thread")
    }

    func testThreadListBuilderPreservesWindowsCWDAsRemoteHostPath() throws {
        let windowsPath = #"C:\Users\gaixg\code\codex-ipad-agent"#
        let project = AgentProject(id: "repo", name: "Repo", path: "  \(windowsPath)  ")
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [project])

        let request = try builder.threadList(cwd: "\n\(windowsPath)\t")
        let params = try XCTUnwrap(request.params?.objectValue)

        XCTAssertEqual(request.method, "thread/list")
        XCTAssertEqual(params["cwd"]?.stringValue, windowsPath)
    }

    func testRequestBuilderValidatesWindowsChildPathWithoutRewritingIt() throws {
        let projectPath = #"C:\Users\gaixg\code\codex-ipad-agent"#
        let imagePath = projectPath + #"\screens\preview.png"#
        let project = AgentProject(id: "repo", name: "Repo", path: projectPath)
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [project])

        let request = try builder.turnStart(
            threadID: "thread-1",
            projectID: project.id,
            payload: CodexAppServerTurnPayload(input: [.localImage(path: imagePath)])
        )
        let input = try XCTUnwrap(request.params?.objectValue?["input"]?.arrayValue)
        XCTAssertEqual(input.first?.objectValue?["path"]?.stringValue, imagePath)

        XCTAssertThrowsError(try builder.turnStart(
            threadID: "thread-1",
            projectID: project.id,
            payload: CodexAppServerTurnPayload(input: [
                .localImage(path: projectPath + #"\..\other\preview.png"#)
            ])
        ))
        XCTAssertThrowsError(try builder.turnStart(
            threadID: "thread-1",
            projectID: project.id,
            payload: CodexAppServerTurnPayload(input: [
                .localImage(path: projectPath + #"\screens/../other/preview.png"#)
            ])
        ))
    }

    func testThreadSearchBuilderUsesCodexSchemaWithoutCWD() throws {
        let project = AgentProject(id: "repo", name: "Repo", path: "/Users/me/repo")
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [project])

        let request = try builder.threadSearch(query: "  关键实现  ", limit: 50, cursor: "next-search")
        let params = try XCTUnwrap(request.params?.objectValue)

        XCTAssertEqual(request.method, "thread/search")
        XCTAssertEqual(params["searchTerm"]?.stringValue, "关键实现")
        XCTAssertEqual(params["limit"]?.intValue, 50)
        XCTAssertEqual(params["cursor"]?.stringValue, "next-search")
        XCTAssertEqual(params["sortKey"]?.stringValue, "updated_at")
        XCTAssertEqual(params["sortDirection"]?.stringValue, "desc")
        XCTAssertEqual(params["archived"]?.boolValue, false)
        XCTAssertNil(params["cwd"], "thread/search 不应由 iOS 注入任意 cwd")
    }

    func testThreadSearchPreservesAndMapsWindowsHostPaths() async throws {
        let projectPath = #"C:\Users\gaixg\code\codex-ipad-agent"#
        let worktreePath = projectPath + #"\.codex\worktrees\mim-13"#
        let runtime = CodexAppServerSessionRuntime(endpoint: "http://127.0.0.1:8787", token: "test")
        let page = try await runtime.threadSearchPage(
            from: .object([
                "data": .array([
                    .object([
                        "snippet": .string("Windows result"),
                        "thread": .object([
                            "id": .string("thread-windows"),
                            "cwd": .string(worktreePath),
                            "name": .string("Windows thread")
                        ])
                    ])
                ])
            ]),
            projects: [AgentProject(id: "repo", name: "Repo", path: projectPath)]
        )

        let result = try XCTUnwrap(page.results.first)
        XCTAssertEqual(page.results.count, 1)
        XCTAssertEqual(result.session.dir, worktreePath)
        XCTAssertEqual(result.session.projectID, "repo")
    }

    func testThreadResumeBuilderRequestsBoundedRecentTurns() throws {
        let project = AgentProject(id: "repo", name: "Repo", path: "/Users/me/repo")
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [project])

        let request = try builder.threadResume(threadID: "thread-1", cwd: project.path)
        let params = try XCTUnwrap(request.params?.objectValue)
        let page = try XCTUnwrap(params["initialTurnsPage"]?.objectValue)

        XCTAssertEqual(params["excludeTurns"]?.boolValue, true)
        XCTAssertEqual(page["limit"]?.intValue, 5)
        XCTAssertEqual(page["sortDirection"]?.stringValue, "desc")
        XCTAssertEqual(page["itemsView"]?.stringValue, "summary")
    }

    func testTurnStartBuilderSendsExplicitCollaborationMode() throws {
        let project = AgentProject(id: "repo", name: "Repo", path: "/Users/me/repo")
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [project])

        var planOptions = CodexAppServerTurnOptions.default
        planOptions.model = "gpt-5.6-sol"
        planOptions.reasoningEffort = .ultra
        planOptions.collaborationMode = .plan
        let planPayload = CodexAppServerTurnPayload(prompt: "先做方案", options: planOptions)
        let planRequest = try builder.turnStart(threadID: "thread-1", projectID: project.id, payload: planPayload)
        let planParams = try XCTUnwrap(planRequest.params?.objectValue)
        let collaborationMode = try XCTUnwrap(planParams["collaborationMode"]?.objectValue)
        XCTAssertEqual(collaborationMode["mode"]?.stringValue, "plan")
        let settings = try XCTUnwrap(collaborationMode["settings"]?.objectValue)
        XCTAssertEqual(settings["model"]?.stringValue, "gpt-5.6-sol")
        XCTAssertEqual(settings["reasoning_effort"]?.stringValue, "ultra")
        XCTAssertEqual(settings["developer_instructions"], .null)

        let standardPayload = CodexAppServerTurnPayload(prompt: "直接做", options: .default)
        let standardRequest = try builder.turnStart(threadID: "thread-1", projectID: project.id, payload: standardPayload)
        let standardMode = try XCTUnwrap(standardRequest.params?.objectValue?["collaborationMode"]?.objectValue)
        XCTAssertEqual(standardMode["mode"]?.stringValue, "default")
        let standardSettings = try XCTUnwrap(standardMode["settings"]?.objectValue)
        XCTAssertNil(standardSettings["model"]?.stringValue)
        XCTAssertEqual(standardSettings["reasoning_effort"]?.stringValue, "xhigh")
        XCTAssertEqual(standardSettings["developer_instructions"], .null)
    }

    func testTurnOptionsDecodesLegacyPayloadWithNilModelAndDefaultCollaborationMode() throws {
        let legacy = Data(#"{"approval_policy":"on-request","sandbox_mode":"dangerFullAccess","plan_guidance_enabled":false}"#.utf8)
        let decoded = try JSONDecoder().decode(CodexAppServerTurnOptions.self, from: legacy)

        XCTAssertNil(decoded.model)
        XCTAssertEqual(decoded.reasoningEffort, .xhigh)
        XCTAssertEqual(decoded.approvalPolicy, .onRequest)
        XCTAssertEqual(decoded.sandboxMode, .dangerFullAccess)
        XCTAssertEqual(decoded.collaborationMode, .default)
        XCTAssertEqual(decoded.modelSelectionPolicy, .catalogOnly)
    }

    func testTurnStartBuilderUsesDefaultCollaborationModeForGoalTurns() throws {
        let project = AgentProject(id: "repo", name: "Repo", path: "/Users/me/repo")
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [project])
        var goalOptions = CodexAppServerTurnOptions.default
        goalOptions.collaborationMode = .default

        let request = try builder.turnStart(
            threadID: "thread-1",
            projectID: project.id,
            payload: CodexAppServerTurnPayload(prompt: "完成目标", options: goalOptions)
        )

        let mode = try XCTUnwrap(request.params?.objectValue?["collaborationMode"]?.objectValue)
        XCTAssertEqual(mode["mode"]?.stringValue, "default")
    }

    func testTurnSteerBuilderUsesActiveTurnPreconditionWithoutStartOptions() throws {
        let project = AgentProject(id: "repo", name: "Repo", path: "/Users/me/repo")
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [project])
        var options = CodexAppServerTurnOptions.default
        options.collaborationMode = .plan
        options.model = "gpt-5-codex"

        let payload = CodexAppServerTurnPayload(prompt: "这条直接引导当前回复", options: options)
        let request = try builder.turnSteer(
            threadID: "thread-1",
            cwd: project.path,
            payload: payload,
            clientMessageID: "client-steer",
            expectedTurnID: "turn-active"
        )
        let params = try XCTUnwrap(request.params?.objectValue)

        XCTAssertEqual(request.method, "turn/steer")
        XCTAssertEqual(params["threadId"]?.stringValue, "thread-1")
        XCTAssertEqual(params["clientUserMessageId"]?.stringValue, "client-steer")
        XCTAssertEqual(params["expectedTurnId"]?.stringValue, "turn-active")
        XCTAssertEqual(params["input"]?.arrayValue?.first?.objectValue?["text"]?.stringValue, "这条直接引导当前回复")
        XCTAssertNil(params["cwd"])
        XCTAssertNil(params["collaborationMode"])
        XCTAssertNil(params["model"])
        XCTAssertNil(params["approvalPolicy"])
    }

    func testRequestBuilderForwardsStructuredInputAndAdvancedOptions() throws {
        let project = AgentProject(id: "repo", name: "Repo", path: "/Users/me/repo")
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [project])
        var options = CodexAppServerTurnOptions.default
        options.runtimeProvider = "claude"
        options.model = "gpt-5-codex"
        options.modelProvider = "openai"
        options.serviceTier = "priority"
        options.reasoningEffort = .high
        options.reasoningSummary = .detailed
        options.approvalPolicy = .onFailure
        options.sandboxMode = .readOnly
        options.personality = .friendly
        options.config = .object(["feature": .bool(true)])
        options.baseInstructions = "base"
        options.developerInstructions = "dev"
        options.outputSchema = .object(["type": .string("object")])
        options.serviceName = "ios"
        options.sessionStartSource = "ipad"
        options.threadSource = "user"

        let threadStart = try builder.threadStart(projectID: project.id, options: options)
        let threadParams = try XCTUnwrap(threadStart.params?.objectValue)
        XCTAssertEqual(threadParams["model"]?.stringValue, "gpt-5-codex")
        XCTAssertEqual(threadParams["modelProvider"]?.stringValue, "openai")
        XCTAssertEqual(threadParams["serviceTier"]?.stringValue, "priority")
        XCTAssertEqual(threadParams["approvalPolicy"]?.stringValue, "on-failure")
        XCTAssertEqual(threadParams["sandbox"]?.stringValue, "read-only")
        XCTAssertEqual(threadParams["config"]?.objectValue?["feature"]?.boolValue, true)
        XCTAssertEqual(threadParams["baseInstructions"]?.stringValue, "base")
        XCTAssertEqual(threadParams["developerInstructions"]?.stringValue, "dev")
        XCTAssertEqual(threadParams["serviceName"]?.stringValue, "ios")
        XCTAssertNil(threadParams["runtimeProvider"])
        XCTAssertNil(threadParams["runtime_provider"])

        let payload = CodexAppServerTurnPayload(input: [
            .text("看图并检查引用"),
            .image(url: "data:image/png;base64,AA==", detail: .high),
            .localImage(path: "/Users/me/repo/screens/a.png", detail: .original),
            .skill(name: "review", path: "/Users/me/.codex/skills/review/SKILL.md"),
            .mention(name: "README", path: "/Users/me/repo/README.md")
        ], options: options)
        let turnStart = try builder.turnStart(threadID: "thread-1", projectID: project.id, payload: payload, clientMessageID: "client-rich")
        let turnParams = try XCTUnwrap(turnStart.params?.objectValue)
        XCTAssertEqual(turnParams["model"]?.stringValue, "gpt-5-codex")
        XCTAssertEqual(turnParams["serviceTier"]?.stringValue, "priority")
        XCTAssertEqual(turnParams["effort"]?.stringValue, "high")
        XCTAssertEqual(turnParams["summary"]?.stringValue, "detailed")
        XCTAssertEqual(turnParams["approvalPolicy"]?.stringValue, "on-failure")
        XCTAssertEqual(turnParams["clientUserMessageId"]?.stringValue, "client-rich")
        XCTAssertNil(turnParams["modelProvider"])
        XCTAssertNil(turnParams["runtimeProvider"])
        XCTAssertNil(turnParams["runtime_provider"])
        XCTAssertNil(turnParams["config"])
        XCTAssertNil(turnParams["baseInstructions"])
        let input = try XCTUnwrap(turnParams["input"]?.arrayValue)
        XCTAssertEqual(input.count, 5)
        XCTAssertEqual(input[0].objectValue?["type"]?.stringValue, "text")
        XCTAssertEqual(input[1].objectValue?["detail"]?.stringValue, "high")
        XCTAssertEqual(input[2].objectValue?["path"]?.stringValue, "/Users/me/repo/screens/a.png")
        XCTAssertEqual(input[3].objectValue?["name"]?.stringValue, "review")
        XCTAssertEqual(input[3].objectValue?["path"]?.stringValue, "/Users/me/.codex/skills/review/SKILL.md")
        let sandbox = try XCTUnwrap(turnParams["sandboxPolicy"]?.objectValue)
        XCTAssertEqual(sandbox["type"]?.stringValue, "readOnly")
        XCTAssertEqual(sandbox["networkAccess"]?.boolValue, false)
    }

    func testGatewayURLIncludesRuntimeOnlyForNonCodexChannels() throws {
        let codex = try CodexAppServerSessionRuntime.gatewayURL(endpoint: "http://127.0.0.1:8787", sessionID: "thr_codex")
        XCTAssertEqual(codex.path, "/api/app-server/ws")
        XCTAssertNil(URLComponents(url: codex, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "runtime" }))

        let claude = try CodexAppServerSessionRuntime.gatewayURL(endpoint: "http://127.0.0.1:8787", sessionID: "thr_claude", runtimeProvider: "claude")
        let queryItems = URLComponents(url: claude, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(claude.path, "/api/app-server/ws")
        XCTAssertEqual(queryItems.first(where: { $0.name == "runtime" })?.value, "claude")
        XCTAssertEqual(queryItems.first(where: { $0.name == "thread_id" })?.value, "thr_claude")
    }

    // 真实连接的 thread_id 是空的（一条连接承载所有线程），所以能不能接回常驻会话
    // 全看这个 session 键。它必须存在、跨调用稳定、且落在网关的字符集白名单里。
    func testGatewayURLCarriesStableSessionKey() throws {
        let first = try CodexAppServerSessionRuntime.gatewayURL(
            endpoint: "http://127.0.0.1:8787", sessionID: "", runtimeProvider: "claude")
        let second = try CodexAppServerSessionRuntime.gatewayURL(
            endpoint: "http://127.0.0.1:8787", sessionID: "", runtimeProvider: "claude")

        func sessionKey(_ url: URL) throws -> String {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return try XCTUnwrap(items.first(where: { $0.name == "session" })?.value)
        }

        let key = try sessionKey(first)
        XCTAssertFalse(key.isEmpty)
        XCTAssertEqual(key, try sessionKey(second), "同一安装的会话键必须稳定，否则每次重连都是新会话")
        XCTAssertTrue(key.hasSuffix("-claude"))
        XCTAssertLessThanOrEqual(key.count, 128)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        XCTAssertNil(key.rangeOfCharacter(from: allowed.inverted), "会话键含网关会拒绝的字符：\(key)")

        // 不同 runtime 各自一条常驻会话，不能互相串。
        let codex = try CodexAppServerSessionRuntime.gatewayURL(
            endpoint: "http://127.0.0.1:8787", sessionID: "")
        XCTAssertNotEqual(try sessionKey(codex), key)
    }

    func testClaudeGatewayURLCarriesClientProcessedCursor() throws {
        let suiteName = "CodexAppServerProtocolTests.gatewayCursor.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let endpoint = "http://127.0.0.1:8787"
        let gatewaySession = "\(CodexAppServerSessionRuntime.gatewaySessionKey(defaults: defaults))-claude"
        CodexAppServerSessionRuntime.storeGatewayLastSeenSequence(
            37,
            endpoint: endpoint,
            gatewaySession: gatewaySession,
            runtimeProvider: "claude",
            defaults: defaults
        )
        CodexAppServerSessionRuntime.storeGatewayLastSeenSequence(
            12,
            endpoint: endpoint,
            gatewaySession: gatewaySession,
            runtimeProvider: "claude",
            defaults: defaults
        )
        let url = try CodexAppServerSessionRuntime.gatewayURL(
            endpoint: endpoint,
            sessionID: "",
            runtimeProvider: "claude",
            defaults: defaults
        )
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first(where: { $0.name == "last_seen" })?.value, "37")

        let codex = try CodexAppServerSessionRuntime.gatewayURL(
            endpoint: "http://127.0.0.1:8787",
            sessionID: "",
            runtimeProvider: "codex",
            defaults: defaults
        )
        let codexQuery = URLComponents(url: codex, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertNil(codexQuery.first(where: { $0.name == "last_seen" }))

        let otherEndpoint = try CodexAppServerSessionRuntime.gatewayURL(
            endpoint: "http://127.0.0.1:8788",
            sessionID: "",
            runtimeProvider: "claude",
            defaults: defaults
        )
        let otherQuery = URLComponents(url: otherEndpoint, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertNil(otherQuery.first(where: { $0.name == "last_seen" }))
    }

    func testClaudeGatewayCursorResetStartsANewBridgeEpoch() async throws {
        let suiteName = "CodexAppServerProtocolTests.gatewayCursorReset.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let endpoint = "http://127.0.0.1:8787"
        let gatewaySession = "\(CodexAppServerSessionRuntime.gatewaySessionKey(defaults: defaults))-claude"
        CodexAppServerSessionRuntime.storeGatewayLastSeenSequence(
            37,
            endpoint: endpoint,
            gatewaySession: gatewaySession,
            runtimeProvider: "claude",
            defaults: defaults
        )
        let runtime = CodexAppServerSessionRuntime(
            endpoint: endpoint,
            token: "test-token",
            runtimeProvider: "claude",
            gatewayDefaults: defaults
        )

        await runtime.handle(CodexAppServerNotification(
            method: "_mimi/claudeReplayCursor/reset",
            params: .object(["sequence": .int(0)])
        ))
        XCTAssertEqual(
            CodexAppServerSessionRuntime.gatewayLastSeenSequence(
                endpoint: endpoint,
                gatewaySession: gatewaySession,
                runtimeProvider: "claude",
                defaults: defaults
            ),
            0
        )

        await runtime.acknowledgeAppliedReplayBoundary(37, epoch: 0)
        XCTAssertEqual(
            CodexAppServerSessionRuntime.gatewayLastSeenSequence(
                endpoint: endpoint,
                gatewaySession: gatewaySession,
                runtimeProvider: "claude",
                defaults: defaults
            ),
            0,
            "上一 epoch 的迟到确认不能把刚清零的 cursor 写回来"
        )
        await runtime.acknowledgeAppliedReplayBoundary(5, epoch: 1)
        CodexAppServerSessionRuntime.storeGatewayLastSeenSequence(
            3,
            endpoint: endpoint,
            gatewaySession: gatewaySession,
            runtimeProvider: "claude",
            defaults: defaults
        )
        XCTAssertEqual(
            CodexAppServerSessionRuntime.gatewayLastSeenSequence(
                endpoint: endpoint,
                gatewaySession: gatewaySession,
                runtimeProvider: "claude",
                defaults: defaults
            ),
            5
        )
    }

    func testRequestBuilderAllowsFullAccessSandboxWithApproval() throws {
        let project = AgentProject(id: "repo", name: "Repo", path: "/Users/me/repo")
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [project])
        var options = CodexAppServerTurnOptions.default
        options.sandboxMode = .dangerFullAccess

        let threadStart = try builder.threadStart(projectID: project.id, options: options)
        let threadParams = try XCTUnwrap(threadStart.params?.objectValue)
        XCTAssertEqual(threadParams["approvalPolicy"]?.stringValue, "on-request")
        XCTAssertEqual(threadParams["sandbox"]?.stringValue, "danger-full-access")

        let payload = CodexAppServerTurnPayload(prompt: "hi", options: options)
        let turnStart = try builder.turnStart(
            threadID: "thread-1",
            projectID: project.id,
            payload: payload,
            clientMessageID: nil
        )
        let turnParams = try XCTUnwrap(turnStart.params?.objectValue)
        let sandbox = try XCTUnwrap(turnParams["sandboxPolicy"]?.objectValue)
        XCTAssertEqual(turnParams["approvalPolicy"]?.stringValue, "on-request")
        XCTAssertEqual(sandbox["type"]?.stringValue, "dangerFullAccess")
        XCTAssertEqual(sandbox["networkAccess"]?.boolValue, false)
    }

    func testModelListBuilderAndFlexibleParser() throws {
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [])
        let request = builder.modelList()
        XCTAssertEqual(request.method, "model/list")
        XCTAssertEqual(request.params?.objectValue, [:])

        let parsed = CodexAppServerModelOption.parseListResult(.object([
            "models": .array([
                .string("gpt-5-codex"),
                .object([
                    "id": .string("gpt-5.1-codex"),
                    "label": .string("GPT-5.1 Codex"),
                    "provider": .string("openai"),
                    "isDefault": .bool(true)
                ]),
                .object([
                    "model": .string("gpt-5"),
                    "description": .string("general")
                ]),
                .object([
                    "model": .string("gpt-5"),
                    "provider": .string("azure")
                ])
            ])
        ]))

        XCTAssertEqual(parsed.first?.model, "gpt-5-codex")
        XCTAssertEqual(Set(parsed.map(\.id)), ["gpt-5.1-codex@openai", "gpt-5", "gpt-5@azure", "gpt-5-codex"])
        let defaultOption = try XCTUnwrap(parsed.first(where: \.isDefault))
        XCTAssertEqual(defaultOption.title, "GPT-5.1 Codex")
        XCTAssertEqual(defaultOption.provider, "openai")
    }

    func testSkillsListBuilderAndRichMetadataParser() throws {
        let project = AgentProject(id: "repo", name: "Repo", path: "/Users/me/repo")
        let request = try CodexAppServerRequestBuilder(allowlistedProjects: [project])
            .skillsList(cwd: project.path, forceReload: true)
        XCTAssertEqual(request.method, "skills/list")
        XCTAssertEqual(request.params?.objectValue?["cwds"]?.arrayValue?.first?.stringValue, project.path)
        XCTAssertEqual(request.params?.objectValue?["forceReload"]?.boolValue, true)

        let parsed = SkillCapability.parseAppServerListResult(.object([
            "data": .array([
                .object([
                    "cwd": .string(project.path),
                    "errors": .array([]),
                    "skills": .array([
                        .object([
                            "name": .string("review"),
                            "description": .string("Review changes"),
                            "scope": .string("system"),
                            "path": .string("/Users/me/.codex/skills/.system/review/SKILL.md"),
                            "enabled": .bool(true),
                            "interface": .object([
                                "displayName": .string("Code Review"),
                                "shortDescription": .string("Find risky changes"),
                                "brandColor": .string("#43A7A8")
                            ])
                        ])
                    ])
                ])
            ])
        ]), cwd: project.path)

        let skill = try XCTUnwrap(parsed.first)
        XCTAssertEqual(skill.name, "review")
        XCTAssertEqual(skill.presentationName, "Code Review")
        XCTAssertEqual(skill.presentationDescription, "Find risky changes")
        XCTAssertEqual(skill.scope, "system")
        XCTAssertEqual(skill.brandColor, "#43A7A8")
    }

    func testSkillsListParserMatchesWindowsCWDWithoutRewritingIt() throws {
        let windowsPath = #"C:\Users\gaixg\code\codex-ipad-agent"#
        let parsed = SkillCapability.parseAppServerListResult(.object([
            "data": .array([
                .object([
                    "cwd": .string("  \(windowsPath)  "),
                    "skills": .array([
                        .object([
                            "name": .string("review"),
                            "path": .string(#"C:\Users\gaixg\.codex\skills\review\SKILL.md"#),
                            "enabled": .bool(true)
                        ])
                    ])
                ])
            ])
        ]), cwd: windowsPath)

        XCTAssertEqual(parsed.map(\.name), ["review"])
    }

    func testInstalledPluginListBuilderAndComposerMetadataParser() throws {
        let project = AgentProject(id: "repo", name: "Repo", path: "/Users/me/repo")
        let request = try CodexAppServerRequestBuilder(allowlistedProjects: [project])
            .installedPluginList(cwd: project.path)
        XCTAssertEqual(request.method, "plugin/installed")
        XCTAssertEqual(request.params?.objectValue?["cwds"]?.arrayValue?.first?.stringValue, project.path)
        XCTAssertNil(request.params?.objectValue?["installSuggestionPluginNames"])

        let parsed = CodexPluginCapability.parseAppServerInstalledResult(.object([
            "marketplaces": .array([
                .object([
                    "name": .string("openai-curated"),
                    "interface": .object(["displayName": .string("OpenAI")]),
                    "plugins": .array([
                        .object([
                            "id": .string("github@openai-curated"),
                            "name": .string("github"),
                            "enabled": .bool(true),
                            "installed": .bool(true),
                            "interface": .object([
                                "displayName": .string("GitHub"),
                                "shortDescription": .string("读取仓库与 Pull Request"),
                                "composerIconUrl": .string("https://example.test/github.png"),
                                "brandColor": .string("#24292F")
                            ])
                        ]),
                        .object([
                            "id": .string("unused@openai-curated"),
                            "name": .string("unused"),
                            "enabled": .bool(true),
                            "installed": .bool(false)
                        ])
                    ])
                ])
            ])
        ]))

        let plugin = try XCTUnwrap(parsed.first)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(plugin.id, "github@openai-curated")
        XCTAssertEqual(plugin.presentationName, "GitHub")
        XCTAssertEqual(plugin.description, "读取仓库与 Pull Request")
        XCTAssertEqual(plugin.marketplace, "OpenAI")
        XCTAssertTrue(plugin.enabled)
        XCTAssertTrue(plugin.installed)
    }

    func testModelListParserRetainsReasoningGridMetadata() throws {
        let parsed = CodexAppServerModelOption.parseListResult(.object([
            "data": .array([
                .object([
                    "model": .string("gpt-5.6-sol"),
                    "displayName": .string("GPT-5.6 Sol"),
                    "description": .string("Detail and polish"),
                    "isDefault": .bool(true),
                    "hidden": .bool(false),
                    "defaultReasoningEffort": .string("low"),
                    "supportedReasoningEfforts": .array([
                        .object(["reasoningEffort": .string("medium"), "description": .string("Balanced")]),
                        .object(["reasoningEffort": .string("high"), "description": .string("Deep")]),
                        .object(["reasoningEffort": .string("xhigh"), "description": .string("Deepest")]),
                        .object(["reasoningEffort": .string("max"), "description": .string("Maximum")]),
                        .object(["reasoningEffort": .string("ultra"), "description": .string("Ultra")])
                    ])
                ])
            ])
        ]))

        let option = try XCTUnwrap(parsed.first)
        XCTAssertEqual(option.title, "GPT-5.6 Sol")
        XCTAssertEqual(option.supportedReasoningEfforts, ["medium", "high", "xhigh", "max", "ultra"])
        XCTAssertEqual(option.defaultReasoningEffort, "low")
        XCTAssertFalse(option.hidden)
        XCTAssertEqual(
            ModelReasoningGridCatalog.layout(runtimeProvider: "codex", options: parsed).models.map(\.model),
            ["gpt-5.6-sol"]
        )
    }

    func testClaudeModelGridPreservesBridgeOrderAndNativeReasoningMetadata() {
        let efforts = ["medium", "high", "xhigh", "max"]
        let options = [
            CodexAppServerModelOption(
                id: "claude-fable-5",
                title: "Claude Fable 5",
                runtimeProvider: "claude",
                supportedReasoningEfforts: efforts,
                defaultReasoningEffort: "high"
            ),
            CodexAppServerModelOption(
                id: "claude-opus-5",
                title: "Claude Opus 5",
                runtimeProvider: "claude",
                isDefault: true,
                supportedReasoningEfforts: efforts,
                defaultReasoningEffort: "high"
            ),
            CodexAppServerModelOption(
                id: "claude-sonnet-4-6",
                title: "Claude Sonnet 4.6",
                runtimeProvider: "claude",
                supportedReasoningEfforts: efforts,
                defaultReasoningEffort: "high"
            ),
            CodexAppServerModelOption(
                id: "claude-haiku-4-5-20251001",
                title: "Claude Haiku 4.5",
                runtimeProvider: "claude",
                supportedReasoningEfforts: []
            )
        ]

        let layout = ModelReasoningGridCatalog.layout(runtimeProvider: "claude", options: options)

        XCTAssertEqual(
            layout.models.map(\.model),
            ["claude-fable-5", "claude-opus-5", "claude-sonnet-4-6"]
        )
        XCTAssertEqual(
            layout.models.map { ModelReasoningGridCatalog.shortTitle(for: $0, kind: .claude) },
            ["Claude Fable 5", "Claude Opus 5", "Claude Sonnet 4.6"]
        )
        XCTAssertEqual(layout.efforts, [.medium, .high, .xhigh, .max])
        XCTAssertEqual(layout.modelRowCount, 3)
        XCTAssertEqual(layout.effortColumnCount, 4)
        XCTAssertEqual(
            layout.selection(modelRow: 0, effortColumn: 0),
            ModelReasoningGridSelection(modelID: "claude-fable-5", effort: .medium)
        )
        XCTAssertEqual(
            layout.selection(modelRow: 2, effortColumn: 3),
            ModelReasoningGridSelection(modelID: "claude-sonnet-4-6", effort: .max)
        )
        XCTAssertFalse(layout.contains(modelID: "fable"), "未返回的 alias 不应再被本地映射成具体模型")
        XCTAssertFalse(layout.contains(modelID: "claude-haiku-4-5-20251001"), "网格只展示运行时返回的前三个模型")
        XCTAssertFalse(layout.showsFastMode)
        XCTAssertEqual(
            ModelReasoningGridCatalog.triggerTitle(for: "claude-fable-5", effort: .max, layout: layout),
            "Claude Fable 5 · Max"
        )
        XCTAssertEqual(
            ModelReasoningGridCatalog.triggerTitle(for: "claude-sonnet-4-6", effort: .high, layout: layout),
            "Claude Sonnet 4.6 · High"
        )
    }

    func testModelGridValidatesReasoningEffortAgainstSelectedRow() {
        let sonnet = CodexAppServerModelOption(
            id: "claude-sonnet-4-6",
            runtimeProvider: "claude",
            supportedReasoningEfforts: ["medium", "high"]
        )
        let opus = CodexAppServerModelOption(
            id: "claude-opus-5",
            runtimeProvider: "claude",
            supportedReasoningEfforts: ["xhigh", "max"],
            defaultReasoningEffort: "xhigh"
        )
        let layout = ModelReasoningGridCatalog.layout(runtimeProvider: "claude", options: [sonnet, opus])

        XCTAssertEqual(layout.efforts, [.medium, .high, .xhigh, .max])
        XCTAssertFalse(ModelReasoningGridCatalog.isStandardEffortAvailable(.xhigh, option: sonnet, layout: layout))
        XCTAssertTrue(ModelReasoningGridCatalog.isStandardEffortAvailable(.xhigh, option: opus, layout: layout))
        XCTAssertEqual(
            ModelReasoningGridCatalog.normalizedVisibleEffort(
                option: sonnet,
                current: .xhigh,
                layout: layout
            ),
            .medium
        )
        XCTAssertEqual(
            ModelReasoningGridCatalog.normalizedVisibleEffort(
                option: opus,
                current: .medium,
                layout: layout
            ),
            .xhigh
        )
        XCTAssertEqual(
            ModelReasoningGridCatalog.visibleEfforts(for: sonnet, layout: layout),
            [.medium, .high]
        )
        XCTAssertEqual(
            ModelReasoningGridCatalog.visibleEfforts(for: opus, layout: layout),
            [.xhigh, .max]
        )
    }

    func testCodexStandardMenuUsesModelSpecificFourthEffort() {
        let options = CodexAppServerModelOption.builtInFallback
        let sol = options[0]
        let terra = options[1]
        let luna = options[2]
        let layout = ModelReasoningGridCatalog.layout(runtimeProvider: "codex", options: options)

        XCTAssertEqual(layout.efforts, [.medium, .high, .xhigh, .ultra])
        XCTAssertEqual(layout.modelRowCount, 3)
        XCTAssertEqual(layout.effortColumnCount, 4)
        XCTAssertEqual(
            layout.selection(modelRow: 2, effortColumn: 3),
            ModelReasoningGridSelection(modelID: luna.model, effort: .max)
        )
        XCTAssertEqual(
            ModelReasoningGridCatalog.allSupportedEfforts(for: sol),
            [.low, .medium, .high, .xhigh, .max, .ultra]
        )
        XCTAssertEqual(
            ModelReasoningGridCatalog.allSupportedEfforts(for: terra),
            [.low, .medium, .high, .xhigh, .max, .ultra]
        )
        XCTAssertEqual(
            ModelReasoningGridCatalog.allSupportedEfforts(for: luna),
            [.low, .medium, .high, .xhigh, .max]
        )
        XCTAssertEqual(
            ModelReasoningGridCatalog.visibleEfforts(for: sol, layout: layout),
            [.medium, .high, .xhigh, .ultra]
        )
        XCTAssertEqual(
            ModelReasoningGridCatalog.visibleEfforts(for: terra, layout: layout),
            [.medium, .high, .xhigh, .ultra]
        )
        XCTAssertEqual(
            ModelReasoningGridCatalog.visibleEfforts(for: luna, layout: layout),
            [.medium, .high, .xhigh, .max]
        )
        XCTAssertEqual(sol.defaultReasoningEffort, "xhigh")
        XCTAssertTrue(sol.isDefault)
        XCTAssertEqual(terra.defaultReasoningEffort, "medium")
        XCTAssertEqual(luna.defaultReasoningEffort, "medium")
        XCTAssertTrue(ModelReasoningGridCatalog.supports(.ultra, option: sol))
        XCTAssertFalse(ModelReasoningGridCatalog.supports(.ultra, option: luna))
        XCTAssertFalse(ModelReasoningGridCatalog.isStandardEffortAvailable(.max, option: sol, layout: layout))
        XCTAssertEqual(
            ModelReasoningGridCatalog.normalizedVisibleEffort(
                option: luna,
                current: .ultra,
                layout: layout
            ),
            .medium
        )
        XCTAssertEqual(ModelReasoningGridCatalog.effortTitle(.max), "Max")
        XCTAssertEqual(ModelReasoningGridCatalog.effortTitle(.ultra), "Ultra")
    }

    func testPreferredCodexDefaultOverridesServerDefaultWithSolXHigh() throws {
        let options = [
            CodexAppServerModelOption(
                id: "gpt-5.6-terra",
                title: "GPT-5.6 Terra",
                runtimeProvider: "codex",
                isDefault: true,
                supportedReasoningEfforts: ["medium", "high", "xhigh"]
            ),
            CodexAppServerModelOption(
                id: "gpt-5.6-sol",
                title: "GPT-5.6 Sol",
                provider: "openai",
                runtimeProvider: "codex",
                supportedReasoningEfforts: ["medium", "high", "xhigh", "ultra"],
                defaultReasoningEffort: "medium"
            )
        ]
        let option = try XCTUnwrap(
            ModelReasoningGridCatalog.preferredDefaultOption(
                runtimeProvider: "codex",
                options: options
            )
        )
        let layout = ModelReasoningGridCatalog.layout(runtimeProvider: "codex", options: options)

        XCTAssertEqual(option.model, "gpt-5.6-sol")
        XCTAssertEqual(
            ModelReasoningGridCatalog.preferredDefaultEffort(
                runtimeProvider: "codex",
                option: option,
                layout: layout
            ),
            .xhigh
        )
    }

    func testPreferredClaudeDefaultUsesCanonicalOpus5High() throws {
        let options = [
            CodexAppServerModelOption(
                id: "claude-fable-5",
                title: "Claude Fable 5",
                runtimeProvider: "claude",
                isDefault: true,
                supportedReasoningEfforts: ["medium", "high", "xhigh", "max"]
            ),
            CodexAppServerModelOption(
                id: "claude-opus-5",
                title: "Claude Opus 5",
                provider: "anthropic",
                runtimeProvider: "claude",
                supportedReasoningEfforts: ["medium", "high", "xhigh", "max"],
                defaultReasoningEffort: "medium"
            )
        ]
        let option = try XCTUnwrap(
            ModelReasoningGridCatalog.preferredDefaultOption(
                runtimeProvider: "claude",
                options: options
            )
        )
        let layout = ModelReasoningGridCatalog.layout(runtimeProvider: "claude", options: options)

        XCTAssertEqual(option.model, "claude-opus-5")
        XCTAssertEqual(
            ModelReasoningGridCatalog.preferredDefaultEffort(
                runtimeProvider: "claude",
                option: option,
                layout: layout
            ),
            .high
        )
    }

    func testPreferredClaudeFallbackUsesOpusAliasHigh() throws {
        let option = try XCTUnwrap(
            ModelReasoningGridCatalog.preferredDefaultOption(
                runtimeProvider: "claude",
                options: []
            )
        )
        let layout = ModelReasoningGridCatalog.layout(
            runtimeProvider: "claude",
            options: CodexAppServerModelOption.builtInClaudeFallback
        )

        XCTAssertEqual(option.model, "opus")
        XCTAssertTrue(option.isDefault)
        XCTAssertEqual(option.defaultReasoningEffort, "high")
        XCTAssertEqual(
            ModelReasoningGridCatalog.preferredDefaultEffort(
                runtimeProvider: "claude",
                option: option,
                layout: layout
            ),
            .high
        )
    }

    func testPreferredDefaultFallsBackToAvailableCatalogModel() throws {
        let onlyAvailable = CodexAppServerModelOption(
            id: "gpt-account-default",
            title: "Account Default",
            runtimeProvider: "codex",
            isDefault: true,
            supportedReasoningEfforts: ["medium"]
        )
        let option = try XCTUnwrap(
            ModelReasoningGridCatalog.preferredDefaultOption(
                runtimeProvider: "codex",
                options: [onlyAvailable]
            )
        )
        let layout = ModelReasoningGridCatalog.layout(
            runtimeProvider: "codex",
            options: [onlyAvailable]
        )

        XCTAssertEqual(option.model, "gpt-account-default")
        XCTAssertEqual(
            ModelReasoningGridCatalog.preferredDefaultEffort(
                runtimeProvider: "codex",
                option: option,
                layout: layout
            ),
            .medium,
            "账号没有 Sol 时必须使用目录内可发送组合，不能硬编码未授权模型"
        )
    }

    func testEmptyReasoningMetadataUsesProviderSpecificFallback() {
        let codex = CodexAppServerModelOption(
            id: "legacy-codex",
            runtimeProvider: "codex",
            supportedReasoningEfforts: []
        )
        let claude = CodexAppServerModelOption(
            id: "claude-haiku",
            supportedReasoningEfforts: []
        )
        let codexLayout = ModelReasoningGridCatalog.layout(runtimeProvider: "codex", options: [codex])
        let claudeLayout = ModelReasoningGridCatalog.layout(runtimeProvider: "claude", options: [claude])

        XCTAssertEqual(
            ModelReasoningGridCatalog.visibleEfforts(for: codex, layout: codexLayout),
            [.medium, .high, .xhigh, .ultra]
        )
        XCTAssertTrue(ModelReasoningGridCatalog.visibleEfforts(for: claude, layout: claudeLayout).isEmpty)
        XCTAssertNil(
            ModelReasoningGridCatalog.normalizedVisibleEffort(
                option: claude,
                current: .max,
                layout: claudeLayout
            )
        )
    }

    func testAllModelsSelectionUpdatesModelAndEffortTogether() {
        let codex = CodexAppServerModelOption(
            id: "gpt-5.6-sol",
            title: "GPT-5.6 Sol",
            provider: "openai",
            runtimeProvider: "codex",
            supportedReasoningEfforts: ["medium", "high", "xhigh", "ultra"]
        )
        var options = CodexAppServerTurnOptions.default

        ModelReasoningGridCatalog.applySelection(
            option: codex,
            effort: .ultra,
            preservesServerDefault: false,
            fallbackRuntimeProvider: nil,
            to: &options
        )

        XCTAssertEqual(options.model, "gpt-5.6-sol")
        XCTAssertEqual(options.modelProvider, "openai")
        XCTAssertEqual(options.reasoningEffort, .ultra)

        ModelReasoningGridCatalog.applySelection(
            option: codex,
            effort: .high,
            preservesServerDefault: true,
            fallbackRuntimeProvider: nil,
            to: &options
        )

        XCTAssertNil(options.model)
        XCTAssertNil(options.modelProvider)
        XCTAssertEqual(options.reasoningEffort, .high)
    }

    func testNoNativeEffortModelClearsEffortAndClaudeServiceTier() {
        let haiku = CodexAppServerModelOption(
            id: "haiku",
            provider: "anthropic",
            runtimeProvider: "claude",
            supportedReasoningEfforts: []
        )
        var options = CodexAppServerTurnOptions.default
        options.serviceTier = "priority"

        ModelReasoningGridCatalog.applySelection(
            option: haiku,
            effort: nil,
            preservesServerDefault: false,
            fallbackRuntimeProvider: nil,
            to: &options
        )

        XCTAssertEqual(options.model, "haiku")
        XCTAssertNil(options.reasoningEffort)
        XCTAssertNil(options.serviceTier)
    }

    func testLeavingDeveloperMaxFallsBackToStandardCodexEffort() {
        let sol = CodexAppServerModelOption.builtInFallback[0]
        let layout = ModelReasoningGridCatalog.layout(runtimeProvider: "codex", options: [sol])

        XCTAssertTrue(ModelReasoningGridCatalog.supports(.max, option: sol))
        XCTAssertEqual(
            ModelReasoningGridCatalog.normalizedVisibleEffort(
                option: sol,
                current: .max,
                layout: layout
            ),
            .xhigh
        )
    }

    func testFastModeIsTheOnlyStandardServiceTierEntry() {
        XCTAssertEqual(ModelReasoningGridCatalog.serviceTierForFastMode(true), "priority")
        XCTAssertNil(ModelReasoningGridCatalog.serviceTierForFastMode(false))
        XCTAssertEqual(
            ModelReasoningGridCatalog.normalizedStandardServiceTier(
                "priority",
                runtimeProvider: "codex"
            ),
            "priority"
        )
        XCTAssertNil(
            ModelReasoningGridCatalog.normalizedStandardServiceTier(
                "auto",
                runtimeProvider: "codex"
            )
        )
        XCTAssertNil(
            ModelReasoningGridCatalog.normalizedStandardServiceTier(
                "priority",
                runtimeProvider: "claude"
            )
        )
    }

    func testComposerSkillQueryOnlyMatchesWhitespaceDelimitedTokenAtCursor() throws {
        let text = "请检查 $apple-de"
        let query = try XCTUnwrap(ComposerSkillQuery.match(
            text: text,
            selectedRange: NSRange(location: (text as NSString).length, length: 0)
        ))
        XCTAssertEqual(query.query, "apple-de")
        XCTAssertEqual((text as NSString).substring(with: query.replacementRange), "$apple-de")

        XCTAssertNil(ComposerSkillQuery.match(
            text: "price$skill",
            selectedRange: NSRange(location: 11, length: 0)
        ))
        XCTAssertNil(ComposerSkillQuery.match(
            text: "$skill",
            selectedRange: NSRange(location: 0, length: 2)
        ))
    }

    func testModelListParserAcceptsKeyedSnakeCaseDefaults() throws {
        let parsed = CodexAppServerModelOption.parseListResult(.object([
            "data": .object([
                "gpt-snake-default": .object([
                    "display_name": .string("Snake Default"),
                    "model_provider": .string("openai"),
                    "is_default": .bool(true)
                ]),
                "gpt-side": .object([
                    "summary": .string("side model")
                ])
            ])
        ]))

        let defaultOption = try XCTUnwrap(parsed.first(where: \.isDefault))
        XCTAssertEqual(defaultOption.model, "gpt-snake-default")
        XCTAssertEqual(defaultOption.title, "Snake Default")
        XCTAssertEqual(defaultOption.provider, "openai")
        XCTAssertEqual(Set(parsed.map(\.model)), ["gpt-snake-default", "gpt-side"])
    }

    func testRequestBuilderBuildsThreadGoalRequests() throws {
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [])

        let get = builder.threadGoalGet(threadID: "thread-1")
        XCTAssertEqual(get.method, "thread/goal/get")
        XCTAssertEqual(get.params?.objectValue?["threadId"]?.stringValue, "thread-1")

        let set = builder.threadGoalSet(
            threadID: "thread-1",
            objective: "ship ipad goal",
            status: .active,
            tokenBudget: 50_000
        )
        let setParams = try XCTUnwrap(set.params?.objectValue)
        XCTAssertEqual(set.method, "thread/goal/set")
        XCTAssertEqual(setParams["threadId"]?.stringValue, "thread-1")
        XCTAssertEqual(setParams["objective"]?.stringValue, "ship ipad goal")
        XCTAssertEqual(setParams["status"]?.stringValue, "active")
        XCTAssertEqual(setParams["tokenBudget"]?.intValue, 50_000)

        let clear = builder.threadGoalClear(threadID: "thread-1")
        XCTAssertEqual(clear.method, "thread/goal/clear")
        XCTAssertEqual(clear.params?.objectValue?["threadId"]?.stringValue, "thread-1")
    }

    func testRequestBuilderRejectsUnsafeStructuredInputAndOptions() throws {
        let project = AgentProject(id: "repo", name: "Repo", path: "/Users/me/repo")
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [project])

        XCTAssertThrowsError(try builder.turnStart(
            threadID: "thread-1",
            projectID: project.id,
            payload: CodexAppServerTurnPayload(input: [.image(url: "file:///Users/me/repo/a.png")])
        ))

        XCTAssertThrowsError(try builder.turnStart(
            threadID: "thread-1",
            projectID: project.id,
            payload: CodexAppServerTurnPayload(input: [.localImage(path: "/Users/me/other/a.png")])
        ))

        XCTAssertThrowsError(try builder.turnStart(
            threadID: "thread-1",
            projectID: project.id,
            payload: CodexAppServerTurnPayload(input: [.localImage(path: "/Users/me/repo/../other/a.png")])
        ))

        var unsafe = CodexAppServerTurnOptions.default
        unsafe.networkAccess = true
        XCTAssertThrowsError(try builder.turnStart(
            threadID: "thread-1",
            projectID: project.id,
            payload: CodexAppServerTurnPayload(input: [.text("hi")], options: unsafe)
        ))

        var unsafeConfig = CodexAppServerTurnOptions.default
        unsafeConfig.config = .object(["approval_policy": .string("never")])
        XCTAssertThrowsError(try builder.threadStart(projectID: project.id, options: unsafeConfig))

        unsafeConfig.config = .object(["sandbox_mode": .string("danger-full-access")])
        XCTAssertThrowsError(try builder.threadStart(projectID: project.id, options: unsafeConfig))

        unsafeConfig.config = .object(["network_access": .bool(true)])
        XCTAssertThrowsError(try builder.threadStart(projectID: project.id, options: unsafeConfig))
    }

    func testProjectorMapsAssistantDeltaAndCompletedItem() throws {
        let delta = CodexAppServerNotification(method: "item/agentMessage/delta", params: .object([
            "threadId": .string("thread-1"),
            "turnId": .string("turn-1"),
            "itemId": .string("item-1"),
            "delta": .string("hello")
        ]))
        var projector = CodexAppServerEventProjector()
        guard case .assistantDelta(let agentDelta, let metadata) = projector.project(delta) else {
            return XCTFail("expected assistant delta")
        }
        XCTAssertEqual(agentDelta.text, "hello")
        XCTAssertEqual(metadata.sessionID, "thread-1")
        XCTAssertEqual(metadata.messageID, "appserver:turn-1:item-1")

        let completed = CodexAppServerNotification(method: "item/completed", params: .object([
            "threadId": .string("thread-1"),
            "turnId": .string("turn-1"),
            "item": .object([
                "id": .string("item-1"),
                "type": .string("agentMessage"),
                "text": .string("hello world")
            ])
        ]))
        guard case .messageCompleted(let message, _) = projector.project(completed) else {
            return XCTFail("expected completed message")
        }
        XCTAssertEqual(message.id, "appserver:turn-1:item-1")
        XCTAssertEqual(message.sessionID, "thread-1")
        XCTAssertEqual(message.content, "hello world")
    }

    func testProjectorMapsCompletedGeneratedAndViewedImages() throws {
        var projector = CodexAppServerEventProjector()
        let generated = CodexAppServerNotification(method: "item/completed", params: .object([
            "threadId": .string("thread-image"),
            "turnId": .string("turn-image"),
            "item": .object([
                "id": .string("ig-1"),
                "type": .string("imageGeneration"),
                "status": .string("completed"),
                "result": .string("agentd-history-media://media-generated"),
                "savedPath": .string("/tmp/generated.png")
            ])
        ]))
        guard case .messageCompleted(let generatedMessage, _) = projector.project(generated) else {
            return XCTFail("expected generated image message")
        }
        XCTAssertEqual(generatedMessage.role, .assistant)
        XCTAssertEqual(generatedMessage.content, "![生成的图片](agentd-history-media://media-generated)")

        let viewed = CodexAppServerNotification(method: "item/completed", params: .object([
            "threadId": .string("thread-image"),
            "turnId": .string("turn-image"),
            "item": .object([
                "id": .string("view-1"),
                "type": .string("imageView"),
                "path": .string("/tmp/simulator screen.png")
            ])
        ]))
        guard case .messageCompleted(let viewedMessage, _) = projector.project(viewed) else {
            return XCTFail("expected viewed image message")
        }
        XCTAssertEqual(viewedMessage.content, "![截图](file:///tmp/simulator%20screen.png)")
    }

    func testProjectorMapsApprovalServerRequest() throws {
        let request = CodexAppServerServerRequest(
            id: .int(9),
            method: "item/commandExecution/requestApproval",
            params: .object([
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("cmd-1"),
                "command": .string("go test ./..."),
                "reason": .string("验证改动")
            ])
        )
        var projector = CodexAppServerEventProjector()
        guard case .approvalRequest(let approval, let metadata) = projector.project(request) else {
            return XCTFail("expected approval request")
        }
        XCTAssertEqual(metadata.sessionID, "thread-1")
        XCTAssertEqual(approval.id, "cmd-1")
        XCTAssertEqual(approval.kind, "command")
        XCTAssertTrue(approval.title.contains("go test"))
        XCTAssertTrue(approval.body?.contains("验证改动") == true)
    }

    func testProjectorMapsSnakeCaseApprovalSessionAliases() throws {
        var projector = CodexAppServerEventProjector()
        let legacyRequest = CodexAppServerServerRequest(
            id: .string("legacy-approval"),
            method: "execCommandApproval",
            params: .object([
                "conversation_id": .string("legacy-conversation"),
                "itemId": .string("legacy-command"),
                "command": .string("pwd")
            ])
        )
        guard case .approvalRequest(_, let legacyMetadata) = projector.project(legacyRequest) else {
            return XCTFail("expected legacy approval request")
        }
        XCTAssertEqual(legacyMetadata.sessionID, "legacy-conversation")

        let modernRequest = CodexAppServerServerRequest(
            id: .string("modern-approval"),
            method: "item/commandExecution/requestApproval",
            params: .object([
                "thread_id": .string("modern-thread"),
                "itemId": .string("modern-command"),
                "command": .string("go test ./...")
            ])
        )
        guard case .approvalRequest(_, let modernMetadata) = projector.project(modernRequest) else {
            return XCTFail("expected modern approval request")
        }
        XCTAssertEqual(modernMetadata.sessionID, "modern-thread")
    }

    func testProjectorMapsClaudeFileApprovalAndPersistentLocalRule() throws {
        let request = CodexAppServerServerRequest(
            id: .string("claude-approval-1"),
            method: "item/fileChange/requestApproval",
            params: .object([
                "threadId": .string("thread-claude"),
                "turnId": .string("turn-claude"),
                "itemId": .string("edit-1"),
                "toolName": .string("Edit"),
                "path": .string("Sources/App.swift"),
                "diff": .string("-old\n+new"),
                "availableDecisions": .array([
                    .string("accept"),
                    .string("acceptWithPermissionUpdate"),
                    .string("decline")
                ]),
                "permissionSuggestions": .array([
                    .object([
                        "type": .string("addRules"),
                        "behavior": .string("allow"),
                        "destination": .string("localSettings"),
                        "rules": .array([
                            .object([
                                "toolName": .string("Edit"),
                                "ruleContent": .string("Sources/**")
                            ])
                        ])
                    ]),
                    .object([
                        "type": .string("setMode"),
                        "behavior": .string("allow"),
                        "destination": .string("userSettings"),
                        "rules": .array([.string("Bash(*)")])
                    ])
                ])
            ])
        )

        var projector = CodexAppServerEventProjector()
        guard case .approvalRequest(let approval, _) = projector.project(request) else {
            return XCTFail("expected Claude file approval")
        }
        XCTAssertEqual(approval.kind, "file_change")
        XCTAssertTrue(approval.body?.contains("Sources/App.swift") == true)
        XCTAssertTrue(approval.body?.contains("+new") == true)
        XCTAssertEqual(approval.persistentPermissionRules, ["Edit(Sources/**)"])
        XCTAssertTrue(approval.availableDecisions?.contains("acceptWithPermissionUpdate") == true)
    }

    func testProjectorMapsUserInputServerRequestSeparatelyFromApproval() throws {
        let request = CodexAppServerServerRequest(
            id: .string("request-1"),
            method: "item/tool/requestUserInput",
            params: .object([
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "itemId": .string("input-1"),
                "questions": .array([
                    .object([
                        "id": .string("scope"),
                        "header": .string("范围"),
                        "question": .string("先做哪一部分？"),
                        "isOther": .bool(true),
                        "isSecret": .bool(false),
                        "options": .array([
                            .object(["label": .string("后端"), "description": .string("先落 API")])
                        ])
                    ])
                ])
            ])
        )
        var projector = CodexAppServerEventProjector()
        guard case .userInputRequest(let userInput, let metadata) = projector.project(request) else {
            return XCTFail("expected user input request")
        }
        XCTAssertEqual(metadata.sessionID, "thread-1")
        XCTAssertEqual(userInput.id, "input-1")
        XCTAssertEqual(userInput.questions.first?.id, "scope")
        XCTAssertEqual(userInput.questions.first?.options.first?.label, "后端")
        XCTAssertFalse(userInput.questions.first?.allowsMultipleSelection ?? true)
    }

    func testProjectorMapsClaudeMultiSelectQuestion() throws {
        let request = CodexAppServerServerRequest(
            id: .string("claude-question"),
            method: "item/tool/requestUserInput",
            params: .object([
                "threadId": .string("thread-claude"),
                "itemId": .string("question-1"),
                "questions": .array([
                    .object([
                        "id": .string("features"),
                        "header": .string("范围"),
                        "question": .string("需要哪些能力？"),
                        "multiSelect": .bool(true),
                        "options": .array([
                            .object(["label": .string("审批")]),
                            .object(["label": .string("额度")])
                        ])
                    ])
                ])
            ])
        )

        var projector = CodexAppServerEventProjector()
        guard case .userInputRequest(let input, _) = projector.project(request) else {
            return XCTFail("expected Claude user input")
        }
        XCTAssertTrue(input.questions.first?.allowsMultipleSelection == true)
    }

    func testProjectorMapsThreadGoalNotifications() throws {
        var projector = CodexAppServerEventProjector()
        let updated = CodexAppServerNotification(method: "thread/goal/updated", params: .object([
            "threadId": .string("thread-1"),
            "goal": .object([
                "threadId": .string("thread-1"),
                "objective": .string("完成 iPad 目标功能"),
                "status": .string("active"),
                "tokenBudget": .int(80_000),
                "tokensUsed": .int(12_000),
                "timeUsedSeconds": .int(360)
            ])
        ]))

        guard case .goalUpdated(let goal, let metadata) = projector.project(updated) else {
            return XCTFail("expected goal updated")
        }
        XCTAssertEqual(metadata.sessionID, "thread-1")
        XCTAssertEqual(goal.threadID, "thread-1")
        XCTAssertEqual(goal.objective, "完成 iPad 目标功能")
        XCTAssertEqual(goal.status, .active)
        XCTAssertEqual(goal.tokenBudget, 80_000)
        XCTAssertEqual(goal.tokensUsed, 12_000)
        XCTAssertEqual(goal.timeUsedSeconds, 360)

        let cleared = CodexAppServerNotification(method: "thread/goal/cleared", params: .object([
            "threadId": .string("thread-1")
        ]))
        guard case .goalCleared(let clearMetadata) = projector.project(cleared) else {
            return XCTFail("expected goal cleared")
        }
        XCTAssertEqual(clearMetadata.sessionID, "thread-1")
    }

    func testCurrentThreadAndReviewRequestBuildersUseOfficialMethodNames() throws {
        let builder = CodexAppServerRequestBuilder(allowlistedProjects: [])

        let setName = try builder.threadSetName(threadID: "thread-1", name: "  发布前收尾  ")
        XCTAssertEqual(setName.method, "thread/name/set")
        XCTAssertEqual(setName.params?["threadId"]?.stringValue, "thread-1")
        XCTAssertEqual(setName.params?["name"]?.stringValue, "发布前收尾")

        XCTAssertEqual(builder.threadCompactStart(threadID: "thread-1").method, "thread/compact/start")
        XCTAssertEqual(builder.threadUnsubscribe(threadID: "thread-1").method, "thread/unsubscribe")

        let review = try builder.reviewStart(
            threadID: "thread-1",
            target: .baseBranch(" main "),
            delivery: .inline
        )
        XCTAssertEqual(review.method, "review/start")
        XCTAssertEqual(review.params?["target"]?.objectValue?["type"]?.stringValue, "baseBranch")
        XCTAssertEqual(review.params?["target"]?.objectValue?["branch"]?.stringValue, "main")
        XCTAssertEqual(review.params?["delivery"]?.stringValue, "inline")

        let uncommitted = try builder.reviewStart(
            threadID: "thread-1",
            target: .uncommittedChanges,
            delivery: .inline
        )
        XCTAssertEqual(uncommitted.params?["target"]?.objectValue?["type"]?.stringValue, "uncommittedChanges")

        let commit = try builder.reviewStart(
            threadID: "thread-1",
            target: .commit(sha: " abc123 ", title: " 修复崩溃 "),
            delivery: .inline
        )
        XCTAssertEqual(commit.params?["target"]?.objectValue?["type"]?.stringValue, "commit")
        XCTAssertEqual(commit.params?["target"]?.objectValue?["sha"]?.stringValue, "abc123")
        XCTAssertEqual(commit.params?["target"]?.objectValue?["title"]?.stringValue, "修复崩溃")

        XCTAssertThrowsError(try builder.reviewStart(
            threadID: "thread-1",
            target: .uncommittedChanges,
            delivery: .detached
        ))
        XCTAssertThrowsError(try builder.reviewStart(
            threadID: "thread-1",
            target: .custom("绕过常规 Turn")
        ))
        XCTAssertThrowsError(try builder.reviewStart(
            threadID: "thread-1",
            target: .baseBranch(" \n "),
            delivery: .inline
        ))
        XCTAssertThrowsError(try builder.reviewStart(
            threadID: "thread-1",
            target: .commit(sha: " \t "),
            delivery: .inline
        ))
    }

    func testMcpElicitationFormProjectsToUserInputAndIgnoresUnknownFields() throws {
        let data = Data(#"""
        {
          "id":"mcp-1",
          "method":"mcpServer/elicitation/request",
          "params":{
            "threadId":"thread-1",
            "turnId":"turn-1",
            "serverName":"github",
            "mode":"form",
            "message":"请选择环境",
            "requestedSchema":{
              "type":"object",
              "properties":{
                "environment":{"type":"string","title":"环境","enum":["staging","production"]},
                "confirmed":{"type":"boolean","title":"确认"}
              }
            },
            "futureField":{"nested":true}
          },
          "futureEnvelope":"ignored"
        }
        """#.utf8)
        let message = try JSONDecoder().decode(CodexAppServerMessage.self, from: data)
        guard case .serverRequest(let request) = message else {
            return XCTFail("expected server request")
        }
        var projector = CodexAppServerEventProjector()
        guard case .userInputRequest(let userInput, let metadata) = projector.project(request) else {
            return XCTFail("expected MCP form user input")
        }
        XCTAssertEqual(metadata.sessionID, "thread-1")
        XCTAssertEqual(userInput.id, "mcp-1")
        XCTAssertEqual(userInput.questions.map(\.id), ["confirmed", "environment"])
        XCTAssertEqual(userInput.questions.first(where: { $0.id == "confirmed" })?.options.map(\.label), ["true", "false"])
        XCTAssertEqual(userInput.questions.first(where: { $0.id == "environment" })?.options.map(\.label), ["staging", "production"])
    }

    func testUnmarkedEmptyOrUnrenderableMcpSchemaFailsClosed() {
        let requests = [
            CodexAppServerServerRequest(
                id: .string("mcp-empty"),
                method: "mcpServer/elicitation/request",
                params: .object([
                    "threadId": .string("thread-1"),
                    "turnId": .string("turn-1"),
                    "serverName": .string("linear"),
                    "mode": .string("form"),
                    "message": .string("Allow the linear MCP server to run tool \"save_issue\"?"),
                    "requestedSchema": .object([
                        "type": .string("object"),
                        "properties": .object([:])
                    ])
                ])
            ),
            CodexAppServerServerRequest(
                id: .string("mcp-object"),
                method: "mcpServer/elicitation/request",
                params: .object([
                    "threadId": .string("thread-1"),
                    "turnId": .string("turn-1"),
                    "serverName": .string("linear"),
                    "mode": .string("form"),
                    "message": .string("Allow this MCP request?"),
                    "requestedSchema": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "nested": .object(["type": .string("object")])
                        ])
                    ])
                ])
            )
        ]

        for request in requests {
            var projector = CodexAppServerEventProjector()
            XCTAssertNil(
                projector.project(request),
                "没有 Codex 工具审批标记的空或不可渲染表单不能暴露授权入口"
            )
        }
    }

    func testUnknownMcpElicitationModeDoesNotExposeApproval() {
        let request = CodexAppServerServerRequest(
            id: .string("mcp-future"),
            method: "mcpServer/elicitation/request",
            params: .object([
                "threadId": .string("thread-1"),
                "serverName": .string("unknown"),
                "mode": .string("future-destructive-mode"),
                "message": .string("Approve everything")
            ])
        )
        var projector = CodexAppServerEventProjector()
        XCTAssertNil(projector.project(request))
    }

    func testCodexMcpToolElicitationProjectsToApprovalWithDeclaredTrustChoices() throws {
        let request = CodexAppServerServerRequest(
            id: .string("mcp-tool-approval-1"),
            method: "mcpServer/elicitation/request",
            params: .object([
                "threadId": .string("thread-1"),
                "turnId": .string("turn-1"),
                "serverName": .string("linear"),
                "mode": .string("form"),
                "message": .string(#"Allow the linear MCP server to run tool "save_issue"?"#),
                "requestedSchema": .object([
                    "type": .string("object"),
                    "properties": .object([:])
                ]),
                "_meta": .object([
                    "codex_approval_kind": .string("mcp_tool_call"),
                    "persist": .array([.string("session"), .string("always")])
                ])
            ])
        )

        var projector = CodexAppServerEventProjector()
        guard case .approvalRequest(let approval, let metadata) = projector.project(request) else {
            return XCTFail("Codex MCP 工具调用应投影为审批，而不是空表单")
        }
        XCTAssertEqual(metadata.sessionID, "thread-1")
        XCTAssertEqual(approval.kind, CodexMCPToolApprovalProtocol.kind)
        XCTAssertTrue(approval.body?.contains("save_issue") == true)
        XCTAssertEqual(
            approval.availableDecisions,
            ["accept", "acceptForSession", "acceptAlways", "decline"]
        )
        let summary = ApprovalSummary(
            id: approval.id,
            title: approval.title,
            body: approval.body,
            kind: approval.kind,
            count: 1,
            availableDecisions: approval.availableDecisions
        )
        XCTAssertTrue(summary.canAcceptMCPToolForSession)
        XCTAssertTrue(summary.canAlwaysAllowMCPTool)
    }

    func testCodexMcpToolElicitationDoesNotInventPersistentTrustChoices() throws {
        let request = CodexAppServerServerRequest(
            id: .string("mcp-tool-destructive"),
            method: "mcpServer/elicitation/request",
            params: .object([
                "threadId": .string("thread-1"),
                "serverName": .string("linear"),
                "mode": .string("form"),
                "message": .string("Allow destructive tool call?"),
                "requestedSchema": .object([
                    "type": .string("object"),
                    "properties": .object([:])
                ]),
                "_meta": .object([
                    "codex_approval_kind": .string("mcp_tool_call")
                ])
            ])
        )

        var projector = CodexAppServerEventProjector()
        guard case .approvalRequest(let approval, _) = projector.project(request) else {
            return XCTFail("expected MCP tool approval")
        }
        XCTAssertEqual(approval.availableDecisions, ["accept", "decline"])
        let summary = ApprovalSummary(
            id: approval.id,
            title: approval.title,
            body: approval.body,
            kind: approval.kind,
            count: 1,
            availableDecisions: approval.availableDecisions
        )
        XCTAssertFalse(summary.canAcceptMCPToolForSession)
        XCTAssertFalse(summary.canAlwaysAllowMCPTool)
    }

    func testMcpURLelicitationProjectsToExplicitApproval() {
        let request = CodexAppServerServerRequest(
            id: .int(17),
            method: "mcpServer/elicitation/request",
            params: .object([
                "threadId": .string("thread-1"),
                "serverName": .string("calendar"),
                "mode": .string("url"),
                "message": .string("请完成授权"),
                "url": .string("https://example.test/oauth")
            ])
        )
        var projector = CodexAppServerEventProjector()
        guard case .approvalRequest(let approval, let metadata) = projector.project(request) else {
            return XCTFail("expected MCP URL approval")
        }
        XCTAssertEqual(metadata.sessionID, "thread-1")
        XCTAssertEqual(approval.id, "17")
        XCTAssertEqual(approval.kind, "mcp_elicitation")
        XCTAssertTrue(approval.body?.contains("https://example.test/oauth") == true)
    }

    func testRuntimeProjectsThreadNameUpdateIntoCachedSession() async {
        let runtime = CodexAppServerSessionRuntime(
            endpoint: "http://127.0.0.1:8787",
            token: "test"
        )
        await runtime.handle(CodexAppServerNotification(
            method: "thread/started",
            params: .object([
                "thread": .object([
                    "id": .string("thread-title"),
                    "cwd": .string("/tmp/thread-title"),
                    "name": .string("旧标题"),
                    "status": .object(["type": .string("idle")])
                ])
            ])
        ))
        await runtime.handle(CodexAppServerNotification(
            method: "thread/name/updated",
            params: .object([
                "threadId": .string("thread-title"),
                "threadName": .string("  新标题  ")
            ])
        ))

        let shell = await runtime.historyThreadShell(
            sessionID: "thread-title",
            projects: []
        )

        XCTAssertEqual(shell["name"]?.stringValue, "新标题")
    }

    func testRuntimeBuildsTypedMcpElicitationResponses() async {
        let runtime = CodexAppServerSessionRuntime(endpoint: "http://127.0.0.1:8787", token: "test")
        let form = CodexAppServerServerRequest(
            id: .string("mcp-form"),
            method: "mcpServer/elicitation/request",
            params: .object([
                "threadId": .string("thread-1"),
                "mode": .string("form"),
                "requestedSchema": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "confirmed": .object(["type": .string("boolean")]),
                        "retries": .object(["type": .string("integer")]),
                        "scopes": .object(["type": .string("array")])
                    ])
                ])
            ])
        )
        let accepted = await runtime.userInputResponse(for: form, answers: [
            "confirmed": ["true"],
            "retries": ["3"],
            "scopes": ["read", "write"]
        ])
        XCTAssertEqual(accepted["action"]?.stringValue, "accept")
        XCTAssertEqual(accepted["content"]?.objectValue?["confirmed"]?.boolValue, true)
        XCTAssertEqual(accepted["content"]?.objectValue?["retries"]?.intValue, 3)
        XCTAssertEqual(accepted["content"]?.objectValue?["scopes"]?.arrayValue?.compactMap(\.stringValue), ["read", "write"])

        let declined = await runtime.userInputResponse(for: form, answers: [:])
        XCTAssertEqual(declined["action"]?.stringValue, "decline")
        XCTAssertEqual(declined["content"], .null)

        let url = CodexAppServerServerRequest(
            id: .int(7),
            method: "mcpServer/elicitation/request",
            params: .object(["threadId": .string("thread-1"), "mode": .string("url")])
        )
        let urlAccepted = await runtime.approvalResponse(method: url.method, params: url.params?.objectValue ?? [:], decision: "accept")
        XCTAssertEqual(urlAccepted["action"]?.stringValue, "accept")
        XCTAssertEqual(urlAccepted["content"], .null)
    }

    func testRuntimeBuildsScopedCodexMcpToolApprovalResponsesAndFailsClosed() async {
        let runtime = CodexAppServerSessionRuntime(endpoint: "http://127.0.0.1:8787", token: "test")
        let params: [String: CodexAppServerJSONValue] = [
            "mode": .string("form"),
            "_meta": .object([
                "codex_approval_kind": .string("mcp_tool_call"),
                "persist": .array([.string("session"), .string("always")])
            ])
        ]

        let once = await runtime.approvalResponse(
            method: "mcpServer/elicitation/request",
            params: params,
            decision: "accept"
        )
        XCTAssertEqual(once["action"]?.stringValue, "accept")
        XCTAssertEqual(once["_meta"], .null)

        let session = await runtime.approvalResponse(
            method: "mcpServer/elicitation/request",
            params: params,
            decision: "acceptForSession"
        )
        XCTAssertEqual(session["action"]?.stringValue, "accept")
        XCTAssertEqual(session["_meta"]?.objectValue?["persist"]?.stringValue, "session")

        let always = await runtime.approvalResponse(
            method: "mcpServer/elicitation/request",
            params: params,
            decision: "acceptAlways"
        )
        XCTAssertEqual(always["action"]?.stringValue, "accept")
        XCTAssertEqual(always["_meta"]?.objectValue?["persist"]?.stringValue, "always")

        let oneTimeOnlyParams: [String: CodexAppServerJSONValue] = [
            "mode": .string("form"),
            "_meta": .object(["codex_approval_kind": .string("mcp_tool_call")])
        ]
        let forgedAlways = await runtime.approvalResponse(
            method: "mcpServer/elicitation/request",
            params: oneTimeOnlyParams,
            decision: "acceptAlways"
        )
        XCTAssertEqual(forgedAlways["action"]?.stringValue, "decline")
        XCTAssertEqual(forgedAlways["_meta"], .null)
    }

    func testProjectorMapsPlanReasoningUsageCompactionNameMCPAndDeprecationNotifications() throws {
        var projector = CodexAppServerEventProjector()

        let plan = CodexAppServerNotification(method: "turn/plan/updated", params: .object([
            "threadId": .string("thread-1"),
            "turnId": .string("turn-1"),
            "plan": .array([
                .object(["step": .string("补齐协议"), "status": .string("completed")]),
                .object(["step": .string("运行测试"), "status": .string("inProgress")])
            ])
        ]))
        guard case .messageCompleted(let planMessage, _) = projector.project(plan) else {
            return XCTFail("expected plan message")
        }
        XCTAssertEqual(planMessage.kind, .plan)
        XCTAssertTrue(planMessage.content.contains("补齐协议"))

        let planDelta = CodexAppServerNotification(method: "item/plan/delta", params: .object([
            "threadId": .string("thread-1"), "turnId": .string("turn-1"), "itemId": .string("plan-item"),
            "delta": .string("正在补齐协议")
        ]))
        guard case .messageCompleted(let planDeltaMessage, _) = projector.project(planDelta) else {
            return XCTFail("expected plan delta message")
        }
        XCTAssertEqual(planDeltaMessage.kind, .plan)
        XCTAssertEqual(planDeltaMessage.content, "正在补齐协议")

        let reasoning1 = CodexAppServerNotification(method: "item/reasoning/summaryTextDelta", params: .object([
            "threadId": .string("thread-1"), "turnId": .string("turn-1"), "itemId": .string("reason-1"),
            "summaryIndex": .int(0), "delta": .string("先检查")
        ]))
        let reasoning2 = CodexAppServerNotification(method: "item/reasoning/summaryTextDelta", params: .object([
            "threadId": .string("thread-1"), "turnId": .string("turn-1"), "itemId": .string("reason-1"),
            "summaryIndex": .int(0), "delta": .string("再修复")
        ]))
        _ = projector.project(reasoning1)
        let summaryBoundary = CodexAppServerNotification(method: "item/reasoning/summaryPartAdded", params: .object([
            "threadId": .string("thread-1"), "turnId": .string("turn-1"), "itemId": .string("reason-1"),
            "summaryIndex": .int(1)
        ]))
        XCTAssertNil(projector.project(summaryBoundary), "summaryPartAdded 仅是分段边界，不应制造空消息")
        guard case .messageCompleted(let reasoningMessage, _) = projector.project(reasoning2) else {
            return XCTFail("expected reasoning message")
        }
        XCTAssertEqual(reasoningMessage.kind, .reasoningSummary)
        XCTAssertEqual(reasoningMessage.content, "先检查再修复")

        let usage = CodexAppServerNotification(method: "thread/tokenUsage/updated", params: .object([
            "threadId": .string("thread-1"), "turnId": .string("turn-1"),
            "tokenUsage": .object([
                "total": .object(["inputTokens": .int(100), "outputTokens": .int(50), "totalTokens": .int(150)]),
                "modelContextWindow": .int(200_000)
            ])
        ]))
        guard case .sessionContext(let usageContext, _) = projector.project(usage) else {
            return XCTFail("expected token context")
        }
        XCTAssertEqual(usageContext.tasks.first?.kind, "token_usage")
        XCTAssertTrue(usageContext.tasks.first?.subtitle?.contains("150") == true)

        let compacted = CodexAppServerNotification(method: "thread/compacted", params: .object([
            "threadId": .string("thread-1"), "turnId": .string("turn-1")
        ]))
        XCTAssertNil(projector.project(compacted), "compaction 只更新模型上下文，不能写入可见 transcript")

        let named = CodexAppServerNotification(method: "thread/name/updated", params: .object([
            "threadId": .string("thread-1"), "threadName": .string("新名称")
        ]))
        XCTAssertNil(projector.project(named), "标题是导航元数据，不应写入 transcript")

        let mcp = CodexAppServerNotification(method: "item/mcpToolCall/progress", params: .object([
            "threadId": .string("thread-1"), "turnId": .string("turn-1"), "itemId": .string("mcp-item"),
            "message": .string("正在读取日历")
        ]))
        guard case .sessionContext(let mcpContext, _) = projector.project(mcp) else {
            return XCTFail("expected MCP progress context")
        }
        XCTAssertEqual(mcpContext.tasks.first?.subtitle, "正在读取日历")

        let deprecation = CodexAppServerNotification(method: "deprecationNotice", params: .object([
            "summary": .string("旧方法已废弃"), "details": .string("请迁移")
        ]))
        guard case .warning(let warning, _) = projector.project(deprecation) else {
            return XCTFail("expected deprecation warning")
        }
        XCTAssertEqual(warning.code, "deprecationNotice")
        XCTAssertTrue(warning.message.contains("请迁移"))
    }
}
