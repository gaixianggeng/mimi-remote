//go:build darwin

package setup

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestMacPreflightValidatesWithoutStartingResident(t *testing.T) {
	root := t.TempDir()
	bin := filepath.Join(root, "codex")
	// 任何非版本请求都失败，确保设置与配置迁移不会在 caller 安全会话里启动服务。
	if err := os.WriteFile(bin, []byte("#!/bin/sh\n[ \"$1\" = --version ] || exit 91\necho 'codex-cli 0.153.0'\n"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := preflightSharedLocalAppServer(context.Background(), bin, map[string]string{"CODEX_HOME": root}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, "app-server-control")); !os.IsNotExist(err) {
		t.Fatalf("preflight created runtime state: %v", err)
	}
}
