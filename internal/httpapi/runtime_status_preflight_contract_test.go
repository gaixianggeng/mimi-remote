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
		} {
			t.Run(platform+"/"+scenario.name, func(t *testing.T) {
				dir := t.TempDir()
				path := filepath.Join(dir, "config.json")
				fixtureToken := strings.Repeat("fixture-", 5)
				if scenario.committed {
					data := []byte("{")
					if scenario.valid {
						var err error
						data, err = json.Marshal(map[string]any{
							"listen": "127.0.0.1:8787", "auth": map[string]string{"token": fixtureToken},
							"app_server": map[string]string{"transport": "ssh", "ssh_target": "fixture.invalid"},
							"codex":      map[string]any{"enabled": true}, "network": map[string]any{"allow_tailscale": true},
							"scan_roots": []string{dir}, "browse_roots": []string{dir},
						})
						if err != nil {
							t.Fatal(err)
						}
					}
					if err := os.WriteFile(path, data, 0600); err != nil {
						t.Fatal(err)
					}
				}
				probes := setup.PreflightProbes{Platform: platform, Host: func(_ context.Context, cfg config.Config) (setup.PreflightHost, error) {
					if cfg.Auth.Token != fixtureToken {
						return setup.PreflightHost{}, setup.PreflightHostError("pair_token_mismatch")
					}
					return setup.PreflightHost{Ready: true, Version: "fixture", Assistants: map[string]bool{"codex": true}, Networks: map[string]bool{"tailscale": true}, Accounts: map[string]string{"codex": "connected"}}, nil
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
				opts := setup.PreflightOptions{Stage: scenario.stage, Version: "fixture", ConfigPath: path, ScanRoot: dir, BrowseRoot: dir}
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

// Exercise the process boundary as well as the typed report. The agentd test
// binary injects the host observations, keeping installed CLIs and the user's
// daemon out of both the report and the build environment.
func TestPreflightCLIStdoutAgainstPublishedContract(t *testing.T) {
	c := loadOnboarding(t)
	dir := t.TempDir()
	bin := filepath.Join(dir, "agentd-test")
	if runtime.GOOS == "windows" {
		bin += ".exe"
	}
	build := exec.CommandContext(t.Context(), "go", "test", "-c", "-o", bin, "../../cmd/agentd")
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build CLI test process: %v: %s", err, output)
	}
	cmd := exec.CommandContext(t.Context(), bin, "-test.run=^TestPreflightProgressCLIProcess$", "--", "preflight", "--json", "--config", filepath.Join(dir, "missing.json"), "--scan-root", dir, "--assistant", "codex=enabled")
	cmd.Env = []string{"MIMI_TEST_PREFLIGHT_PROGRESS=1", "HOME=" + dir, "USERPROFILE=" + dir, "APPDATA=" + dir, "LOCALAPPDATA=" + dir, "XDG_CONFIG_HOME=" + dir, "PATH=" + dir, "SystemRoot=" + os.Getenv("SystemRoot")}
	cmd.Stdin = strings.NewReader("x")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil || stderr.Len() != 0 {
		t.Fatalf("CLI status %v, diagnostics %q", err, stderr.String())
	}
	doc := contractJSON[wireObject](t, out)
	if err := c.report(doc, wireObject{"platform": "linux"}); err != nil {
		t.Fatalf("CLI stdout: %v", err)
	}
}
