//go:build windows

package setup

import (
	"context"
	"net"
	"os"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/windowslan"
)

func preflightLANPolicy(ctx context.Context, enabled bool) string {
	exe, err := os.Executable()
	if err != nil {
		return "lan_public_network_blocked"
	}
	policy, err := windowslan.Check(ctx, exe)
	if ctx.Err() != nil {
		return "probe_timeout"
	}
	if err != nil || !policy.ProfilePrivate {
		return "lan_public_network_blocked"
	}
	if len(policy.UnsafeRules) > 0 || enabled && !policy.FirewallValid {
		return "lan_firewall_blocked"
	}
	return ""
}

func confirmPlatformPairingLAN(ctx context.Context, cfg config.Config) error {
	return confirmResidentPairingLAN(ctx, cfg, preflightLANPolicy, func(c context.Context, conn net.Conn) bool { return windowslan.TrustedPeer(c, conn, 0, "") })
}
