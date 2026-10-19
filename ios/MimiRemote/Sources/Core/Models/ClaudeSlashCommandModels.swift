import Foundation

/// Claude Code 自带的斜杠命令（内置命令、技能、自定义命令），来自 Claude 适配器的
/// `slashCommand/list`（#765）。选中后只把 `/名称 ` 插进草稿，按普通文本发送，由 Claude Code
/// 自己解析；客户端不执行这些命令。
struct ClaudeSlashCommand: Hashable, Identifiable {
    let name: String
    let description: String
    let argumentHint: String?
    let aliases: [String]

    var id: String { name }

    static func parseListResult(_ result: CodexAppServerJSONValue?) -> [ClaudeSlashCommand] {
        guard let values = result?.objectValue?["data"]?.arrayValue else {
            return []
        }
        var seen: Set<String> = []
        return values.compactMap { value in
            guard let object = value.objectValue,
                  let name = object["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  // 名字里有空白或斜杠就无法作为 `/名称` 输入，插进草稿也不会被识别。
                  !name.isEmpty,
                  name.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                  !name.contains("/"),
                  seen.insert(name).inserted
            else {
                return nil
            }
            let hint = object["argumentHint"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            return ClaudeSlashCommand(
                name: name,
                description: object["description"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                argumentHint: hint?.isEmpty == false ? hint : nil,
                aliases: (object["aliases"]?.arrayValue ?? []).compactMap(\.stringValue).filter { !$0.isEmpty }
            )
        }
    }
}

/// 同一主机、工作区与执行边界下，Claude Code 认识的命令相同：受限档位不加载本机设置，
/// 只有内置命令；完全访问还包含用户与项目的技能和命令。
struct ClaudeSlashCommandCatalogKey: Hashable {
    let hostScope: HostScope
    let cwd: String
    let fullAccess: Bool
}

struct ClaudeSlashCommandCatalogState: Equatable {
    var commands: [ClaudeSlashCommand] = []
    var fetchedAt: Date?
    var failedAt: Date?
    var isLoading = false
}

enum ClaudeSlashCommandCatalogError: Error {
    /// 主机的 Claude 通道没有声明 slashCommand/list（旧 bridge 或旧 agentd）。
    case unsupported
}
