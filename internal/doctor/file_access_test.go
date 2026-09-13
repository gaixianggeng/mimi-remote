package doctor

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
)

func TestFileAccessPreflightTargetsExpandProtectedHomeDirectories(t *testing.T) {
	home := t.TempDir()
	projectPath := filepath.Join(home, "code", "demo")
	if err := os.MkdirAll(projectPath, 0o755); err != nil {
		t.Fatal(err)
	}
	registry, err := projects.NewRegistry([]config.ProjectConfig{{ID: "demo", Path: projectPath}})
	if err != nil {
		t.Fatal(err)
	}
	projectRealPath, err := filepath.EvalSymlinks(projectPath)
	if err != nil {
		t.Fatal(err)
	}

	targets := fileAccessPreflightTargets(config.Config{
		BrowseRoots: []string{home},
		ScanRoots:   []string{filepath.Join(home, "code")},
	}, registry, home, true)
	paths := map[string]fileAccessTarget{}
	for _, target := range targets {
		paths[target.path] = target
	}
	for _, expected := range []string{
		home,
		filepath.Join(home, "Desktop"),
		filepath.Join(home, "Documents"),
		filepath.Join(home, "Downloads"),
		filepath.Join(home, "code"),
		projectRealPath,
		filepath.Join(home, "Pictures", "Photos Library.photoslibrary"),
	} {
		if _, ok := paths[expected]; !ok {
			t.Fatalf("启动权限预检缺少路径 %s：%+v", expected, targets)
		}
	}
	if !paths[filepath.Join(home, "Documents")].missingIsOkay {
		t.Fatal("用户可能删除标准目录，缺失的受保护目录不应导致预检失败")
	}
	if !paths[filepath.Join(home, "Pictures", "Photos Library.photoslibrary")].missingIsOkay {
		t.Fatal("没有照片图库的机器不应因为缺失该 bundle 而预检失败")
	}
}

func TestFileAccessPreflightTargetsIncludePhotosLibraryForPicturesRoot(t *testing.T) {
	home := t.TempDir()
	registry, err := projects.NewRegistry(nil)
	if err != nil {
		t.Fatal(err)
	}
	photosLibrary := filepath.Join(home, "Pictures", "Photos Library.photoslibrary")
	targets := fileAccessPreflightTargets(config.Config{
		BrowseRoots: []string{filepath.Join(home, "Pictures")},
	}, registry, home, true)
	for _, target := range targets {
		if target.path == photosLibrary {
			if !target.missingIsOkay {
				t.Fatal("Pictures 浏览根下缺失的照片图库不应导致预检失败")
			}
			return
		}
	}
	t.Fatalf("Pictures 单独作为浏览根时也必须预检照片图库：%+v", targets)
}

func TestRunFileAccessPreflightReadsOneDirectoryEntryAndReportsBlockedPath(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "visible.txt"), []byte("ok"), 0o600); err != nil {
		t.Fatal(err)
	}
	registry, err := projects.NewRegistry(nil)
	if err != nil {
		t.Fatal(err)
	}

	check, failures := runFileAccessPreflight(config.Config{BrowseRoots: []string{root}}, registry, root, false)
	if !check.OK || len(failures) != 0 {
		t.Fatalf("可读目录应通过预检：check=%+v failures=%+v", check, failures)
	}

	filePath := filepath.Join(root, "not-a-directory")
	if err := os.WriteFile(filePath, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	check, failures = runFileAccessPreflight(config.Config{BrowseRoots: []string{filePath}}, registry, root, false)
	if check.OK || len(failures) != 1 || failures[0].path != filePath {
		t.Fatalf("不可列目录的路径必须显示为预检 warning：check=%+v failures=%+v", check, failures)
	}
}

func TestProbeDirectoryAccessAllowsEmptyAndReportsMissingDirectory(t *testing.T) {
	if err := probeDirectoryAccess(t.TempDir()); err != nil {
		t.Fatalf("空目录也应视为可访问：%v", err)
	}
	missing := filepath.Join(t.TempDir(), "missing")
	if err := probeDirectoryAccess(missing); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("缺失目录应保留 os.ErrNotExist：%v", err)
	}
}

func TestRequestFileAccessProbesStandardDomainOnceAndUpdatesWarning(t *testing.T) {
	home := t.TempDir()
	checker := &Checker{}
	called := make(chan string, 2)
	var calls atomic.Int32
	probe := func(path string) error {
		calls.Add(1)
		called <- path
		return os.ErrPermission
	}

	domain, ok := checker.requestFileAccess(filepath.Join(home, "Documents", "report.md"), home, probe)
	if !ok || domain != "documents" {
		t.Fatalf("Documents 应映射到 documents 权限域：domain=%q ok=%v", domain, ok)
	}
	if _, ok := checker.requestFileAccess(filepath.Join(home, "Documents", "other.md"), home, probe); !ok {
		t.Fatal("同一权限域的后续请求仍应返回权限域")
	}
	select {
	case path := <-called:
		if path != filepath.Join(home, "Documents") {
			t.Fatalf("应探测 Documents 根目录，got=%s", path)
		}
	case <-time.After(time.Second):
		t.Fatal("未执行异步目录探测")
	}
	updated := false
	for deadline := time.Now().Add(time.Second); time.Now().Before(deadline); {
		if check := checker.fileAccessPreflightCheck(); check.Name != "" {
			if check.OK || check.Level != "warning" || !strings.Contains(check.Message, "文稿") || strings.Contains(check.Message, "documents") {
				t.Fatalf("权限拒绝应更新 warning-only doctor check：%+v", check)
			}
			updated = true
			break
		}
		time.Sleep(time.Millisecond)
	}
	if !updated {
		t.Fatal("异步权限拒绝未更新 doctor check")
	}
	if calls.Load() != 1 {
		t.Fatalf("同一权限域只应探测一次，got=%d", calls.Load())
	}
}

func TestStartupPreflightSuccessDoesNotOverwriteOnDemandFailure(t *testing.T) {
	checker := &Checker{
		fileAccessRequestedDomains: map[string]bool{"documents": true},
		fileAccessPreflight: Check{
			Name:    fileAccessPreflightName,
			OK:      false,
			Level:   "warning",
			Message: "macOS 拒绝访问“文稿”文件夹",
		},
	}
	checker.mergeStartupFileAccessPreflight(Check{
		Name:    fileAccessPreflightName,
		OK:      true,
		Message: "启动预检成功",
	})
	check := checker.fileAccessPreflightCheck()
	if check.OK || !strings.Contains(check.Message, "文稿") {
		t.Fatalf("启动成功不能覆盖按需权限失败：%+v", check)
	}
}

func TestStandardFileAccessPermissionDomainDoesNotExpandArbitraryPaths(t *testing.T) {
	home := t.TempDir()
	for path, want := range map[string]string{
		filepath.Join(home, "Desktop", "a.txt"):                                               "desktop",
		filepath.Join(home, "Downloads", "a.zip"):                                             "downloads",
		filepath.Join(home, "Pictures", "Photos Library.photoslibrary", "resources", "a.jpg"): "photos_library",
	} {
		domain, ok := standardFileAccessPermissionDomain(path, home)
		if !ok || domain.name != want {
			t.Fatalf("标准目录映射错误 path=%s domain=%+v", path, domain)
		}
	}
	if _, ok := standardFileAccessPermissionDomain(filepath.Join(home, "code", "secret"), home); ok {
		t.Fatal("普通目录不能自动扩大成权限域")
	}
	if _, ok := standardFileAccessPermissionDomain(filepath.Join(home, "Pictures", "a.jpg"), home); ok {
		t.Fatal("普通 Pictures 不是 macOS 文件与文件夹标准权限域")
	}
	libraryPath := filepath.Join(home, "Pictures", "Photos Library.photoslibrary", "resources", "a.jpg")
	domain, _ := standardFileAccessPermissionDomain(libraryPath, home)
	if domain.path != filepath.Join(home, "Pictures", "Photos Library.photoslibrary") {
		t.Fatalf("照片图库必须探测 bundle 根，got=%s", domain.path)
	}
	customLibrary := filepath.Join(home, "Pictures", "Archives", "家庭影集.photoslibrary")
	domain, ok := standardFileAccessPermissionDomain(filepath.Join(customLibrary, "resources", "derivatives", "a.jpg"), home)
	if !ok || domain.name != "photos_library" || domain.path != customLibrary {
		t.Fatalf("自定义图库应识别并探测实际 bundle 根：domain=%+v ok=%v", domain, ok)
	}
	outsideLibrary := filepath.Join(t.TempDir(), "Outside.photoslibrary", "resources", "a.jpg")
	if _, ok := standardFileAccessPermissionDomain(outsideLibrary, home); ok {
		t.Fatal("Pictures 外的 .photoslibrary 不能扩大为照片图库权限域")
	}
}
