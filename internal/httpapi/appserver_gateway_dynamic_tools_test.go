package httpapi

import (
	"bytes"
	"encoding/json"
	"testing"

	"github.com/gorilla/websocket"
)

func TestMimiTaskDynamicToolsAreCanonicalized(t *testing.T) {
	optIn := mimiTaskOptInForTest()
	canonical, ok := canonicalMimiTaskDynamicTools(optIn)
	if !ok {
		t.Fatal("完整 mimi_tasks V1 应被识别")
	}
	encoded, _ := json.Marshal(canonical)
	if bytes.Contains(encoded, []byte(`"required":null`)) || !bytes.Contains(encoded, []byte(`"required":[]`)) {
		t.Fatalf("无必填参数的工具必须使用空 required 数组：%s", encoded)
	}
	for _, want := range [][]byte{[]byte(`"additionalProperties":false`), []byte(`"default":30000`), []byte(`"uniqueItems":true`), []byte(`"maxLength":20000`)} {
		if !bytes.Contains(encoded, want) {
			t.Fatalf("canonical definitions 缺少 %s：%s", want, encoded)
		}
	}
	if bytes.Contains(encoded, []byte("untrusted")) {
		t.Fatalf("客户端描述不得透传：%s", encoded)
	}
	params := sanitizedGatewayThreadParams("codex", "thread/start", map[string]any{"cwd": "/tmp/project", "dynamicTools": optIn})
	if _, exists := params["dynamicTools"]; !exists {
		t.Fatal("thread/start 应保留 canonical definitions")
	}
	resume := sanitizedGatewayThreadParams("codex", "thread/resume", map[string]any{"cwd": "/tmp/project", "threadId": "thread-1", "dynamicTools": optIn})
	if _, exists := resume["dynamicTools"]; exists {
		t.Fatal("thread/resume 不支持 dynamicTools")
	}
}

func TestMimiTaskDynamicToolsRequireInitializeCapability(t *testing.T) {
	router := &Router{}
	policy := newMimiTaskTestPolicy(router, false)
	initialize := []byte(`{"id":1,"method":"initialize","params":{"capabilities":{"experimentalApi":true,"mimiDynamicTaskToolsV1":true}}}`)
	forwarded, policyErr := policy.validateClientFrame(websocket.TextMessage, initialize)
	if policyErr != nil || !policy.allowsMimiTaskTools() {
		t.Fatalf("initialize capability 应启用当前连接：err=%+v", policyErr)
	}
	if bytes.Contains(forwarded, []byte("mimiDynamicTaskToolsV1")) {
		t.Fatalf("Mimi 私有 capability 不得发给 upstream：%s", forwarded)
	}
}

func TestMimiTaskInitializeCapabilityCommitsOnlyAfterValidation(t *testing.T) {
	router := &Router{}
	policy := newMimiTaskTestPolicy(router, false)
	invalid := []byte(`{"id":1,"method":"initialize","params":{"capabilities":{"mimiDynamicTaskToolsV1":true},"networkAccess":true}}`)
	if _, policyErr := policy.validateClientFrame(websocket.TextMessage, invalid); policyErr == nil {
		t.Fatal("危险 initialize 应被策略拒绝")
	}
	if policy.allowsMimiTaskTools() {
		t.Fatal("失败 initialize 不得提交动态任务 capability")
	}
	validWithoutCapability := []byte(`{"id":2,"method":"initialize","params":{"capabilities":{"experimentalApi":true}}}`)
	if _, policyErr := policy.validateClientFrame(websocket.TextMessage, validWithoutCapability); policyErr != nil {
		t.Fatalf("合法 initialize 应通过：%+v", policyErr)
	}
	if policy.allowsMimiTaskTools() {
		t.Fatal("不含私有 capability 的 initialize 必须保持关闭")
	}
}

func TestMimiTaskDynamicCallIsCodexOnly(t *testing.T) {
	if !appServerServerRequestAllowed("codex", "item/tool/call") {
		t.Fatal("Codex 应允许受策略约束的 item/tool/call")
	}
	if appServerServerRequestAllowed("claude", "item/tool/call") {
		t.Fatal("Claude bridge 不得继承 Codex dynamic tool request")
	}
}

func TestMimiTaskDynamicCallValidatesAuthorizationAndArguments(t *testing.T) {
	router := &Router{}
	policy := newMimiTaskTestPolicy(router, true)
	policy.allowThread(appServerGatewayAllowedThread{id: "parent", scopeID: "scope-a"})
	policy.allowThread(appServerGatewayAllowedThread{id: "child", scopeID: "scope-a"})
	policy.allowThread(appServerGatewayAllowedThread{id: "other", scopeID: "scope-b"})
	valid := []byte(`{"id":60,"method":"item/tool/call","params":{"threadId":"parent","turnId":"turn-1","callId":"call-1","namespace":"mimi_tasks","tool":"send_message_to_thread","arguments":{"threadId":"child","prompt":"continue"}}}`)
	if got, forward, err := policy.observeUpstreamFrame(websocket.TextMessage, valid); err != nil || !forward || !bytes.Equal(got, valid) {
		t.Fatalf("有效调用应转发：forward=%v err=%+v got=%s", forward, err, got)
	}
	invalid := []string{
		`{"id":61,"method":"item/tool/call","params":{"threadId":"parent","turnId":"turn-1","callId":"call-2","namespace":"codex_app","tool":"list_threads","arguments":{}}}`,
		`{"id":62,"method":"item/tool/call","params":{"threadId":"missing","turnId":"turn-1","callId":"call-3","namespace":"mimi_tasks","tool":"list_threads","arguments":{}}}`,
		`{"id":63,"method":"item/tool/call","params":{"threadId":"parent","turnId":"turn-1","callId":"call-4","namespace":"mimi_tasks","tool":"read_thread","arguments":{"threadId":"other"}}}`,
		`{"id":64,"method":"item/tool/call","params":{"threadId":"parent","turnId":"turn-1","callId":"call-5","namespace":"mimi_tasks","tool":"wait_threads","arguments":{"threadIds":["child","child"]}}}`,
	}
	for _, payload := range invalid {
		if _, forward, err := policy.observeUpstreamFrame(websocket.TextMessage, []byte(payload)); err != nil || forward {
			t.Fatalf("非法调用应静默丢弃：forward=%v err=%+v payload=%s", forward, err, payload)
		}
	}
}

func TestMimiTaskDynamicCallHasOneOwnerAcrossSubscribers(t *testing.T) {
	router := &Router{}
	first := newMimiTaskTestPolicy(router, true)
	second := newMimiTaskTestPolicy(router, true)
	for _, policy := range []*appServerGatewayPolicy{first, second} {
		policy.allowThread(appServerGatewayAllowedThread{id: "parent", scopeID: "scope-a"})
	}
	payload := []byte(`{"id":70,"method":"item/tool/call","params":{"threadId":"parent","turnId":"turn-owner","callId":"call-owner","namespace":"mimi_tasks","tool":"create_thread","arguments":{"prompt":"do it"}}}`)
	if _, forward, err := first.observeUpstreamFrame(websocket.TextMessage, payload); err != nil || !forward {
		t.Fatalf("第一个连接应取得 owner：forward=%v err=%+v", forward, err)
	}
	if _, forward, err := second.observeUpstreamFrame(websocket.TextMessage, payload); err != nil || forward {
		t.Fatalf("第二个连接不得重复执行：forward=%v err=%+v", forward, err)
	}
	response := []byte(`{"id":70,"result":{"contentItems":[{"type":"inputText","text":"{\"threadId\":\"child\"}"}],"success":true}}`)
	rawID := json.RawMessage(`70`)
	frame := &appServerGatewayFrame{ID: &rawID, Result: json.RawMessage(`{"contentItems":[{"type":"inputText","text":"ok"}],"success":true}`)}
	if _, err := first.validateClientResponse(response, frame); err != nil {
		t.Fatalf("owner response 应通过：%v", err)
	}
	if _, forward, err := second.observeUpstreamFrame(websocket.TextMessage, payload); err != nil || forward {
		t.Fatalf("响应后的迟到广播仍不得执行：forward=%v err=%+v", forward, err)
	}
}

func TestMimiTaskDynamicClaimReleasesClosedOwnerButKeepsTombstone(t *testing.T) {
	router := &Router{}
	first := newMimiTaskTestPolicy(router, true)
	second := newMimiTaskTestPolicy(router, true)
	for _, policy := range []*appServerGatewayPolicy{first, second} {
		policy.allowThread(appServerGatewayAllowedThread{id: "parent", scopeID: "scope-a"})
	}
	payload := []byte(`{"id":71,"method":"item/tool/call","params":{"threadId":"parent","turnId":"turn-close","callId":"call-close","namespace":"mimi_tasks","tool":"create_thread","arguments":{"prompt":"do it"}}}`)
	if _, forward, err := first.observeUpstreamFrame(websocket.TextMessage, payload); err != nil || !forward {
		t.Fatalf("第一个连接应取得 owner：forward=%v err=%+v", forward, err)
	}
	first.close()
	key := "parent\x00turn-close\x00call-close"
	router.mimiTaskClaimsMu.Lock()
	claim, exists := router.mimiTaskClaims[key]
	router.mimiTaskClaimsMu.Unlock()
	if !exists || claim.owner != nil || claim.state != mimiTaskDynamicClaimAbandoned {
		t.Fatalf("断连后应保留 abandoned tombstone：exists=%v owner=%p state=%v", exists, claim.owner, claim.state)
	}
	if _, forward, policyErr := second.observeUpstreamFrame(websocket.TextMessage, payload); policyErr == nil || forward {
		t.Fatalf("断连后的广播必须明确失败且不得重放：forward=%v err=%+v", forward, policyErr)
	} else {
		if policyErr.id == nil || string(*policyErr.id) != "71" {
			t.Fatalf("失败响应必须保留重播 request id：%+v", policyErr)
		}
		if policyErr.message != "dynamic task execution was interrupted before a response was available" || policyErr.data["reason"] != "mimi_task_owner_disconnected" {
			t.Fatalf("失败响应必须固定且安全：%+v", policyErr)
		}
	}
}

func TestMimiTaskCompletedTombstoneStillDropsLateBroadcast(t *testing.T) {
	router := &Router{}
	first := newMimiTaskTestPolicy(router, true)
	second := newMimiTaskTestPolicy(router, true)
	for _, policy := range []*appServerGatewayPolicy{first, second} {
		policy.allowThread(appServerGatewayAllowedThread{id: "parent", scopeID: "scope-a"})
	}
	payload := []byte(`{"id":"late","method":"item/tool/call","params":{"threadId":"parent","turnId":"turn-late","callId":"call-late","namespace":"mimi_tasks","tool":"list_threads","arguments":{}}}`)
	if _, forward, policyErr := first.observeUpstreamFrame(websocket.TextMessage, payload); policyErr != nil || !forward {
		t.Fatalf("第一个连接应取得 owner：forward=%v err=%+v", forward, policyErr)
	}
	response := []byte(`{"id":"late","result":{"contentItems":[{"type":"inputText","text":"{}"}],"success":true}}`)
	rawID := json.RawMessage(`"late"`)
	frame := &appServerGatewayFrame{ID: &rawID, Result: json.RawMessage(`{"contentItems":[{"type":"inputText","text":"{}"}],"success":true}`)}
	if _, err := first.validateClientResponse(response, frame); err != nil {
		t.Fatalf("owner response 应通过：%v", err)
	}
	key := "parent\x00turn-late\x00call-late"
	router.mimiTaskClaimsMu.Lock()
	claim := router.mimiTaskClaims[key]
	router.mimiTaskClaimsMu.Unlock()
	if claim.state != mimiTaskDynamicClaimCompleted || claim.owner != nil {
		t.Fatalf("响应后应保留 completed tombstone：%+v", claim)
	}
	if _, forward, policyErr := second.observeUpstreamFrame(websocket.TextMessage, payload); policyErr != nil || forward {
		t.Fatalf("completed 迟到广播应静默丢弃：forward=%v err=%+v", forward, policyErr)
	}
}

func TestMimiTaskDynamicResponseAllowsOneBoundedTextItem(t *testing.T) {
	valid := []byte(`{"id":1,"result":{"contentItems":[{"type":"inputText","text":"{\"ok\":true}"}],"success":true}}`)
	if _, err := rewriteMimiTaskDynamicResponse(valid); err != nil {
		t.Fatalf("有效响应应通过：%v", err)
	}
	invalid := [][]byte{
		[]byte(`{"id":1,"result":{"contentItems":[{"type":"inputImage","imageUrl":"https://example.com/a.png"}],"success":true}}`),
		[]byte(`{"id":1,"result":{"contentItems":[],"success":true}}`),
		[]byte(`{"id":1,"result":{"contentItems":[{"type":"inputText","text":"ok"}],"success":true,"extra":1}}`),
	}
	for _, payload := range invalid {
		if _, err := rewriteMimiTaskDynamicResponse(payload); err == nil {
			t.Fatalf("非法响应必须拒绝：%s", payload)
		}
	}
}

func mimiTaskOptInForTest() []any {
	tools := make([]any, 0, len(mimiTaskToolNames))
	for _, name := range mimiTaskToolNames {
		tools = append(tools, map[string]any{"type": "function", "name": name, "description": "untrusted", "inputSchema": map[string]any{}})
	}
	return []any{map[string]any{"type": "namespace", "name": mimiTasksNamespace, "description": "untrusted", "tools": tools}}
}

func newMimiTaskTestPolicy(router *Router, enabled bool) *appServerGatewayPolicy {
	if router.gatewayThreads == nil {
		router.gatewayThreads = map[string]appServerGatewayAllowedThread{}
	}
	return &appServerGatewayPolicy{
		router: router, runtimeID: "codex", mimiTaskToolsEnabled: enabled,
		pendingThreads:        map[string]appServerGatewayPendingThreadRequest{},
		pendingServerRequests: map[string]appServerGatewayPendingServerRequest{},
		allowedThreads:        map[string]appServerGatewayAllowedThread{},
	}
}
