//go:build !darwin && !linux

package main

import (
	"context"
	"net"

	"github.com/gaixianggeng/mimi-remote/internal/windowslan"
)

func trustedForegroundPeer(ctx context.Context, conn net.Conn) bool {
	return windowslan.TrustedPeer(ctx, conn, 0, "")
}
