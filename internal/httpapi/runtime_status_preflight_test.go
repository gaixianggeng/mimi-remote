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
	"github.com/gaixianggeng/mimi-remote/internal/config/configtest"
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

func TestPreflightLocalEndpointReportsAppliedGeneration(t *testing.T) {
	root := t.TempDir()
	document := map[string]any{
		"listen":     "127.0.0.1:8787",
		"auth":       map[string]string{"token": testToken},
		"network":    map[string]bool{"allow_lan": true, "allow_tailscale": false},
		"scan_roots": []string{root}, "browse_roots": []string{root},
		"codex": map[string]bool{"enabled": false},
	}
	server := newFileBackedPairingServer(t, document, nil)
	r := server.router
	readHost := func() setup.PreflightHost {
		t.Helper()
		req := httptest.NewRequest(http.MethodGet, "http://127.0.0.1:8787/api/local/preflight", nil)
		req.RemoteAddr = "127.0.0.1:39002"
		req.Header.Set("Authorization", "Bearer "+testToken)
		w := httptest.NewRecorder()
		server.handler.ServeHTTP(w, req)
		if w.Code != http.StatusOK {
			t.Fatalf("preflight status=%d body=%s", w.Code, w.Body.String())
		}
		var host setup.PreflightHost
		if err := json.Unmarshal(w.Body.Bytes(), &host); err != nil {
			t.Fatal(err)
		}
		return host
	}

	initial := readHost()
	wantGen := r.cfg.SourceGeneration()
	if wantGen == "" || initial.AppliedGeneration == nil || *initial.AppliedGeneration != wantGen {
		t.Fatalf("未修改配置时应返回当前已应用 generation %q，got=%+v", wantGen, initial.AppliedGeneration)
	}

	// 仅修改内存热生效的 Tailcat 字段且 live supervisor 同步后，applied_generation 应跟随新配置代次。
	document["tailcat"] = map[string]any{"enabled": true}
	liveTailcatBytes, err := json.Marshal(document)
	if err != nil {
		t.Fatal(err)
	}
	configtest.WritePrivateFile(t, r.configPath, liveTailcatBytes)
	if sup, ok := r.tailcat.(*tailcatSidecarSupervisor); ok {
		sup.mu.Lock()
		sup.config.Enabled = true
		sup.mu.Unlock()
	}
	liveTailcatGen := config.ReadPreflightSnapshot(r.configPath).Config.SourceGeneration()
	liveHost := readHost()
	if liveHost.AppliedGeneration == nil || *liveHost.AppliedGeneration != liveTailcatGen {
		t.Fatalf("热生效 Tailcat 后 applied_generation 应等于最新配置代次 %q，got=%v", liveTailcatGen, liveHost.AppliedGeneration)
	}

	// 修改需要重启的字段后，applied_generation 应为空字符串（与 /api/local/pair/issue 门禁一致）。
	document["browse_roots"] = []string{t.TempDir()}
	editedBytes, err := json.Marshal(document)
	if err != nil {
		t.Fatal(err)
	}
	configtest.WritePrivateFile(t, r.configPath, editedBytes)
	editedHost := readHost()
	if editedHost.AppliedGeneration == nil || *editedHost.AppliedGeneration != "" {
		t.Fatalf("未重启应用配置改动时 applied_generation 应为空字符串，got=%v", editedHost.AppliedGeneration)
	}
}
