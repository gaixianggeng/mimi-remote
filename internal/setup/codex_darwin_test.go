//go:build darwin

package setup

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestRepairCodexBinWaitsForSharedDaemonOperation(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	configPath := config.PlatformDefaultPath()
	if err := os.MkdirAll(filepath.Dir(configPath), 0o700); err != nil {
		t.Fatal(err)
	}
	original := []byte("{\n  \"codex\": {\"bin\": \"/stale/codex\"}\n}\n")
	if err := os.WriteFile(configPath, original, 0o600); err != nil {
		t.Fatal(err)
	}

	entered := make(chan struct{})
	release := make(chan struct{})
	lockDone := make(chan error, 1)
	go func() {
		lockDone <- appserver.CommitConfigWithSharedDaemonLock(
			context.Background(),
			func() error { return nil },
			func() error {
				close(entered)
				<-release
				return nil
			},
		)
	}()
	<-entered

	repairDone := make(chan error, 1)
	go func() {
		_, _, err := repairCodexBin(
			configPath,
			func(string) (string, error) { return "/new/codex", nil },
			nil,
		)
		repairDone <- err
	}()
	select {
	case err := <-repairDone:
		t.Fatalf("codex.bin 修复不得穿过 shared-daemon operation lock：%v", err)
	case <-time.After(100 * time.Millisecond):
	}
	close(release)
	if err := <-lockDone; err != nil {
		t.Fatal(err)
	}
	if err := <-repairDone; err != nil {
		t.Fatal(err)
	}
}

func TestCustomConfigCommitDoesNotRemoveDefaultSharedDaemonOwner(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	ownerPath, err := appserver.SharedDaemonLaunchAgentPath()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(ownerPath), 0o700); err != nil {
		t.Fatal(err)
	}
	sentinel := []byte("default-owner-must-survive\n")
	if err := os.WriteFile(ownerPath, sentinel, 0o600); err != nil {
		t.Fatal(err)
	}

	customPath := filepath.Join(t.TempDir(), "custom-profile.json")
	committed := false
	if err := commitConfigReplacingOwnedSharedDaemon(
		context.Background(),
		customPath,
		func() error { return nil },
		func() error {
			committed = true
			return nil
		},
	); err != nil {
		t.Fatal(err)
	}
	if !committed {
		t.Fatal("自定义配置提交回调未执行")
	}
	got, err := os.ReadFile(ownerPath)
	if err != nil {
		t.Fatalf("自定义配置不能删除默认服务 owner：%v", err)
	}
	if string(got) != string(sentinel) {
		t.Fatalf("自定义配置不能改写默认服务 owner：got=%q", got)
	}
}

func TestLegacyCustomSharedDisablePreservesDefaultOwner(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	customPath, codexHome, _ := writeCodexSharingTestConfig(t)
	if _, err := configureCodexSharing(
		context.Background(),
		customPath,
		true,
		func(_ context.Context, options appserver.LocalDaemonOptions) (appserver.LocalDaemonStatus, error) {
			return appserver.LocalDaemonStatus{
				SocketPath: filepath.Join(options.Env["CODEX_HOME"], "app-server-control", "app-server-control.sock"),
				Version:    "0.147.0",
			}, nil
		},
		recoverableLifecycleInspector(t, codexHome),
		noopRemoveSharedDaemonOwner,
	); err != nil {
		t.Fatalf("准备 legacy custom shared 配置失败：%v", err)
	}
	ownerPath, err := appserver.SharedDaemonLaunchAgentPath()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(ownerPath), 0o700); err != nil {
		t.Fatal(err)
	}
	sentinel := []byte("default-owner-must-survive-custom-disable\n")
	if err := os.WriteFile(ownerPath, sentinel, 0o600); err != nil {
		t.Fatal(err)
	}

	result, err := ConfigureCodexSharing(context.Background(), customPath, false)
	if err != nil {
		t.Fatal(err)
	}
	if result.Enabled || result.Transport != "ws" || !result.Changed || result.Warning == "" {
		t.Fatalf("legacy custom shared 应恢复 fallback：%+v", result)
	}
	got, err := os.ReadFile(ownerPath)
	if err != nil || string(got) != string(sentinel) {
		t.Fatalf("custom disable 不能触碰默认 owner：got=%q err=%v", got, err)
	}
}
