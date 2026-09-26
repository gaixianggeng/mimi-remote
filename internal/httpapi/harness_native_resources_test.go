package httpapi

import (
	"net/http"
	"sync/atomic"
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

func TestHarnessNativeClientDisconnectCancelsOpeningSubscription(t *testing.T) {
	for _, graceful := range []bool{false, true} {
		name := "socket-close"
		if graceful {
			name = "normal-close-frame"
		}
		t.Run(name, func(t *testing.T) {
			stub := newHarnessNativeStreamStub(t)
			started := make(chan struct{})
			cancelled := make(chan struct{})
			release := make(chan struct{})
			var calls atomic.Int32
			stub.beforeRPCReply = func(req *http.Request) {
				if calls.Add(1) != 1 {
					return
				}
				close(started)
				select {
				case <-req.Context().Done():
					close(cancelled)
				case <-release:
				}
			}
			url, cwd, router := harnessNativeSessionLimitFixture(t, stub, 1)
			t.Cleanup(func() { close(release) })
			t.Cleanup(router.Shutdown)
			stub.sessions = []harnessclient.SessionSummary{harnessNativeFixtureSession("session-a", cwd)}
			stub.muxOpen = func(conn *websocket.Conn, open map[string]any) {
				h03SendUpstream(t, conn, open["streamId"].(string), map[string]any{
					"type": "snapshot", "header": map[string]any{"id": "session-a", "cwd": cwd},
					"records": []any{}, "cursor": 0,
				})
				_, _, _ = conn.ReadMessage()
			}
			conn := dialHarnessNativeStream(t, url)
			sendHarnessNativeFollow(t, conn, "follow", "session-a")
			awaitHarnessNativeSignal(t, started, "follow 未开始目录授权")
			if graceful {
				if err := conn.WriteMessage(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.CloseNormalClosure, "")); err != nil {
					t.Fatal(err)
				}
			} else {
				_ = conn.Close()
			}
			awaitHarnessNativeSignal(t, cancelled, "移动端断开后打开中的 follow 授权未取消")
			waitForHarnessNativeActiveSessions(t, router, 0)
			if opens, _ := stub.upstreamTouches(); opens != 0 {
				t.Fatalf("已断开的连接建立了上游订阅：%d", opens)
			}

			// 用真实重连证明旧请求已归还名额，而不只检查内部计数。
			reconnected := dialHarnessNativeStream(t, url)
			sendHarnessNativeFollow(t, reconnected, "follow", "session-a")
			if value := h03Value(t, readHarnessNativeFrame(t, reconnected)); value["type"] != "snapshot" {
				t.Fatalf("重连未恢复订阅：%v", value)
			}
		})
	}
}

func TestHarnessNativeClientDisconnectCancelsRespond(t *testing.T) {
	for _, phase := range []string{"authorization", "result"} {
		t.Run(phase, func(t *testing.T) {
			stub := newHarnessNativeStreamStub(t)
			started := make(chan struct{})
			cancelled := make(chan struct{})
			release := make(chan struct{})
			var lists atomic.Int32
			stub.beforeRPCReply = func(req *http.Request) {
				isRespondAuthorization := req.URL.Path == "/api/session/list" && lists.Add(1) == 2
				if !(phase == "authorization" && isRespondAuthorization) &&
					!(phase == "result" && req.URL.Path == "/api/$events/result") {
					return
				}
				close(started)
				select {
				case <-req.Context().Done():
					close(cancelled)
				case <-release:
				}
			}
			stub.muxOpen = func(conn *websocket.Conn, open map[string]any) {
				id := open["streamId"].(string)
				h03SendUpstream(t, conn, id, map[string]any{"type": "ready", "clientId": "client-a"})
				h03SendUpstream(t, conn, id, h03Approval("session-a", "event-a"))
				_, _, _ = conn.ReadMessage()
			}
			url, cwd, router := harnessNativeSessionLimitFixture(t, stub, 1)
			t.Cleanup(func() { close(release) })
			t.Cleanup(router.Shutdown)
			stub.sessions = []harnessclient.SessionSummary{harnessNativeFixtureSession("session-a", cwd)}
			conn := dialHarnessNativeStream(t, url)
			h03Open(t, conn, "events", harnessclient.EndpointEvents, "")
			_ = h03Value(t, readHarnessNativeFrame(t, conn))
			if value := h03Value(t, readHarnessNativeFrame(t, conn)); value["eventId"] != "event-a" {
				t.Fatalf("交互未投递：%v", value)
			}
			sendHarnessNativeFrame(t, conn, map[string]any{
				"type": "respond", "eventId": "event-a", "outcome": map[string]any{"kind": "result", "value": "allowed-once"},
			})
			awaitHarnessNativeSignal(t, started, "应答未进入预期 RPC")
			_ = conn.Close()
			awaitHarnessNativeSignal(t, cancelled, "移动端断开后应答 RPC 未取消")
			router.Shutdown()
			results := 0
			for _, method := range stub.recordedRPCs() {
				if method == harnessclient.EndpointEventsResult {
					results++
				}
			}
			want := 0
			if phase == "result" {
				want = 1
			}
			if results != want {
				t.Fatalf("断线后不应继续或重试应答：result RPC=%d，期望 %d", results, want)
			}
		})
	}
}

func TestHarnessNativeQueuedFramesPreserveOpenCancelOrder(t *testing.T) {
	stub := newHarnessNativeStreamStub(t)
	started := make(chan struct{})
	release := make(chan struct{})
	var calls atomic.Int32
	stub.beforeRPCReply = func(req *http.Request) {
		if calls.Add(1) != 1 {
			return
		}
		close(started)
		select {
		case <-req.Context().Done():
		case <-release:
		}
	}
	stub.muxOpen = func(conn *websocket.Conn, _ map[string]any) {
		_, _, _ = conn.ReadMessage()
	}
	url, cwd, router := harnessNativeSessionLimitFixture(t, stub, 1)
	t.Cleanup(router.Shutdown)
	stub.sessions = []harnessclient.SessionSummary{harnessNativeFixtureSession("session-a", cwd)}
	conn := dialHarnessNativeStream(t, url)
	sendHarnessNativeFollow(t, conn, "follow", "session-a")
	awaitHarnessNativeSignal(t, started, "follow 未开始目录授权")
	sendHarnessNativeFrame(t, conn, map[string]any{"type": "cancel", "streamId": "follow"})
	sendHarnessNativeFollow(t, conn, "follow", "session-a")
	close(release)
	if frame := readHarnessNativeFrame(t, conn); frame["type"] != harnessclient.CarrierEnd || frame["streamId"] != "follow" {
		t.Fatalf("应先完成旧 follow 的退订：%v", frame)
	}
	waitForHarnessNativeOpens(t, stub, 2)
	waitForHarnessNativeActiveSessions(t, router, 1)
	if _, lists := stub.upstreamTouches(); lists != 2 {
		t.Fatalf("复用 streamId 的第二次订阅未按顺序授权：lists=%d", lists)
	}
}

func TestHarnessNativePendingFrameOverflowCancelsOpeningSubscription(t *testing.T) {
	stub := newHarnessNativeStreamStub(t)
	started := make(chan struct{})
	cancelled := make(chan struct{})
	stub.beforeRPCReply = func(req *http.Request) {
		close(started)
		<-req.Context().Done()
		close(cancelled)
	}
	url, _, router := harnessNativeSessionLimitFixture(t, stub, 1)
	t.Cleanup(router.Shutdown)
	conn := dialHarnessNativeStream(t, url)
	sendHarnessNativeFollow(t, conn, "follow", "session-a")
	awaitHarnessNativeSignal(t, started, "follow 未开始目录授权")
	for range harnessNativeWSMaxPendingFrames + 1 {
		if err := conn.WriteJSON(map[string]any{"type": "cancel", "streamId": "follow"}); err != nil {
			break // 服务端已因缓冲超限关连接，后续断言仍须证明 RPC 和名额已回收。
		}
	}
	awaitHarnessNativeSignal(t, cancelled, "缓冲超限后授权 RPC 未取消")
	waitForHarnessNativeActiveSessions(t, router, 0)
	h03AssertTransportClosed(t, conn)
	if opens, _ := stub.upstreamTouches(); opens != 0 {
		t.Fatalf("关闭期间建立了上游订阅：%d", opens)
	}
}

func awaitHarnessNativeSignal(t *testing.T, signal <-chan struct{}, message string) {
	t.Helper()
	select {
	case <-signal:
	case <-time.After(2 * time.Second):
		t.Fatal(message)
	}
}
