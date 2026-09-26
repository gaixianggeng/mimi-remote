package httpapi

import (
	"net/http"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
	"github.com/gorilla/websocket"
)

func TestHarnessNativeRouterShutdownClosesConnectionsAndSubscriptions(t *testing.T) {
	stub := newHarnessNativeStreamStub(t)
	url, cwd, router := harnessNativeSessionLimitFixture(t, stub, 2)
	stub.sessions = []harnessclient.SessionSummary{harnessNativeFixtureSession("session-a", cwd)}
	closed := make(chan struct{}, 4)
	stub.muxOpen = func(conn *websocket.Conn, open map[string]any) {
		// 观察订阅关闭，只响应 close/ping；不模拟取消上游任务。
		for {
			if _, _, err := conn.ReadMessage(); err != nil {
				closed <- struct{}{}
				return
			}
		}
	}
	phone := dialHarnessNativeStream(t, url)
	tablet := dialHarnessNativeStream(t, url)
	sendHarnessNativeFollow(t, phone, "phone-follow", "session-a")
	h03Open(t, phone, "events", harnessclient.EndpointEvents, "")
	h03Open(t, phone, "control", harnessNativeEndpointSessionControl, "")
	sendHarnessNativeFollow(t, tablet, "tablet-follow", "session-a")
	waitForHarnessNativeOpens(t, stub, 4)
	waitForHarnessNativeActiveSessions(t, router, 2)

	router.Shutdown()
	router.Shutdown()
	if got := activeHarnessNativeSessions(router); got != 0 {
		t.Fatalf("Router.Shutdown 返回后 follow 名额仍被占用：%d", got)
	}
	if router.harnessNative.acquireSession(2) {
		t.Fatal("关闭后的资源 owner 仍接受新 follow 名额")
	}
	h03AssertTransportClosed(t, phone)
	h03AssertTransportClosed(t, tablet)
	for range 4 {
		awaitHarnessNativeSignal(t, closed, "上游观察订阅未关闭")
	}
	for _, method := range stub.recordedRPCs() {
		if method != harnessclient.MethodSessionList {
			t.Fatalf("关闭观察连接不应触发写 RPC：%s", method)
		}
	}
}

func TestHarnessNativeRouterShutdownRejectsLateConnection(t *testing.T) {
	stub := newHarnessNativeStreamStub(t)
	url, _, router := harnessNativeSessionLimitFixture(t, stub, 1)
	router.Shutdown()
	conn := dialHarnessNativeStream(t, url)
	h03AssertTransportClosed(t, conn)
	if opens, lists := stub.upstreamTouches(); opens != 0 || lists != 0 {
		t.Fatalf("关闭后的新连接访问了上游：opens=%d lists=%d", opens, lists)
	}
}

func TestHarnessNativeClientDisconnectCancelsRelayAuthorization(t *testing.T) {
	stub := newHarnessNativeStreamStub(t)
	started := make(chan struct{})
	cancelled := make(chan struct{})
	release := make(chan struct{})
	stub.beforeRPCReply = func(req *http.Request) {
		close(started)
		select {
		case <-req.Context().Done():
			close(cancelled)
		case <-release:
		}
	}
	stub.muxOpen = func(conn *websocket.Conn, open map[string]any) {
		h03SendUpstream(t, conn, open["streamId"].(string), map[string]any{
			"type": "baseline", "value": map[string]any{
				"queues":      map[string]any{"session-a": []any{}},
				"jobs":        map[string]any{},
				"projections": map[string]any{},
			},
		})
		_, _, _ = conn.ReadMessage()
	}
	url, _ := harnessNativeStreamFixture(t, stub)
	t.Cleanup(func() { close(release) })
	conn := dialHarnessNativeStream(t, url)
	h03Open(t, conn, "control", harnessNativeEndpointSessionControl, "")
	awaitHarnessNativeSignal(t, started, "控制流未开始目录授权")
	_ = conn.Close()
	awaitHarnessNativeSignal(t, cancelled, "移动端断开后目录授权未取消")
}

func TestHarnessNativeRouterShutdownCancelsOpeningSubscription(t *testing.T) {
	stub := newHarnessNativeStreamStub(t)
	started := make(chan struct{})
	cancelled := make(chan struct{})
	release := make(chan struct{})
	stub.beforeRPCReply = func(req *http.Request) {
		close(started)
		select {
		case <-req.Context().Done():
			close(cancelled)
		case <-release:
		}
	}
	url, _, router := harnessNativeSessionLimitFixture(t, stub, 1)
	t.Cleanup(func() { close(release) })
	conn := dialHarnessNativeStream(t, url)
	sendHarnessNativeFollow(t, conn, "follow", "session-a")
	awaitHarnessNativeSignal(t, started, "follow 未开始目录授权")
	if got := activeHarnessNativeSessions(router); got != 1 {
		t.Fatalf("授权期间应持有一个 follow 名额：%d", got)
	}

	shutdown := make(chan struct{})
	go func() {
		router.Shutdown()
		close(shutdown)
	}()
	awaitHarnessNativeSignal(t, cancelled, "Router 关闭后 follow 授权未取消")
	awaitHarnessNativeSignal(t, shutdown, "Router 未等待 follow handler 完成清理")
	if got := activeHarnessNativeSessions(router); got != 0 {
		t.Fatalf("尚未登记的订阅在关闭后未归还名额：%d", got)
	}
	if opens, _ := stub.upstreamTouches(); opens != 0 {
		t.Fatalf("关闭期间建立了上游订阅：%d", opens)
	}
	h03AssertTransportClosed(t, conn)
}

func awaitHarnessNativeSignal(t *testing.T, signal <-chan struct{}, message string) {
	t.Helper()
	select {
	case <-signal:
	case <-time.After(2 * time.Second):
		t.Fatal(message)
	}
}
