//go:build windows

package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/windowslan"
	"golang.org/x/sys/windows"
)

func TestInspectPlatformNetworkStatusRedactsUnsafeRuleNames(t *testing.T) {
	previous := windowsLANStatusCheck
	windowsLANStatusCheck = func(context.Context, string) (windowslan.Status, error) {
		return windowslan.Status{
			FirewallValid:   false,
			ProfilePrivate:  false,
			InterfaceAlias:  "WLAN",
			NetworkCategory: "Public",
			UnsafeRules:     []string{"secret rule one", "secret rule two"},
		}, nil
	}
	t.Cleanup(func() { windowsLANStatusCheck = previous })

	status := inspectPlatformNetworkStatus(context.Background(), config.Config{
		Listen:  "0.0.0.0:8787",
		Network: config.NetworkConfig{AllowLAN: true},
	})
	if !status.PolicyChecked || status.PolicyOK || status.UnsafeRuleCount != 2 ||
		status.InterfaceAlias != "WLAN" || status.NetworkCategory != "Public" {
		t.Fatalf("unexpected Windows network status: %+v", status)
	}
	raw, err := json.Marshal(status)
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{"secret rule one", "secret rule two"} {
		if strings.Contains(string(raw), forbidden) {
			t.Fatalf("network status must not expose firewall rule names: %s", raw)
		}
	}
}

func TestInspectPlatformNetworkStatusDoesNotRequireManagedRuleWhenLANDisabled(t *testing.T) {
	previous := windowsLANStatusCheck
	windowsLANStatusCheck = func(context.Context, string) (windowslan.Status, error) {
		return windowslan.Status{
			FirewallValid:   false,
			ProfilePrivate:  false,
			InterfaceAlias:  "WLAN",
			NetworkCategory: "Public",
		}, nil
	}
	t.Cleanup(func() { windowsLANStatusCheck = previous })

	status := inspectPlatformNetworkStatus(context.Background(), config.Config{
		Listen: "127.0.0.1:8787",
	})
	if !status.PolicyChecked || !status.PolicyOK || status.Mode != "loopback" {
		t.Fatalf("loopback-only mode must not require a LAN firewall rule: %+v", status)
	}
}

func TestInspectPlatformNetworkStatusCanonicalizesVolumeGUIDExecutable(t *testing.T) {
	if statusNetworkPolicyTimeout < windowsLANPolicyCheckTimeout {
		t.Fatalf("status --network-policy timeout %s is shorter than Windows policy budget %s", statusNetworkPolicyTimeout, windowsLANPolicyCheckTimeout)
	}
	selfExe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	canonicalSelf, err := windowslan.CanonicalFirewallPath(selfExe)
	if err != nil {
		t.Fatal(err)
	}
	volume := filepath.VolumeName(canonicalSelf)
	if len(volume) != 2 || volume[1] != ':' {
		t.Skipf("test executable not on drive letter volume: %q", canonicalSelf)
	}
	root, err := windows.UTF16PtrFromString(volume + `\`)
	if err != nil {
		t.Fatal(err)
	}
	var guid [64]uint16
	if err := windows.GetVolumeNameForVolumeMountPoint(root, &guid[0], uint32(len(guid))); err != nil {
		t.Fatal(err)
	}
	guidPath := strings.TrimSuffix(windows.UTF16ToString(guid[:]), `\`) + canonicalSelf[len(volume):]
	if !strings.HasPrefix(guidPath, `\\?\Volume{`) {
		t.Fatalf("failed to construct volume GUID path: %q", guidPath)
	}

	prevExe := statusExecutablePath
	prevCheck := windowsLANStatusCheck
	var receivedPath string
	statusExecutablePath = func() (string, error) { return guidPath, nil }
	windowsLANStatusCheck = func(_ context.Context, agentPath string) (windowslan.Status, error) {
		receivedPath = agentPath
		return windowslan.Status{
			FirewallValid:   true,
			ProfilePrivate:  true,
			InterfaceAlias:  "Ethernet",
			NetworkCategory: "Private",
		}, nil
	}
	t.Cleanup(func() {
		statusExecutablePath = prevExe
		windowsLANStatusCheck = prevCheck
	})

	status := inspectPlatformNetworkStatus(context.Background(), config.Config{
		Listen:  "0.0.0.0:8787",
		Network: config.NetworkConfig{AllowLAN: true},
	})
	if !status.PolicyChecked || !status.PolicyOK || !status.FirewallValid || status.PolicyInspectionErr {
		t.Fatalf("expected valid canonical firewall check, got %+v", status)
	}
	if strings.HasPrefix(receivedPath, `\\?\`) || !strings.EqualFold(receivedPath, canonicalSelf) {
		t.Fatalf("firewall check received %q, want canonical drive path %q", receivedPath, canonicalSelf)
	}
}
