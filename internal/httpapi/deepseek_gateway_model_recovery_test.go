package httpapi

import (
	"encoding/json"
	"sync"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
)

func deepSeekSelectionRecord(t *testing.T, seq int64, eventType string, data map[string]any) harnessclient.SessionWireEvent {
	t.Helper()
	raw, err := json.Marshal(data)
	if err != nil {
		t.Fatal(err)
	}
	return harnessclient.SessionWireEvent{Seq: seq, Type: eventType, Data: raw}
}

// 恢复逻辑必须与 Harness 的 durable projection 一致：新的选择替换 pending；
// request/header 只有实际使用了完整的 pending 选择时才消费它。
func TestDeepSeekSessionSelectionProjectsPendingAndLastUsed(t *testing.T) {
	selection := func(seq int64, provider, effort string) harnessclient.SessionWireEvent {
		return deepSeekSelectionRecord(t, seq, deepSeekEventModelSelection, map[string]any{
			"provider": provider, "model": "shared-model", "reasoningEffort": effort,
		})
	}
	header := func(seq int64, provider, effort any) harnessclient.SessionWireEvent {
		return deepSeekSelectionRecord(t, seq, deepSeekEventRequestHeader, map[string]any{
			"header": map[string]any{"config": map[string]any{
				"provider": provider, "model": "shared-model", "reasoningEffort": effort,
			}},
		})
	}

	tests := []struct {
		name    string
		records []harnessclient.SessionWireEvent
		want    deepSeekSelection
	}{
		{
			name:    "后一条选择替换 pending",
			records: []harnessclient.SessionWireEvent{selection(10, "provider-a", "high"), selection(20, "provider-b", "high")},
			want:    deepSeekSelection{Provider: "provider-b", Model: "shared-model", Effort: "high"},
		},
		{
			name: "实际使用完整 pending 后回到最新 lastUsed",
			records: []harnessclient.SessionWireEvent{
				selection(10, "provider-a", "high"), header(20, "provider-a", "high"), header(30, "provider-b", 2),
			},
			want: deepSeekSelection{Provider: "provider-b", Model: "shared-model", Effort: "2"},
		},
		{
			name: "实际使用不同档位不会消费 pending",
			records: []harnessclient.SessionWireEvent{
				selection(10, "provider-a", "high"), header(20, "provider-a", "low"),
			},
			want: deepSeekSelection{Provider: "provider-a", Model: "shared-model", Effort: "high"},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, ok := deepSeekSessionSelection(test.records)
			if !ok || got != test.want {
				t.Fatalf("selection=(%+v, %v), want (%+v, true)", got, ok, test.want)
			}
		})
	}
}

// 同名模型有多个 provider 时，apply 必须把会话最新的持久选择一路交给
// session/selectModel，不能退回最早选择或目录顺序。
func TestApplyDeepSeekModelSelectionUsesLatestSessionProvider(t *testing.T) {
	fake := newFakeDeepSeekHarness(t)
	fake.handle(harnessclient.MethodSessionModelCatalog, func(json.RawMessage) (any, *harnessclient.RemoteError) {
		return map[string]any{
			"groups": []any{
				map[string]any{"id": "provider-a", "models": []any{map[string]any{"id": "shared-model"}}},
				map[string]any{"id": "provider-b", "models": []any{map[string]any{"id": "shared-model"}}},
			},
			"failures": []any{},
		}, nil
	})
	var mu sync.Mutex
	var selected harnessclient.SelectModelRequest
	fake.handle(harnessclient.MethodSessionSelectModel, func(raw json.RawMessage) (any, *harnessclient.RemoteError) {
		var args struct {
			Request harnessclient.SelectModelRequest `json:"request"`
		}
		if err := json.Unmarshal(raw, &args); err != nil {
			t.Fatal(err)
		}
		mu.Lock()
		selected = args.Request
		mu.Unlock()
		return map[string]any{}, nil
	})
	server := fake.serve()
	t.Cleanup(server.Close)
	client, err := harnessclient.New(harnessclient.Config{BaseURL: server.URL, AccessToken: fake.token})
	if err != nil {
		t.Fatal(err)
	}
	if err := client.Authenticate(t.Context()); err != nil {
		t.Fatal(err)
	}

	follow := &deepSeekFollow{threadID: "session-1", records: []harnessclient.SessionWireEvent{
		deepSeekSelectionRecord(t, 10, deepSeekEventModelSelection, map[string]any{
			"provider": "provider-a", "model": "shared-model",
		}),
		deepSeekSelectionRecord(t, 20, deepSeekEventModelSelection, map[string]any{
			"provider": "provider-b", "model": "shared-model",
		}),
	}}
	conn := &deepSeekGatewayConn{
		harness: client,
		follows: map[string]*deepSeekFollow{"session-1": follow},
	}
	if err := conn.applyDeepSeekModelSelection(t.Context(), "session-1", map[string]any{
		"model": "shared-model",
	}); err != nil {
		t.Fatalf("apply selection: %v", err)
	}

	mu.Lock()
	got := selected
	mu.Unlock()
	if got.SessionID != "session-1" || got.Provider != "provider-b" || got.Model != "shared-model" {
		t.Fatalf("session/selectModel request=%+v, want latest provider-b selection", got)
	}
}
