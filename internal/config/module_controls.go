package config

import (
	"net"
	"strings"
)

func (c CodexConfig) IsEnabled() bool { return c.Enabled == nil || *c.Enabled }

func (c Config) HasEnabledAgent() bool { return c.Codex.IsEnabled() || c.Claude.Enabled }

// Independent ingress controls are opt-in, so upgrading does not change an
// existing custom bind. The first explicit network mutation records both intents.
func (c Config) HasNetworkModuleControls() bool { return c.Network.AllowTailscale != nil }

func (c Config) TailscaleAccessEnabled() bool {
	if c.Network.AllowTailscale != nil {
		return *c.Network.AllowTailscale
	}
	ip := c.configuredListenIP()
	return c.Network.AllowLAN || (ip != nil && (ip.IsUnspecified() || isTailscaleListenIP(ip)))
}

func (c Config) LANAccessEnabled() bool {
	if c.HasNetworkModuleControls() {
		return c.Network.AllowLAN
	}
	ip := c.configuredListenIP()
	return c.Network.AllowLAN || (ip != nil && (ip.IsUnspecified() || (ip.To4() != nil && ip.IsPrivate())))
}

func (c Config) configuredListenIP() net.IP {
	host, _, err := net.SplitHostPort(strings.TrimSpace(c.Listen))
	if err != nil {
		return nil
	}
	return net.ParseIP(strings.Trim(host, "[]"))
}

// In managed mode listen supplies the port, not an unrestricted bind. The
// listener is selected separately and every accepted socket is policy checked.
func (c Config) moduleValidationListen() string {
	if !c.HasNetworkModuleControls() {
		return c.Listen
	}
	_, port, err := net.SplitHostPort(c.Listen)
	if err != nil {
		return c.Listen
	}
	return net.JoinHostPort("127.0.0.1", port)
}

// ModuleStatus comes from the running daemon, never from the CLI's on-disk
// snapshot. Clients use it to confirm a reload actually applied a mutation.
type ModuleStatus struct {
	CodexEnabled       bool `json:"codex_enabled"`
	ClaudeEnabled      bool `json:"claude_enabled"`
	TailscaleEnabled   bool `json:"tailscale_enabled"`
	LANEnabled         bool `json:"lan_enabled"`
	TailscaleAvailable bool `json:"tailscale_available"`
	LANAvailable       bool `json:"lan_available"`
}
