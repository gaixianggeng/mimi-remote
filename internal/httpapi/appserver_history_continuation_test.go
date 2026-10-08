package httpapi

import (
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func newHistoryContinuationTestPolicy() *appServerGatewayPolicy {
	return newAppServerGatewayPolicy(&Router{monitor: newRelayMonitor()}, "claude")
}

// respondHistoryPage 模拟上游返回一页历史，并把响应交给 gateway 观察。
func respondHistoryPage(t *testing.T, policy *appServerGatewayPolicy, id int, nextCursor string) {
	t.Helper()
	cursor := "null"
	if nextCursor != "" {
		cursor = fmt.Sprintf("%q", nextCursor)
	}
	response := []byte(fmt.Sprintf(`{"id":%d,"result":{"data":[],"nextCursor":%s}}`, id, cursor))
	if _, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, response); !forward || policyErr != nil {
		t.Fatalf("小历史页应正常透传：forward=%v err=%+v", forward, policyErr)
	}
}

func TestHistoryContinuationPagesSkipRequestCountLimit(t *testing.T) {
	cases := []struct {
		method string
		params map[string]any
	}{
		// Claude 长回合：一个 turn 数百条 item，按 50 条一页补齐。
		{"thread/items/list", map[string]any{"threadId": "thread-long", "turnId": "turn-a", "limit": json.Number("50")}},
		// 连续向上翻更早回合。
		{"thread/turns/list", map[string]any{"threadId": "thread-long", "itemsView": "summary", "limit": json.Number("10")}},
	}
	for _, tc := range cases {
		t.Run(tc.method, func(t *testing.T) {
			policy := newHistoryContinuationTestPolicy()
			pages := appServerGatewayHistoryBudgetMaxRequests * 3
			cursor := ""
			for page := 0; page < pages; page++ {
				id := json.RawMessage(fmt.Sprint(page + 1))
				params := map[string]any{}
				for key, value := range tc.params {
					params[key] = value
				}
				if cursor != "" {
					params["cursor"] = cursor
				}
				if err := policy.reserveHistoryRequest(&id, tc.method, params, 160); err != nil {
					t.Fatalf("沿上游签发的 cursor 续页不应撞上次数上限：page=%d err=%+v", page, err)
				}
				cursor = fmt.Sprintf("issued-%d", page+1)
				respondHistoryPage(t, policy, page+1, cursor)
			}
		})
	}
}

func TestHistoryContinuationCursorIsSingleUse(t *testing.T) {
	policy := newHistoryContinuationTestPolicy()
	params := func(cursor string) map[string]any {
		values := map[string]any{"threadId": "thread-retry", "turnId": "turn-a"}
		if cursor != "" {
			values["cursor"] = cursor
		}
		return values
	}
	firstID := json.RawMessage(`1`)
	if err := policy.reserveHistoryRequest(&firstID, "thread/items/list", params(""), 160); err != nil {
		t.Fatal(err)
	}
	respondHistoryPage(t, policy, 1, "issued")

	// 第一次带 issued 是续页（不计数）；之后重放同一 cursor 是重试，和首页一起计入六次。
	for attempt := 0; attempt <= appServerGatewayHistoryBudgetMaxRequests; attempt++ {
		id := json.RawMessage(fmt.Sprint(attempt + 2))
		err := policy.reserveHistoryRequest(&id, "thread/items/list", params("issued"), 160)
		if attempt == appServerGatewayHistoryBudgetMaxRequests {
			if err == nil || err.data["reason"] != "history_budget_limited" {
				t.Fatalf("重放同一 cursor 的重试仍应受次数限制：%+v", err)
			}
			return
		}
		if err != nil {
			t.Fatalf("attempt=%d err=%+v", attempt, err)
		}
		policy.consumePendingHistoryRequest(&id)
	}
}

func TestHistoryContinuationDoesNotCrossTurns(t *testing.T) {
	policy := newHistoryContinuationTestPolicy()
	firstID := json.RawMessage(`1`)
	if err := policy.reserveHistoryRequest(&firstID, "thread/items/list", map[string]any{"threadId": "thread-x", "turnId": "turn-a"}, 160); err != nil {
		t.Fatal(err)
	}
	respondHistoryPage(t, policy, 1, "issued-a")
	key, ok := policy.historyContinuationLocked(appServerGatewayPendingHistoryRequest{
		method: "thread/items/list", threadID: "thread-x", itemsView: "items", filterFingerprint: "turn-b", cursor: "issued-a",
	}, time.Now())
	if ok {
		t.Fatalf("turn-a 签发的 cursor 不能给 turn-b 免计数：%s", key)
	}
}

func TestHistorySummaryFirstPageBypassesExhaustedGlobalBudget(t *testing.T) {
	oldMax := appServerGatewayHistoryGlobalMaxResponseBytes
	appServerGatewayHistoryGlobalMaxResponseBytes = 1500
	t.Cleanup(func() { appServerGatewayHistoryGlobalMaxResponseBytes = oldMax })

	router := &Router{monitor: newRelayMonitor()}
	enrichment := newAppServerGatewayPolicy(router, "claude")
	firstPage := newAppServerGatewayPolicy(router, "claude")

	// 上一个会话的后台补齐用完全局下行预算。
	itemsID := json.RawMessage(`1`)
	if err := enrichment.reserveHistoryRequest(&itemsID, "thread/items/list", map[string]any{"threadId": "thread-heavy", "turnId": "turn-a"}, 160); err != nil {
		t.Fatal(err)
	}
	pending, _ := enrichment.consumePendingHistoryRequest(&itemsID)
	enrichment.recordHistoryResponseBudget(pending, 2048)

	moreItemsID := json.RawMessage(`2`)
	if err := enrichment.reserveHistoryRequest(&moreItemsID, "thread/items/list", map[string]any{"threadId": "thread-heavy", "turnId": "turn-b"}, 160); err == nil || err.data["scope"] != "global" {
		t.Fatalf("后台补齐仍应受全局下行预算限制：%+v", err)
	}

	summaryID := json.RawMessage(`3`)
	summaryParams := map[string]any{"threadId": "thread-next", "itemsView": "summary", "limit": json.Number("10"), "sortDirection": "desc"}
	if err := firstPage.reserveHistoryRequest(&summaryID, "thread/turns/list", summaryParams, 160); err != nil {
		t.Fatalf("summary 首页不应被后台补齐耗尽的全局预算阻断：%+v", err)
	}
	summaryPending, _ := firstPage.consumePendingHistoryRequest(&summaryID)
	before := router.gatewayHistoryGlobalBudget.responseBytes
	firstPage.recordHistoryResponseBudget(summaryPending, 512)
	if got := router.gatewayHistoryGlobalBudget.responseBytes; got != before+512 {
		t.Fatalf("summary 响应仍须计入全局字节：before=%d got=%d", before, got)
	}

	fullID := json.RawMessage(`4`)
	fullParams := map[string]any{"threadId": "thread-next", "itemsView": "full", "limit": json.Number("10")}
	if err := firstPage.reserveHistoryRequest(&fullID, "thread/turns/list", fullParams, 160); err == nil || err.data["scope"] != "global" {
		t.Fatalf("full 历史仍应受全局下行预算限制：%+v", err)
	}
}
