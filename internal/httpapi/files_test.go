package httpapi

import (
	"encoding/base64"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
)

func readPreviewFile(t *testing.T, handler http.Handler, path string) (*httptest.ResponseRecorder, map[string]any) {
	t.Helper()

	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/files/read", map[string]string{
		"path": path,
	}))
	if rec.Code != http.StatusOK {
		return rec, nil
	}
	return rec, decodeJSON(t, rec)
}

func TestFileReadReturnsAllowedFilePayload(t *testing.T) {
	server := newTestServer(t)
	projectDir := configuredProjectPath(t, server.handler)
	filePath := filepath.Join(projectDir, "notes.txt")
	if err := os.WriteFile(filePath, []byte("hello\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	rec, body := readPreviewFile(t, server.handler, filePath)
	if rec.Code != http.StatusOK {
		t.Fatalf("授权文件应可读取，got=%d body=%s", rec.Code, rec.Body.String())
	}
	realPath, err := filepath.EvalSymlinks(filePath)
	if err != nil {
		t.Fatal(err)
	}
	if body["path"] != realPath || body["name"] != "notes.txt" {
		t.Fatalf("响应应包含真实路径和文件名：%v", body)
	}
	if body["size"] != float64(len("hello\n")) {
		t.Fatalf("响应 size 不正确：%v", body)
	}
	if !strings.HasPrefix(body["content_type"].(string), "text/plain") {
		t.Fatalf("notes.txt 应识别为普通文本：%v", body["content_type"])
	}
	data, err := base64.StdEncoding.DecodeString(body["content_base64"].(string))
	if err != nil {
		t.Fatalf("content_base64 应可解码：%v", err)
	}
	if string(data) != "hello\n" {
		t.Fatalf("文件内容不正确：%q", string(data))
	}
}

func TestFileReadRejectsOutsidePathWithoutLeakingDetails(t *testing.T) {
	server := newTestServer(t)
	outside := filepath.Join(t.TempDir(), "secret.txt")
	if err := os.WriteFile(outside, []byte("secret"), 0o644); err != nil {
		t.Fatal(err)
	}

	rec, _ := readPreviewFile(t, server.handler, outside)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("allowlist 外文件应被拒绝，got=%d body=%s", rec.Code, rec.Body.String())
	}
	if strings.Contains(rec.Body.String(), outside) {
		t.Fatalf("拒绝响应不应泄漏外部路径：%s", rec.Body.String())
	}
	body := decodeJSON(t, rec)
	if body["code"] != fileReadCodePathOutsideScope || body["error"] == nil {
		t.Fatalf("越界响应应保留 error 并返回稳定 code：%v", body)
	}
}

func TestFileReadReportsMissingFileInsideScope(t *testing.T) {
	server := newTestServer(t)
	missing := filepath.Join(configuredProjectPath(t, server.handler), "missing.md")
	rec, _ := readPreviewFile(t, server.handler, missing)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("授权范围内缺失文件应为旧客户端保留 403，got=%d body=%s", rec.Code, rec.Body.String())
	}
	body := decodeJSON(t, rec)
	if body["code"] != fileReadCodeNotFound || body["error"] == nil {
		t.Fatalf("缺失响应应保留 error 并返回稳定 code：%v", body)
	}
}

func TestFileReadReportsPermissionDeniedWithActionableGuidance(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows 不用 Unix 权限位模拟 TCC 拒绝")
	}
	server := newTestServer(t)
	projectDir := configuredProjectPath(t, server.handler)
	filePath := filepath.Join(projectDir, "locked.txt")
	if err := os.WriteFile(filePath, []byte("secret"), 0o000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(filePath, 0o644) })

	rec, _ := readPreviewFile(t, server.handler, filePath)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("OS 拒绝访问应返回 403，got=%d body=%s", rec.Code, rec.Body.String())
	}
	// 路径明明在授权范围内，OS 拒绝时不能再报“不在允许范围内”，否则用户会去改 browse_roots。
	if strings.Contains(rec.Body.String(), "不在允许范围内") {
		t.Fatalf("授权路径的权限拒绝不应报成 allowlist 问题：%s", rec.Body.String())
	}
	// decodeJSON 会读空 recorder body，文本断言必须先取快照。
	bodyText := rec.Body.String()
	body := decodeJSON(t, rec)
	if body["code"] != fileReadCodeAccessDenied || body["error"] == nil {
		t.Fatalf("权限拒绝应保留 error 并返回稳定 code：%v", body)
	}
	if runtime.GOOS == "darwin" {
		// 0o000 触发的是 EACCES：普通 POSIX 权限，不是 TCC，不能误导用户去开完全磁盘访问。
		if strings.Contains(bodyText, "完全磁盘访问") || body["permission_domain"] != nil {
			t.Fatalf("普通文件权限拒绝不能误导用户授予完全磁盘访问：%s", bodyText)
		}
		return
	}
	if strings.Contains(bodyText, "完全磁盘访问") ||
		!strings.Contains(bodyText, "运行用户") {
		t.Fatalf("非 macOS 权限拒绝应提示检查服务运行用户权限：%s", bodyText)
	}
}

func TestFileAccessDeniedMessageMatchesMacPermissionDomain(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS 文件夹授权提示只在 macOS 生效")
	}
	documents := fileAccessDeniedMessage("documents")
	if !strings.Contains(documents, "文稿") || !strings.Contains(documents, "文件与文件夹") || !strings.Contains(documents, "agentd") {
		t.Fatalf("文稿权限提示应指向文件与文件夹并点名 agentd：%s", documents)
	}
	photos := fileAccessDeniedMessage("photos_library")
	if !strings.Contains(photos, "照片图库") || !strings.Contains(photos, "完全磁盘访问") || !strings.Contains(photos, "Mimi Remote Mac.app") {
		t.Fatalf("照片图库权限提示应指向完全磁盘访问并说明 agentd 位置：%s", photos)
	}
	other := fileAccessDeniedMessage("")
	if strings.Contains(other, "完全磁盘访问") {
		t.Fatalf("非标准目录的权限拒绝不应引导完全磁盘访问：%s", other)
	}
}

func TestFileReadReportsUnexpectedResolverFailure(t *testing.T) {
	server := newTestServer(t)
	projectDir := configuredProjectPath(t, server.handler)
	path := filepath.Join(projectDir, strings.Repeat("x", 5000))
	rec, _ := readPreviewFile(t, server.handler, path)
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("非 ENOENT/EPERM 解析错误应返回 500，got=%d body=%s", rec.Code, rec.Body.String())
	}
	body := decodeJSON(t, rec)
	if body["code"] != fileReadCodeReadFailed || body["error"] == nil {
		t.Fatalf("未知读取错误应返回 file_read_failed：%v", body)
	}
}

func TestPhotosDerivativeResolverPreservesCandidateErrorsAndRejectsEscape(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	target := filepath.Join(home, "Pictures", "Photos Library.photoslibrary", "resources", "derivatives", "2", "image.jpeg")
	pictures := filepath.Join(home, "Pictures")
	original := evalFileSymlinks
	t.Cleanup(func() { evalFileSymlinks = original })

	for _, wantErr := range []error{syscall.EPERM, syscall.ENOENT} {
		evalFileSymlinks = func(path string) (string, error) {
			if path == target {
				return "", wantErr
			}
			return path, nil
		}
		if _, candidate, err := resolveAllowedPhotosDerivativeImagePath(target); !candidate || !errors.Is(err, wantErr) {
			t.Fatalf("合法照片 derivatives 候选应保留 %v：candidate=%v err=%v", wantErr, candidate, err)
		}
	}

	escape := filepath.Join(t.TempDir(), "escaped.jpeg")
	evalFileSymlinks = func(path string) (string, error) {
		if path == target {
			return escape, nil
		}
		if path == pictures {
			return pictures, nil
		}
		return path, nil
	}
	if resolved, candidate, err := resolveAllowedPhotosDerivativeImagePath(target); !candidate || err != nil || resolved != "" {
		t.Fatalf("成功解析到 Pictures 外时必须拒绝：resolved=%q candidate=%v err=%v", resolved, candidate, err)
	}
}

func TestFileReadPhotosLibraryEPERMReportsPhotosPermissionDomain(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("照片图库权限域只在 macOS 生效")
	}
	home := t.TempDir()
	t.Setenv("HOME", home)
	target := filepath.Join(home, "Pictures", "Photos Library.photoslibrary", "resources", "derivatives", "2", "image.jpeg")
	original := evalFileSymlinks
	t.Cleanup(func() { evalFileSymlinks = original })
	evalFileSymlinks = func(path string) (string, error) {
		if path == target {
			return "", &os.PathError{Op: "lstat", Path: path, Err: syscall.EPERM}
		}
		return path, nil
	}
	server := newTestServer(t)
	rec, _ := readPreviewFile(t, server.handler, target)
	bodyText := rec.Body.String()
	if rec.Code != http.StatusForbidden {
		t.Fatalf("照片图库被 TCC 拒绝应返回 403，got=%d body=%s", rec.Code, bodyText)
	}
	body := decodeJSON(t, rec)
	if body["code"] != fileReadCodeAccessDenied || body["permission_domain"] != "photos_library" || body["action"] != "allow_on_mac" {
		t.Fatalf("照片图库 EPERM 应带 photos_library 权限域与 Mac 授权动作：%v", body)
	}
	if !strings.Contains(bodyText, "完全磁盘访问") {
		t.Fatalf("照片图库权限拒绝应引导完全磁盘访问：%s", bodyText)
	}
}

func TestFileReadOnlyTreatsEPERMAsMacOSTCCCandidate(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("TCC 候选仅适用于 macOS")
	}
	if !isMacOSTCCPermissionCandidate(syscall.EPERM) {
		t.Fatal("EPERM 应视为 macOS TCC 候选")
	}
	if isMacOSTCCPermissionCandidate(syscall.EACCES) {
		t.Fatal("EACCES 是普通文件权限错误，不能触发 TCC 探测")
	}
	rec := httptest.NewRecorder()
	(&Router{}).writeFileReadError(rec, "/no/path/leak", syscall.EACCES)
	body := decodeJSON(t, rec)
	if body["code"] != fileReadCodeAccessDenied || body["permission_domain"] != nil || body["action"] != nil {
		t.Fatalf("EACCES 不应携带权限域或 Mac 授权动作：%v", body)
	}
}

func TestFileReadAllowsPhotosDerivativeImage(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)

	server := newTestServer(t)
	photoDir := filepath.Join(home, "Pictures", "Photos Library.photoslibrary", "resources", "derivatives", "2")
	if err := os.MkdirAll(photoDir, 0o755); err != nil {
		t.Fatal(err)
	}
	imagePath := filepath.Join(photoDir, "screen shot.jpeg")
	imageBytes := []byte{0xff, 0xd8, 0xff, 0xd9}
	if err := os.WriteFile(imagePath, imageBytes, 0o644); err != nil {
		t.Fatal(err)
	}

	rec, body := readPreviewFile(t, server.handler, imagePath)
	if rec.Code != http.StatusOK {
		t.Fatalf("照片库 derivatives 图片应可读取，got=%d body=%s", rec.Code, rec.Body.String())
	}
	realPath, err := filepath.EvalSymlinks(imagePath)
	if err != nil {
		t.Fatal(err)
	}
	if body["path"] != realPath || body["name"] != "screen shot.jpeg" {
		t.Fatalf("响应应包含照片真实路径和文件名：%v", body)
	}
	if !strings.HasPrefix(body["content_type"].(string), "image/jpeg") {
		t.Fatalf("照片库 jpeg 应识别为图片：%v", body["content_type"])
	}
	data, err := base64.StdEncoding.DecodeString(body["content_base64"].(string))
	if err != nil {
		t.Fatalf("content_base64 应可解码：%v", err)
	}
	if string(data) != string(imageBytes) {
		t.Fatalf("文件内容不正确：%v", data)
	}
}

func TestFileReadRejectsPhotosLibraryOutsideDerivatives(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	server := newTestServer(t)
	photoDir := filepath.Join(home, "Pictures", "Photos Library.photoslibrary", "originals")
	if err := os.MkdirAll(photoDir, 0o755); err != nil {
		t.Fatal(err)
	}
	imagePath := filepath.Join(photoDir, "original.jpeg")
	if err := os.WriteFile(imagePath, []byte{0xff, 0xd8, 0xff, 0xd9}, 0o644); err != nil {
		t.Fatal(err)
	}

	rec, _ := readPreviewFile(t, server.handler, imagePath)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("非 derivatives 照片库文件应被拒绝，got=%d body=%s", rec.Code, rec.Body.String())
	}
}

func TestFileReadRejectsOutsideImagePath(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	server := newTestServer(t)
	outside := filepath.Join(t.TempDir(), "outside.jpeg")
	if err := os.WriteFile(outside, []byte{0xff, 0xd8, 0xff, 0xd9}, 0o644); err != nil {
		t.Fatal(err)
	}

	rec, _ := readPreviewFile(t, server.handler, outside)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("普通外部图片仍应被拒绝，got=%d body=%s", rec.Code, rec.Body.String())
	}
}

func TestFileReadAllowsCodexClipboardTemporaryImageOnMacOS(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("Codex 桌面剪贴板临时路径只在 macOS 放行")
	}

	server := newTestServer(t)
	imagePath := filepath.Join(os.TempDir(), "codex-clipboard-9ba62714-bcfb-4693-805b-1be6e284e924.png")
	t.Cleanup(func() { _ = os.Remove(imagePath) })
	imageBytes := append(
		[]byte{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A},
		make([]byte, 512)...,
	)
	if err := os.WriteFile(imagePath, imageBytes, 0o600); err != nil {
		t.Fatal(err)
	}

	rec, body := readPreviewFile(t, server.handler, imagePath)
	if rec.Code != http.StatusOK {
		t.Fatalf("可信 Codex 剪贴板图片应可读取，got=%d body=%s", rec.Code, rec.Body.String())
	}
	if body["name"] != filepath.Base(imagePath) || body["content_type"] != "image/png" {
		t.Fatalf("响应应保留剪贴板图片名称并验证真实图片类型：%v", body)
	}
}

func TestAllowedCodexClipboardImagePathRejectsUnsafeVariants(t *testing.T) {
	tempRoot := t.TempDir()
	validName := "codex-clipboard-9ba62714-bcfb-4693-805b-1be6e284e924.png"
	validPath := filepath.Join(tempRoot, validName)
	if err := os.WriteFile(validPath, []byte("not inspected by path resolver"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got, ok := allowedCodexClipboardImagePath(validPath, tempRoot); !ok || got == "" {
		t.Fatalf("严格命名的普通文件应通过路径阶段校验：got=%q ok=%v", got, ok)
	}

	invalidNamePath := filepath.Join(tempRoot, "codex-clipboard-not-a-uuid.png")
	if err := os.WriteFile(invalidNamePath, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, ok := allowedCodexClipboardImagePath(invalidNamePath, tempRoot); ok {
		t.Fatal("非 UUID 剪贴板文件名不应放行")
	}

	outsideRoot := t.TempDir()
	outsidePath := filepath.Join(outsideRoot, validName)
	if err := os.WriteFile(outsidePath, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, ok := allowedCodexClipboardImagePath(outsidePath, tempRoot); ok {
		t.Fatal("临时授权根之外的同名文件不应放行")
	}

	nestedDir := filepath.Join(tempRoot, "nested")
	if err := os.Mkdir(nestedDir, 0o700); err != nil {
		t.Fatal(err)
	}
	nestedPath := filepath.Join(nestedDir, validName)
	if err := os.WriteFile(nestedPath, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, ok := allowedCodexClipboardImagePath(nestedPath, tempRoot); ok {
		t.Fatal("只允许临时目录直属的 Codex 剪贴板图片，不能递归放行子目录")
	}

	targetPath := filepath.Join(tempRoot, "target.png")
	if err := os.WriteFile(targetPath, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	symlinkPath := filepath.Join(tempRoot, "codex-clipboard-15031bdc-111a-4669-b3e6-4ef5f2094829.png")
	requireTestSymlink(t, targetPath, symlinkPath)
	if _, ok := allowedCodexClipboardImagePath(symlinkPath, tempRoot); ok {
		t.Fatal("符号链接伪装成剪贴板图片时不应放行")
	}
}

func TestFileReadRejectsFakeCodexClipboardImageContentOnMacOS(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("Codex 桌面剪贴板临时路径只在 macOS 放行")
	}

	server := newTestServer(t)
	fakeImagePath := filepath.Join(os.TempDir(), "codex-clipboard-f64f3119-46f6-479a-b93d-abc5d81f879f.png")
	t.Cleanup(func() { _ = os.Remove(fakeImagePath) })
	if err := os.WriteFile(fakeImagePath, []byte("plain text with a png extension"), 0o600); err != nil {
		t.Fatal(err)
	}

	rec, _ := readPreviewFile(t, server.handler, fakeImagePath)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("只有扩展名、没有图片文件头的临时文件应被拒绝，got=%d body=%s", rec.Code, rec.Body.String())
	}
}

func TestFileReadRejectsDirectoryPath(t *testing.T) {
	server := newTestServer(t)
	projectDir := configuredProjectPath(t, server.handler)

	rec, _ := readPreviewFile(t, server.handler, projectDir)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("目录不能作为文件预览，got=%d body=%s", rec.Code, rec.Body.String())
	}
}

func TestFileReadRejectsLargeFile(t *testing.T) {
	previousLimit := filePreviewMaxBytes
	filePreviewMaxBytes = 4
	t.Cleanup(func() {
		filePreviewMaxBytes = previousLimit
	})

	server := newTestServer(t)
	projectDir := configuredProjectPath(t, server.handler)
	filePath := filepath.Join(projectDir, "large.txt")
	if err := os.WriteFile(filePath, []byte("12345"), 0o644); err != nil {
		t.Fatal(err)
	}

	rec, _ := readPreviewFile(t, server.handler, filePath)
	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("超限文件应被拒绝，got=%d body=%s", rec.Code, rec.Body.String())
	}
}

func TestFileReadReportsMissingFileUnderSymlinkedBrowseRoot(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows 创建符号链接需要额外权限")
	}
	realRoot := t.TempDir()
	linkParent := t.TempDir()
	linkRoot := filepath.Join(linkParent, "browse-link")
	if err := os.Symlink(realRoot, linkRoot); err != nil {
		t.Fatal(err)
	}
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.BrowseRoots = []string{linkRoot}
	})
	canonicalRoot, err := filepath.EvalSymlinks(realRoot)
	if err != nil {
		t.Fatal(err)
	}
	// 目录浏览返回的是 canonical 路径；文件在预览前被删掉时应报缺失而不是越界。
	missing := filepath.Join(canonicalRoot, "docs", "gone.md")
	rec, _ := readPreviewFile(t, server.handler, missing)
	body := decodeJSON(t, rec)
	if rec.Code != http.StatusForbidden || body["code"] != fileReadCodeNotFound {
		t.Fatalf("符号链接 browse root 下的缺失文件应返回 file_not_found，got=%d body=%v", rec.Code, body)
	}
	outside := filepath.Join(t.TempDir(), "gone.md")
	rec, _ = readPreviewFile(t, server.handler, outside)
	body = decodeJSON(t, rec)
	if body["code"] != fileReadCodePathOutsideScope {
		t.Fatalf("授权根之外的缺失文件仍应返回 path_outside_scope，got=%v", body)
	}
}

func TestFileReadReportsMissingFileInManagedWorktree(t *testing.T) {
	worktreesRoot := t.TempDir()
	checkout := filepath.Join(worktreesRoot, "checkouts", "repo", "review")
	if err := os.MkdirAll(checkout, 0o755); err != nil {
		t.Fatal(err)
	}
	canonicalCheckout, err := filepath.EvalSymlinks(checkout)
	if err != nil {
		t.Fatal(err)
	}
	projectDir := t.TempDir()
	writeManagedWorktreeRegistryForTest(t, worktreesRoot, managedWorktree{
		Path:        canonicalCheckout,
		RootProject: projects.Project{ID: "repo", Name: "Repo", Path: projectDir, RealPath: projectDir},
	})
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.WorktreesRoot = worktreesRoot
		cfg.Projects = []config.ProjectConfig{{ID: "repo", Name: "Repo", Path: projectDir}}
	})
	missing := filepath.Join(canonicalCheckout, "notes", "deleted.md")
	rec, _ := readPreviewFile(t, server.handler, missing)
	body := decodeJSON(t, rec)
	if rec.Code != http.StatusForbidden || body["code"] != fileReadCodeNotFound {
		t.Fatalf("已登记托管 worktree 内的缺失文件应返回 file_not_found，got=%d body=%v", rec.Code, body)
	}
}
