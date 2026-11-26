//go:build !windows

package windowslan

import (
	"context"
	"net"
)

func TrustedPeer(context.Context, net.Conn, int, string) bool { return false }
