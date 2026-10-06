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

    func testMessageMenuLiftFollowsPresentationWithoutChangingTextLayout() {
        let view = MessageTextView()
        let document = markdown("正文 **保持排版**，只让消息表面浮起。")
        view.apply(document, style: style)
        let originalSize = view.measuredSize(width: 360, fillsWidth: true)
        let originalText = NSAttributedString(attributedString: view.attributedText)
        var presentations: [Bool] = []
        view.messageActions = MessageTextActions(copyText: "正文", menuPresentationChanged: { presentations.append($0) })
        let interaction = UIEditMenuInteraction(delegate: view)
        let configuration = UIEditMenuConfiguration(identifier: nil, sourcePoint: .zero)

        view.editMenuInteraction(interaction, willPresentMenuFor: configuration, animator: ImmediateMenuAnimator())
        XCTAssertEqual(presentations, [true])
        XCTAssertTrue(view.attributedText.isEqual(to: originalText))
        XCTAssertEqual(view.measuredSize(width: 360, fillsWidth: true), originalSize)

        view.editMenuInteraction(interaction, willDismissMenuFor: configuration, animator: ImmediateMenuAnimator())
        XCTAssertEqual(presentations, [true, false])
        XCTAssertFalse(view.isSelectingMessageText)
    }

    func testEnteringSelectionSettlesLiftAndDoesNotLiftFragmentMenu() {
        let view = MessageTextView()
        view.apply(.plain("选择正文片段", style: style), style: style)
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 150)
        let window = host(view)
        defer {
            view.resignFirstResponder()
            window.isHidden = true
        }
        var presentations: [Bool] = []
        view.messageActions = MessageTextActions(copyText: "选择正文片段", menuPresentationChanged: { presentations.append($0) })
        let interaction = UIEditMenuInteraction(delegate: view)
        let configuration = UIEditMenuConfiguration(identifier: nil, sourcePoint: .zero)

        view.editMenuInteraction(interaction, willPresentMenuFor: configuration, animator: ImmediateMenuAnimator())
        view.beginSelection()
        view.editMenuInteraction(interaction, willPresentMenuFor: configuration, animator: ImmediateMenuAnimator())

        XCTAssertEqual(presentations, [true, false])
        XCTAssertTrue(view.isSelectingMessageText)
    }

    func testRemovingMessageViewResetsMenuLift() {
        let view = MessageTextView()
        let window = host(view)
        defer { window.isHidden = true }
        var presentations: [Bool] = []
        view.messageActions = MessageTextActions(copyText: "正文", menuPresentationChanged: { presentations.append($0) })
        view.editMenuInteraction(
            UIEditMenuInteraction(delegate: view),
            willPresentMenuFor: UIEditMenuConfiguration(identifier: nil, sourcePoint: .zero),
            animator: ImmediateMenuAnimator()
        )

        view.removeFromSuperview()

        XCTAssertEqual(presentations, [true, false])
    }

    private final class ImmediateMenuAnimator: NSObject, UIEditMenuInteractionAnimating {
        func addAnimations(_ animations: @escaping () -> Void) { animations() }
        func addCompletion(_ completion: @escaping () -> Void) { completion() }
    }

    func testMenuLiftMovesOnlyDisplayAndRespectsReducedMotion() async throws {
        let resting = try await liftedTextFrame(isPresented: false, reduceMotion: false)
        let lifted = try await liftedTextFrame(isPresented: true, reduceMotion: false)
        let reduced = try await liftedTextFrame(isPresented: true, reduceMotion: true)

        XCTAssertLessThan(lifted.minY, resting.minY)
        XCTAssertGreaterThan(lifted.width, resting.width)
        XCTAssertLessThanOrEqual(lifted.width - resting.width, 8.1)
        XCTAssertEqual(reduced.minY, resting.minY, accuracy: 0.1)
        XCTAssertEqual(reduced.width, resting.width, accuracy: 0.1)
    }

    private func liftedTextFrame(isPresented: Bool, reduceMotion: Bool) async throws -> CGRect {
        let suite = "MessageMenuLiftTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = MessagePlainText(text: "消息浮起时保持原有排版。", style: style.markdown, fillsWidth: true)
            .frame(width: 300, height: 60)
            .modifier(MessageMenuLift(isPresented: isPresented, role: .assistant, reduceMotion: reduceMotion))
            .environmentObject(ThemeStore(defaults: defaults))
        let controller = UIHostingController(rootView: root)
        controller.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        controller.view.layoutIfNeeded()
        let textView = try XCTUnwrap(messageTextView(in: controller.view))
        return textView.convert(textView.bounds, to: window)
    }

    private func messageTextView(in view: UIView) -> MessageTextView? {
        if let text = view as? MessageTextView { return text }
        return view.subviews.lazy.compactMap { self.messageTextView(in: $0) }.first
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
