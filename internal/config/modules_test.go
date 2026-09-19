package config

import (
	"encoding/json"
	"testing"
)

func TestModuleConfigurationPreservesLegacyDefaultsAndExplicitDisable(t *testing.T) {
	var legacy Config
	if err := json.Unmarshal([]byte(`{"codex":{"bin":"codex"},"network":{"allow_lan":false}}`), &legacy); err != nil {
		t.Fatal(err)
	}
	if !legacy.Codex.IsEnabled() || !legacy.Network.AllowsTailscale() || legacy.Network.AllowLAN {
		t.Fatalf("legacy defaults changed: %+v", legacy.Modules())
	}
	var disabled Config
	if err := json.Unmarshal([]byte(`{"codex":{"enabled":false},"network":{"tailscale_enabled":false,"allow_lan":true},"claude":{"enabled":true}}`), &disabled); err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(disabled)
	if err != nil {
		t.Fatal(err)
	}
	var roundTrip Config
	if err := json.Unmarshal(raw, &roundTrip); err != nil {
		t.Fatal(err)
	}
	if roundTrip.Codex.IsEnabled() || roundTrip.Network.AllowsTailscale() || !roundTrip.Network.AllowLAN || !roundTrip.HasEnabledAgent() {
		t.Fatalf("independent choices lost after round trip: %+v", roundTrip.Modules())
	}
}
