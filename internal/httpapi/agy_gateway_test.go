package httpapi

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/gaixianggeng/mimi-remote/internal/agybridge"
	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
	runtimebudget "github.com/gaixianggeng/mimi-remote/internal/runtimestatus"
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

	fakeAgyBin, err := os.Executable()
	if err != nil {
		t.Fatalf("resolve test executable: %v", err)
	}
	router := &Router{
		cfg: config.Config{
			Listen: "127.0.0.1:8787",
			Agy: config.AgyConfig{
				Enabled:               true,
				AdapterBin:            "mimi-agy-adapter",
				MaxConcurrentSessions: 3,
				Env: map[string]string{
					agybridge.AgyBinaryEnvKey: fakeAgyBin,
				},
			},
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

func TestB13Round2ImmediateConsistencyAcrossConfigStatusAndWSHandshakeAfterBinaryRemoval(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell script fixture requires POSIX")
	}
	dir := t.TempDir()
	adapterPath := filepath.Join(dir, "fake-agy-adapter")
	agyBin := filepath.Join(dir, "agy")
	adapterScript := `#!/bin/sh
if [ "$1" = "--version" ]; then
  echo "mimi-agy-adapter 0.1.0"
  exit 0
fi
if [ "$1" = "--capabilities" ]; then
  echo '{"name":"mimi-agy-adapter","version":"0.1.0","methods":["initialize","thread/list","thread/read","thread/start","turn/start"],"fullAccess":true,"agy":{"minimumVersion":"1.5.0"}}'
  exit 0
fi
exit 0
`
	agyScript := `#!/bin/sh
if [ "$1" = "--version" ]; then
  echo "1.5.14"
  exit 0
fi
if [ "$1" = "models" ]; then
  echo "gemini-4-carbon"
  exit 0
fi
exit 0
`
	if err := os.WriteFile(adapterPath, []byte(adapterScript), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(agyBin, []byte(agyScript), 0o755); err != nil {
		t.Fatal(err)
	}
	projectDir := filepath.Join(dir, "proj")
	if err := os.MkdirAll(projectDir, 0o755); err != nil {
		t.Fatal(err)
	}
	registry, err := projects.NewRegistry([]config.ProjectConfig{{ID: "proj", Name: "Proj", Path: projectDir}})
	if err != nil {
		t.Fatal(err)
	}
	cfg := config.Config{
		Auth: config.AuthConfig{Token: "0123456789abcdef0123456789abcdef"},
		Agy: config.AgyConfig{
			Enabled:    true,
			AdapterBin: adapterPath,
			Env: map[string]string{
				"PATH":                    dir,
				agybridge.AgyBinaryEnvKey: agyBin,
			},
		},
	}
	router := &Router{
		cfg:        cfg,
		projects:   registry,
		agyAdapter: newAgyAdapterSupervisor(),
		upgrader:   websocket.Upgrader{},
	}

	// Warm probe cache: agy is healthy and fresh (well inside 5s cache TTL).
	if p := router.refreshAgyAdapterProbe(); !p.Healthy || p.Status != "ready" {
		t.Fatalf("expected initial probe ready, got %+v", p)
	}

	srv := httptest.NewServer(http.HandlerFunc(router.appServerAgyGatewayWS))
	defer srv.Close()

	// Remove the agy binary and IMMEDIATELY (0ms wait!) check config, runtime status, and WS handshake.
	if err := os.Remove(agyBin); err != nil {
		t.Fatal(err)
	}

	// 1) /api/app-server/config must IMMEDIATELY report gateway_available=false and agy_missing.
	cfgReq := httptest.NewRequest("GET", srv.URL+"/api/app-server/config", nil)
	ch := router.agyChannelConfig(cfgReq)
	if ch.GatewayAvailable || ch.Bridge == nil || ch.Bridge.Status != "agy_missing" {
		t.Fatalf("config MUST immediately reflect agy_missing with 0ms wait, got %+v", ch)
	}

	// 2) runtime/status probe must IMMEDIATELY report agy_missing.
	rt := router.probeAgyRuntime(context.Background())
	if rt.State != runtimeStateUnavailable || rt.Reason != "agy_missing" {
		t.Fatalf("runtime/status MUST immediately report agy_missing, got %+v", rt)
	}

	// 3) New WS handshake must IMMEDIATELY reject with -32081 / AGY_ADAPTER_UNAVAILABLE / agy_missing.
	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http") + "/api/app-server/ws?runtime=agy"
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, map[string][]string{
		"Authorization": {"Bearer " + cfg.Auth.Token},
	})
	if err != nil {
		t.Fatalf("dial ws failed: %v", err)
	}
	defer conn.Close()
	_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	_, msg, err := conn.ReadMessage()
	if err != nil {
		t.Fatalf("expected immediate gateway error frame on WS, got err=%v", err)
	}
	var errFrame struct {
		Error struct {
			Code    int            `json:"code"`
			Message string         `json:"message"`
			Data    map[string]any `json:"data"`
		} `json:"error"`
	}
	if err := json.Unmarshal(msg, &errFrame); err != nil {
		t.Fatalf("unmarshal ws error frame: %v raw=%s", err, string(msg))
	}
	if errFrame.Error.Code != -32081 || errFrame.Error.Data["bridgeStatus"] != "agy_missing" {
		t.Fatalf("expected -32081 with bridgeStatus=agy_missing immediately on WS, got %s", string(msg))
	}
}

func TestC11Round2ExternalHolderRejectionDistinguishedFromReadOnlySubsession(t *testing.T) {
	projectDir := t.TempDir()
	registry, err := projects.NewRegistry([]config.ProjectConfig{
		{ID: "proj", Name: "Proj", Path: projectDir},
	})
	if err != nil {
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

	// 1) Initial idle list loads session as writable.
	policy.allowThread(appServerGatewayAllowedThread{
		id:                   "sess-c11",
		runtimeID:            appServerRuntimeAgyID,
		cwd:                  projectDir,
		scopeID:              "proj",
		canAcceptDirectInput: true,
		directInputKnown:     true,
		readOnly:             false,
	})

	// 2) Mac CLI enters busy -> thread/read returns canAcceptDirectInput=false (external holder, NOT readOnly subsession).
	reqID := json.RawMessage(`10`)
	if err := policy.rememberPendingThreadRequest(&reqID, appServerGatewayPendingThreadRequest{
		method:   "thread/read",
		threadID: "sess-c11",
	}); err != nil {
		t.Fatal(err)
	}
	busyRead, _ := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"id":      10,
		"result": map[string]any{
			"thread": map[string]any{
				"id":                   "sess-c11",
				"cwd":                  projectDir,
				"canAcceptDirectInput": false,
				"claudeOwner": map[string]any{
					"entrypoint": "desktop",
					"kind":       "desktop",
					"status":     "busy",
				},
			},
		},
	})
	var busyFrame appServerGatewayFrame
	_ = json.Unmarshal(busyRead, &busyFrame)
	if _, forward, policyErr := policy.finishUpstreamThreadResponse(busyRead, busyFrame); !forward || policyErr != nil {
		t.Fatalf("expected busy thread/read to succeed: forward=%v err=%+v", forward, policyErr)
	}

	// 3) turn/start & turn/interrupt must be rejected with external-holder message (NOT "只读子会话").
	startReq, _ := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"id":      11,
		"method":  "turn/start",
		"params": map[string]any{
			"threadId": "sess-c11",
			"cwd":      projectDir,
			"input":    []map[string]any{{"type": "text", "text": "hello"}},
		},
	})
	if _, policyErr := policy.validateClientFrame(websocket.TextMessage, startReq); policyErr == nil {
		t.Fatal("expected turn/start to be rejected while Mac holds session")
	} else {
		if strings.Contains(policyErr.message, "只读子会话") {
			t.Fatalf("external-holder rejection MUST NOT claim 只读子会话: %q", policyErr.message)
		}
		if !strings.Contains(policyErr.message, "电脑端其他进程") {
			t.Fatalf("expected external-holder guidance in error, got %q", policyErr.message)
		}
	}

	interruptReq, _ := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"id":      12,
		"method":  "turn/interrupt",
		"params": map[string]any{
			"threadId": "sess-c11",
		},
	})
	if _, policyErr := policy.validateClientFrame(websocket.TextMessage, interruptReq); policyErr == nil {
		t.Fatal("expected turn/interrupt to be rejected while Mac holds session")
	} else {
		if strings.Contains(policyErr.message, "只读子会话") {
			t.Fatalf("external-holder interrupt rejection MUST NOT claim 只读子会话: %q", policyErr.message)
		}
		if !strings.Contains(policyErr.message, "电脑端其他进程") {
			t.Fatalf("expected external-holder guidance in interrupt error, got %q", policyErr.message)
		}
	}

	// 4) Structural read-only subsession STILL reports "只读子会话".
	policy.allowThread(appServerGatewayAllowedThread{
		id:                   "subagent-c11",
		runtimeID:            appServerRuntimeAgyID,
		cwd:                  projectDir,
		scopeID:              "proj",
		canAcceptDirectInput: false,
		directInputKnown:     true,
		readOnly:             true,
	})
	subStart, _ := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"id":      13,
		"method":  "turn/start",
		"params": map[string]any{
			"threadId": "subagent-c11",
			"cwd":      projectDir,
			"input":    []map[string]any{{"type": "text", "text": "hello"}},
		},
	})
	if _, policyErr := policy.validateClientFrame(websocket.TextMessage, subStart); policyErr == nil || !strings.Contains(policyErr.message, "只读子会话") {
		t.Fatalf("structural read-only subsession should keep 只读子会话 wording, got %+v", policyErr)
	}

	// 5) Mac returns idle -> thread/read returns canAcceptDirectInput=true -> turn/start succeeds again!
	reqIDIdle := json.RawMessage(`14`)
	if err := policy.rememberPendingThreadRequest(&reqIDIdle, appServerGatewayPendingThreadRequest{
		method:   "thread/read",
		threadID: "sess-c11",
	}); err != nil {
		t.Fatal(err)
	}
	idleRead, _ := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"id":      14,
		"result": map[string]any{
			"thread": map[string]any{
				"id":                   "sess-c11",
				"cwd":                  projectDir,
				"canAcceptDirectInput": true,
			},
		},
	})
	var idleFrame appServerGatewayFrame
	_ = json.Unmarshal(idleRead, &idleFrame)
	if _, forward, policyErr := policy.finishUpstreamThreadResponse(idleRead, idleFrame); !forward || policyErr != nil {
		t.Fatalf("expected idle thread/read to succeed: forward=%v err=%+v", forward, policyErr)
	}
	startAfterIdle, _ := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"id":      15,
		"method":  "turn/start",
		"params": map[string]any{
			"threadId": "sess-c11",
			"cwd":      projectDir,
			"input":    []map[string]any{{"type": "text", "text": "after idle"}},
		},
	})
	if _, policyErr := policy.validateClientFrame(websocket.TextMessage, startAfterIdle); policyErr != nil {
		t.Fatalf("expected turn/start to succeed after Mac becomes idle, got %+v", policyErr)
	}
}

func TestB11Round2SlowOrUnknownAuthProbeDoesNotReportReadyAndPassesIsolatedAccountFlags(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell script fixture requires POSIX")
	}
	oldTimeout := agyAuthProbeTimeout
	agyAuthProbeTimeout = 150 * time.Millisecond
	t.Cleanup(func() { agyAuthProbeTimeout = oldTimeout })

	dir := t.TempDir()
	adapterPath := writeFakeAgyAdapterScript(t, dir)
	agyPath := filepath.Join(dir, "agy")
	argsLog := filepath.Join(dir, "models-args.txt")

	// 1) Slow/hanging probe must yield agy_auth_unknown (Healthy=false), NEVER ready!
	// Strict script mirrors real `agy 1.5.14`: only accepts global --gemini_dir / --app_data_dir BEFORE `models`.
	slowScript := `#!/bin/sh
if [ "$1" = "--version" ]; then echo "1.5.14"; exit 0; fi
echo "$@" > "` + argsLog + `"
while [ $# -gt 0 ]; do
  case "$1" in
    --gemini_dir|--app_data_dir) shift 2 ;;
    models)
      shift
      if [ $# -gt 0 ]; then echo "Usage: agy models [flags]" >&2; exit 2; fi
      /bin/sleep 2
      exit 0
      ;;
    *) echo "flags provided but not defined: $1" >&2; exit 2 ;;
  esac
done
exit 2
`
	if err := os.WriteFile(agyPath, []byte(slowScript), 0o755); err != nil {
		t.Fatal(err)
	}
	router := &Router{
		cfg: config.Config{
			Listen: "127.0.0.1:8787",
			Agy: config.AgyConfig{
				Enabled:    true,
				AdapterBin: adapterPath,
				Env: map[string]string{
					"PATH":                        dir,
					agybridge.AgyBinaryEnvKey:     agyPath,
					agybridge.AgyGeminiDirEnvKey:  ".gemini-isolated",
					agybridge.AgyAppDataDirEnvKey: "antigravity-custom",
				},
			},
		},
		agyAdapter: newAgyAdapterSupervisor(),
	}

	probe := router.refreshAgyAdapterProbe()
	if probe.Healthy || probe.Status != "agy_auth_unknown" {
		t.Fatalf("slow/unknown auth probe MUST NOT report ready; got %+v", probe)
	}
	ch := router.agyChannelConfig(httptest.NewRequest("GET", "http://127.0.0.1:8787/api/app-server/config", nil))
	if ch.GatewayAvailable || ch.Bridge == nil || ch.Bridge.Status != "agy_auth_unknown" {
		t.Fatalf("config MUST NOT report gateway_available=true when auth probe is unknown; got %+v", ch)
	}
	rt := router.probeAgyRuntime(context.Background())
	if rt.State != runtimeStateUnavailable || rt.Reason != "agy_auth_unknown" {
		t.Fatalf("runtime status should report unavailable/agy_auth_unknown, got %+v", rt)
	}

	// Verify isolated ACP account flags were forwarded in global underscore form BEFORE `models`.
	recordedArgsBytes, err := os.ReadFile(argsLog)
	if err != nil {
		t.Fatalf("expected agy models to record args: %v", err)
	}
	recordedArgs := strings.TrimSpace(string(recordedArgsBytes))
	wantArgs := "--gemini_dir .gemini-isolated --app_data_dir antigravity-custom models"
	if recordedArgs != wantArgs {
		t.Fatalf("expected %q, got %q", wantArgs, recordedArgs)
	}

	// 2) Once probe becomes fast & signed-in (still validating strict real-CLI flag order), short unknown cache TTL expires and probe recovers cleanly.
	fastSignedIn := `#!/bin/sh
if [ "$1" = "--version" ]; then echo "1.5.14"; exit 0; fi
while [ $# -gt 0 ]; do
  case "$1" in
    --gemini_dir|--app_data_dir) shift 2 ;;
    models)
      shift
      if [ $# -gt 0 ]; then echo "Usage: agy models [flags]" >&2; exit 2; fi
      echo "gemini-4-carbon"
      exit 0
      ;;
    *) echo "flags provided but not defined: $1" >&2; exit 2 ;;
  esac
done
exit 2
`
	if err := os.WriteFile(agyPath, []byte(fastSignedIn), 0o755); err != nil {
		t.Fatal(err)
	}
	router.agyMu.Lock()
	router.agyAuth.checkedAt = time.Now().UTC().Add(-agyAuthUnknownCacheTTL - time.Second)
	router.agyProbe.CheckedAt = time.Now().UTC().Add(-agyAuthUnknownCacheTTL - time.Second)
	router.agyMu.Unlock()

	recovered := router.currentAgyAdapterProbe()
	if !recovered.Healthy || recovered.Status != "ready" {
		t.Fatalf("expected recovery to ready after short unknown retry TTL, got %+v", recovered)
	}
}

func TestC14C15Round3PathRestorePreservesPermanentReadOnlyProvenanceAndRefreshesProjectAPI(t *testing.T) {
	parentDir := t.TempDir()
	projectDir := filepath.Join(parentDir, "registered-proj")
	browseRoot := filepath.Join(parentDir, "browse-root")
	browseSub := filepath.Join(browseRoot, "browse-missing")
	if err := os.MkdirAll(projectDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(browseSub, 0o755); err != nil {
		t.Fatal(err)
	}
	registry, err := projects.NewRegistry([]config.ProjectConfig{
		{ID: "reg-1", Name: "Registered", Path: projectDir},
	})
	if err != nil {
		t.Fatal(err)
	}
	router := &Router{
		cfg: config.Config{
			BrowseRoots: []string{browseRoot},
		},
		projects:       registry,
		gatewayThreads: map[string]appServerGatewayAllowedThread{},
	}
	policy := &appServerGatewayPolicy{
		router:         router,
		runtimeID:      appServerRuntimeAgyID,
		pendingThreads: map[string]appServerGatewayPendingThreadRequest{},
		allowedThreads: map[string]appServerGatewayAllowedThread{},
	}

	// Remove both directories while gateway is running.
	if err := os.RemoveAll(projectDir); err != nil {
		t.Fatal(err)
	}
	if err := os.RemoveAll(browseSub); err != nil {
		t.Fatal(err)
	}

	// 1) /api/projects dynamically reports missing=true before restart.
	rec1 := httptest.NewRecorder()
	router.projectsHandler(rec1, httptest.NewRequest("GET", "http://127.0.0.1:8787/api/projects", nil))
	var projectsBefore struct {
		Projects []projects.Project `json:"projects"`
	}
	if err := json.Unmarshal(rec1.Body.Bytes(), &projectsBefore); err != nil {
		t.Fatal(err)
	}
	if len(projectsBefore.Projects) != 1 || !projectsBefore.Projects[0].Missing {
		t.Fatalf("expected /api/projects to report missing=true when dir removed, got %+v", projectsBefore.Projects)
	}

	// 2) Global thread/list discovers:
	//    - subagent-missing (registered project + parentThreadId != "" + cwdMissing)
	//    - browse-missing (browse_roots + cwdMissing)
	//    - normal-missing (registered project + cwdMissing ONLY)
	listID := json.RawMessage(`100`)
	if err := policy.rememberPendingThreadRequest(&listID, appServerGatewayPendingThreadRequest{
		method:           "thread/list",
		globalDiscovery:  true,
		responseLimit:    25,
		responseLimitSet: true,
	}); err != nil {
		t.Fatal(err)
	}
	globalPayload, _ := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"id":      100,
		"result": map[string]any{
			"data": []map[string]any{
				{
					"id":                   "subagent-missing",
					"parentThreadId":       "parent-1",
					"cwd":                  projectDir,
					"canAcceptDirectInput": true,
				},
				{
					"id":                   "browse-missing",
					"cwd":                  browseSub,
					"canAcceptDirectInput": true,
				},
				{
					"id":                   "normal-missing",
					"cwd":                  projectDir,
					"canAcceptDirectInput": true,
				},
			},
			"nextCursor": nil,
		},
	})
	var listFrame appServerGatewayFrame
	_ = json.Unmarshal(globalPayload, &listFrame)
	if _, forward, policyErr := policy.finishUpstreamThreadResponse(globalPayload, listFrame); !forward || policyErr != nil {
		t.Fatalf("global list failed: forward=%v err=%+v", forward, policyErr)
	}

	// 3) Restore BOTH directories on disk without restarting gateway!
	if err := os.MkdirAll(projectDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(browseSub, 0o755); err != nil {
		t.Fatal(err)
	}

	// /api/projects MUST immediately clear missing=true without restart!
	rec2 := httptest.NewRecorder()
	router.projectsHandler(rec2, httptest.NewRequest("GET", "http://127.0.0.1:8787/api/projects", nil))
	var projectsAfter struct {
		Projects []projects.Project `json:"projects"`
	}
	if err := json.Unmarshal(rec2.Body.Bytes(), &projectsAfter); err != nil {
		t.Fatal(err)
	}
	if len(projectsAfter.Projects) != 1 || projectsAfter.Projects[0].Missing {
		t.Fatalf("expected /api/projects to clear missing after dir restore, got %+v", projectsAfter.Projects)
	}

	// 4) Run thread/read on all 3 threads after restore:
	//    - normal-missing: clears cwdMissing AND becomes writable!
	//    - subagent-missing: clears cwdMissing, MUST STAY readOnly (readOnlySubagent preserved)!
	//    - browse-missing: clears cwdMissing, MUST STAY readOnly (readOnlyBrowseScope preserved)!
	readThread := func(reqID int, threadID, cwd, parentID string) {
		rawID := json.RawMessage(fmt.Sprintf("%d", reqID))
		if err := policy.rememberPendingThreadRequest(&rawID, appServerGatewayPendingThreadRequest{
			method:   "thread/read",
			threadID: threadID,
		}); err != nil {
			t.Fatal(err)
		}
		threadObj := map[string]any{
			"id":                   threadID,
			"cwd":                  cwd,
			"canAcceptDirectInput": true,
		}
		if parentID != "" {
			threadObj["parentThreadId"] = parentID
		}
		payload, _ := json.Marshal(map[string]any{
			"jsonrpc": "2.0",
			"id":      reqID,
			"result":  map[string]any{"thread": threadObj},
		})
		var frame appServerGatewayFrame
		_ = json.Unmarshal(payload, &frame)
		if _, forward, policyErr := policy.finishUpstreamThreadResponse(payload, frame); !forward || policyErr != nil {
			t.Fatalf("thread/read %s failed: forward=%v err=%+v", threadID, forward, policyErr)
		}
	}

	readThread(101, "normal-missing", projectDir, "")
	readThread(102, "subagent-missing", projectDir, "") // Note: detail omits parentThreadId, provenance from global list must STILL hold!
	readThread(103, "browse-missing", browseSub, "")

	normalAllowed, _ := policy.allowedThread("normal-missing")
	if normalAllowed.cwdMissing || normalAllowed.readOnly || !normalAllowed.canAcceptDirectInput {
		t.Fatalf("normal-missing should recover writable after restore, got %+v", normalAllowed)
	}
	subAllowed, _ := policy.allowedThread("subagent-missing")
	if subAllowed.cwdMissing || !subAllowed.readOnly || !subAllowed.readOnlySubagent || subAllowed.canAcceptDirectInput {
		t.Fatalf("subagent-missing MUST preserve readOnlySubagent after path restore, got %+v", subAllowed)
	}
	browseAllowed, _ := policy.allowedThread("browse-missing")
	if browseAllowed.cwdMissing || !browseAllowed.readOnly || !browseAllowed.readOnlyBrowseScope || browseAllowed.canAcceptDirectInput {
		t.Fatalf("browse-missing MUST preserve readOnlyBrowseScope after path restore, got %+v", browseAllowed)
	}

	// 5) Also verify threadsFromResult checks ParentThreadID even when discovered directly via detail response!
	directSub := policy.threadsFromResult(
		json.RawMessage(`{"thread":{"id":"direct-sub","parentThreadId":"parent-2","cwd":`+strconv.Quote(projectDir)+`,"canAcceptDirectInput":true}}`),
		appServerGatewayPendingThreadRequest{method: "thread/read", threadID: "direct-sub"},
	)
	if len(directSub) != 1 || !directSub[0].readOnly || !directSub[0].readOnlySubagent || directSub[0].canAcceptDirectInput {
		t.Fatalf("threadsFromResult MUST mark parentThreadId thread as readOnlySubagent, got %+v", directSub)
	}
}

func TestB11Round4SlowColdAgyProbeStaysConsistentAcrossConfigAndRuntimeStatus(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell script fixture requires POSIX")
	}
	if agyRuntimeProbeTimeout < agyAuthProbeTimeout || runtimebudget.ProbeGenerationTimeout < agyAuthProbeTimeout {
		t.Fatalf(
			"agy runtime status budget (%s / %s) MUST cover cold auth probe timeout (%s)",
			agyRuntimeProbeTimeout,
			runtimebudget.ProbeGenerationTimeout,
			agyAuthProbeTimeout,
		)
	}

	dir := t.TempDir()
	residentBridge := writeTestBridge(t, `#!/bin/sh
IFS= read -r initialize
printf '{"id":1,"result":{"userAgent":"mimi-agy-adapter/0.1.0"}}\n'
IFS= read -r initialized
while IFS= read -r line; do :; done
`)
	adapterWrapper := filepath.Join(dir, "mimi-agy-adapter")
	wrapperScript := `#!/bin/sh
case "$1" in
  --version)
    echo "mimi-agy-adapter 0.1.0"
    exit 0
    ;;
  --capabilities)
    echo '{"name":"mimi-agy-adapter","version":"0.1.0","methods":["initialize","thread/list","thread/start","turn/start","model/list"],"fullAccess":true,"agy":{"minimumVersion":"1.5.0"}}'
    exit 0
    ;;
  *)
    exec "` + residentBridge + `" "$@"
    ;;
esac
`
	if err := os.WriteFile(adapterWrapper, []byte(wrapperScript), 0o755); err != nil {
		t.Fatal(err)
	}

	// Simulate real slow-but-healthy agy cold auth probe taking > 4s (past old claudeRuntimeProbeTimeout).
	agyPath := filepath.Join(dir, "agy")
	slowReadyAgy := `#!/bin/sh
if [ "$1" = "--version" ]; then echo "1.5.14"; exit 0; fi
/bin/sleep 4.2
echo "gemini-4-carbon"
exit 0
`
	if err := os.WriteFile(agyPath, []byte(slowReadyAgy), 0o755); err != nil {
		t.Fatal(err)
	}

	upstreamURL, _, _ := fakeAppServerUpstream(t, runtimeStatusCodexResponder(t))
	handler, _ := appServerGatewayRouterFixtureWithConfig(t, upstreamURL, func(cfg *config.Config) {
		cfg.Agy.Enabled = true
		cfg.Agy.AdapterBin = adapterWrapper
		cfg.Agy.MaxConcurrentSessions = 2
		cfg.Agy.Env = map[string]string{
			"PATH":                    dir,
			agybridge.AgyBinaryEnvKey: agyPath,
		}
	})

	// Concurrent cold /api/app-server/config and /api/runtime/status?refresh=wait MUST BOTH report available!
	statusCh := make(chan runtimeStatusResponse, 1)
	configCh := make(chan appServerChannel, 1)
	go func() {
		rec := httptest.NewRecorder()
		req := authedRequest(t, http.MethodGet, "/api/runtime/status?refresh=wait", nil)
		req.RemoteAddr = "127.0.0.1:44123"
		handler.ServeHTTP(rec, req)
		var resp runtimeStatusResponse
		if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
			t.Errorf("decode runtime status: %v body=%s", err, rec.Body.String())
		}
		statusCh <- resp
	}()
	go func() {
		rec := httptest.NewRecorder()
		req := authedRequest(t, http.MethodGet, "/api/app-server/config", nil)
		handler.ServeHTTP(rec, req)
		var cfgResp struct {
			Channels []appServerChannel `json:"channels"`
		}
		if err := json.Unmarshal(rec.Body.Bytes(), &cfgResp); err != nil {
			t.Errorf("decode app-server config: %v body=%s", err, rec.Body.String())
		}
		var found appServerChannel
		for _, ch := range cfgResp.Channels {
			if ch.ID == appServerRuntimeAgyID {
				found = ch
				break
			}
		}
		configCh <- found
	}()

	ch := <-configCh
	resp := <-statusCh
	if !ch.GatewayAvailable || ch.Bridge == nil || ch.Bridge.Status != "ready" {
		t.Fatalf("expected config ready after 4.2s cold auth probe, got %+v", ch)
	}
	var agyStatus *runtimeAccountStatus
	for i := range resp.Runtimes {
		if resp.Runtimes[i].ID == "agy" {
			agyStatus = &resp.Runtimes[i]
			break
		}
	}
	if agyStatus == nil {
		t.Fatalf("expected agy entry in runtime status response, got %+v", resp.Runtimes)
	}
	if agyStatus.State != runtimeStateAvailable || agyStatus.Reason != "" {
		t.Fatalf("expected runtime status agy=available (not adapter_unavailable) after 4.2s cold probe, got %+v", *agyStatus)
	}
}

func TestB23Round5SpecialAndPercentLiteralPathsPreserveScopeAndWritability(t *testing.T) {
	root := t.TempDir()
	specialDir := filepath.Join(root, "边界 空格 & '引号'")
	literalPercentDir := filepath.Join(root, "foo%20bar")
	outsideDir := filepath.Join(root, "outside")
	for _, dir := range []string{specialDir, literalPercentDir, outsideDir} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}

	registry, err := projects.NewRegistry([]config.ProjectConfig{
		{ID: "proj-special", Name: "Special", Path: specialDir},
		{ID: "proj-literal-pct", Name: "LiteralPercent", Path: literalPercentDir},
	})
	if err != nil {
		t.Fatal(err)
	}
	router := &Router{
		projects:       registry,
		gatewayThreads: map[string]appServerGatewayAllowedThread{},
	}

	// Existing Chinese/space/&/quote and literal %20 registered projects resolve cleanly as writable (missing=false).
	for _, tc := range []struct {
		name string
		dir  string
		id   string
	}{
		{name: "chinese_special", dir: specialDir, id: "proj-special"},
		{name: "literal_percent20", dir: literalPercentDir, id: "proj-literal-pct"},
	} {
		scope, ok := router.gatewayScopeForPath(tc.dir)
		if !ok || scope.missing || scope.id != tc.id {
			t.Fatalf("%s: expected writable registered project scope %q, got ok=%v scope=%+v", tc.name, tc.id, ok, scope)
		}
	}

	// Gateway scope validation MUST remain strict: encoded traversal or outside paths are rejected.
	if _, ok := router.gatewayScopeForPath(filepath.Join(specialDir, "%2E%2E", "outside")); ok {
		t.Fatalf("expected percent-encoded traversal path to be rejected by strict gateway scope")
	}
	if _, ok := router.gatewayReadOnlyScopeForHistoryPath(outsideDir); ok {
		t.Fatalf("expected outside directory to be rejected by history scope")
	}

	// Global thread/list with normalized real paths marks both sessions writable (cwdMissing=false, canAcceptDirectInput=true).
	policy := &appServerGatewayPolicy{
		router:         router,
		runtimeID:      appServerRuntimeAgyID,
		pendingThreads: map[string]appServerGatewayPendingThreadRequest{},
		allowedThreads: map[string]appServerGatewayAllowedThread{},
	}
	payload, err := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"id":      1,
		"result": map[string]any{
			"data": []map[string]any{
				{
					"id":                   "thr-special",
					"cwd":                  specialDir,
					"cwdMissing":           false,
					"canAcceptDirectInput": true,
				},
				{
					"id":                   "thr-literal-pct",
					"cwd":                  literalPercentDir,
					"cwdMissing":           false,
					"canAcceptDirectInput": true,
				},
			},
			"nextCursor": nil,
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	rewritten, allowed, err := policy.sanitizeGlobalThreadListResponse(payload, appServerGatewayPendingThreadRequest{
		method:          "thread/list",
		globalDiscovery: true,
	})
	if err != nil {
		t.Fatalf("sanitizeGlobalThreadListResponse failed: %v", err)
	}
	if len(allowed) != 2 {
		t.Fatalf("expected 2 allowed threads, got %d (%+v)", len(allowed), allowed)
	}
	for _, entry := range allowed {
		if entry.cwdMissing || entry.readOnly || !entry.canAcceptDirectInput {
			t.Fatalf("expected thread %s to be writable and non-missing, got %+v", entry.id, entry)
		}
	}
	var resp struct {
		Result struct {
			Data []struct {
				ID                   string `json:"id"`
				CWD                  string `json:"cwd"`
				CwdMissing           bool   `json:"cwdMissing"`
				CanAcceptDirectInput bool   `json:"canAcceptDirectInput"`
			} `json:"data"`
		} `json:"result"`
	}
	if err := json.Unmarshal(rewritten, &resp); err != nil {
		t.Fatal(err)
	}
	if len(resp.Result.Data) != 2 || resp.Result.Data[0].CwdMissing || !resp.Result.Data[0].CanAcceptDirectInput || resp.Result.Data[1].CWD != literalPercentDir {
		t.Fatalf("unexpected global list payload: %+v", resp.Result.Data)
	}
}
