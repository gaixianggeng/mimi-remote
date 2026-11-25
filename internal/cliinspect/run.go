// Package cliinspect runs short-lived CLI probes and cleans up their descendants.
package cliinspect

import (
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"sync"
)

const versionOutputLimit = 64 << 10

// Process workers use their own slots so a bounded resolver can invoke a command
// even when all resolver workers are occupied.
var processSlots = make(chan struct{}, 8)

type output struct {
	stdout, stderr []byte
}

func Run(ctx context.Context, path string, env []string, args ...string) (string, error) {
	out, err := inspectCommand(ctx, func() (*exec.Cmd, error) {
		cmd := exec.CommandContext(ctx, path, args...)
		cmd.Env = env
		return cmd, nil
	}, versionOutputLimit, true)
	return string(out.stdout), err
}

// Stdout reads a version or capability report without mixing in diagnostics.
func Stdout(ctx context.Context, path string, env []string, args ...string) ([]byte, error) {
	out, _, err := Output(ctx, func() (*exec.Cmd, error) {
		cmd := exec.CommandContext(ctx, path, args...)
		cmd.Env = env
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
	cleanup, err := start(cmd)
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
