package tunnel

import (
	"context"
	"crypto/tls"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"tailscale.com/derp/derpserver"
	"tailscale.com/tailcfg"
	"tailscale.com/tstest/integration"
	"tailscale.com/types/key"
)

type hostEventRecorder struct {
	mu     sync.Mutex
	events []HostEvent
}

func (r *hostEventRecorder) record(event HostEvent) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.events = append(r.events, event)
}

func (r *hostEventRecorder) names() map[string]HostEvent {
	r.mu.Lock()
	defer r.mu.Unlock()
	names := make(map[string]HostEvent, len(r.events))
	for _, event := range r.events {
		names[event.Name] = event
	}
	return names
}

// 上游日志格式串一旦变化，事件会静默消失；这里用真实握手钉住关键事件。
func TestHostEmitsConnectionEventsFromRealHandshake(t *testing.T) {
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	defer backend.Close()
	backendURL, err := url.Parse(backend.URL)
	if err != nil {
		t.Fatal(err)
	}
	derpMap := integration.RunDERPAndSTUN(t, t.Logf, "127.0.0.1")
	temporary := t.TempDir()
	clientIdentity := filepath.Join(temporary, "client.json")
	clientPrivate, err := LoadOrCreateClientIdentity(clientIdentity)
	if err != nil {
		t.Fatal(err)
	}
	recorder := &hostEventRecorder{}
	host, err := StartHost(HostConfig{
		TargetAddr:        backendURL.Host,
		RemotePort:        8787,
		IdentityPath:      filepath.Join(temporary, "host.json"),
		AddressPath:       filepath.Join(temporary, "address"),
		AllowedClientKeys: []string{clientPrivate.Public().String()},
		Region:            derpMap.Regions[1],
		Events:            recorder.record,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer host.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	forwarder, err := StartForwarder(ctx, ForwarderConfig{
		Address:      host.Address(),
		IdentityPath: clientIdentity,
		ListenAddr:   "127.0.0.1:0",
		RemotePort:   8787,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer forwarder.Close()

	client := &http.Client{Timeout: 20 * time.Second, Transport: &http.Transport{DisableKeepAlives: true}}
	response, err := client.Get(forwarder.Endpoint() + "/")
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()

	deadline := time.Now().Add(15 * time.Second)
	want := []string{HostEventPeerContact, HostEventDERPConnected, HostEventConnOpened, HostEventConnClosed}
	for {
		names := recorder.names()
		missing := ""
		for _, name := range want {
			if _, ok := names[name]; !ok {
				missing = name
			}
		}
		if missing == "" {
			if peer := names[HostEventPeerContact].Peer; peer != clientPrivate.Public().ShortString() {
				t.Fatalf("peer_contact 短公钥不对：%q", peer)
			}
			if region := names[HostEventDERPConnected].Region; region != 1 {
				t.Fatalf("derp_connected 区域号不对：%d", region)
			}
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("缺少事件 %s，已有 %+v", missing, names)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// 排查时最需要回答的问题：断的是中继还是设备。设备消失时 Mac 与中继的连接不受影响，
// 不应出现 derp 断开事件；中继断开时必须留下 derp_lost。
func TestHostEventsDistinguishRelayLossFromClientLoss(t *testing.T) {
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	defer backend.Close()
	backendURL, err := url.Parse(backend.URL)
	if err != nil {
		t.Fatal(err)
	}
	relay, region := startClosableRelay(t)
	temporary := t.TempDir()
	clientIdentity := filepath.Join(temporary, "client.json")
	clientPrivate, err := LoadOrCreateClientIdentity(clientIdentity)
	if err != nil {
		t.Fatal(err)
	}
	recorder := &hostEventRecorder{}
	host, err := StartHost(HostConfig{
		TargetAddr:        backendURL.Host,
		RemotePort:        8787,
		IdentityPath:      filepath.Join(temporary, "host.json"),
		AddressPath:       filepath.Join(temporary, "address"),
		AllowedClientKeys: []string{clientPrivate.Public().String()},
		Region:            region,
		Events:            recorder.record,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer host.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	forwarder, err := StartForwarder(ctx, ForwarderConfig{
		Address:      host.Address(),
		IdentityPath: clientIdentity,
		ListenAddr:   "127.0.0.1:0",
		RemotePort:   8787,
	})
	if err != nil {
		t.Fatal(err)
	}
	client := &http.Client{Timeout: 20 * time.Second, Transport: &http.Transport{DisableKeepAlives: true}}
	response, err := client.Get(forwarder.Endpoint() + "/")
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	waitForHostEvent(t, recorder, HostEventDERPConnected)

	forwarder.Close()
	time.Sleep(3 * time.Second)
	if event, ok := recorder.names()[HostEventDERPLost]; ok {
		t.Fatalf("设备消失不应产生中继断开事件：%+v", event)
	}

	relay.Close()
	lost := waitForHostEvent(t, recorder, HostEventDERPLost)
	if lost.Region != int(region.RegionID) || lost.Reason == "" {
		t.Fatalf("derp_lost 字段不完整：%+v", lost)
	}
}

func waitForHostEvent(t *testing.T, recorder *hostEventRecorder, name string) HostEvent {
	t.Helper()
	deadline := time.Now().Add(20 * time.Second)
	for {
		names := recorder.names()
		if event, ok := names[name]; ok {
			return event
		}
		if time.Now().After(deadline) {
			t.Fatalf("等待事件 %s 超时，已有 %+v", name, names)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// integration.RunDERPAndSTUN 不暴露服务器，测试无法主动切断客户端连接，这里单独起一个。
// DERP 连接已被 hijack，httptest 不再持有，只能通过关闭 DERP 服务本身来断开。
func startClosableRelay(t *testing.T) (*derpserver.Server, *tailcfg.DERPRegion) {
	t.Helper()
	derp := derpserver.New(key.NewNode(), t.Logf)
	server := httptest.NewUnstartedServer(derpserver.Handler(derp))
	server.Config.TLSNextProto = make(map[string]func(*http.Server, *tls.Conn, http.Handler))
	server.StartTLS()
	t.Cleanup(func() {
		server.CloseClientConnections()
		server.Close()
		derp.Close()
	})
	return derp, &tailcfg.DERPRegion{
		RegionID:   1,
		RegionCode: "test",
		Nodes: []*tailcfg.DERPNode{{
			Name:             "t1",
			RegionID:         1,
			HostName:         "127.0.0.1",
			IPv4:             "127.0.0.1",
			IPv6:             "none",
			STUNPort:         -1,
			DERPPort:         server.Listener.Addr().(*net.TCPAddr).Port,
			InsecureForTests: true,
		}},
	}
}
