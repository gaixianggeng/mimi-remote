package config

import (
	"net"
	"strings"
)

// IsEnabled preserves pre-module-management installations: a missing enabled
// field means Codex remains enabled. Explicit false survives config round trips.
func (c CodexConfig) IsEnabled() bool {
	return c.Enabled == nil || *c.Enabled
}

// AllowsTailscale controls only Mimi's listener/request boundary, never the
// system Tailscale client. Nil keeps the legacy configured-listener policy.
func (c NetworkConfig) AllowsTailscale() bool {
	return c.TailscaleEnabled == nil || *c.TailscaleEnabled
}

func (c Config) HasEnabledAgent() bool {
	return c.Codex.IsEnabled() || c.Claude.Enabled
}

// ModuleConfiguration is a credential-free projection of configuration intent.
// Availability must come from the running service/provider, not these booleans.
type ModuleConfiguration struct {
	CodexEnabled     bool `json:"codex_enabled"`
	ClaudeEnabled    bool `json:"claude_enabled"`
	TailscaleEnabled bool `json:"tailscale_enabled"`
	LANEnabled       bool `json:"lan_enabled"`
	TailcatEnabled   bool `json:"tailcat_enabled"`
}

func (c Config) Modules() ModuleConfiguration {
	return ModuleConfiguration{
		CodexEnabled: c.Codex.IsEnabled(), ClaudeEnabled: c.Claude.Enabled,
		TailscaleEnabled: c.Network.AllowsTailscale(), LANEnabled: c.LANAccessEnabled(),
		TailcatEnabled: c.Tailcat.Enabled,
	}
}

// Older configurations could explicitly bind a private/wildcard address without
// allow_lan. Preserve their effective intent until a network switch is changed.
func (c Config) LANAccessEnabled() bool {
	if c.Network.AllowLAN {
		return true
	}
	if c.Network.TailscaleEnabled != nil {
		return false
	}
	host, _, err := net.SplitHostPort(c.Listen)
	if err != nil {
		return false
	}
	ip := net.ParseIP(strings.Trim(host, "[]"))
	return ip != nil && (ip.IsPrivate() || ip.IsUnspecified())
}
