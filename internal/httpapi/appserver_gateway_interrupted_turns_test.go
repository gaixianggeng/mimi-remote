package httpapi

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/codexhistory"
)

type interruptedTurnTestSource struct {
	turns map[string]map[string]time.Time
}

func (s *interruptedTurnTestSource) Snapshot() ([]codexhistory.ExternalActivity, error) {
	return []codexhistory.ExternalActivity{}, nil
}

func (s *interruptedTurnTestSource) SetCodexRuntimeIdentity(string, time.Time) {}

func (s *interruptedTurnTestSource) GatewayInterruptedTurns(threadID string) map[string]time.Time {
	result := map[string]time.Time{}
	for turnID, interruptedAt := range s.turns[threadID] {
		result[turnID] = interruptedAt
	}
	return result
}

func TestRewriteInterruptedGatewayTurnsListIsExact(t *testing.T) {
	interruptedAt := time.Date(2026, 8, 11, 10, 0, 0, 0, time.UTC)
	router := &Router{externalActivity: &interruptedTurnTestSource{turns: map[string]map[string]time.Time{
		"thread-1": {"turn-old": interruptedAt},
	}}}
	payload := []byte(`{"id":1,"result":{"data":[{"id":"turn-old","status":"inProgress","completedAt":null,"items":[]},{"id":"turn-new","status":"inProgress","items":[]}],"nextCursor":null}}`)

	rewritten, changed := router.rewriteInterruptedGatewayHistoryResponse(payload, appServerGatewayPendingHistoryRequest{
		method: "thread/turns/list", threadID: "thread-1",
	})
	if !changed {
		t.Fatal("精确命中的旧 Turn 应被改写")
	}
	var response struct {
		Result struct {
			Data []struct {
				ID          string `json:"id"`
				Status      string `json:"status"`
				CompletedAt *int64 `json:"completedAt"`
			} `json:"data"`
		} `json:"result"`
	}
	if err := json.Unmarshal(rewritten, &response); err != nil {
		t.Fatal(err)
	}
	if response.Result.Data[0].Status != "interrupted" ||
		response.Result.Data[0].CompletedAt == nil ||
		*response.Result.Data[0].CompletedAt != interruptedAt.Unix() {
		t.Fatalf("旧 Turn 中断投影异常：%s", rewritten)
	}
	if response.Result.Data[1].Status != "inProgress" || response.Result.Data[1].CompletedAt != nil {
		t.Fatalf("后续真实新 Turn 不得被旧账本误改：%s", rewritten)
	}
}

func TestRewriteInterruptedGatewayThreadReadReturnsIdleOnlyWithoutNewActiveTurn(t *testing.T) {
	interruptedAt := time.Date(2026, 8, 11, 10, 0, 0, 0, time.UTC)
	router := &Router{externalActivity: &interruptedTurnTestSource{turns: map[string]map[string]time.Time{
		"thread-1": {"turn-old": interruptedAt},
	}}}
	tests := []struct {
		name       string
		turns      string
		wantStatus string
	}{
		{name: "only interrupted turn", turns: `[{"id":"turn-old","status":"inProgress"}]`, wantStatus: "idle"},
		{name: "new active turn survives", turns: `[{"id":"turn-old","status":"inProgress"},{"id":"turn-new","status":"running"}]`, wantStatus: "active"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			payload := []byte(`{"id":2,"result":{"thread":{"id":"thread-1","status":{"type":"active"},"turns":` + tc.turns + `}}}`)
			rewritten, changed := router.rewriteInterruptedGatewayHistoryResponse(payload, appServerGatewayPendingHistoryRequest{
				method: "thread/read", threadID: "thread-1", includeTurns: true,
			})
			if !changed {
				t.Fatal("thread/read 应投影精确中断 Turn")
			}
			var response struct {
				Result struct {
					Thread struct {
						Status struct {
							Type string `json:"type"`
						} `json:"status"`
						Turns []struct {
							ID     string `json:"id"`
							Status string `json:"status"`
						} `json:"turns"`
					} `json:"thread"`
				} `json:"result"`
			}
			if err := json.Unmarshal(rewritten, &response); err != nil {
				t.Fatal(err)
			}
			if response.Result.Thread.Status.Type != tc.wantStatus {
				t.Fatalf("thread status 不符合预期：want=%s payload=%s", tc.wantStatus, rewritten)
			}
			if response.Result.Thread.Turns[0].Status != "interrupted" {
				t.Fatalf("旧 Turn 应为 interrupted：%s", rewritten)
			}
		})
	}
}

func TestRewriteInterruptedGatewayHistoryPreservesUpstreamTerminal(t *testing.T) {
	router := &Router{externalActivity: &interruptedTurnTestSource{turns: map[string]map[string]time.Time{
		"thread-1": {"turn-old": time.Now().UTC()},
	}}}
	payload := []byte(`{"id":3,"result":{"data":[{"id":"turn-old","status":"completed","completedAt":1786423200}]}}`)
	rewritten, changed := router.rewriteInterruptedGatewayHistoryResponse(payload, appServerGatewayPendingHistoryRequest{
		method: "thread/turns/list", threadID: "thread-1",
	})
	if changed || string(rewritten) != string(payload) {
		t.Fatalf("上游已有真实终态时不得覆盖：%s", rewritten)
	}
}

func TestGatewayPolicyRewritesInterruptedTurnHistoryResponse(t *testing.T) {
	interruptedAt := time.Date(2026, 8, 11, 10, 0, 0, 0, time.UTC)
	router := &Router{externalActivity: &interruptedTurnTestSource{turns: map[string]map[string]time.Time{
		"thread-policy": {"turn-policy": interruptedAt},
	}}}
	policy := &appServerGatewayPolicy{
		router:         router,
		runtimeID:      "codex",
		pendingHistory: map[string]appServerGatewayPendingHistoryRequest{},
		historyBudgets: map[string]appServerGatewayHistoryBudget{},
	}
	id := json.RawMessage(`91`)
	if policyErr := policy.reserveHistoryRequest(&id, "thread/turns/list", map[string]any{
		"threadId":  "thread-policy",
		"limit":     json.Number("20"),
		"itemsView": "summary",
	}, 128); policyErr != nil {
		t.Fatalf("登记 history 请求失败：%+v", policyErr)
	}
	payload := []byte(`{"id":91,"result":{"data":[{"id":"turn-policy","status":"inProgress","items":[]}]}}`)
	forwarded, forward, policyErr := policy.observeUpstreamFrame(1, payload)
	if policyErr != nil || !forward {
		t.Fatalf("history 响应应成功透传：forward=%t err=%+v", forward, policyErr)
	}
	if string(forwarded) == string(payload) {
		t.Fatalf("gateway 策略应调用精确中断投影：%s", forwarded)
	}
	var response struct {
		Result struct {
			Data []struct {
				Status string `json:"status"`
			} `json:"data"`
		} `json:"result"`
	}
	if err := json.Unmarshal(forwarded, &response); err != nil {
		t.Fatal(err)
	}
	if len(response.Result.Data) != 1 || response.Result.Data[0].Status != "interrupted" {
		t.Fatalf("gateway 输出未收敛为 interrupted：%s", forwarded)
	}
}

func TestRewriteInterruptedGatewayThreadListOnlyChangesRowsWithTurns(t *testing.T) {
	interruptedAt := time.Date(2026, 8, 11, 10, 0, 0, 0, time.UTC)
	router := &Router{externalActivity: &interruptedTurnTestSource{turns: map[string]map[string]time.Time{
		"thread-with-turns": {"turn-old": interruptedAt},
		"thread-metadata":   {"turn-metadata": interruptedAt},
	}}}
	payload := []byte(`{"id":4,"result":{"data":[{"id":"thread-with-turns","status":{"type":"active"},"turns":[{"id":"turn-old","status":"inProgress"}]},{"id":"thread-metadata","status":{"type":"active"}}]}}`)

	rewritten, changed := router.rewriteInterruptedGatewayHistoryResponse(payload, appServerGatewayPendingHistoryRequest{
		method: "thread/list",
	})
	if !changed {
		t.Fatal("带 turns 的列表行应立即收敛")
	}
	var response struct {
		Result struct {
			Data []struct {
				Status struct {
					Type string `json:"type"`
				} `json:"status"`
			} `json:"data"`
		} `json:"result"`
	}
	if err := json.Unmarshal(rewritten, &response); err != nil {
		t.Fatal(err)
	}
	if response.Result.Data[0].Status.Type != "idle" {
		t.Fatalf("带精确 turns 的旧列表行应 idle：%s", rewritten)
	}
	if response.Result.Data[1].Status.Type != "active" {
		t.Fatalf("无 turns 的 metadata 行不能猜测状态：%s", rewritten)
	}
}

func TestRewriteInterruptedGatewayResumeWithoutTurnsDoesNotGuess(t *testing.T) {
	router := &Router{externalActivity: &interruptedTurnTestSource{turns: map[string]map[string]time.Time{
		"thread-resume": {"turn-old": time.Now().UTC()},
	}}}
	payload := []byte(`{"id":5,"result":{"thread":{"id":"thread-resume","status":{"type":"active"}}}}`)
	rewritten, changed := router.rewriteInterruptedGatewayHistoryResponse(payload, appServerGatewayPendingHistoryRequest{
		method: "thread/resume", threadID: "thread-resume",
	})
	if changed || string(rewritten) != string(payload) {
		t.Fatalf("resume 没有 turns 时不能按线程猜测终态：%s", rewritten)
	}
}
