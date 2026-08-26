package httpapi

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

// Claude 的常驻 bridge 会跨断线保留审批 prompt，并在重新 attach 时用
// serverRequest/replay 宣告幸存者。但 agentd 只在有客户端连接时才读 bridge：
// App 退到后台之后，期间到达的审批请求没有任何人看见，也就无从提醒。
//
// observer 就是那双眼睛：客户端断开后接管这条 bridge 连接，继续读帧、登记待审批
// 请求并触发推送。它是只读的 —— 不向客户端转发任何东西，也不缓存会话内容；
// 真正的重放仍由 bridge 在下次 attach 时完成。
//
// 有界且不持久化：没有待审批请求也没有活跃 turn 时立刻释放；TTL 到期强制释放；
// 新客户端接入同名会话时立刻让位；agentd 重启后全部消失。
const (
	claudeObserverTTL           = 10 * time.Minute
	claudeObserverSweepInterval = 30 * time.Second
	claudeObserverMax           = 4
)

type claudeApprovalObserver struct {
	router     *Router
	sessionKey string
	conn       net.Conn
	writeMu    *sync.Mutex
	reader     *bufio.Reader
	policy     *appServerGatewayPolicy
	cancel     context.CancelFunc

	mu          sync.Mutex
	closed      bool
	startedAt   time.Time
	activeTurns map[string]struct{}
	// pending 记录 requestID -> threadID。turn 结束只该撤掉该 thread 的审批，
	// 一个 bridge 会话下还有别的 thread 在跑。
	pending map[string]string
}

// startClaudeApprovalObserver 在客户端断开后接管 bridge 连接。返回 false 表示
// 没有接管（未启用推送、无待审批线索或已达上限），调用方按原样关闭连接。
func (r *Router) startClaudeApprovalObserver(
	sessionKey string,
	conn net.Conn,
	writeMu *sync.Mutex,
	reader *bufio.Reader,
	policy *appServerGatewayPolicy,
) bool {
	if !r.pushEnabled() || strings.TrimSpace(sessionKey) == "" || conn == nil || reader == nil {
		return false
	}
	r.claudeObserverMu.Lock()
	if r.claudeObservers == nil {
		r.claudeObservers = map[string]*claudeApprovalObserver{}
	}
	if existing := r.claudeObservers[sessionKey]; existing != nil {
		r.claudeObserverMu.Unlock()
		existing.close("observer_replaced")
		r.claudeObserverMu.Lock()
	}
	if len(r.claudeObservers) >= claudeObserverMax {
		r.claudeObserverMu.Unlock()
		return false
	}
	ctx, cancel := context.WithCancel(context.Background())
	activeTurns, pendingRequests := policy.approvalObservationSnapshot()
	pending := make(map[string]string, len(pendingRequests))
	for requestID, request := range pendingRequests {
		pending[requestID] = request.threadID
	}
	observer := &claudeApprovalObserver{
		router:      r,
		sessionKey:  sessionKey,
		conn:        conn,
		writeMu:     writeMu,
		reader:      reader,
		policy:      policy,
		cancel:      cancel,
		startedAt:   time.Now(),
		activeTurns: activeTurns,
		pending:     pending,
	}
	r.claudeObservers[sessionKey] = observer
	r.claudeObserverMu.Unlock()

	go observer.pump(ctx)
	go observer.sweep(ctx)
	// 客户端离开时已经可见但尚未回答的审批也需要提醒。Manager 会按 runtime、
	// session 与 request id 去重，不会和先前的投递堆出重复通知。
	for requestID, request := range pendingRequests {
		r.notifyPendingApproval("claude", sessionKey, request.threadID,
			policy.projectIDForThread(request.threadID), requestID, request.method)
	}
	return true
}

// stopClaudeApprovalObserver 在新客户端接入同名会话时让位：新连接会自己 attach
// 到同一个 bridge 会话并拿到 serverRequest/replay。
func (r *Router) stopClaudeApprovalObserver(sessionKey string) {
	if strings.TrimSpace(sessionKey) == "" {
		return
	}
	r.claudeObserverMu.Lock()
	observer := r.claudeObservers[sessionKey]
	r.claudeObserverMu.Unlock()
	if observer != nil {
		observer.close("client_reattached")
	}
}

func (r *Router) claudeApprovalObserverFor(sessionKey string) *claudeApprovalObserver {
	r.claudeObserverMu.Lock()
	defer r.claudeObserverMu.Unlock()
	return r.claudeObservers[sessionKey]
}

func (o *claudeApprovalObserver) pump(ctx context.Context) {
	maxLine := int(appServerGatewayReadLimit)
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}
		line, oversize, err := readBridgeStdoutLine(o.reader, maxLine)
		if !oversize {
			if payload := bytes.TrimSpace(line); len(payload) > 0 {
				o.observe(payload)
			}
		}
		if err != nil {
			if !errors.Is(err, io.EOF) {
				log.Printf("claude approval observer 读失败 session=%s err=%v",
					sanitizeGatewayDiagnostic(o.sessionKey), err)
			}
			o.close("bridge_stdout_closed")
			return
		}
	}
}

// observe 只做两件事：让 policy 登记/清理待审批请求，以及在新请求出现时推送。
func (o *claudeApprovalObserver) observe(payload []byte) {
	_, _, policyErr := o.policy.observeUpstreamFrame(websocket.TextMessage, payload)
	if policyErr != nil {
		// 观察期没有客户端可以回错误。策略拒绝的帧直接忽略，不影响 bridge。
		return
	}
	var frame appServerGatewayFrame
	if json.Unmarshal(payload, &frame) != nil {
		return
	}
	method := strings.TrimSpace(frame.Method)
	if method == "" {
		return
	}
	threadID, _, _ := appServerGatewayServerRequestScope(frame.Params)
	if frame.ID != nil {
		requestID := gatewayRequestIDKey(frame.ID)
		if requestID == "" {
			return
		}
		o.mu.Lock()
		_, known := o.pending[requestID]
		o.pending[requestID] = threadID
		o.mu.Unlock()
		if !known {
			o.router.notifyPendingApproval("claude", o.sessionKey, threadID, o.policy.projectIDForThread(threadID), requestID, method)
		}
		return
	}
	switch method {
	case "turn/started":
		if threadID != "" {
			o.mu.Lock()
			o.activeTurns[threadID] = struct{}{}
			o.mu.Unlock()
		}
	case "serverRequest/resolved":
		o.forgetResolved(frame.Params)
	case "turn/completed", "thread/closed", "error":
		if threadID == "" {
			return
		}
		o.mu.Lock()
		delete(o.activeTurns, threadID)
		o.mu.Unlock()
		o.forgetPendingForThread(threadID)
	}
}

func (o *claudeApprovalObserver) forgetResolved(params json.RawMessage) {
	var body struct {
		RequestID json.RawMessage `json:"requestId"`
		ID        json.RawMessage `json:"id"`
	}
	if json.Unmarshal(params, &body) != nil {
		return
	}
	for _, raw := range []json.RawMessage{body.RequestID, body.ID} {
		requestID := gatewayRequestIDKey(rawMessagePointer(raw))
		if requestID == "" {
			continue
		}
		o.mu.Lock()
		delete(o.pending, requestID)
		o.mu.Unlock()
		o.router.resolveApprovalNotifications("claude", o.sessionKey, requestID)
	}
}

// forgetPendingForThread 只撤掉某个 thread 的待审批。整段会话的作废交给
// close()，那时候确实没人能再代替用户回答任何一条。
func (o *claudeApprovalObserver) forgetPendingForThread(threadID string) {
	o.mu.Lock()
	forgotten := []string{}
	for requestID, owner := range o.pending {
		if owner != threadID {
			continue
		}
		forgotten = append(forgotten, requestID)
		delete(o.pending, requestID)
	}
	o.mu.Unlock()
	for _, requestID := range forgotten {
		o.router.resolveApprovalNotifications("claude", o.sessionKey, requestID)
	}
}

// submit 把锁屏决策写回 bridge。它走与前台完全相同的客户端帧校验链路。
func (o *claudeApprovalObserver) submit(ctx context.Context, payload []byte) error {
	o.mu.Lock()
	closed := o.closed
	o.mu.Unlock()
	if closed {
		return errors.New("Claude 会话观察已结束")
	}
	forwarded, rollback, policyErr := o.policy.validatePushApprovalFrame(ctx, payload)
	if policyErr != nil {
		return errors.New(policyErr.message)
	}
	o.writeMu.Lock()
	defer o.writeMu.Unlock()
	_ = o.conn.SetWriteDeadline(time.Now().Add(appServerGatewayWriteWindow))
	if _, err := o.conn.Write(append(forwarded, '\n')); err != nil {
		rollback()
		return err
	}
	return nil
}

func (o *claudeApprovalObserver) sweep(ctx context.Context) {
	ticker := time.NewTicker(claudeObserverSweepInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-ticker.C:
			o.mu.Lock()
			idle := len(o.activeTurns) == 0 && len(o.pending) == 0
			expired := now.Sub(o.startedAt) > claudeObserverTTL
			o.mu.Unlock()
			if idle {
				o.close("observer_idle")
				return
			}
			if expired {
				o.close("observer_ttl")
				return
			}
		}
	}
}

func (o *claudeApprovalObserver) close(reason string) {
	o.mu.Lock()
	if o.closed {
		o.mu.Unlock()
		return
	}
	o.closed = true
	o.mu.Unlock()

	if o.cancel != nil {
		o.cancel()
	}
	_ = o.conn.Close()
	o.policy.close()
	o.router.claudeObserverMu.Lock()
	if current, ok := o.router.claudeObservers[o.sessionKey]; ok && current == o {
		delete(o.router.claudeObservers, o.sessionKey)
	}
	o.router.claudeObserverMu.Unlock()
	// 会话观察结束意味着没人能再代替用户回答；作废剩余句柄并撤下旧通知。
	o.router.resolveApprovalNotifications("claude", o.sessionKey, "")
	log.Printf("claude approval observer 结束 session=%s reason=%s",
		sanitizeGatewayDiagnostic(o.sessionKey), reason)
}
