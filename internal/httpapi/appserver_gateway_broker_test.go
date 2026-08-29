package httpapi

import (
	"bytes"
	"encoding/json"
	"fmt"
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

// 用户可能在 turn/start 已写入上游、但 turn/started 尚未返回时立刻锁屏。
// 这段窗口内 broker 也必须保留上游，否则任务只会在 App 重连后继续。
func TestCodexGatewayBrokerSurvivesDetachBeforeTurnStarted(t *testing.T) {
	up := newBrokerUpstream(t)
	handler, router, projectDir := buildAppServerGatewayFixture(t, up.url, func(cfg *config.Config) {
		cfg.AppServer.ApprovalBroker = true
	})
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)

	client := brokerDial(t, server, brokerTestSession)
	upstream := up.accept(t)
	broker := waitForBroker(t, router, brokerTestSession, true)
	scope, ok := router.gatewayScopeForPath(projectDir)
	if !ok {
		t.Fatal("测试项目目录应命中 gateway scope")
	}
	broker.policy.allowThread(appServerGatewayAllowedThread{
		id: "thread-1", runtimeID: "codex", cwd: projectDir, scopeID: scope.id,
	})
	turnStart := fmt.Sprintf(
		`{"jsonrpc":"2.0","id":"turn-start-1","method":"turn/start","params":{"threadId":"thread-1","cwd":%q,"input":[{"type":"text","text":"需要审批"}],"approvalPolicy":"on-request","approvalsReviewer":"user","sandboxPolicy":{"type":"workspaceWrite","writableRoots":[%q],"networkAccess":false}}}`,
		projectDir,
		projectDir,
	)
	if err := client.WriteMessage(websocket.TextMessage, []byte(turnStart)); err != nil {
		t.Fatal(err)
	}
	select {
	case forwarded := <-up.frames:
		var frame appServerGatewayFrame
		if json.Unmarshal(forwarded, &frame) != nil || frame.Method != "turn/start" {
			t.Fatalf("上游没有收到 turn/start：%s", forwarded)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("上游没有收到 turn/start")
	}

	// 在上游来得及发 turn/started 前锁屏断线。
	_ = client.Close()
	deadline := time.Now().Add(3 * time.Second)
	for {
		broker.mu.Lock()
		detached := broker.sink == nil
		closed := broker.closed
		broker.mu.Unlock()
		if detached {
			if closed {
				t.Fatal("turn/start 已转发但 turn/started 未到达时，broker 不应回收上游")
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("客户端断开后 broker 没有进入 detached 状态")
		}
		time.Sleep(10 * time.Millisecond)
	}

	// 上游在客户端离线后才确认 turn 并发出审批。
	up.emit(t, upstream, brokerTurnStartedFrame)
	up.emit(t, upstream, brokerApprovalFrame)
	waitForPendingCount(t, broker, 1, "turn/started 前断线后到达的审批没有被 broker 接住")
}

func TestCodexGatewayBrokerClearsStartingTurnWhenUpstreamRejectsStart(t *testing.T) {
	b := &codexGatewayBroker{startingTurns: map[string]string{"thread-1": `"turn-start-1"`}}
	b.observeLifecycle(websocket.TextMessage, []byte(
		`{"jsonrpc":"2.0","id":"turn-start-1","error":{"code":-32602,"message":"invalid params"}}`,
	))
	if len(b.startingTurns) != 0 {
		t.Fatalf("上游明确拒绝 turn/start 后应撤销启动占位：%v", b.startingTurns)
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

func TestCodexGatewayBrokerSerializesSinkReplacementWithClientFrame(t *testing.T) {
	oldSink := &codexGatewaySink{done: make(chan string, 1)}
	newSink := &codexGatewaySink{done: make(chan string, 1)}
	broker := &codexGatewayBroker{
		sink:             oldSink,
		pending:          map[string][]byte{},
		pendingDelivered: map[string]*codexGatewaySink{},
	}

	// 模拟旧连接已经读到一帧并开始处理。接管必须等这帧完成，之后旧连接的
	// authorizer 必须稳定失败，不能在 replay 期间继续消费 policy 或写上游。
	broker.clientFrameMu.Lock()
	attached := make(chan bool, 1)
	go func() { attached <- broker.attach(newSink) }()
	select {
	case <-attached:
		t.Fatal("sink 接管不能越过仍在处理的旧客户端帧")
	case <-time.After(100 * time.Millisecond):
	}
	broker.clientFrameMu.Unlock()

	select {
	case ok := <-attached:
		if !ok {
			t.Fatal("新 sink 应成功接管")
		}
	case <-time.After(3 * time.Second):
		t.Fatal("旧客户端帧结束后 sink 接管没有完成")
	}
	if broker.acceptsClientFrame(oldSink) {
		t.Fatal("新 sink 发布后旧 sink 不得保留上游写权限")
	}
	if !broker.acceptsClientFrame(newSink) {
		t.Fatal("新 sink 应取得上游写权限")
	}
}

func TestCodexGatewayBrokerSweepDecisionAlwaysReleasesLock(t *testing.T) {
	attached := &codexGatewayBroker{sink: &codexGatewaySink{}}
	if reason := attached.sweepCloseReason(time.Now()); reason != "" {
		t.Fatalf("在线 broker 不应被 sweep 回收：%s", reason)
	}
	lockAvailable := make(chan struct{})
	go func() {
		attached.mu.Lock()
		attached.mu.Unlock()
		close(lockAvailable)
	}()
	select {
	case <-lockAvailable:
	case <-time.After(time.Second):
		t.Fatal("在线 broker 执行 sweep 后泄漏了 b.mu")
	}

	expired := &codexGatewayBroker{detachedAt: time.Now().Add(-codexGatewayBrokerDetachTTL - time.Second)}
	if reason := expired.sweepCloseReason(time.Now()); reason != "broker_detach_ttl" {
		t.Fatalf("超时 broker close reason = %q", reason)
	}
	expired.mu.Lock()
	expired.mu.Unlock()

	idle := &codexGatewayBroker{
		detachedAt:       time.Now(),
		startingTurns:    map[string]string{},
		activeTurns:      map[string]struct{}{},
		pending:          map[string][]byte{},
		pendingDelivered: map[string]*codexGatewaySink{},
	}
	if reason := idle.sweepCloseReason(time.Now()); reason != "broker_idle_expired" {
		t.Fatalf("空闲 broker close reason = %q", reason)
	}
	idle.mu.Lock()
	idle.mu.Unlock()
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

// 真机验证抓到的崩溃：客户端离线时（sink 为 nil）收到一条被策略拒绝的上游帧，
// pumpUpstream 会去读 sink.monitor 字段——从 nil 指针取字段直接 SIGSEGV，
// 整个 agentd 一起死。而「客户端离线」正是 broker 存在的意义，不是边角情况。
func TestCodexGatewayBrokerSurvivesRejectedFrameWhileDetached(t *testing.T) {
	up := newBrokerUpstream(t)
	server, router := brokerTestServer(t, up.url, true)

	first := brokerDial(t, server, brokerTestSession)
	upstream := up.accept(t)
	up.emit(t, upstream, brokerTurnStartedFrame)
	readFrameWithMethod(t, first, "turn/started", 3*time.Second)
	_ = first.Close()
	broker := waitForBroker(t, router, brokerTestSession, true)

	// 未被移动端支持的反向请求：policy 会拒绝它并要求回错误，走的正是崩溃那条分支。
	up.emit(t, upstream, `{"jsonrpc":"2.0","id":"unsupported-1","method":"someRuntime/unknownRequest","params":{"threadId":"thread-1"}}`)
	// 再发一条正常审批，证明 broker 在上一帧之后仍然活着并继续工作。
	up.emit(t, upstream, brokerApprovalFrame)
	waitForPendingCount(t, broker, 1, "被拒绝的帧不能打死 broker：后续审批仍必须被接住")

	// 会话整体仍然可用：重连能拿回重放。
	second := brokerDial(t, server, brokerTestSession)
	readFrameWithMethod(t, second, "execCommandApproval", 3*time.Second)
}

// 真机验证抓到的重连风暴：broker 复用同一条上游连接，但 JSON-RPC 握手是有状态的。
// 客户端每次重连都会重发 initialize，上游那条连接早已握过手，于是回
// "already initialized"，iOS 判定致命错误 → 断开 → 重连，每秒一轮。
func TestCodexGatewayBrokerAnswersRepeatInitializeLocally(t *testing.T) {
	up := newBrokerUpstream(t)
	server, _ := brokerTestServer(t, up.url, true)

	first := brokerDial(t, server, brokerTestSession)
	upstream := up.accept(t)
	// 必须先有活跃 turn，broker 才会在客户端断开后存活——没有它 broker 会立刻
	// 回收，重连拿到的是一条全新上游，也就复现不出握手复用的问题。
	up.emit(t, upstream, brokerTurnStartedFrame)
	readFrameWithMethod(t, first, "turn/started", 3*time.Second)

	// 首次握手必须照常送到上游。
	if err := first.WriteMessage(websocket.TextMessage,
		[]byte(`{"jsonrpc":"2.0","id":"init-1","method":"initialize","params":{}}`)); err != nil {
		t.Fatal(err)
	}
	forwarded := up.waitForUpstreamFrame(t, func(payload []byte) bool {
		var frame struct {
			Method string `json:"method"`
		}
		return json.Unmarshal(payload, &frame) == nil && frame.Method == "initialize"
	}, 3*time.Second)
	var forwardedFrame struct {
		ID json.RawMessage `json:"id"`
	}
	if err := json.Unmarshal(forwarded, &forwardedFrame); err != nil {
		t.Fatal(err)
	}
	up.emit(t, upstream, `{"jsonrpc":"2.0","id":`+string(forwardedFrame.ID)+`,"result":{"userAgent":"broker-test"}}`)
	// 等客户端确实收到首次握手结果，确保 broker 已经缓存下来。
	deadline := time.Now().Add(3 * time.Second)
	for {
		_ = first.SetReadDeadline(deadline)
		_, payload, err := first.ReadMessage()
		if err != nil {
			t.Fatalf("首次握手没有回到客户端：%v", err)
		}
		if bytes.Contains(payload, []byte("broker-test")) {
			break
		}
	}
	if err := first.WriteMessage(websocket.TextMessage,
		[]byte(`{"jsonrpc":"2.0","method":"initialized","params":{}}`)); err != nil {
		t.Fatal(err)
	}
	up.waitForUpstreamFrame(t, func(payload []byte) bool {
		var frame struct {
			Method string `json:"method"`
		}
		return json.Unmarshal(payload, &frame) == nil && frame.Method == "initialized"
	}, 3*time.Second)
	_ = first.Close()

	// 重连后重发握手：必须由 broker 本地应答，上游不能再看到第二次 initialize。
	second := brokerDial(t, server, brokerTestSession)
	if err := second.WriteMessage(websocket.TextMessage,
		[]byte(`{"jsonrpc":"2.0","id":"init-2","method":"initialize","params":{}}`)); err != nil {
		t.Fatal(err)
	}
	deadline = time.Now().Add(3 * time.Second)
	for {
		_ = second.SetReadDeadline(deadline)
		_, payload, err := second.ReadMessage()
		if err != nil {
			t.Fatalf("重连握手没有得到应答：%v", err)
		}
		var frame struct {
			ID     string          `json:"id"`
			Result json.RawMessage `json:"result"`
		}
		if json.Unmarshal(payload, &frame) != nil || frame.ID != "init-2" {
			continue
		}
		if !bytes.Contains(frame.Result, []byte("broker-test")) {
			t.Fatalf("重连握手应回放缓存结果，got=%s", frame.Result)
		}
		break
	}
	if err := second.WriteMessage(websocket.TextMessage,
		[]byte(`{"jsonrpc":"2.0","method":"initialized","params":{}}`)); err != nil {
		t.Fatal(err)
	}

	select {
	case payload := <-up.frames:
		var frame struct {
			Method string `json:"method"`
		}
		if json.Unmarshal(payload, &frame) == nil && (frame.Method == "initialize" || frame.Method == "initialized") {
			t.Fatalf("上游不能收到重连后的重复握手帧：%s", payload)
		}
	case <-time.After(500 * time.Millisecond):
		// 上游安静，符合预期。
	}
}

func TestCodexGatewayBrokerForwardsFirstInitializedOnly(t *testing.T) {
	broker := &codexGatewayBroker{}
	if handled, _ := broker.interceptClientFrame(
		[]byte(`{"jsonrpc":"2.0","id":"init-1","method":"initialize","params":{}}`),
	); handled {
		t.Fatal("首次 initialize 必须发给上游")
	}
	initialized := []byte(`{"jsonrpc":"2.0","method":"initialized","params":{}}`)
	if handled, _ := broker.interceptClientFrame(initialized); handled {
		t.Fatal("首次 initialized 是上游握手的一部分，不能被 broker 吞掉")
	}
	rollback := broker.trackClientFrameForward(websocket.TextMessage, initialized)
	if rollback == nil {
		t.Fatal("首次 initialized 写入前必须登记握手状态")
	}
	if handled, _ := broker.interceptClientFrame(initialized); !handled {
		t.Fatal("上游握手完成后，重连的重复 initialized 必须由 broker 吞掉")
	}
	rollback()
	if handled, _ := broker.interceptClientFrame(initialized); handled {
		t.Fatal("initialized 写入失败回滚后必须允许重试")
	}
}

func TestCodexGatewayBrokerRewritesInitializeResponseForReplacementSink(t *testing.T) {
	broker := &codexGatewayBroker{}
	first := []byte(`{"jsonrpc":"2.0","id":"init-1","method":"initialize","params":{}}`)
	if handled, _ := broker.interceptClientFrame(first); handled {
		t.Fatal("首次 initialize 必须发给上游")
	}
	second := []byte(`{"jsonrpc":"2.0","id":"init-2","method":"initialize","params":{}}`)
	if handled, response := broker.interceptClientFrame(second); !handled || len(response) != 0 {
		t.Fatalf("上游响应飞行期间的重复 initialize 应被本地吞掉：handled=%v response=%s", handled, response)
	}
	rewritten := broker.rewriteInitializeResponse(
		[]byte(`{"jsonrpc":"2.0","id":"init-1","result":{"userAgent":"broker-test"}}`),
	)
	var frame struct {
		ID     string          `json:"id"`
		Result json.RawMessage `json:"result"`
	}
	if err := json.Unmarshal(rewritten, &frame); err != nil {
		t.Fatal(err)
	}
	if frame.ID != "init-2" || !bytes.Contains(frame.Result, []byte("broker-test")) {
		t.Fatalf("首次响应必须改写给替换后的 sink：%s", rewritten)
	}
}
