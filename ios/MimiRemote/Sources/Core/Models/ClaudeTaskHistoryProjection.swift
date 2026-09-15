import Foundation

/// Task 工具使用已有 DynamicToolCall 字段重建清单，缺失创建结果时不猜测任务身份。
enum ClaudeTaskHistoryProjection {
    static func isTaskMutation(_ item: [String: CodexAppServerJSONValue]) -> Bool {
        item["namespace"]?.stringValue == "claude"
            && ["TaskCreate", "TaskUpdate"].contains(item["tool"]?.stringValue ?? "")
    }

    static func tasks(in turns: [[String: CodexAppServerJSONValue]]) -> [SessionContextTask] {
        var tasks: [SessionContextTask] = []
        for turn in turns {
            for value in turn["items"]?.arrayValue ?? [] {
                guard let item = value.objectValue,
                      item["type"]?.stringValue == "dynamicToolCall",
                      item["namespace"]?.stringValue == "claude",
                      item["success"]?.boolValue == true,
                      let arguments = item["arguments"]?.objectValue else { continue }
                switch item["tool"]?.stringValue {
                case "TaskCreate":
                    guard let result = resultObject(in: item),
                          let id = taskID(in: result),
                          let title = arguments["subject"]?.stringValue
                            ?? arguments["description"]?.stringValue,
                          !id.isEmpty, !title.isEmpty else { continue }
                    let task = SessionContextTask(
                        id: "claude-task:\(id)", kind: "plan", title: title,
                        subtitle: nil, status: status(arguments["status"]?.stringValue ?? "pending")
                    )
                    if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                        tasks[index] = task
                    } else {
                        tasks.append(task)
                    }
                case "TaskUpdate":
                    guard let id = arguments["taskId"]?.stringValue,
                          let index = tasks.firstIndex(where: { $0.id == "claude-task:\(id)" }) else { continue }
                    if arguments["status"]?.stringValue == "deleted" {
                        tasks.remove(at: index)
                    } else {
                        let previous = tasks[index]
                        tasks[index] = SessionContextTask(
                            id: previous.id, kind: previous.kind,
                            title: arguments["subject"]?.stringValue ?? previous.title,
                            subtitle: previous.subtitle,
                            status: arguments["status"]?.stringValue.map(status) ?? previous.status
                        )
                    }
                default:
                    continue
                }
            }
        }
        return tasks
    }

    private static func resultObject(in item: [String: CodexAppServerJSONValue]) -> [String: CodexAppServerJSONValue]? {
        if let result = item["result"]?.objectValue, taskID(in: result) != nil { return result }
        for value in item["contentItems"]?.arrayValue ?? [] {
            guard let text = value["text"]?.stringValue,
                  let data = text.data(using: .utf8),
                  let result = try? JSONDecoder().decode(CodexAppServerJSONValue.self, from: data),
                  let object = result.objectValue else { continue }
            if taskID(in: object) != nil { return object }
        }
        return nil
    }

    private static func taskID(in result: [String: CodexAppServerJSONValue]) -> String? {
        let id = result["task"]?["id"]?.stringValue ?? result["taskId"]?.stringValue ?? result["id"]?.stringValue
        return id?.isEmpty == false ? id : nil
    }

    private static func status(_ value: String) -> String {
        value == "in_progress" ? "inProgress" : value
    }
}
