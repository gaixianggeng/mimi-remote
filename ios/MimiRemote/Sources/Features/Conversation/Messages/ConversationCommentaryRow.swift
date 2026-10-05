import SwiftUI

struct ConversationCommentaryRow: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    let message: ConversationMessage
    let layout: ConversationLayout
    let stop: () -> Void

    var body: some View {
        commentaryBody
            .frame(maxWidth: layout.assistantBubbleMaxWidth, alignment: .leading)
            .contentShape(.interaction, Rectangle())
            .contentShape(.contextMenuPreview, Rectangle())
            .messageContextMenu(
                for: message,
                retry: {},
                stop: stop
            )
            .accessibilityElement(children: .contain)
    }

    private var commentaryBody: some View {
        let tokens = themeStore.tokens(for: colorScheme)
        let style = MarkdownStyle.make(
            role: .assistant,
            colorScheme: colorScheme,
            fontScale: themeStore.fontScale,
            tokens: tokens
        )
        let plan = MessageRenderPlanCache.shared.plan(for: message)
        return MessageMarkdownBody(blocks: plan.blocks, style: style)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}
