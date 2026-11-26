//go:build !windows

package main

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestKillingPreflightReapsProbeDescendants(t *testing.T) {
	isolateOnboardingCommandEnv(t)
	dir := t.TempDir()
	shim := filepath.Join(dir, "codex")
	script := "#!/bin/sh\ncd \"$HOME\" || exit 1\n(/bin/sleep 1; : > escaped) &\n: > started\nwait\n"
	if err := os.WriteFile(shim, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("MIMI_TEST_ONBOARDING_ERROR_CLI", "1")
	cmd := exec.CommandContext(t.Context(), os.Args[0], "-test.run=^TestOnboardingErrorCLIProcess$", "--",
		"preflight", "--json", "--config", filepath.Join(dir, "absent"), "--scan-root", dir,
		"--runtime-path", "codex="+shim, "--runtime-path", "agy="+dir, "--runtime-path", "claude="+dir)
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if cmd.ProcessState == nil {
			_ = cmd.Process.Kill()
			_ = cmd.Wait()
		}
	})
	home := os.Getenv("HOME")
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, err := os.Stat(filepath.Join(home, "started")); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("fixture probe did not start")
		}
		time.Sleep(10 * time.Millisecond)
	}
	if err := cmd.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	if err := cmd.Wait(); err == nil {
		t.Fatal("preflight exited before cancellation")
	}
	time.Sleep(1100 * time.Millisecond)
	if _, err := os.Stat(filepath.Join(home, "escaped")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("a probe descendant outlived the killed CLI")
	}
}
