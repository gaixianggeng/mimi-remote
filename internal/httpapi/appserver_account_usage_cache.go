package httpapi

import (
	"bytes"
	"encoding/json"
	"time"
)

const defaultAccountTokenUsageCacheTTL = 12 * time.Hour

const accountTokenUsageForceRefreshParam = "mimiForceRefresh"

// cachedAccountTokenUsageResult 只返回 TTL 内的成功快照。缓存属于当前 Mac 的
// agentd 进程，同一服务端的所有客户端连接共享；它不落盘、不跨 Mac 共享，
// 也不会影响实时额度事件。
func (r *Router) cachedAccountTokenUsageResult(now time.Time) (json.RawMessage, bool) {
	if r == nil {
		return nil, false
	}
	r.accountTokenUsageMu.RLock()
	defer r.accountTokenUsageMu.RUnlock()
	if r.accountTokenUsageCacheTTL <= 0 ||
		r.accountTokenUsageCachedAt.IsZero() ||
		now.Sub(r.accountTokenUsageCachedAt) >= r.accountTokenUsageCacheTTL ||
		len(r.accountTokenUsageResult) == 0 {
		return nil, false
	}
	return append(json.RawMessage(nil), r.accountTokenUsageResult...), true
}

func (r *Router) storeAccountTokenUsageResult(result json.RawMessage, now time.Time) {
	if r == nil || len(result) == 0 || !json.Valid(result) || bytes.Equal(bytes.TrimSpace(result), []byte("null")) {
		return
	}
	r.accountTokenUsageMu.Lock()
	r.accountTokenUsageResult = append(r.accountTokenUsageResult[:0], result...)
	r.accountTokenUsageCachedAt = now
	r.accountTokenUsageMu.Unlock()
}

// cachedAccountTokenUsageResponse 用当前请求 id 重建 JSON-RPC 响应。只复用 result，
// 不缓存上游 request id，避免不同连接之间串响应。
func (p *appServerGatewayPolicy) cachedAccountTokenUsageResponse(requestPayload []byte, now time.Time) ([]byte, bool) {
	if p == nil || normalizeAppServerRuntimeID(p.runtimeID) != "codex" {
		return nil, false
	}
	var frame appServerGatewayFrame
	if err := json.Unmarshal(requestPayload, &frame); err != nil ||
		frame.ID == nil ||
		frame.Method != "account/usage/read" {
		return nil, false
	}
	params, err := decodeGatewayParams(frame.Params)
	if err != nil {
		return nil, false
	}
	// 设置页的显式刷新必须读取最新数据；该标记只供 agentd 判断，转发前会被安全参数重写剥离。
	if forceRefresh, ok := gatewayBoolParam(params, accountTokenUsageForceRefreshParam); ok && forceRefresh {
		return nil, false
	}
	result, ok := p.router.cachedAccountTokenUsageResult(now)
	if !ok {
		return nil, false
	}

	// validateClientFrame 已登记 pending；缓存命中不再等上游响应，立即释放这一项。
	p.consumePendingClientRequest(frame.ID)
	response := map[string]json.RawMessage{
		"id":     append(json.RawMessage(nil), (*frame.ID)...),
		"result": result,
	}
	var envelope map[string]json.RawMessage
	if json.Unmarshal(requestPayload, &envelope) == nil {
		if version := envelope["jsonrpc"]; len(version) > 0 {
			response["jsonrpc"] = version
		}
	}
	payload, err := json.Marshal(response)
	if err != nil {
		return nil, false
	}
	return payload, true
}

// rememberAccountTokenUsageResponse 的 requestMethod 来自在途请求表：调用方已经按
// 响应 id 认领过对应请求。
func (p *appServerGatewayPolicy) rememberAccountTokenUsageResponse(frame *appServerGatewayFrame, requestMethod string, now time.Time) {
	if p == nil ||
		normalizeAppServerRuntimeID(p.runtimeID) != "codex" ||
		frame == nil ||
		!gatewayFrameIsResponse(frame) {
		return
	}
	if requestMethod != "account/usage/read" || len(frame.Error) > 0 || len(frame.Result) == 0 {
		return
	}
	p.router.storeAccountTokenUsageResult(frame.Result, now)
}
