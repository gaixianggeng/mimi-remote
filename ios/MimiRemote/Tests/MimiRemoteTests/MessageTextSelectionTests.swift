import SwiftUI
import UIKit
import XCTest
@testable import MimiRemote

@MainActor
final class MessageTextSelectionTests: XCTestCase {
    private var style: MessageTextStyle {
        MessageTextStyle(markdown: .make(role: .assistant, colorScheme: .light))
    }

    func testRichTextKeepsFormattingAndLinksInOneSelectableDocument() throws {
        let document = markdown("""
        ## 标题

        正文 **重点** 与 [链接](https://example.com)。

        - 第一项
        - 第二项

        ```swift
        let value = 42
        ```
        """)
        let source = document.text.string as NSString
        let boldRange = source.range(of: "重点")
        let boldFont = try XCTUnwrap(document.text.attribute(.font, at: boldRange.location, effectiveRange: nil) as? UIFont)
        XCTAssertTrue(boldFont.fontDescriptor.symbolicTraits.contains(.traitBold))
        let linkRange = source.range(of: "链接")
        XCTAssertEqual(document.text.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL, URL(string: "https://example.com"))
        XCTAssertTrue(source.contains("•\t第一项\n•\t第二项"))
        XCTAssertEqual(document.codeBlocks.count, 1)
        XCTAssertFalse(source.contains("**"))
        XCTAssertFalse(source.contains("```"))
        XCTAssertTrue(MessageTextSelectionPolicy.copyText(document.text.string).contains("let value = 42"))
        XCTAssertFalse(MessageTextSelectionPolicy.copyText(document.text.string).contains("\u{fffc}"))
    }

    func testPlainAndMarkdownParagraphsHaveSameTypography() throws {
        let content = "同样的正文，保持相同的行距。\n第二行继续阅读。"
        let plain = MessageTextDocument.plain(content, style: style)
        let rich = markdown(content)
        let plainParagraph = try XCTUnwrap(plain.text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let richParagraph = try XCTUnwrap(rich.text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(plainParagraph.lineSpacing, richParagraph.lineSpacing)
        XCTAssertEqual(plain.text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont, rich.text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
    }

    func testCopyUsesVisibleBodyWithoutInternalDirectivesOrMarkdownSyntax() {
        let message = ConversationMessage(role: .assistant, content: """
        **已完成**，[说明](https://example.com)。

        ::git-stage{cwd="/tmp/example"}
        """)
        XCTAssertEqual(message.visibleCopyText, "已完成，说明。")
    }

    func testStructuredBlocksKeepTheirOriginalContainers() {
        let blocks = MarkdownParser.shared.parse("""
        > 引用内容

        ---

        | 标题 | 值 |
        | --- | --- |
        | 条目 | 内容 |

        <proposed_plan>
        计划内容
        </proposed_plan>
        """).blocks
        XCTAssertEqual(blocks.count, 4)
        XCTAssertTrue(blocks.allSatisfy { !$0.supportsContinuousTextSelection })
    }

    func testNativeSelectionDoesNotReplaceOrResizeRichContent() {
        let view = MessageTextView()
        let document = markdown("""
        ## 一条回复

        这段正文可以选择其中几个字，气泡和排版保持不变。

        - 选中片段
        - 复制内容

        ```swift
        let message = "Hello"
        ```
        """)
        view.apply(document, style: style)
        let size = view.measuredSize(width: 360, fillsWidth: true)
        view.frame = CGRect(origin: .zero, size: size)
        let window = host(view)
        defer {
            view.resignFirstResponder()
            window.isHidden = true
        }
        view.layoutIfNeeded()
        let originalText = NSAttributedString(attributedString: view.attributedText)
        let originalGlyphBounds = view.layoutManager.usedRect(for: view.textContainer)

        attachImage(of: view, name: "rich-message-before-selection")
        view.beginSelection()
        view.selectedRange = (view.textStorage.string as NSString).range(of: "正文可以选择其中几个字")
        view.layoutIfNeeded()

        XCTAssertTrue(view.isSelectingMessageText)
        XCTAssertFalse(view.isEditable)
        XCTAssertTrue(view.attributedText.isEqual(to: originalText))
        XCTAssertEqual(view.measuredSize(width: 360, fillsWidth: true), size)
        XCTAssertEqual(view.layoutManager.usedRect(for: view.textContainer), originalGlyphBounds)
        view.copy(nil)
        XCTAssertEqual(UIPasteboard.general.string, "正文可以选择其中几个字")
        attachImage(of: view, name: "rich-message-during-selection")
    }

    func testStreamingAppendPreservesSelectionAndReceivesNewText() {
        let view = MessageTextView()
        let initial = "正文里有 🌿 和需要复制的片段。"
        view.apply(.plain(initial, style: style), style: style)
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 200)
        let window = host(view)
        defer {
            view.resignFirstResponder()
            window.isHidden = true
        }
        view.beginSelection()
        let range = (initial as NSString).range(of: "需要复制的片段")
        view.selectedRange = range

        view.apply(.plain(initial + "\n后续内容继续生成。", style: style), style: style)

        XCTAssertTrue(view.isSelectingMessageText)
        XCTAssertEqual(view.selectedRange, range)
        XCTAssertTrue(view.text.contains("后续内容继续生成"))
        view.copy(nil)
        XCTAssertEqual(UIPasteboard.general.string, "需要复制的片段")
    }

    func testReplacingSelectedContentDismissesSelectionInsteadOfCopyingWrongRange() {
        let view = MessageTextView()
        view.apply(.plain("原本选中的文字", style: style), style: style)
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 200)
        let window = host(view)
        defer {
            view.resignFirstResponder()
            window.isHidden = true
        }
        view.beginSelection()
        view.selectedRange = NSRange(location: 2, length: 3)

        view.apply(.plain("已替换正文", style: style), style: style)

        XCTAssertFalse(view.isSelectingMessageText)
        XCTAssertFalse(view.isSelectable)
    }

    func testSelectionCanCrossParagraphListAndCodeWithoutCopyingCodeHeader() {
        let document = markdown("开头正文。\n\n- 列表内容\n\n```swift\nlet value = 1\n```")
        let view = MessageTextView()
        view.apply(document, style: style)
        view.isSelectable = true
        view.selectedRange = NSRange(location: 0, length: view.textStorage.length)
        view.copy(nil)
        XCTAssertEqual(UIPasteboard.general.string, "开头正文。\n•\t列表内容\nlet value = 1")
    }

    func testShortUserTextKeepsContentSizedBubble() {
        let view = MessageTextView()
        view.apply(.plain("好的", style: style), style: style)
        let size = view.measuredSize(width: 360, fillsWidth: false)
        XCTAssertLessThan(size.width, 100)
        XCTAssertGreaterThan(size.height, 15)
    }

    func testSelectionFromCodeHeaderStartsAtVisibleWord() {
        let view = MessageTextView()
        view.apply(markdown("```swift\nlet value = 1\n```"), style: style)
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 150)
        let window = host(view)
        defer {
            view.resignFirstResponder()
            window.isHidden = true
        }
        view.beginSelection()
        view.copy(nil)
        XCTAssertEqual(UIPasteboard.general.string, "let")
    }

    private func markdown(_ source: String) -> MessageTextDocument {
        .markdown(MarkdownParser.shared.parse(source).blocks, style: style)
    }

    private func host(_ view: UIView) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.addSubview(view)
        controller.view.layoutIfNeeded()
        return window
    }

    private func attachImage(of view: UIView, name: String) {
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            UIColor.systemBackground.setFill()
            UIRectFill(view.bounds)
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
