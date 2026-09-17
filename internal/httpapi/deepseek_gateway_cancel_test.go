package httpapi

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
)

// 回归：retry 复制暂存项后收到 cancel，手里的副本必须失效，不能重新生成审批卡片。
func TestDeepSeekCancelInvalidatesCopiedPendingInteraction(t *testing.T) {
	const eventID = "event-cancel-before-delivery"
	conn := &deepSeekGatewayConn{
		callThreads: map[string]string{},
		waterfalls:  map[string]deepSeekPendingWaterfall{},
		pendingInteractions: map[string]deepSeekPendingInteraction{
			eventID: {
				request:   deepSeekApprovalRequest(eventID),
				expiresAt: time.Now().Add(time.Minute),
			},
		},
	}

	copied := make(chan struct{})
	resume := make(chan struct{})
	done := make(chan struct{})
	go func() {
		conn.retryPendingInteractionsAfterSnapshot(func() {
			close(copied)
			<-resume
		})
		close(done)
	}()

	<-copied
	conn.resolveCancelledWaterfall(eventID)
	close(resume)
	<-done
	// 另一条事件流随后才递交同一 eventId，也必须命中终态而被拒绝。
	conn.dispatchWaterfall(t.Context(), deepSeekApprovalRequest(eventID))

	if _, ok := conn.pendingInteractions[eventID]; ok {
		t.Fatal("cancel 后不应保留暂存交互")
	}
	if _, ok := conn.waterfalls[eventID]; ok {
		t.Fatal("已取消的暂存副本不得重新登记为待应答交互")
	}
}

// 回归：两条上游流可能重复递交同一 eventId。第一张卡片已登记后，重投不得覆盖
// requestId，也不得向客户端再写一张无法与原应答对账的重复卡片。
func TestDeepSeekDuplicateDeliveredInteractionIsIgnored(t *testing.T) {
	serverConn, clientConn := deepSeekCancelTestWebSocketPair(t)
	policy, _ := newInboundPolicyForTest(t, appServerRuntimeDeepSeekID)
	conn := &deepSeekGatewayConn{
		client:              serverConn,
		policy:              policy,
		callThreads:         map[string]string{},
		waterfalls:          map[string]deepSeekPendingWaterfall{},
		pendingInteractions: map[string]deepSeekPendingInteraction{},
	}
	request := deepSeekApprovalRequest("event-duplicate-delivery")

	conn.dispatchWaterfall(t.Context(), request)
	_, _, err := clientConn.ReadMessage()
	if err != nil {
		t.Fatalf("读取第一张审批卡片失败：%v", err)
	}
	firstID := conn.waterfalls[request.EventID].requestID

	conn.dispatchWaterfall(t.Context(), request)
	if got := conn.waterfalls[request.EventID].requestID; got != firstID {
		t.Fatalf("重复 eventId 不得覆盖已登记 requestId：first=%d got=%d", firstID, got)
	}
	if err := clientConn.SetReadDeadline(time.Now().Add(20 * time.Millisecond)); err != nil {
		t.Fatal(err)
	}
	if _, payload, err := clientConn.ReadMessage(); err == nil {
		t.Fatalf("重复 eventId 不得再次下发卡片：%s", payload)
	}

	// 回传进行中仍挡住重复卡片，但只有上游确认后才进入终态。
	pending, ok := conn.beginWaterfallResponse(firstID)
	if !ok {
		t.Fatal("首次下发的审批应可由客户端完成")
	}
	if conn.interactionIsTerminal(request.EventID) {
		t.Fatal("回传尚未确认时不得提前标成终态")
	}
	if _, duplicate := conn.beginWaterfallResponse(firstID); duplicate {
		t.Fatal("进行中的同一应答不得再次回传")
	}
	conn.dispatchWaterfall(t.Context(), request)
	if len(conn.waterfalls) != 1 || conn.waterfalls[request.EventID].requestID != firstID {
		t.Fatal("回传进行中重投必须保留原交互")
	}
	conn.completeWaterfallResponse(pending)
	conn.dispatchWaterfall(t.Context(), request)
	if _, ok := conn.waterfalls[request.EventID]; ok {
		t.Fatal("已经完成的 eventId 不得重新登记")
	}
}

// 回归：有效性重读时先判过期。即使此刻已能归属，也不能把过期请求下发给客户端。
func TestDeepSeekExpiredAttributedInteractionIsTerminal(t *testing.T) {
	for _, direct := range []bool{false, true} {
		t.Run(map[bool]string{false: "retry", true: "direct redelivery"}[direct], func(t *testing.T) {
			const eventID = "event-expired-attributed"
			conn := &deepSeekGatewayConn{
				callThreads: map[string]string{},
				waterfalls:  map[string]deepSeekPendingWaterfall{},
				pendingInteractions: map[string]deepSeekPendingInteraction{
					eventID: {
						request:   deepSeekApprovalRequest(eventID),
						expiresAt: time.Now().Add(-time.Second),
					},
				},
			}

			if direct {
				conn.dispatchWaterfall(t.Context(), deepSeekApprovalRequest(eventID))
			} else {
				conn.retryPendingInteractions()
			}
			if _, ok := conn.pendingInteractions[eventID]; ok {
				t.Fatal("已过期交互应从暂存区移除")
			}
			if _, ok := conn.waterfalls[eventID]; ok {
				t.Fatal("已过期但可归属的交互不得下发")
			}
			conn.interactionMu.Lock()
			terminal := conn.interactionIsTerminal(eventID)
			conn.interactionMu.Unlock()
			if !terminal {
				t.Fatal("已过期交互应记录为终态，阻止另一条流重投")
			}
		})
	}
}

func TestDeepSeekTerminalInteractionRecordsStayBounded(t *testing.T) {
	conn := &deepSeekGatewayConn{}
	conn.interactionMu.Lock()
	for i := 0; i < deepSeekInteractionTerminalMax+8; i++ {
		conn.markInteractionTerminal("event-" + time.Unix(int64(i), 0).Format("150405"))
	}
	got := len(conn.terminalInteractions)
	conn.interactionMu.Unlock()
	if got != deepSeekInteractionTerminalMax {
		t.Fatalf("终态记录数 = %d，want %d", got, deepSeekInteractionTerminalMax)
	}
}

// 回归：cancel 到达时若请求正在写给客户端，必须等请求写完后再发送 resolved。
// 这样客户端只会看到“卡片 → 撤卡”，不会先收到撤卡、随后又出现过期卡片。
func TestDeepSeekCancelDuringDeliveryResolvesAfterRequest(t *testing.T) {
	serverConn, clientConn := deepSeekCancelTestWebSocketPair(t)
	policy, _ := newInboundPolicyForTest(t, appServerRuntimeDeepSeekID)
	conn := &deepSeekGatewayConn{
		client:              serverConn,
		policy:              policy,
		callThreads:         map[string]string{},
		waterfalls:          map[string]deepSeekPendingWaterfall{},
		pendingInteractions: map[string]deepSeekPendingInteraction{},
	}
	request := deepSeekApprovalRequest("event-cancel-during-delivery")

	// 卡在真正写帧的位置。deliver 已完成有效性检查与登记，但仍持有交互生命周期锁。
	conn.writeMu.Lock()
	delivered := make(chan struct{})
	go func() {
		conn.dispatchWaterfall(t.Context(), request)
		close(delivered)
	}()
	waitForDeepSeekWaterfall(t, conn, request.EventID)

	cancelled := make(chan struct{})
	go func() {
		conn.resolveCancelledWaterfall(request.EventID)
		close(cancelled)
	}()
	select {
	case <-cancelled:
		t.Fatal("请求尚未写出时，cancel 不应越过下发先完成")
	case <-time.After(20 * time.Millisecond):
	}

	conn.writeMu.Unlock()
	<-delivered
	<-cancelled

	_, first, err := clientConn.ReadMessage()
	if err != nil {
		t.Fatalf("读取审批请求失败：%v", err)
	}
	if !strings.Contains(string(first), `"method":"item/commandExecution/requestApproval"`) {
		t.Fatalf("第一帧应为审批请求：%s", first)
	}
	_, second, err := clientConn.ReadMessage()
	if err != nil {
		t.Fatalf("读取撤卡通知失败：%v", err)
	}
	if !strings.Contains(string(second), `"method":"serverRequest/resolved"`) {
		t.Fatalf("第二帧应为撤卡通知：%s", second)
	}
	if _, ok := conn.waterfalls[request.EventID]; ok {
		t.Fatal("撤卡后不应保留待应答交互")
	}
}

func deepSeekApprovalRequest(eventID string) harnessclient.WaterfallRequest {
	return harnessclient.WaterfallRequest{
		Type:    "waterfall",
		EventID: eventID,
		Event:   harnessclient.WaterfallApprovalRequest,
		AgentID: "allowed",
		Request: harnessclient.WaterfallPayload{
			ToolName: "write",
			CallID:   "call-1",
		},
	}
}

func deepSeekCancelTestWebSocketPair(t *testing.T) (*websocket.Conn, *websocket.Conn) {
	t.Helper()
	upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	accepted := make(chan *websocket.Conn, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		accepted <- conn
	}))
	t.Cleanup(server.Close)

	client, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(server.URL, "http"), nil)
	if err != nil {
		t.Fatalf("连接测试 WebSocket 失败：%v", err)
	}
	serverSide := <-accepted
	t.Cleanup(func() {
		_ = client.Close()
		_ = serverSide.Close()
	})
	return serverSide, client
}

func waitForDeepSeekWaterfall(t *testing.T, conn *deepSeekGatewayConn, eventID string) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		conn.mu.Lock()
		_, ok := conn.waterfalls[eventID]
		conn.mu.Unlock()
		if ok {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("交互请求未进入待应答登记")
}
