package httpapi

import (
	"net/url"
	"path/filepath"
	"sort"
	"strings"
	"unicode"
	"unicode/utf8"
)

// 本文件把 iOS 的 ConversationFileReferenceDetector 移植到 agentd：iOS 用它把助手正文里的
// 本机路径识别成可点的文件 chip，会话引用授权（见 session_file_grants.go）用同一套规则从
// AI 产出里提取路径。两边规则不一致时，要么 chip 点开被拒，要么授权了 iOS 不会请求的路径，
// 所以共用 contracts/file-references/detector-cases.json 夹具，两侧测试读同一份用例。
//
// Swift 按字素簇遍历，这里按 rune 遍历；差异只出现在 CRLF、组合字符这类多标量字符上。

// agentFileReferencePreviewExtensions 与 iOS previewExtensions 保持一致。
var agentFileReferencePreviewExtensions = map[string]struct{}{
	"csv": {}, "doc": {}, "docx": {}, "gif": {}, "heic": {}, "html": {}, "jpeg": {}, "jpg": {},
	"json": {}, "log": {}, "md": {}, "numbers": {}, "pages": {}, "pdf": {}, "png": {}, "ppt": {},
	"pptx": {}, "rtf": {}, "txt": {}, "webp": {}, "xls": {}, "xlsx": {}, "yaml": {}, "yml": {},
	"zip": {},
}

// 扩展名按长度降序、同长按字母序匹配，"jpeg" 先于 "jpg"，与 Swift 的排序一致。
var agentFileReferenceExtensionsByLength = func() []string {
	values := make([]string, 0, len(agentFileReferencePreviewExtensions))
	for ext := range agentFileReferencePreviewExtensions {
		values = append(values, ext)
	}
	sort.Slice(values, func(i, j int) bool {
		if len(values[i]) != len(values[j]) {
			return len(values[i]) > len(values[j])
		}
		return values[i] < values[j]
	})
	return values
}()

// 单段正文最多提取的路径数。iOS chip 只取前 5 个，但 Markdown 链接和图片不受该限制。
const agentFileReferenceMaxPerText = 64

const (
	agentFileReferenceEdgeTrim         = "`\"'“”‘’()[]{}<>.,;"
	agentFileReferenceStartBoundary    = "`\"'“”‘’([{<：:，,;；"
	agentFileReferenceCandidateStop    = "`\"'“”‘’<>"
	agentFileReferenceExtensionEndings = "`\"'“”‘’()[]{}<>,;:.!?。！？、，；："
)

// agentTextFileReferencePaths 返回正文里 iOS 会识别成文件引用的规范化路径，去重并保持出现顺序。
func agentTextFileReferencePaths(text string) []string {
	runes := []rune(text)
	var result []string
	seen := map[string]struct{}{}
	for index := 0; index < len(runes) && len(result) < agentFileReferenceMaxPerText; {
		if !agentFileReferencePathStart(runes, index) {
			index++
			continue
		}
		end, ok := agentFileReferenceCandidateEnd(runes, index)
		if !ok {
			index++
			continue
		}
		candidate := string(runes[index:end])
		index = end
		path, ok := normalizedAgentFileReference(candidate)
		if !ok || !agentFileReferenceHasPreviewExtension(path) {
			continue
		}
		if _, duplicate := seen[path]; duplicate {
			continue
		}
		seen[path] = struct{}{}
		result = append(result, path)
	}
	return result
}

func agentFileReferenceHasPreviewExtension(path string) bool {
	ext := strings.ToLower(strings.TrimPrefix(filepath.Ext(path), "."))
	_, ok := agentFileReferencePreviewExtensions[ext]
	return ok
}

func agentFileReferenceCandidateEnd(runes []rune, start int) (int, bool) {
	for index := start; index < len(runes); index++ {
		if index != start && agentFileReferencePathStart(runes, index) {
			return 0, false
		}
		char := runes[index]
		if isAgentFileReferenceNewline(char) || isAgentFileReferenceControl(char) ||
			strings.ContainsRune(agentFileReferenceCandidateStop, char) {
			return 0, false
		}
		if char != '.' {
			continue
		}
		extensionStart := index + 1
		for _, ext := range agentFileReferenceExtensionsByLength {
			if !hasCaseInsensitiveRunePrefix(runes, extensionStart, ext) {
				continue
			}
			extensionEnd := extensionStart + utf8.RuneCountInString(ext)
			if agentFileReferenceExtensionTerminator(runes, extensionEnd) {
				return extensionEnd, true
			}
		}
	}
	return 0, false
}

func agentFileReferencePathStart(runes []rune, index int) bool {
	if index > 0 {
		previous := runes[index-1]
		if !isAgentFileReferenceWhitespace(previous) && !isAgentFileReferenceControl(previous) &&
			!strings.ContainsRune(agentFileReferenceStartBoundary, previous) {
			return false
		}
	}
	if hasCaseInsensitiveRunePrefix(runes, index, "file://") {
		return true
	}
	if runes[index] != '/' {
		return false
	}
	return index+1 >= len(runes) || runes[index+1] != '/'
}

func agentFileReferenceExtensionTerminator(runes []rune, index int) bool {
	if index >= len(runes) {
		return true
	}
	char := runes[index]
	return char == '?' || char == '#' || isAgentFileReferenceWhitespace(char) ||
		isAgentFileReferenceControl(char) || strings.ContainsRune(agentFileReferenceExtensionEndings, char)
}

func hasCaseInsensitiveRunePrefix(runes []rune, index int, prefix string) bool {
	for _, want := range prefix {
		if index >= len(runes) || unicode.ToLower(runes[index]) != unicode.ToLower(want) {
			return false
		}
		index++
	}
	return true
}

func normalizedAgentFileReference(raw string) (string, bool) {
	token := strings.TrimFunc(raw, func(char rune) bool {
		return strings.ContainsRune(agentFileReferenceEdgeTrim, char)
	})
	if token == "" {
		return "", false
	}
	if cut := strings.IndexAny(token, "?#"); cut >= 0 {
		token = token[:cut]
	}
	if len(token) >= len("file://") && strings.EqualFold(token[:len("file://")], "file://") {
		rawPath := token[len("file://"):]
		if strings.HasPrefix(rawPath, "/") {
			// 与 removingPercentEncoding 一致：非法转义或解出非 UTF-8 时保留原文。
			if decoded, err := url.PathUnescape(rawPath); err == nil && utf8.ValidString(decoded) {
				rawPath = decoded
			}
			token = rawPath
		} else {
			parsed, err := url.Parse(token)
			if err != nil || !strings.EqualFold(parsed.Scheme, "file") {
				return "", false
			}
			token = parsed.Path
		}
	}
	token = stripAgentFileReferenceLineSuffix(token)
	if !strings.HasPrefix(token, "/") || utf8.RuneCountInString(token) <= 1 || strings.ContainsRune(token, 0) {
		return "", false
	}
	return strings.ReplaceAll(token, `\ `, " "), true
}

func stripAgentFileReferenceLineSuffix(token string) string {
	colon := strings.LastIndex(token, ":")
	if colon < 0 {
		return token
	}
	suffix := token[colon+1:]
	if suffix == "" {
		return token
	}
	for _, char := range suffix {
		if !unicode.IsNumber(char) {
			return token
		}
	}
	return token[:colon]
}

// 对应 Foundation 的 whitespacesAndNewlines、newlines 与 controlCharacters（Cc + Cf）。
func isAgentFileReferenceWhitespace(char rune) bool {
	return unicode.IsSpace(char) || unicode.Is(unicode.Zs, char) || isAgentFileReferenceNewline(char)
}

func isAgentFileReferenceNewline(char rune) bool {
	switch char {
	case '\n', '\v', '\f', '\r', 0x85, 0x2028, 0x2029:
		return true
	default:
		return false
	}
}

func isAgentFileReferenceControl(char rune) bool {
	return unicode.Is(unicode.Cc, char) || unicode.Is(unicode.Cf, char)
}

// 只沿协议里承载 turn 与 item 的容器字段下钻，不进入任何 item 内部：工具输出、
// 用户消息、任意 JSON 结构化结果里的路径都不能成为授权依据。
var agentFileReferenceContainerKeys = map[string]struct{}{
	"result": {}, "params": {}, "thread": {}, "turns": {}, "data": {}, "items": {}, "item": {},
}

// collectAgentProducedFilePaths 从 app-server 帧（history 响应或 item 通知）里收集 AI 自己产出
// 的文件路径：助手正文中 iOS 会识别的路径、查看的图片、生成图的落盘路径、改动的文件。
func collectAgentProducedFilePaths(value any, add func(string)) {
	switch typed := value.(type) {
	case []any:
		for _, child := range typed {
			collectAgentProducedFilePaths(child, add)
		}
	case map[string]any:
		if itemType, ok := typed["type"].(string); ok && strings.TrimSpace(itemType) != "" {
			collectAgentItemFilePaths(itemType, typed, add)
			return
		}
		for key, child := range typed {
			if _, ok := agentFileReferenceContainerKeys[key]; ok {
				collectAgentProducedFilePaths(child, add)
			}
		}
	}
}

func collectAgentItemFilePaths(itemType string, item map[string]any, add func(string)) {
	switch itemType {
	case "agentMessage":
		if text, ok := item["text"].(string); ok {
			for _, path := range agentTextFileReferencePaths(text) {
				add(path)
			}
		}
	case "imageView":
		if path, ok := item["path"].(string); ok {
			add(path)
		}
	case "imageGeneration":
		for _, key := range []string{"savedPath", "saved_path"} {
			if path, ok := item[key].(string); ok {
				add(path)
			}
		}
	case "fileChange":
		changes, _ := item["changes"].([]any)
		for _, change := range changes {
			if object, ok := change.(map[string]any); ok {
				if path, ok := object["path"].(string); ok {
					add(path)
				}
			}
		}
	}
}
