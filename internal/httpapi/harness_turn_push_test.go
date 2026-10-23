package httpapi

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/harnessclient"
	"github.com/gaixianggeng/mimi-remote/internal/pushbridge"
	"github.com/gorilla/websocket"
)

// 本文件覆盖 DeepSeek 回复提醒（#568）：手机经 agentd 提交 session/prompt 后，
// 即使手机连接已经断开，agentd 也要在包含这次提交的回合结束时推送一次。

const turnPushSession = "deepseek-session-1"

// fakeTurnHarness 是只服务本文件的 Harness 替身：follow 的帧由用例逐条注入，
// 这样能精确控制“提交前已结束”“电脑端回合在前”等时序。
type fakeTurnHarness struct {
	t        *testing.T
	token    string
	server   *httptest.Server
	sessions []harnessclient.SessionSummary
	// snapshot 返回 follow 开场快照；为空时用授权目录、空记录。
	snapshot func(cwd string) map[string]any
	// promptError 非空时 session/prompt 回业务失败。
	promptError *harnessclient.RemoteError

	mu      sync.Mutex
	follows []*fakeTurnFollow
	opened  chan *fakeTurnFollow
	prompts int
}

type fakeTurnFollow struct {
	conn     *websocket.Conn
	streamID string
	request  map[string]any
	closed   chan struct{}
	writeMu  sync.Mutex
}

func (follow *fakeTurnFollow) write(value any) error {
	follow.writeMu.Lock()
	defer follow.writeMu.Unlock()
	return follow.conn.WriteJSON(map[string]any{"type": "item", "streamId": follow.streamID, "value": value})
}

func (follow *fakeTurnFollow) send(t *testing.T, value any) {
	t.Helper()
	if err := follow.write(value); err != nil {
		t.Fatalf("写入 follow 帧失败：%v", err)
	}
}

func (follow *fakeTurnFollow) waitClosed(t *testing.T) {
	t.Helper()
	select {
	case <-follow.closed:
	case <-time.After(5 * time.Second):
		t.Fatal("agentd 应在回合结束后退订")
	}
}

func newFakeTurnHarness(t *testing.T, authorized string) *fakeTurnHarness {
	t.Helper()
	harness := &fakeTurnHarness{
		t:        t,
		token:    "startup-token-turn-push",
		sessions: []harnessclient.SessionSummary{harnessNativeFixtureSession(turnPushSession, authorized)},
		opened:   make(chan *fakeTurnFollow, 8),
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" || r.URL.Query().Get("token") != harness.token {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		http.SetCookie(w, &http.Cookie{Name: "harness_session", Value: "turn-push", Path: "/"})
		w.WriteHeader(http.StatusSeeOther)
	})
	mux.HandleFunc("/api/remote.mux", func(w http.ResponseWriter, r *http.Request) {
		conn, err := (&websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}).Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer func() { _ = conn.Close() }()
		var open struct {
			StreamID string `json:"streamId"`
			Endpoint string `json:"endpoint"`
			Payload  struct {
				Args struct {
					Request map[string]any `json:"request"`
				} `json:"args"`
			} `json:"payload"`
		}
		if conn.ReadJSON(&open) != nil || open.Endpoint != harnessclient.MethodSessionFollow {
			return
		}
		follow := &fakeTurnFollow{conn: conn, streamID: open.StreamID, request: open.Payload.Args.Request, closed: make(chan struct{})}
		defer close(follow.closed)
		harness.mu.Lock()
		harness.follows = append(harness.follows, follow)
		snapshot := harness.snapshot
		harness.mu.Unlock()
		value := map[string]any{"type": "snapshot", "header": map[string]any{"id": turnPushSession, "cwd": authorized}, "cursor": 0, "records": []any{}}
		if snapshot != nil {
			value = snapshot(authorized)
		}
		// 服务端协程里不能调 t.Fatal；写失败说明 agentd 已退订，用例自会发现。
		if follow.write(value) != nil {
			return
		}
		harness.opened <- follow
		for {
			if _, _, err := conn.ReadMessage(); err != nil {
				return
			}
		}
	})
	mux.HandleFunc("/api/", func(w http.ResponseWriter, r *http.Request) {
		var envelope struct {
			RPCID string `json:"rpcId"`
		}
		_ = json.NewDecoder(r.Body).Decode(&envelope)
		result := map[string]any{"ok": true, "value": map[string]any{}}
		switch strings.TrimPrefix(r.URL.Path, "/api/") {
		case "session/list":
			result["value"] = map[string]any{"items": harness.sessions}
		case "session/prompt":
			harness.mu.Lock()
			harness.prompts++
			harness.mu.Unlock()
			if harness.promptError != nil {
				result = map[string]any{"ok": false, "error": harness.promptError}
			} else {
				result["value"] = map[string]any{"accepted": true}
			}
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"type": "server-response", "rpcId": envelope.RPCID, "result": result})
	})
	harness.server = httptest.NewServer(mux)
	t.Cleanup(harness.server.Close)
	return harness
}

func (harness *fakeTurnHarness) waitFollow(t *testing.T) *fakeTurnFollow {
	t.Helper()
	select {
	case follow := <-harness.opened:
		return follow
	case <-time.After(5 * time.Second):
		t.Fatal("agentd 应为提交打开 session/follow")
		return nil
	}
}

func (harness *fakeTurnHarness) followCount() int {
	harness.mu.Lock()
	defer harness.mu.Unlock()
	return len(harness.follows)
}

type turnPushFixture struct {
	server     *httptest.Server
	router     *Router
	harness    *fakeTurnHarness
	provider   *fakePushProvider
	authorized string
}

func newTurnPushFixture(t *testing.T, pushEnabled bool) turnPushFixture {
	t.Helper()
	cfg, registry, checker, projectDir := appServerGatewayBaseFixture(t)
	harness := newFakeTurnHarness(t, projectDir)
	provider := newFakePushProvider(t)
	tokenFile := filepath.Join(t.TempDir(), "harness-token")
	if err := os.WriteFile(tokenFile, []byte(harness.token), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg.DeepSeek = config.DeepSeekConfig{Enabled: true, BaseURL: harness.server.URL, TokenFile: tokenFile}
	cfg.Push = config.PushConfig{Enabled: pushEnabled, ProviderURL: provider.server.URL, Environment: "sandbox"}
	handler, router := NewRouterWithInstallationIDAndOptions(
		cfg, registry, checker, "test", "install-push-test",
		RouterOptions{ConfigPath: filepath.Join(t.TempDir(), "config.json")},
	)
	t.Cleanup(router.Shutdown)
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	return turnPushFixture{server: server, router: router, harness: harness, provider: provider, authorized: projectDir}
}

// submit 模拟手机经 agentd 提交一条 DeepSeek 消息，返回上游结果是否 ok。
func (fixture turnPushFixture) submit(t *testing.T, requestID string) bool {
	t.Helper()
	body := fmt.Sprintf(
		`{"rpcId":"rpc-%s","method":"session/prompt","args":{"request":{"requestId":%q,"sessionId":%q,"mode":"queue","content":[{"type":"text","text":"PRIVATE PROMPT"}]}}}`,
		requestID, requestID, turnPushSession,
	)
	req, err := http.NewRequest(http.MethodPost, fixture.server.URL+"/api/harness/rpc", strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+testToken)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var envelope struct {
		Result struct {
			OK bool `json:"ok"`
		} `json:"result"`
	}
	if resp.StatusCode != http.StatusOK || json.NewDecoder(resp.Body).Decode(&envelope) != nil {
		t.Fatalf("提交请求失败 status=%d", resp.StatusCode)
	}
	return envelope.Result.OK
}

func (fixture turnPushFixture) watcherCount() int {
	watchers := &fixture.router.harnessTurnPush
	watchers.mu.Lock()
	defer watchers.mu.Unlock()
	return len(watchers.watchers)
}

func turnPushUserMessage(seq int, requestID string) map[string]any {
	return map[string]any{"type": "event", "event": map[string]any{
		"type": "user/message", "seq": seq, "time": 1,
		"data": map[string]any{"id": "m", "role": "user", "content": []any{map[string]any{"type": "text", "text": "PRIVATE PROMPT"}},
			"source": map[string]any{"kind": "rpc", "rpcId": requestID}},
	}}
}

func turnPushTurnEnd(seq int, turn int, kind string) map[string]any {
	return map[string]any{"type": "event", "event": map[string]any{
		"type": "turn/end", "seq": seq, "time": 1,
		"data": map[string]any{"turn": turn, "reason": map[string]any{"kind": kind}},
	}}
}

func waitTurnPushCount(t *testing.T, provider *fakePushProvider, want int) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for provider.count() < want && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	// 多等一小段，确认没有多余的推送尾随。
	time.Sleep(100 * time.Millisecond)
	if got := provider.count(); got != want {
		t.Fatalf("推送次数错误：want=%d got=%d", want, got)
	}
}

func TestDeepSeekPromptNotifiesCapableDeviceWhenTurnEnds(t *testing.T) {
	fixture := newTurnPushFixture(t, true)
	registerPushDevice(t, fixture.server, "device-old")
	response := registerPushDeviceWithFields(t, fixture.server, "device-new", map[string]any{"supports_deepseek_messages": true})
	if response["supports_deepseek_messages"] != true {
		t.Fatalf("注册响应应回显 DeepSeek 能力：%v", response)
	}

	if !fixture.submit(t, "req-1") {
		t.Fatal("提交应成功")
	}
	follow := fixture.harness.waitFollow(t)
	address, _ := follow.request["address"].(map[string]any)
	if address["sessionId"] != turnPushSession || follow.request["assistantStream"] != nil {
		t.Fatalf("观察订阅参数错误：%v", follow.request)
	}
	// 回合结束之前不能有任何推送。
	follow.send(t, turnPushUserMessage(5, "req-1"))
	time.Sleep(50 * time.Millisecond)
	if fixture.provider.count() != 0 {
		t.Fatal("回合未结束不应推送")
	}
	follow.send(t, turnPushTurnEnd(9, 1, "completed"))

	notification := fixture.provider.waitFor(t, pushbridge.EventTurnCompleted)
	if notification["runtime"] != "deepseek" || notification["device_id"] != "device-new" || notification["approval_kind"] != "" {
		t.Fatalf("DeepSeek 提醒内容错误：%v", notification)
	}
	encoded, _ := json.Marshal(notification)
	if strings.Contains(string(encoded), "PRIVATE") || strings.Contains(string(encoded), turnPushSession) {
		t.Fatalf("Provider 请求泄漏会话内容或标识：%s", encoded)
	}
	follow.waitClosed(t)
	waitTurnPushCount(t, fixture.provider, 1)

	actionID, _ := notification["action_id"].(string)
	status, route := getPushActionRoute(t, fixture.server, actionID, "device-new")
	if status != http.StatusOK || route["runtime"] != "deepseek" || route["thread_id"] != turnPushSession ||
		route["cwd"] != fixture.authorized || route["kind"] != pushbridge.RouteKindMessage || route["thread_authorized"] != true {
		t.Fatalf("DeepSeek 定位记录错误：status=%d route=%v", status, route)
	}
	if status, _ := getPushActionRoute(t, fixture.server, actionID, "device-old"); status != http.StatusForbidden {
		t.Fatalf("旧客户端不应取得 DeepSeek 路由，got=%d", status)
	}
	if fixture.watcherCount() != 0 {
		t.Fatal("回合结束后观察订阅应被摘除")
	}
}

func TestDeepSeekTurnAlreadyEndedInSnapshotStillNotifies(t *testing.T) {
	fixture := newTurnPushFixture(t, true)
	registerPushDeviceWithFields(t, fixture.server, "device-new", map[string]any{"supports_deepseek_messages": true})
	fixture.harness.snapshot = func(cwd string) map[string]any {
		return map[string]any{
			"type":   "snapshot",
			"header": map[string]any{"id": turnPushSession, "cwd": cwd},
			"cursor": 12,
			// 更早的回合与本次提交无关，不能被当成本次结束。
			"records": []any{
				turnPushTurnEnd(3, 1, "completed"),
				map[string]any{"type": "event", "event": map[string]any{"type": "approval/decided", "seq": 4, "data": map[string]any{"reason": "free text"}}},
				turnPushUserMessage(6, "req-fast"),
				turnPushTurnEnd(11, 2, "aborted"),
			},
		}
	}
	if !fixture.submit(t, "req-fast") {
		t.Fatal("提交应成功")
	}
	follow := fixture.harness.waitFollow(t)
	fixture.provider.waitFor(t, pushbridge.EventTurnInterrupted)
	follow.waitClosed(t)
	waitTurnPushCount(t, fixture.provider, 1)
}

func TestDeepSeekPushSkipsTurnsWithoutMimiPrompt(t *testing.T) {
	fixture := newTurnPushFixture(t, true)
	registerPushDeviceWithFields(t, fixture.server, "device-new", map[string]any{"supports_deepseek_messages": true})
	if !fixture.submit(t, "req-queued") {
		t.Fatal("提交应成功")
	}
	follow := fixture.harness.waitFollow(t)
	// 电脑端正在跑的回合先结束：它不含本次提交，不提醒。
	follow.send(t, turnPushTurnEnd(20, 4, "completed"))
	follow.send(t, turnPushUserMessage(22, "someone-else"))
	follow.send(t, turnPushTurnEnd(25, 5, "completed"))
	time.Sleep(100 * time.Millisecond)
	if fixture.provider.count() != 0 {
		t.Fatal("不含 Mimi 提交的回合不应提醒")
	}
	// 第二条提交复用同一条观察订阅。
	if !fixture.submit(t, "req-second") {
		t.Fatal("提交应成功")
	}
	follow.send(t, turnPushUserMessage(27, "req-queued"))
	follow.send(t, turnPushTurnEnd(30, 6, "error"))
	fixture.provider.waitFor(t, pushbridge.EventTurnFailed)
	if fixture.watcherCount() != 1 {
		t.Fatal("仍有未开始的提交时应继续观察")
	}
	follow.send(t, turnPushUserMessage(32, "req-second"))
	follow.send(t, turnPushTurnEnd(35, 7, "completed"))
	fixture.provider.waitFor(t, pushbridge.EventTurnCompleted)
	follow.waitClosed(t)
	waitTurnPushCount(t, fixture.provider, 2)
	if got := fixture.harness.followCount(); got != 1 {
		t.Fatalf("同一会话只应有一条观察订阅，got=%d", got)
	}
}

func TestDeepSeekRejectedPromptWithdrawsWatcher(t *testing.T) {
	fixture := newTurnPushFixture(t, true)
	registerPushDeviceWithFields(t, fixture.server, "device-new", map[string]any{"supports_deepseek_messages": true})
	fixture.harness.promptError = &harnessclient.RemoteError{Code: "session/agent-busy", Message: "busy"}
	if fixture.submit(t, "req-rejected") {
		t.Fatal("上游拒绝应如实回给客户端")
	}
	deadline := time.Now().Add(5 * time.Second)
	for fixture.watcherCount() != 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if fixture.watcherCount() != 0 {
		t.Fatal("被拒的提交应撤回观察")
	}
	select {
	case follow := <-fixture.harness.opened:
		follow.waitClosed(t)
	case <-time.After(200 * time.Millisecond):
	}
	waitTurnPushCount(t, fixture.provider, 0)
}

func TestDeepSeekPushRejectsSnapshotOutsideAuthorizedScope(t *testing.T) {
	fixture := newTurnPushFixture(t, true)
	registerPushDeviceWithFields(t, fixture.server, "device-new", map[string]any{"supports_deepseek_messages": true})
	outside := t.TempDir()
	fixture.harness.snapshot = func(string) map[string]any {
		return map[string]any{"type": "snapshot", "header": map[string]any{"id": turnPushSession, "cwd": outside}, "cursor": 0,
			"records": []any{turnPushUserMessage(1, "req-1"), turnPushTurnEnd(2, 1, "completed")}}
	}
	if !fixture.submit(t, "req-1") {
		t.Fatal("提交应成功")
	}
	fixture.harness.waitFollow(t).waitClosed(t)
	waitTurnPushCount(t, fixture.provider, 0)
}

func TestDeepSeekPromptDoesNotWatchWhenPushDisabled(t *testing.T) {
	fixture := newTurnPushFixture(t, false)
	if !fixture.submit(t, "req-1") {
		t.Fatal("提交应成功")
	}
	time.Sleep(100 * time.Millisecond)
	if fixture.harness.followCount() != 0 || fixture.watcherCount() != 0 {
		t.Fatal("推送未启用时不应观察会话")
	}
}

func TestDeepSeekWatcherStopsOnRouterShutdown(t *testing.T) {
	fixture := newTurnPushFixture(t, true)
	registerPushDeviceWithFields(t, fixture.server, "device-new", map[string]any{"supports_deepseek_messages": true})
	if !fixture.submit(t, "req-1") {
		t.Fatal("提交应成功")
	}
	follow := fixture.harness.waitFollow(t)
	done := make(chan struct{})
	go func() {
		fixture.router.Shutdown()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Shutdown 应结束观察订阅")
	}
	follow.waitClosed(t)
	if fixture.submit(t, "req-2") && fixture.watcherCount() != 0 {
		t.Fatal("关闭后不应再登记观察")
	}
}
