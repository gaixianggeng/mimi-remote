//go:build windows

package setup

import (
	"context"
	"io"
	"os/exec"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
)

// lookupUsableExecutable 只确认 Windows 候选路径可以真实启动。Claude 与
// Codex 的版本格式不同，因此通用探测不能附带 Codex 版本规则。
func lookupUsableExecutable(file string) (string, error) {
	path, err := exec.LookPath(file)
	if err != nil {
		return "", err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, path, "--version")
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard
	if err := cmd.Run(); err != nil {
		return "", exec.ErrNotFound
	}
	return path, nil
}

// WindowsApps package resources can be discoverable by LookPath while their
// ACL denies CreateProcess to an ordinary desktop process. Probe candidates
// before persisting them so the service never records an unusable path.
func lookupUsableCodexExecutable(file string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	info, err := appserver.ValidateIndependentCodexRuntime(ctx, file)
	if err != nil {
		return "", err
	}
	return info.Path, nil
}
