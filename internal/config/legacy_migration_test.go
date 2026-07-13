package config

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestMigrateLegacyDefaultConfigPreservesRawConfig(t *testing.T) {
	destination, source := legacyDefaultMigrationPaths(t)
	projectPath := filepath.Join(t.TempDir(), "project")
	upstreamTokenPath := filepath.Join(filepath.Dir(source), "app-server-ws-token")
	worktreesPath := filepath.Join(filepath.Dir(source), "worktrees")
	raw := []byte(`{
  "listen": "127.0.0.1:8787",
  "auth": {"token": "legacy-outer-token-must-stay-unchanged"},
  "app_server": {"transport": "ws", "managed": true, "listen": "ws://127.0.0.1:4222", "ws_token_file": "` + upstreamTokenPath + `"},
  "codex": {"bin": "codex"},
  "projects": [{"id": "demo", "name": "Demo", "path": "` + projectPath + `"}],
  "worktrees_root": "` + worktreesPath + `",
  "future_unknown_field": {"keep": true}
}
`)
	writeLegacyMigrationFile(t, source, raw, 0o644)
	otherState := filepath.Join(filepath.Dir(source), "app-server-ws-token")
	writeLegacyMigrationFile(t, otherState, []byte("legacy-upstream-secret\n"), 0o600)

	migrated, err := MigrateLegacyDefaultConfig(destination, false)
	if err != nil {
		t.Fatalf("迁移旧版默认配置失败：%v", err)
	}
	if !migrated {
		t.Fatal("旧版配置存在且新版缺失时应执行迁移")
	}
	assertLegacyMigrationFile(t, destination, raw, 0o600)
	assertLegacyMigrationFile(t, source, raw, 0o644)
	if _, err := os.Lstat(filepath.Join(filepath.Dir(destination), "app-server-ws-token")); !os.IsNotExist(err) {
		t.Fatalf("迁移不得擅自复制 upstream token 或其他状态：%v", err)
	}
}

func TestMigrateLegacyDefaultConfigNewConfigAlwaysWins(t *testing.T) {
	destination, source := legacyDefaultMigrationPaths(t)
	legacyRaw := []byte("legacy config must not win\n")
	currentRaw := []byte("current config must stay byte-for-byte\n")
	writeLegacyMigrationFile(t, source, legacyRaw, 0o600)
	writeLegacyMigrationFile(t, destination, currentRaw, 0o640)

	migrated, err := MigrateLegacyDefaultConfig(destination, false)
	if err != nil {
		t.Fatal(err)
	}
	if migrated {
		t.Fatal("新版配置已存在时不得再次迁移")
	}
	assertLegacyMigrationFile(t, destination, currentRaw, 0o640)
}

func TestMigrateLegacyDefaultConfigRejectsUnsafeLegacyPath(t *testing.T) {
	for _, kind := range []string{"symlink", "directory"} {
		t.Run(kind, func(t *testing.T) {
			destination, source := legacyDefaultMigrationPaths(t)
			if err := os.MkdirAll(filepath.Dir(source), 0o700); err != nil {
				t.Fatal(err)
			}
			switch kind {
			case "symlink":
				target := filepath.Join(t.TempDir(), "target.json")
				writeLegacyMigrationFile(t, target, []byte("secret"), 0o600)
				if err := os.Symlink(target, source); err != nil {
					t.Fatal(err)
				}
			case "directory":
				if err := os.Mkdir(source, 0o700); err != nil {
					t.Fatal(err)
				}
			}

			migrated, err := MigrateLegacyDefaultConfig(destination, false)
			if err == nil || migrated || !strings.Contains(err.Error(), "普通文件") {
				t.Fatalf("不安全旧路径必须 fail-closed：migrated=%v err=%v", migrated, err)
			}
			assertLegacyMigrationMissing(t, destination)
			assertLegacyMigrationMissing(t, filepath.Dir(destination))
		})
	}
}

func TestMigrateLegacyDefaultConfigReadAndWriteFailuresLeaveNothing(t *testing.T) {
	for _, failure := range []string{"read", "write", "sync"} {
		t.Run(failure, func(t *testing.T) {
			root := t.TempDir()
			source := filepath.Join(root, "old", "config.json")
			destination := filepath.Join(root, "new", "config.json")
			writeLegacyMigrationFile(t, source, []byte("legacy secret config\n"), 0o600)
			sentinel := errors.New("injected migration failure")
			ops := defaultLegacyMigrationFileOps()
			switch failure {
			case "read":
				ops.readRegular = func(string, os.FileInfo) ([]byte, error) {
					return nil, sentinel
				}
			case "write":
				ops.stage = func(dir string, _ string, _ []byte) (stagedLegacyConfig, error) {
					path := filepath.Join(dir, ".config.json.migrate-partial")
					if err := os.WriteFile(path, []byte("partial"), 0o600); err != nil {
						t.Fatal(err)
					}
					info, err := os.Lstat(path)
					if err != nil {
						t.Fatal(err)
					}
					return stagedLegacyConfig{path: path, info: info}, sentinel
				}
			case "sync":
				ops.syncDir = func(string) error { return sentinel }
			}

			migrated, err := migrateLegacyDefaultConfig(destination, source, ops)
			if err == nil || migrated || !errors.Is(err, sentinel) {
				t.Fatalf("迁移失败必须上报原始原因：migrated=%v err=%v", migrated, err)
			}
			assertLegacyMigrationMissing(t, destination)
			assertLegacyMigrationMissing(t, filepath.Dir(destination))
			assertNoLegacyMigrationTemps(t, root)
			assertLegacyMigrationFile(t, source, []byte("legacy secret config\n"), 0o600)
		})
	}
}

func TestMigrateLegacyDefaultConfigConcurrentDestinationIsNotOverwritten(t *testing.T) {
	root := t.TempDir()
	source := filepath.Join(root, "old", "config.json")
	destination := filepath.Join(root, "new", "config.json")
	legacyRaw := []byte("legacy config\n")
	concurrentRaw := []byte("concurrent new config wins\n")
	writeLegacyMigrationFile(t, source, legacyRaw, 0o600)
	ops := defaultLegacyMigrationFileOps()
	originalLink := ops.link
	ops.link = func(oldPath string, newPath string) error {
		writeLegacyMigrationFile(t, newPath, concurrentRaw, 0o640)
		return originalLink(oldPath, newPath)
	}

	migrated, err := migrateLegacyDefaultConfig(destination, source, ops)
	if err != nil {
		t.Fatalf("并发创建的新配置应按新配置优先处理：%v", err)
	}
	if migrated {
		t.Fatal("并发目标已存在时不得宣称迁移提交成功")
	}
	assertLegacyMigrationFile(t, destination, concurrentRaw, 0o640)
	assertNoLegacyMigrationTemps(t, root)
}

func TestMigrateLegacyDefaultConfigNeverRunsForExplicitOrCustomPath(t *testing.T) {
	destination, source := legacyDefaultMigrationPaths(t)
	legacyRaw := []byte("legacy config\n")
	writeLegacyMigrationFile(t, source, legacyRaw, 0o600)

	if migrated, err := MigrateLegacyDefaultConfig(destination, true); err != nil || migrated {
		t.Fatalf("显式 --config 不得触发迁移：migrated=%v err=%v", migrated, err)
	}
	assertLegacyMigrationMissing(t, destination)

	custom := filepath.Join(t.TempDir(), "custom.json")
	if migrated, err := MigrateLegacyDefaultConfig(custom, false); err != nil || migrated {
		t.Fatalf("自定义路径不得触发迁移：migrated=%v err=%v", migrated, err)
	}
	assertLegacyMigrationMissing(t, custom)

	t.Setenv("AGENTD_CONFIG", destination)
	if migrated, err := MigrateLegacyDefaultConfig(destination, false); err != nil || migrated {
		t.Fatalf("显式 AGENTD_CONFIG 不得触发迁移：migrated=%v err=%v", migrated, err)
	}
	assertLegacyMigrationMissing(t, destination)
}

func legacyDefaultMigrationPaths(t *testing.T) (string, string) {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(home, ".config"))
	t.Setenv("AGENTD_CONFIG", "")
	return PlatformDefaultPath(), LegacyDefaultPath()
}

func writeLegacyMigrationFile(t *testing.T, path string, raw []byte, mode os.FileMode) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, raw, mode); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, mode); err != nil {
		t.Fatal(err)
	}
}

func assertLegacyMigrationFile(t *testing.T, path string, want []byte, mode os.FileMode) {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(raw) != string(want) {
		t.Fatalf("文件内容被改写：path=%s got=%q want=%q", path, raw, want)
	}
	info, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	if !info.Mode().IsRegular() || info.Mode().Perm() != mode {
		t.Fatalf("文件 mode 异常：path=%s mode=%v", path, info.Mode())
	}
}

func assertLegacyMigrationMissing(t *testing.T, path string) {
	t.Helper()
	if _, err := os.Lstat(path); !os.IsNotExist(err) {
		t.Fatalf("失败后不应残留路径：path=%s err=%v", path, err)
	}
}

func assertNoLegacyMigrationTemps(t *testing.T, root string) {
	t.Helper()
	err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if strings.Contains(entry.Name(), ".config.json.migrate-") {
			t.Fatalf("迁移不得残留暂存文件：%s", path)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}
