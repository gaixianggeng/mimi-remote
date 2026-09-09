package tunnel

import (
	"net/http"
	"net/url"
	"path/filepath"
	"testing"
	"time"

	"tailscale.com/tstest/integration"
)

// 锁屏恢复复用同一安装身份，必须先关闭旧引擎再启动新连接。
// 两个同身份引擎并存会抢占 DERP 下行，导致原连接后续请求超时。
func TestApprovalRouteRecoversSeriallyOverDERP(t *testing.T) {
	t.Setenv("TS_DEBUG_ALWAYS_USE_DERP", "1")
	backend := newAgentdFixture(t)
	parsed, err := url.Parse(backend.URL)
	if err != nil {
		t.Fatal(err)
	}
	region := integration.RunDERPAndSTUN(t, t.Logf, "127.0.0.1").Regions[1]
	root := t.TempDir()
	identityPath := filepath.Join(root, "client.json")
	identity, err := LoadOrCreateClientIdentity(identityPath)
	if err != nil {
		t.Fatal(err)
	}
	host, err := StartHost(HostConfig{
		TargetAddr: parsed.Host, RemotePort: 8787,
		IdentityPath: filepath.Join(root, "host.json"), AddressPath: filepath.Join(root, "address"),
		AllowedClientKeys: []string{identity.Public().String()}, Region: region,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer host.Close()
	original := startTestForwarder(t, host.Address(), identityPath)
	defer original.Close()
	check := func(endpoint string) {
		t.Helper()
		req, err := http.NewRequest("GET", endpoint+"/api/readyz", nil)
		if err != nil {
			t.Fatal(err)
		}
		req.Header.Set("Authorization", "Bearer "+experimentToken)
		response, err := (&http.Client{Timeout: 8 * time.Second}).Do(req)
		if err != nil {
			t.Fatal(err)
		}
		response.Body.Close()
		if response.StatusCode != 200 {
			t.Fatalf("unexpected status %d", response.StatusCode)
		}
	}
	check(original.Endpoint())
	if err := original.Close(); err != nil {
		t.Fatal(err)
	}
	recovered := startTestForwarder(t, host.Address(), identityPath)
	defer recovered.Close()
	check(recovered.Endpoint())
}
