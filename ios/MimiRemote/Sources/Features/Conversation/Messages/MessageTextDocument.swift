import SwiftUI
import UIKit

struct MessageTextDocument {
    struct CodeBlock {
        let range: NSRange
        let text: String
        let language: String?
    }

    let text: NSAttributedString
    let codeBlocks: [CodeBlock]

    static func plain(_ text: String, style: MessageTextStyle) -> Self {
        Self(text: NSAttributedString(string: text, attributes: style.attributes()), codeBlocks: [])
    }

    static func markdown(_ blocks: [MarkdownBlock], style: MessageTextStyle) -> Self {
        var builder = MessageTextDocumentBuilder(style: style)
        builder.append(blocks)
        return Self(text: builder.text, codeBlocks: builder.codeBlocks)
    }
}

struct MessageTextStyle {
    let markdown: MarkdownStyle
    var fontPreset: ThemeUIFontPreset = .system
    var codeFontPreset: ThemeCodeFontPreset = .systemMono

    var foreground: UIColor { UIColor(markdown.textColor) }
    var linkColor: UIColor { UIColor(markdown.linkColor) }

    func headingFont(level: Int) -> UIFont {
        let sizes: [CGFloat] = [24, 21, 19, 18, 17]
        return font(size: sizes[min(max(level - 1, 0), sizes.count - 1)], weight: .semibold)
    }

    func font(size: CGFloat = 17, weight: UIFont.Weight = .regular, code: Bool = false) -> UIFont {
        let pointSize = markdown.scaled(size)
        if code {
            if codeFontPreset == .menlo, let font = UIFont(name: "Menlo-Regular", size: pointSize) {
                return font
            }
            return .monospacedSystemFont(ofSize: pointSize, weight: weight)
        }
        let font = UIFont.systemFont(ofSize: pointSize, weight: weight)
        let design: UIFontDescriptor.SystemDesign
        switch fontPreset {
        case .system: design = .default
        case .rounded: design = .rounded
        case .serif: design = .serif
        }
        return font.fontDescriptor.withDesign(design).map { UIFont(descriptor: $0, size: pointSize) } ?? font
    }

    func attributes(font: UIFont? = nil, indent: CGFloat = 0) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = markdown.textLineSpacing
        paragraph.paragraphSpacing = markdown.blockSpacing
        paragraph.firstLineHeadIndent = indent
        paragraph.headIndent = indent
        return [.font: font ?? self.font(), .foregroundColor: foreground, .paragraphStyle: paragraph]
    }

    func inline(_ inline: MarkdownInlineText, font: UIFont? = nil, indent: CGFloat = 0) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for run in inline.attributed.runs {
            var runFont = font ?? self.font()
            var attributes = attributes(font: runFont, indent: indent)
            let intent = run.inlinePresentationIntent
            if intent?.contains(.code) == true {
                runFont = self.font(size: 15, code: true)
                attributes[.backgroundColor] = UIColor(markdown.codeBackground)
            }
            var traits = runFont.fontDescriptor.symbolicTraits
            if intent?.contains(.stronglyEmphasized) == true { traits.insert(.traitBold) }
            if intent?.contains(.emphasized) == true { traits.insert(.traitItalic) }
            if let descriptor = runFont.fontDescriptor.withSymbolicTraits(traits) {
                runFont = UIFont(descriptor: descriptor, size: runFont.pointSize)
            }
            attributes[.font] = runFont
            if intent?.contains(.strikethrough) == true { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = linkColor
                if markdown.underlinesLinks { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            }
            result.append(NSAttributedString(string: String(inline.attributed[run.range].characters), attributes: attributes))
        }
        return result
    }
}

private struct MessageTextDocumentBuilder {
    let style: MessageTextStyle
    let text = NSMutableAttributedString(string: "")
    var codeBlocks: [MessageTextDocument.CodeBlock] = []

    mutating func append(_ blocks: [MarkdownBlock], indent: CGFloat = 0) {
        for block in blocks {
            append(block, indent: indent)
        }
    }

    private mutating func append(_ block: MarkdownBlock, indent: CGFloat) {
        switch block.kind {
        case .paragraph(let inline):
            appendParagraph(style.inline(inline, indent: indent))
        case .heading(let level, let inline):
            appendParagraph(style.inline(inline, font: style.headingFont(level: level), indent: indent))
        case .bulletList(let items, let tight):
            appendList(items, start: nil, tight: tight, indent: indent)
        case .orderedList(let start, let items, let tight):
            appendList(items, start: start, tight: tight, indent: indent)
        case .taskList(let items):
            for item in items {
                appendListItem(item.blocks, marker: item.checked ? "☑" : "☐", tight: true, indent: indent)
            }
        case .codeBlock(let language, let code):
            appendCode(code, language: language, indent: indent)
        case .table, .image, .blockquote, .proposedPlan, .thematicBreak:
            break
        }
    }

    private func appendParagraph(_ paragraph: NSAttributedString) {
        if text.length > 0 {
            text.append(NSAttributedString(string: "\n", attributes: text.attributes(at: text.length - 1, effectiveRange: nil)))
        }
        text.append(paragraph)
    }

    private mutating func appendList(_ items: [MarkdownListItem], start: Int?, tight: Bool, indent: CGFloat) {
        for (index, item) in items.enumerated() {
            let marker = item.checkbox.map { $0 ? "☑" : "☐" } ?? start.map { "\($0 + index)." } ?? "•"
            appendListItem(item.blocks, marker: marker, tight: tight, indent: indent)
        }
    }

    private mutating func appendListItem(_ blocks: [MarkdownBlock], marker: String, tight: Bool, indent: CGFloat) {
        let markerWidth: CGFloat = marker.last == "." ? 30 : 22
        if case .paragraph(let inline) = blocks.first?.kind {
            let item = NSMutableAttributedString(string: marker + "\t", attributes: style.attributes())
            item.append(style.inline(inline))
            let paragraph = NSMutableParagraphStyle()
            paragraph.firstLineHeadIndent = indent
            paragraph.headIndent = indent + markerWidth
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent + markerWidth)]
            paragraph.lineSpacing = style.markdown.textLineSpacing
            paragraph.paragraphSpacing = tight ? 5 : style.markdown.blockSpacing
            item.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: item.length))
            appendParagraph(item)
            append(Array(blocks.dropFirst()), indent: indent + markerWidth)
        } else {
            appendParagraph(NSAttributedString(string: marker, attributes: style.attributes(indent: indent)))
            append(blocks, indent: indent + markerWidth)
        }
    }

    private mutating func appendCode(_ code: String, language: String?, indent: CGFloat) {
        // 代码仍是同一份可选文字。页眉用无文字附件留位，复制时不混入语言标签和按钮。
        let header = NSTextAttachment()
        header.bounds = CGRect(x: 0, y: 0, width: 1, height: 38)
        let content = NSMutableAttributedString(attachment: header)
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = indent + 10
        paragraph.headIndent = indent + 10
        paragraph.tailIndent = -10
        paragraph.lineSpacing = 1.5
        paragraph.paragraphSpacing = 0
        let attributes: [NSAttributedString.Key: Any] = [
            .font: style.font(size: 15, code: true),
            .foregroundColor: UIColor(style.markdown.codeForeground),
            .paragraphStyle: paragraph
        ]
        content.append(NSAttributedString(string: "\n" + code.trimmingCharacters(in: .newlines), attributes: attributes))
        content.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: content.length))
        let lastParagraph = paragraph.mutableCopy() as! NSMutableParagraphStyle
        lastParagraph.paragraphSpacing = style.markdown.blockSpacing + 10
        let lastLine = (content.string as NSString).paragraphRange(for: NSRange(location: content.length - 1, length: 0))
        content.addAttribute(.paragraphStyle, value: lastParagraph, range: lastLine)
        appendParagraph(content)
        codeBlocks.append(.init(range: NSRange(location: text.length - content.length, length: content.length), text: code, language: language))
    }
}
