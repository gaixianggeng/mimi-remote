//go:build !windows

package main

import (
	"context"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/networkaccess"
)

const statusNetworkPolicyTimeout = 8 * time.Second

func platformServeLANGate(context.Context, config.Config) *networkaccess.LANGate { return nil }

func ensurePlatformLANAccessAllowed() error {
	return nil
}
