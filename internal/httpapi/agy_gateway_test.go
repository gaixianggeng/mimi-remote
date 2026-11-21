package httpapi

import (
	"context"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
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

func writeFakeAgyAdapterScript(t *testing.T, dir string) string {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("shell script fixture requires unix")
	}
	scriptPath := filepath.Join(dir, "mimi-agy-adapter")
	script := `#!/bin/sh
case "$1" in
  --version)
    echo "mimi-agy-adapter 0.1.0"
    ;;
  --capabilities)
    echo '{"name":"mimi-agy-adapter","version":"0.1.0","methods":["initialize","thread/list","thread/start","turn/start","model/list"],"fullAccess":true,"agy":{"minimumVersion":"1.5.0"}}'
    ;;
  *)
    exit 1
    ;;
esac
`
	if err := os.WriteFile(scriptPath, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake adapter: %v", err)
	}
	return scriptPath
}

func TestB13AgyProbeRevokesGatewayAvailabilityWhenCLIMissing(t *testing.T) {
	dir := t.TempDir()
	adapterPath := writeFakeAgyAdapterScript(t, dir)
	missingAgy := filepath.Join(dir, "deleted-agy")

	router := &Router{
		cfg: config.Config{
			Listen: "127.0.0.1:8787",
			Agy: config.AgyConfig{
				Enabled:    true,
				AdapterBin: adapterPath,
				Env: map[string]string{
					"PATH":                    dir,
					agybridge.AgyBinaryEnvKey: missingAgy,
				},
			},
		},
		agyAdapter: newAgyAdapterSupervisor(),
	}

	probe := router.refreshAgyAdapterProbe()
	if probe.Healthy || probe.Status != "agy_missing" || probe.Error == "" {
		t.Fatalf("expected agy_missing unhealthy probe, got %+v", probe)
	}

	req := httptest.NewRequest("GET", "http://127.0.0.1:8787/api/app-server/config", nil)
	ch := router.agyChannelConfig(req)
	if ch.GatewayAvailable || ch.Bridge == nil || ch.Bridge.Healthy || ch.Bridge.Status != "agy_missing" {
		t.Fatalf("expected channel gateway_available=false and bridge.status=agy_missing, got %+v", ch)
	}

	runtimeStatus := router.probeAgyRuntime(context.Background())
	if runtimeStatus.State != runtimeStateUnavailable || runtimeStatus.Reason != "agy_missing" {
		t.Fatalf("expected runtime status unavailable/agy_missing, got %+v", runtimeStatus)
	}

	// Restoring the agy binary recovers channel availability on next probe.
	fakeAgy := "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo \"1.5.13\"; exit 0; fi\nexit 0\n"
	if err := os.WriteFile(missingAgy, []byte(fakeAgy), 0o755); err != nil {
		t.Fatalf("write fake agy: %v", err)
	}
	recovered := router.refreshAgyAdapterProbe()
	if !recovered.Healthy || recovered.Status != "ready" {
		t.Fatalf("expected ready probe after restoring agy binary, got %+v", recovered)
	}
}
