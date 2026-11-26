import CryptoKit
import Darwin
import Foundation

extension CodexLocalSSHConfigurator {
    // MARK: - Pure Parsing, Formatting & Conflict Detection

    static func computeOpenSSHSHA256Fingerprint(fromKeyBody keyBody: String) -> String? {
        let tokens = keyBody.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count == 2, let keyBlob = Data(base64Encoded: tokens[1]) else {
            return nil
        }
        let digest = SHA256.hash(data: keyBlob)
        let base64 = Data(digest).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:\(base64)"
    }

    static func renderManagedBlock(
        alias: String,
        username: String,
        identityFile: String,
        appendGlobalHostReset: Bool = false
    ) -> String {
        var lines = [
            managedBlockStart,
            "Host \(alias)",
            "    HostName 127.0.0.1",
            "    Port 22",
            "    User \(username)",
            "    IdentityFile \(identityFile)",
            "    IdentitiesOnly yes",
            "    IdentityAgent none",
            "    ProxyJump none",
            "    ProxyCommand none",
            "    ControlMaster no",
            "    ControlPath none",
            "    ControlPersist no",
            "    ForwardAgent no",
            "    CanonicalizeHostname no",
            "    PermitLocalCommand no",
            "    RemoteCommand none",
            "    StrictHostKeyChecking accept-new",
        ]
        if appendGlobalHostReset {
            lines.append("Host *")
        }
        lines.append(managedBlockEnd)
        return lines.joined(separator: "\n")
    }

    static func extractPublicKeyBody(from line: String) -> String? {
        let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count >= 2,
              isKnownSSHKeyType(tokens[0]),
              Data(base64Encoded: tokens[1]) != nil else {
            return nil
        }
        return "\(tokens[0]) \(tokens[1])"
    }

    static func isKnownSSHKeyType(_ token: String) -> Bool {
        guard !token.isEmpty,
              !token.contains("="),
              !token.contains(","),
              !token.contains("\"") else {
            return false
        }
        return token.hasPrefix("ssh-") ||
            token.hasPrefix("ecdsa-sha2-") ||
            token.hasPrefix("sk-ssh-") ||
            token.hasPrefix("sk-ecdsa-")
    }

    /// 按 OpenSSH `authorized_keys` 语法结构化解析单行；空行、注释行或非法行返回 nil。
    static func parseAuthorizedKeyLine(_ rawLine: String) -> ParsedAuthorizedKeyLine? {
        var line = rawLine
        if line.hasSuffix("\r") {
            line.removeLast()
        }
        var index = line.startIndex
        while index < line.endIndex, line[index] == " " || line[index] == "\t" {
            index = line.index(after: index)
        }
        guard index < line.endIndex, line[index] != "#" else { return nil }

        let firstPlainEnd = scanUnquotedTokenEnd(in: line, from: index)
        let firstPlain = String(line[index..<firstPlainEnd])

        var options: [ParsedAuthorizedKeyOption] = []
        var cursor: String.Index
        var keyType: String

        if isKnownSSHKeyType(firstPlain) {
            keyType = firstPlain
            cursor = firstPlainEnd
        } else {
            guard let (parsedOptions, afterOptions) = scanAuthorizedKeyOptions(in: line, from: index) else {
                return nil
            }
            options = parsedOptions
            cursor = afterOptions
            skipHorizontalWhitespace(in: line, cursor: &cursor)
            let typeEnd = scanUnquotedTokenEnd(in: line, from: cursor)
            keyType = String(line[cursor..<typeEnd])
            guard isKnownSSHKeyType(keyType) else { return nil }
            cursor = typeEnd
        }

        skipHorizontalWhitespace(in: line, cursor: &cursor)
        guard cursor < line.endIndex else { return nil }
        let base64End = scanUnquotedTokenEnd(in: line, from: cursor)
        let keyBase64 = String(line[cursor..<base64End])
        guard !keyBase64.isEmpty, Data(base64Encoded: keyBase64) != nil else { return nil }
        cursor = base64End
        skipHorizontalWhitespace(in: line, cursor: &cursor)
        let comment = String(line[cursor..<line.endIndex])

        return ParsedAuthorizedKeyLine(
            options: options,
            keyType: keyType,
            keyBase64: keyBase64,
            comment: comment
        )
    }

    private static func scanUnquotedTokenEnd(in line: String, from start: String.Index) -> String.Index {
        var idx = start
        while idx < line.endIndex, line[idx] != " " && line[idx] != "\t" {
            idx = line.index(after: idx)
        }
        return idx
    }

    private static func skipHorizontalWhitespace(in line: String, cursor: inout String.Index) {
        while cursor < line.endIndex, line[cursor] == " " || line[cursor] == "\t" {
            cursor = line.index(after: cursor)
        }
    }

    private static func scanAuthorizedKeyOptions(
        in line: String,
        from start: String.Index
    ) -> ([ParsedAuthorizedKeyOption], String.Index)? {
        var idx = start
        var inQuotes = false
        var escaped = false
        var rawOptions: [String] = []
        var current = ""

        while idx < line.endIndex {
            let ch = line[idx]
            if inQuotes {
                current.append(ch)
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inQuotes = false
                }
            } else {
                if ch == " " || ch == "\t" {
                    break
                } else if ch == "\"" {
                    inQuotes = true
                    current.append(ch)
                } else if ch == "," {
                    rawOptions.append(current)
                    current = ""
                } else {
                    current.append(ch)
                }
            }
            idx = line.index(after: idx)
        }
        guard !inQuotes, idx < line.endIndex else { return nil }
        rawOptions.append(current)

        var parsed: [ParsedAuthorizedKeyOption] = []
        for item in rawOptions where !item.isEmpty {
            if let eq = item.firstIndex(of: "=") {
                let name = String(item[..<eq]).lowercased()
                let rawVal = String(item[item.index(after: eq)...])
                parsed.append(ParsedAuthorizedKeyOption(name: name, value: unquoteSSHValue(rawVal)))
            } else {
                parsed.append(ParsedAuthorizedKeyOption(name: item.lowercased(), value: nil))
            }
        }
        return (parsed, idx)
    }

    private static func unquoteSSHValue(_ raw: String) -> String {
        guard raw.count >= 2, raw.first == "\"", raw.last == "\"" else { return raw }
        let inner = raw.dropFirst().dropLast()
        var out = ""
        var escaped = false
        for ch in inner {
            if escaped {
                out.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                out.append(ch)
            }
        }
        return out
    }

    struct AuthorizedKeysEvaluation: Equatable {
        let hasValidLoopbackEntry: Bool
        let hasConflict: Bool
        let conflictReason: String?
    }

    static func evaluateAuthorizedKeys(
        content: String,
        keyBody: String,
        recordedEntry: String?
    ) -> AuthorizedKeysEvaluation {
        var hasValidLoopback = false
        for slice in rawLineSlices(in: content) {
            let lineText = String(content[slice.contentRange])
            guard let parsed = parseAuthorizedKeyLine(lineText), parsed.keyBody == keyBody else {
                continue
            }
            if !parsed.isStrictlyLoopbackFrom {
                return AuthorizedKeysEvaluation(
                    hasValidLoopbackEntry: false,
                    hasConflict: true,
                    conflictReason: "发现同一公钥缺少仅限 127.0.0.1/::1 的 from= 限制。"
                )
            }
            if parsed.hasCommandOption {
                return AuthorizedKeysEvaluation(
                    hasValidLoopbackEntry: false,
                    hasConflict: true,
                    conflictReason: "发现同一公钥带有 command= 限制选项。"
                )
            }
            hasValidLoopback = true
        }
        _ = recordedEntry
        return AuthorizedKeysEvaluation(
            hasValidLoopbackEntry: hasValidLoopback,
            hasConflict: false,
            conflictReason: nil
        )
    }

    static func appendAuthorizedKeyEntry(_ entry: String, to existing: String) -> (text: String, addedLeadingNewline: Bool) {
        if existing.isEmpty {
            return (entry + "\n", false)
        }
        if existing.hasSuffix("\n") {
            return (existing + entry + "\n", false)
        }
        return (existing + "\n" + entry + "\n", true)
    }

    static func containsExactLine(_ entry: String, in content: String) -> Bool {
        rawLineSlices(in: content).contains { String(content[$0.contentRange]) == entry }
    }

    /// 仅移除与记录完全匹配且结构校验通过的托管授权行，保留其余所有原始字节（包括 CRLF、空行与用户同公钥条目）。
    static func removeExactAuthorizedKeyEntry(
        _ recordedEntry: String,
        expectedKeyBody: String,
        addedLeadingNewline: Bool,
        from content: String
    ) -> (text: String, removed: Bool) {
        let slices = rawLineSlices(in: content)
        var targetRanges: [Range<String.Index>] = []
        var removedTrailingLineAtEOF = false

        for (idx, slice) in slices.enumerated() {
            let lineText = String(content[slice.contentRange])
            guard lineText == recordedEntry,
                  let parsed = parseAuthorizedKeyLine(lineText),
                  parsed.keyBody == expectedKeyBody,
                  parsed.isStrictlyLoopbackFrom else {
                continue
            }
            targetRanges.append(slice.fullRange)
            if idx == slices.count - 1 {
                removedTrailingLineAtEOF = true
            }
        }

        guard !targetRanges.isEmpty else {
            return (content, false)
        }

        var result = content
        for range in targetRanges.reversed() {
            result.removeSubrange(range)
        }
        if addedLeadingNewline && removedTrailingLineAtEOF && result.hasSuffix("\n") {
            result.removeLast()
        }
        return (result, true)
    }

    // MARK: - Byte-Preserving Line Scanning & Config Block Composition

    struct RawLineSlice {
        /// 含行尾换行符（`\n` 或 `\r\n`）的完整区间。
        let fullRange: Range<String.Index>
        /// 不含行尾 `\r\n` 或 `\n` 的行内容区间。
        let contentRange: Range<String.Index>
    }

    static func rawLineSlices(in text: String) -> [RawLineSlice] {
        guard !text.isEmpty else { return [] }
        var slices: [RawLineSlice] = []
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let lineStart = cursor
            while cursor < text.endIndex && text[cursor] != "\n" {
                cursor = text.index(after: cursor)
            }
            var contentEnd = cursor
            if contentEnd > lineStart {
                let before = text.index(before: contentEnd)
                if text[before] == "\r" {
                    contentEnd = before
                }
            }
            let fullEnd = cursor < text.endIndex ? text.index(after: cursor) : cursor
            slices.append(RawLineSlice(fullRange: lineStart..<fullEnd, contentRange: lineStart..<contentEnd))
            cursor = fullEnd
        }
        return slices
    }

    struct StrippedConfig: Equatable {
        let remaining: String
        let hadManagedBlock: Bool
    }

    /// 仅移除托管标记区间及其自带的一条分隔空行，逐字节保留其余所有内容（CRLF、空行、有无尾换行）。
    static func stripManagedBlock(from text: String) throws -> StrippedConfig {
        let slices = rawLineSlices(in: text)
        var startIndex: Int?
        var blockRanges: [(startSlice: Int, endSlice: Int)] = []

        for (i, slice) in slices.enumerated() {
            let trimmed = text[slice.contentRange].trimmingCharacters(in: .whitespaces)
            if trimmed == managedBlockStart {
                if startIndex != nil { throw ConfigError.invalidManagedBlock }
                startIndex = i
            } else if trimmed == managedBlockEnd {
                guard let open = startIndex else { throw ConfigError.invalidManagedBlock }
                blockRanges.append((open, i))
                startIndex = nil
            }
        }
        if startIndex != nil { throw ConfigError.invalidManagedBlock }
        if blockRanges.count > 1 { throw ConfigError.invalidManagedBlock }
        guard let block = blockRanges.first else {
            return StrippedConfig(remaining: text, hadManagedBlock: false)
        }

        var removeStart = slices[block.startSlice].fullRange.lowerBound
        var removeEnd = slices[block.endSlice].fullRange.upperBound

        if block.startSlice == 0 {
            // 托管块在开头：仅吞掉紧随其后的最多一个分隔空行。
            let nextSliceIndex = block.endSlice + 1
            if nextSliceIndex < slices.count,
               slices[nextSliceIndex].contentRange.isEmpty {
                removeEnd = slices[nextSliceIndex].fullRange.upperBound
            }
        } else if block.endSlice == slices.count - 1 {
            // 兼容旧版本追加到末尾的托管块：若前面有分隔空行，去掉这一个空行，保留原内容字节。
            let prevSliceIndex = block.startSlice - 1
            if prevSliceIndex >= 0, slices[prevSliceIndex].contentRange.isEmpty {
                removeStart = slices[prevSliceIndex].fullRange.lowerBound
            }
        } else {
            let nextSliceIndex = block.endSlice + 1
            if nextSliceIndex < slices.count,
               slices[nextSliceIndex].contentRange.isEmpty {
                removeEnd = slices[nextSliceIndex].fullRange.upperBound
            }
        }

        var remaining = text
        remaining.removeSubrange(removeStart..<removeEnd)
        return StrippedConfig(remaining: remaining, hadManagedBlock: true)
    }

    /// 将托管块置于文件顶部（优先于后续 `Host *`），并逐字节保留原配置其余内容。
    static func composeSSHConfig(remaining: String, managedBlock: String) -> String {
        if remaining.isEmpty {
            return managedBlock + "\n"
        }
        return managedBlock + "\n\n" + remaining
    }

    static func hasTopLevelDirectivesBeforeFirstHostOrMatch(_ configText: String) -> Bool {
        for slice in rawLineSlices(in: configText) {
            let tokens = tokenizeSSHConfigLine(String(configText[slice.contentRange]))
            guard let keyword = tokens.first?.lowercased() else { continue }
            if keyword == "host" || keyword == "match" {
                return false
            }
            return true
        }
        return false
    }

    static func tokenizeSSHConfigLine(_ rawLine: String) -> [String] {
        var idx = rawLine.startIndex
        while idx < rawLine.endIndex, rawLine[idx] == " " || rawLine[idx] == "\t" {
            idx = rawLine.index(after: idx)
        }
        guard idx < rawLine.endIndex, rawLine[idx] != "#" else { return [] }

        var tokens: [String] = []
        // 第一个词为关键字，可用空白或 '=' 分隔
        let keyStart = idx
        while idx < rawLine.endIndex, rawLine[idx] != " " && rawLine[idx] != "\t" && rawLine[idx] != "=" {
            idx = rawLine.index(after: idx)
        }
        tokens.append(String(rawLine[keyStart..<idx]))

        while idx < rawLine.endIndex, rawLine[idx] == " " || rawLine[idx] == "\t" {
            idx = rawLine.index(after: idx)
        }
        if idx < rawLine.endIndex && rawLine[idx] == "=" {
            idx = rawLine.index(after: idx)
        }

        while idx < rawLine.endIndex {
            while idx < rawLine.endIndex, rawLine[idx] == " " || rawLine[idx] == "\t" {
                idx = rawLine.index(after: idx)
            }
            guard idx < rawLine.endIndex else { break }
            if rawLine[idx] == "#" { break }

            let quoteChar: Character? = (rawLine[idx] == "\"" || rawLine[idx] == "'") ? rawLine[idx] : nil
            if let q = quoteChar {
                idx = rawLine.index(after: idx)
                var value = ""
                while idx < rawLine.endIndex && rawLine[idx] != q {
                    value.append(rawLine[idx])
                    idx = rawLine.index(after: idx)
                }
                if idx < rawLine.endIndex && rawLine[idx] == q {
                    idx = rawLine.index(after: idx)
                }
                tokens.append(value)
            } else {
                let start = idx
                while idx < rawLine.endIndex, rawLine[idx] != " " && rawLine[idx] != "\t" {
                    idx = rawLine.index(after: idx)
                }
                tokens.append(String(rawLine[start..<idx]))
            }
        }
        return tokens
    }

    func containsConflictingHostAlias(_ alias: String, in configText: String) -> Bool {
        var visited: Set<String> = []
        return scanConfigForConflictingHostAlias(
            alias: alias,
            configText: configText,
            depth: 0,
            visited: &visited
        )
    }

    private func scanConfigForConflictingHostAlias(
        alias: String,
        configText: String,
        depth: Int,
        visited: inout Set<String>
    ) -> Bool {
        guard depth <= 16 else { return false }
        for slice in Self.rawLineSlices(in: configText) {
            let tokens = Self.tokenizeSSHConfigLine(String(configText[slice.contentRange]))
            guard tokens.count >= 2 else { continue }
            let keyword = tokens[0].lowercased()

            if keyword == "host" {
                let patterns = Array(tokens.dropFirst())
                if Self.hostPatternsConflict(patterns, with: alias) {
                    return true
                }
            } else if keyword == "match" {
                if Self.matchCriteriaConflict(Array(tokens.dropFirst()), with: alias) {
                    return true
                }
            } else if keyword == "include" {
                for rawPattern in tokens.dropFirst() {
                    let includedFiles = resolveIncludePaths(pattern: rawPattern)
                    for filePath in includedFiles {
                        let canonical = URL(fileURLWithPath: filePath).standardizedFileURL.path
                        guard !visited.contains(canonical) else { continue }
                        visited.insert(canonical)
                        guard let data = try? readRegularFileDataIfPresent(URL(fileURLWithPath: canonical)),
                              let text = String(data: data, encoding: .utf8) else {
                            continue
                        }
                        if scanConfigForConflictingHostAlias(
                            alias: alias,
                            configText: text,
                            depth: depth + 1,
                            visited: &visited
                        ) {
                            return true
                        }
                    }
                }
            }
        }
        return false
    }

    private func resolveIncludePaths(pattern: String) -> [String] {
        let expanded: String
        if pattern == "~" {
            expanded = homeDirectory.path
        } else if pattern.hasPrefix("~/") {
            expanded = homeDirectory.path + "/" + String(pattern.dropFirst(2))
        } else if pattern.hasPrefix("/") {
            expanded = pattern
        } else {
            expanded = sshDirectory.appendingPathComponent(pattern).path
        }

        var globResult = glob_t()
        let status = Darwin.glob(expanded, 0, nil, &globResult)
        defer { Darwin.globfree(&globResult) }
        guard status == 0, let pathv = globResult.gl_pathv else {
            return []
        }
        var results: [String] = []
        for i in 0..<Int(globResult.gl_matchc) {
            if let cStr = pathv[i] {
                results.append(String(cString: cStr))
            }
        }
        return results
    }

    static func hostPatternsConflict(_ patterns: [String], with alias: String) -> Bool {
        let target = alias.lowercased()
        var matchedSpecificPositive = false
        for rawPattern in patterns {
            let p = rawPattern.lowercased()
            guard !p.isEmpty else { continue }
            if p.hasPrefix("!") {
                let negated = String(p.dropFirst())
                if wildcardMatches(pattern: negated, string: target) {
                    return false
                }
            } else if p != "*" && wildcardMatches(pattern: p, string: target) {
                matchedSpecificPositive = true
            }
        }
        return matchedSpecificPositive
    }

    static func matchCriteriaConflict(_ criteria: [String], with alias: String) -> Bool {
        var idx = 0
        while idx < criteria.count {
            let raw = criteria[idx]
            let lower = raw.lowercased()
            let key: String
            let value: String?
            if let eq = raw.firstIndex(of: "=") {
                key = String(raw[..<eq]).lowercased()
                value = String(raw[raw.index(after: eq)...])
            } else {
                key = lower
                value = (idx + 1 < criteria.count) ? criteria[idx + 1] : nil
            }
            if key == "host" || key == "originalhost" {
                if let value {
                    let patternList = value.split(separator: ",").map(String.init)
                    if hostPatternsConflict(patternList, with: alias) {
                        return true
                    }
                }
                if !raw.contains("=") { idx += 1 }
            }
            idx += 1
        }
        return false
    }

    private static func wildcardMatches(pattern: String, string: String) -> Bool {
        Darwin.fnmatch(pattern, string, 0) == 0
    }

    static func parseEffectiveSSHConfig(_ output: String) -> EffectiveSSHConfig {
        var parsed = EffectiveSSHConfig()
        for slice in rawLineSlices(in: output) {
            let line = String(output[slice.contentRange])
            guard let spaceIdx = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else { continue }
            let key = String(line[..<spaceIdx]).lowercased()
            let value = String(line[spaceIdx...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "hostname":
                parsed.hostname = value
            case "port":
                parsed.port = value
            case "user":
                parsed.user = value
            case "identitiesonly":
                parsed.identitiesOnly = value
            case "identityagent":
                parsed.identityAgent = value
            case "identityfile":
                parsed.identityFiles.append(value)
            case "proxyjump":
                parsed.proxyJump = value
            case "proxycommand":
                parsed.proxyCommand = value
            case "controlmaster":
                parsed.controlMaster = value
            case "controlpath":
                parsed.controlPath = value
            case "remotecommand":
                parsed.remoteCommand = value
            default:
                break
            }
        }
        return parsed
    }

    static func validateEffectiveLoopbackConfig(
        _ config: EffectiveSSHConfig,
        expectedUser: String,
        expectedIdentityFile: String
    ) -> String? {
        guard config.hostname == "127.0.0.1" else {
            return "HostName 实际解析为 \(config.hostname ?? "<空>")，预期 127.0.0.1。"
        }
        guard config.port == "22" else {
            return "Port 实际解析为 \(config.port ?? "<空>")，预期 22。"
        }
        guard config.user == expectedUser else {
            return "User 实际解析为 \(config.user ?? "<空>")，预期 \(expectedUser)。"
        }
        guard config.identitiesOnly?.lowercased() == "yes" else {
            return "IdentitiesOnly 未生效。"
        }
        guard config.identityFiles.first == expectedIdentityFile else {
            return "首选 IdentityFile 为 \(config.identityFiles.first ?? "<空>")，预期 \(expectedIdentityFile)。"
        }
        if let agent = config.identityAgent?.lowercased(), !agent.isEmpty, agent != "none" {
            return "IdentityAgent 未禁用（\(agent)）。"
        }
        if let proxyJump = config.proxyJump?.lowercased(), !proxyJump.isEmpty, proxyJump != "none" {
            return "存在 ProxyJump（\(proxyJump)）。"
        }
        if let proxyCommand = config.proxyCommand?.lowercased(), !proxyCommand.isEmpty, proxyCommand != "none" {
            return "存在 ProxyCommand（\(proxyCommand)）。"
        }
        if let cm = config.controlMaster?.lowercased(), cm != "false" && cm != "no" {
            return "ControlMaster 未禁用（\(cm)）。"
        }
        if let cp = config.controlPath?.lowercased(), !cp.isEmpty, cp != "none" {
            return "存在 ControlPath（\(cp)）。"
        }
        if let rc = config.remoteCommand?.lowercased(), !rc.isEmpty, rc != "none" {
            return "存在 RemoteCommand（\(rc)）。"
        }
        return nil
    }
}
