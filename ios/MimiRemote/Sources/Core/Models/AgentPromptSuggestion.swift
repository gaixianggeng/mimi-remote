import Foundation

/// 只接收运行时的独立建议事件，普通回复正文不参与提取。
struct AgentPromptSuggestion: Equatable {
    let id: String
    let text: String
    // 由当前客户端绑定，绝不从网络参数读取。已排进邮箱的旧连接尾包也必须失效。
    private(set) var connectionGeneration: Int?

    init?(params: [String: CodexAppServerJSONValue]) {
        guard let id = params["id"]?.stringValue, !id.isEmpty, id.utf8.count <= 128,
              let rawText = params["text"]?.stringValue else { return nil }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf16.count <= 4_096 else { return nil }
        self.id = id
        self.text = text
    }

    func bound(to generation: Int) -> Self {
        var copy = self
        copy.connectionGeneration = generation
        return copy
    }
}

extension AgentEvent {
    func bindingPromptSuggestion(to generation: Int) -> AgentEvent {
        guard case .promptSuggestion(let suggestion, let metadata) = self else { return self }
        return .promptSuggestion(suggestion.bound(to: generation), metadata)
    }
}
