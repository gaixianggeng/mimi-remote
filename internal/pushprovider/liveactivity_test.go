package pushprovider

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"log"
	"net/http"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

const (
	testBundleTopic       = "app.mimi.remote"
	testLiveActivityTopic = "app.mimi.remote.push-type.liveactivity"
)

var testActivityToken = strings.Repeat("cd", 80)

type testClock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *testClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *testClock) Advance(d time.Duration) {
	c.mu.Lock()
	c.now = c.now.Add(d)
	c.mu.Unlock()
}

// manualScheduler 代替 time.AfterFunc：合并窗口何时结束完全由用例决定，不依赖真实时钟。
type manualScheduler struct {
	mu     sync.Mutex
	calls  []func()
	delays []time.Duration
}

func (m *manualScheduler) schedule(delay time.Duration, fn func()) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.calls = append(m.calls, fn)
	m.delays = append(m.delays, delay)
}

func (m *manualScheduler) scheduled() []time.Duration {
	m.mu.Lock()
	defer m.mu.Unlock()
	return append([]time.Duration(nil), m.delays...)
}

func (m *manualScheduler) runPending() {
	m.mu.Lock()
	calls := m.calls
	m.calls = nil
	m.mu.Unlock()
	for _, fn := range calls {
		fn()
	}
}

type liveActivityHarness struct {
	t      *testing.T
	fake   *fakeAPNs
	server *Server
	base   string
	clock  *testClock
	sched  *manualScheduler
}

func newLiveActivityHarness(t *testing.T) *liveActivityHarness {
	t.Helper()
	fake := newFakeAPNs(t)
	server, httpServer := newTestServer(t, fake)
	clock := &testClock{now: time.Now().Truncate(time.Second)}
	sched := &manualScheduler{}
	server.now = clock.Now
	server.activities.schedule = sched.schedule
	return &liveActivityHarness{t: t, fake: fake, server: server, base: httpServer.URL, clock: clock, sched: sched}
}

func (h *liveActivityHarness) issue(kind string) string {
	h.t.Helper()
	token := strings.Repeat("ab", 32)
	if kind != "" && kind != "notification" {
		token = testActivityToken
	}
	status, body := postJSON(h.t, h.base+"/v1/ticket", map[string]any{
		"version":      1,
		"environment":  "production",
		"device_token": token,
		"installation": "install-abc123",
		"kind":         kind,
	})
	if status != http.StatusOK {
		h.t.Fatalf("签发 %q Ticket 失败 status=%d body=%v", kind, status, body)
	}
	return body["ticket"].(string)
}

func (h *liveActivityHarness) post(body map[string]any) (int, map[string]any) {
	h.t.Helper()
	return postJSON(h.t, h.base+"/v1/notify/liveactivity", body)
}

// removeField 作为覆盖值时表示删掉该字段。
var removeField = &struct{}{}

func (h *liveActivityHarness) body(ticket string, event string, overrides map[string]any) map[string]any {
	now := h.clock.Now()
	body := map[string]any{
		"version": 1,
		"event":   event,
		"ticket":  ticket,
		"content_state": map[string]any{
			"status":            "running",
			"running_count":     2,
			"needs_you_count":   1,
			"started_at":        now.Add(-10 * time.Minute).Unix(),
			"focus_session_tag": "7D92",
		},
		"expires_at": now.Add(time.Hour).UTC().Format(time.RFC3339),
	}
	if event == liveActivityEventStart {
		body["attributes_type"] = LiveActivityAttributesType
		body["attributes"] = map[string]any{"host_tag": "A1C3"}
	}
	for key, value := range overrides {
		target, field := body, key
		if parent, child, nested := strings.Cut(key, "."); nested {
			if _, ok := body[parent].(map[string]any); !ok {
				body[parent] = map[string]any{}
			}
			target, field = body[parent].(map[string]any), child
		}
		if value == removeField {
			delete(target, field)
		} else {
			target[field] = value
		}
	}
	return body
}

func sealRawClaims(t *testing.T, sealer *TicketSealer, claims map[string]any) string {
	t.Helper()
	plaintext, err := json.Marshal(claims)
	if err != nil {
		t.Fatal(err)
	}
	aead := sealer.keys[sealer.currentVersion]
	nonce := make([]byte, aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		t.Fatal(err)
	}
	version := strconv.Itoa(sealer.currentVersion)
	sealed := aead.Seal(nonce, nonce, plaintext, []byte(ticketPrefix+"."+version))
	return ticketPrefix + "." + version + "." + base64.RawURLEncoding.EncodeToString(sealed)
}

func openPlaintext(t *testing.T, sealer *TicketSealer, ticket string) []byte {
	t.Helper()
	parts := strings.Split(ticket, ".")
	sealed, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		t.Fatal(err)
	}
	aead := sealer.keys[sealer.currentVersion]
	plaintext, err := aead.Open(nil, sealed[:aead.NonceSize()], sealed[aead.NonceSize():], []byte(ticketPrefix+"."+parts[1]))
	if err != nil {
		t.Fatal(err)
	}
	return plaintext
}

func TestTicketKindsSealAndOpen(t *testing.T) {
	sealer, err := NewTicketSealer(map[int][]byte{1: bytes.Repeat([]byte{9}, 32)}, 1, ticketMaxLifetime)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	for _, test := range []struct {
		kind         string
		wantVersion  int
		wantLifetime time.Duration
	}{
		{kind: ticketKindNotification, wantVersion: 1, wantLifetime: ticketMaxLifetime},
		{kind: ticketKindActivityUpdate, wantVersion: 2, wantLifetime: activityUpdateTicketLifetime},
		{kind: ticketKindActivityStart, wantVersion: 2, wantLifetime: ticketMaxLifetime},
	} {
		t.Run("kind="+test.kind, func(t *testing.T) {
			ticket, issued, err := sealer.IssueKind(test.kind, "production", testBundleTopic, testActivityToken, "digest", now)
			if err != nil {
				t.Fatal(err)
			}
			claims, err := sealer.Open(ticket, now)
			if err != nil {
				t.Fatal(err)
			}
			if claims.Kind != test.kind || claims.Version != test.wantVersion || claims.ID != issued.ID {
				t.Fatalf("claims = %+v", claims)
			}
			if got := time.Duration(claims.ExpiresAt-claims.IssuedAt) * time.Second; got != test.wantLifetime {
				t.Fatalf("lifetime = %s, want %s", got, test.wantLifetime)
			}
			// 通知 Ticket 的明文必须与旧格式一致：不出现 kind 字段。
			hasKind := bytes.Contains(openPlaintext(t, sealer, ticket), []byte(`"kind"`))
			if hasKind != (test.kind != ticketKindNotification) {
				t.Fatalf("kind 字段出现与否不符合预期 hasKind=%v", hasKind)
			}
		})
	}
	if _, err := sealer.Seal(TicketClaims{ID: "x", Topic: "t", DeviceToken: "ab", Kind: "bogus"}); err == nil {
		t.Fatal("未知用途不能封装成 Ticket")
	}
}

func TestTicketOpenRejectsVersionKindMismatch(t *testing.T) {
	sealer, err := NewTicketSealer(map[int][]byte{1: bytes.Repeat([]byte{9}, 32)}, 1, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	base := func(version int, kind string) map[string]any {
		claims := map[string]any{
			"v": version, "tid": "ticket-1", "env": "production", "topic": testBundleTopic,
			"dt": strings.Repeat("ab", 32), "idg": "digest", "iat": now.Unix(), "exp": now.Add(time.Hour).Unix(),
		}
		if kind != "" {
			claims["kind"] = kind
		}
		return claims
	}
	for _, test := range []struct {
		name     string
		claims   map[string]any
		wantOpen bool
		wantKind string
	}{
		{name: "旧版 v1 通知 Ticket", claims: base(1, ""), wantOpen: true},
		{name: "v2 活动更新 Ticket", claims: base(2, ticketKindActivityUpdate), wantOpen: true, wantKind: ticketKindActivityUpdate},
		{name: "v1 冒充活动用途", claims: base(1, ticketKindActivityUpdate)},
		{name: "v2 缺少用途", claims: base(2, "")},
		{name: "v2 未知用途", claims: base(2, "alert")},
		{name: "未知版本", claims: base(3, ticketKindActivityStart)},
	} {
		t.Run(test.name, func(t *testing.T) {
			claims, err := sealer.Open(sealRawClaims(t, sealer, test.claims), now)
			if test.wantOpen != (err == nil) {
				t.Fatalf("open err=%v, wantOpen=%v", err, test.wantOpen)
			}
			if err == nil && claims.Kind != test.wantKind {
				t.Fatalf("kind = %q, want %q", claims.Kind, test.wantKind)
			}
		})
	}
}

func TestIssueTicketKindsOverHTTP(t *testing.T) {
	for _, test := range []struct {
		name       string
		kind       any
		token      string
		wantStatus int
		wantError  string
		wantKind   string
		wantTopic  string
		wantLife   time.Duration
	}{
		{name: "旧客户端不带 kind", kind: removeField, token: strings.Repeat("ab", 32), wantStatus: 200, wantTopic: testBundleTopic, wantLife: 24 * time.Hour},
		{name: "显式 notification", kind: "notification", token: strings.Repeat("ab", 32), wantStatus: 200, wantTopic: testBundleTopic, wantLife: 24 * time.Hour},
		{name: "活动更新 Token", kind: ticketKindActivityUpdate, token: testActivityToken, wantStatus: 200, wantKind: ticketKindActivityUpdate, wantTopic: testLiveActivityTopic, wantLife: 24 * time.Hour},
		{name: "push-to-start Token", kind: ticketKindActivityStart, token: testActivityToken, wantStatus: 200, wantKind: ticketKindActivityStart, wantTopic: testLiveActivityTopic, wantLife: 24 * time.Hour},
		{name: "未知用途", kind: "alert", token: strings.Repeat("ab", 32), wantStatus: 400, wantError: "unsupported_ticket_kind"},
		{name: "通知 Token 长度上限不变", kind: "notification", token: strings.Repeat("ab", 150), wantStatus: 400, wantError: "invalid_device_token"},
		{name: "活动 Token 超长", kind: ticketKindActivityUpdate, token: strings.Repeat("ab", 201), wantStatus: 400, wantError: "invalid_device_token"},
		{name: "活动 Token 非十六进制", kind: ticketKindActivityStart, token: strings.Repeat("zz", 40), wantStatus: 400, wantError: "invalid_device_token"},
	} {
		t.Run(test.name, func(t *testing.T) {
			h := newLiveActivityHarness(t)
			request := map[string]any{
				"version": 1, "environment": "production", "device_token": test.token,
				"installation": "install-abc123", "kind": test.kind,
			}
			if test.kind == removeField {
				delete(request, "kind")
			}
			status, body := postJSON(t, h.base+"/v1/ticket", request)
			if status != test.wantStatus {
				t.Fatalf("status=%d body=%v", status, body)
			}
			if test.wantError != "" {
				if body["error"] != test.wantError {
					t.Fatalf("error = %v", body["error"])
				}
				return
			}
			if got, want := sortedKeys(body), []string{"expires_at", "ticket"}; !reflect.DeepEqual(got, want) {
				t.Fatalf("签发响应的字段必须保持不变：%v", got)
			}
			claims, err := h.server.sealer.Open(body["ticket"].(string), h.clock.Now())
			if err != nil {
				t.Fatal(err)
			}
			if claims.Kind != test.wantKind || claims.Topic != test.wantTopic || claims.DeviceToken != test.token {
				t.Fatalf("claims = %+v", claims)
			}
			if got := time.Duration(claims.ExpiresAt-claims.IssuedAt) * time.Second; got != test.wantLife {
				t.Fatalf("lifetime = %s", got)
			}
		})
	}
}

func TestLiveActivityPayloadMatchesAppleSchema(t *testing.T) {
	for _, test := range []struct {
		name         string
		kind         string
		event        string
		overrides    map[string]any
		wantPriority string
		wantExtra    map[string]any
		wantState    map[string]any
	}{
		{
			name: "start 远程启动", kind: ticketKindActivityStart, event: liveActivityEventStart, wantPriority: "10",
			wantExtra: map[string]any{
				"attributes-type": LiveActivityAttributesType,
				"attributes":      map[string]any{"hostTag": "A1C3"},
				"alert": map[string]any{
					"title": map[string]any{"loc-key": liveActivityStartTitleKey},
					"body":  map[string]any{"loc-key": liveActivityStartBodyKey},
				},
				"input-push-token": float64(1),
			},
		},
		{name: "update 运行中用低优先级", kind: ticketKindActivityUpdate, event: liveActivityEventUpdate, wantPriority: "5"},
		{
			name: "update 带 stale-date", kind: ticketKindActivityUpdate, event: liveActivityEventUpdate, wantPriority: "5",
			overrides: map[string]any{"stale_date": "+30m"},
			wantExtra: map[string]any{"stale-date": "+30m"},
		},
		{
			name: "update 待你处理用高优先级", kind: ticketKindActivityUpdate, event: liveActivityEventUpdate, wantPriority: "10",
			overrides: map[string]any{"content_state.status": "needsYou", "content_state.needs_you_count": 3},
			wantState: map[string]any{"status": "needsYou", "needsYouCount": float64(3)},
		},
		{
			name: "end 带 dismissal-date", kind: ticketKindActivityUpdate, event: liveActivityEventEnd, wantPriority: "10",
			overrides: map[string]any{"content_state.status": "completed", "content_state.running_count": 0, "dismissal_date": "+1h"},
			wantExtra: map[string]any{"dismissal-date": "+1h"},
			wantState: map[string]any{"status": "completed", "runningCount": float64(0)},
		},
		{
			name: "end 失败且立即移除", kind: ticketKindActivityUpdate, event: liveActivityEventEnd, wantPriority: "10",
			overrides: map[string]any{"content_state.status": "failed", "dismissal_date": "-1m"},
			wantExtra: map[string]any{"dismissal-date": "-1m"},
			wantState: map[string]any{"status": "failed"},
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			h := newLiveActivityHarness(t)
			now := h.clock.Now()
			relative := func(value any) any {
				if raw, ok := value.(string); ok && (strings.HasPrefix(raw, "+") || strings.HasPrefix(raw, "-")) {
					offset, err := time.ParseDuration(raw)
					if err != nil {
						t.Fatal(err)
					}
					return now.Add(offset).Unix()
				}
				return value
			}
			overrides := map[string]any{}
			for key, value := range test.overrides {
				overrides[key] = relative(value)
			}
			ticket := h.issue(test.kind)
			request := h.body(ticket, test.event, overrides)
			status, response := h.post(request)
			if status != http.StatusOK || response["delivered"] != true {
				t.Fatalf("投递失败 status=%d body=%v", status, response)
			}
			got := h.fake.last(t)
			if got.PushType != "liveactivity" || got.Topic != testLiveActivityTopic || got.Priority != test.wantPriority {
				t.Fatalf("headers: type=%q topic=%q priority=%q", got.PushType, got.Topic, got.Priority)
			}
			if got.CollapseID != "" {
				t.Fatalf("Live Activity 不应带 apns-collapse-id：%q", got.CollapseID)
			}
			if !strings.HasSuffix(got.Path, "/3/device/"+testActivityToken) {
				t.Fatalf("投递路径未使用活动 Token：%s", got.Path)
			}
			if want := strconv.FormatInt(now.Add(time.Hour).Unix(), 10); got.Expiration != want {
				t.Fatalf("apns-expiration = %s, want %s", got.Expiration, want)
			}
			if keys := sortedKeys(got.Payload); !reflect.DeepEqual(keys, []string{"aps"}) {
				t.Fatalf("Payload 只能有 aps：%v", keys)
			}
			state := map[string]any{
				"status": "running", "runningCount": float64(2), "needsYouCount": float64(1),
				"startedAt": float64(now.Add(-10 * time.Minute).Unix()), "focusSessionTag": "7D92",
			}
			for key, value := range test.wantState {
				state[key] = value
			}
			want := map[string]any{"timestamp": float64(now.Unix()), "event": test.event, "content-state": state}
			for key, value := range test.wantExtra {
				if unix, ok := relative(value).(int64); ok {
					value = float64(unix)
				}
				want[key] = value
			}
			if !reflect.DeepEqual(got.Payload["aps"], want) {
				t.Fatalf("aps 不符合 ActivityKit 格式：\n got=%v\nwant=%v", got.Payload["aps"], want)
			}
		})
	}
}

func TestLiveActivityRejectsInvalidRequests(t *testing.T) {
	type invalidCase struct {
		name      string
		event     string
		overrides map[string]any
		wantError string
	}
	at := func(offset time.Duration) string { return "@" + offset.String() }
	cases := []invalidCase{
		{name: "未知状态", event: "update", overrides: map[string]any{"content_state.status": "paused"}},
		{name: "状态塞自由文本", event: "update", overrides: map[string]any{"content_state.status": "修复登录 bug"}},
		{name: "状态大小写不符", event: "update", overrides: map[string]any{"content_state.status": "NeedsYou"}},
		{name: "负计数", event: "update", overrides: map[string]any{"content_state.running_count": -1}},
		{name: "计数超上限", event: "update", overrides: map[string]any{"content_state.needs_you_count": maxLiveActivityCount + 1}},
		{name: "计数用字符串", event: "update", overrides: map[string]any{"content_state.running_count": "2"}, wantError: "invalid_body"},
		{name: "焦点标签塞标题", event: "update", overrides: map[string]any{"content_state.focus_session_tag": "修复登录"}},
		{name: "焦点标签塞主机名", event: "update", overrides: map[string]any{"content_state.focus_session_tag": "landy-mbp"}},
		{name: "焦点标签缺失", event: "update", overrides: map[string]any{"content_state.focus_session_tag": removeField}},
		{name: "开始时间缺失", event: "update", overrides: map[string]any{"content_state.started_at": removeField}},
		{name: "开始时间在未来", event: "update", overrides: map[string]any{"content_state.started_at": at(time.Hour)}},
		{name: "开始时间过旧", event: "update", overrides: map[string]any{"content_state.started_at": at(-48 * time.Hour)}},
		{name: "content_state 带标题", event: "update", overrides: map[string]any{"content_state.title": "修复登录"}, wantError: "invalid_body"},
		{name: "content_state 带提示词", event: "end", overrides: map[string]any{"content_state.prompt": "rm -rf /"}, wantError: "invalid_body"},
		{name: "顶层注入 alert", event: "update", overrides: map[string]any{"alert": map[string]any{"body": "rm -rf /"}}, wantError: "invalid_body"},
		{name: "顶层注入 aps", event: "update", overrides: map[string]any{"aps": map[string]any{"event": "update"}}, wantError: "invalid_body"},
		{name: "attributes 多出字段", event: "start", overrides: map[string]any{"attributes.name": "Mac mini"}, wantError: "invalid_body"},
		{name: "start 缺 attributes", event: "start", overrides: map[string]any{"attributes": removeField}},
		{name: "start 缺 attributes_type", event: "start", overrides: map[string]any{"attributes_type": removeField}},
		{name: "start attributes_type 不符", event: "start", overrides: map[string]any{"attributes_type": "AdventureAttributes"}},
		{name: "start 主机标签非法", event: "start", overrides: map[string]any{"attributes.host_tag": "my-mac"}},
		{name: "start 带 dismissal_date", event: "start", overrides: map[string]any{"dismissal_date": at(time.Hour)}},
		{name: "update 带 attributes", event: "update", overrides: map[string]any{"attributes": map[string]any{"host_tag": "A1C3"}}},
		{name: "end 带 attributes_type", event: "end", overrides: map[string]any{"attributes_type": LiveActivityAttributesType}},
		{name: "update 带 dismissal_date", event: "update", overrides: map[string]any{"dismissal_date": at(time.Hour)}},
		{name: "end dismissal_date 超 4 小时", event: "end", overrides: map[string]any{"dismissal_date": at(5 * time.Hour)}},
		{name: "end dismissal_date 为负", event: "end", overrides: map[string]any{"dismissal_date": -5}},
		{name: "end 带 stale_date", event: "end", overrides: map[string]any{"stale_date": at(time.Hour)}},
		{name: "stale_date 已过", event: "update", overrides: map[string]any{"stale_date": at(-time.Minute)}},
		{name: "stale_date 超上限", event: "update", overrides: map[string]any{"stale_date": at(13 * time.Hour)}},
		{name: "expires_at 超上限", event: "update", overrides: map[string]any{"expires_at": "@13h"}},
		{name: "expires_at 已过期", event: "update", overrides: map[string]any{"expires_at": "@-1m"}},
		{name: "expires_at 非 RFC3339", event: "update", overrides: map[string]any{"expires_at": "tomorrow"}},
		{name: "不支持的 version", event: "update", overrides: map[string]any{"version": 2}},
		{name: "未知事件", event: "pause"},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			h := newLiveActivityHarness(t)
			now := h.clock.Now()
			kind := ticketKindActivityUpdate
			if test.event == liveActivityEventStart {
				kind = ticketKindActivityStart
			}
			overrides := map[string]any{}
			for key, value := range test.overrides {
				if raw, ok := value.(string); ok && strings.HasPrefix(raw, "@") {
					offset, err := time.ParseDuration(raw[1:])
					if err != nil {
						t.Fatal(err)
					}
					if key == "expires_at" {
						value = now.Add(offset).UTC().Format(time.RFC3339)
					} else {
						value = now.Add(offset).Unix()
					}
				}
				overrides[key] = value
			}
			status, body := h.post(h.body(h.issue(kind), test.event, overrides))
			wantError := test.wantError
			if wantError == "" {
				wantError = "invalid_request"
			}
			if status != http.StatusBadRequest || body["error"] != wantError {
				t.Fatalf("应以 %s 拒绝，got status=%d body=%v", wantError, status, body)
			}
			if h.fake.count() != 0 {
				t.Fatal("非法请求不能触发任何 APNs 投递")
			}
		})
	}
}

func TestLiveActivityTicketKindMismatch(t *testing.T) {
	h := newLiveActivityHarness(t)
	tickets := map[string]string{
		"notification":           h.issue("notification"),
		ticketKindActivityUpdate: h.issue(ticketKindActivityUpdate),
		ticketKindActivityStart:  h.issue(ticketKindActivityStart),
	}
	for _, test := range []struct {
		name   string
		kind   string
		path   string
		event  string
		status int
	}{
		{name: "通知 Ticket 不能更新活动", kind: "notification", path: "/v1/notify/liveactivity", event: "update"},
		{name: "通知 Ticket 不能启动活动", kind: "notification", path: "/v1/notify/liveactivity", event: "start"},
		{name: "更新 Ticket 不能远程启动", kind: ticketKindActivityUpdate, path: "/v1/notify/liveactivity", event: "start"},
		{name: "push-to-start Ticket 不能更新", kind: ticketKindActivityStart, path: "/v1/notify/liveactivity", event: "update"},
		{name: "push-to-start Ticket 不能结束", kind: ticketKindActivityStart, path: "/v1/notify/liveactivity", event: "end"},
		{name: "更新 Ticket 不能发通知", kind: ticketKindActivityUpdate, path: "/v1/notify"},
		{name: "push-to-start Ticket 不能发通知", kind: ticketKindActivityStart, path: "/v1/notify"},
	} {
		t.Run(test.name, func(t *testing.T) {
			body := approvalBody(tickets[test.kind], nil)
			if test.path != "/v1/notify" {
				body = h.body(tickets[test.kind], test.event, nil)
			}
			status, response := postJSON(t, h.base+test.path, body)
			if status != http.StatusBadRequest || response["error"] != "ticket_kind_mismatch" {
				t.Fatalf("应以 ticket_kind_mismatch 拒绝，got status=%d body=%v", status, response)
			}
		})
	}
	if h.fake.count() != 0 {
		t.Fatalf("用途不符的 Ticket 不能触发投递，count=%d", h.fake.count())
	}
}

func (h *liveActivityHarness) update(ticket string, status string, running int, needsYou int) (int, map[string]any) {
	h.t.Helper()
	return h.post(h.body(ticket, liveActivityEventUpdate, map[string]any{
		"content_state.status":          status,
		"content_state.running_count":   running,
		"content_state.needs_you_count": needsYou,
	}))
}

func lastContentState(t *testing.T, fake *fakeAPNs) (map[string]any, map[string]any) {
	t.Helper()
	aps := fake.last(t).Payload["aps"].(map[string]any)
	return aps, aps["content-state"].(map[string]any)
}

func TestLiveActivityCoalescesUpdatesPerActivity(t *testing.T) {
	h := newLiveActivityHarness(t)
	activityA := h.issue(ticketKindActivityUpdate)
	activityB := h.issue(ticketKindActivityUpdate)
	t0 := h.clock.Now()

	if status, body := h.update(activityA, "running", 1, 0); status != http.StatusOK || body["delivered"] != true {
		t.Fatalf("第一条 update 应立即投递 status=%d body=%v", status, body)
	}
	h.clock.Advance(time.Second)
	if status, body := h.update(activityA, "running", 2, 0); status != http.StatusAccepted || body["coalesced"] != true {
		t.Fatalf("窗口内的 update 应被合并 status=%d body=%v", status, body)
	}
	h.clock.Advance(time.Second)
	if status, _ := h.update(activityA, "running", 3, 0); status != http.StatusAccepted {
		t.Fatalf("窗口内的 update 应被合并 status=%d", status)
	}
	if got := h.sched.scheduled(); !reflect.DeepEqual(got, []time.Duration{4 * time.Second}) {
		t.Fatalf("同一窗口只应排一次计时，delays=%v", got)
	}
	// 另一个活动有自己的窗口，不受 A 影响。
	if status, _ := h.update(activityB, "running", 1, 0); status != http.StatusOK {
		t.Fatalf("另一个活动的 update 应立即投递 status=%d", status)
	}
	if h.fake.count() != 2 {
		t.Fatalf("窗口结束前只应有 2 次投递，count=%d", h.fake.count())
	}

	h.clock.Advance(3 * time.Second)
	h.sched.runPending()
	if h.fake.count() != 3 {
		t.Fatalf("窗口结束应只发出最后一条，count=%d", h.fake.count())
	}
	aps, state := lastContentState(t, h.fake)
	if state["runningCount"] != float64(3) || aps["timestamp"] != float64(t0.Add(2*time.Second).Unix()) {
		t.Fatalf("应发出窗口内最新一条并保留其接收时间：aps=%v", aps)
	}
	if h.fake.last(t).Priority != "5" {
		t.Fatalf("合并后的普通 update 仍用低优先级，got=%q", h.fake.last(t).Priority)
	}

	// end 不等窗口，并丢弃窗口里更旧的 update。
	h.clock.Advance(time.Second)
	if status, _ := h.update(activityA, "running", 4, 0); status != http.StatusAccepted {
		t.Fatalf("刚发出后的 update 应被合并 status=%d", status)
	}
	h.clock.Advance(time.Second)
	end := h.body(activityA, liveActivityEventEnd, map[string]any{"content_state.status": "completed", "content_state.running_count": 0})
	if status, body := h.post(end); status != http.StatusOK || body["delivered"] != true {
		t.Fatalf("end 应立即投递 status=%d body=%v", status, body)
	}
	if got := h.fake.last(t); got.Priority != "10" || got.Payload["aps"].(map[string]any)["event"] != "end" {
		t.Fatalf("end 应以高优先级发出：%+v", got)
	}
	h.clock.Advance(5 * time.Second)
	h.sched.runPending()
	if h.fake.count() != 4 {
		t.Fatalf("end 之后不能再补发旧 update，count=%d", h.fake.count())
	}
}

func TestLiveActivityNeedsYouSkipsWindowOnlyOnTransition(t *testing.T) {
	h := newLiveActivityHarness(t)
	activity := h.issue(ticketKindActivityUpdate)
	t0 := h.clock.Now()

	h.update(activity, "running", 1, 0)
	h.clock.Advance(time.Second)
	if status, _ := h.update(activity, "running", 2, 0); status != http.StatusAccepted {
		t.Fatalf("窗口内的 update 应被合并 status=%d", status)
	}
	h.clock.Advance(time.Second)
	if status, body := h.update(activity, "needsYou", 2, 1); status != http.StatusOK || body["delivered"] != true {
		t.Fatalf("转入待你处理应立即投递 status=%d body=%v", status, body)
	}
	if got := h.fake.last(t).Priority; got != "10" {
		t.Fatalf("待你处理应使用高优先级，got=%q", got)
	}
	h.clock.Advance(time.Second)
	// 已经是待你处理时，计数变化照常合并。
	if status, _ := h.update(activity, "needsYou", 2, 2); status != http.StatusAccepted {
		t.Fatalf("待你处理期间的 update 应被合并 status=%d", status)
	}

	// 最初的计时器在 t0+5s 到期，但窗口已从 t0+2s 的紧急更新重新起算。
	h.clock.Advance(2 * time.Second)
	h.sched.runPending()
	if h.fake.count() != 2 {
		t.Fatalf("新窗口未结束前不能发出，count=%d", h.fake.count())
	}
	if got := h.sched.scheduled(); len(got) != 2 || got[1] != 2*time.Second {
		t.Fatalf("应按剩余窗口重新计时，delays=%v", got)
	}
	h.clock.Advance(2 * time.Second)
	h.sched.runPending()
	if h.fake.count() != 3 {
		t.Fatalf("新窗口结束应发出最新一条，count=%d", h.fake.count())
	}
	aps, state := lastContentState(t, h.fake)
	if state["needsYouCount"] != float64(2) || aps["timestamp"] != float64(t0.Add(3*time.Second).Unix()) {
		t.Fatalf("应发出最新的待你处理状态：aps=%v", aps)
	}
	if got := h.fake.last(t).Priority; got != "10" {
		t.Fatalf("待你处理的合并更新仍用高优先级，got=%q", got)
	}
}

func TestLiveActivityFlushSkipsRevokedTicket(t *testing.T) {
	h := newLiveActivityHarness(t)
	activity := h.issue(ticketKindActivityUpdate)
	h.update(activity, "running", 1, 0)
	h.clock.Advance(time.Second)
	if status, _ := h.update(activity, "running", 2, 0); status != http.StatusAccepted {
		t.Fatalf("窗口内的 update 应被合并 status=%d", status)
	}
	if status, body := postJSON(t, h.base+"/v1/ticket/revoke", map[string]any{"version": 1, "ticket": activity}); status != http.StatusOK {
		t.Fatalf("撤销活动 Ticket 失败 status=%d body=%v", status, body)
	}
	h.clock.Advance(5 * time.Second)
	h.sched.runPending()
	if h.fake.count() != 1 {
		t.Fatalf("撤销后不能补发合并中的 update，count=%d", h.fake.count())
	}
	if status, body := h.update(activity, "running", 3, 0); status != http.StatusForbidden || body["error"] != "ticket_revoked" {
		t.Fatalf("已撤销的活动 Ticket 应回 403 ticket_revoked，status=%d body=%v", status, body)
	}
}

func TestLiveActivityAutoRevokesGoneTokens(t *testing.T) {
	for _, test := range []struct {
		status int
		reason string
	}{
		{status: http.StatusGone, reason: "Unregistered"},
		{status: http.StatusGone, reason: "ExpiredToken"},
		{status: http.StatusBadRequest, reason: "BadDeviceToken"},
		{status: http.StatusBadRequest, reason: "DeviceTokenNotForTopic"},
	} {
		t.Run(test.reason, func(t *testing.T) {
			h := newLiveActivityHarness(t)
			activity := h.issue(ticketKindActivityUpdate)
			h.fake.setResponse(test.status, test.reason)
			if status, body := h.update(activity, "running", 1, 0); status != http.StatusGone || body["reason"] != "unregistered" {
				t.Fatalf("失效的活动 Token 应回 410，status=%d body=%v", status, body)
			}
			h.fake.setResponse(http.StatusOK, "")
			if status, _ := h.update(activity, "running", 1, 0); status != http.StatusForbidden {
				t.Fatalf("Token 失效后 Ticket 应已撤销，got=%d", status)
			}
		})
	}
	// ExpiredToken 只对活动 Ticket 生效；通知路径的判定保持不变。
	h := newLiveActivityHarness(t)
	ticket := issueTestTicket(t, h.base)
	h.fake.setResponse(http.StatusGone, "ExpiredToken")
	if status, body := postJSON(t, h.base+"/v1/notify", approvalBody(ticket, nil)); status != http.StatusOK || body["delivered"] != false {
		t.Fatalf("通知路径对 ExpiredToken 应保持 delivered:false，status=%d body=%v", status, body)
	}
}

func TestLiveActivityRateLimitIsPerDeviceAndSeparateFromNotifications(t *testing.T) {
	h := newLiveActivityHarness(t)
	notification := h.issue("")
	first := h.issue(ticketKindActivityUpdate)
	second := h.issue(ticketKindActivityUpdate)
	for i := 0; i < rateBurst; i++ {
		if status, _ := h.update(first, "running", 1, 0); status == http.StatusTooManyRequests {
			t.Fatalf("第 %d 次就被限速", i+1)
		}
	}
	if status, _ := h.update(first, "running", 1, 0); status != http.StatusTooManyRequests {
		t.Fatalf("超过每设备上限应回 429，got=%d", status)
	}
	if status, _ := h.update(second, "running", 1, 0); status != http.StatusTooManyRequests {
		t.Fatalf("同一设备的其它活动共用上限，got=%d", status)
	}
	if status, body := postJSON(t, h.base+"/v1/notify", approvalBody(notification, nil)); status != http.StatusOK || body["delivered"] != true {
		t.Fatalf("活动更新不能挤占审批通知的额度，status=%d body=%v", status, body)
	}
}

func TestLiveActivityLogsOmitContentState(t *testing.T) {
	var logs bytes.Buffer
	previous := log.Writer()
	log.SetOutput(&logs)
	t.Cleanup(func() { log.SetOutput(previous) })

	h := newLiveActivityHarness(t)
	ticket := h.issue(ticketKindActivityStart)
	request := h.body(ticket, liveActivityEventStart, map[string]any{
		"content_state.focus_session_tag": "C0FFEE42",
		"attributes.host_tag":             "BEEF1234",
	})
	h.fake.setResponse(http.StatusBadRequest, "BadTopic")
	if status, body := h.post(request); status != http.StatusOK || body["delivered"] != false {
		t.Fatalf("APNs 协议级拒绝应回 delivered:false，status=%d body=%v", status, body)
	}
	h.fake.server.Close()
	if status, _ := h.post(request); status != http.StatusBadGateway {
		t.Fatalf("APNs 传输错误应回 502，got=%d", status)
	}
	output := logs.String()
	for _, forbidden := range []string{"C0FFEE42", "BEEF1234", "running", testActivityToken, ticket, "content"} {
		if strings.Contains(output, forbidden) {
			t.Fatalf("日志泄漏了 %q：%s", forbidden, output)
		}
	}
	if !strings.Contains(output, "event=start") || !strings.Contains(output, "reason=BadTopic") {
		t.Fatalf("日志应保留事件枚举与 APNs 原因：%s", output)
	}
}

// 升级前签发的通知 Ticket（v1、无 kind）必须照旧投递，签发与撤销接口对它们不变。
func TestLegacyNotificationTicketStillDelivers(t *testing.T) {
	fake := newFakeAPNs(t)
	server, httpServer := newTestServer(t, fake)
	now := time.Now()
	legacy := sealRawClaims(t, server.sealer, map[string]any{
		"v": 1, "tid": "legacy-ticket", "env": "production", "topic": testBundleTopic,
		"dt": strings.Repeat("ab", 32), "idg": "digest", "iat": now.Unix(), "exp": now.Add(time.Hour).Unix(),
	})
	status, body := postJSON(t, httpServer.URL+"/v1/notify", approvalBody(legacy, nil))
	if status != http.StatusOK || body["delivered"] != true {
		t.Fatalf("旧 Ticket 投递失败 status=%d body=%v", status, body)
	}
	if got := fake.last(t); got.PushType != "alert" || got.Topic != testBundleTopic {
		t.Fatalf("旧 Ticket 的投递 header 变了：%+v", got)
	}
	if status, _ := postJSON(t, httpServer.URL+"/v1/ticket/revoke", map[string]any{"version": 1, "ticket": legacy}); status != http.StatusOK {
		t.Fatalf("旧 Ticket 撤销失败 status=%d", status)
	}
	if status, _ := postJSON(t, httpServer.URL+"/v1/notify", approvalBody(legacy, nil)); status != http.StatusForbidden {
		t.Fatalf("撤销后的旧 Ticket 应被拒绝，got=%d", status)
	}
}

func TestLiveActivityRejectsNonPost(t *testing.T) {
	h := newLiveActivityHarness(t)
	resp, err := http.Get(h.base + "/v1/notify/liveactivity")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("GET 应回 405，got=%d", resp.StatusCode)
	}
}
