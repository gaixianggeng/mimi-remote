package setup

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
)

func TestMigrateAppServerToSSHPreflightFailureDoesNotWrite(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	original := []byte(`{"future":{"keep":true},"app_server":{"transport":"ws","managed":true,"listen":"ws://127.0.0.1:4222","ws_token_file":"/tmp/old","future_option":"keep"}}`)
	if err := os.WriteFile(path, original, 0o600); err != nil {
		t.Fatal(err)
	}
	previous := sshPreflight
	sshPreflight = func(context.Context, *appserver.SSHTransport) error { return errors.New("initialize failed") }
	t.Cleanup(func() { sshPreflight = previous })

	if err := MigrateAppServerToSSH(context.Background(), path, "127.0.0.1"); err == nil {
		t.Fatal("SSH preflight 失败时迁移必须失败")
	}
	stored, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(stored, original) {
		t.Fatalf("preflight 失败不能改写配置：%s", stored)
	}
}

func TestMigrateAppServerToSSHAtomicallyPreservesUnknownFields(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	original := []byte(`{"future":{"keep":true},"app_server":{"transport":"ws","managed":true,"listen":"ws://127.0.0.1:4222","ws_token_file":"/tmp/old","remote_gateway":{"enabled":true},"future_option":"keep"}}`)
	if err := os.WriteFile(path, original, 0o600); err != nil {
		t.Fatal(err)
	}
	previous := sshPreflight
	sshPreflight = func(context.Context, *appserver.SSHTransport) error { return nil }
	t.Cleanup(func() { sshPreflight = previous })

	if err := MigrateAppServerToSSH(context.Background(), path, "user@host"); err != nil {
		t.Fatal(err)
	}
	stored, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	text := string(stored)
	for _, expected := range []string{`"transport": "ssh"`, `"ssh_target": "user@host"`, `"future_option": "keep"`, `"future"`} {
		if !bytes.Contains(stored, []byte(expected)) {
			t.Fatalf("迁移丢失字段 %s：%s", expected, text)
		}
	}
	for _, removed := range []string{`"managed"`, `"listen"`, `"ws_token_file"`, `"remote_gateway"`} {
		if bytes.Contains(stored, []byte(removed)) {
			t.Fatalf("迁移未删除旧字段 %s：%s", removed, text)
		}
	}
	info, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	if !info.Mode().IsRegular() || (runtime.GOOS != "windows" && info.Mode().Perm()&0o077 != 0) {
		t.Fatalf("原子迁移结果必须是私有 regular file：%v", info.Mode())
	}
}

func TestMigrateAppServerToSharedLocalPreflightFailureDoesNotWrite(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("Linux-specific local App Server migration")
	}
	path := filepath.Join(t.TempDir(), "config.json")
	original := []byte(`{"future":{"keep":true},"app_server":{"transport":"ws","managed":true,"listen":"ws://127.0.0.1:4222","ws_token_file":"/tmp/old"}}`)
	if err := os.WriteFile(path, original, 0o600); err != nil {
		t.Fatal(err)
	}
	previous := localAppServerPreflight
	localAppServerPreflight = func(context.Context, string, map[string]string) error { return errors.New("initialize failed") }
	t.Cleanup(func() { localAppServerPreflight = previous })

	if err := MigrateAppServerToSharedLocal(context.Background(), path); err == nil {
		t.Fatal("共享本机 preflight 失败时迁移必须失败")
	}
	stored, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(stored, original) {
		t.Fatalf("preflight 失败不能改写配置：%s", stored)
	}
}

func TestMigrateAppServerToSharedLocalPreservesUnknownFields(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("Linux-specific local App Server migration")
	}
	path := filepath.Join(t.TempDir(), "config.json")
	original := []byte(`{"future":{"keep":true},"codex":{"bin":"/opt/codex","env":{"TERM":"xterm"}},"app_server":{"transport":"ws","managed":true,"listen":"ws://127.0.0.1:4222","ws_token_file":"/tmp/old","remote_gateway":{"enabled":true},"future_option":"keep"}}`)
	if err := os.WriteFile(path, original, 0o600); err != nil {
		t.Fatal(err)
	}
	previous := localAppServerPreflight
	var gotBin string
	localAppServerPreflight = func(_ context.Context, bin string, env map[string]string) error {
		gotBin = bin
		if env["TERM"] != "xterm" {
			t.Fatalf("迁移预检应沿用 codex.env：%+v", env)
		}
		return nil
	}
	t.Cleanup(func() { localAppServerPreflight = previous })

	if err := MigrateAppServerToSharedLocal(context.Background(), path); err != nil {
		t.Fatal(err)
	}
	if gotBin != "/opt/codex" {
		t.Fatalf("迁移预检应沿用 codex.bin，got %q", gotBin)
	}
	stored, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	text := string(stored)
	for _, expected := range []string{`"transport": "local"`, `"future_option": "keep"`, `"future"`} {
		if !bytes.Contains(stored, []byte(expected)) {
			t.Fatalf("迁移丢失字段 %s：%s", expected, text)
		}
	}
	for _, removed := range []string{`"managed"`, `"listen"`, `"ws_token_file"`, `"remote_gateway"`} {
		if bytes.Contains(stored, []byte(removed)) {
			t.Fatalf("迁移未删除旧字段 %s：%s", removed, text)
		}
	}
}

func TestMigrateAppServerToSharedLocalAcceptsLegacyManagedConfigWithoutTransport(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("Linux-specific local App Server migration")
	}
	path := filepath.Join(t.TempDir(), "config.json")
	original := []byte(`{"app_server":{"managed":true,"listen":"ws://127.0.0.1:4222"}}`)
	if err := os.WriteFile(path, original, 0o600); err != nil {
		t.Fatal(err)
	}
	previous := localAppServerPreflight
	localAppServerPreflight = func(context.Context, string, map[string]string) error { return nil }
	t.Cleanup(func() { localAppServerPreflight = previous })

	if err := MigrateAppServerToSharedLocal(context.Background(), path); err != nil {
		t.Fatal(err)
	}
	stored, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(stored, []byte(`"transport": "local"`)) || bytes.Contains(stored, []byte(`"managed"`)) {
		t.Fatalf("无 transport 的旧 managed 配置应迁移为 local：%s", stored)
	}
}

func TestMigrateAppServerToSharedLocalLeavesExplicitSSHUntouched(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("Linux-specific local App Server migration")
	}
	path := filepath.Join(t.TempDir(), "config.json")
	original := []byte(`{"app_server":{"transport":"ssh","ssh_target":"build-host","auto_title":true}}`)
	if err := os.WriteFile(path, original, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := MigrateAppServerToSharedLocal(context.Background(), path); err != nil {
		t.Fatal(err)
	}
	stored, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(stored, original) {
		t.Fatalf("显式 SSH 配置不应被迁移：%s", stored)
	}
}
