package pushprovider

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	maxRequestBytes  = 8 << 10
	maxDeviceTokenLn = 200
)

// Server 是最小推送服务：注册/刷新 Ticket、撤销 Ticket、按固定枚举发一条审批通知。
// 它不托管账号、不托管会话、不代理审批动作，也不接收任何会话内容。
type Server struct {
	sealer      *TicketSealer
	store       *RevocationStore
	topic       string
	environment string
	apns        map[string]*APNsClient
	limiter     *rateLimiter
	metrics     *metrics
	now         func() time.Time
}

type Options struct {
	Sealer      *TicketSealer
	Store       *RevocationStore
	Topic       string
	Environment string
	// APNs 客户端按环境分开：sandbox 与 production 的 Device Token 不通用，
	// 混用会稳定收到 BadDeviceToken。
	Clients map[string]*APNsClient
	Now     func() time.Time
}

func NewServer(options Options) (*Server, error) {
	if options.Sealer == nil || options.Store == nil {
		return nil, errors.New("sealer 与 store 必填")
	}
	if strings.TrimSpace(options.Topic) == "" {
		return nil, errors.New("apns topic（Bundle ID）必填")
	}
	now := options.Now
	if now == nil {
		now = time.Now
	}
	environment := strings.TrimSpace(options.Environment)
	if environment == "" {
		environment = "production"
	}
	return &Server{
		sealer:      options.Sealer,
		store:       options.Store,
		topic:       options.Topic,
		environment: environment,
		apns:        options.Clients,
		limiter:     newRateLimiter(),
		metrics:     &metrics{},
		now:         now,
	}, nil
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", s.handleHealth)
	mux.HandleFunc("/metrics", s.handleMetrics)
	mux.HandleFunc("/v1/ticket", s.handleIssueTicket)
	mux.HandleFunc("/v1/ticket/revoke", s.handleRevokeTicket)
	mux.HandleFunc("/v1/notify", s.handleNotify)
	return mux
}

func (s *Server) handleHealth(w http.ResponseWriter, req *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok", "environment": s.environment})
}

func (s *Server) handleMetrics(w http.ResponseWriter, req *http.Request) {
	writeJSON(w, http.StatusOK, s.metrics.snapshot())
}

type issueTicketRequest struct {
	Version      int    `json:"version"`
	Environment  string `json:"environment"`
	DeviceToken  string `json:"device_token"`
	Installation string `json:"installation"`
}

func (s *Server) handleIssueTicket(w http.ResponseWriter, req *http.Request) {
	if !s.acceptPost(w, req, "ip:"+clientIP(req)) {
		return
	}
	var body issueTicketRequest
	if !decodeJSONBody(w, req, &body) {
		return
	}
	if body.Version != 1 {
		writeError(w, http.StatusBadRequest, "unsupported_version")
		return
	}
	token := strings.TrimSpace(body.DeviceToken)
	if !validDeviceToken(token) {
		writeError(w, http.StatusBadRequest, "invalid_device_token")
		return
	}
	if err := validateOpaque("installation", strings.TrimSpace(body.Installation), maxIdentifierLen); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_installation")
		return
	}
	environment := strings.TrimSpace(body.Environment)
	if environment == "" {
		environment = s.environment
	}
	if _, ok := s.apns[normalizeEnvironmentName(environment)]; !ok {
		writeError(w, http.StatusBadRequest, "unsupported_environment")
		return
	}
	ticket, claims, err := s.sealer.Issue(
		normalizeEnvironmentName(environment),
		s.topic,
		strings.ToLower(token),
		installationDigest(body.Installation),
		s.now(),
	)
	if err != nil {
		log.Printf("push provider ticket issue failed err=%v", err)
		writeError(w, http.StatusInternalServerError, "issue_failed")
		return
	}
	s.metrics.record("ticket_issued")
	writeJSON(w, http.StatusOK, map[string]any{
		"ticket":     ticket,
		"expires_at": claims.Expiry().Format(time.RFC3339),
	})
}

type revokeTicketRequest struct {
	Version int    `json:"version"`
	Ticket  string `json:"ticket"`
}

func (s *Server) handleRevokeTicket(w http.ResponseWriter, req *http.Request) {
	if !s.acceptPost(w, req, "ip:"+clientIP(req)) {
		return
	}
	var body revokeTicketRequest
	if !decodeJSONBody(w, req, &body) {
		return
	}
	claims, err := s.sealer.Open(strings.TrimSpace(body.Ticket), s.now())
	if err != nil {
		// 已过期的 Ticket 无需撤销：它本来就打不开了。
		if errors.Is(err, errTicketExpired) {
			writeJSON(w, http.StatusOK, map[string]any{"revoked": true})
			return
		}
		writeError(w, http.StatusBadRequest, "invalid_ticket")
		return
	}
	if err := s.store.Revoke(req.Context(), claims.ID, claims.Expiry()); err != nil {
		log.Printf("push provider revoke failed err=%v", err)
		writeError(w, http.StatusInternalServerError, "revoke_failed")
		return
	}
	s.metrics.record("ticket_revoked")
	writeJSON(w, http.StatusOK, map[string]any{"revoked": true})
}

func (s *Server) handleNotify(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed")
		return
	}
	var body ApprovalNotification
	if !decodeJSONBody(w, req, &body) {
		return
	}
	now := s.now()
	claims, err := s.sealer.Open(strings.TrimSpace(body.Ticket), now)
	if err != nil {
		s.metrics.record("notify_rejected_ticket")
		writeError(w, http.StatusUnauthorized, "invalid_ticket")
		return
	}
	// 限速以 Ticket 为单位：一张泄漏的 Ticket 只能骚扰它绑定的那台设备，且有上限。
	if !s.limiter.allow("ticket:"+claims.ID, now) {
		s.metrics.record("rate_limited")
		w.Header().Set("Retry-After", "1")
		writeError(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	if err := body.Validate(now); err != nil {
		s.metrics.record("notify_rejected_schema")
		writeError(w, http.StatusBadRequest, "invalid_request")
		return
	}
	revoked, err := s.store.Revoked(req.Context(), claims.ID)
	if err != nil {
		log.Printf("push provider revocation lookup failed err=%v", err)
		writeError(w, http.StatusInternalServerError, "revocation_unavailable")
		return
	}
	if revoked {
		s.metrics.record("notify_rejected_revoked")
		writeError(w, http.StatusForbidden, "ticket_revoked")
		return
	}
	client, ok := s.apns[claims.Environment]
	if !ok {
		writeError(w, http.StatusBadRequest, "unsupported_environment")
		return
	}
	payload, err := BuildAPNsPayload(body)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "payload_failed")
		return
	}
	expiry := body.Expiry()
	if ticketExpiry := claims.Expiry(); ticketExpiry.Before(expiry) {
		expiry = ticketExpiry
	}
	priority := 10
	if body.Event == resolvedPushEvent {
		priority = 5
	}
	start := now
	result, err := client.Push(req.Context(), APNsRequest{
		DeviceToken: claims.DeviceToken,
		Topic:       claims.Topic,
		CollapseID:  CollapseID(body.ActionID),
		Expiration:  expiry,
		Priority:    priority,
		Payload:     payload,
	})
	if err != nil {
		s.metrics.record("apns_transport_error")
		log.Printf("push provider apns transport error env=%s err=%v", claims.Environment, err)
		writeError(w, http.StatusBadGateway, "apns_unavailable")
		return
	}
	s.metrics.recordAPNs(result.StatusCode, s.now().Sub(start))
	if result.Unregistered() {
		// Device Token 已失效：顺手把 Ticket 加进撤销表，避免继续对死 Token 投递。
		if revokeErr := s.store.Revoke(req.Context(), claims.ID, claims.Expiry()); revokeErr != nil {
			log.Printf("push provider auto revoke failed err=%v", revokeErr)
		}
		writeJSON(w, http.StatusGone, map[string]any{"delivered": false, "reason": "unregistered"})
		return
	}
	if !result.OK() {
		log.Printf("push provider apns rejected status=%d reason=%s", result.StatusCode, result.Reason)
		writeJSON(w, http.StatusBadGateway, map[string]any{"delivered": false, "reason": result.Reason})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"delivered": true})
}

func (s *Server) acceptPost(w http.ResponseWriter, req *http.Request, limitKey string) bool {
	if req.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed")
		return false
	}
	if !s.limiter.allow(limitKey, s.now()) {
		s.metrics.record("rate_limited")
		w.Header().Set("Retry-After", "1")
		writeError(w, http.StatusTooManyRequests, "rate_limited")
		return false
	}
	return true
}

// PurgeLoop 周期清理已经自然到期的撤销记录，让 Provider 的持久数据始终有界。
func (s *Server) PurgeLoop(ctx context.Context, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if _, err := s.store.Purge(ctx, s.now()); err != nil {
				log.Printf("push provider purge failed err=%v", err)
			}
		}
	}
}

func normalizeEnvironmentName(environment string) string {
	if strings.EqualFold(strings.TrimSpace(environment), "sandbox") {
		return "sandbox"
	}
	return "production"
}

func validDeviceToken(token string) bool {
	if len(token) == 0 || len(token) > maxDeviceTokenLn {
		return false
	}
	if _, err := hex.DecodeString(token); err != nil {
		return false
	}
	return len(token)%2 == 0
}

func decodeJSONBody(w http.ResponseWriter, req *http.Request, target any) bool {
	req.Body = http.MaxBytesReader(w, req.Body, maxRequestBytes)
	decoder := json.NewDecoder(req.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_body")
		return false
	}
	return true
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func writeError(w http.ResponseWriter, status int, reason string) {
	writeJSON(w, status, map[string]any{"error": reason})
}

func clientIP(req *http.Request) string {
	host, _, err := net.SplitHostPort(req.RemoteAddr)
	if err != nil {
		return req.RemoteAddr
	}
	return host
}

// rateLimiter 是进程内令牌桶。Provider 是单实例小服务，不为限速引入 Redis。
type rateLimiter struct {
	mu      sync.Mutex
	buckets map[string]*bucket
}

type bucket struct {
	tokens   float64
	lastSeen time.Time
}

const (
	rateBurst      = 20
	ratePerSecond  = 2.0
	bucketIdleLife = 10 * time.Minute
)

func newRateLimiter() *rateLimiter {
	return &rateLimiter{buckets: map[string]*bucket{}}
}

func (l *rateLimiter) allow(key string, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.evictLocked(now)
	entry, ok := l.buckets[key]
	if !ok {
		l.buckets[key] = &bucket{tokens: rateBurst - 1, lastSeen: now}
		return true
	}
	entry.tokens += now.Sub(entry.lastSeen).Seconds() * ratePerSecond
	if entry.tokens > rateBurst {
		entry.tokens = rateBurst
	}
	entry.lastSeen = now
	if entry.tokens < 1 {
		return false
	}
	entry.tokens--
	return true
}

func (l *rateLimiter) evictLocked(now time.Time) {
	if len(l.buckets) < 4096 {
		return
	}
	for key, entry := range l.buckets {
		if now.Sub(entry.lastSeen) > bucketIdleLife {
			delete(l.buckets, key)
		}
	}
}

// metrics 只记录计数、延迟与 APNs 状态码。禁止记录 Authorization、Ticket、
// Device Token、action_id、请求体或 APNs Payload。
type metrics struct {
	mu           sync.Mutex
	counters     map[string]int64
	apnsStatuses map[int]int64
	apnsLatency  time.Duration
	apnsCalls    int64
}

func (m *metrics) record(name string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.counters == nil {
		m.counters = map[string]int64{}
	}
	m.counters[name]++
}

func (m *metrics) recordAPNs(status int, latency time.Duration) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.apnsStatuses == nil {
		m.apnsStatuses = map[int]int64{}
	}
	m.apnsStatuses[status]++
	m.apnsLatency += latency
	m.apnsCalls++
}

func (m *metrics) snapshot() map[string]any {
	m.mu.Lock()
	defer m.mu.Unlock()
	counters := map[string]int64{}
	for key, value := range m.counters {
		counters[key] = value
	}
	statuses := map[string]int64{}
	for status, value := range m.apnsStatuses {
		statuses[strconv.Itoa(status)] = value
	}
	averageMillis := int64(0)
	if m.apnsCalls > 0 {
		averageMillis = (m.apnsLatency / time.Duration(m.apnsCalls)).Milliseconds()
	}
	return map[string]any{
		"counters":            counters,
		"apns_statuses":       statuses,
		"apns_avg_latency_ms": averageMillis,
	}
}
