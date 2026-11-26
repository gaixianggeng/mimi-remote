//go:build !windows

package main

import (
	"context"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/networkaccess"
)

func platformServeLANGate(context.Context, config.Config) *networkaccess.LANGate { return nil }

func ensurePlatformLANAccessAllowed() error {
	return nil
}
