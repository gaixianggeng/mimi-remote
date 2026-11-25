package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"
	"unicode"
)

const trayContractDir = "../../contracts/host-cli"

func loadTrayContractFile(t *testing.T, name string) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(trayContractDir, name))
	if err != nil {
		t.Fatalf("read contract %s: %v", name, err)
	}
	return data
}

func TestTrayOnboardingCatalogSetEquality(t *testing.T) {
	var manifest struct {
		Schema string `json:"schema"`
		Checks []struct {
			ID        string   `json:"id"`
			Group     string   `json:"group"`
			Platforms []string `json:"platforms"`
		} `json:"checks"`
		URLs            map[string]string `json:"urls"`
		SettingsTargets []string          `json:"settings_targets"`
		PathTargets     []string          `json:"path_targets"`
		RunFix          map[string]struct {
			RequiresConfig     bool   `json:"requires_config"`
			RequiresCapability string `json:"requires_capability"`
		} `json:"run_fix"`
		Timeouts []struct {
			Commands      []string `json:"commands"`
			BackendMax    int      `json:"backend_max"`
			ClientMin     int      `json:"client_min"`
			WindowsClient int      `json:"windows_client"`
		} `json:"timeouts_seconds"`
		WireCodes []struct {
			Code string `json:"code"`
		} `json:"wire_codes"`
		UILocalCodes []struct {
			Code string `json:"code"`
		} `json:"ui_local_codes"`
	}
	if err := json.Unmarshal(loadTrayContractFile(t, "onboarding-codes-v1.json"), &manifest); err != nil {
		t.Fatal(err)
	}
	if manifest.Schema != onboardingCodesSchemaV1 {
		t.Fatalf("schema = %q", manifest.Schema)
	}
	if len(manifest.Checks) == 0 || len(manifest.WireCodes) == 0 || len(manifest.UILocalCodes) == 0 {
		t.Fatalf("loaded manifest counts must be > 0")
	}

	// Checks exact order, groups, and platforms.
	if len(onboardingChecksCatalog) != len(manifest.Checks) {
		t.Fatalf("checks count = %d, want %d", len(onboardingChecksCatalog), len(manifest.Checks))
	}
	for i, want := range manifest.Checks {
		got := onboardingChecksCatalog[i]
		if got.ID != want.ID || got.Group != want.Group || !slices.Equal(got.Platforms, want.Platforms) {
			t.Errorf("check[%d] mismatch: got %+v want %+v", i, got, want)
		}
	}

	// Exact set equality for wire codes (77) and UI-local codes (2).
	var wantWire, gotWire, wantLocal, gotLocal []string
	for _, w := range manifest.WireCodes {
		wantWire = append(wantWire, w.Code)
	}
	for _, l := range manifest.UILocalCodes {
		wantLocal = append(wantLocal, l.Code)
	}
	for _, entry := range onboardingCodeCatalog {
		if !strings.ContainsFunc(entry.MessageZH, func(r rune) bool { return unicode.Is(unicode.Han, r) }) {
			t.Errorf("code %s missing Chinese copy", entry.Code)
		}
		if entry.UILocal {
			gotLocal = append(gotLocal, entry.Code)
		} else {
			gotWire = append(gotWire, entry.Code)
		}
	}
	slices.Sort(wantWire)
	slices.Sort(gotWire)
	slices.Sort(wantLocal)
	slices.Sort(gotLocal)
	if !slices.Equal(gotWire, wantWire) {
		t.Fatalf("wire code set mismatch: got %d want %d", len(gotWire), len(wantWire))
	}
	if !slices.Equal(gotLocal, wantLocal) {
		t.Fatalf("ui_local code set mismatch: got %v want %v", gotLocal, wantLocal)
	}

	// URLs, settings targets, path targets, run_fix metadata.
	if len(onboardingURLAllowlist) != len(manifest.URLs) {
		t.Fatalf("url allowlist size mismatch")
	}
	for k, want := range manifest.URLs {
		if onboardingURLAllowlist[k] != want {
			t.Errorf("url %s = %q, want %q", k, onboardingURLAllowlist[k], want)
		}
	}
	if !slices.Equal(onboardingSettingsTargets, manifest.SettingsTargets) {
		t.Errorf("settings targets mismatch")
	}
	if !slices.Equal(onboardingPathTargets, manifest.PathTargets) {
		t.Errorf("path targets mismatch")
	}
	if len(onboardingRunFixSpecs) != len(manifest.RunFix) {
		t.Fatalf("run_fix count mismatch")
	}
	for action, want := range manifest.RunFix {
		got, ok := onboardingRunFixSpecs[action]
		if !ok || got.RequiresConfig != want.RequiresConfig || got.RequiresCapability != want.RequiresCapability {
			t.Errorf("run_fix %s mismatch: got %+v want %+v", action, got, want)
		}
	}

	// Timeouts alignment.
	if len(onboardingCommandTimeouts) != len(manifest.Timeouts) {
		t.Fatalf("timeouts count mismatch")
	}
	for i, want := range manifest.Timeouts {
		got := onboardingCommandTimeouts[i]
		if !slices.Equal(got.Commands, want.Commands) ||
			got.ClientMin < time.Duration(want.ClientMin)*time.Second ||
			got.BackendMax != time.Duration(want.BackendMax)*time.Second {
			t.Errorf("timeout[%d] mismatch: got %+v want %+v", i, got, want)
		}
	}
}

type trayReportPatch struct {
	Op    string `json:"op"`
	Path  string `json:"path"`
	Value any    `json:"value"`
}

func applyTrayReportPatch(t *testing.T, fixture string, patches []trayReportPatch) []byte {
	t.Helper()
	var doc map[string]any
	if err := json.Unmarshal(loadTrayContractFile(t, fixture), &doc); err != nil {
		t.Fatal(err)
	}
	for _, p := range patches {
		key := strings.TrimPrefix(p.Path, "/")
		if strings.HasPrefix(key, "checks/") {
			items := doc["checks"].([]any)
			idxStr := strings.TrimPrefix(key, "checks/")
			if p.Op == "add" && idxStr == "-" {
				doc["checks"] = append(items, p.Value)
			} else if p.Op == "remove" {
				idx, err := strconv.Atoi(idxStr)
				if err != nil {
					t.Fatal(err)
				}
				doc["checks"] = slices.Delete(items, idx, idx+1)
			} else {
				t.Fatalf("unsupported checks patch %+v", p)
			}
			continue
		}
		switch p.Op {
		case "add", "replace":
			doc[key] = p.Value
		case "remove":
			delete(doc, key)
		default:
			t.Fatalf("unsupported op %s", p.Op)
		}
	}
	raw, err := json.Marshal(doc)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func TestTrayOnboardingErrorCasesContract(t *testing.T) {
	var cases []struct {
		ID      string            `json:"id"`
		Valid   bool              `json:"valid"`
		Context map[string]any    `json:"context"`
		Payload json.RawMessage   `json:"payload"`
		Fixture string            `json:"fixture"`
		Patch   []trayReportPatch `json:"patch"`
	}
	if err := json.Unmarshal(loadTrayContractFile(t, "onboarding-error-cases.json"), &cases); err != nil {
		t.Fatal(err)
	}
	if len(cases) == 0 {
		t.Fatal("expected nonzero error cases")
	}

	parseContext := func(raw map[string]any) onboardingValidationContext {
		ctx := onboardingValidationContext{}
		if v, ok := raw["surface"].(string); ok {
			ctx.Surface = v
		}
		if v, ok := raw["platform"].(string); ok {
			ctx.Platform = v
		}
		if v, ok := raw["stage"].(string); ok {
			ctx.Stage = v
		}
		if v, ok := raw["configured"].(bool); ok {
			val := v
			ctx.Configured = &val
		}
		if v, present := raw["recommended_transport"]; present {
			ctx.HasRecommendedTransport = true
			if s, ok := v.(string); ok {
				ctx.RecommendedTransport = s
			}
		}
		if v, ok := raw["verified_capability"].(string); ok {
			ctx.VerifiedCapability = v
		}
		if v, ok := raw["explicitly_enabled"].(bool); ok {
			val := v
			ctx.ExplicitlyEnabled = &val
		}
		return ctx
	}

	executed := 0
	for _, tc := range cases {
		executed++
		t.Run(tc.ID, func(t *testing.T) {
			ctx := parseContext(tc.Context)
			var err error
			var resolved onboardingResolvedDiagnostic
			switch ctx.Surface {
			case "report":
				raw := applyTrayReportPatch(t, tc.Fixture, tc.Patch)
				_, err = decodeAndValidatePreflightReport(raw, ctx.Platform, false, ctx.VerifiedCapability)
			case "check", "native":
				var row onboardingCheck
				row, err = decodeOnboardingCheck(tc.Payload)
				if err == nil {
					resolved, err = validateOnboardingCheck(row, ctx)
				}
			case "cli", "http", "ui_local":
				resolved, err = decodeOnboardingErrorEnvelope(tc.Payload, ctx)
			default:
				t.Fatalf("unexpected surface %q", ctx.Surface)
			}
			if (err == nil) != tc.Valid {
				t.Fatalf("case %s: valid=%v, got err=%v", tc.ID, tc.Valid, err)
			}
			if !tc.Valid && resolved.AllowedFix != nil {
				t.Fatalf("case %s: invalid diagnostic must yield zero execution (AllowedFix=nil), got %+v", tc.ID, resolved.AllowedFix)
			}
			if tc.Valid && ctx.Surface != "report" && !resolved.Trusted {
				t.Fatalf("case %s: valid diagnostic must be trusted", tc.ID)
			}
		})
	}
	if executed != len(cases) {
		t.Fatalf("executed %d != %d", executed, len(cases))
	}
}

func TestTrayOnboardingFixturesAndReceipts(t *testing.T) {
	reports := []struct {
		file          string
		platform      string
		nativeOverlay bool
	}{
		{"preflight-all-green.json", "macos", false},
		{"preflight-claude-only-no-network.json", "linux", false},
		{"preflight-codex-chatgpt-app.json", "macos", false},
		{"preflight-permission-needed.json", "macos", true},
		{"preflight-deepseek-only.json", "linux", false},
		{"preflight-windows-public.json", "windows", false},
	}
	for _, r := range reports {
		report, err := decodeAndValidatePreflightReport(loadTrayContractFile(t, r.file), r.platform, r.nativeOverlay, "")
		if err != nil {
			t.Fatalf("%s: %v", r.file, err)
		}
		if r.file == "preflight-codex-chatgpt-app.json" {
			// Verify enabled-but-signed-out other assistant (Claude) alongside ready Codex and disabled-but-available agy.
			byID := map[string]onboardingCheck{}
			for _, c := range report.Checks {
				byID[c.ID] = c
			}
			if byID["assistant_codex"].State != "ok" || byID["assistant_claude"].Code != "claude_signed_out" || byID["assistant_claude"].State != "action_needed" {
				t.Fatalf("unexpected codex/claude state: %+v / %+v", byID["assistant_codex"], byID["assistant_claude"])
			}
			if byID["assistant_agy"].Code != "assistant_disabled" || byID["assistant_agy"].State != "optional" {
				t.Fatalf("unexpected agy state: %+v", byID["assistant_agy"])
			}
		}
	}

	// No-QR setup success fixtures.
	noAssist, err := decodeOnboardingSetupReceipt(loadTrayContractFile(t, "setup-ok-no-assistant.json"))
	if err != nil || noAssist.PairURL != "" || !*noAssist.Configured || !*noAssist.Created {
		t.Fatalf("setup-ok-no-assistant failed: %+v err=%v", noAssist, err)
	}
	deferred, err := decodeOnboardingSetupReceipt(loadTrayContractFile(t, "setup-ok-pairing-deferred.json"))
	if err != nil || deferred.PairURL != "" || deferred.PairingDeferred == nil || !*deferred.PairingDeferred {
		t.Fatalf("setup-ok-pairing-deferred failed: %+v err=%v", deferred, err)
	}

	// Legacy ticket setup compatibility.
	legacySetup, err := decodeOnboardingSetupReceipt([]byte(`{"endpoint":"http://127.0.0.1:8787","pair_url":"mimiremote://pair?pair_sig=legacy","pair_expires_at":"2030-01-01T00:05:00Z"}`))
	if err != nil || !legacySetup.Legacy || legacySetup.PairURL == "" {
		t.Fatalf("legacy setup decode failed: %+v err=%v", legacySetup, err)
	}

	// Up readiness vs submitted.
	ready, err := decodeOnboardingUpReadinessReceipt(loadTrayContractFile(t, "up-ok-ready.json"))
	if err != nil || ready.Version != "1.0.0" {
		t.Fatalf("up-ok-ready failed: %+v err=%v", ready, err)
	}
	if _, err := decodeOnboardingUpReadinessReceipt([]byte(`{"ok":true,"start_submitted":true}`)); err == nil {
		t.Fatal("start_submitted must not decode as authenticated readiness")
	}

	// Pairing tickets.
	for _, f := range []string{"pair-ok-direct.json", "pair-ok-tailcat.json"} {
		ticket, err := decodeOnboardingPairingTicketReceipt(loadTrayContractFile(t, f), true)
		if err != nil || ticket.PairURL == "" || ticket.Network == "" {
			t.Fatalf("%s failed: %+v err=%v", f, ticket, err)
		}
	}

	// Standalone error fixtures.
	configured := true
	for _, item := range []struct {
		file, surface, stage, code string
	}{
		{"setup-error-config-invalid.json", "cli", "setup", "config_invalid"},
		{"setup-error-config-concurrent-change.json", "cli", "setup", "config_concurrent_change"},
		{"up-error-service-start-timeout.json", "cli", "pair", "service_start_timeout"},
		{"pair-error-no-enabled-assistant.json", "cli", "pair", "no_enabled_assistant"},
		{"pair-error-expired.json", "http", "pair", "pair_ticket_expired"},
	} {
		resolved, err := decodeOnboardingErrorEnvelope(loadTrayContractFile(t, item.file), onboardingValidationContext{
			Surface: item.surface, Platform: "macos", Stage: item.stage, Configured: &configured,
		})
		if err != nil || resolved.Code != item.code || !resolved.Trusted || resolved.AllowedFix == nil {
			t.Fatalf("%s: resolved=%+v err=%v", item.file, resolved, err)
		}
	}
}

func TestTrayProgressOutOfOrderAndCancelDoesNotOverwriteTerminal(t *testing.T) {
	ndjson := loadTrayContractFile(t, "preflight-progress-slow-assistant.ndjson")
	lines := bytes.Split(bytes.TrimSpace(ndjson), []byte("\n"))
	if len(lines) != 36 {
		t.Fatalf("expected 36 progress lines, got %d", len(lines))
	}

	acc := newOnboardingProgressAccumulator(1)
	// Inject malformed noise lines alongside real progress lines.
	if acc.ApplyLine(1, []byte("non-json child warning stderr")) {
		t.Fatal("malformed stderr noise should be ignored")
	}
	// Apply initial 18 checking skeleton + fast completions (lines 0..25), before slow assistant_claude finishes (line 35).
	for i := 0; i < 26; i++ {
		if !acc.ApplyLine(1, lines[i]) {
			t.Fatalf("expected progress line %d to apply", i+1)
		}
	}
	rows, finalRep := acc.Snapshot()
	if finalRep != nil || len(rows) != 18 {
		t.Fatalf("expected 18 in-flight rows before completion, got %d", len(rows))
	}
	byID := map[string]onboardingCheck{}
	for _, r := range rows {
		byID[r.ID] = r
	}
	if byID["assistant_codex"].State != "ok" || byID["assistant_any"].State != "ok" || byID["assistant_claude"].State != "checking" {
		t.Fatalf("fast assistant and aggregate must complete while slow assistant is still checking: codex=%s any=%s claude=%s",
			byID["assistant_codex"].State, byID["assistant_any"].State, byID["assistant_claude"].State)
	}

	// Finish stream and apply authoritative stdout report.
	for i := 26; i < len(lines); i++ {
		acc.ApplyLine(1, lines[i])
	}
	report, err := decodeAndValidatePreflightReport(loadTrayContractFile(t, "preflight-codex-chatgpt-app.json"), "macos", false, "")
	if err != nil {
		t.Fatal(err)
	}
	if !acc.Complete(1, report) {
		t.Fatal("expected final report completion")
	}

	// Late cancel or late progress line MUST NOT overwrite terminal state.
	acc.Cancel(1)
	if acc.ApplyLine(1, lines[0]) {
		t.Fatal("late progress after terminal state must be rejected")
	}
	_, finalAfter := acc.Snapshot()
	if finalAfter == nil || !*finalAfter.OK {
		t.Fatalf("terminal report was overwritten: %+v", finalAfter)
	}

	// Also verify cancelling before completion rejects late lines & late completion.
	acc2 := newOnboardingProgressAccumulator(2)
	acc2.ApplyLine(2, lines[0])
	acc2.Cancel(2)
	if acc2.ApplyLine(2, lines[18]) || acc2.Complete(2, report) {
		t.Fatal("cancelled generation must reject late updates and completion")
	}
}

func TestTrayDecodeCommandErrorStdoutFirstAndZeroExecutionOnUntrusted(t *testing.T) {
	ctx := trayValidationContextForArgs("windows", []string{"setup", "--no-pair", "--json"})
	stdout := loadTrayContractFile(t, "setup-error-config-invalid.json")
	err := decodeTrayCommandError(stdout, []byte("raw stderr noise"), errors.New("exit status 1"), ctx)
	var cliErr *onboardingCLIError
	if !errors.As(err, &cliErr) || !cliErr.Diagnostic.Trusted || cliErr.Diagnostic.Code != "config_invalid" {
		t.Fatalf("expected trusted CLI error from stdout, got %v", err)
	}
	if cliErr.Diagnostic.AllowedFix == nil || cliErr.Diagnostic.AllowedFix.Target != "host_recovery" {
		t.Fatalf("expected host_recovery fix, got %+v", cliErr.Diagnostic.AllowedFix)
	}

	// Untrusted rotates_token:true payload must yield zero execution.
	tampered := []byte(`{"ok":false,"error":{"code":"config_permissions_unsafe","step":"config_store","message":"fix","fix":{"kind":"run_fix","action":"doctor_fix","rotates_token":true}}}`)
	err = decodeTrayCommandError(tampered, nil, errors.New("exit status 1"), ctx)
	if !errors.As(err, &cliErr) || cliErr.Diagnostic.Trusted || cliErr.Diagnostic.AllowedFix != nil {
		t.Fatalf("rotates_token payload must yield zero execution: %+v", cliErr)
	}

	// Old-host compatibility fallback only on recognized legacy stderr.
	legacyErr := decodeTrayCommandError(nil, []byte(`Error: unknown command "preflight" for "agentd"`), errors.New("exit status 1"), ctx)
	if !errors.As(legacyErr, &cliErr) || !cliErr.Diagnostic.LegacyHost || cliErr.Diagnostic.AllowedFix == nil || cliErr.Diagnostic.AllowedFix.URL != onboardingURLDesktop {
		t.Fatalf("expected legacy host update link, got %+v", legacyErr)
	}

	// Arbitrary unstructured stderr is NOT treated as legacy host.
	if decodeTrayCommandError(nil, []byte("some random failure"), errors.New("exit status 1"), ctx) != nil {
		t.Fatal("unstructured stderr should not fabricate a structured envelope or legacy host")
	}

	// UI-local synthesis works and defaults unknown step to service_daemon.
	timeoutErr := newTrayUILocalError("command_timeout", "", "")
	if !timeoutErr.Diagnostic.Trusted || timeoutErr.Diagnostic.Step != "service_daemon" || timeoutErr.Diagnostic.AllowedFix.Kind != "retry" {
		t.Fatalf("unexpected ui-local timeout diagnostic: %+v", timeoutErr.Diagnostic)
	}
	missingBin := newTrayUILocalError("embedded_binary_missing", "service_daemon", "")
	if !missingBin.Diagnostic.Trusted || missingBin.Diagnostic.AllowedFix.URL != onboardingURLDesktop {
		t.Fatalf("unexpected ui-local missing binary diagnostic: %+v", missingBin.Diagnostic)
	}
}
