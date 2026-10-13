package httpapi

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/pushbridge"
	"github.com/gorilla/websocket"
)

func testClaudeApprovalObserver(t *testing.T, router *Router, sessionKey string) *claudeApprovalObserver {
	t.Helper()
	conn, peer := net.Pipe()
	t.Cleanup(func() {
		_ = conn.Close()
		_ = peer.Close()
	})
	_, cancel := context.WithCancel(context.Background())
	return &claudeApprovalObserver{
		router:      router,
		sessionKey:  sessionKey,
		conn:        conn,
		writeMu:     &sync.Mutex{},
		policy:      newAppServerGatewayPolicy(router, "claude"),
		cancel:      cancel,
		activeTurns: map[string]struct{}{},
		pending:     map[string]string{},
	}
}

func waitForApprovalActionState(t *testing.T, router *Router, actionID string, want pushbridge.ActionState) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if action, ok := router.push.Actions().Get(actionID); ok && action.State == want {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	action, _ := router.push.Actions().Get(actionID)
	t.Fatalf("等待 Action 状态超时：want=%s got=%s", want, action.State)
}

func TestInstallClaudeApprovalObserverReplacesGenerationAtomically(t *testing.T) {
	router := &Router{}
	epoch := router.stopClaudeApprovalObserver("session-1")
	oldObserver := testClaudeApprovalObserver(t, router, "session-1")
	if replaced, ok := router.installClaudeApprovalObserver(oldObserver, epoch); !ok || replaced != nil {
		t.Fatalf("首次安装结果异常：ok=%v replaced=%p", ok, replaced)
	}
	newObserver := testClaudeApprovalObserver(t, router, "session-1")
	replaced, ok := router.installClaudeApprovalObserver(newObserver, epoch)
	if !ok || replaced != oldObserver {
		t.Fatalf("替换结果异常：ok=%v replaced=%p", ok, replaced)
	}

	oldObserver.close("observer_replaced")
	if current := router.claudeApprovalObserverFor("session-1"); current != newObserver {
		t.Fatal("旧 generation 的迟到 close 删除了当前 observer")
	}
	newObserver.close("test_done")
	if current := router.claudeApprovalObserverFor("session-1"); current != nil {
		t.Fatal("当前 observer 关闭后应从 map 删除")
	}
}

func TestInstallClaudeApprovalObserverConcurrentReplacementLeavesOneCurrent(t *testing.T) {
	router := &Router{}
	epoch := router.stopClaudeApprovalObserver("session-race")
	const count = 16
	observers := make([]*claudeApprovalObserver, count)
	for index := range observers {
		observers[index] = testClaudeApprovalObserver(t, router, "session-race")
	}

	var wait sync.WaitGroup
	wait.Add(count)
	for _, observer := range observers {
		go func(candidate *claudeApprovalObserver) {
			defer wait.Done()
			replaced, ok := router.installClaudeApprovalObserver(candidate, epoch)
			if !ok {
				t.Errorf("同 session 的 replacement 不应受容量上限拒绝")
				return
			}
			if replaced != nil {
				replaced.close("observer_replaced")
			}
		}(observer)
	}
	wait.Wait()

	current := router.claudeApprovalObserverFor("session-race")
	if current == nil {
		t.Fatal("并发替换后必须留下一个当前 observer")
	}
	for _, observer := range observers {
		observer.mu.Lock()
		closed := observer.closed
		observer.mu.Unlock()
		if observer != current && !closed {
			t.Fatal("被竞争淘汰的 observer 没有关闭")
		}
	}
	current.close("test_done")
}

func TestInstallClaudeApprovalObserverRejectsStaleForegroundEpoch(t *testing.T) {
	router := &Router{}
	oldEpoch := router.stopClaudeApprovalObserver("session-epoch")
	newEpoch := router.stopClaudeApprovalObserver("session-epoch")
	if newEpoch <= oldEpoch {
		t.Fatalf("新前台连接必须推进 observer 代际：old=%d new=%d", oldEpoch, newEpoch)
	}

	stale := testClaudeApprovalObserver(t, router, "session-epoch")
	if replaced, ok := router.installClaudeApprovalObserver(stale, oldEpoch); ok || replaced != nil {
		t.Fatalf("旧 handler 不得在新前台连接后安装 observer：ok=%v replaced=%p", ok, replaced)
	}
	if current := router.claudeApprovalObserverFor("session-epoch"); current != nil {
		t.Fatal("拒绝旧代际后不应留下 observer")
	}

	current := testClaudeApprovalObserver(t, router, "session-epoch")
	if replaced, ok := router.installClaudeApprovalObserver(current, newEpoch); !ok || replaced != nil {
		t.Fatalf("当前代际应允许安装 observer：ok=%v replaced=%p", ok, replaced)
	}
	current.close("test_done")
}

func TestClaudeApprovalObserverSweepKeepsAuthorizedIdleRoute(t *testing.T) {
	observer := testClaudeApprovalObserver(t, &Router{}, "session-authorized")
	observer.startedAt = time.Now()
	observer.policy.mu.Lock()
	observer.policy.allowedThreads["thread-1"] = appServerGatewayAllowedThread{
		id: "thread-1", runtimeID: "claude", scopeID: "demo",
	}
	observer.policy.mu.Unlock()
	if reason := observer.sweepCloseReason(time.Now().Add(time.Minute)); reason != "" {
		t.Fatalf("有已授权 thread 时空闲 observer 应保活：%s", reason)
	}
}

func TestClaudeApprovalObserverSweepReclaimsUnauthorizedIdleAndHonorsTTL(t *testing.T) {
	observer := testClaudeApprovalObserver(t, &Router{}, "session-sweep")
	observer.startedAt = time.Now()
	if reason := observer.sweepCloseReason(time.Now().Add(time.Minute)); reason != "observer_idle" {
		t.Fatalf("无授权的空闲 observer 应回收：%s", reason)
	}
	observer.policy.mu.Lock()
	observer.policy.allowedThreads["thread-1"] = appServerGatewayAllowedThread{
		id: "thread-1", runtimeID: "claude", scopeID: "demo",
	}
	observer.policy.mu.Unlock()
	if reason := observer.sweepCloseReason(observer.startedAt.Add(claudeObserverTTL + time.Second)); reason != "observer_ttl" {
		t.Fatalf("有授权也不能越过 24h TTL：%s", reason)
	}
}

func TestClaudeApprovalObserverHolderWaitingRequiresLocalThreadAuthorization(t *testing.T) {
	provider := newFakePushProvider(t)
	server, router := pushTestFixture(t, "ws://unused", provider.server.URL)
	supported := true
	registerPushDeviceWithCapability(t, server, "device-a", &supported)
	projectDir := router.cfg.Projects[0].Path
	scope, ok := router.gatewayScopeForPath(projectDir)
	if !ok {
		t.Fatal("测试项目必须具有 gateway scope")
	}

	observer := testClaudeApprovalObserver(t, router, "session-local-auth")
	observer.policy.mu.Lock()
	observer.policy.allowedThreads["thread-a"] = appServerGatewayAllowedThread{
		id: "thread-a", runtimeID: "claude", cwd: projectDir, scopeID: scope.id,
	}
	observer.policy.mu.Unlock()
	// B 只属于另一条连接留下的全局缓存，不能成为当前 observer 的授权来源。
	router.allowGatewayThread(appServerGatewayAllowedThread{
		id: "thread-b", runtimeID: "claude", cwd: projectDir, scopeID: scope.id,
	})
	waitingFrame := func(threadID string, updatedAt int64) []byte {
		return []byte(`{"method":"thread/status/changed","params":{"threadId":"` + threadID +
			`","status":{"type":"active","activeFlags":["waitingOnUserInput"]},"canAcceptDirectInput":false,` +
			`"claudeOwner":{"pid":42,"status":"waiting","waitingKind":"input","statusUpdatedAt":` +
			fmt.Sprint(updatedAt) + `}}}`)
	}
	observer.observe(waitingFrame("thread-b", 1700000000000))
	time.Sleep(50 * time.Millisecond)
	if provider.count() != 0 {
		t.Fatalf("仅全局授权的 thread-b 不得由当前 observer 推送，got=%d", provider.count())
	}

	observer.observe(waitingFrame("thread-a", 1700000001000))
	notification := provider.waitFor(t, pushbridge.EventHolderWaiting)
	actionID, _ := notification["action_id"].(string)
	status, route := getPushActionRoute(t, server, actionID, "device-a")
	if status != 200 || route["thread_id"] != "thread-a" {
		t.Fatalf("本地授权 thread-a 应正常推送并定位：status=%d route=%v", status, route)
	}

	// 状态广播门禁不能改变审批请求的既有 pending 登记链路。
	observer.observe([]byte(`{"id":"approval-a","method":"item/commandExecution/requestApproval","params":{"threadId":"thread-a","turnId":"turn-a","itemId":"item-a"}}`))
	observer.mu.Lock()
	pending := len(observer.pending)
	observer.mu.Unlock()
	if pending != 1 {
		t.Fatalf("审批 pending 登记不应受状态广播门禁影响：%d", pending)
	}
}

func TestClaudeApprovalObserverReplacementRevokesOnlyStaleActions(t *testing.T) {
	provider := newFakePushProvider(t)
	_, router := pushTestFixture(t, "", provider.server.URL)
	epoch := router.stopClaudeApprovalObserver("session-actions")
	oldObserver := testClaudeApprovalObserver(t, router, "session-actions")
	oldObserver.pending[`"stale"`] = "thread-1"
	oldObserver.pending[`"inherited"`] = "thread-1"
	if replaced, ok := router.installClaudeApprovalObserver(oldObserver, epoch); !ok || replaced != nil {
		t.Fatal("旧 observer 安装失败")
	}

	stale, _, err := router.push.Actions().Issue(pushbridge.Action{
		Runtime: "claude", SessionKey: "session-actions", RequestID: `"stale"`,
		ThreadID: "thread-1", Method: "item/commandExecution/requestApproval", Kind: pushbridge.KindCommand,
	}, []string{"device-a"})
	if err != nil {
		t.Fatal(err)
	}
	inherited, _, err := router.push.Actions().Issue(pushbridge.Action{
		Runtime: "claude", SessionKey: "session-actions", RequestID: `"inherited"`,
		ThreadID: "thread-1", Method: "item/commandExecution/requestApproval", Kind: pushbridge.KindCommand,
	}, []string{"device-a"})
	if err != nil {
		t.Fatal(err)
	}

	newObserver := testClaudeApprovalObserver(t, router, "session-actions")
	newObserver.pending[`"inherited"`] = "thread-1"
	if replaced, ok := router.installClaudeApprovalObserver(newObserver, epoch); !ok || replaced != oldObserver {
		t.Fatal("新 observer 替换失败")
	}
	oldObserver.close("observer_replaced")

	waitForApprovalActionState(t, router, stale.ID, pushbridge.StateRevoked)
	if action, ok := router.push.Actions().Get(inherited.ID); !ok || action.State != pushbridge.StatePending {
		t.Fatalf("继承的 Action 不得被旧 generation 撤销：ok=%v state=%s", ok, action.State)
	}
	newObserver.close("test_done")
}

func TestClaudeApprovalObserverCloseCannotLeaveLatePendingAction(t *testing.T) {
	provider := newFakePushProvider(t)
	server, router := pushTestFixture(t, "", provider.server.URL)
	registerPushDevice(t, server, "device-a")
	epoch := router.stopClaudeApprovalObserver("session-order")
	observer := testClaudeApprovalObserver(t, router, "session-order")
	if replaced, ok := router.installClaudeApprovalObserver(observer, epoch); !ok || replaced != nil {
		t.Fatal("observer 安装失败")
	}

	payload := []byte(`{"id":"approval-fast","method":"execCommandApproval","params":{"conversationId":"thread-1","callId":"call-1","command":["ls"]}}`)
	observer.observe(payload)
	if got := router.push.Actions().Len(); got != 1 {
		t.Fatalf("observe 返回前必须同步签发 Action，got=%d", got)
	}
	action, _, created := router.push.PreparePending(pushbridge.ApprovalRequest{
		Runtime:    "claude",
		SessionKey: "session-order",
		ThreadID:   "thread-1",
		RequestID:  `"approval-fast"`,
		Method:     "execCommandApproval",
	})
	if created {
		t.Fatal("同一请求应命中 observe 已经签发的 Action")
	}
	observer.close("test_done")
	resolved, ok := router.push.Actions().Get(action.ID)
	if !ok || resolved.State != pushbridge.StateRevoked {
		t.Fatalf("observer 关闭后不得留下迟到 Action：ok=%v state=%s", ok, resolved.State)
	}
}

func TestClaudeApprovalObserverRejectsSubmitAfterReplacementAndRestoresPending(t *testing.T) {
	_, router, projectDir := buildAppServerGatewayFixture(t, "", nil)
	scope, ok := router.gatewayScopeForPath(projectDir)
	if !ok {
		t.Fatal("测试项目必须具有 gateway scope")
	}
	router.allowGatewayThread(appServerGatewayAllowedThread{id: "thread-1", runtimeID: "claude", cwd: projectDir, scopeID: scope.id})
	router.cfg.AppServer.Transport = "ws"
	epoch := router.stopClaudeApprovalObserver("session-submit")
	oldObserver := testClaudeApprovalObserver(t, router, "session-submit")
	request := []byte(`{"id":"approval-stale","method":"execCommandApproval","params":{"conversationId":"thread-1","callId":"call-1","command":["ls"]}}`)
	if _, forward, policyErr := oldObserver.policy.observeUpstreamFrame(websocket.TextMessage, request); policyErr != nil || !forward {
		t.Fatalf("旧 observer 登记审批失败：forward=%v err=%+v", forward, policyErr)
	}
	if replaced, ok := router.installClaudeApprovalObserver(oldObserver, epoch); !ok || replaced != nil {
		t.Fatal("旧 observer 安装失败")
	}
	newObserver := testClaudeApprovalObserver(t, router, "session-submit")
	if replaced, ok := router.installClaudeApprovalObserver(newObserver, epoch); !ok || replaced != oldObserver {
		t.Fatal("新 observer 替换失败")
	}

	response := []byte(`{"id":"approval-stale","result":{"decision":"accept"}}`)
	if err := oldObserver.submit(t.Context(), response); err == nil {
		t.Fatal("已被替换的 observer 不得继续写旧 bridge")
	}
	id := json.RawMessage(`"approval-stale"`)
	if _, ok := oldObserver.policy.pendingServerRequest(&id); !ok {
		t.Fatal("generation 检查拒绝写入后必须恢复 pending")
	}
	oldObserver.close("observer_replaced")
	newObserver.close("test_done")
}
