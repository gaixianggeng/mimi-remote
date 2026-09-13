package pushbridge

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"testing"
	"time"
)

func TestTurnMessageDeduplicatesConcurrentTerminalEventsAndCannotApprove(t *testing.T) {
	manager, provider := newTestManager(t, true, "one", "two")
	message := TurnMessage{Runtime: "codex", ThreadID: "thread", ProjectID: "project", TurnID: "turn", Event: EventTurnFailed}
	var wg sync.WaitGroup
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if send := manager.PrepareTurnMessage(message); send != nil {
				send(context.Background())
			}
		}()
	}
	wg.Wait()
	got := provider.events(EventTurnFailed)
	if len(got) != 2 {
		t.Fatalf("want one per device, got %d", len(got))
	}
	message.Event = EventTurnCompleted
	if manager.PrepareTurnMessage(message) != nil {
		t.Fatal("failure followed by completed must not notify twice")
	}
	for _, sent := range got {
		route, ok := manager.MessageRoute(sent.ActionID, sent.DeviceID)
		if !ok || route.ThreadID != "thread" || route.ProjectID != "project" {
			t.Fatal("missing message route")
		}
		if _, ok := manager.Actions().Get(sent.ActionID); ok {
			t.Fatal("message must not acquire approval rights")
		}
		if sent.Kind != "" {
			t.Fatal("message must not contain approval kind")
		}
	}
	if _, ok := manager.MessageRoute(got[0].ActionID, "unknown"); ok {
		t.Fatal("unregistered device can access route")
	}
	manager.Devices().Remove(got[0].DeviceID)
	if _, ok := manager.MessageRoute(got[0].ActionID, got[0].DeviceID); ok {
		t.Fatal("removed device can access route")
	}
}

func TestTurnMessageExpiryCapacityAndDisabledMode(t *testing.T) {
	manager, provider := newTestManager(t, true, "one")
	now := time.Now()
	manager.now = func() time.Time { return now }
	message := TurnMessage{Runtime: "claude", ThreadID: "thread", TurnID: "first", Event: EventTurnCompleted}
	manager.PrepareTurnMessage(message)(context.Background())
	first := provider.events(EventTurnCompleted)[0].ActionID
	now = now.Add(24*time.Hour + time.Second)
	if _, ok := manager.MessageRoute(first, "one"); ok {
		t.Fatal("expired route accepted")
	}
	for i := 0; i < maxMessages+2; i++ {
		message.TurnID = fmt.Sprint(i)
		if manager.PrepareTurnMessage(message) == nil {
			t.Fatal("could not enqueue")
		}
		now = now.Add(time.Second)
	}
	if manager.routes.Len() != maxMessages {
		t.Fatalf("unbounded routes: %d", manager.routes.Len())
	}
	disabled, _ := newTestManager(t, false, "one")
	if disabled.PrepareTurnMessage(message) != nil {
		t.Fatal("disabled notifications sent")
	}
	message.Event = "unknown"
	if manager.PrepareTurnMessage(message) != nil {
		t.Fatal("unknown event accepted")
	}
}

// 从同一目录重建 Manager 等价于 agentd 重启：定位记录必须仍只服务推送时的设备。
func TestMessageRouteSurvivesRestartForOriginalDevicesOnly(t *testing.T) {
	dir := t.TempDir()
	manager, provider := newTestManagerInDir(t, dir, true, "one", "two")
	message := TurnMessage{
		Runtime: "codex", ThreadID: "thread", ProjectID: "ws_abc", ScopeID: "ws_abc",
		CWD: "/tmp/worktree", ReadOnly: true, TurnID: "turn", Event: EventTurnCompleted,
	}
	manager.PrepareTurnMessage(message)(context.Background())
	sent := provider.events(EventTurnCompleted)
	if len(sent) != 2 {
		t.Fatalf("want one push per device, got %d", len(sent))
	}
	id := sent[0].ActionID
	if _, _, err := manager.Devices().Remove("two"); err != nil {
		t.Fatal(err)
	}

	restarted, _ := newTestManagerInDir(t, dir, true)
	record, outcome := restarted.LocateRoute(id, "one")
	if outcome != OutcomeProceed || record.Kind != RouteKindMessage || record.ThreadID != "thread" ||
		record.ProjectID != "ws_abc" || record.ScopeID != "ws_abc" || record.CWD != "/tmp/worktree" || !record.ReadOnly {
		t.Fatalf("route lost across restart: %+v %s", record, outcome)
	}
	if route, ok := restarted.MessageRoute(id, "one"); !ok || route.TurnID != "turn" || route.ScopeID != "ws_abc" {
		t.Fatalf("message route lost across restart: %+v %v", route, ok)
	}
	if _, outcome := restarted.LocateRoute(id, "two"); outcome != OutcomeForbidden {
		t.Fatalf("device removed before restart was served: %s", outcome)
	}
	if _, err := restarted.Devices().Register(Device{ID: "three", Ticket: "mpt1.1.three", ExpiresAt: time.Now().Add(time.Hour)}); err != nil {
		t.Fatal(err)
	}
	if _, outcome := restarted.LocateRoute(id, "three"); outcome != OutcomeForbidden {
		t.Fatalf("device registered after the push was granted: %s", outcome)
	}
	if _, outcome := restarted.LocateRoute("act-unknown", "one"); outcome != OutcomeNotFound {
		t.Fatalf("unknown id must be not found: %s", outcome)
	}
	if restarted.PrepareTurnMessage(message) != nil {
		t.Fatal("turn pushed before restart was pushed again")
	}
	if _, ok := restarted.Actions().Get(id); ok {
		t.Fatal("message record acquired approval rights")
	}
}

// 重启只恢复记录，不重新计时：到期时间以原始推送时刻为准。
func TestMessageRouteTTLIsNotExtendedByReload(t *testing.T) {
	dir := t.TempDir()
	manager, provider := newTestManagerInDir(t, dir, true, "one")
	origin := time.Now().Add(-23 * time.Hour)
	manager.now = func() time.Time { return origin }
	message := TurnMessage{Runtime: "claude", ThreadID: "thread", TurnID: "turn", Event: EventTurnCompleted}
	manager.PrepareTurnMessage(message)(context.Background())
	id := provider.events(EventTurnCompleted)[0].ActionID

	restarted, _ := newTestManagerInDir(t, dir, true)
	record, ok := restarted.Routes().Get(id)
	if !ok || !record.ExpiresAt.Equal(origin.Add(messageTTL)) {
		t.Fatalf("expiry changed by reload: %+v %v", record, ok)
	}
	restarted.now = func() time.Time { return origin.Add(messageTTL - time.Minute) }
	if _, outcome := restarted.LocateRoute(id, "one"); outcome != OutcomeProceed {
		t.Fatalf("still valid route refused: %s", outcome)
	}
	restarted.now = func() time.Time { return origin.Add(messageTTL + time.Second) }
	if _, outcome := restarted.LocateRoute(id, "one"); outcome != OutcomeGone {
		t.Fatalf("expired route served after reload: %s", outcome)
	}

	// 磁盘上已经过期的记录在加载时就丢弃，不会以任何形式回到内存。
	manager.now = func() time.Time { return time.Now().Add(-messageTTL - time.Hour) }
	message.TurnID = "stale"
	manager.PrepareTurnMessage(message)(context.Background())
	stale := provider.events(EventTurnCompleted)[1].ActionID
	reloaded, _ := newTestManagerInDir(t, dir, true)
	if _, ok := reloaded.Routes().Get(stale); ok {
		t.Fatal("expired record survived reload")
	}
}

func TestRouteCapEvictsOldestAndOrderPersistsAcrossRestart(t *testing.T) {
	dir := t.TempDir()
	manager, provider := newTestManagerInDir(t, dir, true, "one")
	now := time.Now()
	manager.now = func() time.Time { return now }
	for i := 0; i < maxRoutes+2; i++ {
		message := TurnMessage{Runtime: "codex", ThreadID: "thread", TurnID: fmt.Sprint(i), Event: EventTurnCompleted}
		manager.PrepareTurnMessage(message)(context.Background())
		now = now.Add(time.Second)
	}
	sent := provider.events(EventTurnCompleted)
	if len(sent) != maxRoutes+2 {
		t.Fatalf("unexpected push count %d", len(sent))
	}
	restarted, _ := newTestManagerInDir(t, dir, true)
	if restarted.Routes().Len() != maxRoutes {
		t.Fatalf("cap not persisted: %d", restarted.Routes().Len())
	}
	for i, notification := range sent {
		_, outcome := restarted.LocateRoute(notification.ActionID, "one")
		if i < 2 && outcome != OutcomeNotFound {
			t.Fatalf("oldest record %d survived eviction: %s", i, outcome)
		}
		if i >= 2 && outcome != OutcomeProceed {
			t.Fatalf("newer record %d lost: %s", i, outcome)
		}
	}
}

func TestRouteStoreToleratesCorruptFilesAndKeepsPrivateFields(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "push-routes.json")
	for index, raw := range []string{"{not json", `[{"id":"act-1","kind":"message","device_ids":["one"`, ""} {
		if err := os.WriteFile(path, []byte(raw), 0o600); err != nil {
			t.Fatal(err)
		}
		manager, provider := newTestManagerInDir(t, dir, true, "one")
		if manager.Routes().Len() != 0 {
			t.Fatalf("corrupt file %d produced records", index)
		}
		message := TurnMessage{Runtime: "codex", ThreadID: "thread", ProjectID: "demo", TurnID: fmt.Sprint(index), Event: EventTurnFailed}
		manager.PrepareTurnMessage(message)(context.Background())
		id := provider.events(EventTurnFailed)[0].ActionID
		if _, outcome := manager.LocateRoute(id, "one"); outcome != OutcomeProceed {
			t.Fatalf("store unusable after corrupt file %d: %s", index, outcome)
		}
		info, err := os.Stat(path)
		if err != nil {
			t.Fatalf("route file missing: %v", err)
		}
		// Windows 没有 POSIX 权限位，只在类 Unix 平台核对 0600。
		if runtime.GOOS != "windows" && info.Mode().Perm() != routeFileMode {
			t.Fatalf("route file mode: %v", info.Mode())
		}
		encoded, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		var records []map[string]any
		if err := json.Unmarshal(encoded, &records); err != nil || len(records) != 1 {
			t.Fatalf("file not rewritten as valid JSON: %v %s", err, encoded)
		}
		allowed := map[string]bool{
			"id": true, "kind": true, "runtime": true, "thread_id": true, "project_id": true, "scope_id": true,
			"cwd": true, "read_only": true, "turn_id": true, "event": true, "approval_kind": true,
			"device_ids": true, "created_at": true, "expires_at": true,
		}
		for key := range records[0] {
			if !allowed[key] {
				t.Fatalf("route file leaks field %q", key)
			}
		}
		if _, exists := records[0]["ticket"]; exists {
			t.Fatal("route file must not contain tickets")
		}
	}
}

// 审批定位记录与句柄同 id，但寿命更长、权限为零：重启后能打开会话，不能批准。
func TestApprovalLocateRecordOutlivesHandleWithoutGrantingRights(t *testing.T) {
	dir := t.TempDir()
	manager, _ := newTestManagerInDir(t, dir, true, "one")
	request := codexApproval()
	request.ProjectID = "ws_wt"
	request.ScopeID = "ws_wt"
	request.CWD = "/tmp/worktree"
	request.ReadOnly = true
	action, sent := manager.NotifyPending(context.Background(), request)
	if !sent {
		t.Fatal("approval not pushed")
	}
	if _, again := manager.NotifyPending(context.Background(), request); again || manager.Routes().Len() != 1 {
		t.Fatalf("duplicate approval created a second record: %d", manager.Routes().Len())
	}
	record, outcome := manager.LocateRoute(action.ID, "one")
	if outcome != OutcomeProceed || record.Kind != RouteKindApproval || record.ApprovalKind != KindCommand ||
		record.ScopeID != "ws_wt" || record.CWD != "/tmp/worktree" || !record.ReadOnly ||
		!record.ExpiresAt.Equal(action.IssuedAt.Add(routeTTL)) {
		t.Fatalf("approval record wrong: %+v %s", record, outcome)
	}
	if _, ok := manager.MessageRoute(action.ID, "one"); ok {
		t.Fatal("approval record must not masquerade as a message")
	}
	manager.Resolve(context.Background(), request.Runtime, request.SessionKey, request.RequestID)
	if _, outcome := manager.LocateRoute(action.ID, "one"); outcome != OutcomeProceed {
		t.Fatalf("resolved approval can no longer be located: %s", outcome)
	}

	restarted, _ := newTestManagerInDir(t, dir, true)
	if _, outcome := restarted.LocateRoute(action.ID, "one"); outcome != OutcomeProceed {
		t.Fatalf("approval route lost across restart: %s", outcome)
	}
	if _, ok := restarted.Actions().Get(action.ID); ok {
		t.Fatal("approval handle survived restart")
	}
	called := false
	_, outcome, err := restarted.Decide(context.Background(), action.ID, "one", DecisionAllow,
		func(context.Context, Action, Decision) error { called = true; return nil })
	if err != nil || outcome != OutcomeNotFound || called {
		t.Fatalf("locate record granted approval rights: outcome=%s called=%v err=%v", outcome, called, err)
	}
}

// 写盘瞬时失败（目录不可写）时脏快照必须保留，之后的 Flush 仍能把已投递的记录补写到磁盘。
func TestRouteStoreRetainsDirtySnapshotWhenWriteFails(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows 的只读目录不阻止创建文件")
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "push-routes.json")
	store := NewRouteStore(path)
	now := time.Now()
	if !store.Insert(now, LocateRecord{ID: "act-keep", Kind: RouteKindMessage, Runtime: "codex", ThreadID: "thread", TurnID: "turn", DeviceIDs: []string{"one"}, CreatedAt: now, ExpiresAt: now.Add(time.Hour)}) {
		t.Fatal("insert failed")
	}
	if err := os.Chmod(dir, 0o500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(dir, 0o700) })
	store.Flush()
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("只读目录下不应写出文件: %v", err)
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	store.Flush()
	reloaded := NewRouteStore(path)
	if _, ok := reloaded.Get("act-keep"); !ok {
		t.Fatal("写失败后的脏快照没有在下一次 Flush 落盘")
	}
}
