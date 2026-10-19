package httpapi

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/pushbridge"
)

// #800：手机切网后旧 TCP 收不到 FIN/RST，网关要等读超时才发现它断了。这期间
// 同名会话的新连接必须立即接管，不能被旧连接占着的槽位或卡住的写入拖住。
// 用例里旧连接都不主动关闭：在服务端看来它们仍然在线，与半开连接一致。

const claudeTakeoverBridgeScript = `#!/bin/sh
IFS= read -r line
printf '{"jsonrpc":"2.0","method":"_alleycat/attached","params":{"sessionKey":"s","kind":"fresh","currentSeq":0,"floorSeq":0}}\n'
while IFS= read -r line; do
  case "$line" in
  *'"method":"thread/list"'*)
    printf '{"jsonrpc":"2.0","id":81,"result":{"data":[]}}\n'
    ;;
  esac
done
`

func claudeTakeoverServer(t *testing.T, limit int) (*httptest.Server, *Router, string) {
	t.Helper()
	bridge := writeTestBridge(t, claudeTakeoverBridgeScript)
	upstreamURL, _, _ := fakeAppServerUpstream(t, nil)
	handler, router, projectDir := buildAppServerGatewayFixture(t, upstreamURL, func(cfg *config.Config) {
		cfg.Claude.Enabled = true
		cfg.Claude.BridgeBin = bridge
		cfg.Claude.MaxConcurrentBridges = limit
	})
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	return server, router, projectDir
}

// claudeRoundTrip 证明连接已经接上 bridge 会话：请求必须得到 bridge 的应答。
func claudeRoundTrip(conn *websocket.Conn, projectDir string) error {
	payload := fmt.Sprintf(`{"id":81,"method":"thread/list","params":{"cwd":%q}}`, projectDir)
	if err := conn.WriteMessage(websocket.TextMessage, []byte(payload)); err != nil {
		return err
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		_ = conn.SetReadDeadline(deadline)
		_, raw, err := conn.ReadMessage()
		if err != nil {
			return err
		}
		if bytes.Contains(raw, []byte("CLAUDE_BRIDGE_LIMIT_EXCEEDED")) {
			return errors.New(string(raw))
		}
		var frame struct {
			ID     json.RawMessage `json:"id"`
			Result json.RawMessage `json:"result"`
		}
		if json.Unmarshal(raw, &frame) == nil && string(frame.ID) == "81" && len(frame.Result) > 0 {
			return nil
		}
	}
}

// expectConnectionClosed 要求服务端已经主动断开：读到的必须是断开错误而不是超时。
func expectConnectionClosed(t *testing.T, conn *websocket.Conn, message string) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for {
		_ = conn.SetReadDeadline(deadline)
		_, _, err := conn.ReadMessage()
		if err == nil {
			continue
		}
		var netErr net.Error
		if errors.As(err, &netErr) && netErr.Timeout() {
			t.Fatalf("%s：3 秒内仍未断开", message)
		}
		return
	}
}

func claudeSlotState(router *Router) (int, int) {
	router.claudeMu.Lock()
	defer router.claudeMu.Unlock()
	return router.activeClaudeBridge, len(router.claudeForeground)
}

func waitForClaudeSlots(t *testing.T, router *Router, wantSlots int, wantSessions int) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for {
		slots, sessions := claudeSlotState(router)
		if slots == wantSlots && sessions == wantSessions {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("Claude 槽位=%d 前台会话=%d，期望 %d / %d", slots, sessions, wantSlots, wantSessions)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestClaudeGatewaySameSessionReconnectTakesOverStaleConnection(t *testing.T) {
	const limit = 3
	server, router, projectDir := claudeTakeoverServer(t, limit)

	var previous *websocket.Conn
	// 重连次数超过上限：旧实现在第 limit+1 次就会收到 CLAUDE_BRIDGE_LIMIT_EXCEEDED。
	for i := 0; i < limit+2; i++ {
		conn := dialAuthedGatewaySession(t, server.URL, "claude", "dev-1-claude")
		t.Cleanup(func() { _ = conn.Close() })
		if err := claudeRoundTrip(conn, projectDir); err != nil {
			t.Fatalf("第 %d 次重连应立即可用：%v", i+1, err)
		}
		if previous != nil {
			expectConnectionClosed(t, previous, fmt.Sprintf("第 %d 次重连后旧连接应被关闭", i+1))
		}
		if slots, sessions := claudeSlotState(router); slots != 1 || sessions != 1 {
			t.Fatalf("同名会话只应占一个槽位：slots=%d sessions=%d", slots, sessions)
		}
		previous = conn
	}

	_ = previous.Close()
	waitForClaudeSlots(t, router, 0, 0)
}

// 正常连接不受影响：不同会话名之间互不接管，并发上限照旧生效。
func TestClaudeGatewayTakeoverIsScopedToSameSession(t *testing.T) {
	const limit = 3
	server, router, projectDir := claudeTakeoverServer(t, limit)

	keys := []string{"dev-1-claude", "dev-1-claude-probe", "dev-2-claude"}
	conns := make([]*websocket.Conn, 0, len(keys))
	for _, key := range keys {
		conn := dialAuthedGatewaySession(t, server.URL, "claude", key)
		t.Cleanup(func() { _ = conn.Close() })
		if err := claudeRoundTrip(conn, projectDir); err != nil {
			t.Fatalf("会话 %s 应可用：%v", key, err)
		}
		conns = append(conns, conn)
	}

	extra := dialAuthedGatewaySession(t, server.URL, "claude", "dev-3-claude")
	t.Cleanup(func() { _ = extra.Close() })
	// 网关写完拒绝帧就关闭连接，只能先读、不能先写：Windows 上向已关闭的对端写入
	// 会引来 RST，RST 会丢掉接收缓冲里尚未读出的拒绝帧。拒绝前网关可能先重探 bridge
	// 版本（自身 2 秒超时），读等待不能和它一样短。
	_ = extra.SetReadDeadline(time.Now().Add(10 * time.Second))
	_, raw, err := extra.ReadMessage()
	if err != nil || !bytes.Contains(raw, []byte("CLAUDE_BRIDGE_LIMIT_EXCEEDED")) {
		t.Fatalf("不同会话超过上限仍应被拒绝，got=%s err=%v", raw, err)
	}
	for i, conn := range conns {
		if err := claudeRoundTrip(conn, projectDir); err != nil {
			t.Fatalf("会话 %s 不应被别的会话顶掉：%v", keys[i], err)
		}
	}
	waitForClaudeSlots(t, router, limit, limit)
}

const claudeApprovalTakeoverBridgeScript = `#!/bin/sh
IFS= read -r line
printf '{"jsonrpc":"2.0","method":"_alleycat/attached","params":{"sessionKey":"s","kind":"fresh","currentSeq":0,"floorSeq":0}}\n'
printf '{"jsonrpc":"2.0","id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","command":"ls"}}\n'
while IFS= read -r line; do :; done
`

// 被接管的旧连接退出时客户端并没有离开：不能装观察者、不能补发离线提醒。
// 当前连接真正断开后，观察者照常接手并提醒仍未处理的审批。
func TestClaudeGatewayTakeoverKeepsApprovalObserverForCurrentConnection(t *testing.T) {
	provider := newFakePushProvider(t)
	bridge := writeTestBridge(t, claudeApprovalTakeoverBridgeScript)
	server, router := pushTestFixtureWith(t, "ws://unused", provider.server.URL, pushFixtureOptions{
		customize: func(cfg *config.Config) {
			cfg.Claude.Enabled = true
			cfg.Claude.BridgeBin = bridge
			cfg.Claude.MaxConcurrentBridges = 3
		},
	})
	registerPushDevice(t, server, "device-1")
	projectDir := router.cfg.Projects[0].Path
	scope, _ := router.gatewayScopeForPath(projectDir)
	router.allowGatewayThread(appServerGatewayAllowedThread{id: "thread-1", runtimeID: "claude", cwd: projectDir, scopeID: scope.id})
	const sessionKey = "dev-1-claude"

	first := dialAuthedGatewaySession(t, server.URL, "claude", sessionKey)
	t.Cleanup(func() { _ = first.Close() })
	readFrameWithMethod(t, first, "item/commandExecution/requestApproval", 5*time.Second)

	second := dialAuthedGatewaySession(t, server.URL, "claude", sessionKey)
	t.Cleanup(func() { _ = second.Close() })
	readFrameWithMethod(t, second, "item/commandExecution/requestApproval", 5*time.Second)
	expectConnectionClosed(t, first, "同名会话重连后旧连接应被关闭")

	time.Sleep(300 * time.Millisecond)
	if router.claudeApprovalObserverFor(sessionKey) != nil {
		t.Fatal("被接管的旧连接不能安装观察者")
	}
	if got := provider.count(); got != 0 {
		t.Fatalf("客户端在线时不应推送离线审批提醒，got=%d", got)
	}

	_ = second.Close()
	provider.waitFor(t, pushbridge.EventApprovalPending)
	if router.claudeApprovalObserverFor(sessionKey) == nil {
		t.Fatal("当前连接断开后观察者应接手")
	}
}

func TestClaudeForegroundLeaseTransfersSlotOnTakeover(t *testing.T) {
	router := &Router{cfg: config.Config{Claude: config.ClaudeConfig{MaxConcurrentBridges: 2}}}
	first, ok := router.claimClaudeForeground("dev-1-claude", nil)
	if !ok {
		t.Fatal("首个连接应取得槽位")
	}
	second, ok := router.claimClaudeForeground("dev-1-claude", nil)
	if !ok {
		t.Fatal("同名会话重连应接过旧槽位")
	}
	if !router.claudeForegroundSuperseded(first) || router.claudeForegroundSuperseded(second) {
		t.Fatal("只有旧连接应被标记为已接管")
	}
	if first.attachMu != second.attachMu {
		t.Fatal("同名会话的各代连接必须共用 attach 锁")
	}
	if slots, sessions := claudeSlotState(router); slots != 1 || sessions != 1 {
		t.Fatalf("接管不应增加槽位：slots=%d sessions=%d", slots, sessions)
	}
	if router.setClaudeForegroundUpstream(first, nil) {
		t.Fatal("已被接管的连接拨号完成后应直接退出")
	}
	if router.handOffClaudeForegroundUpstream(first) {
		t.Fatal("已被接管的连接不能把 bridge 连接交给观察者")
	}
	if !router.handOffClaudeForegroundUpstream(second) {
		t.Fatal("当前连接断开时应能交给观察者")
	}

	unnamed, ok := router.claimClaudeForeground("", nil)
	if !ok {
		t.Fatal("未命名连接应按上限申请槽位")
	}
	if _, ok := router.claimClaudeForeground("", nil); ok {
		t.Fatal("未命名连接之间不能互相接管，超过上限应被拒绝")
	}

	// 旧连接退出不能释放已经转交的槽位，也不能删掉新连接的登记。
	router.releaseClaudeForeground(first)
	if slots, sessions := claudeSlotState(router); slots != 2 || sessions != 1 {
		t.Fatalf("旧连接退出后槽位不应变化：slots=%d sessions=%d", slots, sessions)
	}
	router.releaseClaudeForeground(second)
	router.releaseClaudeForeground(unnamed)
	if slots, sessions := claudeSlotState(router); slots != 0 || sessions != 0 {
		t.Fatalf("全部退出后应归还槽位：slots=%d sessions=%d", slots, sessions)
	}
}

// brokerUpstreamWriter 串行化用例对上游连接的写：大帧 goroutine 与应答可能同时写。
type brokerUpstreamWriter struct {
	mu   sync.Mutex
	conn *websocket.Conn
}

func (w *brokerUpstreamWriter) write(frame string) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.conn.WriteMessage(websocket.TextMessage, []byte(frame))
}

// brokerInitialize 完成首个连接的握手，让 broker 缓存 initialize 结果。
func brokerInitialize(t *testing.T, up *brokerUpstream, writer *brokerUpstreamWriter, client *websocket.Conn) {
	t.Helper()
	if err := client.WriteMessage(websocket.TextMessage,
		[]byte(`{"jsonrpc":"2.0","id":"init-1","method":"initialize","params":{}}`)); err != nil {
		t.Fatal(err)
	}
	forwarded := up.waitForUpstreamFrame(t, func(payload []byte) bool {
		return bytes.Contains(payload, []byte(`"initialize"`))
	}, 3*time.Second)
	var forwardedFrame struct {
		ID json.RawMessage `json:"id"`
	}
	if err := json.Unmarshal(forwarded, &forwardedFrame); err != nil {
		t.Fatal(err)
	}
	if err := writer.write(`{"jsonrpc":"2.0","id":` + string(forwardedFrame.ID) + `,"result":{"userAgent":"broker-test"}}`); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(3 * time.Second)
	for {
		_ = client.SetReadDeadline(deadline)
		_, payload, err := client.ReadMessage()
		if err != nil {
			t.Fatalf("首次握手没有回到客户端：%v", err)
		}
		if bytes.Contains(payload, []byte("broker-test")) {
			break
		}
	}
	if err := client.WriteMessage(websocket.TextMessage, []byte(`{"jsonrpc":"2.0","method":"initialized","params":{}}`)); err != nil {
		t.Fatal(err)
	}
	up.waitForUpstreamFrame(t, func(payload []byte) bool {
		return bytes.Contains(payload, []byte(`"initialized"`))
	}, 3*time.Second)
}

func brokerLargeDeltaFrame(size int) string {
	return `{"jsonrpc":"2.0","method":"item/agentMessage/delta","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","delta":"` +
		strings.Repeat("x", size) + `"}}`
}

// stalledConn 模拟切网后的半开 TCP：冻结后写入既不成功也不报错，直到写超时或被
// 关闭。这与内核发送缓冲写满后的表现一致，但不依赖各平台的缓冲大小。
type stalledConn struct {
	net.Conn
	mu            sync.Mutex
	stalled       bool
	writeDeadline time.Time
	closed        chan struct{}
	closeOnce     sync.Once
	blocked       chan struct{}
}

func (c *stalledConn) Write(p []byte) (int, error) {
	c.mu.Lock()
	stalled, deadline := c.stalled, c.writeDeadline
	c.mu.Unlock()
	if !stalled {
		return c.Conn.Write(p)
	}
	select {
	case c.blocked <- struct{}{}:
	default:
	}
	var expired <-chan time.Time
	if !deadline.IsZero() {
		timer := time.NewTimer(time.Until(deadline))
		defer timer.Stop()
		expired = timer.C
	}
	select {
	case <-c.closed:
		return 0, net.ErrClosed
	case <-expired:
		return 0, errors.New("i/o timeout")
	}
}

func (c *stalledConn) SetWriteDeadline(deadline time.Time) error {
	c.mu.Lock()
	c.writeDeadline = deadline
	c.mu.Unlock()
	return c.Conn.SetWriteDeadline(deadline)
}

func (c *stalledConn) SetDeadline(deadline time.Time) error {
	c.mu.Lock()
	c.writeDeadline = deadline
	c.mu.Unlock()
	return c.Conn.SetDeadline(deadline)
}

func (c *stalledConn) Close() error {
	c.closeOnce.Do(func() { close(c.closed) })
	return c.Conn.Close()
}

func (c *stalledConn) stall() {
	c.mu.Lock()
	c.stalled = true
	c.mu.Unlock()
}

type stallingListener struct {
	net.Listener
	accepted chan *stalledConn
}

func (l *stallingListener) Accept() (net.Conn, error) {
	conn, err := l.Listener.Accept()
	if err != nil {
		return nil, err
	}
	wrapped := &stalledConn{Conn: conn, closed: make(chan struct{}), blocked: make(chan struct{}, 1)}
	select {
	case l.accepted <- wrapped:
	default:
	}
	return wrapped, nil
}

// stallingBrokerTestServer 与 brokerTestServer 相同，但能冻结某条客户端连接的服务端写入。
func stallingBrokerTestServer(t *testing.T, upstreamURL string) (*httptest.Server, *Router, <-chan *stalledConn) {
	t.Helper()
	handler, router, projectDir := buildAppServerGatewayFixture(t, upstreamURL, func(cfg *config.Config) {
		cfg.AppServer.ApprovalBroker = true
	})
	scope, ok := router.gatewayScopeForPath(projectDir)
	if !ok {
		t.Fatal("测试项目必须具有 gateway scope")
	}
	router.allowGatewayThread(appServerGatewayAllowedThread{id: "thread-1", runtimeID: "codex", cwd: projectDir, scopeID: scope.id})
	server := httptest.NewUnstartedServer(handler)
	listener := &stallingListener{Listener: server.Listener, accepted: make(chan *stalledConn, 8)}
	server.Listener = listener
	server.Start()
	t.Cleanup(server.Close)
	return server, router, listener.accepted
}

func TestCodexGatewayBrokerReconnectIsNotBlockedByStaleSinkWrite(t *testing.T) {
	up := newBrokerUpstream(t)
	server, router, accepted := stallingBrokerTestServer(t, up.url)

	first := brokerDial(t, server, brokerTestSession)
	firstServerConn := <-accepted
	writer := &brokerUpstreamWriter{conn: up.accept(t)}
	if err := writer.write(brokerTurnStartedFrame); err != nil {
		t.Fatal(err)
	}
	readFrameWithMethod(t, first, "turn/started", 3*time.Second)
	brokerInitialize(t, up, writer, first)
	if err := writer.write(brokerApprovalFrame); err != nil {
		t.Fatal(err)
	}
	readFrameWithMethod(t, first, "execCommandApproval", 3*time.Second)
	broker := waitForBroker(t, router, brokerTestSession, true)
	staleSink := broker.currentSink()

	// 旧连接切网失联：服务端对它的写入卡住。泵送随后写这条大帧时会卡在旧 sink 上，
	// 旧实现要等大帧写窗（最长 75 秒）才放开 broker。
	firstServerConn.stall()
	const sentinel = `{"jsonrpc":"2.0","method":"turn/started","params":{"threadId":"thread-1","turnId":"turn-sentinel"}}`
	if err := writer.write(brokerLargeDeltaFrame(300 << 10)); err != nil {
		t.Fatal(err)
	}
	if err := writer.write(sentinel); err != nil {
		t.Fatal(err)
	}
	select {
	case <-firstServerConn.blocked:
	case <-time.After(5 * time.Second):
		t.Fatal("泵送没有写旧 sink，用例前提不成立")
	}
	for len(up.frames) > 0 {
		<-up.frames
	}

	start := time.Now()
	second := brokerDial(t, server, brokerTestSession)
	if err := second.WriteMessage(websocket.TextMessage,
		[]byte(`{"jsonrpc":"2.0","id":"init-2","method":"initialize","params":{}}`)); err != nil {
		t.Fatal(err)
	}
	if err := second.WriteMessage(websocket.TextMessage,
		[]byte(`{"jsonrpc":"2.0","id":77,"method":"model/list","params":{}}`)); err != nil {
		t.Fatal(err)
	}
	upstreamSeen := make(chan time.Duration, 1)
	go func() {
		deadline := time.After(10 * time.Second)
		for {
			select {
			case frame := <-up.frames:
				if bytes.Contains(frame, []byte(`"model/list"`)) {
					upstreamSeen <- time.Since(start)
					return
				}
			case <-deadline:
				return
			}
		}
	}()

	// 接管窗口里泵送读到的帧（这里是 sentinel）必须交给新连接，不能写进已断开的旧连接。
	var initElapsed time.Duration
	approvals := 0
	sawSentinel := false
	deadline := time.Now().Add(10 * time.Second)
	for !sawSentinel || initElapsed == 0 {
		_ = second.SetReadDeadline(deadline)
		_, payload, err := second.ReadMessage()
		if err != nil {
			t.Fatalf("新连接等待帧时读失败（approvals=%d init=%s sentinel=%t）：%v", approvals, initElapsed, sawSentinel, err)
		}
		var frame struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
			Params struct {
				TurnID string `json:"turnId"`
			} `json:"params"`
		}
		if json.Unmarshal(payload, &frame) != nil {
			continue
		}
		switch {
		case string(frame.ID) == `"init-2"` && frame.Method == "":
			initElapsed = time.Since(start)
		case frame.Method == "execCommandApproval":
			approvals++
		case frame.Method == "turn/started" && frame.Params.TurnID == "turn-sentinel":
			sawSentinel = true
		}
	}

	if initElapsed == 0 || initElapsed > time.Second {
		t.Fatalf("新连接的 initialize 应在 1 秒内本地应答，got=%s", initElapsed)
	}
	select {
	case elapsed := <-upstreamSeen:
		if elapsed > time.Second {
			t.Fatalf("新连接的请求应在 1 秒内转发到上游，got=%s", elapsed)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("新连接的请求没有转发到上游")
	}
	if approvals != 1 {
		t.Fatalf("待审批请求在接管后应恰好重放一次，got=%d", approvals)
	}
	expectConnectionClosed(t, first, "同名会话重连后旧连接应被关闭")
	if broker.currentSink() == staleSink {
		t.Fatal("旧 sink 不应仍是当前连接")
	}
}

// 正常长连接不受影响：持续接收大帧的连接不会被误断，别的会话接入也不会打扰它。
func TestCodexGatewayBrokerKeepsHealthySinkStreamingLargeFrames(t *testing.T) {
	up := newBrokerUpstream(t)
	server, _ := brokerTestServer(t, up.url, true)

	first := brokerDial(t, server, brokerTestSession)
	writer := &brokerUpstreamWriter{conn: up.accept(t)}
	if err := writer.write(brokerTurnStartedFrame); err != nil {
		t.Fatal(err)
	}
	readFrameWithMethod(t, first, "turn/started", 3*time.Second)

	// 每帧都超过大帧阈值（256 KB），走按体积放宽的写窗。
	const frames = 3
	const size = 300 << 10
	go func() {
		for i := 0; i < frames; i++ {
			if writer.write(brokerLargeDeltaFrame(size)) != nil {
				return
			}
		}
		_ = writer.write(brokerTurnDoneFrame)
	}()
	other := brokerDial(t, server, brokerTestSession+"-other")
	_ = up.accept(t)

	received := 0
	deadline := time.Now().Add(10 * time.Second)
	for {
		_ = first.SetReadDeadline(deadline)
		_, payload, err := first.ReadMessage()
		if err != nil {
			t.Fatalf("健康连接在接收大帧时被断开（已收 %d 帧）：%v", received, err)
		}
		if bytes.Contains(payload, []byte(`"item/agentMessage/delta"`)) {
			if len(payload) < size {
				t.Fatalf("大帧被截断：%d 字节", len(payload))
			}
			received++
			continue
		}
		if bytes.Contains(payload, []byte(`"turn/completed"`)) {
			break
		}
	}
	if received != frames {
		t.Fatalf("应按序收到全部 %d 个大帧，got=%d", frames, received)
	}
	for len(up.frames) > 0 {
		<-up.frames
	}
	if err := first.WriteMessage(websocket.TextMessage, []byte(`{"jsonrpc":"2.0","id":78,"method":"model/list","params":{}}`)); err != nil {
		t.Fatal(err)
	}
	up.waitForUpstreamFrame(t, func(payload []byte) bool {
		return bytes.Contains(payload, []byte(`"model/list"`))
	}, 3*time.Second)
	_ = other.Close()
}

// 旧 handler 的 detach 可能在接管途中到达（旧连接已被断开、新 sink 尚未发布）。
// 这时不能把会话当成离线：既不能摘掉 sink，也不能补发离线提醒或回收 broker。
func TestCodexGatewayBrokerDetachDuringTakeoverKeepsSession(t *testing.T) {
	oldSink := &codexGatewaySink{done: make(chan string, 1)}
	newSink := &codexGatewaySink{done: make(chan string, 1)}
	broker := &codexGatewayBroker{
		sink:             oldSink,
		activeTurns:      map[string]struct{}{"thread-1": {}},
		pending:          map[string][]byte{},
		pendingDelivered: map[string]*codexGatewaySink{},
	}

	broker.clientFrameMu.Lock()
	attached := make(chan bool, 1)
	go func() { attached <- broker.attach(newSink) }()
	select {
	case reason := <-oldSink.done:
		if reason != "broker_sink_replaced" {
			t.Fatalf("旧 sink 的结束原因 = %q", reason)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("接管应先断开旧 sink，而不是等旧连接的帧处理完")
	}

	broker.detach(oldSink)
	broker.mu.Lock()
	sink, detachedAt := broker.sink, broker.detachedAt
	broker.mu.Unlock()
	if sink != oldSink || !detachedAt.IsZero() {
		t.Fatal("接管途中旧 handler 的 detach 不能把会话标成离线")
	}

	broker.clientFrameMu.Unlock()
	select {
	case ok := <-attached:
		if !ok {
			t.Fatal("新 sink 应成功接管")
		}
	case <-time.After(3 * time.Second):
		t.Fatal("接管没有完成")
	}
	if broker.currentSink() != newSink {
		t.Fatal("新 sink 应成为当前连接")
	}
}
