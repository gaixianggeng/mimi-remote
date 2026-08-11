package httpapi

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/url"
	"sort"
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
	projects       *projects.Registry
	sessions       *session.Manager
	runtime        SessionRuntime
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
	// externalActivity 只读取同一 CODEX_HOME 内 Codex Desktop 的脱敏运行态。
	// 它与本进程 app-server runtime 分离，不能被用于 resume、审批或中断外部 turn。
	externalActivity externalActivitySource
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
	accountTokenUsageMu       sync.RWMutex
	accountTokenUsageResult   json.RawMessage
	accountTokenUsageCachedAt time.Time
	accountTokenUsageCacheTTL time.Duration
	// threadHandoffs 在 Mac 侧等待 Codex thread 空闲后执行一次短暂的
	// archive -> unarchive。thread/unsubscribe 只取消事件订阅，不能释放
	// resident app-server 持有的 writer lock，因此跨 App 交接必须由进程所有者完成。
	threadHandoffs        *appServerThreadHandoffCoordinator
	threadHandoffRecovery *appServerThreadHandoffRecoveryStore

	gatewayThreadsMu              sync.Mutex
	gatewayThreads                map[string]appServerGatewayAllowedThread
	codexGatewayMu                sync.Mutex
	activeCodexGateway            int
	gatewayHistoryBudgetMu        sync.Mutex
	gatewayHistoryGlobalBudget    appServerGatewayHistoryBudget
	claudeMu                      sync.Mutex
	claudeProbe                   appServerBridgeProbe
	activeClaudeBridge            int
	claudeBridge                  *claudeBridgeSupervisor
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
// 必须同时注入两条绝对路径。
type RouterOptions struct {
	GatewayTurnClaimStorePath      string
	ThreadHandoffRecoveryStorePath string
}

func NewRouter(cfg config.Config, registry *projects.Registry, manager *session.Manager, checker *doctor.Checker, version string) http.Handler {
	handler, _ := NewRouterWithRuntime(cfg, registry, manager, checker, version, nil)
	return handler
}

// NewRouterWithInstallationID 为生产入口注入启动阶段已加载的稳定安装身份。
// Router 只保留内存副本，确保高频 /api/version 探测不会读磁盘或连接 upstream。
func NewRouterWithInstallationID(cfg config.Config, registry *projects.Registry, manager *session.Manager, checker *doctor.Checker, version string, installationID string) http.Handler {
	handler, _ := NewRouterWithRuntimeAndInstallationID(cfg, registry, manager, checker, version, installationID, nil)
	return handler
}

// NewRouterWithRuntime also hands back the *Router so a caller that owns the
// process lifetime can shut down what the handler started. That matters now
// that the Claude bridge is resident: it survives individual connections by
// design, so nothing else would ever reap it.
func NewRouterWithRuntime(cfg config.Config, registry *projects.Registry, manager *session.Manager, checker *doctor.Checker, version string, runtime SessionRuntime) (http.Handler, *Router) {
	return NewRouterWithRuntimeAndInstallationID(cfg, registry, manager, checker, version, "", runtime)
}

// NewRouterWithRuntimeAndInstallationID 同时注入 runtime 与稳定安装身份。
// 保留旧构造器作为兼容包装，现有测试和内部调用无需一次性迁移。
func NewRouterWithRuntimeAndInstallationID(cfg config.Config, registry *projects.Registry, manager *session.Manager, checker *doctor.Checker, version string, installationID string, runtime SessionRuntime) (http.Handler, *Router) {
	return NewRouterWithRuntimeInstallationIDAndOptions(
		cfg,
		registry,
		manager,
		checker,
		version,
		installationID,
		runtime,
		RouterOptions{},
	)
}

// NewRouterWithRuntimeInstallationIDAndOptions 由 agentd 生产入口显式注入私有状态路径。
// 旧构造器保持纯内存默认值，避免单元测试意外读写当前用户目录。
func NewRouterWithRuntimeInstallationIDAndOptions(
	cfg config.Config,
	registry *projects.Registry,
	manager *session.Manager,
	checker *doctor.Checker,
	version string,
	installationID string,
	runtime SessionRuntime,
	options RouterOptions,
) (http.Handler, *Router) {
	// external activity 必须读取与共享 daemon 相同的 CODEX_HOME。否则自定义
	// CODEX_HOME 下 Desktop 已有 active turn 时，移动端会因为查错数据库而误放行写入。
	externalActivityDB := codexhistory.ExternalActivityDatabasePath(cfg.Codex.Env)
	externalActivity := externalActivitySource(codexhistory.NewExternalActivityTracker(externalActivityDB, registry))
	if strings.TrimSpace(options.GatewayTurnClaimStorePath) != "" {
		externalActivity = codexhistory.NewExternalActivityTrackerWithClaimStore(
			externalActivityDB,
			registry,
			options.GatewayTurnClaimStorePath,
		)
	}
	fileUploads := newFileUploadStore(defaultFileUploadRoot())
	r := &Router{
		cfg:            cfg,
		projects:       registry,
		sessions:       manager,
		runtime:        runtime,
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
		externalActivity:            externalActivity,
		tailscalePathLookup:         defaultTailscaleNetworkPathLookup,
		gatewayThreads:              map[string]appServerGatewayAllowedThread{},
		managedWorktrees:            map[string]managedWorktree{},
		managedWorktreeCleanupPlans: map[string]worktreeCleanupPlan{},
		managedWorktreePendingUses:  map[string]int{},
		gitTestFlightJobs:           map[string]*gitTestFlightReleaseJob{},
		accountTokenUsageCacheTTL:   defaultAccountTokenUsageCacheTTL,
		claudeBridge:                newClaudeBridgeSupervisor(),
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
	r.threadHandoffRecovery = newAppServerThreadHandoffRecoveryStore(options.ThreadHandoffRecoveryStorePath)
	if err := r.threadHandoffRecovery.LoadError(); err != nil {
		// fail closed：后续 MarkUnarchiveRequired 会持续失败，因此不会执行新的 archive。
		log.Printf("app-server thread handoff recovery store unavailable err=%v", err)
	}
	r.threadHandoffs = newAppServerThreadHandoffCoordinator(r)
	// 构造期间同步安装为 executing entry，再异步恢复。这样第一个 gateway 写请求
	// 也只能等待 unarchive 完成，不能抢先取消重启恢复。
	for _, threadID := range r.threadHandoffRecovery.ThreadIDs() {
		r.threadHandoffs.Schedule(threadID)
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
	mux.Handle(appServerThreadHandoffPath, authed(http.HandlerFunc(r.appServerThreadHandoffHandler)))
	mux.Handle("/api/app-server/external-activity", authed(http.HandlerFunc(r.externalActivityHandler)))
	mux.Handle("/api/app-server/history-media/", authed(http.HandlerFunc(r.appServerHistoryMediaHandler)))
	mux.Handle("/api/app-server/history-output/", authed(http.HandlerFunc(r.appServerHistoryOutputHandler)))
	mux.Handle("/api/app-server/ws", authed(http.HandlerFunc(r.appServerGatewayWS)))
	return logging(limitAPIRequestBodies(mux), r.monitor), r
}

// EnableTailscaleHostMetadata 只由生产 serve 入口启用。测试构造器默认不启动外部 CLI，
// 保证协议 golden fixture 和无 Tailscale 环境仍然稳定、快速。
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
	if r.threadHandoffs != nil {
		r.threadHandoffs.Close()
	}
	r.runtimeStatus.Close()
	r.claudeBridge.shutdown()
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

type sessionPageCursor struct {
	ID          string `json:"id"`
	UpdatedAtMS int64  `json:"updated_at_ms"`
}

func decodeSessionCursor(raw string) (sessionPageCursor, bool, error) {
	if strings.TrimSpace(raw) == "" {
		return sessionPageCursor{}, false, nil
	}
	data, err := base64.RawURLEncoding.DecodeString(raw)
	if err != nil {
		return sessionPageCursor{}, false, err
	}
	var cursor sessionPageCursor
	if err := json.Unmarshal(data, &cursor); err != nil {
		return sessionPageCursor{}, false, err
	}
	if cursor.ID == "" || cursor.UpdatedAtMS <= 0 {
		return sessionPageCursor{}, false, fmt.Errorf("invalid session cursor")
	}
	return cursor, true, nil
}

func encodeSessionCursor(item session.SessionSnapshot) string {
	cursor := sessionPageCursor{ID: item.ID, UpdatedAtMS: sessionUpdatedAtMS(item)}
	if cursor.ID == "" || cursor.UpdatedAtMS <= 0 {
		return ""
	}
	data, err := json.Marshal(cursor)
	if err != nil {
		return ""
	}
	return base64.RawURLEncoding.EncodeToString(data)
}

func activeSessionSnapshots(list []*session.Session, projectID string) []session.SessionSnapshot {
	return activeSessionSnapshotWindow(list, projectID, sessionPageCursor{}, false, 0)
}

func activeSessionSnapshotWindow(list []*session.Session, projectID string, cursor sessionPageCursor, hasCursor bool, limit int) []session.SessionSnapshot {
	capacity := len(list)
	if limit > 0 && limit < capacity {
		capacity = limit
	}
	out := make([]session.SessionSnapshot, 0, capacity)
	cursorID := ""
	cursorUpdatedAtMS := int64(0)
	if hasCursor {
		cursorID = cursor.ID
		cursorUpdatedAtMS = cursor.UpdatedAtMS
	}
	for _, item := range list {
		// 项目会话列表是 iPad 高频轮询入口，先按项目收窄再排序/分页，避免无关运行会话
		// 参与后续投影；全局列表仍保留所有 active session。
		if snapshot, ok := item.SnapshotIfProjectBeforeCursor(projectID, cursorID, cursorUpdatedAtMS); ok {
			out = appendSessionWindowCandidate(out, snapshot, limit)
		}
	}
	return out
}

func paginateSessions(items []session.SessionSnapshot, cursor sessionPageCursor, hasCursor bool, limit int) ([]session.SessionSnapshot, string, bool) {
	sortSessionsByUpdated(items)
	if hasCursor {
		filtered := items[:0]
		for _, item := range items {
			if sessionBeforeCursor(item, cursor) {
				filtered = append(filtered, item)
			}
		}
		items = filtered
	}
	if limit <= 0 || len(items) <= limit {
		return items, "", false
	}
	page := append([]session.SessionSnapshot(nil), items[:limit]...)
	return page, encodeSessionCursor(page[len(page)-1]), true
}

func sortSessionsByUpdated(items []session.SessionSnapshot) {
	sort.SliceStable(items, func(i, j int) bool {
		return sessionSortBefore(items[i], items[j])
	})
}

func appendSessionWindowCandidate(items []session.SessionSnapshot, candidate session.SessionSnapshot, limit int) []session.SessionSnapshot {
	if limit <= 0 {
		return append(items, candidate)
	}
	insertAt := len(items)
	for index, item := range items {
		if sessionSortBefore(candidate, item) {
			insertAt = index
			break
		}
	}
	if insertAt == len(items) && len(items) >= limit {
		return items
	}
	items = append(items, candidate)
	if insertAt < len(items)-1 {
		copy(items[insertAt+1:], items[insertAt:len(items)-1])
		items[insertAt] = candidate
	}
	if len(items) > limit {
		items = items[:limit]
	}
	return items
}

func sessionSortBefore(left, right session.SessionSnapshot) bool {
	leftUpdatedAt := sessionUpdatedAtMS(left)
	rightUpdatedAt := sessionUpdatedAtMS(right)
	if leftUpdatedAt == rightUpdatedAt {
		return left.ID > right.ID
	}
	return leftUpdatedAt > rightUpdatedAt
}

func sessionBeforeCursor(item session.SessionSnapshot, cursor sessionPageCursor) bool {
	updatedAtMS := sessionUpdatedAtMS(item)
	if updatedAtMS != cursor.UpdatedAtMS {
		return updatedAtMS < cursor.UpdatedAtMS
	}
	return item.ID < cursor.ID
}

func sessionUpdatedAtMS(item session.SessionSnapshot) int64 {
	if !item.UpdatedAt.IsZero() {
		return item.UpdatedAt.UnixMilli()
	}
	if !item.CreatedAt.IsZero() {
		return item.CreatedAt.UnixMilli()
	}
	return 0
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
