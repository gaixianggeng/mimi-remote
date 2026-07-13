package setup

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestSetupWriteFailuresRestoreExistingFilesExactly(t *testing.T) {
	for _, failure := range []string{
		"token-write",
		"config-write",
		"token-fsync",
		"config-fsync",
		"token-rename",
		"config-rename",
		"directory-fsync",
	} {
		t.Run(failure, func(t *testing.T) {
			clearSetupEnv(t)
			dir := t.TempDir()
			configPath := filepath.Join(dir, "config.json")
			tokenPath := filepath.Join(dir, "app-server-ws-token")
			oldConfig := []byte("old-config-must-stay-byte-identical\n")
			oldToken := []byte("old-upstream-token-must-stay-byte-identical\n")
			writeFileWithMode(t, configPath, oldConfig, 0o640)
			writeFileWithMode(t, tokenPath, oldToken, 0o644)
			sentinel := errors.New("injected " + failure)

			_, err := runWithFileOps(context.Background(), atomicSetupOptions(t, configPath, true), failingSetupFileOps(configPath, tokenPath, failure, sentinel))
			if !errors.Is(err, sentinel) {
				t.Fatalf("应返回注入错误 %q，实际 %v", failure, err)
			}
			assertFileBytesAndMode(t, configPath, oldConfig, 0o640)
			assertFileBytesAndMode(t, tokenPath, oldToken, 0o644)
			assertSetupDirectoryEntries(t, dir, "config.json", "app-server-ws-token")
		})
	}
}

func TestSetupWriteFailuresLeaveNoFreshInstallArtifacts(t *testing.T) {
	for _, failure := range []string{
		"token-write",
		"config-write",
		"token-fsync",
		"config-fsync",
		"token-rename",
		"config-rename",
		"directory-fsync",
	} {
		t.Run(failure, func(t *testing.T) {
			clearSetupEnv(t)
			dir := t.TempDir()
			configPath := filepath.Join(dir, "config.json")
			tokenPath := filepath.Join(dir, "app-server-ws-token")
			sentinel := errors.New("injected " + failure)

			_, err := runWithFileOps(context.Background(), atomicSetupOptions(t, configPath, false), failingSetupFileOps(configPath, tokenPath, failure, sentinel))
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
	tokenPath := filepath.Join(dir, "app-server-ws-token")
	sentinel := errors.New("injected token-write")

	_, err := runWithFileOps(context.Background(), atomicSetupOptions(t, configPath, false), failingSetupFileOps(configPath, tokenPath, "token-write", sentinel))
	if !errors.Is(err, sentinel) {
		t.Fatalf("应返回注入错误：%v", err)
	}
	assertMissingPath(t, dir)
}

func TestSetupSuccessUsesPrivateFilesAndKeepsRotationSemantics(t *testing.T) {
	for _, testCase := range []struct {
		name     string
		force    bool
		existing bool
	}{
		{name: "fresh", force: false, existing: false},
		{name: "force rotates", force: true, existing: true},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			clearSetupEnv(t)
			dir := t.TempDir()
			configPath := filepath.Join(dir, "config.json")
			tokenPath := filepath.Join(dir, "app-server-ws-token")
			oldToken := []byte("old-token-before-force\n")
			if testCase.existing {
				writeFileWithMode(t, configPath, []byte("old-config-before-force\n"), 0o644)
				writeFileWithMode(t, tokenPath, oldToken, 0o644)
			}

			result, err := Run(context.Background(), atomicSetupOptions(t, configPath, testCase.force))
			if err != nil {
				t.Fatal(err)
			}
			if !result.Created || result.AppServerTokenFile != tokenPath {
				t.Fatalf("setup 成功结果异常：%+v", result)
			}
			assertPrivateRegularFile(t, configPath)
			assertPrivateRegularFile(t, tokenPath)
			newToken, err := os.ReadFile(tokenPath)
			if err != nil {
				t.Fatal(err)
			}
			if len(strings.TrimSpace(string(newToken))) != 64 {
				t.Fatalf("upstream token 应为 32-byte hex：%q", newToken)
			}
			if testCase.existing && bytes.Equal(newToken, oldToken) {
				t.Fatal("setup --force 成功后必须保持既有的 token 轮换语义")
			}
			cfg, err := config.Load(configPath)
			if err != nil {
				t.Fatal(err)
			}
			if cfg.AppServer.WSTokenFile != tokenPath || len(cfg.Auth.Token) != 64 {
				t.Fatalf("提交后的配置未引用新 token 或缺少外侧 token：%+v", cfg)
			}
			assertSetupDirectoryEntries(t, dir, "config.json", "app-server-ws-token")
		})
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
			t.Fatal(err)
		}

		_, err := Run(context.Background(), atomicSetupOptions(t, configPath, true))
		if err == nil || !strings.Contains(err.Error(), "regular file") {
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
		if err == nil || !strings.Contains(err.Error(), "regular file") {
			t.Fatalf("配置目录必须 fail-closed：%v", err)
		}
		info, statErr := os.Lstat(configPath)
		if statErr != nil || !info.IsDir() {
			t.Fatalf("拒绝目录后不能替换原目标：info=%v err=%v", info, statErr)
		}
	})

	for _, kind := range []string{"symlink", "directory"} {
		t.Run("token "+kind, func(t *testing.T) {
			clearSetupEnv(t)
			dir := t.TempDir()
			configPath := filepath.Join(dir, "config.json")
			oldConfig := []byte("old-config\n")
			writeFileWithMode(t, configPath, oldConfig, 0o600)
			tokenPath := filepath.Join(dir, "app-server-ws-token")
			if kind == "symlink" {
				target := filepath.Join(dir, "real-token")
				writeFileWithMode(t, target, []byte("do-not-touch-token\n"), 0o600)
				if err := os.Symlink(target, tokenPath); err != nil {
					t.Fatal(err)
				}
				defer assertFileBytesAndMode(t, target, []byte("do-not-touch-token\n"), 0o600)
			} else if err := os.Mkdir(tokenPath, 0o700); err != nil {
				t.Fatal(err)
			}

			_, err := Run(context.Background(), atomicSetupOptions(t, configPath, true))
			if err == nil || !strings.Contains(err.Error(), "regular file") {
				t.Fatalf("token %s 必须 fail-closed：%v", kind, err)
			}
			assertFileBytesAndMode(t, configPath, oldConfig, 0o600)
		})
	}
}

func failingSetupFileOps(configPath string, tokenPath string, failure string, sentinel error) setupFileTransactionOps {
	ops := defaultSetupFileTransactionOps()
	defaultStage := ops.stage
	if failure == "token-write" || failure == "config-write" || failure == "token-fsync" || failure == "config-fsync" {
		ops.stage = func(dir string, pattern string, raw []byte) (string, error) {
			isToken := strings.Contains(pattern, "app-server-ws-token")
			failThisFile := (strings.HasPrefix(failure, "token-") && isToken) || (strings.HasPrefix(failure, "config-") && !isToken)
			if !failThisFile {
				return defaultStage(dir, pattern, raw)
			}
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
	if failure == "token-rename" || failure == "config-rename" {
		ops.rename = func(oldPath string, newPath string) error {
			isTokenCommit := newPath == tokenPath && strings.Contains(filepath.Base(oldPath), ".app-server-ws-token.tmp-")
			isConfigCommit := newPath == configPath && strings.Contains(filepath.Base(oldPath), ".config.json.tmp-")
			if (failure == "token-rename" && isTokenCommit) || (failure == "config-rename" && isConfigCommit) {
				return sentinel
			}
			return defaultRename(oldPath, newPath)
		}
	}
	if failure == "directory-fsync" {
		defaultSyncDir := ops.syncDir
		calls := 0
		ops.syncDir = func(dir string) error {
			calls++
			if calls == 1 {
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
	if !info.Mode().IsRegular() || info.Mode().Perm() != wantMode.Perm() {
		t.Fatalf("%s 权限被意外修改：got=%04o want=%04o", path, info.Mode().Perm(), wantMode.Perm())
	}
}

func assertPrivateRegularFile(t *testing.T, path string) {
	t.Helper()
	info, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	if !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 {
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
