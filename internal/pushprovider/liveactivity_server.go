package pushprovider

import (
	"context"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"
)

const (
	// 同一活动的连续 update 至少间隔这么久才发下一条；窗口内只保留最后一条。
	liveActivityMinInterval = 5 * time.Second
	// 合并后延迟发出的更新不再有调用方等待，单独限定投递时长。
	liveActivityFlushTimeout = 15 * time.Second
)

type liveActivityJob struct {
	claims       TicketClaims
	notification LiveActivityNotification
	receivedAt   time.Time
}

type deliveryOutcome struct {
	status int
	body   map[string]any
}

func (s *Server) handleLiveActivity(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed")
		return
	}
	var body LiveActivityNotification
	if !decodeJSONBody(w, req, &body) {
		return
	}
	now := s.now()
	claims, err := s.sealer.Open(strings.TrimSpace(body.Ticket), now)
	if err != nil {
		s.metrics.record("liveactivity_rejected_ticket")
		writeError(w, http.StatusUnauthorized, "invalid_ticket")
		return
	}
	if !isActivityTicketKind(claims.Kind) {
		s.metrics.record("liveactivity_rejected_ticket_kind")
		writeError(w, http.StatusBadRequest, "ticket_kind_mismatch")
		return
	}
	// 每台设备一个独立的桶：活动更新再频繁也不会挤占审批通知的额度。
	if !s.limiter.allow("liveactivity:"+claims.InstallDigest, now) {
		s.metrics.record("rate_limited")
		w.Header().Set("Retry-After", "1")
		writeError(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	if err := body.Validate(now); err != nil {
		s.metrics.record("liveactivity_rejected_schema")
		writeError(w, http.StatusBadRequest, "invalid_request")
		return
	}
	if claims.Kind != body.requiredTicketKind() {
		s.metrics.record("liveactivity_rejected_ticket_kind")
		writeError(w, http.StatusBadRequest, "ticket_kind_mismatch")
		return
	}
	revoked, err := s.store.Revoked(req.Context(), claims.ID)
	if err != nil {
		log.Printf("push provider revocation lookup failed err=%v", err)
		writeError(w, http.StatusInternalServerError, "revocation_unavailable")
		return
	}
	if revoked {
		s.metrics.record("liveactivity_rejected_revoked")
		writeError(w, http.StatusForbidden, "ticket_revoked")
		return
	}
	if _, ok := s.apns[claims.Environment]; !ok {
		writeError(w, http.StatusBadRequest, "unsupported_environment")
		return
	}
	job := liveActivityJob{claims: claims, notification: body, receivedAt: now}
	if body.Event == liveActivityEventUpdate || body.Event == liveActivityEventEnd {
		if !s.activities.submit(claims.ID, job) {
			// 202 只表示已接受：窗口结束时发出的是那时最新的一条，结果不再回报给调用方。
			// Token 失效会照常撤销 Ticket，下一次请求即得到 403 ticket_revoked。
			s.metrics.record("liveactivity_coalesced")
			writeJSON(w, http.StatusAccepted, map[string]any{"accepted": true, "coalesced": true})
			return
		}
	}
	outcome := s.deliverLiveActivity(req.Context(), job)
	writeJSON(w, outcome.status, outcome.body)
}

// flushLiveActivity 发出合并窗口结束时最新的那条 update。窗口期间 Ticket 可能已被撤销
// 或过期，因此投递前重新检查。
func (s *Server) flushLiveActivity(job liveActivityJob) {
	ctx, cancel := context.WithTimeout(context.Background(), liveActivityFlushTimeout)
	defer cancel()
	if !job.claims.Expiry().After(s.now()) {
		return
	}
	revoked, err := s.store.Revoked(ctx, job.claims.ID)
	if err != nil {
		log.Printf("push provider revocation lookup failed err=%v", err)
		return
	}
	if revoked {
		s.metrics.record("liveactivity_rejected_revoked")
		return
	}
	s.deliverLiveActivity(ctx, job)
}

// deliverLiveActivity 的日志只含环境、事件枚举与 APNs 状态，不含 content-state、
// Ticket、Token 或 Payload。
func (s *Server) deliverLiveActivity(ctx context.Context, job liveActivityJob) deliveryOutcome {
	claims, notification := job.claims, job.notification
	client, ok := s.apns[claims.Environment]
	if !ok {
		return deliveryOutcome{http.StatusBadRequest, map[string]any{"error": "unsupported_environment"}}
	}
	payload, err := BuildLiveActivityPayload(notification, job.receivedAt)
	if err != nil {
		return deliveryOutcome{http.StatusInternalServerError, map[string]any{"error": "payload_failed"}}
	}
	expiry := notification.Expiry()
	if ticketExpiry := claims.Expiry(); ticketExpiry.Before(expiry) {
		expiry = ticketExpiry
	}
	start := s.now()
	result, err := client.Push(ctx, APNsRequest{
		DeviceToken: claims.DeviceToken,
		Topic:       claims.Topic,
		PushType:    apnsPushTypeLiveActivity,
		Expiration:  expiry,
		Priority:    notification.priority(),
		Payload:     payload,
	})
	if err != nil {
		s.metrics.record("apns_transport_error")
		log.Printf("push provider liveactivity apns transport error env=%s event=%s err=%v",
			claims.Environment, notification.Event, err)
		return deliveryOutcome{http.StatusBadGateway, map[string]any{"error": "apns_unavailable"}}
	}
	s.metrics.recordAPNs(result.StatusCode, s.now().Sub(start))
	if result.ActivityTokenGone() {
		if revokeErr := s.store.Revoke(ctx, claims.ID, claims.Expiry()); revokeErr != nil {
			log.Printf("push provider auto revoke failed err=%v", revokeErr)
		}
		return deliveryOutcome{http.StatusGone, map[string]any{"delivered": false, "reason": "unregistered"}}
	}
	if !result.OK() {
		log.Printf("push provider liveactivity apns rejected event=%s status=%d reason=%s",
			notification.Event, result.StatusCode, result.Reason)
		return deliveryOutcome{http.StatusOK, map[string]any{
			"delivered":   false,
			"reason":      result.Reason,
			"apns_status": result.StatusCode,
		}}
	}
	s.metrics.record("liveactivity_delivered_" + notification.Event)
	return deliveryOutcome{http.StatusOK, map[string]any{"delivered": true}}
}

// activityCoalescer 按活动（即更新 Ticket）合并 update：距上次发送不足最小间隔时
// 只保留最新一条，窗口结束再发。转入「待你处理」与 end 不等窗口，并丢弃窗口里
// 更旧的 update。状态只在进程内，重启时丢掉的最多是一条尚未发出的中间态。
type activityCoalescer struct {
	mu       sync.Mutex
	interval time.Duration
	now      func() time.Time
	schedule func(time.Duration, func())
	flush    func(liveActivityJob)
	entries  map[string]*activityEntry
	// 最近一次清扫的时刻与次数；清扫节奏与限速表相同（#915）。
	lastSweep time.Time
	sweeps    int
}

type activityEntry struct {
	lastSent   time.Time
	lastStatus string
	pending    *liveActivityJob
	scheduled  bool
}

func newActivityCoalescer(interval time.Duration, now func() time.Time, flush func(liveActivityJob)) *activityCoalescer {
	return &activityCoalescer{
		interval: interval,
		now:      now,
		schedule: func(delay time.Duration, fn func()) { time.AfterFunc(delay, fn) },
		flush:    flush,
		entries:  map[string]*activityEntry{},
	}
}

// submit 返回 true 表示调用方应立即投递；false 表示已放进合并窗口。
func (c *activityCoalescer) submit(activityID string, job liveActivityJob) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.now()
	c.evictLocked(now)
	entry, ok := c.entries[activityID]
	if !ok {
		entry = &activityEntry{}
		c.entries[activityID] = entry
	}
	status := job.notification.ContentState.Status
	urgent := job.notification.Event == liveActivityEventEnd ||
		(status == liveActivityStatusNeedsYou && entry.lastStatus != liveActivityStatusNeedsYou)
	windowOpen := !entry.lastSent.IsZero() && now.Sub(entry.lastSent) < c.interval
	if urgent || (entry.pending == nil && !windowOpen) {
		// 已排队的旧 update 比这一条更早，留着只会把状态改回去。
		entry.pending = nil
		entry.lastSent = now
		entry.lastStatus = status
		return true
	}
	entry.pending = &job
	if !entry.scheduled {
		entry.scheduled = true
		delay := entry.lastSent.Add(c.interval).Sub(now)
		if delay < 0 {
			delay = 0
		}
		c.schedule(delay, func() { c.fire(activityID) })
	}
	return false
}

func (c *activityCoalescer) fire(activityID string) {
	c.mu.Lock()
	entry, ok := c.entries[activityID]
	if !ok {
		c.mu.Unlock()
		return
	}
	entry.scheduled = false
	job := entry.pending
	if job == nil {
		c.mu.Unlock()
		return
	}
	now := c.now()
	// 计时器排下之后可能有一条紧急更新刚刚发出，窗口要从那一刻重新算。
	if remaining := entry.lastSent.Add(c.interval).Sub(now); remaining > 0 {
		entry.scheduled = true
		c.schedule(remaining, func() { c.fire(activityID) })
		c.mu.Unlock()
		return
	}
	entry.pending = nil
	entry.lastSent = now
	entry.lastStatus = job.notification.ContentState.Status
	c.mu.Unlock()
	c.flush(*job)
}

// evictLocked 让合并状态有界：只清理窗口已过、没有待发更新的活动。有待发更新或计时器的活动
// 一律保留，表满时新活动照常加入，宁可多占内存也不丢最后一次更新。
func (c *activityCoalescer) evictLocked(now time.Time) {
	if len(c.entries) < stateSweepThreshold || now.Sub(c.lastSweep) < stateSweepInterval {
		return
	}
	c.lastSweep = now
	c.sweeps++
	for id, entry := range c.entries {
		if entry.pending == nil && !entry.scheduled && now.Sub(entry.lastSent) >= c.interval {
			delete(c.entries, id)
		}
	}
}
