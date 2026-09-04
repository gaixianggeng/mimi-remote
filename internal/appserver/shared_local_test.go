//go:build linux

package appserver

import (
	"context"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestSharedLocalSocketPathUsesCanonicalCodexHome(t *testing.T) {
	realHome := shortSharedLocalCodexHome(t)
	link := filepath.Join(filepath.Dir(realHome), "codex-link")
	if err := os.Symlink(realHome, link); err != nil {
		t.Fatal(err)
	}
	path, err := SharedLocalSocketPath(map[string]string{"CODEX_HOME": link})
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(realHome, sharedLocalSocketDir, sharedLocalSocketName); path != want {
		t.Fatalf("socket path = %q, want %q", path, want)
	}
}

func TestSharedLocalTransportAttachesWithoutStartingAnotherServer(t *testing.T) {
	codexHome := shortSharedLocalCodexHome(t)
	socket := filepath.Join(codexHome, sharedLocalSocketDir, sharedLocalSocketName)
	stop := startSharedLocalTestServer(t, socket)
	defer stop()

	transport, err := NewSharedLocalTransport(SharedLocalOptions{Env: map[string]string{"CODEX_HOME": codexHome}})
	if err != nil {
		t.Fatal(err)
	}
	var starts atomic.Int32
	transport.startOnce = func(context.Context, SharedLocalOptions) error {
		starts.Add(1)
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := transport.EnsureReady(ctx); err != nil {
		t.Fatal(err)
	}
	if starts.Load() != 0 {
		t.Fatalf("已有 control socket 时不应启动第二个 App Server：starts=%d", starts.Load())
	}
}

func TestSharedLocalTransportStartsOnceAndThenAttaches(t *testing.T) {
	codexHome := shortSharedLocalCodexHome(t)
	socket := filepath.Join(codexHome, sharedLocalSocketDir, sharedLocalSocketName)
	transport, err := NewSharedLocalTransport(SharedLocalOptions{Env: map[string]string{"CODEX_HOME": codexHome}})
	if err != nil {
		t.Fatal(err)
	}
	var starts atomic.Int32
	var stop func()
	transport.startOnce = func(context.Context, SharedLocalOptions) error {
		starts.Add(1)
		stop = startSharedLocalTestServer(t, socket)
		return nil
	}
	t.Cleanup(func() {
		if stop != nil {
			stop()
		}
	})
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := transport.EnsureReady(ctx); err != nil {
		t.Fatal(err)
	}
	if err := transport.EnsureReady(ctx); err != nil {
		t.Fatal(err)
	}
	if starts.Load() != 1 {
		t.Fatalf("缺失 socket 时应只启动一次：starts=%d", starts.Load())
	}
}

func TestSharedLocalTransportRejectsNonSocketOccupant(t *testing.T) {
	codexHome := shortSharedLocalCodexHome(t)
	socket := filepath.Join(codexHome, sharedLocalSocketDir, sharedLocalSocketName)
	if err := os.MkdirAll(filepath.Dir(socket), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(socket, []byte("occupied"), 0o600); err != nil {
		t.Fatal(err)
	}
	transport, err := NewSharedLocalTransport(SharedLocalOptions{Env: map[string]string{"CODEX_HOME": codexHome}})
	if err != nil {
		t.Fatal(err)
	}
	transport.startOnce = func(context.Context, SharedLocalOptions) error {
		t.Fatal("非 socket 占位不得触发启动")
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	if err := transport.EnsureReady(ctx); err == nil || !strings.Contains(err.Error(), "非 socket") {
		t.Fatalf("应拒绝非 socket 占位，got %v", err)
	}
}

func TestSharedLocalTransportDoesNotReplaceUnresponsiveSocket(t *testing.T) {
	codexHome := shortSharedLocalCodexHome(t)
	socket := filepath.Join(codexHome, sharedLocalSocketDir, sharedLocalSocketName)
	if err := os.MkdirAll(filepath.Dir(socket), 0o700); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	listener.(*net.UnixListener).SetUnlinkOnClose(false)
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
	transport, err := NewSharedLocalTransport(SharedLocalOptions{Env: map[string]string{"CODEX_HOME": codexHome}})
	if err != nil {
		t.Fatal(err)
	}
	transport.startOnce = func(context.Context, SharedLocalOptions) error {
		t.Fatal("仍存在的 socket 不得触发第二个 App Server")
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	if err := transport.EnsureReady(ctx); err == nil || !strings.Contains(err.Error(), "仍存在") {
		t.Fatalf("无法握手的现有 socket 应明确失败，got %v", err)
	}
}

func TestStartResidentCommandUsesStableHome(t *testing.T) {
	originalDirectory, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	launchDirectory := filepath.Join(root, "temporary-launch")
	home := filepath.Join(root, "home")
	for _, directory := range []string{launchDirectory, home} {
		if err := os.Mkdir(directory, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Chdir(launchDirectory); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(originalDirectory) })

	marker := filepath.Join(root, "resident-cwd")
	err = startResidentCommand(
		"/bin/sh",
		[]string{"-c", `pwd > "$MIMI_SHARED_LOCAL_CWD_MARKER"; sleep 1`},
		map[string]string{
			"HOME":                         home,
			"MIMI_SHARED_LOCAL_CWD_MARKER": marker,
		},
	)
	if chdirErr := os.Chdir(originalDirectory); chdirErr != nil {
		t.Fatal(chdirErr)
	}
	if err != nil {
		t.Fatal(err)
	}
	if err := os.RemoveAll(launchDirectory); err != nil {
		t.Fatal(err)
	}
	contents, err := os.ReadFile(marker)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.TrimSpace(string(contents)); got != home {
		t.Fatalf("resident cwd = %q, want stable HOME %q", got, home)
	}
}

func TestSharedLocalWorkingDirectoryRejectsInvalidHome(t *testing.T) {
	for name, home := range map[string]string{
		"empty":    "",
		"relative": "relative/home",
		"missing":  filepath.Join(t.TempDir(), "missing"),
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := sharedLocalWorkingDirectory(map[string]string{"HOME": home}); err == nil {
				t.Fatalf("HOME %q should be rejected", home)
			}
		})
	}
}

func shortSharedLocalCodexHome(t *testing.T) string {
	t.Helper()
	root, err := os.MkdirTemp("/tmp", "msl-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(root) })
	path := filepath.Join(root, "c")
	if err := os.Mkdir(path, 0o700); err != nil {
		t.Fatal(err)
	}
	return path
}

func startSharedLocalTestServer(t *testing.T, socket string) func() {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(socket), 0o700); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		conn, upgradeErr := upgrader.Upgrade(w, request, nil)
		if upgradeErr != nil {
			return
		}
		defer conn.Close()
		var initialize map[string]any
		if conn.ReadJSON(&initialize) != nil {
			return
		}
		_ = conn.WriteJSON(map[string]any{"id": 1, "result": map[string]any{}})
		var initialized map[string]any
		_ = conn.ReadJSON(&initialized)
	})}
	go func() { _ = server.Serve(listener) }()
	return func() {
		_ = server.Close()
		_ = os.Remove(socket)
	}
}
