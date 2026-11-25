package networkaccess

import (
	"context"
	"net"
	"testing"
)

func TestAvailabilityRequiresActiveTunnelEvidence(t *testing.T) {
	for _, tc := range []struct {
		name, iface, address string
		flags                net.Flags
		signedOut            bool
		wantProbes           int
		wantTS, wantLAN      bool
	}{
		{"CGNAT on Wi-Fi", "en0", "100.64.0.5", net.FlagUp, false, 0, false, false},
		{"CGNAT on Ethernet", "eth0", "100.64.0.5", net.FlagUp, false, 0, false, false},
		{"bridge", "br-tailscale", "100.64.0.5", net.FlagUp, false, 0, false, false},
		{"tunnel prefix collision", "tunnelbridge0", "100.64.0.5", net.FlagUp, false, 0, false, false},
		{"tailscale prefix collision", "tailscalebridge0", "100.64.0.5", net.FlagUp, false, 0, false, false},
		{"utun prefix collision", "utunbridge0", "100.64.0.5", net.FlagUp, false, 0, false, false},
		{"container", "docker0", "100.64.0.5", net.FlagUp, false, 0, false, false},
		{"loopback", "utun0", "100.64.0.5", net.FlagUp | net.FlagLoopback, false, 0, false, false},
		{"down", "tailscale0", "100.64.0.5", 0, false, 0, false, false},
		{"macOS tunnel", "utun4", "100.64.0.5", net.FlagUp, false, 1, true, false},
		{"tun tunnel", "tun2", "100.64.0.5", net.FlagUp, false, 1, true, false},
		{"named tunnel", "Tailscale", "100.64.0.5", net.FlagUp, false, 1, true, false},
		{"CLI signed out", "utun4", "100.64.0.5", net.FlagUp, true, 1, false, false},
		{"private physical LAN", "eth0", "192.168.1.5", net.FlagUp, false, 0, false, true},
		{"private VPN", "tun-vpn", "192.168.1.5", net.FlagUp, false, 0, false, false},
		{"private tunnel", "tailscale0", "192.168.1.5", net.FlagUp, false, 0, false, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			probeCalls := 0
			gotTS, gotLAN := availability(context.Background(), func() ([]net.Interface, error) {
				return []net.Interface{{Name: tc.iface, Flags: tc.flags}}, nil
			}, func(*net.Interface) ([]net.Addr, error) {
				return []net.Addr{&net.IPNet{IP: net.ParseIP(tc.address), Mask: net.CIDRMask(32, 32)}}, nil
			}, func(context.Context) bool {
				probeCalls++
				return !tc.signedOut
			})
			if gotTS != tc.wantTS || gotLAN != tc.wantLAN || probeCalls != tc.wantProbes {
				t.Fatalf("availability = (%t, %t), CLI calls = %d", gotTS, gotLAN, probeCalls)
			}
		})
	}
}
