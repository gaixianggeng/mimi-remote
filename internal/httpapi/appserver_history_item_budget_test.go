package httpapi

import (
	"encoding/json"
	"fmt"
	"testing"
)

func TestHistoryItemBudgetAllowsFirstPageAcrossTenTurns(t *testing.T) {
	for _, runtimeID := range []string{"claude", "codex"} {
		t.Run(runtimeID, func(t *testing.T) {
			policy := &appServerGatewayPolicy{router: &Router{monitor: newRelayMonitor()}, runtimeID: runtimeID}
			for turn := 0; turn < 10; turn++ {
				id := json.RawMessage(fmt.Sprint(turn + 1))
				params := map[string]any{"threadId": "thread-small", "turnId": fmt.Sprintf("turn-%d", turn), "limit": json.Number("50")}
				if err := policy.reserveHistoryRequest(&id, "thread/items/list", params, 160); err != nil {
					t.Fatalf("十个回合各补齐一页不应消耗彼此的次数预算，turn=%d err=%+v", turn, err)
				}
				pending, ok := policy.consumePendingHistoryRequest(&id)
				if !ok {
					t.Fatal("历史请求必须跟踪响应预算")
				}
				policy.recordHistoryResponseBudget(pending, 1024)
			}
		})
	}
}

func TestHistoryItemBudgetStillLimitsRepeatedTurnPages(t *testing.T) {
	policy := &appServerGatewayPolicy{router: &Router{monitor: newRelayMonitor()}, runtimeID: "claude"}
	for page := 0; page <= appServerGatewayHistoryBudgetMaxRequests; page++ {
		id := json.RawMessage(fmt.Sprint(page + 1))
		params := map[string]any{"threadId": "thread-small", "turnId": "turn-a", "cursor": fmt.Sprintf("page-%d", page)}
		err := policy.reserveHistoryRequest(&id, "thread/items/list", params, 160)
		if page == appServerGatewayHistoryBudgetMaxRequests {
			if err == nil || err.data["reason"] != "history_budget_limited" {
				t.Fatalf("同一回合换 cursor 仍应受次数限制：%+v", err)
			}
			if err.data["retryAfterSeconds"] == nil {
				t.Fatal("必须返回恢复窗口")
			}
		} else {
			if err != nil {
				t.Fatal(err)
			}
			policy.consumePendingHistoryRequest(&id)
		}
	}
}

func TestHistoryItemAggregateBudgetLimitsRotatingTurns(t *testing.T) {
	oldMaxRequests := appServerGatewayHistoryItemsAggregateMaxRequests
	oldMaxRequestBytes := appServerGatewayHistoryItemsAggregateMaxRequestBytes
	appServerGatewayHistoryItemsAggregateMaxRequests = 3
	appServerGatewayHistoryItemsAggregateMaxRequestBytes = 64 << 10
	t.Cleanup(func() {
		appServerGatewayHistoryItemsAggregateMaxRequests = oldMaxRequests
		appServerGatewayHistoryItemsAggregateMaxRequestBytes = oldMaxRequestBytes
	})

	policy := &appServerGatewayPolicy{router: &Router{monitor: newRelayMonitor()}, runtimeID: "claude"}
	for turn := 0; turn <= appServerGatewayHistoryItemsAggregateMaxRequests; turn++ {
		id := json.RawMessage(fmt.Sprint(turn + 1))
		params := map[string]any{"threadId": "thread-rotating", "turnId": fmt.Sprintf("turn-%d", turn)}
		err := policy.reserveHistoryRequest(&id, "thread/items/list", params, 160)
		if turn < appServerGatewayHistoryItemsAggregateMaxRequests {
			if err != nil {
				t.Fatal(err)
			}
			// 未返回的上游请求也必须消耗 aggregate 预算，避免填满 pendingHistory。
			continue
		}
		if err == nil || err.data["reason"] != "history_budget_limited" {
			t.Fatalf("轮换 turnId 仍应受 thread aggregate 次数限制：%+v", err)
		}
		if err.data["budget"] != "items_aggregate" || err.data["scope"] != "thread" {
			t.Fatalf("错误应标记 items aggregate 范围：%+v", err.data)
		}
	}
}

func TestHistoryItemAggregateBudgetLimitsRequestBytesAcrossTurns(t *testing.T) {
	oldMaxRequests := appServerGatewayHistoryItemsAggregateMaxRequests
	oldMaxRequestBytes := appServerGatewayHistoryItemsAggregateMaxRequestBytes
	appServerGatewayHistoryItemsAggregateMaxRequests = 100
	appServerGatewayHistoryItemsAggregateMaxRequestBytes = 300
	t.Cleanup(func() {
		appServerGatewayHistoryItemsAggregateMaxRequests = oldMaxRequests
		appServerGatewayHistoryItemsAggregateMaxRequestBytes = oldMaxRequestBytes
	})

	policy := &appServerGatewayPolicy{router: &Router{monitor: newRelayMonitor()}, runtimeID: "claude"}
	firstID := json.RawMessage(`1`)
	if err := policy.reserveHistoryRequest(&firstID, "thread/items/list", map[string]any{
		"threadId": "thread-bytes", "turnId": "turn-a",
	}, 160); err != nil {
		t.Fatal(err)
	}
	secondID := json.RawMessage(`2`)
	err := policy.reserveHistoryRequest(&secondID, "thread/items/list", map[string]any{
		"threadId": "thread-bytes", "turnId": "turn-b",
	}, 160)
	if err == nil || err.data["budget"] != "items_aggregate" {
		t.Fatalf("不同 turnId 仍应共用 thread aggregate 请求字节预算：%+v", err)
	}
}

func TestHistoryItemBudgetKeepsGlobalBytesAcrossTurns(t *testing.T) {
	oldMax := appServerGatewayHistoryGlobalMaxResponseBytes
	appServerGatewayHistoryGlobalMaxResponseBytes = 1500
	t.Cleanup(func() { appServerGatewayHistoryGlobalMaxResponseBytes = oldMax })
	policy := &appServerGatewayPolicy{router: &Router{}, runtimeID: "claude"}
	for turn := 0; turn < 3; turn++ {
		id := json.RawMessage(fmt.Sprint(turn + 1))
		params := map[string]any{"threadId": "thread-small", "turnId": fmt.Sprintf("turn-%d", turn)}
		err := policy.reserveHistoryRequest(&id, "thread/items/list", params, 160)
		if turn == 2 {
			if err == nil || err.data["scope"] != "global" {
				t.Fatalf("跨回合仍须共用下行字节预算：%+v", err)
			}
		} else {
			if err != nil {
				t.Fatal(err)
			}
			pending, _ := policy.consumePendingHistoryRequest(&id)
			policy.recordHistoryResponseBudget(pending, 1024)
		}
	}
}
