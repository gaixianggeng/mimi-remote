package setup

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/agybridge"
	"github.com/gaixianggeng/mimi-remote/internal/appserver"
	"github.com/gaixianggeng/mimi-remote/internal/claudebridge"
	"github.com/gaixianggeng/mimi-remote/internal/cliinspect"
	"github.com/gaixianggeng/mimi-remote/internal/config"
)

// RuntimeRequest describes one read-only CLI inspection. Environment is the
// child environment used by the adapter. Pin is the user's saved binary path.
type RuntimeRequest struct {
	Name, Override, Pin       string
	Environment               []string
	MinimumVersion, Transport string
}

func ClaudeRuntime(cfg config.ClaudeConfig, minimum string, environment []string) RuntimeRequest {
	return RuntimeRequest{Name: "claude", Pin: cfg.Env[claudeBinaryEnvKey], MinimumVersion: minimum, Environment: environment}
}

func AgyRuntime(cfg config.AgyConfig, minimum string, environment []string) RuntimeRequest {
	return RuntimeRequest{Name: "agy", Pin: cfg.Env[agybridge.AgyBinaryEnvKey], MinimumVersion: minimum, Environment: environment}
}

func CodexRuntime(cfg config.CodexConfig, transport string) RuntimeRequest {
	return RuntimeRequest{Name: "codex", Pin: cfg.Bin, Transport: transport, Environment: appserver.ManagedEnvironment(cfg.Env)}
}

type RuntimeCandidate struct {
	Path, Version, Source string
}

var (
	ErrRuntimeVersion      = errors.New("unrecognized CLI version")
	ErrRuntimeIncompatible = errors.New("incompatible CLI")
)

// RuntimeDiscovery describes the host used for an inspection. Use NewRuntimeDiscovery
// for platform defaults, or restrict executable lookup to a sandbox.
type RuntimeDiscovery struct {
	GOOS, Home string
	getenv     func(string) string
	LookPath   func(string, []string) (string, error)
	Stat       func(string) (os.FileInfo, error)
	sameFile   func(os.FileInfo, os.FileInfo) bool
	glob       func(string) ([]string, error)
	run        func(context.Context, string, []string, ...string) (string, error)
	timeout    func(context.Context, time.Duration) (context.Context, context.CancelFunc)
}

func NewRuntimeDiscovery() RuntimeDiscovery {
	home, _ := os.UserHomeDir()
	return RuntimeDiscovery{
		GOOS: runtime.GOOS, Home: home, getenv: os.Getenv, LookPath: hostLookPath,
		Stat: os.Stat, sameFile: os.SameFile, glob: filepath.Glob, run: cliinspect.Run, timeout: context.WithTimeout,
	}
}

// ResolveRuntime only inspects executables. It never changes configuration,
// launches a service, or performs an authentication operation.
func ResolveRuntime(ctx context.Context, request RuntimeRequest) (RuntimeCandidate, error) {
	return NewRuntimeDiscovery().Resolve(ctx, request)
}

func (d RuntimeDiscovery) Resolve(parent context.Context, req RuntimeRequest) (RuntimeCandidate, error) {
	if err := parent.Err(); err != nil {
		return RuntimeCandidate{}, err
	}
	ctx, cancel := d.timeout(parent, 20*time.Second)
	defer cancel()
	var key string
	switch req.Name {
	case "codex":
		key = "AGENTD_CODEX_BIN"
		req.MinimumVersion = appserver.MinimumCodexVersion
	case "claude":
		key = claudeBinaryEnvKey
	case "agy":
		key = agybridge.AgyBinaryEnvKey
	default:
		return RuntimeCandidate{}, fmt.Errorf("unknown runtime %q", req.Name)
	}

	envOverride := strings.TrimSpace(d.getenv(key))
	source := "auto"
	path := strings.TrimSpace(req.Override)
	if path == "auto" {
		path, req.Pin = "", ""
	}
	switch {
	case path != "":
		source = "override"
	case envOverride != "":
		path, source = envOverride, "env"
	case strings.TrimSpace(req.Pin) != "" && req.Pin != req.Name:
		path, source = strings.TrimSpace(req.Pin), "pin"
	}
	paths := slices.Values([]string{path})
	if source == "auto" {
		paths = d.autoPaths(ctx, req)
	}
	var best, failed RuntimeCandidate
	var seen []os.FileInfo
	failure := error(exec.ErrNotFound)
	deadline, _ := ctx.Deadline()
	for path := range paths {
		if ctx.Err() != nil || !time.Now().Before(deadline) {
			break
		}
		candidateCtx, stop := d.timeout(ctx, 4*time.Second)
		file, err := d.uniqueExecutable(candidateCtx, req, path, seen)
		if err != nil || file.path == "" {
			if timedOut := candidateCtx.Err(); timedOut != nil && failed.Path == "" {
				failure = timedOut
			} else if source != "auto" && err != nil {
				failure = err
			}
			stop()
			continue
		}
		if file.info != nil {
			seen = append(seen, file.info)
		}
		candidate := RuntimeCandidate{Path: file.path, Source: source}
		candidate.Version, err = d.inspect(candidateCtx, req, file.path)
		if candidateCtx.Err() != nil {
			err = candidateCtx.Err()
		}
		stop()
		if err != nil {
			if failed.Path == "" || (candidate.Version != "" && appserver.CompareCodexVersions(candidate.Version, failed.Version) > 0) {
				failed, failure = candidate, err
			}
			continue
		}
		if best.Path == "" || appserver.CompareCodexVersions(candidate.Version, best.Version) > 0 {
			best = candidate
		}
	}
	if err := parent.Err(); err != nil {
		return RuntimeCandidate{Source: source}, err
	}
	if best.Path != "" {
		return best, nil
	}
	if !time.Now().Before(deadline) {
		return RuntimeCandidate{Source: source}, context.DeadlineExceeded
	}
	failed.Source = source
	return failed, fmt.Errorf("%s (%s): %w", req.Name, source, failure)
}

func (d RuntimeDiscovery) executable(req RuntimeRequest, path string) (string, error) {
	// npm also installs .ps1 and extensionless launchers. Find their native
	// sibling before checking whether the script itself is executable.
	if req.Name == "claude" && d.GOOS == "windows" && filepath.IsAbs(path) {
		if native, err := d.nativeClaude(path); err == nil {
			path = native
		}
	}
	resolved, err := d.LookPath(path, req.Environment)
	if err != nil {
		return "", err
	}
	if req.Name == "claude" && d.GOOS == "windows" {
		return d.nativeClaude(resolved)
	}
	return resolved, nil
}

// Windows may reopen a file to read its ID in SameFile. Resolve the ID under
// this candidate's deadline before retaining it for comparisons with later paths.
func (d RuntimeDiscovery) uniqueExecutable(ctx context.Context, req RuntimeRequest, path string, seen []os.FileInfo) (executableFile, error) {
	return cliinspect.Filesystem(ctx, func() (executableFile, error) {
		file, err := d.lookupFile(req, path)
		if err != nil {
			return executableFile{}, err
		}
		if !d.sameFile(file.info, file.info) {
			file.info = nil // still inspect launchable aliases without an accessible file ID
			return file, nil
		}
		for _, prior := range seen {
			if d.sameFile(prior, file.info) {
				return executableFile{}, nil
			}
		}
		return file, nil
	})
}

func (d RuntimeDiscovery) inspect(ctx context.Context, req RuntimeRequest, path string) (string, error) {
	output, err := d.run(ctx, path, req.Environment, "--version")
	if err != nil {
		return "", err
	}
	parse, compare := claudebridge.ParseVersion, claudebridge.Compare
	if req.Name == "codex" {
		parse, compare = appserver.ParseCodexVersion, appserver.CompareCodexVersions
	}
	version, ok := parse(output)
	if !ok {
		return "", ErrRuntimeVersion
	}
	if (req.Name != "codex" && !claudebridge.IsComparable(version)) ||
		(req.MinimumVersion != "" && compare(version, req.MinimumVersion) < 0) {
		return version, fmt.Errorf("%w: %s (minimum %s)", ErrRuntimeIncompatible, version, req.MinimumVersion)
	}
	if req.Name == "codex" && req.Transport == "ws" {
		help, err := d.run(ctx, path, req.Environment, "app-server", "--help")
		if err != nil {
			return version, err
		}
		for _, flag := range []string{"--listen", "--ws-auth", "--ws-token-file"} {
			if !strings.Contains(help, flag) {
				return version, fmt.Errorf("%w: missing %s", ErrRuntimeIncompatible, flag)
			}
		}
	}
	return version, nil
}
