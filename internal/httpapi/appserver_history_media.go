package httpapi

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"image"
	"image/gif"
	"image/jpeg"
	"image/png"
	"net/http"
	"strings"
	"sync"
	"time"

	"golang.org/x/image/draw"
	"golang.org/x/image/webp"
)

const appServerHistoryMediaURLPrefix = "agentd-history-media://"

var (
	appServerHistoryMediaTTL                       = 30 * time.Minute
	appServerHistoryMediaMaxEntries                = 128
	appServerHistoryMediaMaxBytes            int64 = 256 << 20
	appServerHistoryMediaMaxItemBytes        int64 = 20 << 20
	appServerHistoryMediaDerivedMaxDimension       = 1600
	appServerHistoryMediaJPEGQuality               = 80
)

// image.data、工具 result 之类的裸 base64 只有大到影响 gateway cap / 隧道带宽时才值得改写；
// 小图继续内联，避免为几 KB 的内容多一次往返。
var appServerHistoryMediaMinRawBase64Chars = 16 << 10

type appServerHistoryMediaStore struct {
	mu         sync.Mutex
	entries    map[string]appServerHistoryMediaEntry
	idByHash   map[[32]byte]string
	totalBytes int64
}

type appServerHistoryMediaEntry struct {
	id          string
	contentType string
	data        []byte
	hash        [32]byte
	derived     map[string]appServerHistoryMediaVariant
	createdAt   time.Time
	lastAccess  time.Time
}

type appServerHistoryMediaVariant struct {
	contentType string
	data        []byte
}

func newAppServerHistoryMediaStore() *appServerHistoryMediaStore {
	return &appServerHistoryMediaStore{
		entries:  map[string]appServerHistoryMediaEntry{},
		idByHash: map[[32]byte]string{},
	}
}

func (s *appServerHistoryMediaStore) put(contentType string, data []byte) (string, bool) {
	if s == nil || len(data) == 0 || int64(len(data)) > appServerHistoryMediaMaxItemBytes {
		return "", false
	}
	now := time.Now()
	hash := sha256.Sum256(data)

	s.mu.Lock()
	defer s.mu.Unlock()
	s.pruneLocked(now)
	if s.idByHash == nil {
		s.idByHash = map[[32]byte]string{}
	}
	if existingID := s.idByHash[hash]; existingID != "" {
		if entry, ok := s.entries[existingID]; ok {
			entry.lastAccess = now
			s.entries[existingID] = entry
			return existingID, true
		}
		delete(s.idByHash, hash)
	}
	id, ok := randomHistoryMediaID()
	if !ok {
		return "", false
	}
	entry := appServerHistoryMediaEntry{
		id:          id,
		contentType: contentType,
		data:        append([]byte(nil), data...),
		hash:        hash,
		createdAt:   now,
		lastAccess:  now,
	}
	s.entries[id] = entry
	s.idByHash[hash] = id
	s.totalBytes += entry.totalBytes()
	s.enforceLimitsLocked(now)
	return id, true
}

func (s *appServerHistoryMediaStore) get(id string) (appServerHistoryMediaEntry, bool) {
	if s == nil {
		return appServerHistoryMediaEntry{}, false
	}
	id = strings.TrimSpace(id)
	if id == "" {
		return appServerHistoryMediaEntry{}, false
	}
	now := time.Now()
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pruneLocked(now)
	entry, ok := s.entries[id]
	if !ok {
		return appServerHistoryMediaEntry{}, false
	}
	entry.lastAccess = now
	s.entries[id] = entry
	return entry, true
}

func (s *appServerHistoryMediaStore) getDerived(id string, key string) (appServerHistoryMediaEntry, appServerHistoryMediaVariant, bool) {
	if s == nil {
		return appServerHistoryMediaEntry{}, appServerHistoryMediaVariant{}, false
	}
	id = strings.TrimSpace(id)
	key = strings.TrimSpace(key)
	if id == "" || key == "" {
		return appServerHistoryMediaEntry{}, appServerHistoryMediaVariant{}, false
	}
	now := time.Now()
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pruneLocked(now)
	entry, ok := s.entries[id]
	if !ok {
		return appServerHistoryMediaEntry{}, appServerHistoryMediaVariant{}, false
	}
	entry.lastAccess = now
	s.entries[id] = entry
	variant, ok := entry.derived[key]
	if !ok {
		return entry, appServerHistoryMediaVariant{}, false
	}
	variant.data = append([]byte(nil), variant.data...)
	return entry, variant, true
}

func (s *appServerHistoryMediaStore) storeDerived(id string, key string, variant appServerHistoryMediaVariant) (appServerHistoryMediaEntry, appServerHistoryMediaVariant, bool) {
	if s == nil || strings.TrimSpace(id) == "" || strings.TrimSpace(key) == "" || len(variant.data) == 0 {
		return appServerHistoryMediaEntry{}, appServerHistoryMediaVariant{}, false
	}
	now := time.Now()
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pruneLocked(now)
	entry, ok := s.entries[id]
	if !ok {
		return appServerHistoryMediaEntry{}, appServerHistoryMediaVariant{}, false
	}
	if entry.derived == nil {
		entry.derived = map[string]appServerHistoryMediaVariant{}
	}
	if existing, ok := entry.derived[key]; ok {
		entry.lastAccess = now
		s.entries[id] = entry
		existing.data = append([]byte(nil), existing.data...)
		return entry, existing, true
	}
	copied := appServerHistoryMediaVariant{
		contentType: variant.contentType,
		data:        append([]byte(nil), variant.data...),
	}
	entry.derived[key] = copied
	entry.lastAccess = now
	s.entries[id] = entry
	s.totalBytes += int64(len(copied.data))
	s.enforceLimitsLocked(now)
	copied.data = append([]byte(nil), copied.data...)
	return entry, copied, true
}

func (s *appServerHistoryMediaStore) totalBytesForTest() int64 {
	if s == nil {
		return 0
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.totalBytes
}

func (s *appServerHistoryMediaStore) pruneLocked(now time.Time) {
	if appServerHistoryMediaTTL <= 0 {
		return
	}
	for id, entry := range s.entries {
		if now.Sub(entry.createdAt) > appServerHistoryMediaTTL {
			s.deleteEntryLocked(id, entry)
		}
	}
	if s.totalBytes < 0 {
		s.totalBytes = 0
	}
}

func (s *appServerHistoryMediaStore) enforceLimitsLocked(now time.Time) {
	for (appServerHistoryMediaMaxEntries > 0 && len(s.entries) > appServerHistoryMediaMaxEntries) ||
		(appServerHistoryMediaMaxBytes > 0 && s.totalBytes > appServerHistoryMediaMaxBytes) {
		oldestID := ""
		oldestAt := now
		for id, entry := range s.entries {
			if oldestID == "" || entry.lastAccess.Before(oldestAt) {
				oldestID = id
				oldestAt = entry.lastAccess
			}
		}
		if oldestID == "" {
			return
		}
		entry := s.entries[oldestID]
		s.deleteEntryLocked(oldestID, entry)
	}
	if s.totalBytes < 0 {
		s.totalBytes = 0
	}
}

func (s *appServerHistoryMediaStore) deleteEntryLocked(id string, entry appServerHistoryMediaEntry) {
	delete(s.entries, id)
	if s.idByHash != nil && entry.hash != ([32]byte{}) {
		delete(s.idByHash, entry.hash)
	}
	s.totalBytes -= entry.totalBytes()
}

func (e appServerHistoryMediaEntry) totalBytes() int64 {
	total := int64(len(e.data))
	for _, variant := range e.derived {
		total += int64(len(variant.data))
	}
	return total
}

func randomHistoryMediaID() (string, bool) {
	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", false
	}
	return base64.RawURLEncoding.EncodeToString(raw[:]), true
}

func (r *Router) appServerHistoryMediaHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	id := strings.TrimPrefix(req.URL.Path, "/api/app-server/history-media/")
	id = strings.TrimSpace(id)
	if id == "" || strings.Contains(id, "/") {
		writeError(w, http.StatusBadRequest, "history media id 无效")
		return
	}
	if historyMediaOriginalRequested(req) {
		entry, ok := r.historyMedia.get(id)
		if !ok {
			writeError(w, http.StatusNotFound, "history media 已过期或不存在")
			return
		}
		writeJSON(w, http.StatusOK, historyMediaFileReadResponse(entry.id, entry.contentType, entry.data, 0))
		return
	}
	entry, variant, derived := r.historyMediaValueForDefaultRead(id)
	if entry.id == "" {
		writeError(w, http.StatusNotFound, "history media 已过期或不存在")
		return
	}
	if derived {
		writeJSON(w, http.StatusOK, historyMediaFileReadResponse(entry.id, variant.contentType, variant.data, int64(len(entry.data))))
		return
	}
	writeJSON(w, http.StatusOK, historyMediaFileReadResponse(entry.id, entry.contentType, entry.data, 0))
}

func historyMediaOriginalRequested(req *http.Request) bool {
	value := strings.TrimSpace(req.URL.Query().Get("original"))
	return value == "1" || strings.EqualFold(value, "true")
}

func (r *Router) historyMediaValueForDefaultRead(id string) (appServerHistoryMediaEntry, appServerHistoryMediaVariant, bool) {
	const key = "1600"
	if entry, variant, ok := r.historyMedia.getDerived(id, key); ok {
		return entry, variant, true
	}
	entry, ok := r.historyMedia.get(id)
	if !ok {
		return appServerHistoryMediaEntry{}, appServerHistoryMediaVariant{}, false
	}
	variant, changed := deriveHistoryMediaVariant(entry)
	if !changed {
		return entry, appServerHistoryMediaVariant{}, false
	}
	storedEntry, storedVariant, ok := r.historyMedia.storeDerived(id, key, variant)
	if !ok {
		return entry, variant, true
	}
	return storedEntry, storedVariant, true
}

func historyMediaFileReadResponse(id string, contentType string, data []byte, originalByteCount int64) fileReadResponse {
	return fileReadResponse{
		Path:              appServerHistoryMediaURLPrefix + id,
		Name:              historyMediaFilename(id, contentType),
		ContentType:       contentType,
		Size:              int64(len(data)),
		ContentBase64:     base64.StdEncoding.EncodeToString(data),
		OriginalByteCount: originalByteCount,
	}
}

func deriveHistoryMediaVariant(entry appServerHistoryMediaEntry) (appServerHistoryMediaVariant, bool) {
	img, format, ok := decodeHistoryMediaImage(entry.contentType, entry.data)
	if !ok {
		return appServerHistoryMediaVariant{}, false
	}
	bounds := img.Bounds()
	width := bounds.Dx()
	height := bounds.Dy()
	if width <= 0 || height <= 0 {
		return appServerHistoryMediaVariant{}, false
	}

	target := img
	resized := false
	if appServerHistoryMediaDerivedMaxDimension > 0 && max(width, height) > appServerHistoryMediaDerivedMaxDimension {
		targetWidth, targetHeight := scaledHistoryMediaSize(width, height, appServerHistoryMediaDerivedMaxDimension)
		dst := image.NewNRGBA(image.Rect(0, 0, targetWidth, targetHeight))
		// 核心逻辑：降采样只发生在按需取图接口，WebSocket 主链路永远只传短 URL。
		draw.CatmullRom.Scale(dst, dst.Bounds(), img, bounds, draw.Over, nil)
		target = dst
		resized = true
	}

	if imageHasTransparency(target) {
		if !resized {
			return appServerHistoryMediaVariant{}, false
		}
		data, ok := encodeHistoryMediaPNG(target)
		return appServerHistoryMediaVariant{contentType: "image/png", data: data}, ok
	}

	if resized {
		data, ok := encodeHistoryMediaJPEG(target)
		return appServerHistoryMediaVariant{contentType: "image/jpeg", data: data}, ok
	}

	if historyMediaIsPNG(entry.contentType, format) {
		data, ok := encodeHistoryMediaJPEG(target)
		if ok && len(data) < len(entry.data)*85/100 {
			return appServerHistoryMediaVariant{contentType: "image/jpeg", data: data}, true
		}
	}
	return appServerHistoryMediaVariant{}, false
}

func decodeHistoryMediaImage(contentType string, data []byte) (image.Image, string, bool) {
	reader := bytes.NewReader(data)
	switch strings.ToLower(strings.TrimSpace(strings.Split(contentType, ";")[0])) {
	case "image/png":
		img, err := png.Decode(reader)
		return img, "png", err == nil
	case "image/jpeg", "image/jpg":
		img, err := jpeg.Decode(reader)
		return img, "jpeg", err == nil
	case "image/gif":
		img, err := gif.Decode(reader)
		return img, "gif", err == nil
	case "image/webp":
		img, err := webp.Decode(reader)
		return img, "webp", err == nil
	}
	img, format, err := image.Decode(bytes.NewReader(data))
	return img, format, err == nil
}

func scaledHistoryMediaSize(width int, height int, maxDimension int) (int, int) {
	if width >= height {
		targetWidth := maxDimension
		targetHeight := max(1, height*maxDimension/width)
		return targetWidth, targetHeight
	}
	targetHeight := maxDimension
	targetWidth := max(1, width*maxDimension/height)
	return targetWidth, targetHeight
}

func imageHasTransparency(img image.Image) bool {
	bounds := img.Bounds()
	for y := bounds.Min.Y; y < bounds.Max.Y; y++ {
		for x := bounds.Min.X; x < bounds.Max.X; x++ {
			_, _, _, alpha := img.At(x, y).RGBA()
			if alpha != 0xffff {
				return true
			}
		}
	}
	return false
}

func encodeHistoryMediaJPEG(img image.Image) ([]byte, bool) {
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, &jpeg.Options{Quality: appServerHistoryMediaJPEGQuality}); err != nil {
		return nil, false
	}
	return buf.Bytes(), true
}

func encodeHistoryMediaPNG(img image.Image) ([]byte, bool) {
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		return nil, false
	}
	return buf.Bytes(), true
}

func historyMediaIsPNG(contentType string, format string) bool {
	return strings.EqualFold(strings.TrimSpace(strings.Split(contentType, ";")[0]), "image/png") || strings.EqualFold(format, "png")
}

func (r *Router) redactInlineHistoryImagesInGatewayResponse(payload []byte) ([]byte, bool) {
	if r == nil || r.historyMedia == nil {
		return payload, false
	}
	// app-server 的历史协议里图片存在多种形态：image.url、image.data、
	// 工具字段，以及嵌套在 _meta 中的 screenshot.url。先做廉价筛选，避免普通通知反复解析整段 JSON。
	if !bytes.Contains(payload, []byte("data:image/")) &&
		!bytes.Contains(payload, []byte(`"image"`)) &&
		!bytes.Contains(payload, []byte(`"imageGeneration"`)) &&
		!bytes.Contains(payload, []byte(`"mcpToolCall"`)) &&
		!bytes.Contains(payload, []byte(`"dynamicToolCall"`)) {
		return payload, false
	}
	var root any
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.UseNumber()
	if err := decoder.Decode(&root); err != nil {
		return payload, false
	}
	if !r.redactInlineHistoryImagesValue(root) {
		return payload, false
	}
	rewritten, err := json.Marshal(root)
	if err != nil {
		return payload, false
	}
	return rewritten, true
}

func (r *Router) redactInlineHistoryImagesValue(value any) bool {
	switch typed := value.(type) {
	case map[string]any:
		changed := r.redactInlineHistoryImageObject(typed)
		if r.redactInlineHistoryImageGenerationObject(typed) {
			changed = true
		}
		if r.redactInlineHistoryToolImageObject(typed) {
			changed = true
		}
		if r.redactInlineHistoryDataURLObject(typed) {
			changed = true
		}
		for _, child := range typed {
			if r.redactInlineHistoryImagesValue(child) {
				changed = true
			}
		}
		return changed
	case []any:
		changed := false
		for _, child := range typed {
			if r.redactInlineHistoryImagesValue(child) {
				changed = true
			}
		}
		return changed
	default:
		return false
	}
}

func (r *Router) redactInlineHistoryImageObject(object map[string]any) bool {
	rawType, _ := object["type"].(string)
	if strings.TrimSpace(rawType) != "image" {
		return false
	}
	rawURL, _ := object["url"].(string)
	contentType, data, ok := decodeHistoryImageDataURL(rawURL)
	if !ok {
		rawData, _ := object["data"].(string)
		contentType, data, ok = decodeHistoryInlineImage(rawData)
		if !ok {
			return false
		}
	}
	id, ok := r.historyMedia.put(contentType, data)
	if !ok {
		return false
	}
	// 核心逻辑：历史 full 响应里的 inline 图片对首屏文字没有必要，
	// 先替换成短 URL，避免大 base64 把 gateway 历史 cap 撞爆。
	object["url"] = appServerHistoryMediaURLPrefix + id
	delete(object, "data")
	object["contentType"] = contentType
	object["byteCount"] = len(data)
	object["redacted"] = true
	return true
}

// imageGeneration item 的 result 字段是不带 data: 前缀的裸 base64 整图（旁边有 savedPath），
// 单张 1-2MB，是历史 full 响应撞 cap 的最大来源；iPad 端不消费该字段，改写成短 URL 零损失。
func (r *Router) redactInlineHistoryImageGenerationObject(object map[string]any) bool {
	rawType, _ := object["type"].(string)
	if strings.TrimSpace(rawType) != "imageGeneration" {
		return false
	}
	rawResult, _ := object["result"].(string)
	contentType, data, ok := decodeHistoryRawBase64Image(rawResult)
	if !ok {
		return false
	}
	id, ok := r.historyMedia.put(contentType, data)
	if !ok {
		return false
	}
	object["result"] = appServerHistoryMediaURLPrefix + id
	object["resultContentType"] = contentType
	object["resultByteCount"] = len(data)
	object["resultRedacted"] = true
	return true
}

// MCP 和 dynamic tool 的图片可能出现在 url（data URL）或 result（裸 base64）。
// 只检查这些有明确语义的字段，并用图片文件头二次确认，避免误改普通工具文本。
func (r *Router) redactInlineHistoryToolImageObject(object map[string]any) bool {
	rawType, _ := object["type"].(string)
	switch strings.TrimSpace(rawType) {
	case "mcpToolCall", "dynamicToolCall":
	default:
		return false
	}

	changed := false
	for _, field := range []string{"url", "result"} {
		rawValue, _ := object[field].(string)
		contentType, data, ok := decodeHistoryInlineImage(rawValue)
		if !ok {
			continue
		}
		id, ok := r.historyMedia.put(contentType, data)
		if !ok {
			continue
		}
		object[field] = appServerHistoryMediaURLPrefix + id
		object[field+"ContentType"] = contentType
		object[field+"ByteCount"] = len(data)
		object[field+"Redacted"] = true
		changed = true
	}
	return changed
}

// data:image URL 已经显式声明内容类型，不需要依赖外围对象的 type。
// 浏览器工具会把截图放在 result._meta["codex/toolSurface"].screenshot.url，
// screenshot 对象本身没有 type；统一识别 URL 才能避免这类嵌套图片漏过历史响应 cap。
func (r *Router) redactInlineHistoryDataURLObject(object map[string]any) bool {
	rawURL, _ := object["url"].(string)
	contentType, data, ok := decodeHistoryImageDataURL(rawURL)
	if !ok {
		return false
	}
	id, ok := r.historyMedia.put(contentType, data)
	if !ok {
		return false
	}
	object["url"] = appServerHistoryMediaURLPrefix + id
	object["urlContentType"] = contentType
	object["urlByteCount"] = len(data)
	object["urlRedacted"] = true
	return true
}

func decodeHistoryInlineImage(value string) (string, []byte, bool) {
	if contentType, data, ok := decodeHistoryImageDataURL(value); ok {
		return contentType, data, true
	}
	return decodeHistoryRawBase64Image(value)
}

func decodeHistoryRawBase64Image(value string) (string, []byte, bool) {
	trimmed := strings.TrimSpace(value)
	if len(trimmed) < appServerHistoryMediaMinRawBase64Chars {
		return "", nil, false
	}
	if strings.HasPrefix(strings.ToLower(trimmed), "data:") {
		return "", nil, false
	}
	data, err := base64.StdEncoding.DecodeString(trimmed)
	if err != nil || len(data) == 0 {
		return "", nil, false
	}
	contentType := http.DetectContentType(data)
	if !strings.HasPrefix(contentType, "image/") {
		return "", nil, false
	}
	return contentType, data, true
}

func decodeHistoryImageDataURL(value string) (string, []byte, bool) {
	trimmed := strings.TrimSpace(value)
	if !strings.HasPrefix(strings.ToLower(trimmed), "data:image/") {
		return "", nil, false
	}
	comma := strings.Index(trimmed, ",")
	if comma <= len("data:") {
		return "", nil, false
	}
	metadata := trimmed[len("data:"):comma]
	parts := strings.Split(metadata, ";")
	contentType := strings.TrimSpace(parts[0])
	if !strings.HasPrefix(strings.ToLower(contentType), "image/") {
		return "", nil, false
	}
	isBase64 := false
	for _, part := range parts[1:] {
		if strings.EqualFold(strings.TrimSpace(part), "base64") {
			isBase64 = true
			break
		}
	}
	if !isBase64 {
		return "", nil, false
	}
	data, err := base64.StdEncoding.DecodeString(trimmed[comma+1:])
	if err != nil || len(data) == 0 {
		return "", nil, false
	}
	return contentType, data, true
}

func historyMediaFilename(id, contentType string) string {
	switch strings.ToLower(strings.TrimSpace(contentType)) {
	case "image/png":
		return "history-" + id + ".png"
	case "image/jpeg", "image/jpg":
		return "history-" + id + ".jpg"
	case "image/gif":
		return "history-" + id + ".gif"
	case "image/webp":
		return "history-" + id + ".webp"
	default:
		return "history-" + id + ".bin"
	}
}
