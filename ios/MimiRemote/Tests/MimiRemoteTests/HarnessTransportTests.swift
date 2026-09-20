import Foundation
import XCTest
@testable import MimiRemote

/// H04 传输层测试。
///
/// 三条纪律：
/// 1. **夹具共用**：所有 wire 形状断言都读 `contracts/harness-native/fixtures/*`——与 Go 侧
///    读的是同一份字节。Swift 自己造一份"自洽"的形状，就等于把契约漂移藏进测试里。
/// 2. **不依赖外网、不用真实 Key**：RPC 走 URLProtocol 替身，流走内存替身。
/// 3. **每条拒绝都配一条正向对照**：只有负向用例的套件可能整体是空断言——全部被拒
///    和策略生效看起来一模一样。H03 已经因此漏掉过一个真实缺陷。
final class HarnessTransportTests: XCTestCase {

    // MARK: - 夹具共用

    /// 读一份与 Go 侧共用的原始夹具。
    func harnessFixture(_ name: String) throws -> Data {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 { root.deleteLastPathComponent() }
        return try Data(contentsOf: root
            .appendingPathComponent("contracts/harness-native/fixtures")
            .appendingPathComponent(name))
    }

    func harnessFixtureJSON(_ name: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: harnessFixture(name))
        return try XCTUnwrap(object as? [String: Any], "夹具 \(name) 顶层不是对象")
    }

    /// 取某个 observation 的 value（再编码回 JSON 值容器）。
    func harnessObservation(_ name: String, label: String) throws -> HarnessJSONValue {
        let fixture = try harnessFixtureJSON(name)
        let observations = try XCTUnwrap(fixture["observations"] as? [[String: Any]])
        let match = observations.first { ($0["label"] as? String) == label }
        let value = try XCTUnwrap(match?["value"], "夹具 \(name) 缺少观测 \(label)")
        let data = try JSONSerialization.data(withJSONObject: value)
        return try JSONDecoder().decode(HarnessJSONValue.self, from: data)
    }

    // MARK: - 1. 客户端帧与共用夹具逐字一致

    /// follow 的 open 帧必须与 `stream/mux-carrier.json` 的 `client.open` 观测一致。
    ///
    /// 这是 H03 自审踩过的那个坑的对称保护：`address` 嵌在 `request` 下面。把 address
    /// 当顶层键，每个 follow 都会被拒——而"全都被拒"看起来和策略生效一模一样。
    func testFollowOpenFrameMatchesSharedMuxCarrierFixture() throws {
        let fixture = try harnessObservation("stream/mux-carrier.json", label: "client.open")
        let expected = try XCTUnwrap(fixture["payload"]?["args"])

        let target = HarnessFollowTarget(
            sessionID: "h00-session-0001",
            assistantStream: true,
            maxMessages: 200
        )
        let frame = HarnessClientFrame.open(
            streamID: "h00-rpc-0001",
            endpoint: HarnessWireEndpoint.sessionFollow,
            args: target.argsValue
        )

        XCTAssertEqual(frame.wireValue["payload"]?["args"], expected)
        XCTAssertEqual(frame.wireValue["type"], .string("open"))
        XCTAssertEqual(frame.wireValue["endpoint"], .string("session/follow"))
        // 反向对照：address 不能出现在 args 顶层。
        XCTAssertNil(target.argsValue["address"], "address 必须嵌在 request 下面")
    }

    /// `follow-frames.json` 的 `request` 观测与 `HarnessFollowTarget` 必须同形。
    func testFollowTargetMatchesSharedFollowFramesFixture() throws {
        let fixture = try harnessObservation("stream/follow-frames.json", label: "request")
        let target = HarnessFollowTarget(
            sessionID: "h00-session-0001",
            assistantStream: true,
            maxMessages: 200
        )
        XCTAssertEqual(target.argsValue, fixture)
    }

    // MARK: - 2. 载体层判别式

    /// 载体帧解码与 `mux-carrier.json` 一致；载体层与 value 层是**两层**。
    func testCarrierDecoderMatchesSharedMuxCarrierFixture() throws {
        func carrier(_ label: String) throws -> HarnessCarrierFrame {
            let value = try harnessObservation("stream/mux-carrier.json", label: label)
            let data = try JSONEncoder().encode(value)
            return try JSONDecoder().decode(HarnessCarrierFrame.self, from: data)
        }

        let item = try XCTUnwrap(try HarnessCarrierDecoder.decode(frame: carrier("server.item")))
        XCTAssertEqual(item.streamID, "h00-rpc-0001")
        guard case .value = item.frame else {
            return XCTFail("server.item 必须解成 value 帧")
        }

        let error = try XCTUnwrap(try HarnessCarrierDecoder.decode(frame: carrier("server.error")))
        guard case .carrierError(let remote) = error.frame else {
            return XCTFail("server.error 必须解成载体层错误，不能当成空帧")
        }
        XCTAssertEqual(remote.code, "gateway/internal")

        let end = try XCTUnwrap(try HarnessCarrierDecoder.decode(frame: carrier("server.end")))
        XCTAssertEqual(end.frame, .carrierEnd)
    }

    /// 没有 streamId 的帧不能归属，必须显式返回 nil 而不是猜一个订阅。
    func testCarrierFrameWithoutStreamIDIsNotAttributable() throws {
        let frame = HarnessCarrierFrame(
            type: HarnessWireCarrier.item,
            streamId: nil,
            value: .object(["type": .string("ready")]),
            error: nil
        )
        XCTAssertNil(try HarnessCarrierDecoder.decode(frame: frame))
    }

    /// 服务端声明 error 却没带 error 对象时，不能当成成功，也不能当成"空错误"。
    func testCarrierErrorWithoutErrorObjectStillFails() throws {
        let frame = HarnessCarrierFrame(
            type: HarnessWireCarrier.error,
            streamId: "s1",
            value: nil,
            error: nil
        )
        let decoded = try XCTUnwrap(try HarnessCarrierDecoder.decode(frame: frame))
        guard case .carrierError(let remote) = decoded.frame else {
            return XCTFail("缺 error 对象的 error 帧仍必须是载体层失败")
        }
        XCTAssertEqual(remote.code, "gateway/internal")
    }

    // MARK: - 3. 原生身份字段保留

    /// durable event 的 seq 与事件名必须原样保留（夹具 `toolCallEvent`）。
    func testDurableEventKeepsNativeIdentityFields() throws {
        let value = try harnessObservation("stream/durable-events.json", label: "toolCallEvent")
        // 夹具给的是 item 的 `value`（判别式在 value.type），不是整帧载体。
        // 载体帧是 {type:"item", streamId, value}——少包一层就会因为缺 streamId 而无法归属。
        XCTAssertEqual(value["type"], .string(HarnessWireFrame.durableEvent))
        XCTAssertNil(value["streamId"], "夹具的这一项是 value，不是载体帧")
        let carrier = HarnessCarrierFrame(
            type: HarnessWireCarrier.item,
            streamId: "h00-rpc-0001",
            value: value,
            error: nil
        )
        let decoded = try XCTUnwrap(try HarnessCarrierDecoder.decode(frame: carrier))
        guard case .value(let streamValue) = decoded.frame else {
            return XCTFail("durable event 必须解成 value 帧")
        }

        let identity = HarnessSessionRuntime.identity(of: streamValue)
        XCTAssertEqual(identity.frameType, HarnessWireFrame.durableEvent)
        XCTAssertEqual(identity.eventType, "permission/preset")
        XCTAssertEqual(identity.seq, 0)
        XCTAssertTrue(streamValue.isDurableEvent)
        // 未知可展示字段必须留在 raw 里，不能被丢弃。
        XCTAssertEqual(streamValue.raw["event"]?["data"]?["preset"], .string("workspace-write"))
    }

    /// 直播片段的 revision 必须保留——revision 断档是"重开 follow"的唯一依据。
    func testAssistantStreamKeepsRevisionAndAttemptIdentity() throws {
        let raw = HarnessJSONValue.object([
            "type": .string(HarnessWireFrame.assistantStream),
            "frame": .object([
                "type": .string(HarnessWireAssistantFrame.end),
                "attemptId": .string("attempt-identity"),
                "revision": .number(7),
                "index": .number(3),
                "outcome": .object([
                    "kind": .string("committed"),
                    "eventType": .string("assistant/attempt"),
                    "seq": .number(42),
                ]),
            ]),
        ])
        let streamValue = HarnessStreamValue(
            type: HarnessWireFrame.assistantStream,
            eventType: nil,
            raw: raw
        )
        let identity = HarnessSessionRuntime.identity(of: streamValue)
        XCTAssertEqual(identity.revision, 7)
        XCTAssertEqual(identity.seq, 42)
        XCTAssertEqual(identity.attemptID, "attempt-identity")
    }

    func testAssistantStreamFrameDecodesFromNestedFollowEnvelope() throws {
        let raw: HarnessJSONValue = .object([
            "type": .string(HarnessWireFrame.assistantStream),
            "frame": .object([
                "type": .string(HarnessWireAssistantFrame.chunk),
                "attemptId": .string("attempt-nested"),
                "revision": .number(2),
                "index": .number(0),
                "time": .number(100),
                "chunk": .object([
                    "type": .string(HarnessWireChunkType.textDelta),
                    "index": .number(0),
                    "text": .string("nested"),
                ]),
            ]),
        ])
        let value = HarnessStreamValue(
            type: HarnessWireFrame.assistantStream,
            eventType: nil,
            raw: raw
        )

        let frame = try HarnessAssistantStreamFrame.decode(from: value)

        XCTAssertEqual(frame.type, HarnessWireAssistantFrame.chunk)
        XCTAssertEqual(frame.attemptId, "attempt-nested")
        XCTAssertEqual(frame.chunk?.text, "nested")
    }

    // MARK: - 4. 200 业务失败

    /// HTTP 200 + `result.ok=false` 是**业务**失败，不是可重连的链路故障。
    func testBusinessFailureOnHTTP200IsNotReconnectable() throws {
        let envelope = try harnessObservation(
            "rpc/envelope-errors.json",
            label: "error.gateway/arguments-invalid"
        )
        let data = try JSONEncoder().encode(envelope)

        XCTAssertThrowsError(try URLSessionHarnessRPCTransport.decodeSuccess(
            data: data,
            expectedRPCID: "h00-rpc-0001"
        )) { error in
            guard let transport = error as? HarnessTransportError else {
                return XCTFail("应为 HarnessTransportError，实际 \(error)")
            }
            guard case .business(let remote) = transport else {
                return XCTFail("200 上的 ok=false 必须归为 business，实际 \(transport)")
            }
            XCTAssertEqual(remote.code, "gateway/arguments-invalid")
            // 字段名是 details 而不是 data。
            XCTAssertEqual(remote.details, .object([:]))
            XCTAssertFalse(transport.shouldReconnect, "业务失败重连多少次都是同一个结论")
        }
    }

    /// 正向对照：同一个解码入口对成功外壳必须真的返回 value。
    func testSuccessfulEnvelopeIsDecodedAsValue() throws {
        let envelope = try harnessObservation("rpc/envelope-errors.json", label: "response-success")
        let data = try JSONEncoder().encode(envelope)
        let value = try URLSessionHarnessRPCTransport.decodeSuccess(
            data: data,
            expectedRPCID: "h00-rpc-0001"
        )
        XCTAssertEqual(value, .object([:]))
    }

    // MARK: - 5. 非法 JSON

    /// 非法 JSON 是协议缺陷，不是链路故障：重连拿不到不同的结果。
    func testMalformedJSONIsNotReconnectable() {
        let data = Data("not json at all".utf8)
        XCTAssertThrowsError(try URLSessionHarnessRPCTransport.decodeSuccess(
            data: data,
            expectedRPCID: "ios-rpc-1"
        )) { error in
            guard case .malformedResponse = (error as? HarnessTransportError) else {
                return XCTFail("非法 JSON 必须归为 malformedResponse，实际 \(error)")
            }
            XCTAssertFalse((error as? HarnessTransportError)?.shouldReconnect ?? true)
        }
    }

    /// `ok=true` 却没有 value 同样是不合约，不能当成"空成功"。
    func testSuccessWithoutValueIsMalformed() {
        let data = Data(#"{"type":"server-response","rpcId":"ios-rpc-1","result":{"ok":true}}"#.utf8)
        XCTAssertThrowsError(try URLSessionHarnessRPCTransport.decodeSuccess(
            data: data,
            expectedRPCID: "ios-rpc-1"
        )) { error in
            guard case .malformedResponse = (error as? HarnessTransportError) else {
                return XCTFail("缺 value 必须归为 malformedResponse，实际 \(error)")
            }
        }
    }

    /// 正向对照：外壳 type 正确时才放行；type 不对必须拒绝。
    func testUnexpectedEnvelopeTypeIsMalformed() {
        let data = Data(#"{"type":"server-request","rpcId":"ios-rpc-1","result":{"ok":true,"value":{}}}"#.utf8)
        XCTAssertThrowsError(try URLSessionHarnessRPCTransport.decodeSuccess(
            data: data,
            expectedRPCID: "ios-rpc-1"
        ))
    }

    // MARK: - 6. 晚到响应

    /// 响应 rpcId 与在途请求不符：既不能当成功（张冠李戴），也不能当失败（掩盖真正在途的那条）。
    func testUnattributedResponseIsNeitherSuccessNorFailure() {
        let data = Data(#"{"type":"server-response","rpcId":"ios-rpc-99","result":{"ok":true,"value":{"a":1}}}"#.utf8)
        XCTAssertThrowsError(try URLSessionHarnessRPCTransport.decodeSuccess(
            data: data,
            expectedRPCID: "ios-rpc-1"
        )) { error in
            guard case .unattributedResponse(let rpcId) = (error as? HarnessTransportError) else {
                return XCTFail("rpcId 不符必须归为 unattributedResponse，实际 \(error)")
            }
            XCTAssertEqual(rpcId, "ios-rpc-99")
            XCTAssertFalse((error as? HarnessTransportError)?.shouldReconnect ?? true)
        }
    }

    // MARK: - 7. 状态码分类

    func testUnauthorizedIsReconnectable() {
        let mapped = URLSessionHarnessRPCTransport.mappedStatus(401, data: Data())
        XCTAssertEqual(mapped, .unauthorized(status: 401))
        XCTAssertTrue(mapped.shouldReconnect)
    }

    func testRelayPolicyRejectionIsNotReconnectable() {
        let mapped = URLSessionHarnessRPCTransport.mappedStatus(
            403,
            data: Data(#"{"error":"中继只开放只读方法"}"#.utf8)
        )
        // 403 在中继里既可能是凭据无效也可能是 origin/方法不允许，按状态码归类为凭据问题；
        // 文案仍然取自中继，便于诊断区分。
        XCTAssertEqual(mapped, .unauthorized(status: 403))
        XCTAssertEqual(URLSessionHarnessRPCTransport.errorMessage(
            from: Data(#"{"error":"中继只开放只读方法"}"#.utf8)
        ), "中继只开放只读方法")
    }

    func testBadRequestIsRejectedWithRelayMessage() {
        let mapped = URLSessionHarnessRPCTransport.mappedStatus(
            400,
            data: Data(#"{"error":"请求体不是合法 JSON"}"#.utf8)
        )
        XCTAssertEqual(mapped, .rejected(status: 400, message: "请求体不是合法 JSON"))
        XCTAssertFalse(mapped.shouldReconnect)
    }

    func testUpstreamUnavailableIsReconnectable() {
        let mapped = URLSessionHarnessRPCTransport.mappedStatus(503, data: Data())
        XCTAssertEqual(mapped, .server(status: 503, message: ""))
        XCTAssertTrue(mapped.shouldReconnect)
    }

    /// 分类的用途只有一件事：决定要不要重连。这条断言把"不能都变成 reconnect"钉住。
    func testOnlyLinkLevelFailuresAreReconnectable() {
        let reconnectable: [HarnessTransportError] = [
            .unauthorized(status: 401),
            .server(status: 502, message: ""),
            .notConnected,
            .closed,
            .timedOut,
            // 连续性丢失重开 follow 就能修：新 opening snapshot 提供新基线。
            .continuityLost("revision gap"),
        ]
        let surfaceOnly: [HarnessTransportError] = [
            .rejected(status: 400, message: ""),
            .malformedResponse("x"),
            .business(HarnessRemoteError(code: "gateway/internal", message: nil, details: nil)),
            .unattributedResponse(rpcId: "r"),
            .carrier(HarnessRemoteError(code: "gateway/internal", message: nil, details: nil)),
            .unsupportedInteraction("tool-consent/request"),
            .cancelled,
        ]
        for error in reconnectable {
            XCTAssertTrue(error.shouldReconnect, "\(error.diagnosticSummary) 应当可重连")
        }
        for error in surfaceOnly {
            XCTAssertFalse(error.shouldReconnect, "\(error.diagnosticSummary) 不应触发重连")
        }
    }

    /// 载体错误必须**逐码**分类，不能因为"装在 carrier 里"就一律判死。
    ///
    /// 中继在上游物理断流时先发 `gateway/service-unavailable` 错误帧、再关闭连接。
    /// 若一概不可重连，同一件事就会有两种结果：先消费到错误帧的停止恢复，
    /// 先观察到关闭的自动重连。这条断言把两个时序钉到同一个结论。
    func testCarrierErrorsClassifyByUpstreamSemanticsNotByEnvelope() {
        // 上游断流 / 订阅额度已满：等一会儿重开就能恢复。
        XCTAssertTrue(HarnessTransportError
            .carrier(HarnessRemoteError(code: "gateway/service-unavailable", message: nil, details: nil))
            .shouldReconnect)
        XCTAssertTrue(HarnessTransportError
            .carrier(HarnessRemoteError(code: "gateway/cancelled", message: nil, details: nil))
            .shouldReconnect)

        // 权限、协议、归属类失败：重连多少次都是同一结论，必须停下来告诉用户。
        for code in [
            "gateway/result-invalid",
            "gateway/internal",
            "gateway/arguments-invalid",
            "gateway/binding-invalid",
            "harness/rejected",
            "harness/interaction-settled",
            "session/agent-busy",
            "session/model-unavailable",
        ] {
            XCTAssertFalse(
                HarnessTransportError.carrier(
                    HarnessRemoteError(code: code, message: nil, details: nil)
                ).shouldReconnect,
                "\(code) 不应触发重连"
            )
        }

        // 白名单语义：认不出的码不重连。代价不对称——把不可恢复的当可恢复，
        // 会对着一次权限拒绝无限退避，把明确结论伪装成"网络不好"。
        XCTAssertFalse(HarnessTransportError
            .carrier(HarnessRemoteError(code: "gateway/brand-new-code", message: nil, details: nil))
            .shouldReconnect)
    }

    /// 断流写入提交状态时不能退化成"没执行、可重试"。
    ///
    /// `gateway/service-unavailable` 发生在一次写之后：那次写可能已经落到上游，
    /// 只是结论没回来。判成 `.rejected` 会诱导上层重发，让一次提交变成两次副作用。
    func testServiceUnavailableCarrierBecomesResponseUnknownNotRejected() async {
        let unknown = await HarnessSubmissionController.stateForFailure(
            HarnessTransportError.carrier(
                HarnessRemoteError(code: "gateway/service-unavailable", message: nil, details: nil)
            )
        )
        guard case .responseUnknown = unknown else {
            return XCTFail("上游断流必须归入结果未知，实际是 \(unknown)")
        }

        // 真正的业务拒绝仍是明确结论，可以重试。
        let rejected = await HarnessSubmissionController.stateForFailure(
            HarnessTransportError.carrier(
                HarnessRemoteError(code: "session/agent-busy", message: "busy", details: nil)
            )
        )
        guard case .rejected = rejected else {
            return XCTFail("业务码应当是可重试的明确拒绝，实际是 \(rejected)")
        }
    }

    // MARK: - 8. $events/result 三种 outcome

    /// 契约 §8 缺陷 3：旧注释断言 outcome 只有 `result` 一种。三种都要能表达。
    func testEventsResultFixtureCoversAllThreeOutcomeKinds() throws {
        let fixture = try harnessFixtureJSON("rpc/events-result.json")
        let cases = try XCTUnwrap(fixture["cases"] as? [String: Any])

        func outcome(_ name: String) throws -> HarnessJSONValue {
            let object = try XCTUnwrap(cases[name] as? [String: Any])
            let payload = try XCTUnwrap(object["payload"] as? [String: Any])
            let args = try XCTUnwrap(payload["args"] as? [String: Any])
            let data = try JSONSerialization.data(withJSONObject: try XCTUnwrap(args["outcome"]))
            return try JSONDecoder().decode(HarnessJSONValue.self, from: data)
        }

        XCTAssertEqual(try outcome("approvalRequest")["kind"], .string(HarnessWireOutcomeKind.result))
        XCTAssertEqual(try outcome("approvalRequest")["value"], .string("allowed-once"))
        XCTAssertEqual(try outcome("questionsAnswer")["kind"], .string(HarnessWireOutcomeKind.result))
        XCTAssertEqual(try outcome("outcomeNext")["kind"], .string(HarnessWireOutcomeKind.next))
        XCTAssertEqual(try outcome("outcomeRejected")["kind"], .string(HarnessWireOutcomeKind.rejected))

        // 本地构造的 wire 表示必须与夹具逐字一致（questionsAnswer 是结构化追问）。
        let answers = HarnessOutcome.result(.object([
            "answers": .array([
                .object([
                    "id": .string("question-fixture-0001"),
                    "selected": .array([.string("Option A")]),
                ]),
            ]),
        ]))
        XCTAssertEqual(answers.wireValue, try outcome("questionsAnswer"))

        XCTAssertEqual(HarnessOutcome.next.wireValue, try outcome("outcomeNext"))
    }

    /// 审批取值必须在契约枚举内。自由文本不得伪装成合法应答。
    func testApprovalDecisionRejectsValuesOutsideContract() {
        XCTAssertEqual(
            HarnessOutcome.approval(decision: "allowed-once")?.wireValue,
            .object(["kind": .string("result"), "value": .string("allowed-once")])
        )
        XCTAssertNil(HarnessOutcome.approval(decision: "allow"))
        XCTAssertNil(HarnessOutcome.approval(decision: "ALLOWED-ONCE"))
        XCTAssertNil(HarnessOutcome.approval(decision: ""))
    }

    /// 认不出的安全交互类型不得当普通请求处理。
    func testUnknownWaterfallEventIsUnsupported() {
        XCTAssertTrue(HarnessWireWaterfallEvent.isSupported("approval/request"))
        XCTAssertTrue(HarnessWireWaterfallEvent.isSupported("user-questions/request"))
        XCTAssertFalse(HarnessWireWaterfallEvent.isSupported("tool-consent/request"))
        XCTAssertFalse(HarnessWireWaterfallEvent.isSupported(""))
    }

    /// 归属必须来自协议保证的字段，取不到时不得回退到"唯一活跃会话"。
    func testWaterfallAttributionNeverFallsBackToASingleSession() {
        let empty = HarnessWaterfallRequest(
            type: nil, eventId: nil, event: nil, request: nil,
            agentId: nil, sessionId: nil, threadId: nil
        )
        XCTAssertEqual(empty.threadHint, "")

        let byAgent = HarnessWaterfallRequest(
            type: nil, eventId: nil, event: nil, request: nil,
            agentId: "h00-session-0001", sessionId: nil, threadId: nil
        )
        XCTAssertEqual(byAgent.threadHint, "h00-session-0001")
    }

    // MARK: - 9. 只连原生路径、只带手机凭据

    /// Spy：原生路径不请求旧 app-server / ws，也不带 Cookie。
    func testNativePathNeverRequestsLegacyRoutesOrCookies() async throws {
        HarnessRPCStubURLProtocol.reset()
        HarnessRPCStubURLProtocol.responder = { request in
            // 回显请求的 rpcId：中继本来就是这么做的，回一个固定值反而会触发
            // unattributedResponse，让这条用例测不到路径。
            (200, Self.echoingSuccessEnvelope(for: request))
        }
        let session = HarnessTransportSession.make(protocolClasses: [HarnessRPCStubURLProtocol.self])
        defer { session.invalidateAndCancel() }

        let transport = URLSessionHarnessRPCTransport(
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:8787")),
            token: "pairing-token-fixture",
            session: session
        )
        for method in [
            HarnessWireMethod.sessionList,
            HarnessWireMethod.sessionSearch,
            HarnessWireMethod.sessionPage,
            HarnessWireMethod.sessionModelCatalog,
        ] {
            _ = try await transport.call(HarnessRPCRequest(
                rpcId: "ios-rpc-1", method: method, args: nil, cwd: nil
            ))
        }

        let recorded = HarnessRPCStubURLProtocol.recordedRequests()
        XCTAssertEqual(recorded.count, 4)
        for request in recorded {
            let path = try XCTUnwrap(request.url?.path)
            XCTAssertEqual(path, HarnessTransportPath.rpc)
            XCTAssertFalse(path.contains("app-server"), "原生路径不得打到旧 app-server：\(path)")
            XCTAssertFalse(path.lowercased().contains("codex"), "原生路径不得打到 Codex：\(path)")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"), "不得携带 Cookie")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer pairing-token-fixture")
            XCTAssertEqual(request.httpMethod, "POST")
        }
    }

    /// 流通道的握手请求同样只打原生路径，且不带 Cookie。
    func testStreamConnectRequestTargetsNativePathOnly() throws {
        let transport = URLSessionHarnessStreamTransport(
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:8787")),
            token: "pairing-token-fixture"
        )
        let request = transport.makeConnectRequest()
        XCTAssertEqual(request.url?.path, HarnessTransportPath.stream)
        XCTAssertEqual(request.url?.path, "/api/harness/ws")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer pairing-token-fixture")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }

    /// 请求体字段必须恰好是 rpcId / method / args / cwd：中继用 `DisallowUnknownFields`，
    /// 多一个键整条被拒。
    func testRPCRequestBodyMatchesRelayContract() throws {
        let request = HarnessRPCRequest(
            rpcId: "ios-rpc-1",
            method: HarnessWireMethod.sessionList,
            args: .object(["_request": .object([:])]),
            cwd: "/h00/workspace"
        )
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ["rpcId", "method", "args", "cwd"])
        XCTAssertEqual(object["rpcId"] as? String, "ios-rpc-1")
        XCTAssertEqual(object["method"] as? String, "session/list")
        let args = try XCTUnwrap(object["args"] as? [String: Any])
        XCTAssertEqual(Set(args.keys), ["_request"], "session/list 的形参名是 _request")
    }

    /// 缺省参数不得被编码成 null（中继的 args 是 RawMessage，null 会绕过"零参数"判断）。
    func testRPCRequestOmitsAbsentOptionalFields() throws {
        let request = HarnessRPCRequest(
            rpcId: "ios-rpc-1",
            method: HarnessWireMethod.sessionModelCatalog,
            args: nil,
            cwd: nil
        )
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["rpcId", "method"])
    }

    // MARK: - 10. 重复关闭

    func testStreamTransportCloseIsIdempotent() async throws {
        let transport = URLSessionHarnessStreamTransport(
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:8787")),
            token: "t"
        )
        await transport.close()
        await transport.close()
        await transport.close()
        // 关闭后发送必须显式失败，而不是静默丢弃。
        do {
            try await transport.send(.cancel(streamID: "s1"))
            XCTFail("关闭后发送必须抛错")
        } catch let error as HarnessTransportError {
            XCTAssertEqual(error, .notConnected)
        }
    }

    func testRuntimeShutdownIsIdempotentAndClearsState() async throws {
        let stream = FakeHarnessStreamTransport()
        let runtime = HarnessSessionRuntime(
            configuration: makeConfiguration(),
            transports: HarnessSessionRuntime.TransportPair(rpc: FakeHarnessRPCTransport(), stream: stream)
        )
        try await runtime.openStream(streamID: "s1", endpoint: HarnessWireEndpoint.events)
        let openAfterOpen = await runtime.openStreamIDs()
        XCTAssertEqual(openAfterOpen, ["s1"])

        await runtime.shutdown()
        await runtime.shutdown()
        await runtime.shutdown()

        let openAfterShutdown = await runtime.openStreamIDs()
        XCTAssertEqual(openAfterShutdown, [])
        XCTAssertEqual(stream.closeCount, 3, "每次 shutdown 都会关一次；关键是替身与真实实现都必须能重复关")
        XCTAssertTrue(stream.isClosed)
    }

    // MARK: - 11. 半开

    /// 半开链路：`receive()` 永远挂着不返回，只有主动心跳才能发现。
    func testHalfOpenLinkIsDetectedByHeartbeat() async throws {
        let stream = FakeHarnessStreamTransport()
        stream.pingError = .timedOut
        let runtime = HarnessSessionRuntime(
            configuration: makeConfiguration(pingInterval: .milliseconds(20)),
            transports: HarnessSessionRuntime.TransportPair(rpc: FakeHarnessRPCTransport(), stream: stream)
        )
        let generation = try await runtime.connect()

        let detected = await waitUntil {
            await runtime.connectionGeneration > generation
        }
        XCTAssertTrue(detected, "心跳失败必须更替连接代次")
        let action = await runtime.recoveryAction
        XCTAssertEqual(action, .reconnect)
        XCTAssertTrue(stream.isClosed)
        let diagnostics = await runtime.diagnostics.map(\.summary)
        XCTAssertTrue(
            diagnostics.contains { $0.contains("timed-out") },
            "半开必须留下超时诊断，实际：\(diagnostics)"
        )
    }

    /// 正向对照：心跳正常时代次不得变动（否则每条安静但健康的连接都会被反复重连）。
    func testHealthyHeartbeatKeepsGenerationStable() async throws {
        let stream = FakeHarnessStreamTransport()
        let runtime = HarnessSessionRuntime(
            configuration: makeConfiguration(pingInterval: .milliseconds(20)),
            transports: HarnessSessionRuntime.TransportPair(rpc: FakeHarnessRPCTransport(), stream: stream)
        )
        let generation = try await runtime.connect()
        try await Task.sleep(for: .milliseconds(120))
        let current = await runtime.connectionGeneration
        XCTAssertEqual(current, generation)
        XCTAssertFalse(stream.isClosed)
    }

    // MARK: - 12. 慢消费者

    /// 缓冲必须有界：溢出丢最旧并**计数**，不能无限增长，也不能静默丢。
    func testSlowConsumerDropsOldestAndReports() async throws {
        let stream = FakeHarnessStreamTransport()
        let runtime = HarnessSessionRuntime(
            configuration: makeConfiguration(bufferCapacity: 4),
            transports: HarnessSessionRuntime.TransportPair(rpc: FakeHarnessRPCTransport(), stream: stream)
        )
        try await runtime.openStream(streamID: "s1", endpoint: HarnessWireEndpoint.events)

        for index in 0..<10 {
            stream.push(itemFrame(streamID: "s1", seq: index))
        }

        let reported = await waitUntil {
            await runtime.diagnostics.contains { diagnostic in
                if case .slowConsumer(let streamID, let dropped) = diagnostic {
                    return streamID == "s1" && dropped == 6
                }
                return false
            }
        }
        XCTAssertTrue(reported, "溢出必须留下 slowConsumer 诊断")

        var sequences: [Int] = []
        while let frame = await runtime.pollFrame(streamID: "s1") {
            sequences.append(frame.value?["seq"]?.intValue ?? -1)
        }
        XCTAssertEqual(sequences, [6, 7, 8, 9], "保留最新帧、丢最旧帧")
    }

    /// 正向对照：容量之内不得丢任何一帧。
    func testBufferWithinCapacityDropsNothing() async throws {
        let stream = FakeHarnessStreamTransport()
        let runtime = HarnessSessionRuntime(
            configuration: makeConfiguration(bufferCapacity: 8),
            transports: HarnessSessionRuntime.TransportPair(rpc: FakeHarnessRPCTransport(), stream: stream)
        )
        try await runtime.openStream(streamID: "s1", endpoint: HarnessWireEndpoint.events)
        for index in 0..<8 {
            stream.push(itemFrame(streamID: "s1", seq: index))
        }
        let filled = await waitUntil {
            await runtime.bufferedFrameCount(streamID: "s1") == 8
        }
        XCTAssertTrue(filled)
        let diagnostics = await runtime.diagnostics
        XCTAssertFalse(
            diagnostics.contains { if case .slowConsumer = $0 { return true } else { return false } },
            "容量之内不应报慢消费者"
        )
    }

    // MARK: - 13. 切 host

    func testHostSwitchStopsDeliveringFramesFromPreviousTransport() async throws {
        let oldStream = FakeHarnessStreamTransport()
        let newStream = FakeHarnessStreamTransport()
        let runtime = HarnessSessionRuntime(
            configuration: makeConfiguration(endpoint: "http://127.0.0.1:8787"),
            transports: HarnessSessionRuntime.TransportPair(rpc: FakeHarnessRPCTransport(), stream: oldStream)
        )
        try await runtime.openStream(streamID: "s1", endpoint: HarnessWireEndpoint.events)

        await runtime.switchHost(
            to: makeConfiguration(endpoint: "http://127.0.0.1:9999"),
            transports: HarnessSessionRuntime.TransportPair(rpc: FakeHarnessRPCTransport(), stream: newStream)
        )
        try await runtime.openStream(streamID: "s1", endpoint: HarnessWireEndpoint.events)

        XCTAssertEqual(oldStream.connectCount, 1)
        XCTAssertEqual(newStream.connectCount, 1)
        XCTAssertTrue(oldStream.isClosed, "切 host 必须关掉旧连接")

        oldStream.push(itemFrame(streamID: "s1", seq: 1))
        newStream.push(itemFrame(streamID: "s1", seq: 2))

        let delivered = await waitUntil {
            await runtime.bufferedFrameCount(streamID: "s1") > 0
        }
        XCTAssertTrue(delivered)
        let frame = await runtime.pollFrame(streamID: "s1")
        XCTAssertEqual(frame?.value?["seq"]?.intValue, 2, "只有新 host 的帧可以到达")
        let leftover = await runtime.pollFrame(streamID: "s1")
        XCTAssertNil(leftover, "旧 host 的帧不得混进来")
    }

    /// 已在途的旧帧在切 host 之后到达时，必须在分发口被代次拦下。
    ///
    /// 替身刻意不在 close 时唤醒等待者：真实场景就是"帧已经交到 URLSession，切 host 之后
    /// 才被投递上来"。少了代次校验，这帧会被当成新连接的会话内容。
    func testFrameArrivingAfterHostSwitchIsDiscardedByGeneration() async throws {
        let oldStream = FakeHarnessStreamTransport()
        oldStream.resumeWaitersOnClose = false
        let newStream = FakeHarnessStreamTransport()
        let runtime = HarnessSessionRuntime(
            configuration: makeConfiguration(),
            transports: HarnessSessionRuntime.TransportPair(rpc: FakeHarnessRPCTransport(), stream: oldStream)
        )
        try await runtime.openStream(streamID: "s1", endpoint: HarnessWireEndpoint.events)
        try await Task.sleep(for: .milliseconds(20))

        await runtime.switchHost(
            to: makeConfiguration(endpoint: "http://127.0.0.1:9999"),
            transports: HarnessSessionRuntime.TransportPair(rpc: FakeHarnessRPCTransport(), stream: newStream)
        )
        try await runtime.openStream(streamID: "s1", endpoint: HarnessWireEndpoint.events)

        // 旧连接上迟到的帧。
        oldStream.push(itemFrame(streamID: "s1", seq: 1))
        try await Task.sleep(for: .milliseconds(50))

        let stale = await runtime.diagnostics.contains { diagnostic in
            if case .staleFrame(let streamID) = diagnostic { return streamID == "s1" }
            if case .unattributableFrame = diagnostic { return true }
            return false
        }
        XCTAssertTrue(stale, "旧代次的帧必须被拦下并记录")
        let undelivered = await runtime.pollFrame(streamID: "s1")
        XCTAssertNil(undelivered)
    }

    // MARK: - 14. 未知安全交互

    /// 旧代次的 reader 在切 host **之后**才恢复时，不得拆掉新连接。
    ///
    /// 这条把 `testHostSwitchStopsDeliveringFramesFromPreviousTransport` 偶发的那个竞态
    /// 变成确定性用例：`switchHost` 先 `cancel()` reader 再 `close()` 旧传输，而 cancel
    /// 唤不醒阻塞在 `receive()` 上的续体——真正唤醒它的是 `close()`。所以旧 reader 完全可能
    /// 在新 host 的订阅已经建立之后才跑到 `receive()` 的返回点。它此时若无条件 teardown，
    /// 会把新代次的 `subscriptions` 一并清空：新 host 的帧再也进不来。
    ///
    /// 做法：先让旧传输的 close **不**唤醒等待者，等新连接建好、订阅就位之后，再手动唤醒
    /// 旧 reader。这就是那个时序窗口，只是不再靠负载去赌。
    func testStaleReaderWakingAfterHostSwitchDoesNotTearDownNewConnection() async throws {
        let oldStream = FakeHarnessStreamTransport()
        // 关旧传输时不唤醒 reader：把"唤醒"推迟到新连接建立之后，精确复现竞态窗口。
        oldStream.resumeWaitersOnClose = false
        let newStream = FakeHarnessStreamTransport()
        let runtime = HarnessSessionRuntime(
            configuration: makeConfiguration(),
            transports: HarnessSessionRuntime.TransportPair(rpc: FakeHarnessRPCTransport(), stream: oldStream)
        )
        try await runtime.openStream(streamID: "s1", endpoint: HarnessWireEndpoint.events)
        try await Task.sleep(for: .milliseconds(20))

        await runtime.switchHost(
            to: makeConfiguration(endpoint: "http://127.0.0.1:9999"),
            transports: HarnessSessionRuntime.TransportPair(rpc: FakeHarnessRPCTransport(), stream: newStream)
        )
        try await runtime.openStream(streamID: "s1", endpoint: HarnessWireEndpoint.events)
        // 订阅已就位（上面 openStream 未抛错即说明连接与订阅都建好了）。
        let streamsAfterOpen = await runtime.openStreamIDs()
        XCTAssertEqual(streamsAfterOpen, ["s1"])

        // 现在才唤醒旧 reader——它醒来时看到的 `nil` 属于**上一个**代次。
        oldStream.releasePendingWaiters()
        try await Task.sleep(for: .milliseconds(50))

        // 新连接必须仍然活着：订阅还在，且新 host 的帧能进来。
        let streamsAfterStaleWake = await runtime.openStreamIDs()
        XCTAssertEqual(
            streamsAfterStaleWake, ["s1"],
            "陈旧 reader 不得清掉新代次的订阅"
        )
        newStream.push(itemFrame(streamID: "s1", seq: 7))
        let delivered = await waitUntil {
            await runtime.bufferedFrameCount(streamID: "s1") > 0
        }
        XCTAssertTrue(delivered, "新 host 的帧必须仍能到达")
        let frame = await runtime.pollFrame(streamID: "s1")
        XCTAssertEqual(frame?.value?["seq"]?.intValue, 7)
    }

    /// 认不出的安全交互不得投递（UI 无法为它构造合法应答），但必须留下诊断。
    func testUnknownSafetyInteractionIsNotDeliveredButRecorded() async throws {
        let stream = FakeHarnessStreamTransport()
        let runtime = HarnessSessionRuntime(
            configuration: makeConfiguration(),
            transports: HarnessSessionRuntime.TransportPair(rpc: FakeHarnessRPCTransport(), stream: stream)
        )
        try await runtime.openStream(streamID: "s1", endpoint: HarnessWireEndpoint.events)

        stream.push(waterfallFrame(streamID: "s1", event: "tool-consent/request", eventID: "e1"))
        let recorded = await waitUntil {
            await runtime.diagnostics.contains {
                $0 == .unsupportedInteraction(streamID: "s1", event: "tool-consent/request")
            }
        }
        XCTAssertTrue(recorded, "未知安全交互必须记录")
        let undelivered = await runtime.pollFrame(streamID: "s1")
        XCTAssertNil(undelivered, "未知安全交互不得投递给 UI")
    }

    /// 正向对照：契约内的两条交互必须真的投递，否则"全都拒绝"也会让上面的测试通过。
    func testContractInteractionsAreDelivered() async throws {
        let stream = FakeHarnessStreamTransport()
        let runtime = HarnessSessionRuntime(
            configuration: makeConfiguration(),
            transports: HarnessSessionRuntime.TransportPair(rpc: FakeHarnessRPCTransport(), stream: stream)
        )
        try await runtime.openStream(streamID: "s1", endpoint: HarnessWireEndpoint.events)

        stream.push(waterfallFrame(streamID: "s1", event: "approval/request", eventID: "e1"))
        stream.push(waterfallFrame(streamID: "s1", event: "user-questions/request", eventID: "e2"))

        let delivered = await waitUntil {
            await runtime.bufferedFrameCount(streamID: "s1") == 2
        }
        XCTAssertTrue(delivered, "契约内的交互必须投递")
        let first = await runtime.pollFrame(streamID: "s1")
        XCTAssertEqual(first?.value?["eventId"], .string("e1"))
        XCTAssertEqual(first?.value?["agentId"], .string("h00-session-0001"))
    }

    // MARK: - 15. ready 与 clientId

    /// 中继已剔除 clientId。真的收到也要记诊断，且**绝不保存**。
    func testReadyFrameNeverStoresClientID() async throws {
        let stream = FakeHarnessStreamTransport()
        let runtime = HarnessSessionRuntime(
            configuration: makeConfiguration(),
            transports: HarnessSessionRuntime.TransportPair(rpc: FakeHarnessRPCTransport(), stream: stream)
        )
        let generation = try await runtime.connect()
        try await runtime.openStream(streamID: "s1", endpoint: HarnessWireEndpoint.events)

        stream.push(HarnessCarrierFrame(
            type: HarnessWireCarrier.item,
            streamId: "s1",
            value: .object([
                "type": .string(HarnessWireFrame.ready),
                "clientId": .string("h00-client-0001"),
                "host": .object(["home": .string("/h00/home")]),
            ]),
            error: nil
        ))

        let observed = await waitUntil { await runtime.readyGeneration != nil }
        XCTAssertTrue(observed)
        let readyGeneration = await runtime.readyGeneration
        XCTAssertEqual(readyGeneration, generation)
        let diagnostics = await runtime.diagnostics
        XCTAssertTrue(diagnostics.contains(.unexpectedClientID(streamID: "s1")))

        // host.home 不得出现在任何被投递的帧里。
        let frame = await runtime.pollFrame(streamID: "s1")
        XCTAssertEqual(frame?.value?["type"], .string("ready"))
    }

    /// 正向对照：中继剔除 clientId 后的 ready 形状（`{"type":"ready"}`）不得触发诊断。
    func testStrippedReadyFrameDoesNotTriggerDiagnostic() async throws {
        let stream = FakeHarnessStreamTransport()
        let runtime = HarnessSessionRuntime(
            configuration: makeConfiguration(),
            transports: HarnessSessionRuntime.TransportPair(rpc: FakeHarnessRPCTransport(), stream: stream)
        )
        _ = try await runtime.connect()
        try await runtime.openStream(streamID: "s1", endpoint: HarnessWireEndpoint.events)
        stream.push(HarnessCarrierFrame(
            type: HarnessWireCarrier.item,
            streamId: "s1",
            value: .object(["type": .string(HarnessWireFrame.ready)]),
            error: nil
        ))
        let observed = await waitUntil { await runtime.readyGeneration != nil }
        XCTAssertTrue(observed)
        let diagnostics = await runtime.diagnostics
        XCTAssertFalse(diagnostics.contains(.unexpectedClientID(streamID: "s1")))
    }

    // MARK: - 16. 在途请求与晚到响应（运行时视角）

    func testInFlightRPCIsObservableUntilItSettles() async throws {
        let rpc = FakeHarnessRPCTransport()
        let gate = RPCRegistryGate()
        rpc.handler = { _ in
            gate.wait()
            return .success(.object(["ok": .bool(true)]))
        }
        let runtime = HarnessSessionRuntime(
            configuration: makeConfiguration(),
            transports: HarnessSessionRuntime.TransportPair(rpc: rpc, stream: FakeHarnessStreamTransport())
        )
        let task = Task { try await runtime.call(method: HarnessWireMethod.sessionList) }

        let registered = await waitUntil { await runtime.inFlightRPCIDs.count == 1 }
        XCTAssertTrue(registered, "在途请求必须可观测")
        gate.open()

        let value = try await task.value
        XCTAssertEqual(value, .object(["ok": .bool(true)]))
        let cleared = await waitUntil { await runtime.inFlightRPCIDs.isEmpty }
        XCTAssertTrue(cleared, "请求结算后必须从在途表里摘掉")
    }

    /// 晚到响应：运行时必须如实记录，并把分类保持为不可重连。
    func testLateResponseIsRecordedAndNotReconnectable() async throws {
        let rpc = FakeHarnessRPCTransport()
        rpc.handler = { _ in
            .failure(.unattributedResponse(rpcId: "ios-rpc-99"))
        }
        let runtime = HarnessSessionRuntime(
            configuration: makeConfiguration(),
            transports: HarnessSessionRuntime.TransportPair(rpc: rpc, stream: FakeHarnessStreamTransport())
        )
        do {
            _ = try await runtime.call(method: HarnessWireMethod.sessionList)
            XCTFail("晚到响应不得被当成成功")
        } catch let error as HarnessTransportError {
            XCTAssertEqual(error, .unattributedResponse(rpcId: "ios-rpc-99"))
        }
        let diagnostics = await runtime.diagnostics
        XCTAssertTrue(diagnostics.contains(.unattributedResponse(rpcId: "ios-rpc-99")))
        let action = await runtime.recoveryAction
        XCTAssertEqual(action, .surfaceOnly)
        let inFlight = await runtime.inFlightRPCIDs
        XCTAssertTrue(inFlight.isEmpty)
    }

    // MARK: - 17. 应答不需要 clientId

    /// 应答只带 eventId 与 outcome：clientId 由中继持有，客户端连传的入口都没有。
    func testRespondFrameCarriesNoClientID() throws {
        let frame = HarnessClientFrame.respond(
            eventID: "evt-fixture-0001",
            outcome: try XCTUnwrap(HarnessOutcome.approval(decision: "allowed-once"))
        )
        XCTAssertEqual(Set(try XCTUnwrap(frame.wireValue.objectValue).keys), ["type", "eventId", "outcome"])
        XCTAssertEqual(frame.wireValue["type"], .string("respond"))
        XCTAssertEqual(frame.wireValue["eventId"], .string("evt-fixture-0001"))
        XCTAssertEqual(
            frame.wireValue["outcome"],
            .object(["kind": .string("result"), "value": .string("allowed-once")])
        )
    }

    /// 零参数订阅（$events / session/control）不得带 payload。
    func testZeroArgumentSubscriptionOmitsPayload() throws {
        let frame = HarnessClientFrame.open(
            streamID: "s1",
            endpoint: HarnessWireEndpoint.events,
            args: nil
        )
        XCTAssertNil(frame.wireValue["payload"])
        XCTAssertEqual(Set(try XCTUnwrap(frame.wireValue.objectValue).keys), ["type", "streamId", "endpoint"])
    }

    // MARK: - 18. 取消

    func testCancelStreamSendsCancelAndForgetsSubscription() async throws {
        let stream = FakeHarnessStreamTransport()
        let runtime = HarnessSessionRuntime(
            configuration: makeConfiguration(),
            transports: HarnessSessionRuntime.TransportPair(rpc: FakeHarnessRPCTransport(), stream: stream)
        )
        try await runtime.openStream(streamID: "s1", endpoint: HarnessWireEndpoint.events)
        await runtime.cancelStream(streamID: "s1")
        let remaining = await runtime.openStreamIDs()
        XCTAssertEqual(remaining, [])
        XCTAssertEqual(stream.sentFrames.count, 2)
        XCTAssertEqual(stream.sentFrames.last, .cancel(streamID: "s1"))
        // 退订一条不存在的订阅是空操作（客户端与中继对"谁先发现流已结束"本来就有竞态）。
        await runtime.cancelStream(streamID: "s1")
        XCTAssertEqual(stream.sentFrames.count, 2)
    }

    func testOpenStreamSendsFollowArgsVerbatim() async throws {
        let stream = FakeHarnessStreamTransport()
        let runtime = HarnessSessionRuntime(
            configuration: makeConfiguration(),
            transports: HarnessSessionRuntime.TransportPair(rpc: FakeHarnessRPCTransport(), stream: stream)
        )
        let target = HarnessFollowTarget(sessionID: "h00-session-0001", assistantStream: true, maxMessages: 200)
        try await runtime.openStream(
            streamID: "h00-rpc-0001",
            endpoint: HarnessWireEndpoint.sessionFollow,
            args: target.argsValue
        )
        XCTAssertEqual(stream.sentFrames, [
            .open(
                streamID: "h00-rpc-0001",
                endpoint: HarnessWireEndpoint.sessionFollow,
                args: target.argsValue
            ),
        ])
    }

    /// 重复 streamId 必须显式失败，而不是静默顶掉已有订阅。
    func testDuplicateStreamIDIsRejected() async throws {
        let runtime = HarnessSessionRuntime(
            configuration: makeConfiguration(),
            transports: HarnessSessionRuntime.TransportPair(
                rpc: FakeHarnessRPCTransport(),
                stream: FakeHarnessStreamTransport()
            )
        )
        try await runtime.openStream(streamID: "s1", endpoint: HarnessWireEndpoint.events)
        do {
            try await runtime.openStream(streamID: "s1", endpoint: HarnessWireEndpoint.events)
            XCTFail("重复 streamId 必须失败")
        } catch let error as HarnessTransportError {
            guard case .rejected = error else {
                return XCTFail("应为 rejected，实际 \(error)")
            }
        }
    }

    // MARK: - 19. 载体错误与结束

    /// 载体层错误必须投递给消费方：吞掉它，一次上游报错会伪装成一次静默超时。
    func testCarrierErrorIsDeliveredToConsumer() async throws {
        let stream = FakeHarnessStreamTransport()
        let runtime = HarnessSessionRuntime(
            configuration: makeConfiguration(),
            transports: HarnessSessionRuntime.TransportPair(rpc: FakeHarnessRPCTransport(), stream: stream)
        )
        try await runtime.openStream(streamID: "s1", endpoint: HarnessWireEndpoint.events)
        stream.push(HarnessCarrierFrame(
            type: HarnessWireCarrier.error,
            streamId: "s1",
            value: nil,
            error: HarnessRemoteError(code: "gateway/internal", message: "boom", details: nil)
        ))

        let delivered = await waitUntil { await runtime.bufferedFrameCount(streamID: "s1") == 1 }
        XCTAssertTrue(delivered)
        let frame = await runtime.pollFrame(streamID: "s1")
        XCTAssertEqual(frame?.type, HarnessWireCarrier.error)
        XCTAssertEqual(frame?.error?.code, "gateway/internal")
    }

    /// 服务端宣告 end 后不再接收新帧，但终止帧必须先交给消费者。
    ///
    /// 先删订阅会让 `pollFrame` 永远拿不到 end，持续 reader 只能把正常结束误判成静默挂起。
    func testCarrierEndIsConsumableBeforeSubscriptionIsRetired() async throws {
        let stream = FakeHarnessStreamTransport()
        let runtime = HarnessSessionRuntime(
            configuration: makeConfiguration(),
            transports: HarnessSessionRuntime.TransportPair(rpc: FakeHarnessRPCTransport(), stream: stream)
        )
        try await runtime.openStream(streamID: "s1", endpoint: HarnessWireEndpoint.events)
        stream.push(HarnessCarrierFrame(
            type: HarnessWireCarrier.end, streamId: "s1", value: nil, error: nil
        ))

        let ended = await waitUntil { await runtime.openStreamIDs().isEmpty }
        XCTAssertTrue(ended, "end 到达后订阅不应继续接收业务帧")
        let terminal = await runtime.pollFrame(streamID: "s1")
        XCTAssertEqual(terminal?.type, HarnessWireCarrier.end, "消费者必须能读到终止原因")
        let drained = await runtime.pollFrame(streamID: "s1")
        XCTAssertNil(drained)
    }

    // MARK: - 20. 替身不得掩盖真实链路

    /// 每个订阅一条上游连接：多开订阅必须真的多开连接，不能靠复用一条连接假装支持。
    func testEachSubscriptionOpensItsOwnUpstreamStream() async throws {
        let stream = FakeHarnessStreamTransport()
        let runtime = HarnessSessionRuntime(
            configuration: makeConfiguration(),
            transports: HarnessSessionRuntime.TransportPair(rpc: FakeHarnessRPCTransport(), stream: stream)
        )
        try await runtime.openStream(streamID: "s1", endpoint: HarnessWireEndpoint.events)
        try await runtime.openStream(streamID: "s2", endpoint: HarnessWireEndpoint.sessionControl)
        let openIDs = await runtime.openStreamIDs()
        XCTAssertEqual(openIDs, ["s1", "s2"])
        XCTAssertEqual(stream.sentFrames.count, 2)
        XCTAssertEqual(stream.connectCount, 1, "同一连接的多个订阅共用一条链路")
    }

    // MARK: - 工具

    /// 回显请求 rpcId 的成功外壳，与 H03 中继 `writeHarnessNativeResult` 的形状一致。
    static func echoingSuccessEnvelope(for request: URLRequest) -> Data {
        var rpcId = ""
        if let body = request.httpBody,
           let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            rpcId = object["rpcId"] as? String ?? ""
        }
        let payload = #"{"type":"server-response","rpcId":"\#(rpcId)","result":{"ok":true,"value":{}}}"#
        return Data(payload.utf8)
    }

    func makeConfiguration(
        endpoint: String = "http://127.0.0.1:8787",
        bufferCapacity: Int = 256,
        pingInterval: Duration = .seconds(30)
    ) -> HarnessSessionRuntime.Configuration {
        HarnessSessionRuntime.Configuration(
            endpoint: endpoint,
            token: "pairing-token-fixture",
            bufferCapacity: bufferCapacity,
            pingInterval: pingInterval
        )
    }

    func itemFrame(streamID: String, seq: Int) -> HarnessCarrierFrame {
        HarnessCarrierFrame(
            type: HarnessWireCarrier.item,
            streamId: streamID,
            value: .object([
                "type": .string(HarnessWireFrame.durableEvent),
                "seq": .number(Double(seq)),
                "event": .object([
                    "type": .string("turn/start"),
                    "seq": .number(Double(seq)),
                ]),
            ]),
            error: nil
        )
    }

    func waterfallFrame(streamID: String, event: String, eventID: String) -> HarnessCarrierFrame {
        HarnessCarrierFrame(
            type: HarnessWireCarrier.item,
            streamId: streamID,
            value: .object([
                "type": .string(HarnessWireFrame.waterfall),
                "eventId": .string(eventID),
                "event": .string(event),
                "agentId": .string("h00-session-0001"),
                "request": .object(["toolName": .string("shell")]),
            ]),
            error: nil
        )
    }

    /// 轮询等待条件成立。
    func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: @escaping () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await condition()
    }
}

// MARK: - 替身

/// 内存流替身。不产生任何网络访问。
final class FakeHarnessStreamTransport: HarnessStreamTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [HarnessCarrierFrame] = []
    private var waiters: [CheckedContinuation<HarnessCarrierFrame?, Error>] = []
    private var _sentFrames: [HarnessClientFrame] = []
    private var _connectCount = 0
    private var _closeCount = 0
    private var _closed = false
    private var _pingError: HarnessTransportError?
    private var _sendError: HarnessTransportError?

    /// close 时是否唤醒挂起的 reader。
    ///
    /// 默认唤醒（真实实现里关连接会让 `receive` 立刻返回）。设为 false 用于模拟
    /// "帧已经交到 URLSession，切 host 之后才被投递上来"这个竞态。
    var resumeWaitersOnClose = true

    var pingError: HarnessTransportError? {
        get { lock.lock(); defer { lock.unlock() }; return _pingError }
        set { lock.lock(); _pingError = newValue; lock.unlock() }
    }

    var sendError: HarnessTransportError? {
        get { lock.lock(); defer { lock.unlock() }; return _sendError }
        set { lock.lock(); _sendError = newValue; lock.unlock() }
    }

    var connectCount: Int { lock.lock(); defer { lock.unlock() }; return _connectCount }
    var closeCount: Int { lock.lock(); defer { lock.unlock() }; return _closeCount }
    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return _closed }
    var sentFrames: [HarnessClientFrame] { lock.lock(); defer { lock.unlock() }; return _sentFrames }

    func connect() async throws {
        lock.lock(); _connectCount += 1; lock.unlock()
    }

    func send(_ frame: HarnessClientFrame) async throws {
        lock.lock()
        _sentFrames.append(frame)
        let error = _sendError
        lock.unlock()
        if let error { throw error }
    }

    func receive() async throws -> HarnessCarrierFrame? {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !pending.isEmpty {
                let frame = pending.removeFirst()
                lock.unlock()
                continuation.resume(returning: frame)
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func ping() async throws {
        if let pingError { throw pingError }
    }

    func close() async {
        lock.lock()
        _closeCount += 1
        _closed = true
        let parked = resumeWaitersOnClose ? waiters : []
        if resumeWaitersOnClose { waiters.removeAll() }
        lock.unlock()
        for waiter in parked { waiter.resume(returning: nil) }
    }

    /// 手动唤醒仍在挂起的 reader（返回 nil，表示流已结束）。
    ///
    /// 配合 `resumeWaitersOnClose = false` 使用：把"旧 reader 何时恢复"从 close 时刻
    /// 推迟到测试指定的时刻，从而确定性复现"陈旧 reader 在新连接建立后才醒"的窗口。
    func releasePendingWaiters() {
        lock.lock()
        let parked = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in parked { waiter.resume(returning: nil) }
    }

    func push(_ frame: HarnessCarrierFrame) {
        lock.lock()
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            lock.unlock()
            waiter.resume(returning: frame)
            return
        }
        pending.append(frame)
        lock.unlock()
    }
}

/// 内存 RPC 替身。
final class FakeHarnessRPCTransport: HarnessRPCTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [HarnessRPCRequest] = []
    var handler: ((HarnessRPCRequest) -> Result<HarnessJSONValue, HarnessTransportError>)?

    var requests: [HarnessRPCRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

    func call(_ request: HarnessRPCRequest) async throws -> HarnessJSONValue {
        lock.lock()
        _requests.append(request)
        let handler = self.handler
        lock.unlock()
        guard let handler else {
            throw HarnessTransportError.notConnected
        }
        return try handler(request).get()
    }
}

/// 让测试把一次在途请求卡住的闸门。
final class RPCRegistryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false

    func open() {
        lock.lock()
        opened = true
        lock.unlock()
    }

    func wait() {
        while true {
            lock.lock()
            let ready = opened
            lock.unlock()
            if ready { return }
            Thread.sleep(forTimeInterval: 0.002)
        }
    }
}

// MARK: - URLProtocol 替身

/// 记录每一次请求并返回可编排响应。不产生真实网络访问，也不需要真实凭据。
final class HarnessRPCStubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _requests: [URLRequest] = []
    private static var _responder: ((URLRequest) -> (Int, Data))?

    static var responder: ((URLRequest) -> (Int, Data))? {
        get { lock.lock(); defer { lock.unlock() }; return _responder }
        set { lock.lock(); _responder = newValue; lock.unlock() }
    }

    static func reset() {
        lock.lock()
        _requests = []
        _responder = nil
        lock.unlock()
    }

    static func recordedRequests() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }; return _requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            captured.httpBody = Self.readAll(from: stream)
        }
        Self.lock.lock()
        Self._requests.append(captured)
        let responder = Self._responder
        Self.lock.unlock()

        let (status, body) = responder?(captured) ?? (500, Data(#"{"error":"no responder"}"#.utf8))
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func readAll(from stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4 * 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
