package httpapi

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strings"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
)

// H07 写路径的授权与形状测试。
//
// 写路径与只读的根本区别：只读越权的后果是"看见了不该看的"，写路径是"改了不该改的"。
// 因此本文件的核心断言是**负向**的——被拒的写请求必须一次都不触达上游（spy.touched()==0），
// 并且每条负向都配一条正向对照，否则"全部被拒"和"策略生效"在测试里长得一样。

// writeBody 构造一个写方法的请求体。
func writeBody(t *testing.T, rpcID, method, args string) string {
	t.Helper()
	return fmt.Sprintf(`{"rpcId":%q,"method":%q,"args":%s}`, rpcID, method, args)
}

// --- session/create ---

// 正向对照：cwd 落在授权目录内时，create 必须被转发，且 args 形状正确。
//
// 注意 cwd 出现在**两个位置**，它们的职责不同：
//   - 顶层 `cwd`：中继的授权提示，决定"这次调用允不允许"。它不进上游 args。
//   - `args.request.cwd`：上游真正要创建的目录。
//
// 中继必须校验后者确实落在前者授权的范围内（见 harnessNativeForwardWrite）。
// 这两处不能混为一谈：只校验顶层等于允许"授权 A 却建到 B"。
func TestHarnessNativeH07CreateForwardsAuthorizedCWD(t *testing.T) {
	spy := &harnessNativeSpy{rawValue: json.RawMessage(`{"sessionId":"s-new","agentPreset":"standard"}`)}
	router, authorized, _ := harnessNativeFixture(t, spy)

	body := fmt.Sprintf(`{"rpcId":"c1","method":%q,"args":{"request":{"cwd":%q}},"cwd":%q}`,
		harnessNativeMethodSessionCreate, authorized, authorized)
	recorder := callHarnessNativeRPC(t, router, body, nil)

	envelope := decodeHarnessNativeEnvelope(t, recorder)
	if !envelope.Result.OK {
		t.Fatalf("授权目录内的 create 必须成功：%+v", envelope.Result.Error)
	}
	if spy.rawCalls != 1 {
		t.Fatalf("create 必须触达上游一次，实际 %d", spy.rawCalls)
	}
	if spy.rawMethods[0] != harnessNativeMethodSessionCreate {
		t.Fatalf("转发的方法名错误：%s", spy.rawMethods[0])
	}
	forward, ok := spy.rawArgs[0].(map[string]any)
	if !ok {
		t.Fatalf("转发参数形状错误：%T", spy.rawArgs[0])
	}
	request, ok := forward["request"].(map[string]any)
	if !ok {
		t.Fatalf("缺少 request 外壳：%v", forward)
	}
	if request["cwd"] != authorized {
		t.Fatalf("cwd 未原样转发：%v", request["cwd"])
	}
	// agentPreset 由 Harness 决定默认值（契约 D4），中继不得替它挑一个。
	if _, present := request["agentPreset"]; present {
		t.Fatal("中继不得转发 agentPreset：默认值由 Harness 决定")
	}
}

// 负向：未授权目录的 create 必须被拒，且不触达上游。
func TestHarnessNativeH07CreateRejectsUnauthorizedCWD(t *testing.T) {
	spy := &harnessNativeSpy{rawValue: json.RawMessage(`{}`)}
	router, _, unauthorized := harnessNativeFixture(t, spy)

	body := fmt.Sprintf(`{"rpcId":"c2","method":%q,"args":{"request":{"cwd":%q}},"cwd":%q}`,
		harnessNativeMethodSessionCreate, unauthorized, unauthorized)
	recorder := callHarnessNativeRPC(t, router, body, nil)

	if recorder.Code != http.StatusForbidden {
		t.Fatalf("未授权 cwd 的 create 必须 403，实际 %d：%s", recorder.Code, recorder.Body)
	}
	if spy.touched() != 0 {
		t.Fatalf("被拒的 create 不得触达上游，实际 %d 次", spy.touched())
	}
}

// 负向：缺 cwd 必须拒绝——没有 cwd 就没有授权依据。
func TestHarnessNativeH07CreateRequiresCWD(t *testing.T) {
	spy := &harnessNativeSpy{rawValue: json.RawMessage(`{}`)}
	router, _, _ := harnessNativeFixture(t, spy)

	recorder := callHarnessNativeRPC(t, router,
		writeBody(t, "c3", harnessNativeMethodSessionCreate, `{"request":{"cwd":""}}`), nil)

	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("缺 cwd 必须 400，实际 %d", recorder.Code)
	}
	if spy.touched() != 0 {
		t.Fatalf("不得触达上游，实际 %d", spy.touched())
	}
}

// 负向：路径穿越不得因为"字符串前缀像"而被放行。
//
// 用 `<authorized>/../<unauthorized>` 这种输入试：它字面上以授权目录开头，
// 但 canonical 之后不在授权范围内。
func TestHarnessNativeH07CreateRejectsPathTraversal(t *testing.T) {
	spy := &harnessNativeSpy{rawValue: json.RawMessage(`{}`)}
	router, authorized, unauthorized := harnessNativeFixture(t, spy)

	traversal := authorized + "/../" + unauthorized
	body := fmt.Sprintf(`{"rpcId":"c4","method":%q,"args":{"request":{"cwd":%q}},"cwd":%q}`,
		harnessNativeMethodSessionCreate, traversal, authorized)
	recorder := callHarnessNativeRPC(t, router, body, nil)

	if recorder.Code == http.StatusOK {
		t.Fatalf("路径穿越不得放行：%s", recorder.Body)
	}
	if spy.touched() != 0 {
		t.Fatalf("不得触达上游，实际 %d", spy.touched())
	}
}

// 负向：顶层 cwd 合法但 args 里的 cwd 指向别处——必须拒绝。
//
// 这是 create 最容易出的一类越权：两个 cwd 各自看起来都"有依据"，
// 只校验其中一个就等于允许"授权 A 目录、却把会话建到 B 目录"。
// 中继必须在转发前证明 args 里的目标落在顶层 cwd 授权的范围内。
func TestHarnessNativeH07CreateRejectsArgsCWDEscapingAuthorizedScope(t *testing.T) {
	spy := &harnessNativeSpy{rawValue: json.RawMessage(`{"sessionId":"s-new"}`)}
	router, authorized, unauthorized := harnessNativeFixture(t, spy)

	body := fmt.Sprintf(`{"rpcId":"c6","method":%q,"args":{"request":{"cwd":%q}},"cwd":%q}`,
		harnessNativeMethodSessionCreate, unauthorized, authorized)
	recorder := callHarnessNativeRPC(t, router, body, nil)

	if recorder.Code == http.StatusOK {
		t.Fatalf("args 里的 cwd 逃出授权范围时不得放行：%s", recorder.Body)
	}
	if spy.touched() != 0 {
		t.Fatalf("不得触达上游，实际 %d", spy.touched())
	}
}

// 正向对照：args 里的 cwd 落在授权目录**之下**时必须放行。
//
// 授权的是父目录，创建在子目录里是合法用法。这条同时证明上面的拒绝
// 不是"因为路径不相等而拒"——那会把合法用法一起挡掉。
func TestHarnessNativeH07CreateAllowsSubdirectoryOfAuthorizedScope(t *testing.T) {
	spy := &harnessNativeSpy{rawValue: json.RawMessage(`{"sessionId":"s-sub"}`)}
	router, authorized, _ := harnessNativeFixture(t, spy)

	sub := authorized + "/nested"
	if err := os.MkdirAll(sub, 0o755); err != nil {
		t.Fatal(err)
	}
	body := fmt.Sprintf(`{"rpcId":"c7","method":%q,"args":{"request":{"cwd":%q}},"cwd":%q}`,
		harnessNativeMethodSessionCreate, sub, authorized)
	recorder := callHarnessNativeRPC(t, router, body, nil)

	envelope := decodeHarnessNativeEnvelope(t, recorder)
	if !envelope.Result.OK {
		t.Fatalf("授权目录之下的子目录必须可创建：%+v", envelope.Result.Error)
	}
}

// 负向：cwd 只对 create 开放，其余写方法不接受它。
func TestHarnessNativeH07PromptRejectsCWD(t *testing.T) {
	spy := &harnessNativeSpy{rawValue: json.RawMessage(`{}`)}
	router, authorized, _ := harnessNativeFixture(t, spy)

	body := fmt.Sprintf(`{"rpcId":"c5","method":%q,"args":{"request":{"requestId":"r1","sessionId":"s1","mode":"queue","content":[{"type":"text","text":"hi"}]}},"cwd":%q}`,
		harnessNativeMethodSessionPrompt, authorized)
	recorder := callHarnessNativeRPC(t, router, body, nil)

	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("prompt 带 cwd 必须 400，实际 %d：%s", recorder.Code, recorder.Body)
	}
	if spy.touched() != 0 {
		t.Fatalf("不得触达上游，实际 %d", spy.touched())
	}
}

// --- session/prompt ---

// 正向对照：已授权会话的 prompt 被转发，args 形状正确。
func TestHarnessNativeH07PromptForwardsForAuthorizedSession(t *testing.T) {
	spy := &harnessNativeSpy{rawValue: json.RawMessage(`{"accepted":true}`)}
	router, authorized, _ := harnessNativeFixture(t, spy)
	spy.sessions = []harnessclient.SessionSummary{harnessNativeSession("s1", authorized, 100, false)}

	body := writeBody(t, "p1", harnessNativeMethodSessionPrompt,
		`{"request":{"requestId":"req-1","sessionId":"s1","mode":"queue","content":[{"type":"text","text":"你好"}]}}`)
	recorder := callHarnessNativeRPC(t, router, body, nil)

	envelope := decodeHarnessNativeEnvelope(t, recorder)
	if !envelope.Result.OK {
		t.Fatalf("已授权会话的 prompt 必须成功：%+v", envelope.Result.Error)
	}
	// 一次授权读（ListSessions）+ 一次转发。
	if spy.rawCalls != 1 {
		t.Fatalf("prompt 必须转发一次，实际 %d", spy.rawCalls)
	}
	forward := spy.rawArgs[0].(map[string]any)["request"].(map[string]any)
	if forward["requestId"] != "req-1" {
		t.Fatalf("requestId 必须原样转发（它是提交对账键）：%v", forward["requestId"])
	}
	if forward["mode"] != "queue" {
		t.Fatalf("mode 必须原样转发：%v", forward["mode"])
	}
	if _, present := forward["clientTimeZone"]; present {
		t.Fatal("未给 clientTimeZone 时不得凭空补一个")
	}
}

// 负向：未授权会话的 prompt 必须被拒且不触达上游。
func TestHarnessNativeH07PromptRejectsUnauthorizedSession(t *testing.T) {
	spy := &harnessNativeSpy{rawValue: json.RawMessage(`{"accepted":true}`)}
	router, _, unauthorized := harnessNativeFixture(t, spy)
	// 会话存在，但落在未授权目录。
	spy.sessions = []harnessclient.SessionSummary{harnessNativeSession("s1", unauthorized, 100, false)}

	body := writeBody(t, "p2", harnessNativeMethodSessionPrompt,
		`{"request":{"requestId":"req-2","sessionId":"s1","mode":"queue","content":[{"type":"text","text":"x"}]}}`)
	recorder := callHarnessNativeRPC(t, router, body, nil)

	if recorder.Code != http.StatusForbidden {
		t.Fatalf("未授权会话的 prompt 必须 403，实际 %d：%s", recorder.Code, recorder.Body)
	}
	if _, _, rawCalls := spy.counts(); rawCalls != 0 {
		t.Fatalf("被拒的 prompt 不得转发，实际 %d 次", rawCalls)
	}
}

// 负向：mode 取值域只有 queue/steer（实测）。传别的必须本地就拒。
func TestHarnessNativeH07PromptRejectsUnknownMode(t *testing.T) {
	spy := &harnessNativeSpy{rawValue: json.RawMessage(`{"accepted":true}`)}
	router, authorized, _ := harnessNativeFixture(t, spy)
	spy.sessions = []harnessclient.SessionSummary{harnessNativeSession("s1", authorized, 100, false)}

	for _, mode := range []string{"default", "interrupt", "", "steering"} {
		body := writeBody(t, "p3", harnessNativeMethodSessionPrompt,
			fmt.Sprintf(`{"request":{"requestId":"r","sessionId":"s1","mode":%q,"content":[{"type":"text","text":"x"}]}}`, mode))
		recorder := callHarnessNativeRPC(t, router, body, nil)
		if recorder.Code != http.StatusBadRequest {
			t.Fatalf("mode=%q 必须 400，实际 %d", mode, recorder.Code)
		}
	}
	if spy.touched() != 0 {
		t.Fatalf("非法 mode 不得触达上游，实际 %d", spy.touched())
	}
}

// 负向：缺 requestId 必须拒绝——没有它就无法与 durable 记录对账。
func TestHarnessNativeH07PromptRequiresRequestID(t *testing.T) {
	spy := &harnessNativeSpy{rawValue: json.RawMessage(`{"accepted":true}`)}
	router, authorized, _ := harnessNativeFixture(t, spy)
	spy.sessions = []harnessclient.SessionSummary{harnessNativeSession("s1", authorized, 100, false)}

	body := writeBody(t, "p4", harnessNativeMethodSessionPrompt,
		`{"request":{"sessionId":"s1","mode":"queue","content":[{"type":"text","text":"x"}]}}`)
	recorder := callHarnessNativeRPC(t, router, body, nil)

	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("缺 requestId 必须 400，实际 %d", recorder.Code)
	}
	if spy.touched() != 0 {
		t.Fatalf("不得触达上游，实际 %d", spy.touched())
	}
}

// 负向：空 content 必须拒绝（会让一次用户提交变成空回合）。
func TestHarnessNativeH07PromptRejectsEmptyContent(t *testing.T) {
	spy := &harnessNativeSpy{rawValue: json.RawMessage(`{"accepted":true}`)}
	router, authorized, _ := harnessNativeFixture(t, spy)
	spy.sessions = []harnessclient.SessionSummary{harnessNativeSession("s1", authorized, 100, false)}

	body := writeBody(t, "p5", harnessNativeMethodSessionPrompt,
		`{"request":{"requestId":"r","sessionId":"s1","mode":"queue","content":[]}}`)
	recorder := callHarnessNativeRPC(t, router, body, nil)

	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("空 content 必须 400，实际 %d", recorder.Code)
	}
	if spy.touched() != 0 {
		t.Fatalf("不得触达上游，实际 %d", spy.touched())
	}
}

// 负向：未知字段一律拒绝（可能改写授权目标）。
func TestHarnessNativeH07PromptRejectsUnknownArgs(t *testing.T) {
	spy := &harnessNativeSpy{rawValue: json.RawMessage(`{"accepted":true}`)}
	router, authorized, _ := harnessNativeFixture(t, spy)
	spy.sessions = []harnessclient.SessionSummary{harnessNativeSession("s1", authorized, 100, false)}

	body := writeBody(t, "p6", harnessNativeMethodSessionPrompt,
		`{"request":{"requestId":"r","sessionId":"s1","mode":"queue","content":[{"type":"text","text":"x"}],"sandbox":"danger-full-access"}}`)
	recorder := callHarnessNativeRPC(t, router, body, nil)

	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("未知字段必须 400，实际 %d：%s", recorder.Code, recorder.Body)
	}
	if spy.touched() != 0 {
		t.Fatalf("不得触达上游，实际 %d", spy.touched())
	}
}

// --- session/selectModel 与 session/cancel ---

func TestHarnessNativeH07SelectModelForwardsAndRequiresTarget(t *testing.T) {
	spy := &harnessNativeSpy{rawValue: json.RawMessage(`{"selected":{"provider":"p","model":"m"}}`)}
	router, authorized, _ := harnessNativeFixture(t, spy)
	spy.sessions = []harnessclient.SessionSummary{harnessNativeSession("s1", authorized, 100, false)}

	body := writeBody(t, "m1", harnessNativeMethodSessionSelectModel,
		`{"request":{"sessionId":"s1","provider":"h00-loopback","model":"h00-mock-model"}}`)
	recorder := callHarnessNativeRPC(t, router, body, nil)
	envelope := decodeHarnessNativeEnvelope(t, recorder)
	if !envelope.Result.OK {
		t.Fatalf("已授权会话的 selectModel 必须成功：%+v", envelope.Result.Error)
	}
	forward := spy.rawArgs[0].(map[string]any)["request"].(map[string]any)
	if forward["provider"] != "h00-loopback" || forward["model"] != "h00-mock-model" {
		t.Fatalf("provider/model 必须原样转发：%v", forward)
	}
	// reasoningEffort 可选：没给就不转发，避免把"没选档位"变成空档位。
	if _, present := forward["reasoningEffort"]; present {
		t.Fatal("未给 reasoningEffort 时不得凭空补一个")
	}
}

func TestHarnessNativeH07SelectModelRequiresProviderAndModel(t *testing.T) {
	spy := &harnessNativeSpy{rawValue: json.RawMessage(`{}`)}
	router, authorized, _ := harnessNativeFixture(t, spy)
	spy.sessions = []harnessclient.SessionSummary{harnessNativeSession("s1", authorized, 100, false)}

	for _, args := range []string{
		`{"request":{"sessionId":"s1","provider":"p"}}`,
		`{"request":{"sessionId":"s1","model":"m"}}`,
		`{"request":{"provider":"p","model":"m"}}`,
	} {
		recorder := callHarnessNativeRPC(t, router,
			writeBody(t, "m2", harnessNativeMethodSessionSelectModel, args), nil)
		if recorder.Code != http.StatusBadRequest {
			t.Fatalf("args=%s 必须 400，实际 %d", args, recorder.Code)
		}
	}
	if spy.touched() != 0 {
		t.Fatalf("不得触达上游，实际 %d", spy.touched())
	}
}

func TestHarnessNativeH07CancelForwardsForAuthorizedSession(t *testing.T) {
	spy := &harnessNativeSpy{rawValue: json.RawMessage(`{"accepted":true}`)}
	router, authorized, _ := harnessNativeFixture(t, spy)
	spy.sessions = []harnessclient.SessionSummary{harnessNativeSession("s1", authorized, 100, false)}

	recorder := callHarnessNativeRPC(t, router,
		writeBody(t, "x1", harnessNativeMethodSessionCancel, `{"request":{"sessionId":"s1"}}`), nil)
	envelope := decodeHarnessNativeEnvelope(t, recorder)
	if !envelope.Result.OK {
		t.Fatalf("已授权会话的 cancel 必须成功：%+v", envelope.Result.Error)
	}
	forward := spy.rawArgs[0].(map[string]any)["request"].(map[string]any)
	if forward["sessionId"] != "s1" {
		t.Fatalf("sessionId 必须原样转发：%v", forward)
	}
}

// 负向：cancel 未知会话必须被拒且不触达上游。
func TestHarnessNativeH07CancelRejectsUnknownSession(t *testing.T) {
	spy := &harnessNativeSpy{rawValue: json.RawMessage(`{"accepted":true}`)}
	router, _, _ := harnessNativeFixture(t, spy)
	// 上游列表里没有这个会话：归属无法证明。
	spy.sessions = nil

	recorder := callHarnessNativeRPC(t, router,
		writeBody(t, "x2", harnessNativeMethodSessionCancel, `{"request":{"sessionId":"ghost"}}`), nil)

	if recorder.Code == http.StatusOK {
		t.Fatalf("归属无法证明的 cancel 不得放行：%s", recorder.Body)
	}
	if spy.rawCalls != 0 {
		t.Fatalf("不得转发，实际 %d", spy.rawCalls)
	}
}

// --- 方法白名单边界 ---

// 负向：事件订阅与审批应答不得经由这条 RPC 通道开放。
//
// `$events/result` 尤其重要：它必须绑定活连接的 clientId，单独开放这条 RPC
// 会绕开那层关联。
func TestHarnessNativeH07SubscriptionMethodsStayClosed(t *testing.T) {
	spy := &harnessNativeSpy{rawValue: json.RawMessage(`{}`)}
	router, authorized, _ := harnessNativeFixture(t, spy)

	for _, method := range []string{
		"session/follow", "$events", "$events/result", "session/updateQueue", "workspace/create",
	} {
		recorder := callHarnessNativeRPC(t, router,
			writeBody(t, "s1", method, `{"request":{"sessionId":"s1","address":{"kind":"session","sessionId":"s1"}}}`), nil)
		if recorder.Code != http.StatusForbidden {
			t.Fatalf("%s 必须 403，实际 %d：%s", method, recorder.Code, recorder.Body)
		}
	}
	if spy.touched() != 0 {
		t.Fatalf("未开放的方法不得触达上游，实际 %d", spy.touched())
	}
	_ = authorized
}

// 正向对照：只读方法在加了写路径之后仍然工作（没有被误伤）。
func TestHarnessNativeH07ReadOnlyMethodsStillWork(t *testing.T) {
	spy := &harnessNativeSpy{rawValue: json.RawMessage(`{"items":[]}`)}
	router, _, _ := harnessNativeFixture(t, spy)

	recorder := callHarnessNativeRPC(t, router,
		writeBody(t, "r1", harnessNativeMethodSessionModelCatalog, `{}`), nil)

	envelope := decodeHarnessNativeEnvelope(t, recorder)
	if !envelope.Result.OK {
		t.Fatalf("只读方法必须仍然可用：%+v", envelope.Result.Error)
	}
}

// 负向：上游业务失败按原生语义回传（HTTP 200 + ok=false），不是 502。
//
// 写路径尤其需要这个区分：客户端要能分辨"上游明确拒绝"与"链路不通"，
// 前者不该重试，后者可以。
func TestHarnessNativeH07WriteBusinessFailureUsesNativeSemantics(t *testing.T) {
	spy := &harnessNativeSpy{
		rawErr: &harnessclient.RemoteError{Code: "session/agent-busy", Message: "会话正忙"},
	}
	router, authorized, _ := harnessNativeFixture(t, spy)
	spy.sessions = []harnessclient.SessionSummary{harnessNativeSession("s1", authorized, 100, false)}

	recorder := callHarnessNativeRPC(t, router,
		writeBody(t, "b1", harnessNativeMethodSessionPrompt,
			`{"request":{"requestId":"r","sessionId":"s1","mode":"queue","content":[{"type":"text","text":"x"}]}}`), nil)

	envelope := decodeHarnessNativeEnvelope(t, recorder)
	if envelope.Result.OK {
		t.Fatal("上游业务失败不得判为成功")
	}
	if envelope.Result.Error == nil || envelope.Result.Error.Code != "session/agent-busy" {
		t.Fatalf("必须保留上游错误码：%+v", envelope.Result.Error)
	}
}

// 正向对照：写方法的响应外壳与只读一致（type/rpcId/result），
// 客户端因此可以用同一套判定逻辑处理两条路径。
func TestHarnessNativeH07WriteResponseKeepsEnvelopeShape(t *testing.T) {
	spy := &harnessNativeSpy{rawValue: json.RawMessage(`{"accepted":true}`)}
	router, authorized, _ := harnessNativeFixture(t, spy)
	spy.sessions = []harnessclient.SessionSummary{harnessNativeSession("s1", authorized, 100, false)}

	recorder := callHarnessNativeRPC(t, router,
		writeBody(t, "e1", harnessNativeMethodSessionPrompt,
			`{"request":{"requestId":"r","sessionId":"s1","mode":"queue","content":[{"type":"text","text":"x"}]}}`), nil)

	envelope := decodeHarnessNativeEnvelope(t, recorder)
	if envelope.Type != "server-response" {
		t.Fatalf("外壳 type 必须是 server-response：%s", envelope.Type)
	}
	if envelope.RPCID != "e1" {
		t.Fatalf("rpcId 必须回传：%s", envelope.RPCID)
	}
	if !strings.Contains(string(envelope.Result.Value), "accepted") {
		t.Fatalf("value 必须原样下发：%s", envelope.Result.Value)
	}
}
