import CryptoKit
import Darwin
import Foundation

extension CodexLocalSSHConfigurator {
    // MARK: - Pure Parsing, Formatting & Conflict Detection

    static func computeSHA256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func computeOpenSSHSHA256Fingerprint(fromKeyBody keyBody: String) -> String? {
        let tokens = keyBody.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count == 2, let keyBlob = Data(base64Encoded: tokens[1]) else {
            return nil
        }
        let digest = SHA256.hash(data: keyBlob)
        let base64 = Data(digest).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:\(base64)"
    }

    /// 渲染写入 `~/.ssh/mimi/config` 的完整独立配置（固定 HostKeyAlias、AddressFamily、IdentityFile、IdentitiesOnly、UserKnownHostsFile 与 NoHostAuthenticationForLocalhost no）。
    static func renderMimiConfig(
        alias: String,
        username: String,
        identityFilePath: String,
        knownHostsFilePath: String
    ) -> String {
        let lines = [
            "# Managed by Mimi Remote Mac — isolated local loopback SSH config",
            "Host \(alias)",
            "    HostName 127.0.0.1",
            "    AddressFamily inet",
            "    Port 22",
            "    User \(username)",
            "    HostKeyAlias \(alias)",
            "    IdentityFile \"\(identityFilePath)\"",
            "    IdentitiesOnly yes",
            "    IdentityAgent none",
            "    PubkeyAuthentication yes",
            "    PreferredAuthentications publickey",
            "    PasswordAuthentication no",
            "    KbdInteractiveAuthentication no",
            "    UserKnownHostsFile \"\(knownHostsFilePath)\"",
            "    GlobalKnownHostsFile none",
            "    KnownHostsCommand none",
            "    VerifyHostKeyDNS no",
            "    NoHostAuthenticationForLocalhost no",
            "    HashKnownHosts no",
            "    StrictHostKeyChecking accept-new",
            "    UpdateHostKeys no",
            "    ClearAllForwardings yes",
            "    ProxyJump none",
            "    ProxyCommand none",
            "    ControlMaster no",
            "    ControlPath none",
            "    ControlPersist no",
            "    ForwardAgent no",
            "    ForwardX11 no",
            "    CanonicalizeHostname no",
            "    PermitLocalCommand no",
            "    RemoteCommand none",
            "    StdinNull no",
            "    RequestTTY auto",
            "    SessionType default",
            "    ForkAfterAuthentication no",
            "    EscapeChar none",
            "    EnableEscapeCommandline no",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    static func formatManagedAuthorizedKeyEntry(publicKeyBody: String) -> String {
        "\(Self.loopbackAuthorizedKeyOption) \(publicKeyBody) \(Self.keyComment)"
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

    /// 校验独立 `known_hosts` 数据是否非空且至少包含一条匹配预期 `HostKeyAlias` 的有效主机公钥记录。
    static func containsValidKnownHostEntry(in data: Data, expectedHostAlias: String) -> Bool {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
            return false
        }
        let targetLower = expectedHostAlias.lowercased()
        let bracketedTarget = "[\(targetLower)]:22"
        for slice in rawLineSlices(in: text) {
            let trimmed = utf8Substring(text, range: slice.contentRange)
                .trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
            guard tokens.count >= 3 else { continue }
            if tokens[0].hasPrefix("@") {
                // 拒绝 @revoked，亦不接受仅靠 @cert-authority 替代明确主机公钥记录。
                continue
            }
            let hostPatterns = tokens[0].split(separator: ",").map { $0.lowercased() }
            let matchesHost = hostPatterns.contains(targetLower) || hostPatterns.contains(bracketedTarget)
            guard matchesHost,
                  isKnownSSHKeyType(tokens[1]),
                  Data(base64Encoded: tokens[2]) != nil else {
                continue
            }
            return true
        }
        return false
    }

    /// 按 OpenSSH `authorized_keys` 语法结构化解析单行；空行、注释行或非法行返回 nil。
    static func parseAuthorizedKeyLine(_ rawLine: String) -> ParsedAuthorizedKeyLine? {
        var utf8Bytes = Array(rawLine.utf8)
        while let last = utf8Bytes.last, last == 0x0A || last == 0x0D {
            utf8Bytes.removeLast()
        }
        let line = String(decoding: utf8Bytes, as: UTF8.self)
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
        /// 是否存在精确匹配的 Mimi 标记行（`restrict,from="127.0.0.1,::1" <keyBody> mimi-codex-local`）。
        let hasExactMimiEntry: Bool
        /// 是否存在同一公钥的其他授权行（如用户修改了注释、缺少 restrict 或同公钥多行）。
        let hasOtherSameKeyEntry: Bool
        let hasConflict: Bool
        let conflictReason: String?

        var hasValidLoopbackEntry: Bool { hasExactMimiEntry && !hasConflict }
    }

    static func evaluateAuthorizedKeys(
        content: String,
        keyBody: String,
        recordedEntry: String?
    ) -> AuthorizedKeysEvaluation {
        let expectedEntry = recordedEntry ?? formatManagedAuthorizedKeyEntry(publicKeyBody: keyBody)
        var exactMimiEntryCount = 0
        var hasOtherSameKeyEntry = false
        for slice in rawLineSlices(in: content) {
            let lineText = utf8Substring(content, range: slice.contentRange)
            guard let parsed = parseAuthorizedKeyLine(lineText), parsed.keyBody == keyBody else {
                continue
            }
            if !parsed.isStrictlyLoopbackFrom {
                return AuthorizedKeysEvaluation(
                    hasExactMimiEntry: exactMimiEntryCount > 0,
                    hasOtherSameKeyEntry: true,
                    hasConflict: true,
                    conflictReason: "发现同一公钥缺少仅限 127.0.0.1/::1 的 from= 限制。"
                )
            }
            if !parsed.hasRestrictOption {
                return AuthorizedKeysEvaluation(
                    hasExactMimiEntry: exactMimiEntryCount > 0,
                    hasOtherSameKeyEntry: true,
                    hasConflict: true,
                    conflictReason: "发现同一公钥缺少 restrict 限制选项。"
                )
            }
            if parsed.hasCommandOption {
                return AuthorizedKeysEvaluation(
                    hasExactMimiEntry: exactMimiEntryCount > 0,
                    hasOtherSameKeyEntry: true,
                    hasConflict: true,
                    conflictReason: "发现同一公钥带有 command= 限制选项。"
                )
            }
            if !parsed.hasOnlyManagedRestrictAndLoopbackFromOptions {
                return AuthorizedKeysEvaluation(
                    hasExactMimiEntry: exactMimiEntryCount > 0,
                    hasOtherSameKeyEntry: true,
                    hasConflict: true,
                    conflictReason: "发现同一公钥带有超出 Mimi 最小限制（restrict,from）的额外选项，可能重新开启端口转发或 PTY 访问。"
                )
            }
            if lineText == expectedEntry && parsed.isValidMimiManagedEntry(expectedKeyBody: keyBody) {
                exactMimiEntryCount += 1
            } else {
                hasOtherSameKeyEntry = true
            }
        }
        if hasOtherSameKeyEntry {
            return AuthorizedKeysEvaluation(
                hasExactMimiEntry: exactMimiEntryCount > 0,
                hasOtherSameKeyEntry: true,
                hasConflict: true,
                conflictReason: "发现同一公钥存在额外的外部或已修改授权行（非唯一 Mimi 标记行），已拒绝验收并保留记录未覆盖。"
            )
        }
        if exactMimiEntryCount > 1 {
            return AuthorizedKeysEvaluation(
                hasExactMimiEntry: true,
                hasOtherSameKeyEntry: true,
                hasConflict: true,
                conflictReason: "发现同一托管公钥在 authorized_keys 中出现重复条目（共 \(exactMimiEntryCount) 条），已拒绝验收。"
            )
        }
        return AuthorizedKeysEvaluation(
            hasExactMimiEntry: exactMimiEntryCount == 1,
            hasOtherSameKeyEntry: false,
            hasConflict: false,
            conflictReason: nil
        )
    }

    static func appendAuthorizedKeyEntry(_ entry: String, to existing: String) -> (text: String, addedLeadingNewline: Bool) {
        if existing.isEmpty {
            return (entry + "\n", false)
        }
        // 按 UTF-8 字节判断尾换行，避免 Swift Character 把 "\r\n" 当单个字符导致 hasSuffix("\n") 误判。
        if existing.utf8.last == 0x0A {
            return (existing + entry + "\n", false)
        }
        return (existing + "\n" + entry + "\n", true)
    }

    static func containsExactLine(_ entry: String, in content: String) -> Bool {
        rawLineSlices(in: content).contains { utf8Substring(content, range: $0.contentRange) == entry }
    }

    /// 按结构化公钥标识检查 `authorized_keys` 中是否仍存在指定公钥的有效授权（不受注释或选项修改影响）。
    static func containsAuthorizedKeyBody(_ keyBody: String, in content: String) -> Bool {
        rawLineSlices(in: content).contains { slice in
            let lineText = utf8Substring(content, range: slice.contentRange)
            return parseAuthorizedKeyLine(lineText)?.keyBody == keyBody
        }
    }

    /// 跨回滚、重配、撤销三个入口共用的按公钥残留授权检查：返回仍在 `authorized_keys` 中生效的公钥主体列表（去重保序）。
    static func findResidualAuthorizedKeyBodies(_ keyBodies: [String], in content: String) -> [String] {
        var seen: Set<String> = []
        var residuals: [String] = []
        for body in keyBodies where !body.isEmpty {
            guard seen.insert(body).inserted else { continue }
            if containsAuthorizedKeyBody(body, in: content) {
                residuals.append(body)
            }
        }
        return residuals
    }

    /// 仅移除与记录完全匹配且带有 Mimi 标记与 `restrict,from="127.0.0.1,::1"` 的托管授权行，绝不动其他任何行（含用户同公钥行、CRLF、空行）。
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
            let lineText = utf8Substring(content, range: slice.contentRange)
            guard lineText == recordedEntry,
                  let parsed = parseAuthorizedKeyLine(lineText),
                  parsed.isValidMimiManagedEntry(expectedKeyBody: expectedKeyBody) else {
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

        var bytes = Array(content.utf8)
        let utf8 = content.utf8
        for range in targetRanges.reversed() {
            let startOffset = utf8.distance(from: utf8.startIndex, to: range.lowerBound)
            let endOffset = utf8.distance(from: utf8.startIndex, to: range.upperBound)
            bytes.removeSubrange(startOffset..<endOffset)
        }
        if addedLeadingNewline && removedTrailingLineAtEOF {
            // 仅在末尾确认为 Mimi 追加时插入的独立 LF（非已被外部转为 CRLF 的 \r\n）时才移除，避免残留裸 CR。
            if bytes.last == 0x0A && (bytes.count < 2 || bytes[bytes.count - 2] != 0x0D) {
                bytes.removeLast()
            }
        }
        return (String(decoding: bytes, as: UTF8.self), true)
    }

    // MARK: - Byte-Preserving Line Scanning & Single-Line Managed Include Composition

    struct RawLineSlice {
        /// 含行尾换行符（`\n` 或 `\r\n`）的完整区间。
        let fullRange: Range<String.Index>
        /// 不含行尾 `\r\n` 或 `\n` 的行内容区间。
        let contentRange: Range<String.Index>
    }

    static func utf8Substring(_ text: String, range: Range<String.Index>) -> String {
        String(decoding: text.utf8[range], as: UTF8.self)
    }

    /// 按 UTF-8 字节 `0x0A` / `0x0D` 分行，避免 Swift `Character` 把 CRLF 合并成单字符而漏检行边界。
    static func rawLineSlices(in text: String) -> [RawLineSlice] {
        let utf8 = text.utf8
        guard !utf8.isEmpty else { return [] }
        var slices: [RawLineSlice] = []
        var cursor = utf8.startIndex
        while cursor < utf8.endIndex {
            let lineStart = cursor
            while cursor < utf8.endIndex && utf8[cursor] != 0x0A {
                cursor = utf8.index(after: cursor)
            }
            var contentEnd = cursor
            if contentEnd > lineStart {
                let before = utf8.index(before: contentEnd)
                if utf8[before] == 0x0D {
                    contentEnd = before
                }
            }
            let fullEnd = cursor < utf8.endIndex ? utf8.index(after: cursor) : cursor
            slices.append(RawLineSlice(fullRange: lineStart..<fullEnd, contentRange: lineStart..<contentEnd))
            cursor = fullEnd
        }
        return slices
    }

    struct StrippedIncludeConfig: Equatable {
        let remaining: String
        let hadManagedInclude: Bool
        let wasAtTop: Bool
        let originalManagedLine: String?
    }

    /// 仅移除 `~/.ssh/config` 中由 Mimi 写入的单行带标记 `Include` 指令，逐字节保留其余所有内容（CRLF、空行、有无尾换行）。
    /// 若出现多条标记行、标记行语法被破坏或残缺的旧标记，显式抛出 `invalidManagedBlock`。
    static func stripManagedIncludeLine(from text: String) throws -> StrippedIncludeConfig {
        let slices = rawLineSlices(in: text)
        var matchedSliceIndices: [Int] = []

        for (i, slice) in slices.enumerated() {
            let rawLine = utf8Substring(text, range: slice.contentRange)
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed == managedIncludeLine {
                matchedSliceIndices.append(i)
            } else if trimmed.contains(managedIncludeMarker) {
                // 含有 Mimi 标记但内容不完整或被破坏 -> 明确报错，绝不静默删错行或重复追加。
                throw ConfigError.invalidManagedBlock
            }
        }

        if matchedSliceIndices.count > 1 {
            throw ConfigError.invalidManagedBlock
        }
        guard let matchIdx = matchedSliceIndices.first else {
            return StrippedIncludeConfig(
                remaining: text,
                hadManagedInclude: false,
                wasAtTop: false,
                originalManagedLine: nil
            )
        }

        let slice = slices[matchIdx]
        let originalLine = utf8Substring(text, range: slice.contentRange)
        let utf8 = text.utf8
        let startOffset = utf8.distance(from: utf8.startIndex, to: slice.fullRange.lowerBound)
        let endOffset = utf8.distance(from: utf8.startIndex, to: slice.fullRange.upperBound)
        var bytes = Array(utf8)
        bytes.removeSubrange(startOffset..<endOffset)
        return StrippedIncludeConfig(
            remaining: String(decoding: bytes, as: UTF8.self),
            hadManagedInclude: true,
            wasAtTop: matchIdx == 0,
            originalManagedLine: originalLine
        )
    }

    /// 仅在 `~/.ssh/config` 最顶部加入单行带标记的 `Include`，逐字节保留原配置其余所有内容。
    static func composeSSHConfigWithTopInclude(
        remaining: String,
        includeLine: String = managedIncludeLine
    ) -> String {
        if remaining.isEmpty {
            return includeLine + "\n"
        }
        return includeLine + "\n" + remaining
    }

    // MARK: - OpenSSH-Compatible Line Tokenizer (Supports Mid-Token Quotes, Escapes & Control-Byte Rejection)

    struct ParsedSSHConfigLine: Equatable {
        let tokens: [String]
        let hasSyntaxError: Bool
    }

    /// OpenSSH `ssh_config(5)` 及 macOS Apple OpenSSH 已知客户端配置指令白名单（全小写）。
    /// 冻结器在调用 `ssh -G` 前对所有非空非注释行执行严格白名单校验，任何无法识别的指令一律 fail closed，绝不原样放行。
    static let recognizedSSHConfigKeywords: Set<String> = [
        "addkeystoagent",
        "addressfamily",
        "applemultipath",
        "batchmode",
        "bindaddress",
        "bindinterface",
        "canonicaldomains",
        "canonicalizefallbacklocal",
        "canonicalizehostname",
        "canonicalizemaxdots",
        "canonicalizepermittedcnames",
        "casignaturealgorithms",
        "certificatefile",
        "challengeresponseauthentication",
        "channeltimeout",
        "checkhostip",
        "cipher",
        "ciphers",
        "clearallforwardings",
        "compression",
        "compressionlevel",
        "connectionattempts",
        "connecttimeout",
        "controlmaster",
        "controlpath",
        "controlpersist",
        "dynamicforward",
        "enableescapecommandline",
        "enablesshkeysign",
        "escapechar",
        "exitonforwardfailure",
        "fallbacktorsh",
        "fingerprinthash",
        "forkafterauthentication",
        "forwardagent",
        "forwardx11",
        "forwardx11timeout",
        "forwardx11trusted",
        "gatewayports",
        "globalknownhostsfile",
        "gssapiauthentication",
        "gssapiclientidentity",
        "gssapidelegatecredentials",
        "gssapikeyexchange",
        "gssapikexalgorithms",
        "gssapirenewalforcesrekey",
        "gssapiserveridentity",
        "gssapitrustdns",
        "hashknownhosts",
        "host",
        "hostbasedacceptedalgorithms",
        "hostbasedauthentication",
        "hostbasedkeytypes",
        "hostkeyalgorithms",
        "hostkeyalias",
        "hostname",
        "identitiesonly",
        "identityagent",
        "identityfile",
        "ignoreunknown",
        "include",
        "ipqos",
        "kbdinteractiveauthentication",
        "kbdinteractivedevices",
        "kexalgorithms",
        "knownhostscommand",
        "localcommand",
        "localforward",
        "loglevel",
        "logverbose",
        "macs",
        "match",
        "nohostauthenticationforlocalhost",
        "nohostauthenticationforproxycommand",
        "numberofpasswordprompts",
        "obscurekeystroketiming",
        "passwordauthentication",
        "permitlocalcommand",
        "permitremoteopen",
        "pkcs11provider",
        "port",
        "preferredauthentications",
        "protocol",
        "proxycommand",
        "proxyjump",
        "proxyusefdpass",
        "pubkeyacceptedalgorithms",
        "pubkeyacceptedkeytypes",
        "pubkeyauthentication",
        "refuseconnection",
        "rekeylimit",
        "remotecommand",
        "remoteforward",
        "requesttty",
        "requiredrsasize",
        "revokedhostkeys",
        "rhostsrsaauthentication",
        "rsaauthentication",
        "securitykeyprovider",
        "sendenv",
        "serveralivecountmax",
        "serveraliveinterval",
        "sessiontype",
        "setenv",
        "stdinnull",
        "streamlocalbindmask",
        "streamlocalbindunlink",
        "stricthostkeychecking",
        "syslogfacility",
        "tag",
        "tcpkeepalive",
        "tunnel",
        "tunneldevice",
        "updatehostkeys",
        "usekeychain",
        "useprivilegedport",
        "user",
        "userknownhostsfile",
        "usersh",
        "verifyhostkeydns",
        "versionaddendum",
        "visualhostkey",
        "warnweakcrypto",
        "xauthlocation",
    ]

    /// 解析 OpenSSH `IgnoreUnknown <pattern-list>` 指令（仅接受单参数逗号分隔模式，与 OpenSSH `readconf.c` 一致）。
    static func parseIgnoreUnknownPatterns(from tokens: [String]) -> [String]? {
        guard tokens.count == 2 else { return nil }
        let patterns = tokens[1]
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard !patterns.isEmpty, patterns.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }
        return patterns
    }

    /// 纯 OpenSSH `match_pattern` 语义：仅支持 `*` 与 `?` 通配符（不支持 Darwin `fnmatch` 的 `[...]` 字符类或反斜杠转义），与 OpenSSH `match.c` 严格一致。
    static func matchesOpenSSHWildcard(pattern: String, string: String) -> Bool {
        let p = Array(pattern.utf8)
        let s = Array(string.utf8)
        var pi = 0
        var si = 0
        var starIdx: Int?
        var matchIdx = 0
        while si < s.count {
            if pi < p.count && (p[pi] == 0x3F || p[pi] == s[si]) { // '?' or exact byte
                pi += 1
                si += 1
            } else if pi < p.count && p[pi] == 0x2A { // '*'
                starIdx = pi
                matchIdx = si
                pi += 1
            } else if let star = starIdx {
                pi = star + 1
                matchIdx += 1
                si = matchIdx
            } else {
                return false
            }
        }
        while pi < p.count && p[pi] == 0x2A {
            pi += 1
        }
        return pi == p.count
    }

    /// 判定未识别指令是否满足 OpenSSH `IgnoreUnknown` 模式（严格按 `*`/`?`/`!` 语义，不放行任何已在 `recognizedSSHConfigKeywords` 中的指令）。
    /// 命中后冻结器会原样保留该行交由真实 `/usr/bin/ssh -G` 按 OpenSSH `Host`/`Match` 作用域裁决，绝不私自注释。
    static func matchesIgnoreUnknown(keyword: String, patterns: [String]) -> Bool {
        let lower = keyword.lowercased()
        guard !lower.isEmpty,
              !recognizedSSHConfigKeywords.contains(lower),
              let first = lower.utf8.first,
              (first >= 0x61 && first <= 0x7A),
              lower.utf8.allSatisfy({ b in
                  (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) || b == 0x2D || b == 0x5F
              }) else {
            return false
        }
        var matchedPositive = false
        for pattern in patterns {
            if pattern.hasPrefix("!") {
                let negated = String(pattern.dropFirst())
                if !negated.isEmpty, matchesOpenSSHWildcard(pattern: negated, string: lower) {
                    return false
                }
            } else if matchesOpenSSHWildcard(pattern: pattern, string: lower) {
                matchedPositive = true
            }
        }
        return matchedPositive
    }

    /// 严格按 OpenSSH `strdelim` / `argv_split` 语义切分配置行：
    /// - 拒绝除水平制表符（0x09）外的全部 ASCII 控制字节（含 `\0`、行内 `\r`、`\v`、`\f`、`\n`、`0x7F`），消除与 OpenSSH `WHITESPACE`/`isspace` 的分歧；
    /// - 支持关键字与参数间用空格、制表符或 `=` 分隔，并支持关键字内双引号（如 `"Include"`、`Inc"lude"`、`"Match"`）；
    /// - 支持参数任意位置出现 `"..."`、`'...'`（含路径中段引号，如 `Include /tmp/"a b"/inc.conf`）与反斜杠转义（如 `a\ b`）；
    /// - 任何控制字节、空关键字、未闭合引号、悬空反斜杠或非法关键字转义一律标为 `hasSyntaxError = true`，供冻结器 fail closed 拒绝。
    static func parseSSHConfigLineStrict(_ rawLine: String) -> ParsedSSHConfigLine {
        for byte in rawLine.utf8 {
            if (byte < 0x20 && byte != 0x09) || byte == 0x7F {
                return ParsedSSHConfigLine(tokens: [], hasSyntaxError: true)
            }
        }

        var idx = rawLine.startIndex
        while idx < rawLine.endIndex, rawLine[idx] == " " || rawLine[idx] == "\t" {
            idx = rawLine.index(after: idx)
        }
        guard idx < rawLine.endIndex, rawLine[idx] != "#" else {
            return ParsedSSHConfigLine(tokens: [], hasSyntaxError: false)
        }

        var tokens: [String] = []
        // 第一个词为关键字：按 OpenSSH strdelim 语义支持双引号与空白/'='分隔；不允许空关键字、单引号或反斜杠。
        var keyword = ""
        var inKeywordDoubleQuote = false
        var sawKeywordSegment = false
        while idx < rawLine.endIndex {
            let ch = rawLine[idx]
            if inKeywordDoubleQuote {
                if ch == "\"" {
                    inKeywordDoubleQuote = false
                    idx = rawLine.index(after: idx)
                } else if ch == "\\" {
                    let nextIdx = rawLine.index(after: idx)
                    guard nextIdx < rawLine.endIndex else {
                        return ParsedSSHConfigLine(tokens: tokens, hasSyntaxError: true)
                    }
                    let nextCh = rawLine[nextIdx]
                    if nextCh == "\"" || nextCh == "\\" {
                        keyword.append(nextCh)
                    } else {
                        keyword.append(ch)
                        keyword.append(nextCh)
                    }
                    idx = rawLine.index(after: nextIdx)
                } else {
                    keyword.append(ch)
                    idx = rawLine.index(after: idx)
                }
            } else {
                if ch == " " || ch == "\t" || ch == "=" {
                    break
                } else if ch == "\"" {
                    inKeywordDoubleQuote = true
                    sawKeywordSegment = true
                    idx = rawLine.index(after: idx)
                } else if ch == "'" || ch == "\\" {
                    return ParsedSSHConfigLine(tokens: tokens, hasSyntaxError: true)
                } else {
                    keyword.append(ch)
                    sawKeywordSegment = true
                    idx = rawLine.index(after: idx)
                }
            }
        }
        if inKeywordDoubleQuote || !sawKeywordSegment || keyword.isEmpty {
            return ParsedSSHConfigLine(tokens: tokens, hasSyntaxError: true)
        }
        tokens.append(keyword)

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

            var current = ""
            var openQuote: Character?
            var sawAnySegment = false

            while idx < rawLine.endIndex {
                let ch = rawLine[idx]
                if let q = openQuote {
                    if ch == q {
                        openQuote = nil
                        idx = rawLine.index(after: idx)
                    } else if q == "\"" && ch == "\\" {
                        let nextIdx = rawLine.index(after: idx)
                        guard nextIdx < rawLine.endIndex else {
                            return ParsedSSHConfigLine(tokens: tokens, hasSyntaxError: true)
                        }
                        let nextCh = rawLine[nextIdx]
                        if nextCh == "\"" || nextCh == "\\" {
                            current.append(nextCh)
                        } else {
                            current.append(ch)
                            current.append(nextCh)
                        }
                        idx = rawLine.index(after: nextIdx)
                    } else {
                        current.append(ch)
                        idx = rawLine.index(after: idx)
                    }
                } else {
                    if ch == " " || ch == "\t" {
                        break
                    } else if ch == "\"" || ch == "'" {
                        openQuote = ch
                        sawAnySegment = true
                        idx = rawLine.index(after: idx)
                    } else if ch == "\\" {
                        let nextIdx = rawLine.index(after: idx)
                        guard nextIdx < rawLine.endIndex else {
                            return ParsedSSHConfigLine(tokens: tokens, hasSyntaxError: true)
                        }
                        current.append(rawLine[nextIdx])
                        sawAnySegment = true
                        idx = rawLine.index(after: nextIdx)
                    } else {
                        current.append(ch)
                        sawAnySegment = true
                        idx = rawLine.index(after: idx)
                    }
                }
            }

            if openQuote != nil {
                return ParsedSSHConfigLine(tokens: tokens, hasSyntaxError: true)
            }
            if sawAnySegment {
                tokens.append(current)
            }
        }
        return ParsedSSHConfigLine(tokens: tokens, hasSyntaxError: false)
    }

    static func tokenizeSSHConfigLine(_ rawLine: String) -> [String] {
        parseSSHConfigLineStrict(rawLine).tokens
    }

    static func hasUnclosedQuote(inSSHConfigLine rawLine: String) -> Bool {
        parseSSHConfigLineStrict(rawLine).hasSyntaxError
    }

    func containsConflictingHostAlias(_ alias: String, in configText: String) -> Bool {
        var visited: Set<String> = []
        let mimiConfigCanonical = mimiConfigURL.resolvingSymlinksInPath().standardizedFileURL.path
        visited.insert(mimiConfigCanonical)
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
            let tokens = Self.tokenizeSSHConfigLine(Self.utf8Substring(configText, range: slice.contentRange))
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
                        let url = URL(fileURLWithPath: filePath)
                        let canonical = url.resolvingSymlinksInPath().standardizedFileURL.path
                        guard !visited.contains(canonical) else { continue }
                        visited.insert(canonical)
                        guard let data = try? readEvaluationRegularFileIfPresent(at: url),
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
        (try? Self.resolveGlobPathsStrict(pattern: pattern, baseDirectory: sshDirectory, homeDirectory: homeDirectory)) ?? []
    }

    /// 严格按 OpenSSH 规则展开 `Include` 模式；对包含动态占位符（`%`）、环境变量（`${...}`）、他人主目录（`~user`）或 glob 异常的模式明确报错，绝不静默丢弃。
    static func resolveGlobPathsStrict(
        pattern: String,
        baseDirectory: URL,
        homeDirectory: URL,
        virtualFilePaths: Set<String> = []
    ) throws -> [String] {
        guard !pattern.isEmpty else {
            throw ConfigError.effectiveConfigConflict("SSH Include 包含空路径模式，无法忠实冻结。")
        }
        if pattern.contains("%") {
            throw ConfigError.effectiveConfigConflict("SSH Include 包含 OpenSSH 动态占位符（\(pattern)），无法忠实冻结。")
        }
        if pattern.contains("${") {
            throw ConfigError.effectiveConfigConflict("SSH Include 包含环境变量展开（\(pattern)），无法忠实冻结。")
        }
        let expanded: String
        if pattern == "~" {
            expanded = homeDirectory.path
        } else if pattern.hasPrefix("~/") {
            expanded = homeDirectory.path + "/" + String(pattern.dropFirst(2))
        } else if pattern.hasPrefix("~") {
            throw ConfigError.effectiveConfigConflict("SSH Include 包含其他用户主目录路径（\(pattern)），无法忠实冻结。")
        } else if pattern.hasPrefix("/") {
            expanded = pattern
        } else {
            expanded = baseDirectory.appendingPathComponent(pattern).path
        }

        let standardizedExpanded = URL(fileURLWithPath: expanded).standardizedFileURL.path
        var results: [String] = []
        var globResult = glob_t()
        let status = Darwin.glob(expanded, 0, nil, &globResult)
        defer { Darwin.globfree(&globResult) }
        if status == 0, let pathv = globResult.gl_pathv {
            for i in 0..<Int(globResult.gl_matchc) {
                if let cStr = pathv[i] {
                    results.append(String(cString: cStr))
                }
            }
        } else if status != GLOB_NOMATCH {
            throw ConfigError.effectiveConfigConflict("展开 SSH Include 模式 \(pattern) 失败（glob 状态码 \(status)），无法忠实冻结。")
        }

        // Preflight 阶段允许针对尚未落盘的候选 `~/.ssh/mimi/config` 虚拟覆盖匹配。
        if !virtualFilePaths.isEmpty {
            for virtualPath in virtualFilePaths.sorted() {
                if virtualPath == standardizedExpanded || Darwin.fnmatch(standardizedExpanded, virtualPath, 0) == 0 {
                    if !results.contains(where: { URL(fileURLWithPath: $0).standardizedFileURL.path == virtualPath }) {
                        results.append(virtualPath)
                    }
                }
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

    private static let recognizedMatchZeroArgCriteria: Set<String> = [
        "all", "canonical", "final",
    ]

    private static let recognizedMatchValueCriteria: Set<String> = [
        "host", "originalhost", "user", "localuser", "localnetwork", "tagged", "command",
    ]

    /// 严格校验 OpenSSH `Match` 条件列表：阻断 `exec` / `!exec`，并拒绝空条件、未知条件、缺参或语法不明确的 `=`，fail closed。
    static func validateMatchCriteria(_ criteria: [String]) -> String? {
        guard !criteria.isEmpty else {
            return "SSH 配置包含缺少条件的 Match 指令，拒绝只读评估。"
        }
        var idx = 0
        var sawAll = false
        var sawOtherThanCanonicalFinal = false
        while idx < criteria.count {
            let raw = criteria[idx]
            let lower = raw.lowercased()
            let negated = lower.hasPrefix("!")
            let body = negated ? String(lower.dropFirst()) : lower
            let name: String
            let inlineValue: String?
            if let eq = body.firstIndex(of: "=") {
                name = String(body[..<eq])
                inlineValue = String(body[body.index(after: eq)...])
            } else {
                name = body
                inlineValue = nil
            }
            if name == "exec" {
                return "SSH 配置包含 Match exec 条件命令，只读评估拒绝执行外部 shell 命令。"
            }
            if recognizedMatchZeroArgCriteria.contains(name) {
                guard inlineValue == nil else {
                    return "SSH 配置包含语法不明确的 Match 条件（\(raw)），拒绝只读评估。"
                }
                if name == "all" {
                    if negated {
                        return "SSH 配置包含无效的 Match !all 条件，拒绝只读评估。"
                    }
                    sawAll = true
                }
                idx += 1
            } else if recognizedMatchValueCriteria.contains(name) {
                sawOtherThanCanonicalFinal = true
                if let inlineValue {
                    guard !inlineValue.isEmpty else {
                        return "SSH 配置包含缺少参数值的 Match 条件（\(raw)），拒绝只读评估。"
                    }
                    idx += 1
                } else {
                    guard idx + 1 < criteria.count else {
                        return "SSH 配置包含缺少参数的 Match 条件（\(raw)），拒绝只读评估。"
                    }
                    let nextArg = criteria[idx + 1]
                    guard !nextArg.isEmpty, nextArg != "=" else {
                        return "SSH 配置包含语法不明确的 Match 参数（\(raw) \(nextArg)），拒绝只读评估。"
                    }
                    idx += 2
                }
            } else {
                return "SSH 配置包含无法识别的 Match 条件（\(raw)），拒绝只读评估。"
            }
        }
        if sawAll && sawOtherThanCanonicalFinal {
            return "SSH 配置包含非法组合的 Match all 条件，拒绝只读评估。"
        }
        return nil
    }

    /// 检测 OpenSSH `Match` 条件中是否包含 `exec` 或 `!exec`，用于在被动只读评估（`ssh -G`）前阻断外部 shell 执行。
    static func matchCriteriaContainsExec(_ criteria: [String]) -> Bool {
        var idx = 0
        while idx < criteria.count {
            let raw = criteria[idx]
            let lower = raw.lowercased()
            let unnegated = lower.hasPrefix("!") ? String(lower.dropFirst()) : lower
            if unnegated == "exec" || unnegated.hasPrefix("exec=") {
                return true
            }
            if unnegated == "all" || unnegated == "canonical" || unnegated == "final" {
                idx += 1
            } else if raw.contains("=") {
                idx += 1
            } else {
                idx += 2
            }
        }
        return false
    }

    private static func wildcardMatches(pattern: String, string: String) -> Bool {
        Darwin.fnmatch(pattern, string, 0) == 0
    }

    static func parseEffectiveSSHConfig(_ output: String) -> EffectiveSSHConfig {
        var parsed = EffectiveSSHConfig()
        for slice in rawLineSlices(in: output) {
            let line = utf8Substring(output, range: slice.contentRange)
            guard let spaceIdx = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else { continue }
            let key = String(line[..<spaceIdx]).lowercased()
            let value = String(line[spaceIdx...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "hostname":
                parsed.hostname = value
            case "addressfamily":
                parsed.addressFamily = value
            case "port":
                parsed.port = value
            case "user":
                parsed.user = value
            case "hostkeyalias":
                parsed.hostKeyAlias = value
            case "identitiesonly":
                parsed.identitiesOnly = value
            case "identityagent":
                parsed.identityAgent = value
            case "identityfile":
                parsed.identityFiles.append(value)
            case "certificatefile":
                if !value.isEmpty, value.lowercased() != "none" {
                    parsed.certificateFiles.append(value)
                }
            case "pubkeyauthentication":
                parsed.pubkeyAuthentication = value
            case "preferredauthentications":
                parsed.preferredAuthentications = value
            case "pubkeyacceptedalgorithms", "pubkeyacceptedkeytypes":
                parsed.pubkeyAcceptedAlgorithms = value
            case "userknownhostsfile":
                parsed.userKnownHostsFile = value
            case "globalknownhostsfile":
                parsed.globalKnownHostsFile = value
            case "knownhostscommand":
                parsed.knownHostsCommand = value
            case "verifyhostkeydns":
                parsed.verifyHostKeyDNS = value
            case "nohostauthenticationforlocalhost":
                parsed.noHostAuthenticationForLocalhost = value
            case "stricthostkeychecking":
                parsed.strictHostKeyChecking = value
            case "clearallforwardings":
                parsed.clearAllForwardings = value
            case "forwardagent":
                parsed.forwardAgent = value
            case "forwardx11":
                parsed.forwardX11 = value
            case "localforward":
                parsed.localForwards.append(value)
            case "remoteforward":
                parsed.remoteForwards.append(value)
            case "dynamicforward":
                parsed.dynamicForwards.append(value)
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
            case "permitlocalcommand":
                parsed.permitLocalCommand = value
            case "canonicalizehostname":
                parsed.canonicalizeHostname = value
            case "stdinnull":
                parsed.stdinNull = value
            case "requesttty":
                parsed.requestTTY = value
            case "sessiontype":
                parsed.sessionType = value
            case "forkafterauthentication":
                parsed.forkAfterAuthentication = value
            case "updatehostkeys":
                parsed.updateHostKeys = value
            case "escapechar":
                parsed.escapeChar = value
            case "enableescapecommandline":
                parsed.enableEscapeCommandline = value
            default:
                break
            }
        }
        return parsed
    }

    static func validateEffectiveLoopbackConfig(
        _ config: EffectiveSSHConfig,
        expectedUser: String,
        expectedIdentityFile: String,
        expectedKnownHostsFile: String,
        expectedHostKeyAlias: String = hostAlias,
        additionalAllowedIdentityFiles: Set<String> = []
    ) -> String? {
        guard config.hostname == "127.0.0.1" else {
            return "HostName 实际解析为 \(config.hostname ?? "<空>")，预期 127.0.0.1。"
        }
        guard config.addressFamily?.lowercased() == "inet" else {
            return "AddressFamily 实际解析为 \(config.addressFamily ?? "<空>")，预期 inet。"
        }
        guard config.port == "22" else {
            return "Port 实际解析为 \(config.port ?? "<空>")，预期 22。"
        }
        guard config.user == expectedUser else {
            return "User 实际解析为 \(config.user ?? "<空>")，预期 \(expectedUser)。"
        }
        guard config.hostKeyAlias?.lowercased() == expectedHostKeyAlias.lowercased() else {
            return "HostKeyAlias 实际解析为 \(config.hostKeyAlias ?? "<空>")，预期 \(expectedHostKeyAlias)。"
        }
        guard config.identitiesOnly?.lowercased() == "yes" else {
            return "IdentitiesOnly 未生效。"
        }
        let allowedIdentities = additionalAllowedIdentityFiles.union([expectedIdentityFile])
        guard !config.identityFiles.isEmpty,
              config.identityFiles.allSatisfy({ allowedIdentities.contains($0) }),
              (additionalAllowedIdentityFiles.isEmpty ? config.identityFiles == [expectedIdentityFile] : config.identityFiles.contains(expectedIdentityFile)) else {
            return "有效 IdentityFile 列表为 [\(config.identityFiles.joined(separator: ", "))]，预期仅包含 \(expectedIdentityFile)。"
        }
        guard config.certificateFiles.isEmpty else {
            return "存在额外的 CertificateFile（\(config.certificateFiles.joined(separator: ", "))）。"
        }
        if let agent = config.identityAgent?.lowercased(), !agent.isEmpty, agent != "none" {
            return "IdentityAgent 未禁用（\(agent)）。"
        }
        if let pubkey = config.pubkeyAuthentication?.lowercased(), pubkey != "yes" && pubkey != "true" {
            return "PubkeyAuthentication 未启用（\(pubkey)）。"
        }
        if let preferred = config.preferredAuthentications, !preferred.isEmpty {
            let methods = preferred.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            if !methods.contains("publickey") {
                return "PreferredAuthentications 未允许 publickey（\(preferred)）。"
            }
        }
        if let algos = config.pubkeyAcceptedAlgorithms, !algos.isEmpty {
            let allowed = algos.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            if !allowed.contains("ssh-ed25519") {
                return "PubkeyAcceptedAlgorithms 未允许 ssh-ed25519（\(algos)）。"
            }
        }
        guard config.userKnownHostsFile == expectedKnownHostsFile else {
            return "UserKnownHostsFile 实际解析为 \(config.userKnownHostsFile ?? "<空>")，预期 \(expectedKnownHostsFile)。"
        }
        if let globalKH = config.globalKnownHostsFile?.lowercased(), !globalKH.isEmpty, globalKH != "none" {
            return "GlobalKnownHostsFile 未禁用（\(globalKH)）。"
        }
        if let khCmd = config.knownHostsCommand?.lowercased(), !khCmd.isEmpty, khCmd != "none" {
            return "存在额外的 KnownHostsCommand（\(khCmd)）。"
        }
        if let verifyDNS = config.verifyHostKeyDNS?.lowercased(), !verifyDNS.isEmpty, verifyDNS != "no" && verifyDNS != "false" {
            return "VerifyHostKeyDNS 未禁用（\(verifyDNS)）。"
        }
        guard let noHostAuth = config.noHostAuthenticationForLocalhost?.lowercased(),
              noHostAuth == "no" || noHostAuth == "false" else {
            return "NoHostAuthenticationForLocalhost 未显式禁用（\(config.noHostAuthenticationForLocalhost ?? "<空>")），可能跳过回环主机密钥验证。"
        }
        if let strict = config.strictHostKeyChecking?.lowercased(), strict != "accept-new" && strict != "yes" && strict != "true" {
            return "StrictHostKeyChecking 不安全（\(strict)）。"
        }
        guard config.localForwards.isEmpty else {
            return "存在生效的 LocalForward（\(config.localForwards.joined(separator: "; "))）。"
        }
        guard config.remoteForwards.isEmpty else {
            return "存在生效的 RemoteForward（\(config.remoteForwards.joined(separator: "; "))）。"
        }
        guard config.dynamicForwards.isEmpty else {
            return "存在生效的 DynamicForward（\(config.dynamicForwards.joined(separator: "; "))）。"
        }
        if let forwardAgent = config.forwardAgent?.lowercased(), !forwardAgent.isEmpty, forwardAgent != "no" && forwardAgent != "false" {
            return "ForwardAgent 未禁用（\(forwardAgent)）。"
        }
        if let forwardX11 = config.forwardX11?.lowercased(), !forwardX11.isEmpty, forwardX11 != "no" && forwardX11 != "false" {
            return "ForwardX11 未禁用（\(forwardX11)）。"
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
        if let permitLocal = config.permitLocalCommand?.lowercased(), !permitLocal.isEmpty, permitLocal != "no" && permitLocal != "false" {
            return "PermitLocalCommand 未禁用（\(permitLocal)）。"
        }
        if let canon = config.canonicalizeHostname?.lowercased(), !canon.isEmpty, canon != "no" && canon != "false" {
            return "CanonicalizeHostname 未禁用（\(canon)）。"
        }
        if let stdinNull = config.stdinNull?.lowercased(), !stdinNull.isEmpty, stdinNull != "no" && stdinNull != "false" {
            return "StdinNull 已启用（\(stdinNull)），会阻断 Codex 桌面版 App Server 代理的双向输入。"
        }
        if let requestTTY = config.requestTTY?.lowercased(), !requestTTY.isEmpty, requestTTY != "no" && requestTTY != "auto" && requestTTY != "false" {
            return "RequestTTY 强制分配终端（\(requestTTY)），会破坏 Codex 桌面版代理流。"
        }
        if let sessionType = config.sessionType?.lowercased(), !sessionType.isEmpty, sessionType != "default" {
            return "SessionType 异常（\(sessionType)），无法执行 Codex 桌面版代理命令。"
        }
        if let forkAuth = config.forkAfterAuthentication?.lowercased(), !forkAuth.isEmpty, forkAuth != "no" && forkAuth != "false" {
            return "ForkAfterAuthentication 已启用（\(forkAuth)），会阻断会话输入输出。"
        }
        if let escapeCmd = config.enableEscapeCommandline?.lowercased(), !escapeCmd.isEmpty, escapeCmd != "no" && escapeCmd != "false" {
            return "EnableEscapeCommandline 未禁用（\(escapeCmd)）。"
        }
        return nil
    }

    /// 校验目标（如裸 127.0.0.1）在用户与系统 SSH 配置下是否直连当前用户的回环 22 端口，无重定向或代理，且认证、主机信任与双向传输选项对 Codex 桌面版可用。
    static func isDirectLoopbackConfig(
        _ config: EffectiveSSHConfig,
        expectedUser: String,
        allowedLoopbackHosts: Set<String> = ["127.0.0.1", "::1"]
    ) -> Bool {
        guard let hostname = config.hostname?.lowercased(),
              allowedLoopbackHosts.contains(hostname) else {
            return false
        }
        if let af = config.addressFamily?.lowercased(), !af.isEmpty, af != "any" {
            if hostname == "127.0.0.1" && af != "inet" { return false }
            if hostname == "::1" && af != "inet6" { return false }
        }
        guard config.port == "22", config.user == expectedUser else {
            return false
        }
        if let noHostAuth = config.noHostAuthenticationForLocalhost?.lowercased(),
           !noHostAuth.isEmpty, noHostAuth != "no" && noHostAuth != "false" {
            return false
        }
        if let pubkey = config.pubkeyAuthentication?.lowercased(), !pubkey.isEmpty, pubkey != "yes" && pubkey != "true" {
            return false
        }
        if let preferred = config.preferredAuthentications, !preferred.isEmpty {
            let methods = preferred.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            if !methods.contains("publickey") {
                return false
            }
        }
        if let proxyJump = config.proxyJump?.lowercased(), !proxyJump.isEmpty, proxyJump != "none" {
            return false
        }
        if let proxyCommand = config.proxyCommand?.lowercased(), !proxyCommand.isEmpty, proxyCommand != "none" {
            return false
        }
        if let cm = config.controlMaster?.lowercased(), !cm.isEmpty, cm != "false" && cm != "no" {
            return false
        }
        if let cp = config.controlPath?.lowercased(), !cp.isEmpty, cp != "none" {
            return false
        }
        if let rc = config.remoteCommand?.lowercased(), !rc.isEmpty, rc != "none" {
            return false
        }
        if let permitLocal = config.permitLocalCommand?.lowercased(), !permitLocal.isEmpty, permitLocal != "no" && permitLocal != "false" {
            return false
        }
        if let canon = config.canonicalizeHostname?.lowercased(), !canon.isEmpty, canon != "no" && canon != "false" {
            return false
        }
        if let stdinNull = config.stdinNull?.lowercased(), !stdinNull.isEmpty, stdinNull != "no" && stdinNull != "false" {
            return false
        }
        if let requestTTY = config.requestTTY?.lowercased(), !requestTTY.isEmpty, requestTTY != "no" && requestTTY != "auto" && requestTTY != "false" {
            return false
        }
        if let sessionType = config.sessionType?.lowercased(), !sessionType.isEmpty, sessionType != "default" {
            return false
        }
        if let forkAuth = config.forkAfterAuthentication?.lowercased(), !forkAuth.isEmpty, forkAuth != "no" && forkAuth != "false" {
            return false
        }
        if let khCmd = config.knownHostsCommand?.lowercased(), !khCmd.isEmpty, khCmd != "none" {
            return false
        }
        if let verifyDNS = config.verifyHostKeyDNS?.lowercased(), !verifyDNS.isEmpty, verifyDNS != "no" && verifyDNS != "false" {
            return false
        }
        return true
    }

    /// 判断两个有效 SSH 配置在端点、地址族、身份认证与主机信任输入上是否完全一致（避免探测与 Codex 桌面代理走不同路径）。
    static func effectiveEndpointAuthAndTrustMatch(
        _ lhs: EffectiveSSHConfig,
        _ rhs: EffectiveSSHConfig,
        ignoreKnownHostsPath: Bool = false
    ) -> Bool {
        func norm(_ value: String?) -> String {
            (value ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        }
        guard norm(lhs.hostname) == norm(rhs.hostname),
              norm(lhs.port) == norm(rhs.port),
              lhs.user == rhs.user,
              norm(lhs.addressFamily) == norm(rhs.addressFamily),
              norm(lhs.hostKeyAlias) == norm(rhs.hostKeyAlias),
              norm(lhs.identitiesOnly) == norm(rhs.identitiesOnly),
              norm(lhs.identityAgent) == norm(rhs.identityAgent),
              lhs.identityFiles == rhs.identityFiles,
              lhs.certificateFiles == rhs.certificateFiles,
              norm(lhs.pubkeyAuthentication) == norm(rhs.pubkeyAuthentication),
              norm(lhs.preferredAuthentications) == norm(rhs.preferredAuthentications),
              norm(lhs.pubkeyAcceptedAlgorithms) == norm(rhs.pubkeyAcceptedAlgorithms),
              norm(lhs.globalKnownHostsFile) == norm(rhs.globalKnownHostsFile),
              norm(lhs.knownHostsCommand) == norm(rhs.knownHostsCommand),
              norm(lhs.verifyHostKeyDNS) == norm(rhs.verifyHostKeyDNS),
              norm(lhs.noHostAuthenticationForLocalhost) == norm(rhs.noHostAuthenticationForLocalhost) else {
            return false
        }
        if !ignoreKnownHostsPath && lhs.userKnownHostsFile != rhs.userKnownHostsFile {
            return false
        }
        return true
    }
}
