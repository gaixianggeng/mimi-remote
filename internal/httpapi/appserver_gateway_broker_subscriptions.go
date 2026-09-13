package httpapi

import (
	"encoding/json"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/gorilla/websocket"
)

type brokerQueuedTurn struct {
	clientID  string
	requestID string
}

type brokerSubscriptionRelease struct {
	id   string
	done chan struct{}
}

// App 可能在任务已开始后才连接。resume 的权威状态补齐 turn/started 的缺席，
// 请求发出到响应返回之间则复用 startingTurns 保活，防止再次提前关闭连接。
func (b *codexGatewayBroker) observeResumedThread(frame *appServerGatewayFrame) bool {
	if frame.ID == nil || frame.Method != "" || len(frame.Error) > 0 {
		return false
	}
	var result struct {
		Thread struct {
			ID     string `json:"id"`
			Status struct {
				Type string `json:"type"`
			} `json:"status"`
		} `json:"thread"`
	}
	if json.Unmarshal(frame.Result, &result) != nil || result.Thread.ID == "" {
		return false
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.startingTurns[result.Thread.ID] != gatewayRequestIDKey(frame.ID) {
		return false
	}
	delete(b.startingTurns, result.Thread.ID)
	if result.Thread.Status.Type == "active" {
		b.activeTurns[result.Thread.ID] = struct{}{}
	}
	return true
}

func (b *codexGatewayBroker) trackQueuedTurn(frame *appServerGatewayFrame) func() {
	var params struct {
		ThreadID string `json:"threadId"`
		ClientID string `json:"clientUserMessageId"`
	}
	if json.Unmarshal(frame.Params, &params) != nil || params.ThreadID == "" || params.ClientID == "" || frame.ID == nil {
		return nil
	}
	entry := brokerQueuedTurn{clientID: params.ClientID, requestID: gatewayRequestIDKey(frame.ID)}
	b.mu.Lock()
	if b.queuedTurns == nil {
		b.queuedTurns = map[string]brokerQueuedTurn{}
	}
	previous, existed := b.queuedTurns[params.ThreadID]
	b.queuedTurns[params.ThreadID] = entry
	b.mu.Unlock()
	return func() {
		b.mu.Lock()
		defer b.mu.Unlock()
		if b.queuedTurns[params.ThreadID] != entry {
			return
		}
		if existed {
			b.queuedTurns[params.ThreadID] = previous
		} else {
			delete(b.queuedTurns, params.ThreadID)
		}
	}
}

func (b *codexGatewayBroker) observeQueuedTurn(frame *appServerGatewayFrame) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if frame.ID != nil {
		if frame.Method == "" && len(frame.Error) > 0 {
			for threadID, queued := range b.queuedTurns {
				if queued.requestID == gatewayRequestIDKey(frame.ID) {
					delete(b.queuedTurns, threadID)
				}
			}
		}
		return
	}
	var params struct {
		ThreadID string `json:"threadId"`
		Item     struct {
			Type     string `json:"type"`
			ClientID string `json:"clientId"`
		} `json:"item"`
		Turn struct {
			Items []struct {
				Type     string `json:"type"`
				ClientID string `json:"clientId"`
			} `json:"items"`
		} `json:"turn"`
	}
	if json.Unmarshal(frame.Params, &params) != nil {
		return
	}
	if frame.Method == "thread/closed" {
		delete(b.queuedTurns, params.ThreadID)
		return
	}
	queued, ok := b.queuedTurns[params.ThreadID]
	if !ok {
		return
	}
	// 入队 ACK 和上一轮的终态均不代表本条消息已开始；只有对应 userMessage
	// 进入 turn 才能撤掉保活占位，避免连续两轮之间回收上游。
	if (frame.Method == "item/started" || frame.Method == "item/completed") && params.Item.Type == "userMessage" && params.Item.ClientID == queued.clientID {
		delete(b.queuedTurns, params.ThreadID)
	}
	if frame.Method == "turn/started" || frame.Method == "turn/completed" {
		for _, item := range params.Turn.Items {
			if item.Type == "userMessage" && item.ClientID == queued.clientID {
				delete(b.queuedTurns, params.ThreadID)
			}
		}
	}
}

// 调用方持有 b.mu。只读取任务标识，不缓存对话内容。
func (b *codexGatewayBroker) threadNeedsSubscriptionLocked(threadID string) bool {
	if _, ok := b.activeTurns[threadID]; ok {
		return true
	}
	if _, ok := b.startingTurns[threadID]; ok {
		return true
	}
	if _, ok := b.queuedTurns[threadID]; ok {
		return true
	}
	for _, payload := range b.pending {
		var frame appServerGatewayFrame
		if json.Unmarshal(payload, &frame) != nil {
			continue
		}
		pendingThread, _, _ := appServerGatewayServerRequestScope(frame.Params)
		if pendingThread == threadID {
			return true
		}
	}
	return false
}

func (b *codexGatewayBroker) interceptThreadSubscription(payload []byte, frame *appServerGatewayFrame) (bool, []byte) {
	method := strings.TrimSpace(frame.Method)
	if method != "thread/unsubscribe" && method != "thread/resume" {
		return false, nil
	}
	threadID, _, _ := appServerGatewayServerRequestScope(frame.Params)
	if method == "thread/resume" {
		// 上一轮结束后的内部退订必须先落定。否则迟到的退订会覆盖新页面的 resume。
		b.mu.Lock()
		release := b.subscriptionReleases[threadID]
		b.mu.Unlock()
		if release != nil {
			select {
			case <-release.done:
			case <-time.After(appServerGatewayWriteWindow):
				b.close("broker_unsubscribe_timeout")
			}
		}
		return false, nil
	}
	// 此钩子位于通用 policy 之前。只有完整校验通过，才能本地应答退订，
	// 未授权 thread 和畸形请求继续交给原路径返回错误。
	if _, err := b.policy.validateClientFrame(websocket.TextMessage, payload); err != nil {
		return false, nil
	}
	b.mu.Lock()
	if b.closed || !b.threadNeedsSubscriptionLocked(threadID) {
		b.mu.Unlock()
		return false, nil
	}
	if b.deferredUnsubscribes == nil {
		b.deferredUnsubscribes = map[string]struct{}{}
	}
	b.deferredUnsubscribes[threadID] = struct{}{}
	b.mu.Unlock()
	// 即使共享 socket 仍在线，该页面的待处理请求也已不可见。
	b.notifyPendingApprovalsAfterDetach()
	response, _ := json.Marshal(map[string]any{"id": frame.ID, "result": map[string]string{"status": "unsubscribed"}})
	return true, response
}

func (b *codexGatewayBroker) releaseIdleThreadSubscriptions() {
	b.clientFrameMu.Lock()
	defer b.clientFrameMu.Unlock()
	b.mu.Lock()
	if b.closed {
		b.mu.Unlock()
		return
	}
	var threads []string
	for threadID := range b.deferredUnsubscribes {
		if !b.threadNeedsSubscriptionLocked(threadID) {
			threads = append(threads, threadID)
		}
	}
	b.mu.Unlock()
	for _, threadID := range threads {
		release := &brokerSubscriptionRelease{id: "mimi-broker-unsubscribe-" + uuid.NewString(), done: make(chan struct{})}
		b.mu.Lock()
		// clientFrameMu 保证清理不会越过较新的 resume/queue 写入。
		delete(b.deferredUnsubscribes, threadID)
		if b.subscriptionReleases == nil {
			b.subscriptionReleases = map[string]*brokerSubscriptionRelease{}
		}
		b.subscriptionReleases[threadID] = release
		b.mu.Unlock()
		payload, _ := json.Marshal(map[string]any{"id": release.id, "method": "thread/unsubscribe", "params": map[string]string{"threadId": threadID}})
		if err := writeWebSocketFrame(b.upstream, &b.upstreamWriteMu, websocket.TextMessage, payload); err != nil {
			b.close("broker_unsubscribe_write_failed")
			return
		}
	}
}

func (b *codexGatewayBroker) consumeSubscriptionReleaseResponse(payload []byte) bool {
	var frame appServerGatewayFrame
	if json.Unmarshal(payload, &frame) != nil || frame.ID == nil || frame.Method != "" {
		return false
	}
	var id string
	if json.Unmarshal(*frame.ID, &id) != nil {
		return false
	}
	b.mu.Lock()
	for threadID, release := range b.subscriptionReleases {
		if release.id != id {
			continue
		}
		if len(frame.Error) > 0 {
			b.mu.Unlock()
			b.close("broker_unsubscribe_failed")
			return true
		}
		delete(b.subscriptionReleases, threadID)
		close(release.done)
		b.mu.Unlock()
		return true
	}
	b.mu.Unlock()
	return false
}
