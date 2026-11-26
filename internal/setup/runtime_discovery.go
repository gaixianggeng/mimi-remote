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
	run        func(context.Context, string, RuntimeRequest, ...string) (string, error)
	timeout    func(context.Context, time.Duration) (context.Context, context.CancelFunc)
}

func NewRuntimeDiscovery() RuntimeDiscovery {
	home, _ := os.UserHomeDir()
	return RuntimeDiscovery{
		GOOS: runtime.GOOS, Home: home, getenv: os.Getenv, LookPath: hostLookPath,
		Stat: os.Stat, sameFile: os.SameFile, glob: filepath.Glob, run: runRuntimeProbe, timeout: context.WithTimeout,
	}
}

// ResolveRuntime only inspects executables. It never changes configuration,
// launches a service, or performs an authentication operation.
func ResolveRuntime(ctx context.Context, request RuntimeRequest) (RuntimeCandidate, error) {
	return NewRuntimeDiscovery().Resolve(ctx, request)
}

func (d RuntimeDiscovery) Resolve(parent context.Context, req RuntimeRequest) (RuntimeCandidate, error) {
	return d.resolve(parent, req, nil)
}

// observe runs on the resolver goroutine, in attempt order, after the bounded
// probe returns. Other discovery callers do not collect diagnostic paths.
func (d RuntimeDiscovery) resolve(parent context.Context, req RuntimeRequest, observe func(path, version, outcome string)) (RuntimeCandidate, error) {
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
	var seen []executableFile
	failure := error(exec.ErrNotFound)
	deadline, _ := ctx.Deadline()
	for path := range paths {
		if ctx.Err() != nil || !time.Now().Before(deadline) {
			break
		}
		candidateCtx, stop := d.timeout(ctx, 4*time.Second)
		file, err := d.uniqueExecutable(candidateCtx, req, path, seen)
		if err != nil || file.path == "" {
			if observe != nil && err != nil {
				outcome := "unusable"
				switch {
				case candidateCtx.Err() != nil:
					outcome = "timeout"
				case errors.Is(err, exec.ErrNotFound) || errors.Is(err, os.ErrNotExist):
					outcome = "missing"
				}
				observe(path, "", outcome)
			}
			if timedOut := candidateCtx.Err(); timedOut != nil && failed.Path == "" {
				failure = timedOut
			} else if source != "auto" && err != nil {
				failure = err
			}
			stop()
			continue
		}
		seen = append(seen, file)
		candidate := RuntimeCandidate{Path: file.path, Source: source}
		candidate.Version, err = cliinspect.Bounded(candidateCtx, func() (string, error) {
			return d.inspect(candidateCtx, req, file.path)
		})
		if candidateCtx.Err() != nil {
			err = candidateCtx.Err()
		}
		stop()
		if observe != nil {
			outcome := "compatible"
			switch {
			case errors.Is(err, context.DeadlineExceeded):
				outcome = "timeout"
			case errors.Is(err, ErrRuntimeIncompatible):
				outcome = "unsupported"
			case err != nil:
				outcome = "unusable"
			}
			observe(file.path, candidate.Version, outcome)
		}
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
	if errors.Is(parent.Err(), context.Canceled) {
		return RuntimeCandidate{Source: source}, parent.Err()
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
	if err != nil && req.Name == "codex" && path == strings.TrimSpace(req.Pin) && filepath.Base(path) != path &&
		(errors.Is(err, exec.ErrNotFound) || errors.Is(err, os.ErrNotExist)) {
		// PATH helpers (including Windows LookPath) can hide permission errors.
		// Only a stat of the pinned file can establish that it was removed.
		if _, statErr := d.Stat(path); statErr != nil {
			if d.GOOS == "windows" && filepath.Ext(path) == "" && errors.Is(statErr, os.ErrNotExist) {
				// The pin may point to an inaccessible PATHEXT sibling.
				return "", exec.ErrNotFound
			}
			return "", statErr
		}
		return "", exec.ErrNotFound
	}
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
func (d RuntimeDiscovery) uniqueExecutable(ctx context.Context, req RuntimeRequest, path string, seen []executableFile) (executableFile, error) {
	return cliinspect.Bounded(ctx, func() (executableFile, error) {
		file, err := d.lookupFile(req, path)
		if err != nil {
			return executableFile{}, err
		}
		// PATH and the WindowsApps fallback can resolve to the same alias
		// even when Windows denies access to its file ID.
		for _, prior := range seen {
			if prior.path == file.path {
				return executableFile{}, nil
			}
		}
		if !d.sameFile(file.info, file.info) {
			file.info = nil // still inspect launchable aliases without an accessible file ID
			return file, nil
		}
		for _, prior := range seen {
			if prior.info != nil && d.sameFile(prior.info, file.info) {
				return executableFile{}, nil
			}
		}
		return file, nil
	})
}

func runRuntimeProbe(ctx context.Context, path string, req RuntimeRequest, args ...string) (string, error) {
	if req.Name == "claude" {
		// Claude reports its version on stdout. Its launcher can print a
		// different product's version (such as Node's) on stderr.
		out, err := cliinspect.Stdout(ctx, path, req.Environment, args...)
		return string(out), err
	}
	return cliinspect.Run(ctx, path, req.Environment, args...)
}

func (d RuntimeDiscovery) inspect(ctx context.Context, req RuntimeRequest, path string) (string, error) {
	output, err := d.run(ctx, path, req, "--version")
	if err != nil {
		return "", err
	}
	parse, compare := claudebridge.ParseVersion, claudebridge.Compare
	if req.Name == "codex" {
		parse, compare = appserver.ParseCodexBanner, appserver.CompareCodexVersions
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
		help, err := d.run(ctx, path, req, "app-server", "--help")
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
