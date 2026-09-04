package httpapi

import (
	"bytes"
	"encoding/json"
	"path/filepath"
	"testing"

	"github.com/gorilla/websocket"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
)

func newCodexInboundPolicyForTest(t *testing.T) (*appServerGatewayPolicy, string) {
	t.Helper()
	projectDir := t.TempDir()
	registry, err := projects.NewRegistry([]config.ProjectConfig{{
		ID: "project", Name: "Project", Path: projectDir,
	}})
	if err != nil {
		t.Fatal(err)
	}
	router := &Router{
		cfg: config.Config{}, projects: registry,
		gatewayThreads: map[string]appServerGatewayAllowedThread{},
	}
	policy := &appServerGatewayPolicy{
		router:                router,
		runtimeID:             "codex",
		pendingThreads:        map[string]appServerGatewayPendingThreadRequest{},
		allowedThreads:        map[string]appServerGatewayAllowedThread{},
		pendingServerRequests: map[string]appServerGatewayPendingServerRequest{},
	}
	policy.allowThread(appServerGatewayAllowedThread{
		id: "allowed", runtimeID: "codex", cwd: projectDir, scopeID: "project",
	})
	return policy, projectDir
}

func TestCodexGatewayAuthorizesInboundNotificationsByThread(t *testing.T) {
	policy, projectDir := newCodexInboundPolicyForTest(t)

	cases := []struct {
		name    string
		payload string
		forward bool
	}{
		{name: "top level allowed", payload: `{"method":"turn/completed","params":{"threadId":"allowed","turnId":"turn-1"}}`, forward: true},
		{name: "nested allowed", payload: `{"method":"thread/name/updated","params":{"thread":{"id":"allowed"}}}`, forward: true},
		{name: "unknown thread", payload: `{"method":"turn/completed","params":{"threadId":"desktop-only"}}`, forward: false},
		{name: "missing thread", payload: `{"method":"item/completed","params":{"item":{"id":"secret"}}}`, forward: false},
		{name: "global rate limits", payload: `{"method":"account/rateLimits/updated","params":{}}`, forward: true},
		{name: "global mcp startup", payload: `{"method":"mcpServer/startupStatus/updated","params":{}}`, forward: true},
		{name: "global deprecation", payload: `{"method":"deprecationNotice","params":{}}`, forward: true},
		{name: "unknown global", payload: `{"method":"account/private/updated","params":{}}`, forward: false},
		{name: "started authorized thread", payload: `{"method":"thread/started","params":{"thread":{"id":"allowed","cwd":` + quoteJSON(projectDir) + `}}}`, forward: true},
		{name: "started allowlisted but unauthorized", payload: `{"method":"thread/started","params":{"thread":{"id":"new-thread","cwd":` + quoteJSON(projectDir) + `}}}`, forward: false},
		{name: "started outside cwd", payload: `{"method":"thread/started","params":{"thread":{"id":"outside","cwd":` + quoteJSON(filepath.Dir(projectDir)) + `}}}`, forward: false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			payload := []byte(tc.payload)
			got, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, payload)
			if policyErr != nil || forward != tc.forward {
				t.Fatalf("forward=%t want=%t err=%+v", forward, tc.forward, policyErr)
			}
			if forward && !bytes.Equal(got, payload) {
				t.Fatalf("notification 应原样透传 got=%s want=%s", got, payload)
			}
		})
	}
	if _, ok := policy.allowedThread("new-thread"); ok {
		t.Fatal("只有 cwd 白名单、没有本连接响应授权的 thread/started 不得登记")
	}
	if _, ok := policy.allowedThread("outside"); ok {
		t.Fatal("allowlist 外的 thread/started 不得登记")
	}

	id := json.RawMessage(`99`)
	if err := policy.rememberPendingThreadResponse(&id, "thread/start", projectDir, "project"); err != nil {
		t.Fatal(err)
	}
	response := []byte(`{"id":99,"result":{"thread":{"id":"new-thread","cwd":` + quoteJSON(projectDir) + `}}}`)
	if _, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, response); policyErr != nil || !forward {
		t.Fatalf("本连接 thread/start 响应应建立授权 forward=%t err=%+v", forward, policyErr)
	}
	started := []byte(`{"method":"thread/started","params":{"thread":{"id":"new-thread","cwd":` + quoteJSON(projectDir) + `}}}`)
	if _, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, started); policyErr != nil || !forward {
		t.Fatalf("响应授权后的 thread/started 应透传 forward=%t err=%+v", forward, policyErr)
	}
}

func TestCodexGatewayRequiresAuthorizedThreadForReverseRequests(t *testing.T) {
	policy, _ := newCodexInboundPolicyForTest(t)

	allowed := []byte(`{"id":"approval-ok","method":"item/commandExecution/requestApproval","params":{"threadId":"allowed","itemId":"item-1"}}`)
	if got, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, allowed); policyErr != nil || !forward || !bytes.Equal(got, allowed) {
		t.Fatalf("授权 thread 的 reverse request 应透传 forward=%t err=%+v got=%s", forward, policyErr, got)
	}

	for _, payload := range [][]byte{
		[]byte(`{"id":"approval-other","method":"item/commandExecution/requestApproval","params":{"threadId":"desktop-only"}}`),
		[]byte(`{"id":"approval-unscoped","method":"item/commandExecution/requestApproval","params":{}}`),
		[]byte(`{"id":"unknown","method":"future/serverRequest","params":{"threadId":"allowed"}}`),
	} {
		if _, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, payload); forward || policyErr != nil {
			t.Fatalf("未授权或未知 reverse request 应静默丢弃 forward=%t err=%+v payload=%s", forward, policyErr, payload)
		}
	}
	for _, rawID := range []string{`"approval-other"`, `"approval-unscoped"`, `"unknown"`} {
		id := json.RawMessage(rawID)
		if _, ok := policy.consumePendingServerRequest(&id); ok {
			t.Fatalf("被丢弃的 reverse request 不得登记 pending id=%s", rawID)
		}
	}
}

func TestCodexGatewayAuthorizesResolvedBeforeClearingPending(t *testing.T) {
	policy, _ := newCodexInboundPolicyForTest(t)
	request := []byte(`{"id":"approval-ok","method":"item/tool/requestUserInput","params":{"threadId":"allowed","turnId":"turn-1","itemId":"item-1"}}`)
	if _, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, request); policyErr != nil || !forward {
		t.Fatalf("准备 reverse request 失败 forward=%t err=%+v", forward, policyErr)
	}

	blocked := []byte(`{"method":"serverRequest/resolved","params":{"requestId":"not-pending","threadId":"desktop-only"}}`)
	if _, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, blocked); forward || policyErr != nil {
		t.Fatalf("未授权 resolved 应静默丢弃 forward=%t err=%+v", forward, policyErr)
	}
	id := json.RawMessage(`"approval-ok"`)
	if _, ok := policy.consumePendingServerRequest(&id); !ok {
		t.Fatal("被拒绝的 resolved 不得清理其他 pending")
	}

	if err := policy.rememberPendingServerRequest(&id, "item/tool/requestUserInput", json.RawMessage(`{"threadId":"allowed","turnId":"turn-1","itemId":"item-1"}`)); err != nil {
		t.Fatal(err)
	}
	resolved := []byte(`{"method":"serverRequest/resolved","params":{"requestId":"approval-ok"}}`)
	if got, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, resolved); policyErr != nil || !forward || !bytes.Equal(got, resolved) {
		t.Fatalf("已授权 pending 的无 thread resolved 应透传 forward=%t err=%+v got=%s", forward, policyErr, got)
	}
	if _, ok := policy.consumePendingServerRequest(&id); ok {
		t.Fatal("合法 resolved 应清理 pending")
	}
}

func TestCodexGatewayOnlyAllowsRelatedThreadsFromAuthorizedParent(t *testing.T) {
	policy, _ := newCodexInboundPolicyForTest(t)
	allowedParent := []byte(`{"method":"item/completed","params":{"threadId":"allowed","item":{"type":"collabAgentToolCall","receiverThreadIds":["child-ok"]}}}`)
	if _, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, allowedParent); policyErr != nil || !forward {
		t.Fatalf("授权父 thread 通知应透传 forward=%t err=%+v", forward, policyErr)
	}
	if child, ok := policy.allowedThread("child-ok"); !ok || !child.readOnly {
		t.Fatalf("授权父 thread 应登记只读 child child=%+v ok=%t", child, ok)
	}

	unknownParent := []byte(`{"method":"item/completed","params":{"threadId":"desktop-only","item":{"type":"collabAgentToolCall","receiverThreadIds":["child-no"]}}}`)
	if _, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, unknownParent); forward || policyErr != nil {
		t.Fatalf("未授权父 thread 通知应丢弃 forward=%t err=%+v", forward, policyErr)
	}
	if _, ok := policy.allowedThread("child-no"); ok {
		t.Fatal("未授权父 thread 不得登记 child")
	}
}

func quoteJSON(value string) string {
	raw, _ := json.Marshal(value)
	return string(raw)
}

// MIM-248：Claude 路径的下行门禁。独立 fixture，不复用 Codex 的用例，
// 因为两条链路的全局通知集合与 replay 语义并不相同。
func newClaudeInboundPolicyForTest(t *testing.T) (*appServerGatewayPolicy, string) {
	t.Helper()
	projectDir := t.TempDir()
	registry, err := projects.NewRegistry([]config.ProjectConfig{{
		ID: "project", Name: "Project", Path: projectDir,
	}})
	if err != nil {
		t.Fatal(err)
	}
	router := &Router{
		cfg: config.Config{}, projects: registry,
		gatewayThreads: map[string]appServerGatewayAllowedThread{},
	}
	policy := &appServerGatewayPolicy{
		router:                router,
		runtimeID:             "claude",
		pendingThreads:        map[string]appServerGatewayPendingThreadRequest{},
		allowedThreads:        map[string]appServerGatewayAllowedThread{},
		pendingServerRequests: map[string]appServerGatewayPendingServerRequest{},
	}
	policy.allowThread(appServerGatewayAllowedThread{
		id: "allowed", runtimeID: "claude", cwd: projectDir, scopeID: "project",
	})
	return policy, projectDir
}

func TestClaudeGatewayAuthorizesInboundNotificationsByThread(t *testing.T) {
	policy, _ := newClaudeInboundPolicyForTest(t)

	cases := []struct {
		name    string
		payload string
		forward bool
	}{
		{
			name:    "已授权 thread 的通知放行",
			payload: `{"method":"turn/completed","params":{"threadId":"allowed","turnId":"turn-1"}}`,
			forward: true,
		},
		{
			name:    "未授权 thread 的通知丢弃",
			payload: `{"method":"turn/completed","params":{"threadId":"intruder","turnId":"turn-1"}}`,
			forward: false,
		},
		{
			name:    "Claude 实际会发的无 thread 全局通知放行",
			payload: `{"method":"account/rateLimits/updated","params":{"rateLimits":{}}}`,
			forward: true,
		},
		{
			name:    "未登记的无 thread 通知丢弃",
			payload: `{"method":"account/somethingNew/updated","params":{}}`,
			forward: false,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, []byte(tc.payload))
			if policyErr != nil {
				t.Fatalf("通知不应产生策略错误：%+v", policyErr)
			}
			if forward != tc.forward {
				t.Fatalf("转发判定不符：want=%t got=%t payload=%s", tc.forward, forward, tc.payload)
			}
		})
	}
}

func TestClaudeGatewayRequiresAuthorizedThreadForReverseRequests(t *testing.T) {
	policy, _ := newClaudeInboundPolicyForTest(t)

	allowed := []byte(`{"id":"req-1","method":"item/tool/requestUserInput","params":{"threadId":"allowed","itemId":"toolu_1"}}`)
	if _, forward, err := policy.observeUpstreamFrame(websocket.TextMessage, allowed); err != nil || !forward {
		t.Fatalf("已授权 thread 的反向请求应转发：forward=%t err=%+v", forward, err)
	}

	intruder := []byte(`{"id":"req-2","method":"item/tool/requestUserInput","params":{"threadId":"intruder","itemId":"toolu_2"}}`)
	if _, forward, err := policy.observeUpstreamFrame(websocket.TextMessage, intruder); err != nil || forward {
		t.Fatalf("未授权 thread 的反向请求必须丢弃：forward=%t err=%+v", forward, err)
	}
	// 丢弃的请求不得登记 pending，否则客户端后续可以用它的 id 回一个从未展示过的答复。
	intruderID := json.RawMessage(`"req-2"`)
	if _, ok := policy.consumePendingServerRequest(&intruderID); ok {
		t.Fatal("被丢弃的反向请求不应登记 pending")
	}
}

// replay 信封是 Claude 重连恢复挂起卡片的唯一通道：整帧丢掉会让用户永远等不到
// 那张卡，整帧放行又会泄露未授权 thread 的挂起请求，所以必须按条目裁剪。
func TestClaudeGatewayFiltersReplayEnvelopeByThreadAuthorization(t *testing.T) {
	policy, _ := newClaudeInboundPolicyForTest(t)

	replay := []byte(`{"jsonrpc":"2.0","method":"serverRequest/replay","params":{"outstanding":[` +
		`{"id":"keep","method":"item/tool/requestUserInput","params":{"threadId":"allowed","itemId":"toolu_ok"}},` +
		`{"id":"drop","method":"item/tool/requestUserInput","params":{"threadId":"intruder","itemId":"toolu_bad"}}]}}`)
	got, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, replay)
	if policyErr != nil || !forward {
		t.Fatalf("replay 信封必须转发：forward=%t err=%+v", forward, policyErr)
	}
	if !bytes.Contains(got, []byte(`"keep"`)) {
		t.Fatalf("已授权 thread 的挂起请求必须保留，否则重连恢复不了：%s", got)
	}
	if bytes.Contains(got, []byte(`"drop"`)) || bytes.Contains(got, []byte("toolu_bad")) {
		t.Fatalf("未授权 thread 的挂起请求不应下发：%s", got)
	}

	keepID := json.RawMessage(`"keep"`)
	if _, ok := policy.consumePendingServerRequest(&keepID); !ok {
		t.Fatal("保留下来的重放请求应登记 pending，否则客户端答不了")
	}
	dropID := json.RawMessage(`"drop"`)
	if _, ok := policy.consumePendingServerRequest(&dropID); ok {
		t.Fatal("被裁掉的重放请求不应登记 pending")
	}
}
