package setup

import (
	"bytes"
	"context"
	"errors"
	"github.com/gaixianggeng/mimi-remote/internal/auth"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestSetupWriteFailuresRestoreExistingFilesExactly(t *testing.T) {
	for _, failure := range []string{
		"config-write",
		"config-fsync",
		"config-rename",
		"directory-fsync",
	} {
		t.Run(failure, func(t *testing.T) {
			clearSetupEnv(t)
			dir := t.TempDir()
			configPath := filepath.Join(dir, "config.json")
			options := atomicSetupOptions(t, configPath, false)
			if _, err := Run(t.Context(), options); err != nil {
				t.Fatal(err)
			}
			writeFileWithMode(t, filepath.Join(dir, "user-token"), []byte("user-owned file"), 0600)
			before := setupFilesSnapshot(t, dir)
			options.ScanRoot = t.TempDir()
			sentinel := errors.New("injected " + failure)
			_, err := runWithFileOps(t.Context(), options, failingSetupFileOps(configPath, failure, sentinel))
			if !errors.Is(err, sentinel) {
				t.Fatalf("did not reach %s: %v", failure, err)
			}
			if after := setupFilesSnapshot(t, dir); !reflect.DeepEqual(before, after) {
				t.Fatal("failed change did not restore all bytes and permissions")
			}
		})
	}
}

func TestSetupWriteFailuresLeaveNoFreshInstallArtifacts(t *testing.T) {
	for _, failure := range []string{
		"config-write",
		"config-fsync",
		"config-rename",
		"directory-fsync",
	} {
		t.Run(failure, func(t *testing.T) {
			clearSetupEnv(t)
			dir := t.TempDir()
			configPath := filepath.Join(dir, "config.json")
			tokenPath := filepath.Join(dir, "app-server-ws-token")
			sentinel := errors.New("injected " + failure)

			_, err := runWithFileOps(context.Background(), atomicSetupOptions(t, configPath, false), failingSetupFileOps(configPath, failure, sentinel))
			if !errors.Is(err, sentinel) {
				t.Fatalf("应返回注入错误 %q，实际 %v", failure, err)
			}
			assertMissingPath(t, configPath)
			assertMissingPath(t, tokenPath)
			assertSetupDirectoryEntries(t, dir)
		})
	}
}

func TestFreshSetupFailureRemovesNewEmptyConfigDirectory(t *testing.T) {
	clearSetupEnv(t)
	parent := t.TempDir()
	dir := filepath.Join(parent, "new-mimi-config")
	configPath := filepath.Join(dir, "config.json")
	sentinel := errors.New("injected config-write")

	_, err := runWithFileOps(context.Background(), atomicSetupOptions(t, configPath, false), failingSetupFileOps(configPath, "config-write", sentinel))
	if !errors.Is(err, sentinel) {
		t.Fatalf("应返回注入错误：%v", err)
	}
	assertMissingPath(t, dir)
}

type savedFile struct {
	Body string
	Mode os.FileMode
}

func setupFilesSnapshot(t *testing.T, dir string) map[string]savedFile {
	t.Helper()
	files := map[string]savedFile{}
	err := filepath.WalkDir(dir, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		files[path] = savedFile{string(data), info.Mode()}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return files
}
func TestSetupUsesPrivateCompanionAndForcePreservesIdentity(t *testing.T) {
	clearSetupEnv(t)
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	unmanaged := filepath.Join(dir, "app-server-ws-token")
	old := []byte("preexisting unreferenced user token")
	writeFileWithMode(t, unmanaged, old, 0600)
	options := atomicSetupOptions(t, path, false)
	r, err := Run(t.Context(), options)
	if err != nil || !r.Created {
		t.Fatalf("fresh save: %v", err)
	}
	cfg, err := config.Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.Auth.Token) != 64 {
		t.Fatal("fresh bearer not generated")
	}
	assertPrivateRegularFile(t, path)
	assertDefaultSetupConfigAppServer(t, cfg)
	if config.SupportsManagedAppServer() {
		if cfg.AppServer.WSTokenFile == unmanaged {
			t.Fatal("new config reused unrelated token path")
		}
		token, err := os.ReadFile(cfg.AppServer.WSTokenFile)
		if err != nil || len(strings.TrimSpace(string(token))) != 64 {
			t.Fatalf("private WS token missing: %v", err)
		}
	}
	request := httptest.NewRequest("GET", "/api/projects", nil)
	request.Header.Set("Authorization", "Bearer "+cfg.Auth.Token)
	before := setupFilesSnapshot(t, dir)
	options.Force = true
	if _, err := Run(t.Context(), options); err == nil {
		t.Fatal("force accepted an existing identity")
	}
	if !reflect.DeepEqual(before, setupFilesSnapshot(t, dir)) {
		t.Fatal("blocked force changed user's files")
	}
	options.Force = false
	options.ScanRoot = t.TempDir()
	if _, err := Run(t.Context(), options); err != nil {
		t.Fatal(err)
	}
	after := setupFilesSnapshot(t, dir)
	delete(before, path)
	delete(after, path)
	if !reflect.DeepEqual(before, after) {
		t.Fatal("edit changed a token or left staging debris")
	}
	assertFileBytesAndMode(t, unmanaged, old, 0600)
	updated, err := config.Load(path)
	if err != nil || updated.AppServer.WSTokenFile != cfg.AppServer.WSTokenFile {
		t.Fatalf("new WS token reference: %v", err)
	}
	if !auth.NewWithOptions(updated.Auth.Token, false, auth.Options{}).ValidRequest(request) {
		t.Fatal("previously paired client no longer authenticated")
	}
}

func TestSetupRejectsSymlinkAndDirectoryTargets(t *testing.T) {
	t.Run("config symlink", func(t *testing.T) {
		clearSetupEnv(t)
		dir := t.TempDir()
		target := filepath.Join(dir, "real-config")
		original := []byte("do-not-touch-config\n")
		writeFileWithMode(t, target, original, 0o600)
		configPath := filepath.Join(dir, "config.json")
		if err := os.Symlink(target, configPath); err != nil {
			if runtime.GOOS == "windows" {
				t.Skip("Windows symlink creation requires Developer Mode or elevation")
			}
			t.Fatal(err)
		}

		_, err := Run(context.Background(), atomicSetupOptions(t, configPath, true))
		if err == nil {
			t.Fatalf("配置 symlink 必须 fail-closed：%v", err)
		}
		assertFileBytesAndMode(t, target, original, 0o600)
	})

	t.Run("config directory", func(t *testing.T) {
		clearSetupEnv(t)
		dir := t.TempDir()
		configPath := filepath.Join(dir, "config.json")
		if err := os.Mkdir(configPath, 0o700); err != nil {
			t.Fatal(err)
		}

		_, err := Run(context.Background(), atomicSetupOptions(t, configPath, true))
		if err == nil {
			t.Fatalf("配置目录必须 fail-closed：%v", err)
		}
		info, statErr := os.Lstat(configPath)
		if statErr != nil || !info.IsDir() {
			t.Fatalf("拒绝目录后不能替换原目标：info=%v err=%v", info, statErr)
		}
	})

}

func failingSetupFileOps(configPath string, failure string, sentinel error) setupFileTransactionOps {
	ops := defaultSetupFileTransactionOps()
	if failure == "config-write" || failure == "config-fsync" {
		ops.stage = func(dir string, pattern string, raw []byte) (string, error) {
			stageOps := privateFileStageOps{
				write: func(file *os.File, raw []byte) (int, error) {
					if strings.HasSuffix(failure, "-write") {
						partial := len(raw) / 2
						written, _ := file.Write(raw[:partial])
						return written, sentinel
					}
					return file.Write(raw)
				},
				sync: func(file *os.File) error {
					if strings.HasSuffix(failure, "-fsync") {
						return sentinel
					}
					return file.Sync()
				},
			}
			return stagePrivateFileWithOps(dir, pattern, raw, stageOps)
		}
	}
	defaultRename := ops.rename
	if failure == "config-rename" {
		ops.rename = func(oldPath string, newPath string) error {
			isConfigCommit := newPath == configPath
			if isConfigCommit {
				return sentinel
			}
			return defaultRename(oldPath, newPath)
		}
	}
	if failure == "config-rename" {
		ops.renameNew = ops.rename
	}
	if failure == "directory-fsync" {
		defaultSyncDir := ops.syncDir
		committed := false
		ops.rename = func(src, dst string) error {
			err := defaultRename(src, dst)
			if err == nil && dst == configPath {
				committed = true
			}
			return err
		}
		ops.renameNew = ops.rename
		failed := false
		ops.syncDir = func(dir string) error {
			if committed && !failed {
				failed = true
				return sentinel
			}
			return defaultSyncDir(dir)
		}
	}
	return ops
}

func atomicSetupOptions(t *testing.T, configPath string, force bool) Options {
	t.Helper()
	return Options{
		SaveOnly:   true,
		ConfigPath: configPath,
		ScanRoot:   t.TempDir(),
		BrowseRoot: t.TempDir(),
		Listen:     "127.0.0.1:8787",
		Force:      force,
	}
}

func writeFileWithMode(t *testing.T, path string, raw []byte, mode os.FileMode) {
	t.Helper()
	if err := os.WriteFile(path, raw, mode); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, mode); err != nil {
		t.Fatal(err)
	}
}

func assertFileBytesAndMode(t *testing.T, path string, want []byte, wantMode os.FileMode) {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(raw, want) {
		t.Fatalf("%s 内容被意外修改：got=%q want=%q", path, raw, want)
	}
	info, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	if !info.Mode().IsRegular() || (runtime.GOOS != "windows" && info.Mode().Perm() != wantMode.Perm()) {
		t.Fatalf("%s 权限被意外修改：got=%04o want=%04o", path, info.Mode().Perm(), wantMode.Perm())
	}
}

func assertPrivateRegularFile(t *testing.T, path string) {
	t.Helper()
	info, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	if !info.Mode().IsRegular() || (runtime.GOOS != "windows" && info.Mode().Perm() != 0o600) {
		t.Fatalf("%s 必须是 0600 regular file：%v", path, info.Mode())
	}
}

func assertMissingPath(t *testing.T, path string) {
	t.Helper()
	if _, err := os.Lstat(path); !os.IsNotExist(err) {
		t.Fatalf("不应残留 %s：%v", path, err)
	}
}

func assertSetupDirectoryEntries(t *testing.T, dir string, allowed ...string) {
	t.Helper()
	allowedSet := map[string]bool{}
	for _, name := range allowed {
		allowedSet[name] = true
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if !allowedSet[entry.Name()] {
			t.Fatalf("setup 事务残留临时文件：%s", entry.Name())
		}
	}
	if len(entries) != len(allowedSet) {
		t.Fatalf("setup 目录文件数量异常：entries=%v allowed=%v", entries, allowed)
	}
}
