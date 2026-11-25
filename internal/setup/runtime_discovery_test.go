package setup

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"testing"
	"testing/synctest"
	"time"
)

const discoveryTestBundle = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"

type discoveryFixture struct {
	RuntimeDiscovery
	files    map[string]string // virtual candidate path to its backing file
	versions map[string]string
	env      map[string]string
	calls    []string
}

func newDiscoveryFixture(t *testing.T) *discoveryFixture {
	t.Helper()
	f := &discoveryFixture{
		files: map[string]string{}, versions: map[string]string{}, env: map[string]string{},
	}
	f.RuntimeDiscovery = RuntimeDiscovery{
		GOOS: "darwin", Home: t.TempDir(),
		getenv: func(key string) string { return f.env[key] },
		LookPath: func(path string, _ []string) (string, error) {
			if _, ok := f.files[path]; ok {
				return path, nil
			}
			return "", exec.ErrNotFound
		},
		stat: func(path string) (os.FileInfo, error) {
			if real, ok := f.files[path]; ok {
				return os.Stat(real)
			}
			return nil, os.ErrNotExist
		},
		glob:    func(string) ([]string, error) { return nil, nil },
		timeout: context.WithTimeout,
		run: func(ctx context.Context, path string, _ []string, args ...string) (string, error) {
			if !slices.Equal(args, []string{"--version"}) {
				t.Fatalf("unexpected inspection %q", args)
			}
			f.calls = append(f.calls, path)
			if f.versions[path] == "hang" {
				<-ctx.Done()
				return "", ctx.Err()
			}
			return f.versions[path], nil
		},
	}
	return f
}

func (f *discoveryFixture) add(t *testing.T, path, version string) {
	t.Helper()
	real := filepath.Join(t.TempDir(), "binary")
	if err := os.WriteFile(real, nil, 0700); err != nil {
		t.Fatal(err)
	}
	f.files[path] = real
	f.versions[path] = version
}

func codexRequestWithPATH(dirs ...string) RuntimeRequest {
	return RuntimeRequest{Name: "codex", Environment: []string{"PATH=" + strings.Join(dirs, string(os.PathListSeparator))}}
}

func TestResolveRuntimeSlowShimThenBundledCodex(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		f := newDiscoveryFixture(t)
		dir := t.TempDir()
		shim := filepath.Join(dir, "codex")
		f.add(t, shim, "hang")
		f.add(t, discoveryTestBundle, "codex-cli 0.155.0")
		start := time.Now()
		got, err := f.Resolve(context.Background(), codexRequestWithPATH(dir))
		want := RuntimeCandidate{Path: discoveryTestBundle, Version: "0.155.0", Source: "auto"}
		if err != nil || got != want || !slices.Equal(f.calls, []string{shim, discoveryTestBundle}) || time.Since(start) != 4*time.Second {
			t.Fatalf("candidate %+v, error %v, calls %q, elapsed %s", got, err, f.calls, time.Since(start))
		}
	})
}

func TestResolveRuntimeRanksDistinctPhysicalExecutables(t *testing.T) {
	f := newDiscoveryFixture(t)
	var dirs, paths []string
	for _, version := range []string{"0.149.0", "0.155.0-alpha.1", "0.155.0", "0.155.0+build.2"} {
		dir := t.TempDir()
		path := filepath.Join(dir, "codex")
		f.add(t, path, version)
		dirs = append(dirs, dir)
		paths = append(paths, path)
	}
	link := filepath.Join(t.TempDir(), "hardlink")
	if err := os.Link(f.files[paths[0]], link); err != nil {
		t.Fatal(err)
	}
	f.files[discoveryTestBundle] = link
	// Visiting this alias would falsely select it as the highest version.
	f.versions[discoveryTestBundle] = "9.9.9"
	got, err := f.Resolve(context.Background(), codexRequestWithPATH(dirs...))
	if err != nil || got.Path != paths[2] || got.Version != "0.155.0" || !slices.Equal(f.calls, paths) {
		t.Fatalf("candidate %+v, error %v, calls %q", got, err, f.calls)
	}
}

func TestResolveRuntimeSharesDeadlineBetweenCandidates(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		f := newDiscoveryFixture(t)
		var dirs []string
		for range 7 {
			dir := t.TempDir()
			f.add(t, filepath.Join(dir, "codex"), "hang")
			dirs = append(dirs, dir)
		}
		start := time.Now()
		_, err := f.Resolve(context.Background(), codexRequestWithPATH(dirs...))
		if !errors.Is(err, context.DeadlineExceeded) || time.Since(start) != 20*time.Second || len(f.calls) != 5 {
			t.Fatalf("error %v, elapsed %s, attempts %d", err, time.Since(start), len(f.calls))
		}
		early := filepath.Join(dirs[0], "codex")
		f.versions[early] = "0.155.0"
		got, err := f.Resolve(context.Background(), codexRequestWithPATH(dirs...))
		if err != nil || got.Path != early {
			t.Fatalf("discarded compatible result at deadline: %+v, %v", got, err)
		}
	})
}

func TestResolveRuntimeOverrideEnvPinAndAuto(t *testing.T) {
	f := newDiscoveryFixture(t)
	dir := t.TempDir()
	path := func(name string) string { return filepath.Join(dir, name) }
	auto, pin, env, override, old := path("codex"), path("pin"), path("env"), path("picker"), path("old")
	for bin, version := range map[string]string{override: "0.150.0", env: "0.151.0", pin: "0.152.0", auto: "0.159.0", old: "0.149.0"} {
		f.add(t, bin, version)
	}
	tests := []struct {
		name, override, env, pin, want, source string
		err                                    error
	}{
		{"picker", override, env, pin, override, "override", nil},
		{"env", "", env, pin, env, "env", nil},
		{"pin", "", "", pin, pin, "pin", nil},
		{"auto", "", "", "", auto, "auto", nil},
		{"clear pin", "auto", "", old, auto, "auto", nil},
		{"missing pin", "", "", path("missing"), "", "pin", exec.ErrNotFound},
		{"incompatible pin", "", "", old, old, "pin", ErrRuntimeIncompatible},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			f.env["AGENTD_CODEX_BIN"] = tc.env
			f.calls = nil
			req := codexRequestWithPATH(dir)
			req.Override, req.Pin = tc.override, tc.pin
			got, err := f.Resolve(context.Background(), req)
			if !errors.Is(err, tc.err) || got.Path != tc.want || got.Source != tc.source {
				t.Fatalf("candidate %+v, error %v; want path %q, source %q, error %v", got, err, tc.want, tc.source, tc.err)
			}
			if tc.source != "auto" && slices.Contains(f.calls, auto) {
				t.Fatalf("auto probed during explicit selection: %q", f.calls)
			}
		})
	}
}

func TestResolveRuntimeFiltersWebSocketCapabilitiesBeforeRanking(t *testing.T) {
	f := newDiscoveryFixture(t)
	dir := t.TempDir()
	shim := filepath.Join(dir, "codex")
	f.add(t, shim, "0.199.0")
	f.add(t, discoveryTestBundle, "0.155.0")
	probeVersion := f.run
	f.run = func(ctx context.Context, path string, env []string, args ...string) (string, error) {
		if slices.Equal(args, []string{"app-server", "--help"}) {
			if path == shim {
				return "--listen", nil
			}
			return "--listen --ws-auth --ws-token-file", nil
		}
		return probeVersion(ctx, path, env, args...)
	}
	req := codexRequestWithPATH(dir)
	req.Transport = "ws"
	got, err := f.Resolve(context.Background(), req)
	if err != nil || got.Path != discoveryTestBundle {
		t.Fatalf("candidate %+v, error %v", got, err)
	}
}

func TestResolveRuntimeContinuesAfterBlockedFilesystemLookup(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		f := newDiscoveryFixture(t)
		dir := t.TempDir()
		shim := filepath.Join(dir, "codex")
		release := make(chan struct{})
		defer close(release)
		lookup := f.LookPath
		f.LookPath = func(path string, env []string) (string, error) {
			if path == shim {
				<-release
			}
			return lookup(path, env)
		}
		f.add(t, discoveryTestBundle, "0.155.0")
		start := time.Now()
		got, err := f.Resolve(context.Background(), codexRequestWithPATH(dir))
		if err != nil || got.Path != discoveryTestBundle || time.Since(start) != 4*time.Second {
			t.Fatalf("filesystem lookup stalled discovery: %+v, %v, %s", got, err, time.Since(start))
		}
	})
}

func TestRepairCodexDoesNotPersistEnvironmentOverride(t *testing.T) {
	dir := t.TempDir()
	bin := filepath.Join(dir, "codex")
	script := "#!/bin/sh\necho 'codex-cli 0.155.0'\n"
	if runtime.GOOS == "windows" {
		bin += ".cmd"
		script = "@echo off\r\necho codex-cli 0.155.0\r\n"
	}
	if err := os.WriteFile(bin, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("AGENTD_CODEX_BIN", bin)
	cfg := filepath.Join(dir, "config.json")
	original := `{"codex":{"bin":"saved-bin"},"app_server":{"transport":"local"}}`
	if err := os.WriteFile(cfg, []byte(original), 0600); err != nil {
		t.Fatal(err)
	}
	resolved, changed, err := RepairCodexBin(cfg)
	if err != nil || changed || resolved != bin {
		t.Fatalf("temporary override: %q, %t, %v", resolved, changed, err)
	}
	raw, err := os.ReadFile(cfg)
	if err != nil || string(raw) != original {
		t.Fatal("repair persisted a temporary environment override")
	}
}

func TestWindowsCandidatesUseProfileWithoutAppData(t *testing.T) {
	f := newDiscoveryFixture(t)
	f.GOOS = "windows"
	for _, tc := range []struct{ name, path string }{
		{"agy", "AppData/Local/Programs/Antigravity/bin/agy.exe"},
		{"claude", "AppData/Roaming/npm/node_modules/@anthropic-ai/claude-code/bin/claude.exe"},
		{"codex", "AppData/Local/Microsoft/WindowsApps/codex.exe"},
	} {
		paths := f.candidates(RuntimeRequest{Name: tc.name})
		if !slices.Contains(paths, filepath.Join(f.Home, tc.path)) {
			t.Fatalf("%s missing %s", tc.name, tc.path)
		}
	}
}
