package httpapi

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"github.com/gaixianggeng/mimi-remote/internal/agybridge"
	"github.com/gaixianggeng/mimi-remote/internal/appserver"
	"github.com/gaixianggeng/mimi-remote/internal/claudeenv"
	"github.com/gaixianggeng/mimi-remote/internal/cliinspect"
	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/debuglog"
	"github.com/gaixianggeng/mimi-remote/internal/setup"
)

var appServerAgyAllowedMethods = map[string]struct{}{
	"initialize":              {},
	"initialized":             {},
	"thread/list":             {},
	"thread/loaded/list":      {},
	"thread/start":            {},
	"thread/resume":           {},
	"thread/read":             {},
	"thread/turns/list":       {},
	"thread/items/list":       {},
	"thread/name/set":         {},
	"turn/start":              {},
	"turn/interrupt":          {},
	"model/list":              {},
	"account/rateLimits/read": {},
	"slashCommand/list":       {},
}

type agyAdapterProbe struct {
	cliPath           string
	cliAbsent         bool
	Status            string
	Path              string
	Version           string
	CLIVersion        string
	MinimumCLIVersion string
	Healthy           bool
	Error             string
	CheckedAt         time.Time
	Capabilities      *agybridge.AdapterCapabilities
}

type agyAuthProbeCache struct {
	path      string
	envKey    string
	state     agybridge.AgyAuthState
	message   string
	checkedAt time.Time
}

type agyAuthProbeFlight struct {
	key     string
	done    chan struct{}
	state   agybridge.AgyAuthState
	message string
}

const (
	agyAuthSignedInCacheTTL  = 2 * time.Minute
	agyAuthSignedOutCacheTTL = 5 * time.Second
	agyAuthUnknownCacheTTL   = 2 * time.Second
)

// 真实 `agy 1.5.14` 首次冷探测远端模型目录实测耗时约 7-10 秒；预留 15 秒避免正常已登录账号被误判为超时未知态（B11）。
var agyAuthProbeTimeout = 15 * time.Second

func (p agyAdapterProbe) supportsMethod(method string) bool {
	return p.Healthy && p.Capabilities != nil && p.Capabilities.Supports(method)
}

func (p agyAdapterProbe) fullAccessAvailable() bool {
	return p.Healthy && p.Capabilities != nil && p.Capabilities.FullAccess
}

func newAgyAdapterSupervisor() *claudeBridgeSupervisor {
	return newResidentAdapterSupervisor(residentAdapterSupervisorConfig{
		RuntimeID:      appServerRuntimeAgyID,
		DisplayName:    "Antigravity adapter",
		TempDirPrefix:  "mimi-agy",
		DebugComponent: "agy-adapter",
		BuildEnv: func(extra map[string]string) ([]string, []string) {
			environment := agybridge.BuildEnv(extra)
			return environment, claudeenv.ProxyValues(environment)
		},
	})
}

func agyAdapterFix(probe agyAdapterProbe) string {
	switch probe.Status {
	case "agy_missing":
		return "安装 Antigravity CLI (agy) 并在终端登录"
	case "agy_unsupported":
		return "升级 Antigravity CLI (agy)"
	case "agy_signed_out":
		return "在终端运行 agy 完成登录"
	case "agy_auth_unknown":
		return "请稍后重试，或在终端运行 agy 确认登录状态"
	default:
		return agybridge.InstallHint
	}
}

func (r *Router) checkAgyAuthStatusCached(agyPath string, env []string) (agybridge.AgyAuthState, string) {
	now := time.Now().UTC()
	envKey := agybridge.AgyAuthCacheKey(env)
	flightKey := agyPath + "\x00" + envKey
	r.agyMu.Lock()
	cached := r.agyAuth
	if cached.path == agyPath && cached.envKey == envKey && cached.state != "" && !cached.checkedAt.IsZero() {
		ttl := agyAuthSignedInCacheTTL
		switch cached.state {
		case agybridge.AgyAuthSignedOut:
			ttl = agyAuthSignedOutCacheTTL
		case agybridge.AgyAuthUnknown:
			ttl = agyAuthUnknownCacheTTL
		}
		if now.Sub(cached.checkedAt) < ttl {
			r.agyMu.Unlock()
			return cached.state, cached.message
		}
	}
	if r.agyAuthInFlight != nil && r.agyAuthInFlight.key == flightKey {
		flight := r.agyAuthInFlight
		r.agyMu.Unlock()
		<-flight.done
		return flight.state, flight.message
	}
	flight := &agyAuthProbeFlight{
		key:  flightKey,
		done: make(chan struct{}),
	}
	r.agyAuthInFlight = flight
	r.agyMu.Unlock()

	ctx, cancel := context.WithTimeout(context.Background(), agyAuthProbeTimeout)
	defer cancel()
	state, msg := agybridge.CheckAgyAuthStatus(ctx, agyPath, env)

	r.agyMu.Lock()
	r.agyAuth = agyAuthProbeCache{
		path:      agyPath,
		envKey:    envKey,
		state:     state,
		message:   msg,
		checkedAt: time.Now().UTC(),
	}
	flight.state = state
	flight.message = msg
	if r.agyAuthInFlight == flight {
		r.agyAuthInFlight = nil
	}
	close(flight.done)
	r.agyMu.Unlock()
	return state, msg
}

func (r *Router) refreshAgyAdapterProbe() agyAdapterProbe {
	probe := agyAdapterProbe{Status: "disabled"}
	if !r.cfg.Agy.Enabled {
		return r.setAgyAdapterProbe(probe)
	}
	bin := strings.TrimSpace(r.cfg.Agy.AdapterBin)
	path, ok := agybridge.ResolveBinary(bin)
	if !ok {
		probe.Path = bin
		probe.Status = "missing_command"
		probe.Error = "未找到 mimi-agy-adapter，可重新安装 Mimi Remote 或配置 agy.adapter_bin"
		return r.setAgyAdapterProbe(probe)
	}
	probe.Path = path

	env := agybridge.BuildEnv(r.cfg.Agy.Env)
	verCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	out, err := cliinspect.Stdout(verCtx, path, env, append(append([]string{}, r.cfg.Agy.Args...), "--version")...)
	cancel()
	if err != nil {
		probe.Status = "missing_version"
		probe.Error = agybridge.UpgradeMessage("")
		return r.setAgyAdapterProbe(probe)
	}
	version, ok := agybridge.ParseVersion(string(bytes.TrimSpace(out)))
	probe.Version = version
	if !ok || !agybridge.IsSupported(version) {
		probe.Status = "unsupported_version"
		probe.Error = agybridge.UpgradeMessage(version)
		return r.setAgyAdapterProbe(probe)
	}
	capabilities, err := agybridge.ReadAdapterCapabilities(context.Background(), path, r.cfg.Agy.Args, env)
	if err != nil {
		probe.Status = "missing_capabilities"
		probe.Error = "无法读取 Antigravity 适配器的能力声明：" + err.Error()
		return r.setAgyAdapterProbe(probe)
	}
	probe.Capabilities = &capabilities
	probe.MinimumCLIVersion = strings.TrimSpace(capabilities.Agy.MinimumVersion)

	candidate, err := setup.ResolveRuntime(context.Background(), setup.AgyRuntime(r.cfg.Agy, probe.MinimumCLIVersion, env))
	probe.CLIVersion, probe.cliPath = candidate.Version, candidate.Path
	if err != nil {
		probe.Status = "agy_missing"
		probe.cliAbsent = candidate.Path == ""
		probe.Error = "未检测到可用的 Antigravity CLI (agy)。请检查安装或配置的路径。"
		if errors.Is(err, setup.ErrRuntimeIncompatible) {
			probe.Status = "agy_unsupported"
			probe.Error = agybridge.AgyUpgradeMessage(candidate.Version, probe.MinimumCLIVersion)
		}
		return r.setAgyAdapterProbe(probe)
	}
	authState, authMsg := r.checkAgyAuthStatusCached(candidate.Path, env)
	switch authState {
	case agybridge.AgyAuthSignedOut:
		probe.Status = "agy_signed_out"
		probe.Error = authMsg
		return r.setAgyAdapterProbe(probe)
	case agybridge.AgyAuthUnknown:
		probe.Status = "agy_auth_unknown"
		probe.Error = authMsg
		return r.setAgyAdapterProbe(probe)
	}

	probe.Status = "ready"
	probe.Healthy = true
	return r.setAgyAdapterProbe(probe)
}

func (r *Router) setAgyAdapterProbe(probe agyAdapterProbe) agyAdapterProbe {
	r.agyMu.Lock()
	probe.CheckedAt = time.Now().UTC()
	r.agyProbe = probe
	r.agyMu.Unlock()
	if debuglog.Enabled() {
		methods := -1
		if probe.Capabilities != nil {
			methods = len(probe.Capabilities.Methods)
		}
		debuglog.Printf("agy-adapter", "probe bin=%s version=%s status=%s healthy=%t methods=%d error=%q",
			filepath.Base(probe.Path), probe.Version, probe.Status, probe.Healthy, methods, probe.Error)
	}
	return probe
}

func (r *Router) agyAdapterProbeSnapshot() agyAdapterProbe {
	r.agyMu.Lock()
	defer r.agyMu.Unlock()
	if r.agyProbe.CheckedAt.IsZero() {
		return agyAdapterProbe{Status: "unknown"}
	}
	return r.agyProbe
}

func (p agyAdapterProbe) launchEnv(cfg config.AgyConfig) map[string]string {
	env := agybridge.BuildEnvMap(cfg.Env)
	if p.cliPath != "" {
		env[agybridge.AgyBinaryEnvKey] = p.cliPath
	}
	return env
}

func (r *Router) invalidateAgyMissingProbe() agyAdapterProbe {
	r.agyMu.Lock()
	probe := r.agyProbe
	probe.Status = "agy_missing"
	probe.cliAbsent = true
	probe.Healthy = false
	probe.Error = "未检测到 Antigravity CLI (agy)。请先在电脑安装 agy 并完成登录。"
	probe.CheckedAt = time.Now().UTC()
	r.agyProbe = probe
	r.agyAuth = agyAuthProbeCache{}
	r.agyMu.Unlock()
	return probe
}

// currentAgyAdapterProbe 统一返回 config、runtime/status 与新 WS 握手共享的就绪状态（B13）。
// 每次读取都在微秒级校验 agy 可执行入口是否仍在；若二进制已消失，立即令就绪缓存失效，
// 消除 5 秒 TTL 窗口内三者结论不一致的问题。
func (r *Router) currentAgyAdapterProbe() agyAdapterProbe {
	return r.currentAgyAdapterProbeWithDiscovery(setup.NewRuntimeDiscovery())
}

func (r *Router) currentAgyAdapterProbeWithDiscovery(discovery setup.RuntimeDiscovery) agyAdapterProbe {
	if !r.cfg.Agy.Enabled {
		return r.agyAdapterProbeSnapshot()
	}
	probe := r.agyAdapterProbeSnapshot()
	ttl := claudeBridgeProbeCacheTTL
	if probe.Status == "agy_auth_unknown" {
		ttl = agyAuthUnknownCacheTTL
	}
	if probe.CheckedAt.IsZero() || time.Since(probe.CheckedAt) >= ttl {
		return r.refreshAgyAdapterProbe()
	}
	if probe.Status == "agy_missing" && !probe.cliAbsent {
		// An installed CLI failed inspection. Its continued presence is not a
		// reason to retry before the cached result expires.
		return probe
	}
	env := agybridge.BuildEnv(r.cfg.Agy.Env)
	req := setup.AgyRuntime(r.cfg.Agy, probe.MinimumCLIVersion, env)
	path := firstNonEmpty(probe.cliPath, os.Getenv(agybridge.AgyBinaryEnvKey), req.Pin, "agy")
	if _, err := discovery.LookupExecutable(context.Background(), req, path); err != nil {
		if probe.Healthy || probe.Status != "agy_missing" {
			return r.invalidateAgyMissingProbe()
		}
		return probe
	}
	if probe.Status == "agy_missing" {
		return r.refreshAgyAdapterProbe()
	}
	return probe
}

func (r *Router) agyChannelConfig(req *http.Request) appServerChannel {
	agySpec, _ := appServerRuntimeSpecFor(appServerRuntimeAgyID)
	probe := r.currentAgyAdapterProbe()
	methods := appServerAllowedMethodListForRuntime(agySpec.ID)
	if probe.Capabilities != nil {
		methods = filterAppServerMethods(methods, probe.Capabilities.Supports)
	}
	rateLimitsAvailable := probe.supportsMethod("account/rateLimits/read")
	if !rateLimitsAvailable {
		methods = removeAppServerMethod(methods, "account/rateLimits/read")
	}
	if !probe.supportsMethod("slashCommand/list") {
		methods = removeAppServerMethod(methods, "slashCommand/list")
	}
	if !probe.supportsMethod("thread/items/list") {
		methods = removeAppServerMethod(methods, "thread/items/list")
	}
	if !probe.supportsMethod("thread/name/set") {
		methods = removeAppServerMethod(methods, "thread/name/set")
	}

	capabilities := agySpec.Capabilities
	capabilities.RateLimits = rateLimitsAvailable
	capabilities.Rename = probe.supportsMethod("thread/name/set")

	policy := agySpec.Policy
	policy.ApprovalPolicies = append([]string{}, policy.ApprovalPolicies...)
	policy.SandboxModes = append([]string{}, policy.SandboxModes...)
	if probe.fullAccessAvailable() {
		policy.ApprovalPolicies = append(policy.ApprovalPolicies, "never")
		policy.SandboxModes = append(policy.SandboxModes, "danger-full-access")
	}

	return appServerChannel{
		ID:               agySpec.ID,
		RuntimeID:        agySpec.ID,
		Title:            "Antigravity",
		Provider:         "agy",
		Type:             "agy_acp_adapter",
		Protocol:         "app_server_jsonrpc_stdio_v1",
		Enabled:          true,
		GatewayWSURL:     r.appServerGatewayURLForRuntime(req, agySpec.ID),
		GatewayAvailable: probe.Healthy,
		Managed:          false,
		Experimental:     agySpec.Experimental,
		Lifecycle:        "per_connection",
		Bridge: &appServerBridgeMetadata{
			Name:              agybridge.AdapterName,
			Version:           probe.Version,
			MinimumVersion:    agybridge.MinimumVersion,
			CLIVersion:        probe.CLIVersion,
			MinimumCLIVersion: probe.MinimumCLIVersion,
			Path:              probe.Path,
			Status:            probe.Status,
			Healthy:           probe.Healthy,
			LastProbeError:    probe.Error,
			Fix:               agyAdapterFix(probe),
		},
		Methods:      methods,
		Capabilities: capabilities,
		Policy:       policy,
	}
}

func (r *Router) claimAgyForeground(sessionKey string, client *websocket.Conn) (*claudeForegroundLease, bool) {
	limit := r.cfg.Agy.MaxConcurrentSessions
	if limit <= 0 {
		limit = config.DefaultAgyMaxConcurrentSessions
	}
	lease := &claudeForegroundLease{sessionKey: sessionKey, client: client}
	r.agyMu.Lock()
	var previous *claudeForegroundLease
	if sessionKey != "" {
		previous = r.agyForeground[sessionKey]
	}
	var previousClient *websocket.Conn
	var previousUpstream io.Closer
	if previous != nil {
		previous.superseded = true
		lease.holdsSlot = previous.holdsSlot
		previous.holdsSlot = false
		lease.attachMu = previous.attachMu
		previousClient = previous.client
		previousUpstream = previous.upstream
	} else {
		lease.attachMu = &sync.Mutex{}
	}
	if !lease.holdsSlot {
		if r.activeAgySessions >= limit {
			r.agyMu.Unlock()
			return nil, false
		}
		r.activeAgySessions++
		lease.holdsSlot = true
	}
	if sessionKey != "" {
		if r.agyForeground == nil {
			r.agyForeground = map[string]*claudeForegroundLease{}
		}
		r.agyForeground[sessionKey] = lease
	}
	r.agyMu.Unlock()

	if previous != nil {
		log.Printf("agy gateway session reconnected; closing previous connection session=%s", sanitizeGatewayDiagnostic(sessionKey))
		if previousClient != nil {
			_ = previousClient.Close()
		}
		if previousUpstream != nil {
			_ = previousUpstream.Close()
		}
	}
	return lease, true
}

func (r *Router) setAgyForegroundUpstream(lease *claudeForegroundLease, upstream io.Closer) bool {
	r.agyMu.Lock()
	defer r.agyMu.Unlock()
	lease.upstream = upstream
	return !lease.superseded
}

func (r *Router) agyForegroundSuperseded(lease *claudeForegroundLease) bool {
	r.agyMu.Lock()
	defer r.agyMu.Unlock()
	return lease.superseded
}

func (r *Router) handOffAgyForegroundUpstream(lease *claudeForegroundLease) bool {
	r.agyMu.Lock()
	defer r.agyMu.Unlock()
	if lease.superseded {
		return false
	}
	lease.upstream = nil
	return true
}

func (r *Router) releaseAgyForeground(lease *claudeForegroundLease) {
	if lease == nil {
		return
	}
	r.agyMu.Lock()
	defer r.agyMu.Unlock()
	if lease.holdsSlot {
		lease.holdsSlot = false
		if r.activeAgySessions > 0 {
			r.activeAgySessions--
		}
	}
	if lease.sessionKey != "" && r.agyForeground[lease.sessionKey] == lease {
		delete(r.agyForeground, lease.sessionKey)
	}
}

func (r *Router) attachAgyAdapterSession(
	reader *bufio.Reader,
	upstream io.Writer,
	mu *sync.Mutex,
	sessionKey string,
	clientCursor uint64,
	hasClientCursor bool,
) (claudeBridgeAttachResult, error) {
	result := claudeBridgeAttachResult{}
	params := map[string]any{"sessionKey": sessionKey}
	serverCursor, instanceKnown := r.agyAdapter.resumeCursor(sessionKey)
	cursor, trustedClientCursor := uint64(0), false
	if instanceKnown && hasClientCursor && clientCursor <= serverCursor {
		cursor, trustedClientCursor = clientCursor, true
	}
	params["lastSeen"] = cursor
	preamble, err := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"method":  claudeBridgeAttachMethod,
		"params":  params,
	})
	if err != nil {
		return result, err
	}
	if err := writeStdioBridgeCompactedFrame(upstream, mu, preamble); err != nil {
		return result, err
	}
	line, oversize, err := readBridgeStdoutLine(reader, int(appServerGatewayReadLimit))
	if oversize {
		return result, errors.New("Antigravity adapter attach 应答超出大小上限")
	}
	if err != nil && len(bytes.TrimSpace(line)) == 0 {
		return result, fmt.Errorf("读取 Antigravity adapter attach 应答失败：%w", err)
	}
	var ack struct {
		Method string `json:"method"`
		Params struct {
			Kind       string `json:"kind"`
			CurrentSeq uint64 `json:"currentSeq"`
			FloorSeq   uint64 `json:"floorSeq"`
		} `json:"params"`
	}
	if err := json.Unmarshal(bytes.TrimSpace(line), &ack); err != nil {
		return result, fmt.Errorf("解析 Antigravity adapter attach 应答失败：%w", err)
	}
	if ack.Method != claudeBridgeAttachedMethod {
		return result, fmt.Errorf("Antigravity adapter attach 应答方法异常：%s", sanitizeGatewayDiagnostic(ack.Method))
	}
	renumbered := ack.Params.Kind != "resumed" || ack.Params.CurrentSeq < cursor
	result.resetClientCursor = hasClientCursor && (!trustedClientCursor || renumbered)
	if (instanceKnown || trustedClientCursor) && renumbered {
		r.agyAdapter.forgetCursor(sessionKey)
	}
	return result, nil
}

func (r *Router) appServerAgyGatewayWS(w http.ResponseWriter, req *http.Request) {
	client, err := r.upgrader.Upgrade(w, req, nil)
	if err != nil {
		log.Printf("agy gateway ws upgrade failed err=%v", err)
		return
	}
	defer client.Close()

	if !r.cfg.Agy.Enabled {
		writeGatewayRuntimeError(client, "AGY_DISABLED", "Antigravity runtime 未启用")
		return
	}
	probe := r.currentAgyAdapterProbe()
	if !probe.Healthy {
		minVer := agybridge.MinimumVersion
		if probe.Status == "agy_unsupported" && probe.MinimumCLIVersion != "" {
			minVer = probe.MinimumCLIVersion
		}
		writeGatewayRuntimeErrorWithData(client, "AGY_ADAPTER_UNAVAILABLE", firstNonEmpty(probe.Error, "Antigravity 适配器不可用"), map[string]any{
			"bridgeStatus":      probe.Status,
			"bridgeVersion":     probe.Version,
			"minimumVersion":    minVer,
			"cliVersion":        probe.CLIVersion,
			"minimumCLIVersion": probe.MinimumCLIVersion,
			"fix":               agyAdapterFix(probe),
		})
		return
	}

	sessionKey := claudeGatewaySessionKey(req)
	lease, ok := r.claimAgyForeground(sessionKey, client)
	if !ok {
		writeGatewayRuntimeError(client, "AGY_ADAPTER_LIMIT_EXCEEDED", "Antigravity 会话连接并发数已达上限，请稍后重试")
		return
	}
	defer r.releaseAgyForeground(lease)

	ctx, cancel := context.WithCancel(req.Context())
	defer cancel()
	bin := firstNonEmpty(probe.Path, strings.TrimSpace(r.cfg.Agy.AdapterBin))
	start := time.Now()
	if _, err := r.agyAdapter.ensure(bin, r.cfg.Agy.Args, probe.launchEnv(r.cfg.Agy)); err != nil {
		log.Printf("agy adapter ensure failed err=%v", err)
		writeGatewayRuntimeError(client, "AGY_ADAPTER_START_FAILED", "启动 Antigravity 适配器失败")
		return
	}
	upstream, cursorEpoch, err := r.agyAdapter.dial()
	if err != nil {
		log.Printf("agy adapter dial failed err=%v", err)
		writeGatewayRuntimeError(client, "AGY_ADAPTER_UNAVAILABLE", "连接 Antigravity 适配器失败")
		return
	}
	upstreamOwnedByObserver := false
	defer func() {
		if !upstreamOwnedByObserver {
			_ = upstream.Close()
		}
	}()
	if !r.setAgyForegroundUpstream(lease, upstream) {
		return
	}

	reader := bufio.NewReaderSize(upstream, 64*1024)
	var upstreamWriteMu sync.Mutex
	var observerEpoch uint64
	if sessionKey != "" {
		lease.attachMu.Lock()
		if r.agyForegroundSuperseded(lease) {
			lease.attachMu.Unlock()
			return
		}
		observerEpoch = r.stopResidentApprovalObserver(appServerRuntimeAgyID, sessionKey)
		clientCursor, hasClientCursor := claudeGatewayLastSeen(req)
		attachResult, attachErr := r.attachAgyAdapterSession(reader, upstream, &upstreamWriteMu, sessionKey, clientCursor, hasClientCursor)
		lease.attachMu.Unlock()
		if attachErr != nil {
			log.Printf("agy adapter attach failed session=%s err=%v", sanitizeGatewayDiagnostic(sessionKey), attachErr)
			writeGatewayRuntimeError(client, "AGY_ADAPTER_UNAVAILABLE", "连接 Antigravity 会话失败")
			return
		}
		if attachResult.resetClientCursor {
			payload, marshalErr := json.Marshal(map[string]any{
				"jsonrpc": "2.0",
				"method":  claudeReplayCursorResetMethod,
				"params":  map[string]any{"sequence": 0},
			})
			if marshalErr != nil || client.WriteMessage(websocket.TextMessage, payload) != nil {
				return
			}
		}
	}

	monitor := r.monitor.startGatewayConnection(requestRemoteHost(req), req.Host, "agy:"+filepath.Base(bin), time.Since(start))
	done := make(chan string, 3)
	var clientWriteMu sync.Mutex
	configureGatewayReadConn(client)
	policy := &appServerGatewayPolicy{
		router:                r,
		runtimeID:             appServerRuntimeAgyID,
		pendingThreads:        map[string]appServerGatewayPendingThreadRequest{},
		pendingServerRequests: map[string]appServerGatewayPendingServerRequest{},
		activeServerTurns:     map[string]struct{}{},
		allowedThreads:        map[string]appServerGatewayAllowedThread{},
	}
	defer func() {
		if !upstreamOwnedByObserver {
			policy.close()
		}
	}()

	go func() {
		done <- copyClientFramesToClaudeBridge(client, upstream, &clientWriteMu, &upstreamWriteMu, policy, monitor)
	}()
	upstreamReaderDone := make(chan string, 1)
	go func() {
		readerReason := copyClaudeBridgeFrames(
			ctx,
			reader,
			client,
			&clientWriteMu,
			policy,
			monitor,
			r.agyAdapter,
			sessionKey,
			cursorEpoch,
		)
		upstreamReaderDone <- readerReason
		done <- readerReason
	}()
	go func() {
		pingClientGateway(ctx, client, &clientWriteMu)
		done <- "ping_failed_or_context_done"
	}()

	reason := <-done
	cancel()
	_ = client.Close()
	_ = upstream.SetReadDeadline(time.Now())
	readerReleased := false
	select {
	case <-upstreamReaderDone:
		readerReleased = true
	case <-time.After(2 * time.Second):
	}
	_ = upstream.SetReadDeadline(time.Time{})

	observerStarted := readerReleased &&
		r.handOffAgyForegroundUpstream(lease) &&
		r.startResidentApprovalObserver(appServerRuntimeAgyID, sessionKey, upstream, &upstreamWriteMu, reader, policy, observerEpoch)
	if observerStarted {
		upstreamOwnedByObserver = true
	} else {
		r.releaseResidentApprovalObserverEpoch(appServerRuntimeAgyID, sessionKey, observerEpoch)
		_ = upstream.Close()
	}
	if monitor != nil {
		monitor.finish(reason)
	}
}

func (r *Router) probeAgyRuntime(ctx context.Context) runtimeAccountStatus {
	status := runtimeAccountStatus{
		ID:           "agy",
		Title:        "Antigravity",
		Enabled:      r.cfg.Agy.Enabled,
		State:        runtimeStateDisabled,
		Reason:       "disabled",
		LoginCommand: "agy",
	}
	if !r.cfg.Agy.Enabled {
		return status
	}
	status.State = runtimeStateUnavailable
	status.Reason = "adapter_unavailable"
	probe := r.currentAgyAdapterProbe()
	if !probe.Healthy {
		switch probe.Status {
		case "agy_missing", "agy_unsupported", "agy_auth_unknown":
			status.Reason = probe.Status
		case "agy_signed_out":
			status.State = runtimeStateSignedOut
			status.Reason = "agy_signed_out"
		}
		return status
	}

	connectCtx, cancelConnect := context.WithTimeout(ctx, claudeRuntimeProbeTimeout)
	defer cancelConnect()

	bin := firstNonEmpty(probe.Path, strings.TrimSpace(r.cfg.Agy.AdapterBin))
	ensureDone := make(chan error, 1)
	go func() {
		_, err := r.agyAdapter.ensure(bin, r.cfg.Agy.Args, probe.launchEnv(r.cfg.Agy))
		ensureDone <- err
	}()
	select {
	case <-connectCtx.Done():
		return status
	case err := <-ensureDone:
		if err != nil {
			return status
		}
	}
	status.StartedAt = r.agyAdapter.runningSince()
	if connectCtx.Err() != nil {
		return status
	}
	conn, _, err := r.agyAdapter.dial()
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
	initialization, err := client.Initialize(connectCtx)
	if err != nil {
		return status
	}
	status.Version = runtimeVersionFromUserAgent(initialization.UserAgent)
	status.State = runtimeStateAvailable
	status.Reason = ""

	if !probe.supportsMethod("account/rateLimits/read") {
		return status
	}
	if cached := r.cachedAgyRuntimeQuota(time.Now().UTC()); cached != nil {
		applyAgyRuntimeQuota(&status, cached)
		return status
	}

	type quotaProbeResult struct {
		limits runtimeRateLimitsEnvelope
		err    error
	}
	quotaCtx, cancelQuota := context.WithTimeout(
		context.WithoutCancel(ctx),
		agyRuntimeQuotaHardLimit,
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
		limits := normalizeRuntimeRateLimits(result.limits, "agy")
		r.storeAgyRuntimeQuota(limits)
		applyAgyRuntimeQuota(&status, limits)
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
					r.storeAgyRuntimeQuota(
						normalizeRuntimeRateLimits(result.limits, "agy"),
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

const agyRuntimeQuotaHardLimit = 22 * time.Second

func (r *Router) cachedAgyRuntimeQuota(now time.Time) *runtimeRateLimits {
	r.agyRuntimeQuotaMu.RLock()
	defer r.agyRuntimeQuotaMu.RUnlock()
	if r.agyRuntimeQuota == nil ||
		r.agyRuntimeQuotaCheckedAt.IsZero() ||
		now.Sub(r.agyRuntimeQuotaCheckedAt) < 0 ||
		now.Sub(r.agyRuntimeQuotaCheckedAt) >= runtimeStatusSuccessTTL {
		return nil
	}
	return r.agyRuntimeQuota
}

func (r *Router) storeAgyRuntimeQuota(limits *runtimeRateLimits) {
	if limits == nil || strings.EqualFold(limits.Availability, "unavailable") {
		return
	}
	r.agyRuntimeQuotaMu.Lock()
	r.agyRuntimeQuota = limits
	r.agyRuntimeQuotaCheckedAt = time.Now().UTC()
	r.agyRuntimeQuotaMu.Unlock()
}

func applyAgyRuntimeQuota(status *runtimeAccountStatus, limits *runtimeRateLimits) {
	if limits == nil {
		return
	}
	status.RateLimits = limits
	if limits.PlanType != "" {
		status.PlanType = limits.PlanType
	}
	if runtimeRateLimitsShowAuthenticated(limits) {
		status.State = runtimeStateConnected
		status.Reason = ""
	}
}
