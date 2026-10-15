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
//
// 会话列表同理：冷启动时全局索引与项目列表按 50 条一页顺序翻页，十余页在 15 秒内
// 是常态，第 7 页起被拒会让 iPad 弹出限流提示并拖慢首屏。全局发现返回给 iPad 的是
// gateway 换发的 cursor，但请求在预算检查前已换回上游 cursor，所以这里统一按上游
// cursor 记账，两条路径都能命中。
const appServerGatewayHistoryContinuationMax = 512

func gatewayHistoryRequestTracksContinuation(request appServerGatewayPendingHistoryRequest) bool {
	switch request.method {
	case "thread/turns/list", "thread/items/list", "thread/list":
		return true
	default:
		return false
	}
}

func gatewayHistoryContinuationKey(request appServerGatewayPendingHistoryRequest, cursor string) string {
	encoded, _ := json.Marshal([]string{
		gatewayHistoryBudgetSubject(request), request.method, request.itemsView, request.continuationQuery, cursor,
	})
	return string(encoded)
}

// gatewayThreadListContinuationQuery 把决定列表内容的参数（排序、归档、来源、搜索词等）
// 归一成续页键的一部分：换了查询条件再带旧 cursor 只能按普通请求计数。
// 排除的字段不改变查询本身：cursor 单独入键，cwd 已是预算 subject；limit 允许续页调整页长；
// useStateDbOnly / refreshHistory 只选数据来源与是否重扫——Claude 首页走索引并要求重扫，
// 续页改为扫描且不再重扫，同一条页链里本来就会变化。
func gatewayThreadListContinuationQuery(params map[string]any) string {
	query := make(map[string]any, len(params))
	for key, value := range params {
		switch key {
		case "cursor", "cwd", "limit", "useStateDbOnly", "refreshHistory":
			continue
		}
		query[key] = value
	}
	encoded, _ := json.Marshal(query)
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
// 只放行不带 cursor 的首页：向上翻页若也放行，连续翻页会不断刷新阻断窗口，
// 让全局预算失去上限并长期饿死 full/items 请求。
func gatewayHistoryRequestBypassesGlobalBlock(request appServerGatewayPendingHistoryRequest) bool {
	return request.method == "thread/turns/list" && request.itemsView == "summary" && request.cursor == ""
}
