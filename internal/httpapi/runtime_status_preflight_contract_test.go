package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/config/configtest"
	"github.com/gaixianggeng/mimi-remote/internal/setup"
)

func TestLivePreflightHostCLIContract(t *testing.T) {
	contract := loadOnboarding(t)
	home := t.TempDir()
	for _, key := range []string{"HOME", "USERPROFILE", "APPDATA", "LOCALAPPDATA", "XDG_CONFIG_HOME"} {
		t.Setenv(key, home)
	}
	for _, entry := range os.Environ() {
		key, _, _ := strings.Cut(entry, "=")
		if strings.HasPrefix(strings.ToUpper(key), "AGENTD_") {
			t.Setenv(key, "")
		}
	}
	for _, platform := range []string{"linux", "windows", "macos"} {
		for _, scenario := range []struct {
			name, stage              string
			committed, valid, wantOK bool
		}{
			{"fresh", "setup", false, false, true},
			{"unconfigured", "pair", false, false, false},
			{"invalid", "pair", true, false, false},
			{"ready", "pair", true, true, true},
			{"blank-root", "pair", true, true, false},
			{"relative-root", "pair", true, true, false},
			{"missing-secondary", "pair", true, true, false},
		} {
			t.Run(platform+"/"+scenario.name, func(t *testing.T) {
				dir := t.TempDir()
				path := filepath.Join(dir, "config.json")
				fixtureToken := strings.Repeat("fixture-", 5)
				if scenario.committed {
					data := []byte("{")
					if scenario.valid {
						scan, browse := dir, dir
						switch scenario.name {
						case "blank-root":
							scan = " "
						case "relative-root":
							browse = "."
						}
						scans := []string{scan}
						if scenario.name == "missing-secondary" {
							scans = append(scans, filepath.Join(dir, "unmounted"))
						}
						var err error
						data, err = json.Marshal(map[string]any{
							"listen": "127.0.0.1:8787", "auth": map[string]string{"token": fixtureToken},
							"app_server": map[string]string{"transport": "ssh", "ssh_target": "fixture.invalid"},
							"codex":      map[string]any{"enabled": true}, "network": map[string]any{"allow_tailscale": true},
							"scan_roots": scans, "browse_roots": []string{browse},
						})
						if err != nil {
							t.Fatal(err)
						}
					}
					configtest.CreatePrivateFile(t, path, data)
				}
				probes := setup.PreflightProbes{Platform: platform, Host: func(_ context.Context, cfg config.Config) (setup.PreflightHost, error) {
					if cfg.Auth.Token != fixtureToken {
						return setup.PreflightHost{}, setup.PreflightHostError("pair_token_mismatch")
					}
					return setup.PreflightHost{Ready: true, Version: "1.2.3+mac.42", Assistants: map[string]bool{"codex": true}, Networks: map[string]bool{"tailscale": true}, Accounts: map[string]string{"codex": "connected"}}, nil
				}, Member: func(_ context.Context, id string, _ config.Config, _ string, _ setup.PreflightHost) setup.PreflightObservation {
					yes, no := true, false
					switch id {
					case "assistant_codex":
						return setup.PreflightObservation{Available: &yes, Source: "auto", DetectedVersion: "0.150.0", Candidates: []setup.PreflightCandidate{{Path: "/fixture/bin/codex", Outcome: "selected", Version: "0.150.0"}}}
					case "network_tailscale":
						return setup.PreflightObservation{Available: &yes}
					}
					codes := map[string]string{"assistant_claude": "claude_not_found", "assistant_agy": "runtime_probe_failed", "assistant_deepseek": "deepseek_auth_failed", "network_lan": "lan_unavailable", "network_tailcat": "tailcat_unavailable"}
					return setup.PreflightObservation{Available: &no, Code: codes[id]}
				}}
				opts := setup.PreflightOptions{Stage: scenario.stage, Version: "1.2.3", ConfigPath: path, ScanRoot: dir, BrowseRoot: dir}
				if scenario.valid {
					opts.ScanRoot, opts.BrowseRoot = "", ""
				}
				var progress []wireObject
				asObject := func(v any) wireObject {
					raw, err := json.Marshal(v)
					if err != nil {
						t.Fatal(err)
					}
					return contractJSON[wireObject](t, raw)
				}
				report := setup.InspectPreflight(t.Context(), opts, probes, func(row setup.PreflightCheck) { progress = append(progress, asObject(row)) })
				doc := asObject(report)
				if err := contract.report(doc, wireObject{"platform": platform}); err != nil {
					t.Fatalf("live report: %v", err)
				}
				if report.OK != scenario.wantOK || report.Configured != scenario.committed || report.WorkspaceConfirmed != scenario.valid {
					t.Fatalf("unexpected live report status: ok=%v configured=%v confirmed=%v next=%s", report.OK, report.Configured, report.WorkspaceConfirmed, report.RecommendedNext)
				}
				if scenario.valid && !scenario.wantOK && report.RecommendedNext != "workspace_root" {
					t.Fatalf("invalid committed root should block pairing at workspace_root, got %s", report.RecommendedNext)
				}
				ctx := wireObject{"surface": "check", "platform": platform, "configured": doc["configured"], "stage": doc["stage"], "recommended_transport": doc["recommended_transport"]}
				if len(progress) != 2*len(report.Checks) {
					t.Fatalf("incomplete progress: %d rows", len(progress))
				}
				for i, row := range progress {
					if err := contract.check(row, ctx); err != nil {
						t.Fatalf("live progress row %d: %v", i, err)
					}
				}
			})
		}
	}
}

// Exercise the shipping CLI, including its real probes, with absent runtime pins
// and an isolated home. Validate observations for this platform, regardless of
// which network interfaces the test runner has.
func TestPreflightCLIStdoutAgainstPublishedContract(t *testing.T) {
	c := loadOnboarding(t)
	dir := t.TempDir()
	bin := filepath.Join(dir, "agentd")
	if runtime.GOOS == "windows" {
		bin += ".exe"
	}
	build := exec.CommandContext(t.Context(), "go", "build", "-o", bin, "../../cmd/agentd")
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build CLI: %v: %s", err, output)
	}
	// Intercept the PATH lookup before any system Tailscale app fallback.
	tsName, tsBody := "tailscale", "#!/bin/sh\nexit 1\n"
	if runtime.GOOS == "windows" {
		tsName, tsBody = "tailscale.cmd", "@exit /b 1\r\n"
	}
	if err := os.WriteFile(filepath.Join(dir, tsName), []byte(tsBody), 0700); err != nil {
		t.Fatal(err)
	}
	missing := filepath.Join(dir, "absent")
	args := []string{"preflight", "--json", "--config", filepath.Join(dir, "missing.json"), "--scan-root", dir, "--assistant", "codex=enabled"}
	for _, id := range []string{"codex", "claude", "agy"} {
		args = append(args, "--runtime-path", id+"="+missing)
	}
	cmd := exec.CommandContext(t.Context(), bin, args...)
	cmd.Env = []string{"HOME=" + dir, "USERPROFILE=" + dir, "APPDATA=" + dir, "LOCALAPPDATA=" + dir, "XDG_CONFIG_HOME=" + dir, "PATH=" + dir, "SystemRoot=" + os.Getenv("SystemRoot"), "AGENTD_TAILCAT_BIN=" + missing}
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil || stderr.Len() != 0 {
		t.Fatalf("CLI status %v, diagnostics %q", err, stderr.String())
	}
	doc := contractJSON[wireObject](t, out)
	platform := runtime.GOOS
	if platform == "darwin" {
		platform = "macos"
	}
	if err := c.report(doc, wireObject{"platform": platform}); err != nil {
		t.Fatalf("CLI stdout: %v", err)
	}
}
