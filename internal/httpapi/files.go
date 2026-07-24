package httpapi

import (
	"encoding/base64"
	"mime"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

// filePreviewMaxBytes 限制单个预览文件大小。QuickLook 适合查看产物，不适合把大文件当下载通道。
var filePreviewMaxBytes int64 = 20 << 20

type fileReadRequest struct {
	Path string `json:"path"`
}

type fileReadResponse struct {
	Path              string `json:"path"`
	Name              string `json:"name"`
	ContentType       string `json:"content_type"`
	Size              int64  `json:"size"`
	ContentBase64     string `json:"content_base64"`
	OriginalByteCount int64  `json:"original_byte_count,omitempty"`
}

type fileReadResolvedPath struct {
	realPath              string
	photosDerivativeImage bool
	codexClipboardImage   bool
}

var filePreviewImageExtensions = map[string]struct{}{
	".gif":  {},
	".heic": {},
	".jpeg": {},
	".jpg":  {},
	".png":  {},
	".webp": {},
}

var codexClipboardImageExtensions = map[string]struct{}{
	".jpeg": {},
	".jpg":  {},
	".png":  {},
}

func (r *Router) fileReadHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		methodNotAllowed(w)
		return
	}

	var payload fileReadRequest
	if !decodeJSONRequest(w, req, &payload) {
		return
	}

	path := strings.TrimSpace(payload.Path)
	if path == "" {
		writeError(w, http.StatusBadRequest, "path 不能为空")
		return
	}
	resolved, ok := r.resolveReadableFilePath(path)
	if !ok {
		writeError(w, http.StatusForbidden, "路径不在允许范围内或不可访问")
		return
	}
	realPath := resolved.realPath
	stat, err := os.Stat(realPath)
	if err != nil {
		writeError(w, http.StatusForbidden, "路径不在允许范围内或不可访问")
		return
	}
	if stat.IsDir() {
		writeError(w, http.StatusBadRequest, "路径不是文件")
		return
	}
	if !stat.Mode().IsRegular() {
		writeError(w, http.StatusBadRequest, "仅支持普通文件预览")
		return
	}
	if stat.Size() > filePreviewMaxBytes {
		writeError(w, http.StatusRequestEntityTooLarge, "文件过大，暂不支持预览")
		return
	}

	data, err := os.ReadFile(realPath)
	if err != nil {
		writeError(w, http.StatusForbidden, "路径不在允许范围内或不可访问")
		return
	}
	contentType := detectFileContentType(realPath, data)
	if resolved.codexClipboardImage {
		// 剪贴板临时目录不属于项目授权根，不能只相信扩展名；必须用文件头再次确认。
		contentType = detectFileContentTypeFromBytes(data)
	}
	if (resolved.photosDerivativeImage || resolved.codexClipboardImage) &&
		!strings.HasPrefix(contentType, "image/") {
		writeError(w, http.StatusBadRequest, "仅支持图片预览")
		return
	}
	writeJSON(w, http.StatusOK, fileReadResponse{
		Path:          realPath,
		Name:          filepath.Base(realPath),
		ContentType:   contentType,
		Size:          int64(len(data)),
		ContentBase64: base64.StdEncoding.EncodeToString(data),
	})
}

func (r *Router) resolveReadableFilePath(raw string) (fileReadResolvedPath, bool) {
	if scope, ok := r.gatewayScopeForPath(raw); ok {
		return fileReadResolvedPath{realPath: scope.realPath}, true
	}
	// iPad 只能拿到 Mac 上的文件路径，无法直接访问 Photos Library。
	// 这里额外放行系统照片库的 derivatives 图片，保持预览可用，同时避免扩大成任意路径读取。
	if realPath, ok := allowedPhotosDerivativeImagePath(raw); ok {
		return fileReadResolvedPath{realPath: realPath, photosDerivativeImage: true}, true
	}
	// Codex 桌面端把剪贴板图片写到当前 macOS 用户的临时目录，再在会话里保存 localImage 路径。
	// 只放行严格命名且可验证为图片的普通文件，不能把整个 /var/folders 暴露成 browse root。
	if runtime.GOOS == "darwin" {
		if realPath, ok := allowedCodexClipboardImagePath(raw, os.TempDir()); ok {
			return fileReadResolvedPath{realPath: realPath, codexClipboardImage: true}, true
		}
	}
	return fileReadResolvedPath{}, false
}

func allowedCodexClipboardImagePath(raw string, temporaryRoot string) (string, bool) {
	path := strings.TrimSpace(raw)
	root := strings.TrimSpace(temporaryRoot)
	if path == "" || root == "" || !isCodexClipboardImageName(filepath.Base(path)) {
		return "", false
	}

	abs, err := filepath.Abs(path)
	if err != nil {
		return "", false
	}
	// 最终文件本身不允许是符号链接；否则攻击者可以用可信文件名指向任意文件。
	info, err := os.Lstat(abs)
	if err != nil || info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return "", false
	}
	realPath, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return "", false
	}
	realRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		realRoot, err = filepath.Abs(root)
		if err != nil {
			return "", false
		}
	}
	if filepath.Clean(filepath.Dir(realPath)) != filepath.Clean(realRoot) ||
		!isCodexClipboardImageName(filepath.Base(realPath)) {
		return "", false
	}
	return realPath, true
}

func isCodexClipboardImageName(name string) bool {
	const prefix = "codex-clipboard-"
	ext := strings.ToLower(filepath.Ext(name))
	if _, ok := codexClipboardImageExtensions[ext]; !ok {
		return false
	}
	stem := strings.TrimSuffix(name, filepath.Ext(name))
	if !strings.HasPrefix(stem, prefix) {
		return false
	}
	id := strings.TrimPrefix(stem, prefix)
	if len(id) != 36 || id[8] != '-' || id[13] != '-' || id[18] != '-' || id[23] != '-' {
		return false
	}
	for index, value := range id {
		if index == 8 || index == 13 || index == 18 || index == 23 {
			continue
		}
		if !((value >= '0' && value <= '9') || (value >= 'a' && value <= 'f') || (value >= 'A' && value <= 'F')) {
			return false
		}
	}
	return true
}

func allowedPhotosDerivativeImagePath(raw string) (string, bool) {
	path := strings.TrimSpace(raw)
	if path == "" {
		return "", false
	}
	if _, ok := filePreviewImageExtensions[strings.ToLower(filepath.Ext(path))]; !ok {
		return "", false
	}

	abs, err := filepath.Abs(path)
	if err != nil {
		return "", false
	}
	realPath, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return "", false
	}

	home, err := os.UserHomeDir()
	if err != nil {
		return "", false
	}
	picturesRoot := filepath.Join(home, "Pictures")
	realPicturesRoot, err := filepath.EvalSymlinks(picturesRoot)
	if err != nil {
		realPicturesRoot, err = filepath.Abs(picturesRoot)
		if err != nil {
			return "", false
		}
	}
	if !realPathWithin(realPicturesRoot, realPath) {
		return "", false
	}

	parts := strings.Split(filepath.ToSlash(realPath), "/")
	for idx, part := range parts {
		if !strings.HasSuffix(strings.ToLower(part), ".photoslibrary") {
			continue
		}
		if idx+2 < len(parts) &&
			strings.EqualFold(parts[idx+1], "resources") &&
			strings.EqualFold(parts[idx+2], "derivatives") {
			return realPath, true
		}
	}
	return "", false
}

func detectFileContentType(path string, data []byte) string {
	if value := mime.TypeByExtension(strings.ToLower(filepath.Ext(path))); value != "" {
		return value
	}
	return detectFileContentTypeFromBytes(data)
}

func detectFileContentTypeFromBytes(data []byte) string {
	if len(data) == 0 {
		return "application/octet-stream"
	}
	sample := data
	if len(sample) > 512 {
		sample = sample[:512]
	}
	return http.DetectContentType(sample)
}
