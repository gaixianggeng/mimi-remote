package doctor

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
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
