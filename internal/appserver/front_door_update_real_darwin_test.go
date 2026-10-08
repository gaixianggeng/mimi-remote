//go:build darwin

package appserver

import (
	"context"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// 使用独立目录和显式提供的旧 CLI 复现符号链接升级。不会访问真实会话或启动模型。
func TestFrontDoorRealRuntimeUpgrade(t *testing.T) {
	oldBin := os.Getenv("MIMI_TEST_OLD_CODEX")
	if os.Getenv("MIMI_TEST_REAL_CODEX_FRONT") != "1" || oldBin == "" {
		t.Skip("需要显式开启隔离实测并提供旧 CLI")
	}
	newBin, err := exec.LookPath("codex")
	if err != nil {
		t.Fatal(err)
	}
	newBin, err = filepath.EvalSymlinks(newBin)
	if err != nil {
		t.Fatal(err)
	}
	home, err := os.MkdirTemp("/tmp", "mimi-upgrade-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(home) })
	installDir := filepath.Join(home, "bin")
	if err := os.MkdirAll(installDir, 0o700); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(installDir, "codex")
	if err := os.Symlink(oldBin, link); err != nil {
		t.Fatal(err)
	}
	door, err := NewFrontDoor(SharedLocalOptions{
		CodexBin: link,
		Env:      map[string]string{"CODEX_HOME": home, "CODEX_INSTALL_DIR": installDir},
	}, t.Logf)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(door.public), 0o700); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	start := func(bin, listen string) error {
		processCtx, stop := context.WithCancel(context.Background())
		cmd := exec.CommandContext(processCtx, bin, "app-server", "--listen", listen)
		cmd.Env = []string{"HOME=" + os.Getenv("HOME"), "PATH=" + os.Getenv("PATH"), "CODEX_HOME=" + home}
		if err := cmd.Start(); err != nil {
			stop()
			return err
		}
		done := make(chan error, 1)
		go func() { done <- cmd.Wait() }()
		t.Cleanup(func() { stop(); <-done })
		return nil
	}
	if err := start(link, "unix://"+door.backend); err != nil {
		t.Fatal(err)
	}
	for {
		conn, dialErr := door.dialBackendOnce(ctx)
		if dialErr == nil {
			_ = conn.Close()
			break
		}
		select {
		case <-ctx.Done():
			t.Fatal(ctx.Err())
		case <-time.After(50 * time.Millisecond):
		}
	}
	if err := os.Remove(link); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(newBin, link); err != nil {
		t.Fatal(err)
	}
	before, err := door.RuntimeVersions(ctx)
	if err != nil || !before.UpdateAvailable {
		t.Fatalf("未发现旧后台: %+v %v", before, err)
	}
	marker := filepath.Join(home, "history-preserved")
	if err := os.WriteFile(marker, []byte("unchanged"), 0o600); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("unix", door.public)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	door.launch = func(_ context.Context, options SharedLocalOptions, listen string) error {
		return start(options.CodexBin, listen)
	}
	go func() { _ = door.Serve(ctx, listener) }()
	// 真实公共连接持有共享锁，按钮必须拒绝更新且保留同一后台。
	busy, err := door.DialBackend(ctx)
	if err != nil {
		t.Fatal(err)
	}
	_, err = door.UpdateRuntime(ctx)
	if err == nil || !strings.Contains(err.Error(), "共享连接") {
		t.Fatalf("仍有连接却未拒绝: %v", err)
	}
	_ = busy.Close()
	after, err := door.UpdateRuntime(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if after.UpdateAvailable || after.RunningVersion != before.InstalledVersion {
		t.Fatalf("未切到新版: %+v", after)
	}
	if data, err := os.ReadFile(marker); err != nil || string(data) != "unchanged" {
		t.Fatal("历史目录被改变")
	}
	verified, err := dialSharedLocalRepairTransport(ctx, &SharedLocalTransport{socket: door.backend})
	if err != nil {
		t.Fatal(err)
	}
	defer verified.Close()
	if err := verified.Initialize(ctx); err != nil {
		t.Fatal(err)
	}
	var features struct {
		Data []struct {
			Name    string `json:"name"`
			Enabled bool   `json:"enabled"`
		} `json:"data"`
	}
	if err := verified.RPC().Call(ctx, "experimentalFeature/list", map[string]any{"limit": 1000}, &features); err != nil {
		t.Fatal(err)
	}
	for _, feature := range features.Data {
		if feature.Name == "api_key_model_discovery" {
			if !feature.Enabled {
				t.Fatal("新版后台仍未启用终端要求的 api_key_model_discovery")
			}
			return
		}
	}
	t.Fatal("新版后台未报告 api_key_model_discovery")
}
