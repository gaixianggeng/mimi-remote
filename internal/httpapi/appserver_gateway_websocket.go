package httpapi

import (
	"context"
	"encoding/json"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

func (r *Router) proxyAppServerGateway(ctx context.Context, client *websocket.Conn, upstream *websocket.Conn, monitor *relayGatewayConnMonitor) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	done := make(chan string, 5)
	var clientWriteMu sync.Mutex
	var upstreamWriteMu sync.Mutex
	configureGatewayReadConn(client)
	configureGatewayReadConn(upstream)
	policy := newAppServerGatewayPolicy(r, "codex")
	defer policy.releaseAllHistoryInflight()
	defer policy.close()

	go func() {
		done <- r.copyClientFramesToAppServer(ctx, client, upstream, &clientWriteMu, &upstreamWriteMu, policy, monitor, nil, nil, nil, nil)
	}()
	go func() {
		done <- copyWebSocketFrames(ctx, upstream, client, &upstreamWriteMu, &clientWriteMu, policy, monitor)
	}()
	// 两端各自保活，避免 client 与 upstream 的慢速大帧锁等待在同一个 ping loop 中串联。
	go func() {
		done <- pingGatewayConnection(ctx, client, &clientWriteMu, "client_ping_write")
	}()
	go func() {
		done <- pingGatewayConnection(ctx, upstream, &upstreamWriteMu, "upstream_ping_write")
	}()
	reason := <-done
	cancel()
	_ = client.Close()
	_ = upstream.Close()
	monitor.finish(reason)
}

// newAppServerGatewayPolicy 初始化一次连接（或一个 broker 会话）的全部策略状态。
// broker 与一对一代理必须共用同一套初始化，否则两条路径的裁剪规则会悄悄分叉。
func newAppServerGatewayPolicy(r *Router, runtimeID string) *appServerGatewayPolicy {
	return &appServerGatewayPolicy{
		router:                r,
		runtimeID:             runtimeID,
		pendingThreads:        map[string]appServerGatewayPendingThreadRequest{},
		pendingClientRequests: map[string]appServerGatewayPendingClientRequest{},
		pendingServerRequests: map[string]appServerGatewayPendingServerRequest{},
		activeServerTurns:     map[string]struct{}{},
		pendingHistory:        map[string]appServerGatewayPendingHistoryRequest{},
		historyBudgets:        map[string]appServerGatewayHistoryBudget{},
		allowedThreads:        map[string]appServerGatewayAllowedThread{},
	}
}

func configureGatewayReadConn(conn *websocket.Conn) {
	conn.SetReadLimit(appServerGatewayReadLimit)
	_ = conn.SetReadDeadline(time.Now().Add(appServerGatewayPongWait))
	conn.SetPongHandler(func(string) error {
		return conn.SetReadDeadline(time.Now().Add(appServerGatewayPongWait))
	})
}

func pingGatewayConnection(ctx context.Context, conn *websocket.Conn, writeMu *sync.Mutex, failureStage string) string {
	ticker := time.NewTicker(appServerGatewayPingPeriod)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return "context_done"
		case <-ticker.C:
			if err := writeWebSocketControl(conn, writeMu, websocket.PingMessage, nil, appServerGatewayWriteWindow); err != nil {
				return gatewayCloseReason(failureStage, err)
			}
		}
	}
}

// clientFrameInterceptor 让 broker 在帧到达上游之前把它接下来。
//
// 它存在的唯一原因是握手状态：broker 复用同一条上游连接，而 JSON-RPC 握手是
// 有状态的——客户端每次重连都会重发 initialize，上游那条连接却早已握过手，
// 会回 "already initialized"，客户端据此判定致命错误并重连，形成风暴。
//
// 返回 handled=true 表示这一帧不再转发；response 非空时直接回给客户端。
type clientFrameInterceptor func(payload []byte) (handled bool, response []byte)

// clientFrameForwardTracker 在帧写入前登记 broker 必须保留的生命周期状态。
// 返回的 rollback 只在上游写入失败时调用。
type clientFrameForwardTracker func(messageType int, payload []byte) (rollback func())

// clientFrameAuthorizer 在策略校验前确认当前连接仍有上游写权限。broker 用同一把
// frameMu 串行化接管与整帧处理，避免旧连接先消费审批状态、随后才发现自己已被替换。
type clientFrameAuthorizer func() bool

func (r *Router) copyClientFramesToAppServer(ctx context.Context, client *websocket.Conn, upstream *websocket.Conn, clientWriteMu *sync.Mutex, upstreamWriteMu *sync.Mutex, policy *appServerGatewayPolicy, monitor *relayGatewayConnMonitor, frameMu *sync.Mutex, authorize clientFrameAuthorizer, intercept clientFrameInterceptor, trackForward clientFrameForwardTracker) string {
	for {
		messageType, payload, err := client.ReadMessage()
		if err != nil {
			return gatewayCloseReason("client_read", err)
		}
		if frameMu != nil {
			frameMu.Lock()
		}
		reason, stop := r.processClientFrameToAppServer(ctx, client, upstream, clientWriteMu, upstreamWriteMu, policy, monitor, authorize, intercept, trackForward, messageType, payload)
		if frameMu != nil {
			frameMu.Unlock()
		}
		if stop {
			return reason
		}
	}
}

func (r *Router) processClientFrameToAppServer(ctx context.Context, client *websocket.Conn, upstream *websocket.Conn, clientWriteMu *sync.Mutex, upstreamWriteMu *sync.Mutex, policy *appServerGatewayPolicy, monitor *relayGatewayConnMonitor, authorize clientFrameAuthorizer, intercept clientFrameInterceptor, trackForward clientFrameForwardTracker, messageType int, payload []byte) (string, bool) {
	if authorize != nil && !authorize() {
		return "broker_sink_replaced", true
	}
	if intercept != nil && messageType == websocket.TextMessage {
		if handled, response := intercept(payload); handled {
			if len(response) > 0 {
				if err := writeWebSocketFrame(client, clientWriteMu, websocket.TextMessage, response); err != nil {
					return gatewayCloseReason("client_intercept_write", err), true
				}
			}
			return "", false
		}
	}
	policyStart := time.Now()
	forwardPayload, policyErr := policy.validateClientFrameContext(ctx, messageType, payload)
	policyDuration := time.Since(policyStart)
	if policyErr != nil {
		monitor.recordPolicyError("client_to_upstream", len(payload), policyDuration)
		if policyErr.historyBudgetRejected {
			monitor.recordHistoryBudgetRejected()
		}
		// 非法请求只回 JSON-RPC error，不把高危帧送到 app-server。
		if !writeGatewayPolicyError(client, clientWriteMu, policyErr) {
			return "client_policy_error_write_failed", true
		}
		return "", false
	}
	if cachedPayload, ok := policy.cachedAccountTokenUsageResponse(payload, time.Now()); ok {
		writeStart := time.Now()
		if err := writeWebSocketFrame(client, clientWriteMu, websocket.TextMessage, cachedPayload); err != nil {
			return gatewayCloseReason("client_cache_write", err), true
		}
		monitor.recordForward("upstream_to_client", len(cachedPayload), len(cachedPayload), policyDuration, time.Since(writeStart), cachedPayload)
		return "", false
	}
	requestID := monitor.beginRPCRequest(forwardPayload, len(forwardPayload))
	var rollbackForward func()
	if trackForward != nil {
		// 必须先登记再写上游；否则极快的 turn/started 或 turn/completed
		// 可能先被 broker 读到，留下反向的生命周期竞态。
		rollbackForward = trackForward(messageType, forwardPayload)
	}
	writeStart := time.Now()
	if err := writeWebSocketFrame(upstream, upstreamWriteMu, messageType, forwardPayload); err != nil {
		if rollbackForward != nil {
			rollbackForward()
		}
		monitor.cancelRPCRequest(requestID)
		return gatewayCloseReason("upstream_write", err), true
	}
	monitor.recordForward("client_to_upstream", len(payload), len(forwardPayload), policyDuration, time.Since(writeStart), forwardPayload)
	r.scheduleAutoThreadTitleFromMessage(forwardPayload, policy, func(threadID string, title string) {
		// thread/name/set 由独立 loopback 连接执行，它产生的 notification 只回到
		// 那条连接；这里给发起会话的移动端补发同形通知，让 UI 无需轮询即可更新。
		notification, err := json.Marshal(map[string]any{
			"method": "thread/name/updated",
			"params": map[string]any{
				"threadId":   threadID,
				"threadName": title,
			},
		})
		if err != nil {
			return
		}
		_ = writeWebSocketFrame(client, clientWriteMu, websocket.TextMessage, notification)
	})
	return "", false
}

func copyWebSocketFrames(ctx context.Context, from *websocket.Conn, to *websocket.Conn, fromWriteMu *sync.Mutex, toWriteMu *sync.Mutex, policy *appServerGatewayPolicy, monitor *relayGatewayConnMonitor) string {
	for {
		select {
		case <-ctx.Done():
			return "context_done"
		default:
		}
		messageType, payload, err := from.ReadMessage()
		if err != nil {
			return gatewayCloseReason("upstream_read", err)
		}
		policyStart := time.Now()
		forwardPayload, forward, policyErr := policy.observeUpstreamFrame(messageType, payload)
		policyDuration := time.Since(policyStart)
		if policyErr != nil {
			monitor.recordPolicyError("upstream_to_client", len(payload), policyDuration)
			if policyErr.historyResponseBlocked {
				monitor.recordHistoryResponseBlocked(len(payload), payload)
			}
			if policyErr.target == "client" {
				if !writeGatewayPolicyError(to, toWriteMu, policyErr) {
					return "client_policy_error_write_failed"
				}
			} else if !writeGatewayPolicyError(from, fromWriteMu, policyErr) {
				return "upstream_policy_error_write_failed"
			}
			continue
		}
		if !forward {
			monitor.recordDropped("upstream_to_client", len(payload), policyDuration)
			continue
		}
		writeStart := time.Now()
		if err := writeWebSocketFrame(to, toWriteMu, messageType, forwardPayload); err != nil {
			return gatewayCloseReason("client_write", err)
		}
		monitor.recordForward("upstream_to_client", len(payload), len(forwardPayload), policyDuration, time.Since(writeStart), forwardPayload)
	}
}

func writeWebSocketFrame(conn *websocket.Conn, mu *sync.Mutex, messageType int, payload []byte) error {
	if mu != nil {
		mu.Lock()
		defer mu.Unlock()
	}
	_ = conn.SetWriteDeadline(time.Now().Add(appServerGatewayFrameWriteWindow(len(payload))))
	return conn.WriteMessage(messageType, payload)
}

func appServerGatewayFrameWriteWindow(payloadBytes int) time.Duration {
	if payloadBytes <= appServerGatewayLargeFrameThreshold {
		return appServerGatewayWriteWindow
	}

	// 向上取整，确保不足一秒的尾部数据也拥有完整的一秒写入余量。
	remainingBytes := payloadBytes - appServerGatewayLargeFrameThreshold
	extraSeconds := (remainingBytes + appServerGatewayLargeFrameBytesPerSecond - 1) /
		appServerGatewayLargeFrameBytesPerSecond
	maxExtraSeconds := int((appServerGatewayLargeFrameMaxWriteWindow - appServerGatewayWriteWindow) / time.Second)
	if extraSeconds >= maxExtraSeconds {
		return appServerGatewayLargeFrameMaxWriteWindow
	}
	return appServerGatewayWriteWindow + time.Duration(extraSeconds)*time.Second
}

func writeWebSocketControl(conn *websocket.Conn, mu *sync.Mutex, messageType int, payload []byte, writeWindow time.Duration) error {
	if mu != nil {
		mu.Lock()
		defer mu.Unlock()
	}
	// 大帧可能长时间持有同一把写锁。deadline 必须在拿到锁后生成；若在等待锁前生成，
	// 取锁时它可能早已过期，健康连接会被 ping 误判失败并整页重传。
	return conn.WriteControl(messageType, payload, time.Now().Add(writeWindow))
}
