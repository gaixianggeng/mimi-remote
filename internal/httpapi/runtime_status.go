package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
	"github.com/gaixianggeng/mimi-remote/internal/desktopipc"
	runtimebudget "github.com/gaixianggeng/mimi-remote/internal/runtimestatus"
)

const (
	runtimeStatusRefreshTimeout = runtimebudget.ProbeGenerationTimeout
	runtimeStatusSuccessTTL     = 5 * time.Minute
	runtimeStatusFailureTTL     = 15 * time.Second
	runtimeQuotaFallbackTTL     = 15 * time.Minute
	codexRuntimeProbeTimeout    = 8 * time.Second
	claudeRuntimeProbeTimeout   = 4 * time.Second
	claudeRuntimeQuotaTimeout   = 2 * time.Second
	claudeRuntimeQuotaHardLimit = 7 * time.Second
)

type runtimeConnectionState string

const (
	runtimeStateConnected   runtimeConnectionState = "connected"
	runtimeStateAvailable   runtimeConnectionState = "available"
	runtimeStateSignedOut   runtimeConnectionState = "signed_out"
	runtimeStateDisabled    runtimeConnectionState = "disabled"
	runtimeStateUnavailable runtimeConnectionState = "unavailable"
)

type runtimeStatusResponse struct {
	CheckedAt  *time.Time             `json:"checked_at,omitempty"`
	Refreshing bool                   `json:"refreshing"`
	Stale      bool                   `json:"stale"`
	Runtimes   []runtimeAccountStatus `json:"runtimes"`
}

type runtimeStatusSnapshotCache struct {
	mu sync.Mutex

	probe       func(context.Context) runtimeStatusResponse
	placeholder func() runtimeStatusResponse
	now         func() time.Time
	timeout     time.Duration
	successTTL  time.Duration
	failureTTL  time.Duration

	ctx         context.Context
	cancel      context.CancelFunc
	wg          sync.WaitGroup
	hasResult   bool
	snapshot    runtimeStatusResponse
	refreshing  bool
	refreshGen  uint64
	refreshDone map[uint64]chan struct{}
	forceNext   bool
	closed      bool
}

func newRuntimeStatusSnapshotCache(
	probe func(context.Context) runtimeStatusResponse,
	placeholder func() runtimeStatusResponse,
) *runtimeStatusSnapshotCache {
	ctx, cancel := context.WithCancel(context.Background())
	return &runtimeStatusSnapshotCache{
		probe:       probe,
		placeholder: placeholder,
		now:         time.Now,
		timeout:     runtimeStatusRefreshTimeout,
		successTTL:  runtimeStatusSuccessTTL,
		failureTTL:  runtimeStatusFailureTTL,
		refreshDone: make(map[uint64]chan struct{}),
		ctx:         ctx,
		cancel:      cancel,
	}
}

func (c *runtimeStatusSnapshotCache) Snapshot() runtimeStatusResponse {
	c.mu.Lock()
	defer c.mu.Unlock()

	now := c.now()
	if c.hasResult {
		ttl := c.successTTL
		if runtimeStatusHasFailure(c.snapshot) {
			ttl = c.failureTTL
		}
		if c.snapshot.CheckedAt != nil {
			age := now.Sub(*c.snapshot.CheckedAt)
			if age >= 0 && age < ttl {
				response := c.snapshot
				response.Refreshing = c.refreshing
				response.Stale = false
				return response
			}
		}
	}
	c.startRefreshLocked()
	if c.hasResult {
		response := c.snapshot
		response.Refreshing = c.refreshing
		response.Stale = true
		return response
	}
	response := c.placeholder()
	response.Refreshing = c.refreshing
	return response
}

// Refresh bypasses the TTL and waits for a probe that starts after this call.
// If a background probe is already running, manual callers share one follow-up
// generation. If the caller times out, the old result remains explicitly stale.
func (c *runtimeStatusSnapshotCache) Refresh(ctx context.Context) runtimeStatusResponse {
	if ctx == nil {
		ctx = context.Background()
	}
	c.mu.Lock()
	var target uint64
	if c.refreshing {
		// The running probe started before this request. Queue exactly one
		// follow-up generation so the returned sample is later than the click.
		target = c.refreshGen + 1
		c.forceNext = true
	} else {
		c.startRefreshLocked()
		target = c.refreshGen
	}
	done := c.refreshDoneLocked(target)
	c.mu.Unlock()

	completed := false
	if done != nil {
		select {
		case <-done:
			completed = true
		case <-ctx.Done():
		}
	}

	c.mu.Lock()
	defer c.mu.Unlock()
	if c.hasResult {
		response := c.snapshot
		response.Refreshing = c.refreshing
		response.Stale = c.refreshing && !completed
		return response
	}
	response := c.placeholder()
	response.Refreshing = c.refreshing
	return response
}

func (c *runtimeStatusSnapshotCache) startRefreshLocked() {
	if c.refreshing || c.closed {
		return
	}
	c.refreshing = true
	c.refreshGen++
	generation := c.refreshGen
	c.refreshDoneLocked(generation)
	c.wg.Add(1)
	go c.refresh(generation)
}

func (c *runtimeStatusSnapshotCache) refresh(generation uint64) {
	defer c.wg.Done()
	ctx, cancel := context.WithTimeout(c.ctx, c.timeout)
	response := c.probe(ctx)
	cancel()

	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.closed && c.ctx.Err() == nil {
		c.snapshot = response
		c.hasResult = true
	}
	c.closeRefreshDoneLocked(generation)
	c.refreshing = false
	if !c.closed && c.forceNext {
		c.forceNext = false
		c.startRefreshLocked()
	} else if c.closed {
		for pendingGeneration := range c.refreshDone {
			c.closeRefreshDoneLocked(pendingGeneration)
		}
	}
}

func (c *runtimeStatusSnapshotCache) refreshDoneLocked(generation uint64) chan struct{} {
	if generation == 0 || c.closed {
		return nil
	}
	done := c.refreshDone[generation]
	if done == nil {
		done = make(chan struct{})
		c.refreshDone[generation] = done
	}
	return done
}

func (c *runtimeStatusSnapshotCache) closeRefreshDoneLocked(generation uint64) {
	done := c.refreshDone[generation]
	if done == nil {
		return
	}
	close(done)
	delete(c.refreshDone, generation)
}

func (c *runtimeStatusSnapshotCache) Close() {
	if c == nil {
		return
	}
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return
	}
	c.closed = true
	c.cancel()
	c.mu.Unlock()
	c.wg.Wait()
}

func runtimeStatusHasFailure(response runtimeStatusResponse) bool {
	for _, runtime := range response.Runtimes {
		if runtime.State == runtimeStateUnavailable ||
			runtime.Reason == "quota_refresh_in_progress" ||
			runtime.RateLimits != nil &&
				strings.EqualFold(runtime.RateLimits.Availability, "unavailable") {
			return true
		}
	}
	return false
}

func (r *Router) cachedCodexRuntimeQuota(now time.Time) *runtimeRateLimits {
	r.codexRuntimeQuotaMu.RLock()
	defer r.codexRuntimeQuotaMu.RUnlock()
	if r.codexRuntimeQuota == nil ||
		r.codexRuntimeQuotaCheckedAt.IsZero() ||
		now.Sub(r.codexRuntimeQuotaCheckedAt) < 0 ||
		now.Sub(r.codexRuntimeQuotaCheckedAt) >= runtimeQuotaFallbackTTL {
		return nil
	}
	// runtimeRateLimits 归一化后只读；锁只保护整份缓存的替换。
	return r.codexRuntimeQuota
}

func (r *Router) storeCodexRuntimeQuota(limits *runtimeRateLimits) {
	if limits == nil {
		return
	}
	r.codexRuntimeQuotaMu.Lock()
	r.codexRuntimeQuota = limits
	r.codexRuntimeQuotaCheckedAt = time.Now().UTC()
	r.codexRuntimeQuotaMu.Unlock()
}

func (r *Router) cachedClaudeRuntimeQuota(now time.Time) *runtimeRateLimits {
	r.claudeRuntimeQuotaMu.RLock()
	defer r.claudeRuntimeQuotaMu.RUnlock()
	if r.claudeRuntimeQuota == nil ||
		r.claudeRuntimeQuotaCheckedAt.IsZero() ||
		now.Sub(r.claudeRuntimeQuotaCheckedAt) < 0 ||
		now.Sub(r.claudeRuntimeQuotaCheckedAt) >= runtimeStatusSuccessTTL {
		return nil
	}
	// runtimeRateLimits 解码后只读；锁保护指针替换，字段本身不会再被修改。
	return r.claudeRuntimeQuota
}

func (r *Router) storeClaudeRuntimeQuota(limits *runtimeRateLimits) {
	if limits == nil || strings.EqualFold(limits.Availability, "unavailable") {
		return
	}
	r.claudeRuntimeQuotaMu.Lock()
	r.claudeRuntimeQuota = limits
	r.claudeRuntimeQuotaCheckedAt = time.Now().UTC()
	r.claudeRuntimeQuotaMu.Unlock()
}

// runtimeAccountStatus 只包含菜单栏需要的脱敏状态。账号邮箱、Token、Keychain
// 内容和上游原始错误都不能进入这个结构，避免 status CLI 或日志扩大凭据暴露面。
type runtimeAccountStatus struct {
	ID          string                 `json:"id"`
	Title       string                 `json:"title"`
	Enabled     bool                   `json:"enabled"`
	State       runtimeConnectionState `json:"state"`
	Transport   string                 `json:"transport,omitempty"`
	Version     string                 `json:"version,omitempty"`
	StartedAt   *time.Time             `json:"started_at,omitempty"`
	AuthMode    string                 `json:"auth_mode,omitempty"`
	PlanType    string                 `json:"plan_type,omitempty"`
	Reason      string                 `json:"reason,omitempty"`
	RateLimits  *runtimeRateLimits     `json:"rate_limits,omitempty"`
	DesktopSync *desktopipc.Status     `json:"desktop_sync,omitempty"`
}

type runtimeRateLimits struct {
	LimitID           string                  `json:"limit_id,omitempty"`
	LimitName         string                  `json:"limit_name,omitempty"`
	PlanType          string                  `json:"plan_type,omitempty"`
	ReachedType       string                  `json:"reached_type,omitempty"`
	Availability      string                  `json:"availability,omitempty"`
	UnavailableReason string                  `json:"unavailable_reason,omitempty"`
	Primary           *runtimeRateLimitWindow `json:"primary,omitempty"`
	Secondary         *runtimeRateLimitWindow `json:"secondary,omitempty"`
	HasCredits        *bool                   `json:"has_credits,omitempty"`
	CreditsUnlimited  *bool                   `json:"credits_unlimited,omitempty"`
	CreditBalance     string                  `json:"credit_balance,omitempty"`
}

type runtimeRateLimitWindow struct {
	UsedPercent       *float64 `json:"used_percent,omitempty"`
	WindowDurationMin *int64   `json:"window_duration_mins,omitempty"`
	ResetsAt          *int64   `json:"resets_at,omitempty"`
}

type runtimeAccountResponse struct {
	Account *struct {
		Type     string          `json:"type"`
		PlanType json.RawMessage `json:"planType"`
	} `json:"account"`
	RequiresOpenAIAuth bool `json:"requiresOpenAIAuth"`
}

type runtimeRateLimitsEnvelope struct {
	RateLimits        *runtimeRateLimitWire           `json:"rateLimits"`
	RateLimitsByLimit map[string]runtimeRateLimitWire `json:"rateLimitsByLimitId"`
}

type runtimeRateLimitWire struct {
	LimitID           string                      `json:"limitId"`
	LimitName         string                      `json:"limitName"`
	PlanType          json.RawMessage             `json:"planType"`
	ReachedType       json.RawMessage             `json:"rateLimitReachedType"`
	Availability      string                      `json:"availability"`
	UnavailableReason string                      `json:"unavailableReason"`
	Primary           *runtimeRateLimitWindowWire `json:"primary"`
	Secondary         *runtimeRateLimitWindowWire `json:"secondary"`
	Credits           *struct {
		HasCredits bool            `json:"hasCredits"`
		Unlimited  bool            `json:"unlimited"`
		Balance    json.RawMessage `json:"balance"`
	} `json:"credits"`
}

type runtimeRateLimitWindowWire struct {
	UsedPercent       *float64 `json:"usedPercent"`
	WindowDurationMin *int64   `json:"windowDurationMins"`
	ResetsAt          *int64   `json:"resetsAt"`
}

func (r *Router) runtimeStatusHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	if !runtimeStatusLoopbackRequest(req) {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	var response runtimeStatusResponse
	switch req.URL.Query().Get("refresh") {
	case "":
		response = r.runtimeStatus.Snapshot()
	case "wait":
		response = r.runtimeStatus.Refresh(req.Context())
	default:
		http.Error(w, "invalid refresh mode", http.StatusBadRequest)
		return
	}
	writeJSON(w, http.StatusOK, response)
}

// SetCodexRuntimeStartedAt 连接 serve 层托管的 resident Codex 进程与本机状态接口。
// Router 在 HTTP listener 启动前设置一次；锁让测试和未来热重启也能安全更新。
func (r *Router) SetCodexRuntimeStartedAt(startedAt time.Time) {
	if r == nil {
		return
	}
	r.runtimeProcessMu.Lock()
	r.codexRuntimeStartedAt = startedAt.UTC()
	r.runtimeProcessMu.Unlock()
}

func (r *Router) codexRuntimeStartTime() *time.Time {
	r.runtimeProcessMu.RLock()
	startedAt := r.codexRuntimeStartedAt
	r.runtimeProcessMu.RUnlock()
	if startedAt.IsZero() {
		return nil
	}
	return &startedAt
}

func (r *Router) refreshRuntimeStatus(ctx context.Context) runtimeStatusResponse {
	codexResult := make(chan runtimeAccountStatus, 1)
	claudeResult := make(chan runtimeAccountStatus, 1)
	go func() {
		probeCtx, cancel := context.WithTimeout(ctx, codexRuntimeProbeTimeout)
		defer cancel()
		codexResult <- r.probeCodexRuntime(probeCtx)
	}()
	go func() {
		probeCtx, cancel := context.WithTimeout(ctx, claudeRuntimeProbeTimeout)
		defer cancel()
		claudeResult <- r.probeClaudeRuntime(probeCtx)
	}()

	codex := <-codexResult
	claude := <-claudeResult
	checkedAt := time.Now().UTC()
	return runtimeStatusResponse{
		CheckedAt: &checkedAt,
		Runtimes: []runtimeAccountStatus{
			codex,
			claude,
		},
	}
}

func (r *Router) runtimeStatusPlaceholder() runtimeStatusResponse {
	claude := runtimeAccountStatus{
		ID:      "claude",
		Title:   "Claude",
		Enabled: r.cfg.Claude.Enabled,
		State:   runtimeStateUnavailable,
		Reason:  "refresh_in_progress",
	}
	if !r.cfg.Claude.Enabled {
		claude.State = runtimeStateDisabled
		claude.Reason = "disabled"
	}
	return runtimeStatusResponse{
		Runtimes: []runtimeAccountStatus{
			{
				ID:          "codex",
				Title:       "Codex",
				Enabled:     true,
				State:       runtimeStateUnavailable,
				Transport:   strings.ToLower(strings.TrimSpace(r.cfg.AppServer.Transport)),
				StartedAt:   r.codexRuntimeStartTime(),
				Reason:      "refresh_in_progress",
				DesktopSync: r.desktopSyncStatus(),
			},
			claude,
		},
	}
}

func runtimeStatusLoopbackRequest(req *http.Request) bool {
	remote := strings.TrimSpace(req.RemoteAddr)
	host, _, err := net.SplitHostPort(remote)
	if err != nil {
		host = strings.Trim(remote, "[]")
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func (r *Router) probeCodexRuntime(ctx context.Context) (status runtimeAccountStatus) {
	status = runtimeAccountStatus{
		ID:          "codex",
		Title:       "Codex",
		Enabled:     true,
		State:       runtimeStateUnavailable,
		Transport:   strings.ToLower(strings.TrimSpace(r.cfg.AppServer.Transport)),
		StartedAt:   r.codexRuntimeStartTime(),
		Reason:      "upstream_unavailable",
		DesktopSync: r.desktopSyncStatus(),
	}
	upstreamURL, err := r.appServerUpstreamWebSocketURL()
	if err != nil {
		return status
	}
	headers, err := r.appServerUpstreamHeaders()
	if err != nil {
		return status
	}
	dialer, err := r.appServerUpstreamDialer(codexRuntimeProbeTimeout)
	if err != nil {
		return status
	}
	conn, response, err := dialer.DialContext(ctx, upstreamURL, headers)
	if response != nil && response.Body != nil {
		_ = response.Body.Close()
	}
	if err != nil {
		return status
	}
	defer conn.Close()

	rpc := runtimeWebSocketRPC{conn: conn}
	userAgent, err := rpc.initialize(ctx)
	if err != nil {
		return status
	}
	status.Version = runtimeVersionFromUserAgent(userAgent)
	status.State = runtimeStateAvailable
	status.Reason = ""

	var account runtimeAccountResponse
	if err := rpc.call(ctx, "account/read", map[string]any{"refreshToken": false}, &account); err != nil {
		status.Reason = "account_unavailable"
	} else {
		applyCodexAccount(&status, account)
	}

	var limits runtimeRateLimitsEnvelope
	if err := rpc.call(ctx, "account/rateLimits/read", map[string]any{}, &limits); err == nil {
		status.RateLimits = normalizeRuntimeRateLimits(limits, "codex")
		r.storeCodexRuntimeQuota(status.RateLimits)
	}
	if status.RateLimits == nil {
		status.RateLimits = r.cachedCodexRuntimeQuota(time.Now().UTC())
	}
	if status.PlanType == "" && status.RateLimits != nil {
		status.PlanType = status.RateLimits.PlanType
	}
	if status.RateLimits == nil && status.Reason == "" {
		// 账号连接已经确认，额度缺失只触发短 TTL 后台重试，不能把 Codex
		// 降级成断开；菜单会继续显示连接状态和已有的视觉占位。
		status.Reason = "quota_refresh_in_progress"
	}
	return status
}

func (r *Router) desktopSyncStatus() *desktopipc.Status {
	if r == nil || r.desktopIPC == nil {
		status := desktopipc.DisabledStatus()
		return &status
	}
	status := r.desktopIPC.Status()
	return &status
}

func applyCodexAccount(status *runtimeAccountStatus, response runtimeAccountResponse) {
	if response.Account == nil {
		if response.RequiresOpenAIAuth {
			status.State = runtimeStateSignedOut
			status.Reason = "not_authenticated"
		}
		return
	}
	status.AuthMode = normalizeAuthMode(response.Account.Type)
	status.PlanType = rawScalarString(response.Account.PlanType)
	switch status.AuthMode {
	case "chatgpt":
		// 托管 ChatGPT 账户由 Codex 负责 OAuth 与刷新，account/read 返回账户
		// 即可作为已登录证据。
		status.State = runtimeStateConnected
		status.Reason = ""
	case "api_key":
		// account/read 只证明 Key 已存入 Codex，不会主动验证 Key 是否有效。
		status.State = runtimeStateAvailable
		status.Reason = "api_key_configured_unverified"
	case "bedrock":
		// Bedrock credentialSource 只说明选中的凭据来源，AWS 凭据链可能仍不可用。
		status.State = runtimeStateAvailable
		status.Reason = "bedrock_credentials_configured_unverified"
	default:
		// 新增认证类型默认不宣称已连接；拿到实际认证证据后再提升状态。
		status.State = runtimeStateAvailable
		status.Reason = "account_configured_unverified"
	}
}

func (r *Router) probeClaudeRuntime(ctx context.Context) runtimeAccountStatus {
	status := runtimeAccountStatus{
		ID:      "claude",
		Title:   "Claude",
		Enabled: r.cfg.Claude.Enabled,
		State:   runtimeStateDisabled,
		Reason:  "disabled",
	}
	if !r.cfg.Claude.Enabled {
		return status
	}
	status.State = runtimeStateUnavailable
	status.Reason = "bridge_unavailable"
	r.refreshClaudeBridgeProbeIfStale()
	probe := r.claudeBridgeProbe()
	if !probe.Healthy {
		return status
	}
	bin := firstNonEmpty(probe.Path, strings.TrimSpace(r.cfg.Claude.BridgeBin))
	ensureResult := make(chan error, 1)
	go func() {
		_, err := r.claudeBridge.ensure(bin, r.cfg.Claude.Args, r.cfg.Claude.Env)
		ensureResult <- err
	}()
	select {
	case <-ctx.Done():
		return status
	case err := <-ensureResult:
		if err != nil {
			return status
		}
	}
	status.StartedAt = r.claudeBridge.runningSince()
	if ctx.Err() != nil {
		return status
	}
	conn, _, err := r.claudeBridge.dial()
	if err != nil {
		return status
	}
	keepQuotaProbeAlive := false
	defer func() {
		if !keepQuotaProbeAlive {
			_ = conn.Close()
		}
	}()

	client := appserver.NewClient(conn, conn, appserver.ClientOptions{
		ClientInfo: appserver.ClientInfo{
			Name:    "mimi_remote_mac_status",
			Title:   "Mimi Remote Mac",
			Version: r.version,
		},
	})
	defer func() {
		if !keepQuotaProbeAlive {
			_ = client.Close()
		}
	}()
	initialization, err := client.Initialize(ctx)
	if err != nil {
		return status
	}
	// Claude 行展示的是实际已连接的 resident bridge 版本，而不是磁盘上
	// 可能已经被新安装包替换、但尚未重启的二进制版本。
	status.Version = runtimeVersionFromUserAgent(initialization.UserAgent)
	status.State = runtimeStateAvailable
	status.Reason = ""

	if claudeAPIKeyConfigured(r.cfg.Claude.Env) {
		// bridge 只会收到 cfg.Claude.Env 中显式配置的 API Key。Key 的存在表示
		// “已配置”而不是“已验证”。API Key 是按量计费身份，不能查询并混入
		// 同一台 Mac 上残留的 OAuth 订阅额度。
		status.AuthMode = "api_key"
		status.Reason = "api_key_configured_unverified"
		return status
	}
	if cached := r.cachedClaudeRuntimeQuota(time.Now().UTC()); cached != nil {
		applyClaudeRuntimeQuota(&status, cached)
		return status
	}

	// 连接状态与额度是两种时效要求：本机 bridge 的 initialize 足以确认进程
	// 可用，OAuth/Keychain/网络额度查询则可能很慢。菜单栏最多为额度等待 2 秒，
	// 超时后先返回连接与版本；已发出的查询最多再存活 7 秒以填充 bridge 缓存，
	// 供 15 秒后的补拉复用，不能在返回菜单结果时直接留下无界后台任务。
	type quotaProbeResult struct {
		limits runtimeRateLimitsEnvelope
		err    error
	}
	quotaCtx, cancelQuota := context.WithTimeout(
		context.WithoutCancel(ctx),
		claudeRuntimeQuotaHardLimit,
	)
	quotaResult := make(chan quotaProbeResult, 1)
	go func() {
		var limits runtimeRateLimitsEnvelope
		err := client.Call(
			quotaCtx,
			"account/rateLimits/read",
			map[string]any{},
			&limits,
		)
		quotaResult <- quotaProbeResult{limits: limits, err: err}
	}()
	presentationTimer := time.NewTimer(claudeRuntimeQuotaTimeout)
	defer presentationTimer.Stop()

	select {
	case result := <-quotaResult:
		cancelQuota()
		if result.err != nil {
			return status
		}
		limits := normalizeRuntimeRateLimits(result.limits, "claude")
		r.storeClaudeRuntimeQuota(limits)
		applyClaudeRuntimeQuota(&status, limits)
	case <-presentationTimer.C:
		status.Reason = "quota_refresh_in_progress"
		keepQuotaProbeAlive = true
		go func() {
			defer cancelQuota()
			defer client.Close()
			defer conn.Close()
			select {
			case result := <-quotaResult:
				if result.err == nil {
					r.storeClaudeRuntimeQuota(
						normalizeRuntimeRateLimits(result.limits, "claude"),
					)
				}
			case <-quotaCtx.Done():
			}
		}()
	case <-ctx.Done():
		cancelQuota()
		return status
	}
	return status
}

func applyClaudeRuntimeQuota(status *runtimeAccountStatus, limits *runtimeRateLimits) {
	if limits == nil {
		return
	}
	status.RateLimits = limits
	status.PlanType = limits.PlanType
	if runtimeRateLimitsShowAuthenticated(limits) {
		status.State = runtimeStateConnected
		status.AuthMode = "oauth"
	}
}

func claudeAPIKeyConfigured(configured map[string]string) bool {
	return strings.TrimSpace(configured["ANTHROPIC_API_KEY"]) != ""
}

func runtimeRateLimitsShowAuthenticated(limits *runtimeRateLimits) bool {
	if limits == nil {
		return false
	}
	if strings.EqualFold(limits.Availability, "available") || strings.TrimSpace(limits.PlanType) != "" {
		return true
	}
	return limits.Primary != nil && limits.Primary.UsedPercent != nil ||
		limits.Secondary != nil && limits.Secondary.UsedPercent != nil
}

func normalizeRuntimeRateLimits(
	envelope runtimeRateLimitsEnvelope,
	preferredID string,
) *runtimeRateLimits {
	var wire *runtimeRateLimitWire
	if item, ok := envelope.RateLimitsByLimit[preferredID]; ok {
		wire = &item
	} else if len(envelope.RateLimitsByLimit) > 0 {
		keys := make([]string, 0, len(envelope.RateLimitsByLimit))
		for key := range envelope.RateLimitsByLimit {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		item := envelope.RateLimitsByLimit[keys[0]]
		wire = &item
	} else {
		wire = envelope.RateLimits
	}
	if wire == nil {
		return nil
	}
	normalized := &runtimeRateLimits{
		LimitID:           strings.TrimSpace(wire.LimitID),
		LimitName:         strings.TrimSpace(wire.LimitName),
		PlanType:          rawScalarString(wire.PlanType),
		ReachedType:       rawScalarString(wire.ReachedType),
		Availability:      strings.TrimSpace(wire.Availability),
		UnavailableReason: strings.TrimSpace(wire.UnavailableReason),
		Primary:           normalizeRuntimeRateLimitWindow(wire.Primary),
		Secondary:         normalizeRuntimeRateLimitWindow(wire.Secondary),
	}
	if wire.Credits != nil {
		hasCredits := wire.Credits.HasCredits
		unlimited := wire.Credits.Unlimited
		normalized.HasCredits = &hasCredits
		normalized.CreditsUnlimited = &unlimited
		normalized.CreditBalance = rawScalarString(wire.Credits.Balance)
	}
	if normalized.LimitID == "" && normalized.LimitName == "" &&
		normalized.PlanType == "" && normalized.ReachedType == "" &&
		normalized.Availability == "" && normalized.UnavailableReason == "" &&
		normalized.Primary == nil && normalized.Secondary == nil &&
		normalized.HasCredits == nil && normalized.CreditBalance == "" {
		return nil
	}
	return normalized
}

func normalizeRuntimeRateLimitWindow(wire *runtimeRateLimitWindowWire) *runtimeRateLimitWindow {
	if wire == nil {
		return nil
	}
	if wire.UsedPercent == nil && wire.WindowDurationMin == nil && wire.ResetsAt == nil {
		return nil
	}
	return &runtimeRateLimitWindow{
		UsedPercent:       wire.UsedPercent,
		WindowDurationMin: wire.WindowDurationMin,
		ResetsAt:          wire.ResetsAt,
	}
}

func rawScalarString(raw json.RawMessage) string {
	if len(raw) == 0 || string(raw) == "null" {
		return ""
	}
	var text string
	if json.Unmarshal(raw, &text) == nil {
		return strings.TrimSpace(text)
	}
	var number json.Number
	if json.Unmarshal(raw, &number) == nil {
		return number.String()
	}
	return ""
}

func normalizeAuthMode(raw string) string {
	value := strings.ToLower(strings.TrimSpace(raw))
	switch value {
	case "chatgpt":
		return "chatgpt"
	case "apikey", "api_key", "api-key":
		return "api_key"
	case "amazonbedrock", "amazon_bedrock", "bedrock":
		return "bedrock"
	default:
		return value
	}
}

func runtimeVersionFromUserAgent(raw string) string {
	value := strings.TrimSpace(raw)
	if value == "" {
		return ""
	}
	// Codex 与 Claude bridge 都用 product/version 形式报告实际运行进程。
	// 只提取首个版本 token，避免把平台描述等不稳定信息塞进菜单栏。
	if slash := strings.LastIndex(value, "/"); slash >= 0 && slash+1 < len(value) {
		value = value[slash+1:]
	}
	if fields := strings.Fields(value); len(fields) > 0 {
		if len(fields) > 1 {
			candidate := strings.TrimPrefix(fields[1], "v")
			if candidate != "" && candidate[0] >= '0' && candidate[0] <= '9' {
				return candidate
			}
		}
		return strings.TrimPrefix(fields[0], "v")
	}
	return ""
}

type runtimeWebSocketRPC struct {
	conn          *websocket.Conn
	nextID        int64
	notifications []runtimeWebSocketNotification
	// 状态探针需要保留通知供后续消费；handoff 只轮询单个 thread，丢弃其他
	// thread 的广播可避免长时间等待用户输入时无界积累内存。
	dropNotifications bool
}

type runtimeWebSocketFrame struct {
	ID     json.RawMessage     `json:"id"`
	Method string              `json:"method"`
	Params json.RawMessage     `json:"params"`
	Result json.RawMessage     `json:"result"`
	Error  *appserver.RPCError `json:"error"`
}

type runtimeWebSocketNotification struct {
	Method string
	Params json.RawMessage
}

func (c *runtimeWebSocketRPC) initialize(ctx context.Context) (string, error) {
	return c.initializeClient(ctx, "mimi_remote_mac_status", "Mimi Remote Mac", "0.1.0")
}

func (c *runtimeWebSocketRPC) initializeClient(ctx context.Context, name string, title string, version string) (string, error) {
	var result struct {
		UserAgent string `json:"userAgent"`
	}
	if err := c.call(ctx, "initialize", map[string]any{
		"clientInfo": map[string]any{
			"name":    name,
			"title":   title,
			"version": version,
		},
		"capabilities": map[string]any{},
	}, &result); err != nil {
		return "", err
	}
	if err := c.notify(ctx, "initialized", map[string]any{}); err != nil {
		return "", err
	}
	return result.UserAgent, nil
}

func (c *runtimeWebSocketRPC) call(ctx context.Context, method string, params any, result any) error {
	c.nextID++
	id := c.nextID
	if err := c.write(ctx, map[string]any{
		"id":     id,
		"method": method,
		"params": params,
	}); err != nil {
		return err
	}
	for {
		if err := setRuntimeWebSocketDeadline(ctx, c.conn.SetReadDeadline); err != nil {
			return err
		}
		_, payload, err := c.conn.ReadMessage()
		if err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			return err
		}
		var frame runtimeWebSocketFrame
		if json.Unmarshal(payload, &frame) != nil {
			continue
		}
		if strings.TrimSpace(frame.Method) != "" {
			// App Server 是双向 JSON-RPC。状态探针不拥有外部 Token 等宿主能力，
			// 因此不能处理服务端 request；返回标准错误后继续等待原调用的响应，
			// 避免相同 id 的服务端 request 被误判成成功 response。
			if runtimeRPCFrameHasID(frame.ID) {
				if err := c.write(ctx, map[string]any{
					"id": frame.ID,
					"error": map[string]any{
						"code":    -32601,
						"message": "runtime status client does not support server requests",
					},
				}); err != nil {
					return err
				}
			} else if !c.dropNotifications {
				c.notifications = append(c.notifications, runtimeWebSocketNotification{
					Method: frame.Method,
					Params: append(json.RawMessage(nil), frame.Params...),
				})
			}
			continue
		}
		if strings.TrimSpace(string(frame.ID)) != strconv.FormatInt(id, 10) {
			continue
		}
		if frame.Error != nil {
			return frame.Error
		}
		if len(frame.Result) == 0 {
			return errors.New("app-server RPC 响应缺少 result 或 error")
		}
		if result == nil {
			return nil
		}
		return json.Unmarshal(frame.Result, result)
	}
}

func (c *runtimeWebSocketRPC) nextNotification(ctx context.Context) (runtimeWebSocketNotification, error) {
	for {
		if len(c.notifications) > 0 {
			notification := c.notifications[0]
			c.notifications = c.notifications[1:]
			return notification, nil
		}
		if err := setRuntimeWebSocketDeadline(ctx, c.conn.SetReadDeadline); err != nil {
			return runtimeWebSocketNotification{}, err
		}
		_, payload, err := c.conn.ReadMessage()
		if err != nil {
			if ctx.Err() != nil {
				return runtimeWebSocketNotification{}, ctx.Err()
			}
			return runtimeWebSocketNotification{}, err
		}
		var frame runtimeWebSocketFrame
		if json.Unmarshal(payload, &frame) != nil || strings.TrimSpace(frame.Method) == "" {
			continue
		}
		if runtimeRPCFrameHasID(frame.ID) {
			if err := c.write(ctx, map[string]any{
				"id": frame.ID,
				"error": map[string]any{
					"code":    -32601,
					"message": "local runtime client does not support server requests",
				},
			}); err != nil {
				return runtimeWebSocketNotification{}, err
			}
			continue
		}
		return runtimeWebSocketNotification{Method: frame.Method, Params: frame.Params}, nil
	}
}

func runtimeRPCFrameHasID(id json.RawMessage) bool {
	value := strings.TrimSpace(string(id))
	return value != "" && value != "null"
}

func (c *runtimeWebSocketRPC) notify(ctx context.Context, method string, params any) error {
	return c.write(ctx, map[string]any{
		"method": method,
		"params": params,
	})
}

func (c *runtimeWebSocketRPC) write(ctx context.Context, payload any) error {
	if err := setRuntimeWebSocketDeadline(ctx, c.conn.SetWriteDeadline); err != nil {
		return err
	}
	return c.conn.WriteJSON(payload)
}

func setRuntimeWebSocketDeadline(
	ctx context.Context,
	set func(time.Time) error,
) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	deadline, ok := ctx.Deadline()
	if !ok {
		deadline = time.Now().Add(codexRuntimeProbeTimeout)
	}
	return set(deadline)
}
