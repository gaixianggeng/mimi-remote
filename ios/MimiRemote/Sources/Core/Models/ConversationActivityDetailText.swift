import Foundation

/// 预览只控制紧凑行的长度。已收到的正文保存在现有 content 中，展开时不再读取截断预览。
enum ConversationActivityDetailText {
    static func toolInput(from item: [String: CodexAppServerJSONValue]) -> String? {
        guard ["mcpToolCall", "dynamicToolCall"].contains(item["type"]?.stringValue ?? ""),
              let arguments = item["arguments"], arguments != .null,
              arguments.objectValue?.isEmpty != true else { return nil }
        return formattedJSON(arguments)
    }

    static func output(from item: [String: CodexAppServerJSONValue]) -> String? {
        switch item["type"]?.stringValue {
        case "reasoning":
            let summary = strings(item["summary"])
            let content = strings(item["content"]).filter { !summary.contains($0) }
            return joined(summary + content)
        case "plan":
            return nonempty(item["text"]?.stringValue)
        case "commandExecution":
            return nonempty(item["aggregatedOutput"]?.stringValue)
        case "fileChange":
            let changes = item["changes"]?.arrayValue ?? []
            return joined(changes.compactMap { change in
                guard let object = change.objectValue,
                      let diff = nonempty(object["diff"]?.stringValue) else { return nil }
                let path = nonempty(object["path"]?.stringValue)
                return [path, diff].compactMap { $0 }.joined(separator: "\n")
            })
        case "collabAgentToolCall":
            let states = item["agentsStates"]?.objectValue ?? [:]
            let receivers = strings(item["receiverThreadIds"])
            let ids = receivers + states.keys.filter { !receivers.contains($0) }.sorted()
            return joined(ids.compactMap { render(states[$0]?["message"]) })
        case "mcpToolCall", "dynamicToolCall", "webSearch":
            return joined([
                render(item["error"]),
                render(item["contentItems"]) ?? render(item["result"])
            ].compactMap { $0 })
        default:
            return nil
        }
    }

    static func render(_ value: CodexAppServerJSONValue?) -> String? {
        guard let value, value != .null else { return nil }
        switch value {
        case .string(let text):
            return nonempty(text)
        case .array(let values):
            return joined(values.compactMap(render))
        case .object(let object):
            // 媒体仍交给既有附件投影，不把 base64 数据当成可阅读的工具输出。
            if let type = object["type"]?.stringValue,
               ["image", "image_url", "inputImage", "audio"].contains(type) {
                return nil
            }
            if let text = nonempty(object["text"]?.stringValue) { return text }
            let resultKeys = ["content", "contentItems", "structuredContent"]
            if resultKeys.contains(where: { object[$0] != nil }) {
                // MCP 可同时提供可读文本和结构化结果；纯媒体容器则不能回退为 base64 JSON。
                var parts: [String] = []
                for key in resultKeys {
                    if let part = render(object[key]), !parts.contains(part) { parts.append(part) }
                }
                return joined(parts)
            }
            if let message = nonempty(object["message"]?.stringValue) {
                var parts = [message]
                if let code = render(object["code"]) { parts.append("code: \(code)") }
                if let data = render(object["data"]), !parts.contains(data) { parts.append(data) }
                return joined(parts)
            }
            fallthrough
        default:
            return formattedJSON(value)
        }
    }

    private static func formattedJSON(_ value: CodexAppServerJSONValue) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func strings(_ value: CodexAppServerJSONValue?) -> [String] {
        value?.arrayValue?.compactMap { nonempty($0.stringValue) } ?? []
    }

    private static func joined(_ parts: [String]) -> String? {
        nonempty(parts.joined(separator: "\n\n"))
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}

extension ConversationActivityPayload {
    func detailText(from item: [String: CodexAppServerJSONValue]) -> String {
        let output = ConversationActivityDetailText.output(from: item) ?? outputPreview
        guard let input = ConversationActivityDetailText.toolInput(from: item) else {
            return output ?? summaryText
        }
        // 紧凑预览只取结果；展开正文还保留调用参数，便于理解实际执行了什么。
        let parts = [
            "\(L10n.text("ui.tool_input"))\n\(input)",
            output.map { "\(L10n.text("ui.tool_output"))\n\($0)" }
        ]
        return parts.compactMap { $0 }.joined(separator: "\n\n")
    }
}
