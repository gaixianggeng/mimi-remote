package httpapi

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/gorilla/websocket"
)

// 完整正文和短输出直接可读，较大的过程输出沿用现有鉴权引用按需读取。
func TestHistoryLoadingExternalizesLargeProcessPagesBelowHardCap(t *testing.T) {
	for _, runtime := range []string{"codex", "claude"} {
		for _, method := range []string{"thread/turns/list", "thread/items/list"} {
			t.Run(runtime+"/"+method, func(t *testing.T) {
				router := &Router{historyOutput: newAppServerHistoryOutputStore()}
				policy := &appServerGatewayPolicy{router: router, runtimeID: runtime}
				id := json.RawMessage(`1`)
				if err := policy.reserveHistoryRequest(&id, method, map[string]any{"threadId": "history", "turnId": "turn", "itemsView": "summary"}, 100); err != nil {
					t.Fatal(err)
				}
				fullOutput := strings.Repeat("工具输出 🌿\n", 2000)
				answer := strings.Repeat("完整问答正文。", 600)
				smallOutput := strings.Repeat("short", 500)
				items := []any{
					map[string]any{"id": "user", "type": "userMessage", "content": []any{map[string]any{"type": "text", "text": answer}}},
					map[string]any{"id": "answer", "type": "agentMessage", "text": answer},
					map[string]any{"id": "small", "type": "commandExecution", "aggregatedOutput": smallOutput},
					map[string]any{"id": "command", "type": "commandExecution", "aggregatedOutput": fullOutput},
					map[string]any{"id": "mcp", "type": "mcpToolCall", "result": fullOutput},
				}
				var data []any
				if method == "thread/turns/list" {
					data = []any{map[string]any{"id": "turn", "items": items}}
				} else {
					for _, item := range items {
						data = append(data, map[string]any{"turnId": "turn", "item": item})
					}
				}
				payload, _ := json.Marshal(map[string]any{"id": 1, "result": map[string]any{"data": data, "nextCursor": "next"}})
				if len(payload) >= appServerGatewayHistoryResponseCapBytes {
					t.Fatal("夹具必须低于硬上限，不能只覆盖既有降级")
				}
				rewritten, forward, err := policy.observeUpstreamFrame(websocket.TextMessage, payload)
				if !forward || err != nil {
					t.Fatalf("历史应正常返回：%+v", err)
				}
				if bytes.Contains(rewritten, []byte(fullOutput)) || len(rewritten) > len(payload)/2 {
					t.Fatalf("大过程页必须缩小：before=%d after=%d", len(payload), len(rewritten))
				}
				var decoded map[string]any
				if err := json.Unmarshal(rewritten, &decoded); err != nil {
					t.Fatal(err)
				}
				result := decoded["result"].(map[string]any)
				if result["nextCursor"] != "next" {
					t.Fatal("不能改变分页边界")
				}
				gotData := result["data"].([]any)
				var gotItems []any
				if method == "thread/turns/list" {
					gotItems = gotData[0].(map[string]any)["items"].([]any)
				} else {
					for _, entry := range gotData {
						gotItems = append(gotItems, entry.(map[string]any)["item"])
					}
				}
				if gotItems[0].(map[string]any)["content"].([]any)[0].(map[string]any)["text"] != answer || gotItems[1].(map[string]any)["text"] != answer {
					t.Fatal("问答正文必须完整保留")
				}
				if gotItems[2].(map[string]any)["aggregatedOutput"] != smallOutput {
					t.Fatal("普通短输出无需多点一次才能阅读")
				}
				for _, value := range gotItems[3:] {
					item := value.(map[string]any)
					ref, _ := item["historyOutputRef"].(string)
					entry, ok := router.historyOutput.get(strings.TrimPrefix(ref, appServerHistoryOutputURLPrefix))
					if !ok || string(entry.data) != fullOutput {
						t.Fatal("按需引用必须能无损取回完整输出")
					}
					if item["historyOutputByteCount"] != float64(len(fullOutput)) {
						t.Fatal("保留原字节数")
					}
				}
				if router.gatewayHistoryGlobalBudget.responseBytes != int64(len(rewritten)) {
					t.Fatal("只按实际下发的轻量响应计预算")
				}
				t.Logf("process page bytes: %d -> %d", len(payload), len(rewritten))
			})
		}
	}
}

func TestHistoryLoadingKeepsAnswersAndUnavailableOutputCacheLossless(t *testing.T) {
	for _, hasCache := range []bool{false, true} {
		t.Run(fmt.Sprint(hasCache), func(t *testing.T) {
			router := &Router{}
			if hasCache {
				router.historyOutput = newAppServerHistoryOutputStore()
			}
			policy := &appServerGatewayPolicy{router: router, runtimeID: "codex"}
			id := json.RawMessage(`1`)
			if err := policy.reserveHistoryRequest(&id, "thread/turns/list", map[string]any{"threadId": "history", "itemsView": "summary"}, 100); err != nil {
				t.Fatal(err)
			}
			item := map[string]any{"id": "large", "type": "agentMessage", "text": strings.Repeat("完整正文", 20_000)}
			if !hasCache {
				item = map[string]any{"id": "large", "type": "commandExecution", "aggregatedOutput": strings.Repeat("完整输出", 20_000)}
			}
			payload, _ := json.Marshal(map[string]any{"id": 1, "result": map[string]any{"data": []any{map[string]any{"id": "turn", "items": []any{item}}}}})
			rewritten, forward, err := policy.observeUpstreamFrame(websocket.TextMessage, payload)
			if !forward || err != nil || !bytes.Equal(payload, rewritten) {
				t.Fatal("大正文或无法保存引用时必须无损透传")
			}
		})
	}
}
