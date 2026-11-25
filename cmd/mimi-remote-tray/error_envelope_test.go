package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"sync"
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

	// Timeouts alignment verified through production trayCommandTimeout lookup.
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
		winMin := want.ClientMin
		if want.WindowsClient > winMin {
			winMin = want.WindowsClient
		}
		for _, command := range want.Commands {
			cmdArgs := strings.Fields(command)
			if linuxBudget := trayCommandTimeout("linux", cmdArgs...); linuxBudget < time.Duration(want.ClientMin)*time.Second {
				t.Errorf("linux trayCommandTimeout(%q) = %s, want >= %ds", command, linuxBudget, want.ClientMin)
			}
			if winBudget := trayCommandTimeout("windows", cmdArgs...); winBudget < time.Duration(winMin)*time.Second {
				t.Errorf("windows trayCommandTimeout(%q) = %s, want >= %ds", command, winBudget, winMin)
			}
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
		if suffix, found := strings.CutPrefix(key, "checks/"); found {
			items := doc["checks"].([]any)
			if p.Op == "add" && suffix == "-" {
				doc["checks"] = append(items, p.Value)
				continue
			}
			idxStr, field, nested := strings.Cut(suffix, "/")
			idx, err := strconv.Atoi(idxStr)
			if err != nil || idx < 0 || idx >= len(items) {
				t.Fatalf("invalid checks index in patch %+v", p)
			}
			if !nested {
				switch p.Op {
				case "replace":
					items[idx] = p.Value
					doc["checks"] = items
				case "remove":
					doc["checks"] = slices.Delete(items, idx, idx+1)
				default:
					t.Fatalf("unsupported checks patch %+v", p)
				}
				continue
			}
			rowObj := items[idx].(map[string]any)
			switch p.Op {
			case "add", "replace":
				rowObj[field] = p.Value
			case "remove":
				delete(rowObj, field)
			default:
				t.Fatalf("unsupported checks field patch %+v", p)
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
	legacyErr := decodeTrayCommandError(nil, []byte(`Error: unknown command "preflight" for "agentd"`), errors.New("exit status 1"), ctx, "preflight")
	if !errors.As(legacyErr, &cliErr) || !cliErr.Diagnostic.LegacyHost || cliErr.Diagnostic.AllowedFix == nil || cliErr.Diagnostic.AllowedFix.URL != onboardingURLDesktop {
		t.Fatalf("expected legacy host update link, got %+v", legacyErr)
	}

	// Arbitrary unstructured stderr is NOT treated as legacy host.
	if decodeTrayCommandError(nil, []byte("some random failure"), errors.New("exit status 1"), ctx) != nil {
		t.Fatal("unstructured stderr should not fabricate a structured envelope or legacy host")
	}

	// UI-local synthesis works and defaults unknown step to service_daemon.
	timeoutErr := newTrayUILocalError("command_timeout", "")
	if !timeoutErr.Diagnostic.Trusted || timeoutErr.Diagnostic.Step != "service_daemon" || timeoutErr.Diagnostic.AllowedFix.Kind != "retry" {
		t.Fatalf("unexpected ui-local timeout diagnostic: %+v", timeoutErr.Diagnostic)
	}
	missingBin := newTrayUILocalError("embedded_binary_missing", "service_daemon")
	if !missingBin.Diagnostic.Trusted || missingBin.Diagnostic.AllowedFix.URL != onboardingURLDesktop {
		t.Fatalf("unexpected ui-local missing binary diagnostic: %+v", missingBin.Diagnostic)
	}
}

func TestTrayStageContextSanitizationReceiptsAndTimeouts(t *testing.T) {
	// P1-2: trayValidationContextForArgs defaults to configured=false and parses preflight --stage pair.
	setupCtx := trayValidationContextForArgs("windows", []string{"setup", "--no-pair", "--json"})
	if setupCtx.Stage != "setup" || setupCtx.Configured == nil || *setupCtx.Configured {
		t.Fatalf("setup context must default to configured=false, got %+v", setupCtx)
	}
	restartPayload := []byte(`{"ok":false,"error":{"code":"service_not_running","step":"service_daemon","message":"未运行","fix":{"kind":"run_fix","action":"restart_service"}}}`)
	err := decodeTrayCommandError(restartPayload, nil, errors.New("exit status 1"), setupCtx)
	var cliErr *onboardingCLIError
	if !errors.As(err, &cliErr) || cliErr.Diagnostic.Trusted || cliErr.Diagnostic.AllowedFix != nil {
		t.Fatalf("fresh setup must NOT authorize restart_service: %+v", cliErr)
	}

	pairPreflightCtx := trayValidationContextForArgs("windows", []string{"preflight", "--json", "--stage", "pair"})
	if pairPreflightCtx.Stage != "pair" || pairPreflightCtx.Configured == nil || *pairPreflightCtx.Configured {
		t.Fatalf("preflight --stage pair context wrong: %+v", pairPreflightCtx)
	}
	pairEqCtx := trayValidationContextForArgs("linux", []string{"preflight", "--stage=pair"})
	if pairEqCtx.Stage != "pair" {
		t.Fatalf("preflight --stage=pair stage = %q, want pair", pairEqCtx.Stage)
	}
	verifiedPairCtx := trayValidationContextForArgs("windows", []string{"pair", "--json"}, true)
	if verifiedPairCtx.Configured == nil || !*verifiedPairCtx.Configured {
		t.Fatalf("explicitly verified configured=true was not preserved: %+v", verifiedPairCtx)
	}
	verifiedErr := decodeTrayCommandError(restartPayload, nil, errors.New("exit status 1"), verifiedPairCtx)
	if !errors.As(verifiedErr, &cliErr) || !cliErr.Diagnostic.Trusted || cliErr.Diagnostic.AllowedFix == nil || cliErr.Diagnostic.AllowedFix.Action != "restart_service" {
		t.Fatalf("verified configured host should accept restart_service: %+v", cliErr)
	}

	// P1-1: Unknown failure maps to generic Chinese + sanitized bounded diagnostic (no bearer, pair_url, paths, or unmarked creds).
	rawLeak := `Authorization: Bearer short-private-value fatal: Bearer secretBearer999 mimiremote://pair?pair_sig=leak123 /Users/alice/private/key.json C:\Users\alice\secret.txt \\fileserver\share\token eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abc123def456 UnmarkedCred9876543210ABCDEF ` + strings.Repeat("x", 300)
	unknownErr := newTrayUnknownCommandError(errors.New(rawLeak), "config_store")
	userMsg := unknownErr.Error()
	if unknownErr.Diagnostic.Trusted || unknownErr.Diagnostic.AllowedFix != nil {
		t.Fatalf("unknown command error must not be trusted: %+v", unknownErr.Diagnostic)
	}
	forbidden := []string{"short-private-value", "secretBearer999", "mimiremote://", "pair_sig", "/Users/alice", `C:\Users\alice`, `\\fileserver`, "eyJhbGci", "UnmarkedCred9876543210ABCDEF", "fatal:"}
	for _, secret := range forbidden {
		if strings.Contains(userMsg, secret) {
			t.Fatalf("user-facing error leaked %q: %q", secret, userMsg)
		}
	}
	sanitized := unknownErr.Diagnostic.SanitizedDiagnostic
	if len([]rune(sanitized)) > 180 || len(sanitized) == 0 {
		t.Fatalf("sanitized diagnostic length out of bounds: %d (%q)", len([]rune(sanitized)), sanitized)
	}
	for _, secret := range forbidden[:len(forbidden)-1] {
		if strings.Contains(sanitized, secret) {
			t.Fatalf("sanitized diagnostic leaked %q: %q", secret, sanitized)
		}
	}
	if fallback := redactOnboardingFallback(rawLeak); len([]rune(fallback)) > 180 || strings.Contains(fallback, "/Users/alice") || strings.Contains(fallback, "UnmarkedCred9876543210ABCDEF") {
		t.Fatalf("redactOnboardingFallback failed to scrub/bound: %q", fallback)
	}

	// P1-3: A valid ok:true setup report MUST NOT satisfy a pair preflight request.
	if _, err := decodeAndValidatePreflightReportForStage(
		loadTrayContractFile(t, "preflight-claude-only-no-network.json"),
		"linux",
		"pair",
		false,
		"",
	); err == nil {
		t.Fatal("setup report must not satisfy pair preflight")
	}

	// P2-1: Legacy setup output with explicit ok:false MUST be rejected.
	if _, err := decodeOnboardingSetupReceipt([]byte(`{"ok":false,"endpoint":"http://127.0.0.1:8787","pair_url":"mimiremote://pair?pair_sig=x","pair_expires_at":"2030-01-01T00:05:00Z"}`)); err == nil {
		t.Fatal("legacy setup with ok:false must be rejected")
	}

	// P2-2: Strict RFC3339 / UTC expiry validation.
	for _, bad := range []string{
		`{"ok":true,"endpoint":"http://127.0.0.1:8787","pair_url":"mimiremote://pair?pair_sig=x","pair_expires_at":"2030-01-01T00:05:00Z"}`,
		`{"ok":true,"endpoint":"http://100.64.0.1:8787","pair_url":"mimiremote://pair?pair_sig=x","pair_expires_at":"2030-01-01T08:05:00+08:00","network":"tailscale"}`,
		`{"ok":true,"endpoint":"http://100.64.0.1:8787","pair_url":"mimiremote://pair?pair_sig=x","pair_expires_at":"2030-01-01","network":"tailscale"}`,
		`{"endpoint":"http://100.64.0.1:8787","pair_url":"mimiremote://pair?pair_sig=x","pair_expires_at":"not-a-date"}`,
		`{"ok":true,"endpoint":"http://100.64.0.1:8787","pair_url":"mimiremote://pair?pair_sig=x","pair_expires_at":"2030-02-30T00:05:00Z","network":"tailscale"}`,
		`{"ok":true,"endpoint":"http://100.64.0.1:8787","pair_url":"mimiremote://pair?","pair_expires_at":"2030-01-01T00:05:00Z","network":"tailscale"}`,
	} {
		if _, err := decodeOnboardingPairingTicketReceipt([]byte(bad), false); err == nil {
			t.Fatalf("pairing ticket must reject invalid payload: %s", bad)
		}
	}
	if _, err := decodeOnboardingPairingTicketReceipt(
		[]byte(`{"ok":true,"endpoint":"http://100.64.0.1:8787","pair_url":"mimiremote://pair?pair_sig=ok","pair_expires_at":"2030-01-01T00:05:00.123456789Z","network":"tailscale"}`),
		true,
	); err != nil {
		t.Fatalf("nanosecond UTC ticket should decode: %v", err)
	}
	if _, err := decodeOnboardingPairingTicketReceipt(
		[]byte(`{"endpoint":"http://127.0.0.1:8787","pair_url":"mimiremote://pair?pair_sig=legacy","pair_expires_at":"2030-01-01T08:05:00+08:00"}`),
		false,
	); err != nil {
		t.Fatalf("legacy offset ticket without ok should decode: %v", err)
	}
}

func TestTrayBoundedOutputBlocksReadFromAndStreamsLiveProgress(t *testing.T) {
	// P1-5: Neither writer may expose io.ReaderFrom (which lets os/exec bypass capped Write).
	if _, ok := any(&boundedTrayOutput{}).(io.ReaderFrom); ok {
		t.Fatal("boundedTrayOutput must not implement io.ReaderFrom")
	}
	if _, ok := any(newTrayStderrProgressWriter(16, nil, 0, nil)).(io.ReaderFrom); ok {
		t.Fatal("trayStderrProgressWriter must not implement io.ReaderFrom")
	}

	capped := &boundedTrayOutput{remaining: 16}
	huge := strings.NewReader(strings.Repeat("A", 1024*64))
	if _, err := io.Copy(capped, huge); err != nil {
		t.Fatalf("io.Copy into boundedTrayOutput failed: %v", err)
	}
	if !capped.truncated || capped.Len() != 16 {
		t.Fatalf("boundedTrayOutput cap bypassed: truncated=%v len=%d", capped.truncated, capped.Len())
	}

	if runtime.GOOS == "windows" {
		return
	}
	// Live subprocess streaming through runTrayCommand (shared by both Windows and Linux controllers):
	// verifies fast progress arrives live BEFORE exit, invalid progress tuples are dropped,
	// and stdout/stderr caps are enforced through os/exec.
	ndjsonPath, err := filepath.Abs(filepath.Join(trayContractDir, "preflight-progress-slow-assistant.ndjson"))
	if err != nil {
		t.Fatal(err)
	}
	reportPath, err := filepath.Abs(filepath.Join(trayContractDir, "preflight-codex-chatgpt-app.json"))
	if err != nil {
		t.Fatal(err)
	}
	scriptPath := filepath.Join(t.TempDir(), "fake-agentd.sh")
	badProgress1 := `{"id":"assistant_claude","group":"assistant","state":"action_needed","title":"Claude","detail":"请登录","blocking":false,"enabled":true,"available":false,"candidates":[{"path":"/fixture/bin/claude","outcome":"selected"}],"code":"claude_signed_out","fix":{"kind":"open_url","url":"https://learn.chatgpt.com/docs/codex/cli"}}`
	badProgress2 := `{"id":"service_daemon","group":"service","state":"action_needed","title":"后台服务","detail":"未运行","blocking":true,"code":"service_not_running","fix":{"kind":"run_fix","action":"restart_service"}}`
	script := "#!/bin/sh\n" +
		"echo 'malformed noise line' >&2\n" +
		"printf '%s\\n' '" + badProgress1 + "' >&2\n" +
		"printf '%s\\n' '" + badProgress2 + "' >&2\n" +
		"head -n 26 \"" + ndjsonPath + "\" >&2\n" +
		"sleep 0.25\n" +
		"tail -n +27 \"" + ndjsonPath + "\" >&2\n" +
		"cat \"" + reportPath + "\"\n"
	if err := os.WriteFile(scriptPath, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}

	configured := false
	acc := newOnboardingProgressAccumulatorWithContext(1, onboardingValidationContext{
		Surface:    "check",
		Platform:   "macos",
		Stage:      "pair",
		Configured: &configured,
	})
	var mu sync.Mutex
	var events []onboardingCheck
	var codexOKAt time.Time
	cmd := exec.Command(scriptPath)
	stdout, _, truncated, err := runTrayCommand(cmd, acc, 1, func(row onboardingCheck) {
		mu.Lock()
		events = append(events, row)
		if row.ID == "assistant_codex" && row.State == "ok" && codexOKAt.IsZero() {
			codexOKAt = time.Now()
		}
		mu.Unlock()
	}, 1024*1024, 64*1024)
	finishedAt := time.Now()
	if err != nil || truncated {
		t.Fatalf("runTrayCommand failed: err=%v truncated=%v", err, truncated)
	}
	report, err := decodeAndValidatePreflightReportForStage(stdout, "macos", "pair", false, "")
	if err != nil {
		t.Fatalf("validate streamed report: %v", err)
	}
	if !acc.Complete(1, report) {
		t.Fatal("accumulator completion failed")
	}
	mu.Lock()
	gotCount := len(events)
	earlyGap := finishedAt.Sub(codexOKAt)
	mu.Unlock()
	if gotCount != 36 {
		t.Fatalf("expected exactly 36 valid progress events (2 invalid rows dropped), got %d", gotCount)
	}
	if codexOKAt.IsZero() || earlyGap < 100*time.Millisecond {
		t.Fatalf("expected live progress arrival before process exit, gap=%s", earlyGap)
	}

	// Verify os/exec stdout cap holds when child writes > cap.
	bigCmd := exec.Command("/bin/sh", "-c", "head -c 65536 /dev/zero | tr '\\0' 'A'")
	bigOut, _, bigTrunc, err := runTrayCommand(bigCmd, nil, 0, nil, 32, 32)
	if err != nil {
		t.Fatalf("bigCmd failed: %v", err)
	}
	if !bigTrunc || len(bigOut) != 32 {
		t.Fatalf("os/exec bypassed stdout cap: truncated=%v len=%d", bigTrunc, len(bigOut))
	}
}

func TestTrayDropsProgressWithoutAnAuthorizedTuple(t *testing.T) {
	progress := newOnboardingProgressAccumulator(1)
	for _, fields := range []string{
		`"state":"checking","Fix":{"kind":"run_fix","action":"restart_service"}`,
		`"state":"action_needed","code":null,"fix":{"kind":"run_fix","action":"restart_service"}`,
		`"state":"action_needed","code":"","fix":{"kind":"retry"}`,
		`"schema":"mimi.onboarding.preflight/v2","state":"action_needed","code":"service_not_running","fix":{"kind":"run_fix","action":"save_setup"}`,
	} {
		line := []byte(`{"id":"service_daemon","group":"service","title":"服务","detail":"检查","blocking":false,` + fields + `}`)
		if _, ok := progress.ApplyValidatedLine(1, line); ok {
			t.Errorf("unregistered progress tuple published: %s", fields)
		}
	}
}

func TestTrayUnknownJSONProtocolTakesPrecedenceOverLegacyStderr(t *testing.T) {
	ctx := trayValidationContextForArgs("windows", []string{"preflight"})
	if err := decodeTrayCommandError([]byte("incompatible response"), []byte(`Error: unknown command "preflight" for "agentd"`), errors.New("exit status 1"), ctx, "preflight"); err != nil {
		t.Fatal("unexpected stdout selected a legacy action")
	}
	err := decodeTrayCommandError([]byte(`{"schema":"mimi.onboarding.preflight/v2"}`), []byte(`Error: unknown command "preflight" for "agentd"`), errors.New("exit status 1"), ctx, "preflight")
	var structured *onboardingCLIError
	if !errors.As(err, &structured) || structured.Diagnostic.Trusted || structured.Diagnostic.AllowedFix != nil {
		t.Fatal("unknown protocol enabled an action")
	}
}

func TestTrayCommandBoundsInheritedPipes(t *testing.T) {
	const role = "MIMI_TEST_TRAY_PIPE_ROLE"
	switch os.Getenv(role) {
	case "holder":
		time.Sleep(3 * time.Second)
		return
	case "parent":
		cmd := exec.Command(os.Args[0], "-test.run=^TestTrayCommandBoundsInheritedPipes$")
		cmd.Env = append(os.Environ(), role+"=holder")
		cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		return
	}
	cmd := exec.Command(os.Args[0], "-test.run=^TestTrayCommandBoundsInheritedPipes$")
	cmd.Env = append(os.Environ(), role+"=parent")
	_, _, _, err := runTrayCommand(cmd, nil, 0, nil, 1024, 1024)
	if !errors.Is(err, exec.ErrWaitDelay) {
		t.Fatalf("expected inherited pipe handles to hit the drain deadline, got %v", err)
	}
}

func TestTrayLegacyEvidenceMatchesInvocationAndFirstLine(t *testing.T) {
	const preflight = `错误：未知命令 "preflight"，可用命令：setup、start、pair`
	const missingFlag = "flag provided but not defined: -no-pair\nUsage of setup:"
	for _, tc := range []struct {
		stderr string
		args   []string
		legacy bool
	}{
		{preflight, []string{"preflight", "--json"}, true},
		{missingFlag, []string{"setup", "--no-pair"}, true},
		{preflight, []string{"setup", "--no-pair"}, false},
		{missingFlag, []string{"pair"}, false},
		{"another failure\n" + preflight, []string{"preflight"}, false},
		{"probe: unknown command in preflight output", []string{"preflight"}, false},
	} {
		if got := isLegacyHostCLIOutput([]byte(tc.stderr), tc.args); got != tc.legacy {
			t.Errorf("legacy recognition on %v with %q = %v", tc.args, tc.stderr, got)
		}
	}
}

func TestTrayReceiptsRejectDeclaredFutureProtocol(t *testing.T) {
	future := func(name string) []byte {
		var receipt map[string]json.RawMessage
		if err := json.Unmarshal(loadTrayContractFile(t, name), &receipt); err != nil {
			t.Fatal(err)
		}
		receipt["schema"] = json.RawMessage(`"mimi.onboarding.future/v2"`)
		raw, err := json.Marshal(receipt)
		if err != nil {
			t.Fatal(err)
		}
		return raw
	}
	if _, err := decodeOnboardingSetupReceipt(future("setup-ok-no-assistant.json")); err == nil {
		t.Error("future setup accepted")
	}
	if _, err := decodeOnboardingUpReadinessReceipt(future("up-ok-ready.json")); err == nil {
		t.Error("future readiness accepted")
	}
	if _, err := decodeOnboardingPairingTicketReceipt(future("pair-ok-direct.json"), false); err == nil {
		t.Error("future pairing accepted")
	}
}

func TestTrayPreflightHonorsRequestContextAndCancelledGeneration(t *testing.T) {
	calls := 0
	run := func(_ context.Context, acc *onboardingProgressAccumulator, generation uint64, _ func(onboardingCheck), _ ...string) ([]byte, error) {
		calls++
		acc.Cancel(generation)
		return loadTrayContractFile(t, "preflight-windows-public.json"), nil
	}
	acc := newOnboardingProgressAccumulatorWithContext(1, onboardingValidationContext{
		Surface: "check", Platform: "windows", Stage: "pair",
	})
	if _, err := runTrayPreflight(context.Background(), "windows", "setup", acc, 1, nil, run); err == nil || calls != 0 {
		t.Fatal("started a command with progress validation for a different stage")
	}
	if report, err := runTrayPreflight(context.Background(), "windows", "pair", acc, 1, nil, run); !errors.Is(err, context.Canceled) || report.OK != nil {
		t.Fatal("returned a terminal report from a cancelled generation")
	}
}

func TestTrayPairingWarningsKeepKnownMessagesAndOmitPrivateText(t *testing.T) {
	var raw map[string]any
	if err := json.Unmarshal(loadTrayContractFile(t, "pair-ok-direct.json"), &raw); err != nil {
		t.Fatal(err)
	}
	const known = "局域网配对仅适用于与这台电脑位于同一局域网的设备"
	const private = "Authorization: Bearer private-fixture"
	raw["warnings"] = []string{known, private, raw["pair_url"].(string)}
	data, err := json.Marshal(raw)
	if err != nil {
		t.Fatal(err)
	}
	receipt, err := decodeOnboardingPairingTicketReceipt(data, false)
	if err != nil || len(receipt.Warnings) != 2 || receipt.Warnings[0] != known ||
		strings.Contains(receipt.Warnings[1], "private-fixture") || strings.Contains(receipt.Warnings[1], "mimiremote://") {
		t.Fatal("pairing warning rendering did not preserve safe content and remove private values")
	}
}

func TestTrayDiagnosticProjectionUsesLocalCopyAndPathAliases(t *testing.T) {
	const private = "private-fixture"
	if got := formatOnboardingMessage("claude_signed_out", "assistant_claude", private); strings.Contains(got, private) {
		t.Fatal("untrusted version appeared in localized message")
	}
	if got := formatOnboardingMessage("claude_signed_out", "assistant_claude", "v2.1.30-rc.2"); !strings.Contains(got, "v2.1.30-rc.2") {
		t.Fatal("safe runtime version missing")
	}
	ctx := onboardingValidationContext{Platform: "linux", Surface: "check", Stage: "setup"}
	for _, fields := range []string{
		`"state":"checking"`,
		`"state":"error","code":"internal_error","fix":{"kind":"retry"}`,
	} {
		blocking := strings.Contains(fields, "internal_error")
		line := `{"id":"config_store","group":"workspace","title":"private-fixture","detail":"private-fixture","config_path":"/private-fixture/config.json","blocking":` + strconv.FormatBool(blocking) + `,` + fields + `}`
		row, err := decodeOnboardingCheck([]byte(line))
		if err != nil {
			t.Fatal(err)
		}
		diag, err := validateOnboardingCheck(row, ctx)
		if err != nil || !diag.Trusted || strings.Contains(diag.Message, private) || diag.ConfigPath != "…/config.json" || row.ConfigPath != "/private-fixture/config.json" {
			t.Fatal("diagnostic did not project safe copy and paths while preserving source data")
		}
	}
	raw := []byte(`{"ok":false,"error":{"code":"config_invalid","step":"config_store","message":"private-fixture","fix":{"kind":"open_settings","target":"host_recovery"},"config_path":"C:\\private-fixture\\config.json","recovery_path":"/private-fixture/other.json"}}`)
	diag, err := decodeOnboardingErrorEnvelope(raw, trayValidationContextForArgs("windows", []string{"setup"}))
	if err != nil || !diag.Trusted || strings.Contains(diag.Message, private) || diag.ConfigPath != "…/config.json" || diag.RecoveryPath != "…" {
		t.Fatal("host recovery diagnostic exposed a private path or message")
	}
}
