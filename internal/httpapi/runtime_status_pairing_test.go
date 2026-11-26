package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/gaixianggeng/mimi-remote/internal/agybridge"
	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
)

func isolatePairingAssistantEnv(t *testing.T) {
	t.Helper()
	for _, entry := range os.Environ() {
		name, _, _ := strings.Cut(entry, "=")
		if strings.HasPrefix(name, "AGENTD_") {
			t.Setenv(name, "")
		}
	}
}

type coldPairingCodexTransport struct {
	directWSTestTransport
	readyCalls int
	urlCalls   int
}

func (t *coldPairingCodexTransport) WebSocketURL() (string, error) {
	t.urlCalls++
	if t.readyCalls == 0 {
		return "", errors.New("resident unavailable")
	}
	return t.directWSTestTransport.WebSocketURL()
}

func (t *coldPairingCodexTransport) EnsureReady(context.Context) error {
	t.readyCalls++
	return nil
}

func TestPairingAssistantCodexUsesSelectedAccountWithoutQuota(t *testing.T) {
	isolatePairingAssistantEnv(t)
	for _, tc := range []struct {
		kind string
		want bool
	}{
		{"chatgpt", true}, {"apiKey", true}, {"amazonBedrock", true}, {"unknown", false}, {"", false},
	} {
		t.Run(tc.kind, func(t *testing.T) {
			url, _, dials := fakeAppServerUpstream(t, func(conn *websocket.Conn, mt int, payload []byte) {
				var frame struct {
					ID     json.RawMessage
					Method string
				}
				if err := json.Unmarshal(payload, &frame); err != nil {
					t.Error(err)
					return
				}
				var value any
				switch frame.Method {
				case "initialize":
					value = map[string]string{"userAgent": "fixture-codex"}
				case "initialized":
					return
				case "account/read":
					var account any
					if tc.kind != "" {
						account = map[string]string{"type": tc.kind}
					}
					value = map[string]any{"account": account, "requiresOpenaiAuth": true}
				default:
					t.Errorf("unexpected pairing probe %s", frame.Method)
					return
				}
				if err := conn.WriteJSON(map[string]any{"id": frame.ID, "result": value}); err != nil {
					t.Error(err)
				}
			})
			_, r := appServerGatewayRouterFixtureWithRouter(t, url, nil)
			t.Cleanup(r.Shutdown)
			cold := &coldPairingCodexTransport{directWSTestTransport: directWSTestTransport{upstreamURL: url}}
			r.appServerSSH = cold
			for _, transport := range []string{"local", "ssh"} {
				r.cfg.AppServer.Transport = transport
				if r.pairingCodex(t.Context(), passivePairing) || dials.Load() != 0 || cold.urlCalls != 0 || cold.readyCalls != 0 {
					t.Fatal("passive discovery activated Codex")
				}
			}
			if got := r.checkPairingAssistant(t.Context(), "fixture-generation", explicitPairing) == nil; got != tc.want {
				t.Fatalf("usable = %v, want %v", got, tc.want)
			}
			if cold.readyCalls != 1 {
				t.Fatalf("explicit readiness calls = %d", cold.readyCalls)
			}
		})
	}
}

func TestPassiveCodexClaimUsesFreshAccountObservation(t *testing.T) {
	r := newPairingTestServer(t).router
	generation := r.pairingGeneration()
	r.pairingStatus.passivePairingProbe = func(context.Context) runtimeStatusResponse {
		now := time.Now()
		return runtimeStatusResponse{CheckedAt: &now}
	}
	r.pairingStatus.observeCodexAccount(generation, runtimeAccountStatus{Version: "fixture", State: runtimeStateConnected})
	if r.checkPairingAssistant(t.Context(), generation, passivePairing) != nil {
		t.Fatal("passive discovery lost a current authenticated account observation")
	}
	expirePairingAssistantEvidence(r)
	if r.checkPairingAssistant(t.Context(), generation, passivePairing) == nil {
		t.Fatal("stale host account observation admitted discovery")
	}
}

func TestLocalPairingUsesCodexObservationFromAppliedTailcatGeneration(t *testing.T) {
	isolatePairingAssistantEnv(t)
	for _, transport := range []string{"local", "ssh"} {
		t.Run(transport, func(t *testing.T) {
			if transport == "local" && !config.SupportsSharedLocalAppServer() {
				t.Skip("shared local transport requires macOS or Linux")
			}
			accountRead := make(chan struct{})
			hold, release := context.WithCancel(t.Context())
			defer release()
			pauseFirstRead := sync.OnceFunc(func() {
				close(accountRead)
				<-hold.Done()
			})
			respond := runtimeStatusCodexResponder(t)
			upstream, _, dials := fakeAppServerUpstream(t, func(conn *websocket.Conn, mt int, payload []byte) {
				var frame struct{ Method string }
				if err := json.Unmarshal(payload, &frame); err != nil {
					t.Error(err)
					return
				}
				if frame.Method == "account/read" {
					pauseFirstRead()
				}
				respond(conn, mt, payload)
			})
			root := t.TempDir()
			s := newFileBackedPairingServer(t, map[string]any{
				"auth": map[string]string{"token": testToken}, "app_server": map[string]string{"transport": transport},
				"scan_roots": []string{root}, "browse_roots": []string{root},
			}, directWSTestTransport{upstreamURL: upstream})
			r := s.router
			claim := func() *httptest.ResponseRecorder {
				req := httptest.NewRequest(http.MethodPost, "http://127.0.0.1:8787/api/pair/local", nil)
				req.RemoteAddr = "127.0.0.1:12345"
				req.Header.Set(localPairingHeader, "1")
				rec := httptest.NewRecorder()
				s.handler.ServeHTTP(rec, req)
				return rec
			}

			// Hold an authenticated account response across the live relay change.
			startup := r.cfg.SourceGeneration()
			first := make(chan runtimeAccountStatus, 1)
			go func() { first <- r.probeCodexRuntime(t.Context()) }()
			select {
			case <-accountRead:
			case status := <-first:
				t.Fatalf("host probe ended before account/read: %s", status.Reason)
			}
			if _, err := r.tailcat.ConfigureDERPMap(t.Context(), "https://relay.example.invalid/map"); err != nil {
				t.Fatal(err)
			}
			applied := r.appliedPairingGeneration()
			if applied == "" || applied == startup {
				t.Fatal("live relay change did not advance the applied generation")
			}
			if rec := claim(); rec.Code != http.StatusServiceUnavailable {
				t.Fatalf("claim before current account observation: %d", rec.Code)
			}
			release()
			if status := <-first; status.State != runtimeStateConnected {
				t.Fatalf("old account observation: %s", status.State)
			}
			if r.pairingStatus.stillFreshForPairing(startup) || r.pairingStatus.stillFreshForPairing(applied) {
				t.Fatal("in-flight observation from the old generation admitted pairing")
			}

			_, status := readRuntimeStatusEventually(t, s.handler)
			if status.Runtimes[0].State != runtimeStateConnected {
				t.Fatal("host status did not observe the authenticated Codex account")
			}
			rec := claim()
			var pair pairingClaimResponse
			if rec.Code != http.StatusOK || json.Unmarshal(rec.Body.Bytes(), &pair) != nil || pair.Token != testToken || pair.Endpoint != localPairingEndpoint {
				t.Fatalf("automatic claim after fresh host status: %d %s", rec.Code, rec.Body)
			}
			if got := dials.Load(); got != 2 {
				t.Fatalf("got %d Codex connections, want only the two host probes", got)
			}
		})
	}
}

func TestPairingAssistantUsesCurrentClaudeAndAgyAccount(t *testing.T) {
	isolatePairingAssistantEnv(t)
	const body = "IFS= read -r initialize\nprintf '{\"id\":1,\"result\":{\"userAgent\":\"fixture\"}}\\n'\nIFS= read -r initialized\n"
	for _, kind := range []string{"claude", "agy"} {
		t.Run(kind, func(t *testing.T) {
			bridge := writeTestBridge(t, body)
			var cli, report string
			codex := false
			cfg := config.Config{Codex: config.CodexConfig{Enabled: &codex}}
			if kind == "claude" {
				cli = writeTestBridgeWithVersion(t, "2.1.300 (Claude Code)")
				report = "{\"loggedIn\":true,\"authMethod\":\"api_key\"}"
				cfg.Claude = config.ClaudeConfig{Enabled: true, BridgeBin: bridge, Env: map[string]string{"CLAUDE_BRIDGE_CLAUDE_BIN": cli}}
			} else {
				cli = writeTestBridgeWithVersion(t, "1.5.14")
				report = "fixture-model\n"
				for suffix, content := range map[string]string{".version": "mimi-agy-adapter 0.1.0", ".capabilities": "{\"name\":\"mimi-agy-adapter\",\"version\":\"0.1.0\",\"methods\":[\"initialize\"],\"agy\":{\"minimumVersion\":\"1.5.0\"}}"} {
					if err := os.WriteFile(bridge+suffix, []byte(content), 0600); err != nil {
						t.Fatal(err)
					}
				}
				cfg.Agy = config.AgyConfig{Enabled: true, AdapterBin: bridge, Env: map[string]string{agybridge.AgyBinaryEnvKey: cli}}
			}
			if err := os.WriteFile(cli+".account", []byte(report), 0600); err != nil {
				t.Fatal(err)
			}
			_, r := appServerGatewayRouterFixtureWithRouter(t, "", func(out *config.Config) { out.Codex = cfg.Codex; out.Claude = cfg.Claude; out.Agy = cfg.Agy })
			t.Cleanup(r.Shutdown)
			if r.checkPairingAssistant(t.Context(), "fixture-generation", passivePairing) == nil ||
				r.claudeBridge.runningSince() != nil || r.agyAdapter.runningSince() != nil {
				t.Fatal("automatic discovery started a resident adapter")
			}
			if r.checkPairingAssistant(t.Context(), "fixture-generation", explicitPairing) != nil {
				t.Fatal("selected assistant with authenticated CLI and responding adapter rejected")
			}
			expirePairingAssistantEvidence(r)
			if r.checkPairingAssistant(t.Context(), "fixture-generation", passivePairing) != nil {
				t.Fatal("discovery rejected a running authenticated adapter")
			}
			if err := os.Remove(cli + ".account"); err != nil {
				t.Fatal(err)
			}
			expirePairingAssistantEvidence(r)
			if r.checkPairingAssistant(t.Context(), "fixture-generation", explicitPairing) == nil {
				t.Fatal("adapter alone must not retain lost account eligibility")
			}
		})
	}
}

func TestPairingAssistantDeepSeekRequiresReadOnlyAuthenticatedNonemptyCatalog(t *testing.T) {
	isolatePairingAssistantEnv(t)
	var models atomic.Bool
	models.Store(true)
	h := newFakeDeepSeekHarness(t)
	slow := make(chan struct{})
	defer close(slow)
	var delayCatalog atomic.Bool
	h.handle(harnessclient.MethodSessionModelCatalog, func(json.RawMessage) (any, *harnessclient.RemoteError) {
		if delayCatalog.Swap(false) {
			<-slow
		}
		if models.Load() {
			return json.RawMessage("{\"groups\":[{\"models\":[{\"id\":\"fixture\"}]}]}"), nil
		}
		return json.RawMessage("{\"groups\":[]}"), nil
	})
	s := h.serve()
	tokenPath := writeDeepSeekTestTokenFile(t, h.token)
	codex := false
	_, r := appServerGatewayRouterFixtureWithRouter(t, "", func(cfg *config.Config) {
		cfg.Codex.Enabled = &codex
		cfg.DeepSeek = config.DeepSeekConfig{Enabled: true, BaseURL: s.URL, TokenFile: tokenPath}
	})
	t.Cleanup(r.Shutdown)
	var attemptedRenewal atomic.Bool
	r.deepSeekCredential.renew = func(context.Context) error {
		attemptedRenewal.Store(true)
		return errors.New("unexpected pairing renewal")
	}
	if r.checkPairingAssistant(t.Context(), "fixture-generation", explicitPairing) != nil {
		t.Fatal("authenticated Harness with models rejected")
	}
	delayCatalog.Store(true)
	expirePairingAssistantEvidence(r)
	if f := r.checkPairingAssistant(t.Context(), "fixture-generation", explicitPairing); f == nil || f.code != "probe_timeout" {
		t.Fatalf("timed out model catalog: %v", f)
	}
	if r.checkPairingAssistant(t.Context(), "fixture-generation", explicitPairing) != nil {
		t.Fatal("timeout prevented an immediate retry")
	}
	models.Store(false)
	expirePairingAssistantEvidence(r)
	if r.checkPairingAssistant(t.Context(), "fixture-generation", explicitPairing) == nil {
		t.Fatal("empty catalog accepted")
	}
	models.Store(true)
	if err := os.WriteFile(tokenPath, []byte("bad-fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	expirePairingAssistantEvidence(r)
	if r.checkPairingAssistant(t.Context(), "fixture-generation", explicitPairing) == nil || attemptedRenewal.Load() {
		t.Fatal("rejected credential accepted or rotated")
	}
}

func expirePairingAssistantEvidence(r *Router) {
	c := r.pairingStatus
	c.mu.Lock()
	defer c.mu.Unlock()
	stale := c.now().Add(-pairingEvidenceTTL - time.Second)
	c.snapshot.CheckedAt = &stale
}

func TestPairingAssistantFreshnessAndCoalescedRefresh(t *testing.T) {
	const callers = 12
	var calls atomic.Int32
	var now atomic.Int64
	now.Store(time.Now().UnixNano())
	current := func() time.Time { return time.Unix(0, now.Load()) }
	release := make(chan struct{})
	entered := make(chan struct{})
	c := newRuntimeStatusSnapshotCache(func(ctx context.Context) runtimeStatusResponse {
		if calls.Add(1) == 1 {
			close(entered)
			select {
			case <-ctx.Done():
				return runtimeStatusResponse{}
			case <-release:
			}
		}
		stamp := current()
		return runtimeStatusResponse{CheckedAt: &stamp, Runtimes: []runtimeAccountStatus{{ID: "deepseek", Enabled: true, State: runtimeStateAvailable}}}
	}, func() runtimeStatusResponse { return runtimeStatusResponse{} })
	c.now = current
	defer c.Close()
	codex := false
	r := &Router{pairingStatus: c, cfg: config.Config{Codex: config.CodexConfig{Enabled: &codex}, DeepSeek: config.DeepSeekConfig{Enabled: true}}}
	var group sync.WaitGroup
	for range callers {
		group.Go(func() {
			if r.checkPairingAssistant(t.Context(), "fixture-generation", explicitPairing) != nil {
				t.Error("fresh result rejected")
			}
		})
	}
	<-entered
	close(release)
	group.Wait()
	now.Add(int64(pairingEvidenceTTL))
	if r.checkPairingAssistant(t.Context(), "fixture-generation", explicitPairing) != nil || calls.Load() != 1 {
		t.Fatal("inclusive 15s freshness or coalescing failed")
	}
	now.Add(1)
	if r.checkPairingAssistant(t.Context(), "fixture-generation", explicitPairing) != nil || calls.Load() != 2 {
		t.Fatal("stale evidence reused")
	}
	r.cfg.DeepSeek.Enabled = false
	r.cfg.Claude.Enabled = true
	if r.checkPairingAssistant(t.Context(), "fixture-generation", explicitPairing) == nil {
		t.Fatal("disabled working assistant admitted alongside unavailable enabled assistant")
	}
	r.cfg.Claude.Enabled = false
	if r.checkPairingAssistant(t.Context(), "fixture-generation", explicitPairing) == nil {
		t.Fatal("all assistants disabled yet gate succeeded")
	}
}

func TestPairingRefreshTimeoutHasItsOwnDiagnostic(t *testing.T) {
	s := newPairingTestServer(t)
	r := s.router
	r.pairingStatus.timeout = 5 * time.Millisecond
	r.pairingStatus.probe = func(ctx context.Context) runtimeStatusResponse {
		<-ctx.Done()
		return runtimeStatusResponse{}
	}
	failure := r.pairingGate(t.Context(), nil)
	if failure == nil || failure.code != "probe_timeout" {
		t.Fatalf("expected probe_timeout, got %v", failure)
	}
}

// The Done call in the cache's select proves a waiter reached the in-flight
// refresh before the test releases it. No sleep or scheduler assumption.
type waitingPairingContext struct {
	context.Context
	waiting chan struct{}
	once    sync.Once
}

func (c *waitingPairingContext) Done() <-chan struct{} {
	c.once.Do(func() { close(c.waiting) })
	return c.Context.Done()
}

func TestPairingRefreshIsKeyedToAppliedGeneration(t *testing.T) {
	var calls atomic.Int32
	entered, release := make(chan struct{}), make(chan struct{})
	c := newRuntimeStatusSnapshotCache(func(ctx context.Context) runtimeStatusResponse {
		call := calls.Add(1)
		if call == 1 {
			close(entered)
			select {
			case <-release:
			case <-ctx.Done():
				return runtimeStatusResponse{}
			}
		}
		now := time.Now()
		resp := runtimeStatusResponse{CheckedAt: &now}
		if call != 2 {
			resp.Runtimes = []runtimeAccountStatus{{ID: "deepseek", Enabled: true, State: runtimeStateAvailable}}
		}
		return resp
	}, func() runtimeStatusResponse { return runtimeStatusResponse{} })
	defer c.Close()
	first := make(chan struct{})
	go func() { defer close(first); _ = c.pairingSnapshot(t.Context(), "old", explicitPairing) }()
	<-entered
	later := &waitingPairingContext{Context: t.Context(), waiting: make(chan struct{})}
	second := make(chan runtimeStatusResponse, 1)
	go func() { second <- c.pairingSnapshot(later, "current", explicitPairing) }()
	<-later.waiting
	close(release)
	<-first
	// The original generation was healthy. The new observation must fail
	// even when a caller was already waiting for the old successful probe.
	snapshot := <-second
	if snapshot.CheckedAt == nil || len(snapshot.Runtimes) != 0 || calls.Load() != 2 {
		t.Fatalf("current generation reused old evidence: %+v, probes=%d", snapshot, calls.Load())
	}
	if r := c.pairingSnapshot(t.Context(), "current", explicitPairing); r.CheckedAt == nil || len(r.Runtimes) != 0 || calls.Load() != 2 {
		t.Fatal("did not reuse fresh current-generation failure")
	}
	if r := c.pairingSnapshot(t.Context(), "after-hot-edit", explicitPairing); len(r.Runtimes) != 1 || calls.Load() != 3 {
		t.Fatal("previous generation's fresh failure reused after a hot change")
	}
}
