package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
)

// 本文件覆盖 /api/harness/rpc 的只读中继。
//
// 每条负向用例都同时断言两件事：状态码，以及"上游一次都没被访问过"。后者才是这条
// 通道的核心约束——越权请求如果先建连再判断，攻击面就已经产生了，光看状态码看不出来。

// harnessNativeSpy 是中继上游的可观测替身。
//
// 统计的是**任何**一次上游交互（列表、检索、原始 RPC 都算）。负向用例统一断言
// touched()==0，这样即使将来有人在授权之前插入一次"顺手探活"，用例也会失败。
type harnessNativeSpy struct {
	mu sync.Mutex

	sessions     []harnessclient.SessionSummary
	searchResult harnessclient.SessionSearchResult
	rawValue     json.RawMessage

	listErr   error
	searchErr error
	rawErr    error

	listCalls   int
	searchCalls int
	rawCalls    int
	rawMethods  []string
	rawArgs     []any
}

func (s *harnessNativeSpy) ListSessions(context.Context, harnessclient.SessionListRequest) ([]harnessclient.SessionSummary, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.listCalls++
	if s.listErr != nil {
		return nil, s.listErr
	}
	return s.sessions, nil
}

func (s *harnessNativeSpy) SearchSessions(_ context.Context, _ string) (harnessclient.SessionSearchResult, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.searchCalls++
	if s.searchErr != nil {
		return harnessclient.SessionSearchResult{}, s.searchErr
	}
	return s.searchResult, nil
}

func (s *harnessNativeSpy) CallRaw(_ context.Context, method string, args any) (json.RawMessage, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.rawCalls++
	s.rawMethods = append(s.rawMethods, method)
	s.rawArgs = append(s.rawArgs, args)
	if s.rawErr != nil {
		return nil, s.rawErr
	}
	return s.rawValue, nil
}

func (s *harnessNativeSpy) touched() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.listCalls + s.searchCalls + s.rawCalls
}

func (s *harnessNativeSpy) counts() (int, int, int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.listCalls, s.searchCalls, s.rawCalls
}

// harnessNativeFixture 给出一个已授权目录、一个未授权目录和接好 Spy 的 Router。
func harnessNativeFixture(t *testing.T, spy *harnessNativeSpy) (*Router, string, string) {
	t.Helper()
	authorized := t.TempDir()
	unauthorized := t.TempDir()
	registry, err := projects.NewRegistry([]config.ProjectConfig{{
		ID:   "demo",
		Name: "Demo",
		Path: authorized,
	}})
	if err != nil {
		t.Fatal(err)
	}
	router := &Router{
		cfg:      config.Config{DeepSeek: config.DeepSeekConfig{Enabled: true}},
		projects: registry,
		harnessNativeUpstream: func(context.Context) (harnessNativeRPCUpstream, error) {
			return spy, nil
		},
	}
	return router, authorized, unauthorized
}

func harnessNativeSession(id string, cwd string, updatedAt int64, blank bool) harnessclient.SessionSummary {
	return harnessclient.SessionSummary{SessionID: id, CWD: cwd, UpdatedAt: updatedAt, Blank: blank}
}

// harnessNativeEnvelope 是响应的断言用形状。
type harnessNativeEnvelope struct {
	Type   string `json:"type"`
	RPCID  string `json:"rpcId"`
	Result struct {
		OK    bool            `json:"ok"`
		Value json.RawMessage `json:"value"`
		Error *struct {
			Code    string          `json:"code"`
			Message string          `json:"message"`
			Details json.RawMessage `json:"details"`
		} `json:"error"`
	} `json:"result"`
}

func callHarnessNativeRPC(t *testing.T, router *Router, body string, headers map[string]string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/api/harness/rpc", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	for key, value := range headers {
		req.Header.Set(key, value)
	}
	recorder := httptest.NewRecorder()
	router.harnessNativeRPCHandler(recorder, req)
	return recorder
}

func decodeHarnessNativeEnvelope(t *testing.T, recorder *httptest.ResponseRecorder) harnessNativeEnvelope {
	t.Helper()
	if recorder.Code != http.StatusOK {
		t.Fatalf("期望 HTTP 200，得到 %d：%s", recorder.Code, recorder.Body.String())
	}
	var envelope harnessNativeEnvelope
	if err := json.Unmarshal(recorder.Body.Bytes(), &envelope); err != nil {
		t.Fatalf("响应不是合法 JSON：%v（%s）", err, recorder.Body.String())
	}
	return envelope
}

// --- 正向：读链路返回原生结果 ---

func TestHarnessNativeListReturnsOnlyAuthorizedSessions(t *testing.T) {
	spy := &harnessNativeSpy{}
	router, authorized, unauthorized := harnessNativeFixture(t, spy)
	spy.sessions = []harnessclient.SessionSummary{
		harnessNativeSession("in-scope", authorized, 30, false),
		harnessNativeSession("out-of-scope", unauthorized, 40, false),
		harnessNativeSession("no-cwd", "", 50, false),
		harnessNativeSession("blank", authorized, 60, true),
	}

	recorder := callHarnessNativeRPC(t, router, `{"rpcId":"r1","method":"session/list"}`, nil)
	envelope := decodeHarnessNativeEnvelope(t, recorder)

	if !envelope.Result.OK {
		t.Fatalf("列表应成功：%s", recorder.Body.String())
	}
	if envelope.RPCID != "r1" {
		t.Fatalf("必须回传 rpcId，得到 %q", envelope.RPCID)
	}
	if envelope.Type != "server-response" {
		t.Fatalf("外壳必须保持原生形状，得到 %q", envelope.Type)
	}
	var value harnessNativeListValue
	if err := json.Unmarshal(envelope.Result.Value, &value); err != nil {
		t.Fatal(err)
	}
	if len(value.Items) != 1 || value.Items[0].SessionID != "in-scope" {
		t.Fatalf("只应返回授权目录内的非空会话，得到 %+v", value.Items)
	}
	// 原生字段必须保留：序列化后应当出现 sessionId/cwd，而不是 app-server 的 threadId。
	raw := string(envelope.Result.Value)
	for _, needle := range []string{`"sessionId"`, `"cwd"`} {
		if !strings.Contains(raw, needle) {
			t.Fatalf("原生字段 %s 缺失：%s", needle, raw)
		}
	}
	for _, forbidden := range []string{`"threadId"`, `"turns"`, `"items":[{"thread"`} {
		if strings.Contains(raw, forbidden) {
			t.Fatalf("不得产生 app-server 形状 %s：%s", forbidden, raw)
		}
	}
}

func TestHarnessNativeListWithCWDScopesResults(t *testing.T) {
	spy := &harnessNativeSpy{}
	router, authorized, unauthorized := harnessNativeFixture(t, spy)
	child := filepath.Join(authorized, "child")
	if err := os.Mkdir(child, 0o755); err != nil {
		t.Fatal(err)
	}
	alias := filepath.Join(t.TempDir(), "alias")
	if err := os.Symlink(authorized, alias); err != nil {
		t.Fatal(err)
	}
	spy.sessions = []harnessclient.SessionSummary{
		harnessNativeSession("in-scope", authorized, 10, false),
		harnessNativeSession("same-directory-alias", alias, 15, false),
		harnessNativeSession("child-directory", child, 18, false),
		harnessNativeSession("out-of-scope", unauthorized, 20, false),
	}

	body := `{"rpcId":"r2","method":"session/list","cwd":` + strconv.Quote(authorized) + `}`
	recorder := callHarnessNativeRPC(t, router, body, nil)
	envelope := decodeHarnessNativeEnvelope(t, recorder)

	var value harnessNativeListValue
	if err := json.Unmarshal(envelope.Result.Value, &value); err != nil {
		t.Fatal(err)
	}
	if len(value.Items) != 2 || value.Items[0].SessionID != "same-directory-alias" || value.Items[1].SessionID != "in-scope" {
		t.Fatalf("cwd 应只显示当前目录，兼容同一路径的 symlink，不包含子目录：%+v", value.Items)
	}

	// 无 cwd 的受控全局发现仍应包含获授权的子目录，不能被工作区列表规则缩小。
	global := decodeHarnessNativeEnvelope(t, callHarnessNativeRPC(t, router, `{"rpcId":"global","method":"session/list"}`, nil))
	if err := json.Unmarshal(global.Result.Value, &value); err != nil {
		t.Fatal(err)
	}
	if len(value.Items) != 3 || value.Items[0].SessionID != "child-directory" {
		t.Fatalf("全局发现应保留获授权的子目录会话：%+v", value.Items)
	}
}

func TestHarnessNativeListPreservesSubagentIdentity(t *testing.T) {
	spy := &harnessNativeSpy{}
	router, authorized, _ := harnessNativeFixture(t, spy)
	var child harnessclient.SessionSummary
	if err := json.Unmarshal([]byte(`{"sessionId":"child","parentSessionId":"parent","origin":"subagent","cwd":`+strconv.Quote(authorized)+`}`), &child); err != nil {
		t.Fatal(err)
	}
	spy.sessions = []harnessclient.SessionSummary{child}

	recorder := callHarnessNativeRPC(t, router, `{"rpcId":"child-list","method":"session/list"}`, nil)
	envelope := decodeHarnessNativeEnvelope(t, recorder)
	var value harnessNativeListValue
	if err := json.Unmarshal(envelope.Result.Value, &value); err != nil {
		t.Fatal(err)
	}
	if len(value.Items) != 1 || value.Items[0].ParentSessionID != "parent" || value.Items[0].Origin != "subagent" {
		t.Fatalf("子会话身份必须经原生列表保留，得到 %+v", value.Items)
	}
}

func TestHarnessNativeSearchDropsHitsWithoutAuthorizedSummary(t *testing.T) {
	spy := &harnessNativeSpy{}
	router, authorized, unauthorized := harnessNativeFixture(t, spy)
	spy.sessions = []harnessclient.SessionSummary{
		harnessNativeSession("in-scope", authorized, 10, false),
		harnessNativeSession("out-of-scope", unauthorized, 20, false),
	}
	spy.searchResult = harnessclient.SessionSearchResult{Items: []harnessclient.SessionSearchItem{
		{SessionID: "in-scope", Snippet: "visible"},
		{SessionID: "out-of-scope", Snippet: "must-not-leak"},
		{SessionID: "unknown-session", Snippet: "must-not-leak"},
	}}

	recorder := callHarnessNativeRPC(t, router, `{"rpcId":"r3","method":"session/search","args":{"request":{"query":"anything"}}}`, nil)
	envelope := decodeHarnessNativeEnvelope(t, recorder)

	var value harnessNativeSearchResult
	if err := json.Unmarshal(envelope.Result.Value, &value); err != nil {
		t.Fatal(err)
	}
	if len(value.Items) != 1 || value.Items[0].SessionID != "in-scope" {
		t.Fatalf("越权命中必须被丢弃，得到 %+v", value.Items)
	}
	if strings.Contains(recorder.Body.String(), "must-not-leak") {
		t.Fatalf("未授权会话的 snippet 不得出现在响应里：%s", recorder.Body.String())
	}
}

func TestHarnessNativeSearchWithCWDMatchesExactDirectory(t *testing.T) {
	spy := &harnessNativeSpy{}
	router, authorized, _ := harnessNativeFixture(t, spy)
	child := filepath.Join(authorized, "child")
	if err := os.Mkdir(child, 0o755); err != nil {
		t.Fatal(err)
	}
	spy.sessions = []harnessclient.SessionSummary{
		harnessNativeSession("current", authorized, 10, false),
		harnessNativeSession("child", child, 20, false),
	}
	spy.searchResult = harnessclient.SessionSearchResult{Items: []harnessclient.SessionSearchItem{
		{SessionID: "current", Snippet: "visible"},
		{SessionID: "child", Snippet: "not-in-current-directory"},
	}}
	body := `{"rpcId":"exact-search","method":"session/search","cwd":` + strconv.Quote(authorized) + `,"args":{"request":{"query":"anything"}}}`
	envelope := decodeHarnessNativeEnvelope(t, callHarnessNativeRPC(t, router, body, nil))
	var value harnessNativeSearchResult
	if err := json.Unmarshal(envelope.Result.Value, &value); err != nil {
		t.Fatal(err)
	}
	if len(value.Items) != 1 || value.Items[0].SessionID != "current" {
		t.Fatalf("工作区搜索只能返回当前目录会话：%+v", value.Items)
	}
}

func TestHarnessNativeSearchExcludesSubagents(t *testing.T) {
	for _, indexed := range []bool{true, false} {
		name := "local-fallback"
		if indexed {
			name = "upstream-index"
		}
		t.Run(name, func(t *testing.T) {
			spy := &harnessNativeSpy{}
			router, authorized, _ := harnessNativeFixture(t, spy)
			parent := harnessNativeSession("parent", authorized, 10, false)
			parentOnly := harnessNativeSession("parent-only", authorized, 20, false)
			parentOnly.ParentSessionID = "parent"
			originOnly := harnessNativeSession("origin-only", authorized, 30, false)
			originOnly.Origin = "subagent"
			for _, session := range []*harnessclient.SessionSummary{&parent, &parentOnly, &originOnly} {
				session.Projections = &harnessclient.SessionProjectionHints{
					Values: harnessclient.SessionProjectionValue{Title: "parser"},
				}
			}
			spy.sessions = []harnessclient.SessionSummary{parent, parentOnly, originOnly}
			spy.searchResult = harnessclient.SessionSearchResult{Items: []harnessclient.SessionSearchItem{
				{SessionID: "parent", Snippet: "parser"},
				{SessionID: "parent-only", Snippet: "parser child"},
				{SessionID: "origin-only", Snippet: "parser child"},
			}}
			if !indexed {
				spy.searchErr = &harnessclient.RemoteError{Code: "gateway/internal", Message: "search unavailable"}
			}
			body := `{"rpcId":"top-level-search","method":"session/search","cwd":` + strconv.Quote(authorized) + `,"args":{"request":{"query":"parser"}}}`
			envelope := decodeHarnessNativeEnvelope(t, callHarnessNativeRPC(t, router, body, nil))
			var value harnessNativeSearchResult
			if err := json.Unmarshal(envelope.Result.Value, &value); err != nil {
				t.Fatal(err)
			}
			if len(value.Items) != 1 || value.Items[0].SessionID != "parent" {
				t.Fatalf("搜索只能展示顶层会话，得到 %+v", value.Items)
			}
		})
	}
}

func TestHarnessNativeSearchDegradesToLocalMatchWithinAuthorizedList(t *testing.T) {
	spy := &harnessNativeSpy{}
	router, authorized, unauthorized := harnessNativeFixture(t, spy)
	authorizedSession := harnessNativeSession("in-scope", authorized, 10, false)
	authorizedSession.Projections = &harnessclient.SessionProjectionHints{
		Values: harnessclient.SessionProjectionValue{Title: "fix the parser"},
	}
	unauthorizedSession := harnessNativeSession("out-of-scope", unauthorized, 20, false)
	unauthorizedSession.Projections = &harnessclient.SessionProjectionHints{
		Values: harnessclient.SessionProjectionValue{Title: "fix the parser too"},
	}
	spy.sessions = []harnessclient.SessionSummary{authorizedSession, unauthorizedSession}
	// 检索索引未启用：必须按 code 降级，而不是按文案匹配。
	spy.searchErr = &harnessclient.RemoteError{Code: "gateway/internal", Message: "session search is unavailable"}

	recorder := callHarnessNativeRPC(t, router, `{"rpcId":"r4","method":"session/search","args":{"request":{"query":"parser"}}}`, nil)
	envelope := decodeHarnessNativeEnvelope(t, recorder)

	var value harnessNativeSearchResult
	if err := json.Unmarshal(envelope.Result.Value, &value); err != nil {
		t.Fatal(err)
	}
	if len(value.Items) != 1 || value.Items[0].SessionID != "in-scope" {
		t.Fatalf("降级搜索只能在已授权集合内匹配，得到 %+v", value.Items)
	}
}

func TestHarnessNativeSearchUpstreamFailureIsNotHiddenByLocalFallback(t *testing.T) {
	spy := &harnessNativeSpy{}
	router, authorized, _ := harnessNativeFixture(t, spy)
	spy.sessions = []harnessclient.SessionSummary{harnessNativeSession("in-scope", authorized, 10, false)}
	// 非"索引未启用"的上游错误：必须如实上报，不能拿本地匹配盖过去。
	spy.searchErr = &harnessclient.RemoteError{Code: "gateway/arguments-invalid", Message: "bad request"}

	recorder := callHarnessNativeRPC(t, router, `{"rpcId":"r5","method":"session/search","args":{"request":{"query":"x"}}}`, nil)
	envelope := decodeHarnessNativeEnvelope(t, recorder)

	if envelope.Result.OK {
		t.Fatalf("上游业务错误必须如实上报：%s", recorder.Body.String())
	}
	if envelope.Result.Error == nil || envelope.Result.Error.Code != "gateway/arguments-invalid" {
		t.Fatalf("错误码必须原样保留：%s", recorder.Body.String())
	}
}

func TestHarnessNativePageRelaysNativeRecordsVerbatim(t *testing.T) {
	spy := &harnessNativeSpy{}
	router, authorized, _ := harnessNativeFixture(t, spy)
	spy.sessions = []harnessclient.SessionSummary{harnessNativeSession("s1", authorized, 10, false)}
	// 页里带上中继未建模的字段，用来证明透传没有二次编解码。
	spy.rawValue = json.RawMessage(`{"records":[{"type":"event","event":{"type":"turn/start","seq":1,"time":2,"data":{"turn":1}},"extraKey":{"nested":true}}],"hasMore":false}`)

	body := `{"rpcId":"r6","method":"session/page","args":{"request":{"address":{"kind":"session","sessionId":"s1"},"throughSeq":16}}}`
	recorder := callHarnessNativeRPC(t, router, body, nil)
	envelope := decodeHarnessNativeEnvelope(t, recorder)

	if string(envelope.Result.Value) != string(spy.rawValue) {
		t.Fatalf("page 必须原样透传上游结果\n得到：%s\n期望：%s", envelope.Result.Value, spy.rawValue)
	}
	if !strings.Contains(string(envelope.Result.Value), "extraKey") {
		t.Fatal("未建模字段必须保留，否则就是有损的二次编解码")
	}
	_, _, rawCalls := spy.counts()
	if rawCalls != 1 {
		t.Fatalf("应当转发一次 session/page，得到 %d", rawCalls)
	}
	if spy.rawMethods[0] != harnessclient.MethodSessionPage {
		t.Fatalf("转发方法名错误：%s", spy.rawMethods[0])
	}
	forwarded, ok := spy.rawArgs[0].(map[string]any)
	if !ok {
		t.Fatalf("转发参数形状错误：%T", spy.rawArgs[0])
	}
	request, ok := forwarded["request"].(map[string]any)
	if !ok {
		t.Fatalf("转发参数缺少 request：%+v", forwarded)
	}
	if request["throughSeq"] != int64(16) {
		t.Fatalf("throughSeq 必须原样转发（snapshot 契约）：%+v", request)
	}
	if _, exists := request["beforeSeq"]; exists {
		t.Fatalf("客户端未提供 beforeSeq 时不得转发零值，否则 Harness 会返回空页：%+v", request)
	}
	if _, exists := request["maxMessages"]; exists {
		t.Fatalf("客户端未提供 maxMessages 时不得伪造零值：%+v", request)
	}

	boundedBody := `{"rpcId":"r6-bounded","method":"session/page","args":{"request":{"address":{"kind":"session","sessionId":"s1"},"throughSeq":16,"beforeSeq":9,"maxMessages":4}}}`
	boundedRecorder := callHarnessNativeRPC(t, router, boundedBody, nil)
	decodeHarnessNativeEnvelope(t, boundedRecorder)
	boundedForwarded := spy.rawArgs[1].(map[string]any)
	boundedRequest := boundedForwarded["request"].(map[string]any)
	if boundedRequest["beforeSeq"] != int64(9) || boundedRequest["maxMessages"] != 4 {
		t.Fatalf("客户端提供的分页边界必须原样转发：%+v", boundedRequest)
	}
}

func TestHarnessNativeModelCatalogRelaysNativeValue(t *testing.T) {
	spy := &harnessNativeSpy{}
	router, _, _ := harnessNativeFixture(t, spy)
	spy.rawValue = json.RawMessage(`{"default":{"provider":"p","model":"m"},"groups":[{"id":"p","models":[{"id":"m"}]}]}`)

	recorder := callHarnessNativeRPC(t, router, `{"rpcId":"r7","method":"session/modelCatalog"}`, nil)
	envelope := decodeHarnessNativeEnvelope(t, recorder)

	if string(envelope.Result.Value) != string(spy.rawValue) {
		t.Fatalf("模型目录必须原样透传：%s", envelope.Result.Value)
	}
}

// --- 负向：本地拒绝且不触达 Harness ---

// 未开放的方法必须被拒且不触达上游。
//
// H07 之前这里也包含四个写方法；写路径开放后它们**不再是"被拒"**，
// 而是转入各自的正向/负向用例（见 harness_native_h07_write_test.go）：
// 参数非法时同样是 4xx 且不触达上游，但授权通过时必须有转发。
// 因此这里只保留"经这条 RPC 通道永不开放"的方法——它们的共同点是
// 必须走流载体，或属于中继未实现的能力。
func TestHarnessNativeRejectsNonReadOnlyMethodsWithoutTouchingHarness(t *testing.T) {
	for _, method := range []string{
		"session/follow",
		"$events",
		"$events/result",
		"session/listExtra",
		"workspace/create",
		"session/updateQueue",
	} {
		spy := &harnessNativeSpy{}
		router, _, _ := harnessNativeFixture(t, spy)
		body := `{"rpcId":"r8","method":` + strconv.Quote(method) + `}`
		recorder := callHarnessNativeRPC(t, router, body, nil)
		if recorder.Code != http.StatusForbidden {
			t.Fatalf("%s 必须被拒，得到 %d", method, recorder.Code)
		}
		if spy.touched() != 0 {
			t.Fatalf("%s 被拒后不得访问 Harness，实际交互 %d 次", method, spy.touched())
		}
	}
}

func TestHarnessNativeRejectsArbitraryOriginWithoutTouchingHarness(t *testing.T) {
	spy := &harnessNativeSpy{}
	router, _, _ := harnessNativeFixture(t, spy)

	recorder := callHarnessNativeRPC(t, router, `{"rpcId":"r9","method":"session/list"}`,
		map[string]string{"Origin": "https://evil.example"})
	if recorder.Code != http.StatusForbidden {
		t.Fatalf("跨站 origin 必须被拒，得到 %d", recorder.Code)
	}
	if spy.touched() != 0 {
		t.Fatalf("被拒请求不得访问 Harness，实际交互 %d 次", spy.touched())
	}
}

func TestHarnessNativeRejectsUnauthorizedAndTraversalCWDWithoutTouchingHarness(t *testing.T) {
	spy := &harnessNativeSpy{}
	router, authorized, unauthorized := harnessNativeFixture(t, spy)

	for _, cwd := range []string{
		unauthorized,
		authorized + "/../../etc",
		"/etc",
		"/",
	} {
		body := `{"rpcId":"r10","method":"session/list","cwd":` + strconv.Quote(cwd) + `}`
		recorder := callHarnessNativeRPC(t, router, body, nil)
		if recorder.Code != http.StatusForbidden {
			t.Fatalf("未授权 cwd %q 必须被拒，得到 %d", cwd, recorder.Code)
		}
	}
	if spy.touched() != 0 {
		t.Fatalf("被拒请求不得访问 Harness，实际交互 %d 次", spy.touched())
	}
}

func TestHarnessNativeRejectsOversizedBodyWithoutTouchingHarness(t *testing.T) {
	spy := &harnessNativeSpy{}
	router, _, _ := harnessNativeFixture(t, spy)

	big := strings.Repeat("a", int(harnessNativeRPCRequestBodyMaxBytes)+1024)
	recorder := callHarnessNativeRPC(t, router, `{"rpcId":"r11","method":"session/list","args":{"_request":{"cursor":"`+big+`"}}}`, nil)
	if recorder.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("超大 body 必须被拒，得到 %d", recorder.Code)
	}
	if spy.touched() != 0 {
		t.Fatalf("被拒请求不得访问 Harness，实际交互 %d 次", spy.touched())
	}
}

func TestHarnessNativeRejectsUnknownFieldsWithoutTouchingHarness(t *testing.T) {
	for _, body := range []string{
		// 顶层未知字段
		`{"rpcId":"r12","method":"session/list","targetSession":"other"}`,
		// 参数里的未知字段：可能改写上游解析结果，必须 fail closed
		`{"rpcId":"r12","method":"session/list","args":{"_request":{"cursor":"c"},"cwd":"/tmp"}}`,
		`{"rpcId":"r12","method":"session/page","args":{"request":{"address":{"kind":"session","sessionId":"s"},"throughSeq":1,"threadId":"other"}}}`,
		`{"rpcId":"r12","method":"session/modelCatalog","args":{"extra":1}}`,
		// page 不接受 cwd：它不能改变授权结果，认下只会多一个可试探入口
		`{"rpcId":"r12","method":"session/page","cwd":"/tmp"}`,
	} {
		spy := &harnessNativeSpy{}
		router, _, _ := harnessNativeFixture(t, spy)
		recorder := callHarnessNativeRPC(t, router, body, nil)
		if recorder.Code != http.StatusBadRequest {
			t.Fatalf("未知字段必须被拒：%s -> %d", body, recorder.Code)
		}
		if spy.touched() != 0 {
			t.Fatalf("被拒请求不得访问 Harness：%s", body)
		}
	}
}

func TestHarnessNativeRejectsInvalidCursorWithoutTouchingHarness(t *testing.T) {
	for _, body := range []string{
		// 缺 throughSeq：网关会判非法，本地先拒
		`{"rpcId":"r13","method":"session/page","args":{"request":{"address":{"kind":"session","sessionId":"s1"}}}}`,
		// 负游标
		`{"rpcId":"r13","method":"session/page","args":{"request":{"address":{"kind":"session","sessionId":"s1"},"throughSeq":-1}}}`,
		// 缺目标会话
		`{"rpcId":"r13","method":"session/page","args":{"request":{"address":{"kind":"session"},"throughSeq":1}}}`,
		// subagent 形态首版不开放
		`{"rpcId":"r13","method":"session/page","args":{"request":{"address":{"kind":"subagent","sessionId":"s1"},"throughSeq":1}}}`,
	} {
		spy := &harnessNativeSpy{}
		router, _, _ := harnessNativeFixture(t, spy)
		recorder := callHarnessNativeRPC(t, router, body, nil)
		if recorder.Code != http.StatusBadRequest {
			t.Fatalf("无效游标/目标必须被拒：%s -> %d", body, recorder.Code)
		}
		if spy.touched() != 0 {
			t.Fatalf("被拒请求不得访问 Harness：%s", body)
		}
	}
}

func TestHarnessNativeRejectsForgedOrRevokedSessionWithoutForwarding(t *testing.T) {
	spy := &harnessNativeSpy{}
	router, authorized, unauthorized := harnessNativeFixture(t, spy)
	spy.sessions = []harnessclient.SessionSummary{
		harnessNativeSession("visible", authorized, 10, false),
		harnessNativeSession("revoked", unauthorized, 20, false),
	}

	for _, sessionID := range []string{"revoked", "never-existed"} {
		body := `{"rpcId":"r14","method":"session/page","args":{"request":{"address":{"kind":"session","sessionId":` +
			strconv.Quote(sessionID) + `},"throughSeq":16}}}`
		recorder := callHarnessNativeRPC(t, router, body, nil)
		if recorder.Code != http.StatusForbidden {
			t.Fatalf("%s 必须被拒，得到 %d", sessionID, recorder.Code)
		}
	}
	// 授权判定本身需要读列表（这是允许的），但被拒的目标绝不能转发出去。
	_, _, rawCalls := spy.counts()
	if rawCalls != 0 {
		t.Fatalf("被拒的 page 不得转发到 Harness，实际转发 %d 次", rawCalls)
	}
}

func TestHarnessNativeRejectsMissingRPCIDAndBadMethod(t *testing.T) {
	spy := &harnessNativeSpy{}
	router, _, _ := harnessNativeFixture(t, spy)

	if recorder := callHarnessNativeRPC(t, router, `{"method":"session/list"}`, nil); recorder.Code != http.StatusBadRequest {
		t.Fatalf("缺 rpcId 必须被拒，得到 %d", recorder.Code)
	}
	req := httptest.NewRequest(http.MethodGet, "/api/harness/rpc", nil)
	recorder := httptest.NewRecorder()
	router.harnessNativeRPCHandler(recorder, req)
	if recorder.Code != http.StatusMethodNotAllowed {
		t.Fatalf("非 POST 必须被拒，得到 %d", recorder.Code)
	}
	if spy.touched() != 0 {
		t.Fatalf("被拒请求不得访问 Harness，实际交互 %d 次", spy.touched())
	}
}

func TestHarnessNativeRejectsMalformedJSON(t *testing.T) {
	spy := &harnessNativeSpy{}
	router, _, _ := harnessNativeFixture(t, spy)

	for _, body := range []string{`{`, `{"rpcId":"r","method":"session/list"} {"rpcId":"r"}`} {
		recorder := callHarnessNativeRPC(t, router, body, nil)
		if recorder.Code != http.StatusBadRequest {
			t.Fatalf("畸形 JSON 必须被拒：%s -> %d", body, recorder.Code)
		}
	}
	if spy.touched() != 0 {
		t.Fatalf("被拒请求不得访问 Harness，实际交互 %d 次", spy.touched())
	}
}

// --- 上游失败语义 ---

func TestHarnessNativeUpstreamBusinessFailureKeepsHTTP200AndNativeError(t *testing.T) {
	spy := &harnessNativeSpy{}
	router, authorized, _ := harnessNativeFixture(t, spy)
	spy.sessions = []harnessclient.SessionSummary{harnessNativeSession("s1", authorized, 10, false)}
	spy.rawErr = &harnessclient.RemoteError{
		Code:    "session/agent-busy",
		Message: "prompt rejected",
		Details: json.RawMessage(`{"reason":"busy"}`),
	}

	body := `{"rpcId":"r15","method":"session/page","args":{"request":{"address":{"kind":"session","sessionId":"s1"},"throughSeq":16}}}`
	recorder := callHarnessNativeRPC(t, router, body, nil)
	// 业务失败仍是 HTTP 200：客户端必须按 result.ok 判定，与直连 Harness 一致。
	envelope := decodeHarnessNativeEnvelope(t, recorder)
	if envelope.Result.OK {
		t.Fatal("ok=false 必须是失败")
	}
	if envelope.Result.Error == nil {
		t.Fatal("必须带 error 外壳")
	}
	if envelope.Result.Error.Code != "session/agent-busy" {
		t.Fatalf("错误码必须原样保留：%+v", envelope.Result.Error)
	}
	if !strings.Contains(string(envelope.Result.Error.Details), "busy") {
		t.Fatalf("details 必须保留（wire 名是 details 不是 data）：%+v", envelope.Result.Error)
	}
	if envelope.RPCID != "r15" {
		t.Fatalf("失败响应同样要回传 rpcId，得到 %q", envelope.RPCID)
	}
}

func TestHarnessNativeTransportFailureIsBadGateway(t *testing.T) {
	spy := &harnessNativeSpy{}
	router, _, _ := harnessNativeFixture(t, spy)
	spy.listErr = context.DeadlineExceeded

	recorder := callHarnessNativeRPC(t, router, `{"rpcId":"r16","method":"session/list"}`, nil)
	if recorder.Code != http.StatusBadGateway {
		t.Fatalf("传输层失败必须是 502，得到 %d", recorder.Code)
	}
	if strings.Contains(strings.ToLower(recorder.Body.String()), "token") {
		t.Fatalf("响应不得泄露凭据相关字面量：%s", recorder.Body.String())
	}
}

func TestHarnessNativeReportsUnavailableWhenRuntimeDisabled(t *testing.T) {
	registry, err := projects.NewRegistry([]config.ProjectConfig{{ID: "demo", Name: "Demo", Path: t.TempDir()}})
	if err != nil {
		t.Fatal(err)
	}
	// 不注入 Spy：走生产分支，runtime 未启用时必须显式失败而不是空成功。
	router := &Router{cfg: config.Config{DeepSeek: config.DeepSeekConfig{Enabled: false}}, projects: registry}

	recorder := callHarnessNativeRPC(t, router, `{"rpcId":"r17","method":"session/list"}`, nil)
	if recorder.Code != http.StatusServiceUnavailable {
		t.Fatalf("runtime 未启用必须是 503，得到 %d", recorder.Code)
	}
}

// --- 路由接线 ---

func TestHarnessNativeRouteIsRegisteredAndRequiresAuth(t *testing.T) {
	server := newTestServer(t)

	// 无 token：必须被认证边界挡住，而不是落到 404（那说明路由没接上）。
	request := httptest.NewRequest(http.MethodPost, "/api/harness/rpc", strings.NewReader(`{"rpcId":"r18","method":"session/list"}`))
	recorder := httptest.NewRecorder()
	server.handler.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusUnauthorized {
		t.Fatalf("未认证的中继请求必须 401，得到 %d", recorder.Code)
	}

	// 带 token：路由存在，进到处理器（runtime 未配置时给出明确失败而不是 404）。
	authed := httptest.NewRequest(http.MethodPost, "/api/harness/rpc", strings.NewReader(`{"rpcId":"r18","method":"session/list"}`))
	authed.Header.Set("Authorization", "Bearer "+testToken)
	authedRecorder := httptest.NewRecorder()
	server.handler.ServeHTTP(authedRecorder, authed)
	if authedRecorder.Code == http.StatusUnauthorized || authedRecorder.Code == http.StatusNotFound {
		t.Fatalf("已认证请求必须进入中继处理器，得到 %d：%s", authedRecorder.Code, authedRecorder.Body.String())
	}
}

// --- 凭据不外泄 ---
//
// 验收要求"上游 Cookie/Set-Cookie/token 不返回、不入日志"。上面所有用例都注入了
// harnessNativeUpstream 替身，因此**没有一条**真正走过"启动 token 换 Cookie"的链路；
// 这条约束只能靠真实上游来证。下面两个用例刻意不用替身，让 harnessclient 打真实的
// httptest 服务，从而覆盖三个泄露面：响应头（Set-Cookie）、响应体、以及日志。

// harnessNativeCredentialFixture 是不注入替身的 Router：中继会自己读 token 文件、
// 认证、调用上游。这是唯一能观察到真实凭据流向的装配方式。
func harnessNativeCredentialFixture(t *testing.T, baseURL string, tokenFile string) *Router {
	t.Helper()
	authorized := t.TempDir()
	registry, err := projects.NewRegistry([]config.ProjectConfig{{
		ID:   "demo",
		Name: "Demo",
		Path: authorized,
	}})
	if err != nil {
		t.Fatal(err)
	}
	return &Router{
		cfg: config.Config{DeepSeek: config.DeepSeekConfig{
			Enabled:   true,
			BaseURL:   baseURL,
			TokenFile: tokenFile,
		}},
		projects: registry,
	}
}

func harnessNativeWriteTokenFile(t *testing.T, token string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "harness-token")
	if err := os.WriteFile(path, []byte(token), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

// captureHarnessNativeLogs 把标准日志改道到内存，返回可读的缓冲。
// 必须在调用中继之前调用，否则会漏掉上游交互期间产生的行。
func captureHarnessNativeLogs(t *testing.T) *bytes.Buffer {
	t.Helper()
	buffer := &bytes.Buffer{}
	previous := log.Writer()
	log.SetOutput(buffer)
	t.Cleanup(func() { log.SetOutput(previous) })
	return buffer
}

func TestHarnessNativeRelayNeverReturnsUpstreamCredentials(t *testing.T) {
	const (
		startToken     = "start-token-SECRET-9f2c4a"
		upstreamCookie = "upstream-cookie-SECRET-41ab"
		rotatedCookie  = "rotated-cookie-SECRET-77de"
	)
	logs := captureHarnessNativeLogs(t)

	mux := http.NewServeMux()
	// 认证握手：token 走查询串，回 303 + Set-Cookie。
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("token") != startToken {
			http.Error(w, "bad token", http.StatusUnauthorized)
			return
		}
		http.SetCookie(w, &http.Cookie{Name: "harness_session", Value: upstreamCookie, Path: "/"})
		w.Header().Set("Location", "/")
		w.WriteHeader(http.StatusSeeOther)
	})
	mux.HandleFunc("/api/session/modelCatalog", func(w http.ResponseWriter, r *http.Request) {
		// 先证明中继确实带着换来的 Cookie 到了上游。缺了这一步，"没有泄露"可能
		// 只是因为压根没认证成功——那样的绿灯毫无意义。
		cookie, err := r.Cookie("harness_session")
		if err != nil || cookie.Value != upstreamCookie {
			http.Error(w, "missing cookie", http.StatusUnauthorized)
			return
		}
		// 上游在业务响应上再下发一次 Cookie：中继不得把它转发给移动端。
		http.SetCookie(w, &http.Cookie{Name: "rotated", Value: rotatedCookie, Path: "/"})
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"type":"server-response","rpcId":"up-1","result":{"ok":true,"value":{"models":[{"id":"native-model"}]}}}`))
	})
	server := httptest.NewServer(mux)
	defer server.Close()

	router := harnessNativeCredentialFixture(t, server.URL, harnessNativeWriteTokenFile(t, startToken))
	recorder := callHarnessNativeRPC(t, router, `{"rpcId":"leak-1","method":"session/modelCatalog"}`, nil)

	envelope := decodeHarnessNativeEnvelope(t, recorder)
	if !envelope.Result.OK {
		t.Fatalf("读链路应成功，得到 %s", recorder.Body.String())
	}
	if !strings.Contains(string(envelope.Result.Value), "native-model") {
		t.Fatalf("原生 value 必须原样下发，得到 %s", envelope.Result.Value)
	}

	// 泄露面一：响应头。Set-Cookie 是浏览器会自动吸收的凭据载体，绝不能出现在中继响应上。
	if values := recorder.Result().Header.Values("Set-Cookie"); len(values) != 0 {
		t.Fatalf("中继响应不得携带 Set-Cookie，得到 %v", values)
	}
	// 泄露面二：响应体。
	body := recorder.Body.String()
	for name, secret := range map[string]string{
		"启动 token":    startToken,
		"上游 Cookie":   upstreamCookie,
		"上游轮换 Cookie": rotatedCookie,
	} {
		if strings.Contains(body, secret) {
			t.Fatalf("响应体不得含%s：%s", name, body)
		}
	}
	// 泄露面三：日志。
	logText := logs.String()
	for name, secret := range map[string]string{
		"启动 token":    startToken,
		"上游 Cookie":   upstreamCookie,
		"上游轮换 Cookie": rotatedCookie,
	} {
		if strings.Contains(logText, secret) {
			t.Fatalf("日志不得含%s：%s", name, logText)
		}
	}
}

func TestHarnessNativeRelayNeverLogsCredentialsWhenUpstreamUnreachable(t *testing.T) {
	// 这是最容易漏的一条：认证请求把启动 token 放在查询串上，而 net/http 的传输层
	// 错误（*url.Error）会把**完整 URL** 包进错误文本。关掉一个已建连的服务拿到
	// "端口确定无人监听"的地址，就能稳定复现这条路径。
	dead := httptest.NewServer(http.NotFoundHandler())
	deadURL := dead.URL
	dead.Close()

	const startToken = "start-token-SECRET-deadbeef"
	logs := captureHarnessNativeLogs(t)
	tokenFile := harnessNativeWriteTokenFile(t, startToken)

	router := harnessNativeCredentialFixture(t, deadURL, tokenFile)
	recorder := callHarnessNativeRPC(t, router, `{"rpcId":"leak-2","method":"session/list"}`, nil)

	if recorder.Code != http.StatusBadGateway {
		t.Fatalf("上游不可达必须是 502，得到 %d：%s", recorder.Code, recorder.Body.String())
	}
	body := recorder.Body.String()
	if strings.Contains(body, startToken) {
		t.Fatalf("回给移动端的错误不得含启动 token：%s", body)
	}
	// 本机路径属于脱敏范围（AGENTS.md 的写入边界），也不该下发给移动端。
	if strings.Contains(body, tokenFile) || strings.Contains(body, filepath.Dir(tokenFile)) {
		t.Fatalf("回给移动端的错误不得含本机 token 路径：%s", body)
	}

	logText := logs.String()
	// 先确认确实捕获到了这条路径的日志，否则"日志里没有 secret"是空断言。
	if !strings.Contains(logText, "harness native rpc") {
		t.Fatalf("未捕获到中继的失败日志，无法证明脱敏：%q", logText)
	}
	if strings.Contains(logText, startToken) {
		t.Fatalf("日志不得含启动 token：%s", logText)
	}
	if strings.Contains(logText, "token=") {
		t.Fatalf("日志不得残留带 token 的认证 URL：%s", logText)
	}
}
