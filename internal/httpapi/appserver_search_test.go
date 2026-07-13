package httpapi

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gorilla/websocket"
)

func TestAppServerGatewayThreadSearchParamsAreStrictlyRebuilt(t *testing.T) {
	if _, ok := appServerAllowedMethods["thread/search"]; !ok {
		t.Fatal("Codex gateway allowlist 应包含 thread/search")
	}
	valid := map[string]any{
		"searchTerm":    "  发布检查  ",
		"cursor":        "opaque-cursor",
		"limit":         json.Number("20"),
		"sortDirection": "asc",
		"sortKey":       "recency_at",
		"archived":      true,
		"sourceKinds":   []any{"cli", "appServer", "subAgentReview"},
		"unknown":       map[string]any{"approvalPolicy": "never", "secret": "must-drop"},
	}
	if err := validateGatewayThreadSearchParams(valid); err != nil {
		t.Fatalf("0.144.2 合法 search params 不应被拒绝：%v", err)
	}
	safe := sanitizedGatewayThreadSearchParams(valid)
	assertGatewayParamsOnly(t, safe, "searchTerm", "cursor", "limit", "sortDirection", "sortKey", "archived", "sourceKinds")
	if safe["searchTerm"] != "发布检查" {
		t.Fatalf("searchTerm 应 trim 后转发：%v", safe)
	}
	if _, exists := safe["unknown"]; exists {
		t.Fatalf("未知参数必须剔除，不能透传任意 JSON：%v", safe)
	}
	if err := validateGatewayThreadSearchParams(map[string]any{"searchTerm": "x", "limit": json.Number("0"), "cursor": ""}); err != nil {
		t.Fatalf("0.144.2 schema 允许 uint32 limit=0 与空字符串 cursor：%v", err)
	}

	cases := []struct {
		name   string
		params map[string]any
		want   string
	}{
		{name: "missing term", params: map[string]any{}, want: "searchTerm"},
		{name: "blank term", params: map[string]any{"searchTerm": " \n "}, want: "非空字符串"},
		{name: "term too long", params: map[string]any{"searchTerm": strings.Repeat("a", appServerGatewayThreadSearchTermMaxBytes+1)}, want: "不能超过"},
		{name: "negative limit", params: map[string]any{"searchTerm": "x", "limit": json.Number("-1")}, want: "非负整数"},
		{name: "limit over max", params: map[string]any{"searchTerm": "x", "limit": json.Number("51")}, want: "不能超过 50"},
		{name: "cursor not string", params: map[string]any{"searchTerm": "x", "cursor": 1}, want: "cursor 必须是字符串"},
		{name: "bad sort direction", params: map[string]any{"searchTerm": "x", "sortDirection": "newest"}, want: "sortDirection 不支持"},
		{name: "bad sort key", params: map[string]any{"searchTerm": "x", "sortKey": "score"}, want: "sortKey 不支持"},
		{name: "bad archived", params: map[string]any{"searchTerm": "x", "archived": "true"}, want: "archived 必须是布尔值"},
		{name: "source kinds not array", params: map[string]any{"searchTerm": "x", "sourceKinds": "cli"}, want: "字符串数组"},
		{name: "unknown source kind", params: map[string]any{"searchTerm": "x", "sourceKinds": []any{"mobile"}}, want: "sourceKinds 不支持"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if err := validateGatewayThreadSearchParams(tc.params); err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("非法参数应包含 %q，got=%v", tc.want, err)
			}
		})
	}
}

func TestAppServerGatewayThreadSearchFiltersScopesAndRegistersVisibleThreads(t *testing.T) {
	policy, projectDir, browseDir := newThreadSearchPolicy(t)
	outsideDir := t.TempDir()
	request := []byte(`{"jsonrpc":"2.0","id":1,"method":"thread/search","params":{` +
		`"searchTerm":"  release  ","cursor":"request-cursor","limit":2,"sortDirection":"desc",` +
		`"sortKey":"updated_at","archived":false,"sourceKinds":["cli","appServer"],"unknown":"drop-me"}}`)
	forwardedRequest, policyErr := policy.validateClientFrame(websocket.TextMessage, request)
	if policyErr != nil {
		t.Fatalf("合法 thread/search 请求不应被拒绝：%+v", policyErr)
	}
	params := decodeGatewayParamsForTest(t, forwardedRequest)
	assertGatewayParamsOnly(t, params, "searchTerm", "cursor", "limit", "sortDirection", "sortKey", "archived", "sourceKinds")
	if params["searchTerm"] != "release" || params["cursor"] != "request-cursor" {
		t.Fatalf("重建后的 search params 异常：%v", params)
	}

	response := map[string]any{
		"jsonrpc": "2.0",
		"id":      1,
		"result": map[string]any{
			"data": []any{
				map[string]any{"snippet": "outside-snippet-secret", "thread": map[string]any{"id": "outside-thread", "cwd": outsideDir, "preview": "outside-preview-secret"}},
				map[string]any{"snippet": "allowed-project-snippet", "thread": map[string]any{"id": "project-thread", "cwd": projectDir, "preview": "allowed-project"}, "unknown": "item-extra-secret"},
				map[string]any{"snippet": "missing-cwd-snippet-secret", "thread": map[string]any{"id": "missing-cwd-thread", "preview": "missing-cwd-preview-secret"}},
				map[string]any{"snippet": "malformed-cwd-snippet-secret", "thread": map[string]any{"id": "malformed-cwd-thread", "cwd": 123}},
				map[string]any{"snippet": "relative-cwd-snippet-secret", "thread": map[string]any{"id": "relative-cwd-thread", "cwd": "relative/workspace"}},
				map[string]any{"snippet": "allowed-browse-snippet", "thread": map[string]any{"id": "browse-thread", "cwd": browseDir, "preview": "allowed-browse"}},
				map[string]any{"snippet": "over-limit-snippet-secret", "thread": map[string]any{"id": "over-limit-thread", "cwd": projectDir, "preview": "over-limit-preview-secret"}},
			},
			"nextCursor":      "next-page-cursor",
			"backwardsCursor": "previous-page-cursor",
			"unknown":         "result-root-secret",
		},
		"unknown": "response-root-secret",
	}
	rawResponse, err := json.Marshal(response)
	if err != nil {
		t.Fatal(err)
	}
	forwardedResponse, forward, upstreamPolicyErr := policy.observeUpstreamFrame(websocket.TextMessage, rawResponse)
	if upstreamPolicyErr != nil || !forward {
		t.Fatalf("混合权限 search response 应过滤后转发：forward=%v err=%+v", forward, upstreamPolicyErr)
	}
	for _, secret := range []string{
		"outside-snippet-secret", "outside-preview-secret", "missing-cwd-snippet-secret", "missing-cwd-preview-secret",
		"malformed-cwd-snippet-secret", "relative-cwd-snippet-secret", "over-limit-snippet-secret", "over-limit-preview-secret",
		"item-extra-secret", "result-root-secret", "response-root-secret",
	} {
		if bytes.Contains(forwardedResponse, []byte(secret)) {
			t.Fatalf("过滤后的搜索响应泄漏了 %q：%s", secret, forwardedResponse)
		}
	}
	var decoded struct {
		Result struct {
			Data []struct {
				Snippet string `json:"snippet"`
				Thread  struct {
					ID  string `json:"id"`
					CWD string `json:"cwd"`
				} `json:"thread"`
			} `json:"data"`
			NextCursor      string `json:"nextCursor"`
			BackwardsCursor string `json:"backwardsCursor"`
		} `json:"result"`
	}
	if err := json.Unmarshal(forwardedResponse, &decoded); err != nil {
		t.Fatal(err)
	}
	if len(decoded.Result.Data) != 2 || decoded.Result.Data[0].Thread.ID != "project-thread" || decoded.Result.Data[1].Thread.ID != "browse-thread" {
		t.Fatalf("只应保留前两个有授权 cwd 的搜索结果：%s", forwardedResponse)
	}
	if decoded.Result.NextCursor != "next-page-cursor" || decoded.Result.BackwardsCursor != "previous-page-cursor" {
		t.Fatalf("合法 pagination cursor 必须保留：%+v", decoded.Result)
	}

	for _, threadID := range []string{"project-thread", "browse-thread"} {
		if _, ok := policy.allowedThread(threadID); !ok {
			t.Fatalf("可见搜索结果必须进入 allowed thread registry：%s", threadID)
		}
		if _, ok := policy.router.gatewayThread("codex", threadID); !ok {
			t.Fatalf("可见搜索结果必须进入跨连接 gateway registry：%s", threadID)
		}
	}
	for _, threadID := range []string{"outside-thread", "missing-cwd-thread", "malformed-cwd-thread", "relative-cwd-thread", "over-limit-thread"} {
		if _, ok := policy.allowedThread(threadID); ok {
			t.Fatalf("被过滤或超出响应 limit 的 thread 不能进入 registry：%s", threadID)
		}
	}
	reconnected := &appServerGatewayPolicy{
		router:                policy.router,
		runtimeID:             "codex",
		pendingThreads:        map[string]appServerGatewayPendingThreadRequest{},
		pendingServerRequests: map[string]appServerGatewayPendingServerRequest{},
		pendingHistory:        map[string]appServerGatewayPendingHistoryRequest{},
		historyBudgets:        map[string]appServerGatewayHistoryBudget{},
		allowedThreads:        map[string]appServerGatewayAllowedThread{},
	}
	if _, err := reconnected.validateClientFrame(websocket.TextMessage, []byte(`{"id":2,"method":"thread/read","params":{"threadId":"project-thread","includeTurns":false}}`)); err != nil {
		t.Fatalf("搜索登记后的 thread/read 应可用：%+v", err)
	}
	resume := []byte(fmt.Sprintf(`{"id":3,"method":"thread/resume","params":{"threadId":"project-thread","cwd":%q}}`, projectDir))
	if _, err := reconnected.validateClientFrame(websocket.TextMessage, resume); err != nil {
		t.Fatalf("搜索登记后的 thread/resume 应可用：%+v", err)
	}
	if _, err := policy.validateClientFrame(websocket.TextMessage, []byte(`{"id":4,"method":"thread/read","params":{"threadId":"outside-thread"}}`)); err == nil {
		t.Fatal("越权搜索结果不能获得后续 thread/read 权限")
	}
}

func TestAppServerGatewayThreadSearchUsesHistoryResponseCap(t *testing.T) {
	oldCap := appServerGatewayHistoryResponseCapBytes
	appServerGatewayHistoryResponseCapBytes = 512
	t.Cleanup(func() { appServerGatewayHistoryResponseCapBytes = oldCap })

	policy, projectDir, _ := newThreadSearchPolicy(t)
	request := []byte(`{"id":11,"method":"thread/search","params":{"searchTerm":"large","limit":1}}`)
	if _, policyErr := policy.validateClientFrame(websocket.TextMessage, request); policyErr != nil {
		t.Fatalf("合法 search 请求不应被拒绝：%+v", policyErr)
	}
	response := []byte(fmt.Sprintf(
		`{"id":11,"result":{"data":[{"snippet":%q,"thread":{"id":"large-thread","cwd":%q}}]}}`,
		strings.Repeat("x", 1024), projectDir,
	))
	_, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, response)
	if forward || policyErr == nil || !policyErr.historyResponseBlocked {
		t.Fatalf("thread/search 必须复用 history response cap：forward=%v err=%+v", forward, policyErr)
	}
	if policyErr.data["method"] != "thread/search" || policyErr.data["reason"] != "history_response_too_large" {
		t.Fatalf("search cap 错误应带稳定原因和 method：%+v", policyErr.data)
	}
	if _, ok := policy.allowedThread("large-thread"); ok {
		t.Fatal("被 response cap 阻断的 thread 不能进入 registry")
	}
}

func TestAppServerGatewayThreadSearchRejectsMalformedResponse(t *testing.T) {
	policy, _, _ := newThreadSearchPolicy(t)
	request := []byte(`{"id":21,"method":"thread/search","params":{"searchTerm":"malformed"}}`)
	if _, policyErr := policy.validateClientFrame(websocket.TextMessage, request); policyErr != nil {
		t.Fatalf("合法 search 请求不应被拒绝：%+v", policyErr)
	}
	malformed := []byte(`{"id":21,"result":{"data":{"snippet":"must-not-forward"},"nextCursor":"next"}}`)
	_, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, malformed)
	if forward || policyErr == nil || policyErr.target != "client" || !strings.Contains(policyErr.message, "data 必须是数组") {
		t.Fatalf("畸形 search response 必须 fail-closed：forward=%v err=%+v", forward, policyErr)
	}
	if strings.Contains(policyErr.message, "must-not-forward") {
		t.Fatalf("畸形上游内容不能进入客户端错误：%+v", policyErr)
	}
}

func newThreadSearchPolicy(t *testing.T) (*appServerGatewayPolicy, string, string) {
	t.Helper()
	cfg, registry, _, _, projectDir := appServerGatewayBaseFixture(t)
	browseRoot := t.TempDir()
	browseDir := filepath.Join(browseRoot, "browse-workspace")
	if err := os.Mkdir(browseDir, 0o755); err != nil {
		t.Fatal(err)
	}
	cfg.BrowseRoots = []string{browseRoot}
	router := &Router{
		cfg:            cfg,
		projects:       registry,
		monitor:        newRelayMonitor(),
		historyMedia:   newAppServerHistoryMediaStore(),
		gatewayThreads: map[string]appServerGatewayAllowedThread{},
	}
	return &appServerGatewayPolicy{
		router:                router,
		runtimeID:             "codex",
		pendingThreads:        map[string]appServerGatewayPendingThreadRequest{},
		pendingServerRequests: map[string]appServerGatewayPendingServerRequest{},
		pendingHistory:        map[string]appServerGatewayPendingHistoryRequest{},
		historyBudgets:        map[string]appServerGatewayHistoryBudget{},
		allowedThreads:        map[string]appServerGatewayAllowedThread{},
	}, projectDir, browseDir
}
