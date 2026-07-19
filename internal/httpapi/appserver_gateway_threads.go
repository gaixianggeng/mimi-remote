package httpapi

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/gorilla/websocket"
)

func (p *appServerGatewayPolicy) rememberPendingThreadResponse(id *json.RawMessage, method string, cwd string, scopeID string) error {
	return p.rememberPendingThreadResponseWithManagedUse(id, method, cwd, scopeID, "")
}

func (p *appServerGatewayPolicy) rememberPendingThreadResponseWithManagedUse(id *json.RawMessage, method string, cwd string, scopeID string, managedWorktreePath string) error {
	return p.rememberPendingThreadRequest(id, appServerGatewayPendingThreadRequest{
		method: method, cwd: cwd, scopeID: scopeID, managedWorktreePath: managedWorktreePath,
	})
}

func (p *appServerGatewayPolicy) rememberPendingThreadSearchResponse(id *json.RawMessage, limit int64, limitSet bool) error {
	return p.rememberPendingThreadRequest(id, appServerGatewayPendingThreadRequest{
		method: "thread/search", responseLimit: limit, responseLimitSet: limitSet,
	})
}

func (p *appServerGatewayPolicy) rememberPendingThreadRequest(id *json.RawMessage, pending appServerGatewayPendingThreadRequest) error {
	key := gatewayRequestIDKey(id)
	if key == "" {
		if pending.managedWorktreePath != "" {
			return fmt.Errorf("gateway pending thread 请求缺少 id")
		}
		return nil
	}
	if p.beforePendingRemember != nil {
		p.beforePendingRemember()
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return fmt.Errorf("app-server gateway 连接已关闭")
	}
	now := time.Now()
	p.prunePendingThreadsLocked(now)
	if _, exists := p.pendingThreads[key]; !exists && len(p.pendingThreads) >= appServerGatewayPendingThreadMax {
		return fmt.Errorf("gateway pending thread 请求过多")
	}
	if _, exists := p.pendingThreads[key]; exists {
		return fmt.Errorf("gateway pending thread 请求 id 重复")
	}
	pending.createdAt = now
	p.pendingThreads[key] = pending
	return nil
}

func (p *appServerGatewayPolicy) prunePendingThreadsLocked(now time.Time) {
	for id, pending := range p.pendingThreads {
		if pending.managedWorktreePath != "" {
			// managed checkout 的 lease 不能因本地 TTL 自动释放：上游可能仍在
			// 创建/恢复 thread。只有明确响应、明确失败或 policy.close()
			// 才能证明该 cwd 不再处于未完成使用窗口。
			continue
		}
		if pending.createdAt.IsZero() || now.Sub(pending.createdAt) > appServerGatewayPendingThreadTTL {
			delete(p.pendingThreads, id)
		}
	}
}

func (p *appServerGatewayPolicy) allowedThread(threadID string) (appServerGatewayAllowedThread, bool) {
	threadID = strings.TrimSpace(threadID)
	if threadID == "" {
		return appServerGatewayAllowedThread{}, false
	}
	p.mu.Lock()
	thread, ok := p.allowedThreads[threadID]
	p.mu.Unlock()
	if ok {
		return thread, true
	}
	return p.router.gatewayThread(p.runtimeID, threadID)
}

func (r *Router) gatewayThread(runtimeID string, threadID string) (appServerGatewayAllowedThread, bool) {
	runtimeID = normalizeAppServerRuntimeID(runtimeID)
	if runtimeID == "" {
		runtimeID = "codex"
	}
	threadID = strings.TrimSpace(threadID)
	if threadID == "" {
		return appServerGatewayAllowedThread{}, false
	}
	key := gatewayThreadCacheKey(runtimeID, threadID)
	now := time.Now()
	r.gatewayThreadsMu.Lock()
	defer r.gatewayThreadsMu.Unlock()
	thread, ok := r.gatewayThreads[key]
	if !ok {
		return appServerGatewayAllowedThread{}, false
	}
	if gatewayThreadCacheExpired(thread, now) {
		delete(r.gatewayThreads, key)
		return appServerGatewayAllowedThread{}, false
	}
	// 全局授权表只服务断线重连的短期恢复；命中时刷新 lastSeen，让活跃 thread 不被容量裁剪误删。
	thread.lastSeen = now
	r.gatewayThreads[key] = thread
	return thread, ok
}

func (p *appServerGatewayPolicy) observeUpstreamFrame(messageType int, payload []byte) ([]byte, bool, *appServerGatewayPolicyError) {
	if messageType != websocket.TextMessage {
		return payload, true, nil
	}
	var frame appServerGatewayFrame
	if err := json.Unmarshal(payload, &frame); err != nil {
		return payload, true, nil
	}
	if strings.TrimSpace(frame.Method) != "" && frame.ID != nil {
		if !appServerServerRequestAllowed(p.runtimeID, frame.Method) {
			return payload, false, &appServerGatewayPolicyError{
				id:      frame.ID,
				message: "app-server server request 尚未被移动端支持：" + strings.TrimSpace(frame.Method),
				data: map[string]any{
					"reason": "unsupported_server_request",
					"method": strings.TrimSpace(frame.Method),
				},
			}
		}
		if err := p.rememberPendingServerRequest(frame.ID, frame.Method); err != nil {
			return payload, false, &appServerGatewayPolicyError{id: frame.ID, message: err.Error()}
		}
		return payload, true, nil
	}
	if strings.TrimSpace(frame.Method) != "" && frame.ID == nil {
		if normalizeAppServerRuntimeID(p.runtimeID) == "codex" && appServerMediaRedactNotificationsEnabled() {
			if redacted, changed := p.router.redactInlineHistoryImagesInGatewayResponse(payload); changed {
				payload = redacted
			}
		}
		return payload, true, nil
	}
	if gatewayFrameIsResponse(&frame) {
		if pending, ok := p.consumePendingHistoryRequest(frame.ID); ok {
			if len(frame.Error) == 0 && len(frame.Result) > 0 {
				if redacted, changed := p.router.redactInlineHistoryImagesInGatewayResponse(payload); changed {
					payload = redacted
				}
			}
			blocked := !pending.redactOnly && len(frame.Error) == 0 && len(frame.Result) > 0 && appServerGatewayHistoryResponseCapBytes > 0 && len(payload) > appServerGatewayHistoryResponseCapBytes
			p.recordHistoryResponseMetrics(pending.method, len(payload), blocked)
			if !pending.redactOnly {
				p.recordHistoryResponseBudget(pending, len(payload))
				if blocked {
					p.forgetPending(frame.ID)
					return payload, false, &appServerGatewayPolicyError{
						id:      frame.ID,
						message: fmt.Sprintf("%s history response 过大（%d bytes > %d bytes），gateway 已阻断；请降低 limit/itemsView 或改用分页读取", pending.method, len(payload), appServerGatewayHistoryResponseCapBytes),
						data: gatewayPolicyErrorData("history_response_too_large", appServerGatewayHistoryBudgetWindow, map[string]any{
							"method":           pending.method,
							"threadId":         pending.threadID,
							"cwd":              pending.cwd,
							"itemsView":        pending.itemsView,
							"responseBytes":    len(payload),
							"maxResponseBytes": appServerGatewayHistoryResponseCapBytes,
						}),
						target:                 "client",
						historyResponseBlocked: true,
					}
				}
			}
		}
	}
	if !p.hasPendingThreadResponses() {
		return payload, true, nil
	}
	if frame.ID == nil || len(frame.Result) == 0 || len(frame.Error) > 0 {
		p.forgetPending(frame.ID)
		return payload, true, nil
	}
	key := gatewayRequestIDKey(frame.ID)
	if key == "" {
		return payload, true, nil
	}
	p.mu.Lock()
	pending, ok := p.pendingThreads[key]
	p.mu.Unlock()
	if !ok {
		return payload, true, nil
	}
	if pending.method == "thread/search" {
		rewritten, threads, err := p.sanitizeThreadSearchResponse(payload, pending)
		if err != nil {
			p.forgetPending(frame.ID)
			return payload, false, &appServerGatewayPolicyError{
				id: frame.ID, message: err.Error(), target: "client",
			}
		}
		p.completePendingThreadResponse(key, pending, threads)
		return rewritten, true, nil
	}
	p.completePendingThreadResponse(key, pending, p.threadsFromResult(frame.Result, pending))
	// 成功响应先把 thread 写入连接级与全局 gateway 授权表，再释放
	// pending-use。转换期间至少有一种保护存在，cleanup 看不到可删除窗口。
	return payload, true, nil
}

func (p *appServerGatewayPolicy) sanitizeThreadSearchResponse(payload []byte, pending appServerGatewayPendingThreadRequest) ([]byte, []appServerGatewayAllowedThread, error) {
	var response map[string]json.RawMessage
	if err := json.Unmarshal(payload, &response); err != nil {
		return nil, nil, fmt.Errorf("thread/search response 无效")
	}
	var resultFields map[string]json.RawMessage
	if raw := response["result"]; len(raw) == 0 || bytes.Equal(bytes.TrimSpace(raw), []byte("null")) || json.Unmarshal(raw, &resultFields) != nil {
		return nil, nil, fmt.Errorf("thread/search response.result 必须是对象")
	}
	dataRaw, ok := resultFields["data"]
	if !ok || bytes.Equal(bytes.TrimSpace(dataRaw), []byte("null")) {
		return nil, nil, fmt.Errorf("thread/search response.data 必须是数组")
	}
	var rawItems []json.RawMessage
	if err := json.Unmarshal(dataRaw, &rawItems); err != nil {
		return nil, nil, fmt.Errorf("thread/search response.data 必须是数组")
	}

	limit := int64(appServerGatewayThreadSearchMaxLimit)
	if pending.responseLimitSet {
		limit = pending.responseLimit
	}
	if limit < 0 || limit > appServerGatewayThreadSearchMaxLimit {
		limit = appServerGatewayThreadSearchMaxLimit
	}
	safeItems := make([]map[string]any, 0, min(len(rawItems), int(limit)))
	allowedThreads := make([]appServerGatewayAllowedThread, 0, cap(safeItems))
	for _, rawItem := range rawItems {
		if int64(len(safeItems)) >= limit {
			break
		}
		var item map[string]json.RawMessage
		if json.Unmarshal(rawItem, &item) != nil {
			continue
		}
		var snippet string
		if raw := item["snippet"]; len(raw) == 0 || json.Unmarshal(raw, &snippet) != nil {
			continue
		}
		threadRaw := item["thread"]
		var thread appServerGatewayThreadWire
		if len(threadRaw) == 0 || bytes.Equal(bytes.TrimSpace(threadRaw), []byte("null")) || json.Unmarshal(threadRaw, &thread) != nil {
			continue
		}
		threadID := strings.TrimSpace(thread.ID)
		cwd := strings.TrimSpace(thread.CWD)
		// 0.144.2 schema 要求 Thread.id 与绝对 cwd。不能让 filepath.Abs 把相对路径
		// 悄悄解释成 agentd 当前目录，也不能把 trim 后与客户端看到值不同的 thread 登记进授权表。
		if threadID == "" || threadID != thread.ID || cwd == "" || cwd != thread.CWD || !filepath.IsAbs(cwd) {
			continue
		}
		scope, ok := p.router.gatewayScopeForPath(cwd)
		if !ok {
			continue
		}
		info, err := os.Stat(scope.realPath)
		if err != nil || !info.IsDir() {
			continue
		}
		safeItems = append(safeItems, map[string]any{
			"thread":  threadRaw,
			"snippet": snippet,
		})
		allowedThreads = append(allowedThreads, appServerGatewayAllowedThread{
			id: threadID, runtimeID: normalizeAppServerRuntimeID(p.runtimeID), cwd: scope.realPath, scopeID: scope.id,
		})
	}

	// 只重建协议声明字段：被过滤条目的 snippet 与 result 级未知字段都不会残留在下行 JSON。
	safeResult := map[string]any{"data": safeItems}
	copyGatewaySearchCursor(safeResult, resultFields, "nextCursor")
	copyGatewaySearchCursor(safeResult, resultFields, "backwardsCursor")
	safeResponse := map[string]any{
		"jsonrpc": "2.0",
		"id":      response["id"],
		"result":  safeResult,
	}
	rewritten, err := json.Marshal(safeResponse)
	if err != nil {
		return nil, nil, fmt.Errorf("重写 thread/search response 失败：%w", err)
	}
	return rewritten, allowedThreads, nil
}

func copyGatewaySearchCursor(dst map[string]any, src map[string]json.RawMessage, key string) {
	raw, ok := src[key]
	if !ok {
		return
	}
	if bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		dst[key] = nil
		return
	}
	var cursor string
	if json.Unmarshal(raw, &cursor) == nil {
		dst[key] = cursor
	}
}

func appServerServerRequestAllowed(runtimeID string, method string) bool {
	// Codex 与 Claude 都只开放 iOS 已实现的反向请求。bridge 是外部进程，未知方法同样必须
	// fail closed，避免移动端无法响应时让 Claude turn 永久等待。
	_ = runtimeID
	_, ok := appServerAllowedServerRequestMethods[strings.TrimSpace(method)]
	return ok
}

func appServerMediaRedactNotificationsEnabled() bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv(appServerMediaRedactNotifyEnv))) {
	case "0", "false", "off", "no":
		return false
	default:
		return true
	}
}

func gatewayFrameIsResponse(frame *appServerGatewayFrame) bool {
	return frame != nil &&
		strings.TrimSpace(frame.Method) == "" &&
		frame.ID != nil &&
		(len(frame.Result) > 0 || len(frame.Error) > 0)
}

func (p *appServerGatewayPolicy) rememberPendingClientRequest(id *json.RawMessage, method string) error {
	key := gatewayRequestIDKey(id)
	if key == "" {
		return fmt.Errorf("%s 请求缺少 id", method)
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	now := time.Now()
	p.prunePendingClientRequestsLocked(now)
	if p.pendingClientRequests == nil {
		p.pendingClientRequests = map[string]appServerGatewayPendingClientRequest{}
	}
	if _, exists := p.pendingClientRequests[key]; !exists && len(p.pendingClientRequests) >= appServerGatewayPendingClientRequestMax {
		return fmt.Errorf("gateway pending client request 过多")
	}
	p.pendingClientRequests[key] = appServerGatewayPendingClientRequest{method: method, createdAt: now}
	return nil
}

func (p *appServerGatewayPolicy) consumePendingClientRequest(id *json.RawMessage) (appServerGatewayPendingClientRequest, bool) {
	key := gatewayRequestIDKey(id)
	if key == "" {
		return appServerGatewayPendingClientRequest{}, false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	p.prunePendingClientRequestsLocked(time.Now())
	request, ok := p.pendingClientRequests[key]
	if ok {
		delete(p.pendingClientRequests, key)
	}
	return request, ok
}

func (p *appServerGatewayPolicy) prunePendingClientRequestsLocked(now time.Time) {
	for id, pending := range p.pendingClientRequests {
		if pending.createdAt.IsZero() || now.Sub(pending.createdAt) > appServerGatewayPendingClientRequestTTL {
			delete(p.pendingClientRequests, id)
		}
	}
}

func (p *appServerGatewayPolicy) rememberPendingServerRequest(id *json.RawMessage, method string) error {
	key := gatewayRequestIDKey(id)
	if key == "" {
		return fmt.Errorf("app-server request 缺少 id")
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	now := time.Now()
	p.prunePendingServerRequestsLocked(now)
	if p.pendingServerRequests == nil {
		p.pendingServerRequests = map[string]appServerGatewayPendingServerRequest{}
	}
	if _, exists := p.pendingServerRequests[key]; !exists && len(p.pendingServerRequests) >= appServerGatewayPendingServerRequestMax {
		return fmt.Errorf("gateway pending server request 过多")
	}
	p.pendingServerRequests[key] = appServerGatewayPendingServerRequest{method: method, createdAt: now}
	return nil
}

func (p *appServerGatewayPolicy) consumePendingServerRequest(id *json.RawMessage) (appServerGatewayPendingServerRequest, bool) {
	key := gatewayRequestIDKey(id)
	if key == "" {
		return appServerGatewayPendingServerRequest{}, false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	p.prunePendingServerRequestsLocked(time.Now())
	request, ok := p.pendingServerRequests[key]
	if ok {
		delete(p.pendingServerRequests, key)
	}
	return request, ok
}

func (p *appServerGatewayPolicy) prunePendingServerRequestsLocked(now time.Time) {
	for id, pending := range p.pendingServerRequests {
		if pending.createdAt.IsZero() || now.Sub(pending.createdAt) > appServerGatewayPendingServerRequestTTL {
			delete(p.pendingServerRequests, id)
		}
	}
}

func (p *appServerGatewayPolicy) hasPendingThreadResponses() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.prunePendingThreadsLocked(time.Now())
	return len(p.pendingThreads) > 0
}

func (p *appServerGatewayPolicy) forgetPending(id *json.RawMessage) {
	key := gatewayRequestIDKey(id)
	if key == "" {
		return
	}
	p.mu.Lock()
	pending, ok := p.pendingThreads[key]
	if ok {
		delete(p.pendingThreads, key)
	}
	p.mu.Unlock()
	if ok {
		p.router.releaseManagedWorktreePendingUse(pending.managedWorktreePath)
	}
}

func (p *appServerGatewayPolicy) isClosed() bool {
	p.mu.Lock()
	closed := p.closed
	p.mu.Unlock()
	return closed
}

func (p *appServerGatewayPolicy) close() {
	p.mu.Lock()
	if p.closed {
		p.mu.Unlock()
		return
	}
	p.closed = true
	paths := make([]string, 0, len(p.pendingThreads))
	for key, pending := range p.pendingThreads {
		if pending.managedWorktreePath != "" {
			paths = append(paths, pending.managedWorktreePath)
		}
		delete(p.pendingThreads, key)
	}
	p.mu.Unlock()
	for _, path := range paths {
		p.router.releaseManagedWorktreePendingUse(path)
	}
}

func (p *appServerGatewayPolicy) threadsFromResult(raw json.RawMessage, pending appServerGatewayPendingThreadRequest) []appServerGatewayAllowedThread {
	var threads []appServerGatewayThreadWire
	var object map[string]json.RawMessage
	if err := json.Unmarshal(raw, &object); err == nil {
		appendThreadWire := func(value json.RawMessage) {
			var thread appServerGatewayThreadWire
			if len(value) > 0 && !bytes.Equal(bytes.TrimSpace(value), []byte("null")) && json.Unmarshal(value, &thread) == nil {
				threads = append(threads, thread)
			}
		}
		appendThreadWire(object["thread"])
		for _, key := range []string{"data", "threads"} {
			if value := object[key]; len(value) > 0 {
				var list []appServerGatewayThreadWire
				if err := json.Unmarshal(value, &list); err == nil {
					threads = append(threads, list...)
				}
			}
		}
	}
	if len(threads) == 0 {
		var list []appServerGatewayThreadWire
		if err := json.Unmarshal(raw, &list); err == nil {
			threads = append(threads, list...)
		}
	}

	out := make([]appServerGatewayAllowedThread, 0, len(threads))
	for _, item := range threads {
		id := firstNonEmpty(item.ID, item.ThreadID, item.SessionID)
		if strings.TrimSpace(id) == "" {
			continue
		}
		cwd := firstNonEmpty(item.CWD, item.Path, pending.cwd)
		scope, ok := p.router.gatewayScopeForPath(cwd)
		if !ok {
			continue
		}
		if pending.scopeID != "" && scope.id != pending.scopeID {
			continue
		}
		out = append(out, appServerGatewayAllowedThread{
			id:        strings.TrimSpace(id),
			runtimeID: normalizeAppServerRuntimeID(p.runtimeID),
			// browse 作用域用 canonical 路径绑定，避免同一目录的不同写法绕过精确匹配。
			cwd:     scope.realPath,
			scopeID: scope.id,
		})
	}
	return out
}

func (p *appServerGatewayPolicy) allowThread(thread appServerGatewayAllowedThread) {
	thread, ok := p.normalizeAllowedThread(thread)
	if !ok {
		return
	}
	p.mu.Lock()
	p.allowedThreads[thread.id] = thread
	p.mu.Unlock()
	p.router.allowGatewayThread(thread)
}

func (p *appServerGatewayPolicy) normalizeAllowedThread(thread appServerGatewayAllowedThread) (appServerGatewayAllowedThread, bool) {
	if strings.TrimSpace(thread.id) == "" || strings.TrimSpace(thread.scopeID) == "" {
		return appServerGatewayAllowedThread{}, false
	}
	if strings.TrimSpace(thread.runtimeID) == "" {
		thread.runtimeID = normalizeAppServerRuntimeID(p.runtimeID)
	}
	thread.lastSeen = time.Now()
	return thread, true
}

func (p *appServerGatewayPolicy) completePendingThreadResponse(key string, pending appServerGatewayPendingThreadRequest, threads []appServerGatewayAllowedThread) {
	normalized := make([]appServerGatewayAllowedThread, 0, len(threads))
	for _, thread := range threads {
		if item, ok := p.normalizeAllowedThread(thread); ok {
			normalized = append(normalized, item)
		}
	}

	if pending.managedWorktreePath == "" {
		p.mu.Lock()
		current, ok := p.pendingThreads[key]
		if p.closed || !ok || current.createdAt != pending.createdAt {
			p.mu.Unlock()
			return
		}
		delete(p.pendingThreads, key)
		for _, thread := range normalized {
			p.allowedThreads[thread.id] = thread
			p.router.allowGatewayThread(thread)
		}
		p.mu.Unlock()
		return
	}

	// 固定锁顺序 cleanupMu -> policy.mu -> gatewayThreadsMu。policy.mu 与
	// pending entry 一起充当 close barrier：close 若先发生，晚到响应
	// 不得重新登记 thread；响应若先发生，则在同一 cleanup
	// 临界区内完成全局授权与 lease 释放。
	p.router.managedWorktreeCleanupMu.Lock()
	p.mu.Lock()
	current, ok := p.pendingThreads[key]
	if p.closed || !ok || current.managedWorktreePath != pending.managedWorktreePath || current.createdAt != pending.createdAt {
		p.mu.Unlock()
		p.router.managedWorktreeCleanupMu.Unlock()
		return
	}
	if p.beforeManagedComplete != nil {
		p.beforeManagedComplete()
	}
	delete(p.pendingThreads, key)
	for _, thread := range normalized {
		p.allowedThreads[thread.id] = thread
		p.router.allowGatewayThread(thread)
	}
	p.router.releaseManagedWorktreePendingUseLocked(pending.managedWorktreePath)
	p.mu.Unlock()
	p.router.managedWorktreeCleanupMu.Unlock()
}

func (r *Router) allowGatewayThread(thread appServerGatewayAllowedThread) {
	if strings.TrimSpace(thread.id) == "" || strings.TrimSpace(thread.scopeID) == "" {
		return
	}
	if strings.TrimSpace(thread.runtimeID) == "" {
		thread.runtimeID = "codex"
	}
	thread.runtimeID = normalizeAppServerRuntimeID(thread.runtimeID)
	now := time.Now()
	thread.lastSeen = now
	r.gatewayThreadsMu.Lock()
	r.gatewayThreads[gatewayThreadCacheKey(thread.runtimeID, thread.id)] = thread
	r.pruneGatewayThreadsLocked(now)
	r.gatewayThreadsMu.Unlock()
}

func gatewayThreadCacheKey(runtimeID string, threadID string) string {
	return normalizeAppServerRuntimeID(runtimeID) + "\x00" + strings.TrimSpace(threadID)
}

func (r *Router) pruneGatewayThreadsLocked(now time.Time) {
	for id, thread := range r.gatewayThreads {
		if gatewayThreadCacheExpired(thread, now) {
			delete(r.gatewayThreads, id)
		}
	}
	for len(r.gatewayThreads) > appServerGatewayThreadCacheMax {
		oldestID := ""
		oldestSeen := time.Time{}
		for id, thread := range r.gatewayThreads {
			seen := thread.lastSeen
			if seen.IsZero() {
				seen = now.Add(-appServerGatewayThreadCacheTTL - time.Nanosecond)
			}
			if oldestID == "" || seen.Before(oldestSeen) {
				oldestID = id
				oldestSeen = seen
			}
		}
		if oldestID == "" {
			return
		}
		delete(r.gatewayThreads, oldestID)
	}
}

func gatewayThreadCacheExpired(thread appServerGatewayAllowedThread, now time.Time) bool {
	if thread.lastSeen.IsZero() {
		return false
	}
	return now.Sub(thread.lastSeen) > appServerGatewayThreadCacheTTL
}

func gatewayRequestIDKey(id *json.RawMessage) string {
	if id == nil || len(bytes.TrimSpace(*id)) == 0 {
		return ""
	}
	return string(bytes.TrimSpace(*id))
}

func decodeGatewayParams(raw json.RawMessage) (map[string]any, error) {
	if len(bytes.TrimSpace(raw)) == 0 || bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		return map[string]any{}, nil
	}
	var params map[string]any
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	// 官方 app-server 当前使用命名参数；远程 gateway 不支持 positional params，避免校验策略时漏掉 cwd/sandbox 字段。
	if err := decoder.Decode(&params); err != nil {
		return nil, fmt.Errorf("JSON-RPC params 必须是对象")
	}
	return params, nil
}
