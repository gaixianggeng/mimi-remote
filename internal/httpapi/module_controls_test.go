package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestDisabledCodexSkipsProbeGatewayAndQuotaButPreservesClaudeChannel(t *testing.T) {
	off := false
	r := &Router{cfg: config.Config{Codex: config.CodexConfig{Enabled: &off}, Claude: config.ClaudeConfig{Enabled: true}}}
	state := r.probeCodexRuntime(context.Background())
	if state.Enabled || state.State != runtimeStateDisabled || state.RateLimits != nil {
		t.Fatalf("bad disabled state: %+v", state)
	}
	if check := r.appServerUpstreamReadinessCheck(context.Background()); !check.OK {
		t.Fatal("disabled Codex made host unready")
	}
	req := httptest.NewRequest(http.MethodGet, "/api/app-server/ws", nil)
	rec := httptest.NewRecorder()
	r.appServerCodexGatewayWS(rec, req)
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("disabled gateway = %d", rec.Code)
	}
	channels := r.appServerChannels(req)
	if len(channels) != 1 || channels[0].RuntimeID != "claude" {
		t.Fatalf("wrong channels: %+v", channels)
	}
	rec = httptest.NewRecorder()
	r.voiceTranscribeHandler(rec, httptest.NewRequest(http.MethodPost, "/api/voice/transcribe", strings.NewReader("{}")))
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatal("disabled Codex still allowed transcription")
	}
}

func TestModuleStatusIsResidentStateAndRequiresLoopbackAndAuthentication(t *testing.T) {
	upstream, _, _ := fakeAppServerUpstream(t, runtimeStatusCodexResponder(t))
	handler, r := appServerGatewayRouterFixtureWithRouter(t, upstream, nil)
	off := false
	r.cfg.Codex.Enabled = &off
	r.cfg.Claude.Enabled = true
	r.cfg.Network.AllowTailscale = &off
	r.cfg.Network.AllowLAN = true
	unauth := httptest.NewRecorder()
	handler.ServeHTTP(unauth, httptest.NewRequest(http.MethodGet, "/api/host/modules", nil))
	if unauth.Code != http.StatusUnauthorized {
		t.Fatalf("auth not required: %d", unauth.Code)
	}
	remote := httptest.NewRequest(http.MethodGet, "/api/host/modules", nil)
	remote.RemoteAddr = "192.168.50.3:9000"
	rec := httptest.NewRecorder()
	r.moduleStatusHandler(rec, remote)
	if rec.Code != http.StatusForbidden {
		t.Fatal("module status exposed remotely")
	}
	local := httptest.NewRequest(http.MethodGet, "http://127.0.0.1/api/host/modules", nil)
	local.RemoteAddr = "127.0.0.1:9000"
	rec = httptest.NewRecorder()
	r.moduleStatusHandler(rec, local)
	var status config.ModuleStatus
	if err := json.Unmarshal(rec.Body.Bytes(), &status); err != nil {
		t.Fatal(err)
	}
	if status.CodexEnabled || !status.ClaudeEnabled || status.TailscaleEnabled || !status.LANEnabled {
		t.Fatalf("wrong resident flags: %+v", status)
	}
}

func TestAllAgentsOffCannotIssueLocalOrTailcatPairing(t *testing.T) {
	off := false
	r := &Router{cfg: config.Config{Codex: config.CodexConfig{Enabled: &off}, Auth: config.AuthConfig{Token: "module-test-only"}}}
	req := httptest.NewRequest(http.MethodPost, "http://127.0.0.1/api/pair/local", nil)
	req.RemoteAddr = "127.0.0.1:1000"
	req.Header.Set(localPairingHeader, "1")
	rec := httptest.NewRecorder()
	r.localPairingClaimHandler(rec, req)
	if rec.Code != http.StatusServiceUnavailable || strings.Contains(rec.Body.String(), "module-test-only") {
		t.Fatal("local pairing returned credentials")
	}
	rec = httptest.NewRecorder()
	r.tailcatLocalAction(rec, httptest.NewRequest(http.MethodPost, "/api/tailcat/local", strings.NewReader(`{"action":"pair"}`)))
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatal("Tailcat pairing should fail before invoking sidecar")
	}
}
