import XCTest
@testable import MimiRemote

@MainActor
final class ConversationActivityDetailProjectionTests: XCTestCase {
    func testLiveAndHistoryKeepCommandOutputBeyondCompactPreview() async throws {
        let output = String(repeating: "line of command output\n", count: 100) + "last output line"
        let item = command(output: output)
        var projector = CodexAppServerEventProjector()
        let live = try message(from: projector.project(notification(item)))
        let history = try await history(item)

        XCTAssertEqual(live.content, output)
        XCTAssertEqual(history.content, output)
        XCTAssertEqual(live.id, history.id)
        XCTAssertEqual(live.activityPayload, history.activityPayload)
        XCTAssertLessThan(try XCTUnwrap(live.activityPayload?.outputPreview).count, output.count)
        XCTAssertFalse(try XCTUnwrap(live.activityPayload?.outputPreview).contains("last output line"))
    }

    func testReasoningPartsAccumulateIntoOneItemAndCompletionReplacesThem() throws {
        var projector = CodexAppServerEventProjector()
        let store = ConversationStore()
        for (index, text) in [(0, "**检查文件**\n第一段"), (1, "**确定方案**\n第二段")] {
            let delta = CodexAppServerNotification(method: "item/reasoning/summaryTextDelta", params: .object([
                "threadId": .string("thread-details"), "turnId": .string("turn-details"),
                "itemId": .string("reasoning-details"), "summaryIndex": .int(Int64(index)), "delta": .string(text)
            ]))
            guard case .messageCompleted(let item, let metadata) = try XCTUnwrap(projector.project(delta)) else {
                return XCTFail("reasoning delta must remain visible")
            }
            store.completeMessage(item, metadata: metadata, fallbackSessionID: "thread-details")
        }
        let messages = store.messages(for: "thread-details")
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.content, "**检查文件**\n第一段\n\n**确定方案**\n第二段")
        let originalID = messages.first?.id
        let item: [String: CodexAppServerJSONValue] = [
            "type": .string("reasoning"), "id": .string("reasoning-details"),
            "summary": .array([.string("**检查文件**\n第一段"), .string("**确定方案**\n第二段终稿")]),
            "content": .array([])
        ]
        guard case .processItemCompleted(let final, _, let metadata) = try XCTUnwrap(projector.project(notification(item))) else {
            return XCTFail("reasoning completion must retain the full content")
        }
        store.completeMessage(final, metadata: metadata, fallbackSessionID: "thread-details")
        XCTAssertEqual(store.messages(for: "thread-details").count, 1)
        XCTAssertEqual(store.messages(for: "thread-details").first?.id, originalID)
        XCTAssertTrue(store.messages(for: "thread-details").first?.content.hasSuffix("第二段终稿") == true)
    }

    func testClaudeThinkingTextDeltaUsesTheSameIdentityAsItsCompletion() throws {
        var projector = CodexAppServerEventProjector()
        let delta = CodexAppServerNotification(method: "item/reasoning/textDelta", params: .object([
            "threadId": .string("thread-details"), "turnId": .string("turn-details"),
            "itemId": .string("claude-thinking"), "contentIndex": .int(0), "delta": .string("Live thinking")
        ]))
        let streamed = try message(from: projector.project(delta))
        let completed = try message(from: projector.project(notification([
            "type": .string("reasoning"), "id": .string("claude-thinking"),
            "summary": .array([]), "content": .array([.string("Live thinking finished")])
        ])))
        XCTAssertEqual(streamed.content, "Live thinking")
        XCTAssertEqual(completed.content, "Live thinking finished")
        XCTAssertEqual(streamed.id, completed.id)
        XCTAssertEqual(streamed.itemID, completed.itemID)
    }

    func testReasoningDetailsPreserveAllSuppliedSummaryAndContentBlocks() async throws {
        let item: [String: CodexAppServerJSONValue] = [
            "type": .string("reasoning"), "id": .string("reasoning-details"),
            "summary": .array([.string("First summary"), .string("Second summary")]),
            "content": .array([.string("Additional supplied reasoning")])
        ]
        let result = try await history(item)
        XCTAssertEqual(result.content, "First summary\n\nSecond summary\n\nAdditional supplied reasoning")
    }

    func testFileDiffIsPreservedAndChangesInvalidateThePayload() async throws {
        let diff = "@@ -1 +1 @@\n-old\n+new\n" + String(repeating: "+added\n", count: 200)
        var item: [String: CodexAppServerJSONValue] = [
            "type": .string("fileChange"), "id": .string("edit-details"), "status": .string("completed"),
            "changes": .array([.object(["path": .string("sample.swift"), "kind": .string("update"), "diff": .string(diff)])])
        ]
        let original = try await history(item)
        XCTAssertEqual(original.content, "sample.swift\n" + diff)
        item["changes"] = .array([.object(["path": .string("sample.swift"), "kind": .string("update"), "diff": .string(diff + "+last\n")])])
        let updated = try await history(item)
        XCTAssertNotEqual(original.activityPayload, updated.activityPayload)
        XCTAssertEqual(updated.content, "sample.swift\n" + diff + "+last\n")
    }

    func testMCPAndDynamicResultsUseReadableContentAndKeepFailures() async throws {
        let results: [[String: CodexAppServerJSONValue]] = [
            ["type": .string("mcpToolCall"), "id": .string("mcp-details"), "server": .string("sample"),
             "tool": .string("lookup"), "status": .string("completed"),
             "result": .object(["content": .array([.object(["type": .string("text"), "text": .string("Visible result")])])])],
            ["type": .string("dynamicToolCall"), "id": .string("dynamic-details"), "namespace": .string("claude"),
             "tool": .string("WebSearch"), "status": .string("failed"), "success": .bool(false),
             "contentItems": .array([.object(["type": .string("inputText"), "text": .string("Visible result")])])]
        ]
        for item in results {
            var projector = CodexAppServerEventProjector()
            let live = try message(from: projector.project(notification(item)))
            let restored = try await history(item)
            XCTAssertEqual(live.content, "Visible result")
            XCTAssertEqual(restored.content, live.content)
            XCTAssertEqual(restored.activityPayload?.outputPreview, "Visible result")
        }
        for var item in results {
            item["arguments"] = .object(["query": .string("requested value"), "limit": .int(5)])
            var projector = CodexAppServerEventProjector()
            let live = try message(from: projector.project(notification(item)))
            let restored = try await history(item)
            XCTAssertEqual(live.content, restored.content)
            XCTAssertTrue(live.content.contains("requested value"))
            XCTAssertTrue(live.content.contains("\"limit\""))
            XCTAssertTrue(live.content.contains("Visible result"))
            XCTAssertEqual(restored.activityPayload?.outputPreview, "Visible result")
        }
        XCTAssertTrue(try XCTUnwrap(ConversationActivityPayload(item: results[1])).isFailure)
        XCTAssertEqual(ConversationActivityPayload(item: results[1])?.displayTitle, L10n.text("ui.web_search"))
        let error: [String: CodexAppServerJSONValue] = [
            "type": .string("mcpToolCall"), "id": .string("failure"), "tool": .string("lookup"),
            "status": .string("failed"), "error": .object(["message": .string("Connection failed")])
        ]
        let failed = try await history(error)
        XCTAssertEqual(failed.content, "Connection failed")
        var structuredError = error
        structuredError["error"] = .object([
            "message": .string("Connection failed"), "code": .int(-32000),
            "data": .object(["reason": .string("Upstream timed out")])
        ])
        var projector = CodexAppServerEventProjector()
        let liveFailure = try message(from: projector.project(notification(structuredError)))
        let restoredFailure = try await history(structuredError)
        XCTAssertEqual(liveFailure.content, restoredFailure.content)
        XCTAssertTrue(liveFailure.content.contains("Connection failed"))
        XCTAssertTrue(liveFailure.content.contains("-32000"))
        XCTAssertTrue(liveFailure.content.contains("Upstream timed out"))
    }

    func testMCPDetailsKeepStructuredResultAndDoNotRenderMediaData() {
        let media: CodexAppServerJSONValue = .object([
            "type": .string("image"), "data": .string("BASE64_IMAGE_DATA"), "mimeType": .string("image/png")
        ])
        let result: CodexAppServerJSONValue = .object([
            "content": .array([media, .object(["type": .string("text"), "text": .string("Search complete")])]),
            "structuredContent": .object(["count": .int(3)])
        ])
        let text = ConversationActivityDetailText.render(result)
        XCTAssertTrue(text?.contains("Search complete") == true)
        XCTAssertTrue(text?.contains("\"count\" : 3") == true)
        XCTAssertFalse(text?.contains("BASE64_IMAGE_DATA") == true)
        XCTAssertNil(ConversationActivityDetailText.render(.object(["content": .array([media])])))
    }

    func testSubagentCompletionKeepsBothTimelineResultAndChildRelationship() async throws {
        let item: [String: CodexAppServerJSONValue] = [
            "type": .string("collabAgentToolCall"), "id": .string("agent-details"), "tool": .string("spawn_agent"),
            "status": .string("completed"), "receiverThreadIds": .array([.string("child-details")]),
            "agentsStates": .object(["child-details": .object(["status": .string("completed"), "message": .string("Review finished")])])
        ]
        var projector = CodexAppServerEventProjector()
        guard case .processItemCompleted(let result, let context, _) = try XCTUnwrap(projector.project(notification(item))) else {
            return XCTFail("must preserve the activity and relationship together")
        }
        XCTAssertEqual(result.content, "Review finished")
        XCTAssertEqual(context?.subagents.first?.id, "child-details")
        XCTAssertEqual(context?.subagents.first?.statusMessage, "Review finished")
        let restored = try await history(item)
        XCTAssertEqual(restored.content, result.content)
    }

    func testMCPStructuredBusinessFieldsSurviveLiveAndHistoryProjection() async throws {
        let results: [CodexAppServerJSONValue] = [
            .object(["text": .string("查询完成"), "rows": .array([.object(["id": .string("record-1")])]), "nextCursor": .string("page-2")]),
            .object(["content": .string("业务正文"), "count": .int(3)]),
            .object(["message": .string("业务消息"), "rows": .array([.int(1), .int(2)])]),
            .object(["type": .string("image"), "assetID": .string("business-asset")]),
            .object(["contentItems": .array([.object([
                "text": .string("嵌套正文"), "metadata": .object(["type": .string("audio"), "id": .string("nested-record")])
            ])])])
        ]
        for structured in results {
            let item: [String: CodexAppServerJSONValue] = [
                "type": .string("mcpToolCall"), "id": .string("structured-business"),
                "server": .string("sample"), "tool": .string("lookup"), "status": .string("completed"),
                "result": .object(["content": .array([]), "structuredContent": structured])
            ]
            var projector = CodexAppServerEventProjector()
            let live = try message(from: projector.project(notification(item)))
            let restored = try await history(item)
            XCTAssertEqual(live.content, restored.content)
            // 详细正文仍能还原为原始业务对象，不能因键名碰巧相同就只剩摘要。
            let decoded = try JSONDecoder().decode(CodexAppServerJSONValue.self, from: Data(live.content.utf8))
            XCTAssertEqual(decoded, structured)
        }
    }

    func testNativeSubagentPromptAndWebSearchQueryRemainInDetailedRecords() async throws {
        let prompt = "检查第一项\n" + String(repeating: "继续检查\n", count: 250) + "PROMPT-END"
        let query = "exact query with QUERY-END"
        let subagent: [String: CodexAppServerJSONValue] = [
            "type": .string("collabAgentToolCall"), "id": .string("native-subagent"), "tool": .string("spawn_agent"),
            "status": .string("completed"), "prompt": .string(prompt),
            "receiverThreadIds": .array([.string("child-details")]),
            "agentsStates": .object(["child-details": .object(["status": .string("completed"), "message": .string("Review finished")])])
        ]
        let search: [String: CodexAppServerJSONValue] = [
            "type": .string("webSearch"), "id": .string("native-search"), "query": .string(query)
        ]
        for (item, input) in [(subagent, prompt), (search, query)] {
            var projector = CodexAppServerEventProjector()
            let live = try message(from: projector.project(notification(item)))
            let restored = try await history(item)
            XCTAssertEqual(live.content, restored.content)
            XCTAssertTrue(live.content.contains(input))
            let payload = try XCTUnwrap(restored.activityPayload)
            XCTAssertFalse(payload.displayTitle.contains(input))
            XCTAssertFalse(payload.outputPreview?.contains(input) == true)
        }
        let restoredSubagent = try await history(subagent)
        XCTAssertTrue(restoredSubagent.content.contains("Review finished"))
        let restoredSearch = try await history(search)
        XCTAssertEqual(restoredSearch.activityPayload?.displayTitle, L10n.text("ui.web_search"))
    }

    func testExternalHistoryOutputKeepsPreviewAndItsFullOutputReference() async throws {
        var item = command(output: "Stored preview")
        item["historyOutputRef"] = .string("agentd-history-output://details")
        item["historyOutputPreview"] = .string("Stored preview")
        item["historyOutputByteCount"] = .int(50_000)
        let restored = try await history(item)
        XCTAssertEqual(restored.content, "Stored preview")
        XCTAssertEqual(restored.activityPayload?.historyOutputID, "details")
        XCTAssertEqual(restored.activityPayload?.outputByteCount, 50_000)
    }

    func testClaudeTaskHistoryRestoresLatestStateWithoutInventingTaskIDs() async throws {
        let create = task(tool: "TaskCreate", args: ["subject": .string("Run tests")], output: #"{"task":{"id":"7"}}"#)
        let update = task(tool: "TaskUpdate", args: ["taskId": .string("7"), "status": .string("completed")])
        let unknown = task(tool: "TaskCreate", args: ["subject": .string("No identity")], output: "Created")
        let turn: [String: CodexAppServerJSONValue] = ["items": .array([create, update, unknown].map(CodexAppServerJSONValue.object))]
        let tasks = ClaudeTaskHistoryProjection.tasks(in: [turn])
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.title, "Run tests")
        XCTAssertEqual(tasks.first?.status, "completed")
        let runtime = CodexAppServerSessionRuntime(endpoint: "http://127.0.0.1:8787", token: "test")
        let context = await runtime.contextTasks(from: ["turns": .array([.object(turn)])])
        XCTAssertEqual(context.map(\.id), ["claude-task:7"])
        var projector = CodexAppServerEventProjector()
        guard case .processItemCompleted(let message, let liveContext, _) = try XCTUnwrap(projector.project(notification(create))) else {
            return XCTFail("task mutation must remain visible in the timeline")
        }
        XCTAssertTrue(message.content.contains("Run tests"))
        XCTAssertTrue(message.content.contains(#"{"task":{"id":"7"}}"#))
        XCTAssertEqual(message.activityPayload?.outputPreview, #"{"task":{"id":"7"}}"#)
        XCTAssertTrue(liveContext?.tasks.isEmpty != false)
    }

    private func command(output: String) -> [String: CodexAppServerJSONValue] {
        ["type": .string("commandExecution"), "id": .string("command-details"), "command": .string("run tests"),
         "status": .string("completed"), "aggregatedOutput": .string(output), "exitCode": .int(0)]
    }

    private func task(tool: String, args: [String: CodexAppServerJSONValue], output: String = "Updated") -> [String: CodexAppServerJSONValue] {
        ["type": .string("dynamicToolCall"), "id": .string(tool), "namespace": .string("claude"),
         "tool": .string(tool), "arguments": .object(args), "status": .string("completed"), "success": .bool(true),
         "contentItems": .array([.object(["type": .string("inputText"), "text": .string(output)])])]
    }

    private func notification(_ item: [String: CodexAppServerJSONValue]) -> CodexAppServerNotification {
        CodexAppServerNotification(method: "item/completed", params: .object([
            "threadId": .string("thread-details"), "turnId": .string("turn-details"), "item": .object(item)
        ]))
    }

    private func message(from event: AgentEvent?) throws -> AgentMessage {
        switch try XCTUnwrap(event) {
        case .processItemCompleted(let message, _, _), .messageCompleted(let message, _): return message
        default: throw NSError(domain: "Unexpected activity event", code: 1)
        }
    }

    private func history(_ item: [String: CodexAppServerJSONValue]) async throws -> CodexHistoryMessage {
        let runtime = CodexAppServerSessionRuntime(endpoint: "http://127.0.0.1:8787", token: "test")
        let items = await runtime.historyMessages(from: ["turns": .array([.object([
            "id": .string("turn-details"), "status": .string("completed"), "startedAt": .int(100), "completedAt": .int(101),
            "items": .array([.object(item)])
        ])])], sessionID: "thread-details", snapshotReadAt: Date(timeIntervalSince1970: 102))
        return try XCTUnwrap(items.first)
    }
}
