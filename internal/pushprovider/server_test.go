package pushprovider

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

type fakeAPNs struct {
	mu       sync.Mutex
	requests []fakeAPNsRequest
	status   int
	reason   string
	server   *httptest.Server
}

type fakeAPNsRequest struct {
	Path       string
	Topic      string
	PushType   string
	CollapseID string
	Priority   string
	Expiration string
	Payload    map[string]any
	AuthHeader string
}

func newFakeAPNs(t *testing.T) *fakeAPNs {
	t.Helper()
	fake := &fakeAPNs{status: http.StatusOK}
	fake.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		var payload map[string]any
		_ = json.NewDecoder(req.Body).Decode(&payload)
		fake.mu.Lock()
		fake.requests = append(fake.requests, fakeAPNsRequest{
			Path:       req.URL.Path,
			Topic:      req.Header.Get("apns-topic"),
			PushType:   req.Header.Get("apns-push-type"),
			CollapseID: req.Header.Get("apns-collapse-id"),
			Priority:   req.Header.Get("apns-priority"),
			Expiration: req.Header.Get("apns-expiration"),
			Payload:    payload,
			AuthHeader: req.Header.Get("authorization"),
		})
		status, reason := fake.status, fake.reason
		fake.mu.Unlock()
		w.Header().Set("apns-id", "fake-apns-id")
		w.WriteHeader(status)
		if reason != "" {
			_ = json.NewEncoder(w).Encode(map[string]string{"reason": reason})
		}
	}))
	t.Cleanup(fake.server.Close)
	return fake
}

func (f *fakeAPNs) setResponse(status int, reason string) {
	f.mu.Lock()
	f.status, f.reason = status, reason
	f.mu.Unlock()
}

func (f *fakeAPNs) last(t *testing.T) fakeAPNsRequest {
	t.Helper()
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.requests) == 0 {
		t.Fatal("APNs 没有收到任何投递")
	}
	return f.requests[len(f.requests)-1]
}

func (f *fakeAPNs) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.requests)
}

func newTestServer(t *testing.T, fake *fakeAPNs) (*Server, *httptest.Server) {
	t.Helper()
	sealer, err := NewTicketSealer(map[int][]byte{1: bytes.Repeat([]byte{7}, 32)}, 1, 24*time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	store, err := OpenRevocationStore(filepath.Join(t.TempDir(), "revocations.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })

	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	credentials := APNsCredentials{KeyID: "TESTKEYID1", TeamID: "TESTTEAMID", Key: key}
	client := NewAPNsClient(fake.server.URL, credentials)
	server, err := NewServer(Options{
		Sealer:      sealer,
		Store:       store,
		Topic:       "app.mimi.remote",
		Environment: "production",
		Clients:     map[string]*APNsClient{"production": client, "sandbox": client},
	})
	if err != nil {
		t.Fatal(err)
	}
	httpServer := httptest.NewServer(server.Handler())
	t.Cleanup(httpServer.Close)
	return server, httpServer
}

func postJSON(t *testing.T, url string, body any) (int, map[string]any) {
	t.Helper()
	encoded, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}
	resp, err := http.Post(url, "application/json", bytes.NewReader(encoded))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var decoded map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&decoded)
	return resp.StatusCode, decoded
}

func issueTestTicket(t *testing.T, base string) string {
	t.Helper()
	status, body := postJSON(t, base+"/v1/ticket", map[string]any{
		"version":      1,
		"environment":  "production",
		"device_token": strings.Repeat("ab", 32),
		"installation": "install-abc123",
	})
	if status != http.StatusOK {
		t.Fatalf("签发 Ticket 失败 status=%d body=%v", status, body)
	}
	ticket, _ := body["ticket"].(string)
	if ticket == "" {
		t.Fatalf("响应缺少 ticket: %v", body)
	}
	return ticket
}

func approvalBody(ticket string, overrides map[string]any) map[string]any {
	body := map[string]any{
		"version":       1,
		"event":         "approval.pending",
		"ticket":        ticket,
		"action_id":     "action-0123456789abcdef",
		"device_id":     "device-abc",
		"profile_id":    "profile-abc",
		"runtime":       "codex",
		"approval_kind": "command",
		"host_tag":      "A1C3",
		"session_tag":   "7D92",
		"expires_at":    time.Now().Add(5 * time.Minute).UTC().Format(time.RFC3339),
	}
	for key, value := range overrides {
		body[key] = value
	}
	return body
}

func TestProviderDeliversApprovalWithoutContent(t *testing.T) {
	fake := newFakeAPNs(t)
	_, httpServer := newTestServer(t, fake)
	ticket := issueTestTicket(t, httpServer.URL)

	status, body := postJSON(t, httpServer.URL+"/v1/notify", approvalBody(ticket, nil))
	if status != http.StatusOK {
		t.Fatalf("投递失败 status=%d body=%v", status, body)
	}
	request := fake.last(t)
	if request.Topic != "app.mimi.remote" {
		t.Fatalf("apns-topic = %q", request.Topic)
	}
	if request.PushType != "alert" {
		t.Fatalf("apns-push-type = %q", request.PushType)
	}
	if request.Priority != "10" {
		t.Fatalf("待审批通知应使用高优先级，got=%q", request.Priority)
	}
	if request.CollapseID != CollapseID("action-0123456789abcdef") {
		t.Fatalf("apns-collapse-id 不稳定：%q", request.CollapseID)
	}
	if !strings.HasSuffix(request.Path, strings.Repeat("ab", 32)) {
		t.Fatalf("投递路径未使用 Ticket 内的 Device Token：%s", request.Path)
	}
	if !strings.HasPrefix(request.AuthHeader, "bearer ") {
		t.Fatalf("缺少 provider token：%q", request.AuthHeader)
	}

	// Payload 只能有本地化 key 与不透明标识；任何自由文本都是泄漏。
	encoded, err := json.Marshal(request.Payload)
	if err != nil {
		t.Fatal(err)
	}
	aps, _ := request.Payload["aps"].(map[string]any)
	alert, _ := aps["alert"].(map[string]any)
	if alert["title-loc-key"] != "push.approval.title.codex" {
		t.Fatalf("标题必须使用 App 内本地化 key：%v", alert)
	}
	if alert["loc-key"] != "push.approval.body.command" {
		t.Fatalf("正文必须使用 App 内本地化 key：%v", alert)
	}
	if _, hasBody := alert["body"]; hasBody {
		t.Fatalf("Payload 不能包含正文文本：%s", encoded)
	}
	if aps["category"] != ApprovalCategory {
		t.Fatalf("缺少审批动作类别：%v", aps)
	}
	if aps["thread-id"] != "7D92" {
		t.Fatalf("通知必须按会话归组：%v", aps)
	}
	for _, forbidden := range []string{"ls", "command\":\"", "Bearer", "mpt1."} {
		if bytes.Contains(encoded, []byte(forbidden)) {
			t.Fatalf("Payload 泄漏了 %q：%s", forbidden, encoded)
		}
	}
}

func TestProviderRejectsUnknownEnumsAndFreeText(t *testing.T) {
	fake := newFakeAPNs(t)
	_, httpServer := newTestServer(t, fake)
	ticket := issueTestTicket(t, httpServer.URL)

	cases := []struct {
		name      string
		overrides map[string]any
	}{
		{name: "未知 runtime", overrides: map[string]any{"runtime": "gemini"}},
		{name: "未知审批类型", overrides: map[string]any{"approval_kind": "rm -rf"}},
		{name: "未知事件", overrides: map[string]any{"event": "approval.custom"}},
		{name: "主机标签塞入主机名", overrides: map[string]any{"host_tag": "landy-macbook"}},
		{name: "会话标签塞入标题", overrides: map[string]any{"session_tag": "修复登录"}},
		{name: "过期时间超上限", overrides: map[string]any{"expires_at": time.Now().Add(4 * time.Hour).UTC().Format(time.RFC3339)}},
		{name: "已过期", overrides: map[string]any{"expires_at": time.Now().Add(-time.Minute).UTC().Format(time.RFC3339)}},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			status, _ := postJSON(t, httpServer.URL+"/v1/notify", approvalBody(ticket, test.overrides))
			if status != http.StatusBadRequest {
				t.Fatalf("应拒绝，got status=%d", status)
			}
		})
	}
	if fake.count() != 0 {
		t.Fatalf("非法请求不能触发任何 APNs 投递，count=%d", fake.count())
	}
}

// Provider 只接受固定 Schema：任何额外字段都可能是把自由文本推上锁屏的入口。
func TestProviderRejectsUnknownFields(t *testing.T) {
	fake := newFakeAPNs(t)
	_, httpServer := newTestServer(t, fake)
	ticket := issueTestTicket(t, httpServer.URL)

	body := approvalBody(ticket, nil)
	body["aps"] = map[string]any{"alert": map[string]any{"body": "rm -rf /"}}
	status, _ := postJSON(t, httpServer.URL+"/v1/notify", body)
	if status != http.StatusBadRequest {
		t.Fatalf("含未知字段的请求应被拒绝，got=%d", status)
	}
	if fake.count() != 0 {
		t.Fatal("被拒绝的请求不能触发投递")
	}
}

func TestProviderRejectsTamperedAndRevokedTickets(t *testing.T) {
	fake := newFakeAPNs(t)
	_, httpServer := newTestServer(t, fake)
	ticket := issueTestTicket(t, httpServer.URL)

	tampered := ticket[:len(ticket)-2] + "AA"
	status, _ := postJSON(t, httpServer.URL+"/v1/notify", approvalBody(tampered, nil))
	if status != http.StatusUnauthorized {
		t.Fatalf("篡改的 Ticket 应被拒绝，got=%d", status)
	}

	if status, body := postJSON(t, httpServer.URL+"/v1/ticket/revoke", map[string]any{
		"version": 1,
		"ticket":  ticket,
	}); status != http.StatusOK {
		t.Fatalf("撤销失败 status=%d body=%v", status, body)
	}
	status, _ = postJSON(t, httpServer.URL+"/v1/notify", approvalBody(ticket, nil))
	if status != http.StatusForbidden {
		t.Fatalf("已撤销的 Ticket 应被拒绝，got=%d", status)
	}
	if fake.count() != 0 {
		t.Fatal("无效或已撤销的 Ticket 不能触发投递")
	}
}

// APNs 报告 Token 失效时必须自动撤销，避免继续对死 Token 投递。
func TestProviderAutoRevokesUnregisteredToken(t *testing.T) {
	fake := newFakeAPNs(t)
	_, httpServer := newTestServer(t, fake)
	ticket := issueTestTicket(t, httpServer.URL)

	fake.setResponse(http.StatusGone, "Unregistered")
	status, _ := postJSON(t, httpServer.URL+"/v1/notify", approvalBody(ticket, nil))
	if status != http.StatusGone {
		t.Fatalf("Unregistered 应回 410，got=%d", status)
	}
	fake.setResponse(http.StatusOK, "")
	status, _ = postJSON(t, httpServer.URL+"/v1/notify", approvalBody(ticket, nil))
	if status != http.StatusForbidden {
		t.Fatalf("Unregistered 之后 Ticket 应已被撤销，got=%d", status)
	}
}

// 已处理事件走静默更新：它只让其它设备清理旧通知，不能再震一次用户。
func TestProviderResolvedEventIsSilent(t *testing.T) {
	fake := newFakeAPNs(t)
	_, httpServer := newTestServer(t, fake)
	ticket := issueTestTicket(t, httpServer.URL)

	status, body := postJSON(t, httpServer.URL+"/v1/notify", approvalBody(ticket, map[string]any{
		"event": "approval.resolved",
	}))
	if status != http.StatusOK {
		t.Fatalf("投递失败 status=%d body=%v", status, body)
	}
	request := fake.last(t)
	if request.Priority != "5" {
		t.Fatalf("状态更新应使用低优先级，got=%q", request.Priority)
	}
	aps, _ := request.Payload["aps"].(map[string]any)
	if _, hasCategory := aps["category"]; hasCategory {
		t.Fatalf("状态更新不应再提供审批动作：%v", aps)
	}
	if aps["content-available"] != float64(1) {
		t.Fatalf("状态更新应是静默推送：%v", aps)
	}
}

func TestTicketSurvivesKeyRotationAndRejectsRetiredKey(t *testing.T) {
	oldKey := bytes.Repeat([]byte{1}, 32)
	newKey := bytes.Repeat([]byte{2}, 32)
	now := time.Now()

	previous, err := NewTicketSealer(map[int][]byte{1: oldKey}, 1, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	ticket, _, err := previous.Issue("production", "app.mimi.remote", strings.Repeat("ab", 32), "digest", now)
	if err != nil {
		t.Fatal(err)
	}

	// 轮换中：新旧密钥并存，旧 Ticket 必须继续可用。
	rotating, err := NewTicketSealer(map[int][]byte{1: oldKey, 2: newKey}, 2, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := rotating.Open(ticket, now); err != nil {
		t.Fatalf("轮换期间旧 Ticket 应继续可用：%v", err)
	}

	// 轮换完成、旧密钥退役后，旧 Ticket 必须失效。
	rotated, err := NewTicketSealer(map[int][]byte{2: newKey}, 2, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := rotated.Open(ticket, now); err == nil {
		t.Fatal("旧密钥退役后旧 Ticket 必须失效")
	}
}

func TestTicketRejectsExpiryAndCrossKeyReplay(t *testing.T) {
	keyA := bytes.Repeat([]byte{3}, 32)
	keyB := bytes.Repeat([]byte{4}, 32)
	now := time.Now()

	sealer, err := NewTicketSealer(map[int][]byte{1: keyA, 2: keyB}, 1, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	ticket, _, err := sealer.Issue("production", "app.mimi.remote", strings.Repeat("cd", 32), "digest", now)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := sealer.Open(ticket, now.Add(2*time.Minute)); err == nil {
		t.Fatal("过期 Ticket 必须被拒绝")
	}
	// 把密文改挂到另一版密钥下：密钥版本参与 AEAD 认证，必须失败。
	moved := strings.Replace(ticket, "mpt1.1.", "mpt1.2.", 1)
	if _, err := sealer.Open(moved, now); err == nil {
		t.Fatal("跨密钥版本重放必须被拒绝")
	}
}

func TestRevocationStorePurgesExpiredEntriesOnly(t *testing.T) {
	store, err := OpenRevocationStore(filepath.Join(t.TempDir(), "revocations.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	now := time.Now()
	ctx := t.Context()
	if err := store.Revoke(ctx, "expired-ticket", now.Add(-time.Hour)); err != nil {
		t.Fatal(err)
	}
	if err := store.Revoke(ctx, "live-ticket", now.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	removed, err := store.Purge(ctx, now)
	if err != nil {
		t.Fatal(err)
	}
	if removed != 1 {
		t.Fatalf("应只清理已到期记录，removed=%d", removed)
	}
	if revoked, err := store.Revoked(ctx, "live-ticket"); err != nil || !revoked {
		t.Fatalf("未到期的撤销记录不能被清掉 revoked=%v err=%v", revoked, err)
	}
}

func TestProviderRateLimitsPerTicket(t *testing.T) {
	fake := newFakeAPNs(t)
	_, httpServer := newTestServer(t, fake)
	ticket := issueTestTicket(t, httpServer.URL)

	limited := false
	for i := 0; i < rateBurst+5; i++ {
		status, _ := postJSON(t, httpServer.URL+"/v1/notify", approvalBody(ticket, nil))
		if status == http.StatusTooManyRequests {
			limited = true
			break
		}
	}
	if !limited {
		t.Fatal("同一张 Ticket 的高频投递必须被限速")
	}
}
