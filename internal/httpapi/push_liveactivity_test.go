package httpapi

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/pushbridge"
	"github.com/gorilla/websocket"
)

func pushJSONRequest(t *testing.T, server *httptest.Server, method string, path string, body any) (int, map[string]any) {
	t.Helper()
	var reader *bytes.Reader
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
		reader = bytes.NewReader(encoded)
	} else {
		reader = bytes.NewReader(nil)
	}
	req, err := http.NewRequest(method, server.URL+path, reader)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+testToken)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var decoded map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&decoded)
	return resp.StatusCode, decoded
}

func liveActivityRegistration(deviceID, kind, ticket, activityID string) map[string]any {
	return map[string]any{
		"device_id":   deviceID,
		"kind":        kind,
		"ticket":      ticket,
		"activity_id": activityID,
		"expires_at":  time.Now().Add(12 * time.Hour).UTC().Format(time.RFC3339),
	}
}

func pushStatusDevice(t *testing.T, server *httptest.Server, deviceID string) (map[string]any, map[string]any) {
	t.Helper()
	status, body := pushJSONRequest(t, server, http.MethodGet, "/api/push/status", nil)
	if status != http.StatusOK {
		t.Fatalf("status=%d", status)
	}
	devices, _ := body["devices"].([]any)
	for _, raw := range devices {
		device, _ := raw.(map[string]any)
		if device["device_id"] == deviceID {
			return body, device
		}
	}
	return body, nil
}

func TestPushLiveActivityRegistrationEndpoint(t *testing.T) {
	provider := newFakePushProvider(t)
	server, router := pushTestFixture(t, "ws://unused", provider.server.URL)
	const path = "/api/push/live-activities"

	if status, _ := pushJSONRequest(t, server, http.MethodPost, path,
		liveActivityRegistration("device-1", "start", "mpt1.1.start", "")); status != http.StatusConflict {
		t.Fatalf("未登记消息提醒的设备不能登记活动票据，got=%d", status)
	}
	registerPushDevice(t, server, "device-1")

	invalid := []struct {
		name string
		body map[string]any
	}{
		{"bad kind", liveActivityRegistration("device-1", "notification", "mpt1.1.x", "")},
		{"empty ticket", liveActivityRegistration("device-1", "start", "", "")},
		{"bad activity id", liveActivityRegistration("device-1", "update", "mpt1.1.x", "../etc")},
		{"bad expiry", map[string]any{"device_id": "device-1", "kind": "start", "ticket": "x", "expires_at": "tomorrow"}},
	}
	for _, tc := range invalid {
		if status, _ := pushJSONRequest(t, server, http.MethodPost, path, tc.body); status != http.StatusBadRequest {
			t.Fatalf("%s 应回 400，got=%d", tc.name, status)
		}
	}

	for _, kind := range []string{"start", "update"} {
		status, body := pushJSONRequest(t, server, http.MethodPost, path,
			liveActivityRegistration("device-1", kind, "mpt1.1."+kind, "activity-1"))
		if status != http.StatusOK || body["kind"] != kind {
			t.Fatalf("登记 %s 失败 status=%d body=%v", kind, status, body)
		}
	}
	statusBody, device := pushStatusDevice(t, server, "device-1")
	if statusBody["live_activity"] != true || statusBody["host_tag"] != router.push.HostTag() ||
		device["live_activity_start"] != true || device["live_activity_update"] != true {
		t.Fatalf("状态接口应回报活动能力与票据：%v %v", statusBody, device)
	}

	// 旧活动的迟到注销不能删掉新活动的票据。
	if status, body := pushJSONRequest(t, server, http.MethodDelete,
		path+"?device_id=device-1&kind=update&activity_id=activity-old", nil); status != http.StatusOK || body["removed"] != false {
		t.Fatalf("activity_id 不一致时不应删除：status=%d body=%v", status, body)
	}
	if status, _ := pushJSONRequest(t, server, http.MethodDelete, path+"?device_id=device-1&kind=bogus", nil); status != http.StatusBadRequest {
		t.Fatalf("非法 kind 应回 400，got=%d", status)
	}
	if status, body := pushJSONRequest(t, server, http.MethodDelete, path+"?device_id=device-1&kind=all", nil); status != http.StatusOK || body["removed"] != true {
		t.Fatalf("注销全部失败：status=%d body=%v", status, body)
	}
	if _, device := pushStatusDevice(t, server, "device-1"); device["live_activity_start"] != false || device["live_activity_update"] != false {
		t.Fatalf("注销后不应再有票据：%v", device)
	}
}

// 关闭消息提醒或删除档案时 App 注销设备：活动票据必须一并删除。
func TestPushDeviceUnregisterRemovesLiveActivityTickets(t *testing.T) {
	provider := newFakePushProvider(t)
	server, router := pushTestFixture(t, "ws://unused", provider.server.URL)
	registerPushDevice(t, server, "device-1")
	if status, _ := pushJSONRequest(t, server, http.MethodPost, "/api/push/live-activities",
		liveActivityRegistration("device-1", "start", "mpt1.1.start", "")); status != http.StatusOK {
		t.Fatalf("登记失败 status=%d", status)
	}
	if status, _ := pushJSONRequest(t, server, http.MethodDelete, "/api/push/devices?device_id=device-1", nil); status != http.StatusOK {
		t.Fatalf("注销设备失败 status=%d", status)
	}
	if start, update := router.push.LiveActivities().TicketStatus("device-1"); start || update {
		t.Fatal("注销设备后活动票据应被删除")
	}
}

func (p *fakePushProvider) waitForLiveActivity(t *testing.T, status string) map[string]any {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		p.mu.Lock()
		for _, body := range p.received {
			state, _ := body["content_state"].(map[string]any)
			if state != nil && state["status"] == status {
				p.mu.Unlock()
				return body
			}
		}
		p.mu.Unlock()
		if time.Now().After(deadline) {
			t.Fatalf("等待 Live Activity %s 超时", status)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func (p *fakePushProvider) liveActivityCount() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	count := 0
	for _, body := range p.received {
		if _, ok := body["content_state"]; ok {
			count++
		}
	}
	return count
}

// 网关帧驱动活动状态：只跟已授权线程，Provider 请求里只有枚举、计数、时间与短标签。
func TestLiveActivityFollowsGatewayFrames(t *testing.T) {
	provider := newFakePushProvider(t)
	server, router := pushTestFixture(t, "ws://unused", provider.server.URL)
	registerPushDevice(t, server, "device-1")
	if status, _ := pushJSONRequest(t, server, http.MethodPost, "/api/push/live-activities",
		liveActivityRegistration("device-1", "update", "mpt1.1.update", "activity-1")); status != http.StatusOK {
		t.Fatalf("登记失败 status=%d", status)
	}
	policy := newAppServerGatewayPolicy(router, "codex")
	unauthorized := []byte(`{"method":"turn/started","params":{"threadId":"thread-private","turn":{"id":"turn-9"}}}`)
	policy.observeUpstreamFrame(websocket.TextMessage, unauthorized)
	started := []byte(`{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-1"}}}`)
	if _, forward, err := policy.observeUpstreamFrame(websocket.TextMessage, started); err != nil || !forward {
		t.Fatalf("turn/started 被拒 forward=%v err=%v", forward, err)
	}
	running := provider.waitForLiveActivity(t, pushbridge.LiveActivityStatusRunning)
	state := running["content_state"].(map[string]any)
	if running["event"] != pushbridge.LiveActivityEventUpdate || running["ticket"] != "mpt1.1.update" ||
		state["running_count"] != float64(1) || state["focus_session_tag"] != pushbridge.MessageSessionTag("thread-1") {
		t.Fatalf("运行中状态错误（未授权线程不应计入）：%v", running)
	}

	approval := []byte(`{"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","command":"PRIVATE COMMAND"}}`)
	if _, forward, err := policy.observeUpstreamFrame(websocket.TextMessage, approval); err != nil || !forward {
		t.Fatalf("审批请求被拒 forward=%v err=%v", forward, err)
	}
	needsYou := provider.waitForLiveActivity(t, pushbridge.LiveActivityStatusNeedsYou)
	encoded, _ := json.Marshal(needsYou)
	for _, private := range []string{"thread-1", "thread-private", "PRIVATE", "approval-1", "activity-1"} {
		if strings.Contains(string(encoded), private) {
			t.Fatalf("Provider 请求泄漏 %q：%s", private, encoded)
		}
	}
	allowed := map[string]bool{"version": true, "event": true, "ticket": true, "content_state": true, "expires_at": true}
	for key := range needsYou {
		if !allowed[key] {
			t.Fatalf("update 请求出现额外字段 %q：%s", key, encoded)
		}
	}
}

// 这些帧都不能进入活动汇总：DeepSeek 不发推送（#830 实现边界）；未授权线程即使绕过
// 上游过滤直接到达也不计入；动态工具调用不是审批。
func TestLiveActivityIgnoredFrames(t *testing.T) {
	cases := []struct {
		name    string
		runtime string
		frame   appServerGatewayFrame
	}{
		{"deepseek runtime", "deepseek", appServerGatewayFrame{
			Method: "turn/started", Params: json.RawMessage(`{"threadId":"thread-1"}`),
		}},
		{"unauthorized thread", "codex", appServerGatewayFrame{
			Method: "turn/started", Params: json.RawMessage(`{"threadId":"thread-private"}`),
		}},
		{"unauthorized approval", "codex", appServerGatewayFrame{
			ID:     rawMessagePointer(json.RawMessage(`"req-1"`)),
			Method: "item/commandExecution/requestApproval",
			Params: json.RawMessage(`{"threadId":"thread-private","turnId":"t","itemId":"i"}`),
		}},
		{"dynamic tool call", "codex", appServerGatewayFrame{
			ID:     rawMessagePointer(json.RawMessage(`"req-2"`)),
			Method: "item/tool/call",
			Params: json.RawMessage(`{"threadId":"thread-1","turnId":"t","callId":"c"}`),
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			provider := newFakePushProvider(t)
			server, router := pushTestFixture(t, "ws://unused", provider.server.URL)
			registerPushDevice(t, server, "device-1")
			if status, _ := pushJSONRequest(t, server, http.MethodPost, "/api/push/live-activities",
				liveActivityRegistration("device-1", "update", "mpt1.1.update", "activity-1")); status != http.StatusOK {
				t.Fatalf("登记失败 status=%d", status)
			}
			policy := &appServerGatewayPolicy{router: router, runtimeID: tc.runtime}
			frame := tc.frame
			if frame.ID != nil {
				policy.observeLiveActivityServerRequest(&frame)
			} else {
				policy.observeLiveActivityNotification(&frame)
			}
			time.Sleep(100 * time.Millisecond)
			if got := provider.liveActivityCount(); got != 0 {
				t.Fatalf("不应产生活动推送，got=%d", got)
			}
		})
	}
}

func TestLiveActivityThreadStatusParsing(t *testing.T) {
	cases := []struct {
		raw     string
		kind    string
		waiting bool
	}{
		{`{"type":"active","activeFlags":["waitingOnApproval"]}`, "active", true},
		{`{"type":"active","activeFlags":["waitingOnUserInput"]}`, "active", true},
		{`{"type":"active","activeFlags":[]}`, "active", false},
		{`{"type":"idle"}`, "idle", false},
		{`"active"`, "", false},
	}
	for _, tc := range cases {
		kind, waiting := liveActivityThreadStatus(json.RawMessage(tc.raw))
		if kind != tc.kind || waiting != tc.waiting {
			t.Fatalf("%s → %s %v，期望 %s %v", tc.raw, kind, waiting, tc.kind, tc.waiting)
		}
	}
}
