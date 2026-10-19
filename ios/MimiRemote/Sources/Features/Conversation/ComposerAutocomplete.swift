import Foundation

/// 输入框补全查询：`$` 只补全技能；草稿开头的 `/` 补全命令与技能（#765）。
struct ComposerSkillQuery: Equatable {
    enum Trigger: Equatable {
        case skill
        case command
    }

    let trigger: Trigger
    let query: String
    /// 选中候选后要从正文里移除的范围（UTF-16）。
    let replacementRange: NSRange

    static func match(text: String, selectedRange: NSRange) -> ComposerSkillQuery? {
        let source = text as NSString
        guard selectedRange.length == 0,
              selectedRange.location >= 0,
              selectedRange.location <= source.length
        else {
            return nil
        }

        let prefixRange = NSRange(location: 0, length: selectedRange.location)
        let whitespace = source.rangeOfCharacter(
            from: .whitespacesAndNewlines,
            options: .backwards,
            range: prefixRange
        )
        let tokenStart = whitespace.location == NSNotFound ? 0 : NSMaxRange(whitespace)
        let tokenRange = NSRange(location: tokenStart, length: selectedRange.location - tokenStart)
        guard tokenRange.length > 0 else {
            return nil
        }
        let token = source.substring(with: tokenRange)
        if token.hasPrefix("$") {
            return ComposerSkillQuery(
                trigger: .skill,
                query: String(token.dropFirst()),
                replacementRange: tokenRange
            )
        }
        guard token.hasPrefix("/") else {
            return nil
        }
        return commandQuery(in: source, tokenStart: tokenStart, cursor: selectedRange.location)
    }

    private static func commandQuery(in source: NSString, tokenStart: Int, cursor: Int) -> ComposerSkillQuery? {
        // 只认整段草稿的第一个词：正文中部或第二行的 `/` 多半是路径、分数或代码，弹菜单只会打断输入。
        guard source.substring(to: tokenStart).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        // 光标在词中间时按整个词判断和替换，避免 `/mo|del` 选中后残留 `del`。
        let tail = NSRange(location: cursor, length: source.length - cursor)
        let nextWhitespace = source.rangeOfCharacter(from: .whitespacesAndNewlines, options: [], range: tail)
        let wordEnd = nextWhitespace.location == NSNotFound ? source.length : nextWhitespace.location
        let word = source.substring(with: NSRange(location: tokenStart, length: wordEnd - tokenStart))
        // 第二个 `/` 说明是路径（/tmp/file、//），不是命令。
        guard !word.dropFirst().contains("/") else {
            return nil
        }
        // 顺带移除命令后的一个空格，`/plan 修复登录` 选中后正文不留前导空格。
        var removalEnd = wordEnd
        if removalEnd < source.length, source.character(at: removalEnd) == 0x20 {
            removalEnd += 1
        }
        return ComposerSkillQuery(
            trigger: .command,
            query: source.substring(with: NSRange(location: tokenStart + 1, length: cursor - tokenStart - 1)),
            replacementRange: NSRange(location: tokenStart, length: removalEnd - tokenStart)
        )
    }
}

/// `/` 菜单里的动作。App 自己的动作只调用输入框已有入口，不发消息、不消耗模型回合；
/// 运行时命令（Claude Code 自带的命令与技能）只把 `/名称 ` 插进草稿，由运行时自己解析。
enum ComposerSlashCommandAction: Hashable {
    case model
    case permission(ComposerPermissionMode)
    case plan
    case compact
    case runtimeCommand(String)
}

struct ComposerSlashCommand: Identifiable, Hashable {
    let action: ComposerSlashCommandAction
    /// 斜杠后的命令名保持英文，与 Codex / Claude Code 的输入习惯一致；中文名称放在 title。
    let name: String
    let title: String
    let detail: String
    let systemImage: String
    var isCurrent = false
    /// 暂时不能执行的原因（如回合进行中）；非空时置灰且不响应选择。
    var unavailableReason: String?
    /// 同样能输入的别名（如 Claude 的 `/cost` 对应 `/usage`），参与筛选。
    var aliases: [String] = []

    var id: String {
        switch action {
        case .permission(let mode):
            return "\(name).\(mode.rawValue)"
        case .runtimeCommand:
            return "runtime.\(name)"
        default:
            return name
        }
    }

    /// `/permissions` 里标「当前」的档位，与工具栏权限标签同一口径：沿用会话权限时按服务端报告的
    /// 内置档位判断；选了自定义权限配置时没有对应档位。
    static func currentPermissionMode(
        preservesThreadSettings: Bool,
        selectedMode: ComposerPermissionMode,
        selectedProfileID: String?,
        activeProfileID: String?
    ) -> ComposerPermissionMode? {
        if preservesThreadSettings {
            return activeProfileID.flatMap(ComposerPermissionMode.init(builtInPermissionProfileID:))
        }
        return selectedProfileID == nil ? selectedMode : nil
    }
}

enum ComposerAutocompleteSuggestion: Identifiable {
    case command(ComposerSlashCommand)
    case skill(SkillCapability)

    var id: String {
        switch self {
        case .command(let command):
            return "command:\(command.id)"
        case .skill(let skill):
            return "skill:\(skill.id)"
        }
    }

    /// 名称前缀 > 名称包含 > 中文名或说明包含。技能只比对名称，保持 `$` 原有的匹配范围。
    fileprivate func matchTier(for needle: String) -> Int? {
        let names: [String]
        let texts: [String]
        switch self {
        case .command(let command):
            names = [command.name] + command.aliases
            texts = [command.title, command.detail]
        case .skill(let skill):
            names = [skill.name, skill.presentationName]
            texts = []
        }
        if names.contains(where: { $0.range(of: needle, options: [.anchored, .caseInsensitive]) != nil }) {
            return 0
        }
        if names.contains(where: { $0.localizedCaseInsensitiveContains(needle) }) {
            return 1
        }
        if texts.contains(where: { $0.localizedCaseInsensitiveContains(needle) }) {
            return 2
        }
        return nil
    }
}

enum ComposerAutocompleteRanking {
    /// 本地过滤，不发网络请求。同一档内保持输入顺序，列表不会随每次按键跳动。
    static func rank(
        _ suggestions: [ComposerAutocompleteSuggestion],
        query: String
    ) -> [ComposerAutocompleteSuggestion] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            return suggestions
        }
        return suggestions.enumerated()
            .compactMap { index, suggestion in
                suggestion.matchTier(for: needle).map { (tier: $0, index: index, suggestion: suggestion) }
            }
            .sorted { ($0.tier, $0.index) < ($1.tier, $1.index) }
            .map(\.suggestion)
    }
}
