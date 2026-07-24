package httpapi

import (
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"github.com/gaixianggeng/mimi-remote/internal/appserver"
	"github.com/gaixianggeng/mimi-remote/internal/claudebridge"
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
	// 5 Mbps 链路 15 秒理论可传约 8.9 MiB；取 8 MiB 给协议和控制流量留出余量。
	// 单次历史响应仍受 2 MiB cap 约束，避免一个大响应独占链路。
	appServerGatewayHistoryGlobalMaxResponseBytes int64 = 8 << 20
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
	"skills/list":             {},
	"plugin/installed":        {},
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
	"initialize":              {},
	"initialized":             {},
	"thread/list":             {},
	"thread/start":            {},
	"thread/resume":           {},
	"thread/read":             {},
	"thread/turns/list":       {},
	"turn/start":              {},
	"turn/steer":              {},
	"turn/interrupt":          {},
	"model/list":              {},
	"account/rateLimits/read": {},
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
	MinimumVersion string `json:"minimum_version,omitempty"`
	Path           string `json:"path,omitempty"`
	Status         string `json:"status"`
	Healthy        bool   `json:"healthy"`
	LastProbeError string `json:"last_probe_error,omitempty"`
	Fix            string `json:"fix,omitempty"`
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
	sortKey           string
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
		claudeRateLimitsAvailable := probe.Healthy && claudebridge.IsSupported(probe.Version)
		claudeMethods := appServerAllowedMethodListForRuntime("claude")
		if !claudeRateLimitsAvailable {
			claudeMethods = removeAppServerMethod(claudeMethods, "account/rateLimits/read")
		}
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
				MinimumVersion: claudebridge.MinimumVersion,
				Path:           probe.Path,
				Status:         probe.Status,
				Healthy:        probe.Healthy,
				LastProbeError: probe.Error,
				Fix:            claudebridge.InstallHint,
			},
			Methods: claudeMethods,
			Capabilities: appServerChannelCapability{
				Streaming:        true,
				History:          true,
				ApprovalRequests: true,
				FileDiffs:        true,
				RateLimits:       claudeRateLimitsAvailable,
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

func removeAppServerMethod(methods []string, removed string) []string {
	filtered := make([]string, 0, len(methods))
	for _, method := range methods {
		if method != removed {
			filtered = append(filtered, method)
		}
	}
	return filtered
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
