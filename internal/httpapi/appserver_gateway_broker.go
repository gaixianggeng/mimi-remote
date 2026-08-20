package httpapi

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

// Codex gateway 原本是 iOS 连接与上游 app-server 连接的一对一代理：客户端读出错就
// 同时关掉两端。iOS 退到后台时系统会挂起业务 WebSocket，于是 agentd 也随之失去接收
// 后续反向审批请求的连接，turn 卡在等待里没有任何人能看见。
//
// broker 把上游连接的所有权从「单次客户端连接」提升到「具名会话」：上游读循环由
// broker 独占，客户端只是可随时插拔的 sink。客户端离线期间 broker 继续消费上游帧，
// 只保留待审批反向请求原帧用于重连重放，其余帧直接丢弃 —— iOS 重连后本来就走
// thread/read 权威历史对账，不依赖网关缓冲会话内容。
//
// 边界：有界（数量、TTL、重放条数、单帧大小），且不持久化。agentd 重启后 broker
// 全部消失，上游 runtime 请求继续 fail closed。
const (
	// 后台存活窗口。一次真实工具调用从发起到进入待审批可能要几十秒到几分钟，
	// 窗口必须覆盖它；但被系统永久挂起的客户端不能长期占住 app-server 连接。
	codexGatewayBrokerDetachTTL = 10 * time.Minute
	// 同时常驻的 broker 上限。每个 broker 占一条上游连接，必须小于网关连接上限。
	codexGatewayBrokerMax = 4
	// 重连时重放的待审批请求条数上限。审批帧本身很小，这里限制的是异常上游的洪水。
	codexGatewayBrokerReplayMax = 32
	// 单条待重放帧的大小上限。超过它的审批请求不缓存，重连后由权威历史补齐。
	codexGatewayBrokerFrameMaxBytes = 128 * 1024
	codexGatewayBrokerSweepInterval = 30 * time.Second
)

// codexGatewaySink 是 broker 当前挂载的客户端连接。broker 只往 sink 写，不读它；
// 读客户端帧仍由持有该连接的 HTTP handler 负责。
type codexGatewaySink struct {
	conn    *websocket.Conn
	writeMu *sync.Mutex
	monitor *relayGatewayConnMonitor
	done    chan string
	once    sync.Once
}

// monitorOrNil 是离线期间唯一安全的统计入口。
//
// relayGatewayConnMonitor 的方法都做了 nil receiver 保护，但那救不了从一个 nil
// sink 上**取字段**——那一步就已经解引用了。而「客户端离线、sink 为 nil」恰恰是
// broker 存在的意义，是这条路径最常见的状态，不是边角情况。
func (s *codexGatewaySink) monitorOrNil() *relayGatewayConnMonitor {
	if s == nil {
		return nil
	}
	return s.monitor
}

// finish 只送出第一个终止原因。broker 侧的上游故障与 handler 侧的客户端读错误
// 可能同时发生，重复写 channel 会让先到的原因被覆盖或阻塞。
func (s *codexGatewaySink) finish(reason string) {
	if s == nil {
		return
	}
	s.once.Do(func() {
		s.done <- reason
		close(s.done)
	})
}

type codexGatewayBroker struct {
	router   *Router
	key      string
	upstream *websocket.Conn
	// upstreamWriteMu 跨客户端连接存活。它保护的是上游连接，不是某次会话。
	upstreamWriteMu sync.Mutex
	policy          *appServerGatewayPolicy
	cancel          context.CancelFunc

	mu          sync.Mutex
	sink        *codexGatewaySink
	closed      bool
	closeReason string
	createdAt   time.Time
	detachedAt  time.Time
	// activeTurns 记录仍在跑的 turn。客户端离线且没有活跃 turn、也没有待审批
	// 请求时，继续持有上游连接没有意义，立即回收。
	activeTurns map[string]struct{}
	// pending 保存待审批反向请求原帧，pendingOrder 维持到达顺序，重连按序重放。
	pending      map[string][]byte
	pendingOrder []string
	// initializeResult 是上游对第一次 initialize 的应答内容。
	//
	// JSON-RPC 握手是有状态的：上游连接只能被 initialize 一次，但客户端每次重连
	// 都会重发。缓存下来由 broker 本地应答，上游才不会回 "already initialized"
	// 把客户端推进重连风暴。
	initializeResult    json.RawMessage
	initializeRequestID string
}

// codexGatewayBrokerKey 读取客户端声明的具名会话。iOS 已经在 gateway URL 上带
// session；不带它的旧客户端保持原有语义：一次连接一套隔离状态，断开即回收。
func codexGatewayBrokerKey(req *http.Request) string {
	if req == nil {
		return ""
	}
	return sanitizedClaudeSessionKey(strings.TrimSpace(req.URL.Query().Get("session")))
}

func (r *Router) codexGatewayBrokerEnabled() bool {
	return r != nil && r.cfg.AppServer.ApprovalBroker
}

// attachCodexGatewayBroker 复用同名会话仍然存活的 broker。返回 nil 表示需要按
// 原路径新建上游连接。
func (r *Router) attachCodexGatewayBroker(key string, sink *codexGatewaySink) *codexGatewayBroker {
	if key == "" {
		return nil
	}
	r.codexBrokerMu.Lock()
	broker := r.codexBrokers[key]
	r.codexBrokerMu.Unlock()
	if broker == nil {
		return nil
	}
	if !broker.attach(sink) {
		// 竞态：broker 在取出后关闭。调用方按新建处理。
		r.forgetCodexGatewayBroker(key, broker)
		return nil
	}
	return broker
}

// registerCodexGatewayBroker 把新建的上游连接交给 broker 管理。达到上限时回收
// 最久未使用的已离线 broker；全部在线则拒绝托管，调用方退回一对一代理。
func (r *Router) registerCodexGatewayBroker(
	ctx context.Context,
	key string,
	upstream *websocket.Conn,
	policy *appServerGatewayPolicy,
	sink *codexGatewaySink,
) *codexGatewayBroker {
	if key == "" || upstream == nil {
		return nil
	}
	r.codexBrokerMu.Lock()
	if r.codexBrokers == nil {
		r.codexBrokers = map[string]*codexGatewayBroker{}
	}
	if existing := r.codexBrokers[key]; existing != nil {
		// 同名会话已经有 broker：让新连接接管它而不是并存两条上游。
		r.codexBrokerMu.Unlock()
		if existing.attach(sink) {
			return existing
		}
		r.forgetCodexGatewayBroker(key, existing)
		r.codexBrokerMu.Lock()
	}
	if len(r.codexBrokers) >= codexGatewayBrokerMax {
		evicted := oldestDetachedCodexBroker(r.codexBrokers)
		if evicted == nil {
			r.codexBrokerMu.Unlock()
			return nil
		}
		delete(r.codexBrokers, evicted.key)
		r.codexBrokerMu.Unlock()
		evicted.close("broker_evicted")
		r.codexBrokerMu.Lock()
	}
	brokerCtx, cancel := context.WithCancel(context.WithoutCancel(ctx))
	broker := &codexGatewayBroker{
		router:      r,
		key:         key,
		upstream:    upstream,
		policy:      policy,
		cancel:      cancel,
		createdAt:   time.Now(),
		sink:        sink,
		activeTurns: map[string]struct{}{},
		pending:     map[string][]byte{},
	}
	r.codexBrokers[key] = broker
	r.codexBrokerMu.Unlock()

	go broker.pumpUpstream(brokerCtx)
	go broker.pingUpstream(brokerCtx)
	go broker.sweep(brokerCtx)
	return broker
}

func oldestDetachedCodexBroker(brokers map[string]*codexGatewayBroker) *codexGatewayBroker {
	var oldest *codexGatewayBroker
	for _, broker := range brokers {
		broker.mu.Lock()
		detached := broker.sink == nil && !broker.closed
		detachedAt := broker.detachedAt
		broker.mu.Unlock()
		if !detached {
			continue
		}
		if oldest == nil {
			oldest = broker
			continue
		}
		oldest.mu.Lock()
		oldestAt := oldest.detachedAt
		oldest.mu.Unlock()
		if detachedAt.Before(oldestAt) {
			oldest = broker
		}
	}
	return oldest
}

func (r *Router) forgetCodexGatewayBroker(key string, broker *codexGatewayBroker) {
	r.codexBrokerMu.Lock()
	if current, ok := r.codexBrokers[key]; ok && (broker == nil || current == broker) {
		delete(r.codexBrokers, key)
	}
	r.codexBrokerMu.Unlock()
}

// attach 让新连接接管 broker。旧 sink 先被终止：同名会话只应有一条在线连接，
// 否则上游响应会分裂到两个客户端。
func (b *codexGatewayBroker) attach(sink *codexGatewaySink) bool {
	if b == nil || sink == nil {
		return false
	}
	b.mu.Lock()
	if b.closed {
		b.mu.Unlock()
		return false
	}
	previous := b.sink
	b.sink = sink
	b.detachedAt = time.Time{}
	frames := b.replayFramesLocked()
	b.mu.Unlock()

	if previous != nil && previous != sink {
		previous.finish("broker_sink_replaced")
	}
	for _, frame := range frames {
		if err := writeWebSocketFrame(sink.conn, sink.writeMu, websocket.TextMessage, frame); err != nil {
			sink.finish(gatewayCloseReason("client_replay_write", err))
			return true
		}
	}
	return true
}

// interceptClientFrame 在帧到达上游之前处理握手。
//
// 第一次 initialize 照常放行并记下它的 id，好在响应回来时缓存结果；此后每次
// 重连的 initialize 都由 broker 用缓存结果本地应答，initialized 通知直接吞掉。
func (b *codexGatewayBroker) interceptClientFrame(payload []byte) (bool, []byte) {
	var frame appServerGatewayFrame
	if json.Unmarshal(payload, &frame) != nil {
		return false, nil
	}
	switch strings.TrimSpace(frame.Method) {
	case "initialize":
		b.mu.Lock()
		cached := b.initializeResult
		if len(cached) == 0 {
			b.initializeRequestID = gatewayRequestIDKey(frame.ID)
			b.mu.Unlock()
			return false, nil
		}
		b.mu.Unlock()
		if frame.ID == nil {
			return true, nil
		}
		response, err := json.Marshal(map[string]any{
			"jsonrpc": "2.0",
			"id":      frame.ID,
			"result":  cached,
		})
		if err != nil {
			// 宁可放行让上游报错，也不静默吞掉客户端的握手。
			return false, nil
		}
		return true, response
	case "initialized":
		b.mu.Lock()
		initialized := len(b.initializeResult) > 0
		b.mu.Unlock()
		// 上游已经收过 initialized，重复发送同样会被判为协议错误。
		return initialized, nil
	default:
		return false, nil
	}
}

// rememberInitializeResult 捕获上游对首次 initialize 的应答。
func (b *codexGatewayBroker) rememberInitializeResult(frame *appServerGatewayFrame) {
	if frame == nil || frame.ID == nil || len(frame.Result) == 0 {
		return
	}
	key := gatewayRequestIDKey(frame.ID)
	b.mu.Lock()
	defer b.mu.Unlock()
	if key == "" || key != b.initializeRequestID || len(b.initializeResult) > 0 {
		return
	}
	b.initializeResult = append(json.RawMessage(nil), frame.Result...)
}

// replayFramesLocked 只重放 policy 仍认为待处理的请求。policy 已经实现了
// resolved / turn 结束 / thread 关闭 / TTL 的全部清理规则，这里不复制第二套判定。
func (b *codexGatewayBroker) replayFramesLocked() [][]byte {
	frames := make([][]byte, 0, len(b.pendingOrder))
	kept := b.pendingOrder[:0]
	for _, key := range b.pendingOrder {
		frame, ok := b.pending[key]
		if !ok {
			continue
		}
		id := json.RawMessage(key)
		if _, stillPending := b.policy.pendingServerRequest(&id); !stillPending {
			delete(b.pending, key)
			continue
		}
		kept = append(kept, key)
		frames = append(frames, frame)
	}
	b.pendingOrder = kept
	return frames
}

// detach 摘掉客户端连接。仍有活跃 turn 或待审批请求时保留上游连接，否则立即回收。
func (b *codexGatewayBroker) detach(sink *codexGatewaySink) {
	if b == nil {
		return
	}
	b.mu.Lock()
	if b.sink != sink {
		// 已经被新连接接管，旧 handler 退出不影响 broker。
		b.mu.Unlock()
		return
	}
	b.sink = nil
	b.detachedAt = time.Now()
	keepAlive := len(b.activeTurns) > 0 || len(b.pendingOrder) > 0
	b.mu.Unlock()

	if !keepAlive {
		b.close("broker_idle_detached")
		return
	}
	log.Printf("codex gateway broker detached session=%s pending=%d", sanitizeGatewayDiagnostic(b.key), b.pendingCount())
}

func (b *codexGatewayBroker) pendingCount() int {
	b.mu.Lock()
	defer b.mu.Unlock()
	return len(b.pendingOrder)
}

func (b *codexGatewayBroker) currentSink() *codexGatewaySink {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.sink
}

func (b *codexGatewayBroker) close(reason string) {
	if b == nil {
		return
	}
	b.mu.Lock()
	if b.closed {
		b.mu.Unlock()
		return
	}
	b.closed = true
	b.closeReason = reason
	sink := b.sink
	b.sink = nil
	b.pending = map[string][]byte{}
	b.pendingOrder = nil
	b.mu.Unlock()

	if b.cancel != nil {
		b.cancel()
	}
	// 会话结束后没人能再代替用户回答，剩余句柄必须作废、通知必须撤下。
	b.router.resolveApprovalNotifications("codex", b.key, "")
	_ = b.upstream.Close()
	b.policy.releaseAllHistoryInflight()
	b.policy.close()
	b.router.forgetCodexGatewayBroker(b.key, b)
	sink.finish(reason)
}

// pumpUpstream 独占上游读端。客户端在线与否都要继续消费，否则上游会因为无人读取
// 而阻塞，审批请求也无从登记。
func (b *codexGatewayBroker) pumpUpstream(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			b.close("context_done")
			return
		default:
		}
		messageType, payload, err := b.upstream.ReadMessage()
		if err != nil {
			b.close(gatewayCloseReason("upstream_read", err))
			return
		}
		policyStart := time.Now()
		forwardPayload, forward, policyErr := b.policy.observeUpstreamFrame(messageType, payload)
		policyDuration := time.Since(policyStart)
		sink := b.currentSink()
		if policyErr != nil {
			sink.monitorOrNil().recordPolicyError("upstream_to_client", len(payload), policyDuration)
			if policyErr.historyResponseBlocked {
				sink.monitorOrNil().recordHistoryResponseBlocked(len(payload), payload)
			}
			if policyErr.target == "client" {
				if sink != nil && !writeGatewayPolicyError(sink.conn, sink.writeMu, policyErr) {
					sink.finish("client_policy_error_write_failed")
				}
			} else if !writeGatewayPolicyError(b.upstream, &b.upstreamWriteMu, policyErr) {
				b.close("upstream_policy_error_write_failed")
				return
			}
			continue
		}
		if !forward {
			sink.monitorOrNil().recordDropped("upstream_to_client", len(payload), policyDuration)
			continue
		}
		b.observeLifecycle(messageType, forwardPayload)
		if sink == nil {
			// 离线期间只保留审批帧；会话内容由 iOS 重连后走权威历史补齐。
			continue
		}
		writeStart := time.Now()
		if err := writeWebSocketFrame(sink.conn, sink.writeMu, messageType, forwardPayload); err != nil {
			// 客户端写失败只摘掉 sink：上游 turn 仍在跑，broker 必须活着接住后续审批。
			sink.finish(gatewayCloseReason("client_write", err))
			continue
		}
		sink.monitor.recordForward("upstream_to_client", len(payload), len(forwardPayload), policyDuration, time.Since(writeStart), forwardPayload)
	}
}

func (b *codexGatewayBroker) pingUpstream(ctx context.Context) {
	ticker := time.NewTicker(appServerGatewayPingPeriod)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := writeWebSocketControl(b.upstream, &b.upstreamWriteMu, websocket.PingMessage, nil, appServerGatewayWriteWindow); err != nil {
				b.close(gatewayCloseReason("upstream_ping_write", err))
				return
			}
		}
	}
}

// sweep 是有界性的兜底：客户端可能永远不再回来，被系统挂起的会话不能无限期
// 占住上游连接。
func (b *codexGatewayBroker) sweep(ctx context.Context) {
	ticker := time.NewTicker(codexGatewayBrokerSweepInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-ticker.C:
			b.mu.Lock()
			detached := b.sink == nil && !b.closed
			expired := detached && !b.detachedAt.IsZero() && now.Sub(b.detachedAt) > codexGatewayBrokerDetachTTL
			if detached && !expired {
				b.prunePendingLocked()
				idle := len(b.activeTurns) == 0 && len(b.pendingOrder) == 0
				b.mu.Unlock()
				if idle {
					b.close("broker_idle_expired")
					return
				}
				continue
			}
			b.mu.Unlock()
			if expired {
				b.close("broker_detach_ttl")
				return
			}
		}
	}
}

// observeLifecycle 记录重放所需的最小状态：待审批请求原帧与活跃 turn。
func (b *codexGatewayBroker) observeLifecycle(messageType int, payload []byte) {
	if messageType != websocket.TextMessage {
		return
	}
	var frame appServerGatewayFrame
	if err := json.Unmarshal(payload, &frame); err != nil {
		return
	}
	method := strings.TrimSpace(frame.Method)
	if method == "" && frame.ID != nil {
		// 响应帧：只关心首次 initialize 的结果。
		b.rememberInitializeResult(&frame)
		return
	}
	if method != "" && frame.ID != nil {
		created := b.rememberServerRequestFrame(frame.ID, payload)
		if created && b.currentSink() == nil {
			// 只在客户端确实离线时提醒。App 在前台时审批卡片本来就会实时出现，
			// 再推一条只是重复打扰。
			threadID, _, _ := appServerGatewayServerRequestScope(frame.Params)
			b.router.notifyPendingApproval("codex", b.key, threadID, gatewayRequestIDKey(frame.ID), method)
		}
		return
	}
	if method == "" {
		return
	}
	threadID, _, _ := appServerGatewayServerRequestScope(frame.Params)
	switch method {
	case "turn/started":
		if threadID != "" {
			b.mu.Lock()
			b.activeTurns[threadID] = struct{}{}
			b.mu.Unlock()
		}
	case "turn/completed", "thread/closed", "error":
		// turn 结束后该 thread 的旧审批不可能再被应答，锁屏卡片必须撤掉。
		// 只按 thread 作废：同一个 gateway 会话下还有别的 thread 在跑。
		b.router.resolveApprovalNotificationsForThread("codex", b.key, threadID)
		b.mu.Lock()
		if threadID != "" {
			delete(b.activeTurns, threadID)
		} else if method == "error" {
			// 无 thread 归属的错误无法定位到某个 turn；保守清空，让 broker 靠
			// 待审批请求而不是过期的活跃标记决定是否继续存活。
			b.activeTurns = map[string]struct{}{}
		}
		b.prunePendingLocked()
		b.mu.Unlock()
	case "serverRequest/resolved":
		b.mu.Lock()
		b.prunePendingLocked()
		b.mu.Unlock()
		// 审批已被处理：只作废这一条对应的句柄，撤下其它设备上的旧通知。
		for _, requestID := range resolvedServerRequestIDs(frame.Params) {
			b.router.resolveApprovalNotifications("codex", b.key, requestID)
		}
	}
}

// 返回 true 表示这是一条新的待审批请求，值得提醒用户。
func (b *codexGatewayBroker) rememberServerRequestFrame(id *json.RawMessage, payload []byte) bool {
	key := gatewayRequestIDKey(id)
	if key == "" || len(payload) > codexGatewayBrokerFrameMaxBytes {
		return false
	}
	frame := make([]byte, len(payload))
	copy(frame, payload)
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.closed {
		return false
	}
	_, exists := b.pending[key]
	if !exists {
		if len(b.pendingOrder) >= codexGatewayBrokerReplayMax {
			// 丢最旧的一条而不是拒绝新的：最近的审批请求才是用户要处理的那条。
			oldest := b.pendingOrder[0]
			b.pendingOrder = b.pendingOrder[1:]
			delete(b.pending, oldest)
		}
		b.pendingOrder = append(b.pendingOrder, key)
	}
	b.pending[key] = frame
	return !exists
}

// prunePendingLocked 以 policy 的待处理表为准，丢掉已经被上游解决或过期的帧。
func (b *codexGatewayBroker) prunePendingLocked() {
	if len(b.pendingOrder) == 0 {
		return
	}
	kept := b.pendingOrder[:0]
	for _, key := range b.pendingOrder {
		id := json.RawMessage(key)
		if _, stillPending := b.policy.pendingServerRequest(&id); !stillPending {
			delete(b.pending, key)
			continue
		}
		kept = append(kept, key)
	}
	b.pendingOrder = kept
}

func newCodexGatewaySink(conn *websocket.Conn, writeMu *sync.Mutex, monitor *relayGatewayConnMonitor) *codexGatewaySink {
	return &codexGatewaySink{
		conn:    conn,
		writeMu: writeMu,
		monitor: monitor,
		done:    make(chan string, 1),
	}
}

// serveAttachedCodexGatewayBroker 复用同名会话仍存活的上游连接。命中时完全跳过
// 拨号：iOS 重连后拿回的是同一条 app-server 连接，未应答的审批请求 id 依然有效。
func (r *Router) serveAttachedCodexGatewayBroker(req *http.Request, client *websocket.Conn, key string) bool {
	r.codexBrokerMu.Lock()
	broker := r.codexBrokers[key]
	r.codexBrokerMu.Unlock()
	if broker == nil {
		return false
	}
	var clientWriteMu sync.Mutex
	monitor := r.monitor.startGatewayConnection(requestRemoteHost(req), req.Host, "codex:broker", 0)
	sink := newCodexGatewaySink(client, &clientWriteMu, monitor)
	if !broker.attach(sink) {
		r.forgetCodexGatewayBroker(key, broker)
		monitor.finish("broker_attach_failed")
		return false
	}
	configureGatewayReadConn(client)
	log.Printf("codex gateway broker reattached session=%s pending=%d", sanitizeGatewayDiagnostic(key), broker.pendingCount())
	r.runCodexGatewayBrokerClient(req.Context(), broker, client, &clientWriteMu, sink, monitor)
	return true
}

// serveNewCodexGatewayBroker 把刚拨通的上游连接托管给 broker。托管失败（例如已达
// 上限且全部在线）时返回 false，调用方退回原有一对一代理。
func (r *Router) serveNewCodexGatewayBroker(
	req *http.Request,
	client *websocket.Conn,
	upstream *websocket.Conn,
	monitor *relayGatewayConnMonitor,
	key string,
) bool {
	var clientWriteMu sync.Mutex
	sink := newCodexGatewaySink(client, &clientWriteMu, monitor)
	policy := newAppServerGatewayPolicy(r, "codex")
	configureGatewayReadConn(client)
	configureGatewayReadConn(upstream)
	broker := r.registerCodexGatewayBroker(req.Context(), key, upstream, policy, sink)
	if broker == nil {
		policy.close()
		return false
	}
	r.runCodexGatewayBrokerClient(req.Context(), broker, client, &clientWriteMu, sink, monitor)
	return true
}

// runCodexGatewayBrokerClient 只负责这次客户端连接的生命周期。上游读循环归 broker，
// 因此客户端断开不再关闭上游，只是摘掉 sink。
func (r *Router) runCodexGatewayBrokerClient(
	ctx context.Context,
	broker *codexGatewayBroker,
	client *websocket.Conn,
	clientWriteMu *sync.Mutex,
	sink *codexGatewaySink,
	monitor *relayGatewayConnMonitor,
) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	go func() {
		sink.finish(r.copyClientFramesToAppServer(ctx, client, broker.upstream, clientWriteMu, &broker.upstreamWriteMu, broker.policy, monitor, broker.interceptClientFrame))
	}()
	go func() {
		sink.finish(pingGatewayConnection(ctx, client, clientWriteMu, "client_ping_write"))
	}()

	reason := <-sink.done
	cancel()
	_ = client.Close()
	broker.detach(sink)
	monitor.finish(reason)
}

// resolvedServerRequestIDs 取出 serverRequest/resolved 指向的请求 id。
// 上游在不同版本里用过几种字段名，这里全部接受但只保留能解析出的那些。
func resolvedServerRequestIDs(params json.RawMessage) []string {
	var body struct {
		RequestID  json.RawMessage `json:"requestId"`
		RequestID2 json.RawMessage `json:"request_id"`
		ID         json.RawMessage `json:"id"`
		ApprovalID json.RawMessage `json:"approvalId"`
	}
	if json.Unmarshal(params, &body) != nil {
		return nil
	}
	seen := map[string]struct{}{}
	ids := []string{}
	for _, raw := range []json.RawMessage{body.RequestID, body.RequestID2, body.ID, body.ApprovalID} {
		key := gatewayRequestIDKey(rawMessagePointer(raw))
		if key == "" {
			continue
		}
		if _, duplicate := seen[key]; duplicate {
			continue
		}
		seen[key] = struct{}{}
		ids = append(ids, key)
	}
	return ids
}
