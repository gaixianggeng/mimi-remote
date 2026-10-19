package httpapi

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// #799：网关登记必须活得比客户端等待更久；超过等待时长才到的响应、对不上在途
// 请求的响应一律丢弃，不能因为登记消失就把未裁剪的列表、搜索结果原样放行。

const (
	pendingLifecycleOutsideCWD    = "/outside/secret-dir"
	pendingLifecycleSecretTitle   = "SECRET-TITLE"
	pendingLifecycleRawCursor     = "raw-upstream-cursor"
	pendingLifecycleSecretSnippet = "SECRET-SNIPPET"
)

// agePendingThreadRequests 把所有 pending thread 登记拨到 age 之前，模拟上游慢响应。
func agePendingThreadRequests(policy *appServerGatewayPolicy, age time.Duration) {
	policy.mu.Lock()
	defer policy.mu.Unlock()
	for key, pending := range policy.pendingThreads {
		pending.createdAt = time.Now().Add(-age)
		policy.pendingThreads[key] = pending
	}
}

func mustValidateClientFrame(t *testing.T, policy *appServerGatewayPolicy, payload string) []byte {
	t.Helper()
	forwarded, policyErr := policy.validateClientFrame(websocket.TextMessage, []byte(payload))
	if policyErr != nil {
		t.Fatalf("请求应通过校验：%s\n%s", policyErr.message, payload)
	}
	return forwarded
}

func globalListResponseForTest(id string, projectDir string) []byte {
	return []byte(`{"id":` + id + `,"result":{"data":[` +
		`{"id":"t-in","cwd":` + strconvQuoteForTest(projectDir) + `,"name":"In project"},` +
		`{"id":"t-out","cwd":"` + pendingLifecycleOutsideCWD + `","name":"` + pendingLifecycleSecretTitle + `"}` +
		`],"nextCursor":"` + pendingLifecycleRawCursor + `"}}`)
}

func threadSearchResponseForTest(id string) []byte {
	return []byte(`{"id":` + id + `,"result":{"data":[{"thread":{"id":"t-out","cwd":"` + pendingLifecycleOutsideCWD +
		`","name":"` + pendingLifecycleSecretTitle + `"},"snippet":"` + pendingLifecycleSecretSnippet + `"}],"nextCursor":null}}`)
}

func strconvQuoteForTest(value string) string {
	raw, _ := json.Marshal(value)
	return string(raw)
}

func assertNoOutOfScopeThreadData(t *testing.T, payload []byte) {
	t.Helper()
	for _, secret := range []string{pendingLifecycleSecretTitle, pendingLifecycleOutsideCWD, pendingLifecycleRawCursor, pendingLifecycleSecretSnippet} {
		if bytes.Contains(payload, []byte(secret)) {
			t.Fatalf("下发内容不得含 allowlist 之外的会话或上游原始游标 %q：%s", secret, payload)
		}
	}
}

func TestAppServerGatewayLateGlobalDiscoveryResponsesAreDropped(t *testing.T) {
	relaxGlobalListGitWait(t)
	for _, tc := range []struct {
		name     string
		request  string
		response func(projectDir string) []byte
	}{
		{
			name:     "thread/list",
			request:  `{"id":1,"method":"thread/list","params":{"limit":50}}`,
			response: func(projectDir string) []byte { return globalListResponseForTest("1", projectDir) },
		},
		{
			name:     "thread/search",
			request:  `{"id":1,"method":"thread/search","params":{"searchTerm":"needle","limit":10}}`,
			response: func(string) []byte { return threadSearchResponseForTest("1") },
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			policy, projectDir := newInboundPolicyForTest(t, appServerRuntimeCodexID)
			mustValidateClientFrame(t, policy, tc.request)
			agePendingThreadRequests(policy, appServerGatewayPendingThreadTTL+time.Second)

			forwarded, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, tc.response(projectDir))
			if forward || policyErr != nil {
				t.Fatalf("超过网关等待时长的响应必须丢弃：forward=%v err=%+v payload=%s", forward, policyErr, forwarded)
			}
			policy.mu.Lock()
			remaining := len(policy.pendingThreads)
			policy.mu.Unlock()
			if remaining != 0 {
				t.Fatalf("迟到响应到达后应释放登记，remaining=%d", remaining)
			}
			// 同一份迟到响应再来一次也只能被当成对不上的响应丢弃。
			if _, forward, _ := policy.observeUpstreamFrame(websocket.TextMessage, tc.response(projectDir)); forward {
				t.Fatal("登记释放后重复到达的响应仍必须丢弃")
			}
		})
	}
}

func TestAppServerGatewaySanitizesGlobalDiscoveryWhileClientStillWaits(t *testing.T) {
	relaxGlobalListGitWait(t)
	policy, projectDir := newInboundPolicyForTest(t, appServerRuntimeCodexID)
	mustValidateClientFrame(t, policy, `{"id":1,"method":"thread/list","params":{"limit":50}}`)
	// 45 秒：超过旧的 30 秒网关时限，仍在 iOS 60 秒等待之内。
	agePendingThreadRequests(policy, 45*time.Second)

	forwarded, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, globalListResponseForTest("1", projectDir))
	if !forward || policyErr != nil {
		t.Fatalf("客户端仍在等的全局列表应裁剪后下发：forward=%v err=%+v", forward, policyErr)
	}
	assertNoOutOfScopeThreadData(t, forwarded)
	if !bytes.Contains(forwarded, []byte(`"t-in"`)) {
		t.Fatalf("授权目录内的会话应保留：%s", forwarded)
	}

	mustValidateClientFrame(t, policy, `{"id":2,"method":"thread/search","params":{"searchTerm":"needle","limit":10}}`)
	agePendingThreadRequests(policy, 45*time.Second)
	forwarded, forward, policyErr = policy.observeUpstreamFrame(websocket.TextMessage, threadSearchResponseForTest("2"))
	if !forward || policyErr != nil {
		t.Fatalf("客户端仍在等的搜索结果应裁剪后下发：forward=%v err=%+v", forward, policyErr)
	}
	assertNoOutOfScopeThreadData(t, forwarded)
}

func TestAppServerGatewaySlowThreadResponsesStillAuthorizeFollowUps(t *testing.T) {
	policy, projectDir := newInboundPolicyForTest(t, appServerRuntimeCodexID)
	cwd := strconvQuoteForTest(projectDir)

	mustValidateClientFrame(t, policy, `{"id":4,"method":"thread/start","params":{"cwd":`+cwd+`}}`)
	agePendingThreadRequests(policy, 45*time.Second)
	started := []byte(`{"id":4,"result":{"thread":{"id":"t-new","cwd":` + cwd + `,"canAcceptDirectInput":true}}}`)
	if _, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, started); !forward || policyErr != nil {
		t.Fatalf("thread/start 成功响应应下发：forward=%v err=%+v", forward, policyErr)
	}
	mustValidateClientFrame(t, policy, `{"id":5,"method":"turn/start","params":{"threadId":"t-new","cwd":`+cwd+`,"input":[{"type":"text","text":"hi"}]}}`)

	mustValidateClientFrame(t, policy, `{"id":6,"method":"thread/list","params":{"limit":50,"cwd":`+cwd+`}}`)
	agePendingThreadRequests(policy, 45*time.Second)
	listed := []byte(`{"id":6,"result":{"data":[{"id":"t-listed","cwd":` + cwd + `,"name":"In project"}],"nextCursor":null}}`)
	if _, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, listed); !forward || policyErr != nil {
		t.Fatalf("作用域列表应下发：forward=%v err=%+v", forward, policyErr)
	}
	mustValidateClientFrame(t, policy, `{"id":7,"method":"thread/resume","params":{"threadId":"t-listed","cwd":`+cwd+`}}`)

	// 客户端放弃之后才到的 thread/start 不下发、不登记：客户端会按失败重试。
	mustValidateClientFrame(t, policy, `{"id":8,"method":"thread/start","params":{"cwd":`+cwd+`}}`)
	agePendingThreadRequests(policy, appServerGatewayPendingThreadTTL+time.Second)
	late := []byte(`{"id":8,"result":{"thread":{"id":"t-late","cwd":` + cwd + `,"canAcceptDirectInput":true}}}`)
	if _, forward, _ := policy.observeUpstreamFrame(websocket.TextMessage, late); forward {
		t.Fatal("迟到的 thread/start 不应下发")
	}
	if _, ok := policy.allowedThread("t-late"); ok {
		t.Fatal("迟到的 thread/start 不应登记授权")
	}
}

func TestAppServerGatewayLateErrorResponseReleasesPendingThread(t *testing.T) {
	policy, projectDir := newInboundPolicyForTest(t, appServerRuntimeCodexID)
	mustValidateClientFrame(t, policy, `{"id":4,"method":"thread/start","params":{"cwd":`+strconvQuoteForTest(projectDir)+`}}`)
	agePendingThreadRequests(policy, appServerGatewayPendingThreadTTL+time.Second)

	failure := []byte(`{"id":4,"error":{"code":-32000,"message":"mcp startup failed"}}`)
	if _, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, failure); !forward || policyErr != nil {
		t.Fatalf("迟到的错误响应不带会话数据，应照常下发：forward=%v err=%+v", forward, policyErr)
	}
	if policy.requestIDInFlight(rawMessagePointer(json.RawMessage(`4`))) {
		t.Fatal("错误响应到达后应释放登记，id 可以复用")
	}
}

func TestAppServerGatewayRejectsRequestIDReuseAroundThreadResponses(t *testing.T) {
	relaxGlobalListGitWait(t)
	policy, projectDir := newInboundPolicyForTest(t, appServerRuntimeCodexID)
	globalList := `{"id":1,"method":"thread/list","params":{"limit":50}}`
	modelList := `{"id":1,"method":"model/list","params":{}}`

	// 先列表后其他：同 id 的请求在列表响应前被拒，不会抢走列表的登记。
	mustValidateClientFrame(t, policy, globalList)
	if _, policyErr := policy.validateClientFrame(websocket.TextMessage, []byte(modelList)); policyErr == nil || !strings.Contains(policyErr.message, "id 重复") {
		t.Fatalf("pending 列表期间复用 id 必须拒绝：%+v", policyErr)
	}
	forwarded, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, globalListResponseForTest("1", projectDir))
	if !forward || policyErr != nil {
		t.Fatalf("真正的列表响应应裁剪后下发：forward=%v err=%+v", forward, policyErr)
	}
	assertNoOutOfScopeThreadData(t, forwarded)

	// 先其他后列表：同 id 的列表请求被拒，其他请求的响应照常下发。
	mustValidateClientFrame(t, policy, `{"id":7,"method":"model/list","params":{}}`)
	if _, policyErr := policy.validateClientFrame(websocket.TextMessage, []byte(`{"id":7,"method":"thread/search","params":{"searchTerm":"needle"}}`)); policyErr == nil || !strings.Contains(policyErr.message, "id 重复") {
		t.Fatalf("其他请求在途时复用 id 发搜索必须拒绝：%+v", policyErr)
	}
	modelResponse := []byte(`{"id":7,"result":{"data":[{"id":"gpt-x","model":"gpt-x"}]}}`)
	if forwarded, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, modelResponse); !forward || policyErr != nil || !bytes.Equal(forwarded, modelResponse) {
		t.Fatalf("model/list 响应应原样下发：forward=%v err=%+v payload=%s", forward, policyErr, forwarded)
	}
	// 上游若对同一 id 再回一条列表形状的响应，也没有在途请求认领，只能丢弃。
	if _, forward, _ := policy.observeUpstreamFrame(websocket.TextMessage, globalListResponseForTest("7", projectDir)); forward {
		t.Fatal("没有在途请求认领的响应必须丢弃")
	}

	// 超时的列表登记继续占住 id：迟到的响应可能随时到达。
	mustValidateClientFrame(t, policy, `{"id":3,"method":"thread/list","params":{"limit":50}}`)
	agePendingThreadRequests(policy, appServerGatewayPendingThreadTTL+time.Second)
	if _, policyErr := policy.validateClientFrame(websocket.TextMessage, []byte(`{"id":3,"method":"model/list","params":{}}`)); policyErr == nil || !strings.Contains(policyErr.message, "id 重复") {
		t.Fatalf("迟到标记存在时复用 id 必须拒绝：%+v", policyErr)
	}
	if _, forward, _ := policy.observeUpstreamFrame(websocket.TextMessage, globalListResponseForTest("3", projectDir)); forward {
		t.Fatal("迟到的列表响应必须丢弃")
	}
	mustValidateClientFrame(t, policy, `{"id":3,"method":"model/list","params":{}}`)
}

func TestClaudeGatewayDropsReplayedResponseWithoutInflightRequest(t *testing.T) {
	relaxGlobalListGitWait(t)
	policy, projectDir := newInboundPolicyForTest(t, "claude")
	// bridge 断线重放上一条连接的响应：这条连接从没发过 id 11 的请求。
	replayed := globalListResponseForTest("11", projectDir)
	replayed = append(replayed[:len(replayed)-1], []byte(`,"_alleycat_seq":9}`)...)
	if _, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, replayed); forward || policyErr != nil {
		t.Fatalf("重放的旧响应没有在途请求认领，必须丢弃：forward=%v err=%+v", forward, policyErr)
	}
	// 错误响应不带会话数据，沿用原路径下发，客户端按未知 id 忽略。
	replayedError := []byte(`{"id":12,"error":{"code":-32000,"message":"interrupted"},"_alleycat_seq":10}`)
	if _, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, replayedError); !forward || policyErr != nil {
		t.Fatalf("对不上的错误响应仍按原路径下发：forward=%v err=%+v", forward, policyErr)
	}
}

func TestAppServerGatewayForkProcessesResponseAfterThreadTTL(t *testing.T) {
	policy, projectDir := newInboundPolicyForTest(t, appServerRuntimeCodexID)
	cwd := strconvQuoteForTest(projectDir)
	mustValidateClientFrame(t, policy, `{"id":9,"method":"thread/fork","params":{"threadId":"allowed","cwd":`+cwd+`}}`)
	agePendingThreadRequests(policy, 24*time.Hour)

	forked := []byte(`{"id":9,"result":{"thread":{"id":"t-forked","cwd":` + cwd + `,"turns":[{"id":"turn-1"}]}}}`)
	forwarded, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, forked)
	if !forward || policyErr != nil || bytes.Contains(forwarded, []byte("turn-1")) {
		t.Fatalf("fork 不按 TTL 过期，迟到的响应仍应裁剪后下发：forward=%v err=%+v payload=%s", forward, policyErr, forwarded)
	}
	if _, ok := policy.allowedThread("t-forked"); !ok {
		t.Fatal("fork 响应仍应登记新分支授权")
	}
}
