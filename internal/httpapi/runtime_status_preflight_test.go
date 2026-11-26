package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/setup"
)

func TestPreflightLocalCacheEndpoint(t *testing.T) {
	home := t.TempDir()
	for _, entry := range os.Environ() {
		key, _, _ := strings.Cut(entry, "=")
		if strings.HasPrefix(strings.ToUpper(key), "AGENTD_") {
			t.Setenv(key, "")
		}
	}
	for _, key := range []string{"HOME", "USERPROFILE", "APPDATA", "LOCALAPPDATA", "XDG_CONFIG_HOME", "PATH"} {
		t.Setenv(key, home)
	}
	t.Setenv("AGENTD_FILE_UPLOAD_CACHE_DIR", filepath.Join(home, "uploads"))
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.AppServer = config.AppServerConfig{Transport: "ssh", SSHTarget: "fixture.invalid"}
		cfg.Listen = "0.0.0.0:8787"
		cfg.Network.AllowLAN = true
	})
	cache := server.router.runtimeStatus
	var probes atomic.Int32
	cache.probe = func(context.Context) runtimeStatusResponse { probes.Add(1); return runtimeStatusResponse{} }
	t.Cleanup(cache.Close)
	request := func(method, host, remote, bearer, origin, query string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, "http://"+host+"/api/local/preflight"+query, nil)
		req.RemoteAddr = remote
		if bearer != "" {
			req.Header.Set("Authorization", "Bearer "+bearer)
		}
		if origin != "" {
			req.Header.Set("Origin", origin)
		}
		w := httptest.NewRecorder()
		server.handler.ServeHTTP(w, req)
		return w
	}
	const local = "127.0.0.1:39001"
	for _, tc := range []struct {
		name, method, host, remote, bearer, origin, query string
		status                                            int
	}{
		{"anonymous", http.MethodGet, local, local, "", "", "", http.StatusUnauthorized},
		{"query token", http.MethodGet, local, local, "", "", "?token=" + testToken, http.StatusUnauthorized},
		{"wrong bearer", http.MethodGet, local, local, "fixture-wrong", "", "", http.StatusUnauthorized},
		{"nonlocal peer", http.MethodGet, local, "192.0.2.1:8000", testToken, "", "", http.StatusForbidden},
		{"nonlocal host", http.MethodGet, "example.invalid", local, testToken, "", "", http.StatusForbidden},
		{"browser origin", http.MethodGet, local, local, testToken, "http://example.invalid", "", http.StatusForbidden},
		{"write method", http.MethodPost, local, local, testToken, "", "", http.StatusMethodNotAllowed},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := request(tc.method, tc.host, tc.remote, tc.bearer, tc.origin, tc.query).Code; got != tc.status {
				t.Fatalf("HTTP status %d, want %d", got, tc.status)
			}
		})
	}
	read := func() setup.PreflightHost {
		w := request(http.MethodGet, local, local, testToken, "", "")
		if w.Code != http.StatusOK || w.Header().Get("Cache-Control") != "no-store" {
			t.Fatalf("invalid response: status=%d headers=%v", w.Code, w.Header())
		}
		if strings.Contains(w.Body.String(), testToken) || strings.Contains(w.Body.String(), home) || strings.Contains(w.Body.String(), "private-cached-field") {
			t.Fatal("passive endpoint exposed local details")
		}
		var h setup.PreflightHost
		if err := json.Unmarshal(w.Body.Bytes(), &h); err != nil {
			t.Fatal(err)
		}
		return h
	}
	if h := read(); !h.Ready || len(h.Accounts) != 0 {
		t.Fatalf("empty cache claimed readiness: %+v", h)
	}
	now := time.Now()

	// Ensure the HTTP result only projects allowlisted account states from the current cache.
	cache.mu.Lock()
	cache.hasResult = true
	cache.snapshot = runtimeStatusResponse{CheckedAt: &now, Runtimes: []runtimeAccountStatus{
		{ID: "codex", State: runtimeStateConnected, PlanType: "private-cached-field"},
		{ID: "claude", State: runtimeStateSignedOut}, {ID: "agy", State: runtimeStateUnavailable},
	}}
	cache.mu.Unlock()
	if h := read(); !h.Ready || h.Version != "test" || !h.Assistants["codex"] || !h.Networks["lan"] || !reflect.DeepEqual(h.Accounts, map[string]string{"codex": "connected", "claude": "signed_out"}) {
		t.Fatalf("fresh cache projection: %+v", h)
	}
	cache.mu.Lock()
	cache.snapshot.Runtimes = []runtimeAccountStatus{
		{ID: "codex", State: runtimeStateUnavailable, Reason: "shared_local_session_unavailable"},
		{ID: "agy", State: runtimeStateAvailable, Reason: "quota_refresh_in_progress"},
	}
	cache.mu.Unlock()
	if h := read(); h.Accounts["codex"] != "upstream_unavailable" || h.Accounts["agy"] != "connected" {
		t.Fatal("cached upstream and quota observations lost")
	}
	stale := now.Add(-time.Hour)

	cache.mu.Lock()
	cache.snapshot.CheckedAt = &stale
	cache.mu.Unlock()
	if h := read(); !h.Ready || len(h.Accounts) != 0 {
		t.Fatalf("stale cache claimed readiness: %+v", h)
	}
	cache.mu.Lock()
	generation := cache.refreshGen
	cache.mu.Unlock()
	if generation != 0 || probes.Load() != 0 {
		t.Fatalf("reading preflight initiated a refresh: generation=%d probes=%d", generation, probes.Load())
	}
}
