package harnessclient

import (
	"context"
	"encoding/json"
	"testing"
)

// argsOf 取出一次 RPC 实际发到线路上的 args，并断言它正好是唯一的 payload.args。
func argsOf(t *testing.T, call recordedCall) map[string]any {
	t.Helper()
	payload, ok := call.Envelope["payload"].(map[string]any)
	if !ok {
		t.Fatalf("payload 不是对象：%#v", call.Envelope)
	}
	args, ok := payload["args"].(map[string]any)
	if !ok {
		t.Fatalf("args 不是对象：%#v", payload)
	}
	return args
}

// session/list 的线路参数名是 "_request"。Harness 网关按描述符逐字比对参数名，
// 写成 "request" 会直接得到 gateway/arguments-invalid。
func TestListSessionsUsesUnderscoreRequestWireName(t *testing.T) {
	fake := newFakeHarness(t)
	server := fake.serve()
	client := authenticatedClient(t, fake, server.URL)

	fake.handle(MethodSessionList, func(json.RawMessage) (any, *RemoteError) {
		return SessionListResult{Items: []SessionSummary{
			{SessionID: "s-1", UpdatedAt: 1700000000000, Running: true},
		}}, nil
	})
	items, err := client.ListSessions(context.Background(), SessionListRequest{})
	if err != nil {
		t.Fatalf("列会话失败：%v", err)
	}
	if len(items) != 1 || items[0].SessionID != "s-1" || !items[0].Running {
		t.Fatalf("列表条目解析不符：%#v", items)
	}

	calls := fake.recorded()
	if len(calls) != 1 {
		t.Fatalf("应有一次 RPC，得到 %d", len(calls))
	}
	args := argsOf(t, calls[0])
	if _, ok := args["_request"]; !ok {
		t.Fatalf("args 必须带下划线参数名 _request：%#v", args)
	}
	if _, ok := args["request"]; ok {
		t.Fatalf("args 不能出现 request（会被判参数名不符）：%#v", args)
	}
	if len(args) != 1 {
		t.Fatalf("args 只应有一个键：%#v", args)
	}
}

// session/search 用 request.query，并读 items + hasMore。
func TestSearchSessionsSendsQueryAndReadsItems(t *testing.T) {
	fake := newFakeHarness(t)
	server := fake.serve()
	client := authenticatedClient(t, fake, server.URL)

	var seenQuery string
	fake.handle(MethodSessionSearch, func(raw json.RawMessage) (any, *RemoteError) {
		var decoded struct {
			Request SessionSearchRequest `json:"request"`
		}
		if err := json.Unmarshal(raw, &decoded); err != nil {
			t.Errorf("解析 search 参数失败：%v", err)
		}
		seenQuery = decoded.Request.Query
		return SessionSearchResult{
			Items:   []SessionSearchItem{{SessionID: "s-2", Snippet: "命中片段"}},
			HasMore: true,
		}, nil
	})
	result, err := client.SearchSessions(context.Background(), "fixture")
	if err != nil {
		t.Fatalf("搜索失败：%v", err)
	}
	if seenQuery != "fixture" {
		t.Fatalf("query 未按契约传递：%q", seenQuery)
	}
	if !result.HasMore || len(result.Items) != 1 || result.Items[0].Snippet != "命中片段" {
		t.Fatalf("搜索结果解析不符：%#v", result)
	}
	if _, ok := argsOf(t, fake.recorded()[0])["request"]; !ok {
		t.Fatal("search 的参数名应为 request")
	}
}

// 模型目录的 provider 组字段是 name，模型带 reasoning 档位。
func TestModelCatalogReadsGroupNameAndReasoning(t *testing.T) {
	fake := newFakeHarness(t)
	server := fake.serve()
	client := authenticatedClient(t, fake, server.URL)

	fake.handle(MethodSessionModelCatalog, func(json.RawMessage) (any, *RemoteError) {
		return ModelCatalogResult{
			Default:           ModelSelection{Provider: "ark-coding-plan-cn", Model: "deepseek-v4-pro"},
			RoutableProviders: []string{"ark-coding-plan-cn"},
			Groups: []ModelCatalogGroup{{
				ID:   "ark-coding-plan-cn",
				Name: "Volcano Ark Coding Plan",
				Models: []ModelEntry{{
					ID:        "deepseek-v4-pro",
					Name:      "DeepSeek V4 Pro",
					Reasoning: &ModelReasoning{Efforts: []ModelReasoningEffort{{ID: "high", Name: "High"}}, DefaultEffort: "high"},
				}},
			}},
		}, nil
	})
	catalog, err := client.ModelCatalog(context.Background())
	if err != nil {
		t.Fatalf("取模型目录失败：%v", err)
	}
	if len(catalog.Groups) != 1 || catalog.Groups[0].Name != "Volcano Ark Coding Plan" {
		t.Fatalf("组名字段解析不符：%#v", catalog.Groups)
	}
	model := catalog.Groups[0].Models[0]
	if model.Reasoning == nil || model.Reasoning.DefaultEffort != "high" || len(model.Reasoning.Efforts) != 1 {
		t.Fatalf("推理档位解析不符：%#v", model.Reasoning)
	}
}
