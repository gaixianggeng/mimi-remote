package httpapi

import (
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/agybridge"
	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestAgyRuntimeNormalizationAndChannelDeclaration(t *testing.T) {
	for _, alias := range []string{"agy", "antigravity", "antigravity-cli", "agy-cli"} {
		if got := normalizeAppServerRuntimeID(alias); got != appServerRuntimeAgyID {
			t.Fatalf("normalizeAppServerRuntimeID(%q) = %q, want %q", alias, got, appServerRuntimeAgyID)
		}
	}
	if !appServerRuntimeUsesAdapterSandbox(appServerRuntimeAgyID) {
		t.Fatalf("expected agy to use adapter sandbox")
	}

	policy, reviewer := sanitizedGatewayApproval(map[string]any{
		"approvalPolicy":    "on-request",
		"approvalsReviewer": "accept_edits",
	}, true, false)
	if policy != "on-request" || reviewer != "accept_edits" {
		t.Fatalf("expected accept_edits reviewer to pass sanitization, got %s/%s", policy, reviewer)
	}

	router := &Router{
		cfg: config.Config{
			Listen: "127.0.0.1:8787",
			Agy:    config.AgyConfig{Enabled: true, AdapterBin: "mimi-agy-adapter", MaxConcurrentSessions: 3},
		},
		agyAdapter: newAgyAdapterSupervisor(),
	}
	router.setAgyAdapterProbe(agyAdapterProbe{
		Status:    "ready",
		Path:      "/opt/mimi/mimi-agy-adapter",
		Version:   "0.1.0",
		Healthy:   true,
		CheckedAt: time.Now().UTC(),
		Capabilities: &agybridge.AdapterCapabilities{
			Name:       "mimi-agy-adapter",
			Version:    "0.1.0",
			Methods:    []string{"initialize", "thread/list", "thread/start", "turn/start", "model/list", "slashCommand/list", "thread/name/set"},
			FullAccess: true,
		},
	})

	req := httptest.NewRequest("GET", "http://127.0.0.1:8787/api/app-server/config", nil)
	ch := router.agyChannelConfig(req)
	if ch.ID != "agy" || ch.Provider != "agy" || ch.Title != "Antigravity" || !ch.GatewayAvailable {
		t.Fatalf("unexpected agy channel metadata: %+v", ch)
	}
	if !ch.Capabilities.Rename {
		t.Fatalf("expected Rename capability on agy channel")
	}
	hasDangerFullAccess := false
	for _, mode := range ch.Policy.SandboxModes {
		if mode == "danger-full-access" {
			hasDangerFullAccess = true
		}
	}
	if !hasDangerFullAccess {
		t.Fatalf("expected danger-full-access in SandboxModes: %+v", ch.Policy.SandboxModes)
	}
}
