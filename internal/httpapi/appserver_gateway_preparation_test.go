package httpapi

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
)

type pendingTestTransport struct {
	directWSTestTransport
	lookups atomic.Int32
}

func (p *pendingTestTransport) WebSocketURL() (string, error) {
	p.lookups.Add(1)
	return "", errors.New("transport preparation pending")
}

func TestPendingCodexPreparationReportsUnavailable(t *testing.T) {
	handler, router := appServerGatewayRouterFixtureWithRouter(t, "", nil)
	pending := &pendingTestTransport{}
	router.appServerSSH = pending
	defer router.Shutdown()

	// A request that fails the WebSocket handshake must not trigger preparation.
	req := httptest.NewRequest(http.MethodGet, appServerGatewayPath, nil)
	req.Header.Set("Authorization", "Bearer "+testToken)
	req.Header.Set("Connection", "Upgrade")
	req.Header.Set("Upgrade", "websocket")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusBadRequest || pending.lookups.Load() != 0 {
		t.Fatalf("incomplete handshake: HTTP %d, transport lookups %d", rec.Code, pending.lookups.Load())
	}

	server := httptest.NewServer(handler)
	defer server.Close()
	client := dialAuthedGateway(t, server.URL)
	defer client.Close()
	if frame := readGatewayError(t, client); frame.data["reason"] != "codex_upstream_unavailable" {
		t.Fatalf("pending gateway error = %+v", frame)
	}
	status := router.probeCodexRuntime(t.Context())
	if status.State != runtimeStateUnavailable || status.Reason != "upstream_unavailable" {
		t.Fatalf("pending runtime state = %q, reason = %q", status.State, status.Reason)
	}
	if got := pending.lookups.Load(); got != 2 {
		t.Fatalf("gateway and runtime refresh performed %d transport lookups, want 2", got)
	}
}
