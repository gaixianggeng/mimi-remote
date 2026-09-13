package httpapi

import (
	"encoding/base64"
	"errors"
	"io/fs"
	"mime"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
)

// pathAccessDeniedMessage 区分“路径不在 allowlist / 不存在”与“OS 拒绝访问”。
// macOS 上照片图库（.photoslibrary）、Mail 等 TCC 保护目录：路径能 stat/EvalSymlinks，
// 但 open/read 会以 EPERM 失败。这不是授权范围问题，应返回与当前平台匹配的可操作提示，
// 避免用户误以为要改 browse_roots。
func pathAccessDeniedMessage(err error) (string, bool) {
	if !errors.Is(err, fs.ErrPermission) {
		return "", false
	}
	if runtime.GOOS == "darwin" {
		return "agentd 无法访问该路径：可能是 macOS 隐私保护目录（如“照片”图库）。请在 系统设置 → 隐私与安全性 → 完全磁盘访问 中允许 agentd（或 Mimi Remote），并重启应用后重试。", true
	}
	return "agentd 无法访问该路径：操作系统拒绝了读取权限。请检查 agentd 运行用户对该路径及其父目录的读取权限，并重启服务后重试。", true
}

// filePreviewMaxBytes 限制单个预览文件大小。QuickLook 适合查看产物，不适合把大文件当下载通道。
var filePreviewMaxBytes int64 = 20 << 20

type fileReadRequest struct {
	Path string `json:"path"`
}

// 文件读取失败的稳定错误码。HTTP 状态保持旧客户端可理解（越界、缺失和权限都仍是 403），
// 新客户端按 code 与 permission_domain 给出准确提示，不再把所有 403 覆盖成同一句话。
const (
	fileReadCodePathOutsideScope = "path_outside_scope"
	fileReadCodeAccessDenied     = "file_access_denied"
	fileReadCodeNotFound         = "file_not_found"
	fileReadCodeReadFailed       = "file_read_failed"
)

type fileReadErrorResponse struct {
	Error            string `json:"error"`
	Code             string `json:"code"`
	PermissionDomain string `json:"permission_domain,omitempty"`
	Action           string `json:"action,omitempty"`
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
	resolved, resolveErr := r.resolveReadableFilePath(path)
	if resolveErr != nil {
		r.writeFileReadError(w, path, resolveErr)
		return
	}
	realPath := resolved.realPath
	stat, err := os.Stat(realPath)
	if err != nil {
		r.writeFileReadError(w, path, err)
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
		r.writeFileReadError(w, path, err)
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

var errFilePathOutsideScope = errors.New("file path outside scope")
var evalFileSymlinks = filepath.EvalSymlinks

func (r *Router) resolveReadableFilePath(raw string) (fileReadResolvedPath, error) {
	if scope, ok := r.gatewayScopeForPath(raw); ok {
		return fileReadResolvedPath{realPath: scope.realPath}, nil
	}
	// gateway resolver 使用 EvalSymlinks 验证边界。目标缺失或被 macOS 拒绝时，
	// 仍需在既有授权根内保留原始错误，避免把 ENOENT/EPERM 误报为越界。
	if r.filePathLexicallyInScope(raw) {
		abs, err := filepath.Abs(strings.TrimSpace(raw))
		if err != nil {
			return fileReadResolvedPath{}, errFilePathOutsideScope
		}
		if _, err := evalFileSymlinks(abs); err != nil {
			return fileReadResolvedPath{}, err
		}
		// 能成功解析却未通过 gateway 的路径可能经符号链接逃逸，必须继续拒绝。
		return fileReadResolvedPath{}, errFilePathOutsideScope
	}
	// iPad 只能拿到 Mac 上的文件路径，无法直接访问 Photos Library。
	// 这里额外放行系统照片库的 derivatives 图片，保持预览可用，同时避免扩大成任意路径读取。
	if realPath, candidate, err := resolveAllowedPhotosDerivativeImagePath(raw); candidate {
		if err != nil {
			return fileReadResolvedPath{}, err
		}
		if realPath == "" {
			return fileReadResolvedPath{}, errFilePathOutsideScope
		}
		return fileReadResolvedPath{realPath: realPath, photosDerivativeImage: true}, nil
	}
	// Codex 桌面端把剪贴板图片写到当前 macOS 用户的临时目录，再在会话里保存 localImage 路径。
	// 只放行严格命名且可验证为图片的普通文件，不能把整个 /var/folders 暴露成 browse root。
	if runtime.GOOS == "darwin" {
		if realPath, ok := allowedCodexClipboardImagePath(raw, os.TempDir()); ok {
			return fileReadResolvedPath{realPath: realPath, codexClipboardImage: true}, nil
		}
	}
	return fileReadResolvedPath{}, errFilePathOutsideScope
}

func (r *Router) filePathLexicallyInScope(raw string) bool {
	abs, err := filepath.Abs(strings.TrimSpace(raw))
	if err != nil {
		return false
	}
	if r.projects != nil {
		for _, project := range r.projects.List() {
			projectAbs, _ := filepath.Abs(project.Path)
			if realPathWithin(project.RealPath, abs) || realPathWithin(projectAbs, abs) {
				return true
			}
		}
	}
	for _, root := range r.cfg.BrowseRoots {
		rootAbs, err := filepath.Abs(strings.TrimSpace(root))
		if err == nil && realPathWithin(rootAbs, abs) {
			return true
		}
	}
	return false
}

func (r *Router) writeFileReadError(w http.ResponseWriter, path string, err error) {
	response := fileReadErrorResponse{Error: "路径不在允许范围内或不可访问", Code: fileReadCodePathOutsideScope}
	status := http.StatusForbidden
	switch {
	case errors.Is(err, fs.ErrNotExist):
		// 旧版 iOS 把 404/405 解释为“agentd 不支持文件预览”。继续返回 403，
		// 新版客户端通过稳定 code 区分文件缺失，旧版则保留原有通用提示。
		response.Error = "文件不存在"
		response.Code = fileReadCodeNotFound
	case errors.Is(err, fs.ErrPermission):
		response.Code = fileReadCodeAccessDenied
		domain := ""
		if r.doctor != nil && isMacOSTCCPermissionCandidate(err) {
			triggered := false
			domain, triggered = r.doctor.RequestFileAccess(path)
			if domain != "" {
				response.PermissionDomain = domain
			}
			if triggered {
				response.Action = "allow_on_mac"
			}
		}
		response.Error = fileAccessDeniedMessage(domain)
	case errors.Is(err, errFilePathOutsideScope):
	default:
		status = http.StatusInternalServerError
		response.Error = "读取文件失败"
		response.Code = fileReadCodeReadFailed
	}
	writeJSON(w, status, response)
}

// EACCES 是普通 POSIX 权限，不会触发 macOS 文件夹授权；只有 EPERM 才可能来自 TCC。
func isMacOSTCCPermissionCandidate(err error) bool {
	return runtime.GOOS == "darwin" && errors.Is(err, syscall.EPERM)
}

// fileAccessDeniedMessage 按权限域给出可执行提示。当前 TCC 主体是后台服务 agentd 本身
// （App 安装版位于 Mimi Remote Mac.app 内，Homebrew 版为独立二进制），照片图库不属于
// “文件与文件夹”，只能通过完全磁盘访问放行。
func fileAccessDeniedMessage(domain string) string {
	if runtime.GOOS != "darwin" {
		return "agentd 无法访问该路径：操作系统拒绝了读取权限。请检查 agentd 运行用户对该路径及其父目录的读取权限，并重启服务后重试。"
	}
	if domain == "photos_library" {
		return "agentd 无法访问照片图库：它与“图片”文件夹使用不同的权限。请在 Mac 的 系统设置 → 隐私与安全性 → 完全磁盘访问 中添加 agentd（App 安装版位于 Mimi Remote Mac.app 内，Homebrew 版为 /opt/homebrew/opt/mimi-remote/bin/agentd），然后重试。"
	}
	labels := map[string]string{
		"desktop":   "桌面",
		"documents": "文稿",
		"downloads": "下载",
	}
	if label, ok := labels[domain]; ok {
		return "agentd 无法访问“" + label + "”文件夹。请在 Mac 上允许系统弹出的访问提示；如果没有提示或之前拒绝过，请在 系统设置 → 隐私与安全性 → 文件与文件夹 或 完全磁盘访问 中为 agentd 开启，然后重试。"
	}
	return "agentd 无法读取该文件。请检查该文件及父目录的读取权限后重试。"
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

// resolveAllowedPhotosDerivativeImagePath 返回 (realPath, candidate, err)。candidate 表示
// 路径在结构上属于 Pictures 下某个 .photoslibrary 的 derivatives；此时解析失败要保留
// ENOENT/EPERM，让调用方区分“照片图库被 macOS 拒绝”和“越界”。
func resolveAllowedPhotosDerivativeImagePath(raw string) (string, bool, error) {
	path := strings.TrimSpace(raw)
	if path == "" {
		return "", false, nil
	}
	if _, ok := filePreviewImageExtensions[strings.ToLower(filepath.Ext(path))]; !ok {
		return "", false, nil
	}

	abs, err := filepath.Abs(path)
	if err != nil {
		return "", false, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", false, nil
	}
	picturesRoot := filepath.Join(home, "Pictures")
	if !realPathWithin(picturesRoot, abs) || !photosDerivativePathStructure(abs) {
		return "", false, nil
	}

	realPath, err := evalFileSymlinks(abs)
	if err != nil {
		return "", true, err
	}
	realPicturesRoot, err := evalFileSymlinks(picturesRoot)
	if err != nil {
		realPicturesRoot, err = filepath.Abs(picturesRoot)
		if err != nil {
			return "", true, err
		}
	}
	if !realPathWithin(realPicturesRoot, realPath) || !photosDerivativePathStructure(realPath) {
		return "", true, nil
	}
	return realPath, true, nil
}

func photosDerivativePathStructure(path string) bool {
	parts := strings.Split(filepath.ToSlash(path), "/")
	for idx, part := range parts {
		if !strings.HasSuffix(strings.ToLower(part), ".photoslibrary") {
			continue
		}
		if idx+2 < len(parts) &&
			strings.EqualFold(parts[idx+1], "resources") &&
			strings.EqualFold(parts[idx+2], "derivatives") {
			return true
		}
	}
	return false
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
