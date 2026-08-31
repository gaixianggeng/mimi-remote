package httpapi

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"github.com/gaixianggeng/mimi-remote/internal/auth"
	"github.com/gaixianggeng/mimi-remote/internal/codexhistory"
	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/doctor"
	"github.com/gaixianggeng/mimi-remote/internal/projects"
	"github.com/gaixianggeng/mimi-remote/internal/protocolcontract"
	"github.com/gaixianggeng/mimi-remote/internal/session"
	"github.com/gaixianggeng/mimi-remote/internal/tailscaleinfo"
)

type Router struct {
	cfg            config.Config
	configPath     string
	projects       *projects.Registry
	sessions       *session.Manager
	doctor         *doctor.Checker
	auth           auth.Authenticator
	version        string
	installationID string
	upgrader       websocket.Upgrader
	monitor        *relayMonitor
	historyMedia   *appServerHistoryMediaStore
	historyOutput  *appServerHistoryMediaStore
	fileUploads    *fileUploadStore
	capabilities   capabilityRegistry
	// tailscalePathLookup 只在连接验证/测速时读取一次本机 Tailscale 状态。
	// 使用可注入函数既避免常驻轮询，也让无 Tailscale 环境下的接口行为可测试。
	tailscalePathLookup tailscaleNetworkPathLookup
	// tailscaleHostResolver 只缓存 MagicDNS 路由元数据。installationID 仍是唯一身份边界；
	// 名称变化只会影响下一次候选连接，不会创建或合并 ConnectionProfile。
	tailscaleHostLookup func(context.Context) tailscaleinfo.Host
	// upstreamReadiness 对高频 readyz 轮询做短 TTL + single-flight，避免每 300ms 都创建 WebSocket。
	upstreamReadiness *appServerReadinessProbe
	// runtimeStatus 只服务本机菜单栏。额度探测可能访问 OAuth/Keychain 和 provider，
	// 必须后台 single-flight 刷新，不能阻塞 readiness 或并发创建无上限连接。
	runtimeStatus *runtimeStatusSnapshotCache
	// autoThreadTitles 在 Mac 端串行生成新会话标题。它使用独立的 loopback
	// app-server 连接，不能阻塞或消费移动端 gateway 的 JSON-RPC 响应。
	autoThreadTitles autoThreadTitleScheduler
	// autoThreadTitleThreads 记录内部 ephemeral thread 的短期 tombstone。
	// app-server 会让已初始化连接监听新 thread，Gateway 必须据此丢弃内部标题 Turn 的事件。
	autoThreadTitleThreadsMu sync.Mutex
	autoThreadTitleThreads   map[string]time.Time
	// Codex app-server 由 serve 层启动、由 Router 探测。单独保存真实子进程启动时间，
	// 让菜单栏展示运行时长，而不是误用 agentd 或 Mac App 自身的存活时间。
	runtimeProcessMu      sync.RWMutex
	codexRuntimeStartedAt time.Time
	// Codex 连接探测与额度读取共用一个 app-server 会话。额度偶发超时时保留最近一次
	// 脱敏窗口，避免菜单把三个圆环整块移除；缓存只存百分比和重置时间，不含账号信息。
	codexRuntimeQuotaMu        sync.RWMutex
	codexRuntimeQuota          *runtimeRateLimits
	codexRuntimeQuotaCheckedAt time.Time
	// 菜单只为 Claude 额度等待很短时间；慢查询完成后把脱敏结果留在 Router，
	// 下一轮状态刷新无需依赖已经断开的匿名 bridge connection。
	claudeRuntimeQuotaMu        sync.RWMutex
	claudeRuntimeQuota          *runtimeRateLimits
	claudeRuntimeQuotaCheckedAt time.Time
	// Token 活动只是低频展示数据。缓存成功响应可以让 iOS 重进「我的」页或重连后
	// 立即拿到最近快照，避免每次都等待 account/usage/read 的慢查询。
	accountTokenUsageMu           sync.RWMutex
	accountTokenUsageResult       json.RawMessage
	accountTokenUsageCachedAt     time.Time
	accountTokenUsageCacheTTL     time.Duration
	gatewayThreadsMu              sync.Mutex
	gatewayThreads                map[string]appServerGatewayAllowedThread
	codexGatewayMu                sync.Mutex
	activeCodexGateway            int
	appServerSSH                  appServerSSHTransport
	gatewayHistoryBudgetMu        sync.Mutex
	gatewayHistoryGlobalBudget    appServerGatewayHistoryBudget
	claudeMu                      sync.Mutex
	claudeProbe                   appServerBridgeProbe
	activeClaudeBridge            int
	claudeBridge                  *claudeBridgeSupervisor
	tailcat                       tailcatSidecar
	tailcatLocalToken             string
	managedWorktreesMu            sync.Mutex
	managedWorktrees              map[string]managedWorktree
	managedWorktreeCleanupMu      sync.Mutex
	managedWorktreeCleanupPlans   map[string]worktreeCleanupPlan
	managedWorktreeCleanupDelete  managedWorktreeCleanupDeleteFunc
	managedWorktreePendingUses    map[string]int
	managedWorktreeRegistryRemove func(string) error
	// TestFlight 发布会持续数分钟，使用内存任务保存当前进度，避免让移动端 HTTP 请求长时间挂起。
	gitTestFlightMu   sync.Mutex
	gitTestFlightJobs map[string]*gitTestFlightReleaseJob
}

// RouterOptions 只承载必须在构造时固定的进程级资源路径。
// 空持久化路径保持纯内存行为，供普通测试和嵌入式调用使用；agentd 生产入口
// 必须注入真实配置与私有状态路径。
type RouterOptions struct {
	ConfigPath   string
	AppServerSSH appServerSSHTransport
	tailcat      tailcatSidecar
	// tailcatLocalToken 只供同包测试注入；生产值来自配置目录中的 0600 文件。
	tailcatLocalToken string
}

type appServerSSHTransport interface {
	EnsureReady(context.Context) error
	WebSocketDialer(time.Duration) (websocket.Dialer, error)
}

func NewRouter(cfg config.Config, registry *projects.Registry, manager *session.Manager, checker *doctor.Checker, version string) http.Handler {
	handler, _ := NewRouterWithInstallationIDAndOptions(
		cfg,
		registry,
		manager,
		checker,
		version,
		"",
		RouterOptions{},
	)
	return handler
}

// NewRouterWithInstallationID 为生产入口注入启动阶段已加载的稳定安装身份。
// Router 只保留内存副本，确保高频 /api/version 探测不会读磁盘或连接 upstream。
func NewRouterWithInstallationID(cfg config.Config, registry *projects.Registry, manager *session.Manager, checker *doctor.Checker, version string, installationID string) http.Handler {
	handler, _ := NewRouterWithInstallationIDAndOptions(
		cfg,
		registry,
		manager,
		checker,
		version,
		installationID,
		RouterOptions{},
	)
	return handler
}

// NewRouterWithInstallationIDAndOptions 由拥有进程生命周期的入口使用。
// 它返回 Router，确保调用方能关闭常驻 Claude bridge 等进程级资源。
func NewRouterWithInstallationIDAndOptions(
	cfg config.Config,
	registry *projects.Registry,
	manager *session.Manager,
	checker *doctor.Checker,
	version string,
	installationID string,
	options RouterOptions,
) (http.Handler, *Router) {
	fileUploads := newFileUploadStore(defaultFileUploadRoot())
	tailcat := options.tailcat
	if tailcat == nil {
		tailcat = newTailcatSidecarSupervisor(cfg, options.ConfigPath)
	}
	tailcatLocalToken := strings.TrimSpace(options.tailcatLocalToken)
	if tailcatLocalToken == "" {
		tailcatLocalToken, _ = ReadTailcatLocalControlToken(options.ConfigPath)
	}
	r := &Router{
		cfg:            cfg,
		configPath:     options.ConfigPath,
		projects:       registry,
		sessions:       manager,
		doctor:         checker,
		installationID: installationID,
		auth: auth.NewWithOptions(cfg.Auth.Token, cfg.DevInsecure, auth.Options{
			AllowQueryToken: cfg.Auth.AllowQueryToken,
		}),
		version: version,
		upgrader: websocket.Upgrader{
			CheckOrigin: sameOriginOrNoOrigin,
		},
		monitor:                     newRelayMonitor(),
		historyMedia:                newAppServerHistoryMediaStore(),
		historyOutput:               newAppServerHistoryOutputStore(),
		fileUploads:                 fileUploads,
		capabilities:                newCapabilityRegistry(cfg, fileUploads),
		tailscalePathLookup:         defaultTailscaleNetworkPathLookup,
		gatewayThreads:              map[string]appServerGatewayAllowedThread{},
		managedWorktrees:            map[string]managedWorktree{},
		managedWorktreeCleanupPlans: map[string]worktreeCleanupPlan{},
		managedWorktreePendingUses:  map[string]int{},
		gitTestFlightJobs:           map[string]*gitTestFlightReleaseJob{},
		accountTokenUsageCacheTTL:   defaultAccountTokenUsageCacheTTL,
		claudeBridge:                newClaudeBridgeSupervisor(),
		tailcat:                     tailcat,
		tailcatLocalToken:           tailcatLocalToken,
		appServerSSH:                options.AppServerSSH,
	}
	if cfg.Tailcat.Enabled {
		go func() {
			if err := r.tailcat.Start(context.Background()); err != nil {
				log.Printf("tailcat sidecar start failed: %v", err)
			}
		}()
	}
	r.refreshClaudeBridgeProbe(false)
	r.upstreamReadiness = newAppServerReadinessProbe(r.probeAppServerUpstream)
	r.runtimeStatus = newRuntimeStatusSnapshotCache(r.refreshRuntimeStatus, r.runtimeStatusPlaceholder)
	if cfg.AppServer.AutoTitle {
		r.autoThreadTitles = newAutoThreadTitleCoordinator(
			newCodexAutoThreadTitleGenerator(r),
			autoThreadTitleTimeout,
		)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", r.healthz)
	mux.HandleFunc("/api/health", r.healthz)
	mux.HandleFunc("/api/pair/claim", r.pairingClaimHandler)
	mux.HandleFunc("/api/pair/local", r.localPairingClaimHandler)
	// 先认证再判断协议窗口，既不向未认证请求暴露服务端修订，也让 REST/WS 共用同一条 fail-closed 边界。
	authed := func(handler http.Handler) http.Handler {
		return r.auth.Middleware(protocolCompatibilityMiddleware(handler))
	}
	mux.Handle("/api/readyz", authed(http.HandlerFunc(r.readyz)))
	mux.Handle("/api/version", authed(http.HandlerFunc(r.versionHandler)))
	mux.Handle("/api/doctor", authed(http.HandlerFunc(r.doctorHandler)))
	mux.Handle("/api/diagnostics/relay", authed(http.HandlerFunc(r.relayDiagnosticsHandler)))
	mux.Handle("/api/diagnostics/tailscale-path", authed(http.HandlerFunc(r.tailscaleNetworkPathHandler)))
	mux.Handle("/api/local/tailcat", authed(http.HandlerFunc(r.tailcatLocalHandler)))
	if cfg.Debug.EnableCodexHistory {
		mux.Handle("/api/debug/codex-history", authed(http.HandlerFunc(r.codexHistoryDebugHandler)))
	} else {
		mux.HandleFunc("/api/debug/codex-history", r.codexHistoryDebugDisabledHandler)
	}
	mux.Handle("/api/projects", authed(http.HandlerFunc(r.projectsHandler)))
	mux.Handle("/api/workspaces/resolve", authed(http.HandlerFunc(r.workspaceResolveHandler)))
	mux.Handle("/api/directories/list", authed(http.HandlerFunc(r.directoryListHandler)))
	mux.Handle("/api/files/read", authed(http.HandlerFunc(r.fileReadHandler)))
	mux.Handle("/api/file-uploads", authed(http.HandlerFunc(r.fileUploadHandler)))
	mux.Handle("/api/file-uploads/", authed(http.HandlerFunc(r.fileUploadHandler)))
	mux.Handle("/api/worktrees/list", authed(http.HandlerFunc(r.worktreeListHandler)))
	mux.Handle("/api/worktrees/branches", authed(http.HandlerFunc(r.worktreeBranchListHandler)))
	mux.Handle("/api/worktrees/create", authed(http.HandlerFunc(r.worktreeCreateHandler)))
	mux.Handle("/api/worktrees/delete", authed(http.HandlerFunc(r.worktreeDeleteHandler)))
	mux.Handle("/api/worktrees/prune", authed(http.HandlerFunc(r.worktreePruneHandler)))
	mux.Handle("/api/worktrees/cleanup", authed(http.HandlerFunc(r.worktreeCleanupHandler)))
	mux.Handle("/api/capabilities/list", authed(http.HandlerFunc(r.capabilityListHandler)))
	mux.Handle("/api/actions/list", authed(http.HandlerFunc(r.commandActionListHandler)))
	mux.Handle("/api/actions/run", authed(http.HandlerFunc(r.commandActionRunHandler)))
	mux.Handle("/api/git/status", authed(http.HandlerFunc(r.gitStatusHandler)))
	mux.Handle("/api/git/action", authed(http.HandlerFunc(r.gitActionHandler)))
	mux.Handle("/api/git/commit", authed(http.HandlerFunc(r.gitCommitHandler)))
	mux.Handle("/api/git/push", authed(http.HandlerFunc(r.gitPushHandler)))
	mux.Handle("/api/git/quick-publish", authed(http.HandlerFunc(r.gitQuickPublishHandler)))
	mux.Handle("/api/git/testflight/status", authed(http.HandlerFunc(r.gitTestFlightStatusHandler)))
	mux.Handle("/api/git/testflight/run", authed(http.HandlerFunc(r.gitTestFlightRunHandler)))
	mux.Handle("/api/git/pull-request", authed(http.HandlerFunc(r.gitPullRequestHandler)))
	mux.Handle("/api/git/pull-request/status", authed(http.HandlerFunc(r.gitPullRequestStatusHandler)))
	mux.Handle("/api/voice/transcribe", authed(http.HandlerFunc(r.voiceTranscribeHandler)))
	mux.Handle("/api/runtime/status", authed(http.HandlerFunc(r.runtimeStatusHandler)))
	mux.Handle("/api/app-server/config", authed(http.HandlerFunc(r.appServerConfigHandler)))
	mux.Handle("/api/app-server/history-media/", authed(http.HandlerFunc(r.appServerHistoryMediaHandler)))
	mux.Handle("/api/app-server/history-output/", authed(http.HandlerFunc(r.appServerHistoryOutputHandler)))
	mux.Handle("/api/app-server/ws", authed(http.HandlerFunc(r.appServerGatewayWS)))
	return logging(limitAPIRequestBodies(mux), r.monitor), r
}

func (r *Router) EnableTailscaleHostMetadata() {
	if r == nil || r.tailscaleHostLookup != nil {
		return
	}
	resolver := tailscaleinfo.NewResolver(time.Minute)
	r.tailscaleHostLookup = resolver.Lookup
}

// Shutdown releases the long-lived runtimes the router started. Call it after
// the HTTP server has drained: the resident Claude bridge spawns Claude Code
// children of its own, and killing it earlier would cut turns that in-flight
// requests are still watching.
func (r *Router) Shutdown() {
	if r == nil {
		return
	}
	if r.autoThreadTitles != nil {
		r.autoThreadTitles.Close()
	}
	r.runtimeStatus.Close()
	r.claudeBridge.shutdown()
	if r.tailcat != nil {
		r.tailcat.Close()
	}
}

func sameOriginOrNoOrigin(r *http.Request) bool {
	origin := strings.TrimSpace(r.Header.Get("Origin"))
	if origin == "" {
		return true
	}
	parsed, err := url.Parse(origin)
	if err != nil {
		return false
	}
	return strings.EqualFold(parsed.Host, r.Host)
}

func logging(next http.Handler, monitor *relayMonitor) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		if strings.HasPrefix(r.URL.Path, "/api/") && monitor != nil {
			monitor.beginHTTP()
		}
		next.ServeHTTP(rec, r)
		if strings.HasPrefix(r.URL.Path, "/api/") {
			duration := time.Since(start)
			log.Printf("%s %s remote=%s host=%s status=%d bytes=%d duration=%s write_duration=%s write_calls=%d", r.Method, redactedRequestURI(r.URL), requestRemoteHost(r), r.Host, rec.status, rec.bytes, duration.Round(time.Millisecond), rec.writeDuration.Round(time.Millisecond), rec.writeCalls)
			if monitor != nil {
				monitor.recordHTTP(relayHTTPSample{
					EndedAt:        time.Now().UTC(),
					Method:         r.Method,
					Path:           redactedRequestURI(r.URL),
					Remote:         requestRemoteHost(r),
					Host:           r.Host,
					Status:         rec.status,
					ResponseBytes:  rec.bytes,
					DurationMillis: duration.Milliseconds(),
					WriteMillis:    rec.writeDuration.Milliseconds(),
					WriteCalls:     rec.writeCalls,
				})
			}
		}
	})
}

func redactedRequestURI(u *url.URL) string {
	if u == nil {
		return ""
	}
	next := *u
	query := next.Query()
	for key := range query {
		switch strings.ToLower(key) {
		case "token", "access_token", "authorization", "pair_sig":
			query.Set(key, "<redacted>")
		}
	}
	next.RawQuery = query.Encode()
	return next.RequestURI()
}

func requestRemoteHost(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

type statusRecorder struct {
	http.ResponseWriter
	status        int
	bytes         int
	writeDuration time.Duration
	writeMax      time.Duration
	writeCalls    int
}

func (r *statusRecorder) WriteHeader(status int) {
	r.status = status
	r.ResponseWriter.WriteHeader(status)
}

func (r *statusRecorder) Write(data []byte) (int, error) {
	start := time.Now()
	n, err := r.ResponseWriter.Write(data)
	elapsed := time.Since(start)
	r.bytes += n
	r.writeDuration += elapsed
	if elapsed > r.writeMax {
		r.writeMax = elapsed
	}
	r.writeCalls++
	return n, err
}

func (r *statusRecorder) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	hijacker, ok := r.ResponseWriter.(http.Hijacker)
	if !ok {
		return nil, nil, fmt.Errorf("response writer 不支持 hijack")
	}
	r.status = http.StatusSwitchingProtocols
	return hijacker.Hijack()
}

func (r *statusRecorder) Flush() {
	if flusher, ok := r.ResponseWriter.(http.Flusher); ok {
		flusher.Flush()
	}
}

func (r *statusRecorder) Unwrap() http.ResponseWriter {
	return r.ResponseWriter
}

func (r *Router) healthz(w http.ResponseWriter, req *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "version": r.version})
}

func (r *Router) readyz(w http.ResponseWriter, req *http.Request) {
	results := r.doctor.RunReadiness(req.Context())
	results = appendReadinessCheck(results, r.appServerUpstreamReadinessCheck(req.Context()))
	// 可选 capability 的降级只作为 warning，不把基础会话链路误判为整体不可用。
	// status --json 读取同一 readyz，因此也能看到服务端本地禁用或依赖失败原因。
	results = r.capabilities.appendDoctorCheck(results)
	status := http.StatusOK
	if !results.OK {
		// liveness 与 readiness 分离：进程仍可通过 /healthz 被守护进程观察，
		// 但配置、Codex 或敏感文件检查失败时不能对客户端宣称已经可用。
		status = http.StatusServiceUnavailable
	}
	writeJSON(w, status, results)
}

func (r *Router) versionHandler(w http.ResponseWriter, req *http.Request) {
	host := tailscaleinfo.Host{}
	if r.tailscaleHostLookup != nil {
		host = r.tailscaleHostLookup(req.Context())
	}
	writeJSON(w, http.StatusOK, protocolcontract.CurrentVersionResponseWithTailscale(
		r.version,
		r.installationID,
		host.DNSName,
		host.DeviceName,
		r.capabilities.enabledNames(),
		r.capabilities.statuses(),
	))
}

func (r *Router) doctorHandler(w http.ResponseWriter, req *http.Request) {
	writeJSON(w, http.StatusOK, r.capabilities.appendDoctorCheck(r.doctor.Run(req.Context(), false)))
}

func (r *Router) codexHistoryDebugHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	if !r.cfg.Debug.EnableCodexHistory {
		writeError(w, http.StatusNotFound, "codex history debug endpoint disabled")
		return
	}
	limit := positiveLimit(req.URL.Query().Get("limit"))
	if limit == 0 {
		limit = 80
	}
	projectID := strings.TrimSpace(req.URL.Query().Get("project_id"))
	writeJSON(w, http.StatusOK, codexhistory.Diagnose(r.projects, r.sessions.ListUnsorted(), projectID, limit))
}

func (r *Router) codexHistoryDebugDisabledHandler(w http.ResponseWriter, req *http.Request) {
	writeError(w, http.StatusNotFound, "not found")
}

func (r *Router) projectsHandler(w http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	projectList := r.projects.List()
	log.Printf("projects response remote=%s host=%s projects=%d", requestRemoteHost(req), req.Host, len(projectList))
	writeJSON(w, http.StatusOK, map[string]any{"projects": projectList})
}

func positiveLimit(raw string) int {
	if raw == "" {
		return 0
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n <= 0 {
		return 0
	}
	if n > 300 {
		return 300
	}
	return n
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]any{"error": message})
}

func methodNotAllowed(w http.ResponseWriter) {
	writeError(w, http.StatusMethodNotAllowed, "method not allowed")
}
