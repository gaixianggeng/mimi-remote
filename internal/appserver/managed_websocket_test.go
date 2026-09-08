package appserver

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestNormalizeManagedWebSocketListenAcceptsLoopback(t *testing.T) {
	tests := map[string]string{
		"127.0.0.1:4222":      "ws://127.0.0.1:4222",
		"ws://localhost:4222": "ws://localhost:4222",
		"ws://[::1]:4222":     "ws://[::1]:4222",
	}
	for input, want := range tests {
		t.Run(input, func(t *testing.T) {
			got, err := normalizeManagedWebSocketListen(input)
			if err != nil {
				t.Fatal(err)
			}
			if got != want {
				t.Fatalf("normalizeManagedWebSocketListen(%q) = %q，want %q", input, got, want)
			}
		})
	}
}

func TestNormalizeManagedWebSocketListenRejectsNonLoopback(t *testing.T) {
	for _, input := range []string{
		"ws://0.0.0.0:4222",
		"ws://192.0.2.10:4222",
		"wss://127.0.0.1:4222",
		"ws://127.0.0.1",
	} {
		t.Run(input, func(t *testing.T) {
			if _, err := normalizeManagedWebSocketListen(input); err == nil {
				t.Fatalf("normalizeManagedWebSocketListen(%q) 应拒绝非 loopback ws 监听地址", input)
			}
		})
	}
}

func TestManagedWebSocketWaitReadyRetriesUntilInitializeSucceeds(t *testing.T) {
	var attempts atomic.Int32
	tokenPath := filepath.Join(t.TempDir(), "app-server-token")
	if err := os.WriteFile(tokenPath, []byte("local-capability-token\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if attempts.Add(1) < 3 {
			http.Error(w, "starting", http.StatusServiceUnavailable)
			return
		}
		if r.Header.Get("Authorization") != "Bearer local-capability-token" {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer conn.Close()
		var initialize map[string]any
		if err := conn.ReadJSON(&initialize); err != nil {
			return
		}
		_ = conn.WriteJSON(map[string]any{"id": 1, "result": map[string]any{}})
		var initialized map[string]any
		_ = conn.ReadJSON(&initialized)
	}))
	defer server.Close()

	process := &ManagedWebSocketProcess{
		listen:      strings.Replace(server.URL, "http://", "ws://", 1),
		wsTokenFile: tokenPath,
		doneCh:      make(chan struct{}),
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := process.WaitReady(ctx); err != nil {
		t.Fatal(err)
	}
	if attempts.Load() != 3 {
		t.Fatalf("就绪探测次数 = %d，want 3", attempts.Load())
	}
}
