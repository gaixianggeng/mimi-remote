import SwiftUI

extension ComposerView {
    /// 改动面板等外部入口往当前草稿末尾追加文字（#847）。仓里的草稿已由 SessionStore 先改好；
    /// 仍在层级里的输入框以自己的当前文本为准再追加一次并回写，避免旧内存草稿把追加内容盖掉。
    func applyExternalDraftAppend(_ event: ComposerDraftAppendEvent) {
        guard event.targetScope == activeComposerDraftScope else {
            return
        }
        if composerTextSubmitBridge.isEditing {
            // 正在输入时 UIKit 文本（含输入法候选）可能比草稿新；先收下，再在末尾追加。
            synchronizeComposerTextBeforeDraftScopeChange()
        }
        composerState.draft = ComposerDraftTextAppend.appending(event.text, to: composerState.draft)
        composerTextExternalRevision += 1
        sessionStore.saveComposerDraft(composerState.draftSnapshot(), for: activeComposerDraftScope)
    }
}
