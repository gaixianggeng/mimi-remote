package httpapi

import (
	"context"
	"errors"
	"github.com/gaixianggeng/mimi-remote/internal/config"
	"net"
	"slices"
	"sync"
	"testing"
	"time"
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

func TestRouterDefersAssistantDiscoveryUntilRequested(t *testing.T) {
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.Claude.Enabled, cfg.Agy.Enabled = true, true
	})
	t.Cleanup(server.router.Shutdown)
	if !server.router.claudeBridgeProbe().CheckedAt.IsZero() || !server.router.agyAdapterProbeSnapshot().CheckedAt.IsZero() {
		t.Fatal("router construction ran an assistant probe before serving HTTP")
	}
}

func TestResidentAdapterReportsChangedCLIWithoutInterruptingTurns(t *testing.T) {
	bin := copyFakeBridge(t, t.TempDir(), "resident-adapter")
	for _, tc := range []struct {
		name, key     string
		newSupervisor func() *claudeBridgeSupervisor
	}{
		{"claude", "CLAUDE_BRIDGE_CLAUDE_BIN", newClaudeBridgeSupervisor},
		{"agy", "AGY_ADAPTER_AGY_BIN", newAgyAdapterSupervisor},
	} {
		t.Run(tc.name, func(t *testing.T) {
			supervisor := tc.newSupervisor()
			t.Cleanup(supervisor.shutdown)
			env := map[string]string{tc.key: "fixture-cli-before"}
			ensure := func() int {
				t.Helper()
				if _, err := supervisor.ensure(bin, nil, env); err != nil {
					t.Fatal(err)
				}
				supervisor.mu.Lock()
				defer supervisor.mu.Unlock()
				if !slices.Contains(supervisor.cmd.Env, tc.key+"="+env[tc.key]) {
					t.Fatal("running adapter did not receive the selected CLI")
				}
				return supervisor.cmd.Process.Pid
			}
			first := ensure()
			if ensure() != first {
				t.Fatal("unchanged adapter was replaced")
			}
			env[tc.key] = "fixture-cli-after"
			if _, err := supervisor.ensure(bin, nil, env); !errors.Is(err, errAdapterRestartRequired) {
				t.Fatalf("changed CLI got %v", err)
			}
			supervisor.mu.Lock()
			child, done := supervisor.cmd.Process, supervisor.done
			supervisor.mu.Unlock()
			if child.Pid != first || supervisor.runningSince() == nil {
				t.Fatal("rediscovery interrupted the previous adapter")
			}
			if err := child.Kill(); err != nil {
				t.Fatal(err)
			}
			select {
			case <-done:
			case <-time.After(5 * time.Second):
				t.Fatal("fixture child did not exit")
			}
			ensure()
		})
	}
}
