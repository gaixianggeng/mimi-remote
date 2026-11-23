import SwiftUI
import UIKit
import XCTest
@testable import MimiRemote

@MainActor
final class MessageTextSelectionTests: XCTestCase {
    func testLongHistoryAnswerKeepsCompleteTextAndReportsRenderingCost() {
        for repetitions in [40, 320] {
            let content = String(repeating: "## 一段较长的回复\n\n这里保留完整的说明、**重点**和[链接](https://example.com)，用于检查长回答的首次解析与布局。\n\n- 第一个步骤\n- 第二个步骤\n\n```swift\nlet message = \"完整内容 🌿\"\n```\n\n", count: repetitions) + "最终答案结束标记"
            let start = ProcessInfo.processInfo.systemUptime
            let blocks = MarkdownParser.shared.parse(content).blocks
            let parsedAt = ProcessInfo.processInfo.systemUptime
            let document = MessageTextDocument.markdown(blocks, style: style)
            let builtAt = ProcessInfo.processInfo.systemUptime
            let view = MessageTextView()
            view.apply(document, style: style)
            let size = view.measuredSize(width: 360, fillsWidth: true)
            let laidOutAt = ProcessInfo.processInfo.systemUptime
            XCTAssertTrue(document.text.string.hasSuffix("最终答案结束标记"))
            XCTAssertEqual(document.codeBlocks.count, repetitions)
            XCTAssertTrue(size.height.isFinite && size.height > 0)
            print("History answer fixture: bytes=\(content.utf8.count), parse=\(parsedAt - start)s, document=\(builtAt - parsedAt)s, layout=\(laidOutAt - builtAt)s")
        }
    }

    func testRepeatedContentKeepsSelectionAndStyleChangesStillRebuildText() throws {
        let view = MessageTextView()
        let content = MessageTextContent.markdown(MarkdownParser.shared.parse("正文 **重点** 与[链接](https://example.com)。").blocks)
        view.apply(content: content, style: style)
        let originalSize = view.measuredSize(width: 360, fillsWidth: true)
        view.frame = CGRect(origin: .zero, size: originalSize)
        let window = host(view)
        defer { view.resignFirstResponder(); window.isHidden = true }
        view.beginSelection()
        let selection = NSRange(location: 0, length: 2)
        view.selectedRange = selection
        view.apply(content: content, style: style)
        XCTAssertEqual(view.selectedRange, selection)
        XCTAssertTrue(view.isSelectingMessageText)
        XCTAssertEqual(view.measuredSize(width: 360, fillsWidth: true), originalSize)
        let originalFont = try XCTUnwrap(view.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)

        var enlarged = MessageTextStyle(markdown: .make(role: .assistant, colorScheme: .dark, fontScale: 1.4))
        enlarged.fontPreset = .serif
        view.apply(content: content, style: enlarged)
        let enlargedFont = try XCTUnwrap(view.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertGreaterThan(enlargedFont.pointSize, originalFont.pointSize)
        XCTAssertNotEqual(enlargedFont.fontDescriptor, originalFont.fontDescriptor)
        XCTAssertTrue(view.textStorage.string.contains("重点"))
        view.apply(content: .plain("新会话的正文"), style: enlarged)
        XCTAssertEqual(view.textStorage.string, "新会话的正文", "复用原生视图时不能显示前一条消息")
        XCTAssertFalse(view.isSelectingMessageText)
    }

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

    func testOrderedListMarkersUseSecondaryColorAndHeadingsAddTopSpacing() throws {
        let document = markdown("""
        # 每日摘要

        这是一段导语说明。

        ## AI 资讯

        1. **首个重点结论。** 后接常规字重正文。
        2. **第二条结论。** 序号应当使用次级灰，突出加粗导语。
        """)
        let source = document.text.string as NSString

        let firstHeadingRange = source.range(of: "每日摘要")
        let firstHeadingParagraph = try XCTUnwrap(
            document.text.attribute(.paragraphStyle, at: firstHeadingRange.location, effectiveRange: nil) as? NSParagraphStyle
        )
        let firstHeadingFont = try XCTUnwrap(
            document.text.attribute(.font, at: firstHeadingRange.location, effectiveRange: nil) as? UIFont
        )
        XCTAssertEqual(firstHeadingParagraph.paragraphSpacingBefore, 0, "首行标题不应增加多余顶部留白")
        XCTAssertLessThan(firstHeadingParagraph.paragraphSpacing, style.markdown.blockSpacing)
        XCTAssertTrue(firstHeadingFont.fontDescriptor.symbolicTraits.contains(.traitBold))

        let sectionHeadingRange = source.range(of: "AI 资讯")
        let sectionHeadingParagraph = try XCTUnwrap(
            document.text.attribute(.paragraphStyle, at: sectionHeadingRange.location, effectiveRange: nil) as? NSParagraphStyle
        )
        XCTAssertEqual(sectionHeadingParagraph.paragraphSpacingBefore, 10, "章节二级标题应与上文拉开呼吸间距")

        let markerRange = source.range(of: "1.")
        let markerColor = try XCTUnwrap(
            document.text.attribute(.foregroundColor, at: markerRange.location, effectiveRange: nil) as? UIColor
        )
        let leadRange = source.range(of: "首个重点结论。")
        let leadColor = try XCTUnwrap(
            document.text.attribute(.foregroundColor, at: leadRange.location, effectiveRange: nil) as? UIColor
        )
        let leadFont = try XCTUnwrap(
            document.text.attribute(.font, at: leadRange.location, effectiveRange: nil) as? UIFont
        )
        XCTAssertEqual(markerColor, style.secondaryForeground)
        XCTAssertEqual(leadColor, style.foreground)
        XCTAssertTrue(leadFont.fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    func testMultiDigitOrderedListMarkersKeepBodyOnSameLineAndAlignHangingIndent() throws {
        let sourceMarkdown = """
        98. 检查序号与正文的间距，正文应该保持一致的悬挂缩进。
        99. 第二项验证下一行正文，尤其是文字较多时如何换行。
        100. 三位数字开头的项目需要与上一行正文对齐，并且在折行之后继续维持同一条悬挂缩进基准线。
        """
        let view = MessageTextView()
        let content = MessageTextContent.markdown(MarkdownParser.shared.parse(sourceMarkdown).blocks)
        view.apply(content: content, style: style)
        let size = view.measuredSize(width: 320, fillsWidth: true)
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutIfNeeded()

        let text = view.textStorage.string as NSString
        let range98 = text.range(of: "98.")
        let range99 = text.range(of: "99.")
        let range100 = text.range(of: "100.")
        let range100Body = text.range(of: "三位数字")
        XCTAssertNotEqual(range100.location, NSNotFound)
        XCTAssertNotEqual(range100Body.location, NSNotFound)

        let paragraph98 = try XCTUnwrap(
            view.textStorage.attribute(.paragraphStyle, at: range98.location, effectiveRange: nil) as? NSParagraphStyle
        )
        let paragraph99 = try XCTUnwrap(
            view.textStorage.attribute(.paragraphStyle, at: range99.location, effectiveRange: nil) as? NSParagraphStyle
        )
        let paragraph100 = try XCTUnwrap(
            view.textStorage.attribute(.paragraphStyle, at: range100.location, effectiveRange: nil) as? NSParagraphStyle
        )
        // 同列表内的 98.、99.、100. 必须共享按最大序号宽度计算出的同一悬挂缩进。
        XCTAssertGreaterThan(paragraph100.headIndent, 30, "三位序号列宽必须超过旧固定 30pt")
        XCTAssertEqual(paragraph98.headIndent, paragraph100.headIndent, accuracy: 0.1)
        XCTAssertEqual(paragraph99.headIndent, paragraph100.headIndent, accuracy: 0.1)

        // 真实排版验证：100. 与其正文首字「三位数字」必须位于同一行，不得被挤到下一行。
        let layoutManager = view.layoutManager
        let glyph100 = layoutManager.glyphIndexForCharacter(at: range100.location)
        let glyph100Body = layoutManager.glyphIndexForCharacter(at: range100Body.location)
        let line100 = layoutManager.lineFragmentRect(forGlyphAt: glyph100, effectiveRange: nil)
        let line100Body = layoutManager.lineFragmentRect(forGlyphAt: glyph100Body, effectiveRange: nil)
        XCTAssertEqual(line100.minY, line100Body.minY, accuracy: 0.5, "三位序号 100. 必须与正文保持同行")

        // 折行续行的首个字形应严格对齐悬挂缩进位置。
        let bodyStartLocation = layoutManager.location(forGlyphAt: glyph100Body)
        XCTAssertEqual(bodyStartLocation.x, paragraph100.headIndent, accuracy: 1.5, "正文起点应对齐列表 tabStop 悬挂缩进")
    }

    func testOrderedAndBulletListMarkersAdaptWidthAtLargeFontScale() throws {
        let largeStyle = MessageTextStyle(
            markdown: .make(role: .assistant, colorScheme: .light, fontScale: 1.6)
        )
        let sourceMarkdown = """
        99. 大字号下两位序号不能把正文挤到下一行。
        100. 大字号下三位序号同样应保持与正文同行并正确对齐。

        - 大字号下无序列表项目符号同样保持同行悬挂缩进。
        """
        let view = MessageTextView()
        let content = MessageTextContent.markdown(MarkdownParser.shared.parse(sourceMarkdown).blocks)
        view.apply(content: content, style: largeStyle)
        let size = view.measuredSize(width: 340, fillsWidth: true)
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutIfNeeded()

        let text = view.textStorage.string as NSString
        let range99 = text.range(of: "99.")
        let range99Body = text.range(of: "大字号下两位")
        let range100 = text.range(of: "100.")
        let range100Body = text.range(of: "大字号下三位")
        let rangeBullet = text.range(of: "•")
        let rangeBulletBody = text.range(of: "大字号下无序")
        XCTAssertNotEqual(range99.location, NSNotFound)
        XCTAssertNotEqual(range100.location, NSNotFound)
        XCTAssertNotEqual(rangeBullet.location, NSNotFound)

        let paragraph100 = try XCTUnwrap(
            view.textStorage.attribute(.paragraphStyle, at: range100.location, effectiveRange: nil) as? NSParagraphStyle
        )
        XCTAssertGreaterThan(paragraph100.headIndent, 50, "1.6x 大字号三位序号列宽应随字形宽度自适应扩大")

        let lm = view.layoutManager
        XCTAssertEqual(
            lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: range99.location), effectiveRange: nil).minY,
            lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: range99Body.location), effectiveRange: nil).minY,
            accuracy: 0.5,
            "大字号下 99. 与正文必须同行"
        )
        XCTAssertEqual(
            lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: range100.location), effectiveRange: nil).minY,
            lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: range100Body.location), effectiveRange: nil).minY,
            accuracy: 0.5,
            "大字号下 100. 与正文必须同行"
        )
        XCTAssertEqual(
            lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: rangeBullet.location), effectiveRange: nil).minY,
            lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: rangeBulletBody.location), effectiveRange: nil).minY,
            accuracy: 0.5,
            "大字号下无序项目符号与正文必须同行"
        )
    }

    func testLongMarkdownAndCompactReturnToTailRenderInPhoneWidth() throws {
        let suiteName = "MessageTextSelectionTests.grokbot.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let themeStore = ThemeStore(defaults: defaults)
        let tokens = themeStore.tokens(for: .light)
        let markdownStyle = MarkdownStyle.make(role: .assistant, colorScheme: .light, tokens: tokens)
        let longReply = """
        **AI 热门资讯和工具日报 · 2026年11月22日**

        这份整理的是过去大约 24 到 36 小时里社区互动比较高的讨论，数字都来自原帖，没经官方确认的传言单独标出来了。

        ## AI 资讯

        1. **模型推理与缓存优化获得开发者积极反馈。** 官方表示新版本主打编程、科学与知识工作，在同类任务上成本降低约 50% 到 80%，[发布说明](https://example.com/release) · [社区点评](https://example.com/discussion)。
        2. **IDE 同步扩大缓存并重置使用额度。** 工程团队表示缓存改进以后，同样的额度能多完成约 22% 的任务，[缓存说明](https://example.com/cache) · [额度重置](https://example.com/quota)。
        3. **多模型对比评测引发持续热议。** 开发者重点关注长上下文代码重构与端侧响应速度。
        """
        let blocks = MarkdownParser.shared.parse(longReply).blocks
        let metrics = ConversationReturnToTailButtonMetrics.resolve(isCompactPhone: true)

        let preview = ZStack(alignment: .bottom) {
            tokens.conversationCanvasBackground.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                Text("\(L10n.text("ui.today")) 10:55")
                    .font(themeStore.uiFont(.caption2, weight: .medium))
                    .foregroundStyle(tokens.tertiaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                MessageMarkdownBody(blocks: blocks, style: markdownStyle, fillsWidth: true)
                    .environmentObject(themeStore)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 96)

            VStack(spacing: 6) {
                Image(systemName: metrics.symbolName)
                    .font(.system(size: metrics.symbolSize, weight: metrics.symbolWeight))
                    .foregroundStyle(tokens.primaryText)
                    .frame(width: metrics.visualDiameter, height: metrics.visualDiameter)
                    .background { WorkbenchChromeMaterial(shape: Circle(), tokens: tokens) }
                    .overlay { Circle().stroke(Color.black.opacity(0.10), lineWidth: 0.75) }
                    .shadow(color: Color.black.opacity(0.07), radius: 5, y: 2)
                    .frame(width: metrics.hitDiameter, height: metrics.hitDiameter)

                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(tokens.conversationPrimaryText)
                        .frame(width: 34, height: 34)
                        .background(Color.black.opacity(0.055), in: Circle())
                    Text(L10n.format("ui.ask_context_value", "mimi-remote"))
                        .font(themeStore.uiFont(.body))
                        .foregroundStyle(tokens.conversationTertiaryText)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "mic")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(tokens.conversationPrimaryText)
                        .frame(width: 36, height: 36)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(tokens.inputBackground, in: Capsule(style: .continuous))
                .overlay { Capsule(style: .continuous).strokeBorder(Color.black.opacity(0.09), lineWidth: 0.75) }
                .shadow(color: Color.black.opacity(0.06), radius: 6, y: 2)
                .padding(.horizontal, 8)
            }
            .padding(.bottom, 16)
        }
        .frame(width: 402, height: 760)
        .environment(\.colorScheme, .light)

        let controller = UIHostingController(rootView: preview)
        let bounds = CGRect(x: 0, y: 0, width: 402, height: 760)
        controller.view.frame = bounds
        let window = UIWindow(frame: bounds)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()

        let textView = try XCTUnwrap(messageTextView(in: controller.view))
        XCTAssertTrue(textView.textStorage.string.contains("AI 资讯"))
        XCTAssertTrue(textView.textStorage.string.contains("1.\t"))
        attachImage(of: controller.view, name: "grokbot-long-markdown-and-return-to-tail")
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

    func testWrappedInlineCodeInBulletListDoesNotBleedIntoIndentGutter() throws {
        let sample = """
        - 实测 `agy 1.5.11` 的 `Other` 对话（Antigravity Desktop 产生、落盘在 `~/.gemini/antigravity/conversations/<id>.db`）通过 `--app-data-dir antigravity` 可以完整回放历史。
          - 放行 `~/.gemini/antigravity-cli/conversations/<id>.db`（标记 `source: "cli"`）与 `~/.gemini/antigravity/conversations/<id>.db`（标记 `source: { custom: "other" }`）。
        """
        let view = MessageTextView()
        let content = MessageTextContent.markdown(MarkdownParser.shared.parse(sample).blocks)
        view.apply(content: content, style: style)
        let size = view.measuredSize(width: 300, fillsWidth: true)
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutIfNeeded()

        let layout = try XCTUnwrap(view.layoutManager as? InlineCodeLayoutManager)
        let fullGlyphs = layout.glyphRange(for: view.textContainer)
        let rects = layout.inlineCodeBackgroundRects(forGlyphRange: fullGlyphs, at: .zero)
        XCTAssertGreaterThanOrEqual(rects.count, 8, "折行后的行内代码应按行拆成多个紧贴字形的背景胶囊")
        for entry in rects {
            // 第一级列表 headIndent = 22，嵌套列表 headIndent = 44；任何胶囊左缘都不能越过缩进槽贴到 0。
            XCTAssertGreaterThanOrEqual(entry.rect.minX, 19, "行内代码背景不应向左溢出到列表项目符号缩进槽：\(entry.rect)")
            XCTAssertLessThanOrEqual(entry.rect.maxX, 300.5)
        }
        // 验证不存在原始 .backgroundColor（避免 TextKit 默认整行铺底回归）。
        var hasLegacyBackground = false
        view.textStorage.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: view.textStorage.length), options: []) { value, _, _ in
            if value != nil { hasLegacyBackground = true }
        }
        XCTAssertFalse(hasLegacyBackground)
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
