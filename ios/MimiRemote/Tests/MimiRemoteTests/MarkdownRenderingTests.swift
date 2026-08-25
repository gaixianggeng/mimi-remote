import XCTest
@testable import MimiRemote

@MainActor
final class MarkdownRenderingTests: XCTestCase {
    func testMarkdownParserBuildsGFMBlocks() {
        let result = MarkdownParser.shared.parse("""
        # 标题

        这是 **粗体**、`代码`、[链接](https://example.com) 和 ~~删除~~。

        - [x] 已完成
        - [ ] 待处理

        | 名称 | 数量 |
        |:---|---:|
        | Token | 42 |

        > 引用内容

        ```swift
        let value = 1
        ```
        """)

        XCTAssertTrue(result.blocks.contains { block in
            if case let .heading(level, inline) = block.kind {
                return level == 1 && inline.plain == "标题"
            }
            return false
        })
        XCTAssertTrue(result.blocks.contains { block in
            if case let .taskList(items) = block.kind {
                return items.map(\.checked) == [true, false]
            }
            return false
        })
        XCTAssertTrue(result.blocks.contains { block in
            if case let .table(header, rows, alignments) = block.kind {
                return header.map(\.plain) == ["名称", "数量"]
                    && rows.first?.map(\.plain) == ["Token", "42"]
                    && alignments == [.leading, .trailing]
            }
            return false
        })
        XCTAssertTrue(result.blocks.contains { block in
            if case let .codeBlock(language, code) = block.kind {
                return language == "swift" && code.contains("let value = 1")
            }
            return false
        })
    }

    func testDisallowedLinksRenderAsPlainText() {
        let result = MarkdownParser.shared.parse("[危险](javascript:alert(1)) 和 [安全](mailto:hello@example.com)")
        let paragraph = result.blocks.compactMap { block -> MarkdownInlineText? in
            if case let .paragraph(inline) = block.kind {
                return inline
            }
            return nil
        }.first

        let inline = try! XCTUnwrap(paragraph)
        XCTAssertEqual(inline.plain, "危险 和 安全")
        XCTAssertTrue(inline.hasFormatting)
        XCTAssertTrue(inline.attributed.runs.contains { $0.link?.scheme == "mailto" })
        XCTAssertFalse(inline.attributed.runs.contains { $0.link?.scheme == "javascript" })
    }

    func testCrossSessionLinearURLLabelCompactsToIssueIdentifier() throws {
        let result = MarkdownParser.shared.parse(
            "[https://linear.app/code89757/issue/MIM-24/example](https://linear.app/code89757/issue/MIM-24/example) 帮我继续修复。"
        )
        let inline = try XCTUnwrap(result.blocks.compactMap { block -> MarkdownInlineText? in
            if case let .paragraph(inline) = block.kind {
                return inline
            }
            return nil
        }.first)

        XCTAssertEqual(inline.plain, "MIM-24 帮我继续修复。")
        XCTAssertTrue(inline.attributed.runs.contains { run in
            run.link?.absoluteString.contains("/issue/MIM-24/") == true
        })
    }

    func testLocalSkillMarkdownLinkKeepsNameWithoutExposingPath() throws {
        let result = MarkdownParser.shared.parse(
            "[$delegate-to-chatgpt-pro](/Users/demo/.codex/skills/delegate-to-chatgpt-pro/SKILL.md)"
        )
        let inline = try XCTUnwrap(result.blocks.compactMap { block -> MarkdownInlineText? in
            if case let .paragraph(inline) = block.kind {
                return inline
            }
            return nil
        }.first)

        XCTAssertEqual(inline.plain, "$delegate-to-chatgpt-pro")
        XCTAssertFalse(inline.plain.contains("/Users/"))
        XCTAssertFalse(inline.attributed.runs.contains { $0.link != nil })
    }

    func testConversationPresentationRemovesInternalGitDirectives() {
        let content = """
        已提交并推送完成。

        ::git-stage{cwd="/Users/demo/repo"}
        ::git-commit{cwd="/Users/demo/repo"}
        ::git-push{cwd="/Users/demo/repo" branch="codex/mim-24-fix"}
        """

        XCTAssertEqual(
            ConversationMarkdownPresentation.displayContent(from: content),
            "已提交并推送完成。"
        )
    }

    func testConversationPresentationOnlyPromotesUserTextContainingMarkdownLinks() {
        XCTAssertTrue(
            ConversationMarkdownPresentation.containsLink(
                in: "[MIM-24](https://linear.app/code89757/issue/MIM-24/example)"
            )
        )
        XCTAssertFalse(ConversationMarkdownPresentation.containsLink(in: "普通用户消息保持原有气泡排版"))
        XCTAssertFalse(ConversationMarkdownPresentation.containsLink(in: "这里讨论的是 ]( 两个 Markdown 符号"))
    }

    func testCrossSessionOriginUsesStrongLegacyHandoffSignature() {
        let generated = """
        [https://linear.app/example](https://linear.app/example) 继续处理。
        [$delegate](/Users/demo/.codex/skills/delegate/SKILL.md)
        """

        XCTAssertTrue(
            ConversationOriginPresentation.isCreatedFromAnotherConversation(
                session: nil,
                initialUserContent: generated
            )
        )
        XCTAssertFalse(
            ConversationOriginPresentation.isCreatedFromAnotherConversation(
                session: nil,
                initialUserContent: "[MIM-24](https://linear.app/example) 请检查这个问题。"
            )
        )
        XCTAssertFalse(
            ConversationOriginPresentation.isCreatedFromAnotherConversation(
                session: nil,
                initialUserContent: "[$delegate](/Users/demo/.codex/skills/delegate/SKILL.md)"
            )
        )
    }

    func testCrossSessionOriginPrefersParentThreadMetadata() {
        let session = AgentSession(
            id: "child-thread",
            projectID: "project",
            project: "Project",
            dir: "/tmp/project",
            title: "Child",
            status: "history",
            source: "codex",
            resumeID: "child-thread",
            createdAt: nil,
            updatedAt: nil,
            parentThreadID: "parent-thread"
        )

        XCTAssertTrue(
            ConversationOriginPresentation.isCreatedFromAnotherConversation(
                session: session,
                initialUserContent: "普通首条消息"
            )
        )
    }

    func testConversationPresentationPreservesGitDirectiveExamplesInsideCodeFence() {
        let content = """
        示例：

        ```text
        ::git-stage{cwd="/Users/demo/repo"}
        ```
        """

        XCTAssertEqual(ConversationMarkdownPresentation.displayContent(from: content), content)
    }

    func testConversationPresentationPreservesIndentedGitDirectiveExample() {
        let content = "示例：\n\n    ::git-stage{cwd=\"/Users/demo/repo\"}"

        XCTAssertEqual(ConversationMarkdownPresentation.displayContent(from: content), content)
    }

    func testConversationPresentationRemovesSameLineGitDirectivesAndTrailingWhitespace() {
        let content = """
        已提交并推送完成。

        ::git-stage{cwd="/Users/demo/repo"} ::git-commit{cwd="/Users/demo/repo"} ::git-push{cwd="/Users/demo/repo" branch="codex/mim-64-fix"}


        """

        XCTAssertEqual(
            ConversationMarkdownPresentation.displayContent(from: content),
            "已提交并推送完成。"
        )
    }

    func testConversationPresentationRemovesInlineAndIncompleteStreamingGitDirectives() {
        XCTAssertEqual(
            ConversationMarkdownPresentation.displayContent(
                from: "已完成。 ::git-stage{cwd=\"/Users/demo/repo\"}"
            ),
            "已完成。"
        )
        XCTAssertEqual(
            ConversationMarkdownPresentation.displayContent(
                from: "已完成。\n\n::git-push{cwd=\"/Users/demo/repo"
            ),
            "已完成。"
        )
    }

    func testConversationPresentationPreservesInlineAndLongFenceGitDirectiveExamples() {
        let inline = "示例：`::git-stage{cwd=\"/Users/demo/repo\"}`"
        XCTAssertEqual(ConversationMarkdownPresentation.displayContent(from: inline), inline)

        let fenced = """
        ````text
        ```text
        ::git-stage{cwd="/Users/demo/repo"}
        ```
        ````
        """
        XCTAssertEqual(ConversationMarkdownPresentation.displayContent(from: fenced), fenced)
    }

    func testConversationPresentationPreservesUnsupportedGitDirective() {
        let content = "::git-reset{cwd=\"/Users/demo/repo\"}"

        XCTAssertEqual(ConversationMarkdownPresentation.displayContent(from: content), content)
    }

    func testStandaloneImageKeepsRenderableReference() {
        let result = MarkdownParser.shared.parse("![架构图](/Users/me/project/diagram.png \"当前方案\")")
        let image = result.blocks.compactMap { block -> MarkdownImageReference? in
            if case let .image(reference) = block.kind {
                return reference
            }
            return nil
        }.first

        let reference = try! XCTUnwrap(image)
        XCTAssertEqual(reference.source, "/Users/me/project/diagram.png")
        XCTAssertEqual(reference.altText, "架构图")
        XCTAssertEqual(reference.title, "当前方案")
        XCTAssertEqual(reference.displayText, "架构图")
    }

    func testInlineImageFallsBackToText() {
        let result = MarkdownParser.shared.parse("参考 ![](/tmp/screen.png) 继续分析")
        let paragraph = result.blocks.compactMap { block -> MarkdownInlineText? in
            if case let .paragraph(inline) = block.kind {
                return inline
            }
            return nil
        }.first

        let inline = try! XCTUnwrap(paragraph)
        XCTAssertEqual(inline.plain, "参考 /tmp/screen.png 继续分析")
    }

    func testImageReferenceDetectorOnlyReturnsImagePaths() {
        let references = ConversationFileReferenceDetector.imageReferences(in: """
        看 /repo/screen.png 和 /repo/report.pdf，再对比 file:///repo/nested/photo.webp。
        ## photo one.jpeg: /Users/me/Pictures/Photos Library.photoslibrary/resources/derivatives/2/photo one.jpeg
        """)

        XCTAssertEqual(references.map(\.path), [
            "/repo/screen.png",
            "/repo/nested/photo.webp",
            "/Users/me/Pictures/Photos Library.photoslibrary/resources/derivatives/2/photo one.jpeg"
        ])
        XCTAssertEqual(references.map(\.name), ["screen.png", "photo.webp", "photo one.jpeg"])
    }

    func testMixedAndOrderedTaskItemsKeepCheckboxState() {
        let result = MarkdownParser.shared.parse("""
        - [x] 已完成
        - 普通项

        1. [ ] 有序待办
        2. 普通有序
        """)

        let bulletList = result.blocks.compactMap { block -> [MarkdownListItem]? in
            if case let .bulletList(items, _) = block.kind {
                return items
            }
            return nil
        }.first
        let orderedList = result.blocks.compactMap { block -> [MarkdownListItem]? in
            if case let .orderedList(_, items, _) = block.kind {
                return items
            }
            return nil
        }.first

        XCTAssertEqual(bulletList?.map(\.checkbox), [true, nil])
        XCTAssertEqual(orderedList?.map(\.checkbox), [false, nil])
    }

    func testStreamingCacheConvergesToFullMarkdownParse() {
        let target = """
        ## 步骤

        1. 准备 **输入**
        2. 输出表格

        | Key | Value |
        |---|---:|
        | latency | 12 |

        ```go
        fmt.Println("ok")
        ```
        """
        let streamingCache = MessageRenderPlanCache(limit: 8)
        var streamingMessage = ConversationMessage(
            stableID: "assistant:streaming-markdown",
            role: .assistant,
            content: "",
            sendStatus: .sending
        )
        var streamingPlan = streamingCache.plan(for: streamingMessage)

        for character in target {
            streamingMessage.content.append(character)
            streamingPlan = streamingCache.plan(for: streamingMessage)
        }

        let fullMessage = ConversationMessage(
            stableID: "assistant:full-markdown",
            role: .assistant,
            content: target
        )
        let fullPlan = MessageRenderPlanCache(limit: 8).plan(for: fullMessage)

        XCTAssertGreaterThan(streamingCache.incrementalReuseCountForTesting, 0)
        XCTAssertEqual(streamingPlan.blocks, fullPlan.blocks)
    }

    func testStreamingCacheReparsesLooseListTailUntilSealed() {
        let prefix = """
        说明

        - 第一项

        """
        let suffix = """
          续写内容
        - 第二项
        """
        let target = prefix + suffix
        let cache = MessageRenderPlanCache(limit: 8)
        var message = ConversationMessage(
            stableID: "assistant:streaming-loose-list",
            role: .assistant,
            content: prefix,
            sendStatus: .sending
        )

        var streamingPlan = cache.plan(for: message)
        XCTAssertEqual(streamingPlan.openTailByteOffset, "说明\n\n".utf8.count)

        for character in suffix {
            message.content.append(character)
            streamingPlan = cache.plan(for: message)
        }

        let fullMessage = ConversationMessage(
            stableID: "assistant:full-loose-list",
            role: .assistant,
            content: target
        )
        let fullPlan = MessageRenderPlanCache(limit: 8).plan(for: fullMessage)

        XCTAssertEqual(streamingPlan.blocks, fullPlan.blocks)
        XCTAssertTrue(streamingPlan.blocks.contains { block in
            guard case let .bulletList(items, _) = block.kind else {
                return false
            }
            guard items.count == 2 else {
                return false
            }
            let firstItemText = items[0].blocks.map(\.plainTextForTesting).joined(separator: "\n")
            return firstItemText.contains("第一项")
                && firstItemText.contains("续写内容")
        })
    }

    func testRenderPlanCacheEvictsByContentByteBudget() {
        let cache = MessageRenderPlanCache(limit: 8, byteLimit: 12)
        _ = cache.plan(messageKey: "first", content: "12345678", contentDigest: 1, contentByteCount: 8)
        _ = cache.plan(messageKey: "second", content: "abcdefgh", contentDigest: 2, contentByteCount: 8)

        XCTAssertEqual(cache.cachedPlanCountForTesting, 1)
        XCTAssertLessThanOrEqual(cache.cachedContentByteCountForTesting, 12)
    }

    func testLongPlainStreamingMessageDefersRepeatedMarkdownParsingUntilCompletion() {
        let cache = MessageRenderPlanCache(limit: 8, streamingPlainTextThreshold: 4 * 1_024)
        var message = ConversationMessage(
            stableID: "assistant:long-plain-stream",
            role: .assistant,
            content: String(repeating: "a", count: 4 * 1_024),
            sendStatus: .sending
        )

        _ = cache.plan(for: message)
        XCTAssertEqual(cache.markdownParseInvocationCountForTesting, 1)

        var streamingPlan = cache.plan(for: message)
        for _ in 0..<32 {
            message.appendContent(String(repeating: "b", count: 128))
            streamingPlan = cache.plan(for: message)
        }

        XCTAssertEqual(cache.markdownParseInvocationCountForTesting, 1)
        XCTAssertTrue(streamingPlan.isProvisionalPlainStreaming)
        XCTAssertEqual(streamingPlan.blocks.first?.plainTextForTesting, message.content)

        message.sendStatus = .confirmed
        let completedPlan = cache.plan(for: message)
        let independentlyParsed = MessageRenderPlanCache(limit: 2).plan(for: message)

        XCTAssertEqual(cache.markdownParseInvocationCountForTesting, 2)
        XCTAssertFalse(completedPlan.isProvisionalPlainStreaming)
        XCTAssertEqual(completedPlan.blocks, independentlyParsed.blocks)
    }

    func testLongPlainStreamingMessageReturnsToMarkdownWhenSyntaxAppears() {
        let cache = MessageRenderPlanCache(limit: 8, streamingPlainTextThreshold: 256)
        var message = ConversationMessage(
            stableID: "assistant:plain-to-markdown-stream",
            role: .assistant,
            content: String(repeating: "正文", count: 128),
            sendStatus: .sending
        )

        _ = cache.plan(for: message)
        message.appendContent(String(repeating: "继续", count: 64))
        XCTAssertTrue(cache.plan(for: message).isProvisionalPlainStreaming)

        message.appendContent("\n\n**加粗内容**")
        let syntaxPlan = cache.plan(for: message)
        let independentlyParsed = MessageRenderPlanCache(limit: 2).plan(for: message)

        XCTAssertFalse(syntaxPlan.isProvisionalPlainStreaming)
        XCTAssertEqual(syntaxPlan.blocks, independentlyParsed.blocks)
    }

    func testCompleteProposedPlanWrapperRendersInnerMarkdownOnly() throws {
        let result = MarkdownParser.shared.parse("""
        <proposed_plan>
        ## 修复计划

        1. 确认链路
        2. 补测试
        </proposed_plan>
        """)

        let plan = try XCTUnwrap(result.blocks.first)
        guard case let .proposedPlan(blocks, isComplete) = plan.kind else {
            return XCTFail("完整 proposed_plan 应解析成计划块")
        }
        XCTAssertTrue(isComplete)
        XCTAssertTrue(blocks.contains { block in
            if case let .heading(level, inline) = block.kind {
                return level == 2 && inline.plain == "修复计划"
            }
            return false
        })
        XCTAssertFalse(blocks.map(\.plainTextForTesting).joined(separator: "\n").contains("proposed_plan"))
    }

    func testStreamingProposedPlanWrapperRendersPartialBody() throws {
        let result = MarkdownParser.shared.parse("""
        <proposed_plan>
        - 先修 default mode
        - 再补 UI
        """)

        let plan = try XCTUnwrap(result.blocks.first)
        guard case let .proposedPlan(blocks, isComplete) = plan.kind else {
            return XCTFail("只有 opening tag 时应按流式计划块展示")
        }
        XCTAssertFalse(isComplete)
        XCTAssertTrue(blocks.map(\.plainTextForTesting).joined(separator: "\n").contains("先修 default mode"))
    }

    func testProposedPlanWrapperKeepsMarkdownAfterClosingTag() throws {
        let result = MarkdownParser.shared.parse("""
        <proposed_plan>
        - 第一步
        </proposed_plan>

        后续说明 **继续正常渲染**。
        """)

        XCTAssertEqual(result.blocks.count, 2)
        guard case .proposedPlan = result.blocks[0].kind else {
            return XCTFail("第一块应是计划块")
        }
        guard case let .paragraph(inline) = result.blocks[1].kind else {
            return XCTFail("closing tag 后的内容应作为普通 Markdown")
        }
        XCTAssertEqual(inline.plain, "后续说明 继续正常渲染。")
        XCTAssertTrue(inline.hasFormatting)
    }

    func testInlineOrInvalidProposedPlanTagsFallBackToPlainMarkdown() {
        let inline = MarkdownParser.shared.parse("开始 <proposed_plan> 不应特殊处理 </proposed_plan>")
        XCTAssertFalse(inline.blocks.contains { block in
            if case .proposedPlan = block.kind {
                return true
            }
            return false
        })
        XCTAssertTrue(inline.blocks.map(\.plainTextForTesting).joined(separator: "\n").contains("proposed_plan"))

        let invalid = MarkdownParser.shared.parse("""
        <proposed_plan> 行内正文
        - 普通列表
        </proposed_plan>
        """)
        XCTAssertFalse(invalid.blocks.contains { block in
            if case .proposedPlan = block.kind {
                return true
            }
            return false
        })
    }

    func testMarkdownStyleKeepsConversationTypographyReadableAndScaled() {
        let style = MarkdownStyle.make(role: .assistant, colorScheme: .light, fontScale: 1.2)

        // 正文对齐 iOS .body 的 17pt 阅读档；行距与段间距同步上移，
        // 段落边界仍要比行间距明显一档，否则长回复会糊成一整块。
        XCTAssertEqual(style.blockSpacing, 12)
        XCTAssertEqual(style.textLineSpacing, 5)
        XCTAssertGreaterThan(style.blockSpacing, style.textLineSpacing)
        XCTAssertEqual(style.scaled(17), 20.4, accuracy: 0.001)
    }

    func testStreamingMarkdownPerformanceStaysBoundedForLargeOpenBlocks() {
        let scenarios: [(name: String, content: String, maxSeconds: TimeInterval)] = [
            (
                "long paragraph",
                String(repeating: "这是一段用于模拟长回复的中文说明，包含 **强调** 和 `inline code`。", count: 22),
                4
            ),
            (
                "open code fence",
                "```swift\n" + (0..<32).map { "let value\($0) = \($0)" }.joined(separator: "\n"),
                4
            ),
            (
                "streaming table",
                """
                | 指标 | 数值 | 状态 |
                |---|---:|---|
                """ + "\n" + (0..<18).map { "| latency_\($0) | \($0) | ok |" }.joined(separator: "\n"),
                4
            )
        ]

        for scenario in scenarios {
            let elapsed = elapsedStreamingParseTime(for: scenario.content)
            XCTAssertLessThan(elapsed, scenario.maxSeconds, "\(scenario.name) took \(elapsed)s")
        }
    }

    private func elapsedStreamingParseTime(for content: String) -> TimeInterval {
        let cache = MessageRenderPlanCache(limit: 4)
        var message = ConversationMessage(
            stableID: "assistant:perf:\(UUID().uuidString)",
            role: .assistant,
            content: "",
            sendStatus: .sending
        )

        let start = Date()
        for character in content {
            message.content.append(character)
            _ = cache.plan(for: message)
        }
        return Date().timeIntervalSince(start)
    }
}

private extension MarkdownBlock {
    var plainTextForTesting: String {
        switch kind {
        case let .paragraph(inline), let .heading(_, inline):
            return inline.plain
        case let .bulletList(items, _), let .orderedList(_, items, _):
            return items.flatMap(\.blocks).map(\.plainTextForTesting).joined(separator: "\n")
        case let .taskList(items):
            return items.flatMap(\.blocks).map(\.plainTextForTesting).joined(separator: "\n")
        case let .blockquote(blocks):
            return blocks.map(\.plainTextForTesting).joined(separator: "\n")
        case let .codeBlock(_, code):
            return code
        case let .proposedPlan(blocks, _):
            return blocks.map(\.plainTextForTesting).joined(separator: "\n")
        case let .image(reference):
            return reference.displayText
        case let .table(header, rows, _):
            return (header.map(\.plain) + rows.flatMap { $0.map(\.plain) }).joined(separator: "\n")
        case .thematicBreak:
            return ""
        }
    }
}
