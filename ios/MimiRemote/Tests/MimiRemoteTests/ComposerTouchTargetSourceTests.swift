import XCTest

/// `.frame(width: 44, height: 44)` 只是布局框，不是命中区。
///
/// Button 的命中区取自 label 真正绘制的内容：仓库统一的 `MimiPressButtonStyle` 只做
/// scaleEffect + opacity，`.plain` / `.borderless` 同样不画背景，于是一枚只有图标的按钮
/// 无论把 frame 写多大，可点面积都只有图标字形那么大——ComposerStatusTray 的 disclosure
/// 箭头就这么坏过，实际可点面积约 100pt²，不到声称的 44×44 的 5%。
///
/// 这条守卫扫描 iOS 源码，找出「Button 的 label 声明了 ≥44pt 的 frame，却既没有
/// contentShape 也没有 background，外层也没有由系统画底的 buttonStyle」的写法。
/// 修复方式是给 label 补 `.contentShape(Rectangle())` 或对应圆角形状，而不是加大 frame。
final class ComposerTouchTargetSourceTests: XCTestCase {
    /// 例外表必须精确匹配：新增违规会失败，修好却忘了删例外同样会失败。
    private static let knownPendingViolations: [String: Int] = [:]

    func testButtonLabelsWithLargeFramesDeclareAHitShape() throws {
        let sourceRoot = Self.sourceRoot
        var counts: [String: Int] = [:]
        var violations: [String] = []

        for file in try Self.swiftFiles(in: sourceRoot) {
            let relativePath = file.path.replacingOccurrences(
                of: sourceRoot.path + "/",
                with: ""
            )
            let lines = try String(contentsOf: file, encoding: .utf8)
                .components(separatedBy: .newlines)
                .map(Self.strippingStringsAndComments)
            let scan = Self.buttonLabelBlocks(lines)
            XCTAssertTrue(
                scan.isBalanced,
                "\(relativePath) 的花括号扫描没有归零，命中区守卫无法信任该文件的结果。"
            )

            for block in scan.blocks where !Self.declaresHitShape(lines: lines, block: block) {
                guard let line = Self.firstLargeFrameLine(lines: lines, block: block) else {
                    continue
                }
                counts[relativePath, default: 0] += 1
                violations.append("\(relativePath):\(line + 1)")
            }
        }

        XCTAssertEqual(
            counts,
            Self.knownPendingViolations,
            """
            Button 的 44pt 命中区与实际可点面积不一致。
            当前扫描到的位置：
            \(violations.sorted().joined(separator: "\n"))
            新增位置请给 label 补 .contentShape(...)；已经修好的位置请从 knownPendingViolations 删除。
            """
        )
    }
}

private extension ComposerTouchTargetSourceTests {
    struct ButtonLabelBlock {
        let start: Int
        let end: Int
    }

    static var sourceRoot: URL {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 {
            root.deleteLastPathComponent()
        }
        return root
            .appendingPathComponent("ios")
            .appendingPathComponent("MimiRemote")
            .appendingPathComponent("Sources")
    }

    static func swiftFiles(in root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
    }

    /// 字符串字面量和行注释里的花括号、`.frame(...)` 都不是代码，先抹掉再扫描。
    /// 长度保持不变，行号与列号仍然指向原文件。
    static func strippingStringsAndComments(_ line: String) -> String {
        let characters = Array(line)
        var result = ""
        var isInsideString = false
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if isInsideString {
                if character == "\\" {
                    // 转义序列整体抹掉，避免把 "\\" 的收尾引号误判成转义。
                    result.append(" ")
                    if index + 1 < characters.count {
                        result.append(" ")
                        index += 1
                    }
                } else if character == "\"" {
                    isInsideString = false
                    result.append("\"")
                } else {
                    result.append(" ")
                }
            } else if character == "\"" {
                isInsideString = true
                result.append("\"")
            } else if character == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                break
            } else {
                result.append(character)
            }
            index += 1
        }

        return result
    }

    /// 识别 `Button(action:) { label }` 与 `Button { action } label: { label }` 两种写法。
    /// `refreshButton`、`iconButton` 这类函数名不算 Button 表达式，所以用词边界匹配。
    static func buttonLabelBlocks(_ lines: [String]) -> (blocks: [ButtonLabelBlock], isBalanced: Bool) {
        struct OpenBrace {
            let line: Int
            let isButton: Bool
            let isLabel: Bool
        }

        var stack: [OpenBrace] = []
        var pendingLabelLines: Set<Int> = []
        var blocks: [ButtonLabelBlock] = []

        for (number, line) in lines.enumerated() {
            let characters = Array(line)
            for index in characters.indices {
                switch characters[index] {
                case "{":
                    let header = String(characters[..<index])
                    stack.append(
                        OpenBrace(
                            line: number,
                            isButton: header.range(
                                of: "\\bButton\\b",
                                options: .regularExpression
                            ) != nil,
                            isLabel: header.contains("label:")
                                && pendingLabelLines.contains(number)
                        )
                    )
                case "}":
                    guard let open = stack.popLast() else {
                        return ([], false)
                    }
                    if open.isButton, String(characters[index...]).contains("label:") {
                        // 刚闭合的是 action 闭包，真正的 label 闭包在同一行随后打开。
                        pendingLabelLines.insert(number)
                    } else if open.isButton || open.isLabel {
                        blocks.append(ButtonLabelBlock(start: open.line, end: number))
                    }
                default:
                    continue
                }
            }
        }

        return (blocks, stack.isEmpty)
    }

    /// label 自带背景，或外层用了由系统画底的 buttonStyle 时，背景本身就是命中区。
    static func declaresHitShape(lines: [String], block: ButtonLabelBlock) -> Bool {
        let body = lines[block.start...block.end].joined(separator: "\n")
        if body.contains("contentShape") || body.contains(".background") {
            return true
        }
        return trailingModifiers(lines: lines, after: block.end).contains { modifier in
            modifier.range(
                of: "\\.buttonStyle\\(\\s*\\.(bordered|borderedProminent|glass|glassProminent)",
                options: .regularExpression
            ) != nil
        }
    }

    static func trailingModifiers(lines: [String], after end: Int) -> [String] {
        var modifiers: [String] = []
        var index = end + 1

        while index < lines.count, index <= end + 20 {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            index += 1
            if trimmed.isEmpty {
                continue
            }
            guard trimmed.hasPrefix(".") else {
                break
            }
            modifiers.append(trimmed)
        }

        return modifiers
    }

    static func firstLargeFrameLine(lines: [String], block: ButtonLabelBlock) -> Int? {
        for number in block.start...block.end {
            guard lines[number].trimmingCharacters(in: .whitespaces).hasPrefix(".frame(") else {
                continue
            }
            guard let arguments = frameArguments(lines: lines, startingAt: number) else {
                continue
            }
            if declaresLargeDimension(arguments) {
                return number
            }
        }
        return nil
    }

    /// 取出 `.frame(...)` 的实参文本，按括号配平跨行，避免把后一个修饰器的数字算进来。
    static func frameArguments(lines: [String], startingAt line: Int) -> String? {
        guard let start = lines[line].range(of: ".frame(") else {
            return nil
        }

        var depth = 1
        var text = ""
        var current = line
        var segment = String(lines[line][start.upperBound...])

        while current < lines.count, current < line + 6 {
            for character in segment {
                if character == "(" {
                    depth += 1
                } else if character == ")" {
                    depth -= 1
                    if depth == 0 {
                        return text
                    }
                }
                text.append(character)
            }
            current += 1
            if current < lines.count {
                segment = lines[current]
            }
        }

        return nil
    }

    static func declaresLargeDimension(_ arguments: String) -> Bool {
        let pattern = "(?:minWidth|minHeight|width|height):\\s*([0-9]+)"
        var searchRange = arguments.startIndex..<arguments.endIndex

        while let match = arguments.range(
            of: pattern,
            options: .regularExpression,
            range: searchRange
        ) {
            let value = arguments[match]
                .split(separator: ":")
                .last
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .flatMap(Int.init)
            if let value, value >= 44 {
                return true
            }
            searchRange = match.upperBound..<arguments.endIndex
        }

        return false
    }
}
