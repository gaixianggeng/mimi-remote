package setup

import (
	"fmt"
	"reflect"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

type NetworkModuleState struct {
	AllowLAN       bool  `json:"allow_lan"`
	AllowTailscale *bool `json:"allow_tailscale,omitempty"`
}

type NetworkConfigurationResult struct {
	LANEnabled       bool               `json:"lan_enabled"`
	TailscaleEnabled bool               `json:"tailscale_enabled"`
	Changed          bool               `json:"changed"`
	RestartRequired  bool               `json:"restart_required"`
	Previous         NetworkModuleState `json:"previous"`
	Applied          NetworkModuleState `json:"applied"`
}

func networkModuleState(cfg config.Config) NetworkModuleState {
	return NetworkModuleState{AllowLAN: cfg.Network.AllowLAN, AllowTailscale: cfg.Network.AllowTailscale}
}

// ConfigureNetworkAccess preserves the token, listen port, pairings and all
// unknown fields. Both effective legacy intentions are recorded on first use.
func ConfigureNetworkAccess(path, module string, enabled bool) (NetworkConfigurationResult, error) {
	if module != "lan" && module != "tailscale" {
		return NetworkConfigurationResult{}, fmt.Errorf("未知连接方式 %q", module)
	}
	doc, err := readModuleDocument(path, "network")
	if err != nil {
		return NetworkConfigurationResult{}, err
	}
	before := networkModuleState(doc.cfg)
	tailscale := doc.cfg.TailscaleAccessEnabled()
	after := NetworkModuleState{AllowLAN: doc.cfg.LANAccessEnabled(), AllowTailscale: &tailscale}
	if module == "lan" {
		after.AllowLAN = enabled
	} else {
		*after.AllowTailscale = enabled
	}
	return commitNetworkModule(doc, before, after)
}

// RestoreNetworkAccess is compare-and-swap on the touched module fields, then
// byte-CAS on the file. A newer network choice is never silently overwritten.
func RestoreNetworkAccess(path string, previous NetworkConfigurationResult) (NetworkConfigurationResult, error) {
	doc, err := readModuleDocument(path, "network")
	if err != nil {
		return NetworkConfigurationResult{}, err
	}
	current := networkModuleState(doc.cfg)
	if !reflect.DeepEqual(current, previous.Applied) {
		return NetworkConfigurationResult{}, fmt.Errorf("连接设置已被其他操作修改，未覆盖新的设置；请刷新后重试")
	}
	return commitNetworkModule(doc, current, previous.Previous)
}

func commitNetworkModule(doc moduleDocument, before, after NetworkModuleState) (NetworkConfigurationResult, error) {
	changed := !reflect.DeepEqual(before, after)
	if changed {
		if err := doc.commit("network", map[string]any{
			"allow_lan": after.AllowLAN, "allow_tailscale": optionalBoolValue(after.AllowTailscale),
		}); err != nil {
			return NetworkConfigurationResult{}, err
		}
	}
	cfg := doc.cfg
	cfg.Network.AllowLAN = after.AllowLAN
	cfg.Network.AllowTailscale = after.AllowTailscale
	return NetworkConfigurationResult{
		LANEnabled: cfg.LANAccessEnabled(), TailscaleEnabled: cfg.TailscaleAccessEnabled(),
		Changed: changed, RestartRequired: changed, Previous: before, Applied: after,
	}, nil
}
