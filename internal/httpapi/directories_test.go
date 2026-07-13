package httpapi

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func listDirectories(t *testing.T, handler http.Handler, path string) (*httptest.ResponseRecorder, map[string]any) {
	t.Helper()

	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, authedRequest(t, http.MethodPost, "/api/directories/list", map[string]string{
		"path": path,
	}))
	if rec.Code != http.StatusOK {
		return rec, nil
	}
	return rec, decodeJSON(t, rec)
}

func directoryEntryNames(t *testing.T, body map[string]any) []string {
	t.Helper()

	items, ok := body["entries"].([]any)
	if !ok {
		t.Fatalf("entries 响应异常：%v", body)
	}
	names := make([]string, 0, len(items))
	for _, item := range items {
		entry, ok := item.(map[string]any)
		if !ok {
			t.Fatalf("entry 响应异常：%v", item)
		}
		names = append(names, entry["name"].(string))
	}
	return names
}

func TestDirectoryListReturnsSortedChildDirectoriesAndPreviewableFiles(t *testing.T) {
	server := newTestServer(t)
	projectDir := configuredProjectPath(t, server.handler)

	for _, name := range []string{"finance", "Apps", "zeta"} {
		if err := os.Mkdir(filepath.Join(projectDir, name), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	// 隐藏目录、缓存目录不应出现在浏览列表里；普通文件会作为可预览项展示。
	for _, name := range []string{".git", "node_modules", "Library"} {
		if err := os.Mkdir(filepath.Join(projectDir, name), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(projectDir, "README.md"), []byte("demo"), 0o644); err != nil {
		t.Fatal(err)
	}

	rec, body := listDirectories(t, server.handler, projectDir)
	if rec.Code != http.StatusOK {
		t.Fatalf("期望目录浏览返回 200，实际 %d body=%s", rec.Code, rec.Body.String())
	}
	names := directoryEntryNames(t, body)
	want := []string{"Apps", "finance", "zeta", "README.md"}
	if strings.Join(names, ",") != strings.Join(want, ",") {
		t.Fatalf("目录列表应按目录优先、名称排序：got=%v want=%v", names, want)
	}
	realProjectDir, err := filepath.EvalSymlinks(projectDir)
	if err != nil {
		t.Fatal(err)
	}
	entries := body["entries"].([]any)
	first := entries[0].(map[string]any)
	if first["path"] != filepath.Join(realProjectDir, "Apps") {
		t.Fatalf("entry path 应为真实绝对路径：%v", first)
	}
	if first["is_dir"] != true || first["can_open"] != true || first["can_browse"] != true {
		t.Fatalf("allowlist 内子目录应可打开可浏览：%v", first)
	}
	fileEntry := entries[len(entries)-1].(map[string]any)
	if fileEntry["path"] != filepath.Join(realProjectDir, "README.md") {
		t.Fatalf("文件 entry path 应为真实绝对路径：%v", fileEntry)
	}
	if fileEntry["is_dir"] != false || fileEntry["can_open"] != false || fileEntry["can_browse"] != false || fileEntry["can_preview"] != true {
		t.Fatalf("allowlist 内普通文件应只可预览：%v", fileEntry)
	}
}

func TestDirectoryListParentInsideAndOutsideAllowlist(t *testing.T) {
	server := newTestServer(t)
	projectDir := configuredProjectPath(t, server.handler)
	childDir := filepath.Join(projectDir, "finance")
	if err := os.Mkdir(childDir, 0o755); err != nil {
		t.Fatal(err)
	}

	realProjectDir, err := filepath.EvalSymlinks(projectDir)
	if err != nil {
		t.Fatal(err)
	}
	rec, body := listDirectories(t, server.handler, childDir)
	if rec.Code != http.StatusOK {
		t.Fatalf("期望子目录浏览返回 200，实际 %d body=%s", rec.Code, rec.Body.String())
	}
	if body["parent_path"] != realProjectDir {
		t.Fatalf("子目录的 parent_path 应指向上一级真实路径：got=%v want=%s", body["parent_path"], realProjectDir)
	}

	rec, body = listDirectories(t, server.handler, projectDir)
	if rec.Code != http.StatusOK {
		t.Fatalf("期望授权根浏览返回 200，实际 %d body=%s", rec.Code, rec.Body.String())
	}
	if body["parent_path"] != nil {
		t.Fatalf("授权根的 parent_path 应为 null，避免越过允许边界向上爬：%v", body["parent_path"])
	}
}

func TestDirectoryListRejectsOutsidePathWithoutLeakingDetails(t *testing.T) {
	server := newTestServer(t)
	outside := filepath.Join(t.TempDir(), "outside")
	if err := os.Mkdir(outside, 0o755); err != nil {
		t.Fatal(err)
	}

	rec, _ := listDirectories(t, server.handler, outside)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("allowlist 外路径应被拒绝，实际 %d body=%s", rec.Code, rec.Body.String())
	}
	if strings.Contains(rec.Body.String(), outside) {
		t.Fatalf("拒绝响应不应泄漏外部路径：%s", rec.Body.String())
	}
}

func TestDirectoryListRejectsFilePath(t *testing.T) {
	server := newTestServer(t)
	projectDir := configuredProjectPath(t, server.handler)
	filePath := filepath.Join(projectDir, "README.md")
	if err := os.WriteFile(filePath, []byte("demo"), 0o644); err != nil {
		t.Fatal(err)
	}

	rec, _ := listDirectories(t, server.handler, filePath)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("文件路径不能浏览，实际 %d body=%s", rec.Code, rec.Body.String())
	}
}

func TestDirectoryListHidesSymlinkEscapingAllowlist(t *testing.T) {
	server := newTestServer(t)
	projectDir := configuredProjectPath(t, server.handler)

	outside := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(projectDir, "escape")); err != nil {
		t.Fatal(err)
	}
	insideTarget := filepath.Join(projectDir, "real-target")
	if err := os.Mkdir(insideTarget, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(insideTarget, filepath.Join(projectDir, "alias")); err != nil {
		t.Fatal(err)
	}

	rec, body := listDirectories(t, server.handler, projectDir)
	if rec.Code != http.StatusOK {
		t.Fatalf("期望目录浏览返回 200，实际 %d body=%s", rec.Code, rec.Body.String())
	}
	names := directoryEntryNames(t, body)
	want := []string{"alias", "real-target"}
	if strings.Join(names, ",") != strings.Join(want, ",") {
		t.Fatalf("跳出允许根的 symlink 不应出现在列表里：got=%v want=%v", names, want)
	}
}

func TestDirectoryListEmptyPathFallsBackToScanRoot(t *testing.T) {
	var projectDir string
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		projectDir = cfg.Projects[0].Path
		cfg.ScanRoots = []string{projectDir}
	})
	if err := os.Mkdir(filepath.Join(projectDir, "finance"), 0o755); err != nil {
		t.Fatal(err)
	}

	rec, body := listDirectories(t, server.handler, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("空 path 应回落到第一个 scan root，实际 %d body=%s", rec.Code, rec.Body.String())
	}
	realProjectDir, err := filepath.EvalSymlinks(projectDir)
	if err != nil {
		t.Fatal(err)
	}
	if body["path"] != realProjectDir {
		t.Fatalf("默认浏览根应为 scan root 真实路径：got=%v want=%s", body["path"], realProjectDir)
	}
	names := directoryEntryNames(t, body)
	if strings.Join(names, ",") != "finance" {
		t.Fatalf("默认浏览根应能列出子目录：%v", names)
	}
}

func TestDirectoryListEmptyPathWithoutScanRootsFails(t *testing.T) {
	server := newTestServer(t)

	rec, _ := listDirectories(t, server.handler, "")
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("未配置浏览根时空 path 应返回 400，实际 %d body=%s", rec.Code, rec.Body.String())
	}
}

func TestDirectoryListUsesBrowseRootsBoundary(t *testing.T) {
	browseRoot := t.TempDir()
	financeDir := filepath.Join(browseRoot, "finance")
	if err := os.Mkdir(financeDir, 0o755); err != nil {
		t.Fatal(err)
	}
	outside := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(browseRoot, "escape")); err != nil {
		t.Fatal(err)
	}

	var projectDir string
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		projectDir = cfg.Projects[0].Path
		cfg.ScanRoots = []string{projectDir}
		cfg.BrowseRoots = []string{browseRoot}
	})

	realBrowseRoot, err := filepath.EvalSymlinks(browseRoot)
	if err != nil {
		t.Fatal(err)
	}

	// 空 path 优先回落到 browse root，而不是 scan root。
	rec, body := listDirectories(t, server.handler, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("期望浏览 browse root 返回 200，实际 %d body=%s", rec.Code, rec.Body.String())
	}
	if body["path"] != realBrowseRoot {
		t.Fatalf("默认浏览根应优先 browse_roots：got=%v want=%s", body["path"], realBrowseRoot)
	}
	if body["parent_path"] != nil {
		t.Fatalf("browse root 顶层的 parent_path 应为 null：%v", body["parent_path"])
	}
	names := directoryEntryNames(t, body)
	if strings.Join(names, ",") != "finance" {
		t.Fatalf("跳出 browse root 的 symlink 不应出现在列表里：%v", names)
	}

	// 子目录的 parent 回链到 browse root。
	rec, body = listDirectories(t, server.handler, financeDir)
	if rec.Code != http.StatusOK {
		t.Fatalf("期望浏览 browse root 子目录返回 200，实际 %d body=%s", rec.Code, rec.Body.String())
	}
	if body["parent_path"] != realBrowseRoot {
		t.Fatalf("browse root 子目录 parent 应指向 browse root：got=%v want=%s", body["parent_path"], realBrowseRoot)
	}

	// browse root 外仍然 403。
	rec, _ = listDirectories(t, server.handler, outside)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("browse root 外路径应被拒绝，实际 %d body=%s", rec.Code, rec.Body.String())
	}
}
