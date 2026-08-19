package httpapi

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gorilla/websocket"
)

const brokerTestSession = "mimi-broker-test-codex"

const (
	brokerTurnStartedFrame = `{"jsonrpc":"2.0","method":"turn/started","params":{"threadId":"thread-1","turnId":"turn-1"}}`
	brokerTurnDoneFrame    = `{"jsonrpc":"2.0","method":"turn/completed","params":{"threadId":"thread-1","turnId":"turn-1"}}`
	brokerApprovalFrame    = `{"jsonrpc":"2.0","id":"approval-1","method":"execCommandApproval","params":{"threadId":"thread-1","turnId":"turn-1","callId":"call-1","command":"ls"}}`
	brokerResolvedFrame    = `{"jsonrpc":"2.0","method":"serverRequest/resolved","params":{"requestId":"approval-1","threadId":"thread-1"}}`
)

// brokerUpstream 把上游连接交给用例本身。gateway 的客户端方法白名单会挡掉自造的
// 触发帧，所以事件必须由上游侧主动推送，才能复现「客户端离线后上游继续说话」。
type brokerUpstream struct {
	url    string
	conns  chan *websocket.Conn
	closed chan struct{}
	// frames 是上游收到的客户端帧。用例不能自己再读一次连接：gorilla 不支持
	// 并发读，服务端读循环必须是唯一读者。
	frames      chan []byte
	connections *atomic.Int64
}

func newBrokerUpstream(t *testing.T) *brokerUpstream {
	t.Helper()
	up := &brokerUpstream{
		conns:       make(chan *websocket.Conn, 4),
		closed:      make(chan struct{}, 4),
		frames:      make(chan []byte, 32),
		connections: &atomic.Int64{},
	}
	upgrader := websocket.Upgrader{CheckOrigin: func(r *http.Request) bool { return true }}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		up.connections.Add(1)
		conn, err := upgrader.Upgrade(w, req, nil)
		if err != nil {
			return
		}
		defer func() {
			conn.Close()
			select {
			case up.closed <- struct{}{}:
			default:
			}
		}()
		select {
		case up.conns <- conn:
		default:
		}
		// 持续读取才能让 gorilla 自动应答 gateway 的 ping；同时与用例侧的写并发安全。
		for {
			_, payload, err := conn.ReadMessage()
			if err != nil {
				return
			}
			select {
			case up.frames <- append([]byte(nil), payload...):
			default:
			}
		}
	}))
	t.Cleanup(server.Close)
	up.url = wsURL(server.URL, "/")
	return up
}

func (u *brokerUpstream) accept(t *testing.T) *websocket.Conn {
	t.Helper()
	select {
	case conn := <-u.conns:
		return conn
	case <-time.After(3 * time.Second):
		t.Fatal("上游没有收到 gateway 连接")
		return nil
	}
}

func (u *brokerUpstream) emit(t *testing.T, conn *websocket.Conn, frame string) {
	t.Helper()
	if err := conn.WriteMessage(websocket.TextMessage, []byte(frame)); err != nil {
		t.Fatalf("上游推送失败: %v", err)
	}
}

func brokerTestServer(t *testing.T, upstreamURL string, enabled bool) (*httptest.Server, *Router) {
	t.Helper()
	handler, router := appServerGatewayRouterFixtureWithRouter(t, upstreamURL, func(cfg *config.Config) {
		cfg.AppServer.ApprovalBroker = enabled
	})
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	return server, router
}

func brokerDial(t *testing.T, server *httptest.Server, session string) *websocket.Conn {
	t.Helper()
	target := wsURL(server.URL, appServerGatewayPath)
	if session != "" {
		target += "?session=" + session
	}
	conn, resp, err := websocket.DefaultDialer.Dial(target, http.Header{
		"Authorization": []string{"Bearer " + testToken},
	})
	if err != nil {
		t.Fatalf("dial %s failed: %v resp=%v", target, err, resp)
	}
	t.Cleanup(func() { _ = conn.Close() })
	return conn
}

// readFrameWithMethod 跳过与本用例无关的帧，只等待目标 method 到达。
func readFrameWithMethod(t *testing.T, conn *websocket.Conn, method string, timeout time.Duration) []byte {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for {
		_ = conn.SetReadDeadline(deadline)
		_, payload, err := conn.ReadMessage()
		if err != nil {
			t.Fatalf("等待 %s 时读失败: %v", method, err)
		}
		var frame struct {
			Method string `json:"method"`
		}
		if err := json.Unmarshal(payload, &frame); err != nil {
			continue
		}
		if strings.TrimSpace(frame.Method) == method {
			return payload
		}
	}
}

func waitForBroker(t *testing.T, router *Router, key string, want bool) *codexGatewayBroker {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for {
		router.codexBrokerMu.Lock()
		broker, ok := router.codexBrokers[key]
		router.codexBrokerMu.Unlock()
		if ok == want {
			return broker
		}
		if time.Now().After(deadline) {
			t.Fatalf("broker 存在状态 = %v，期望 %v", ok, want)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func waitForPendingCount(t *testing.T, broker *codexGatewayBroker, want int, message string) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for {
		if broker.pendingCount() == want {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("%s（当前 pending=%d，期望 %d）", message, broker.pendingCount(), want)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// 这是 MIM-112 的核心行为：iOS 退到后台后上游连接必须继续存活并接住审批请求，
// 重连时把仍然有效的请求原样重放回来。
func TestCodexGatewayBrokerSurvivesClientDetachAndReplaysApproval(t *testing.T) {
	up := newBrokerUpstream(t)
	server, router := brokerTestServer(t, up.url, true)

	first := brokerDial(t, server, brokerTestSession)
	upstream := up.accept(t)
	up.emit(t, upstream, brokerTurnStartedFrame)
	readFrameWithMethod(t, first, "turn/started", 3*time.Second)

	// 客户端在审批请求到达前离线，模拟 App 退到后台被系统挂起。
	_ = first.Close()
	broker := waitForBroker(t, router, brokerTestSession, true)

	// 离线之后上游才发出审批请求：一对一代理在这一步早已把上游关掉。
	up.emit(t, upstream, brokerApprovalFrame)
	waitForPendingCount(t, broker, 1, "离线期间到达的审批请求没有被 broker 接住")

	second := brokerDial(t, server, brokerTestSession)
	replayed := readFrameWithMethod(t, second, "execCommandApproval", 3*time.Second)
	var frame struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(replayed, &frame); err != nil {
		t.Fatal(err)
	}
	if frame.ID != "approval-1" {
		t.Fatalf("重放的请求 id = %q，期望保持原 id 才能被应答", frame.ID)
	}
	if got := up.connections.Load(); got != 1 {
		t.Fatalf("重连不应重新拨号上游，upstream connections = %d", got)
	}
}

// 没有活跃 turn 也没有待审批请求时，broker 不能继续占住上游连接。
func TestCodexGatewayBrokerReleasesUpstreamWhenIdle(t *testing.T) {
	up := newBrokerUpstream(t)
	server, router := brokerTestServer(t, up.url, true)

	conn := brokerDial(t, server, brokerTestSession)
	upstream := up.accept(t)
	up.emit(t, upstream, brokerTurnStartedFrame)
	readFrameWithMethod(t, conn, "turn/started", 3*time.Second)
	up.emit(t, upstream, brokerTurnDoneFrame)
	readFrameWithMethod(t, conn, "turn/completed", 3*time.Second)
	_ = conn.Close()

	waitForBroker(t, router, brokerTestSession, false)
	select {
	case <-up.closed:
	case <-time.After(3 * time.Second):
		t.Fatal("空闲会话断开后上游连接没有被回收")
	}
}

// 审批在离线期间被上游解决后，重连不能再把它重放成一张可操作的卡片。
func TestCodexGatewayBrokerDropsResolvedApprovalBeforeReplay(t *testing.T) {
	up := newBrokerUpstream(t)
	server, router := brokerTestServer(t, up.url, true)

	first := brokerDial(t, server, brokerTestSession)
	upstream := up.accept(t)
	up.emit(t, upstream, brokerTurnStartedFrame)
	readFrameWithMethod(t, first, "turn/started", 3*time.Second)
	_ = first.Close()

	broker := waitForBroker(t, router, brokerTestSession, true)
	up.emit(t, upstream, brokerApprovalFrame)
	waitForPendingCount(t, broker, 1, "审批请求没有被 broker 接住")
	up.emit(t, upstream, brokerResolvedFrame)
	waitForPendingCount(t, broker, 0, "已解决的审批仍留在重放队列里")

	second := brokerDial(t, server, brokerTestSession)
	_ = second.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
	if _, payload, err := second.ReadMessage(); err == nil {
		t.Fatalf("已解决的审批不应重放：%s", payload)
	}
}

// 关闭开关时必须逐字保持今天的一对一代理语义。
func TestCodexGatewayBrokerDisabledKeepsOneToOneProxy(t *testing.T) {
	up := newBrokerUpstream(t)
	server, router := brokerTestServer(t, up.url, false)

	first := brokerDial(t, server, brokerTestSession)
	firstUpstream := up.accept(t)
	up.emit(t, firstUpstream, brokerTurnStartedFrame)
	readFrameWithMethod(t, first, "turn/started", 3*time.Second)
	_ = first.Close()

	select {
	case <-up.closed:
	case <-time.After(3 * time.Second):
		t.Fatal("未启用 broker 时客户端断开必须同时关闭上游")
	}
	router.codexBrokerMu.Lock()
	brokerCount := len(router.codexBrokers)
	router.codexBrokerMu.Unlock()
	if brokerCount != 0 {
		t.Fatalf("未启用 broker 时不应登记任何 broker，got=%d", brokerCount)
	}

	second := brokerDial(t, server, brokerTestSession)
	secondUpstream := up.accept(t)
	up.emit(t, secondUpstream, brokerTurnStartedFrame)
	readFrameWithMethod(t, second, "turn/started", 3*time.Second)
	if got := up.connections.Load(); got != 2 {
		t.Fatalf("未启用 broker 时每次连接都应重新拨号，got=%d", got)
	}
}

// 同名会话再次连接时，旧连接必须被顶下线，否则上游响应会分裂到两个客户端。
func TestCodexGatewayBrokerReplacesPreviousSink(t *testing.T) {
	up := newBrokerUpstream(t)
	server, _ := brokerTestServer(t, up.url, true)

	first := brokerDial(t, server, brokerTestSession)
	upstream := up.accept(t)
	up.emit(t, upstream, brokerTurnStartedFrame)
	readFrameWithMethod(t, first, "turn/started", 3*time.Second)

	second := brokerDial(t, server, brokerTestSession)
	up.emit(t, upstream, brokerTurnStartedFrame)
	readFrameWithMethod(t, second, "turn/started", 3*time.Second)

	_ = first.SetReadDeadline(time.Now().Add(3 * time.Second))
	if _, _, err := first.ReadMessage(); err == nil {
		t.Fatal("同名会话的旧连接应被顶下线")
	}
}

// waitForUpstreamFrame 等待上游收到满足条件的客户端帧。
func (u *brokerUpstream) waitForUpstreamFrame(t *testing.T, match func([]byte) bool, timeout time.Duration) []byte {
	t.Helper()
	deadline := time.After(timeout)
	for {
		select {
		case payload := <-u.frames:
			if match(payload) {
				return payload
			}
		case <-deadline:
			t.Fatal("上游没有收到期望的客户端帧")
			return nil
		}
	}
}
