package setup

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestPairingLANRechecksResidentPolicyOnlyForSelectedLAN(t *testing.T) {
	off := false
	cfg := config.Config{Listen: "127.0.0.1:8787", Network: config.NetworkConfig{AllowTailscale: &off, AllowLAN: true}, Auth: config.AuthConfig{Token: "local-policy-fixture"}}
	var checks int
	code := ""
	lookups := pairingNetworkLookups{lanIP: func() string { return "192.168.50.2" }, tailscaleIP: func(context.Context) string { return "100.64.0.2" }, confirmLAN: func(context.Context, config.Config) error { checks++; return pairingLANTrouble(code) }}
	for _, codeValue := range []string{"", "lan_public_network_blocked", "lan_firewall_blocked", "probe_timeout", ""} {
		code = codeValue
		r, err := resultFromConfigForNetwork(context.Background(), "", cfg, PairingNetworkAuto, lookups)
		if code == "" {
			if err != nil || r.PairURL == "" {
				t.Fatalf("safe LAN: %v", err)
			}
		} else {
			var d *PairingDiagnostic
			if !errors.As(err, &d) || d.Code != code || d.Step != "network_lan" || r.PairURL != "" || r.ConnectURL != "" {
				t.Fatalf("unsafe LAN minted a link or lost code: %v", err)
			}
		}
	}
	on := true
	cfg.Network.AllowTailscale = &on
	code = "lan_public_network_blocked"
	r, err := resultFromConfigForNetwork(context.Background(), "", cfg, PairingNetworkAuto, lookups)
	if err != nil || r.Network != PairingNetworkTailscale || checks != 5 {
		t.Fatalf("LAN check affected Tailscale selection: %v checks=%d", err, checks)
	}
}

func TestResidentLANPolicyNeverSendsBearerToUnverifiedPeer(t *testing.T) {
	var calls atomic.Int32
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.Method != "POST" || r.URL.Path != "/api/local/lan-policy" || r.Header.Get("Authorization") != "Bearer local-policy-fixture" {
			t.Error("wrong authenticated request")
		}
		_, _ = io.WriteString(w, "{\"allowed\":false,\"code\":\"lan_public_network_blocked\"}")
	}))
	defer s.Close()
	cfg := config.Config{Listen: strings.TrimPrefix(s.URL, "http://"), Auth: config.AuthConfig{Token: "local-policy-fixture"}}
	offline := func(context.Context, bool) string { t.Fatal("occupied port fell back to offline policy"); return "" }
	for _, tc := range []struct {
		trusted  bool
		code     string
		requests int32
	}{{false, "service_port_in_use", 0}, {true, "lan_public_network_blocked", 1}} {
		err := confirmResidentPairingLAN(context.Background(), cfg, offline, func(_ context.Context, conn net.Conn) bool {
			if conn.RemoteAddr().String() != cfg.Listen {
				t.Fatal("not the configured loopback connection")
			}
			return tc.trusted
		})
		var d *PairingDiagnostic
		if !errors.As(err, &d) || d.Code != tc.code || calls.Load() != tc.requests {
			t.Fatalf("trusted=%t err=%v requests=%d", tc.trusted, err, calls.Load())
		}
	}
}
