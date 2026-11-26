package networkaccess

import (
	"net"
	"testing"
	"time"
)

func TestPairingChecksRealBoundSocketFamilyAndPort(t *testing.T) {
	for _, test := range []struct{ network, address string }{
		{"tcp4", "0.0.0.0:0"},
		{"tcp6", "[::]:0"},
		{"tcp", "[::]:0"}, // Stack default may be dual-stack or IPv6-only.
		{"tcp4", "127.0.0.1:0"},
	} {
		t.Run(test.network+"/"+test.address, func(t *testing.T) {
			l, err := net.Listen(test.network, test.address)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { l.Close() })
			wrapped := Wrap(l, Policy{LAN: true, Tailscale: true})
			port := l.Addr().(*net.TCPAddr).Port
			for _, host := range []string{"127.0.0.1", "::1"} {
				target := &net.TCPAddr{IP: net.ParseIP(host), Port: port}
				dialer := net.Dialer{Timeout: time.Second}
				conn, err := dialer.DialContext(t.Context(), "tcp", target.String())
				if conn != nil {
					conn.Close()
				}
				if got := listenerCovers(wrapped, target); got != (err == nil) {
					t.Errorf("socket coverage for %s = %v, dial error %v", host, got, err)
				}
				if DirectListenerReachable(t.Context(), []net.Listener{wrapped}, target) {
					t.Fatal("loopback is not a phone route")
				}
			}
			target := &net.TCPAddr{IP: net.ParseIP("127.0.0.1"), Port: port + 1}
			if listenerCovers(wrapped, target) {
				t.Fatal("wrong port matched")
			}
			if err := wrapped.Close(); err != nil {
				t.Fatal(err)
			}
			if listenerCovers(wrapped, l.Addr().(*net.TCPAddr)) {
				t.Fatal("closed listener matched its cached address")
			}
		})
	}
}
