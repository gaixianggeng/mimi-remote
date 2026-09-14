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
