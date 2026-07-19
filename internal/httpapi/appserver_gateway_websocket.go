package httpapi

import (
	"context"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

func (r *Router) proxyAppServerGateway(ctx context.Context, client *websocket.Conn, upstream *websocket.Conn, monitor *relayGatewayConnMonitor) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	done := make(chan string, 3)
	var clientWriteMu sync.Mutex
	var upstreamWriteMu sync.Mutex
	configureGatewayReadConn(client)
	configureGatewayReadConn(upstream)
	policy := &appServerGatewayPolicy{
		router:                r,
		runtimeID:             "codex",
		pendingThreads:        map[string]appServerGatewayPendingThreadRequest{},
		pendingClientRequests: map[string]appServerGatewayPendingClientRequest{},
		pendingServerRequests: map[string]appServerGatewayPendingServerRequest{},
		pendingHistory:        map[string]appServerGatewayPendingHistoryRequest{},
		historyBudgets:        map[string]appServerGatewayHistoryBudget{},
		allowedThreads:        map[string]appServerGatewayAllowedThread{},
	}
	defer policy.releaseAllHistoryInflight()
	defer policy.close()

	go func() {
		done <- r.copyClientFramesToAppServer(client, upstream, &clientWriteMu, &upstreamWriteMu, policy, monitor)
	}()
	go func() {
		done <- copyWebSocketFrames(ctx, upstream, client, &upstreamWriteMu, &clientWriteMu, policy, monitor)
	}()
	go func() {
		done <- pingGatewayConnections(ctx, client, upstream, &clientWriteMu, &upstreamWriteMu)
	}()

	reason := <-done
	cancel()
	_ = client.Close()
	_ = upstream.Close()
	monitor.finish(reason)
}

func configureGatewayReadConn(conn *websocket.Conn) {
	conn.SetReadLimit(appServerGatewayReadLimit)
	_ = conn.SetReadDeadline(time.Now().Add(appServerGatewayPongWait))
	conn.SetPongHandler(func(string) error {
		return conn.SetReadDeadline(time.Now().Add(appServerGatewayPongWait))
	})
}

func pingGatewayConnections(ctx context.Context, client *websocket.Conn, upstream *websocket.Conn, clientWriteMu *sync.Mutex, upstreamWriteMu *sync.Mutex) string {
	ticker := time.NewTicker(appServerGatewayPingPeriod)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return "context_done"
		case <-ticker.C:
			deadline := time.Now().Add(appServerGatewayWriteWindow)
			if err := writeWebSocketControl(client, clientWriteMu, websocket.PingMessage, nil, deadline); err != nil {
				return gatewayCloseReason("client_ping_write", err)
			}
			if err := writeWebSocketControl(upstream, upstreamWriteMu, websocket.PingMessage, nil, deadline); err != nil {
				return gatewayCloseReason("upstream_ping_write", err)
			}
		}
	}
}

func (r *Router) copyClientFramesToAppServer(client *websocket.Conn, upstream *websocket.Conn, clientWriteMu *sync.Mutex, upstreamWriteMu *sync.Mutex, policy *appServerGatewayPolicy, monitor *relayGatewayConnMonitor) string {
	for {
		messageType, payload, err := client.ReadMessage()
		if err != nil {
			return gatewayCloseReason("client_read", err)
		}
		policyStart := time.Now()
		forwardPayload, policyErr := policy.validateClientFrame(messageType, payload)
		policyDuration := time.Since(policyStart)
		if policyErr != nil {
			monitor.recordPolicyError("client_to_upstream", len(payload), policyDuration)
			if policyErr.historyBudgetRejected {
				monitor.recordHistoryBudgetRejected()
			}
			// 非法请求只回 JSON-RPC error，不把高危帧送到 app-server。
			if !writeGatewayPolicyError(client, clientWriteMu, policyErr) {
				return "client_policy_error_write_failed"
			}
			continue
		}
		requestID := monitor.beginRPCRequest(forwardPayload, len(forwardPayload))
		writeStart := time.Now()
		if err := writeWebSocketFrame(upstream, upstreamWriteMu, messageType, forwardPayload); err != nil {
			monitor.cancelRPCRequest(requestID)
			return gatewayCloseReason("upstream_write", err)
		}
		monitor.recordForward("client_to_upstream", len(payload), len(forwardPayload), policyDuration, time.Since(writeStart), forwardPayload)
	}
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
	_ = conn.SetWriteDeadline(time.Now().Add(appServerGatewayWriteWindow))
	return conn.WriteMessage(messageType, payload)
}

func writeWebSocketControl(conn *websocket.Conn, mu *sync.Mutex, messageType int, payload []byte, deadline time.Time) error {
	if mu != nil {
		mu.Lock()
		defer mu.Unlock()
	}
	return conn.WriteControl(messageType, payload, deadline)
}
