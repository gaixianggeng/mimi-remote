package httpapi

import (
	"bytes"
	"encoding/json"
	"fmt"
	"testing"

	"github.com/gorilla/websocket"
)

func TestGatewayThreadListInflightUsesForwardedFilters(t *testing.T) {
	_, router, cwd := buildAppServerGatewayFixture(t, "ws://unused", nil)
	policy := newAppServerGatewayPolicy(router, "claude")
	submit := func(p *appServerGatewayPolicy, id int, fields map[string]any) ([]byte, *appServerGatewayPolicyError) {
		t.Helper()
		fields["cwd"], fields["limit"] = cwd, 20
		payload, err := json.Marshal(map[string]any{"id": id, "method": "thread/list", "params": fields})
		if err != nil {
			t.Fatal(err)
		}
		return p.validateClientFrame(websocket.TextMessage, payload)
	}
	const firstTerm = "fixture-term-alpha"
	const nextTerm = "fixture-term-bravo"
	filters := []map[string]any{
		{},
		{"searchTerm": firstTerm, "sourceKinds": []string{"cli"}},
		{"searchTerm": nextTerm, "sourceKinds": []string{"cli"}},
		{"searchTerm": nextTerm, "sourceKinds": []string{"vscode"}},
	}
	for index, filter := range filters {
		forwarded, err := submit(policy, index+1, filter)
		if err != nil {
			t.Fatalf("distinct list %d was rejected: %s", index, err.message)
		}
		if got := decodeGatewayParamsForTest(t, forwarded)["searchTerm"]; got != filter["searchTerm"] {
			t.Fatalf("unexpected forwarded term: %v", got)
		}
	}
	// An identical request, including a field discarded by the gateway, must still share the reservation.
	_, duplicate := submit(policy, 10, map[string]any{"searchTerm": nextTerm, "sourceKinds": []string{"vscode"}, "unused": true})
	if duplicate == nil || duplicate.data["reason"] != "history_request_in_flight" {
		t.Fatal("equivalent request did not hit the in-flight reservation")
	}

	// Responses return out of order and release only their own reservation.
	for id := len(filters); id > 0; id-- {
		payload := []byte(fmt.Sprintf(`{"id":%d,"result":{"data":[]}}`, id))
		response, ok, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, payload)
		if policyErr != nil || !ok {
			t.Fatalf("response %d was rejected: %+v", id, policyErr)
		}
		var frame appServerGatewayFrame
		if err := json.Unmarshal(response, &frame); err != nil || gatewayRequestIDKey(frame.ID) != fmt.Sprint(id) {
			t.Fatalf("response lost request ID %d", id)
		}
	}
	if _, err := submit(policy, 11, filters[1]); err != nil {
		t.Fatalf("completed list retained its reservation: %s", err.message)
	}
	// Changing the term must still consume the same existing per-scope request budget.
	for count := len(filters) + 1; count < appServerGatewayHistoryBudgetMaxRequests; count++ {
		if _, err := submit(policy, 20+count, map[string]any{"searchTerm": fmt.Sprintf("fixture-%d", count)}); err != nil {
			t.Fatal(err.message)
		}
	}
	_, limited := submit(policy, 42, map[string]any{"searchTerm": nextTerm})
	if limited == nil || limited.data["reason"] != "history_budget_limited" {
		t.Fatal("changing filters escaped the existing list budget")
	}
	serialized, err := json.Marshal([]any{duplicate.message, duplicate.data, limited.message, limited.data, router.monitor.snapshot()})
	if err != nil || bytes.Contains(serialized, []byte(nextTerm)) || bytes.Contains(serialized, []byte(firstTerm)) {
		t.Fatal("errors and diagnostics must omit search text")
	}

	// Codex drops thread/list.searchTerm and exposes its own thread/search RPC.
	codex := newAppServerGatewayPolicy(router, "codex")
	if _, err := submit(codex, 1, map[string]any{"searchTerm": firstTerm}); err != nil {
		t.Fatal(err.message)
	}
	if _, err := submit(codex, 2, map[string]any{"searchTerm": nextTerm}); err == nil || err.data["reason"] != "history_request_in_flight" {
		t.Fatal("fields dropped by this runtime should not distinguish requests")
	}
}
