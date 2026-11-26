package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/setup"
)

func TestPreflightProgressCLIProcess(t *testing.T) {
	if os.Getenv("MIMI_TEST_PREFLIGHT_PROGRESS") != "1" {
		return
	}
	runHostPreflight = func(ctx context.Context, opts setup.PreflightOptions, progress func(setup.PreflightCheck)) setup.PreflightReport {
		probes := setup.PreflightProbes{Platform: "linux", Member: func(_ context.Context, id string, _ config.Config, _ string, _ setup.PreflightHost) setup.PreflightObservation {
			available := id == "assistant_codex"
			if available {
				return setup.PreflightObservation{Available: &available, Source: "auto", DetectedVersion: "0.150.0", Candidates: []setup.PreflightCandidate{{Path: "/fixture/bin/codex", Outcome: "selected", Version: "0.150.0"}}}
			}
			if id == "assistant_agy" {
				// The parent withholds this byte until both aggregates have arrived.
				var signal [1]byte
				if _, err := io.ReadFull(os.Stdin, signal[:]); err != nil {
					os.Exit(92)
				}
			}
			codes := map[string]string{"assistant_agy": "agy_not_found", "assistant_claude": "claude_not_found", "assistant_deepseek": "deepseek_not_running", "network_lan": "lan_unavailable", "network_tailcat": "tailcat_unavailable", "network_tailscale": "tailscale_not_installed"}
			return setup.PreflightObservation{Available: &available, Code: codes[id]}
		}}
		return setup.InspectPreflight(ctx, opts, probes, progress)
	}
	separator := slices.Index(os.Args, "--")
	if separator < 0 {
		os.Exit(91)
	}
	os.Args = append([]string{"agentd"}, os.Args[separator+1:]...)
	main()
	os.Exit(0) // Keep the Go test runner's PASS off CLI stdout.
}

func TestPreflightLiveProgress(t *testing.T) {
	dir := t.TempDir()
	home := t.TempDir()
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, exe, "-test.run=^TestPreflightProgressCLIProcess$", "--", "preflight", "--progress-json", "--json", "--config", filepath.Join(dir, "absent.json"), "--scan-root", dir, "--assistant", "codex=enabled")
	cmd.Env = []string{"MIMI_TEST_PREFLIGHT_PROGRESS=1", "PATH=" + home, "HOME=" + home, "USERPROFILE=" + home, "APPDATA=" + home, "LOCALAPPDATA=" + home, "XDG_CONFIG_HOME=" + home, "TMPDIR=" + home, "TEMP=" + home, "TMP=" + home, "SystemRoot=" + os.Getenv("SystemRoot"), "GORACE=atexit_sleep_ms=0"}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		t.Fatal(err)
	}
	var stdout bytes.Buffer
	cmd.Stdout = &stdout
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = stdin.Close()
		if cmd.ProcessState == nil {
			_ = cmd.Process.Kill()
			_ = cmd.Wait()
		}
	})
	expected := strings.Fields("config_store workspace_root service_daemon assistant_codex assistant_claude assistant_agy assistant_deepseek assistant_any network_tailscale network_tailcat network_lan network_any")
	done := map[string]map[string]any{}
	count := 0
	released := false
	stream := bufio.NewScanner(stderr)
	for stream.Scan() {
		var row map[string]any
		if err := json.Unmarshal(stream.Bytes(), &row); err != nil {
			t.Fatalf("invalid progress line %d: %v", count, err)
		}
		id, _ := row["id"].(string)
		if count < len(expected) {
			if id != expected[count] || row["state"] != "checking" {
				t.Fatalf("skeleton %d = %v", count, row)
			}
		} else {
			if !slices.Contains(expected, id) || row["state"] == "checking" || done[id] != nil {
				t.Fatalf("unexpected completion: %v", row)
			}
			if id == "assistant_agy" && !released {
				t.Fatal("slow probe completed before its release")
			}
			if id == "assistant_any" && (done["assistant_codex"] == nil || row["state"] != "ok") {
				t.Fatal("eligible member must precede successful aggregate")
			}
			done[id] = row
			if !released && done["assistant_any"] != nil && done["network_any"] != nil {
				if _, err := stdin.Write([]byte{1}); err != nil {
					t.Fatal(err)
				}
				released = true
			}
		}
		count++
	}
	if err := stream.Err(); err != nil {
		t.Fatal(err)
	}
	if err := cmd.Wait(); err != nil {
		t.Fatalf("child exited %v after %d progress rows (released=%t)", err, count, released)
	}
	if !released || count != 2*len(expected) {
		t.Fatalf("incomplete live progress: rows=%d released=%v", count, released)
	}
	var final struct{ Checks []map[string]any }
	if err := json.Unmarshal(stdout.Bytes(), &final); err != nil {
		t.Fatalf("expected exactly one final report: %v", err)
	}
	if len(final.Checks) != len(expected) || !bytes.HasSuffix(stdout.Bytes(), []byte("\n")) {
		t.Fatal("incomplete final document")
	}
	for i, row := range final.Checks {
		if row["id"] != expected[i] || !reflect.DeepEqual(done[expected[i]], row) {
			t.Fatalf("final row %d differs from streamed completion", i)
		}
	}
}

func TestPreflightRejectsInvalidDraftBeforeDiscovery(t *testing.T) {
	for _, args := range [][]string{
		{"--stage", "unknown"}, {"--runtime-path", "codex=relative"}, {"--runtime-path", "deepseek=auto"}, {"--assistant", "codex=maybe"},
		{"--assistant", "claude=enabled", "--assistant", "claude=auto"}, {"--runtime-path", "agy=auto", "--runtime-path", "agy=auto"},
		{"--stage", "pair", "--assistant", "codex=enabled"},
	} {
		var out, diag bytes.Buffer
		argv := append([]string{"agentd", "preflight", "--progress-json", "--json"}, args...)
		if status := commandExit(argv, &out, &diag); status != 1 {
			t.Fatalf("accepted %q", args)
		}
		assertOnboardingError(t, out.Bytes(), diag.String(), "invalid_request", "config_store")
	}
}
