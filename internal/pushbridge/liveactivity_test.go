package pushbridge

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"testing"
	"time"

	"github.com/gaixianggeng/mimi-remote/internal/pushprovider"
)

// fakeLAClock 让节流窗口、启动宽限与结束延迟在测试里按需推进。
type fakeLAClock struct {
	mu     sync.Mutex
	now    time.Time
	timers []*fakeLATimer
}

type fakeLATimer struct {
	clock   *fakeLAClock
	due     time.Time
	fn      func()
	stopped bool
	fired   bool
}

func (t *fakeLATimer) Stop() bool {
	t.clock.mu.Lock()
	defer t.clock.mu.Unlock()
	active := !t.stopped && !t.fired
	t.stopped = true
	return active
}

func (c *fakeLAClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *fakeLAClock) afterFunc(delay time.Duration, fn func()) liveActivityTimer {
	c.mu.Lock()
	defer c.mu.Unlock()
	timer := &fakeLATimer{clock: c, due: c.now.Add(delay), fn: fn}
	c.timers = append(c.timers, timer)
	return timer
}

// advance 推进时钟并按到期顺序触发计时器；回调在锁外执行，与真实 AfterFunc 一致。
func (c *fakeLAClock) advance(delta time.Duration) {
	c.mu.Lock()
	target := c.now.Add(delta)
	c.mu.Unlock()
	for {
		c.mu.Lock()
		sort.SliceStable(c.timers, func(i, j int) bool { return c.timers[i].due.Before(c.timers[j].due) })
		var next *fakeLATimer
		for _, timer := range c.timers {
			if !timer.stopped && !timer.fired && !timer.due.After(target) {
				next = timer
				break
			}
		}
		if next == nil {
			c.now = target
			c.mu.Unlock()
			return
		}
		next.fired = true
		if next.due.After(c.now) {
			c.now = next.due
		}
		c.mu.Unlock()
		next.fn()
	}
}

type laHarness struct {
	t       *testing.T
	clock   *fakeLAClock
	manager *Manager
	engine  *LiveActivityEngine
	mu      sync.Mutex
	sent    []LiveActivityNotification
	respond func(LiveActivityNotification) error
}

func newLAHarness(t *testing.T, deviceIDs ...string) *laHarness {
	t.Helper()
	return newLAHarnessInDir(t, t.TempDir(), deviceIDs...)
}

func newLAHarnessInDir(t *testing.T, dir string, deviceIDs ...string) *laHarness {
	t.Helper()
	store, err := NewDeviceStore(filepath.Join(dir, "push-devices.json"))
	if err != nil {
		t.Fatal(err)
	}
	clock := &fakeLAClock{now: time.Now().Truncate(time.Second)}
	tickets := NewActivityTicketStore(filepath.Join(dir, "push-live-activities.json"))
	tickets.now = clock.Now
	manager := NewManager(Options{
		Enabled:             true,
		ProviderURL:         "https://provider.example/mimi-push",
		InstallationID:      "install-test",
		DeviceStore:         store,
		ActivityTicketStore: tickets,
	})
	manager.notifyer = newFakeProvider().notify
	h := &laHarness{t: t, clock: clock, manager: manager, engine: manager.LiveActivities()}
	h.engine.now = clock.Now
	h.engine.afterFunc = clock.afterFunc
	h.engine.dispatch = func(delivery func(context.Context)) { delivery(context.Background()) }
	h.engine.send = func(_ context.Context, notification LiveActivityNotification) error {
		h.mu.Lock()
		h.sent = append(h.sent, notification)
		respond := h.respond
		h.mu.Unlock()
		if respond != nil {
			return respond(notification)
		}
		return nil
	}
	for _, id := range deviceIDs {
		if _, err := store.Register(Device{ID: id, Ticket: "mpt1.1.notify-" + id, ExpiresAt: time.Now().Add(30 * 24 * time.Hour)}); err != nil {
			t.Fatal(err)
		}
	}
	return h
}

func (h *laHarness) register(deviceID, kind, ticket, activityID string) {
	h.t.Helper()
	if _, err := h.engine.Register(deviceID, kind, ActivityTicket{
		Ticket:     ticket,
		ExpiresAt:  h.clock.Now().Add(20 * time.Hour),
		ActivityID: activityID,
	}); err != nil {
		h.t.Fatalf("登记 %s 票据失败：%v", kind, err)
	}
}

func (h *laHarness) sends() []LiveActivityNotification {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]LiveActivityNotification(nil), h.sent...)
}

func (h *laHarness) last() LiveActivityNotification {
	h.t.Helper()
	sent := h.sends()
	if len(sent) == 0 {
		h.t.Fatal("没有任何 Live Activity 投递")
	}
	return sent[len(sent)-1]
}

func (h *laHarness) expectSends(count int) {
	h.t.Helper()
	if got := len(h.sends()); got != count {
		h.t.Fatalf("Live Activity 投递次数=%d，期望 %d：%+v", got, count, h.sends())
	}
}

func TestLiveActivityPushToStartWaitsForLocalActivityGrace(t *testing.T) {
	h := newLAHarness(t, "device-1")
	h.register("device-1", ActivityTicketStart, "start-ticket", "")
	h.engine.TurnStarted("codex", "thread-1")
	h.expectSends(0)
	h.clock.advance(liveActivityStartGrace - time.Second)
	h.expectSends(0)
	h.clock.advance(time.Second)
	h.expectSends(1)
	start := h.last()
	if start.Event != LiveActivityEventStart || start.Ticket != "start-ticket" ||
		start.AttributesType != LiveActivityAttributesType || start.Attributes == nil ||
		start.Attributes.HostTag != h.manager.HostTag() {
		t.Fatalf("start 内容错误：%+v", start)
	}
	if start.ContentState.Status != LiveActivityStatusRunning || start.ContentState.RunningCount != 1 ||
		start.ContentState.FocusSessionTag != tag("thread-1") || start.StaleDate == 0 {
		t.Fatalf("start content-state 错误：%+v", start)
	}
	// 同一轮不重复 push-to-start，新会话加入也一样。
	h.engine.TurnStarted("claude", "thread-2")
	h.clock.advance(time.Minute)
	h.expectSends(1)
}

// App 在前台本机拉起活动并在宽限期内登记更新 Ticket：agentd 只原地更新，不再 push-to-start。
func TestLiveActivityLocalActivitySkipsPushToStart(t *testing.T) {
	h := newLAHarness(t, "device-1")
	h.register("device-1", ActivityTicketStart, "start-ticket", "")
	h.engine.TurnStarted("codex", "thread-1")
	h.clock.advance(3 * time.Second)
	h.register("device-1", ActivityTicketUpdate, "update-ticket", "activity-1")
	h.expectSends(1)
	if update := h.last(); update.Event != LiveActivityEventUpdate || update.Ticket != "update-ticket" ||
		update.Attributes != nil || update.ContentState.Status != LiveActivityStatusRunning {
		t.Fatalf("应立即 update 当前状态：%+v", update)
	}
	h.clock.advance(time.Minute)
	h.expectSends(1)
}

// push-to-start 拉起的活动登记更新 Ticket 后，立即补一条当前状态。
func TestLiveActivityUpdateTicketAfterRemoteStartCatchesUp(t *testing.T) {
	h := newLAHarness(t, "device-1")
	h.register("device-1", ActivityTicketStart, "start-ticket", "")
	h.engine.TurnStarted("codex", "thread-1")
	h.clock.advance(liveActivityStartGrace)
	h.engine.ApprovalPending("codex", "thread-1", "req-1")
	h.expectSends(1)
	h.clock.advance(20 * time.Second)
	h.register("device-1", ActivityTicketUpdate, "update-ticket", "activity-1")
	h.expectSends(2)
	if update := h.last(); update.Event != LiveActivityEventUpdate || update.ContentState.Status != LiveActivityStatusNeedsYou {
		t.Fatalf("登记后应补发当前状态：%+v", update)
	}
}

func TestLiveActivityUpdateThrottle(t *testing.T) {
	cases := []struct {
		name    string
		prepare func(*laHarness)
		events  func(*laHarness)
		// immediate 是事件后不等窗口就发出的条数；total 是窗口结束后的总条数。
		immediate int
		total     int
		final     LiveActivityContentState
	}{
		{
			name: "changes inside the window collapse to the latest",
			events: func(h *laHarness) {
				h.engine.TurnStarted("codex", "thread-2")
				h.clock.advance(time.Second)
				h.engine.TurnStarted("codex", "thread-3")
			},
			total: 1,
			final: LiveActivityContentState{Status: LiveActivityStatusRunning, RunningCount: 3},
		},
		{
			name:      "entering needs you is not throttled",
			events:    func(h *laHarness) { h.engine.ApprovalPending("codex", "thread-1", "req-1") },
			immediate: 1,
			total:     1,
			final:     LiveActivityContentState{Status: LiveActivityStatusNeedsYou, NeedsYouCount: 1},
		},
		{
			name: "count change while already waiting is throttled",
			prepare: func(h *laHarness) {
				h.engine.ApprovalPending("codex", "thread-1", "req-1")
				h.clock.advance(time.Second)
			},
			events: func(h *laHarness) { h.engine.TurnStarted("codex", "thread-2") },
			total:  1,
			final:  LiveActivityContentState{Status: LiveActivityStatusNeedsYou, RunningCount: 1, NeedsYouCount: 1},
		},
		{
			name: "identical state is not resent",
			events: func(h *laHarness) {
				h.engine.TurnStarted("codex", "thread-1")
				h.engine.ApprovalResolved("codex", "thread-1", "missing")
			},
			final: LiveActivityContentState{Status: LiveActivityStatusRunning, RunningCount: 1},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := newLAHarness(t, "device-1")
			h.register("device-1", ActivityTicketUpdate, "update-ticket", "activity-1")
			h.engine.TurnStarted("codex", "thread-1")
			h.expectSends(1)
			h.clock.advance(time.Second)
			if tc.prepare != nil {
				tc.prepare(h)
			}
			baseline := len(h.sends())
			tc.events(h)
			h.expectSends(baseline + tc.immediate)
			h.clock.advance(liveActivityMinInterval)
			h.expectSends(baseline + tc.total)
			final := h.last().ContentState
			if final.Status != tc.final.Status || final.RunningCount != tc.final.RunningCount ||
				final.NeedsYouCount != tc.final.NeedsYouCount {
				t.Fatalf("窗口结束后应发出最新状态：%+v，期望 %+v", final, tc.final)
			}
		})
	}
}

// 投递在途时到来的变化不并发投递第二条；完成后按最新状态补发，顺序不会乱。
func TestLiveActivitySerializesInFlightDeliveries(t *testing.T) {
	h := newLAHarness(t, "device-1")
	var queued []func(context.Context)
	h.engine.dispatch = func(delivery func(context.Context)) { queued = append(queued, delivery) }
	h.register("device-1", ActivityTicketUpdate, "update-ticket", "activity-1")
	h.engine.TurnStarted("codex", "thread-1")
	h.engine.ApprovalPending("codex", "thread-1", "req-1")
	if len(queued) != 1 {
		t.Fatalf("在途期间只能有一条投递，got=%d", len(queued))
	}
	first := queued[0]
	queued = nil
	first(context.Background())
	if len(queued) != 1 {
		t.Fatalf("完成后应立即补发转入「待你处理」的状态，got=%d", len(queued))
	}
	queued[0](context.Background())
	if got := h.last().ContentState.Status; got != LiveActivityStatusNeedsYou {
		t.Fatalf("最后送达的应是最新状态，got=%s", got)
	}
}

func TestLiveActivityEndsAfterIdleDelay(t *testing.T) {
	h := newLAHarness(t, "device-1")
	h.register("device-1", ActivityTicketUpdate, "update-ticket", "activity-1")
	h.engine.TurnStarted("codex", "thread-1")
	h.clock.advance(time.Minute)
	h.engine.TurnEnded("codex", "thread-1", LiveActivityStatusCompleted)
	h.expectSends(2)
	if update := h.last(); update.Event != LiveActivityEventUpdate || update.ContentState.Status != LiveActivityStatusCompleted {
		t.Fatalf("完成后先静默更新为终态：%+v", update)
	}
	h.clock.advance(liveActivityEndDelay - time.Second)
	h.expectSends(2)
	h.clock.advance(time.Second)
	h.expectSends(3)
	end := h.last()
	if end.Event != LiveActivityEventEnd || end.ContentState.Status != LiveActivityStatusCompleted ||
		end.DismissalDate != h.clock.Now().Add(liveActivityDismissDelay).Unix() {
		t.Fatalf("end 内容错误：%+v", end)
	}
	if _, update := h.engine.tickets.Get("device-1"); update != nil {
		t.Fatal("end 成功后更新 Ticket 应被删除")
	}
}

// 结束延迟内开始新回合：原地更新回运行中，不结束也不重新拉起。
func TestLiveActivityNewTurnDuringIdleKeepsActivity(t *testing.T) {
	h := newLAHarness(t, "device-1")
	h.register("device-1", ActivityTicketStart, "start-ticket", "")
	h.register("device-1", ActivityTicketUpdate, "update-ticket", "activity-1")
	h.engine.TurnStarted("codex", "thread-1")
	h.engine.TurnEnded("codex", "thread-1", LiveActivityStatusFailed)
	h.clock.advance(time.Minute)
	h.engine.TurnStarted("codex", "thread-1")
	h.clock.advance(liveActivityEndDelay)
	for _, sent := range h.sends() {
		if sent.Event != LiveActivityEventUpdate {
			t.Fatalf("不应出现 %s：%+v", sent.Event, h.sends())
		}
	}
	if got := h.last().ContentState.Status; got != LiveActivityStatusRunning {
		t.Fatalf("新回合应把活动更新回运行中，got=%s", got)
	}
}

// 用户划掉活动后 Provider 回 410：这一轮不再拉回来，下一轮按规则重新 push-to-start。
func TestLiveActivityDismissedActivityRestartsNextPeriod(t *testing.T) {
	h := newLAHarness(t, "device-1")
	h.register("device-1", ActivityTicketStart, "start-ticket", "")
	h.register("device-1", ActivityTicketUpdate, "update-ticket", "activity-1")
	h.engine.TurnStarted("codex", "thread-1")
	h.respond = func(n LiveActivityNotification) error {
		if n.Ticket == "update-ticket" {
			return ErrDeviceUnregistered
		}
		return nil
	}
	h.clock.advance(liveActivityMinInterval)
	h.engine.TurnStarted("codex", "thread-2")
	h.clock.advance(liveActivityMinInterval)
	if _, update := h.engine.tickets.Get("device-1"); update != nil {
		t.Fatal("410 后更新 Ticket 应被删除")
	}
	h.clock.advance(time.Minute)
	for _, sent := range h.sends() {
		if sent.Event == LiveActivityEventStart {
			t.Fatal("同一轮不能把用户划掉的活动拉回来")
		}
	}
	h.engine.TurnEnded("codex", "thread-1", LiveActivityStatusCompleted)
	h.engine.TurnEnded("codex", "thread-2", LiveActivityStatusCompleted)
	h.engine.TurnStarted("codex", "thread-3")
	h.clock.advance(liveActivityStartGrace)
	if start := h.last(); start.Event != LiveActivityEventStart || start.Ticket != "start-ticket" {
		t.Fatalf("下一轮应重新 push-to-start：%+v", start)
	}
	if start, _ := h.engine.tickets.Get("device-1"); start == nil {
		t.Fatal("push-to-start Ticket 不应受更新 Ticket 失效影响")
	}
}

// Provider 未部署、故障或 APNs 拒绝：活动退避重试，审批提醒照常投递。
func TestLiveActivityFailureBacksOffAndFailsOpen(t *testing.T) {
	h := newLAHarness(t, "device-1")
	provider := newFakeProvider()
	h.manager.notifyer = provider.notify
	h.register("device-1", ActivityTicketUpdate, "update-ticket", "activity-1")
	h.respond = func(LiveActivityNotification) error { return errors.New("push provider 返回 404 (unknown)") }
	h.engine.TurnStarted("codex", "thread-1")
	h.expectSends(1)
	h.clock.advance(liveActivityMinInterval - time.Second)
	h.expectSends(1)
	h.clock.advance(time.Second)
	h.expectSends(2)
	h.clock.advance(2 * liveActivityMinInterval)
	h.expectSends(3)
	if _, update := h.engine.tickets.Get("device-1"); update == nil {
		t.Fatal("普通失败不能删除票据")
	}
	if _, created := h.manager.NotifyPending(context.Background(), codexApproval()); !created {
		t.Fatal("审批提醒必须不受活动失败影响")
	}
	if got := len(provider.events(EventApprovalPending)); got != 1 {
		t.Fatalf("审批提醒投递次数=%d", got)
	}
	h.respond = nil
	h.clock.advance(liveActivityMaxBackoff)
	if got := h.last().ContentState.Status; got != LiveActivityStatusRunning {
		t.Fatalf("恢复后应送达当前状态，got=%s", got)
	}
}

func TestLiveActivityStartGivesUpAfterRepeatedFailures(t *testing.T) {
	h := newLAHarness(t, "device-1")
	h.register("device-1", ActivityTicketStart, "start-ticket", "")
	h.respond = func(LiveActivityNotification) error { return errors.New("transport") }
	h.engine.TurnStarted("codex", "thread-1")
	h.clock.advance(time.Hour)
	if got := len(h.sends()); got != liveActivityMaxStartAttempts {
		t.Fatalf("同一轮 push-to-start 最多尝试 %d 次，got=%d", liveActivityMaxStartAttempts, got)
	}
}

func TestLiveActivityRegistrationRules(t *testing.T) {
	expiry := time.Now().Add(time.Hour)
	cases := []struct {
		name    string
		device  string
		kind    string
		ticket  ActivityTicket
		wantErr error
	}{
		{"unknown device", "device-x", ActivityTicketStart, ActivityTicket{Ticket: "t", ExpiresAt: expiry}, ErrLiveActivityDeviceUnknown},
		{"bad kind", "device-1", "notification", ActivityTicket{Ticket: "t", ExpiresAt: expiry}, errActivityTicketKind},
		{"empty ticket", "device-1", ActivityTicketStart, ActivityTicket{ExpiresAt: expiry}, errActivityTicketInvalid},
		{"bad activity id", "device-1", ActivityTicketUpdate, ActivityTicket{Ticket: "t", ExpiresAt: expiry, ActivityID: "../x"}, errActivityIDInvalid},
		{"expired", "device-1", ActivityTicketUpdate, ActivityTicket{Ticket: "t", ExpiresAt: time.Now().Add(-time.Minute)}, nil},
		{"ok", "device-1", ActivityTicketUpdate, ActivityTicket{Ticket: "t", ExpiresAt: expiry, ActivityID: "A1B2-c3"}, nil},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := newLAHarness(t, "device-1")
			_, err := h.engine.Register(tc.device, tc.kind, tc.ticket)
			switch {
			case tc.name == "expired":
				if err == nil {
					t.Fatal("过期票据不能登记")
				}
			case tc.wantErr != nil:
				if !errors.Is(err, tc.wantErr) {
					t.Fatalf("err=%v，期望 %v", err, tc.wantErr)
				}
			case err != nil:
				t.Fatalf("登记失败：%v", err)
			}
		})
	}
}

func TestLiveActivityUnregister(t *testing.T) {
	cases := []struct {
		name       string
		kind       string
		activityID string
		removed    bool
		start      bool
		update     bool
	}{
		{"stale activity id keeps newer ticket", ActivityTicketUpdate, "activity-old", false, true, true},
		{"matching activity id", ActivityTicketUpdate, "activity-1", true, true, false},
		{"start only", ActivityTicketStart, "", true, false, true},
		{"all", "", "", true, false, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := newLAHarness(t, "device-1")
			h.register("device-1", ActivityTicketStart, "start-ticket", "")
			h.register("device-1", ActivityTicketUpdate, "update-ticket", "activity-1")
			removed, err := h.engine.Unregister("device-1", tc.kind, tc.activityID)
			if err != nil || removed != tc.removed {
				t.Fatalf("removed=%v err=%v，期望 %v", removed, err, tc.removed)
			}
			start, update := h.engine.TicketStatus("device-1")
			if start != tc.start || update != tc.update {
				t.Fatalf("start=%v update=%v，期望 %v %v", start, update, tc.start, tc.update)
			}
		})
	}
}

// 设备被 Provider 判定失效（换绑、撤销）时，通知注册与活动票据一起删除。
func TestLiveActivityTicketsFollowDeviceRemoval(t *testing.T) {
	h := newLAHarness(t, "device-1", "device-2")
	provider := newFakeProvider()
	provider.unregisterFor["device-1"] = true
	h.manager.notifyer = provider.notify
	h.register("device-1", ActivityTicketStart, "start-1", "")
	h.register("device-2", ActivityTicketStart, "start-2", "")
	h.manager.NotifyPending(context.Background(), codexApproval())
	if start, update := h.engine.TicketStatus("device-1"); start || update {
		t.Fatal("失效设备的活动票据应一并删除")
	}
	if start, _ := h.engine.TicketStatus("device-2"); !start {
		t.Fatal("其它设备不受影响")
	}
	h.engine.RemoveDevice("device-2")
	if start, _ := h.engine.TicketStatus("device-2"); start {
		t.Fatal("RemoveDevice 应删除活动票据")
	}
}

// 设备的通知 Ticket 过期后不再投递活动，票据随之清理。
func TestLiveActivityRequiresActiveNotificationDevice(t *testing.T) {
	h := newLAHarness(t, "device-1")
	h.register("device-1", ActivityTicketUpdate, "update-ticket", "activity-1")
	if _, _, err := h.manager.Devices().Remove("device-1"); err != nil {
		t.Fatal(err)
	}
	h.engine.TurnStarted("codex", "thread-1")
	h.expectSends(0)
	if _, update := h.engine.TicketStatus("device-1"); update {
		t.Fatal("设备注销后活动票据应被清理")
	}
}

// 多台设备各自维持自己的活动，互不影响。
func TestLiveActivityDevicesAreIndependent(t *testing.T) {
	h := newLAHarness(t, "device-1", "device-2")
	h.register("device-1", ActivityTicketUpdate, "update-1", "activity-1")
	h.register("device-2", ActivityTicketStart, "start-2", "")
	h.engine.TurnStarted("codex", "thread-1")
	h.clock.advance(liveActivityStartGrace)
	byTicket := map[string]string{}
	for _, sent := range h.sends() {
		byTicket[sent.Ticket] = sent.Event
	}
	if byTicket["update-1"] != LiveActivityEventUpdate || byTicket["start-2"] != LiveActivityEventStart {
		t.Fatalf("两台设备应分别 update 与 start：%v", byTicket)
	}
}

func TestLiveActivityDisabledManagerSendsNothing(t *testing.T) {
	h := newLAHarness(t, "device-1")
	h.register("device-1", ActivityTicketUpdate, "update-ticket", "activity-1")
	h.expectSends(0)
	h.manager.mu.Lock()
	h.manager.enabled = false
	h.manager.mu.Unlock()
	h.engine.TurnStarted("codex", "thread-1")
	h.clock.advance(time.Hour)
	h.expectSends(0)
}

func TestLiveActivityCloseStopsTimers(t *testing.T) {
	h := newLAHarness(t, "device-1")
	h.register("device-1", ActivityTicketStart, "start-ticket", "")
	h.engine.TurnStarted("codex", "thread-1")
	h.manager.Close()
	h.clock.advance(time.Hour)
	h.expectSends(0)
}

func TestActivityTicketStorePersistsAcrossRestart(t *testing.T) {
	dir := t.TempDir()
	first := newLAHarnessInDir(t, dir, "device-1")
	first.register("device-1", ActivityTicketStart, "start-ticket", "")
	first.register("device-1", ActivityTicketUpdate, "update-ticket", "activity-1")
	reloaded := NewActivityTicketStore(filepath.Join(dir, "push-live-activities.json"))
	start, update := reloaded.Get("device-1")
	if start == nil || start.Ticket != "start-ticket" || update == nil || update.ActivityID != "activity-1" {
		t.Fatalf("重启后应恢复票据：start=%+v update=%+v", start, update)
	}
}

func TestActivityTicketStoreToleratesCorruptFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "push-live-activities.json")
	if err := os.WriteFile(path, []byte("{broken"), 0o600); err != nil {
		t.Fatal(err)
	}
	store := NewActivityTicketStore(path)
	if ids := store.DeviceIDs(); len(ids) != 0 {
		t.Fatalf("损坏文件应按空表处理：%v", ids)
	}
}

// 重启后没有会话状态：重启前登记的活动按空闲规则结束，并立即从锁屏移除，不显示猜测的结果。
func TestLiveActivityRestartEndsUnknownActivity(t *testing.T) {
	dir := t.TempDir()
	first := newLAHarnessInDir(t, dir, "device-1")
	first.register("device-1", ActivityTicketUpdate, "update-ticket", "activity-1")
	first.manager.Close()

	second := newLAHarnessInDir(t, dir)
	second.engine.ReconcileAll()
	second.expectSends(0)
	second.clock.advance(liveActivityEndDelay)
	second.expectSends(1)
	end := second.last()
	if end.Event != LiveActivityEventEnd || end.DismissalDate != second.clock.Now().Unix() ||
		end.ContentState.FocusSessionTag != second.manager.HostTag() {
		t.Fatalf("未知活动应立即结束：%+v", end)
	}
}

// 契约：agentd 发出的每一种请求都必须通过 Provider 自己的严格解码与校验。
func TestLiveActivityRequestsPassProviderValidation(t *testing.T) {
	h := newLAHarness(t, "device-1")
	h.register("device-1", ActivityTicketStart, "start-ticket", "")
	h.engine.TurnStarted("codex", "thread-1")
	h.clock.advance(liveActivityStartGrace)
	h.register("device-1", ActivityTicketUpdate, "update-ticket", "activity-1")
	h.engine.ApprovalPending("codex", "thread-1", "req-1")
	h.engine.TurnEnded("codex", "thread-1", LiveActivityStatusFailed)
	h.clock.advance(liveActivityEndDelay + liveActivityMinInterval)
	events := map[string]bool{}
	for _, sent := range h.sends() {
		events[sent.Event] = true
		sent.Version = 1
		encoded, err := json.Marshal(sent)
		if err != nil {
			t.Fatal(err)
		}
		decoder := json.NewDecoder(bytes.NewReader(encoded))
		decoder.DisallowUnknownFields()
		var decoded pushprovider.LiveActivityNotification
		if err := decoder.Decode(&decoded); err != nil {
			t.Fatalf("%s 含 Provider 不认识的字段：%v %s", sent.Event, err, encoded)
		}
		if err := decoded.Validate(h.clock.Now()); err != nil {
			t.Fatalf("%s 未通过 Provider 校验：%v %s", sent.Event, err, encoded)
		}
	}
	for _, event := range []string{LiveActivityEventStart, LiveActivityEventUpdate, LiveActivityEventEnd} {
		if !events[event] {
			t.Fatalf("契约测试没有覆盖 %s：%v", event, events)
		}
	}
	if pushprovider.LiveActivityAttributesType != LiveActivityAttributesType {
		t.Fatal("attributes_type 必须与 Provider 一致")
	}
}
