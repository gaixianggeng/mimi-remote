//go:build !windows

package setup

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

// A shim can leave both a grandchild and an inherited output descriptor.
// Cancellation must reap the group before its delayed write, with no delay to
// the final report. The marker belongs only to this test's sandbox.
func TestPreflightHungCandidateDoesNotLeaveChild(t *testing.T) {
	dir := preflightSandbox(t)
	pin := filepath.Join(dir, "codex")
	const script = "#!/bin/sh\ncd \"$HOME\" || exit 1\n: > started\n( /bin/sleep 1; : > escaped ) &\nwait\n"
	if err := os.WriteFile(pin, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
	defer cancel()
	result := make(chan PreflightObservation, 1)
	go func() {
		result <- inspectPreflightRuntime(ctx, "codex", config.Config{AppServer: config.AppServerConfig{Transport: "local"}}, pin, PreflightHost{})
	}()
	for {
		if _, err := os.Stat(filepath.Join(dir, "started")); err == nil {
			break
		}
		select {
		case <-ctx.Done():
			t.Fatal("fixture shim never started")
		case <-time.After(10 * time.Millisecond):
		}
	}
	cancel()
	select {
	case obs := <-result:
		if obs.Code != "probe_timeout" {
			t.Fatalf("cancelled probe: %q", obs.Code)
		}
	case <-time.After(500 * time.Millisecond):
		t.Fatal("cancelled probe held the request open")
	}
	time.Sleep(1100 * time.Millisecond)
	if _, err := os.Stat(filepath.Join(dir, "escaped")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("descendant survived cancellation")
	}
}

func TestPreflightRuntimeOnlyExecutesVersionAndScrubsPickerPath(t *testing.T) {
	home := preflightSandbox(t)
	t.Setenv("CODEX_HOME", "")
	t.Setenv("AGENTD_CODEX_BIN", "/bin/echo")
	pin := filepath.Join(home, "private-picker-name")
	// Only the explicit picker is permitted to run, and only in inspect mode.
	script := "#!/bin/sh\nif [ \"$#:$1\" = '1:--version' ]; then echo 'codex-cli 0.155.0'; else : > \"$HOME/unexpected-command\"; exit 1; fi\n"
	if err := os.WriteFile(pin, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	cfg := config.Config{AppServer: config.AppServerConfig{Transport: "local"}}
	obs := observePreflightMember(t.Context(), "assistant_codex", cfg, pin, PreflightHost{})
	if obs.Source != "pin" || obs.Code != "runtime_probe_failed" || obs.Available != nil || obs.DetectedVersion != "0.155.0" || len(obs.Candidates) != 1 || obs.Candidates[0].Outcome != "selected" {
		t.Fatal("unexpected pinned runtime observation")
	}
	if strings.Contains(obs.Candidates[0].Path, home) || strings.Contains(obs.Candidates[0].Path, "private-picker-name") {
		t.Fatal("picker path leaked")
	}
	if _, err := os.Stat(filepath.Join(home, "unexpected-command")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("unexpected CLI invocation")
	}
}
