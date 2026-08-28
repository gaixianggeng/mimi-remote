//go:build !darwin

package desktopipc

import (
	"context"
	"fmt"
)

func activateDesktopThreadRoute(context.Context, string, string) error {
	return fmt.Errorf("Desktop route activation is supported only on macOS")
}
