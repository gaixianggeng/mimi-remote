// Package cliinspect runs short-lived CLI probes and cleans up their descendants.
package cliinspect

import (
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
)

func Run(ctx context.Context, path string, env []string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, path, args...)
	cmd.Env = env
	// Own the pipe so Wait can reap the shim independently of a child holding
	// the output descriptor. Kill that child before waiting for EOF.
	reader, writer, err := os.Pipe()
	if err != nil {
		return "", err
	}
	defer reader.Close()
	cmd.Stdout, cmd.Stderr = writer, writer
	cleanup, err := start(cmd)
	writer.Close()
	if err != nil {
		return "", err
	}
	finished := make(chan error, 1)
	go func() {
		err := cmd.Wait()
		cleanup()
		finished <- err
	}()
	stop := context.AfterFunc(ctx, func() { reader.Close() })
	defer stop()
	const limit = 64 << 10
	output, readErr := io.ReadAll(io.LimitReader(reader, limit+1))
	reader.Close()
	waitErr := <-finished
	if err := ctx.Err(); err != nil {
		return "", err
	}
	if readErr != nil {
		return "", readErr
	}
	if len(output) > limit {
		return "", errors.New("CLI inspection output too large")
	}
	if waitErr != nil {
		return "", waitErr
	}
	return string(output), nil
}
