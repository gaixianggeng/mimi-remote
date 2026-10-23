import Combine
import Foundation

/// 输入框之外的入口（例如改动面板的审阅备注）向某个草稿末尾追加的一段文字。
/// `id` 让连续两次追加相同文字也能被仍在层级里的 Composer 各收一次。
struct ComposerDraftAppendEvent: Equatable {
    let id: UUID
    let text: String
    let targetScope: ComposerDraftScopeKey
}

enum ComposerDraftTextAppend {
    /// 草稿已有正文时空一行再追加；只去掉原文末尾的空白，用户写下的内容一个字也不改。
    static func appending(_ addition: String, to existing: String) -> String {
        var head = Substring(existing)
        while let last = head.last, last.isWhitespace {
            head.removeLast()
        }
        guard !head.isEmpty else {
            return addition
        }
        return "\(head)\n\n\(addition)"
    }
}

extension SessionStore {
    func saveComposerDraft(_ snapshot: ComposerDraftSnapshot, for scope: ComposerDraftScopeKey) {
        if scope == .session(selectedSessionID ?? ""), composerDraftCache.snapshot(for: scope) != snapshot {
            invalidateNativePromptSuggestion()
        }
        composerDraftCache.save(snapshot, for: scope)
    }

    func composerDraft(for scope: ComposerDraftScopeKey) -> ComposerDraftSnapshot {
        composerDraftCache.snapshot(for: scope)
    }

    func removeComposerDraft(for scope: ComposerDraftScopeKey) {
        composerDraftCache.remove(scope: scope)
    }

    /// 追加到指定作用域的草稿，不发送。先写稳定仓再通知：没有可见输入框时，切回该会话会从仓里恢复；
    /// 输入框仍在层级里时由它在自己的当前文本后追加并回写，覆盖这里基于旧缓存的结果。
    @discardableResult
    func appendComposerDraftText(_ text: String, to scope: ComposerDraftScopeKey) -> Bool {
        let addition = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard scope != .none, !addition.isEmpty else {
            return false
        }
        var snapshot = composerDraft(for: scope)
        snapshot.text = ComposerDraftTextAppend.appending(addition, to: snapshot.text)
        saveComposerDraft(snapshot, for: scope)
        composerDraftAppends.send(ComposerDraftAppendEvent(id: UUID(), text: addition, targetScope: scope))
        return true
    }
}
