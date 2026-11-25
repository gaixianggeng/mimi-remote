package setup

import (
	"context"
	"iter"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/claudebridge"
	"github.com/gaixianggeng/mimi-remote/internal/cliinspect"
)

func (d RuntimeDiscovery) childEnvValue(env []string, name string) (string, bool) {
	for i := len(env) - 1; i >= 0; i-- {
		key, value, found := strings.Cut(env[i], "=")
		if found && (key == name || (d.GOOS == "windows" && strings.EqualFold(key, name))) {
			return value, true
		}
	}
	return "", false
}

func (d RuntimeDiscovery) envValue(env []string, name string) string {
	if value, ok := d.childEnvValue(env, name); ok {
		return value
	}
	return d.getenv(name)
}

// A service account can have USERPROFILE without the shell's AppData variables.
func (d RuntimeDiscovery) appData(env []string, key, folder string) string {
	if path := d.envValue(env, key); path != "" {
		return path
	}
	if d.Home != "" {
		return filepath.Join(d.Home, "AppData", folder)
	}
	return ""
}

func (d RuntimeDiscovery) candidates(req RuntimeRequest) []string {
	name := req.Name
	var paths []string
	add := func(dir string, suffix ...string) {
		if dir != "" {
			paths = append(paths, filepath.Join(append([]string{dir}, suffix...)...))
		}
	}
	// Check every absolute PATH entry so an old shim can't hide a newer CLI.
	for _, dir := range filepath.SplitList(d.envValue(req.Environment, "PATH")) {
		if filepath.IsAbs(dir) {
			add(dir, name)
			if d.GOOS == "windows" {
				add(dir, name+".exe")
				add(dir, name+".cmd")
				add(dir, name+".bat")
				add(dir, name+".com")
			}
		}
	}
	if d.GOOS == "windows" {
		exe := name + ".exe"
		local := d.appData(req.Environment, "LOCALAPPDATA", "Local")
		roaming := d.appData(req.Environment, "APPDATA", "Roaming")
		product := map[string]string{"codex": "Codex", "agy": "Antigravity", "claude": "Claude"}[name]
		add(local, "Microsoft", "WindowsApps", exe)
		add(local, "Programs", product, exe)
		add(local, "Programs", product, "bin", exe)
		add(local, product, exe)
		add(roaming, product, exe)
		for _, base := range []string{local, roaming} {
			add(base, "npm", name+".cmd")
			add(base, "npm", exe)
		}
		if name == "claude" {
			add(roaming, "npm", "node_modules", "@anthropic-ai", "claude-code", "bin", exe)
		}
		add(d.Home, ".local", "bin", exe)
		add(d.Home, "scoop", "shims", exe)
		add(local, "Microsoft", "WinGet", "Links", exe)
		return paths
	}
	if d.GOOS == "darwin" && name == "codex" {
		add(d.envValue(req.Environment, "CODEX_INSTALL_DIR"), name)
		paths = append(paths, darwinCodexCandidates(d.Home)...)
		// Desktop can install under the configured Codex HOME while the
		// service account owns a different home and application bundles.
		if home, ok := d.childEnvValue(req.Environment, "HOME"); ok && filepath.IsAbs(home) && home != d.Home {
			add(home, ".local", "bin", name)
		}
	} else {
		if d.GOOS == "darwin" || name == "agy" {
			add("/opt/homebrew/bin", name)
			add("/usr/local/bin", name)
		}
		add(d.Home, ".local", "bin", name)
		add(d.Home, ".npm-global", "bin", name)
		add(d.Home, ".local", "share", "mise", "shims", name)
		add(d.Home, ".local", "share", "mise", "installs", name, "latest", "bin", name)
	}
	add(d.Home, ".volta", "bin", name)
	add(d.envValue(req.Environment, "VOLTA_HOME"), "bin", name)
	add(d.envValue(req.Environment, "NPM_CONFIG_PREFIX"), "bin", name)
	return paths
}

// Probe concrete paths first. A stalled version-manager directory must not
// consume the budget before PATH and desktop bundles have been inspected.
func (d RuntimeDiscovery) autoPaths(ctx context.Context, req RuntimeRequest) iter.Seq[string] {
	return func(yield func(string) bool) {
		for _, path := range d.candidates(req) {
			if !yield(path) {
				return
			}
		}
		if d.Home == "" || d.GOOS == "windows" {
			return
		}
		for _, prefix := range []string{".nvm/versions/node/*/bin", ".local/share/fnm/node-versions/*/installation/bin",
			"Library/Application Support/fnm/node-versions/*/installation/bin", ".local/share/mise/installs/node/*/bin"} {
			if ctx.Err() != nil {
				return
			}
			globCtx, cancel := d.timeout(ctx, 4*time.Second)
			matches, _ := cliinspect.Bounded(globCtx, func() ([]string, error) { return d.glob(filepath.Join(d.Home, prefix, req.Name)) })
			cancel()
			for _, path := range matches {
				if !yield(path) {
					return
				}
			}
		}
	}
}

type executableFile struct {
	path string
	info os.FileInfo
}

func (d RuntimeDiscovery) lookupFile(req RuntimeRequest, path string) (executableFile, error) {
	resolved, err := d.executable(req, path)
	if err != nil {
		return executableFile{}, err
	}
	info, err := d.Stat(resolved)
	if err != nil {
		return executableFile{}, err
	}
	if !info.Mode().IsRegular() && !(info.Mode().Type() == os.ModeIrregular && d.windowsAlias(req, resolved)) {
		return executableFile{}, exec.ErrNotFound
	}
	return executableFile{path: resolved, info: info}, nil
}

// LookupExecutable rechecks the filesystem entry of a selected runtime without
// launching it. Status polling uses the same Windows alias rules as discovery.
func (d RuntimeDiscovery) LookupExecutable(ctx context.Context, req RuntimeRequest, path string) (string, error) {
	ctx, cancel := d.timeout(ctx, 4*time.Second)
	defer cancel()
	file, err := cliinspect.Bounded(ctx, func() (executableFile, error) { return d.lookupFile(req, path) })
	return file.path, err
}

func (d RuntimeDiscovery) windowsAlias(req RuntimeRequest, path string) bool {
	local := d.appData(req.Environment, "LOCALAPPDATA", "Local")
	return d.GOOS == "windows" && local != "" && strings.EqualFold(filepath.Ext(path), ".exe") &&
		strings.EqualFold(filepath.Dir(path), filepath.Join(local, "Microsoft", "WindowsApps"))
}

func hostLookPath(path string, env []string) (string, error) {
	// exec.LookPath accepts Windows App Execution Aliases. The version probe
	// subsequently verifies that the service account can actually start them.
	if runtime.GOOS == "windows" && filepath.IsAbs(path) {
		return exec.LookPath(path)
	}
	resolved, err := claudebridge.LookPathIn(path, env)
	if err != nil {
		return "", err
	}
	return filepath.Abs(resolved)
}

// The SDK needs a native Claude executable, even when npm exposes a .cmd shim.
func (d RuntimeDiscovery) nativeClaude(path string) (string, error) {
	switch strings.ToLower(filepath.Ext(path)) {
	case ".exe":
		return path, nil
	case ".cmd", ".bat", ".ps1", "":
		info, err := d.Stat(path)
		base := filepath.Base(path)
		if err != nil || !info.Mode().IsRegular() || !strings.EqualFold(strings.TrimSuffix(base, filepath.Ext(base)), "claude") {
			return "", exec.ErrNotFound
		}
		native := filepath.Join(filepath.Dir(path), "node_modules", "@anthropic-ai", "claude-code", "bin", "claude.exe")
		if info, err := d.Stat(native); err == nil && info.Mode().IsRegular() {
			return native, nil
		}
	}
	return "", exec.ErrNotFound
}
