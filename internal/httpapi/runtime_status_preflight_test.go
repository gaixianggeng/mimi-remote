package httpapi

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
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

func TestPreflightLocalEndpointReportsUnsafeSharedCodexSocketEvenWithEmptyCache(t *testing.T) {
	if !config.SupportsSharedLocalAppServer() {
		t.Skip("本机共享 Codex App Server 仅支持 macOS 与 Linux")
	}
	root := t.TempDir()
	t.Setenv("HOME", root)
	t.Setenv("USERPROFILE", root)
	t.Setenv("CODEX_HOME", "")
	codexHome := filepath.Join(root, ".codex")
	if err := os.MkdirAll(codexHome, 0o700); err != nil {
		t.Fatal(err)
	}
	// 动态构造仅用于本地单测的时间有效样例结构，确保在空缓存且安全 socket 下
	// passiveFileAccount 会回退判为 connected，从而严格验证不安全 socket 能覆盖该回退。
	now := time.Now().Unix()
	jwtHeader := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"RS256"}`))
	jwtPayload := base64.RawURLEncoding.EncodeToString([]byte(fmt.Sprintf(`{"nbf":%d,"exp":%d}`, now-60, now+3600)))
	jwtSig := base64.RawURLEncoding.EncodeToString([]byte("fixture-sig"))
	authJSON, err := json.Marshal(map[string]any{
		"auth_mode": "chatgpt",
		"tokens": map[string]string{
			"access_token": jwtHeader + "." + jwtPayload + "." + jwtSig,
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	configtest.CreatePrivateFile(t, filepath.Join(codexHome, "auth.json"), authJSON)
	fakeCodex := filepath.Join(root, "fake-codex")
	fakeScript := "#!/bin/sh\necho 'codex-cli 0.172.0'\n"
	if err := os.WriteFile(fakeCodex, []byte(fakeScript), 0o755); err != nil {
		t.Fatal(err)
	}

	var unsafe atomic.Bool
	var handler http.Handler
	httpServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		handler.ServeHTTP(w, req)
	}))
	defer httpServer.Close()

	document := map[string]any{
		"listen":     strings.TrimPrefix(httpServer.URL, "http://"),
		"auth":       map[string]string{"token": testToken},
		"network":    map[string]bool{"allow_lan": true, "allow_tailscale": false},
		"scan_roots": []string{root}, "browse_roots": []string{root},
		"app_server": map[string]any{"transport": "local"},
		"codex": map[string]any{
			"enabled": true,
			"bin":     fakeCodex,
		},
	}
	server := newFileBackedPairingServer(t, document, nil)
	handler = server.handler
	r := server.router
	r.sharedLocalSocketSafety = func() error {
		if unsafe.Load() {
			return errors.New("共享 Codex 目录 /tmp/codex-daemon-1000 不安全（systemd 预检已拒绝绑定），已忽略")
		}
		return nil
	}

	// 先确认空缓存 + 安全 socket 下，真实 RunPreflight 会回退读取本地 auth.json 判 Codex 可用。
	safeReport := setup.RunPreflight(context.Background(), setup.PreflightOptions{
		Stage:      "pair",
		ConfigPath: r.configPath,
		Version:    r.version,
	}, nil)
	for _, row := range safeReport.Checks {
		if row.ID == "assistant_codex" && row.State != "ok" {
			t.Fatalf("基线安全场景下空缓存应回退识别本地 auth.json 为 ok，got=%+v", row)
		}
	}

	// 再将共享 socket 切换为不安全（缓存仍为空）：/api/local/preflight 与真实 RunPreflight 都必须拒绝。
	unsafe.Store(true)
	req := httptest.NewRequest(http.MethodGet, "http://127.0.0.1:8787/api/local/preflight", nil)
	req.RemoteAddr = "127.0.0.1:39003"
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
	if host.Accounts["codex"] != "upstream_unavailable" {
		t.Fatalf("缓存为空且共享 socket 不安全时 preflight 必须返回 codex=upstream_unavailable，got=%+v", host.Accounts)
	}

	unsafeReport := setup.RunPreflight(context.Background(), setup.PreflightOptions{
		Stage:      "pair",
		ConfigPath: r.configPath,
		Version:    r.version,
	}, nil)
	if unsafeReport.OK {
		t.Fatalf("仅启用 Codex 且共享 socket 被拒绝时真实 RunPreflight 不得报告 OK：%+v", unsafeReport)
	}
	foundCodexUnavailable := false
	for _, row := range unsafeReport.Checks {
		if row.ID == "assistant_codex" && row.Code == "codex_upstream_unavailable" {
			foundCodexUnavailable = true
		}
	}
	if !foundCodexUnavailable {
		t.Fatalf("真实 RunPreflight 缺少 assistant_codex=codex_upstream_unavailable：%+v", unsafeReport.Checks)
	}
}
