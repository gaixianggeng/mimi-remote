//go:build windows

package main

import (
	"context"
	"os"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/windowslan"
)

var (
	windowsLANStatusCheck       = windowslan.Check
	statusExecutablePath        = os.Executable
	statusCanonicalFirewallPath = windowslan.CanonicalFirewallPath
)

func inspectPlatformNetworkStatus(ctx context.Context, cfg config.Config) agentNetworkStatus {
	result := configuredAgentNetworkStatus(cfg)
	result.PolicyChecked = true

	rawPath, err := statusExecutablePath()
	if err != nil {
		result.PolicyInspectionErr = true
		return result
	}
	agentPath, err := statusCanonicalFirewallPath(rawPath)
	if err != nil {
		result.PolicyInspectionErr = true
		return result
	}
	status, err := windowsLANStatusCheck(ctx, agentPath)
	if err != nil {
		result.PolicyInspectionErr = true
		return result
	}

	result.FirewallValid = status.FirewallValid
	result.InterfaceAlias = status.InterfaceAlias
	result.NetworkCategory = status.NetworkCategory
	result.UnsafeRuleCount = len(status.UnsafeRules)
	if cfg.Network.AllowLAN {
		result.PolicyOK = status.Ready()
	} else {
		// A managed LAN rule is not required in loopback/Tailscale-only mode,
		// but stale inbound Allow rules for this executable are still unsafe.
		result.PolicyOK = len(status.UnsafeRules) == 0
	}
	return result
}
