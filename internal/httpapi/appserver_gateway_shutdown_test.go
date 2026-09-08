package httpapi

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestRouterShutdownClosesRegisteredCodexGateways(t *testing.T) {
	transport := &shutdownTrackingAppServerTransport{}
	router := &Router{
		appServerSSH:  transport,
		codexGateways: map[uint64]*codexGatewayConnection{},
	}
	connection, connectionCtx, err := router.acquireCodexGateway(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	client := &trackingCloser{}
	upstream := &trackingCloser{}
	if !connection.attach(client, true) || !connection.attach(upstream, false) {
		t.Fatal("shutdown 前应能登记两端连接")
	}
	released := make(chan struct{})
	go func() {
		<-connectionCtx.Done()
		router.releaseCodexGateway(connection)
		close(released)
	}()

	router.Shutdown()
	router.Shutdown()

	select {
	case <-released:
	case <-time.After(time.Second):
		t.Fatal("Router shutdown 未结束 gateway handler")
	}
	if !client.closed.Load() || !upstream.closed.Load() {
		t.Fatalf("Router shutdown 必须关闭 client 和 upstream：client=%t upstream=%t", client.closed.Load(), upstream.closed.Load())
	}
	if !transport.shutdown.Load() {
		t.Fatal("Router shutdown 必须取消 SSH transport 的后台 readiness")
	}
	if got := router.activeCodexGatewayCount(); got != 0 {
		t.Fatalf("Router shutdown 后 gateway 数量必须归零：%d", got)
	}
	if _, _, err := router.acquireCodexGateway(context.Background()); !errors.Is(err, errCodexGatewayClosing) {
		t.Fatalf("Router shutdown 后必须拒绝新 gateway：%v", err)
	}
}

func TestRouterShutdownClosesMultipleLiveCodexGatewayWebSockets(t *testing.T) {
	upstreamURL, _, upstreamConnections := fakeAppServerUpstream(t, nil)
	handler, router := appServerGatewayRouterFixtureWithRouter(t, upstreamURL, nil)
	server := httptest.NewServer(handler)
	defer server.Close()

	clients := []*websocket.Conn{
		dialAuthedGateway(t, server.URL),
		dialAuthedGateway(t, server.URL),
	}
	deadline := time.Now().Add(time.Second)
	for (router.activeCodexGatewayCount() != len(clients) || upstreamConnections.Load() != int64(len(clients))) && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if got := router.activeCodexGatewayCount(); got != len(clients) {
		t.Fatalf("shutdown 前应登记所有活动 gateway：got=%d want=%d", got, len(clients))
	}
	if got := upstreamConnections.Load(); got != int64(len(clients)) {
		t.Fatalf("每条 gateway 应建立一条 upstream：got=%d want=%d", got, len(clients))
	}

	router.Shutdown()
	if got := router.activeCodexGatewayCount(); got != 0 {
		t.Fatalf("shutdown 返回时活动 gateway 应归零：%d", got)
	}
	for _, client := range clients {
		_ = client.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
		if _, _, err := client.ReadMessage(); err == nil {
			t.Fatal("shutdown 后移动端 WebSocket 应关闭")
		}
		_ = client.Close()
	}

	target := wsURL(server.URL, appServerGatewayPath)
	conn, response, err := websocket.DefaultDialer.Dial(target, http.Header{
		"Authorization": []string{"Bearer " + testToken},
	})
	if conn != nil {
		_ = conn.Close()
	}
	if err == nil || response == nil || response.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("shutdown 后新连接应收到 503：response=%v err=%v", response, err)
	}
	_ = response.Body.Close()
}

type trackingCloser struct {
	closed atomic.Bool
}

func (c *trackingCloser) Close() error {
	c.closed.Store(true)
	return nil
}

type shutdownTrackingAppServerTransport struct {
	shutdown atomic.Bool
}

func (t *shutdownTrackingAppServerTransport) EnsureReady(context.Context) error {
	return nil
}

func (t *shutdownTrackingAppServerTransport) WebSocketURL() (string, error) {
	return "", errors.New("shutdown transport 不提供 upstream")
}

func (t *shutdownTrackingAppServerTransport) WebSocketHeaders() (http.Header, error) {
	return nil, nil
}

func (t *shutdownTrackingAppServerTransport) WebSocketDialer(time.Duration) (websocket.Dialer, error) {
	return websocket.Dialer{}, nil
}

func (t *shutdownTrackingAppServerTransport) Shutdown() {
	t.shutdown.Store(true)
}
