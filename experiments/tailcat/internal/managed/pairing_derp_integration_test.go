//go:build !ios && !js

package managed

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/experiments/tailcat/internal/tunnel"
	"tailscale.com/derp/derpserver"
	"tailscale.com/tailcfg"
	"tailscale.com/types/key"
	"tailscale.com/types/logger"
)

func TestPairingHostReconnectsThroughStrictDERPAfterAdmission(t *testing.T) {
	// 关闭 UDP，避免同机 Tailcat 两端直连后让健康检查产生假阳性。
	t.Setenv("TS_DEBUG_ALWAYS_USE_DERP", "1")

	admission := newAdmissionFixture(t)
	derp, region := startStrictDERP(t, admission.server.URL)
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, "managed-pairing-ready")
	}))
	t.Cleanup(backend.Close)
	backendURL, err := url.Parse(backend.URL)
	if err != nil {
		t.Fatal(err)
	}

	stateDir := t.TempDir()
	startHost := func(config tunnel.HostConfig) (managedHost, error) {
		config.Region = region
		return tunnel.StartHost(config)
	}
	stableHost, err := startHost(tunnel.HostConfig{
		TargetAddr:   backendURL.Host,
		RemotePort:   8787,
		IdentityPath: filepath.Join(stateDir, "host.private.json"),
		AddressPath:  filepath.Join(stateDir, "host.address"),
	})
	if err != nil {
		t.Fatal(err)
	}
	manager := &Manager{
		config: Config{
			TargetAddr: backendURL.Host,
			RemotePort: 8787,
			StateDir:   stateDir,
		},
		host:       stableHost,
		startHost:  startHost,
		instanceID: "strict-derp-test",
	}
	t.Cleanup(func() { _ = manager.Close() })

	status, err := manager.StartPairing(time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if status.PairAddress == "" || status.PairPublicKey == "" {
		t.Fatalf("配对状态缺少地址或临时公钥：%+v", status)
	}
	pairHost := manager.pairHost
	pairAddress := status.PairAddress

	mobilePrivate, err := tunnel.NewClientPrivateKey()
	if err != nil {
		t.Fatal(err)
	}
	mobilePublic, err := tunnel.ClientPublicKey(mobilePrivate)
	if err != nil {
		t.Fatal(err)
	}
	// 先只允许发起探测的移动端，才能让 DERP 单独观察并拒绝尚未授权的配对主机。
	admission.authorize(mobilePublic)
	deniedContext, cancelDenied := context.WithTimeout(context.Background(), 8*time.Second)
	deniedForwarder, deniedErr := tunnel.StartForwarder(deniedContext, tunnel.ForwarderConfig{
		Address:    pairAddress,
		RemotePort: 8787,
		ListenAddr: "127.0.0.1:0",
		PrivateKey: mobilePrivate,
	})
	cancelDenied()
	if deniedErr == nil {
		_ = deniedForwarder.Close()
		t.Fatal("严格 DERP 在授权前必须拒绝临时配对链路")
	}
	if !admission.observedDenied(status.PairPublicKey) {
		t.Fatalf("没有观察到临时配对主机被 DERP 拒绝：key=%s denied=%v", status.PairPublicKey, admission.deniedSnapshot())
	}

	// 模拟 cloud authorize 提交三种身份，并精确失效此前缓存的 deny。
	admission.authorize(
		mobilePublic,
		status.PublicKey,
		status.PairPublicKey,
	)

	forwarderConfig := tunnel.ForwarderConfig{
		Address:    pairAddress,
		RemotePort: 8787,
		ListenAddr: "127.0.0.1:0",
		PrivateKey: mobilePrivate,
	}
	forwarder, err := startForwarderUntil(t, 45*time.Second, forwarderConfig)
	if err != nil {
		t.Fatalf("授权后同一配对身份没有恢复：%v admissions=%v", err, admission.cacheSnapshot())
	}
	t.Cleanup(func() { _ = forwarder.Close() })
	if manager.pairHost != pairHost || manager.Status().PairAddress != pairAddress {
		t.Fatal("恢复连接时不应重启或替换临时配对主机")
	}

	pingContext, cancelPing := context.WithTimeout(context.Background(), 10*time.Second)
	diagnostic, err := forwarder.DiscoPing(pingContext)
	cancelPing()
	if err != nil {
		t.Fatal(err)
	}
	if diagnostic.Path != "derp" {
		t.Fatalf("链路没有经过指定 DERP：%+v", diagnostic)
	}

	before := derpCounters(t, derp)
	client := &http.Client{Timeout: 10 * time.Second}
	response, err := client.Get(forwarder.Endpoint() + "/health")
	if err != nil {
		t.Fatal(err)
	}
	body, readErr := io.ReadAll(response.Body)
	response.Body.Close()
	if readErr != nil {
		t.Fatal(readErr)
	}
	if response.StatusCode != http.StatusOK || string(body) != "managed-pairing-ready" {
		t.Fatalf("健康检查异常：status=%d body=%q", response.StatusCode, body)
	}
	after := derpCounters(t, derp)
	if after.BytesReceived <= before.BytesReceived || after.BytesSent <= before.BytesSent {
		t.Fatalf("健康检查没有产生 DERP 转发流量：before=%+v after=%+v", before, after)
	}
}

type admissionFixture struct {
	mu     sync.Mutex
	origin map[string]bool
	cache  map[string]bool
	denied map[string]int
	server *httptest.Server
}

func newAdmissionFixture(t *testing.T) *admissionFixture {
	t.Helper()
	fixture := &admissionFixture{
		origin: make(map[string]bool),
		cache:  make(map[string]bool),
		denied: make(map[string]int),
	}
	fixture.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var request tailcfg.DERPAdmitClientRequest
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		publicKey := request.NodePublic.String()
		fixture.mu.Lock()
		allow, exists := fixture.cache[publicKey]
		if !exists {
			allow = fixture.origin[publicKey]
			fixture.cache[publicKey] = allow
		}
		if !allow {
			fixture.denied[publicKey]++
		}
		fixture.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(tailcfg.DERPAdmitClientResponse{Allow: allow})
	}))
	t.Cleanup(fixture.server.Close)
	return fixture
}

func (f *admissionFixture) authorize(publicKeys ...string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, publicKey := range publicKeys {
		f.origin[publicKey] = true
		delete(f.cache, publicKey)
	}
}

func (f *admissionFixture) observedDenied(publicKey string) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.denied[publicKey] > 0
}

func (f *admissionFixture) deniedSnapshot() map[string]int {
	f.mu.Lock()
	defer f.mu.Unlock()
	result := make(map[string]int, len(f.denied))
	for publicKey, count := range f.denied {
		result[publicKey] = count
	}
	return result
}

func (f *admissionFixture) cacheSnapshot() map[string]bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	result := make(map[string]bool, len(f.cache))
	for publicKey, allow := range f.cache {
		result[publicKey] = allow
	}
	return result
}

func startForwarderUntil(t *testing.T, timeout time.Duration, config tunnel.ForwarderConfig) (*tunnel.Forwarder, error) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	var lastErr error
	for time.Now().Before(deadline) {
		attemptContext, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		forwarder, err := tunnel.StartForwarder(attemptContext, config)
		cancel()
		if err == nil {
			return forwarder, nil
		}
		lastErr = err
		time.Sleep(100 * time.Millisecond)
	}
	return nil, lastErr
}

func startStrictDERP(t *testing.T, verifyURL string) (*derpserver.Server, *tailcfg.DERPRegion) {
	t.Helper()
	server := derpserver.New(key.NewNode(), logger.Discard)
	server.SetVerifyClientURL(verifyURL)
	server.SetVerifyClientURLFailOpen(false)
	handler := derpserver.AddWebSocketSupport(server, derpserver.Handler(server))
	httpServer := httptest.NewUnstartedServer(handler)
	httpServer.Config.TLSNextProto = make(map[string]func(*http.Server, *tls.Conn, http.Handler))
	httpServer.StartTLS()
	t.Cleanup(func() {
		httpServer.CloseClientConnections()
		httpServer.Close()
		server.Close()
	})
	port := httpServer.Listener.Addr().(*net.TCPAddr).Port
	region := &tailcfg.DERPRegion{
		RegionID:   1,
		RegionCode: "strict-test",
		Nodes: []*tailcfg.DERPNode{{
			Name:             "strict-test-1",
			RegionID:         1,
			HostName:         "127.0.0.1",
			IPv4:             "127.0.0.1",
			IPv6:             "none",
			STUNPort:         -1,
			DERPPort:         port,
			InsecureForTests: true,
		}},
	}
	return server, region
}

type trafficCounters struct {
	BytesReceived float64
	BytesSent     float64
	ForwardedIn   float64
	ForwardedOut  float64
}

func derpCounters(t *testing.T, server *derpserver.Server) trafficCounters {
	t.Helper()
	var values map[string]any
	if err := json.Unmarshal([]byte(server.ExpVar(false).String()), &values); err != nil {
		t.Fatal(err)
	}
	value := func(name string) float64 {
		number, ok := values[name].(float64)
		if !ok {
			t.Fatalf("DERP 指标 %s 缺失或类型异常：%v", name, values[name])
		}
		return number
	}
	return trafficCounters{
		BytesReceived: value("bytes_received"),
		BytesSent:     value("bytes_sent"),
		ForwardedIn:   value("packets_forwarded_in"),
		ForwardedOut:  value("packets_forwarded_out"),
	}
}

func (c trafficCounters) String() string {
	return fmt.Sprintf("recv=%.0f sent=%.0f forwarded-in=%.0f forwarded-out=%.0f", c.BytesReceived, c.BytesSent, c.ForwardedIn, c.ForwardedOut)
}
