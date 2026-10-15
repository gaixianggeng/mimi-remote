package httpapi

import (
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
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

// 冷启动时全局索引与项目列表顺序翻十余页：沿上游签发的 cursor 续页不能在第 7 页被拒，
// 否则 iPad 会弹限流提示并拖慢首屏。全局发现走 gateway 换发的 cursor，项目列表直接透传。
func TestThreadListContinuationPagesSkipRequestCountLimit(t *testing.T) {
	for _, tc := range []struct {
		name   string
		global bool
	}{{"global discovery", true}, {"project list", false}} {
		t.Run(tc.name, func(t *testing.T) {
			policy, projectDir := newThreadListContinuationTestPolicy(t)
			clientCursor := ""
			for page := 0; page < appServerGatewayHistoryBudgetMaxRequests*3; page++ {
				// Claude 首页走索引（快速首屏）或要求重扫（权威首屏），续页改为普通扫描：
				// 数据来源变化不影响续页身份。
				params := map[string]any{"limit": 50, "sortKey": "updated_at", "sortDirection": "desc", "useStateDbOnly": false}
				if !tc.global {
					params["cwd"] = projectDir
				}
				switch {
				case clientCursor != "":
					params["cursor"] = clientCursor
				case tc.global:
					params["useStateDbOnly"] = true
				default:
					params["refreshHistory"] = true
				}
				request, _ := json.Marshal(map[string]any{"id": page + 1, "method": "thread/list", "params": params})
				if _, err := policy.validateClientFrame(websocket.TextMessage, request); err != nil {
					t.Fatalf("沿签发的 cursor 翻页不应撞上次数上限：page=%d err=%+v", page, err)
				}
				upstreamCursor := fmt.Sprintf("upstream-%d", page+1)
				response := []byte(fmt.Sprintf(`{"jsonrpc":"2.0","id":%d,"result":{"data":[],"nextCursor":%q}}`, page+1, upstreamCursor))
				forwarded, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, response)
				if !forward || policyErr != nil {
					t.Fatalf("列表页应正常透传：forward=%v err=%+v", forward, policyErr)
				}
				var decoded struct {
					Result struct {
						NextCursor string `json:"nextCursor"`
					} `json:"result"`
				}
				if err := json.Unmarshal(forwarded, &decoded); err != nil {
					t.Fatal(err)
				}
				clientCursor = decoded.Result.NextCursor
				if tc.global == (clientCursor == upstreamCursor) {
					t.Fatalf("全局发现必须换发 cursor、项目列表直接透传：global=%v cursor=%q", tc.global, clientCursor)
				}
			}
		})
	}
}

// 续页只属于签发它的查询：换了排序或筛选再带旧 cursor，是另一条查询的翻页，照常计数。
func TestThreadListContinuationIsBoundToOriginatingQuery(t *testing.T) {
	policy, projectDir := newThreadListContinuationTestPolicy(t)
	issued := ""
	for attempt := 0; attempt <= appServerGatewayHistoryBudgetMaxRequests; attempt++ {
		// 每页都换排序：每个 cursor 都被拿去翻另一条查询，因此每次都要计数。
		params := map[string]any{"cwd": projectDir, "limit": 50, "sortKey": "updated_at"}
		if attempt%2 == 1 {
			params["sortKey"] = "recency_at"
		}
		if issued != "" {
			params["cursor"] = issued
		}
		request, _ := json.Marshal(map[string]any{"id": attempt + 1, "method": "thread/list", "params": params})
		_, err := policy.validateClientFrame(websocket.TextMessage, request)
		if attempt == appServerGatewayHistoryBudgetMaxRequests {
			if err == nil || err.data["reason"] != "history_budget_limited" {
				t.Fatalf("换了查询条件的 cursor 不能免计数：%+v", err)
			}
			return
		}
		if err != nil {
			t.Fatalf("attempt=%d err=%+v", attempt, err)
		}
		issued = fmt.Sprintf("upstream-%d", attempt+1)
		respondHistoryPage(t, policy, attempt+1, issued)
	}
}

func TestThreadListInventedCursorsStillCountTowardLimit(t *testing.T) {
	policy, projectDir := newThreadListContinuationTestPolicy(t)
	for attempt := 0; attempt <= appServerGatewayHistoryBudgetMaxRequests; attempt++ {
		request, _ := json.Marshal(map[string]any{"id": attempt + 1, "method": "thread/list", "params": map[string]any{
			"cwd": projectDir, "limit": 50, "cursor": fmt.Sprintf("invented-%d", attempt),
		}})
		_, err := policy.validateClientFrame(websocket.TextMessage, request)
		if attempt == appServerGatewayHistoryBudgetMaxRequests {
			if err == nil || err.data["reason"] != "history_budget_limited" {
				t.Fatalf("未经签发的 cursor 仍应受次数限制：%+v", err)
			}
			return
		}
		if err != nil {
			t.Fatalf("attempt=%d err=%+v", attempt, err)
		}
		id := json.RawMessage(fmt.Sprint(attempt + 1))
		policy.consumePendingHistoryRequest(&id)
	}
}

func newThreadListContinuationTestPolicy(t *testing.T) (*appServerGatewayPolicy, string) {
	t.Helper()
	projectDir := t.TempDir()
	registry, err := projects.NewRegistry([]config.ProjectConfig{{ID: "project", Name: "Project", Path: projectDir}})
	if err != nil {
		t.Fatal(err)
	}
	router := &Router{
		monitor: newRelayMonitor(), projects: registry,
		gatewayThreads: map[string]appServerGatewayAllowedThread{},
	}
	return newAppServerGatewayPolicy(router, "claude"), projectDir
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

	pageID := json.RawMessage(`5`)
	pageParams := map[string]any{"threadId": "thread-next", "itemsView": "summary", "cursor": "older", "limit": json.Number("10")}
	if err := firstPage.reserveHistoryRequest(&pageID, "thread/turns/list", pageParams, 160); err == nil || err.data["scope"] != "global" {
		t.Fatalf("带 cursor 的 summary 翻页不是首页，仍应受全局下行预算限制：%+v", err)
	}

	fullID := json.RawMessage(`4`)
	fullParams := map[string]any{"threadId": "thread-next", "itemsView": "full", "limit": json.Number("10")}
	if err := firstPage.reserveHistoryRequest(&fullID, "thread/turns/list", fullParams, 160); err == nil || err.data["scope"] != "global" {
		t.Fatalf("full 历史仍应受全局下行预算限制：%+v", err)
	}
}
