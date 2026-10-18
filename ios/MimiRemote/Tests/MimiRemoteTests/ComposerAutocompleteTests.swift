import XCTest
@testable import MimiRemote

/// `/` 命令菜单与 `$` 技能补全的触发、替换范围和排序（#765）。
final class ComposerAutocompleteTests: XCTestCase {
    func testSlashOpensOnlyForFirstWordOfDraft() throws {
        let empty = try XCTUnwrap(match("/"))
        XCTAssertEqual(empty.trigger, .command)
        XCTAssertEqual(empty.query, "")

        let typed = try XCTUnwrap(match("  /mo"))
        XCTAssertEqual(typed.query, "mo")
        XCTAssertEqual(typed.replacementRange, NSRange(location: 2, length: 3))

        XCTAssertEqual(match("\n/权限")?.query, "权限", "前导空行不算正文")
        XCTAssertNil(match("修复 /plan"), "正文中部的 / 不弹菜单")
        XCTAssertNil(match("第一行\n/plan"), "第二行的 / 不弹菜单")
    }

    func testSlashIgnoresPathsAndUrls() {
        XCTAssertNil(match("/tmp/file"))
        XCTAssertNil(match("/tmp/file", cursor: 4), "光标停在路径前半段也按整个词判断")
        XCTAssertNil(match("//"))
        XCTAssertNil(match("https://example.com"))
        XCTAssertNil(match("src/file"))
    }

    func testSlashReplacesWholeWordAndOneTrailingSpace() throws {
        let text = "/model 继续修复"
        let query = try XCTUnwrap(match(text, cursor: 3))
        XCTAssertEqual(query.query, "mo")
        XCTAssertEqual((text as NSString).substring(with: query.replacementRange), "/model ")

        let atEnd = "/plan"
        XCTAssertEqual(try XCTUnwrap(match(atEnd)).replacementRange, NSRange(location: 0, length: 5))
    }

    func testSlashSkipsSelectionAndEmojiKeepsUtf16Ranges() throws {
        XCTAssertNil(ComposerSkillQuery.match(text: "/plan", selectedRange: NSRange(location: 0, length: 2)))

        let text = "/😀 继续"
        let query = try XCTUnwrap(match(text, cursor: ("/😀" as NSString).length))
        XCTAssertEqual(query.query, "😀")
        XCTAssertEqual((text as NSString).substring(with: query.replacementRange), "/😀 ")
    }

    func testDollarTriggerKeepsSkillSemantics() throws {
        let text = "请检查 $apple"
        let query = try XCTUnwrap(match(text))
        XCTAssertEqual(query.trigger, .skill)
        XCTAssertEqual(query.query, "apple")
        XCTAssertEqual((text as NSString).substring(with: query.replacementRange), "$apple")
    }

    func testRankingPrefersNamePrefixThenNameThenDescription() {
        let suggestions: [ComposerAutocompleteSuggestion] = [
            .command(command("model", title: "切换模型", detail: "切换模型与推理强度")),
            .command(command("permissions", title: "完全访问", detail: "允许访问整个文件系统")),
            .command(command("plan", title: "计划模式", detail: "下一条消息先生成计划")),
            .command(command("compact", title: "压缩上下文", detail: "腾出上下文空间")),
        ]

        XCTAssertEqual(ids(ComposerAutocompleteRanking.rank(suggestions, query: "p")), [
            "command:permissions", "command:plan", "command:compact",
        ])
        XCTAssertEqual(ids(ComposerAutocompleteRanking.rank(suggestions, query: "完全")), ["command:permissions"])
        XCTAssertEqual(ids(ComposerAutocompleteRanking.rank(suggestions, query: "上下文")), ["command:compact"])
        XCTAssertEqual(ComposerAutocompleteRanking.rank(suggestions, query: " ").count, 4, "空查询保留原顺序")
        XCTAssertTrue(ComposerAutocompleteRanking.rank(suggestions, query: "zzz").isEmpty)
    }

    func testRankingMatchesSkillsByNameOnly() {
        let skill = SkillCapability(
            name: "apple-design",
            description: "Review layouts",
            scope: "user",
            path: "/skills/apple-design/SKILL.md",
            enabled: true,
            displayName: "Apple Design"
        )
        let suggestions: [ComposerAutocompleteSuggestion] = [.skill(skill)]

        XCTAssertEqual(ComposerAutocompleteRanking.rank(suggestions, query: "APPLE").count, 1)
        XCTAssertEqual(ComposerAutocompleteRanking.rank(suggestions, query: "design").count, 1)
        XCTAssertTrue(
            ComposerAutocompleteRanking.rank(suggestions, query: "layouts").isEmpty,
            "技能保持 $ 原有的名称匹配范围，不按说明匹配"
        )
    }

    func testPermissionCommandsHaveDistinctIdentities() {
        let ids = ComposerPermissionMode.allCases.map { mode in
            ComposerSlashCommand(
                action: .permission(mode),
                name: "permissions",
                title: mode.rawValue,
                detail: "",
                systemImage: mode.systemImage
            ).id
        }
        XCTAssertEqual(Set(ids).count, ComposerPermissionMode.allCases.count)
    }

    private func match(_ text: String, cursor: Int? = nil) -> ComposerSkillQuery? {
        ComposerSkillQuery.match(
            text: text,
            selectedRange: NSRange(location: cursor ?? (text as NSString).length, length: 0)
        )
    }

    private func command(_ name: String, title: String, detail: String) -> ComposerSlashCommand {
        ComposerSlashCommand(action: .model, name: name, title: title, detail: detail, systemImage: "cpu")
    }

    private func ids(_ suggestions: [ComposerAutocompleteSuggestion]) -> [String] {
        suggestions.map(\.id)
    }
}
