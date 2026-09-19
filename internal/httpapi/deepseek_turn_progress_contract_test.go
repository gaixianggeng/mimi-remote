package httpapi

import (
	"context"
	"encoding/json"
	"os"
	"reflect"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
)

func TestDeepSeekTurnProgressMatchesSharedIOSContract(t *testing.T) {
	harness := newFakeDeepSeekHarness(t)
	calls := 0
	harness.handle(harnessclient.MethodSessionPage, func(json.RawMessage) (any, *harnessclient.RemoteError) {
		calls++
		if calls <= 16 {
			return map[string]any{
				"records": []any{map[string]any{"seq": 100 - calls, "type": "step/start", "data": map[string]any{"turn": 1, "step": 1}}},
				"hasMore": true,
			}, nil
		}
		return map[string]any{
			"records": []any{
				map[string]any{"seq": 82, "type": "turn/start", "data": map[string]any{"turn": 1}},
				map[string]any{"seq": 83, "type": "turn/end", "data": map[string]any{"turn": 1, "reason": map[string]any{"kind": "completed"}}},
			}, "hasMore": false,
		}, nil
	})
	conn := newDeepSeekHistoryConn(t, harness)
	follow := &deepSeekFollow{threadID: "session-a", throughSeq: 100, updated: make(chan struct{}, 1)}
	follow.note([]harnessclient.SessionWireEvent{{Type: "step/start", Seq: 100, Data: json.RawMessage(`{"turn":1,"step":1}`)}})
	var pages []any
	cursor := ""
	for range 3 {
		buckets, next, hasMore, err := conn.deepSeekTurnPage(context.Background(), follow, map[string]any{"cursor": cursor, "limit": 1})
		if err != nil {
			t.Fatal(err)
		}
		rows := make([]any, 0, len(buckets))
		for _, bucket := range buckets {
			rows = append(rows, deepSeekTurnWire(bucket, true))
		}
		pages = append(pages, deepSeekPageResultWithCursor(rows, next, hasMore))
		cursor = next
	}
	actualJSON, err := json.Marshal(pages)
	if err != nil {
		t.Fatal(err)
	}
	fixture, err := os.ReadFile("../../contracts/mimi-protocol/fixtures/deepseek-turn-progress-pages.json")
	if err != nil {
		t.Fatal(err)
	}
	var actual, expected any
	if err := json.Unmarshal(actualJSON, &actual); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(fixture, &expected); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(actual, expected) {
		t.Fatalf("Go 历史分页与 iOS 共享回包不同：%s", actualJSON)
	}
	if calls != 17 || cursor != "" {
		t.Fatalf("必须越过两次 8 页预算后准确收尾：calls=%d cursor=%q", calls, cursor)
	}
}
