package httpapi

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/agybridge"
	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
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

func TestB11AgyProbeMarksSignedOutUnavailableAndRecoversAfterLogin(t *testing.T) {
	dir := t.TempDir()
	adapterPath := writeFakeAgyAdapterScript(t, dir)
	agyPath := filepath.Join(dir, "agy")
	signedOutScript := `#!/bin/sh
if [ "$1" = "--version" ]; then echo "1.5.13"; exit 0; fi
if [ "$1" = "models" ]; then echo "Error: Please sign in to view available models." >&2; exit 1; fi
exit 0
`
	if err := os.WriteFile(agyPath, []byte(signedOutScript), 0o755); err != nil {
		t.Fatalf("write signed-out agy: %v", err)
	}

	router := &Router{
		cfg: config.Config{
			Listen: "127.0.0.1:8787",
			Agy: config.AgyConfig{
				Enabled:    true,
				AdapterBin: adapterPath,
				Env: map[string]string{
					"PATH":                    dir,
					agybridge.AgyBinaryEnvKey: agyPath,
				},
			},
		},
		agyAdapter: newAgyAdapterSupervisor(),
	}

	probe := router.refreshAgyAdapterProbe()
	if probe.Healthy || probe.Status != "agy_signed_out" || probe.Error == "" {
		t.Fatalf("expected agy_signed_out unhealthy probe, got %+v", probe)
	}

	req := httptest.NewRequest("GET", "http://127.0.0.1:8787/api/app-server/config", nil)
	ch := router.agyChannelConfig(req)
	if ch.GatewayAvailable || ch.Bridge == nil || ch.Bridge.Healthy || ch.Bridge.Status != "agy_signed_out" {
		t.Fatalf("expected channel gateway_available=false and agy_signed_out, got %+v", ch)
	}

	rt := router.probeAgyRuntime(context.Background())
	if rt.State != runtimeStateSignedOut || rt.Reason != "agy_signed_out" {
		t.Fatalf("expected runtime status signed_out/agy_signed_out, got %+v", rt)
	}

	// Simulate user signing in and cache expiring.
	signedInScript := `#!/bin/sh
if [ "$1" = "--version" ]; then echo "1.5.13"; exit 0; fi
if [ "$1" = "models" ]; then echo "gemini-4-carbon"; exit 0; fi
exit 0
`
	if err := os.WriteFile(agyPath, []byte(signedInScript), 0o755); err != nil {
		t.Fatalf("write signed-in agy: %v", err)
	}
	router.agyMu.Lock()
	router.agyAuth.checkedAt = time.Time{}
	router.agyMu.Unlock()

	recovered := router.refreshAgyAdapterProbe()
	if !recovered.Healthy || recovered.Status != "ready" {
		t.Fatalf("expected ready probe after signing in, got %+v", recovered)
	}
}

func TestB14AgyProbeExposesCLIVersionAndMinimumVersionWhenOutdated(t *testing.T) {
	dir := t.TempDir()
	adapterPath := writeFakeAgyAdapterScript(t, dir)
	agyPath := filepath.Join(dir, "agy")
	outdatedScript := `#!/bin/sh
if [ "$1" = "--version" ]; then echo "1.4.99"; exit 0; fi
exit 0
`
	if err := os.WriteFile(agyPath, []byte(outdatedScript), 0o755); err != nil {
		t.Fatalf("write outdated agy: %v", err)
	}

	router := &Router{
		cfg: config.Config{
			Listen: "127.0.0.1:8787",
			Agy: config.AgyConfig{
				Enabled:    true,
				AdapterBin: adapterPath,
				Env: map[string]string{
					"PATH":                    dir,
					agybridge.AgyBinaryEnvKey: agyPath,
				},
			},
		},
		agyAdapter: newAgyAdapterSupervisor(),
	}

	probe := router.refreshAgyAdapterProbe()
	if probe.Healthy || probe.Status != "agy_unsupported" || probe.CLIVersion != "1.4.99" || probe.MinimumCLIVersion != "1.5.0" {
		t.Fatalf("expected agy_unsupported with versions 1.4.99/1.5.0, got %+v", probe)
	}

	req := httptest.NewRequest("GET", "http://127.0.0.1:8787/api/app-server/config", nil)
	ch := router.agyChannelConfig(req)
	if ch.GatewayAvailable || ch.Bridge == nil || ch.Bridge.CLIVersion != "1.4.99" || ch.Bridge.MinimumCLIVersion != "1.5.0" {
		t.Fatalf("expected channel bridge to include cli_version=1.4.99 and minimum_cli_version=1.5.0, got %+v", ch.Bridge)
	}
}

func TestC14C15GlobalListAndReadPreserveMissingDirectorySessionsAsReadOnly(t *testing.T) {
	parentDir := t.TempDir()
	projectDir := filepath.Join(parentDir, "remove-fixture")
	if err := os.MkdirAll(projectDir, 0o755); err != nil {
		t.Fatalf("mkdir projectDir: %v", err)
	}
	registry, err := projects.NewRegistry([]config.ProjectConfig{
		{ID: "remove-fixture", Name: "Remove Fixture", Path: projectDir},
	})
	if err != nil {
		t.Fatalf("new project registry: %v", err)
	}
	// Remove the registered workspace directory after registration (C14/C15).
	if err := os.Remove(projectDir); err != nil {
		t.Fatalf("remove projectDir: %v", err)
	}

	router := &Router{
		projects:       registry,
		gatewayThreads: map[string]appServerGatewayAllowedThread{},
		cfg: config.Config{
			BrowseRoots: []string{parentDir},
		},
	}

	// Strict write-path scope check must still reject missing directory.
	if _, ok := router.gatewayScopeForPath(projectDir); ok {
		t.Fatalf("expected strict gatewayScopeForPath to reject missing directory")
	}
	// Read-only history scope helper must resolve it as missing=true.
	histScope, ok := router.gatewayReadOnlyScopeForHistoryPath(projectDir)
	if !ok || !histScope.missing || histScope.project.ID != "remove-fixture" {
		t.Fatalf("expected missing read-only history scope for remove-fixture, got ok=%v scope=%+v", ok, histScope)
	}

	policy := &appServerGatewayPolicy{
		router:         router,
		runtimeID:      appServerRuntimeAgyID,
		allowedThreads: map[string]appServerGatewayAllowedThread{},
	}
	upstreamPayload, err := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"id":      1,
		"result": map[string]any{
			"data": []map[string]any{
				{
					"id":                   "sess-removed",
					"cwd":                  projectDir,
					"name":                 "Removed Fixture Session",
					"canAcceptDirectInput": true,
				},
			},
			"nextCursor": nil,
		},
	})
	if err != nil {
		t.Fatalf("marshal upstream payload: %v", err)
	}
	rewritten, allowed, err := policy.sanitizeGlobalThreadListResponse(upstreamPayload, appServerGatewayPendingThreadRequest{
		method: "thread/list",
	})
	if err != nil {
		t.Fatalf("sanitizeGlobalThreadListResponse failed: %v", err)
	}
	if len(allowed) != 1 || !allowed[0].readOnly || !allowed[0].cwdMissing || allowed[0].canAcceptDirectInput {
		t.Fatalf("expected read-only cwdMissing allowed thread, got %+v", allowed)
	}

	var decoded struct {
		Result struct {
			Data []struct {
				ID                   string         `json:"id"`
				CanAcceptDirectInput bool           `json:"canAcceptDirectInput"`
				CwdMissing           bool           `json:"cwdMissing"`
				MimiRemote           map[string]any `json:"mimiRemote"`
			} `json:"data"`
		} `json:"result"`
	}
	if err := json.Unmarshal(rewritten, &decoded); err != nil {
		t.Fatalf("unmarshal rewritten global list: %v", err)
	}
	if len(decoded.Result.Data) != 1 || decoded.Result.Data[0].ID != "sess-removed" ||
		decoded.Result.Data[0].CanAcceptDirectInput || !decoded.Result.Data[0].CwdMissing ||
		decoded.Result.Data[0].MimiRemote["cwdMissing"] != true {
		t.Fatalf("unexpected rewritten missing-dir item: %s", string(rewritten))
	}

	// Register allowed thread and verify thread/read validation succeeds for the missing-dir history.
	policy.allowThread(allowed[0])
	readRaw, _ := json.Marshal(map[string]any{
		"thread": map[string]any{
			"id":  "sess-removed",
			"cwd": projectDir,
		},
	})
	if err := policy.validateReadOnlyThreadResponse(readRaw, appServerGatewayPendingThreadRequest{
		method:   "thread/read",
		threadID: "sess-removed",
	}); err != nil {
		t.Fatalf("expected validateReadOnlyThreadResponse to allow missing-dir history read, got %v", err)
	}
}

func TestC14C15Round2RejectsOutOfScopeSymlinkEscapeInMissingPathFallback(t *testing.T) {
	allowedRoot := t.TempDir()
	outsideRoot := t.TempDir()
	projectDir := filepath.Join(allowedRoot, "project")
	if err := os.MkdirAll(projectDir, 0o755); err != nil {
		t.Fatal(err)
	}
	registry, err := projects.NewRegistry([]config.ProjectConfig{
		{ID: "proj", Name: "Proj", Path: projectDir},
	})
	if err != nil {
		t.Fatal(err)
	}
	router := &Router{
		projects:       registry,
		gatewayThreads: map[string]appServerGatewayAllowedThread{},
		cfg: config.Config{
			BrowseRoots: []string{allowedRoot},
		},
	}

	// 1) Leaf symlink inside project pointing to an existing directory outside allowed scope.
	escapeLink := filepath.Join(projectDir, "escape-link")
	if err := os.Symlink(outsideRoot, escapeLink); err != nil {
		t.Fatal(err)
	}
	if scope, ok := router.gatewayReadOnlyScopeForHistoryPath(escapeLink); ok {
		t.Fatalf("out-of-scope leaf symlink MUST NOT be accepted via missing-path fallback: scope=%+v", scope)
	}

	// 2) Non-existent child underneath an out-of-scope symlink.
	escapeChild := filepath.Join(escapeLink, "missing-child")
	if scope, ok := router.gatewayReadOnlyScopeForHistoryPath(escapeChild); ok {
		t.Fatalf("missing child under out-of-scope symlink MUST NOT be accepted: scope=%+v", scope)
	}

	// 3) Dangling symlink inside project pointing outside scope.
	danglingLink := filepath.Join(projectDir, "dangling-link")
	if err := os.Symlink(filepath.Join(outsideRoot, "nonexistent"), danglingLink); err != nil {
		t.Fatal(err)
	}
	if scope, ok := router.gatewayReadOnlyScopeForHistoryPath(danglingLink); ok {
		t.Fatalf("dangling symlink MUST NOT be accepted as missing dir: scope=%+v", scope)
	}
	if scope, ok := router.gatewayReadOnlyScopeForHistoryPath(filepath.Join(danglingLink, "sub")); ok {
		t.Fatalf("child under dangling symlink MUST NOT be accepted: scope=%+v", scope)
	}
}

func TestC15Round2GlobalListDiscoversDeletedBrowseOnlyDirectoryAsReadOnly(t *testing.T) {
	browseRoot := t.TempDir()
	otherProject := filepath.Join(t.TempDir(), "other-proj")
	if err := os.MkdirAll(otherProject, 0o755); err != nil {
		t.Fatal(err)
	}
	browseOnlyDir := filepath.Join(browseRoot, "ephemeral-browse-dir")
	if err := os.MkdirAll(browseOnlyDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(browseOnlyDir); err != nil {
		t.Fatal(err)
	}

	registry, err := projects.NewRegistry([]config.ProjectConfig{
		{ID: "other", Name: "Other", Path: otherProject},
	})
	if err != nil {
		t.Fatal(err)
	}
	router := &Router{
		projects:       registry,
		gatewayThreads: map[string]appServerGatewayAllowedThread{},
		cfg: config.Config{
			BrowseRoots: []string{browseRoot},
		},
	}
	policy := &appServerGatewayPolicy{
		router:         router,
		runtimeID:      appServerRuntimeAgyID,
		allowedThreads: map[string]appServerGatewayAllowedThread{},
	}

	upstreamPayload, _ := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"id":      1,
		"result": map[string]any{
			"data": []map[string]any{
				{
					"id":                   "sess-browse-deleted",
					"cwd":                  browseOnlyDir,
					"name":                 "Browse Only Deleted Session",
					"canAcceptDirectInput": true,
				},
			},
			"nextCursor": nil,
		},
	})
	rewritten, allowed, err := policy.sanitizeGlobalThreadListResponse(upstreamPayload, appServerGatewayPendingThreadRequest{
		method: "thread/list",
	})
	if err != nil {
		t.Fatalf("sanitizeGlobalThreadListResponse failed: %v", err)
	}
	if len(allowed) != 1 || !allowed[0].readOnly || !allowed[0].cwdMissing || allowed[0].canAcceptDirectInput {
		t.Fatalf("deleted browse-only dir must be preserved in global list as readOnly+cwdMissing, got %+v", allowed)
	}
	if !strings.Contains(string(rewritten), `"cwdMissing":true`) {
		t.Fatalf("expected cwdMissing=true in rewritten global list: %s", string(rewritten))
	}
	policy.allowThread(allowed[0])

	readRaw, _ := json.Marshal(map[string]any{
		"thread": map[string]any{
			"id":  "sess-browse-deleted",
			"cwd": browseOnlyDir,
		},
	})
	if err := policy.validateReadOnlyThreadResponse(readRaw, appServerGatewayPendingThreadRequest{
		method:   "thread/read",
		threadID: "sess-browse-deleted",
	}); err != nil {
		t.Fatalf("expected cold thread/read to succeed for deleted browse-only dir, got %v", err)
	}
}

func TestC14Round2RestoredDirectoryRefreshesListAndDetailPermissionsOnSameConnection(t *testing.T) {
	parentDir := t.TempDir()
	projectDir := filepath.Join(parentDir, "move-fixture")
	if err := os.MkdirAll(projectDir, 0o755); err != nil {
		t.Fatal(err)
	}
	registry, err := projects.NewRegistry([]config.ProjectConfig{
		{ID: "move-fixture", Name: "Move Fixture", Path: projectDir},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(projectDir); err != nil {
		t.Fatal(err)
	}

	router := &Router{
		projects:       registry,
		gatewayThreads: map[string]appServerGatewayAllowedThread{},
	}
	policy := &appServerGatewayPolicy{
		router:         router,
		runtimeID:      appServerRuntimeAgyID,
		pendingThreads: map[string]appServerGatewayPendingThreadRequest{},
		allowedThreads: map[string]appServerGatewayAllowedThread{},
	}

	// Step 1: While directory is missing, global list caches the thread as readOnly + cwdMissing.
	listPayload, _ := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"id":      1,
		"result": map[string]any{
			"data": []map[string]any{
				{"id": "sess-move", "cwd": projectDir, "canAcceptDirectInput": true},
			},
			"nextCursor": nil,
		},
	})
	_, missingAllowed, err := policy.sanitizeGlobalThreadListResponse(listPayload, appServerGatewayPendingThreadRequest{method: "thread/list"})
	if err != nil || len(missingAllowed) != 1 || !missingAllowed[0].cwdMissing || !missingAllowed[0].readOnly {
		t.Fatalf("expected missing-dir thread cached as readOnly+cwdMissing, got %+v err=%v", missingAllowed, err)
	}
	policy.allowThread(missingAllowed[0])

	// Step 2: Restore directory on disk!
	if err := os.MkdirAll(projectDir, 0o755); err != nil {
		t.Fatal(err)
	}

	// Step 3: On the SAME connection, thread/read must clear stale cwdMissing/readOnly cache and return writable!
	reqID := json.RawMessage(`2`)
	if err := policy.rememberPendingThreadRequest(&reqID, appServerGatewayPendingThreadRequest{
		method:   "thread/read",
		threadID: "sess-move",
	}); err != nil {
		t.Fatal(err)
	}
	readPayload, _ := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"id":      2,
		"result": map[string]any{
			"thread": map[string]any{
				"id":                   "sess-move",
				"cwd":                  projectDir,
				"canAcceptDirectInput": true,
				"cwdMissing":           false,
			},
		},
	})
	var readFrame appServerGatewayFrame
	if err := json.Unmarshal(readPayload, &readFrame); err != nil {
		t.Fatal(err)
	}
	outPayload, forward, policyErr := policy.finishUpstreamThreadResponse(readPayload, readFrame)
	if policyErr != nil || !forward {
		t.Fatalf("expected restored thread/read to succeed, forward=%v err=%+v", forward, policyErr)
	}
	var readDecoded struct {
		Result struct {
			Thread struct {
				CanAcceptDirectInput bool `json:"canAcceptDirectInput"`
				CwdMissing           bool `json:"cwdMissing"`
			} `json:"thread"`
		} `json:"result"`
	}
	if err := json.Unmarshal(outPayload, &readDecoded); err != nil {
		t.Fatal(err)
	}
	if !readDecoded.Result.Thread.CanAcceptDirectInput || readDecoded.Result.Thread.CwdMissing {
		t.Fatalf("restored directory detail MUST be writable (not stuck read-only): %s", string(outPayload))
	}
	refreshed, ok := policy.allowedThread("sess-move")
	if !ok || refreshed.readOnly || refreshed.cwdMissing || !refreshed.canAcceptDirectInput {
		t.Fatalf("expected allowedThread cache to refresh after path restore, got %+v", refreshed)
	}
}
