package httpapi

import (
	"encoding/json"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/pushbridge"
	"github.com/gorilla/websocket"
)

func TestTurnMessageClassification(t *testing.T) {
	cases := []struct{ name, method, params, event string }{
		{"complete", "turn/completed", `{"threadId":"t","turn":{"id":"r","status":"completed"}}`, pushbridge.EventTurnCompleted},
		{"failed", "turn/completed", `{"threadId":"t","turn":{"id":"r","status":"failed","error":{"message":"private"}}}`, pushbridge.EventTurnFailed},
		{"stopped", "turn/completed", `{"threadId":"t","turn":{"id":"r","status":"interrupted"}}`, pushbridge.EventTurnInterrupted},
		{"legacy", "turn/completed", `{"threadId":"t","turnId":"r"}`, pushbridge.EventTurnCompleted},
		{"terminal error", "error", `{"threadId":"t","turnId":"r","willRetry":false}`, pushbridge.EventTurnFailed},
		{"retry", "error", `{"threadId":"t","turnId":"r","willRetry":true}`, ""},
		{"delta", "item/agentMessage/delta", `{"threadId":"t","turnId":"r","delta":"private"}`, ""},
		{"missing turn", "turn/completed", `{"threadId":"t"}`, ""},
		{"not terminal", "turn/completed", `{"threadId":"t","turn":{"id":"r","status":"inProgress"}}`, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			frame := appServerGatewayFrame{Method: tc.method, Params: json.RawMessage(tc.params)}
			got, ok := turnMessageFromFrame(&frame)
			if ok != (tc.event != "") || got.Event != tc.event {
				t.Fatalf("got %+v %v", got, ok)
			}
		})
	}
}

func TestAuthorizedCompletionNotifiesAndRoutesWithoutApprovalRights(t *testing.T) {
	provider := newFakePushProvider(t)
	server, router := pushTestFixture(t, "ws://unused", provider.server.URL)
	registerPushDevice(t, server, "device-one")
	policy := newAppServerGatewayPolicy(router, "codex")
	payload := []byte(`{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-one","status":"completed","items":[{"text":"PRIVATE REPLY"}]}}}`)
	if _, forward, err := policy.observeUpstreamFrame(websocket.TextMessage, payload); err != nil || !forward {
		t.Fatalf("frame rejected: %v", err)
	}
	notification := provider.waitFor(t, pushbridge.EventTurnCompleted)
	if _, exists := notification["text"]; exists {
		t.Fatal("reply leaked")
	}
	if notification["approval_kind"] != "" {
		t.Fatal("message grants approval type")
	}
	actionID := notification["action_id"].(string)
	req, _ := http.NewRequest(http.MethodGet, server.URL+"/api/push/actions/route?action_id="+url.QueryEscape(actionID)+"&device_id=device-one", nil)
	req.Header.Set("Authorization", "Bearer "+testToken)
	response, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	var route map[string]any
	json.NewDecoder(response.Body).Decode(&route)
	if response.StatusCode != 200 || route["thread_id"] != "thread-1" {
		t.Fatalf("route failed: %d %v", response.StatusCode, route)
	}
	// 回复提醒只定位不审批：kind 说明身份，state 为空，作用域 id 与 iOS 的会话标识一致。
	if route["kind"] != pushbridge.RouteKindMessage || route["state"] != "" || route["scope_id"] != "demo" ||
		route["project_id"] != "demo" || route["thread_authorized"] != true {
		t.Fatalf("message route shape wrong: %v", route)
	}
	status, _ := postDecide(t, server, actionID, "device-one", "allow")
	if status != http.StatusNotFound {
		t.Fatalf("message record must not be decidable, got %d", status)
	}
	policy.observeUpstreamFrame(websocket.TextMessage, payload)
	private := []byte(`{"method":"turn/completed","params":{"threadId":"not-authorized","turn":{"id":"another","status":"completed"}}}`)
	if _, forward, _ := policy.observeUpstreamFrame(websocket.TextMessage, private); forward {
		t.Fatal("unauthorized frame forwarded")
	}
	time.Sleep(50 * time.Millisecond)
	if provider.count() != 1 {
		t.Fatalf("duplicate or unauthorized push: %d", provider.count())
	}
}

func TestRetryableErrorPreservesBackgroundObservation(t *testing.T) {
	provider := newFakePushProvider(t)
	server, router := pushTestFixture(t, "ws://unused", provider.server.URL)
	registerPushDevice(t, server, "device-one")
	policy := newAppServerGatewayPolicy(router, "codex")
	started := []byte(`{"method":"turn/started","params":{"threadId":"thread-1","turnId":"turn-one"}}`)
	retry := []byte(`{"method":"error","params":{"threadId":"thread-1","turnId":"turn-one","willRetry":true}}`)
	policy.observeUpstreamFrame(websocket.TextMessage, started)
	policy.observeUpstreamFrame(websocket.TextMessage, retry)
	active, _ := policy.approvalObservationSnapshot()
	if _, ok := active["thread-1"]; !ok {
		t.Fatal("retry closed active turn observation")
	}
	broker := &codexGatewayBroker{router: router, policy: policy, key: "session", activeTurns: map[string]struct{}{}, startingTurns: map[string]string{}, detachedAt: time.Now().Add(-20 * time.Minute)}
	broker.observeLifecycle(websocket.TextMessage, started)
	broker.observeLifecycle(websocket.TextMessage, retry)
	if _, ok := broker.activeTurns["thread-1"]; !ok {
		t.Fatal("retry removed active broker turn")
	}
	if reason := broker.sweepCloseReason(time.Now()); reason != "" {
		t.Fatalf("long task prematurely closed: %s", reason)
	}
	broker.detachedAt = time.Now().Add(-codexGatewayBrokerDetachTTL - time.Second)
	if reason := broker.sweepCloseReason(time.Now()); reason != "broker_detach_ttl" {
		t.Fatalf("missing upper bound: %s", reason)
	}
}

// agentd 重启后：落盘的定位记录仍能打开会话，线程授权按当前作用域配置恢复，
// 而不是等某次 thread/list 碰巧带上它。
func TestMessageRouteSurvivesAgentRestartAndRestoresThreadAuthorization(t *testing.T) {
	provider := newFakePushProvider(t)
	configPath := filepath.Join(t.TempDir(), "config.json")
	projectDir := t.TempDir()
	server, router := pushTestFixtureWith(t, "ws://unused", provider.server.URL,
		pushFixtureOptions{configPath: configPath, projectDir: projectDir, seedThread: true})
	registerPushDevice(t, server, "device-one")
	policy := newAppServerGatewayPolicy(router, "codex")
	payload := []byte(`{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-one","status":"completed"}}}`)
	if _, forward, err := policy.observeUpstreamFrame(websocket.TextMessage, payload); err != nil || !forward {
		t.Fatalf("frame rejected: %v", err)
	}
	actionID := provider.waitFor(t, pushbridge.EventTurnCompleted)["action_id"].(string)
	if _, err := os.Stat(pushRouteStorePath(configPath)); err != nil {
		t.Fatalf("route store not written next to config: %v", err)
	}

	// 重启：同一配置目录、同一项目，授权缓存与审批句柄全部为空。
	restartedServer, restarted := pushTestFixtureWith(t, "ws://unused", provider.server.URL,
		pushFixtureOptions{configPath: configPath, projectDir: projectDir})
	fresh := newAppServerGatewayPolicy(restarted, "codex")
	if _, ok := fresh.allowedThread("thread-1"); ok {
		t.Fatal("authorization cache must start empty after restart")
	}
	status, route := getPushActionRoute(t, restartedServer, actionID, "device-one")
	if status != http.StatusOK || route["thread_id"] != "thread-1" || route["runtime"] != "codex" ||
		route["kind"] != pushbridge.RouteKindMessage || route["scope_id"] != "demo" || route["thread_authorized"] != true {
		t.Fatalf("route lost across restart: %d %v", status, route)
	}
	thread, ok := fresh.allowedThread("thread-1")
	if !ok || thread.scopeID != "demo" || thread.readOnly || thread.runtimeID != "codex" {
		t.Fatalf("thread authorization not restored: %+v %v", thread, ok)
	}
	if _, ok := newAppServerGatewayPolicy(restarted, "claude").allowedThread("thread-1"); ok {
		t.Fatal("restore must be scoped to the record's runtime")
	}
	registerPushDevice(t, restartedServer, "device-two")
	if status, _ := getPushActionRoute(t, restartedServer, actionID, "device-two"); status != http.StatusForbidden {
		t.Fatalf("device registered after the push was served: %d", status)
	}
	if status, _ := getPushActionRoute(t, restartedServer, "act-unknown", "device-one"); status != http.StatusNotFound {
		t.Fatalf("unknown id should be 404, got %d", status)
	}
	if status, _ := postDecide(t, restartedServer, actionID, "device-one", "allow"); status != http.StatusNotFound {
		t.Fatalf("locate record must not be decidable after restart, got %d", status)
	}
	// 同一 turn 不因重启再推一次。
	if _, forward, err := fresh.observeUpstreamFrame(websocket.TextMessage, payload); err != nil || !forward {
		t.Fatalf("frame rejected after restart: %v", err)
	}
	time.Sleep(50 * time.Millisecond)
	if provider.count() != 1 {
		t.Fatalf("turn pushed again after restart: %d", provider.count())
	}
}

func TestPushRouteDistinguishesUnknownFromExpired(t *testing.T) {
	provider := newFakePushProvider(t)
	server, router := pushTestFixture(t, "ws://unused", provider.server.URL)
	registerPushDevice(t, server, "device-one")
	if status, _ := getPushActionRoute(t, server, "act-missing", "device-one"); status != http.StatusNotFound {
		t.Fatalf("unknown id should be 404, got %d", status)
	}
	now := time.Now()
	router.push.Routes().Insert(now, pushbridge.LocateRecord{
		ID: "act-expired", Kind: pushbridge.RouteKindMessage, Runtime: "codex", ThreadID: "thread-1",
		DeviceIDs: []string{"device-one"}, CreatedAt: now.Add(-25 * time.Hour), ExpiresAt: now.Add(-time.Hour),
	})
	if status, _ := getPushActionRoute(t, server, "act-expired", "device-one"); status != http.StatusGone {
		t.Fatalf("expired record should be 410, got %d", status)
	}
}

// 补种授权只依据当前作用域配置：路径不再被授权就不补；缓存里已只读的线程保持只读。
func TestPushRouteRestoresThreadAuthorizationOnlyForResolvableScope(t *testing.T) {
	provider := newFakePushProvider(t)
	server, router := pushTestFixture(t, "ws://unused", provider.server.URL)
	registerPushDevice(t, server, "device-one")
	projectDir := router.cfg.Projects[0].Path
	scope, ok := router.gatewayScopeForPath(projectDir)
	if !ok {
		t.Fatal("测试项目必须具有 gateway scope")
	}
	now := time.Now()
	insert := func(id, threadID, cwd string, readOnly bool) {
		router.push.Routes().Insert(now, pushbridge.LocateRecord{
			ID: id, Kind: pushbridge.RouteKindApproval, Runtime: "codex", ThreadID: threadID, ProjectID: scope.id,
			ScopeID: scope.id, CWD: cwd, ReadOnly: readOnly, ApprovalKind: pushbridge.KindCommand,
			DeviceIDs: []string{"device-one"}, CreatedAt: now, ExpiresAt: now.Add(time.Hour),
		})
	}
	insert("act-restore", "thread-restored", projectDir, false)
	insert("act-orphan", "thread-orphan", t.TempDir(), false)
	insert("act-readonly", "thread-readonly", projectDir, true)
	insert("act-sticky", "thread-sticky", projectDir, false)
	router.allowGatewayThread(appServerGatewayAllowedThread{id: "thread-sticky", runtimeID: "codex", cwd: projectDir, scopeID: scope.id, readOnly: true})

	policy := newAppServerGatewayPolicy(router, "codex")
	if _, ok := policy.allowedThread("thread-restored"); ok {
		t.Fatal("thread must not be authorized before locate")
	}
	status, route := getPushActionRoute(t, server, "act-restore", "device-one")
	if status != http.StatusOK || route["thread_authorized"] != true || route["kind"] != pushbridge.RouteKindApproval || route["state"] != "unknown" {
		t.Fatalf("approval without handle should still locate: %d %v", status, route)
	}
	if thread, ok := policy.allowedThread("thread-restored"); !ok || thread.scopeID != scope.id || thread.readOnly {
		t.Fatalf("thread authorization not restored: %+v %v", thread, ok)
	}
	status, route = getPushActionRoute(t, server, "act-orphan", "device-one")
	if status != http.StatusOK || route["thread_authorized"] != false {
		t.Fatalf("unresolvable cwd must not seed authorization: %d %v", status, route)
	}
	if _, ok := policy.allowedThread("thread-orphan"); ok {
		t.Fatal("thread outside every scope was authorized")
	}
	getPushActionRoute(t, server, "act-readonly", "device-one")
	if thread, ok := policy.allowedThread("thread-readonly"); !ok || !thread.readOnly {
		t.Fatalf("read-only record must restore a read-only thread: %+v %v", thread, ok)
	}
	getPushActionRoute(t, server, "act-sticky", "device-one")
	if thread, ok := policy.allowedThread("thread-sticky"); !ok || !thread.readOnly {
		t.Fatalf("existing read-only entry must stay read-only: %+v %v", thread, ok)
	}
}

// iOS 用 gateway 作用域 id（worktree/子目录为 ws_…）标识会话；路由必须给同一个 id。
func TestProjectIDForThreadPrefersScopeID(t *testing.T) {
	browseRoot := t.TempDir()
	financeDir := filepath.Join(browseRoot, "finance")
	if err := os.MkdirAll(financeDir, 0o755); err != nil {
		t.Fatal(err)
	}
	_, router, projectDir := buildAppServerGatewayFixture(t, "", func(cfg *config.Config) {
		cfg.BrowseRoots = []string{browseRoot}
	})
	browseScope, ok := router.gatewayScopeForPath(financeDir)
	if !ok || !strings.HasPrefix(browseScope.id, "ws_") {
		t.Fatalf("browse scope missing: %+v %v", browseScope, ok)
	}
	policy := newAppServerGatewayPolicy(router, "codex")
	policy.allowThread(appServerGatewayAllowedThread{id: "thread-browse", cwd: financeDir, scopeID: browseScope.id})
	if got := policy.projectIDForThread("thread-browse"); got != browseScope.id {
		t.Fatalf("browse-scope thread should route by scope id, got %q want %q", got, browseScope.id)
	}
	// 没有作用域 id 的旧记录退回根项目 id。
	policy.mu.Lock()
	policy.allowedThreads["thread-root"] = appServerGatewayAllowedThread{id: "thread-root", cwd: projectDir}
	policy.mu.Unlock()
	if got := policy.projectIDForThread("thread-root"); got != "demo" {
		t.Fatalf("thread without scope id should fall back to root project, got %q", got)
	}
	// 只在全局缓存里的线程（断线后新连接）也能取到完整事实。
	projectScope, _ := router.gatewayScopeForPath(projectDir)
	router.allowGatewayThread(appServerGatewayAllowedThread{id: "thread-cached", runtimeID: "codex", cwd: projectDir, scopeID: projectScope.id, readOnly: true})
	facts := newAppServerGatewayPolicy(router, "codex").threadRouteFacts("thread-cached")
	if facts.projectID != "demo" || facts.scopeID != "demo" || facts.cwd != projectDir || !facts.readOnly || facts.runtime != "codex" {
		t.Fatalf("router-cache fallback facts wrong: %+v", facts)
	}
	if got := newAppServerGatewayPolicy(router, "codex").projectIDForThread("thread-unknown"); got != "" {
		t.Fatalf("unknown thread must not map to a project, got %q", got)
	}
}
