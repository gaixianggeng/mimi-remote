import SwiftUI

extension ComposerView {
    var canInsertNativePromptSuggestion: Bool {
        composerState.draft.isEmpty && composerState.attachments.isEmpty
            && activeComposerDraftScope == currentComposerDraftScope
            && !isComposerTextComposing && !isVoiceTranscribing && !isVoicePressActive
            && !clipboardImageState.isPreparing(activeComposerDraftScope)
            && !sessionStore.fileUploadStore.hasBlockingJob(for: activeComposerDraftScope)
    }

    @ViewBuilder
    var nativePromptSuggestionNotice: some View {
        if canInsertNativePromptSuggestion, let suggestion = sessionStore.currentNativePromptSuggestion {
            let tokens = themeStore.tokens(for: colorScheme)
            HStack(alignment: .top, spacing: 8) {
                Button {
                    acceptNativePromptSuggestion(suggestion)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("ui.native_suggestion_add_to_draft"))
                            .font(themeStore.uiFont(.caption))
                            .foregroundStyle(tokens.accent)
                        Text(suggestion.text)
                            .font(themeStore.uiFont(.subheadline))
                            .foregroundStyle(tokens.secondaryText)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("composer.nativeSuggestion.accept")
                Button {
                    sessionStore.nativePromptSuggestionState.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(themeStore.uiFont(size: 12, weight: .semibold))
                        .foregroundStyle(tokens.secondaryText)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("ui.native_suggestion_dismiss"))
                .accessibilityIdentifier("composer.nativeSuggestion.dismiss")
            }
            .accessibilityElement(children: .contain)
        }
    }

    func acceptNativePromptSuggestion(_ candidate: AgentPromptSuggestion) {
        guard canInsertNativePromptSuggestion,
              let suggestion = sessionStore.takeNativePromptSuggestion(
                id: candidate.id, scope: activeComposerDraftScope, draft: composerState.draftSnapshot()
              ), composerState.insertNativePromptSuggestion(suggestion) else { return }
        composerTextExternalRevision &+= 1
        sessionStore.saveComposerDraft(composerState.draftSnapshot(), for: activeComposerDraftScope)
        // 只有用户按下接受才请求编辑焦点；事件到达时不改变焦点。
        composerTextFocusRequestID = UUID()
    }
}
