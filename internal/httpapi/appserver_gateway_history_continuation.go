package httpapi

import (
	"encoding/json"
	"strings"
	"time"
)

// 上游自己签发的 nextCursor 只代表“沿同一条页链继续向前”，不是重试风暴。
// Claude 长任务的单个回合常有数百条 item，按 50 条一页补齐时第 7 页必然撞上
// 同一 thread/turn 的六次请求上限，整段补齐停顿 15 秒；向上翻更早回合同理。
// 因此记下每个历史响应返回的 nextCursor，恰好带着它的下一次请求按续页处理：
// 不消耗次数预算，但仍受阻断窗口、请求字节、响应字节和全局下行预算约束。
// cursor 一次性有效：重放同一 cursor 的重试照常计数，伪造的 cursor 不在表中也照常计数。
// 续页记录与 pending 历史请求同寿命，过期后按普通请求计数。
const appServerGatewayHistoryContinuationMax = 512

func gatewayHistoryRequestTracksContinuation(request appServerGatewayPendingHistoryRequest) bool {
	return request.method == "thread/turns/list" || request.method == "thread/items/list"
}

func gatewayHistoryContinuationKey(request appServerGatewayPendingHistoryRequest, cursor string) string {
	encoded, _ := json.Marshal([]string{gatewayHistoryBudgetSubject(request), request.method, request.itemsView, cursor})
	return string(encoded)
}

// historyContinuationLocked 只判断不消费：请求随后仍可能被阻断窗口拒绝，
// 此时 cursor 必须留给下一次重试。调用方在预算全部通过后再删除。
func (p *appServerGatewayPolicy) historyContinuationLocked(
	request appServerGatewayPendingHistoryRequest,
	now time.Time,
) (string, bool) {
	if request.cursor == "" || len(p.historyContinuations) == 0 || !gatewayHistoryRequestTracksContinuation(request) {
		return "", false
	}
	key := gatewayHistoryContinuationKey(request, request.cursor)
	expiresAt, ok := p.historyContinuations[key]
	return key, ok && expiresAt.After(now)
}

func (p *appServerGatewayPolicy) rememberHistoryContinuation(request appServerGatewayPendingHistoryRequest, result json.RawMessage) {
	if !gatewayHistoryRequestTracksContinuation(request) || len(result) == 0 {
		return
	}
	var page struct {
		NextCursor *string `json:"nextCursor"`
	}
	if json.Unmarshal(result, &page) != nil || page.NextCursor == nil {
		return
	}
	cursor := strings.TrimSpace(*page.NextCursor)
	if cursor == "" || cursor == request.cursor {
		return
	}
	now := time.Now()
	p.mu.Lock()
	defer p.mu.Unlock()
	p.pruneHistoryContinuationsLocked(now)
	if p.historyContinuations == nil {
		p.historyContinuations = map[string]time.Time{}
	}
	if len(p.historyContinuations) >= appServerGatewayHistoryContinuationMax {
		// 表满时宁可让后续页照常计数，也不让续页记录无界增长。
		return
	}
	p.historyContinuations[gatewayHistoryContinuationKey(request, cursor)] = now.Add(appServerGatewayPendingHistoryRequestTTL)
}

func (p *appServerGatewayPolicy) pruneHistoryContinuationsLocked(now time.Time) {
	for key, expiresAt := range p.historyContinuations {
		if !expiresAt.After(now) {
			delete(p.historyContinuations, key)
		}
	}
}

// summary 首页只含用户与 Agent 文本，是打开会话的第一屏。全局下行预算主要被后台
// 按回合补齐的 items 用完；若连 summary 一起阻断，首屏会被上一个会话或本会话的
// 补齐拖住，iPad 只能干等 15 秒。summary 响应仍计入全局字节，继续限制后台补齐。
func gatewayHistoryRequestBypassesGlobalBlock(request appServerGatewayPendingHistoryRequest) bool {
	return request.method == "thread/turns/list" && request.itemsView == "summary"
}
