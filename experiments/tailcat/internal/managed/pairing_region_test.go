package managed

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"reflect"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/experiments/tailcat/internal/tunnel"
	"github.com/tailscale/tailcat"
	"tailscale.com/tailcfg"
	"tailscale.com/tstest/integration"
	"tailscale.com/types/key"
)

func TestPairingRegionUsesCurrentStableHostOrDiscovery(t *testing.T) {
	region := &tailcfg.DERPRegion{RegionID: 1, Nodes: []*tailcfg.DERPNode{{Name: "relay", HostName: "relay.example.invalid", DERPPort: 8443}}}
	info := tailcat.ConnInfo{ServerPublic: tailcat.NodePublic{NodePublic: key.NewNode().Public()}, Region: []*tailcfg.DERPRegion{region}}
	address := info.Addr()
	decoded, err := tailcat.ParseAddr(address)
	if err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct {
		name string
		host managedHost
		want *tailcfg.DERPRegion
	}{
		{"embedded relay", &fakeManagedHost{address: string(address)}, decoded.Region[0]},
		{"no stable host", nil, nil},
		{"unreadable address", &fakeManagedHost{address: "invalid"}, nil},
		{"region ID only", &fakeManagedHost{address: string((&tailcat.ConnInfo{ServerPublic: info.ServerPublic, RegionID: 1}).Addr())}, nil},
	} {
		t.Run(test.name, func(t *testing.T) {
			manager := &Manager{host: test.host, config: Config{StateDir: t.TempDir(), DERPMapURL: "https://map.example.invalid/derpmap"}}
			manager.startHost = func(config tunnel.HostConfig) (managedHost, error) {
				if !reflect.DeepEqual(config.Region, test.want) || config.DERPMapURL != manager.config.DERPMapURL {
					t.Fatal("pairing ignored the current relay or lost the discovery fallback")
				}
				if !config.AllowAllClients {
					t.Fatal("pairing transport contract changed")
				}
				return &fakeManagedHost{}, nil
			}
			t.Cleanup(func() { _ = manager.Close() })
			if _, err := manager.StartPairing(time.Minute); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestPairingSkipsDiscoveryRotatesIdentityAndStillConnects(t *testing.T) {
	t.Setenv("TS_DEBUG_ALWAYS_USE_DERP", "1")
	derpMap := integration.RunDERPAndSTUN(t, t.Logf, "127.0.0.1")
	var mapRequests atomic.Int32
	discovery := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		mapRequests.Add(1)
		http.Error(w, "discovery unavailable", http.StatusServiceUnavailable)
	}))
	t.Cleanup(discovery.Close)
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, "pairing-ready")
	}))
	t.Cleanup(backend.Close)
	endpoint, _ := url.Parse(backend.URL)
	stateDir := t.TempDir()
	stable, err := tunnel.StartHost(tunnel.HostConfig{
		TargetAddr: endpoint.Host, RemotePort: 8787, Region: derpMap.Regions[1],
		IdentityPath: filepath.Join(stateDir, "host.private.json"), AddressPath: filepath.Join(stateDir, "host.address"),
	})
	if err != nil {
		t.Fatal(err)
	}
	manager := &Manager{
		config:    Config{TargetAddr: endpoint.Host, RemotePort: 8787, StateDir: stateDir, DERPMapURL: discovery.URL},
		host:      stable,
		startHost: func(config tunnel.HostConfig) (managedHost, error) { return tunnel.StartHost(config) },
	}
	t.Cleanup(func() { _ = manager.Close() })
	first, err := manager.StartPairing(time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	second, err := manager.StartPairing(time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if mapRequests.Load() != 0 {
		t.Fatal("generating a code contacted the unavailable discovery service")
	}
	if first.PairAddress == second.PairAddress || first.PairPublicKey == second.PairPublicKey || second.PublicKey != stable.PublicKey() {
		t.Fatal("new pairing must rotate only the temporary identity")
	}
	expires, err := time.Parse(time.RFC3339Nano, second.PairExpiresAt)
	if err != nil || time.Until(expires) > time.Minute || time.Until(expires) < 50*time.Second {
		t.Fatal("pairing TTL changed")
	}
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	client, err := tunnel.StartForwarder(ctx, tunnel.ForwarderConfig{
		Address: second.PairAddress, RemotePort: 8787, ListenAddr: "127.0.0.1:0", IdentityPath: filepath.Join(stateDir, "client.json"),
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = client.Close() })
	response, err := (&http.Client{Timeout: 5 * time.Second}).Get(client.Endpoint())
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil || string(body) != "pairing-ready" {
		t.Fatal("new pairing host cannot carry traffic")
	}
}
