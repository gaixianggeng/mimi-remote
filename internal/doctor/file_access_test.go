package doctor

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

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
	} {
		if _, ok := paths[expected]; !ok {
			t.Fatalf("启动权限预检缺少路径 %s：%+v", expected, targets)
		}
	}
	if !paths[filepath.Join(home, "Documents")].missingIsOkay {
		t.Fatal("用户可能删除标准目录，缺失的受保护目录不应导致预检失败")
	}
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
