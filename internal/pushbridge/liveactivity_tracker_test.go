package pushbridge

import (
	"fmt"
	"testing"
	"time"
)

type trackerStep struct {
	at    time.Duration
	apply func(*activityTracker, time.Time)
}

func started(runtime, thread string) func(*activityTracker, time.Time) {
	return func(t *activityTracker, now time.Time) { t.TurnStarted(runtime, thread, now) }
}

func ended(runtime, thread, status string) func(*activityTracker, time.Time) {
	return func(t *activityTracker, now time.Time) { t.TurnEnded(runtime, thread, status, now) }
}

func pending(runtime, thread, request string) func(*activityTracker, time.Time) {
	return func(t *activityTracker, now time.Time) { t.ApprovalPending(runtime, thread, request, now) }
}

func resolved(runtime, thread, request string) func(*activityTracker, time.Time) {
	return func(t *activityTracker, now time.Time) { t.ApprovalResolved(runtime, thread, request, now) }
}

func threadStatus(runtime, thread, statusType string, waiting bool) func(*activityTracker, time.Time) {
	return func(t *activityTracker, now time.Time) { t.ThreadStatus(runtime, thread, statusType, waiting, now) }
}

func tag(thread string) string { return MessageSessionTag(thread) }

func TestActivityTrackerSummary(t *testing.T) {
	base := time.Unix(1_800_000_000, 0)
	manySessions := []trackerStep{}
	for index := 0; index < 120; index++ {
		manySessions = append(manySessions, trackerStep{0, started("codex", fmt.Sprintf("bulk-%d", index))})
	}
	cases := []struct {
		name      string
		steps     []trackerStep
		at        time.Duration
		active    bool
		hasFocus  bool
		status    string
		running   int
		needsYou  int
		focus     string
		startedAt time.Duration
	}{
		{name: "nothing observed", at: 0},
		{
			name:  "single running",
			steps: []trackerStep{{0, started("codex", "t1")}},
			at:    time.Second, active: true, hasFocus: true,
			status: LiveActivityStatusRunning, running: 1, focus: tag("t1"),
		},
		{
			name:  "approval needs you",
			steps: []trackerStep{{0, started("codex", "t1")}, {time.Second, pending("codex", "t1", "r1")}},
			at:    2 * time.Second, active: true, hasFocus: true,
			status: LiveActivityStatusNeedsYou, needsYou: 1, focus: tag("t1"),
		},
		{
			name: "resolved without thread returns to running",
			steps: []trackerStep{
				{0, started("codex", "t1")}, {time.Second, pending("codex", "t1", "r1")},
				{2 * time.Second, resolved("codex", "", "r1")},
			},
			at: 3 * time.Second, active: true, hasFocus: true,
			status: LiveActivityStatusRunning, running: 1, focus: tag("t1"),
		},
		{
			name: "resolution from another runtime is ignored",
			steps: []trackerStep{
				{0, started("codex", "t1")}, {time.Second, pending("codex", "t1", "r1")},
				{2 * time.Second, resolved("claude", "", "r1")},
			},
			at: 3 * time.Second, active: true, hasFocus: true,
			status: LiveActivityStatusNeedsYou, needsYou: 1, focus: tag("t1"),
		},
		{
			name: "approval without turn start still counts",
			steps: []trackerStep{
				{0, pending("claude", "t1", "r1")},
			},
			at: time.Second, active: true, hasFocus: true,
			status: LiveActivityStatusNeedsYou, needsYou: 1, focus: tag("t1"),
		},
		{
			name: "needs you wins focus over newer running session",
			steps: []trackerStep{
				{0, started("codex", "t1")}, {time.Second, pending("codex", "t1", "r1")},
				{2 * time.Second, started("codex", "t2")},
			},
			at: 3 * time.Second, active: true, hasFocus: true,
			status: LiveActivityStatusNeedsYou, running: 1, needsYou: 1, focus: tag("t1"),
		},
		{
			name:  "latest started running session is focus",
			steps: []trackerStep{{0, started("codex", "t1")}, {time.Second, started("claude", "t2")}},
			at:    2 * time.Second, active: true, hasFocus: true,
			status: LiveActivityStatusRunning, running: 2, focus: tag("t2"), startedAt: time.Second,
		},
		{
			name:  "duplicate turn start keeps original start time",
			steps: []trackerStep{{0, started("codex", "t1")}, {10 * time.Second, started("codex", "t1")}},
			at:    11 * time.Second, active: true, hasFocus: true,
			status: LiveActivityStatusRunning, running: 1, focus: tag("t1"),
		},
		{
			name:  "completed when idle",
			steps: []trackerStep{{0, started("codex", "t1")}, {time.Minute, ended("codex", "t1", LiveActivityStatusCompleted)}},
			at:    2 * time.Minute, hasFocus: true,
			status: LiveActivityStatusCompleted, focus: tag("t1"),
		},
		{
			name: "latest terminal wins when idle",
			steps: []trackerStep{
				{0, started("codex", "t1")}, {0, started("codex", "t2")},
				{time.Minute, ended("codex", "t1", LiveActivityStatusFailed)},
				{2 * time.Minute, ended("codex", "t2", LiveActivityStatusCompleted)},
			},
			at: 3 * time.Minute, hasFocus: true, status: LiveActivityStatusCompleted, focus: tag("t2"),
		},
		{
			name: "running session outranks a failure",
			steps: []trackerStep{
				{0, started("codex", "t1")}, {0, started("codex", "t2")},
				{time.Minute, ended("codex", "t1", LiveActivityStatusFailed)},
			},
			at: 2 * time.Minute, active: true, hasFocus: true,
			status: LiveActivityStatusRunning, running: 1, focus: tag("t2"),
		},
		{
			name:  "holder waiting flag needs you",
			steps: []trackerStep{{0, threadStatus("claude", "t1", "active", true)}},
			at:    time.Second, active: true, hasFocus: true,
			status: LiveActivityStatusNeedsYou, needsYou: 1, focus: tag("t1"),
		},
		{
			name: "waiting flag cleared returns to running",
			steps: []trackerStep{
				{0, threadStatus("codex", "t1", "active", true)},
				{time.Second, threadStatus("codex", "t1", "active", false)},
			},
			at: 2 * time.Second, active: true, hasFocus: true,
			status: LiveActivityStatusRunning, running: 1, focus: tag("t1"),
		},
		{
			name:  "idle for untracked thread does not invent a completion",
			steps: []trackerStep{{0, threadStatus("codex", "t9", "idle", false)}},
			at:    time.Second,
		},
		{
			name:  "idle ends tracked turn",
			steps: []trackerStep{{0, started("codex", "t1")}, {time.Minute, threadStatus("codex", "t1", "idle", false)}},
			at:    2 * time.Minute, hasFocus: true, status: LiveActivityStatusCompleted, focus: tag("t1"),
		},
		{
			name:  "system error fails tracked turn",
			steps: []trackerStep{{0, started("codex", "t1")}, {time.Minute, threadStatus("codex", "t1", "systemError", false)}},
			at:    2 * time.Minute, hasFocus: true, status: LiveActivityStatusFailed, focus: tag("t1"),
		},
		{
			name: "turn end clears pending approvals",
			steps: []trackerStep{
				{0, started("codex", "t1")}, {time.Second, pending("codex", "t1", "r1")},
				{time.Minute, ended("codex", "t1", LiveActivityStatusCompleted)},
				{2 * time.Minute, started("codex", "t1")},
			},
			at: 3 * time.Minute, active: true, hasFocus: true,
			status: LiveActivityStatusRunning, running: 1, focus: tag("t1"), startedAt: 2 * time.Minute,
		},
		{
			name:  "silent active turn expires",
			steps: []trackerStep{{0, started("codex", "t1")}},
			at:    activityActiveTTL + time.Minute,
		},
		{
			name: "touch keeps active turn alive",
			steps: []trackerStep{
				{0, started("codex", "t1")},
				{2 * time.Hour, func(t *activityTracker, now time.Time) { t.Touch("codex", "t1", now) }},
			},
			at: 4 * time.Hour, active: true, hasFocus: true,
			status: LiveActivityStatusRunning, running: 1, focus: tag("t1"),
		},
		{
			name:  "terminal state is retained only briefly",
			steps: []trackerStep{{0, ended("codex", "t1", LiveActivityStatusCompleted)}},
			at:    activityTerminalRetention + time.Minute,
		},
		{
			name: "closed thread leaves the summary",
			steps: []trackerStep{
				{0, started("codex", "t1")},
				{time.Second, func(t *activityTracker, _ time.Time) { t.ThreadClosed("codex", "t1") }},
			},
			at: 2 * time.Second,
		},
		{
			name:  "same thread id on two runtimes counts twice",
			steps: []trackerStep{{0, started("codex", "t1")}, {0, started("claude", "t1")}},
			at:    time.Second, active: true, hasFocus: true,
			status: LiveActivityStatusRunning, running: 2, focus: tag("t1"),
		},
		{
			name:  "counts are capped",
			steps: manySessions,
			at:    time.Second, active: true, hasFocus: true,
			status: LiveActivityStatusRunning, running: maxLiveActivityCount,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			tracker := newActivityTracker()
			for _, step := range tc.steps {
				step.apply(tracker, base.Add(step.at))
			}
			summary := tracker.Summary(base.Add(tc.at))
			if summary.Active != tc.active || summary.HasFocus != tc.hasFocus {
				t.Fatalf("active=%v hasFocus=%v，期望 %v %v", summary.Active, summary.HasFocus, tc.active, tc.hasFocus)
			}
			if !tc.hasFocus {
				return
			}
			state := summary.State
			if state.Status != tc.status || state.RunningCount != tc.running || state.NeedsYouCount != tc.needsYou {
				t.Fatalf("state=%+v，期望 %s %d/%d", state, tc.status, tc.running, tc.needsYou)
			}
			if tc.focus != "" && state.FocusSessionTag != tc.focus {
				t.Fatalf("focus=%s，期望 %s", state.FocusSessionTag, tc.focus)
			}
			if tc.focus != "" && state.StartedAt != base.Add(tc.startedAt).Unix() {
				t.Fatalf("startedAt=%d，期望 %d", state.StartedAt, base.Add(tc.startedAt).Unix())
			}
		})
	}
}

// 一轮「有会话在跑」从第一个会话开始到全部结束；中间新增会话不开启新一轮。
func TestActivityTrackerActivePeriod(t *testing.T) {
	base := time.Unix(1_800_000_000, 0)
	tracker := newActivityTracker()
	tracker.TurnStarted("codex", "t1", base)
	first := tracker.Summary(base).ActiveSince
	tracker.TurnStarted("codex", "t2", base.Add(time.Minute))
	if got := tracker.Summary(base.Add(time.Minute)).ActiveSince; !got.Equal(first) {
		t.Fatalf("新增会话不应开启新一轮：%v != %v", got, first)
	}
	tracker.TurnEnded("codex", "t1", LiveActivityStatusCompleted, base.Add(2*time.Minute))
	tracker.TurnEnded("codex", "t2", LiveActivityStatusCompleted, base.Add(2*time.Minute))
	if summary := tracker.Summary(base.Add(2 * time.Minute)); summary.Active || !summary.ActiveSince.IsZero() {
		t.Fatalf("全部结束后这一轮应结束：%+v", summary)
	}
	tracker.TurnStarted("codex", "t1", base.Add(3*time.Minute))
	if got := tracker.Summary(base.Add(3 * time.Minute)).ActiveSince; !got.Equal(base.Add(3 * time.Minute)) {
		t.Fatalf("再次开始应是新一轮：%v", got)
	}
}

// 事件经多个网关连接重复到达时不能反复报告变化，否则每条重复帧都会触发一次投递决策。
func TestActivityTrackerEventsAreIdempotent(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	cases := []struct {
		name  string
		apply func(*activityTracker) bool
	}{
		{"turn started", func(tr *activityTracker) bool { return tr.TurnStarted("codex", "t1", now) }},
		{"approval pending", func(tr *activityTracker) bool { return tr.ApprovalPending("codex", "t1", "r1", now) }},
		{"turn ended", func(tr *activityTracker) bool {
			return tr.TurnEnded("codex", "t1", LiveActivityStatusCompleted, now)
		}},
		{"waiting status", func(tr *activityTracker) bool { return tr.ThreadStatus("claude", "t1", "active", true, now) }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			tracker := newActivityTracker()
			if !tc.apply(tracker) {
				t.Fatal("第一次应报告变化")
			}
			if tc.apply(tracker) {
				t.Fatal("重复事件不应报告变化")
			}
		})
	}
}
