import Foundation

/// `turn/end` 的 `data.reason` 映射成共用轮次终态（#809、#861）。
///
/// 实测原因见契约 `recovery.turnEndReasonsObserved`：`completed`、`aborted`、`error`。
/// 0.2.1-alpha.1 源码另有四种，语义按源码确定：
/// - `max-tokens`：单次输出触到 token 上限，回复被截断；
/// - `blocked`：轮次前置检查拒绝继续；
/// - `interrupted`：旧格式迁移时给没收尾的轮次补写的结束；
/// - `forked`：分叉种子给继承来的未完成轮次补写的结束。
///
/// 与 Codex/Claude 对齐：用户或宿主取消、补写的收尾都按"已中断"，因为这一轮确实没跑完，
/// 但也不是出错。真正没完成的结束（出错、截断、被拒、认不出的原因）按"失败"处理，并带上
/// 可展示的原因。agentd 推送侧（`harness_turn_push.go`）对非 completed、非 aborted 的原因
/// 同样推失败提醒。
enum HarnessTurnEndReason {
    struct Settlement: Equatable {
        let lifecycle: ConversationTurnLifecycle
        let error: AgentErrorPayload?
    }

    /// 返回 nil 表示正常完成（含缺少 reason 的旧记录），沿用 reducer 的完成路径。
    static func settlement(for event: HarnessDurableEvent) -> Settlement? {
        let reason = event.data?["reason"]
        let kind = reason?["kind"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch kind {
        case "", "completed":
            return nil
        case "aborted", "interrupted", "forked":
            return Settlement(lifecycle: .interrupted, error: nil)
        case "error":
            return Settlement(lifecycle: .failed, error: errorPayload(from: reason?["error"]))
        case "max-tokens":
            return failed(L10n.text("harness.turn_failed_max_tokens"), code: "MAX_TOKENS")
        case "blocked":
            return failed(L10n.text("harness.turn_failed_blocked"), code: "BLOCKED")
        default:
            let label = String(kind.prefix(maxCodeLength))
            return failed(L10n.format("harness.turn_failed_unknown", label), code: label)
        }
    }

    /// 失败卡片的身份。与 `EventReducer` 给失败 completion 生成的错误卡同一规则，
    /// 重开会话时历史页那张原位覆盖实时那张，不会多出第二张。
    static func failureMessageID(turnID: TurnID) -> MessageID {
        "runtime-error:\(turnID)"
    }

    /// 上游 `error.message` 在 code 为 UNKNOWN 时是整条错误链，可能夹带本机路径或请求里的
    /// 凭据片段。展示前抹掉这些并截到有限长度；code 是稳定的机器码，原样保留。
    static func sanitizedMessage(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for (pattern, template) in redactions {
            text = text.replacingOccurrences(
                of: pattern, with: template, options: [.regularExpression, .caseInsensitive]
            )
        }
        guard text.count > maxMessageLength else { return text }
        return String(text.prefix(maxMessageLength)) + "…"
    }

    private static let maxMessageLength = 500
    private static let maxCodeLength = 64

    private static let redactions: [(String, String)] = [
        (#"(/Users|/home)/[^/\s"']+"#, "~"),
        // 认证头的值是「方案 + 凭据」（Basic、Digest 还会带多段参数），只抹第一个词会留下
        // 编码后的凭据，所以抹到行尾。
        (#"\b((?:proxy-)?authorization)(["']?\s*[:=]\s*)[^\r\n]*"#, "$1$2<redacted>"),
        (#"\bBearer\s+[^\s"',;]+"#, "Bearer <redacted>"),
        (#"\bsk-[A-Za-z0-9_-]{8,}"#, "<redacted>"),
        (
            #"\b(api[_-]?key|access[_-]?token|refresh[_-]?token|token|secret|password)(["']?\s*[:=]\s*["']?)[^\s"'&,;]+"#,
            "$1$2<redacted>"
        ),
    ]

    private static func errorPayload(from error: HarnessJSONValue?) -> AgentErrorPayload {
        let code = error?["code"]?.stringValue?.trimmedNonEmpty.map { String($0.prefix(maxCodeLength)) }
        let message = sanitizedMessage(error?["message"]?.stringValue ?? "")
        return AgentErrorPayload(
            // 没有正文时退回机器码，再退回通用文案；失败卡片不能是空的。
            message: message.isEmpty ? (code ?? L10n.text("ui.error_run_failed")) : message,
            code: code,
            retryable: error?["retryable"]?.boolValue
        )
    }

    private static func failed(_ message: String, code: String) -> Settlement {
        Settlement(lifecycle: .failed, error: AgentErrorPayload(message: message, code: code, retryable: nil))
    }
}
