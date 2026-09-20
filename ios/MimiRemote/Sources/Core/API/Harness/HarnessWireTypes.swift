import Foundation

/// 原生 Harness wire 类型（H04）。
///
/// 形状全部取自 H00 冻结契约（`contracts/harness-native/manifest.json` 与
/// `fixtures/*`），与 agentd 侧 `internal/harnessclient` 的同名类型一一对应。
/// Go 与 Swift 读**同一份**夹具，所以两边不会各自漂移出一套"自洽"的协议。
///
/// 纪律：
/// - 业务数据只解到这里定义的 DTO，**不经过** Codex JSON-RPC DTO。
/// - 载体层判别式（`item`/`error`/`end`）与 value 内层判别式
///   （`ready`/`snapshot`/`waterfall`/…）是**两层**，必须分开处理。把两层混为
///   一谈正是契约 §8 缺陷 2 的成因：`error`/`end` 帧根本没有 value，一旦按
///   "解不出 value 就当空帧"处理，一次上游报错就会伪装成一次静默超时。
/// - 解不出来必须显式失败，不用默认值补齐、不丢弃未知字段的诊断信息。

// MARK: - 常量

/// Connection RPC 方法名。只登记 #498 首版声明给移动端的子集。
enum HarnessWireMethod {
    static let sessionList = "session/list"
    static let sessionSearch = "session/search"
    static let sessionPage = "session/page"
    static let sessionModelCatalog = "session/modelCatalog"
    static let sessionFollow = "session/follow"
    static let sessionCreate = "session/create"
    static let sessionSelectModel = "session/selectModel"
    static let sessionPrompt = "session/prompt"
    static let sessionCancel = "session/cancel"
}

/// remote.mux 上开放的 stream endpoint。
enum HarnessWireEndpoint {
    static let events = "$events"
    static let eventsResult = "$events/result"
    static let sessionFollow = "session/follow"
    static let sessionControl = "session/control"
}

/// value 内层判别式。
enum HarnessWireFrame {
    static let ready = "ready"
    static let snapshot = "snapshot"
    static let waterfall = "waterfall"
    static let cancel = "cancel"
    static let assistantStream = "assistant-stream"
    static let durableEvent = "event"
}

/// 载体层判别式：服务端**每帧**都在顶层带 type，取值只有这三个。
enum HarnessWireCarrier {
    static let item = "item"
    static let error = "error"
    static let end = "end"
}

/// 载体层结果在本地判别式上的表示。刻意与 wire 字面量不同：万一将来服务端
/// 真的发出内层 type 为 "error" 的 value，两者不会互相冒充。
enum HarnessWireCarrierOutcome {
    static let error = "carrier-error"
    static let end = "carrier-end"
}

/// Harness 只经这两条 waterfall 向客户端发起交互。
enum HarnessWireWaterfallEvent {
    static let approvalRequest = "approval/request"
    static let userQuestions = "user-questions/request"

    /// 认不出的交互类型不得当普通请求处理：移动端无法为它构造合法应答。
    static func isSupported(_ event: String) -> Bool {
        event == approvalRequest || event == userQuestions
    }
}

/// `$events/result` 的 outcome 判别式。三种都要支持——契约 §8 缺陷 3 正是
/// 旧实现断言"只有 result 一种"。
enum HarnessWireOutcomeKind {
    static let next = "next"
    static let result = "result"
    static let rejected = "rejected"
}

/// 审批应答取值，对齐 Harness 的 result outcome。
enum HarnessWireApprovalDecision {
    static let allowedOnce = "allowed-once"
    static let rejected = "rejected"
    static let cancelled = "cancelled"
    static let unavailable = "unavailable"

    static let all: Set<String> = [allowedOnce, rejected, cancelled, unavailable]
}

// MARK: - 通用 JSON 容器

/// 原生 wire 上的通用 JSON 值。
///
/// 刻意不复用 Codex 的 JSON 容器：Harness 的业务数据不应借道 Codex 的类型体系，
/// 否则"没有经过 Codex DTO"就只剩口头承诺。未知字段靠它原样保留，便于诊断。
indirect enum HarnessJSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([HarnessJSONValue])
    case object([String: HarnessJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([HarnessJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: HarnessJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "原生 wire 上出现无法表示的 JSON 值"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    subscript(key: String) -> HarnessJSONValue? {
        guard case .object(let values) = self else { return nil }
        return values[key]
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        guard case .number(let value) = self else { return nil }
        return Int(value)
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var objectValue: [String: HarnessJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [HarnessJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }
}

// MARK: - Connection RPC 外壳

/// Harness 侧返回的业务错误。第三个字段的 wire 名是 `details`，**不是** `data`
/// ——这是实跑核对过的事实，按 `data` 解会静默丢掉整项。
struct HarnessRemoteError: Decodable, Equatable {
    let code: String?
    let message: String?
    let details: HarnessJSONValue?

    /// 诊断用的一行描述。没有 code 时不留空串，明确说明缺失。
    var diagnosticCode: String {
        let trimmed = code?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "harness/unknown" : trimmed
    }
}

/// `result` 外壳。业务结果一律在这里，**必须**检查 `ok`：HTTP 200 也可能是失败。
struct HarnessResultEnvelope: Decodable {
    let ok: Bool
    let value: HarnessJSONValue?
    let error: HarnessRemoteError?
}

/// Connection RPC 的响应外壳。
struct HarnessServerResponse: Decodable {
    let type: String?
    let rpcId: String?
    let result: HarnessResultEnvelope?
}

// MARK: - remote.mux 载体帧

/// 载体帧。三个键都是**载体层**字段：`type` 是服务端的判别值，`streamId` 把帧
/// 归到对应订阅，`item` 的 `value` 结构由 `value.type` 决定。
struct HarnessCarrierFrame: Decodable {
    let type: String?
    let streamId: String?
    let value: HarnessJSONValue?
    let error: HarnessRemoteError?
}

/// 一帧解码后的判别结果。
enum HarnessStreamFrame: Equatable {
    /// 业务帧：内层判别式在 `value.type`（durable event 另见 `eventType`）。
    case value(HarnessStreamValue)
    /// 载体层错误：真实原因在 error 里，**不能**降级成"没有帧"。
    case carrierError(HarnessRemoteError)
    /// 服务端宣告这条订阅结束。
    case carrierEnd
}

/// 业务帧的判别结果。`raw` 原样保留，供上层按类型解码。
struct HarnessStreamValue: Equatable {
    let type: String
    /// 仅当 `type == "event"` 时给出 durable event 类型（如 `turn/start`）。
    let eventType: String?
    let raw: HarnessJSONValue

    var isDurableEvent: Bool { type == HarnessWireFrame.durableEvent }
}

/// 把一帧载体 JSON 解成判别结果。
///
/// `nil` 表示**该帧无法归属**（没有 streamId，或载体 type 认不出）：调用方必须
/// 显式失败或记录，不能当成空帧吞掉。
enum HarnessCarrierDecoder {
    static func decode(frame: HarnessCarrierFrame) throws -> (streamID: String, frame: HarnessStreamFrame)? {
        guard let streamID = frame.streamId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !streamID.isEmpty else {
            return nil
        }
        switch frame.type {
        case .some(HarnessWireCarrier.error):
            // 服务端声明了 error 却没带 error 对象：不能当成成功，也不能当成空错误。
            return (streamID, .carrierError(frame.error ?? HarnessRemoteError(
                code: "gateway/internal",
                message: "载体错误帧缺少 error 对象",
                details: nil
            )))
        case .some(HarnessWireCarrier.end):
            return (streamID, .carrierEnd)
        case .some(let other) where !other.isEmpty && other != HarnessWireCarrier.item:
            // 载体 type 认不出：不能猜，交给调用方显式失败或记录。
            return nil
        default:
            // item，或 type 缺失/空。`value` 缺失说明形状不符，同样不能猜。
            guard let value = frame.value else {
                return nil
            }
            let type = value["type"]?.stringValue ?? ""
            let eventType = value["event"]?["type"]?.stringValue
            return (streamID, .value(HarnessStreamValue(
                type: type.isEmpty && eventType != nil ? HarnessWireFrame.durableEvent : type,
                eventType: eventType,
                raw: value
            )))
        }
    }
}

// MARK: - follow：snapshot

struct HarnessSnapshotHeader: Decodable, Equatable {
    let version: Int?
    /// 会话标识。**必须**与订阅目标一致——上游返回别人的快照就是越权。
    let id: String?
    let createdAt: Double?
    let cwd: String?
    let isSeeded: Bool?
    let agentPreset: String?
}

/// 持久日志里的一条记录。只解出信封，`data` 保持原样。
struct HarnessSnapshotRecord: Decodable, Equatable {
    let type: String?
    let event: HarnessDurableEvent?
}

/// durable event 信封。`seq` 是持久日志序号，去重与分页都靠它。
struct HarnessDurableEvent: Decodable, Equatable {
    let type: String?
    let seq: Int?
    let time: Double?
    let data: HarnessJSONValue?
}

/// follow 打开帧。首帧**必须**是 snapshot，且 header.id 必须与订阅目标一致。
struct HarnessSnapshot: Decodable, Equatable {
    let type: String?
    let header: HarnessSnapshotHeader?
    /// 本次快照的**闭区间**日志切点，也是 `session/page` 唯一合法的 `throughSeq`。
    let cursor: Int?
    let records: [HarnessSnapshotRecord]?
    let hasMore: Bool?
    let projections: HarnessJSONValue?
    let assistantStream: HarnessAssistantStreamBaseline?
}

/// snapshot 里的直播基线。缺了它而客户端又 opt-in 了 assistantStream，
/// 上游会报 `gateway/internal`。
struct HarnessAssistantStreamBaseline: Decodable, Equatable {
    let revision: Int?
    let activeAttempt: HarnessActiveAttempt?
}

struct HarnessActiveAttempt: Decodable, Equatable {
    let attemptId: String?
    let startedAfterSeq: Int?
    let turn: Int?
    let step: Int?
    let nextIndex: Int?
    let stream: String?
}

// MARK: - follow：assistant-stream 直播片段

/// 直播 chunk 的判别式词表（wire 上**只**会出现这些；带 `_chunks` 的是持久压缩
/// 记录的名字，wire 上永远看不到）。
enum HarnessWireChunkType {
    static let blockStart = "block-start"
    static let textDelta = "text-delta"
    static let reasoningDelta = "reasoning-delta"
    static let toolCallDelta = "tool-call-delta"
    static let blockEnd = "block-end"
    static let usage = "usage"
    static let finish = "finish"

    static let all: Set<String> = [
        blockStart, textDelta, reasoningDelta, toolCallDelta, blockEnd, usage, finish,
    ]
}

/// assistant-stream 帧型。实测只有这三种（`stream/assistant-stream.json`）。
enum HarnessWireAssistantFrame {
    static let start = "start"
    static let chunk = "chunk"
    static let end = "end"
}

/// durable settlement 的 `outcome.eventType` 取值。
///
/// **这是区分"正常结算"与"用户取消"的唯一依据。** `outcome.kind` 两者都是
/// `committed`（实测 `run.aborted-by-user` 的 end 帧），拿 kind 判断会把被取消的
/// 输出当成一条完整正文。
enum HarnessWireSettlement {
    /// 正常结算的助手消息。
    static let assistantMessage = "assistant/message"
    /// 用户取消：持久日志里记的是 attempt，不是 message。
    static let assistantAttempt = "assistant/attempt"
}

/// assistant-stream 帧。
///
/// `revision` 连续递增（expected = previous + 1，start 为 1）：**跳号必须重开
/// follow**，不能把断档静默接上。
struct HarnessAssistantStreamFrame: Decodable, Equatable {
    let type: String?
    let revision: Int?
    let index: Int?
    let chunk: HarnessAssistantChunk?
    /// 收尾结算。注意 `kind == "committed"` **不**代表有完整正文：用户取消的
    /// 回合同样是 committed，只能靠 `eventType` 区分。
    let outcome: HarnessAssistantStreamOutcome?
    /// attempt 身份。契约 §2.7：`start` 帧带 `startedAfterSeq`/`turn`/`step`，
    /// 且三态帧都带 `attemptId`（实测 `h00-attempt-0001`）。
    ///
    /// H04 首版只解了 revision/index/chunk/outcome，漏了这四个——而它们正是
    /// "不能仅用 (turn, step) 认领同一条消息"这条规则的执行依据：重试可以发生在
    /// 同一步，认领必须以 attemptId 为准。
    let attemptId: String?
    let turn: Int?
    let step: Int?
    let startedAfterSeq: Int?
}

struct HarnessAssistantChunk: Decodable, Equatable {
    let type: String?
    let index: Int?
    let text: String?
    let blockType: String?
    let argumentsDelta: String?
}

struct HarnessAssistantStreamOutcome: Decodable, Equatable {
    let kind: String?
    let eventType: String?
    let seq: Int?
}

// MARK: - $events：waterfall

/// 需要客户端应答的交互请求。审批与用户追问共用这一层信封。
struct HarnessWaterfallRequest: Decodable, Equatable {
    let type: String?
    let eventId: String?
    let event: String?
    let request: HarnessWaterfallPayload?
    /// agentId 是协议保证存在的字段，且**等于会话 id**（Harness 的身份设计是
    /// "agent 的注册表 id 等于其会话 id"）。归属因此是核事实，不是推断。
    let agentId: String?
    let sessionId: String?
    let threadId: String?

    /// 能确认的会话标识，取不到时为空串。**不得**回退到"唯一活跃会话"。
    var threadHint: String {
        for candidate in [agentId, threadId, sessionId] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }
}

struct HarnessWaterfallPayload: Decodable, Equatable {
    let toolName: String?
    let callId: String?
    let reason: String?
    let questions: [HarnessQuestion]?
}

/// 结构化追问。答案必须按 id 回填，不能把自然语言伪装成答案。
struct HarnessQuestion: Decodable, Equatable {
    let id: String?
    let question: String?
    let options: [HarnessQuestionOption]?
}

struct HarnessQuestionOption: Decodable, Equatable {
    let id: String?
    let label: String?
}

// MARK: - $events/result

/// 应答的 outcome。三种 kind 都要能表达——只支持 result 会让 `next`/`rejected`
/// 被静默改写。
enum HarnessOutcome: Equatable {
    /// 链路确认：只带 kind，不带值。
    case next
    /// 真实结果。审批用字符串取值，追问用 `{answers:[{id,selected}]}`。
    case result(HarnessJSONValue)
    /// 显式拒绝，必须带结构化 error。
    case rejected(HarnessRemoteError)

    var kind: String {
        switch self {
        case .next: return HarnessWireOutcomeKind.next
        case .result: return HarnessWireOutcomeKind.result
        case .rejected: return HarnessWireOutcomeKind.rejected
        }
    }

    /// wire 表示。**逐字**转发，不在中继里改写形状。
    var wireValue: HarnessJSONValue {
        switch self {
        case .next:
            return .object(["kind": .string(HarnessWireOutcomeKind.next)])
        case .result(let value):
            return .object(["kind": .string(HarnessWireOutcomeKind.result), "value": value])
        case .rejected(let error):
            var payload: [String: HarnessJSONValue] = ["kind": .string(HarnessWireOutcomeKind.rejected)]
            var object: [String: HarnessJSONValue] = [:]
            if let code = error.code { object["code"] = .string(code) }
            if let message = error.message { object["message"] = .string(message) }
            if let details = error.details { object["details"] = details }
            payload["error"] = .object(object)
            return .object(payload)
        }
    }

    /// 审批应答的取值必须是契约枚举之一。伪造的自由文本不允许通过。
    static func approval(decision: String) -> HarnessOutcome? {
        guard HarnessWireApprovalDecision.all.contains(decision) else { return nil }
        return .result(.string(decision))
    }
}
