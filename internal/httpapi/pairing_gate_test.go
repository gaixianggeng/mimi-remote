package httpapi

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/auth"
	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/config/configtest"
	"github.com/gaixianggeng/mimi-remote/internal/doctor"
	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
	"github.com/gaixianggeng/mimi-remote/internal/setup"
)

// The legacy handler tests supply an applied, reachable host and a healthy
// account. Dedicated gate tests below exercise the underlying evidence.
func newPairingTestServer(t *testing.T) testServer {
	t.Helper()
	root := t.TempDir()
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.ScanRoots, cfg.BrowseRoots = []string{root}, []string{root}
		cfg.AppServer.SSHTarget = "127.0.0.1"
		cfg.Listen = "0.0.0.0:8787"
		cfg.Network.AllowLAN = true
	})
	r := server.router
	r.pairingGeneration = func() string { return "fixture-generation" }
	r.directReachable = func(_ context.Context, a *net.TCPAddr) bool { return a.Port == 8787 }
	r.pairingStatus.probe = func(context.Context) runtimeStatusResponse {
		now := time.Now()
		return runtimeStatusResponse{CheckedAt: &now, Runtimes: []runtimeAccountStatus{{ID: "codex", Enabled: true, State: runtimeStateAvailable}}}
	}
	r.pairingStatus.passivePairingProbe = r.pairingStatus.probe
	t.Cleanup(r.Shutdown)
	return server
}

func performLocalIssue(t *testing.T, s testServer, generation string, change func(*http.Request)) *httptest.ResponseRecorder {
	t.Helper()
	req := authedRequest(t, http.MethodPost, "/api/local/pair/issue", map[string]string{"network": "lan", "version": "test", "generation": generation})
	req.RemoteAddr = "127.0.0.1:12345"
	req.Host = "127.0.0.1:8787"
	req.Header.Set(TailcatLocalControlHeader, s.router.tailcatLocalToken)
	if change != nil {
		change(req)
	}
	rec := httptest.NewRecorder()
	s.handler.ServeHTTP(rec, req)
	return rec
}

func newFileBackedPairingServer(t *testing.T, document map[string]any, transport AppServerTransport) testServer {
	t.Helper()
	path := filepath.Join(t.TempDir(), "config.json")
	raw, err := json.Marshal(document)
	if err != nil {
		t.Fatal(err)
	}
	configtest.CreatePrivateFile(t, path, raw)
	cfg, err := config.LoadForDoctor(path)
	if err != nil {
		t.Fatal(err)
	}
	registry, err := projects.NewRegistry(cfg.Projects)
	if err != nil {
		t.Fatal(err)
	}
	checker := doctor.NewChecker("test", cfg, registry, path)
	handler, r := NewRouterWithInstallationIDAndOptions(cfg, registry, checker, "test", "", RouterOptions{ConfigPath: path, AppServerSSH: transport})
	t.Cleanup(r.Shutdown)
	return testServer{handler: handler, router: r}
}

func TestDeepSeekOnlyIssuesAndClaimsOnAppliedGeneration(t *testing.T) {
	isolatePairingAssistantEnv(t)
	root := t.TempDir()
	h := newFakeDeepSeekHarness(t)
	var models atomic.Bool
	models.Store(true)
	h.handle(harnessclient.MethodSessionModelCatalog, func(json.RawMessage) (any, *harnessclient.RemoteError) {
		if models.Load() {
			return json.RawMessage(`{"groups":[{"models":[{"id":"fixture"}]}]}`), nil
		}
		return json.RawMessage(`{"groups":[]}`), nil
	})
	upstream := h.serve()
	document := map[string]any{
		"listen": "127.0.0.1:8787", "auth": map[string]string{"token": testToken},
		"network":    map[string]bool{"allow_lan": true, "allow_tailscale": false},
		"scan_roots": []string{root}, "browse_roots": []string{root},
		"codex": map[string]bool{"enabled": false}, "deepseek": map[string]any{"enabled": true, "base_url": upstream.URL, "token_file": writeDeepSeekTestTokenFile(t, h.token)},
	}
	s := newFileBackedPairingServer(t, document, nil)
	r, handler := s.router, s.handler
	const endpoint = "http://192.168.50.5:8787"
	r.directCandidate = func(context.Context, string, config.Config, setup.PairingNetwork) (setup.Result, error) {
		return setup.Result{Endpoint: endpoint, Token: testToken, Network: setup.PairingNetworkLAN}, nil
	}
	r.directReachable = func(_ context.Context, a *net.TCPAddr) bool { return "http://"+a.String() == endpoint }
	g := r.cfg.SourceGeneration()
	if g == "" || g != r.appliedPairingGeneration() {
		t.Fatalf("applied document unavailable: %s", config.ReadPreflightSnapshot(r.configPath).Code)
	}
	issue := performLocalIssue(t, s, g, nil)
	var pair setup.Result
	if issue.Code != 200 || json.Unmarshal(issue.Body.Bytes(), &pair) != nil || pair.PairURL == "" {
		t.Fatalf("DeepSeek-only issue: %d %s", issue.Code, issue.Body.String())
	}
	u, err := url.Parse(pair.PairURL)
	if err != nil {
		t.Fatal(err)
	}
	connect, err := url.Parse(pair.ConnectURL)
	if err != nil || connect.Scheme != "mimiremote" || connect.Host != "connect" || connect.Query().Get("token") != testToken || connect.Query().Get("endpoint") != pair.Endpoint {
		t.Fatal("legacy connect link lost the endpoint or bearer")
	}
	if u.Scheme != "mimiremote" || u.Host != "pair" || u.Query().Has("token") || u.Query().Get("endpoint") != pair.Endpoint || u.Query().Get("expires_at") != pair.PairExpiresAt {
		t.Fatal("invalid short-lived QR link")
	}
	claim := pairingClaimRequest{Endpoint: pair.Endpoint, IssuedAt: pair.PairIssuedAt, ExpiresAt: pair.PairExpiresAt, Signature: u.Query().Get("pair_sig")}
	if response := performPairingClaim(t, handler, claim); response.Code != 200 {
		t.Fatalf("claim: %d %s", response.Code, response.Body.String())
	}
	for _, tc := range []struct {
		name   string
		mutate func(*http.Request)
		want   int
	}{
		{"wrong bearer", func(q *http.Request) { q.Header.Set("Authorization", "Bearer wrong") }, 401},
		{"wrong local control", func(q *http.Request) { q.Header.Del(TailcatLocalControlHeader) }, 403},
		{"remote source", func(q *http.Request) { q.RemoteAddr = "192.168.50.2:12345" }, 403},
		{"external Host", func(q *http.Request) { q.Host = "example.invalid" }, 403},
		{"Origin", func(q *http.Request) { q.Header.Set("Origin", "https://example.invalid") }, 403},
		{"wrong version", func(q *http.Request) {
			q.Body = io.NopCloser(strings.NewReader(fmt.Sprintf(`{"network":"lan","generation":%q,"version":"another-build"}`, g)))
		}, 503},
	} {
		t.Run(tc.name, func(t *testing.T) {
			rejected := performLocalIssue(t, s, g, tc.mutate)
			if rejected.Code != tc.want || strings.Contains(rejected.Body.String(), "pair_sig") {
				t.Fatalf("unauthorized issuance: %d", rejected.Code)
			}
		})
	}
	r.directReachable = func(context.Context, *net.TCPAddr) bool { return false }
	if response := performLocalIssue(t, s, g, nil); response.Code != 503 {
		t.Fatal("issued after listener loss")
	}
	if response := performPairingClaim(t, handler, claim); response.Code != 503 {
		t.Fatal("claimed after listener loss")
	}
	r.directReachable = func(context.Context, *net.TCPAddr) bool { return true }
	models.Store(false)
	expirePairingAssistantEvidence(r)
	if response := performPairingClaim(t, handler, claim); response.Code != 503 || strings.Contains(response.Body.String(), testToken) {
		t.Fatalf("lost assistant: %d", response.Code)
	}
	if response := performLocalIssue(t, s, g, nil); response.Code != 503 {
		t.Fatal("empty Harness catalog permitted issue")
	}
	models.Store(true)
	expirePairingAssistantEvidence(r)
	document["browse_roots"] = []string{t.TempDir()}
	changed, err := json.Marshal(document)
	if err != nil {
		t.Fatal(err)
	}
	configtest.WritePrivateFile(t, r.configPath, changed)
	if r.appliedPairingGeneration() != "" {
		t.Fatal("new workspace incorrectly attributed to running daemon")
	}
	if response := performPairingClaim(t, handler, claim); response.Code != 503 {
		t.Fatal("accepted ticket after generation change")
	}
}

func TestPairIssuanceRechecksResidentLANPolicyOnlyForLAN(t *testing.T) {
	s := newPairingTestServer(t)
	r := s.router
	r.tailcatLocalToken = "fixture-control"
	var code string
	var policyCalls int
	r.confirmLANPolicy = func(context.Context) string {
		policyCalls++
		return code
	}
	r.directCandidate = func(context.Context, string, config.Config, setup.PairingNetwork) (setup.Result, error) {
		return setup.Result{Endpoint: "http://192.168.50.2:8787", Token: testToken, Network: setup.PairingNetworkLAN}, nil
	}
	for _, code = range []string{"", "lan_public_network_blocked", "lan_firewall_blocked", "probe_timeout", ""} {
		reply := performLocalIssue(t, s, r.pairingGeneration(), nil)
		if code == "" {
			var result setup.Result
			if json.Unmarshal(reply.Body.Bytes(), &result) != nil || reply.Code != http.StatusOK || result.PairURL == "" || result.Endpoint != "http://192.168.50.2:8787" {
				t.Fatal("safe LAN failed to issue a link")
			}
			continue
		}
		var failure struct{ Code, Step string }
		if json.Unmarshal(reply.Body.Bytes(), &failure) != nil || reply.Code != http.StatusServiceUnavailable || failure.Code != code || failure.Step != "network_lan" || strings.Contains(reply.Body.String(), testToken) || strings.Contains(reply.Body.String(), "pair_sig") {
			t.Fatal("unsafe LAN issued credentials or lost its diagnostic")
		}
	}
	if failure := r.directRoute(t.Context(), "http://100.64.0.2:8787"); failure != nil || policyCalls != 5 {
		t.Fatalf("LAN policy affected Tailscale: %v, calls=%d", failure, policyCalls)
	}
}

func TestPairingRechecksWorkspaceAfterRouteProbe(t *testing.T) {
	r := newPairingTestServer(t).router
	missing := filepath.Join(t.TempDir(), "disconnected")
	if err := os.Mkdir(missing, 0700); err != nil {
		t.Fatal(err)
	}
	r.cfg.BrowseRoots = []string{missing}
	failure := r.pairingGate(t.Context(), func(context.Context) *tailcatActionFailure {
		if err := os.Remove(missing); err != nil {
			t.Fatal(err)
		}
		return nil
	})
	if failure == nil || failure.code != "workspace_not_found" {
		t.Fatalf("disconnected workspace admitted: %v", failure)
	}
}

func TestPendingWorkspaceDisclosedOnlyAfterAuthentication(t *testing.T) {
	server := newPairingTestServer(t)
	pending := false
	server.router.cfg.Onboarding.Confirmed = &pending
	now := time.Now()
	ticket := auth.NewPairingTicket("http://192.168.50.5:8787", testToken, now, now.Add(time.Minute))
	payload := pairingClaimRequest{Endpoint: ticket.Endpoint, IssuedAt: ticket.IssuedAt, ExpiresAt: ticket.ExpiresAt, Signature: ticket.Signature}
	for _, v1 := range []bool{false, true} {
		for _, valid := range []bool{false, true} {
			copy := payload
			if !valid {
				copy.Signature = "invalid"
			}
			req := pairingClaimHTTPRequest(t, copy)
			if v1 {
				req.Header.Set("Accept", pairingErrorMediaType)
			}
			rec := httptest.NewRecorder()
			server.handler.ServeHTTP(rec, req)
			want := http.StatusUnauthorized
			if valid {
				want = http.StatusConflict
			}
			if rec.Code != want || strings.Contains(rec.Body.String(), testToken) {
				t.Errorf("valid=%v v1=%v: %d", valid, v1, rec.Code)
			}
			if v1 && strings.Contains(rec.Body.String(), "workspace_confirmation_required") != valid {
				t.Fatal("unexpected disclosure")
			}
		}
	}
}

func TestPairingGateReleasesBlockedFileReadOnCancellation(t *testing.T) {
	r := newPairingTestServer(t).router
	entered, release := make(chan struct{}), make(chan struct{})
	defer close(release)
	r.pairingGeneration = func() string {
		close(entered)
		<-release
		return "fixture-generation"
	}
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	done := make(chan *tailcatActionFailure, 1)
	go func() { done <- r.pairingGate(ctx, nil) }()
	<-entered
	cancel()
	select {
	case f := <-done:
		if f == nil {
			t.Fatal("cancelled file check admitted pairing")
		}
	case <-time.After(time.Second):
		t.Fatal("pairing remained blocked on the filesystem after cancellation")
	}
}
