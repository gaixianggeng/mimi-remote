package httpapi

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestSanitizedGatewayThreadForkKeepsSourceAndForcesBoundedResponse(t *testing.T) {
	policy, projectDir, _ := newThreadSearchPolicy(t)
	params := sanitizedGatewayThreadParams("codex", "thread/fork", map[string]any{
		"threadId":     "thread-source",
		"cwd":          projectDir,
		"threadSource": "duplicate",
		"excludeTurns": false,
	})
	if params["threadSource"] != "duplicate" || params["excludeTurns"] != true {
		t.Fatalf("thread/fork 必须保留来源并强制小响应：%v", params)
	}

	largeTurn := strings.Repeat("large-turn-output", 20_000)
	payload, err := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"id":      41,
		"result": map[string]any{
			"thread": map[string]any{
				"id":           "thread-forked",
				"cwd":          projectDir,
				"threadSource": "duplicate",
				"turns":        []any{map[string]any{"id": "turn-1", "items": []any{largeTurn}}},
			},
			"model": "gpt-5.6-sol",
		},
	})
	if err != nil {
		t.Fatal(err)
	}

	rewritten, result, err := sanitizeThreadForkResponse(payload)
	if err != nil {
		t.Fatal(err)
	}
	if len(rewritten) >= len(payload)/10 || bytes.Contains(rewritten, []byte(largeTurn)) {
		t.Fatalf("thread/fork 完整历史未被裁剪：before=%d after=%d", len(payload), len(rewritten))
	}
	var resultFields map[string]json.RawMessage
	if err := json.Unmarshal(result, &resultFields); err != nil {
		t.Fatal(err)
	}
	var thread struct {
		ID           string            `json:"id"`
		ThreadSource string            `json:"threadSource"`
		Turns        []json.RawMessage `json:"turns"`
	}
	if err := json.Unmarshal(resultFields["thread"], &thread); err != nil {
		t.Fatal(err)
	}
	if thread.ID != "thread-forked" || thread.ThreadSource != "duplicate" || len(thread.Turns) != 0 {
		t.Fatalf("裁剪后必须保留线程元数据并清空 turns：%+v", thread)
	}

	scope, ok := policy.router.gatewayScopeForPath(projectDir)
	if !ok {
		t.Fatal("测试工作区必须可由 gateway 授权")
	}
	rawID := json.RawMessage(`41`)
	if err := policy.rememberPendingThreadRequest(&rawID, appServerGatewayPendingThreadRequest{
		method: "thread/fork", cwd: projectDir, scopeID: scope.id, threadID: "thread-source",
	}); err != nil {
		t.Fatal(err)
	}
	forwarded, forward, policyErr := policy.observeUpstreamFrame(1, payload)
	if policyErr != nil || !forward || bytes.Contains(forwarded, []byte(largeTurn)) {
		t.Fatalf("gateway 必须转发有界 fork 响应：forward=%t err=%v bytes=%d", forward, policyErr, len(forwarded))
	}
	if _, ok := policy.allowedThread("thread-forked"); !ok {
		t.Fatal("裁剪响应后仍必须授权新分支，保证后续 thread/started 和重命名可用")
	}
}

func TestAppServerGatewayKeepsSlowForkPendingForLateReconciliation(t *testing.T) {
	oldThreadTTL := appServerGatewayPendingThreadTTL
	oldForkTTL := appServerGatewayPendingForkTTL
	appServerGatewayPendingThreadTTL = 30 * time.Second
	appServerGatewayPendingForkTTL = 2 * time.Minute
	t.Cleanup(func() {
		appServerGatewayPendingThreadTTL = oldThreadTTL
		appServerGatewayPendingForkTTL = oldForkTTL
	})

	createdAt := time.Now().Add(-75 * time.Second)
	policy := &appServerGatewayPolicy{
		pendingThreads: map[string]appServerGatewayPendingThreadRequest{
			"fork": {method: "thread/fork", createdAt: createdAt},
			"list": {method: "thread/list", createdAt: createdAt},
		},
	}
	policy.mu.Lock()
	policy.prunePendingThreadsLocked(time.Now())
	_, keptFork := policy.pendingThreads["fork"]
	_, keptList := policy.pendingThreads["list"]
	policy.mu.Unlock()

	if !keptFork || keptList {
		t.Fatalf("75 秒 fork 应保留对账上下文，普通列表应按 30 秒清理：fork=%t list=%t", keptFork, keptList)
	}
}
