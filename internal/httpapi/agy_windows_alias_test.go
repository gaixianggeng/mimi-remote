package httpapi

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/agybridge"
	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/setup"
)

type executionAliasInfo struct{ os.FileInfo }

func (executionAliasInfo) Mode() os.FileMode { return os.ModeIrregular }

func TestAgyStatusAcceptsDiscoveredWindowsExecutionAlias(t *testing.T) {
	local := t.TempDir()
	alias := filepath.Join(local, "Microsoft", "WindowsApps", "agy.exe")
	if err := os.MkdirAll(filepath.Dir(alias), 0700); err != nil {
		t.Fatal(err)
	}
	// The fake CLI is executable on the test host. Present its metadata as an
	// App Execution Alias, including on CI hosts without the Windows Store.
	copyFakeBridgeTo(t, alias)
	if err := os.WriteFile(alias+".version", []byte("1.5.14"), 0600); err != nil {
		t.Fatal(err)
	}
	d := setup.NewRuntimeDiscovery()
	d.GOOS, d.Home = "windows", local
	d.LookPath = func(path string, _ []string) (string, error) {
		if path != alias {
			return "", exec.ErrNotFound
		}
		return path, nil
	}
	d.Stat = func(path string) (os.FileInfo, error) {
		info, err := os.Stat(path)
		return executionAliasInfo{info}, err
	}
	cfg := config.AgyConfig{Enabled: true, Env: map[string]string{"LOCALAPPDATA": local, agybridge.AgyBinaryEnvKey: alias}}
	r := &Router{cfg: config.Config{Agy: cfg}}
	candidate, err := d.Resolve(context.Background(), setup.AgyRuntime(cfg, "1.5.0", agybridge.BuildEnv(cfg.Env)))
	if err != nil || candidate.Path != alias {
		t.Fatalf("alias selection: %+v, %v", candidate, err)
	}
	r.setAgyAdapterProbe(agyAdapterProbe{cliPath: candidate.Path, Healthy: true, Status: "ready", CheckedAt: time.Now()})
	if got := r.currentAgyAdapterProbeWithDiscovery(d); !got.Healthy || got.Status != "ready" {
		t.Fatalf("status rejected selected alias: %+v", got)
	}
	if err := os.Remove(alias); err != nil {
		t.Fatal(err)
	}
	if got := r.currentAgyAdapterProbeWithDiscovery(d); got.Healthy || got.Status != "agy_missing" {
		t.Fatalf("status accepted deleted alias: %+v", got)
	}
}
