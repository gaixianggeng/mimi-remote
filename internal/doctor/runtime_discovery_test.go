package doctor

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/setup"
	"github.com/gaixianggeng/mimi-remote/internal/tailscaleinfo"
)

type bundleInfo struct{ os.FileInfo }

func (b bundleInfo) Mode() os.FileMode { return 0755 }

// Exercise both actual discovery routines without consulting system Applications.
func TestDoctorRecognizesBundledCLIsWithEmptyPATH(t *testing.T) {
	t.Setenv("PATH", "")
	t.Setenv("AGENTD_CODEX_BIN", "")
	d := setup.NewRuntimeDiscovery()
	d.GOOS, d.Home = "darwin", t.TempDir()
	bundle := filepath.Join(d.Home, "Applications", "ChatGPT.app", "Contents", "Resources", "codex-cli", "bin", "codex")
	bin := writeFakeCodexWithAppServerHelp(t, filepath.Join(t.TempDir(), "codex"))
	d.LookPath = func(path string, _ []string) (string, error) {
		if path == bundle {
			return bin, nil
		}
		return "", exec.ErrNotFound
	}
	checker := newTestChecker(t, config.Config{AppServer: config.AppServerConfig{Transport: "local"}})
	checker.resolveRuntime = d.Resolve
	checker.findTailscale = func() (string, error) {
		return tailscaleinfo.FindCLIForHost(func(string) (string, error) { return "", exec.ErrNotFound }, func(path string) (os.FileInfo, error) {
			if path != "/Applications/Tailscale.app/Contents/MacOS/Tailscale" {
				return nil, os.ErrNotExist
			}
			info, err := os.Stat(bin)
			return bundleInfo{info}, err
		}, "darwin", d.Home)
	}
	results := checker.Run(context.Background(), false)
	for _, name := range []string{"codex", "codex-app-server", "tailscale"} {
		var passed bool
		for _, check := range results.Checks {
			if check.Name == name {
				passed = check.OK && check.Level == "ok"
			}
		}
		if !passed {
			t.Fatalf("bundle check %s failed: %+v", name, results.Checks)
		}
	}
}

func TestDoctorLegacyBridgeRequiresConfiguredClaudeCLI(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("PATH", dir)
	t.Setenv("CLAUDE_BRIDGE_CLAUDE_BIN", "")
	t.Setenv("AGENTD_CLAUDE_BRIDGE_BIN", "")
	t.Setenv("AGENTD_CODEX_BIN", "")
	bridge := filepath.Join(dir, "alleycat-claude-bridge")
	script := "#!/bin/sh\necho 'alleycat-claude-bridge 0.2.8'\n"
	if runtime.GOOS == "windows" {
		bridge += ".cmd"
		script = "@echo off\r\necho alleycat-claude-bridge 0.2.8\r\n"
	}
	if err := os.WriteFile(bridge, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	pin := filepath.Join(dir, "deleted-claude.exe")
	cfg := config.ClaudeConfig{Enabled: true, BridgeBin: bridge, LegacyBridge: true, Env: map[string]string{"CLAUDE_BRIDGE_CLAUDE_BIN": pin}}
	checker := newTestChecker(t, config.Config{Claude: cfg})
	d := setup.NewRuntimeDiscovery()
	d.LookPath = func(path string, _ []string) (string, error) {
		if path != pin {
			return "", fmt.Errorf("unexpected lookup %q", path)
		}
		return "", os.ErrNotExist
	}
	var inspected bool
	checker.resolveRuntime = func(ctx context.Context, req setup.RuntimeRequest) (setup.RuntimeCandidate, error) {
		inspected = req.Name == "claude" && req.Pin == pin && req.MinimumVersion == ""
		return d.Resolve(ctx, req)
	}
	check := checker.claudeBridgeCheck(context.Background())
	if !inspected || check.OK || !strings.Contains(check.Message, "无法确认 Claude Code") {
		t.Fatalf("status for missing explicit Claude CLI: %+v, inspected=%t", check, inspected)
	}
	// A slow unrelated platform lookup must not consume the assistant discovery window.
	inspected = false
	checker.cfg.Codex.Enabled = new(bool)
	checker.findTailscale = func() (string, error) {
		if !inspected {
			t.Error("Tailscale lookup preceded assistant inspection")
		}
		return "", exec.ErrNotFound
	}
	checker.Run(t.Context(), false)

}
