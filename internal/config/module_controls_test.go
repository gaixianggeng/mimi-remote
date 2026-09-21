package config

import "testing"

func TestModuleControlDefaultsAndNetworkCompatibility(t *testing.T) {
	off := false
	if !(CodexConfig{}).IsEnabled() || (CodexConfig{Enabled: &off}).IsEnabled() {
		t.Fatal("legacy codex semantics changed")
	}
	tests := []struct {
		listen  string
		lan, ts bool
	}{
		{"127.0.0.1:8787", false, false}, {"100.64.0.2:8787", false, true},
		{"192.168.50.2:8787", true, false}, {"0.0.0.0:8787", true, true},
	}
	for _, tt := range tests {
		cfg := Config{Listen: tt.listen}
		if cfg.LANAccessEnabled() != tt.lan || cfg.TailscaleAccessEnabled() != tt.ts {
			t.Fatalf("legacy %s", tt.listen)
		}
		cfg.Network.AllowTailscale = &off
		if cfg.LANAccessEnabled() || cfg.TailscaleAccessEnabled() {
			t.Fatalf("explicit off ignored stale bind %s", tt.listen)
		}
	}
}

func TestNetworkModulesCannotExposeUnauthenticatedListener(t *testing.T) {
	on := true
	cfg := defaults()
	cfg.DevInsecure = true
	cfg.Network.AllowTailscale = &on
	if err := cfg.Validate(); err == nil {
		t.Fatal("tokenless TS ingress accepted")
	}
	off := false
	cfg.Network.AllowTailscale = &off
	cfg.Network.AllowLAN = true
	if err := cfg.Validate(); err == nil {
		t.Fatal("tokenless LAN ingress accepted")
	}
}
