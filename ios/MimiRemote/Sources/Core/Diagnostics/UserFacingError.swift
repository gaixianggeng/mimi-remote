import Foundation

/// 用户可见错误的分类。
///
/// 主界面只按分类回答「发生了什么、接下来能做什么」；HTTP 状态码、JSON-RPC 错误码、
/// WebSocket / app-server 术语和解码细节一律留在 `UserFacingError.technicalDetail`，
/// 供「详情」展开、复制和诊断使用，不再直接铺到聊天主界面（#508）。
enum UserFacingErrorCategory: String, Equatable, Sendable {
    /// 本机没有网络。
    case offline
    /// 有网络但连不上电脑（找不到主机、拒绝连接、安全连接失败等）。
    case hostUnreachable
    /// 曾经连上，但当前链路已经断开。
    case connectionLost
    /// 链路断开且已经在自动重连：这是进行中的状态，不是需要用户处理的错误。
    case reconnecting
    case timedOut
    case authenticationExpired
    case permissionDenied
    /// 电脑端版本过旧或当前通道不支持这项操作。
    case unsupported
    case rateLimited
    /// 电脑上的服务内部出错或暂时不可用。
    case hostError
    /// 电脑明确拒绝了这次请求（参数、冲突、策略等）。
    case rejected
    /// 电脑返回的数据无法解析。
    case invalidResponse
    /// 请求可能已经执行，客户端无法确认结果。
    case outcomeUnknown
    case unknown
    /// 原文本身就是可读的业务说明，不含协议细节，原样展示。
    case described
}

struct UserFacingError: Equatable, Sendable {
    let category: UserFacingErrorCategory
    /// 已本地化、可以直接展示的一句话说明。
    let message: String
    /// 原始技术描述。nil 表示 `message` 已经是全部信息，没有可展开的详情。
    let technicalDetail: String?

    init(category: UserFacingErrorCategory, message: String, technicalDetail: String? = nil) {
        self.category = category
        self.message = message
        let detail = technicalDetail?.trimmingCharacters(in: .whitespacesAndNewlines)
        // 详情与正文相同就没有展开的意义，避免出现一个点开后什么都没多的「详情」。
        self.technicalDetail = (detail?.isEmpty ?? true) || detail == message ? nil : detail
    }

    /// 已经是用户文案的说明（例如 App 自己写的本地化提示）。
    static func described(_ message: String) -> UserFacingError {
        UserFacingError(category: .described, message: message)
    }

    /// 进行中的状态（例如自动重连）应使用中性样式，不能再冠以「错误」。
    var isInProgress: Bool {
        category == .reconnecting
    }

    /// 是否值得在提示上直接给出「重新连接」入口。离线由网络横幅负责，凭据失效由重新配对
    /// 横幅负责，这里只覆盖点一下就可能恢复的链路类失败。
    var suggestsReconnect: Bool {
        switch category {
        case .hostUnreachable, .connectionLost, .timedOut, .hostError:
            return true
        default:
            return false
        }
    }

    /// 用格式化后的文案替换正文，保留分类与技术详情。用于「重命名失败：%@」这类带动作前缀的提示。
    func withMessage(_ message: String) -> UserFacingError {
        UserFacingError(category: category, message: message, technicalDetail: technicalDetail)
    }
}

extension UserFacingError {
    init(_ error: Error) {
        let rawDescription = error.localizedDescription
        if error is FileAccessAPIError {
            // 文件访问错误已有按错误码细分的可读说明，比通用分类更准确。
            self.init(
                category: .permissionDenied,
                message: FilePreviewErrorPresentation.message(for: error),
                technicalDetail: rawDescription
            )
            return
        }
        if case .unsafeParameter(let reason)? = error as? CodexAppServerRequestBuilderError {
            // 本地参数校验的原因本身是可读说明（如「基础分支不能为空」），只去掉 app-server 外壳。
            self.init(category: .described, message: reason, technicalDetail: rawDescription)
            return
        }
        if case .business(let remote)? = error as? HarnessTransportError,
           let message = remote.message?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty,
           !Self.containsTechnicalDetail(message) {
            self.init(category: .described, message: message, technicalDetail: remote.diagnosticCode)
            return
        }
        if Self.isReadableAsIs(error) {
            self = .described(rawDescription)
            return
        }
        guard let category = Self.category(for: error) else {
            self.init(rawMessage: rawDescription)
            return
        }
        self.init(
            category: category,
            message: Self.message(for: category),
            technicalDetail: Self.technicalDetail(for: error, rawDescription: rawDescription)
        )
    }

    /// 只拿得到字符串的出口（WebSocket 回调、运行时 error 通知等）的兜底翻译。
    ///
    /// 不含协议细节的原文原样保留；含有细节时按关键字归类，并尽量保留「审批失败：」这类
    /// 动作前缀，让用户仍知道是哪一步没有完成。
    init(rawMessage: String) {
        let trimmed = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.containsTechnicalDetail(trimmed) else {
            self = .described(trimmed)
            return
        }
        if let split = Self.actionPrefix(in: trimmed),
           !Self.containsTechnicalDetail(split.prefix) {
            let category = Self.category(forRawMessage: split.remainder)
            self.init(
                category: category,
                message: split.prefix + split.separator + Self.message(for: category),
                technicalDetail: trimmed
            )
            return
        }
        let category = Self.category(forRawMessage: trimmed)
        self.init(category: category, message: Self.message(for: category), technicalDetail: trimmed)
    }

    /// 运行时 error 通知（模型服务、agentd 转发的本轮失败原因）。
    ///
    /// 这里的原文描述的是模型侧的失败，不是手机到电脑的链路，不能套用「连不上电脑」之类的
    /// 链路文案。可读的原文（如上下文超限）原样保留；夹带协议细节时只给一句结论，原文进详情。
    init(runtimeFailureMessage: String) {
        let trimmed = runtimeFailureMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        // 运行时原文里的请求地址只对排障有用；App 自己的说明可能带示例地址，所以只在这里算作细节。
        let mentionsURL = trimmed.range(of: "https?://", options: [.regularExpression, .caseInsensitive]) != nil
        guard Self.containsTechnicalDetail(trimmed) || mentionsURL else {
            self = .described(trimmed)
            return
        }
        self.init(category: .unknown, message: L10n.text("ui.error_run_failed"), technicalDetail: trimmed)
    }

    static func message(for category: UserFacingErrorCategory) -> String {
        switch category {
        case .offline:
            return L10n.text("ui.error_offline")
        case .hostUnreachable:
            return L10n.text("ui.error_host_unreachable")
        case .connectionLost:
            return L10n.text("ui.error_connection_lost")
        case .reconnecting:
            return L10n.text("ui.error_reconnecting")
        case .timedOut:
            return L10n.text("ui.error_timed_out")
        case .authenticationExpired:
            return ConnectionTerminationStatus.credentialsInvalid.message
        case .permissionDenied:
            return L10n.text("ui.error_permission_denied")
        case .unsupported:
            return L10n.text("ui.error_unsupported")
        case .rateLimited:
            return L10n.text("ui.error_rate_limited")
        case .hostError:
            return L10n.text("ui.error_host_error")
        case .rejected:
            return L10n.text("ui.error_rejected")
        case .invalidResponse:
            return L10n.text("ui.error_invalid_response")
        case .outcomeUnknown:
            return L10n.text("ui.error_outcome_unknown")
        case .unknown, .described:
            return L10n.text("ui.error_unknown")
        }
    }

    // MARK: - 结构化错误分类

    /// 自带描述已经是可执行说明的错误（配置地址、允许列表、上游 Codex 不可用等），
    /// 原样展示，不再交给字符串兜底，避免说明里的示例地址被误判为技术细节。
    private static func isReadableAsIs(_ error: Error) -> Bool {
        switch error {
        case AgentAPIError.invalidEndpoint, AgentAPIError.insecurePublicHTTPEndpoint:
            return true
        case CodexAppServerRequestBuilderError.projectNotAllowlisted,
             CodexAppServerRequestBuilderError.pathNotAllowlisted:
            return true
        case CodexAppServerConnectionError.appServer(let appServerError):
            return isUpstreamUnavailable(appServerError)
        case let appServerError as CodexAppServerError:
            return isUpstreamUnavailable(appServerError)
        default:
            return false
        }
    }

    private static func isUpstreamUnavailable(_ error: CodexAppServerError) -> Bool {
        // 上游 Codex 不可用已有专门的可读说明（检查 SSH / Codex App Server）。
        error.data?.objectValue?["reason"]?.stringValue == "codex_upstream_unavailable"
    }

    /// nil 表示该错误自带的描述已经是用户文案（配置错误、业务说明等），交给字符串兜底判断。
    static func category(for error: Error) -> UserFacingErrorCategory? {
        if let urlError = error as? URLError {
            return category(forURLErrorCode: urlError.code)
        }
        if error is DecodingError {
            return .invalidResponse
        }
        if let apiError = error as? AgentAPIError {
            switch apiError {
            case .invalidEndpoint, .insecurePublicHTTPEndpoint:
                return nil
            case .invalidResponse, .decoding:
                return .invalidResponse
            case .credentialsInvalid:
                return .authenticationExpired
            case .server(let status, _):
                return apiError.invalidatesCredentials ? .authenticationExpired : category(forHTTPStatus: status)
            }
        }
        if let connectionError = error as? CodexAppServerConnectionError {
            switch connectionError {
            case .disconnected, .notInitialized:
                return .connectionLost
            case .duplicateRequestID:
                return .unknown
            case .timeout:
                return .timedOut
            case .outcomeUnknown:
                return .outcomeUnknown
            case .appServer(let appServerError):
                return category(forJSONRPCCode: appServerError.code)
            case .decoding:
                return .invalidResponse
            case .transport(let underlying):
                if connectionError.invalidatesCredentials {
                    return .authenticationExpired
                }
                return category(for: underlying) ?? .connectionLost
            }
        }
        if let appServerError = error as? CodexAppServerError {
            return category(forJSONRPCCode: appServerError.code)
        }
        if let harnessError = error as? HarnessTransportError {
            return category(forHarnessError: harnessError)
        }
        if let compatibilityError = error as? ProtocolCompatibilityError {
            switch compatibilityError {
            case .serverTooOld:
                return .unsupported
            case .clientTooOld, .invalidServerMetadata:
                return .invalidResponse
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return category(forURLErrorCode: URLError.Code(rawValue: nsError.code))
        }
        return nil
    }

    static func category(forHTTPStatus status: Int) -> UserFacingErrorCategory {
        switch status {
        case 401:
            return .authenticationExpired
        case 403:
            return .permissionDenied
        case 404, 405, 501:
            return .unsupported
        case 408, 504:
            return .timedOut
        case 429:
            return .rateLimited
        case 500...599:
            return .hostError
        case 400...499:
            return .rejected
        default:
            return .unknown
        }
    }

    static func category(forJSONRPCCode code: Int) -> UserFacingErrorCategory {
        switch code {
        case -32601:
            return .unsupported
        case -32700, -32600, -32602:
            return .rejected
        default:
            return .hostError
        }
    }

    private static func category(forURLErrorCode urlErrorCode: URLError.Code) -> UserFacingErrorCategory {
        switch urlErrorCode {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            return .offline
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .secureConnectionFailed,
             .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected, .clientCertificateRequired:
            return .hostUnreachable
        case .networkConnectionLost:
            return .connectionLost
        case .timedOut:
            return .timedOut
        case .userAuthenticationRequired, .userCancelledAuthentication:
            return .authenticationExpired
        case .badServerResponse, .cannotParseResponse, .cannotDecodeContentData,
             .cannotDecodeRawData, .zeroByteResource:
            return .invalidResponse
        default:
            return .unknown
        }
    }

    private static func category(forHarnessError harnessError: HarnessTransportError) -> UserFacingErrorCategory {
        switch harnessError {
        case .unauthorized:
            return .authenticationExpired
        case .rejected, .business:
            return .rejected
        case .server(let status, _):
            return category(forHTTPStatus: status)
        case .malformedResponse:
            return .invalidResponse
        case .notConnected, .closed, .continuityLost:
            return .connectionLost
        case .timedOut:
            return .timedOut
        case .carrier:
            return .hostError
        case .unsupportedInteraction:
            return .unsupported
        case .unattributedResponse, .cancelled:
            return .unknown
        }
    }

    private static func technicalDetail(for error: Error, rawDescription: String) -> String {
        // 不是 LocalizedError 的 Swift 错误只有「操作无法完成 (X error N.)」这种描述，
        // 补上类型与 case，支持人员才能对上是哪一类失败。
        guard !(error is LocalizedError) else {
            return rawDescription
        }
        let reflected = String(reflecting: error)
        return reflected == rawDescription ? rawDescription : "\(reflected) — \(rawDescription)"
    }

    // MARK: - 字符串兜底分类

    private static let technicalMarkers: [NSRegularExpression] = [
        "websocket",
        "json-?rpc",
        "app-server",
        "\\bagentd\\b",
        "\\bhttp\\s*\\d{3}\\b",
        "decodingerror",
        "keynotfound",
        "typemismatch",
        "valuenotfound",
        "datacorrupted",
        "nsurlerrordomain",
        "error domain=",
        "-32[0-7]\\d{2}\\b",
        "request id",
        "\\b(?:thread|turn|model|review|account)/[a-z]+",
        // Foundation 对非 LocalizedError 的默认描述：「…(Module.Type error 1.)」。
        "\\([\\w.]+ error -?\\d+\\.\\)"
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    static func containsTechnicalDetail(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return technicalMarkers.contains { $0.firstMatch(in: text, options: [], range: range) != nil }
    }

    static func category(forRawMessage text: String) -> UserFacingErrorCategory {
        let lowered = text.lowercased()
        func containsAny(_ needles: [String]) -> Bool {
            needles.contains { lowered.contains($0) }
        }
        if containsAny(["重连", "重新接入", "正在连接", "reconnect", "is connecting"]) {
            return .reconnecting
        }
        if containsAny(["超时", "timed out", "timeout"]) {
            return .timedOut
        }
        if let status = firstCapturedInt(in: text, pattern: "\\bhttp\\s*(\\d{3})\\b") {
            return category(forHTTPStatus: status)
        }
        if let code = firstCapturedInt(in: text, pattern: "(-32[0-7]\\d{2})\\b") {
            return category(forJSONRPCCode: code)
        }
        if containsAny(["未连接", "断开", "not connected", "disconnected", "connection was lost", "connection lost", "传输失败", "transfer failed"]) {
            return .connectionLost
        }
        if containsAny(["解析", "parsing", "failed to parse", "decodingerror", "keynotfound", "typemismatch", "valuenotfound", "datacorrupted", "invalid response", "无效响应"]) {
            return .invalidResponse
        }
        if containsAny(["不支持", "not support", "unsupported", "method not found"]) {
            return .unsupported
        }
        return .unknown
    }

    private static func firstCapturedInt(in text: String, pattern: String) -> Int? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Int(text[range])
    }

    /// 拆出「审批失败：」「Approval failed: 」这类短动作前缀。前缀过长时更像一整句说明，
    /// 不拆，避免把半句话当成标题。
    private static func actionPrefix(in text: String) -> (prefix: String, separator: String, remainder: String)? {
        let candidates = ["：", ": "].compactMap { separator -> (String.Index, String)? in
            text.range(of: separator).map { ($0.lowerBound, separator) }
        }
        guard let (index, separator) = candidates.min(by: { $0.0 < $1.0 }) else {
            return nil
        }
        let prefix = String(text[..<index]).trimmingCharacters(in: .whitespaces)
        let remainder = String(text[text.index(index, offsetBy: separator.count)...])
        guard !prefix.isEmpty, prefix.count <= 32, !remainder.isEmpty else {
            return nil
        }
        return (prefix, separator, remainder)
    }
}
