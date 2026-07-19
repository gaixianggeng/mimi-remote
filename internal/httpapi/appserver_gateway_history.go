package httpapi

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

func (p *appServerGatewayPolicy) reserveHistoryRequest(id *json.RawMessage, method string, params map[string]any, requestBytes int) *appServerGatewayPolicyError {
	pending, ok := gatewayHistoryRequestFromParams(method, params)
	if !ok {
		return nil
	}
	key := gatewayRequestIDKey(id)
	if key == "" {
		return &appServerGatewayPolicyError{id: id, message: fmt.Sprintf("%s 请求缺少 id", method)}
	}
	now := time.Now()
	pending.fingerprint = gatewayHistoryRequestFingerprint(p.runtimeID, pending)
	pending.inflightOwner = fmt.Sprintf("%p\x00%s", p, key)
	if !p.reserveHistoryInflight(pending) {
		return &appServerGatewayPolicyError{
			id:      id,
			message: fmt.Sprintf("%s 相同历史或列表请求仍在执行，请稍后重试", method),
			data: gatewayPolicyErrorData("history_request_in_flight", time.Second, map[string]any{
				"method": method,
			}),
		}
	}
	budgetKey := gatewayHistoryBudgetKey(gatewayHistoryBudgetSubject(pending), pending.method, pending.itemsView)

	p.mu.Lock()
	defer p.mu.Unlock()
	p.pruneHistoryLocked(now)
	if p.pendingHistory == nil {
		p.pendingHistory = map[string]appServerGatewayPendingHistoryRequest{}
	}
	if pending.redactOnly {
		// 追踪表满时放弃改写而不是拒绝请求：redact-only 请求宁可原样透传也不能失败。
		if _, exists := p.pendingHistory[key]; !exists && len(p.pendingHistory) >= appServerGatewayPendingHistoryRequestMax {
			p.releaseHistoryInflight(pending)
			return nil
		}
		pending.createdAt = now
		p.pendingHistory[key] = pending
		return nil
	}
	if policyErr := p.router.reserveHistoryGlobalBudget(id, pending); policyErr != nil {
		p.releaseHistoryInflight(pending)
		p.recordHistoryRateLimited(pending.method)
		return policyErr
	}
	if _, exists := p.pendingHistory[key]; !exists && len(p.pendingHistory) >= appServerGatewayPendingHistoryRequestMax {
		p.releaseHistoryInflight(pending)
		return &appServerGatewayPolicyError{id: id, message: "gateway pending history 请求过多"}
	}
	if p.historyBudgets == nil {
		p.historyBudgets = map[string]appServerGatewayHistoryBudget{}
	}
	budget := p.historyBudgets[budgetKey]
	if budget.windowStarted.IsZero() || now.Sub(budget.windowStarted) >= appServerGatewayHistoryBudgetWindow {
		budget = appServerGatewayHistoryBudget{windowStarted: now}
	}
	if budget.blockedUntil.After(now) {
		p.historyBudgets[budgetKey] = budget
		p.releaseHistoryInflight(pending)
		p.recordHistoryRateLimited(pending.method)
		return gatewayHistoryBudgetPolicyError(
			id,
			fmt.Sprintf("%s 同一 thread/method 正在临时限流，请稍后重试或降低 limit/itemsView（itemsView=%s）", method, pending.itemsView),
			"history_budget_limited",
			budget.blockedUntil.Sub(now),
			pending,
			nil,
		)
	}
	if appServerGatewayHistoryBudgetMaxRequests > 0 && budget.requests >= appServerGatewayHistoryBudgetMaxRequests {
		budget.blockedUntil = now.Add(appServerGatewayHistoryBudgetWindow)
		p.historyBudgets[budgetKey] = budget
		p.releaseHistoryInflight(pending)
		p.recordHistoryRateLimited(pending.method)
		return gatewayHistoryBudgetPolicyError(
			id,
			fmt.Sprintf("%s 同一 thread/method 请求过于频繁，请稍后重试（itemsView=%s）", method, pending.itemsView),
			"history_budget_limited",
			appServerGatewayHistoryBudgetWindow,
			pending,
			nil,
		)
	}
	if appServerGatewayHistoryBudgetMaxRequestBytes > 0 && budget.requestBytes+int64(requestBytes) > appServerGatewayHistoryBudgetMaxRequestBytes {
		budget.blockedUntil = now.Add(appServerGatewayHistoryBudgetWindow)
		p.historyBudgets[budgetKey] = budget
		p.releaseHistoryInflight(pending)
		p.recordHistoryRateLimited(pending.method)
		return gatewayHistoryBudgetPolicyError(
			id,
			fmt.Sprintf("%s 同一 thread/method 请求字节预算已用尽，请稍后重试（itemsView=%s）", method, pending.itemsView),
			"history_budget_limited",
			appServerGatewayHistoryBudgetWindow,
			pending,
			nil,
		)
	}
	if appServerGatewayHistoryBudgetMaxResponseBytes > 0 && budget.responseBytes >= appServerGatewayHistoryBudgetMaxResponseBytes {
		budget.blockedUntil = now.Add(appServerGatewayHistoryBudgetWindow)
		p.historyBudgets[budgetKey] = budget
		p.releaseHistoryInflight(pending)
		p.recordHistoryRateLimited(pending.method)
		return gatewayHistoryBudgetPolicyError(
			id,
			fmt.Sprintf("%s 同一 thread/method 历史响应预算已用尽，请稍后重试（itemsView=%s）", method, pending.itemsView),
			"history_budget_limited",
			appServerGatewayHistoryBudgetWindow,
			pending,
			nil,
		)
	}
	budget.requests++
	budget.requestBytes += int64(requestBytes)
	p.historyBudgets[budgetKey] = budget
	pending.createdAt = now
	p.pendingHistory[key] = pending
	return nil
}

func gatewayHistoryRequestFromParams(method string, params map[string]any) (appServerGatewayPendingHistoryRequest, bool) {
	switch method {
	case "thread/list":
		cwd, _ := gatewayStringParam(params, "cwd")
		return appServerGatewayPendingHistoryRequest{
			method: method, cwd: cwd, cursor: gatewayOptionalStringParam(params, "cursor"),
			limit: gatewayOptionalInt64Param(params, "limit"), sortDirection: gatewayOptionalStringParam(params, "sortDirection"),
			itemsView: "list", useStateDBOnly: gatewayOptionalBoolFingerprintParam(params, "useStateDbOnly"),
		}, true
	case "thread/search":
		// 搜索没有 cwd/threadId，请求指纹必须包含完整的安全参数；预算 subject 则使用固定
		// search 桶，避免把用户搜索词写入诊断信息或错误响应。
		safeParams := sanitizedGatewayThreadSearchParams(params)
		filterFingerprint, _ := json.Marshal(safeParams)
		return appServerGatewayPendingHistoryRequest{
			method: method, cursor: gatewayOptionalStringParam(safeParams, "cursor"),
			limit: gatewayOptionalInt64Param(safeParams, "limit"), sortDirection: gatewayOptionalStringParam(safeParams, "sortDirection"),
			itemsView: "search", filterFingerprint: string(filterFingerprint),
		}, true
	case "thread/turns/list":
		threadID, ok := gatewayStringParam(params, "threadId")
		if !ok {
			return appServerGatewayPendingHistoryRequest{}, false
		}
		limit := gatewayOptionalInt64Param(params, "limit")
		if limit == 0 {
			limit = appServerGatewayThreadTurnsDefaultLimit
		}
		if gatewayHistoryItemsViewFromParams(params) == "full" && limit > appServerGatewayThreadTurnsFullMaxLimit {
			limit = appServerGatewayThreadTurnsFullMaxLimit
		}
		return appServerGatewayPendingHistoryRequest{
			method: method, threadID: threadID, cursor: gatewayOptionalStringParam(params, "cursor"), limit: limit,
			sortDirection: gatewayOptionalStringParam(params, "sortDirection"), itemsView: gatewayHistoryItemsViewFromParams(params),
		}, true
	case "thread/read":
		threadID, ok := gatewayStringParam(params, "threadId")
		if !ok {
			return appServerGatewayPendingHistoryRequest{}, false
		}
		includeTurns, includeTurnsOK := gatewayBoolParam(params, "includeTurns")
		if includeTurnsOK && includeTurns {
			return appServerGatewayPendingHistoryRequest{method: method, threadID: threadID, itemsView: "fullRead", includeTurns: true}, true
		}
	case "thread/resume":
		threadID, ok := gatewayStringParam(params, "threadId")
		if !ok {
			return appServerGatewayPendingHistoryRequest{}, false
		}
		if page, pageOK := params["initialTurnsPage"].(map[string]any); pageOK {
			safePage := sanitizedGatewayInitialTurnsPage(page)
			return appServerGatewayPendingHistoryRequest{
				method: method, threadID: threadID,
				limit: gatewayOptionalInt64Param(safePage, "limit"), sortDirection: gatewayOptionalStringParam(safePage, "sortDirection"),
				itemsView: gatewayHistoryItemsViewFromParams(safePage),
			}, true
		}
		// resume 一次性带回整段 thread（大线程 9MB+ 内联图），必须做图片改写；
		// 但它是消息发送的前置绑定，不能被预算/cap 阻断。
		return appServerGatewayPendingHistoryRequest{method: method, threadID: threadID, itemsView: "resume", redactOnly: true}, true
	}
	return appServerGatewayPendingHistoryRequest{}, false
}

func gatewayHistoryRequestFingerprint(runtimeID string, request appServerGatewayPendingHistoryRequest) string {
	// 指纹只由会改变上游结果的协议字段组成；JSON 编码避免 cwd/cursor 中的分隔符造成碰撞。
	encoded, _ := json.Marshal(struct {
		Runtime        string `json:"runtime"`
		Method         string `json:"method"`
		ThreadID       string `json:"thread,omitempty"`
		CWD            string `json:"cwd,omitempty"`
		Cursor         string `json:"cursor,omitempty"`
		Limit          int64  `json:"limit,omitempty"`
		SortDirection  string `json:"sortDirection,omitempty"`
		ItemsView      string `json:"itemsView,omitempty"`
		UseStateDBOnly string `json:"useStateDbOnly,omitempty"`
		Filter         string `json:"filter,omitempty"`
	}{
		Runtime: normalizeAppServerRuntimeID(runtimeID), Method: request.method, ThreadID: request.threadID,
		CWD: request.cwd, Cursor: request.cursor, Limit: request.limit, SortDirection: request.sortDirection,
		ItemsView: request.itemsView, UseStateDBOnly: request.useStateDBOnly, Filter: request.filterFingerprint,
	})
	return string(encoded)
}

func gatewayOptionalStringParam(params map[string]any, key string) string {
	value, _ := gatewayStringParam(params, key)
	return strings.TrimSpace(value)
}

func gatewayOptionalInt64Param(params map[string]any, key string) int64 {
	value, ok := params[key]
	if !ok || value == nil {
		return 0
	}
	parsed, _ := gatewayJSONNumberInt64(value)
	return parsed
}

func gatewayOptionalBoolFingerprintParam(params map[string]any, key string) string {
	value, ok := params[key]
	if !ok || value == nil {
		return "unset"
	}
	if flag, ok := value.(bool); ok && flag {
		return "true"
	}
	return "false"
}

func (p *appServerGatewayPolicy) reserveHistoryInflight(request appServerGatewayPendingHistoryRequest) bool {
	if p == nil || p.router == nil || p.router.monitor == nil || request.fingerprint == "" {
		return true
	}
	return p.router.monitor.reserveHistoryInflight(request.fingerprint, request.inflightOwner, request.method, appServerGatewayPendingHistoryRequestTTL)
}

func (p *appServerGatewayPolicy) releaseHistoryInflight(request appServerGatewayPendingHistoryRequest) {
	if p == nil || p.router == nil || p.router.monitor == nil {
		return
	}
	p.router.monitor.releaseHistoryInflight(request.fingerprint, request.inflightOwner)
}

func (p *appServerGatewayPolicy) recordHistoryRateLimited(method string) {
	if p == nil || p.router == nil || p.router.monitor == nil {
		return
	}
	p.router.monitor.recordHistoryRateLimited(method)
}

func (p *appServerGatewayPolicy) recordHistoryResponseMetrics(method string, responseBytes int, blocked bool) {
	if p == nil || p.router == nil || p.router.monitor == nil {
		return
	}
	p.router.monitor.recordHistoryResponseMetrics(method, responseBytes, blocked)
}

func gatewayHistoryItemsViewFromParams(params map[string]any) string {
	if itemsView, ok := gatewayStringParam(params, "itemsView"); ok {
		if normalized := strings.TrimSpace(itemsView); normalized != "" {
			return normalized
		}
	}
	return "full"
}

func gatewayHistoryBudgetKey(threadID string, method string, itemsView string) string {
	return strings.TrimSpace(threadID) + "\x00" + strings.TrimSpace(method) + "\x00" + strings.TrimSpace(itemsView)
}

func gatewayHistoryBudgetSubject(request appServerGatewayPendingHistoryRequest) string {
	if threadID := strings.TrimSpace(request.threadID); threadID != "" {
		return threadID
	}
	if request.method == "thread/search" {
		return "thread-search"
	}
	return strings.TrimSpace(request.cwd)
}

func gatewayHistoryBudgetPolicyError(
	id *json.RawMessage,
	message string,
	reason string,
	retryAfter time.Duration,
	request appServerGatewayPendingHistoryRequest,
	extra map[string]any,
) *appServerGatewayPolicyError {
	data := gatewayPolicyErrorData(reason, retryAfter, extra)
	if strings.TrimSpace(request.method) != "" {
		data["method"] = request.method
	}
	if strings.TrimSpace(request.threadID) != "" {
		data["threadId"] = request.threadID
	}
	if strings.TrimSpace(request.cwd) != "" {
		data["cwd"] = request.cwd
	}
	if strings.TrimSpace(request.itemsView) != "" {
		data["itemsView"] = request.itemsView
	}
	return &appServerGatewayPolicyError{
		id:                    id,
		message:               message,
		data:                  data,
		historyBudgetRejected: true,
	}
}

func gatewayPolicyErrorData(reason string, retryAfter time.Duration, extra map[string]any) map[string]any {
	data := map[string]any{}
	if reason != "" {
		data["reason"] = reason
	}
	if retryAfter > 0 {
		retryAfterMs := int64((retryAfter + time.Millisecond - 1) / time.Millisecond)
		retryAfterSeconds := int64((retryAfter + time.Second - 1) / time.Second)
		if retryAfterMs < 1 {
			retryAfterMs = 1
		}
		if retryAfterSeconds < 1 {
			retryAfterSeconds = 1
		}
		data["retryAfterMs"] = retryAfterMs
		data["retryAfterSeconds"] = retryAfterSeconds
	}
	for key, value := range extra {
		data[key] = value
	}
	return data
}

func (p *appServerGatewayPolicy) pruneHistoryLocked(now time.Time) {
	for id, pending := range p.pendingHistory {
		if pending.createdAt.IsZero() || now.Sub(pending.createdAt) > appServerGatewayPendingHistoryRequestTTL {
			delete(p.pendingHistory, id)
			p.releaseHistoryInflight(pending)
		}
	}
	for key, budget := range p.historyBudgets {
		if budget.windowStarted.IsZero() || (now.Sub(budget.windowStarted) >= appServerGatewayHistoryBudgetWindow && !budget.blockedUntil.After(now)) {
			delete(p.historyBudgets, key)
		}
	}
}

func (p *appServerGatewayPolicy) consumePendingHistoryRequest(id *json.RawMessage) (appServerGatewayPendingHistoryRequest, bool) {
	key := gatewayRequestIDKey(id)
	if key == "" {
		return appServerGatewayPendingHistoryRequest{}, false
	}
	p.mu.Lock()
	p.pruneHistoryLocked(time.Now())
	request, ok := p.pendingHistory[key]
	if ok {
		delete(p.pendingHistory, key)
	}
	p.mu.Unlock()
	if ok {
		p.releaseHistoryInflight(request)
	}
	return request, ok
}

func (p *appServerGatewayPolicy) cancelPendingHistoryRequest(id *json.RawMessage) {
	_, _ = p.consumePendingHistoryRequest(id)
}

func (p *appServerGatewayPolicy) releaseAllHistoryInflight() {
	if p == nil {
		return
	}
	p.mu.Lock()
	requests := make([]appServerGatewayPendingHistoryRequest, 0, len(p.pendingHistory))
	for key, request := range p.pendingHistory {
		requests = append(requests, request)
		delete(p.pendingHistory, key)
	}
	p.mu.Unlock()
	for _, request := range requests {
		p.releaseHistoryInflight(request)
	}
}

func (p *appServerGatewayPolicy) recordHistoryResponseBudget(request appServerGatewayPendingHistoryRequest, responseBytes int) {
	subject := gatewayHistoryBudgetSubject(request)
	if subject == "" || strings.TrimSpace(request.method) == "" {
		return
	}
	now := time.Now()
	key := gatewayHistoryBudgetKey(subject, request.method, request.itemsView)
	p.mu.Lock()
	if p.historyBudgets == nil {
		p.historyBudgets = map[string]appServerGatewayHistoryBudget{}
	}
	budget := p.historyBudgets[key]
	if budget.windowStarted.IsZero() || now.Sub(budget.windowStarted) >= appServerGatewayHistoryBudgetWindow {
		budget = appServerGatewayHistoryBudget{windowStarted: now}
	}
	budget.responseBytes += int64(responseBytes)
	if appServerGatewayHistoryBudgetMaxResponseBytes > 0 && budget.responseBytes >= appServerGatewayHistoryBudgetMaxResponseBytes {
		budget.blockedUntil = now.Add(appServerGatewayHistoryBudgetWindow)
	}
	p.historyBudgets[key] = budget
	p.mu.Unlock()

	p.router.recordHistoryGlobalResponseBudget(request, responseBytes)
}

func (r *Router) reserveHistoryGlobalBudget(id *json.RawMessage, request appServerGatewayPendingHistoryRequest) *appServerGatewayPolicyError {
	if r == nil || request.redactOnly || appServerGatewayHistoryGlobalMaxResponseBytes <= 0 {
		return nil
	}
	now := time.Now()
	window := appServerGatewayHistoryGlobalBudgetWindow()
	r.gatewayHistoryBudgetMu.Lock()
	defer r.gatewayHistoryBudgetMu.Unlock()
	budget := r.gatewayHistoryGlobalBudget
	if budget.windowStarted.IsZero() || (now.Sub(budget.windowStarted) >= window && !budget.blockedUntil.After(now)) {
		budget = appServerGatewayHistoryBudget{windowStarted: now}
	}
	if budget.blockedUntil.After(now) {
		r.gatewayHistoryGlobalBudget = budget
		return gatewayHistoryBudgetPolicyError(
			id,
			fmt.Sprintf("%s 全局历史下行预算已用尽，请稍后重试（itemsView=%s）", request.method, request.itemsView),
			"history_budget_limited",
			budget.blockedUntil.Sub(now),
			request,
			map[string]any{"scope": "global"},
		)
	}
	r.gatewayHistoryGlobalBudget = budget
	return nil
}

func (r *Router) recordHistoryGlobalResponseBudget(request appServerGatewayPendingHistoryRequest, responseBytes int) {
	if r == nil || request.redactOnly || appServerGatewayHistoryGlobalMaxResponseBytes <= 0 || responseBytes <= 0 {
		return
	}
	now := time.Now()
	window := appServerGatewayHistoryGlobalBudgetWindow()
	r.gatewayHistoryBudgetMu.Lock()
	defer r.gatewayHistoryBudgetMu.Unlock()
	budget := r.gatewayHistoryGlobalBudget
	if budget.windowStarted.IsZero() || (now.Sub(budget.windowStarted) >= window && !budget.blockedUntil.After(now)) {
		budget = appServerGatewayHistoryBudget{windowStarted: now}
	}
	// 核心逻辑：全局预算按进程共享，避免 full/summary/fullRead 或多连接同时拉历史时合计挤爆 5Mbps 链路。
	budget.responseBytes += int64(responseBytes)
	if budget.responseBytes >= appServerGatewayHistoryGlobalMaxResponseBytes {
		budget.blockedUntil = now.Add(window)
	}
	r.gatewayHistoryGlobalBudget = budget
}

func appServerGatewayHistoryGlobalBudgetWindow() time.Duration {
	if appServerGatewayHistoryGlobalWindow > 0 {
		return appServerGatewayHistoryGlobalWindow
	}
	return appServerGatewayHistoryBudgetWindow
}

func copyGatewayStringParams(params map[string]any, keys ...string) map[string]any {
	copied := map[string]any{}
	for _, key := range keys {
		if value, ok := params[key].(string); ok {
			copied[key] = value
		}
	}
	return copied
}

func copyGatewayBoolParams(params map[string]any, keys ...string) map[string]any {
	copied := map[string]any{}
	for _, key := range keys {
		if value, ok := params[key].(bool); ok {
			copied[key] = value
		}
	}
	return copied
}
