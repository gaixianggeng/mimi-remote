package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/gorilla/websocket"
)

const relayMonitorRecentLimit = 80

type relayMonitor struct {
	mu        sync.Mutex
	startedAt time.Time
	nextID    int64

	http            relayHTTPStats
	gateway         relayGatewayStats
	active          map[string]*relayGatewayConnectionStats
	historyInflight map[string]relayHistoryInflightRequest
}

type relayHistoryInflightRequest struct {
	owner     string
	method    string
	startedAt time.Time
}

type relayHTTPStats struct {
	TotalRequests       int64             `json:"total_requests"`
	InflightRequests    int64             `json:"inflight_requests"`
	BytesOut            int64             `json:"bytes_out"`
	DurationMillisTotal int64             `json:"duration_ms_total"`
	DurationMillisMax   int64             `json:"duration_ms_max"`
	WriteMillisTotal    int64             `json:"write_ms_total"`
	WriteMillisMax      int64             `json:"write_ms_max"`
	WriteCalls          int64             `json:"write_calls"`
	Recent              []relayHTTPSample `json:"recent"`
}

type relayHTTPSample struct {
	EndedAt        time.Time `json:"ended_at"`
	Method         string    `json:"method"`
	Path           string    `json:"path"`
	Remote         string    `json:"remote"`
	Host           string    `json:"host"`
	Status         int       `json:"status"`
	ResponseBytes  int       `json:"response_bytes"`
	DurationMillis int64     `json:"duration_ms"`
	WriteMillis    int64     `json:"write_ms"`
	WriteCalls     int       `json:"write_calls"`
}

type relayGatewayStats struct {
	TotalConnections            int64                              `json:"total_connections"`
	ActiveConnections           int64                              `json:"active_connections"`
	FailedUpstreamDials         int64                              `json:"failed_upstream_dials"`
	UpstreamDialFailureKinds    map[string]int64                   `json:"upstream_dial_failure_kinds"`
	RecentUpstreamDialFailures  []relayGatewayDialFailureSample    `json:"recent_upstream_dial_failures"`
	UpstreamDialMillisMax       int64                              `json:"upstream_dial_ms_max"`
	UpstreamDialMillisSum       int64                              `json:"upstream_dial_ms_total"`
	ClientToUpstream            relayGatewayDirectionStats         `json:"client_to_upstream"`
	UpstreamToClient            relayGatewayDirectionStats         `json:"upstream_to_client"`
	RPC                         relayGatewayRPCStats               `json:"rpc"`
	PolicyErrors                int64                              `json:"policy_errors"`
	HistoryResponsesBlocked     int64                              `json:"history_responses_blocked"`
	HistoryResponseBytesBlocked int64                              `json:"history_response_bytes_blocked"`
	HistoryBudgetRejections     int64                              `json:"history_budget_rejections"`
	Methods                     map[string]relayGatewayMethodStats `json:"methods"`
	TerminationCounts           map[string]int64                   `json:"termination_counts"`
	RecentTerminations          []relayGatewayTerminationSample    `json:"recent_terminations"`
	RecentConnections           []relayGatewayConnectionStats      `json:"recent_connections"`
	ActiveConnectionDetail      []relayGatewayConnectionStats      `json:"active_connections_detail"`
	RecentRPC                   []relayGatewayRPCSample            `json:"recent_rpc"`
}

// relayGatewayDialFailureSample 只保存故障类别和耗时，不保存底层 error 文本。
// dial error 可能包含主机、URL 甚至第三方库拼接的凭据，诊断接口不能把它原样带给移动端。
type relayGatewayDialFailureSample struct {
	FailedAt       time.Time `json:"failed_at"`
	Kind           string    `json:"kind"`
	DurationMillis int64     `json:"duration_ms"`
}

// relayGatewayTerminationSample 用限界字段描述一次连接结束，足够区分客户端断网、
// 上游退出和写超时，同时避免记录 WebSocket close text、prompt 或文件内容。
type relayGatewayTerminationSample struct {
	EndedAt             time.Time `json:"ended_at"`
	ConnectionID        string    `json:"connection_id"`
	Stage               string    `json:"stage"`
	Kind                string    `json:"kind"`
	WebSocketCode       int       `json:"websocket_code,omitempty"`
	DurationMillis      int64     `json:"duration_ms"`
	OutstandingRequests int64     `json:"outstanding_requests"`
}

type relayGatewayMethodStats struct {
	Requested         int64 `json:"requested"`
	Inflight          int64 `json:"inflight"`
	DuplicateRejected int64 `json:"duplicate_rejected"`
	Rejected          int64 `json:"rejected"`
	Blocked           int64 `json:"blocked"`
	RateLimited       int64 `json:"rate_limited"`
	ResponseBytes     int64 `json:"response_bytes"`
}

type relayGatewayDirectionStats struct {
	Frames                int64 `json:"frames"`
	Bytes                 int64 `json:"bytes"`
	ForwardedBytes        int64 `json:"forwarded_bytes"`
	RedactedFrames        int64 `json:"redacted_frames"`
	RedactedBytesSaved    int64 `json:"redacted_bytes_saved"`
	PolicyMillisTotal     int64 `json:"policy_ms_total"`
	PolicyMillisMax       int64 `json:"policy_ms_max"`
	WriteMillisTotal      int64 `json:"write_ms_total"`
	WriteMillisMax        int64 `json:"write_ms_max"`
	ForwardedFrames       int64 `json:"forwarded_frames"`
	PolicyRejectedFrames  int64 `json:"policy_rejected_frames"`
	DroppedFrames         int64 `json:"dropped_frames"`
	LastFrameBytes        int64 `json:"last_frame_bytes"`
	LastForwardedBytes    int64 `json:"last_forwarded_bytes"`
	LastWriteMillis       int64 `json:"last_write_ms"`
	LastPolicyMillis      int64 `json:"last_policy_ms"`
	LastForwardedAtUnixMs int64 `json:"last_forwarded_at_unix_ms,omitempty"`
}

type relayGatewayRPCStats struct {
	Responses             int64 `json:"responses"`
	LatencyMillisTotal    int64 `json:"latency_ms_total"`
	LatencyMillisMax      int64 `json:"latency_ms_max"`
	RequestBytesTotal     int64 `json:"request_bytes_total"`
	ResponseBytesTotal    int64 `json:"response_bytes_total"`
	OutstandingRequests   int64 `json:"outstanding_requests"`
	OutstandingMillisMax  int64 `json:"outstanding_ms_max"`
	LastCompletedAtUnixMs int64 `json:"last_completed_at_unix_ms,omitempty"`
}

type relayGatewayConnectionStats struct {
	ID                          string                     `json:"id"`
	StartedAt                   time.Time                  `json:"started_at"`
	EndedAt                     *time.Time                 `json:"ended_at,omitempty"`
	DurationMillis              int64                      `json:"duration_ms"`
	Remote                      string                     `json:"remote"`
	Host                        string                     `json:"host"`
	Upstream                    string                     `json:"upstream"`
	UpstreamDialMillis          int64                      `json:"upstream_dial_ms"`
	CloseReason                 string                     `json:"close_reason,omitempty"`
	CloseStage                  string                     `json:"close_stage,omitempty"`
	CloseKind                   string                     `json:"close_kind,omitempty"`
	CloseWebSocketCode          int                        `json:"close_websocket_code,omitempty"`
	ClientToUpstream            relayGatewayDirectionStats `json:"client_to_upstream"`
	UpstreamToClient            relayGatewayDirectionStats `json:"upstream_to_client"`
	RPC                         relayGatewayRPCStats       `json:"rpc"`
	PolicyErrors                int64                      `json:"policy_errors"`
	HistoryResponsesBlocked     int64                      `json:"history_responses_blocked"`
	HistoryResponseBytesBlocked int64                      `json:"history_response_bytes_blocked"`
	HistoryBudgetRejections     int64                      `json:"history_budget_rejections"`
	RecentRPC                   []relayGatewayRPCSample    `json:"recent_rpc,omitempty"`
	pendingRPC                  map[string]relayPendingRPC `json:"-"`
	LastClientMethod            string                     `json:"last_client_method,omitempty"`
	LastUpstreamMethod          string                     `json:"last_upstream_method,omitempty"`
	LastClientFrameBytes        int64                      `json:"last_client_frame_bytes,omitempty"`
	LastUpstreamBytes           int64                      `json:"last_upstream_frame_bytes,omitempty"`
}

type relayPendingRPC struct {
	Method       string
	SentAt       time.Time
	RequestBytes int
}

type relayGatewayRPCSample struct {
	CompletedAt    time.Time `json:"completed_at"`
	Method         string    `json:"method"`
	LatencyMillis  int64     `json:"latency_ms"`
	RequestBytes   int       `json:"request_bytes"`
	ResponseBytes  int       `json:"response_bytes"`
	Outstanding    bool      `json:"outstanding,omitempty"`
	OutstandingFor int64     `json:"outstanding_for_ms,omitempty"`
}

type relayDiagnosticsResponse struct {
	GeneratedAt      time.Time             `json:"generated_at"`
	StartedAt        time.Time             `json:"started_at"`
	UptimeSeconds    int64                 `json:"uptime_seconds"`
	HTTP             relayHTTPStats        `json:"http"`
	AppServerGateway relayGatewayStats     `json:"app_server_gateway"`
	Hints            []string              `json:"hints"`
	Guide            relayDiagnosticsGuide `json:"guide"`
}

type relayDiagnosticsGuide struct {
	BandwidthSignal string `json:"bandwidth_signal"`
	ServerSignal    string `json:"server_signal"`
}

type relayGatewayConnMonitor struct {
	parent *relayMonitor
	id     string
}

type relayFrameMeta struct {
	ID         string
	Method     string
	IsResponse bool
}

type relayGatewayTermination struct {
	Stage         string
	Kind          string
	WebSocketCode int
}

func newRelayMonitor() *relayMonitor {
	return &relayMonitor{
		startedAt: time.Now().UTC(),
		gateway: relayGatewayStats{
			Methods:                  map[string]relayGatewayMethodStats{},
			UpstreamDialFailureKinds: map[string]int64{},
			TerminationCounts:        map[string]int64{},
		},
		active:          map[string]*relayGatewayConnectionStats{},
		historyInflight: map[string]relayHistoryInflightRequest{},
	}
}

func (m *relayMonitor) reserveHistoryInflight(fingerprint string, owner string, method string, ttl time.Duration) bool {
	if m == nil || fingerprint == "" || owner == "" {
		return true
	}
	now := time.Now()
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.historyInflight == nil {
		m.historyInflight = map[string]relayHistoryInflightRequest{}
	}
	for key, request := range m.historyInflight {
		if request.startedAt.IsZero() || (ttl > 0 && now.Sub(request.startedAt) > ttl) {
			stats := m.gateway.Methods[request.method]
			if stats.Inflight > 0 {
				stats.Inflight--
			}
			m.gateway.Methods[request.method] = stats
			delete(m.historyInflight, key)
		}
	}
	stats := m.gateway.Methods[method]
	stats.Requested++
	if _, exists := m.historyInflight[fingerprint]; exists {
		stats.DuplicateRejected++
		stats.Rejected++
		m.gateway.Methods[method] = stats
		return false
	}
	stats.Inflight++
	m.gateway.Methods[method] = stats
	m.historyInflight[fingerprint] = relayHistoryInflightRequest{owner: owner, method: method, startedAt: now}
	return true
}

func (m *relayMonitor) releaseHistoryInflight(fingerprint string, owner string) {
	if m == nil || fingerprint == "" || owner == "" {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	request, exists := m.historyInflight[fingerprint]
	if exists && request.owner == owner {
		delete(m.historyInflight, fingerprint)
		stats := m.gateway.Methods[request.method]
		if stats.Inflight > 0 {
			stats.Inflight--
		}
		m.gateway.Methods[request.method] = stats
	}
}

func (m *relayMonitor) recordHistoryResponseMetrics(method string, responseBytes int, blocked bool) {
	if m == nil || strings.TrimSpace(method) == "" {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	stats := m.gateway.Methods[method]
	stats.ResponseBytes += int64(responseBytes)
	if blocked {
		stats.Blocked++
	}
	m.gateway.Methods[method] = stats
}

func (m *relayMonitor) recordHistoryRateLimited(method string) {
	if m == nil || strings.TrimSpace(method) == "" {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	stats := m.gateway.Methods[method]
	stats.RateLimited++
	stats.Rejected++
	m.gateway.Methods[method] = stats
}

func (m *relayMonitor) beginHTTP() {
	if m == nil {
		return
	}
	m.mu.Lock()
	m.http.InflightRequests++
	m.mu.Unlock()
}

func (m *relayMonitor) recordHTTP(sample relayHTTPSample) {
	if m == nil {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.http.InflightRequests > 0 {
		m.http.InflightRequests--
	}
	m.http.TotalRequests++
	m.http.BytesOut += int64(sample.ResponseBytes)
	m.http.DurationMillisTotal += sample.DurationMillis
	if sample.DurationMillis > m.http.DurationMillisMax {
		m.http.DurationMillisMax = sample.DurationMillis
	}
	m.http.WriteMillisTotal += sample.WriteMillis
	if sample.WriteMillis > m.http.WriteMillisMax {
		m.http.WriteMillisMax = sample.WriteMillis
	}
	m.http.WriteCalls += int64(sample.WriteCalls)
	m.http.Recent = appendRecentHTTP(m.http.Recent, sample)
}

func (m *relayMonitor) recordGatewayDialFailure(duration time.Duration, err error) {
	if m == nil {
		return
	}
	ms := duration.Milliseconds()
	kind, _ := relayGatewayErrorKind(err)
	m.mu.Lock()
	defer m.mu.Unlock()
	m.gateway.FailedUpstreamDials++
	if m.gateway.UpstreamDialFailureKinds == nil {
		m.gateway.UpstreamDialFailureKinds = map[string]int64{}
	}
	m.gateway.UpstreamDialFailureKinds[kind]++
	m.gateway.RecentUpstreamDialFailures = appendRecentGatewayDialFailure(
		m.gateway.RecentUpstreamDialFailures,
		relayGatewayDialFailureSample{FailedAt: time.Now().UTC(), Kind: kind, DurationMillis: ms},
	)
	m.gateway.UpstreamDialMillisSum += ms
	if ms > m.gateway.UpstreamDialMillisMax {
		m.gateway.UpstreamDialMillisMax = ms
	}
}

func (m *relayMonitor) startGatewayConnection(remote string, host string, upstream string, dialDuration time.Duration) *relayGatewayConnMonitor {
	if m == nil {
		return nil
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.nextID++
	id := fmt.Sprintf("gateway-%d", m.nextID)
	dialMillis := dialDuration.Milliseconds()
	stats := &relayGatewayConnectionStats{
		ID:                 id,
		StartedAt:          time.Now().UTC(),
		Remote:             remote,
		Host:               host,
		Upstream:           upstream,
		UpstreamDialMillis: dialMillis,
		pendingRPC:         map[string]relayPendingRPC{},
	}
	m.gateway.TotalConnections++
	m.gateway.ActiveConnections = int64(len(m.active) + 1)
	m.gateway.UpstreamDialMillisSum += dialMillis
	if dialMillis > m.gateway.UpstreamDialMillisMax {
		m.gateway.UpstreamDialMillisMax = dialMillis
	}
	m.active[id] = stats
	return &relayGatewayConnMonitor{parent: m, id: id}
}

func (c *relayGatewayConnMonitor) finish(reason string) {
	if c == nil || c.parent == nil {
		return
	}
	c.parent.finishGatewayConnection(c.id, reason)
}

func (m *relayMonitor) finishGatewayConnection(id string, reason string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	stats, ok := m.active[id]
	if !ok {
		return
	}
	now := time.Now().UTC()
	termination := relayGatewayTerminationFromReason(reason)
	stats.EndedAt = &now
	stats.DurationMillis = now.Sub(stats.StartedAt).Milliseconds()
	stats.CloseStage = termination.Stage
	stats.CloseKind = termination.Kind
	stats.CloseWebSocketCode = termination.WebSocketCode
	stats.CloseReason = termination.safeReason()
	stats.RPC.OutstandingRequests = int64(len(stats.pendingRPC))
	stats.RPC.OutstandingMillisMax = maxOutstandingMillis(stats.pendingRPC, now)
	if m.gateway.TerminationCounts == nil {
		m.gateway.TerminationCounts = map[string]int64{}
	}
	m.gateway.TerminationCounts[termination.Stage+"."+termination.Kind]++
	m.gateway.RecentTerminations = appendRecentGatewayTermination(
		m.gateway.RecentTerminations,
		relayGatewayTerminationSample{
			EndedAt:             now,
			ConnectionID:        stats.ID,
			Stage:               termination.Stage,
			Kind:                termination.Kind,
			WebSocketCode:       termination.WebSocketCode,
			DurationMillis:      stats.DurationMillis,
			OutstandingRequests: stats.RPC.OutstandingRequests,
		},
	)
	stats.pendingRPC = nil
	m.gateway.RecentConnections = appendRecentGatewayConnection(m.gateway.RecentConnections, *stats)
	delete(m.active, id)
	m.gateway.ActiveConnections = int64(len(m.active))
}

func (c *relayGatewayConnMonitor) recordForward(direction string, payloadBytes int, forwardedBytes int, policyDuration time.Duration, writeDuration time.Duration, payload []byte) {
	if c == nil || c.parent == nil {
		return
	}
	c.parent.recordGatewayForward(c.id, direction, payloadBytes, forwardedBytes, policyDuration, writeDuration, payload)
}

// beginRPCRequest 必须在把请求写给上游前调用。上游可能在 Write 返回后立刻响应，
// 若等到 recordForward 才登记请求，响应协程可能先到并丢失 RPC 关联关系。
func (c *relayGatewayConnMonitor) beginRPCRequest(payload []byte, requestBytes int) string {
	if c == nil || c.parent == nil {
		return ""
	}
	meta := relayFrameMetaFromPayload(payload)
	if meta.ID == "" || meta.Method == "" {
		return ""
	}
	c.parent.beginGatewayRPC(c.id, meta.ID, meta.Method, requestBytes)
	return meta.ID
}

func (c *relayGatewayConnMonitor) cancelRPCRequest(id string) {
	if c == nil || c.parent == nil || id == "" {
		return
	}
	c.parent.cancelGatewayRPC(c.id, id)
}

func (m *relayMonitor) beginGatewayRPC(connectionID string, requestID string, method string, requestBytes int) {
	now := time.Now().UTC()
	m.mu.Lock()
	defer m.mu.Unlock()
	stats, ok := m.active[connectionID]
	if !ok {
		return
	}
	stats.pendingRPC[requestID] = relayPendingRPC{
		Method:       method,
		SentAt:       now,
		RequestBytes: requestBytes,
	}
	stats.RPC.OutstandingRequests = int64(len(stats.pendingRPC))
	m.gateway.RPC.OutstandingRequests = totalOutstandingRPC(m.active)
	m.gateway.RPC.OutstandingMillisMax = maxOutstandingMillisAcross(m.active, now)
}

func (m *relayMonitor) cancelGatewayRPC(connectionID string, requestID string) {
	now := time.Now().UTC()
	m.mu.Lock()
	defer m.mu.Unlock()
	stats, ok := m.active[connectionID]
	if !ok {
		return
	}
	delete(stats.pendingRPC, requestID)
	stats.RPC.OutstandingRequests = int64(len(stats.pendingRPC))
	stats.RPC.OutstandingMillisMax = maxOutstandingMillis(stats.pendingRPC, now)
	m.gateway.RPC.OutstandingRequests = totalOutstandingRPC(m.active)
	m.gateway.RPC.OutstandingMillisMax = maxOutstandingMillisAcross(m.active, now)
}

func (m *relayMonitor) recordGatewayForward(id string, direction string, payloadBytes int, forwardedBytes int, policyDuration time.Duration, writeDuration time.Duration, payload []byte) {
	meta := relayFrameMetaFromPayload(payload)
	now := time.Now().UTC()
	policyMillis := policyDuration.Milliseconds()
	writeMillis := writeDuration.Milliseconds()

	m.mu.Lock()
	defer m.mu.Unlock()
	stats, ok := m.active[id]
	if !ok {
		return
	}
	connDir := relayDirectionForConnection(stats, direction)
	totalDir := relayDirectionForGateway(&m.gateway, direction)
	applyRelayDirectionForward(connDir, payloadBytes, forwardedBytes, policyMillis, writeMillis, now)
	applyRelayDirectionForward(totalDir, payloadBytes, forwardedBytes, policyMillis, writeMillis, now)
	if direction == "client_to_upstream" {
		stats.LastClientMethod = meta.Method
		stats.LastClientFrameBytes = int64(payloadBytes)
		return
	}
	stats.LastUpstreamMethod = meta.Method
	stats.LastUpstreamBytes = int64(payloadBytes)
	if meta.ID != "" && meta.IsResponse {
		m.completeGatewayRPC(stats, meta.ID, forwardedBytes, now)
	}
}

func (m *relayMonitor) completeGatewayRPC(stats *relayGatewayConnectionStats, id string, responseBytes int, now time.Time) {
	pending, ok := stats.pendingRPC[id]
	if !ok {
		return
	}
	delete(stats.pendingRPC, id)
	latencyMillis := now.Sub(pending.SentAt).Milliseconds()
	sample := relayGatewayRPCSample{
		CompletedAt:    now,
		Method:         pending.Method,
		LatencyMillis:  latencyMillis,
		RequestBytes:   pending.RequestBytes,
		ResponseBytes:  responseBytes,
		Outstanding:    false,
		OutstandingFor: 0,
	}
	applyRelayRPCStats(&stats.RPC, sample)
	applyRelayRPCStats(&m.gateway.RPC, sample)
	stats.RecentRPC = appendRecentRPC(stats.RecentRPC, sample)
	m.gateway.RecentRPC = appendRecentRPC(m.gateway.RecentRPC, sample)
	stats.RPC.OutstandingRequests = int64(len(stats.pendingRPC))
	stats.RPC.OutstandingMillisMax = maxOutstandingMillis(stats.pendingRPC, now)
	m.gateway.RPC.OutstandingRequests = totalOutstandingRPC(m.active)
	m.gateway.RPC.OutstandingMillisMax = maxOutstandingMillisAcross(m.active, now)
}

func (c *relayGatewayConnMonitor) recordPolicyError(direction string, payloadBytes int, policyDuration time.Duration) {
	if c == nil || c.parent == nil {
		return
	}
	c.parent.recordGatewayPolicyError(c.id, direction, payloadBytes, policyDuration)
}

func (m *relayMonitor) recordGatewayPolicyError(id string, direction string, payloadBytes int, policyDuration time.Duration) {
	policyMillis := policyDuration.Milliseconds()
	m.mu.Lock()
	defer m.mu.Unlock()
	stats, ok := m.active[id]
	if !ok {
		return
	}
	connDir := relayDirectionForConnection(stats, direction)
	totalDir := relayDirectionForGateway(&m.gateway, direction)
	applyRelayDirectionPolicyError(connDir, payloadBytes, policyMillis)
	applyRelayDirectionPolicyError(totalDir, payloadBytes, policyMillis)
	stats.PolicyErrors++
	m.gateway.PolicyErrors++
}

func (c *relayGatewayConnMonitor) recordHistoryResponseBlocked(payloadBytes int, payload []byte) {
	if c == nil || c.parent == nil {
		return
	}
	c.parent.recordGatewayHistoryResponseBlocked(c.id, payloadBytes, payload)
}

func (m *relayMonitor) recordGatewayHistoryResponseBlocked(id string, payloadBytes int, payload []byte) {
	meta := relayFrameMetaFromPayload(payload)
	now := time.Now().UTC()
	m.mu.Lock()
	defer m.mu.Unlock()
	stats, ok := m.active[id]
	if !ok {
		return
	}
	stats.HistoryResponsesBlocked++
	stats.HistoryResponseBytesBlocked += int64(payloadBytes)
	m.gateway.HistoryResponsesBlocked++
	m.gateway.HistoryResponseBytesBlocked += int64(payloadBytes)
	if meta.ID != "" && meta.IsResponse {
		m.completeGatewayRPC(stats, meta.ID, payloadBytes, now)
	}
}

func (c *relayGatewayConnMonitor) recordHistoryBudgetRejected() {
	if c == nil || c.parent == nil {
		return
	}
	c.parent.recordGatewayHistoryBudgetRejected(c.id)
}

func (m *relayMonitor) recordGatewayHistoryBudgetRejected(id string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	stats, ok := m.active[id]
	if !ok {
		return
	}
	stats.HistoryBudgetRejections++
	m.gateway.HistoryBudgetRejections++
}

func (c *relayGatewayConnMonitor) recordDropped(direction string, payloadBytes int, policyDuration time.Duration) {
	if c == nil || c.parent == nil {
		return
	}
	c.parent.recordGatewayDropped(c.id, direction, payloadBytes, policyDuration)
}

func (m *relayMonitor) recordGatewayDropped(id string, direction string, payloadBytes int, policyDuration time.Duration) {
	policyMillis := policyDuration.Milliseconds()
	m.mu.Lock()
	defer m.mu.Unlock()
	stats, ok := m.active[id]
	if !ok {
		return
	}
	connDir := relayDirectionForConnection(stats, direction)
	totalDir := relayDirectionForGateway(&m.gateway, direction)
	applyRelayDirectionDropped(connDir, payloadBytes, policyMillis)
	applyRelayDirectionDropped(totalDir, payloadBytes, policyMillis)
}

func (m *relayMonitor) snapshot() relayDiagnosticsResponse {
	now := time.Now().UTC()
	m.mu.Lock()
	defer m.mu.Unlock()

	httpStats := m.http
	httpStats.Recent = append([]relayHTTPSample(nil), m.http.Recent...)

	gatewayStats := m.gateway
	gatewayStats.Methods = make(map[string]relayGatewayMethodStats, len(m.gateway.Methods))
	for method, stats := range m.gateway.Methods {
		gatewayStats.Methods[method] = stats
	}
	gatewayStats.UpstreamDialFailureKinds = copyRelayInt64Map(m.gateway.UpstreamDialFailureKinds)
	gatewayStats.TerminationCounts = copyRelayInt64Map(m.gateway.TerminationCounts)
	gatewayStats.RecentUpstreamDialFailures = append([]relayGatewayDialFailureSample(nil), m.gateway.RecentUpstreamDialFailures...)
	gatewayStats.RecentTerminations = append([]relayGatewayTerminationSample(nil), m.gateway.RecentTerminations...)
	gatewayStats.RecentConnections = append([]relayGatewayConnectionStats(nil), m.gateway.RecentConnections...)
	gatewayStats.RecentRPC = append([]relayGatewayRPCSample(nil), m.gateway.RecentRPC...)
	gatewayStats.ActiveConnections = int64(len(m.active))
	gatewayStats.RPC.OutstandingRequests = totalOutstandingRPC(m.active)
	gatewayStats.RPC.OutstandingMillisMax = maxOutstandingMillisAcross(m.active, now)
	gatewayStats.ActiveConnectionDetail = make([]relayGatewayConnectionStats, 0, len(m.active))
	for _, stats := range m.active {
		copyStats := *stats
		copyStats.DurationMillis = now.Sub(copyStats.StartedAt).Milliseconds()
		copyStats.RPC.OutstandingRequests = int64(len(stats.pendingRPC))
		copyStats.RPC.OutstandingMillisMax = maxOutstandingMillis(stats.pendingRPC, now)
		copyStats.pendingRPC = nil
		copyStats.RecentRPC = append([]relayGatewayRPCSample(nil), stats.RecentRPC...)
		gatewayStats.ActiveConnectionDetail = append(gatewayStats.ActiveConnectionDetail, copyStats)
	}

	response := relayDiagnosticsResponse{
		GeneratedAt:      now,
		StartedAt:        m.startedAt,
		UptimeSeconds:    int64(now.Sub(m.startedAt).Seconds()),
		HTTP:             httpStats,
		AppServerGateway: gatewayStats,
		Guide: relayDiagnosticsGuide{
			BandwidthSignal: "write_ms 高、bytes 大时，优先怀疑 iPad/VPS/SSH 隧道/公网带宽或客户端读取慢",
			ServerSignal:    "rpc.latency_ms 高但 write_ms 不高时，优先怀疑本机 agentd/app-server/Codex/模型处理慢",
		},
	}
	response.Hints = relayDiagnosticsHints(response)
	return response
}

func (r *Router) relayDiagnosticsHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	writeJSON(w, http.StatusOK, r.monitor.snapshot())
}

func relayDiagnosticsHints(snapshot relayDiagnosticsResponse) []string {
	hints := []string{}
	httpStats := snapshot.HTTP
	gatewayStats := snapshot.AppServerGateway
	if httpStats.TotalRequests == 0 && gatewayStats.TotalConnections == 0 {
		return []string{"暂无足够样本；先在 iPad 上复现一次慢请求，再刷新该接口。"}
	}
	if httpStats.WriteMillisMax >= 500 {
		hints = append(hints, fmt.Sprintf("HTTP 写出最大耗时 %dms，若对应响应较大，优先看公网带宽、VPS 转发或 SSH 隧道。", httpStats.WriteMillisMax))
	}
	if gatewayStats.UpstreamToClient.WriteMillisMax >= 500 {
		hints = append(hints, fmt.Sprintf("app-server gateway 写回客户端最大耗时 %dms，优先怀疑 iPad/VPS/SSH 隧道/公网带宽。", gatewayStats.UpstreamToClient.WriteMillisMax))
	}
	if gatewayStats.FailedUpstreamDials > 0 && len(gatewayStats.RecentUpstreamDialFailures) > 0 {
		last := gatewayStats.RecentUpstreamDialFailures[len(gatewayStats.RecentUpstreamDialFailures)-1]
		hints = append(hints, fmt.Sprintf("app-server 上游握手累计失败 %d 次，最近类别为 %s；若持续出现，先检查本机 app-server 是否就绪。", gatewayStats.FailedUpstreamDials, last.Kind))
	}
	if count := relayWeakNetworkTerminationCount(gatewayStats.TerminationCounts); count > 0 {
		hints = append(hints, fmt.Sprintf("最近连接累计出现 %d 次超时、断流或连接重置；真机验收时请对照 recent_terminations 的 stage 判断是客户端链路还是本机上游。", count))
	}
	if gatewayStats.RPC.LatencyMillisMax >= 2000 && gatewayStats.UpstreamToClient.WriteMillisMax < 500 {
		hints = append(hints, fmt.Sprintf("app-server JSON-RPC 最大响应耗时 %dms，但写回客户端不慢，优先看本机 app-server/Codex/模型响应。", gatewayStats.RPC.LatencyMillisMax))
	}
	if gatewayStats.RPC.OutstandingMillisMax >= 5000 {
		hints = append(hints, fmt.Sprintf("仍有 app-server 请求等待超过 %dms，说明上游还没返回响应；优先看 app-server、模型或本机负载。", gatewayStats.RPC.OutstandingMillisMax))
	}
	if gatewayStats.HistoryResponsesBlocked > 0 {
		hints = append(hints, fmt.Sprintf("app-server gateway 已阻断 %d 个超大历史响应（合计 %d bytes），建议降低 thread/turns/list limit、避免 full 大页或改用分页。", gatewayStats.HistoryResponsesBlocked, gatewayStats.HistoryResponseBytesBlocked))
	}
	if gatewayStats.HistoryBudgetRejections > 0 {
		hints = append(hints, fmt.Sprintf("app-server gateway 已限流 %d 个历史请求，说明同一 thread/method 可能在重试风暴；建议等待窗口恢复后再重试。", gatewayStats.HistoryBudgetRejections))
	}
	if len(hints) == 0 {
		hints = append(hints, "当前样本没有明显瓶颈信号；继续复现慢场景后重点比较 write_ms 和 rpc.latency_ms。")
	}
	return hints
}

func relayDirectionForConnection(stats *relayGatewayConnectionStats, direction string) *relayGatewayDirectionStats {
	if direction == "upstream_to_client" {
		return &stats.UpstreamToClient
	}
	return &stats.ClientToUpstream
}

func relayDirectionForGateway(stats *relayGatewayStats, direction string) *relayGatewayDirectionStats {
	if direction == "upstream_to_client" {
		return &stats.UpstreamToClient
	}
	return &stats.ClientToUpstream
}

func applyRelayDirectionForward(stats *relayGatewayDirectionStats, payloadBytes int, forwardedBytes int, policyMillis int64, writeMillis int64, now time.Time) {
	stats.Frames++
	stats.ForwardedFrames++
	stats.Bytes += int64(payloadBytes)
	stats.ForwardedBytes += int64(forwardedBytes)
	if payloadBytes > forwardedBytes {
		stats.RedactedFrames++
		stats.RedactedBytesSaved += int64(payloadBytes - forwardedBytes)
	}
	stats.PolicyMillisTotal += policyMillis
	stats.WriteMillisTotal += writeMillis
	stats.LastFrameBytes = int64(payloadBytes)
	stats.LastForwardedBytes = int64(forwardedBytes)
	stats.LastPolicyMillis = policyMillis
	stats.LastWriteMillis = writeMillis
	stats.LastForwardedAtUnixMs = now.UnixMilli()
	if policyMillis > stats.PolicyMillisMax {
		stats.PolicyMillisMax = policyMillis
	}
	if writeMillis > stats.WriteMillisMax {
		stats.WriteMillisMax = writeMillis
	}
}

func applyRelayDirectionPolicyError(stats *relayGatewayDirectionStats, payloadBytes int, policyMillis int64) {
	stats.Frames++
	stats.PolicyRejectedFrames++
	stats.Bytes += int64(payloadBytes)
	stats.PolicyMillisTotal += policyMillis
	stats.LastFrameBytes = int64(payloadBytes)
	stats.LastPolicyMillis = policyMillis
	if policyMillis > stats.PolicyMillisMax {
		stats.PolicyMillisMax = policyMillis
	}
}

func applyRelayDirectionDropped(stats *relayGatewayDirectionStats, payloadBytes int, policyMillis int64) {
	stats.Frames++
	stats.DroppedFrames++
	stats.Bytes += int64(payloadBytes)
	stats.PolicyMillisTotal += policyMillis
	stats.LastFrameBytes = int64(payloadBytes)
	stats.LastPolicyMillis = policyMillis
	if policyMillis > stats.PolicyMillisMax {
		stats.PolicyMillisMax = policyMillis
	}
}

func applyRelayRPCStats(stats *relayGatewayRPCStats, sample relayGatewayRPCSample) {
	stats.Responses++
	stats.LatencyMillisTotal += sample.LatencyMillis
	if sample.LatencyMillis > stats.LatencyMillisMax {
		stats.LatencyMillisMax = sample.LatencyMillis
	}
	stats.RequestBytesTotal += int64(sample.RequestBytes)
	stats.ResponseBytesTotal += int64(sample.ResponseBytes)
	stats.LastCompletedAtUnixMs = sample.CompletedAt.UnixMilli()
}

func relayFrameMetaFromPayload(payload []byte) relayFrameMeta {
	var frame appServerGatewayFrame
	if err := json.Unmarshal(payload, &frame); err != nil {
		return relayFrameMeta{}
	}
	meta := relayFrameMeta{Method: strings.TrimSpace(frame.Method)}
	if frame.ID != nil {
		meta.ID = string(*frame.ID)
	}
	if meta.Method == "" && meta.ID != "" && (len(frame.Result) > 0 || len(frame.Error) > 0) {
		meta.IsResponse = true
	}
	return meta
}

func appendRecentHTTP(items []relayHTTPSample, sample relayHTTPSample) []relayHTTPSample {
	items = append(items, sample)
	if len(items) > relayMonitorRecentLimit {
		items = append([]relayHTTPSample(nil), items[len(items)-relayMonitorRecentLimit:]...)
	}
	return items
}

func appendRecentGatewayConnection(items []relayGatewayConnectionStats, sample relayGatewayConnectionStats) []relayGatewayConnectionStats {
	items = append(items, sample)
	if len(items) > relayMonitorRecentLimit {
		items = append([]relayGatewayConnectionStats(nil), items[len(items)-relayMonitorRecentLimit:]...)
	}
	return items
}

func appendRecentGatewayDialFailure(items []relayGatewayDialFailureSample, sample relayGatewayDialFailureSample) []relayGatewayDialFailureSample {
	items = append(items, sample)
	if len(items) > relayMonitorRecentLimit {
		items = append([]relayGatewayDialFailureSample(nil), items[len(items)-relayMonitorRecentLimit:]...)
	}
	return items
}

func appendRecentGatewayTermination(items []relayGatewayTerminationSample, sample relayGatewayTerminationSample) []relayGatewayTerminationSample {
	items = append(items, sample)
	if len(items) > relayMonitorRecentLimit {
		items = append([]relayGatewayTerminationSample(nil), items[len(items)-relayMonitorRecentLimit:]...)
	}
	return items
}

func appendRecentRPC(items []relayGatewayRPCSample, sample relayGatewayRPCSample) []relayGatewayRPCSample {
	items = append(items, sample)
	if len(items) > relayMonitorRecentLimit {
		items = append([]relayGatewayRPCSample(nil), items[len(items)-relayMonitorRecentLimit:]...)
	}
	return items
}

func maxOutstandingMillis(pending map[string]relayPendingRPC, now time.Time) int64 {
	var max int64
	for _, item := range pending {
		ms := now.Sub(item.SentAt).Milliseconds()
		if ms > max {
			max = ms
		}
	}
	return max
}

func totalOutstandingRPC(active map[string]*relayGatewayConnectionStats) int64 {
	var total int64
	for _, stats := range active {
		total += int64(len(stats.pendingRPC))
	}
	return total
}

func maxOutstandingMillisAcross(active map[string]*relayGatewayConnectionStats, now time.Time) int64 {
	var max int64
	for _, stats := range active {
		ms := maxOutstandingMillis(stats.pendingRPC, now)
		if ms > max {
			max = ms
		}
	}
	return max
}

func trimRelayString(value string, max int) string {
	value = strings.TrimSpace(value)
	if len(value) <= max {
		return value
	}
	return value[:max] + "..."
}

func copyRelayInt64Map(source map[string]int64) map[string]int64 {
	result := make(map[string]int64, len(source))
	for key, value := range source {
		result[key] = value
	}
	return result
}

// gatewayCloseReason 把 error 先归类再编码。这里故意不保留 err.Error()：WebSocket
// close text 由对端控制，可能意外携带 Token、prompt 或文件内容。
func gatewayCloseReason(stage string, err error) string {
	kind, code := relayGatewayErrorKind(err)
	stage = normalizeRelayDiagnosticLabel(stage, "unknown")
	return stage + "|" + kind + "|" + strconv.Itoa(code)
}

func relayGatewayTerminationFromReason(reason string) relayGatewayTermination {
	parts := strings.Split(reason, "|")
	if len(parts) == 3 {
		code, _ := strconv.Atoi(parts[2])
		return relayGatewayTermination{
			Stage:         normalizeRelayDiagnosticLabel(parts[0], "unknown"),
			Kind:          normalizeRelayDiagnosticLabel(parts[1], "network_error"),
			WebSocketCode: code,
		}
	}

	// 固定内部原因也要转成限界字段。冒号后的原始进程错误只用于归类，不会进入响应。
	stage := reason
	if index := strings.IndexByte(stage, ':'); index >= 0 {
		stage = stage[:index]
	}
	stage = normalizeRelayDiagnosticLabel(stage, "unknown")
	kind := "internal"
	switch {
	case stage == "context_done":
		kind = "canceled"
	case stage == "bridge_exit" || stage == "bridge_stdout_closed":
		kind = "process_exit"
	case strings.Contains(stage, "policy_error_write"):
		kind = "write_failed"
	case strings.Contains(stage, "ping"):
		kind = "network_error"
	}
	return relayGatewayTermination{Stage: stage, Kind: kind}
}

func (t relayGatewayTermination) safeReason() string {
	if t.WebSocketCode != 0 {
		return fmt.Sprintf("%s:%s:%d", t.Stage, t.Kind, t.WebSocketCode)
	}
	return t.Stage + ":" + t.Kind
}

func relayGatewayErrorKind(err error) (string, int) {
	if err == nil {
		return "none", 0
	}
	var closeErr *websocket.CloseError
	if errors.As(err, &closeErr) {
		switch closeErr.Code {
		case websocket.CloseNormalClosure, websocket.CloseGoingAway:
			return "normal_close", closeErr.Code
		case websocket.CloseAbnormalClosure, websocket.CloseNoStatusReceived:
			return "connection_lost", closeErr.Code
		default:
			return "peer_closed", closeErr.Code
		}
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, net.ErrClosed) {
		return "canceled", 0
	}
	if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
		return "eof", 0
	}
	if errors.Is(err, syscall.ECONNRESET) {
		return "connection_reset", 0
	}
	if errors.Is(err, syscall.EPIPE) {
		return "broken_pipe", 0
	}
	if errors.Is(err, syscall.ECONNREFUSED) {
		return "connection_refused", 0
	}
	var netErr net.Error
	if errors.As(err, &netErr) && netErr.Timeout() {
		return "timeout", 0
	}

	// 某些包装库没有保留可 errors.Is 的底层错误，只做关键词归类，原文仍不会保存。
	message := strings.ToLower(err.Error())
	switch {
	case strings.Contains(message, "timeout"):
		return "timeout", 0
	case strings.Contains(message, "connection reset"):
		return "connection_reset", 0
	case strings.Contains(message, "broken pipe"):
		return "broken_pipe", 0
	case strings.Contains(message, "connection refused"):
		return "connection_refused", 0
	case strings.Contains(message, "unexpected eof"):
		return "eof", 0
	default:
		return "network_error", 0
	}
}

func normalizeRelayDiagnosticLabel(value string, fallback string) string {
	value = strings.ToLower(strings.TrimSpace(value))
	if value == "" || len(value) > 64 {
		return fallback
	}
	for _, r := range value {
		if (r < 'a' || r > 'z') && (r < '0' || r > '9') && r != '_' && r != '-' {
			return fallback
		}
	}
	return value
}

func relayWeakNetworkTerminationCount(counts map[string]int64) int64 {
	var total int64
	for key, count := range counts {
		for _, suffix := range []string{".timeout", ".connection_lost", ".connection_reset", ".broken_pipe", ".eof"} {
			if strings.HasSuffix(key, suffix) {
				total += count
				break
			}
		}
	}
	return total
}
