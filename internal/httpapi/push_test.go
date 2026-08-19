package httpapi

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

const pushTestSession = "mimi-push-test-codex"

// fakePushProvider 站在 agentd 与真实 APNs 之间，让用例既能断言 agentd 发出了
// 什么，也能确认它没有发出会话内容。
type fakePushProvider struct {
	mu       sync.Mutex
	received []map[string]any
	server   *httptest.Server
	status   int
}

func newFakePushProvider(t *testing.T) *fakePushProvider {
	t.Helper()
	provider := &fakePushProvider{status: http.StatusOK}
	provider.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		var body map[string]any
		_ = json.NewDecoder(req.Body).Decode(&body)
		provider.mu.Lock()
		provider.received = append(provider.received, body)
		status := provider.status
		provider.mu.Unlock()
		w.WriteHeader(status)
		_ = json.NewEncoder(w).Encode(map[string]any{"delivered": status == http.StatusOK})
	}))
	t.Cleanup(provider.server.Close)
	return provider
}

func (p *fakePushProvider) waitFor(t *testing.T, event string) map[string]any {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		p.mu.Lock()
		for _, body := range p.received {
			if body["event"] == event {
				p.mu.Unlock()
				return body
			}
		}
		p.mu.Unlock()
		if time.Now().After(deadline) {
			t.Fatalf("等待 %s 推送超时", event)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func (p *fakePushProvider) count() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return len(p.received)
}

func pushTestFixture(t *testing.T, upstreamURL string, providerURL string) (*httptest.Server, *Router) {
	t.Helper()
	cfg, registry, manager, checker, _ := appServerGatewayBaseFixture(t)
	cfg.AppServer = config.AppServerConfig{
		Transport:      "ws",
		Managed:        true,
		Listen:         upstreamURL,
		WSTokenFile:    testAppServerTokenFile(t, "test-upstream-token"),
		ApprovalBroker: true,
	}
	cfg.Push = config.PushConfig{
		Enabled:     true,
		ProviderURL: providerURL,
		Environment: "sandbox",
	}
	configPath := filepath.Join(t.TempDir(), "config.json")
	handler, router := NewRouterWithRuntimeInstallationIDAndOptions(
		cfg, registry, manager, checker, "test", "install-push-test", nil,
		RouterOptions{ConfigPath: configPath},
	)
	t.Cleanup(router.claudeBridge.shutdown)
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	return server, router
}

func registerPushDevice(t *testing.T, server *httptest.Server, deviceID string) {
	t.Helper()
	body, err := json.Marshal(map[string]any{
		"device_id":  deviceID,
		"ticket":     "mpt1.1.opaque-ticket",
		"platform":   "ios",
		"expires_at": time.Now().Add(30 * 24 * time.Hour).UTC().Format(time.RFC3339),
	})
	if err != nil {
		t.Fatal(err)
	}
	req, err := http.NewRequest(http.MethodPost, server.URL+"/api/push/devices", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+testToken)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("注册设备失败 status=%d", resp.StatusCode)
	}
}

func postDecide(t *testing.T, server *httptest.Server, actionID string, deviceID string, decision string) (int, map[string]any) {
	t.Helper()
	body, err := json.Marshal(map[string]any{
		"action_id": actionID,
		"device_id": deviceID,
		"decision":  decision,
	})
	if err != nil {
		t.Fatal(err)
	}
	req, err := http.NewRequest(http.MethodPost, server.URL+"/api/push/actions/decide", bytes.NewReader(body))
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

// MIM-112 的完整闭环：App 退到后台后到达的审批请求触发提醒，用户在锁屏放行，
// 决策原路回到 runtime。
func TestApprovalArrivingWhileClientOfflineNotifiesAndCanBeDecided(t *testing.T) {
	up := newBrokerUpstream(t)
	provider := newFakePushProvider(t)
	server, router := pushTestFixture(t, up.url, provider.server.URL)
	registerPushDevice(t, server, "device-a")

	client := brokerDial(t, server, pushTestSession)
	upstream := up.accept(t)
	up.emit(t, upstream, brokerTurnStartedFrame)
	readFrameWithMethod(t, client, "turn/started", 3*time.Second)

	// App 退到后台：系统挂起 WebSocket。
	_ = client.Close()
	waitForBroker(t, router, pushTestSession, true)

	up.emit(t, upstream, brokerApprovalFrame)
	notification := provider.waitFor(t, "approval.pending")

	if notification["runtime"] != "codex" || notification["approval_kind"] != "command" {
		t.Fatalf("推送内容不正确：%v", notification)
	}
	encoded, err := json.Marshal(notification)
	if err != nil {
		t.Fatal(err)
	}
	// 推送里不能出现命令、线程 id 或任何会话内容。
	for _, forbidden := range []string{"\"ls\"", "thread-1", "call-1", testToken} {
		if bytes.Contains(encoded, []byte(forbidden)) {
			t.Fatalf("推送泄漏了 %q：%s", forbidden, encoded)
		}
	}
	actionID, _ := notification["action_id"].(string)
	if actionID == "" {
		t.Fatalf("推送缺少 action_id：%v", notification)
	}

	status, body := postDecide(t, server, actionID, "device-a", "allow")
	if status != http.StatusOK {
		t.Fatalf("锁屏放行失败 status=%d body=%v", status, body)
	}
	if body["state"] != "approved" {
		t.Fatalf("放行后状态应为 approved：%v", body)
	}

	// 决策必须真的回到 runtime，而不是只在 agentd 内部落定。
	response := up.waitForUpstreamFrame(t, func(payload []byte) bool {
		var frame struct {
			ID string `json:"id"`
		}
		return json.Unmarshal(payload, &frame) == nil && frame.ID == "approval-1"
	}, 3*time.Second)
	if !strings.Contains(string(response), `"decision":"accept"`) {
		t.Fatalf("上游收到的决策不正确：%s", response)
	}
}

// 客户端在线时审批卡片本来就会实时出现，不能再推一条重复打扰。
func TestApprovalWhileClientOnlineIsNotPushed(t *testing.T) {
	up := newBrokerUpstream(t)
	provider := newFakePushProvider(t)
	server, _ := pushTestFixture(t, up.url, provider.server.URL)
	registerPushDevice(t, server, "device-a")

	client := brokerDial(t, server, pushTestSession)
	upstream := up.accept(t)
	up.emit(t, upstream, brokerTurnStartedFrame)
	readFrameWithMethod(t, client, "turn/started", 3*time.Second)
	up.emit(t, upstream, brokerApprovalFrame)
	readFrameWithMethod(t, client, "execCommandApproval", 3*time.Second)

	time.Sleep(300 * time.Millisecond)
	if provider.count() != 0 {
		t.Fatalf("客户端在线时不应推送，got=%d", provider.count())
	}
}

// 没有注册设备就等于用户没同意：链路上不能产生任何对外请求。
func TestNoRegisteredDeviceMeansNoProviderTraffic(t *testing.T) {
	up := newBrokerUpstream(t)
	provider := newFakePushProvider(t)
	server, router := pushTestFixture(t, up.url, provider.server.URL)

	client := brokerDial(t, server, pushTestSession)
	upstream := up.accept(t)
	up.emit(t, upstream, brokerTurnStartedFrame)
	readFrameWithMethod(t, client, "turn/started", 3*time.Second)
	_ = client.Close()
	waitForBroker(t, router, pushTestSession, true)
	up.emit(t, upstream, brokerApprovalFrame)

	time.Sleep(300 * time.Millisecond)
	if provider.count() != 0 {
		t.Fatalf("未注册设备时不应有任何 Provider 请求，got=%d", provider.count())
	}
}

func TestPushStatusReportsActionableKinds(t *testing.T) {
	up := newBrokerUpstream(t)
	provider := newFakePushProvider(t)
	server, _ := pushTestFixture(t, up.url, provider.server.URL)
	registerPushDevice(t, server, "device-a")

	req, err := http.NewRequest(http.MethodGet, server.URL+"/api/push/status", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+testToken)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var body map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	if body["enabled"] != true || body["provider_configured"] != true {
		t.Fatalf("状态不正确：%v", body)
	}
	kinds, _ := body["actionable_kinds"].([]any)
	if len(kinds) != 2 {
		t.Fatalf("锁屏可直接放行的类型应只有 command 与 patch：%v", body["actionable_kinds"])
	}
	devices, _ := body["devices"].([]any)
	if len(devices) != 1 {
		t.Fatalf("应报告一台已注册设备：%v", body["devices"])
	}
}

// 只能在 App 内处理的审批类型，即使拿到 action_id 也不能从锁屏直接放行。
func TestNonActionableKindIsRefusedAtDecideEndpoint(t *testing.T) {
	up := newBrokerUpstream(t)
	provider := newFakePushProvider(t)
	server, router := pushTestFixture(t, up.url, provider.server.URL)
	registerPushDevice(t, server, "device-a")

	client := brokerDial(t, server, pushTestSession)
	upstream := up.accept(t)
	up.emit(t, upstream, brokerTurnStartedFrame)
	readFrameWithMethod(t, client, "turn/started", 3*time.Second)
	_ = client.Close()
	waitForBroker(t, router, pushTestSession, true)

	up.emit(t, upstream, `{"jsonrpc":"2.0","id":"elicit-1","method":"mcpServer/elicitation/request","params":{"threadId":"thread-1","turnId":"turn-1"}}`)
	notification := provider.waitFor(t, "approval.pending")
	if notification["approval_kind"] != "elicitation" {
		t.Fatalf("类型识别错误：%v", notification)
	}
	actionID, _ := notification["action_id"].(string)

	status, body := postDecide(t, server, actionID, "device-a", "allow")
	if status != http.StatusBadGateway {
		t.Fatalf("不可锁屏放行的类型应被拒绝：status=%d body=%v", status, body)
	}
}

func TestDecideRejectsUnknownDeviceAndAction(t *testing.T) {
	up := newBrokerUpstream(t)
	provider := newFakePushProvider(t)
	server, _ := pushTestFixture(t, up.url, provider.server.URL)
	registerPushDevice(t, server, "device-a")

	if status, _ := postDecide(t, server, "act-unknown", "device-a", "allow"); status != http.StatusNotFound {
		t.Fatalf("未知句柄应返回 404，got=%d", status)
	}
	if status, _ := postDecide(t, server, "act-unknown", "device-a", "maybe"); status != http.StatusBadRequest {
		t.Fatalf("非法 decision 应返回 400，got=%d", status)
	}
}

// 决策帧必须与 iOS 前台响应同形，才能复用 gateway 的既有安全判定。
func TestApprovalResponseFrameMatchesClientShape(t *testing.T) {
	payload, err := buildApprovalResponseFrame(`"approval-1"`, "allow")
	if err != nil {
		t.Fatal(err)
	}
	var frame struct {
		JSONRPC string `json:"jsonrpc"`
		ID      string `json:"id"`
		Result  struct {
			Decision string `json:"decision"`
		} `json:"result"`
	}
	if err := json.Unmarshal(payload, &frame); err != nil {
		t.Fatal(err)
	}
	if frame.JSONRPC != "2.0" || frame.ID != "approval-1" || frame.Result.Decision != "accept" {
		t.Fatalf("响应帧形状不正确：%s", payload)
	}
	denied, err := buildApprovalResponseFrame(`"approval-1"`, "deny")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(denied, []byte(`"decision":"decline"`)) {
		t.Fatalf("拒绝应映射为 decline：%s", denied)
	}
	if _, err := buildApprovalResponseFrame("", "allow"); err == nil {
		t.Fatal("缺少请求 id 时必须失败")
	}
}

// 配置文件不一定叫 config.json。按文件名裁剪会拼出既不报错也不正确的路径，
// 设备注册表就会落在一个谁也找不到的地方。
func TestPushDeviceStorePathFollowsConfigDirectory(t *testing.T) {
	cases := map[string]string{
		"/Users/me/.config/mimi/config.json": "/Users/me/.config/mimi/push-devices.json",
		"/etc/mimi/agentd.json":              "/etc/mimi/push-devices.json",
		"/opt/mimi/custom-name.json":         "/opt/mimi/push-devices.json",
	}
	for configPath, want := range cases {
		if got := pushDeviceStorePath(configPath); got != want {
			t.Fatalf("pushDeviceStorePath(%q) = %q，期望 %q", configPath, got, want)
		}
	}
	if got := pushDeviceStorePath("  "); got != "" {
		t.Fatalf("没有配置路径时应返回空，got=%q", got)
	}
}
