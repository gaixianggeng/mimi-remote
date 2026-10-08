//go:build darwin

package appserver

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// 使用独立目录和显式提供的旧 CLI 复现符号链接升级；活动任务只连接本地模拟模型。
func TestFrontDoorRealRuntimeUpgrade(t *testing.T) {
	for _, mode := range []string{"idle", "confirmed connection", "confirmed active task"} {
		t.Run(mode, func(t *testing.T) { testRealRuntimeUpgrade(t, mode) })
	}
}

func testRealRuntimeUpgrade(t *testing.T, mode string) {
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
	entered := make(chan struct{}, 1)
	if mode == "confirmed active task" {
		mock := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "text/event-stream")
			fmt.Fprint(w, "event: response.created\ndata: {\"type\":\"response.created\",\"response\":{\"id\":\"resp-restart-test\"}}\n\n")
			w.(http.Flusher).Flush()
			select {
			case entered <- struct{}{}:
			default:
			}
			<-r.Context().Done()
		}))
		t.Cleanup(mock.Close)
		writeRealCodexMockConfig(t, home, mock.URL)
	}
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
	var oldPID int
	var launches atomic.Int32
	start := func(bin, listen string) error {
		processCtx, stop := context.WithCancel(context.Background())
		cmd := exec.CommandContext(processCtx, bin, "app-server", "--listen", listen)
		cmd.Env = []string{"HOME=" + home, "PATH=" + os.Getenv("PATH"), "CODEX_HOME=" + home, "CODEX_INTERNAL_APP_SERVER_REMOTE_CONTROL_DISABLED=1"}
		if err := cmd.Start(); err != nil {
			stop()
			return err
		}
		if launches.Add(1) == 1 {
			oldPID = cmd.Process.Pid
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
		if _, alive, err := realSharedLocalRepairProcess(oldPID); err != nil || alive {
			return fmt.Errorf("旧后台尚未退出就启动 replacement: alive=%v err=%v", alive, err)
		}
		return start(options.CodexBin, listen)
	}
	go func() { _ = door.Serve(ctx, listener) }()
	// 默认管理命令仍不能中断用户；确认模式允许在共享锁仍被连接持有时切换。
	busy, err := door.DialBackend(ctx)
	if err != nil {
		t.Fatal(err)
	}
	_, err = door.UpdateRuntime(ctx)
	if err == nil || !strings.Contains(err.Error(), "共享连接") {
		t.Fatalf("仍有连接却未拒绝: %v", err)
	}
	defer busy.Close()
	threadID := ""
	if mode == "confirmed active task" {
		client := dialRealCodexWebSocket(t, ctx, door.public)
		defer client.Close()
		if _, err := initializeWebSocketResult(ctx, client); err != nil {
			t.Fatal(err)
		}
		threadID = startRealCodexThread(t, ctx, client, 102, home)
		var result map[string]any
		callRealCodexRPC(t, ctx, client, 103, "turn/start", map[string]any{
			"threadId": threadID,
			"input":    []map[string]any{{"type": "text", "text": "isolated restart test"}},
		}, &result)
		select {
		case <-entered:
		case <-ctx.Done():
			t.Fatal("模拟模型未收到活动任务", ctx.Err())
		}
	}
	var after CodexRuntimeVersions
	if mode == "idle" {
		_ = busy.Close()
		after, err = door.UpdateRuntime(ctx)
	} else {
		after, err = door.RestartRuntime(ctx)
	}
	if err != nil {
		t.Fatal(err)
	}
	if launches.Load() != 2 {
		t.Fatalf("实际启动次数=%d，期望旧版和新版各一次", launches.Load())
	}
	if threadID != "" {
		client := dialRealCodexWebSocket(t, ctx, door.public)
		defer client.Close()
		if _, err := initializeWebSocketResult(ctx, client); err != nil {
			t.Fatal(err)
		}
		if !listRealCodexThreads(t, ctx, client, 104)[threadID] {
			t.Fatal("切换后已保存的任务历史丢失")
		}
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
