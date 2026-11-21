package httpapi

import (
	"context"
	"net"
	"sync"
	"testing"
)

func TestNormalizeAppServerRuntimeIDReadsSpecAliases(t *testing.T) {
	cases := map[string]string{
		"":                   appServerRuntimeCodexID,
		"codex":              appServerRuntimeCodexID,
		"OpenAI":             appServerRuntimeCodexID,
		"codex-app-server":   appServerRuntimeCodexID,
		"claude":             appServerRuntimeClaudeID,
		"Claude_Code_Bridge": appServerRuntimeClaudeID,
		"unknown-runtime":    "unknown-runtime",
	}
	for raw, want := range cases {
		if got := normalizeAppServerRuntimeID(raw); got != want {
			t.Fatalf("normalizeAppServerRuntimeID(%q) = %q, want %q", raw, got, want)
		}
	}
	if !appServerRuntimeUsesAdapterSandbox("claude-code") {
		t.Fatal("expected claude alias to use adapter sandbox normalization")
	}
	if appServerRuntimeUsesAdapterSandbox("codex") {
		t.Fatal("expected codex not to use adapter sandbox normalization")
	}
}

func TestResidentApprovalObserverIsolatesRuntimesSharingSessionKey(t *testing.T) {
	router := &Router{}
	claudeEpoch := router.stopResidentApprovalObserver("claude", "shared-session")
	otherEpoch := router.stopResidentApprovalObserver("agy", "shared-session")

	connA, peerA := net.Pipe()
	connB, peerB := net.Pipe()
	t.Cleanup(func() {
		_ = connA.Close()
		_ = peerA.Close()
		_ = connB.Close()
		_ = peerB.Close()
	})
	_, cancelA := context.WithCancel(context.Background())
	_, cancelB := context.WithCancel(context.Background())

	claudeObs := &claudeApprovalObserver{
		router:      router,
		runtimeID:   "claude",
		sessionKey:  "shared-session",
		conn:        connA,
		writeMu:     &sync.Mutex{},
		policy:      newAppServerGatewayPolicy(router, "claude"),
		cancel:      cancelA,
		activeTurns: map[string]struct{}{},
		pending:     map[string]string{},
	}
	otherObs := &claudeApprovalObserver{
		router:      router,
		runtimeID:   "agy",
		sessionKey:  "shared-session",
		conn:        connB,
		writeMu:     &sync.Mutex{},
		policy:      newAppServerGatewayPolicy(router, "agy"),
		cancel:      cancelB,
		activeTurns: map[string]struct{}{},
		pending:     map[string]string{},
	}

	if _, ok := router.installClaudeApprovalObserver(claudeObs, claudeEpoch); !ok {
		t.Fatal("expected claude observer install to succeed")
	}
	if _, ok := router.installClaudeApprovalObserver(otherObs, otherEpoch); !ok {
		t.Fatal("expected second runtime observer with same sessionKey to coexist")
	}
	if router.residentApprovalObserverFor("claude", "shared-session") != claudeObs {
		t.Fatal("claude observer overwritten by other runtime")
	}
	if router.residentApprovalObserverFor("agy", "shared-session") != otherObs {
		t.Fatal("other runtime observer not stored independently")
	}
	otherObs.close("test_done")
	if router.residentApprovalObserverFor("claude", "shared-session") != claudeObs {
		t.Fatal("closing other runtime observer affected claude observer")
	}
	claudeObs.close("test_done")
}
