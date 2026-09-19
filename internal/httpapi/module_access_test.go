package httpapi

import (
	"context"
	"github.com/gaixianggeng/mimi-remote/internal/config"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestModuleNetworkPolicyMatrix(t *testing.T) {
	for _, tc := range []struct {
		name, local, remote string
		lan, ts, want       bool
	}{
		{"both_off_local_control", "127.0.0.1:8787", "127.0.0.1:50000", false, false, true},
		{"remote_cannot_spoof_loopback", "127.0.0.1:8787", "100.64.1.2:50000", false, true, false},
		{"lan_only", "192.168.1.2:8787", "192.168.1.3:50000", true, false, true},
		{"tailscale_blocked_despite_lan", "100.64.1.2:8787", "100.64.1.3:50000", true, false, false},
		{"tailscale_only", "100.64.1.2:8787", "100.64.1.3:50000", false, true, true},
		{"lan_blocked_despite_ts", "192.168.1.2:8787", "192.168.1.3:50000", false, true, false},
		{"tailscale_v6_off", "[fd7a:115c:a1e0::2]:8787", "[fd7a:115c:a1e0::3]:50000", true, false, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			router := &Router{cfg: config.Config{Network: config.NetworkConfig{AllowLAN: tc.lan, TailscaleEnabled: &tc.ts}}}
			request := httptest.NewRequest(http.MethodGet, "http://localhost/api/version", nil)
			request.RemoteAddr = tc.remote
			local, err := net.ResolveTCPAddr("tcp", tc.local)
			if err != nil {
				t.Fatal(err)
			}
			request = request.WithContext(context.WithValue(request.Context(), http.LocalAddrContextKey, local))
			request.Header.Set("X-Forwarded-For", "127.0.0.1")
			if got := router.moduleConnectionAllowed(request); got != tc.want {
				t.Fatalf("got %t, want %t", got, tc.want)
			}
		})
	}
}

func TestModuleCodexRouteAliasesAndHistory(t *testing.T) {
	for _, path := range []string{"/api/app-server/ws", "/api/app-server/ws?runtime=openai", "/api/app-server/history-media/abc", "/api/app-server/history-output/abc"} {
		if !codexOnlyModulePath(httptest.NewRequest("GET", path, nil)) {
			t.Fatalf("unguarded: %s", path)
		}
	}
	for _, path := range []string{"/api/app-server/config", "/api/app-server/ws?runtime=claude", "/api/app-server/ws?runtime=anthropic"} {
		if codexOnlyModulePath(httptest.NewRequest("GET", path, nil)) {
			t.Fatalf("blocked independent endpoint: %s", path)
		}
	}
}
