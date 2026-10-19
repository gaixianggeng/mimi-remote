package httpapi

import (
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

// #799 评审：在途登记既不能被挤掉或按时限删掉（否则 id 可被复用，旧响应会冒充
// 新请求），也不能因上游不回而永久占满（否则连接卡死）。满载且已有超时登记时，
// 网关重置连接；新上游连接不可能再收到旧响应，登记随之清空。

func limitGatewayPendingTracking(t *testing.T, clientMax int, threadMax int) {
	t.Helper()
	oldClientMax := appServerGatewayPendingClientRequestMax
	oldThreadMax := appServerGatewayPendingThreadMax
	appServerGatewayPendingClientRequestMax = clientMax
	appServerGatewayPendingThreadMax = threadMax
	t.Cleanup(func() {
		appServerGatewayPendingClientRequestMax = oldClientMax
		appServerGatewayPendingThreadMax = oldThreadMax
	})
}

func expireGatewayPendingTracking(t *testing.T) {
	t.Helper()
	oldClientTTL := appServerGatewayPendingClientRequestTTL
	oldThreadTTL := appServerGatewayPendingThreadTTL
	appServerGatewayPendingClientRequestTTL = time.Nanosecond
	appServerGatewayPendingThreadTTL = time.Nanosecond
	t.Cleanup(func() {
		appServerGatewayPendingClientRequestTTL = oldClientTTL
		appServerGatewayPendingThreadTTL = oldThreadTTL
	})
}

func TestAppServerGatewayFullInflightTableNeverFreesUnansweredIDs(t *testing.T) {
	limitGatewayPendingTracking(t, 2, 128)
	policy, _ := newInboundPolicyForTest(t, appServerRuntimeCodexID)
	mustValidateClientFrame(t, policy, `{"id":1,"method":"model/list","params":{}}`)
	mustValidateClientFrame(t, policy, `{"id":2,"method":"model/list","params":{}}`)

	overflow, policyErr := policy.validateClientFrame(websocket.TextMessage, []byte(`{"id":3,"method":"model/list","params":{}}`))
	if policyErr == nil || !strings.Contains(policyErr.message, "请求过多") {
		t.Fatalf("在途登记都还在客户端等待期内时，满载应拒绝新请求：%+v payload=%s", policyErr, overflow)
	}
	if _, policyErr := policy.validateClientFrame(websocket.TextMessage, []byte(`{"id":1,"method":"thread/list","params":{"limit":50}}`)); policyErr == nil || !strings.Contains(policyErr.message, "id 重复") {
		t.Fatalf("满载不得挤掉最旧登记，让仍可能回包的 id 被复用：%+v", policyErr)
	}
	response := []byte(`{"id":1,"result":{"data":[]}}`)
	if _, forward, _ := policy.observeUpstreamFrame(websocket.TextMessage, response); !forward {
		t.Fatal("仍在登记中的请求回包应照常下发")
	}
	mustValidateClientFrame(t, policy, `{"id":3,"method":"model/list","params":{}}`)
}

func TestAppServerGatewayExpiredInflightIDStaysReservedUntilResponse(t *testing.T) {
	policy, _ := newInboundPolicyForTest(t, appServerRuntimeCodexID)
	mustValidateClientFrame(t, policy, `{"id":1,"method":"model/list","params":{}}`)
	policy.mu.Lock()
	for key, pending := range policy.pendingClientRequests {
		pending.createdAt = time.Now().Add(-appServerGatewayPendingClientRequestTTL - time.Second)
		policy.pendingClientRequests[key] = pending
	}
	policy.mu.Unlock()

	if _, policyErr := policy.validateClientFrame(websocket.TextMessage, []byte(`{"id":1,"method":"thread/list","params":{"limit":50}}`)); policyErr == nil || !strings.Contains(policyErr.message, "id 重复") {
		t.Fatalf("超时但未回包的 id 仍可能收到旧响应，不能复用：%+v", policyErr)
	}
	if _, forward, _ := policy.observeUpstreamFrame(websocket.TextMessage, []byte(`{"id":1,"result":{"data":[]}}`)); forward {
		t.Fatal("超过等待时长才到的成功响应应丢弃")
	}
	mustValidateClientFrame(t, policy, `{"id":1,"method":"model/list","params":{}}`)
}

func TestAppServerGatewayFullTableWithExpiredEntriesAsksForReset(t *testing.T) {
	for _, tc := range []struct {
		name      string
		clientMax int
		threadMax int
		requests  []string
		overflow  string
	}{
		{
			name: "pending thread", clientMax: 256, threadMax: 2,
			requests: []string{
				`{"id":1,"method":"thread/list","params":{"limit":50}}`,
				`{"id":2,"method":"thread/search","params":{"searchTerm":"needle"}}`,
			},
			overflow: `{"id":3,"method":"thread/list","params":{"limit":50}}`,
		},
		{
			name: "in-flight request", clientMax: 2, threadMax: 128,
			requests: []string{
				`{"id":1,"method":"model/list","params":{}}`,
				`{"id":2,"method":"model/list","params":{}}`,
			},
			overflow: `{"id":3,"method":"model/list","params":{}}`,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			limitGatewayPendingTracking(t, tc.clientMax, tc.threadMax)
			expireGatewayPendingTracking(t)
			policy, _ := newInboundPolicyForTest(t, appServerRuntimeCodexID)
			for _, request := range tc.requests {
				mustValidateClientFrame(t, policy, request)
			}
			time.Sleep(time.Millisecond)
			_, policyErr := policy.validateClientFrame(websocket.TextMessage, []byte(tc.overflow))
			if policyErr == nil || !strings.Contains(policyErr.message, "重置") {
				t.Fatalf("上游长期不回导致登记占满时，应要求重置连接而不是永久拒绝：%+v", policyErr)
			}
		})
	}
}

// assertGatewayResetsConnection 发两条上游不回的请求：第二条触发重置，客户端先收到
// 错误，随后连接被关闭。
func assertGatewayResetsConnection(t *testing.T, conn *websocket.Conn) {
	t.Helper()
	for _, frame := range []string{
		`{"id":1,"method":"model/list","params":{}}`,
		`{"id":2,"method":"model/list","params":{}}`,
	} {
		time.Sleep(5 * time.Millisecond)
		if err := conn.WriteMessage(websocket.TextMessage, []byte(frame)); err != nil {
			t.Fatal(err)
		}
	}
	if errFrame := readGatewayError(t, conn); !strings.Contains(errFrame.message, "重置") {
		t.Fatalf("重置前应告知客户端原因：%+v", errFrame)
	}
	_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	for {
		if _, _, err := conn.ReadMessage(); err != nil {
			if strings.Contains(err.Error(), "i/o timeout") {
				t.Fatal("登记占满后网关应关闭连接，客户端重连拿到新的上游连接")
			}
			return
		}
	}
}

func TestAppServerGatewayResetsDirectConnectionWhenTrackingExhausted(t *testing.T) {
	limitGatewayPendingTracking(t, 1, 128)
	expireGatewayPendingTracking(t)
	upstreamURL, _, _ := fakeAppServerUpstream(t, nil)
	handler, _ := appServerGatewayRouterFixture(t, upstreamURL)
	server := httptest.NewServer(handler)
	defer server.Close()

	conn := dialAuthedGateway(t, server.URL)
	defer conn.Close()
	assertGatewayResetsConnection(t, conn)
}

func TestAppServerGatewayBrokerClosesUpstreamWhenTrackingExhausted(t *testing.T) {
	limitGatewayPendingTracking(t, 1, 128)
	expireGatewayPendingTracking(t)
	up := newBrokerUpstream(t)
	server, router := brokerTestServer(t, up.url, true)

	conn := brokerDial(t, server, brokerTestSession)
	defer conn.Close()
	_ = up.accept(t)
	waitForBroker(t, router, brokerTestSession, true)
	assertGatewayResetsConnection(t, conn)
	// broker 跨重连复用同一份 policy；只摘 sink 会让新连接继续卡在旧登记上。
	waitForBroker(t, router, brokerTestSession, false)
}

func TestClaudeGatewayResetsConnectionWhenTrackingExhausted(t *testing.T) {
	limitGatewayPendingTracking(t, 1, 128)
	expireGatewayPendingTracking(t)
	bridge := writeTestBridge(t, `#!/bin/sh
while IFS= read -r line; do :; done
`)
	upstreamURL, _, _ := fakeAppServerUpstream(t, nil)
	handler, _ := appServerGatewayRouterFixtureWithRouter(t, upstreamURL, func(cfg *config.Config) {
		cfg.Claude.Enabled = true
		cfg.Claude.BridgeBin = bridge
		cfg.Claude.MaxConcurrentBridges = 3
	})
	server := httptest.NewServer(handler)
	defer server.Close()

	conn := dialAuthedGatewayRuntime(t, server.URL, "claude")
	defer conn.Close()
	assertGatewayResetsConnection(t, conn)
}

func TestAppServerGatewayResetErrorKeepsRequestID(t *testing.T) {
	limitGatewayPendingTracking(t, 1, 128)
	expireGatewayPendingTracking(t)
	policy, _ := newInboundPolicyForTest(t, appServerRuntimeCodexID)
	mustValidateClientFrame(t, policy, `{"id":1,"method":"model/list","params":{}}`)
	time.Sleep(time.Millisecond)
	_, policyErr := policy.validateClientFrame(websocket.TextMessage, []byte(`{"id":"next","method":"model/list","params":{}}`))
	if policyErr == nil || policyErr.id == nil || string(*policyErr.id) != `"next"` {
		t.Fatalf("重置错误应带上触发请求的 id，客户端才能结束等待：%+v", policyErr)
	}
	var probe json.RawMessage
	if json.Unmarshal(*policyErr.id, &probe) != nil {
		t.Fatal("错误 id 应是合法 JSON")
	}
}
