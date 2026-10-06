//go:build darwin

package setup

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestMacPreflightValidatesWithoutStartingResident(t *testing.T) {
	root := shortMacPreflightDirectory(t)
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

func TestMacPreflightRejectsInvalidSocketTargetWithoutStartingResident(t *testing.T) {
	root := shortMacPreflightDirectory(t)
	bin := filepath.Join(root, "codex")
	if err := os.WriteFile(bin, []byte("#!/bin/sh\n[ \"$1\" = --version ] || exit 91\necho 'codex-cli 0.153.0'\n"), 0700); err != nil {
		t.Fatal(err)
	}
	tooLong := filepath.Join(root, strings.Repeat("x", 110))
	if err := os.Mkdir(tooLong, 0700); err != nil {
		t.Fatal(err)
	}
	for _, home := range []string{"relative-home", filepath.Join(root, "missing"), tooLong, bin} {
		t.Run(filepath.Base(home), func(t *testing.T) {
			if err := preflightSharedLocalAppServer(context.Background(), bin, map[string]string{"CODEX_HOME": home}); err == nil {
				t.Fatal("配置提交前应拒绝无效的本机 socket 目标")
			}
			for _, appServer := range []map[string]any{
				{"transport": "ssh", "ssh_target": "127.0.0.1"},
				{"transport": "ws", "managed": true, "listen": "ws://127.0.0.1:4222"},
			} {
				original, err := json.Marshal(map[string]any{
					"app_server": appServer,
					"codex":      map[string]any{"bin": bin, "env": map[string]string{"CODEX_HOME": home}},
				})
				if err != nil {
					t.Fatal(err)
				}
				path := filepath.Join(root, "config.json")
				if err := os.WriteFile(path, original, 0600); err != nil {
					t.Fatal(err)
				}
				if err := MigrateAppServerToSharedLocalWithPreflight(context.Background(), path, preflightSharedLocalAppServer); err == nil {
					t.Fatal("无效目标不能提交 transport 迁移")
				}
				stored, err := os.ReadFile(path)
				if err != nil || !bytes.Equal(stored, original) {
					t.Fatal("静态预检失败必须保留原配置")
				}
			}
		})
	}
	if _, err := os.Stat(filepath.Join(root, "app-server-control")); !os.IsNotExist(err) {
		t.Fatalf("静态预检不应创建 resident：%v", err)
	}
}

func shortMacPreflightDirectory(t *testing.T) string {
	t.Helper()
	// 默认测试目录可能已经超过 Darwin Unix socket 的路径长度限制。
	root, err := os.MkdirTemp("/tmp", "msp-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(root) })
	return root
}
