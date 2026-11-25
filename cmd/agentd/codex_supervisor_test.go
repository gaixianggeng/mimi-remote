package main

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/doctor"
	"github.com/gaixianggeng/mimi-remote/internal/httpapi"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
)

func waitForCodex(t *testing.T, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for !condition() {
		if time.Now().After(deadline) {
			t.Fatal("timed out waiting for Codex state")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// The test binary emulates a managed Codex CLI on all platforms, so Windows
// exercises the same process launch, authenticated readiness and shutdown path.
func runTestManagedCodex(args []string) int {
	if slices.Equal(args, []string{"--version"}) {
		fmt.Println("codex-cli " + appserver.MinimumCodexVersion)
		return 0
	}
	listen, token := slices.Index(args, "--listen"), slices.Index(args, "--ws-token-file")
	if listen < 0 || listen+1 >= len(args) || token < 0 || token+1 >= len(args) {
		return 2
	}
	secret, err := os.ReadFile(args[token+1])
	if err != nil {
		return 2
	}
	exited := make(chan struct{})
	upgrader := websocket.Upgrader{}
	srv := http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+string(secret) {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer conn.Close()
		for {
			var msg struct {
				ID     int
				Method string
			}
			if err := conn.ReadJSON(&msg); err != nil {
				return
			}
			switch msg.Method {
			case "test/exit":
				close(exited)
				return
			case "initialize":
				_ = conn.WriteJSON(map[string]any{"id": msg.ID, "result": map[string]any{}})
			}
		}
	})}
	ln, err := net.Listen("tcp", strings.TrimPrefix(args[listen+1], "ws://"))
	if err != nil {
		return 2
	}
	go srv.Serve(ln)
	<-exited
	_ = srv.Close()
	return 3
}

func isolatedHost(t *testing.T, cfg config.Config, transport httpapi.AppServerTransport, catalog http.HandlerFunc) http.Handler {
	t.Helper()
	dir := t.TempDir()
	cfg.Auth.Token = "pairing-fixture"
	cfg.Projects = []config.ProjectConfig{{ID: "demo", Name: "Demo", Path: dir}}
	token := filepath.Join(dir, "harness-token")
	if err := os.WriteFile(token, []byte("harness-fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/api/session/modelCatalog", catalog)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		http.SetCookie(w, &http.Cookie{Name: "harness", Value: "fixture"})
		w.WriteHeader(http.StatusSeeOther)
	})
	harness := httptest.NewServer(mux)
	t.Cleanup(harness.Close)
	cfg.DeepSeek = config.DeepSeekConfig{Enabled: true, BaseURL: harness.URL, TokenFile: token, MaxConcurrentSessions: 1}
	registry, err := projects.NewRegistry(cfg.Projects)
	if err != nil {
		t.Fatal(err)
	}
	handler, router := httpapi.NewRouterWithInstallationIDAndOptions(cfg, registry, doctor.NewChecker("test", cfg, registry), "test", "", httpapi.RouterOptions{AppServerSSH: transport})
	t.Cleanup(router.Shutdown)
	return handler
}

func hostRequest(handler http.Handler, method, path, body string) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer pairing-fixture")
	handler.ServeHTTP(rec, req)
	return rec
}

func fetchHarnessCatalog(handler http.Handler) *httptest.ResponseRecorder {
	return hostRequest(handler, http.MethodPost, "/api/harness/rpc", `{"rpcId":"test","method":"session/modelCatalog"}`)
}

func replyHarnessCatalog(w http.ResponseWriter, _ *http.Request) {
	_, _ = io.WriteString(w, `{"result":{"ok":true,"value":{"model":"working"}}}`)
}

func TestUnavailableCodexPreservesHostAndOtherRuntime(t *testing.T) {
	for _, kind := range []string{"local", "ssh"} {
		t.Run(kind, func(t *testing.T) {
			if kind == "local" && !config.SupportsSharedLocalAppServer() {
				t.Skip("shared local transport runs on Unix")
			}
			binDir := t.TempDir()
			t.Setenv("PATH", binDir)
			if kind == "ssh" && runtime.GOOS != "windows" {
				// Match an offline OpenSSH host without contacting a real target.
				if err := os.WriteFile(filepath.Join(binDir, "ssh"), []byte("#!/bin/sh\nexit 255\n"), 0700); err != nil {
					t.Fatal(err)
				}
			}
			cfg := config.Config{Codex: config.CodexConfig{Bin: filepath.Join(t.TempDir(), "missing")}, AppServer: config.AppServerConfig{Transport: kind, SSHTarget: "example.invalid"}}
			if kind == "local" {
				cfg.AppServer.SSHTarget = ""
				// Keep the Unix socket within sun_path even when the host or CI
				// runner uses a long temporary home directory.
				home, err := os.MkdirTemp("/tmp", "mimi-codex-")
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(func() { _ = os.RemoveAll(home) })
				cfg.Codex.Env = map[string]string{"CODEX_HOME": home}
			}
			r, err := prepareAgentAppServerRuntime(cfg)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = r.shutdown() })
			waitForCodex(t, func() bool {
				_, err := r.supervisor.current()
				return err != nil && (strings.Contains(err.Error(), "版本检查失败") || strings.Contains(err.Error(), "SSH"))
			})
			handler := isolatedHost(t, cfg, r.routerOptions.AppServerSSH, replyHarnessCatalog)
			if got := hostRequest(handler, http.MethodGet, "/healthz", ""); got.Code != http.StatusOK {
				t.Fatalf("health %d %s", got.Code, got.Body)
			}
			if got := hostRequest(handler, http.MethodGet, "/api/readyz", ""); got.Code != http.StatusServiceUnavailable || !strings.Contains(got.Body.String(), "app-server-upstream") {
				t.Fatalf("Codex diagnostics %d %s", got.Code, got.Body)
			}
			if got := fetchHarnessCatalog(handler); got.Code != http.StatusOK || !strings.Contains(got.Body.String(), `"model":"working"`) {
				t.Fatalf("Harness RPC %d %s", got.Code, got.Body)
			}
		})
	}
}

func TestManagedCodexRestartsWithoutInterruptingOtherRuntime(t *testing.T) {
	t.Setenv("MIMI_TEST_MANAGED_CODEX", "1")
	bin, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	endpoint := "ws://" + ln.Addr().String()
	_ = ln.Close()
	token := filepath.Join(t.TempDir(), "codex-token")
	if err := os.WriteFile(token, []byte("test-capability"), 0600); err != nil {
		t.Fatal(err)
	}
	options := appserver.ManagedWebSocketOptions{CodexBin: bin, Listen: endpoint, WSTokenFile: token, EarlyExitGrace: 10 * time.Millisecond}
	s := startCodexSupervisor(func(ctx context.Context) (httpapi.AppServerTransport, error) {
		return startReadyManagedCodex(ctx, options)
	}, nil, 20*time.Millisecond)
	t.Cleanup(func() { _ = s.shutdown() })
	first := awaitManagedCodex(t, s, nil)
	started, finish := make(chan struct{}), make(chan struct{})
	handler := isolatedHost(t, config.Config{}, s, func(w http.ResponseWriter, req *http.Request) {
		close(started)
		select {
		case <-finish:
			replyHarnessCatalog(w, req)
		case <-req.Context().Done():
		}
	})
	release := sync.OnceFunc(func() { close(finish) })
	defer release()
	result := make(chan *httptest.ResponseRecorder, 1)
	go func() { result <- fetchHarnessCatalog(handler) }()
	select {
	case <-started:
	case got := <-result:
		t.Fatalf("request did not reach Harness: %s", got.Body)
	case <-time.After(5 * time.Second):
		t.Fatal("Harness request did not start")
	}
	dialer, err := s.WebSocketDialer(time.Second)
	if err != nil {
		t.Fatal(err)
	}
	headers, err := s.WebSocketHeaders()
	if err != nil {
		t.Fatal(err)
	}
	conn, _, err := dialer.Dial(endpoint, headers)
	if err != nil {
		t.Fatal(err)
	}
	if err := conn.WriteJSON(map[string]any{"method": "test/exit"}); err != nil {
		t.Fatal(err)
	}
	_ = conn.Close()
	second := awaitManagedCodex(t, s, first)
	if err := s.EnsureReady(t.Context()); err != nil {
		t.Fatalf("replacement failed initialize: %v", err)
	}
	release()
	got := <-result
	if got.Code != http.StatusOK || !strings.Contains(got.Body.String(), `"model":"working"`) {
		t.Fatalf("in-flight Harness RPC lost: %d %s", got.Code, got.Body)
	}
	if err := s.shutdown(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-second.Done():
	default:
		t.Fatal("replacement process survived shutdown")
	}
	if _, err := s.WebSocketURL(); err == nil {
		t.Fatal("stopped supervisor still offers a transport")
	}
}

func awaitManagedCodex(t *testing.T, s *codexSupervisor, previous *appserver.ManagedWebSocketProcess) *appserver.ManagedWebSocketProcess {
	t.Helper()
	var p *appserver.ManagedWebSocketProcess
	waitForCodex(t, func() bool {
		current, _ := s.current()
		p, _ = current.(*appserver.ManagedWebSocketProcess)
		return p != nil && p != previous
	})
	return p
}
