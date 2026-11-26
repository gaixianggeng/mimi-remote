package setup

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"sync"
	"testing"
	"testing/synctest"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config/configtest"
)

const discoveryTestBundle = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"

type discoveryFixture struct {
	RuntimeDiscovery
	files    map[string]string // virtual candidate path to its backing file
	versions map[string]string
	env      map[string]string
	mu       sync.Mutex
	probes   []string
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
		sameFile: os.SameFile,
		Stat: func(path string) (os.FileInfo, error) {
			if real, ok := f.files[path]; ok {
				return os.Stat(real)
			}
			return nil, os.ErrNotExist
		},
		glob:    func(string) ([]string, error) { return nil, nil },
		timeout: context.WithTimeout,
		run: func(ctx context.Context, path string, _ RuntimeRequest, args ...string) (string, error) {
			if !slices.Equal(args, []string{"--version"}) {
				t.Fatalf("unexpected inspection %q", args)
			}
			f.mu.Lock()
			f.probes = append(f.probes, path)
			version := f.versions[path]
			f.mu.Unlock()
			if version == "hang" {
				<-ctx.Done()
				return "", ctx.Err()
			}
			return version, nil
		},
	}
	return f
}

func (f *discoveryFixture) calls() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return slices.Clone(f.probes)
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
		if err != nil || got != want || !slices.Equal(f.calls(), []string{shim, discoveryTestBundle}) || time.Since(start) != 4*time.Second {
			t.Fatalf("candidate %+v, error %v, calls %q, elapsed %s", got, err, f.calls(), time.Since(start))
		}
	})
}

func TestResolveRuntimeRanksDistinctPhysicalExecutables(t *testing.T) {
	f := newDiscoveryFixture(t)
	var dirs, paths []string
	for _, version := range []string{"0.149.0", "0.155.0-alpha.1", "0.155.0", "0.155.0+build.2"} {
		dir := t.TempDir()
		path := filepath.Join(dir, "codex")
		f.add(t, path, "codex-cli "+version)
		dirs = append(dirs, dir)
		paths = append(paths, path)
	}
	link := filepath.Join(t.TempDir(), "hardlink")
	if err := os.Link(f.files[paths[0]], link); err != nil {
		t.Fatal(err)
	}
	f.files[discoveryTestBundle] = link
	// Visiting this alias would falsely select it as the highest version.
	f.versions[discoveryTestBundle] = "codex-cli 9.9.9"
	got, err := f.Resolve(context.Background(), codexRequestWithPATH(dirs...))
	if err != nil || got.Path != paths[2] || got.Version != "0.155.0" || !slices.Equal(f.calls(), paths) {
		t.Fatalf("candidate %+v, error %v, calls %q", got, err, f.calls())
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
		if !errors.Is(err, context.DeadlineExceeded) || time.Since(start) != 20*time.Second || len(f.calls()) != 5 {
			t.Fatalf("error %v, elapsed %s, attempts %d", err, time.Since(start), len(f.calls()))
		}
		early := filepath.Join(dirs[0], "codex")
		synctest.Wait()
		f.versions[early] = "codex-cli 0.155.0"
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		got, err := f.Resolve(ctx, codexRequestWithPATH(dirs...))
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
		f.add(t, bin, "codex-cli "+version)
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
		{"missing pin", "", "", path("missing"), "", "pin", os.ErrNotExist},
		{"incompatible pin", "", "", old, old, "pin", ErrRuntimeIncompatible},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			f.env["AGENTD_CODEX_BIN"] = tc.env
			f.probes = nil
			req := codexRequestWithPATH(dir)
			req.Override, req.Pin = tc.override, tc.pin
			got, err := f.Resolve(context.Background(), req)
			if !errors.Is(err, tc.err) || got.Path != tc.want || got.Source != tc.source {
				t.Fatalf("candidate %+v, error %v; want path %q, source %q, error %v", got, err, tc.want, tc.source, tc.err)
			}
			if tc.source != "auto" && slices.Contains(f.calls(), auto) {
				t.Fatalf("auto probed during explicit selection: %q", f.calls())
			}
		})
	}
}

func TestResolveRuntimeFiltersWebSocketCapabilitiesBeforeRanking(t *testing.T) {
	f := newDiscoveryFixture(t)
	dir := t.TempDir()
	shim := filepath.Join(dir, "codex")
	f.add(t, shim, "codex-cli 0.199.0")
	f.add(t, discoveryTestBundle, "codex-cli 0.155.0")
	probeVersion := f.run
	f.run = func(ctx context.Context, path string, req RuntimeRequest, args ...string) (string, error) {
		if slices.Equal(args, []string{"app-server", "--help"}) {
			if path == shim {
				return "--listen", nil
			}
			return "--listen --ws-auth --ws-token-file", nil
		}
		return probeVersion(ctx, path, req, args...)
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
		f.add(t, discoveryTestBundle, "codex-cli 0.155.0")
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
	configtest.WritePrivateFile(t, cfg, []byte(original))
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

func TestResolveRuntimeBoundsFileIdentityLookup(t *testing.T) {
	for _, count := range []int{1, 6} {
		synctest.Test(t, func(t *testing.T) {
			f := newDiscoveryFixture(t)
			f.GOOS = "windows"
			dir := t.TempDir()
			first := filepath.Join(dir, "codex.exe")
			f.add(t, first, "codex-cli 0.150.0")
			dirs := []string{dir}
			offline := filepath.Join(t.TempDir(), "offline")
			if err := os.WriteFile(offline, nil, 0700); err != nil {
				t.Fatal(err)
			}
			for range count {
				dir := t.TempDir()
				f.files[filepath.Join(dir, "codex.exe")] = offline
				dirs = append(dirs, dir)
			}
			dir = t.TempDir()
			last := filepath.Join(dir, "codex.exe")
			f.add(t, last, "codex-cli 0.155.0")
			dirs = append(dirs, dir)
			release := make(chan struct{})
			defer close(release)
			f.sameFile = func(prior, info os.FileInfo) bool {
				if info.Name() == "offline" {
					<-release
				}
				return os.SameFile(prior, info)
			}
			start := time.Now()
			got, err := f.Resolve(context.Background(), codexRequestWithPATH(dirs...))
			want, elapsed := last, 4*time.Second
			if count > 1 {
				want, elapsed = first, 20*time.Second
			}
			if err != nil || got.Path != want || time.Since(start) != elapsed {
				t.Fatalf("%d stalled file identities: %+v, %v after %s", count, got, err, time.Since(start))
			}
		})
	}
}

func TestResolveRuntimeProbesWindowsAliasOnceWithoutFileID(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		f := newDiscoveryFixture(t)
		f.GOOS = "windows"
		dir := filepath.Join(f.Home, "AppData", "Local", "Microsoft", "WindowsApps")
		alias := filepath.Join(dir, "codex.exe")
		f.add(t, alias, "hang")
		f.sameFile = func(os.FileInfo, os.FileInfo) bool { return false }
		lookup := f.LookPath
		f.LookPath = func(path string, env []string) (string, error) {
			if path == filepath.Join(dir, "codex") {
				return alias, nil
			}
			return lookup(path, env)
		}
		fallback := filepath.Join(f.Home, "scoop", "shims", "codex.exe")
		f.add(t, fallback, "codex-cli 0.155.0")
		start := time.Now()
		got, err := f.Resolve(context.Background(), codexRequestWithPATH(dir, dir))
		if err != nil || got.Path != fallback || time.Since(start) != 4*time.Second || !slices.Equal(f.calls(), []string{alias, fallback}) {
			t.Fatalf("repeated Windows alias: %+v, %v, calls=%v, elapsed=%s", got, err, f.calls(), time.Since(start))
		}
	})
}

func TestMigrationPreservesCodexPinAfterProbeTimeout(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		f := newDiscoveryFixture(t)
		const original = `{"codex":{"bin":"pinned-codex"},"app_server":{"transport":"ws","managed":true}}`
		cfg := filepath.Join(t.TempDir(), "config.json")
		configtest.WritePrivateFile(t, cfg, []byte(original))
		f.add(t, "pinned-codex", "hang")
		f.add(t, discoveryTestBundle, "codex-cli 0.155.0")
		prev := resolveMigrationCodexBin
		defer func() { resolveMigrationCodexBin = prev }()
		resolveMigrationCodexBin = func(pin string) (string, error) {
			candidate, err := f.repairCodex(context.Background(), RuntimeRequest{Name: "codex", Pin: pin})
			return candidate.Path, err
		}
		err := MigrateAppServerToSharedLocalWithPreflight(context.Background(), cfg, func(context.Context, string, map[string]string) error {
			t.Fatal("migration proceeded after pin timeout")
			return nil
		})
		if !errors.Is(err, context.DeadlineExceeded) || !slices.Equal(f.calls(), []string{"pinned-codex"}) {
			t.Fatalf("after timeout: probes %q, error %v", f.calls(), err)
		}
		if raw, err := os.ReadFile(cfg); err != nil || string(raw) != original {
			t.Fatalf("migration changed config after pin timeout, read error %v", err)
		}
	})
}

func TestResolveRuntimeContinuesAfterBlockedRunnerStartup(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		f := newDiscoveryFixture(t)
		dir := t.TempDir()
		shim := filepath.Join(dir, "codex")
		f.add(t, shim, "codex-cli 0.199.0")
		f.add(t, discoveryTestBundle, "codex-cli 0.155.0")
		run := f.run
		release := make(chan struct{})
		defer close(release)
		f.run = func(ctx context.Context, path string, req RuntimeRequest, args ...string) (string, error) {
			if path == shim {
				<-release // startup does not observe the context
				return "", ctx.Err()
			}
			return run(ctx, path, req, args...)
		}
		start := time.Now()
		got, err := f.Resolve(context.Background(), codexRequestWithPATH(dir))
		if err != nil || got.Path != discoveryTestBundle || time.Since(start) != 4*time.Second {
			t.Fatalf("blocked runner: %+v, %v after %s", got, err, time.Since(start))
		}
	})
}

func TestResolveRuntimeRejectsUnrelatedVersionBanner(t *testing.T) {
	f := newDiscoveryFixture(t)
	picker := filepath.Join(t.TempDir(), "codex")
	f.add(t, picker, "other-tool 42.1.0")
	got, err := f.Resolve(context.Background(), RuntimeRequest{Name: "codex", Override: picker, Transport: "local"})
	if !errors.Is(err, ErrRuntimeVersion) || got.Path != picker || got.Source != "override" {
		t.Fatalf("picked an unrelated CLI: %+v, %v", got, err)
	}
}

func TestResolveRuntimeVersionWithWrapperDiagnostics(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("uses a POSIX wrapper")
	}
	for _, tc := range []struct {
		name, banner, minimum, want string
		err                         error
	}{
		{"codex", "codex-cli 0.155.0", "", "0.155.0", nil},
		{"claude", "2.1.0 (Claude Code)", "2.1.100", "2.1.0", ErrRuntimeIncompatible},
		{"claude", "", "", "", ErrRuntimeVersion},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), tc.name)
			writeExecutableFixture(t, path, "echo 'wrapper 24.1.0' >&2\necho '"+tc.banner+"'\n")
			got, err := ResolveRuntime(context.Background(), RuntimeRequest{
				Name: tc.name, Override: path, MinimumVersion: tc.minimum, Transport: "local",
			})
			if !errors.Is(err, tc.err) || got.Version != tc.want {
				t.Fatalf("selected version %q, error %v; want %q, %v", got.Version, err, tc.want, tc.err)
			}
		})
	}
}

func TestResolveCodexUsesConfiguredRuntimeHome(t *testing.T) {
	f := newDiscoveryFixture(t)
	home := t.TempDir()
	path := filepath.Join(home, ".local", "bin", "codex")
	f.add(t, path, "codex-cli 0.155.0")
	req := RuntimeRequest{Name: "codex", Transport: "local", Environment: []string{"HOME=" + home, "PATH="}}
	got, err := f.Resolve(context.Background(), req)
	if err != nil || got.Path != path || got.Source != "auto" {
		t.Fatalf("configured runtime home: %+v, %v", got, err)
	}
	serviceBundle := filepath.Join(f.Home, "Applications", "ChatGPT.app", "Contents", "Resources", "codex-cli", "bin", "codex")
	f.add(t, serviceBundle, "codex-cli 0.156.0")
	if got, err = f.Resolve(context.Background(), req); err != nil || got.Path != serviceBundle {
		t.Fatalf("service account bundle: %+v, %v", got, err)
	}
}

func TestMigrationPreservesInaccessibleCodexPin(t *testing.T) {
	f := newDiscoveryFixture(t)
	pin := filepath.Join(t.TempDir(), "private", "codex")
	f.add(t, discoveryTestBundle, "codex-cli 0.155.0")
	// Host lookup can report ErrNotFound for an inaccessible parent directory.
	stat := f.Stat
	f.Stat = func(path string) (os.FileInfo, error) {
		if path == pin {
			return nil, &os.PathError{Op: "stat", Path: pin, Err: os.ErrPermission}
		}
		return stat(path)
	}
	cfg := filepath.Join(t.TempDir(), "config.json")
	original, err := json.Marshal(map[string]any{"codex": map[string]string{"bin": pin}, "app_server": map[string]any{"transport": "ws", "managed": true}})
	if err != nil {
		t.Fatal(err)
	}
	configtest.WritePrivateFile(t, cfg, original)
	prev := resolveMigrationCodexBin
	t.Cleanup(func() { resolveMigrationCodexBin = prev })
	resolveMigrationCodexBin = func(pin string) (string, error) {
		got, err := f.repairCodex(context.Background(), RuntimeRequest{Name: "codex", Pin: pin})
		return got.Path, err
	}
	err = MigrateAppServerToSharedLocalWithPreflight(context.Background(), cfg, func(context.Context, string, map[string]string) error {
		t.Fatal("preflight attempted for inaccessible pin")
		return nil
	})
	raw, readErr := os.ReadFile(cfg)
	if !errors.Is(err, os.ErrPermission) || readErr != nil || !bytes.Equal(raw, original) || len(f.calls()) != 0 {
		t.Fatalf("inaccessible pin: migration=%v, read=%v, changed=%t, probes=%v", err, readErr, !bytes.Equal(raw, original), f.calls())
	}
}

func TestManagedSetupDefersAutomaticCodexInspection(t *testing.T) {
	f := newDiscoveryFixture(t)
	f.GOOS = "windows"
	dir := t.TempDir()
	bin := filepath.Join(dir, "codex.exe")
	f.add(t, bin, "codex-cli 0.149.0")
	f.env["PATH"] = dir
	if err := f.preflightManagedCodex(context.Background(), ""); err != nil || len(f.calls()) != 0 {
		t.Fatalf("automatic setup inspected old Codex: probes=%q, err=%v", f.calls(), err)
	}
	if err := f.preflightManagedCodex(context.Background(), bin); !errors.Is(err, ErrRuntimeIncompatible) || !slices.Equal(f.calls(), []string{bin}) {
		t.Fatalf("explicit old Codex: probes=%q, err=%v", f.calls(), err)
	}
}

func TestRepairKeepsAmbiguousWindowsPin(t *testing.T) {
	f := newDiscoveryFixture(t)
	f.GOOS = "windows"
	dir := t.TempDir()
	pin := filepath.Join(dir, "pinned")
	f.env["PATH"] = dir
	f.add(t, filepath.Join(dir, "codex.exe"), "codex-cli 0.155.0")
	// A failed PATHEXT search and an absent literal "pinned" do not prove that
	// its "pinned.exe" sibling was removed.
	got, err := f.repairCodex(context.Background(), RuntimeRequest{Name: "codex", Pin: pin})
	if err == nil || got.Source != "pin" || len(f.calls()) != 0 {
		t.Fatalf("ambiguous Windows pin: %+v, %v, probes=%v", got, err, f.calls())
	}
}
