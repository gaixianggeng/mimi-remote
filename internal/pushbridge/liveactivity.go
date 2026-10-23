package pushbridge

import (
	"context"
	"errors"
	"log"
	"strings"
	"sync"
	"time"
)

// LiveActivityEngine 把会话汇总态投递到每台设备的锁屏 / 灵动岛活动（#830）。
//
// 每台设备一次只维持一个活动：有更新 Ticket 时原地 update，没有时在一轮运行开始后
// 用 push-to-start 拉起一次；全部会话结束后保留一段时间再 end。投递全部异步、
// fail-open：Provider 不可用、未部署或 APNs 拒绝都只影响活动本身，审批与回复提醒
// 走原有路径，互不阻塞。
const (
	// 同一活动两次 update 的最小间隔，与 Provider 的合并窗口一致；窗口内只发最新一条。
	liveActivityMinInterval = 5 * time.Second
	// App 在前台会直接在本机拉起活动并登记更新 Ticket。这段时间内不发 push-to-start，
	// 避免同一轮出现两个活动。
	liveActivityStartGrace = 8 * time.Second
	// 全部会话结束后，活动以终态保留这么久再结束；期间开始的新回合原地更新。
	liveActivityEndDelay = 3 * time.Minute
	// end 之后锁屏上继续显示的时长。
	liveActivityDismissDelay = 15 * time.Minute
	// push-to-start 拉起的活动若一直没登记更新 Ticket，到点后系统把它显示为过期。
	liveActivityStartStale  = 2 * time.Hour
	liveActivityStartExpiry = 10 * time.Minute
	// 普通更新过时就没有意义；end 要尽量送达。
	liveActivityUpdateExpiry = time.Hour
	liveActivityEndExpiry    = 4 * time.Hour
	liveActivityMaxBackoff   = 5 * time.Minute
	// 同一轮 push-to-start 连续失败这么多次就放弃，等下一轮再试。
	liveActivityMaxStartAttempts = 3
	// Provider 只接受 24 小时内的开始时间。
	liveActivityMaxStartedAge = 23 * time.Hour
)

// ErrLiveActivityDeviceUnknown 表示设备没有登记消息提醒：活动票据只能挂在已登记的
// 设备上，关闭提醒或删除档案后一并失效。
var ErrLiveActivityDeviceUnknown = errors.New("设备未登记消息提醒")

type liveActivityTimer interface{ Stop() bool }

type liveActivityDevice struct {
	updateTicket  string
	lastSent      *LiveActivityContentState
	lastSentAt    time.Time
	idleSince     time.Time
	startedPeriod time.Time
	startAttempts int
	inFlight      bool
	retryAt       time.Time
	failures      int
	timer         liveActivityTimer
	wakeAt        time.Time
	// discarded 是已经结束或已失效、但从磁盘删除失败的票据。投递决策不再使用它们，
	// 否则每次成功的 end 都会因票据还在而立即重发一遍。
	discarded map[string]struct{}
}

func (d *liveActivityDevice) resetActivity() {
	d.lastSent = nil
	d.lastSentAt = time.Time{}
	d.idleSince = time.Time{}
	d.failures = 0
	d.retryAt = time.Time{}
}

type liveActivityJob struct {
	deviceID     string
	kind         string
	ticket       string
	period       time.Time
	notification LiveActivityNotification
}

type LiveActivityEngine struct {
	mu      sync.Mutex
	tracker *activityTracker
	tickets *ActivityTicketStore
	devices map[string]*liveActivityDevice
	hostTag string
	closed  bool

	now          func() time.Time
	afterFunc    func(time.Duration, func()) liveActivityTimer
	send         func(context.Context, LiveActivityNotification) error
	dispatch     func(func(context.Context))
	deviceActive func(string) bool
	enabled      func() bool
}

func newLiveActivityEngine(tickets *ActivityTicketStore, hostTag string) *LiveActivityEngine {
	if tickets == nil {
		tickets = NewActivityTicketStore("")
	}
	return &LiveActivityEngine{
		tracker: newActivityTracker(),
		tickets: tickets,
		devices: map[string]*liveActivityDevice{},
		hostTag: hostTag,
		now:     time.Now,
		afterFunc: func(delay time.Duration, fn func()) liveActivityTimer {
			return time.AfterFunc(delay, fn)
		},
		deviceActive: func(string) bool { return false },
		enabled:      func() bool { return false },
	}
}

// MARK: - runtime 事件

func (e *LiveActivityEngine) TurnStarted(runtime, threadID string) {
	e.observe(func(now time.Time) bool { return e.tracker.TurnStarted(runtime, threadID, now) })
}

func (e *LiveActivityEngine) TurnEnded(runtime, threadID, status string) {
	e.observe(func(now time.Time) bool { return e.tracker.TurnEnded(runtime, threadID, status, now) })
}

func (e *LiveActivityEngine) ApprovalPending(runtime, threadID, requestID string) {
	e.observe(func(now time.Time) bool {
		return e.tracker.ApprovalPending(runtime, threadID, requestID, now)
	})
}

func (e *LiveActivityEngine) ApprovalResolved(runtime, threadID, requestID string) {
	e.observe(func(now time.Time) bool {
		return e.tracker.ApprovalResolved(runtime, threadID, requestID, now)
	})
}

func (e *LiveActivityEngine) ThreadStatus(runtime, threadID, statusType string, waiting bool) {
	e.observe(func(now time.Time) bool {
		return e.tracker.ThreadStatus(runtime, threadID, statusType, waiting, now)
	})
}

func (e *LiveActivityEngine) ThreadClosed(runtime, threadID string) {
	e.observe(func(time.Time) bool { return e.tracker.ThreadClosed(runtime, threadID) })
}

func (e *LiveActivityEngine) Touch(runtime, threadID string) {
	if e == nil {
		return
	}
	e.mu.Lock()
	e.tracker.Touch(runtime, threadID, e.now())
	e.mu.Unlock()
}

// observe 在推送关闭时也照常记账：App 稍后登记票据时，进行中的回合能立即显示。
func (e *LiveActivityEngine) observe(apply func(time.Time) bool) {
	if e == nil {
		return
	}
	e.mu.Lock()
	now := e.now()
	var jobs []liveActivityJob
	if apply(now) {
		jobs = e.reconcileAllLocked(now)
	}
	e.mu.Unlock()
	e.dispatchJobs(jobs)
}

// MARK: - 票据登记

func (e *LiveActivityEngine) Register(deviceID string, kind string, ticket ActivityTicket) (ActivityTicket, error) {
	if !e.deviceActive(deviceID) {
		return ActivityTicket{}, ErrLiveActivityDeviceUnknown
	}
	registered, err := e.tickets.Register(deviceID, kind, ticket)
	if err != nil {
		return ActivityTicket{}, err
	}
	e.Reconcile(deviceID)
	return registered, nil
}

// Unregister 的 kind 为空表示两类都注销。
func (e *LiveActivityEngine) Unregister(deviceID string, kind string, activityID string) (bool, error) {
	kinds := []string{kind}
	if kind == "" {
		kinds = []string{ActivityTicketStart, ActivityTicketUpdate}
	}
	removed := false
	for _, candidate := range kinds {
		ok, err := e.tickets.Remove(deviceID, candidate, activityID)
		if err != nil {
			return removed, err
		}
		removed = removed || ok
		if ok && candidate == ActivityTicketUpdate {
			e.mu.Lock()
			if device, exists := e.devices[deviceID]; exists {
				e.settlePeriodLocked(device)
			}
			e.mu.Unlock()
		}
	}
	e.Reconcile(deviceID)
	return removed, nil
}

// settlePeriodLocked 在活动被用户划掉或系统回收后调用：这一轮不再用 push-to-start
// 把它拉回来，下一轮回合开始时才重新拉起。
func (e *LiveActivityEngine) settlePeriodLocked(device *liveActivityDevice) {
	if !e.tracker.activeSince.IsZero() {
		device.startedPeriod = e.tracker.activeSince
	}
}

// RemoveDevice 随设备注销调用，不再向它发送任何活动推送。
func (e *LiveActivityEngine) RemoveDevice(deviceID string) {
	if e == nil {
		return
	}
	if _, err := e.tickets.RemoveDevice(deviceID); err != nil {
		log.Printf("push bridge 删除 Live Activity 票据失败 err=%v", err)
	}
	e.mu.Lock()
	e.dropDeviceLocked(deviceID)
	e.mu.Unlock()
}

// TicketStatus 只回答两类票据是否在登记中，供状态接口展示。
func (e *LiveActivityEngine) TicketStatus(deviceID string) (start bool, update bool) {
	startTicket, updateTicket := e.tickets.Get(deviceID)
	return startTicket != nil, updateTicket != nil
}

func (e *LiveActivityEngine) Reconcile(deviceID string) {
	if e == nil {
		return
	}
	e.mu.Lock()
	jobs := e.reconcileLocked(deviceID, e.now())
	e.mu.Unlock()
	e.dispatchJobs(jobs)
}

// ReconcileAll 在启动后调用：重启前登记的活动没有任何会话可显示，按空闲规则结束。
func (e *LiveActivityEngine) ReconcileAll() {
	if e == nil {
		return
	}
	e.mu.Lock()
	jobs := e.reconcileAllLocked(e.now())
	e.mu.Unlock()
	e.dispatchJobs(jobs)
}

func (e *LiveActivityEngine) Close() {
	if e == nil {
		return
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	e.closed = true
	for _, device := range e.devices {
		if device.timer != nil {
			device.timer.Stop()
			device.timer = nil
		}
	}
}

// MARK: - 投递决策

func (e *LiveActivityEngine) reconcileAllLocked(now time.Time) []liveActivityJob {
	ids := map[string]struct{}{}
	for _, id := range e.tickets.DeviceIDs() {
		ids[id] = struct{}{}
	}
	for id := range e.devices {
		ids[id] = struct{}{}
	}
	var jobs []liveActivityJob
	for id := range ids {
		jobs = append(jobs, e.reconcileLocked(id, now)...)
	}
	return jobs
}

func (e *LiveActivityEngine) dropDeviceLocked(deviceID string) {
	if device, ok := e.devices[deviceID]; ok {
		if device.timer != nil {
			device.timer.Stop()
		}
		delete(e.devices, deviceID)
	}
}

// reconcileLocked 比较「应当显示的状态」与「已经送达的状态」，最多产生一次投递；
// 需要等待（节流窗口、启动宽限、结束延迟、失败退避）时只排一次唤醒。
func (e *LiveActivityEngine) reconcileLocked(deviceID string, now time.Time) []liveActivityJob {
	if e.closed || !e.enabled() {
		return nil
	}
	start, update := e.tickets.Get(deviceID)
	if start == nil && update == nil {
		e.dropDeviceLocked(deviceID)
		return nil
	}
	if !e.deviceActive(deviceID) {
		// 设备的消息提醒已失效（过期或被删）：活动票据随之作废。
		if _, err := e.tickets.RemoveDevice(deviceID); err != nil {
			log.Printf("push bridge 删除 Live Activity 票据失败 err=%v", err)
		}
		e.dropDeviceLocked(deviceID)
		return nil
	}
	device, ok := e.devices[deviceID]
	if !ok {
		device = &liveActivityDevice{}
		e.devices[deviceID] = device
	}
	start, update = e.usableTicketsLocked(deviceID, device, start, update)
	// 先求汇总：下面判断「这一轮」时要用最新的 activeSince。
	summary := e.tracker.Summary(now)
	currentUpdate := ""
	if update != nil {
		currentUpdate = update.Ticket
	}
	if currentUpdate != device.updateTicket {
		if currentUpdate == "" {
			// 更新 Ticket 自然过期（活动到了系统时限）与被划掉同理：这一轮不再拉起。
			e.settlePeriodLocked(device)
		}
		// 换了活动（或活动没了）：之前送达的状态不再代表手机上那一个。
		device.updateTicket = currentUpdate
		device.resetActivity()
	}
	if device.inFlight || (start == nil && update == nil) {
		return nil
	}
	if now.Before(device.retryAt) {
		e.scheduleLocked(deviceID, device, device.retryAt, now)
		return nil
	}
	if summary.Active {
		device.idleSince = time.Time{}
		if update != nil {
			jobs := e.updateLocked(deviceID, device, update.Ticket, summary.State, now)
			if expiry := e.tracker.NextActiveExpiry(); len(jobs) == 0 && !expiry.IsZero() {
				// 观察中断时不会再有事件到来；到点回来清掉过期会话，活动才能按空闲规则结束。
				e.scheduleLocked(deviceID, device, expiry, now)
			}
			return jobs
		}
		if start == nil || device.startedPeriod.Equal(summary.ActiveSince) {
			return nil
		}
		if due := summary.ActiveSince.Add(liveActivityStartGrace); now.Before(due) {
			e.scheduleLocked(deviceID, device, due, now)
			return nil
		}
		return e.emitLocked(device, liveActivityJob{
			deviceID:     deviceID,
			kind:         ActivityTicketStart,
			ticket:       start.Ticket,
			period:       summary.ActiveSince,
			notification: e.notification(LiveActivityEventStart, start.Ticket, summary.State, now, now),
		})
	}
	if update == nil {
		return nil
	}
	if device.idleSince.IsZero() {
		device.idleSince = now
	}
	if summary.HasFocus && (device.lastSent == nil || *device.lastSent != summary.State) {
		// 先静默更新成终态；锁屏上的「已完成 / 失败」保留到 end。
		return e.updateLocked(deviceID, device, update.Ticket, summary.State, now)
	}
	if due := device.idleSince.Add(liveActivityEndDelay); now.Before(due) {
		e.scheduleLocked(deviceID, device, due, now)
		return nil
	}
	final, dismissal := summary.State, now.Add(liveActivityDismissDelay)
	if !summary.HasFocus {
		if device.lastSent == nil {
			// 什么都不知道（例如 agentd 重启前登记的活动）：立即移除，不显示猜测的结果。
			final = LiveActivityContentState{
				Status:          LiveActivityStatusCompleted,
				StartedAt:       update.RegisteredAt.Unix(),
				FocusSessionTag: e.hostTag,
			}
			dismissal = now
		} else {
			final = *device.lastSent
			if final.Status == LiveActivityStatusRunning || final.Status == LiveActivityStatusNeedsYou {
				// 会话没有终态就消失了（线程关闭、观察中断）：结果未知，立即移除，
				// 不把「运行中」留在锁屏上。
				dismissal = now
			}
		}
	}
	job := liveActivityJob{
		deviceID:     deviceID,
		kind:         ActivityTicketUpdate,
		ticket:       update.Ticket,
		notification: e.notification(LiveActivityEventEnd, update.Ticket, final, dismissal, now),
	}
	return e.emitLocked(device, job)
}

// usableTicketsLocked 去掉已丢弃的票据，并顺手再试一次把它们从磁盘删掉。
func (e *LiveActivityEngine) usableTicketsLocked(
	deviceID string,
	device *liveActivityDevice,
	start *ActivityTicket,
	update *ActivityTicket,
) (*ActivityTicket, *ActivityTicket) {
	if len(device.discarded) == 0 {
		return start, update
	}
	present := map[string]string{}
	if start != nil {
		present[start.Ticket] = ActivityTicketStart
	}
	if update != nil {
		present[update.Ticket] = ActivityTicketUpdate
	}
	for ticket := range device.discarded {
		kind, ok := present[ticket]
		if !ok {
			delete(device.discarded, ticket)
			continue
		}
		if removed, err := e.tickets.RemoveIfTicket(deviceID, kind, ticket); err == nil && removed {
			delete(device.discarded, ticket)
		}
		if kind == ActivityTicketStart {
			start = nil
		} else {
			update = nil
		}
	}
	return start, update
}

// discardLocked 删除一张已经结束或失效的票据；写盘失败时记进内存，之后的决策不再用它。
func (e *LiveActivityEngine) discardLocked(device *liveActivityDevice, deviceID string, kind string, ticket string) {
	if _, err := e.tickets.RemoveIfTicket(deviceID, kind, ticket); err != nil {
		log.Printf("push bridge 删除 Live Activity 票据失败 err=%v", err)
		if device.discarded == nil {
			device.discarded = map[string]struct{}{}
		}
		device.discarded[ticket] = struct{}{}
	}
	if kind == ActivityTicketUpdate && device.updateTicket == ticket {
		device.updateTicket = ""
		device.resetActivity()
	}
}

func (e *LiveActivityEngine) updateLocked(
	deviceID string,
	device *liveActivityDevice,
	ticket string,
	want LiveActivityContentState,
	now time.Time,
) []liveActivityJob {
	if device.lastSent != nil && *device.lastSent == want {
		return nil
	}
	// 新活动的第一条与转入「待你处理」不等窗口；其余在窗口内只保留最新状态。
	urgent := device.lastSent == nil ||
		(want.Status == LiveActivityStatusNeedsYou && device.lastSent.Status != LiveActivityStatusNeedsYou)
	if !urgent {
		if due := device.lastSentAt.Add(liveActivityMinInterval); now.Before(due) {
			e.scheduleLocked(deviceID, device, due, now)
			return nil
		}
	}
	return e.emitLocked(device, liveActivityJob{
		deviceID:     deviceID,
		kind:         ActivityTicketUpdate,
		ticket:       ticket,
		notification: e.notification(LiveActivityEventUpdate, ticket, want, now, now),
	})
}

func (e *LiveActivityEngine) emitLocked(device *liveActivityDevice, job liveActivityJob) []liveActivityJob {
	device.inFlight = true
	if device.timer != nil {
		device.timer.Stop()
		device.timer = nil
		device.wakeAt = time.Time{}
	}
	return []liveActivityJob{job}
}

// scheduleLocked 每台设备只保留最早的一次唤醒。
func (e *LiveActivityEngine) scheduleLocked(deviceID string, device *liveActivityDevice, at time.Time, now time.Time) {
	if device.timer != nil && !device.wakeAt.After(at) {
		return
	}
	if device.timer != nil {
		device.timer.Stop()
	}
	device.wakeAt = at
	device.timer = e.afterFunc(at.Sub(now), func() { e.wake(deviceID) })
}

func (e *LiveActivityEngine) wake(deviceID string) {
	e.mu.Lock()
	if device, ok := e.devices[deviceID]; ok {
		device.timer = nil
		device.wakeAt = time.Time{}
	}
	jobs := e.reconcileLocked(deviceID, e.now())
	e.mu.Unlock()
	e.dispatchJobs(jobs)
}

// notification 按事件补齐 Provider 要求的时间字段，并把计数与开始时间收进合法范围。
func (e *LiveActivityEngine) notification(
	event string,
	ticket string,
	state LiveActivityContentState,
	dismissal time.Time,
	now time.Time,
) LiveActivityNotification {
	state.RunningCount = max(0, min(state.RunningCount, maxLiveActivityCount))
	state.NeedsYouCount = max(0, min(state.NeedsYouCount, maxLiveActivityCount))
	if oldest := now.Add(-liveActivityMaxStartedAge).Unix(); state.StartedAt < oldest {
		state.StartedAt = oldest
	}
	if state.StartedAt > now.Unix() {
		state.StartedAt = now.Unix()
	}
	if strings.TrimSpace(state.FocusSessionTag) == "" {
		state.FocusSessionTag = e.hostTag
	}
	notification := LiveActivityNotification{Event: event, Ticket: ticket, ContentState: state}
	expiry := now.Add(liveActivityUpdateExpiry)
	switch event {
	case LiveActivityEventStart:
		notification.AttributesType = LiveActivityAttributesType
		notification.Attributes = &LiveActivityAttributes{HostTag: e.hostTag}
		notification.StaleDate = now.Add(liveActivityStartStale).Unix()
		expiry = now.Add(liveActivityStartExpiry)
	case LiveActivityEventEnd:
		notification.DismissalDate = dismissal.Unix()
		expiry = now.Add(liveActivityEndExpiry)
	}
	notification.ExpiresAt = expiry.UTC().Format(time.RFC3339)
	return notification
}

func (e *LiveActivityEngine) dispatchJobs(jobs []liveActivityJob) {
	for _, job := range jobs {
		job := job
		e.dispatch(func(ctx context.Context) {
			err := e.send(ctx, job.notification)
			e.complete(job, err)
		})
	}
}

// complete 处理一次投递的结果。Ticket 失效只删这张活动 Ticket；其它失败退避后重试，
// 都不触碰通知 Ticket 与设备注册。
func (e *LiveActivityEngine) complete(job liveActivityJob, err error) {
	e.mu.Lock()
	device, ok := e.devices[job.deviceID]
	if !ok {
		e.mu.Unlock()
		return
	}
	device.inFlight = false
	now := e.now()
	event := job.notification.Event
	switch {
	case err == nil:
		device.failures, device.retryAt = 0, time.Time{}
		switch event {
		case LiveActivityEventStart:
			device.startedPeriod, device.startAttempts = job.period, 0
		case LiveActivityEventUpdate:
			if device.updateTicket == job.ticket {
				state := job.notification.ContentState
				device.lastSent, device.lastSentAt = &state, now
			}
		case LiveActivityEventEnd:
			// 活动已结束，它的更新 Ticket 不再有用；下一轮重新拉起。结束期间若已开始新回合，
			// 新一轮照常 push-to-start。
			e.discardLocked(device, job.deviceID, ActivityTicketUpdate, job.ticket)
		}
	case errors.Is(err, ErrDeviceUnregistered):
		// Token 失效（用户划掉活动、系统回收）或 Ticket 被撤销：这张票据作废，下一轮按规则重新拉起。
		if job.kind == ActivityTicketUpdate {
			e.settlePeriodLocked(device)
		}
		e.discardLocked(device, job.deviceID, job.kind, job.ticket)
	default:
		device.failures++
		backoff := liveActivityMinInterval << min(device.failures-1, 8)
		device.retryAt = now.Add(min(backoff, liveActivityMaxBackoff))
		if event == LiveActivityEventStart {
			device.startAttempts++
			if device.startAttempts >= liveActivityMaxStartAttempts {
				device.startedPeriod, device.startAttempts = job.period, 0
			}
		}
		log.Printf("push bridge Live Activity 投递失败 event=%s err=%v", event, err)
	}
	jobs := e.reconcileLocked(job.deviceID, now)
	e.mu.Unlock()
	e.dispatchJobs(jobs)
}
