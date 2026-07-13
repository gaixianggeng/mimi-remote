package httpapi

import (
	"encoding/base64"
	"mime"
	"net/http"
	"os"
	"path/filepath"
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
}

var filePreviewImageExtensions = map[string]struct{}{
	".gif":  {},
	".heic": {},
	".jpeg": {},
	".jpg":  {},
	".png":  {},
	".webp": {},
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
	if resolved.photosDerivativeImage && !strings.HasPrefix(contentType, "image/") {
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
	return fileReadResolvedPath{}, false
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
	if len(data) == 0 {
		return "application/octet-stream"
	}
	sample := data
	if len(sample) > 512 {
		sample = sample[:512]
	}
	return http.DetectContentType(sample)
}
