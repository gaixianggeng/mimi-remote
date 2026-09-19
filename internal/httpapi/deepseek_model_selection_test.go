package httpapi

import (
	"encoding/json"
	"errors"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/gorilla/websocket"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
)

// 本文件覆盖模型与推理档位的转译。
//
// 这条链路只有两种可接受的结局：请求的选择真的落到 Harness 会话上，或者明确回绝。
// 静默忽略是最坏的一种——policy 让 model/effort 通过参数门禁，移动端也总在每条
// turn/start 上带着它们，被丢掉之后"界面选的是 A、实际跑的是 B"不会有任何提示。

// ---------------------------------------------------------------- 目录判据

func deepSeekCatalogFixture() harnessclient.ModelCatalogResult {
	var catalog harnessclient.ModelCatalogResult
	raw := `{
		"default": {"provider": "volc", "model": "deepseek-v4", "reasoningEffort": "medium"},
		"routableProviders": ["volc", "backup"],
		"groups": [
			{"id": "volc", "name": "火山", "models": [
				{"id": "deepseek-v4", "name": "DeepSeek V4", "reasoning": {
					"efforts": [{"id": "low"}, {"id": "medium"}, {"id": "high"}],
					"defaultEffort": "medium"
				}},
				{"id": "deepseek-plain", "name": "DeepSeek Plain"}
			]},
			{"id": "backup", "name": "备用", "models": [
				{"id": "deepseek-v4", "name": "DeepSeek V4 Mirror"}
			]}
		],
		"failures": []
	}`
	if err := json.Unmarshal([]byte(raw), &catalog); err != nil {
		panic(err)
	}
	return catalog
}

// provider 只能从目录取；客户端给了 provider 就必须落在那一个分组上。
func TestDeepSeekCatalogLookupOnlyTrustsCatalog(t *testing.T) {
	catalog := deepSeekCatalogFixture()

	tests := []struct {
		name         string
		modelID      string
		providerHint string
		wantProvider string
		wantOK       bool
		wantCandi    int
	}{
		{name: "按提示取分组", modelID: "deepseek-v4", providerHint: "volc", wantProvider: "volc", wantOK: true, wantCandi: 1},
		{name: "大小写不敏感", modelID: "DeepSeek-V4", providerHint: "VOLC", wantProvider: "volc", wantOK: true, wantCandi: 1},
		// 同名模型出现在两个 provider 下：没有任何依据时不得替用户挑一个。
		// 模型目录按 provider 逐个列举，没有机制保证 model id 全局唯一，取第一个命中项
		// 就是"界面选 A、实际跑 B"，而 A/B 可能是不同的计费路线。
		{name: "同名模型多 provider 时必须报歧义", modelID: "deepseek-v4", wantOK: false, wantCandi: 2},
		{name: "目录里唯一的模型可以直接使用", modelID: "deepseek-plain", wantProvider: "volc", wantOK: true, wantCandi: 1},
		// 客户端点名了供应商却指不到：不能退回到别的分组，那会让用户选的供应商被悄悄换掉。
		{name: "提示指不到分组", modelID: "deepseek-v4", providerHint: "nope", wantOK: false, wantCandi: 0},
		{name: "提示的分组里没有这个模型", modelID: "deepseek-plain", providerHint: "backup", wantOK: false, wantCandi: 0},
		{name: "目录里没有的模型", modelID: "gpt-6-astra", wantOK: false, wantCandi: 0},
		{name: "空模型 id", modelID: "", wantOK: false, wantCandi: 0},
		{name: "只有空白", modelID: "   ", wantOK: false, wantCandi: 0},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			match, candidates, ok := deepSeekCatalogLookup(catalog, test.modelID, test.providerHint)
			if ok != test.wantOK {
				t.Fatalf("lookup(%q, %q) ok=%v, want %v", test.modelID, test.providerHint, ok, test.wantOK)
			}
			if len(candidates) != test.wantCandi {
				t.Fatalf("lookup(%q, %q) 候选数=%d, want %d（候选=%v）",
					test.modelID, test.providerHint, len(candidates), test.wantCandi, candidates)
			}
			if ok && match.Provider != test.wantProvider {
				t.Fatalf("provider=%q, want %q", match.Provider, test.wantProvider)
			}
		})
	}
}

// 推理档位只下发目录声明过的值；声明了却不匹配就拒绝，没有声明就不下发。
func TestDeepSeekCatalogEffortOnlyForwardsDeclaredEffort(t *testing.T) {
	catalog := deepSeekCatalogFixture()
	// 显式点名分组：deepseek-v4 在 volc 与 backup 下都存在，不给提示就是歧义。
	reasoning, _, ok := deepSeekCatalogLookup(catalog, "deepseek-v4", "volc")
	if !ok {
		t.Fatal("前置条件：volc 下应有 deepseek-v4")
	}
	plain, _, ok := deepSeekCatalogLookup(catalog, "deepseek-plain", "volc")
	if !ok {
		t.Fatal("前置条件：目录里应有 deepseek-plain")
	}

	tests := []struct {
		name      string
		model     harnessclient.ModelEntry
		requested string
		want      string
		wantErr   bool
	}{
		{name: "声明过的档位", model: reasoning.Model, requested: "high", want: "high"},
		{name: "按目录规范化大小写", model: reasoning.Model, requested: "HIGH", want: "high"},
		{name: "客户端没要求档位", model: reasoning.Model, requested: "", want: ""},
		{name: "未声明的档位必须拒绝", model: reasoning.Model, requested: "xhigh", wantErr: true},
		// 没有 reasoning 段的模型没有推理强度可调，客户端带的档位无处可落；
		// 递一个上游不认识的参数只会让这次发送整体失败。
		{name: "模型没有推理档位", model: plain.Model, requested: "xhigh", want: ""},
		{name: "模型没有推理档位且未要求", model: plain.Model, requested: "", want: ""},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := deepSeekCatalogEffort(test.model, test.requested)
			if test.wantErr {
				if err == nil {
					t.Fatalf("requested=%q 应被拒绝，得到 %q", test.requested, got)
				}
				var selectionErr *deepSeekModelSelectionError
				if !errors.As(err, &selectionErr) {
					t.Fatalf("拒绝原因必须是用户可据此改选的选择错误：%v", err)
				}
				return
			}
			if err != nil {
				t.Fatalf("不应失败：%v", err)
			}
			if got != test.want {
				t.Fatalf("effort=%q, want %q", got, test.want)
			}
		})
	}
}

// 空 id 的档位条目不能算作"可用档位"，否则会下发一个空档位。
func TestDeepSeekCatalogEffortRejectsBlankDeclaredEfforts(t *testing.T) {
	model := harnessclient.ModelEntry{
		ID:        "deepseek-blank",
		Reasoning: &harnessclient.ModelReasoning{Efforts: []harnessclient.ModelReasoningEffort{{ID: "  "}}},
	}
	if effort, err := deepSeekCatalogEffort(model, "high"); err == nil {
		t.Fatalf("全空档位时不得下发：%q", effort)
	}
}

// turn/start 的选择参数必须原样读出并去掉空白。
func TestDeepSeekTurnSelectionParamsReadsAllFields(t *testing.T) {
	selection := deepSeekTurnSelectionParams(map[string]any{
		"model":         "  deepseek-v4  ",
		"modelProvider": " volc ",
		"effort":        " high ",
	})
	if selection.Model != "deepseek-v4" || selection.Provider != "volc" || selection.Effort != "high" {
		t.Fatalf("参数未按预期读出：%+v", selection)
	}
	if empty := deepSeekTurnSelectionParams(map[string]any{}); empty.Model != "" || empty.Provider != "" || empty.Effort != "" {
		t.Fatalf("缺参数时应全为空：%+v", empty)
	}
}

// policy 不得替 DeepSeek 补推理档位。
//
// Codex 的默认档位名（xhigh）与 Harness 各模型自己声明的档位集合无关，写进去就是一个
// 凭空多出来的约束；更糟的是它让"档位是不是客户端选的"无法判断，于是网关要么拒绝掉
// 每一次正常发送，要么把客户端没要求过的档位当成用户选择下发。
func TestDeepSeekTurnParamsDoNotFabricateReasoningEffort(t *testing.T) {
	deepSeekParams := sanitizedGatewayTurnParams("deepseek", map[string]any{
		"threadId": "s-1",
	}, "/tmp/project")
	if effort, present := deepSeekParams["effort"]; present {
		t.Fatalf("DeepSeek 的 turn/start 不得被补上默认档位：%v", effort)
	}

	// 客户端明确带的档位必须原样保留，否则网关连"客户端要了什么"都看不到。
	explicit := sanitizedGatewayTurnParams("deepseek", map[string]any{
		"threadId": "s-1",
		"effort":   "high",
	}, "/tmp/project")
	if explicit["effort"] != "high" {
		t.Fatalf("客户端显式档位必须保留：%v", explicit["effort"])
	}

	// Codex 侧的行为不变：它依赖这个默认值。
	codexParams := sanitizedGatewayTurnParams("codex", map[string]any{
		"threadId": "thread-1",
	}, "/tmp/project")
	if codexParams["effort"] != defaultCodexReasoningEffort {
		t.Fatalf("Codex 仍应补上默认档位：%v", codexParams["effort"])
	}
}

// ---------------------------------------------------------------- 端到端

// deepSeekModelGateway 起一条连着假 Harness 的网关，并记录 selectModel 与 prompt 的
// 到达顺序。
type deepSeekModelGateway struct {
	conn      *websocket.Conn
	workspace string
	mu        sync.Mutex
	order     []string
	selects   []map[string]any
	prompts   []map[string]any
}

func (g *deepSeekModelGateway) selection() []map[string]any {
	g.mu.Lock()
	defer g.mu.Unlock()
	return append([]map[string]any(nil), g.selects...)
}

func (g *deepSeekModelGateway) delivered() []map[string]any {
	g.mu.Lock()
	defer g.mu.Unlock()
	return append([]map[string]any(nil), g.prompts...)
}

func (g *deepSeekModelGateway) callOrder() []string {
	g.mu.Lock()
	defer g.mu.Unlock()
	return append([]string(nil), g.order...)
}

// newDeepSeekModelGateway 装配假 Harness 与网关，并把会话建好（thread/start）。
//
// session/selectModel 的失败由 selectError 控制：nil 表示成功。
func newDeepSeekModelGateway(
	t *testing.T,
	catalog map[string]any,
	selectError *harnessclient.RemoteError,
) *deepSeekModelGateway {
	t.Helper()
	fixture := &deepSeekModelGateway{}
	harness := newFakeDeepSeekHarness(t)
	harness.handle(harnessclient.MethodSessionList, func(json.RawMessage) (any, *harnessclient.RemoteError) {
		return map[string]any{"items": []any{}}, nil
	})
	harness.handle(harnessclient.MethodSessionCreate, func(json.RawMessage) (any, *harnessclient.RemoteError) {
		return map[string]any{"sessionId": "s-new", "agentPreset": "default"}, nil
	})
	harness.handle(harnessclient.MethodSessionModelCatalog, func(json.RawMessage) (any, *harnessclient.RemoteError) {
		return catalog, nil
	})
	harness.handle(harnessclient.MethodSessionSelectModel, func(args json.RawMessage) (any, *harnessclient.RemoteError) {
		var envelope struct {
			Request map[string]any `json:"request"`
		}
		if err := json.Unmarshal(args, &envelope); err != nil {
			return nil, &harnessclient.RemoteError{Code: "gateway/bad-request", Message: err.Error()}
		}
		fixture.mu.Lock()
		fixture.order = append(fixture.order, "selectModel")
		fixture.selects = append(fixture.selects, envelope.Request)
		fixture.mu.Unlock()
		if selectError != nil {
			return nil, selectError
		}
		return map[string]any{"selected": envelope.Request}, nil
	})

	var followMu sync.Mutex
	var followConn *websocket.Conn
	harness.handle(harnessclient.MethodSessionPrompt, func(args json.RawMessage) (any, *harnessclient.RemoteError) {
		var envelope struct {
			Request map[string]any `json:"request"`
		}
		if err := json.Unmarshal(args, &envelope); err != nil {
			return nil, &harnessclient.RemoteError{Code: "gateway/bad-request", Message: err.Error()}
		}
		fixture.mu.Lock()
		fixture.order = append(fixture.order, "prompt")
		fixture.prompts = append(fixture.prompts, envelope.Request)
		fixture.mu.Unlock()
		// 真实 Harness 收到投递后把轮次与用户消息写进会话日志，这里照此回放。
		// 本文件关注模型选择，因此只回放一条足够让 turn/start 拿到 turn id 的记录。
		followMu.Lock()
		conn := followConn
		followMu.Unlock()
		if conn != nil {
			_ = writeDeepSeekMuxValue(conn, "", map[string]any{
				"type": "event",
				"event": map[string]any{
					"type": "turn/start",
					"seq":  13,
					"data": map[string]any{"turn": 2},
				},
			})
			_ = writeDeepSeekMuxValue(conn, "", map[string]any{
				"type": "event",
				"event": map[string]any{
					"type": "user/message",
					"seq":  14,
					"data": map[string]any{
						"id":     "um-1",
						"role":   "user",
						"source": map[string]any{"kind": "user", "rpcId": envelope.Request["requestId"]},
					},
				},
			})
		}
		return map[string]any{"accepted": true}, nil
	})

	harness.onOpen = func(conn *websocket.Conn, open map[string]any) error {
		switch endpoint, _ := open["endpoint"].(string); endpoint {
		case harnessclient.EndpointEvents:
			// $events 的 ready 给出回传审批所需的 clientId。
			return writeDeepSeekMuxValue(conn, "", map[string]any{
				"type":     "ready",
				"clientId": "client-fixture",
			})
		case harnessclient.MethodSessionFollow:
			followMu.Lock()
			followConn = conn
			followMu.Unlock()
			return writeDeepSeekMuxValue(conn, "", map[string]any{
				"type":    "snapshot",
				"cursor":  12,
				"header":  map[string]any{"id": "s-new"},
				"records": []any{},
			})
		}
		return nil
	}

	harnessServer := harness.serve()
	server := newTestServerWithConfig(t, func(cfg *config.Config) {
		cfg.DeepSeek.Enabled = true
		cfg.DeepSeek.BaseURL = harnessServer.URL
		cfg.DeepSeek.TokenFile = writeDeepSeekTestTokenFile(t, harness.token)
	})
	fixture.workspace = server.router.cfg.Projects[0].Path

	httpServer := httptest.NewServer(server.handler)
	t.Cleanup(httpServer.Close)
	conn := dialDeepSeekGateway(t, httpServer.URL)
	t.Cleanup(func() { _ = conn.Close() })
	callDeepSeekGateway(t, conn, 1, "initialize", map[string]any{})
	callDeepSeekGateway(t, conn, 2, "thread/start", map[string]any{"cwd": fixture.workspace})
	fixture.conn = conn
	return fixture
}

func deepSeekCatalogWithReasoning() map[string]any {
	return map[string]any{
		"default":           map[string]any{"provider": "volc", "model": "deepseek-v4", "reasoningEffort": "medium"},
		"routableProviders": []any{"volc"},
		"groups": []any{map[string]any{
			"id":   "volc",
			"name": "火山",
			"models": []any{map[string]any{
				"id":   "deepseek-v4",
				"name": "DeepSeek V4",
				"reasoning": map[string]any{
					"efforts":       []any{map[string]any{"id": "low"}, map[string]any{"id": "medium"}, map[string]any{"id": "high"}},
					"defaultEffort": "medium",
				},
			}},
		}},
		"failures": []any{},
	}
}

func deepSeekTurnStartParams(fixture *deepSeekModelGateway, extra map[string]any) map[string]any {
	params := map[string]any{
		"threadId":            "s-new",
		"cwd":                 fixture.workspace,
		"clientUserMessageId": "msg-1",
		"input":               []any{map[string]any{"type": "text", "text": "你好"}},
	}
	for key, value := range extra {
		params[key] = value
	}
	return params
}

// 回归：客户端的选择必须真的落到 Harness 会话上，而且要在投递之前。
func TestDeepSeekTurnStartForwardsModelSelectionBeforePrompt(t *testing.T) {
	fixture := newDeepSeekModelGateway(t, deepSeekCatalogWithReasoning(), nil)

	turn := callDeepSeekGateway(t, fixture.conn, 3, "turn/start", deepSeekTurnStartParams(fixture, map[string]any{
		"model":  "deepseek-v4",
		"effort": "high",
	}))
	turnInfo, _ := turn["turn"].(map[string]any)
	if turnInfo == nil {
		t.Fatalf("turn/start 应答缺少 turn：%+v", turn)
	}
	if turnInfo["id"] != "t2" {
		t.Fatalf("turn id 应来自本次投递：%+v", turnInfo)
	}

	selects := fixture.selection()
	if len(selects) != 1 {
		t.Fatalf("应恰好转发一次模型选择，得到 %d 次", len(selects))
	}
	selection := selects[0]
	if selection["sessionId"] != "s-new" {
		t.Fatalf("选择必须落在本次会话上：%+v", selection)
	}
	// provider 只能来自目录：这条请求的 turn/start 没带 modelProvider，会话也没有可用
	// 的 provider 依据，此时目录里恰好只有一个 provider 声明该模型才允许继续——把它
	// 猜成别的供应商会把用户选到另一条计费路线上。
	if selection["provider"] != "volc" {
		t.Fatalf("provider 必须取自模型目录：%+v", selection)
	}
	if selection["model"] != "deepseek-v4" {
		t.Fatalf("model 应为客户端所选：%+v", selection)
	}
	if selection["reasoningEffort"] != "high" {
		t.Fatalf("推理档位必须一并下发：%+v", selection)
	}

	// 顺序必须是"先选模型再投递"：选择表达的是"下一轮用哪个模型"，反了的话这一轮
	// 用的还是上一个模型，而客户端拿到的是这一轮的 turn id。
	if order := fixture.callOrder(); len(order) != 2 || order[0] != "selectModel" || order[1] != "prompt" {
		t.Fatalf("模型选择必须先于投递：%v", order)
	}
	if len(fixture.delivered()) != 1 {
		t.Fatalf("应恰好投递一次：%+v", fixture.delivered())
	}
}

// 回归：目录里没有的模型必须明确回绝，而不是退回 Harness 的默认模型。
func TestDeepSeekTurnStartRejectsModelOutsideCatalog(t *testing.T) {
	fixture := newDeepSeekModelGateway(t, deepSeekCatalogWithReasoning(), nil)

	_, err := callDeepSeekGatewayNoFatal(fixture.conn, 3, "turn/start", deepSeekTurnStartParams(fixture, map[string]any{
		"model": "gpt-6-astra",
	}))
	if err == nil {
		t.Fatal("目录里没有的模型必须被回绝")
	}
	// 错误里必须点名那个模型，用户才知道要改哪个选择。
	if !strings.Contains(err.Error(), "gpt-6-astra") {
		t.Fatalf("拒绝原因应点名模型：%v", err)
	}
	if len(fixture.selection()) != 0 {
		t.Fatalf("被回绝的请求不得改动会话选择：%+v", fixture.selection())
	}
	if len(fixture.delivered()) != 0 {
		t.Fatal("被回绝的请求不得投递给 Harness")
	}
}

// 回归：模型不支持的推理档位必须被回绝，不能静默换成别的档位。
func TestDeepSeekTurnStartRejectsUnsupportedReasoningEffort(t *testing.T) {
	fixture := newDeepSeekModelGateway(t, deepSeekCatalogWithReasoning(), nil)

	_, err := callDeepSeekGatewayNoFatal(fixture.conn, 3, "turn/start", deepSeekTurnStartParams(fixture, map[string]any{
		"model":  "deepseek-v4",
		"effort": "xhigh",
	}))
	if err == nil {
		t.Fatal("未声明的推理档位必须被回绝")
	}
	// 拒绝时要把可用档位列出来，否则用户只能猜。
	if !strings.Contains(err.Error(), "high") {
		t.Fatalf("拒绝原因应列出可用档位：%v", err)
	}
	if len(fixture.delivered()) != 0 {
		t.Fatal("被回绝的请求不得投递给 Harness")
	}
}

// Harness 明确否决这次选择时要回可操作的原因，而不是"操作被忽略"。
func TestDeepSeekTurnStartSurfacesHarnessModelRejection(t *testing.T) {
	fixture := newDeepSeekModelGateway(t, deepSeekCatalogWithReasoning(), &harnessclient.RemoteError{
		Code:    "session/model-unavailable",
		Message: "provider is not routable",
	})

	_, err := callDeepSeekGatewayNoFatal(fixture.conn, 3, "turn/start", deepSeekTurnStartParams(fixture, map[string]any{
		"model": "deepseek-v4",
	}))
	if err == nil {
		t.Fatal("Harness 否决选择时必须回错误帧")
	}
	// 上游错误原文不能带出去，但原因要指向可选动作。
	if strings.Contains(err.Error(), "provider is not routable") {
		t.Fatalf("不得把上游错误原文下发给移动端：%v", err)
	}
	if len(fixture.delivered()) != 0 {
		t.Fatal("选择没生效时不得继续投递")
	}
}

// 没有推理档位的模型：选择照常生效，档位不下发（该模型没有可调档位）。
func TestDeepSeekTurnStartOmitsEffortForModelWithoutReasoningTiers(t *testing.T) {
	catalog := map[string]any{
		"default": map[string]any{"provider": "volc", "model": "deepseek-plain"},
		"groups": []any{map[string]any{
			"id":     "volc",
			"name":   "火山",
			"models": []any{map[string]any{"id": "deepseek-plain", "name": "DeepSeek Plain"}},
		}},
		"failures": []any{},
	}
	fixture := newDeepSeekModelGateway(t, catalog, nil)

	turn := callDeepSeekGateway(t, fixture.conn, 3, "turn/start", deepSeekTurnStartParams(fixture, map[string]any{
		"model":  "deepseek-plain",
		"effort": "xhigh",
	}))
	if _, ok := turn["turn"].(map[string]any); !ok {
		t.Fatalf("turn/start 应答缺少 turn：%+v", turn)
	}
	selects := fixture.selection()
	if len(selects) != 1 {
		t.Fatalf("模型选择仍应生效：%+v", selects)
	}
	if _, present := selects[0]["reasoningEffort"]; present {
		t.Fatalf("没有推理档位的模型不得下发档位：%+v", selects[0])
	}
}

// 只给档位不给模型：selectModel 需要 provider+model 才能表达一次选择，必须回绝而不是忽略。
func TestDeepSeekTurnStartRejectsEffortWithoutModel(t *testing.T) {
	fixture := newDeepSeekModelGateway(t, deepSeekCatalogWithReasoning(), nil)

	_, err := callDeepSeekGatewayNoFatal(fixture.conn, 3, "turn/start", deepSeekTurnStartParams(fixture, map[string]any{
		"effort": "high",
	}))
	if err == nil {
		t.Fatal("只有档位、没有模型时必须回绝")
	}
	if len(fixture.selection()) != 0 {
		t.Fatalf("缺模型时不得改动会话选择：%+v", fixture.selection())
	}
	if len(fixture.delivered()) != 0 {
		t.Fatal("被回绝的请求不得投递给 Harness")
	}
}

// 客户端没有表达选择时不得改动会话设置：不查目录、不下发选择。
func TestDeepSeekTurnStartWithoutSelectionSkipsModelRPCs(t *testing.T) {
	fixture := newDeepSeekModelGateway(t, deepSeekCatalogWithReasoning(), nil)

	callDeepSeekGateway(t, fixture.conn, 3, "turn/start", deepSeekTurnStartParams(fixture, nil))
	if len(fixture.selection()) != 0 {
		t.Fatalf("没有选择时不得改动会话设置：%+v", fixture.selection())
	}
	if order := fixture.callOrder(); len(order) != 1 || order[0] != "prompt" {
		t.Fatalf("应只投递一次：%v", order)
	}
}

// 回归（PR 评审：provider 未随请求携带）：没有任何 provider 依据时，同名模型出现在多个
// provider 下必须拒绝并列出候选，绝不能取"目录里第一个命中项"。
//
// 目录层面的 TestDeepSeekCatalogLookupOnlyTrustsCatalog 只断言 lookup 返回 ok=false；
// 这里断言用户看得见的结论——选择被拒绝、原因可操作（点名候选供应商），因此用户知道
// 要改哪一项，而不是被静默地送到另一条计费路线上。
func TestDeepSeekRejectsAmbiguousModelWithoutProviderEvidence(t *testing.T) {
	// deepseek-v4 同时出现在 volc 与 backup 下；deepseek-plain 只在 volc 下。
	catalog := deepSeekCatalogFixture()

	conn := &deepSeekGatewayConn{threadProviders: map[string]string{}}
	_, err := conn.resolveDeepSeekModel(catalog, "session-ambiguous",
		deepSeekRequestedSelection{Model: "deepseek-v4"})

	var selectionErr *deepSeekModelSelectionError
	if !errors.As(err, &selectionErr) {
		t.Fatalf("歧义模型必须按可操作的模型选择错误拒绝，got %v", err)
	}
	for _, want := range []string{"volc", "backup", "请先选定供应商"} {
		if !strings.Contains(selectionErr.message, want) {
			t.Fatalf("拒绝原因应包含 %q 以便用户重选，实际：%s", want, selectionErr.message)
		}
	}
}

// 与上一条互补：三条"有依据"的路径都必须能落地，其中前两条来自客户端携带的提示。
//
// 这条是评审 Finding 的正面形态——提示不是必需的，但一旦存在就必须被用上：本次
// turn/start 自带的 provider 优先级最高，其次是线程创建时记住的那份，两者都缺时才轮到
// 目录里唯一命中的条目。
func TestDeepSeekResolvesProviderFromRequestOrThreadEvidence(t *testing.T) {
	catalog := deepSeekCatalogFixture()
	for _, tc := range []struct {
		name       string
		requested  deepSeekRequestedSelection
		remembered map[string]string
		want       string
	}{
		{
			name:      "本次 turn/start 自带的 provider 是第一判据",
			requested: deepSeekRequestedSelection{Model: "deepseek-v4", Provider: "backup"},
			want:      "backup",
		},
		{
			name:       "本次没带时用线程创建时声明的 provider",
			requested:  deepSeekRequestedSelection{Model: "deepseek-v4"},
			remembered: map[string]string{"session-1": "backup"},
			want:       "backup",
		},
		{
			name:      "都没有依据时目录里唯一命中仍可直接使用",
			requested: deepSeekRequestedSelection{Model: "deepseek-plain"},
			want:      "volc",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			conn := &deepSeekGatewayConn{threadProviders: tc.remembered}
			match, err := conn.resolveDeepSeekModel(catalog, "session-1", tc.requested)
			if err != nil {
				t.Fatalf("有依据的选择不应被拒绝：%v", err)
			}
			if match.Provider != tc.want {
				t.Fatalf("provider 应为 %q，得到 %q", tc.want, match.Provider)
			}
			if match.Model.ID != tc.requested.Model {
				t.Fatalf("model 应为 %q，得到 %q", tc.requested.Model, match.Model.ID)
			}
		})
	}
}
