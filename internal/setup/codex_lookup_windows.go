//go:build windows

package setup

import (
	"context"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
)

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
