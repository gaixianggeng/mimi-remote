package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
)

const (
	appServerGatewayPath        = "/api/app-server/ws"
	appServerPolicyErrorCode    = -32080
	appServerGatewayWriteWindow = 10 * time.Second
	// 个人/小团队场景通常只有 1–2 个移动端。保留重连余量，同时限制一个泄漏的 token
	// 无限建立“移动端 WS + 本机 upstream WS”连接，避免耗尽文件描述符和 goroutine。
	appServerGatewayMaxConnections = 8
	appServerGatewayThreadCacheMax = 2048
	appServerGatewayThreadCacheTTL = 24 * time.Hour
	defaultCodexReasoningEffort    = "xhigh"
	appServerMediaRedactNotifyEnv  = "AGENTD_MEDIA_REDACT_NOTIFICATIONS"

	appServerGatewayThreadTurnsDefaultLimit  = 20
	appServerGatewayThreadTurnsMaxLimit      = 50
	appServerGatewayThreadTurnsFullMaxLimit  = 20
	appServerGatewayThreadListMaxLimit       = 50
	appServerGatewayThreadSearchMaxLimit     = appServerGatewayThreadListMaxLimit
	appServerGatewayThreadSearchTermMaxBytes = 512
	appServerGatewayInitialTurnsMaxLimit     = 5
)

var (
	appServerGatewayReadLimit                     int64 = 64 << 20
	appServerGatewayPongWait                            = 60 * time.Second
	appServerGatewayPingPeriod                          = 45 * time.Second
	appServerGatewayPendingThreadTTL                    = 30 * time.Second
	appServerGatewayPendingThreadMax                    = 128
	appServerGatewayPendingClientRequestTTL             = 2 * time.Minute
	appServerGatewayPendingClientRequestMax             = 256
	appServerGatewayPendingServerRequestTTL             = 24 * time.Hour
	appServerGatewayPendingServerRequestMax             = 256
	appServerGatewayPendingHistoryRequestTTL            = 2 * time.Minute
	appServerGatewayPendingHistoryRequestMax            = 256
	appServerGatewayHistoryResponseCapBytes             = 2 << 20
	appServerGatewayHistoryBudgetWindow                 = 15 * time.Second
	appServerGatewayHistoryBudgetMaxRequests            = 6
	appServerGatewayHistoryBudgetMaxRequestBytes        = int64(64 << 10)
	appServerGatewayHistoryBudgetMaxResponseBytes       = int64(8 << 20)
	appServerGatewayHistoryGlobalMaxResponseBytes int64 = 3 << 20
	appServerGatewayHistoryGlobalWindow                 = appServerGatewayHistoryBudgetWindow
)

var appServerAllowedMethods = map[string]struct{}{
	"initialize":              {},
	"initialized":             {},
	"thread/list":             {},
	"thread/search":           {},
	"thread/start":            {},
	"thread/resume":           {},
	"thread/fork":             {},
	"thread/read":             {},
	"thread/turns/list":       {},
	"thread/name/set":         {},
	"thread/compact/start":    {},
	"thread/unsubscribe":      {},
	"thread/archive":          {},
	"thread/unarchive":        {},
	"thread/goal/get":         {},
	"thread/goal/set":         {},
	"thread/goal/clear":       {},
	"review/start":            {},
	"turn/start":              {},
	"turn/steer":              {},
	"turn/interrupt":          {},
	"model/list":              {},
	"account/rateLimits/read": {},
}

// appServerAllowedServerRequestMethods 是反向 RPC 的显式能力边界。
// app-server 新增 Server Request 时不能直接落到移动端；只有 iOS 已实现响应协议的方法才能加入这里，
// 未知方法会由 gateway 立即回错，避免上游一直等待一个移动端永远不会发出的响应。
var appServerAllowedServerRequestMethods = map[string]struct{}{
	"applyPatchApproval":                    {},
	"execCommandApproval":                   {},
	"item/commandExecution/requestApproval": {},
	"item/fileChange/requestApproval":       {},
	"item/permissions/requestApproval":      {},
	"item/tool/requestUserInput":            {},
	"mcpServer/elicitation/request":         {},
}

var appServerClaudeAllowedMethods = map[string]struct{}{
	"initialize":        {},
	"initialized":       {},
	"thread/list":       {},
	"thread/start":      {},
	"thread/resume":     {},
	"thread/read":       {},
	"thread/turns/list": {},
	"turn/start":        {},
	"turn/steer":        {},
	"turn/interrupt":    {},
	"model/list":        {},
}

type appServerConfigResponse struct {
	GatewayWSURL string                   `json:"gateway_ws_url"`
	Runtime      appServerRuntimeMetadata `json:"runtime"`
	Channels     []appServerChannel       `json:"channels,omitempty"`
	Projects     []projects.Project       `json:"projects"`
	Policy       appServerPolicyMetadata  `json:"policy"`
}

type appServerRuntimeMetadata struct {
	Type               string `json:"type"`
	Transport          string `json:"transport"`
	Managed            bool   `json:"managed"`
	GatewayAvailable   bool   `json:"gateway_available"`
	UpstreamConfigured bool   `json:"upstream_configured"`
	Running            bool   `json:"running"`
	Initialized        bool   `json:"initialized"`
	PendingRequests    int    `json:"pending_requests"`
}

type appServerChannel struct {
	ID               string                     `json:"id"`
	RuntimeID        string                     `json:"runtime_id"`
	Title            string                     `json:"title"`
	Provider         string                     `json:"provider"`
	Type             string                     `json:"type"`
	Protocol         string                     `json:"protocol"`
	GatewayWSURL     string                     `json:"gateway_ws_url"`
	GatewayAvailable bool                       `json:"gateway_available"`
	Managed          bool                       `json:"managed"`
	Experimental     bool                       `json:"experimental,omitempty"`
	Lifecycle        string                     `json:"lifecycle,omitempty"`
	Bridge           *appServerBridgeMetadata   `json:"bridge,omitempty"`
	Methods          []string                   `json:"methods,omitempty"`
	Capabilities     appServerChannelCapability `json:"capabilities,omitempty"`
	Policy           appServerChannelPolicy     `json:"policy,omitempty"`
}

type appServerBridgeMetadata struct {
	Name           string `json:"name"`
	Version        string `json:"version,omitempty"`
	Path           string `json:"path,omitempty"`
	Status         string `json:"status"`
	Healthy        bool   `json:"healthy"`
	LastProbeError string `json:"last_probe_error,omitempty"`
}

type appServerChannelCapability struct {
	Streaming        bool `json:"streaming"`
	History          bool `json:"history"`
	ApprovalRequests bool `json:"approval_requests"`
	FileDiffs        bool `json:"file_diffs"`
	Goals            bool `json:"goals"`
	Archive          bool `json:"archive"`
	Fork             bool `json:"fork"`
	Rename           bool `json:"rename"`
	Compact          bool `json:"compact"`
	Review           bool `json:"review"`
	RateLimits       bool `json:"rate_limits"`
}

type appServerChannelPolicy struct {
	ApprovalPolicies []string `json:"approval_policies,omitempty"`
	SandboxModes     []string `json:"sandbox_modes,omitempty"`
	NetworkAccess    bool     `json:"network_access"`
	CWDScope         string   `json:"cwd_scope"`
}

type appServerPolicyMetadata struct {
	AllowedMethods []string `json:"allowed_methods"`
	ProjectsSource string   `json:"projects_source"`
}

type appServerDiagnosticsProvider interface {
	AppServerDiagnostics() appserver.Diagnostics
}

type appServerGatewayFrame struct {
	ID     *json.RawMessage `json:"id,omitempty"`
	Method string           `json:"method,omitempty"`
	Params json.RawMessage  `json:"params,omitempty"`
	Result json.RawMessage  `json:"result,omitempty"`
	Error  json.RawMessage  `json:"error,omitempty"`
}

type appServerGatewayPolicyError struct {
	id                     *json.RawMessage
	message                string
	data                   map[string]any
	target                 string
	historyResponseBlocked bool
	historyBudgetRejected  bool
}

type appServerGatewayPolicy struct {
	router    *Router
	runtimeID string
	mu        sync.Mutex
	closed    bool

	pendingThreads        map[string]appServerGatewayPendingThreadRequest
	pendingClientRequests map[string]appServerGatewayPendingClientRequest
	pendingServerRequests map[string]appServerGatewayPendingServerRequest
	pendingHistory        map[string]appServerGatewayPendingHistoryRequest
	historyBudgets        map[string]appServerGatewayHistoryBudget
	allowedThreads        map[string]appServerGatewayAllowedThread
	beforePendingRemember func()
	beforeManagedComplete func()
}

type appServerGatewayPendingThreadRequest struct {
	method              string
	cwd                 string
	scopeID             string
	responseLimit       int64
	responseLimitSet    bool
	managedWorktreePath string
	createdAt           time.Time
}

type appServerGatewayPendingClientRequest struct {
	method    string
	createdAt time.Time
}

type appServerGatewayPendingServerRequest struct {
	method    string
	createdAt time.Time
}

type appServerGatewayPendingHistoryRequest struct {
	method            string
	threadID          string
	cwd               string
	cursor            string
	limit             int64
	sortDirection     string
	itemsView         string
	useStateDBOnly    string
	filterFingerprint string
	includeTurns      bool
	fingerprint       string
	inflightOwner     string
	// redactOnly 请求（thread/resume）只做图片改写，不记预算、不做 cap 阻断：
	// resume 是发消息前的绑定步骤，被阻断会直接废掉大线程的消息发送。
	redactOnly bool
	createdAt  time.Time
}

type appServerGatewayHistoryBudget struct {
	windowStarted time.Time
	requests      int
	requestBytes  int64
	responseBytes int64
	blockedUntil  time.Time
}

type appServerGatewayValidatedParams struct {
	cwd                        string
	hasCWD                     bool
	cwdScope                   gatewayScope
	cwdScopeOK                 bool
	pendingManagedWorktreePath string
}

// gatewayScope 描述一个 cwd 的授权来源。命中 projects allowlist 时是项目作用域，
// 线程可以在同一项目内的子目录间工作；命中 browse_roots 时是“精确目录”作用域，
// scope id 取该目录 canonical 路径的 workspace hash，线程被绑定到这一个目录，
// turn/start 切到 sibling 目录（如 ~/finance → ~/Documents）会因 scope id 不同被拒。
type gatewayScope struct {
	id       string
	realPath string
	project  projects.Project
	browse   bool
	managed  bool
}

type appServerGatewayAllowedThread struct {
	id        string
	runtimeID string
	cwd       string
	scopeID   string
	lastSeen  time.Time
}

type appServerGatewayThreadWire struct {
	ID        string `json:"id"`
	ThreadID  string `json:"threadId"`
	SessionID string `json:"sessionId"`
	CWD       string `json:"cwd"`
	Path      string `json:"path"`
}

func (r *Router) appServerConfigHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	r.refreshClaudeBridgeProbeIfStale()
	projectList := r.projects.List()
	runtimeMeta := r.appServerRuntimeMetadata()
	log.Printf("app-server config response remote=%s host=%s projects=%d transport=%s gateway_available=%t", requestRemoteHost(req), req.Host, len(projectList), runtimeMeta.Transport, runtimeMeta.GatewayAvailable)
	writeJSON(w, http.StatusOK, appServerConfigResponse{
		GatewayWSURL: r.appServerGatewayURL(req),
		Runtime:      runtimeMeta,
		Channels:     r.appServerChannels(req),
		Projects:     projectList,
		Policy: appServerPolicyMetadata{
			AllowedMethods: appServerAllowedMethodList(),
			ProjectsSource: "agentd_allowlist",
		},
	})
}

func (r *Router) appServerRuntimeMetadata() appServerRuntimeMetadata {
	upstream, _ := r.appServerUpstreamWebSocketURL()
	meta := appServerRuntimeMetadata{
		Type:               firstNonEmpty(r.cfg.Runtime.Type, "codex_app_server"),
		Transport:          firstNonEmpty(r.cfg.AppServer.Transport, "ws"),
		Managed:            r.cfg.AppServer.Managed,
		GatewayAvailable:   upstream != "",
		UpstreamConfigured: strings.TrimSpace(r.cfg.AppServer.Listen) != "",
	}
	if provider, ok := r.runtime.(appServerDiagnosticsProvider); ok {
		// metadata 只暴露运行态计数，不返回 codex home、token 或 stderr 等敏感细节。
		diag := provider.AppServerDiagnostics()
		meta.Running = diag.Running
		meta.Initialized = diag.Initialized
		meta.PendingRequests = diag.PendingRequests
	}
	return meta
}

func appServerAllowedMethodList() []string {
	return appServerAllowedMethodListForRuntime("codex")
}

func appServerAllowedMethodListForRuntime(runtimeID string) []string {
	allowed := appServerAllowedMethodsForRuntime(runtimeID)
	methods := make([]string, 0, len(allowed))
	for method := range allowed {
		methods = append(methods, method)
	}
	sort.Strings(methods)
	return methods
}

func appServerAllowedMethodsForRuntime(runtimeID string) map[string]struct{} {
	if normalizeAppServerRuntimeID(runtimeID) == "claude" {
		return appServerClaudeAllowedMethods
	}
	return appServerAllowedMethods
}

func (r *Router) appServerGatewayURL(req *http.Request) string {
	return r.appServerGatewayURLForRuntime(req, "codex")
}

func (r *Router) appServerGatewayURLForRuntime(req *http.Request, runtimeID string) string {
	scheme := "ws"
	if req.TLS != nil || strings.EqualFold(req.Header.Get("X-Forwarded-Proto"), "https") {
		scheme = "wss"
	}
	host := req.Host
	if strings.TrimSpace(host) == "" {
		host = r.cfg.Listen
	}
	values := url.Values{}
	if runtimeID = normalizeAppServerRuntimeID(runtimeID); runtimeID != "" && runtimeID != "codex" {
		values.Set("runtime", runtimeID)
	}
	return (&url.URL{Scheme: scheme, Host: host, Path: appServerGatewayPath, RawQuery: values.Encode()}).String()
}

func (r *Router) appServerChannels(req *http.Request) []appServerChannel {
	codexUpstream, _ := r.appServerUpstreamWebSocketURL()
	channels := []appServerChannel{{
		ID:               "codex",
		RuntimeID:        "codex",
		Title:            "Codex",
		Provider:         "openai",
		Type:             "codex_app_server",
		Protocol:         "app_server_jsonrpc_ws",
		GatewayWSURL:     r.appServerGatewayURLForRuntime(req, "codex"),
		GatewayAvailable: codexUpstream != "",
		Managed:          r.cfg.AppServer.Managed,
		Methods:          appServerAllowedMethodList(),
		Capabilities: appServerChannelCapability{
			Streaming:        true,
			History:          true,
			ApprovalRequests: true,
			FileDiffs:        true,
			Goals:            true,
			Archive:          true,
			Fork:             true,
			Rename:           true,
			Compact:          true,
			Review:           true,
			RateLimits:       true,
		},
		Policy: appServerChannelPolicy{
			ApprovalPolicies: []string{"on-request", "on-failure"},
			SandboxModes:     []string{"read-only", "workspace-write", "danger-full-access"},
			NetworkAccess:    false,
			CWDScope:         "agentd_allowlist",
		},
	}}
	if r.cfg.Claude.Enabled {
		probe := r.claudeBridgeProbe()
		channels = append(channels, appServerChannel{
			ID:               "claude",
			RuntimeID:        "claude",
			Title:            "Claude Code",
			Provider:         "anthropic",
			Type:             "claude_code_bridge",
			Protocol:         "app_server_jsonrpc_stdio_v1",
			GatewayWSURL:     r.appServerGatewayURLForRuntime(req, "claude"),
			GatewayAvailable: probe.Healthy,
			Managed:          false,
			Experimental:     true,
			Lifecycle:        "per_connection",
			Bridge: &appServerBridgeMetadata{
				Name:           "alleycat-claude-bridge",
				Version:        probe.Version,
				Path:           probe.Path,
				Status:         probe.Status,
				Healthy:        probe.Healthy,
				LastProbeError: probe.Error,
			},
			Methods: appServerAllowedMethodListForRuntime("claude"),
			Capabilities: appServerChannelCapability{
				Streaming:        true,
				History:          true,
				ApprovalRequests: true,
				FileDiffs:        true,
			},
			Policy: appServerChannelPolicy{
				ApprovalPolicies: []string{"on-request", "on-failure"},
				SandboxModes:     []string{"read-only", "workspace-write"},
				NetworkAccess:    false,
				CWDScope:         "agentd_allowlist",
			},
		})
	}
	return channels
}

func normalizeAppServerRuntimeID(raw string) string {
	value := strings.TrimSpace(strings.ToLower(raw))
	switch value {
	case "", "codex", "openai", "codex_app_server", "codex-app-server":
		return "codex"
	case "claude", "anthropic", "claude_code", "claude-code", "claude_code_bridge", "claude-code-bridge":
		return "claude"
	default:
		return value
	}
}

func (r *Router) appServerGatewayWS(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	if !sameOriginOrNoOrigin(req) {
		writeError(w, http.StatusForbidden, "Origin 不允许访问 app-server gateway")
		return
	}
	runtimeID := normalizeAppServerRuntimeID(req.URL.Query().Get("runtime"))
	switch runtimeID {
	case "codex":
		r.appServerCodexGatewayWS(w, req)
	case "claude":
		r.appServerClaudeGatewayWS(w, req)
	default:
		writeError(w, http.StatusBadRequest, "未知 app-server runtime："+runtimeID)
	}
}

func (r *Router) appServerCodexGatewayWS(w http.ResponseWriter, req *http.Request) {
	// 必须先验证外侧请求确实要升级 WebSocket。普通 GET 或畸形握手不能触发本机
	// app-server 拨号，否则一个有效的外侧 token 就能被用来批量消耗 upstream 连接。
	if !websocket.IsWebSocketUpgrade(req) {
		writeError(w, http.StatusBadRequest, "app-server gateway 需要 WebSocket Upgrade")
		return
	}
	if !r.acquireCodexGatewaySlot() {
		w.Header().Set("Retry-After", "1")
		writeError(w, http.StatusTooManyRequests, "Codex gateway 连接数已达上限，请稍后重试")
		return
	}
	defer r.releaseCodexGatewaySlot()

	upstreamURL, err := r.appServerUpstreamWebSocketURL()
	if err != nil {
		// 底层错误可能带配置内容；外侧只返回可操作但不泄漏本机信息的固定文案。
		writeError(w, http.StatusServiceUnavailable, "Codex app-server 上游配置不可用，请在电脑运行 agentd doctor")
		return
	}
	upstreamHeaders, err := r.appServerUpstreamHeaders()
	if err != nil {
		// token file 错误通常含电脑绝对路径，不能回显给移动端。
		writeError(w, http.StatusServiceUnavailable, "Codex app-server 上游鉴权不可用，请在电脑运行 agentd doctor")
		return
	}

	client, err := r.upgrader.Upgrade(w, req, nil)
	if err != nil {
		log.Printf("app-server gateway ws upgrade failed err=%v", err)
		return
	}
	defer client.Close()

	// 上游是 loopback app-server，就绪时握手是亚毫秒级；冷启动上游还没起来时，端口未监听会立刻
	// ECONNREFUSED，只有“端口已开但还没接受握手”才会卡到这里。把超时收紧到 4s，让 iPad 端能更快
	// 收到可重试错误，而不是每次都白等 10s。外侧握手已完成后才拨号，确保畸形握手不会占用 upstream。
	dialer := websocket.Dialer{HandshakeTimeout: 4 * time.Second}
	dialStart := time.Now()
	upstream, _, err := dialer.DialContext(req.Context(), upstreamURL, upstreamHeaders)
	dialDuration := time.Since(dialStart)
	if err != nil {
		r.monitor.recordGatewayDialFailure(dialDuration, err)
		writeCodexGatewayRuntimeError(client, "CODEX_UPSTREAM_UNAVAILABLE", "Codex app-server 暂时不可用，请稍后重试")
		return
	}
	defer upstream.Close()

	log.Printf("app-server gateway connected upstream=%s", sanitizeGatewayURL(upstreamURL))
	monitor := r.monitor.startGatewayConnection(requestRemoteHost(req), req.Host, sanitizeGatewayURL(upstreamURL), dialDuration)
	r.proxyAppServerGateway(req.Context(), client, upstream, monitor)
}

func (r *Router) acquireCodexGatewaySlot() bool {
	r.codexGatewayMu.Lock()
	defer r.codexGatewayMu.Unlock()
	if r.activeCodexGateway >= appServerGatewayMaxConnections {
		return false
	}
	r.activeCodexGateway++
	return true
}

func (r *Router) releaseCodexGatewaySlot() {
	r.codexGatewayMu.Lock()
	if r.activeCodexGateway > 0 {
		r.activeCodexGateway--
	}
	r.codexGatewayMu.Unlock()
}

func writeCodexGatewayRuntimeError(conn *websocket.Conn, code string, message string) {
	payload, err := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"id":      nil,
		"error": map[string]any{
			"code":    appServerPolicyErrorCode,
			"message": code + ": " + message,
		},
	})
	if err != nil {
		return
	}
	_ = conn.SetWriteDeadline(time.Now().Add(appServerGatewayWriteWindow))
	_ = conn.WriteMessage(websocket.TextMessage, payload)
}

func (r *Router) appServerUpstreamWebSocketURL() (string, error) {
	raw := strings.TrimSpace(r.cfg.AppServer.Listen)
	if raw == "" {
		return "", fmt.Errorf("app_server.listen 未配置，无法启用 app-server raw gateway")
	}
	if !strings.Contains(raw, "://") {
		raw = "ws://" + raw
	}
	parsed, err := url.Parse(raw)
	if err != nil {
		return "", fmt.Errorf("app_server.listen 不是合法 URL：%w", err)
	}
	switch parsed.Scheme {
	case "ws", "wss":
	case "http":
		parsed.Scheme = "ws"
	case "https":
		parsed.Scheme = "wss"
	default:
		return "", fmt.Errorf("app_server.listen 仅支持 ws/wss/http/https")
	}
	if parsed.Host == "" {
		return "", fmt.Errorf("app_server.listen 缺少 host")
	}
	if !isLoopbackGatewayHost(parsed.Hostname()) {
		return "", fmt.Errorf("app_server.listen 只允许 loopback upstream")
	}
	if parsed.Path == "" {
		parsed.Path = "/"
	}
	return parsed.String(), nil
}

func isLoopbackGatewayHost(host string) bool {
	host = strings.TrimSpace(host)
	if host == "" {
		return false
	}
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func (r *Router) appServerUpstreamHeaders() (http.Header, error) {
	tokenFile := strings.TrimSpace(r.cfg.AppServer.WSTokenFile)
	if tokenFile == "" {
		if r.cfg.AppServer.Managed {
			return nil, fmt.Errorf("app_server.ws_token_file 未配置；managed app-server 必须使用独立 upstream token")
		}
		return nil, nil
	}
	raw, err := os.ReadFile(tokenFile)
	if err != nil {
		return nil, fmt.Errorf("读取 app_server.ws_token_file 失败：%w", err)
	}
	token := strings.TrimSpace(string(raw))
	if token == "" {
		return nil, fmt.Errorf("app_server.ws_token_file 为空")
	}
	headers := http.Header{}
	// app-server upstream capability token 和 iPad 访问 agentd 的 token 分离，避免把外侧 token 复用到本机上游。
	headers.Set("Authorization", "Bearer "+token)
	return headers, nil
}

func (r *Router) proxyAppServerGateway(ctx context.Context, client *websocket.Conn, upstream *websocket.Conn, monitor *relayGatewayConnMonitor) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	done := make(chan string, 3)
	var clientWriteMu sync.Mutex
	var upstreamWriteMu sync.Mutex
	configureGatewayReadConn(client)
	configureGatewayReadConn(upstream)
	policy := &appServerGatewayPolicy{
		router:                r,
		runtimeID:             "codex",
		pendingThreads:        map[string]appServerGatewayPendingThreadRequest{},
		pendingClientRequests: map[string]appServerGatewayPendingClientRequest{},
		pendingServerRequests: map[string]appServerGatewayPendingServerRequest{},
		pendingHistory:        map[string]appServerGatewayPendingHistoryRequest{},
		historyBudgets:        map[string]appServerGatewayHistoryBudget{},
		allowedThreads:        map[string]appServerGatewayAllowedThread{},
	}
	defer policy.releaseAllHistoryInflight()
	defer policy.close()

	go func() {
		done <- r.copyClientFramesToAppServer(client, upstream, &clientWriteMu, &upstreamWriteMu, policy, monitor)
	}()
	go func() {
		done <- copyWebSocketFrames(ctx, upstream, client, &upstreamWriteMu, &clientWriteMu, policy, monitor)
	}()
	go func() {
		done <- pingGatewayConnections(ctx, client, upstream, &clientWriteMu, &upstreamWriteMu)
	}()

	reason := <-done
	cancel()
	_ = client.Close()
	_ = upstream.Close()
	monitor.finish(reason)
}

func configureGatewayReadConn(conn *websocket.Conn) {
	conn.SetReadLimit(appServerGatewayReadLimit)
	_ = conn.SetReadDeadline(time.Now().Add(appServerGatewayPongWait))
	conn.SetPongHandler(func(string) error {
		return conn.SetReadDeadline(time.Now().Add(appServerGatewayPongWait))
	})
}

func pingGatewayConnections(ctx context.Context, client *websocket.Conn, upstream *websocket.Conn, clientWriteMu *sync.Mutex, upstreamWriteMu *sync.Mutex) string {
	ticker := time.NewTicker(appServerGatewayPingPeriod)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return "context_done"
		case <-ticker.C:
			deadline := time.Now().Add(appServerGatewayWriteWindow)
			if err := writeWebSocketControl(client, clientWriteMu, websocket.PingMessage, nil, deadline); err != nil {
				return gatewayCloseReason("client_ping_write", err)
			}
			if err := writeWebSocketControl(upstream, upstreamWriteMu, websocket.PingMessage, nil, deadline); err != nil {
				return gatewayCloseReason("upstream_ping_write", err)
			}
		}
	}
}

func (r *Router) copyClientFramesToAppServer(client *websocket.Conn, upstream *websocket.Conn, clientWriteMu *sync.Mutex, upstreamWriteMu *sync.Mutex, policy *appServerGatewayPolicy, monitor *relayGatewayConnMonitor) string {
	for {
		messageType, payload, err := client.ReadMessage()
		if err != nil {
			return gatewayCloseReason("client_read", err)
		}
		policyStart := time.Now()
		forwardPayload, policyErr := policy.validateClientFrame(messageType, payload)
		policyDuration := time.Since(policyStart)
		if policyErr != nil {
			monitor.recordPolicyError("client_to_upstream", len(payload), policyDuration)
			if policyErr.historyBudgetRejected {
				monitor.recordHistoryBudgetRejected()
			}
			// 非法请求只回 JSON-RPC error，不把高危帧送到 app-server。
			if !writeGatewayPolicyError(client, clientWriteMu, policyErr) {
				return "client_policy_error_write_failed"
			}
			continue
		}
		requestID := monitor.beginRPCRequest(forwardPayload, len(forwardPayload))
		writeStart := time.Now()
		if err := writeWebSocketFrame(upstream, upstreamWriteMu, messageType, forwardPayload); err != nil {
			monitor.cancelRPCRequest(requestID)
			return gatewayCloseReason("upstream_write", err)
		}
		monitor.recordForward("client_to_upstream", len(payload), len(forwardPayload), policyDuration, time.Since(writeStart), forwardPayload)
	}
}

func copyWebSocketFrames(ctx context.Context, from *websocket.Conn, to *websocket.Conn, fromWriteMu *sync.Mutex, toWriteMu *sync.Mutex, policy *appServerGatewayPolicy, monitor *relayGatewayConnMonitor) string {
	for {
		select {
		case <-ctx.Done():
			return "context_done"
		default:
		}
		messageType, payload, err := from.ReadMessage()
		if err != nil {
			return gatewayCloseReason("upstream_read", err)
		}
		policyStart := time.Now()
		forwardPayload, forward, policyErr := policy.observeUpstreamFrame(messageType, payload)
		policyDuration := time.Since(policyStart)
		if policyErr != nil {
			monitor.recordPolicyError("upstream_to_client", len(payload), policyDuration)
			if policyErr.historyResponseBlocked {
				monitor.recordHistoryResponseBlocked(len(payload), payload)
			}
			if policyErr.target == "client" {
				if !writeGatewayPolicyError(to, toWriteMu, policyErr) {
					return "client_policy_error_write_failed"
				}
			} else if !writeGatewayPolicyError(from, fromWriteMu, policyErr) {
				return "upstream_policy_error_write_failed"
			}
			continue
		}
		if !forward {
			monitor.recordDropped("upstream_to_client", len(payload), policyDuration)
			continue
		}
		writeStart := time.Now()
		if err := writeWebSocketFrame(to, toWriteMu, messageType, forwardPayload); err != nil {
			return gatewayCloseReason("client_write", err)
		}
		monitor.recordForward("upstream_to_client", len(payload), len(forwardPayload), policyDuration, time.Since(writeStart), forwardPayload)
	}
}

func writeWebSocketFrame(conn *websocket.Conn, mu *sync.Mutex, messageType int, payload []byte) error {
	if mu != nil {
		mu.Lock()
		defer mu.Unlock()
	}
	_ = conn.SetWriteDeadline(time.Now().Add(appServerGatewayWriteWindow))
	return conn.WriteMessage(messageType, payload)
}

func writeWebSocketControl(conn *websocket.Conn, mu *sync.Mutex, messageType int, payload []byte, deadline time.Time) error {
	if mu != nil {
		mu.Lock()
		defer mu.Unlock()
	}
	return conn.WriteControl(messageType, payload, deadline)
}

func (p *appServerGatewayPolicy) validateClientFrame(messageType int, payload []byte) ([]byte, *appServerGatewayPolicyError) {
	if p.isClosed() {
		return nil, &appServerGatewayPolicyError{message: "app-server gateway 连接已关闭"}
	}
	if messageType != websocket.TextMessage {
		return nil, &appServerGatewayPolicyError{message: "app-server gateway 只允许 JSON text frame"}
	}
	var frame appServerGatewayFrame
	if err := json.Unmarshal(payload, &frame); err != nil {
		return nil, &appServerGatewayPolicyError{message: "JSON-RPC frame 无效"}
	}
	method := strings.TrimSpace(frame.Method)
	if method == "" {
		if frame.ID != nil && (len(frame.Result) > 0 || len(frame.Error) > 0) {
			rewritten, err := p.validateClientResponse(payload, &frame)
			if err != nil {
				return nil, &appServerGatewayPolicyError{id: frame.ID, message: err.Error()}
			}
			return rewritten, nil
		}
		return nil, &appServerGatewayPolicyError{id: frame.ID, message: "JSON-RPC frame 缺少 method"}
	}
	if method != "initialized" && frame.ID == nil {
		return nil, &appServerGatewayPolicyError{message: "app-server request 必须包含 id"}
	}
	if !p.methodAllowed(method) {
		return nil, &appServerGatewayPolicyError{id: frame.ID, message: "app-server method 不允许：" + method}
	}
	params, err := decodeGatewayParams(frame.Params)
	if err != nil {
		return nil, &appServerGatewayPolicyError{id: frame.ID, message: err.Error()}
	}
	validated, err := p.router.validateGatewayPolicyParams(normalizeAppServerRuntimeID(p.runtimeID), method, params)
	if err != nil {
		return nil, &appServerGatewayPolicyError{id: frame.ID, message: err.Error()}
	}
	if err := p.validateThreadCapability(&frame, method, params, validated); err != nil {
		p.router.releaseManagedWorktreePendingUse(validated.pendingManagedWorktreePath)
		return nil, &appServerGatewayPolicyError{id: frame.ID, message: err.Error()}
	}
	if policyErr := p.reserveHistoryRequest(frame.ID, method, params, len(payload)); policyErr != nil {
		p.forgetPending(frame.ID)
		return nil, policyErr
	}
	rewritten, err := rewriteGatewaySafeDefaults(payload, normalizeAppServerRuntimeID(p.runtimeID), method, params, validated)
	if err != nil {
		p.cancelPendingHistoryRequest(frame.ID)
		p.forgetPending(frame.ID)
		return nil, &appServerGatewayPolicyError{id: frame.ID, message: err.Error()}
	}
	if frame.ID != nil && normalizeAppServerRuntimeID(p.runtimeID) == "claude" && method == "model/list" {
		if err := p.rememberPendingClientRequest(frame.ID, method); err != nil {
			return nil, &appServerGatewayPolicyError{id: frame.ID, message: err.Error()}
		}
	}
	if p.isClosed() {
		p.cancelPendingHistoryRequest(frame.ID)
		p.forgetPending(frame.ID)
		return nil, &appServerGatewayPolicyError{id: frame.ID, message: "app-server gateway 连接已关闭"}
	}
	logGatewayForwardedClientTurnSummary(method, rewritten)
	return rewritten, nil
}

func (p *appServerGatewayPolicy) methodAllowed(method string) bool {
	_, ok := appServerAllowedMethodsForRuntime(p.runtimeID)[method]
	return ok
}

func (p *appServerGatewayPolicy) validateThreadCapability(frame *appServerGatewayFrame, method string, params map[string]any, validated appServerGatewayValidatedParams) error {
	cwd := validated.cwd
	scope := validated.cwdScope
	scopeOK := validated.cwdScopeOK

	switch method {
	case "thread/list", "thread/start":
		if method == "thread/list" {
			if err := validateGatewayThreadListParams(params); err != nil {
				return err
			}
		}
		if err := p.rememberPendingThreadResponseWithManagedUse(frame.ID, method, cwd, scope.id, validated.pendingManagedWorktreePath); err != nil {
			return err
		}
	case "thread/search":
		if err := validateGatewayThreadSearchParams(params); err != nil {
			return err
		}
		limit := int64(0)
		limitSet := false
		if value, ok := params["limit"]; ok && value != nil {
			limit, _ = gatewayJSONNumberInt64(value)
			limitSet = true
		}
		if err := p.rememberPendingThreadSearchResponse(frame.ID, limit, limitSet); err != nil {
			return err
		}
	case "thread/resume":
		if err := validateGatewayThreadResumeParams(params); err != nil {
			return err
		}
		threadID, ok := gatewayStringParam(params, "threadId")
		if !ok {
			return fmt.Errorf("%s.threadId 不能为空", method)
		}
		thread, ok := p.allowedThread(threadID)
		if !ok {
			return fmt.Errorf("%s.threadId 未由当前 gateway 连接授权", method)
		}
		if !scopeOK || scope.id != thread.scopeID {
			return fmt.Errorf("%s.cwd 必须匹配已授权 thread 的工作区", method)
		}
		if err := p.rememberPendingThreadResponseWithManagedUse(frame.ID, method, cwd, scope.id, validated.pendingManagedWorktreePath); err != nil {
			return err
		}
	case "thread/fork":
		threadID, ok := gatewayStringParam(params, "threadId")
		if !ok {
			return fmt.Errorf("%s.threadId 不能为空", method)
		}
		if _, ok := p.allowedThread(threadID); !ok {
			return fmt.Errorf("%s.threadId 未由当前 gateway 连接授权", method)
		}
		if !scopeOK {
			return fmt.Errorf("%s.cwd 必须来自已授权工作区", method)
		}
		if err := p.rememberPendingThreadResponseWithManagedUse(frame.ID, method, cwd, scope.id, validated.pendingManagedWorktreePath); err != nil {
			return err
		}
	case "thread/read", "thread/turns/list", "thread/name/set", "thread/compact/start", "thread/unsubscribe",
		"thread/goal/get", "thread/goal/set", "thread/goal/clear", "review/start":
		threadID, ok := gatewayStringParam(params, "threadId")
		if !ok {
			return fmt.Errorf("%s.threadId 不能为空", method)
		}
		if _, ok := p.allowedThread(threadID); !ok {
			return fmt.Errorf("%s.threadId 未由当前 gateway 连接授权", method)
		}
		if method == "thread/read" {
			if err := p.rememberPendingThreadResponse(frame.ID, method, "", ""); err != nil {
				return err
			}
		}
		if method == "thread/turns/list" {
			if err := validateGatewayThreadTurnsListParams(params); err != nil {
				return err
			}
		}
		if method == "thread/goal/set" {
			if err := validateGatewayGoalSetParams(params); err != nil {
				return err
			}
		}
		if method == "thread/name/set" {
			if err := validateGatewayThreadSetNameParams(params); err != nil {
				return err
			}
		}
		if method == "review/start" {
			if err := validateGatewayReviewStartParams(params); err != nil {
				return err
			}
		}
	case "thread/archive", "thread/unarchive":
		threadID, ok := gatewayStringParam(params, "threadId")
		if !ok {
			return fmt.Errorf("%s.threadId 不能为空", method)
		}
		if _, ok := p.allowedThread(threadID); !ok {
			return fmt.Errorf("%s.threadId 未由当前 gateway 连接授权", method)
		}
	case "turn/start":
		threadID, ok := gatewayStringParam(params, "threadId")
		if !ok {
			return fmt.Errorf("%s.threadId 不能为空", method)
		}
		thread, ok := p.allowedThread(threadID)
		if !ok {
			return fmt.Errorf("%s.threadId 未由当前 gateway 连接授权", method)
		}
		// 项目作用域：同项目内目录都可用；browse 作用域：scope id 是 canonical cwd 的
		// hash，等价于精确目录绑定，不允许切到允许根下的 sibling 目录。
		if !scopeOK || scope.id != thread.scopeID {
			return fmt.Errorf("%s.cwd 必须匹配已授权 thread 的工作区", method)
		}
	case "turn/steer":
		threadID, ok := gatewayStringParam(params, "threadId")
		if !ok {
			return fmt.Errorf("%s.threadId 不能为空", method)
		}
		thread, ok := p.allowedThread(threadID)
		if !ok {
			return fmt.Errorf("%s.threadId 未由当前 gateway 连接授权", method)
		}
		if _, ok := gatewayStringParam(params, "expectedTurnId"); !ok {
			return fmt.Errorf("%s.expectedTurnId 不能为空", method)
		}
		if err := p.validateThreadInputPaths(method, params, thread); err != nil {
			return err
		}
	case "turn/interrupt":
		threadID, ok := gatewayStringParam(params, "threadId")
		if !ok {
			return fmt.Errorf("%s.threadId 不能为空", method)
		}
		if _, ok := p.allowedThread(threadID); !ok {
			return fmt.Errorf("%s.threadId 未由当前 gateway 连接授权", method)
		}
	}
	return nil
}

func (p *appServerGatewayPolicy) validateThreadInputPaths(method string, params map[string]any, thread appServerGatewayAllowedThread) error {
	inputPaths, err := collectUserInputPaths(method, params)
	if err != nil {
		return err
	}
	if len(inputPaths) == 0 {
		return nil
	}
	var scope gatewayScope
	var scopeOK bool
	if strings.TrimSpace(thread.cwd) != "" {
		scope, scopeOK = p.router.gatewayScopeForPath(thread.cwd)
	}
	for _, path := range inputPaths {
		if _, ok := p.router.projectForGatewayPath(path); ok {
			continue
		}
		// turn/steer 不携带 cwd，只能根据已授权 thread 的 cwd 还原 browse/worktree 精确边界。
		if scopeOK && scope.id == thread.scopeID && (scope.browse || scope.managed) && gatewayScopeContainsPath(scope, path) {
			continue
		}
		return fmt.Errorf("%s.input path 必须来自 projects allowlist", method)
	}
	return nil
}

func (p *appServerGatewayPolicy) validateClientResponse(payload []byte, frame *appServerGatewayFrame) ([]byte, error) {
	if frame.ID == nil {
		return nil, fmt.Errorf("JSON-RPC response 缺少 id")
	}
	request, ok := p.consumePendingServerRequest(frame.ID)
	if !ok {
		return nil, fmt.Errorf("JSON-RPC response id 未由 app-server 发起")
	}
	if len(frame.Error) > 0 {
		return payload, nil
	}
	if len(frame.Result) == 0 {
		return nil, fmt.Errorf("JSON-RPC response 缺少 result")
	}
	if !isPermissionsApprovalMethod(request.method) {
		return payload, nil
	}
	return rewriteGatewayPermissionsApprovalResponse(payload)
}

func rewriteGatewayPermissionsApprovalResponse(payload []byte) ([]byte, error) {
	var frame map[string]any
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.UseNumber()
	if err := decoder.Decode(&frame); err != nil {
		return nil, fmt.Errorf("JSON-RPC response 无效")
	}
	frame["result"] = map[string]any{
		"permissions":      map[string]any{},
		"scope":            "turn",
		"strictAutoReview": true,
	}
	delete(frame, "error")
	rewritten, err := json.Marshal(frame)
	if err != nil {
		return nil, fmt.Errorf("重写 permissions approval response 失败：%w", err)
	}
	return rewritten, nil
}

func isPermissionsApprovalMethod(method string) bool {
	return strings.Contains(strings.ToLower(strings.TrimSpace(method)), "permissions/requestapproval")
}

func rewriteGatewaySafeDefaults(payload []byte, runtimeID string, method string, params map[string]any, validated appServerGatewayValidatedParams) ([]byte, error) {
	var sanitized map[string]any
	switch method {
	case "initialize":
		sanitized = sanitizedGatewayInitializeParams(params)
	case "initialized", "model/list", "account/rateLimits/read":
		sanitized = map[string]any{}
	case "thread/list":
		sanitized = sanitizedGatewayThreadListParams(params)
	case "thread/search":
		sanitized = sanitizedGatewayThreadSearchParams(params)
	case "thread/read":
		sanitized = copyGatewayParams(params, "threadId", "includeTurns")
	case "thread/turns/list":
		sanitized = sanitizedGatewayThreadTurnsListParams(params)
	case "thread/goal/get", "thread/goal/clear":
		sanitized = copyGatewayParams(params, "threadId")
	case "thread/goal/set":
		sanitized = sanitizedGatewayGoalSetParams(params)
	case "thread/name/set":
		sanitized = copyGatewayParams(params, "threadId", "name")
	case "thread/compact/start", "thread/unsubscribe":
		sanitized = copyGatewayParams(params, "threadId")
	case "thread/archive", "thread/unarchive":
		sanitized = copyGatewayParams(params, "threadId")
	case "review/start":
		sanitized = sanitizedGatewayReviewStartParams(params)
	case "thread/start", "thread/resume", "thread/fork":
		sanitized = sanitizedGatewayThreadParams(runtimeID, method, params)
	case "turn/start":
		sanitized = sanitizedGatewayTurnParams(runtimeID, params, validated.cwd)
	case "turn/steer":
		sanitized = sanitizedGatewayTurnSteerParams(params)
	case "turn/interrupt":
		sanitized = copyGatewayParams(params, "threadId", "turnId")
	default:
		return payload, nil
	}
	if reflect.DeepEqual(params, sanitized) {
		return payload, nil
	}
	var frame map[string]any
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.UseNumber()
	if err := decoder.Decode(&frame); err != nil {
		return nil, fmt.Errorf("JSON-RPC frame 无效")
	}
	frame["params"] = sanitized
	rewritten, err := json.Marshal(frame)
	if err != nil {
		return nil, fmt.Errorf("重写 app-server 安全参数失败：%w", err)
	}
	return rewritten, nil
}

func sanitizedGatewayGoalSetParams(params map[string]any) map[string]any {
	// 目标本身由 Codex app-server 管理；gateway 只保留协议字段，避免把移动端额外配置透传到运行时。
	safe := copyGatewayParams(params, "threadId", "objective", "status", "tokenBudget")
	if _, ok := params["tokenBudget"]; !ok {
		if value, ok := params["token_budget"]; ok {
			safe["tokenBudget"] = value
		}
	}
	return safe
}

func validateGatewayThreadSetNameParams(params map[string]any) error {
	name, ok := gatewayStringParam(params, "name")
	if !ok {
		return fmt.Errorf("thread/name/set.name 必须是非空字符串")
	}
	// 名称只是列表展示字段，限制到足够日常使用的长度，避免移动端误把正文当作标题上传。
	if len(name) > 256 {
		return fmt.Errorf("thread/name/set.name 不能超过 256 bytes")
	}
	return nil
}

func validateGatewayReviewStartParams(params map[string]any) error {
	if delivery, exists := params["delivery"]; exists && delivery != nil {
		value, ok := delivery.(string)
		if !ok || strings.TrimSpace(value) != "inline" {
			// detached 会创建一个新 thread；第一批先只开放原 thread 内 review，避免绕过 thread 授权登记。
			return fmt.Errorf("review/start.delivery 只允许 inline")
		}
	}
	target, ok := params["target"].(map[string]any)
	if !ok {
		return fmt.Errorf("review/start.target 必须是对象")
	}
	targetType, ok := gatewayStringParam(target, "type")
	if !ok {
		return fmt.Errorf("review/start.target.type 不能为空")
	}
	requireNonEmptyString := func(key string) error {
		if _, ok := gatewayStringParam(target, key); !ok {
			return fmt.Errorf("review/start.target.%s 不能为空", key)
		}
		return nil
	}
	switch targetType {
	case "uncommittedChanges":
		return nil
	case "baseBranch":
		return requireNonEmptyString("branch")
	case "commit":
		if err := requireNonEmptyString("sha"); err != nil {
			return err
		}
		if title, exists := target["title"]; exists && title != nil {
			if _, ok := title.(string); !ok {
				return fmt.Errorf("review/start.target.title 必须是字符串或 null")
			}
		}
		return nil
	case "custom":
		// custom 等价于一段自由提示词，会绕过 turn/start 对沙盒和审批参数的统一改写。
		return fmt.Errorf("review/start.target.type 不允许远程使用：custom")
	default:
		return fmt.Errorf("review/start.target.type 不支持：%s", targetType)
	}
}

func sanitizedGatewayReviewStartParams(params map[string]any) map[string]any {
	target, _ := params["target"].(map[string]any)
	targetType, _ := gatewayStringParam(target, "type")
	safeTarget := map[string]any{"type": targetType}
	switch targetType {
	case "baseBranch":
		copyGatewayParam(safeTarget, target, "branch")
	case "commit":
		copyGatewayParam(safeTarget, target, "sha")
		copyGatewayParam(safeTarget, target, "title")
	}
	return map[string]any{
		"threadId": params["threadId"],
		"target":   safeTarget,
		// 强制 inline，确保响应不会产生一个尚未进入 gateway 授权缓存的新 thread。
		"delivery": "inline",
	}
}

func sanitizedGatewayThreadTurnsListParams(params map[string]any) map[string]any {
	safe := copyGatewayParams(params, "threadId", "cursor", "sortDirection", "itemsView")
	limit := int64(appServerGatewayThreadTurnsDefaultLimit)
	if value, ok := params["limit"]; ok && value != nil {
		if parsed, parsedOK := gatewayJSONNumberInt64(value); parsedOK {
			limit = parsed
		}
	}
	if limit > appServerGatewayThreadTurnsMaxLimit {
		limit = appServerGatewayThreadTurnsMaxLimit
	}
	if itemsView, ok := gatewayStringParam(params, "itemsView"); ok && itemsView == "full" && limit > appServerGatewayThreadTurnsFullMaxLimit {
		// full turn item 可能包含大量消息内容；移动端默认只拿小页，避免一次把完整历史打到 iPad。
		limit = appServerGatewayThreadTurnsFullMaxLimit
	}
	safe["limit"] = limit
	return safe
}

func sanitizedGatewayThreadListParams(params map[string]any) map[string]any {
	return copyGatewayParams(params, "cwd", "limit", "cursor", "sortKey", "sortDirection", "archived", "useStateDbOnly")
}

func sanitizedGatewayThreadSearchParams(params map[string]any) map[string]any {
	// searchTerm 是唯一必填字段，统一 trim；其余只重建 0.144.2 schema 中的字段，
	// 未知字段一律丢弃，避免未来/恶意 JSON 绕过 gateway 的显式策略边界。
	safe := copyGatewayParams(params, "cursor", "limit", "sortDirection", "sortKey", "archived", "sourceKinds")
	if searchTerm, ok := params["searchTerm"].(string); ok {
		safe["searchTerm"] = strings.TrimSpace(searchTerm)
	}
	return safe
}

func validateGatewayThreadSearchParams(params map[string]any) error {
	rawSearchTerm, ok := params["searchTerm"]
	if !ok {
		return fmt.Errorf("thread/search.searchTerm 不能为空")
	}
	searchTerm, ok := rawSearchTerm.(string)
	if !ok || strings.TrimSpace(searchTerm) == "" {
		return fmt.Errorf("thread/search.searchTerm 必须是非空字符串")
	}
	if len(strings.TrimSpace(searchTerm)) > appServerGatewayThreadSearchTermMaxBytes {
		return fmt.Errorf("thread/search.searchTerm 不能超过 %d bytes", appServerGatewayThreadSearchTermMaxBytes)
	}
	if value, ok := params["limit"]; ok {
		if value != nil {
			limit, parsed := gatewayJSONNumberInt64(value)
			if !parsed || limit < 0 {
				return fmt.Errorf("thread/search.limit 必须是非负整数")
			}
		}
		if gatewayJSONNumberGreaterThan(value, appServerGatewayThreadSearchMaxLimit) {
			return fmt.Errorf("thread/search.limit 不能超过 %d", appServerGatewayThreadSearchMaxLimit)
		}
	}
	if value, ok := params["cursor"]; ok && value != nil {
		if _, ok := value.(string); !ok {
			return fmt.Errorf("thread/search.cursor 必须是字符串")
		}
	}
	if value, ok := params["sortDirection"]; ok && value != nil {
		sortDirection, ok := value.(string)
		if !ok {
			return fmt.Errorf("thread/search.sortDirection 必须是字符串")
		}
		switch sortDirection {
		case "asc", "desc":
		default:
			return fmt.Errorf("thread/search.sortDirection 不支持：%s", sortDirection)
		}
	}
	if value, ok := params["sortKey"]; ok && value != nil {
		sortKey, ok := value.(string)
		if !ok {
			return fmt.Errorf("thread/search.sortKey 必须是字符串")
		}
		switch sortKey {
		case "created_at", "updated_at", "recency_at":
		default:
			return fmt.Errorf("thread/search.sortKey 不支持：%s", sortKey)
		}
	}
	if value, ok := params["archived"]; ok && value != nil {
		if _, ok := value.(bool); !ok {
			return fmt.Errorf("thread/search.archived 必须是布尔值")
		}
	}
	if value, ok := params["sourceKinds"]; ok && value != nil {
		sourceKinds, ok := value.([]any)
		if !ok {
			return fmt.Errorf("thread/search.sourceKinds 必须是字符串数组")
		}
		allowed := map[string]struct{}{
			"cli": {}, "vscode": {}, "exec": {}, "appServer": {}, "subAgent": {},
			"subAgentReview": {}, "subAgentCompact": {}, "subAgentThreadSpawn": {}, "subAgentOther": {}, "unknown": {},
		}
		for _, value := range sourceKinds {
			sourceKind, ok := value.(string)
			if !ok {
				return fmt.Errorf("thread/search.sourceKinds 必须是字符串数组")
			}
			if _, ok := allowed[sourceKind]; !ok {
				return fmt.Errorf("thread/search.sourceKinds 不支持：%s", sourceKind)
			}
		}
	}
	return nil
}

func validateGatewayGoalSetParams(params map[string]any) error {
	if value, ok := params["objective"]; ok {
		if value != nil {
			text, ok := value.(string)
			if !ok || strings.TrimSpace(text) == "" {
				return fmt.Errorf("thread/goal/set.objective 必须是非空字符串")
			}
		}
	}
	if value, ok := params["status"]; ok {
		if value != nil {
			status, ok := value.(string)
			if !ok {
				return fmt.Errorf("thread/goal/set.status 必须是字符串")
			}
			switch status {
			case "active", "paused", "blocked", "usageLimited", "budgetLimited", "complete":
			default:
				return fmt.Errorf("thread/goal/set.status 不支持：%s", status)
			}
		}
	}
	if value, ok := params["tokenBudget"]; ok {
		if value != nil && !gatewayPositiveJSONNumber(value) {
			return fmt.Errorf("thread/goal/set.tokenBudget 必须是正数")
		}
	}
	if value, ok := params["token_budget"]; ok {
		if value != nil && !gatewayPositiveJSONNumber(value) {
			return fmt.Errorf("thread/goal/set.token_budget 必须是正数")
		}
	}
	return nil
}

func validateGatewayThreadListParams(params map[string]any) error {
	if value, ok := params["limit"]; ok {
		if value != nil && !gatewayPositiveJSONNumber(value) {
			return fmt.Errorf("thread/list.limit 必须是正整数")
		}
		if gatewayJSONNumberGreaterThan(value, appServerGatewayThreadListMaxLimit) {
			return fmt.Errorf("thread/list.limit 不能超过 %d", appServerGatewayThreadListMaxLimit)
		}
	}
	if value, ok := params["cursor"]; ok && value != nil {
		if text, ok := value.(string); !ok || strings.TrimSpace(text) == "" {
			return fmt.Errorf("thread/list.cursor 必须是非空字符串")
		}
	}
	if value, ok := params["sortKey"]; ok && value != nil {
		text, ok := value.(string)
		if !ok {
			return fmt.Errorf("thread/list.sortKey 必须是字符串")
		}
		switch strings.TrimSpace(text) {
		case "updated_at":
		default:
			return fmt.Errorf("thread/list.sortKey 不支持：%s", text)
		}
	}
	if value, ok := params["sortDirection"]; ok && value != nil {
		text, ok := value.(string)
		if !ok {
			return fmt.Errorf("thread/list.sortDirection 必须是字符串")
		}
		switch strings.TrimSpace(text) {
		case "desc":
		default:
			return fmt.Errorf("thread/list.sortDirection 不支持：%s", text)
		}
	}
	if value, ok := params["archived"]; ok && value != nil {
		archived, ok := value.(bool)
		if !ok {
			return fmt.Errorf("thread/list.archived 必须是布尔值")
		}
		if archived {
			return fmt.Errorf("thread/list.archived 只允许 false")
		}
	}
	if value, ok := params["useStateDbOnly"]; ok && value != nil {
		if _, ok := value.(bool); !ok {
			return fmt.Errorf("thread/list.useStateDbOnly 必须是布尔值")
		}
	}
	return nil
}

func validateGatewayThreadResumeParams(params map[string]any) error {
	value, ok := params["initialTurnsPage"]
	if !ok || value == nil {
		return nil
	}
	page, ok := value.(map[string]any)
	if !ok {
		return fmt.Errorf("thread/resume.initialTurnsPage 必须是对象")
	}
	if value, ok := page["limit"]; ok {
		if value != nil && !gatewayPositiveJSONNumber(value) {
			return fmt.Errorf("thread/resume.initialTurnsPage.limit 必须是正整数")
		}
		if gatewayJSONNumberGreaterThan(value, appServerGatewayInitialTurnsMaxLimit) {
			return fmt.Errorf("thread/resume.initialTurnsPage.limit 不能超过 %d", appServerGatewayInitialTurnsMaxLimit)
		}
	}
	if value, ok := page["sortDirection"]; ok && value != nil {
		text, ok := value.(string)
		if !ok || strings.TrimSpace(text) != "desc" {
			return fmt.Errorf("thread/resume.initialTurnsPage.sortDirection 只支持 desc")
		}
	}
	if value, ok := page["itemsView"]; ok && value != nil {
		text, ok := value.(string)
		if !ok {
			return fmt.Errorf("thread/resume.initialTurnsPage.itemsView 必须是字符串")
		}
		switch strings.TrimSpace(text) {
		case "summary", "full":
		default:
			return fmt.Errorf("thread/resume.initialTurnsPage.itemsView 只支持 summary/full")
		}
	}
	return nil
}

func validateGatewayThreadTurnsListParams(params map[string]any) error {
	if value, ok := params["limit"]; ok {
		if value != nil && !gatewayPositiveJSONNumber(value) {
			return fmt.Errorf("thread/turns/list.limit 必须是正整数")
		}
		if gatewayJSONNumberGreaterThan(value, appServerGatewayThreadTurnsMaxLimit) {
			return fmt.Errorf("thread/turns/list.limit 不能超过 %d", appServerGatewayThreadTurnsMaxLimit)
		}
	}
	if value, ok := params["cursor"]; ok && value != nil {
		if text, ok := value.(string); !ok || strings.TrimSpace(text) == "" {
			return fmt.Errorf("thread/turns/list.cursor 必须是非空字符串")
		}
	}
	if value, ok := params["sortDirection"]; ok && value != nil {
		text, ok := value.(string)
		if !ok {
			return fmt.Errorf("thread/turns/list.sortDirection 必须是字符串")
		}
		switch strings.TrimSpace(text) {
		case "asc", "desc":
		default:
			return fmt.Errorf("thread/turns/list.sortDirection 不支持：%s", text)
		}
	}
	if value, ok := params["itemsView"]; ok && value != nil {
		text, ok := value.(string)
		if !ok {
			return fmt.Errorf("thread/turns/list.itemsView 必须是字符串")
		}
		switch strings.TrimSpace(text) {
		case "notLoaded", "summary", "full":
		default:
			return fmt.Errorf("thread/turns/list.itemsView 不支持：%s", text)
		}
	}
	return nil
}

func gatewayPositiveJSONNumber(value any) bool {
	switch typed := value.(type) {
	case json.Number:
		number, err := typed.Int64()
		return err == nil && number > 0
	case float64:
		return typed > 0 && typed == float64(int64(typed))
	case int:
		return typed > 0
	case int64:
		return typed > 0
	default:
		return false
	}
}

func gatewayJSONNumberGreaterThan(value any, max int64) bool {
	switch typed := value.(type) {
	case json.Number:
		number, err := typed.Int64()
		return err == nil && number > max
	case float64:
		return typed > float64(max)
	case int:
		return int64(typed) > max
	case int64:
		return typed > max
	default:
		return false
	}
}

func gatewayJSONNumberInt64(value any) (int64, bool) {
	switch typed := value.(type) {
	case json.Number:
		number, err := typed.Int64()
		return number, err == nil
	case float64:
		if typed != float64(int64(typed)) {
			return 0, false
		}
		return int64(typed), true
	case int:
		return int64(typed), true
	case int64:
		return typed, true
	default:
		return 0, false
	}
}

func sanitizedGatewayInitializeParams(params map[string]any) map[string]any {
	safe := map[string]any{}
	if clientInfo, ok := params["clientInfo"].(map[string]any); ok {
		sanitizedClientInfo := copyGatewayStringParams(clientInfo, "name", "title", "version")
		if len(sanitizedClientInfo) > 0 {
			safe["clientInfo"] = sanitizedClientInfo
		}
	}
	if capabilities, ok := params["capabilities"].(map[string]any); ok {
		sanitizedCapabilities := copyGatewayBoolParams(capabilities, "experimentalApi", "requestAttestation")
		if len(sanitizedCapabilities) > 0 {
			safe["capabilities"] = sanitizedCapabilities
		}
	}
	return safe
}

func sanitizedGatewayThreadParams(runtimeID string, method string, params map[string]any) map[string]any {
	safe := copyGatewayParams(params, "cwd", "serviceTier", "personality")
	if method == "thread/resume" || method == "thread/fork" {
		copyGatewayParam(safe, params, "threadId")
	}
	if method == "thread/resume" {
		safe["excludeTurns"] = true
		if page, ok := params["initialTurnsPage"].(map[string]any); ok {
			safe["initialTurnsPage"] = sanitizedGatewayInitialTurnsPage(page)
		}
	}
	safe["approvalPolicy"], safe["approvalsReviewer"] = sanitizedGatewayApproval(params)
	safe["sandbox"] = sanitizedGatewayThreadSandbox(runtimeID, params)
	return safe
}

func sanitizedGatewayInitialTurnsPage(page map[string]any) map[string]any {
	// 空对象也必须补齐受控默认值，不能依赖上游可能变化的默认页大小。
	safe := map[string]any{
		"limit":         int64(appServerGatewayInitialTurnsMaxLimit),
		"sortDirection": "desc",
		"itemsView":     "full",
	}
	if limit := gatewayOptionalInt64Param(page, "limit"); limit > 0 && limit <= appServerGatewayInitialTurnsMaxLimit {
		safe["limit"] = limit
	}
	if direction := gatewayOptionalStringParam(page, "sortDirection"); direction == "desc" {
		safe["sortDirection"] = direction
	}
	if itemsView := gatewayOptionalStringParam(page, "itemsView"); itemsView == "summary" || itemsView == "full" {
		safe["itemsView"] = itemsView
	}
	return safe
}

func sanitizedGatewayThreadSandbox(runtimeID string, params map[string]any) string {
	if normalizeAppServerRuntimeID(runtimeID) == "claude" {
		if sandbox, ok := gatewayStringParam(params, "sandbox"); ok && normalizePolicyValue(sandbox) == "readonly" {
			return "read-only"
		}
		return "workspace-write"
	}
	if sandbox, ok := gatewayStringParam(params, "sandbox"); ok && normalizePolicyValue(sandbox) == "readonly" {
		return "read-only"
	}
	if sandbox, ok := gatewayStringParam(params, "sandbox"); ok && normalizePolicyValue(sandbox) == "workspacewrite" {
		return "workspace-write"
	}
	if sandbox, ok := gatewayStringParam(params, "sandbox"); ok && normalizePolicyValue(sandbox) == "dangerfullaccess" {
		return "danger-full-access"
	}
	return "danger-full-access"
}

func sanitizedGatewayTurnParams(runtimeID string, params map[string]any, cwd string) map[string]any {
	safe := copyGatewayParams(params, "threadId", "cwd", "input", "clientUserMessageId", "model", "serviceTier", "effort", "summary", "personality")
	if collaborationMode, ok := sanitizedGatewayCollaborationMode(params["collaborationMode"]); ok {
		safe["collaborationMode"] = collaborationMode
	}
	safe["approvalPolicy"], safe["approvalsReviewer"] = sanitizedGatewayApproval(params)
	safe["sandboxPolicy"] = sanitizedGatewaySandboxPolicy(runtimeID, params["sandboxPolicy"], cwd)
	// 默认模型必须交给 app-server 按账号 rollout 决定；gateway 只透传用户显式选择的 model。
	if effort, ok := gatewayStringParam(safe, "effort"); !ok || strings.TrimSpace(effort) == "" {
		safe["effort"] = defaultCodexReasoningEffort
	}
	return safe
}

func sanitizedGatewayTurnSteerParams(params map[string]any) map[string]any {
	return copyGatewayParams(params, "threadId", "input", "clientUserMessageId", "expectedTurnId")
}

func logGatewayForwardedClientTurnSummary(method string, payload []byte) {
	if method != "turn/start" && method != "turn/steer" {
		return
	}
	var frame appServerGatewayFrame
	if err := json.Unmarshal(payload, &frame); err != nil {
		log.Printf("app-server gateway forwarded client turn method=%s summary_error=json", method)
		return
	}
	params, err := decodeGatewayParams(frame.Params)
	if err != nil {
		log.Printf("app-server gateway forwarded client turn method=%s summary_error=params", method)
		return
	}
	threadID, _ := gatewayStringParam(params, "threadId")
	expectedTurnID, _ := gatewayStringParam(params, "expectedTurnId")
	clientUserMessageID, _ := gatewayStringParam(params, "clientUserMessageId")
	// 这里只记录协议元信息，刻意不记录 input.text、图片 URL 或本地文件路径。
	log.Printf(
		"app-server gateway forwarded client turn method=%s threadId=%s cwdBase=%s input=%s collaborationMode=%s expectedTurnId=%s clientUserMessageId=%s",
		method,
		gatewayCompactLogToken(threadID),
		gatewayCWDBaseLabel(params),
		gatewayInputTypeSummary(params),
		gatewayCollaborationModeSummary(params),
		gatewayCompactLogToken(expectedTurnID),
		gatewayCompactLogToken(clientUserMessageID),
	)
}

func gatewayInputTypeSummary(params map[string]any) string {
	raw, ok := params["input"]
	if !ok {
		return "absent"
	}
	items, ok := raw.([]any)
	if !ok {
		return "invalid"
	}
	counts := map[string]int{}
	for _, item := range items {
		obj, ok := item.(map[string]any)
		if !ok {
			counts["invalid"]++
			continue
		}
		inputType, _ := gatewayStringParam(obj, "type")
		if inputType == "" {
			inputType = "unknown"
		}
		counts[inputType]++
	}
	keys := make([]string, 0, len(counts))
	for key := range counts {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	parts := []string{fmt.Sprintf("count=%d", len(items))}
	for _, key := range keys {
		parts = append(parts, fmt.Sprintf("%s=%d", gatewayCompactLogToken(key), counts[key]))
	}
	return strings.Join(parts, ",")
}

func gatewayCollaborationModeSummary(params map[string]any) string {
	raw, ok := params["collaborationMode"]
	if !ok {
		return "absent"
	}
	mode, ok := raw.(map[string]any)
	if !ok {
		return "invalid"
	}
	modeValue, ok := gatewayStringParam(mode, "mode")
	if !ok {
		modeValue = "missing"
	}
	settings, _ := mode["settings"].(map[string]any)
	model, ok := gatewayStringParam(settings, "model")
	if !ok {
		model = "absent"
	}
	effort := "absent"
	if value, exists := settings["reasoning_effort"]; exists {
		switch typed := value.(type) {
		case nil:
			effort = "null"
		case string:
			effort = strings.TrimSpace(typed)
			if effort == "" {
				effort = "missing"
			}
		default:
			effort = "invalid"
		}
	}
	return fmt.Sprintf(
		"mode=%s,model=%s,effort=%s",
		gatewayCompactLogToken(modeValue),
		gatewayCompactLogToken(model),
		gatewayCompactLogToken(effort),
	)
}

func gatewayCWDBaseLabel(params map[string]any) string {
	cwd, ok := gatewayStringParam(params, "cwd")
	if !ok {
		return "absent"
	}
	base := filepath.Base(filepath.Clean(cwd))
	if base == "" {
		return "unknown"
	}
	return gatewayCompactLogToken(base)
}

func gatewayCompactLogToken(value string) string {
	value = strings.Join(strings.Fields(strings.TrimSpace(value)), "_")
	if value == "" {
		return "absent"
	}
	if len(value) <= 16 {
		return value
	}
	return value[:8] + "..." + value[len(value)-4:]
}

func sanitizedGatewayCollaborationMode(raw any) (map[string]any, bool) {
	mode, ok := raw.(map[string]any)
	if !ok {
		return nil, false
	}
	modeValue, ok := gatewayStringParam(mode, "mode")
	if !ok {
		return nil, false
	}
	settings, _ := mode["settings"].(map[string]any)
	safeSettings := map[string]any{
		"reasoning_effort":       nil,
		"developer_instructions": nil,
	}
	// 默认模型不在 gateway 补齐；只有显式选择时才放进 collaboration settings。
	if model, ok := gatewayStringParam(settings, "model"); ok {
		safeSettings["model"] = model
	}
	if effort, ok := settings["reasoning_effort"]; ok {
		safeSettings["reasoning_effort"] = effort
	}
	return map[string]any{
		"mode":     modeValue,
		"settings": safeSettings,
	}, true
}

func sanitizedGatewayApproval(params map[string]any) (string, string) {
	policy, _ := gatewayStringParam(params, "approvalPolicy")
	reviewer, _ := gatewayStringParam(params, "approvalsReviewer")
	// 移动端只放行一个有限自动审批组合：失败时交给 auto_review。
	// never / networkAccess 仍由 validateGatewayPolicyParams 统一拦截。
	if normalizePolicyValue(policy) == "onfailure" && reviewer == "auto_review" {
		return "on-failure", reviewer
	}
	return "on-request", "user"
}

func sanitizedGatewaySandboxPolicy(runtimeID string, raw any, cwd string) map[string]any {
	sandbox, _ := raw.(map[string]any)
	sandboxType, _ := gatewayStringParam(sandbox, "type")
	normalizedType := normalizePolicyValue(sandboxType)
	if normalizeAppServerRuntimeID(runtimeID) == "claude" {
		if normalizedType == "readonly" {
			return map[string]any{
				"type":          "readOnly",
				"networkAccess": false,
			}
		}
		return map[string]any{
			"type":          "workspaceWrite",
			"writableRoots": []any{cwd},
			"networkAccess": false,
		}
	}
	if normalizedType == "readonly" {
		return map[string]any{
			"type":          "readOnly",
			"networkAccess": false,
		}
	}
	if normalizedType == "dangerfullaccess" {
		return map[string]any{
			"type":          "dangerFullAccess",
			"networkAccess": false,
		}
	}
	if normalizedType == "workspacewrite" {
		return map[string]any{
			"type":          "workspaceWrite",
			"writableRoots": []any{cwd},
			"networkAccess": false,
		}
	}
	// 默认权限模式是“用户批准 + 完全访问”；网络仍默认关闭，避免无意放开外连能力。
	return map[string]any{
		"type":          "dangerFullAccess",
		"networkAccess": false,
	}
}

func copyGatewayParams(params map[string]any, keys ...string) map[string]any {
	copied := map[string]any{}
	for _, key := range keys {
		copyGatewayParam(copied, params, key)
	}
	return copied
}

func copyGatewayParam(dst map[string]any, src map[string]any, key string) {
	if value, ok := src[key]; ok {
		dst[key] = value
	}
}

func (p *appServerGatewayPolicy) reserveHistoryRequest(id *json.RawMessage, method string, params map[string]any, requestBytes int) *appServerGatewayPolicyError {
	pending, ok := gatewayHistoryRequestFromParams(method, params)
	if !ok {
		return nil
	}
	key := gatewayRequestIDKey(id)
	if key == "" {
		return &appServerGatewayPolicyError{id: id, message: fmt.Sprintf("%s 请求缺少 id", method)}
	}
	now := time.Now()
	pending.fingerprint = gatewayHistoryRequestFingerprint(p.runtimeID, pending)
	pending.inflightOwner = fmt.Sprintf("%p\x00%s", p, key)
	if !p.reserveHistoryInflight(pending) {
		return &appServerGatewayPolicyError{
			id:      id,
			message: fmt.Sprintf("%s 相同历史或列表请求仍在执行，请稍后重试", method),
			data: gatewayPolicyErrorData("history_request_in_flight", time.Second, map[string]any{
				"method": method,
			}),
		}
	}
	budgetKey := gatewayHistoryBudgetKey(gatewayHistoryBudgetSubject(pending), pending.method, pending.itemsView)

	p.mu.Lock()
	defer p.mu.Unlock()
	p.pruneHistoryLocked(now)
	if p.pendingHistory == nil {
		p.pendingHistory = map[string]appServerGatewayPendingHistoryRequest{}
	}
	if pending.redactOnly {
		// 追踪表满时放弃改写而不是拒绝请求：redact-only 请求宁可原样透传也不能失败。
		if _, exists := p.pendingHistory[key]; !exists && len(p.pendingHistory) >= appServerGatewayPendingHistoryRequestMax {
			p.releaseHistoryInflight(pending)
			return nil
		}
		pending.createdAt = now
		p.pendingHistory[key] = pending
		return nil
	}
	if policyErr := p.router.reserveHistoryGlobalBudget(id, pending); policyErr != nil {
		p.releaseHistoryInflight(pending)
		p.recordHistoryRateLimited(pending.method)
		return policyErr
	}
	if _, exists := p.pendingHistory[key]; !exists && len(p.pendingHistory) >= appServerGatewayPendingHistoryRequestMax {
		p.releaseHistoryInflight(pending)
		return &appServerGatewayPolicyError{id: id, message: "gateway pending history 请求过多"}
	}
	if p.historyBudgets == nil {
		p.historyBudgets = map[string]appServerGatewayHistoryBudget{}
	}
	budget := p.historyBudgets[budgetKey]
	if budget.windowStarted.IsZero() || now.Sub(budget.windowStarted) >= appServerGatewayHistoryBudgetWindow {
		budget = appServerGatewayHistoryBudget{windowStarted: now}
	}
	if budget.blockedUntil.After(now) {
		p.historyBudgets[budgetKey] = budget
		p.releaseHistoryInflight(pending)
		p.recordHistoryRateLimited(pending.method)
		return gatewayHistoryBudgetPolicyError(
			id,
			fmt.Sprintf("%s 同一 thread/method 正在临时限流，请稍后重试或降低 limit/itemsView（itemsView=%s）", method, pending.itemsView),
			"history_budget_limited",
			budget.blockedUntil.Sub(now),
			pending,
			nil,
		)
	}
	if appServerGatewayHistoryBudgetMaxRequests > 0 && budget.requests >= appServerGatewayHistoryBudgetMaxRequests {
		budget.blockedUntil = now.Add(appServerGatewayHistoryBudgetWindow)
		p.historyBudgets[budgetKey] = budget
		p.releaseHistoryInflight(pending)
		p.recordHistoryRateLimited(pending.method)
		return gatewayHistoryBudgetPolicyError(
			id,
			fmt.Sprintf("%s 同一 thread/method 请求过于频繁，请稍后重试（itemsView=%s）", method, pending.itemsView),
			"history_budget_limited",
			appServerGatewayHistoryBudgetWindow,
			pending,
			nil,
		)
	}
	if appServerGatewayHistoryBudgetMaxRequestBytes > 0 && budget.requestBytes+int64(requestBytes) > appServerGatewayHistoryBudgetMaxRequestBytes {
		budget.blockedUntil = now.Add(appServerGatewayHistoryBudgetWindow)
		p.historyBudgets[budgetKey] = budget
		p.releaseHistoryInflight(pending)
		p.recordHistoryRateLimited(pending.method)
		return gatewayHistoryBudgetPolicyError(
			id,
			fmt.Sprintf("%s 同一 thread/method 请求字节预算已用尽，请稍后重试（itemsView=%s）", method, pending.itemsView),
			"history_budget_limited",
			appServerGatewayHistoryBudgetWindow,
			pending,
			nil,
		)
	}
	if appServerGatewayHistoryBudgetMaxResponseBytes > 0 && budget.responseBytes >= appServerGatewayHistoryBudgetMaxResponseBytes {
		budget.blockedUntil = now.Add(appServerGatewayHistoryBudgetWindow)
		p.historyBudgets[budgetKey] = budget
		p.releaseHistoryInflight(pending)
		p.recordHistoryRateLimited(pending.method)
		return gatewayHistoryBudgetPolicyError(
			id,
			fmt.Sprintf("%s 同一 thread/method 历史响应预算已用尽，请稍后重试（itemsView=%s）", method, pending.itemsView),
			"history_budget_limited",
			appServerGatewayHistoryBudgetWindow,
			pending,
			nil,
		)
	}
	budget.requests++
	budget.requestBytes += int64(requestBytes)
	p.historyBudgets[budgetKey] = budget
	pending.createdAt = now
	p.pendingHistory[key] = pending
	return nil
}

func gatewayHistoryRequestFromParams(method string, params map[string]any) (appServerGatewayPendingHistoryRequest, bool) {
	switch method {
	case "thread/list":
		cwd, _ := gatewayStringParam(params, "cwd")
		return appServerGatewayPendingHistoryRequest{
			method: method, cwd: cwd, cursor: gatewayOptionalStringParam(params, "cursor"),
			limit: gatewayOptionalInt64Param(params, "limit"), sortDirection: gatewayOptionalStringParam(params, "sortDirection"),
			itemsView: "list", useStateDBOnly: gatewayOptionalBoolFingerprintParam(params, "useStateDbOnly"),
		}, true
	case "thread/search":
		// 搜索没有 cwd/threadId，请求指纹必须包含完整的安全参数；预算 subject 则使用固定
		// search 桶，避免把用户搜索词写入诊断信息或错误响应。
		safeParams := sanitizedGatewayThreadSearchParams(params)
		filterFingerprint, _ := json.Marshal(safeParams)
		return appServerGatewayPendingHistoryRequest{
			method: method, cursor: gatewayOptionalStringParam(safeParams, "cursor"),
			limit: gatewayOptionalInt64Param(safeParams, "limit"), sortDirection: gatewayOptionalStringParam(safeParams, "sortDirection"),
			itemsView: "search", filterFingerprint: string(filterFingerprint),
		}, true
	case "thread/turns/list":
		threadID, ok := gatewayStringParam(params, "threadId")
		if !ok {
			return appServerGatewayPendingHistoryRequest{}, false
		}
		limit := gatewayOptionalInt64Param(params, "limit")
		if limit == 0 {
			limit = appServerGatewayThreadTurnsDefaultLimit
		}
		if gatewayHistoryItemsViewFromParams(params) == "full" && limit > appServerGatewayThreadTurnsFullMaxLimit {
			limit = appServerGatewayThreadTurnsFullMaxLimit
		}
		return appServerGatewayPendingHistoryRequest{
			method: method, threadID: threadID, cursor: gatewayOptionalStringParam(params, "cursor"), limit: limit,
			sortDirection: gatewayOptionalStringParam(params, "sortDirection"), itemsView: gatewayHistoryItemsViewFromParams(params),
		}, true
	case "thread/read":
		threadID, ok := gatewayStringParam(params, "threadId")
		if !ok {
			return appServerGatewayPendingHistoryRequest{}, false
		}
		includeTurns, includeTurnsOK := gatewayBoolParam(params, "includeTurns")
		if includeTurnsOK && includeTurns {
			return appServerGatewayPendingHistoryRequest{method: method, threadID: threadID, itemsView: "fullRead", includeTurns: true}, true
		}
	case "thread/resume":
		threadID, ok := gatewayStringParam(params, "threadId")
		if !ok {
			return appServerGatewayPendingHistoryRequest{}, false
		}
		if page, pageOK := params["initialTurnsPage"].(map[string]any); pageOK {
			safePage := sanitizedGatewayInitialTurnsPage(page)
			return appServerGatewayPendingHistoryRequest{
				method: method, threadID: threadID,
				limit: gatewayOptionalInt64Param(safePage, "limit"), sortDirection: gatewayOptionalStringParam(safePage, "sortDirection"),
				itemsView: gatewayHistoryItemsViewFromParams(safePage),
			}, true
		}
		// resume 一次性带回整段 thread（大线程 9MB+ 内联图），必须做图片改写；
		// 但它是消息发送的前置绑定，不能被预算/cap 阻断。
		return appServerGatewayPendingHistoryRequest{method: method, threadID: threadID, itemsView: "resume", redactOnly: true}, true
	}
	return appServerGatewayPendingHistoryRequest{}, false
}

func gatewayHistoryRequestFingerprint(runtimeID string, request appServerGatewayPendingHistoryRequest) string {
	// 指纹只由会改变上游结果的协议字段组成；JSON 编码避免 cwd/cursor 中的分隔符造成碰撞。
	encoded, _ := json.Marshal(struct {
		Runtime        string `json:"runtime"`
		Method         string `json:"method"`
		ThreadID       string `json:"thread,omitempty"`
		CWD            string `json:"cwd,omitempty"`
		Cursor         string `json:"cursor,omitempty"`
		Limit          int64  `json:"limit,omitempty"`
		SortDirection  string `json:"sortDirection,omitempty"`
		ItemsView      string `json:"itemsView,omitempty"`
		UseStateDBOnly string `json:"useStateDbOnly,omitempty"`
		Filter         string `json:"filter,omitempty"`
	}{
		Runtime: normalizeAppServerRuntimeID(runtimeID), Method: request.method, ThreadID: request.threadID,
		CWD: request.cwd, Cursor: request.cursor, Limit: request.limit, SortDirection: request.sortDirection,
		ItemsView: request.itemsView, UseStateDBOnly: request.useStateDBOnly, Filter: request.filterFingerprint,
	})
	return string(encoded)
}

func gatewayOptionalStringParam(params map[string]any, key string) string {
	value, _ := gatewayStringParam(params, key)
	return strings.TrimSpace(value)
}

func gatewayOptionalInt64Param(params map[string]any, key string) int64 {
	value, ok := params[key]
	if !ok || value == nil {
		return 0
	}
	parsed, _ := gatewayJSONNumberInt64(value)
	return parsed
}

func gatewayOptionalBoolFingerprintParam(params map[string]any, key string) string {
	value, ok := params[key]
	if !ok || value == nil {
		return "unset"
	}
	if flag, ok := value.(bool); ok && flag {
		return "true"
	}
	return "false"
}

func (p *appServerGatewayPolicy) reserveHistoryInflight(request appServerGatewayPendingHistoryRequest) bool {
	if p == nil || p.router == nil || p.router.monitor == nil || request.fingerprint == "" {
		return true
	}
	return p.router.monitor.reserveHistoryInflight(request.fingerprint, request.inflightOwner, request.method, appServerGatewayPendingHistoryRequestTTL)
}

func (p *appServerGatewayPolicy) releaseHistoryInflight(request appServerGatewayPendingHistoryRequest) {
	if p == nil || p.router == nil || p.router.monitor == nil {
		return
	}
	p.router.monitor.releaseHistoryInflight(request.fingerprint, request.inflightOwner)
}

func (p *appServerGatewayPolicy) recordHistoryRateLimited(method string) {
	if p == nil || p.router == nil || p.router.monitor == nil {
		return
	}
	p.router.monitor.recordHistoryRateLimited(method)
}

func (p *appServerGatewayPolicy) recordHistoryResponseMetrics(method string, responseBytes int, blocked bool) {
	if p == nil || p.router == nil || p.router.monitor == nil {
		return
	}
	p.router.monitor.recordHistoryResponseMetrics(method, responseBytes, blocked)
}

func gatewayHistoryItemsViewFromParams(params map[string]any) string {
	if itemsView, ok := gatewayStringParam(params, "itemsView"); ok {
		if normalized := strings.TrimSpace(itemsView); normalized != "" {
			return normalized
		}
	}
	return "full"
}

func gatewayHistoryBudgetKey(threadID string, method string, itemsView string) string {
	return strings.TrimSpace(threadID) + "\x00" + strings.TrimSpace(method) + "\x00" + strings.TrimSpace(itemsView)
}

func gatewayHistoryBudgetSubject(request appServerGatewayPendingHistoryRequest) string {
	if threadID := strings.TrimSpace(request.threadID); threadID != "" {
		return threadID
	}
	if request.method == "thread/search" {
		return "thread-search"
	}
	return strings.TrimSpace(request.cwd)
}

func gatewayHistoryBudgetPolicyError(
	id *json.RawMessage,
	message string,
	reason string,
	retryAfter time.Duration,
	request appServerGatewayPendingHistoryRequest,
	extra map[string]any,
) *appServerGatewayPolicyError {
	data := gatewayPolicyErrorData(reason, retryAfter, extra)
	if strings.TrimSpace(request.method) != "" {
		data["method"] = request.method
	}
	if strings.TrimSpace(request.threadID) != "" {
		data["threadId"] = request.threadID
	}
	if strings.TrimSpace(request.cwd) != "" {
		data["cwd"] = request.cwd
	}
	if strings.TrimSpace(request.itemsView) != "" {
		data["itemsView"] = request.itemsView
	}
	return &appServerGatewayPolicyError{
		id:                    id,
		message:               message,
		data:                  data,
		historyBudgetRejected: true,
	}
}

func gatewayPolicyErrorData(reason string, retryAfter time.Duration, extra map[string]any) map[string]any {
	data := map[string]any{}
	if reason != "" {
		data["reason"] = reason
	}
	if retryAfter > 0 {
		retryAfterMs := int64((retryAfter + time.Millisecond - 1) / time.Millisecond)
		retryAfterSeconds := int64((retryAfter + time.Second - 1) / time.Second)
		if retryAfterMs < 1 {
			retryAfterMs = 1
		}
		if retryAfterSeconds < 1 {
			retryAfterSeconds = 1
		}
		data["retryAfterMs"] = retryAfterMs
		data["retryAfterSeconds"] = retryAfterSeconds
	}
	for key, value := range extra {
		data[key] = value
	}
	return data
}

func (p *appServerGatewayPolicy) pruneHistoryLocked(now time.Time) {
	for id, pending := range p.pendingHistory {
		if pending.createdAt.IsZero() || now.Sub(pending.createdAt) > appServerGatewayPendingHistoryRequestTTL {
			delete(p.pendingHistory, id)
			p.releaseHistoryInflight(pending)
		}
	}
	for key, budget := range p.historyBudgets {
		if budget.windowStarted.IsZero() || (now.Sub(budget.windowStarted) >= appServerGatewayHistoryBudgetWindow && !budget.blockedUntil.After(now)) {
			delete(p.historyBudgets, key)
		}
	}
}

func (p *appServerGatewayPolicy) consumePendingHistoryRequest(id *json.RawMessage) (appServerGatewayPendingHistoryRequest, bool) {
	key := gatewayRequestIDKey(id)
	if key == "" {
		return appServerGatewayPendingHistoryRequest{}, false
	}
	p.mu.Lock()
	p.pruneHistoryLocked(time.Now())
	request, ok := p.pendingHistory[key]
	if ok {
		delete(p.pendingHistory, key)
	}
	p.mu.Unlock()
	if ok {
		p.releaseHistoryInflight(request)
	}
	return request, ok
}

func (p *appServerGatewayPolicy) cancelPendingHistoryRequest(id *json.RawMessage) {
	_, _ = p.consumePendingHistoryRequest(id)
}

func (p *appServerGatewayPolicy) releaseAllHistoryInflight() {
	if p == nil {
		return
	}
	p.mu.Lock()
	requests := make([]appServerGatewayPendingHistoryRequest, 0, len(p.pendingHistory))
	for key, request := range p.pendingHistory {
		requests = append(requests, request)
		delete(p.pendingHistory, key)
	}
	p.mu.Unlock()
	for _, request := range requests {
		p.releaseHistoryInflight(request)
	}
}

func (p *appServerGatewayPolicy) recordHistoryResponseBudget(request appServerGatewayPendingHistoryRequest, responseBytes int) {
	subject := gatewayHistoryBudgetSubject(request)
	if subject == "" || strings.TrimSpace(request.method) == "" {
		return
	}
	now := time.Now()
	key := gatewayHistoryBudgetKey(subject, request.method, request.itemsView)
	p.mu.Lock()
	if p.historyBudgets == nil {
		p.historyBudgets = map[string]appServerGatewayHistoryBudget{}
	}
	budget := p.historyBudgets[key]
	if budget.windowStarted.IsZero() || now.Sub(budget.windowStarted) >= appServerGatewayHistoryBudgetWindow {
		budget = appServerGatewayHistoryBudget{windowStarted: now}
	}
	budget.responseBytes += int64(responseBytes)
	if appServerGatewayHistoryBudgetMaxResponseBytes > 0 && budget.responseBytes >= appServerGatewayHistoryBudgetMaxResponseBytes {
		budget.blockedUntil = now.Add(appServerGatewayHistoryBudgetWindow)
	}
	p.historyBudgets[key] = budget
	p.mu.Unlock()

	p.router.recordHistoryGlobalResponseBudget(request, responseBytes)
}

func (r *Router) reserveHistoryGlobalBudget(id *json.RawMessage, request appServerGatewayPendingHistoryRequest) *appServerGatewayPolicyError {
	if r == nil || request.redactOnly || appServerGatewayHistoryGlobalMaxResponseBytes <= 0 {
		return nil
	}
	now := time.Now()
	window := appServerGatewayHistoryGlobalBudgetWindow()
	r.gatewayHistoryBudgetMu.Lock()
	defer r.gatewayHistoryBudgetMu.Unlock()
	budget := r.gatewayHistoryGlobalBudget
	if budget.windowStarted.IsZero() || (now.Sub(budget.windowStarted) >= window && !budget.blockedUntil.After(now)) {
		budget = appServerGatewayHistoryBudget{windowStarted: now}
	}
	if budget.blockedUntil.After(now) {
		r.gatewayHistoryGlobalBudget = budget
		return gatewayHistoryBudgetPolicyError(
			id,
			fmt.Sprintf("%s 全局历史下行预算已用尽，请稍后重试（itemsView=%s）", request.method, request.itemsView),
			"history_budget_limited",
			budget.blockedUntil.Sub(now),
			request,
			map[string]any{"scope": "global"},
		)
	}
	r.gatewayHistoryGlobalBudget = budget
	return nil
}

func (r *Router) recordHistoryGlobalResponseBudget(request appServerGatewayPendingHistoryRequest, responseBytes int) {
	if r == nil || request.redactOnly || appServerGatewayHistoryGlobalMaxResponseBytes <= 0 || responseBytes <= 0 {
		return
	}
	now := time.Now()
	window := appServerGatewayHistoryGlobalBudgetWindow()
	r.gatewayHistoryBudgetMu.Lock()
	defer r.gatewayHistoryBudgetMu.Unlock()
	budget := r.gatewayHistoryGlobalBudget
	if budget.windowStarted.IsZero() || (now.Sub(budget.windowStarted) >= window && !budget.blockedUntil.After(now)) {
		budget = appServerGatewayHistoryBudget{windowStarted: now}
	}
	// 核心逻辑：全局预算按进程共享，避免 full/summary/fullRead 或多连接同时拉历史时合计挤爆 5Mbps 链路。
	budget.responseBytes += int64(responseBytes)
	if budget.responseBytes >= appServerGatewayHistoryGlobalMaxResponseBytes {
		budget.blockedUntil = now.Add(window)
	}
	r.gatewayHistoryGlobalBudget = budget
}

func appServerGatewayHistoryGlobalBudgetWindow() time.Duration {
	if appServerGatewayHistoryGlobalWindow > 0 {
		return appServerGatewayHistoryGlobalWindow
	}
	return appServerGatewayHistoryBudgetWindow
}

func copyGatewayStringParams(params map[string]any, keys ...string) map[string]any {
	copied := map[string]any{}
	for _, key := range keys {
		if value, ok := params[key].(string); ok {
			copied[key] = value
		}
	}
	return copied
}

func copyGatewayBoolParams(params map[string]any, keys ...string) map[string]any {
	copied := map[string]any{}
	for _, key := range keys {
		if value, ok := params[key].(bool); ok {
			copied[key] = value
		}
	}
	return copied
}

func (p *appServerGatewayPolicy) rememberPendingThreadResponse(id *json.RawMessage, method string, cwd string, scopeID string) error {
	return p.rememberPendingThreadResponseWithManagedUse(id, method, cwd, scopeID, "")
}

func (p *appServerGatewayPolicy) rememberPendingThreadResponseWithManagedUse(id *json.RawMessage, method string, cwd string, scopeID string, managedWorktreePath string) error {
	return p.rememberPendingThreadRequest(id, appServerGatewayPendingThreadRequest{
		method: method, cwd: cwd, scopeID: scopeID, managedWorktreePath: managedWorktreePath,
	})
}

func (p *appServerGatewayPolicy) rememberPendingThreadSearchResponse(id *json.RawMessage, limit int64, limitSet bool) error {
	return p.rememberPendingThreadRequest(id, appServerGatewayPendingThreadRequest{
		method: "thread/search", responseLimit: limit, responseLimitSet: limitSet,
	})
}

func (p *appServerGatewayPolicy) rememberPendingThreadRequest(id *json.RawMessage, pending appServerGatewayPendingThreadRequest) error {
	key := gatewayRequestIDKey(id)
	if key == "" {
		if pending.managedWorktreePath != "" {
			return fmt.Errorf("gateway pending thread 请求缺少 id")
		}
		return nil
	}
	if p.beforePendingRemember != nil {
		p.beforePendingRemember()
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return fmt.Errorf("app-server gateway 连接已关闭")
	}
	now := time.Now()
	p.prunePendingThreadsLocked(now)
	if _, exists := p.pendingThreads[key]; !exists && len(p.pendingThreads) >= appServerGatewayPendingThreadMax {
		return fmt.Errorf("gateway pending thread 请求过多")
	}
	if _, exists := p.pendingThreads[key]; exists {
		return fmt.Errorf("gateway pending thread 请求 id 重复")
	}
	pending.createdAt = now
	p.pendingThreads[key] = pending
	return nil
}

func (p *appServerGatewayPolicy) prunePendingThreadsLocked(now time.Time) {
	for id, pending := range p.pendingThreads {
		if pending.managedWorktreePath != "" {
			// managed checkout 的 lease 不能因本地 TTL 自动释放：上游可能仍在
			// 创建/恢复 thread。只有明确响应、明确失败或 policy.close()
			// 才能证明该 cwd 不再处于未完成使用窗口。
			continue
		}
		if pending.createdAt.IsZero() || now.Sub(pending.createdAt) > appServerGatewayPendingThreadTTL {
			delete(p.pendingThreads, id)
		}
	}
}

func (p *appServerGatewayPolicy) allowedThread(threadID string) (appServerGatewayAllowedThread, bool) {
	threadID = strings.TrimSpace(threadID)
	if threadID == "" {
		return appServerGatewayAllowedThread{}, false
	}
	p.mu.Lock()
	thread, ok := p.allowedThreads[threadID]
	p.mu.Unlock()
	if ok {
		return thread, true
	}
	return p.router.gatewayThread(p.runtimeID, threadID)
}

func (r *Router) gatewayThread(runtimeID string, threadID string) (appServerGatewayAllowedThread, bool) {
	runtimeID = normalizeAppServerRuntimeID(runtimeID)
	if runtimeID == "" {
		runtimeID = "codex"
	}
	threadID = strings.TrimSpace(threadID)
	if threadID == "" {
		return appServerGatewayAllowedThread{}, false
	}
	key := gatewayThreadCacheKey(runtimeID, threadID)
	now := time.Now()
	r.gatewayThreadsMu.Lock()
	defer r.gatewayThreadsMu.Unlock()
	thread, ok := r.gatewayThreads[key]
	if !ok {
		return appServerGatewayAllowedThread{}, false
	}
	if gatewayThreadCacheExpired(thread, now) {
		delete(r.gatewayThreads, key)
		return appServerGatewayAllowedThread{}, false
	}
	// 全局授权表只服务断线重连的短期恢复；命中时刷新 lastSeen，让活跃 thread 不被容量裁剪误删。
	thread.lastSeen = now
	r.gatewayThreads[key] = thread
	return thread, ok
}

func (p *appServerGatewayPolicy) observeUpstreamFrame(messageType int, payload []byte) ([]byte, bool, *appServerGatewayPolicyError) {
	if messageType != websocket.TextMessage {
		return payload, true, nil
	}
	var frame appServerGatewayFrame
	if err := json.Unmarshal(payload, &frame); err != nil {
		return payload, true, nil
	}
	if strings.TrimSpace(frame.Method) != "" && frame.ID != nil {
		if !appServerServerRequestAllowed(p.runtimeID, frame.Method) {
			return payload, false, &appServerGatewayPolicyError{
				id:      frame.ID,
				message: "app-server server request 尚未被移动端支持：" + strings.TrimSpace(frame.Method),
				data: map[string]any{
					"reason": "unsupported_server_request",
					"method": strings.TrimSpace(frame.Method),
				},
			}
		}
		if err := p.rememberPendingServerRequest(frame.ID, frame.Method); err != nil {
			return payload, false, &appServerGatewayPolicyError{id: frame.ID, message: err.Error()}
		}
		return payload, true, nil
	}
	if strings.TrimSpace(frame.Method) != "" && frame.ID == nil {
		if normalizeAppServerRuntimeID(p.runtimeID) == "codex" && appServerMediaRedactNotificationsEnabled() {
			if redacted, changed := p.router.redactInlineHistoryImagesInGatewayResponse(payload); changed {
				payload = redacted
			}
		}
		return payload, true, nil
	}
	if gatewayFrameIsResponse(&frame) {
		if pending, ok := p.consumePendingHistoryRequest(frame.ID); ok {
			if len(frame.Error) == 0 && len(frame.Result) > 0 {
				if redacted, changed := p.router.redactInlineHistoryImagesInGatewayResponse(payload); changed {
					payload = redacted
				}
			}
			blocked := !pending.redactOnly && len(frame.Error) == 0 && len(frame.Result) > 0 && appServerGatewayHistoryResponseCapBytes > 0 && len(payload) > appServerGatewayHistoryResponseCapBytes
			p.recordHistoryResponseMetrics(pending.method, len(payload), blocked)
			if !pending.redactOnly {
				p.recordHistoryResponseBudget(pending, len(payload))
				if blocked {
					p.forgetPending(frame.ID)
					return payload, false, &appServerGatewayPolicyError{
						id:      frame.ID,
						message: fmt.Sprintf("%s history response 过大（%d bytes > %d bytes），gateway 已阻断；请降低 limit/itemsView 或改用分页读取", pending.method, len(payload), appServerGatewayHistoryResponseCapBytes),
						data: gatewayPolicyErrorData("history_response_too_large", appServerGatewayHistoryBudgetWindow, map[string]any{
							"method":           pending.method,
							"threadId":         pending.threadID,
							"cwd":              pending.cwd,
							"itemsView":        pending.itemsView,
							"responseBytes":    len(payload),
							"maxResponseBytes": appServerGatewayHistoryResponseCapBytes,
						}),
						target:                 "client",
						historyResponseBlocked: true,
					}
				}
			}
		}
	}
	if !p.hasPendingThreadResponses() {
		return payload, true, nil
	}
	if frame.ID == nil || len(frame.Result) == 0 || len(frame.Error) > 0 {
		p.forgetPending(frame.ID)
		return payload, true, nil
	}
	key := gatewayRequestIDKey(frame.ID)
	if key == "" {
		return payload, true, nil
	}
	p.mu.Lock()
	pending, ok := p.pendingThreads[key]
	p.mu.Unlock()
	if !ok {
		return payload, true, nil
	}
	if pending.method == "thread/search" {
		rewritten, threads, err := p.sanitizeThreadSearchResponse(payload, pending)
		if err != nil {
			p.forgetPending(frame.ID)
			return payload, false, &appServerGatewayPolicyError{
				id: frame.ID, message: err.Error(), target: "client",
			}
		}
		p.completePendingThreadResponse(key, pending, threads)
		return rewritten, true, nil
	}
	p.completePendingThreadResponse(key, pending, p.threadsFromResult(frame.Result, pending))
	// 成功响应先把 thread 写入连接级与全局 gateway 授权表，再释放
	// pending-use。转换期间至少有一种保护存在，cleanup 看不到可删除窗口。
	return payload, true, nil
}

func (p *appServerGatewayPolicy) sanitizeThreadSearchResponse(payload []byte, pending appServerGatewayPendingThreadRequest) ([]byte, []appServerGatewayAllowedThread, error) {
	var response map[string]json.RawMessage
	if err := json.Unmarshal(payload, &response); err != nil {
		return nil, nil, fmt.Errorf("thread/search response 无效")
	}
	var resultFields map[string]json.RawMessage
	if raw := response["result"]; len(raw) == 0 || bytes.Equal(bytes.TrimSpace(raw), []byte("null")) || json.Unmarshal(raw, &resultFields) != nil {
		return nil, nil, fmt.Errorf("thread/search response.result 必须是对象")
	}
	dataRaw, ok := resultFields["data"]
	if !ok || bytes.Equal(bytes.TrimSpace(dataRaw), []byte("null")) {
		return nil, nil, fmt.Errorf("thread/search response.data 必须是数组")
	}
	var rawItems []json.RawMessage
	if err := json.Unmarshal(dataRaw, &rawItems); err != nil {
		return nil, nil, fmt.Errorf("thread/search response.data 必须是数组")
	}

	limit := int64(appServerGatewayThreadSearchMaxLimit)
	if pending.responseLimitSet {
		limit = pending.responseLimit
	}
	if limit < 0 || limit > appServerGatewayThreadSearchMaxLimit {
		limit = appServerGatewayThreadSearchMaxLimit
	}
	safeItems := make([]map[string]any, 0, min(len(rawItems), int(limit)))
	allowedThreads := make([]appServerGatewayAllowedThread, 0, cap(safeItems))
	for _, rawItem := range rawItems {
		if int64(len(safeItems)) >= limit {
			break
		}
		var item map[string]json.RawMessage
		if json.Unmarshal(rawItem, &item) != nil {
			continue
		}
		var snippet string
		if raw := item["snippet"]; len(raw) == 0 || json.Unmarshal(raw, &snippet) != nil {
			continue
		}
		threadRaw := item["thread"]
		var thread appServerGatewayThreadWire
		if len(threadRaw) == 0 || bytes.Equal(bytes.TrimSpace(threadRaw), []byte("null")) || json.Unmarshal(threadRaw, &thread) != nil {
			continue
		}
		threadID := strings.TrimSpace(thread.ID)
		cwd := strings.TrimSpace(thread.CWD)
		// 0.144.2 schema 要求 Thread.id 与绝对 cwd。不能让 filepath.Abs 把相对路径
		// 悄悄解释成 agentd 当前目录，也不能把 trim 后与客户端看到值不同的 thread 登记进授权表。
		if threadID == "" || threadID != thread.ID || cwd == "" || cwd != thread.CWD || !filepath.IsAbs(cwd) {
			continue
		}
		scope, ok := p.router.gatewayScopeForPath(cwd)
		if !ok {
			continue
		}
		info, err := os.Stat(scope.realPath)
		if err != nil || !info.IsDir() {
			continue
		}
		safeItems = append(safeItems, map[string]any{
			"thread":  threadRaw,
			"snippet": snippet,
		})
		allowedThreads = append(allowedThreads, appServerGatewayAllowedThread{
			id: threadID, runtimeID: normalizeAppServerRuntimeID(p.runtimeID), cwd: scope.realPath, scopeID: scope.id,
		})
	}

	// 只重建协议声明字段：被过滤条目的 snippet 与 result 级未知字段都不会残留在下行 JSON。
	safeResult := map[string]any{"data": safeItems}
	copyGatewaySearchCursor(safeResult, resultFields, "nextCursor")
	copyGatewaySearchCursor(safeResult, resultFields, "backwardsCursor")
	safeResponse := map[string]any{
		"jsonrpc": "2.0",
		"id":      response["id"],
		"result":  safeResult,
	}
	rewritten, err := json.Marshal(safeResponse)
	if err != nil {
		return nil, nil, fmt.Errorf("重写 thread/search response 失败：%w", err)
	}
	return rewritten, allowedThreads, nil
}

func copyGatewaySearchCursor(dst map[string]any, src map[string]json.RawMessage, key string) {
	raw, ok := src[key]
	if !ok {
		return
	}
	if bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		dst[key] = nil
		return
	}
	var cursor string
	if json.Unmarshal(raw, &cursor) == nil {
		dst[key] = cursor
	}
}

func appServerServerRequestAllowed(runtimeID string, method string) bool {
	// Claude bridge 目前沿用既有反向请求协议；Codex 的协议面更宽且会持续新增，因此必须显式收口。
	if normalizeAppServerRuntimeID(runtimeID) != "codex" {
		return true
	}
	_, ok := appServerAllowedServerRequestMethods[strings.TrimSpace(method)]
	return ok
}

func appServerMediaRedactNotificationsEnabled() bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv(appServerMediaRedactNotifyEnv))) {
	case "0", "false", "off", "no":
		return false
	default:
		return true
	}
}

func gatewayFrameIsResponse(frame *appServerGatewayFrame) bool {
	return frame != nil &&
		strings.TrimSpace(frame.Method) == "" &&
		frame.ID != nil &&
		(len(frame.Result) > 0 || len(frame.Error) > 0)
}

func (p *appServerGatewayPolicy) rememberPendingClientRequest(id *json.RawMessage, method string) error {
	key := gatewayRequestIDKey(id)
	if key == "" {
		return fmt.Errorf("%s 请求缺少 id", method)
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	now := time.Now()
	p.prunePendingClientRequestsLocked(now)
	if p.pendingClientRequests == nil {
		p.pendingClientRequests = map[string]appServerGatewayPendingClientRequest{}
	}
	if _, exists := p.pendingClientRequests[key]; !exists && len(p.pendingClientRequests) >= appServerGatewayPendingClientRequestMax {
		return fmt.Errorf("gateway pending client request 过多")
	}
	p.pendingClientRequests[key] = appServerGatewayPendingClientRequest{method: method, createdAt: now}
	return nil
}

func (p *appServerGatewayPolicy) consumePendingClientRequest(id *json.RawMessage) (appServerGatewayPendingClientRequest, bool) {
	key := gatewayRequestIDKey(id)
	if key == "" {
		return appServerGatewayPendingClientRequest{}, false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	p.prunePendingClientRequestsLocked(time.Now())
	request, ok := p.pendingClientRequests[key]
	if ok {
		delete(p.pendingClientRequests, key)
	}
	return request, ok
}

func (p *appServerGatewayPolicy) prunePendingClientRequestsLocked(now time.Time) {
	for id, pending := range p.pendingClientRequests {
		if pending.createdAt.IsZero() || now.Sub(pending.createdAt) > appServerGatewayPendingClientRequestTTL {
			delete(p.pendingClientRequests, id)
		}
	}
}

func (p *appServerGatewayPolicy) rememberPendingServerRequest(id *json.RawMessage, method string) error {
	key := gatewayRequestIDKey(id)
	if key == "" {
		return fmt.Errorf("app-server request 缺少 id")
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	now := time.Now()
	p.prunePendingServerRequestsLocked(now)
	if p.pendingServerRequests == nil {
		p.pendingServerRequests = map[string]appServerGatewayPendingServerRequest{}
	}
	if _, exists := p.pendingServerRequests[key]; !exists && len(p.pendingServerRequests) >= appServerGatewayPendingServerRequestMax {
		return fmt.Errorf("gateway pending server request 过多")
	}
	p.pendingServerRequests[key] = appServerGatewayPendingServerRequest{method: method, createdAt: now}
	return nil
}

func (p *appServerGatewayPolicy) consumePendingServerRequest(id *json.RawMessage) (appServerGatewayPendingServerRequest, bool) {
	key := gatewayRequestIDKey(id)
	if key == "" {
		return appServerGatewayPendingServerRequest{}, false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	p.prunePendingServerRequestsLocked(time.Now())
	request, ok := p.pendingServerRequests[key]
	if ok {
		delete(p.pendingServerRequests, key)
	}
	return request, ok
}

func (p *appServerGatewayPolicy) prunePendingServerRequestsLocked(now time.Time) {
	for id, pending := range p.pendingServerRequests {
		if pending.createdAt.IsZero() || now.Sub(pending.createdAt) > appServerGatewayPendingServerRequestTTL {
			delete(p.pendingServerRequests, id)
		}
	}
}

func (p *appServerGatewayPolicy) hasPendingThreadResponses() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.prunePendingThreadsLocked(time.Now())
	return len(p.pendingThreads) > 0
}

func (p *appServerGatewayPolicy) forgetPending(id *json.RawMessage) {
	key := gatewayRequestIDKey(id)
	if key == "" {
		return
	}
	p.mu.Lock()
	pending, ok := p.pendingThreads[key]
	if ok {
		delete(p.pendingThreads, key)
	}
	p.mu.Unlock()
	if ok {
		p.router.releaseManagedWorktreePendingUse(pending.managedWorktreePath)
	}
}

func (p *appServerGatewayPolicy) isClosed() bool {
	p.mu.Lock()
	closed := p.closed
	p.mu.Unlock()
	return closed
}

func (p *appServerGatewayPolicy) close() {
	p.mu.Lock()
	if p.closed {
		p.mu.Unlock()
		return
	}
	p.closed = true
	paths := make([]string, 0, len(p.pendingThreads))
	for key, pending := range p.pendingThreads {
		if pending.managedWorktreePath != "" {
			paths = append(paths, pending.managedWorktreePath)
		}
		delete(p.pendingThreads, key)
	}
	p.mu.Unlock()
	for _, path := range paths {
		p.router.releaseManagedWorktreePendingUse(path)
	}
}

func (p *appServerGatewayPolicy) threadsFromResult(raw json.RawMessage, pending appServerGatewayPendingThreadRequest) []appServerGatewayAllowedThread {
	var threads []appServerGatewayThreadWire
	var object map[string]json.RawMessage
	if err := json.Unmarshal(raw, &object); err == nil {
		appendThreadWire := func(value json.RawMessage) {
			var thread appServerGatewayThreadWire
			if len(value) > 0 && !bytes.Equal(bytes.TrimSpace(value), []byte("null")) && json.Unmarshal(value, &thread) == nil {
				threads = append(threads, thread)
			}
		}
		appendThreadWire(object["thread"])
		for _, key := range []string{"data", "threads"} {
			if value := object[key]; len(value) > 0 {
				var list []appServerGatewayThreadWire
				if err := json.Unmarshal(value, &list); err == nil {
					threads = append(threads, list...)
				}
			}
		}
	}
	if len(threads) == 0 {
		var list []appServerGatewayThreadWire
		if err := json.Unmarshal(raw, &list); err == nil {
			threads = append(threads, list...)
		}
	}

	out := make([]appServerGatewayAllowedThread, 0, len(threads))
	for _, item := range threads {
		id := firstNonEmpty(item.ID, item.ThreadID, item.SessionID)
		if strings.TrimSpace(id) == "" {
			continue
		}
		cwd := firstNonEmpty(item.CWD, item.Path, pending.cwd)
		scope, ok := p.router.gatewayScopeForPath(cwd)
		if !ok {
			continue
		}
		if pending.scopeID != "" && scope.id != pending.scopeID {
			continue
		}
		out = append(out, appServerGatewayAllowedThread{
			id:        strings.TrimSpace(id),
			runtimeID: normalizeAppServerRuntimeID(p.runtimeID),
			// browse 作用域用 canonical 路径绑定，避免同一目录的不同写法绕过精确匹配。
			cwd:     scope.realPath,
			scopeID: scope.id,
		})
	}
	return out
}

func (p *appServerGatewayPolicy) allowThread(thread appServerGatewayAllowedThread) {
	thread, ok := p.normalizeAllowedThread(thread)
	if !ok {
		return
	}
	p.mu.Lock()
	p.allowedThreads[thread.id] = thread
	p.mu.Unlock()
	p.router.allowGatewayThread(thread)
}

func (p *appServerGatewayPolicy) normalizeAllowedThread(thread appServerGatewayAllowedThread) (appServerGatewayAllowedThread, bool) {
	if strings.TrimSpace(thread.id) == "" || strings.TrimSpace(thread.scopeID) == "" {
		return appServerGatewayAllowedThread{}, false
	}
	if strings.TrimSpace(thread.runtimeID) == "" {
		thread.runtimeID = normalizeAppServerRuntimeID(p.runtimeID)
	}
	thread.lastSeen = time.Now()
	return thread, true
}

func (p *appServerGatewayPolicy) completePendingThreadResponse(key string, pending appServerGatewayPendingThreadRequest, threads []appServerGatewayAllowedThread) {
	normalized := make([]appServerGatewayAllowedThread, 0, len(threads))
	for _, thread := range threads {
		if item, ok := p.normalizeAllowedThread(thread); ok {
			normalized = append(normalized, item)
		}
	}

	if pending.managedWorktreePath == "" {
		p.mu.Lock()
		current, ok := p.pendingThreads[key]
		if p.closed || !ok || current.createdAt != pending.createdAt {
			p.mu.Unlock()
			return
		}
		delete(p.pendingThreads, key)
		for _, thread := range normalized {
			p.allowedThreads[thread.id] = thread
			p.router.allowGatewayThread(thread)
		}
		p.mu.Unlock()
		return
	}

	// 固定锁顺序 cleanupMu -> policy.mu -> gatewayThreadsMu。policy.mu 与
	// pending entry 一起充当 close barrier：close 若先发生，晚到响应
	// 不得重新登记 thread；响应若先发生，则在同一 cleanup
	// 临界区内完成全局授权与 lease 释放。
	p.router.managedWorktreeCleanupMu.Lock()
	p.mu.Lock()
	current, ok := p.pendingThreads[key]
	if p.closed || !ok || current.managedWorktreePath != pending.managedWorktreePath || current.createdAt != pending.createdAt {
		p.mu.Unlock()
		p.router.managedWorktreeCleanupMu.Unlock()
		return
	}
	if p.beforeManagedComplete != nil {
		p.beforeManagedComplete()
	}
	delete(p.pendingThreads, key)
	for _, thread := range normalized {
		p.allowedThreads[thread.id] = thread
		p.router.allowGatewayThread(thread)
	}
	p.router.releaseManagedWorktreePendingUseLocked(pending.managedWorktreePath)
	p.mu.Unlock()
	p.router.managedWorktreeCleanupMu.Unlock()
}

func (r *Router) allowGatewayThread(thread appServerGatewayAllowedThread) {
	if strings.TrimSpace(thread.id) == "" || strings.TrimSpace(thread.scopeID) == "" {
		return
	}
	if strings.TrimSpace(thread.runtimeID) == "" {
		thread.runtimeID = "codex"
	}
	thread.runtimeID = normalizeAppServerRuntimeID(thread.runtimeID)
	now := time.Now()
	thread.lastSeen = now
	r.gatewayThreadsMu.Lock()
	r.gatewayThreads[gatewayThreadCacheKey(thread.runtimeID, thread.id)] = thread
	r.pruneGatewayThreadsLocked(now)
	r.gatewayThreadsMu.Unlock()
}

func gatewayThreadCacheKey(runtimeID string, threadID string) string {
	return normalizeAppServerRuntimeID(runtimeID) + "\x00" + strings.TrimSpace(threadID)
}

func (r *Router) pruneGatewayThreadsLocked(now time.Time) {
	for id, thread := range r.gatewayThreads {
		if gatewayThreadCacheExpired(thread, now) {
			delete(r.gatewayThreads, id)
		}
	}
	for len(r.gatewayThreads) > appServerGatewayThreadCacheMax {
		oldestID := ""
		oldestSeen := time.Time{}
		for id, thread := range r.gatewayThreads {
			seen := thread.lastSeen
			if seen.IsZero() {
				seen = now.Add(-appServerGatewayThreadCacheTTL - time.Nanosecond)
			}
			if oldestID == "" || seen.Before(oldestSeen) {
				oldestID = id
				oldestSeen = seen
			}
		}
		if oldestID == "" {
			return
		}
		delete(r.gatewayThreads, oldestID)
	}
}

func gatewayThreadCacheExpired(thread appServerGatewayAllowedThread, now time.Time) bool {
	if thread.lastSeen.IsZero() {
		return false
	}
	return now.Sub(thread.lastSeen) > appServerGatewayThreadCacheTTL
}

func gatewayRequestIDKey(id *json.RawMessage) string {
	if id == nil || len(bytes.TrimSpace(*id)) == 0 {
		return ""
	}
	return string(bytes.TrimSpace(*id))
}

func decodeGatewayParams(raw json.RawMessage) (map[string]any, error) {
	if len(bytes.TrimSpace(raw)) == 0 || bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		return map[string]any{}, nil
	}
	var params map[string]any
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	// 官方 app-server 当前使用命名参数；远程 gateway 不支持 positional params，避免校验策略时漏掉 cwd/sandbox 字段。
	if err := decoder.Decode(&params); err != nil {
		return nil, fmt.Errorf("JSON-RPC params 必须是对象")
	}
	return params, nil
}

func (r *Router) validateGatewayPolicyParams(runtimeID string, method string, params map[string]any) (appServerGatewayValidatedParams, error) {
	validated := appServerGatewayValidatedParams{}
	committedPendingUse := false
	defer func() {
		if !committedPendingUse {
			r.releaseManagedWorktreePendingUse(validated.pendingManagedWorktreePath)
		}
	}()
	if hasApprovalPolicyNever(params) {
		return validated, fmt.Errorf("approvalPolicy=never 不允许远程使用")
	}
	if hasDangerousConfigSandbox(params["config"]) {
		return validated, fmt.Errorf("dangerFullAccess 不允许通过 config 使用")
	}
	// Claude runtime 不在这里硬拒 dangerFullAccess：老客户端/默认草稿会在 thread/resume 上带全量沙盒，
	// 硬拒会让会话恢复进入确定性失败的重连死循环。rewriteGatewaySafeDefaults 的
	// sanitizedGatewayThreadSandbox / sanitizedGatewaySandboxPolicy 会把 Claude 的沙盒强制压回
	// workspace-write/read-only，所有 Claude 允许的方法都在改写覆盖范围内。
	if hasNetworkAccessEnabled(params) {
		return validated, fmt.Errorf("networkAccess=true 不允许远程使用")
	}
	if value, ok := params["collaborationMode"]; ok {
		if err := validateGatewayCollaborationMode(value); err != nil {
			return validated, err
		}
	}
	if cwd, ok := gatewayStringParam(params, "cwd"); ok {
		scope, pendingManagedPath, scopeOK := r.gatewayScopeForPathWithPendingUse(cwd, gatewayMethodNeedsManagedPendingUse(method))
		if !scopeOK {
			return validated, fmt.Errorf("%s.cwd 必须来自 projects allowlist 或 browse_roots", method)
		}
		validated.cwd = cwd
		validated.hasCWD = true
		validated.cwdScope = scope
		validated.cwdScopeOK = true
		validated.pendingManagedWorktreePath = pendingManagedPath
	}
	if requiresGatewayCWD(method) {
		if !validated.hasCWD {
			return validated, fmt.Errorf("%s.cwd 必须来自 projects allowlist 或 browse_roots", method)
		}
	}
	roots, err := collectWritableRoots(params)
	if err != nil {
		return validated, err
	}
	seenRoots := map[string]struct{}{}
	for _, root := range roots {
		if root == validated.cwd && validated.cwdScopeOK {
			continue
		}
		if _, seen := seenRoots[root]; seen {
			continue
		}
		seenRoots[root] = struct{}{}
		// writableRoots 不随 browse_roots 放宽：browse workspace 的可写范围只有 cwd 本身
		//（上面 root == cwd 已放行），其余仍要求命中项目 allowlist。
		if _, ok := r.projectForGatewayPath(root); !ok {
			return validated, fmt.Errorf("sandboxPolicy.writableRoots 必须来自 projects allowlist")
		}
	}
	inputPaths, err := collectUserInputPaths(method, params)
	if err != nil {
		return validated, err
	}
	if method != "turn/steer" {
		for _, path := range inputPaths {
			if _, ok := r.projectForGatewayPath(path); ok {
				continue
			}
			// browse/worktree workspace 的结构化文件输入（图片/mention）允许引用绑定目录内的文件，
			// 但不允许引用允许根下的 sibling 目录，保持和 cwd 一样的精确边界。
			if validated.cwdScopeOK && (validated.cwdScope.browse || validated.cwdScope.managed) && gatewayScopeContainsPath(validated.cwdScope, path) {
				continue
			}
			return validated, fmt.Errorf("%s.input path 必须来自 projects allowlist", method)
		}
	}
	committedPendingUse = true
	return validated, nil
}

func gatewayMethodNeedsManagedPendingUse(method string) bool {
	switch strings.TrimSpace(method) {
	case "thread/start", "thread/resume", "thread/fork":
		return true
	default:
		return false
	}
}

func requiresGatewayCWD(method string) bool {
	switch method {
	case "thread/list", "thread/start", "thread/resume", "thread/fork", "turn/start":
		return true
	default:
		return false
	}
}

func gatewayStringParam(params map[string]any, key string) (string, bool) {
	value, ok := params[key]
	if !ok {
		return "", false
	}
	text, ok := value.(string)
	return strings.TrimSpace(text), ok && strings.TrimSpace(text) != ""
}

func gatewayBoolParam(params map[string]any, key string) (bool, bool) {
	value, ok := params[key]
	if !ok {
		return false, false
	}
	typed, ok := value.(bool)
	return typed, ok
}

func collectUserInputPaths(method string, params map[string]any) ([]string, error) {
	raw, ok := params["input"]
	if !ok {
		return nil, nil
	}
	items, ok := raw.([]any)
	if !ok {
		return nil, fmt.Errorf("%s.input 必须是数组", method)
	}
	paths := []string{}
	for _, item := range items {
		obj, ok := item.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("%s.input item 必须是 object", method)
		}
		inputType, _ := gatewayStringParam(obj, "type")
		switch inputType {
		case "localImage", "mention":
			path, ok := gatewayStringParam(obj, "path")
			if !ok {
				return nil, fmt.Errorf("%s.input.%s.path 不能为空", method, inputType)
			}
			paths = append(paths, path)
		case "skill":
			// Skill 可能来自用户级 / 管理员级 skill root 或插件缓存，不属于当前项目工作区；
			// gateway 只校验字段完整性，不把 skill.path 当作文件输入路径做 allowlist 限制。
			if _, ok := gatewayStringParam(obj, "path"); !ok {
				return nil, fmt.Errorf("%s.input.skill.path 不能为空", method)
			}
		case "image":
			url, ok := gatewayStringParam(obj, "url")
			if !ok {
				return nil, fmt.Errorf("%s.input.image.url 不能为空", method)
			}
			if strings.HasPrefix(strings.ToLower(url), "file:") {
				return nil, fmt.Errorf("%s.input.image.url 不允许 file URL，请使用 localImage.path", method)
			}
		case "text":
		default:
			return nil, fmt.Errorf("%s.input 类型不支持：%s", method, inputType)
		}
	}
	return paths, nil
}

func validateGatewayCollaborationMode(value any) error {
	mode, ok := value.(map[string]any)
	if !ok {
		return fmt.Errorf("collaborationMode 必须是 object")
	}
	if hasDangerousConfigSandbox(mode) {
		return fmt.Errorf("collaborationMode 不允许 dangerFullAccess")
	}
	modeValue, ok := gatewayStringParam(mode, "mode")
	if !ok {
		return fmt.Errorf("collaborationMode.mode 必须是 plan/default")
	}
	switch modeValue {
	case "plan", "default":
	default:
		return fmt.Errorf("collaborationMode.mode 不支持：%s", modeValue)
	}
	settings, ok := mode["settings"].(map[string]any)
	if !ok {
		return fmt.Errorf("collaborationMode.settings 必须是 object")
	}
	if model, ok := settings["model"]; ok && model != nil {
		if text, ok := model.(string); !ok || strings.TrimSpace(text) == "" {
			return fmt.Errorf("collaborationMode.settings.model 必须是非空字符串")
		}
	}
	if developerInstructions, ok := settings["developer_instructions"]; ok && developerInstructions != nil {
		return fmt.Errorf("collaborationMode.settings.developer_instructions 只能是 null")
	}
	if developerInstructions, ok := settings["developerInstructions"]; ok && developerInstructions != nil {
		return fmt.Errorf("collaborationMode.settings.developerInstructions 只能是 null")
	}
	if effort, ok := settings["reasoning_effort"]; ok && effort != nil {
		text, ok := effort.(string)
		if !ok {
			return fmt.Errorf("collaborationMode.settings.reasoning_effort 必须是字符串或 null")
		}
		switch text {
		case "none", "minimal", "low", "medium", "high", "xhigh":
		default:
			return fmt.Errorf("collaborationMode.settings.reasoning_effort 不支持：%s", text)
		}
	}
	return nil
}

func (r *Router) projectForGatewayPath(raw string) (projects.Project, bool) {
	project, _, ok := r.projectForGatewayPathWithRealPath(raw)
	return project, ok
}

func (r *Router) projectForGatewayPathWithRealPath(raw string) (projects.Project, string, bool) {
	path := strings.TrimSpace(raw)
	if path == "" {
		return projects.Project{}, "", false
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return projects.Project{}, "", false
	}
	realPath, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return projects.Project{}, "", false
	}
	project, ok := r.projects.FindByPath(realPath)
	return project, realPath, ok
}

// gatewayScopeForPath 把路径解析成授权作用域：优先命中 projects allowlist（项目作用域），
// 否则若在 browse_roots 内则得到精确目录作用域；两者都不命中即未授权。
func (r *Router) gatewayScopeForPath(raw string) (gatewayScope, bool) {
	scope, _, ok := r.gatewayScopeForPathWithPendingUse(raw, false)
	return scope, ok
}

func (r *Router) gatewayScopeForPathWithPendingUse(raw string, acquirePendingUse bool) (gatewayScope, string, bool) {
	path := strings.TrimSpace(raw)
	if path == "" {
		return gatewayScope{}, "", false
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return gatewayScope{}, "", false
	}
	realPath, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return gatewayScope{}, "", false
	}
	if project, ok := r.projects.FindByPath(realPath); ok {
		return gatewayScope{id: project.ID, realPath: realPath, project: project}, "", true
	}

	// managed checkout 的路径授权、LastUsedAt 推进和 pending-use 计数
	// 必须在同一 cleanup 临界区完成；否则普通 delete 可在“授权已通过、
	// pending thread 尚未登记”的窗口删掉 cwd。
	r.managedWorktreeCleanupMu.Lock()
	if worktree, ok := r.managedWorktreeForPathLocked(realPath); ok {
		pendingPath := ""
		if acquirePendingUse {
			pendingPath = worktree.Path
			r.acquireManagedWorktreePendingUseLocked(pendingPath)
		}
		r.managedWorktreeCleanupMu.Unlock()
		return gatewayScope{
			id:       workspaceIDForRealPath(worktree.Path),
			realPath: realPath,
			project:  worktree.RootProject,
			managed:  true,
		}, pendingPath, true
	}
	r.managedWorktreeCleanupMu.Unlock()
	if r.realPathInBrowseRoots(realPath) {
		return gatewayScope{id: workspaceIDForRealPath(realPath), realPath: realPath, browse: true}, "", true
	}
	return gatewayScope{}, "", false
}

// realPathInBrowseRoots 期望传入已 EvalSymlinks 的路径；browse root 自身每次惰性
// canonical 化，配置后新建的目录也能即时生效。
func (r *Router) realPathInBrowseRoots(realPath string) bool {
	for _, root := range r.cfg.BrowseRoots {
		value := strings.TrimSpace(root)
		if value == "" {
			continue
		}
		abs, err := filepath.Abs(value)
		if err != nil {
			continue
		}
		realRoot, err := filepath.EvalSymlinks(abs)
		if err != nil {
			continue
		}
		if realPathWithin(realRoot, realPath) {
			return true
		}
	}
	return false
}

func gatewayScopeContainsPath(scope gatewayScope, raw string) bool {
	path := strings.TrimSpace(raw)
	if path == "" {
		return false
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return false
	}
	realPath, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return false
	}
	return realPathWithin(scope.realPath, realPath)
}

func realPathWithin(root, path string) bool {
	rel, err := filepath.Rel(root, path)
	if err != nil {
		return false
	}
	return rel == "." || (rel != ".." && !strings.HasPrefix(rel, ".."+string(os.PathSeparator)))
}

func collectWritableRoots(value any) ([]string, error) {
	var roots []string
	if err := collectWritableRootsInto(value, &roots); err != nil {
		return nil, err
	}
	return roots, nil
}

func collectWritableRootsInto(value any, roots *[]string) error {
	switch typed := value.(type) {
	case map[string]any:
		for key, child := range typed {
			if strings.EqualFold(key, "writableRoots") {
				items, ok := child.([]any)
				if !ok {
					return fmt.Errorf("sandboxPolicy.writableRoots 必须是字符串数组")
				}
				for _, item := range items {
					root, ok := item.(string)
					if !ok || strings.TrimSpace(root) == "" {
						return fmt.Errorf("sandboxPolicy.writableRoots 必须是字符串数组")
					}
					*roots = append(*roots, strings.TrimSpace(root))
				}
				continue
			}
			if err := collectWritableRootsInto(child, roots); err != nil {
				return err
			}
		}
	case []any:
		for _, child := range typed {
			if err := collectWritableRootsInto(child, roots); err != nil {
				return err
			}
		}
	}
	return nil
}

func hasApprovalPolicyNever(value any) bool {
	switch typed := value.(type) {
	case map[string]any:
		for key, child := range typed {
			if normalizePolicyValue(key) == "approvalpolicy" {
				if text, ok := child.(string); ok && strings.EqualFold(strings.TrimSpace(text), "never") {
					return true
				}
			}
			if hasApprovalPolicyNever(child) {
				return true
			}
		}
	case []any:
		for _, child := range typed {
			if hasApprovalPolicyNever(child) {
				return true
			}
		}
	}
	return false
}

func hasNetworkAccessEnabled(value any) bool {
	switch typed := value.(type) {
	case map[string]any:
		for key, child := range typed {
			if normalizePolicyValue(key) == "networkaccess" {
				if enabled, ok := child.(bool); ok && enabled {
					return true
				}
				if text, ok := child.(string); ok && strings.EqualFold(strings.TrimSpace(text), "true") {
					return true
				}
			}
			if hasNetworkAccessEnabled(child) {
				return true
			}
		}
	case []any:
		for _, child := range typed {
			if hasNetworkAccessEnabled(child) {
				return true
			}
		}
	}
	return false
}

func hasDangerousConfigSandbox(value any) bool {
	return hasDangerousConfigSandboxValue(value, "")
}

func hasDangerousConfigSandboxValue(value any, parentKey string) bool {
	switch typed := value.(type) {
	case map[string]any:
		for key, child := range typed {
			normalizedKey := normalizePolicyValue(key)
			if normalizedKey == "dangerfullaccess" {
				return true
			}
			if normalizedKey == "sandbox" || normalizedKey == "sandboxmode" || (parentKey == "sandboxpolicy" && normalizedKey == "type") {
				if text, ok := child.(string); ok && normalizePolicyValue(text) == "dangerfullaccess" {
					return true
				}
			}
			if hasDangerousConfigSandboxValue(child, normalizedKey) {
				return true
			}
		}
	case []any:
		for _, child := range typed {
			if hasDangerousConfigSandboxValue(child, parentKey) {
				return true
			}
		}
	}
	return false
}

func normalizePolicyValue(value string) string {
	value = strings.ToLower(strings.TrimSpace(value))
	value = strings.ReplaceAll(value, "-", "")
	value = strings.ReplaceAll(value, "_", "")
	return value
}

func writeGatewayPolicyError(conn *websocket.Conn, mu *sync.Mutex, policyErr *appServerGatewayPolicyError) bool {
	id := json.RawMessage("null")
	if policyErr.id != nil && len(*policyErr.id) > 0 {
		id = *policyErr.id
	}
	errorBody := map[string]any{
		"code":    appServerPolicyErrorCode,
		"message": policyErr.message,
	}
	if len(policyErr.data) > 0 {
		errorBody["data"] = policyErr.data
	}
	payload, err := json.Marshal(map[string]any{
		"id":    id,
		"error": errorBody,
	})
	if err != nil {
		return false
	}
	return writeWebSocketFrame(conn, mu, websocket.TextMessage, payload) == nil
}

func sanitizeGatewayURL(raw string) string {
	parsed, err := url.Parse(raw)
	if err != nil {
		return "[invalid-url]"
	}
	parsed.User = nil
	parsed.RawQuery = ""
	return parsed.String()
}
