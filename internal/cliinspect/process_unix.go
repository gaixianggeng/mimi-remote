//go:build !windows

package cliinspect

import (
	"context"
	"os"
	"os/exec"
	"sync"
	"syscall"
)

const probeLogSink = os.DevNull

func start(ctx context.Context, cmd *exec.Cmd) (func(), error) {
	if ctx.Value(parentLifetimeKey{}) == true {
		return startPreflightChild(ctx, cmd)
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	// CommandContext kills the root on cancellation. Clean the group after
	// every Wait, including when the root exits successfully on its own.
	pgid := cmd.Process.Pid
	return func() { _ = syscall.Kill(-pgid, syscall.SIGKILL) }, nil
}

// The watchdog owns a distinct process group before the candidate can start.
// Only the parent holds the write end. EOF kills the group on normal cleanup,
// request cancellation, or immediate parent exit. A late Start cannot join a
// group that has gone away. The target is always executed directly by Go.
func startPreflightChild(ctx context.Context, cmd *exec.Cmd) (func(), error) {
	reader, writer, err := os.Pipe()
	if err != nil {
		return nil, err
	}
	watchdog := exec.CommandContext(ctx, "/bin/sh", "-c", `read -r line; kill -KILL 0`)
	// Leave the watchdog itself alive until EOF so it can kill all descendants.
	watchdog.Cancel = nil
	watchdog.Env = []string{"PATH=/usr/bin:/bin"}
	watchdog.Stdin = reader
	watchdog.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	err = watchdog.Start()
	reader.Close()
	if err != nil {
		writer.Close()
		return nil, err
	}
	finish := sync.OnceFunc(func() {
		writer.Close()
		_ = watchdog.Wait()
	})
	stop := context.AfterFunc(ctx, finish)
	cleanup := func() {
		stop()
		finish()
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true, Pgid: watchdog.Process.Pid}
	if err := cmd.Start(); err != nil {
		cleanup()
		return nil, err
	}
	return cleanup, nil
}
