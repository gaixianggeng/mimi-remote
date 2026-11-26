// Package cliinspect runs short-lived CLI probes and cleans up their descendants.
package cliinspect

import (
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
)

type parentLifetimeKey struct{}

// WithParentLifetime ties any probes in this request to the calling CLI process.
// On Unix a pipe signals process death even when the CLI cannot run defers.
func WithParentLifetime(ctx context.Context) context.Context {
	return context.WithValue(ctx, parentLifetimeKey{}, true)
}

const versionOutputLimit = 64 << 10

// Process workers use their own slots so a bounded resolver can invoke a command
// even when all resolver workers are occupied.
var processSlots = make(chan struct{}, 8)

type output struct {
	stdout, stderr []byte
}

var probeOverrides = map[string]string{
	"NO_UPDATE_NOTIFIER":         "1",
	"NPM_CONFIG_UPDATE_NOTIFIER": "false",
	// Redirect writes and cleanup without changing retention. Older npm versions
	// ignore logs-dir and interpret logs-max=0 as "delete all existing logs".
	"NPM_CONFIG_LOGS_DIR":        probeLogSink,
	"NPM_CONFIG_TIMING":          "false",
	"NPM_CONFIG_AUDIT":           "false",
	"NPM_CONFIG_FUND":            "false",
	"NODE_DISABLE_COMPILE_CACHE": "1",
}

// Preflight must leave Mimi-owned state untouched. Vendor shims run with the
// user's permissions and may write their own caches. Suppress known writes
// while preserving the HOME and PATH they use to find installed packages.
func probeEnvironment(env []string) []string {
	if env == nil {
		env = os.Environ()
	}
	result := make([]string, 0, len(env)+len(probeOverrides))
	for _, entry := range env {
		key, _, _ := strings.Cut(entry, "=")
		key = strings.ToUpper(key)
		if strings.HasPrefix(key, "NPM_CONFIG_") {
			// npm treats dashes and underscores in option names as equivalent.
			key = strings.ReplaceAll(key, "-", "_")
		}
		if _, overridden := probeOverrides[key]; !overridden {
			result = append(result, entry)
		}
	}
	for key, value := range probeOverrides {
		result = append(result, key+"="+value)
	}
	return result
}

func Run(ctx context.Context, path string, env []string, args ...string) (string, error) {
	out, err := inspectCommand(ctx, func() (*exec.Cmd, error) {
		cmd := exec.CommandContext(ctx, path, args...)
		cmd.Env = probeEnvironment(env)
		return cmd, nil
	}, versionOutputLimit, true)
	return string(out.stdout), err
}

// Stdout reads a version or capability report without mixing in diagnostics.
func Stdout(ctx context.Context, path string, env []string, args ...string) ([]byte, error) {
	out, _, err := Output(ctx, func() (*exec.Cmd, error) {
		cmd := exec.CommandContext(ctx, path, args...)
		cmd.Env = probeEnvironment(env)
		return cmd, nil
	}, versionOutputLimit)
	return out, err
}

// Output captures stdout and stderr independently. build must bind the command
// to ctx. Both lookup and startup may block, so the worker owns the command and
// its cleanup even if the caller's deadline elapses before Start returns.
func Output(ctx context.Context, build func() (*exec.Cmd, error), limit int64) ([]byte, []byte, error) {
	out, err := inspectCommand(ctx, build, limit, false)
	return out.stdout, out.stderr, err
}

func inspectCommand(ctx context.Context, build func() (*exec.Cmd, error), limit int64, combined bool) (output, error) {
	return withSlots(ctx, processSlots, func() (output, error) {
		cmd, err := build()
		if err != nil {
			return output{}, err
		}
		return capture(ctx, cmd, limit, combined)
	})
}

type streamResult struct {
	data []byte
	err  error
}

// Own the pipes so Wait can reap the root even when a descendant inherits
// stdout or stderr. Killing the group after Wait then closes those descriptors.
func capturePipe(ctx context.Context, limit int64) (*os.File, <-chan streamResult, error) {
	reader, writer, err := os.Pipe()
	if err != nil {
		return nil, nil, err
	}
	done := make(chan streamResult, 1)
	go func() {
		stop := context.AfterFunc(ctx, func() { reader.Close() })
		data, err := io.ReadAll(io.LimitReader(reader, limit+1))
		stop()
		reader.Close()
		if int64(len(data)) > limit {
			data, err = nil, errors.New("CLI inspection output too large")
		}
		done <- streamResult{data, err}
	}()
	return writer, done, nil
}

func capture(ctx context.Context, cmd *exec.Cmd, limit int64, combined bool) (output, error) {
	stdout, stdoutDone, err := capturePipe(ctx, limit)
	if err != nil {
		return output{}, err
	}
	cmd.Stdout, cmd.Stderr = stdout, stdout
	var stderrDone <-chan streamResult
	var stderr *os.File
	if !combined {
		stderr, stderrDone, err = capturePipe(ctx, limit)
		if err != nil {
			stdout.Close()
			return output{}, err
		}
		cmd.Stderr = stderr
	}
	cleanup, err := start(ctx, cmd)
	stdout.Close()
	if stderr != nil {
		stderr.Close()
	}
	if err != nil {
		return output{}, err
	}
	cleanup = sync.OnceFunc(cleanup)
	stop := context.AfterFunc(ctx, cleanup)
	waitErr := cmd.Wait()
	stop()
	cleanup()
	out := <-stdoutDone
	var diagnostic streamResult
	if stderrDone != nil {
		diagnostic = <-stderrDone
	}
	if ctx.Err() != nil {
		return output{}, ctx.Err()
	}
	if out.err != nil {
		return output{}, out.err
	}
	if diagnostic.err != nil {
		return output{}, diagnostic.err
	}
	if exitErr, ok := waitErr.(*exec.ExitError); ok {
		exitErr.Stderr = diagnostic.data
	}
	return output{out.data, diagnostic.data}, waitErr
}
