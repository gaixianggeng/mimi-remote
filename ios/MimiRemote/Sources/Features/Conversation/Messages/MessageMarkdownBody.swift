import SwiftUI

struct MessageMarkdownBody: View {
    @EnvironmentObject private var themeStore: ThemeStore
    let blocks: [MarkdownBlock]
    let style: MarkdownStyle
    var fillsWidth = true

    var body: some View {
        let textStyle = MessageTextStyle(markdown: style, fontPreset: themeStore.uiFontPreset, codeFontPreset: themeStore.codeFontPreset)
        VStack(alignment: .leading, spacing: style.blockSpacing) {
            ForEach(segments) { segment in
                if segment.isText {
                    MessageSelectableText(document: .markdown(segment.blocks, style: textStyle), style: textStyle, fillsWidth: fillsWidth)
                } else if let block = segment.blocks.first {
                    MarkdownBlockView(block: block, style: style, selectable: true)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var segments: [Segment] {
        var result: [Segment] = []
        for block in blocks {
            if block.supportsContinuousTextSelection, result.last?.isText == true {
                result[result.count - 1].blocks.append(block)
            } else {
                result.append(Segment(id: block.id, blocks: [block], isText: block.supportsContinuousTextSelection))
            }
        }
        return result
    }

    private struct Segment: Identifiable {
        let id: Int
        var blocks: [MarkdownBlock]
        let isText: Bool
    }
}

struct MessagePlainText: View {
    @EnvironmentObject private var themeStore: ThemeStore
    let text: String
    let style: MarkdownStyle
    var fillsWidth = false

    var body: some View {
        let textStyle = MessageTextStyle(markdown: style, fontPreset: themeStore.uiFontPreset, codeFontPreset: themeStore.codeFontPreset)
        MessageSelectableText(document: .plain(text, style: textStyle), style: textStyle, fillsWidth: fillsWidth)
    }
}

extension MarkdownBlock {
    var supportsContinuousTextSelection: Bool {
        switch kind {
        case .table, .image, .proposedPlan, .thematicBreak, .blockquote:
            return false
        case .bulletList(let items, _), .orderedList(_, let items, _):
            return items.allSatisfy { $0.blocks.allSatisfy(\.supportsContinuousTextSelection) }
        case .taskList(let items):
            return items.allSatisfy { $0.blocks.allSatisfy(\.supportsContinuousTextSelection) }
        default:
            return true
        }
    }

    var visibleCopyText: String {
        switch kind {
        case .paragraph(let inline), .heading(_, let inline):
            return inline.plain
        case .bulletList(let items, _):
            return items.map { item in
                let marker = item.checkbox.map { $0 ? "☑" : "☐" } ?? "•"
                return marker + " " + item.blocks.map(\.visibleCopyText).joined(separator: "\n")
            }.joined(separator: "\n")
        case .orderedList(let start, let items, _):
            return items.enumerated().map { index, item in
                "\(start + index). " + item.blocks.map(\.visibleCopyText).joined(separator: "\n")
            }.joined(separator: "\n")
        case .taskList(let items):
            return items.map { ($0.checked ? "☑ " : "☐ ") + $0.blocks.map(\.visibleCopyText).joined(separator: "\n") }.joined(separator: "\n")
        case .blockquote(let blocks), .proposedPlan(let blocks, _):
            return blocks.map(\.visibleCopyText).joined(separator: "\n\n")
        case .codeBlock(_, let code):
            return code.trimmingCharacters(in: .newlines)
        case .image(let reference):
            return reference.altText ?? reference.title ?? ""
        case .table(let header, let rows, _):
            return ([header] + rows).map { $0.map(\.plain).joined(separator: "\t") }.joined(separator: "\n")
        case .thematicBreak:
            return ""
        }
    }
}

extension ConversationMessage {
    @MainActor var visibleCopyText: String {
        let visible = role == .user
            ? ConversationUserMessagePresentation.displayContent(from: content)
            : ConversationMarkdownPresentation.displayContent(from: content)
        guard role == .assistant || ConversationMarkdownPresentation.containsLink(in: visible) else { return visible }
        return MessageRenderPlanCache.shared.plan(for: self, rendering: visible).blocks
            .map(\.visibleCopyText).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
