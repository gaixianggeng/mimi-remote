package windowslan

import "strings"

// Status describes the two independent conditions required before agentd may
// expose its LAN listener on Windows.
type Status struct {
	FirewallValid   bool     `json:"firewall_valid"`
	ProfilePrivate  bool     `json:"profile_private"`
	InterfaceAlias  string   `json:"interface_alias"`
	NetworkCategory string   `json:"network_category"`
	UnsafeRules     []string `json:"unsafe_rules"`
}

func (s Status) Ready() bool {
	return s.FirewallValid && s.ProfilePrivate && len(s.UnsafeRules) == 0
}

func (s Status) InterfaceLabel() string {
	if value := strings.TrimSpace(s.InterfaceAlias); value != "" {
		return value
	}
	return "默认网络"
}

func (s Status) CategoryLabel() string {
	if value := strings.TrimSpace(s.NetworkCategory); value != "" {
		return value
	}
	return "Unknown"
}
