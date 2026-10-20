package pushbridge

import (
	"strings"
	"time"
)

// activityTracker 把 runtime 事件收敛成这台 Mac 上全部会话的汇总态。它只记枚举、
// 时间和请求 ID，不记任何内容；状态只在内存，agentd 重启后从下一次事件重新开始。
//
// 同一帧可能经多个网关连接重复到达，所有事件都必须幂等。
const (
	// 回合内没有任何生命周期事件超过这么久就视为观察中断（连接断了、错过终态），
	// 不能让锁屏一直显示「运行中」。
	activityActiveTTL = 3 * time.Hour
	// 终态只用于空闲时显示「刚完成 / 失败」的那一条，保留到活动结束为止即可。
	activityTerminalRetention  = 30 * time.Minute
	maxTrackedActivitySessions = 256
)

type trackedSession struct {
	runtime   string
	threadID  string
	tag       string
	active    bool
	startedAt time.Time
	// pending 是该线程尚未应答的审批 / 输入请求 ID；waiting 来自 thread/status 的等待标记。
	pending       map[string]struct{}
	waiting       bool
	needsYouSince time.Time
	terminal      string
	endedAt       time.Time
	lastSeen      time.Time
}

func (s *trackedSession) needsYou() bool {
	return s.active && (len(s.pending) > 0 || s.waiting)
}

func (s *trackedSession) status() string {
	switch {
	case s.needsYou():
		return LiveActivityStatusNeedsYou
	case s.active:
		return LiveActivityStatusRunning
	default:
		return s.terminal
	}
}

type activitySummary struct {
	// Active 为 true 表示至少一个会话在运行或等你处理。
	Active bool
	// HasFocus 为 false 表示没有可展示的会话（从未观察到或已全部过期）。
	HasFocus bool
	State    LiveActivityContentState
	// ActiveSince 是这一轮「有会话在跑」开始的时刻；每轮最多 push-to-start 一次。
	ActiveSince time.Time
}

type activityTracker struct {
	sessions    map[string]*trackedSession
	activeSince time.Time
}

func newActivityTracker() *activityTracker {
	return &activityTracker{sessions: map[string]*trackedSession{}}
}

func activitySessionKey(runtime, threadID string) string {
	return runtime + "\x00" + threadID
}

func (t *activityTracker) lookup(runtime, threadID string, create bool, now time.Time) *trackedSession {
	runtime, threadID = strings.TrimSpace(runtime), strings.TrimSpace(threadID)
	if runtime == "" || threadID == "" {
		return nil
	}
	key := activitySessionKey(runtime, threadID)
	if session, ok := t.sessions[key]; ok {
		return session
	}
	if !create {
		return nil
	}
	if len(t.sessions) >= maxTrackedActivitySessions {
		t.evictOldest()
	}
	session := &trackedSession{
		runtime:  runtime,
		threadID: threadID,
		tag:      MessageSessionTag(threadID),
		pending:  map[string]struct{}{},
		lastSeen: now,
	}
	t.sessions[key] = session
	return session
}

func (t *activityTracker) evictOldest() {
	var oldestKey string
	var oldest time.Time
	for key, session := range t.sessions {
		if oldestKey == "" || session.lastSeen.Before(oldest) {
			oldestKey, oldest = key, session.lastSeen
		}
	}
	delete(t.sessions, oldestKey)
}

func (s *trackedSession) begin(now time.Time) bool {
	s.lastSeen = now
	if s.active {
		return false
	}
	s.active = true
	s.startedAt = now
	s.terminal = ""
	s.endedAt = time.Time{}
	s.pending = map[string]struct{}{}
	s.waiting = false
	s.needsYouSince = time.Time{}
	return true
}

// TurnStarted 幂等：重复的 turn/started 不会重置开始时间。
func (t *activityTracker) TurnStarted(runtime, threadID string, now time.Time) bool {
	session := t.lookup(runtime, threadID, true, now)
	if session == nil {
		return false
	}
	return session.begin(now)
}

// TurnEnded 记录终态。没跟踪过的会话也记下来：agentd 重启后错过了 turn/started，
// 已有的活动仍应能显示「已完成」。
func (t *activityTracker) TurnEnded(runtime, threadID, status string, now time.Time) bool {
	if status != LiveActivityStatusCompleted && status != LiveActivityStatusFailed {
		return false
	}
	session := t.lookup(runtime, threadID, true, now)
	if session == nil {
		return false
	}
	session.lastSeen = now
	if !session.active && session.terminal == status {
		return false
	}
	if session.startedAt.IsZero() {
		session.startedAt = now
	}
	session.active = false
	session.terminal = status
	session.endedAt = now
	session.pending = map[string]struct{}{}
	session.waiting = false
	session.needsYouSince = time.Time{}
	return true
}

// ThreadClosed 让线程退出汇总。
func (t *activityTracker) ThreadClosed(runtime, threadID string) bool {
	session := t.lookup(runtime, threadID, false, time.Time{})
	if session == nil {
		return false
	}
	delete(t.sessions, activitySessionKey(session.runtime, session.threadID))
	return true
}

func (t *activityTracker) markNeedsYou(session *trackedSession, wasNeedsYou bool, now time.Time) {
	if !wasNeedsYou && session.needsYou() {
		session.needsYouSince = now
	}
	if !session.needsYou() {
		session.needsYouSince = time.Time{}
	}
}

// ApprovalPending：审批或输入请求出现即「待你处理」。请求只可能在回合内发起，
// 所以未跟踪的会话按运行中补登。
func (t *activityTracker) ApprovalPending(runtime, threadID, requestID string, now time.Time) bool {
	requestID = strings.TrimSpace(requestID)
	session := t.lookup(runtime, threadID, true, now)
	if session == nil || requestID == "" {
		return false
	}
	changed := session.begin(now)
	if _, ok := session.pending[requestID]; ok {
		return changed
	}
	was := session.needsYou()
	session.pending[requestID] = struct{}{}
	t.markNeedsYou(session, was, now)
	return true
}

// ApprovalResolved 在 threadID 为空时按 runtime 内的请求 ID 查找。
func (t *activityTracker) ApprovalResolved(runtime, threadID, requestID string, now time.Time) bool {
	requestID = strings.TrimSpace(requestID)
	if requestID == "" {
		return false
	}
	changed := false
	for _, session := range t.sessions {
		if session.runtime != runtime || (threadID != "" && session.threadID != threadID) {
			continue
		}
		if _, ok := session.pending[requestID]; !ok {
			continue
		}
		was := session.needsYou()
		delete(session.pending, requestID)
		session.lastSeen = now
		t.markNeedsYou(session, was, now)
		changed = changed || was != session.needsYou()
	}
	return changed
}

// ThreadStatus 对应 thread/status/changed。active 会话补登为运行中并同步等待标记；
// idle 只结束已跟踪的活跃会话，订阅或恢复线程时的空闲通知不会凭空造出「已完成」。
func (t *activityTracker) ThreadStatus(runtime, threadID, statusType string, waiting bool, now time.Time) bool {
	switch statusType {
	case "active":
		session := t.lookup(runtime, threadID, true, now)
		if session == nil {
			return false
		}
		changed := session.begin(now)
		was := session.needsYou()
		session.waiting = waiting
		t.markNeedsYou(session, was, now)
		return changed || was != session.needsYou()
	case "idle":
		session := t.lookup(runtime, threadID, false, now)
		if session == nil || !session.active {
			return false
		}
		return t.TurnEnded(runtime, threadID, LiveActivityStatusCompleted, now)
	case "systemError":
		session := t.lookup(runtime, threadID, false, now)
		if session == nil || !session.active {
			return false
		}
		return t.TurnEnded(runtime, threadID, LiveActivityStatusFailed, now)
	}
	return false
}

// Touch 只刷新活跃会话的存活时间，不改变状态。
func (t *activityTracker) Touch(runtime, threadID string, now time.Time) {
	if session := t.lookup(runtime, threadID, false, now); session != nil && session.active {
		session.lastSeen = now
	}
}

// NextActiveExpiry 是最早一个活跃会话因长时间没有事件而被清掉的时刻；没有活跃会话时为零值。
func (t *activityTracker) NextActiveExpiry() time.Time {
	var earliest time.Time
	for _, session := range t.sessions {
		if !session.active {
			continue
		}
		// Summary 只清掉超过 TTL 的会话，多留一秒保证到点时已经过期。
		expiry := session.lastSeen.Add(activityActiveTTL + time.Second)
		if earliest.IsZero() || expiry.Before(earliest) {
			earliest = expiry
		}
	}
	return earliest
}

// Summary 先清掉过期会话，再选出最需要关注的一条：最近转入「待你处理」的优先，
// 其次是最近开始的运行中会话；都没有时取最近结束的那条终态。
func (t *activityTracker) Summary(now time.Time) activitySummary {
	var focus *trackedSession
	running, needsYou := 0, 0
	for key, session := range t.sessions {
		if session.active && now.Sub(session.lastSeen) > activityActiveTTL {
			delete(t.sessions, key)
			continue
		}
		if !session.active && now.Sub(session.endedAt) > activityTerminalRetention {
			delete(t.sessions, key)
			continue
		}
		switch {
		case session.needsYou():
			needsYou++
		case session.active:
			running++
		}
		if focus == nil || focusBefore(session, focus) {
			focus = session
		}
	}
	summary := activitySummary{Active: running+needsYou > 0}
	if summary.Active {
		if t.activeSince.IsZero() {
			t.activeSince = now
		}
		summary.ActiveSince = t.activeSince
	} else {
		t.activeSince = time.Time{}
	}
	if focus == nil {
		return summary
	}
	summary.HasFocus = true
	summary.State = LiveActivityContentState{
		Status:          focus.status(),
		RunningCount:    min(running, maxLiveActivityCount),
		NeedsYouCount:   min(needsYou, maxLiveActivityCount),
		StartedAt:       focus.startedAt.Unix(),
		FocusSessionTag: focus.tag,
	}
	return summary
}

// focusBefore 返回 a 是否比 b 更需要关注；时间相同时按标签排序保证结果稳定。
func focusBefore(a, b *trackedSession) bool {
	rank := func(s *trackedSession) int {
		switch {
		case s.needsYou():
			return 0
		case s.active:
			return 1
		default:
			return 2
		}
	}
	if rank(a) != rank(b) {
		return rank(a) < rank(b)
	}
	at, bt := a.endedAt, b.endedAt
	switch rank(a) {
	case 0:
		at, bt = a.needsYouSince, b.needsYouSince
	case 1:
		at, bt = a.startedAt, b.startedAt
	}
	if !at.Equal(bt) {
		return at.After(bt)
	}
	return a.tag < b.tag
}
