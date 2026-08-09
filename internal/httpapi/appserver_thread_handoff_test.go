package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestAppServerThreadHandoffReclaimCancelsPendingWatcher(t *testing.T) {
	started := make(chan struct{})
	coordinator := &appServerThreadHandoffCoordinator{
		entries: map[string]*appServerThreadHandoffEntry{},
		run: func(ctx context.Context, _ string, _ func() bool) (appServerThreadHandoffOutcome, error) {
			close(started)
			<-ctx.Done()
			return "", ctx.Err()
		},
	}
	t.Cleanup(coordinator.Close)

	if !coordinator.Schedule("thread-pending") {
		t.Fatal("首次 handoff 应成功调度")
	}
	if !coordinator.Schedule("thread-pending") {
		t.Fatal("重复 handoff 应幂等复用同一个 watcher")
	}
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("handoff watcher 未启动")
	}
	if err := coordinator.Reclaim("thread-pending"); err != nil {
		t.Fatalf("重新使用 thread 应取消尚未执行的 handoff：%v", err)
	}
	waitForThreadHandoffEntryCount(t, coordinator, 0)
}

func TestAppServerThreadHandoffDelayedCompletionIsCanceledByNewTurn(t *testing.T) {
	var runs atomic.Int64
	coordinator := &appServerThreadHandoffCoordinator{
		entries: map[string]*appServerThreadHandoffEntry{},
		run: func(_ context.Context, _ string, _ func() bool) (appServerThreadHandoffOutcome, error) {
			runs.Add(1)
			return appServerThreadHandoffReleased, nil
		},
	}
	t.Cleanup(coordinator.Close)
	router := &Router{threadHandoffs: coordinator}
	policy := &appServerGatewayPolicy{router: router, runtimeID: "codex"}

	if !coordinator.ScheduleAfter("thread-next-turn", 40*time.Millisecond) {
		t.Fatal("terminal handoff 应成功延迟调度")
	}
	if err := policy.guardThreadHandoff("turn/start", map[string]any{"threadId": "thread-next-turn"}); err != nil {
		t.Fatalf("新 turn 应取消尚未执行的 terminal handoff：%v", err)
	}
	time.Sleep(60 * time.Millisecond)
	if runs.Load() != 0 {
		t.Fatalf("已被新 turn 取消的 handoff 不应执行，runs=%d", runs.Load())
	}
	waitForThreadHandoffEntryCount(t, coordinator, 0)
}

func TestAppServerTurnCompletedNotificationSchedulesTerminalHandoff(t *testing.T) {
	coordinator := &appServerThreadHandoffCoordinator{
		entries: map[string]*appServerThreadHandoffEntry{},
		run: func(ctx context.Context, _ string, _ func() bool) (appServerThreadHandoffOutcome, error) {
			<-ctx.Done()
			return "", ctx.Err()
		},
	}
	t.Cleanup(coordinator.Close)
	policy := &appServerGatewayPolicy{
		router:               &Router{threadHandoffs: coordinator},
		runtimeID:            "codex",
		threadHandoffCapable: true,
		allowedThreads:       map[string]appServerGatewayAllowedThread{"thread-terminal": {id: "thread-terminal"}},
	}
	payload := []byte(`{"method":"turn/completed","params":{"threadId":"thread-terminal","turnId":"turn-1"}}`)

	forwarded, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, payload)
	if policyErr != nil || !forward || string(forwarded) != string(payload) {
		t.Fatalf("turn/completed 应原样透传并调度 handoff，forward=%t err=%+v payload=%s", forward, policyErr, forwarded)
	}
	coordinator.mu.Lock()
	entry := coordinator.entries["thread-terminal"]
	coordinator.mu.Unlock()
	if entry == nil || entry.executing {
		t.Fatalf("terminal handoff 应先处于可取消的 grace 窗口，entry=%+v", entry)
	}
	if err := policy.guardThreadHandoff("turn/start", map[string]any{"threadId": "thread-terminal"}); err != nil {
		t.Fatalf("续问应取消 terminal handoff：%v", err)
	}
	waitForThreadHandoffEntryCount(t, coordinator, 0)
}

func TestAppServerTurnCompletedAutoHandoffRequiresClientCapability(t *testing.T) {
	var runs atomic.Int64
	coordinator := &appServerThreadHandoffCoordinator{
		entries: map[string]*appServerThreadHandoffEntry{},
		run: func(_ context.Context, _ string, _ func() bool) (appServerThreadHandoffOutcome, error) {
			runs.Add(1)
			return appServerThreadHandoffReleased, nil
		},
	}
	t.Cleanup(coordinator.Close)
	policy := &appServerGatewayPolicy{
		router:         &Router{threadHandoffs: coordinator},
		runtimeID:      "codex",
		allowedThreads: map[string]appServerGatewayAllowedThread{"thread-old-client": {id: "thread-old-client"}},
	}
	payload := []byte(`{"method":"turn/completed","params":{"threadId":"thread-old-client","turnId":"turn-1"}}`)

	if _, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, payload); policyErr != nil || !forward {
		t.Fatalf("旧客户端仍应收到 terminal notification：forward=%t err=%+v", forward, policyErr)
	}
	time.Sleep(10 * time.Millisecond)
	if runs.Load() != 0 {
		t.Fatalf("未声明 capability 的旧 iOS 不能触发 auto-handoff，runs=%d", runs.Load())
	}
	coordinator.mu.Lock()
	entryCount := len(coordinator.entries)
	coordinator.mu.Unlock()
	if entryCount != 0 {
		t.Fatalf("旧客户端不应安装 handoff entry，count=%d", entryCount)
	}
}

func TestAppServerInitializeRecordsPrivateThreadHandoffCapability(t *testing.T) {
	policy := &appServerGatewayPolicy{runtimeID: "codex"}
	policy.rememberThreadHandoffCapability("initialize", map[string]any{
		"capabilities": map[string]any{"mimiThreadHandoff": true},
	})
	if !policy.supportsThreadHandoff() {
		t.Fatal("新版 iOS initialize capability 应启用 terminal auto-handoff")
	}
	policy.rememberThreadHandoffCapability("initialize", map[string]any{
		"capabilities": map[string]any{"mimiThreadHandoff": false},
	})
	if policy.supportsThreadHandoff() {
		t.Fatal("未声明 capability 时必须保持旧客户端兼容行为")
	}
}

func TestAppServerThreadHandoffRewritesOnlyOwnedLifecycleNotifications(t *testing.T) {
	started := make(chan struct{})
	finish := make(chan struct{})
	coordinator := &appServerThreadHandoffCoordinator{
		entries: map[string]*appServerThreadHandoffEntry{},
		run: func(_ context.Context, _ string, markExecuting func() bool) (appServerThreadHandoffOutcome, error) {
			if !markExecuting() {
				return "", context.Canceled
			}
			close(started)
			<-finish
			return appServerThreadHandoffReleased, nil
		},
	}
	t.Cleanup(coordinator.Close)
	policy := &appServerGatewayPolicy{
		router:    &Router{threadHandoffs: coordinator},
		runtimeID: "codex",
	}
	coordinator.Schedule("thread-lifecycle")
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("handoff 未进入 executing")
	}

	assertRewritten := func(payload string, originalMethod string) {
		t.Helper()
		rewritten, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, []byte(payload))
		if policyErr != nil || !forward {
			t.Fatalf("handoff 生命周期通知应以私有通知继续转发：err=%+v forward=%v", policyErr, forward)
		}
		var frame appServerGatewayFrame
		if err := json.Unmarshal(rewritten, &frame); err != nil {
			t.Fatalf("解析改写通知失败：%v", err)
		}
		if frame.Method != appServerThreadHandoffLifecycleMethod {
			t.Fatalf("handoff 生命周期必须改写为私有 method，got=%s", frame.Method)
		}
		params, err := decodeGatewayParams(frame.Params)
		if err != nil || params["originalMethod"] != originalMethod {
			t.Fatalf("私有通知必须保留原 method：params=%+v err=%v", params, err)
		}
	}

	assertRewritten(`{"method":"thread/archived","params":{"threadId":"thread-lifecycle"}}`, "thread/archived")
	assertRewritten(`{"method":"thread/closed","params":{"threadId":"thread-lifecycle"}}`, "thread/closed")
	assertRewritten(`{"method":"thread/status/changed","params":{"threadId":"thread-lifecycle","status":{"type":"notLoaded"}}}`, "thread/status/changed")
	assertRewritten(`{"method":"thread/unarchived","params":{"threadId":"thread-lifecycle"}}`, "thread/unarchived")

	close(finish)
	waitForThreadHandoffEntryCount(t, coordinator, 0)
	// 模拟该 gateway 之前一帧写回客户端阻塞：entry 已删除、policy 从未见过任何
	// handoff lifecycle，第一条迟到 closed 仍必须由 coordinator tombstone 识别。
	latePolicy := &appServerGatewayPolicy{
		router:    &Router{threadHandoffs: coordinator},
		runtimeID: "codex",
	}
	latePayload := []byte(`{"method":"thread/closed","params":{"threadId":"thread-lifecycle"}}`)
	lateRewritten, forward, policyErr := latePolicy.observeUpstreamFrame(websocket.TextMessage, latePayload)
	var lateFrame appServerGatewayFrame
	if policyErr != nil || !forward || json.Unmarshal(lateRewritten, &lateFrame) != nil ||
		lateFrame.Method != appServerThreadHandoffLifecycleMethod {
		t.Fatalf("entry 删除后的第一条迟到 closed 仍必须改写：err=%+v forward=%v payload=%s", policyErr, forward, lateRewritten)
	}

	coordinator.mu.Lock()
	coordinator.lifecycleUntil["thread-lifecycle"] = time.Now().Add(-time.Second)
	coordinator.mu.Unlock()
	latePolicy.mu.Lock()
	latePolicy.threadHandoffLifecycle["thread-lifecycle"] = time.Now().Add(-time.Second)
	latePolicy.mu.Unlock()
	ordinary := []byte(`{"method":"thread/closed","params":{"threadId":"thread-lifecycle"}}`)
	rewritten, forward, policyErr := latePolicy.observeUpstreamFrame(websocket.TextMessage, ordinary)
	if policyErr != nil || !forward || string(rewritten) != string(ordinary) {
		t.Fatalf("handoff 来源窗口外的真实 closed 必须保留原语义：err=%+v forward=%v payload=%s", policyErr, forward, rewritten)
	}
}

func TestAppServerThreadHandoffReclaimRejectsOldFrameAfterExecutingWindow(t *testing.T) {
	started := make(chan struct{})
	finish := make(chan struct{})
	coordinator := &appServerThreadHandoffCoordinator{
		entries: map[string]*appServerThreadHandoffEntry{},
		run: func(_ context.Context, _ string, markExecuting func() bool) (appServerThreadHandoffOutcome, error) {
			if !markExecuting() {
				return "", context.Canceled
			}
			close(started)
			<-finish
			return appServerThreadHandoffReleased, nil
		},
	}
	t.Cleanup(coordinator.Close)

	coordinator.Schedule("thread-executing")
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("handoff 未进入 executing")
	}
	policy := &appServerGatewayPolicy{
		router:    &Router{threadHandoffs: coordinator},
		runtimeID: "codex",
	}
	reclaimed := make(chan error, 1)
	go func() {
		reclaimed <- policy.guardThreadHandoff("turn/start", map[string]any{"threadId": "thread-executing"})
	}()
	select {
	case err := <-reclaimed:
		t.Fatalf("archive/unarchive 完成前续问必须保持等待，got=%v", err)
	case <-time.After(20 * time.Millisecond):
	}
	close(finish)
	select {
	case err := <-reclaimed:
		if !errors.Is(err, errAppServerThreadHandoffExecuting) {
			t.Fatalf("原 frame 跨过执行窗口后必须拒绝并要求新请求，got=%v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("unarchive 完成后旧请求仍未收到可重试拒绝")
	}
	waitForThreadHandoffEntryCount(t, coordinator, 0)
}

func TestAppServerThreadHandoffGatewayCancellationDoesNotCancelRecovery(t *testing.T) {
	started := make(chan struct{})
	finish := make(chan struct{})
	coordinator := &appServerThreadHandoffCoordinator{
		entries: map[string]*appServerThreadHandoffEntry{},
		run: func(_ context.Context, _ string, markExecuting func() bool) (appServerThreadHandoffOutcome, error) {
			if !markExecuting() {
				return "", context.Canceled
			}
			close(started)
			<-finish
			return appServerThreadHandoffReleased, nil
		},
	}
	t.Cleanup(coordinator.Close)
	coordinator.Schedule("thread-context-cancel")
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("handoff 未进入 executing")
	}

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := coordinator.ReclaimContext(ctx, "thread-context-cancel"); err == nil {
		t.Fatal("gateway context 取消后 waiter 应退出")
	}
	coordinator.mu.Lock()
	entryStillRunning := coordinator.entries["thread-context-cancel"] != nil
	coordinator.mu.Unlock()
	if !entryStillRunning {
		t.Fatal("gateway waiter 取消不能取消独立的 unarchive 恢复任务")
	}
	close(finish)
	waitForThreadHandoffEntryCount(t, coordinator, 0)
}

func TestAppServerThreadHandoffDeadlineRejectsOldFrameAsRetryableBeforeForwarding(t *testing.T) {
	started := make(chan struct{})
	finish := make(chan struct{})
	coordinator := &appServerThreadHandoffCoordinator{
		entries: map[string]*appServerThreadHandoffEntry{},
		run: func(_ context.Context, _ string, markExecuting func() bool) (appServerThreadHandoffOutcome, error) {
			if !markExecuting() {
				return "", context.Canceled
			}
			close(started)
			<-finish
			return appServerThreadHandoffReleased, nil
		},
	}
	_, router, projectDir := buildAppServerGatewayFixture(t, "", nil)
	router.threadHandoffs.Close()
	router.threadHandoffs = coordinator
	t.Cleanup(coordinator.Close)
	scope, ok := router.gatewayScopeForPath(projectDir)
	if !ok {
		t.Fatal("测试项目目录应命中 gateway scope")
	}
	policy := &appServerGatewayPolicy{
		router:    router,
		runtimeID: "codex",
		allowedThreads: map[string]appServerGatewayAllowedThread{
			"thread-deadline": {
				id: "thread-deadline", runtimeID: "codex", cwd: projectDir, scopeID: scope.id,
			},
		},
	}
	payload := []byte(fmt.Sprintf(
		`{"id":41,"method":"turn/start","params":{"threadId":"thread-deadline","cwd":%q,"input":[{"type":"text","text":"retry once"}],"approvalPolicy":"on-request","approvalsReviewer":"user","sandboxPolicy":{"type":"workspaceWrite","writableRoots":[%q],"networkAccess":false}}}`,
		projectDir,
		projectDir,
	))
	coordinator.Schedule("thread-deadline")
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("handoff 未进入 executing")
	}

	requestCtx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	forwarded, policyErr := policy.validateClientFrameContext(requestCtx, websocket.TextMessage, payload)
	if policyErr == nil || len(forwarded) != 0 {
		t.Fatalf("deadline 后旧 frame 必须明确拒绝且永不转发，err=%+v payload=%s", policyErr, forwarded)
	}
	if policyErr.data["reason"] != "thread_handoff_in_progress" ||
		policyErr.data["accepted"] != false || policyErr.data["retryable"] != true {
		t.Fatalf("handoff timeout 必须携带安全重试证据：%+v", policyErr.data)
	}
	close(finish)
	waitForThreadHandoffEntryCount(t, coordinator, 0)

	forwarded, policyErr = policy.validateClientFrame(websocket.TextMessage, payload)
	if policyErr != nil || len(forwarded) == 0 {
		t.Fatalf("恢复后客户端新 retry 应只转发一次，err=%+v payload=%s", policyErr, forwarded)
	}
}

func TestAppServerThreadHandoffHandlerRequiresAuthorizedWritableThread(t *testing.T) {
	coordinator := &appServerThreadHandoffCoordinator{
		entries: map[string]*appServerThreadHandoffEntry{},
		run: func(ctx context.Context, _ string, _ func() bool) (appServerThreadHandoffOutcome, error) {
			<-ctx.Done()
			return "", ctx.Err()
		},
	}
	defer coordinator.Close()
	router := &Router{
		gatewayThreads: map[string]appServerGatewayAllowedThread{},
		threadHandoffs: coordinator,
	}

	unauthorized := httptest.NewRecorder()
	router.appServerThreadHandoffHandler(unauthorized, authedRequest(t, http.MethodPost, appServerThreadHandoffPath, appServerThreadHandoffRequest{ThreadID: "thread-outside"}))
	if unauthorized.Code != http.StatusForbidden {
		t.Fatalf("未授权 thread 必须拒绝，got=%d body=%s", unauthorized.Code, unauthorized.Body.String())
	}

	router.allowGatewayThread(appServerGatewayAllowedThread{id: "thread-authorized", runtimeID: "codex", scopeID: "demo"})
	recorder := httptest.NewRecorder()
	router.appServerThreadHandoffHandler(recorder, authedRequest(t, http.MethodPost, appServerThreadHandoffPath, appServerThreadHandoffRequest{ThreadID: "thread-authorized"}))
	if recorder.Code != http.StatusAccepted {
		t.Fatalf("已授权 thread 应接受调度，got=%d body=%s", recorder.Code, recorder.Body.String())
	}
	var response appServerThreadHandoffResponse
	if err := json.NewDecoder(recorder.Body).Decode(&response); err != nil {
		t.Fatal(err)
	}
	if response.ThreadID != "thread-authorized" || response.Status != "scheduled" {
		t.Fatalf("handoff 响应异常：%+v", response)
	}
}

func TestRunCodexThreadHandoffWaitsForIdleThenArchivesAndRestores(t *testing.T) {
	statuses := []string{"active", "idle", "idle"}
	router, methods := threadHandoffRPCFixture(t, "thread-idle", statuses, nil)
	var executing atomic.Int64
	outcome, err := router.runCodexThreadHandoff(context.Background(), "thread-idle", func() bool {
		executing.Add(1)
		return true
	}, 5*time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	if outcome != appServerThreadHandoffReleased || executing.Load() != 1 {
		t.Fatalf("handoff 应只在 idle 后执行一次，outcome=%s executing=%d", outcome, executing.Load())
	}
	assertThreadHandoffMethodOrder(t, methods, []string{
		"initialize", "initialized", "thread/read", "thread/read", "thread/read", "thread/archive", "thread/unarchive",
	})
}

func TestRunCodexThreadHandoffTreatsNotLoadedAsAlreadyReleased(t *testing.T) {
	router, methods := threadHandoffRPCFixture(t, "thread-unloaded", []string{"notLoaded"}, nil)
	outcome, err := router.runCodexThreadHandoff(context.Background(), "thread-unloaded", func() bool {
		t.Fatal("notLoaded 不应进入 archive/unarchive")
		return false
	}, time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	if outcome != appServerThreadHandoffAlreadyReleased {
		t.Fatalf("notLoaded 状态应幂等成功，got=%s", outcome)
	}
	assertThreadHandoffMethodOrder(t, methods, []string{"initialize", "initialized", "thread/read"})
}

func TestRunCodexThreadHandoffRetriesUnarchiveOnFreshConnection(t *testing.T) {
	var unarchiveAttempts atomic.Int64
	router, methods := threadHandoffRPCFixture(t, "thread-recover", []string{"idle", "idle"}, func(method string) bool {
		return method == "thread/unarchive" && unarchiveAttempts.Add(1) == 1
	})
	outcome, err := router.runCodexThreadHandoff(context.Background(), "thread-recover", func() bool { return true }, time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	if outcome != appServerThreadHandoffReleased || unarchiveAttempts.Load() != 2 {
		t.Fatalf("unarchive 应换新连接重试并恢复，outcome=%s attempts=%d", outcome, unarchiveAttempts.Load())
	}
	got := collectThreadHandoffMethods(methods)
	if countThreadHandoffMethod(got, "thread/unarchive") != 2 || countThreadHandoffMethod(got, "initialize") != 2 {
		t.Fatalf("恢复路径应建立新连接并重试 unarchive，methods=%v", got)
	}
}

func TestRunCodexThreadHandoffRecoveryJournalSurvivesRepeatedUnarchiveFailure(t *testing.T) {
	const threadID = "thread-crash-safe"
	var unarchiveAttempts atomic.Int64
	router, methods := threadHandoffRPCFixture(t, threadID, []string{"idle", "idle"}, func(method string) bool {
		return method == "thread/unarchive" && unarchiveAttempts.Add(1) <= 3
	})
	storePath := filepath.Join(t.TempDir(), "state", "thread-handoff-recovery.json")
	router.threadHandoffRecovery = newAppServerThreadHandoffRecoveryStore(storePath)

	_, err := router.runCodexThreadHandoff(context.Background(), threadID, func() bool { return true }, time.Millisecond)
	if err == nil || !router.threadHandoffRecovery.RequiresUnarchive(threadID) {
		t.Fatalf("连续 unarchive 失败后必须保留 durable recovery marker，err=%v", err)
	}

	// 模拟 agentd 重启：从同一文件重新加载；恢复路径不能先 thread/read，
	// 否则 archived thread 的 notLoaded 会被误判为已经释放。
	router.threadHandoffRecovery = newAppServerThreadHandoffRecoveryStore(storePath)
	if loadErr := router.threadHandoffRecovery.LoadError(); loadErr != nil {
		t.Fatal(loadErr)
	}
	outcome, err := router.runCodexThreadHandoff(context.Background(), threadID, func() bool { return true }, time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	if outcome != appServerThreadHandoffReleased || router.threadHandoffRecovery.RequiresUnarchive(threadID) {
		t.Fatalf("重启恢复必须 unarchive 并清理 marker，outcome=%s", outcome)
	}
	got := collectThreadHandoffMethods(methods)
	if countThreadHandoffMethod(got, "thread/read") != 2 ||
		countThreadHandoffMethod(got, "thread/archive") != 1 ||
		countThreadHandoffMethod(got, "thread/unarchive") != 4 {
		t.Fatalf("恢复必须跳过第二轮 read/archive，methods=%v", got)
	}
}

func TestRunCodexThreadHandoffDoesNotArchiveWhenRecoveryJournalCannotPersist(t *testing.T) {
	const threadID = "thread-store-failure"
	router, methods := threadHandoffRPCFixture(t, threadID, []string{"idle", "idle"}, nil)
	blockedParent := filepath.Join(t.TempDir(), "blocked")
	storePath := filepath.Join(blockedParent, "thread-handoff-recovery.json")
	router.threadHandoffRecovery = newAppServerThreadHandoffRecoveryStore(storePath)
	if err := os.WriteFile(blockedParent, []byte("not a directory"), 0o600); err != nil {
		t.Fatal(err)
	}

	_, err := router.runCodexThreadHandoff(context.Background(), threadID, func() bool { return true }, time.Millisecond)
	if err == nil {
		t.Fatal("恢复日志无法持久化时 handoff 必须失败关闭")
	}
	got := collectThreadHandoffMethods(methods)
	if countThreadHandoffMethod(got, "thread/archive") != 0 || countThreadHandoffMethod(got, "thread/unarchive") != 0 {
		t.Fatalf("marker 未 durable 前禁止 archive，methods=%v", got)
	}
}

func threadHandoffRPCFixture(
	t *testing.T,
	threadID string,
	statuses []string,
	shouldFail func(method string) bool,
) (*Router, <-chan string) {
	t.Helper()
	methods := make(chan string, 32)
	var statusMu sync.Mutex
	statusIndex := 0
	upstreamURL, received, _ := fakeAppServerUpstream(t, func(conn *websocket.Conn, _ int, payload []byte) {
		var frame appServerGatewayFrame
		if err := json.Unmarshal(payload, &frame); err != nil {
			t.Errorf("handoff fake upstream 收到无效 JSON：%v", err)
			return
		}
		method := strings.TrimSpace(frame.Method)
		methods <- method
		if frame.ID == nil {
			return
		}
		if shouldFail != nil && shouldFail(method) {
			_ = conn.WriteJSON(map[string]any{
				"id":    frame.ID,
				"error": map[string]any{"code": -32000, "message": "injected failure"},
			})
			return
		}
		var result any = map[string]any{}
		switch method {
		case "initialize":
			result = map[string]any{"userAgent": "codex-test/1.0"}
		case "thread/read":
			statusMu.Lock()
			status := statuses[len(statuses)-1]
			if statusIndex < len(statuses) {
				status = statuses[statusIndex]
				statusIndex++
			}
			statusMu.Unlock()
			result = map[string]any{
				"thread": map[string]any{"id": threadID, "status": map[string]any{"type": status}},
			}
		}
		_ = conn.WriteJSON(map[string]any{"id": frame.ID, "result": result})
	})
	drainDone := make(chan struct{})
	go func() {
		for {
			select {
			case <-received:
			case <-drainDone:
				return
			}
		}
	}()
	t.Cleanup(func() { close(drainDone) })

	_, router := appServerGatewayRouterFixtureWithRouter(t, upstreamURL, nil)
	t.Cleanup(router.threadHandoffs.Close)
	return router, methods
}

func assertThreadHandoffMethodOrder(t *testing.T, methods <-chan string, want []string) {
	t.Helper()
	got := make([]string, 0, len(want))
	for range want {
		select {
		case method := <-methods:
			got = append(got, method)
		case <-time.After(time.Second):
			t.Fatalf("等待 handoff RPC 超时，got=%v want=%v", got, want)
		}
	}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("handoff RPC 顺序异常，got=%v want=%v", got, want)
	}
}

func collectThreadHandoffMethods(methods <-chan string) []string {
	got := make([]string, 0, len(methods))
	for {
		select {
		case method := <-methods:
			got = append(got, method)
		default:
			return got
		}
	}
}

func countThreadHandoffMethod(methods []string, want string) int {
	count := 0
	for _, method := range methods {
		if method == want {
			count++
		}
	}
	return count
}

func waitForThreadHandoffEntryCount(t *testing.T, coordinator *appServerThreadHandoffCoordinator, want int) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		coordinator.mu.Lock()
		got := len(coordinator.entries)
		coordinator.mu.Unlock()
		if got == want {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("handoff entry 未收敛到 %d", want)
}
