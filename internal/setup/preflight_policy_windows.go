//go:build windows

package setup

import (
	"context"
	"os"

	"github.com/gaixianggeng/mimi-remote/internal/windowslan"
)

func preflightLANPolicy(ctx context.Context, enabled bool) string {
	rawExe, err := os.Executable()
	if err != nil {
		return "lan_public_network_blocked"
	}
	exe, err := windowslan.CanonicalFirewallPath(rawExe)
	if err != nil {
		return "lan_firewall_blocked"
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
