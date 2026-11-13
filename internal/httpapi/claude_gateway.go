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
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"github.com/gaixianggeng/mimi-remote/internal/claudebridge"
	"github.com/gaixianggeng/mimi-remote/internal/claudeenv"
	"github.com/gaixianggeng/mimi-remote/internal/config"
	"github.com/gaixianggeng/mimi-remote/internal/debuglog"
)

const claudeBridgePolicyErrorCode = -32081
const claudeBridgeProbeCacheTTL = 5 * time.Second

// Transport-level handshake with the resident bridge. Mirrors ATTACH_METHOD /
// ATTACHED_METHOD in bridges/claude/crates/bridge-core/src/server.rs.
const claudeBridgeAttachMethod = "_alleycat/attach"
const claudeBridgeAttachedMethod = "_alleycat/attached"
const claudeReplayCursorResetMethod = "_mimi/claudeReplayCursor/reset"

// claudeBridgeSeqField is the top-level stamp the bridge puts on every
// outbound frame so a reconnect can resume from a known point.
const claudeBridgeSeqField = "_alleycat_seq"

// claudeBridgeServerRequestReplayMethod is the notification a bridge sends on
// attach listing the server requests still waiting on the user.
const claudeBridgeServerRequestReplayMethod = "serverRequest/replay"

// claudeBridgeFrameSeq reads the replay sequence number off an upstream frame.
func claudeBridgeFrameSeq(payload []byte) (uint64, bool) {
	if !bytes.Contains(payload, []byte(`"`+claudeBridgeSeqField+`"`)) {
		return 0, false
	}
	var frame struct {
		Seq *uint64 `json:"_alleycat_seq"`
	}
	if err := json.Unmarshal(payload, &frame); err != nil || frame.Seq == nil {
		return 0, false
	}
	return *frame.Seq, true
}

type appServerBridgeProbe struct {
	Status    string
	Path      string
	Version   string
	Healthy   bool
	Error     string
	CheckedAt time.Time
	// Adapter 非空表示探测到的是 SDK 适配器；能力以它的声明为准，不按旧 bridge 的版本门槛推断。
	Adapter *claudebridge.AdapterCapabilities
}

// supportsMethod 判断已探测的 bridge 是否实现某个方法；旧 bridge 按版本门槛判断。
func (p appServerBridgeProbe) supportsMethod(method string, legacy func(string) bool) bool {
	if !p.Healthy {
		return false
	}
	if p.Adapter != nil {
		return p.Adapter.Supports(method)
	}
	return legacy(p.Version)
}

func (p appServerBridgeProbe) fullAccessAvailable() bool {
	if !p.Healthy {
		return false
	}
	if p.Adapter != nil {
		return p.Adapter.FullAccess
	}
	return claudebridge.SupportsFullAccess(p.Version)
}

func (p appServerBridgeProbe) bridgeName() string {
	if p.Adapter != nil {
		return claudebridge.AdapterName
	}
	return "alleycat-claude-bridge"
}

func (r *Router) refreshClaudeBridgeProbe(_ bool) appServerBridgeProbe {
	probe := appServerBridgeProbe{
		Status:    "disabled",
		CheckedAt: time.Now().UTC(),
	}
	if !r.cfg.Claude.Enabled {
		r.setClaudeBridgeProbe(probe)
		return probe
	}
	// An unset bridge_bin is no longer fatal: an installed app ships its own
	// bridge next to agentd, so the common case needs no configuration at all.
	bin := strings.TrimSpace(r.cfg.Claude.BridgeBin)
	path, ok := resolveClaudeBridgePath(bin, r.cfg.Claude.LegacyBridge)
	if !ok {
		probe.Path = bin
		if bin == "" {
			probe.Status = "invalid"
			probe.Error = "未随安装包提供 Claude bridge，且 claude.bridge_bin 未配置"
		} else {
			probe.Status = "missing_command"
			probe.Error = "找不到 Claude bridge，可配置绝对路径"
		}
		r.setClaudeBridgeProbe(probe)
		return probe
	}
	probe.Path = path
	// 版本门禁是协议安全边界，不能因为 cheap probe 跳过；--version 对兼容 bridge 是无副作用快速调用。
	var isAdapter bool
	probe.Version, isAdapter = probeClaudeBridgeVersion(path, r.cfg.Claude.Args, r.cfg.Claude.Env)
	if probe.Version == "" {
		probe.Status = "missing_version"
		probe.Error = claudebridge.UpgradeMessage("")
		r.setClaudeBridgeProbe(probe)
		return probe
	}
	if !claudebridge.IsSupported(probe.Version) {
		probe.Status = "unsupported_version"
		probe.Error = claudebridge.UpgradeMessage(probe.Version)
		r.setClaudeBridgeProbe(probe)
		return probe
	}
	if isAdapter {
		capabilities, err := probeClaudeAdapterCapabilities(path, r.cfg.Claude.Args, r.cfg.Claude.Env)
		if err != nil {
			probe.Status = "missing_capabilities"
			probe.Error = "无法读取 Claude 适配器的能力声明：" + err.Error()
			r.setClaudeBridgeProbe(probe)
			return probe
		}
		probe.Adapter = &capabilities
		// 适配器声明了 Claude Code 下限：已知过旧时整条通道标为不可用，客户端连接时就能看到
		// 升级提示，而不是等发出第一条消息才失败。找不到或无法确认版本时不在这里拦。
		if version, ok := r.claudeCode.version(r.cfg.Claude.Env); ok && !capabilities.ClaudeCodeSupported(version) {
			probe.Status = "claude_unsupported"
			probe.Error = claudebridge.ClaudeCodeUpgradeMessage(version, capabilities.ClaudeCode.MinimumVersion)
			r.setClaudeBridgeProbe(probe)
			return probe
		}
	}
	probe.Status = "ready"
	probe.Healthy = true
	r.setClaudeBridgeProbe(probe)
	return probe
}

func (r *Router) setClaudeBridgeProbe(probe appServerBridgeProbe) {
	r.claudeMu.Lock()
	r.claudeProbe = probe
	r.claudeMu.Unlock()
	if debuglog.Enabled() {
		methods := -1
		if probe.Adapter != nil {
			methods = len(probe.Adapter.Methods)
		}
		debuglog.Printf("claude-bridge", "probe bin=%s name=%s version=%s status=%s healthy=%t adapter_methods=%d error=%q",
			filepath.Base(probe.Path), probe.bridgeName(), probe.Version, probe.Status, probe.Healthy, methods, probe.Error)
	}
}

func (r *Router) claudeBridgeProbe() appServerBridgeProbe {
	r.claudeMu.Lock()
	defer r.claudeMu.Unlock()
	if r.claudeProbe.CheckedAt.IsZero() {
		return appServerBridgeProbe{Status: "unknown"}
	}
	return r.claudeProbe
}

func (r *Router) refreshClaudeBridgeProbeIfStale() {
	if !r.cfg.Claude.Enabled {
		return
	}
	r.claudeMu.Lock()
	checkedAt := r.claudeProbe.CheckedAt
	r.claudeMu.Unlock()
	if checkedAt.IsZero() || time.Since(checkedAt) >= claudeBridgeProbeCacheTTL {
		r.refreshClaudeBridgeProbe(false)
	}
}

// claudeBridgeFix 是给用户的修复建议：Claude Code 过旧时升级它；随安装包提供 bridge 的安装重新
// 安装 Mimi Remote；只有自行安装旧 bridge 的环境（Homebrew、Linux 发布包）才需要 cargo。
func claudeBridgeFix(probe appServerBridgeProbe) string {
	switch {
	case probe.Status == "claude_unsupported":
		return "在终端运行 claude update"
	case claudebridge.BundledAvailable():
		return "重新安装或升级 Mimi Remote"
	default:
		return claudebridge.InstallHint
	}
}

// resolveClaudeBridgePath finds the bridge to run: by default the SDK adapter
// shipped alongside agentd, or the old Rust bridge when the legacy switch is on.
// A config naming some other program (a locally built adapter, say) still gets
// exactly that one; see claudebridge.ResolveBinary for the full rule.
func resolveClaudeBridgePath(command string, legacy bool) (string, bool) {
	return claudebridge.ResolveBinary(command, legacy)
}

// probeClaudeBridgeVersion 返回版本号，以及输出是否来自 SDK 适配器。
func probeClaudeBridgeVersion(path string, args []string, env map[string]string) (string, bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, path, append(append([]string{}, args...), "--version")...)
	cmd.Env = buildClaudeBridgeEnv(env)
	output, err := cmd.Output()
	if err != nil {
		return "", false
	}
	trimmed := string(bytes.TrimSpace(output))
	version, ok := claudebridge.ParseVersion(trimmed)
	if !ok {
		return "", false
	}
	return version, claudebridge.IsAdapterVersionOutput(trimmed)
}

func probeClaudeAdapterCapabilities(path string, args []string, env map[string]string) (claudebridge.AdapterCapabilities, error) {
	return claudebridge.ReadAdapterCapabilities(context.Background(), path, args, buildClaudeBridgeEnv(env))
}

func (r *Router) appServerClaudeGatewayWS(w http.ResponseWriter, req *http.Request) {
	client, err := r.upgrader.Upgrade(w, req, nil)
	if err != nil {
		log.Printf("claude gateway ws upgrade failed err=%v", err)
		return
	}
	defer client.Close()

	if !r.cfg.Claude.Enabled {
		writeGatewayRuntimeError(client, "CLAUDE_DISABLED", "Claude Code runtime 未启用")
		return
	}
	// 直连 WS 可能不经过 config 接口；握手前按 TTL 重探，避免复用启动时的旧 probe 状态。
	r.refreshClaudeBridgeProbeIfStale()
	probe := r.claudeBridgeProbe()
	if !probe.Healthy {
		code := "CLAUDE_BRIDGE_UNAVAILABLE"
		switch probe.Status {
		case "missing_version":
			code = "CLAUDE_BRIDGE_VERSION_UNKNOWN"
		case "unsupported_version":
			code = "CLAUDE_BRIDGE_VERSION_UNSUPPORTED"
		case "claude_unsupported":
			code = "CLAUDE_CODE_VERSION_UNSUPPORTED"
		}
		writeGatewayRuntimeErrorWithData(client, code, firstNonEmpty(probe.Error, "Claude bridge 不可用"), map[string]any{
			"bridgeStatus":   probe.Status,
			"bridgeVersion":  probe.Version,
			"minimumVersion": claudebridge.MinimumVersion,
			"fix":            claudeBridgeFix(probe),
		})
		return
	}
	// The bridge outlives this connection, so a client that names a session
	// resumes the one it had; an unnamed client gets an isolated session and
	// today's semantics.
	sessionKey := claudeGatewaySessionKey(req)
	lease, ok := r.claimClaudeForeground(sessionKey, client)
	if !ok {
		writeGatewayRuntimeError(client, "CLAUDE_BRIDGE_LIMIT_EXCEEDED", "Claude bridge 并发数已达上限，请稍后重试")
		return
	}
	defer r.releaseClaudeForeground(lease)

	ctx, cancel := context.WithCancel(req.Context())
	defer cancel()
	bin := firstNonEmpty(probe.Path, strings.TrimSpace(r.cfg.Claude.BridgeBin))
	start := time.Now()
	if _, err := r.claudeBridge.ensure(
		bin,
		r.cfg.Claude.Args,
		claudeBridgeRuntimeEnv(r.cfg.Claude, probe.Adapter != nil),
	); err != nil {
		log.Printf("claude bridge ensure failed err=%v", err)
		writeGatewayRuntimeError(client, "CLAUDE_BRIDGE_START_FAILED", "启动 Claude bridge 失败")
		return
	}
	upstream, bridgeCursorEpoch, err := r.claudeBridge.dial()
	if err != nil {
		log.Printf("claude bridge dial failed err=%v", err)
		writeGatewayRuntimeError(client, "CLAUDE_BRIDGE_UNAVAILABLE", "连接 Claude bridge 失败")
		return
	}
	// observer 接管后这条 bridge 连接要比本次 HTTP 请求活得更久，不能由 handler 关闭。
	upstreamOwnedByObserver := false
	defer func() {
		if !upstreamOwnedByObserver {
			upstream.Close()
		}
	}()
	if !r.setClaudeForegroundUpstream(lease, upstream) {
		return
	}

	reader := bufio.NewReaderSize(upstream, 64*1024)
	var upstreamWriteMu sync.Mutex
	var observerEpoch uint64
	if sessionKey != "" {
		lease.attachMu.Lock()
		if r.claudeForegroundSuperseded(lease) {
			// 同名会话的新连接已经接管。这里再 attach 会把 bridge 会话切回本连接。
			lease.attachMu.Unlock()
			return
		}
		// 新客户端自己 attach 同一个 bridge 会话并拿到 serverRequest/replay，
		// 离线期间的观察连接必须先让位，避免两条连接同时读同一个会话。
		observerEpoch = r.stopClaudeApprovalObserver(sessionKey)
		clientCursor, hasClientCursor := claudeGatewayLastSeen(req)
		attachResult, err := r.attachClaudeBridgeSession(
			reader,
			upstream,
			&upstreamWriteMu,
			sessionKey,
			clientCursor,
			hasClientCursor,
		)
		lease.attachMu.Unlock()
		if err != nil {
			log.Printf("claude bridge attach failed session=%s err=%v", sanitizeGatewayDiagnostic(sessionKey), err)
			writeGatewayRuntimeError(client, "CLAUDE_BRIDGE_UNAVAILABLE", "连接 Claude bridge 会话失败")
			return
		}
		if attachResult.resetClientCursor {
			// bridge 重启或会话重新编号后，旧 sequence 不能继续单调累计。必须先通知
			// App 覆盖本地 cursor，再转发新 epoch 的回放帧。
			payload, marshalErr := json.Marshal(map[string]any{
				"jsonrpc": "2.0",
				"method":  claudeReplayCursorResetMethod,
				"params":  map[string]any{"sequence": 0},
			})
			if marshalErr != nil || client.WriteMessage(websocket.TextMessage, payload) != nil {
				log.Printf("claude bridge cursor reset notification failed session=%s", sanitizeGatewayDiagnostic(sessionKey))
				return
			}
		}
	}

	monitor := r.monitor.startGatewayConnection(requestRemoteHost(req), req.Host, "claude:"+filepath.Base(bin), time.Since(start))
	done := make(chan string, 3)
	var clientWriteMu sync.Mutex
	configureGatewayReadConn(client)
	policy := &appServerGatewayPolicy{
		router:                r,
		runtimeID:             "claude",
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
			r.claudeBridge,
			sessionKey,
			bridgeCursorEpoch,
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
	// 取消 context 不能中断已经阻塞在 net.Conn.Read 的旧 goroutine。先用一次性
	// deadline 唤醒它并确认退出，再把同一个 bufio.Reader 交给 observer。
	_ = upstream.SetReadDeadline(time.Now())
	readerReleased := false
	select {
	case <-upstreamReaderDone:
		readerReleased = true
	case <-time.After(2 * time.Second):
	}
	_ = upstream.SetReadDeadline(time.Time{})
	// 客户端走了不等于审批结束：把 bridge 连接交给只读观察者，它继续接住
	// 离线期间到达的审批请求并触发提醒。被同名新连接接管时客户端并没有离开，
	// 不需要观察者，也不能为它补发离线提醒。
	observerStarted := readerReleased && r.handOffClaudeForegroundUpstream(lease) && r.startClaudeApprovalObserver(
		sessionKey,
		upstream,
		&upstreamWriteMu,
		reader,
		policy,
		observerEpoch,
	)
	if observerStarted {
		upstreamOwnedByObserver = true
	} else {
		r.releaseClaudeApprovalObserverEpoch(sessionKey, observerEpoch)
		_ = upstream.Close()
	}
	if monitor != nil {
		monitor.finish(reason)
	}
}

// claudeGatewaySessionKey reads the client's resumable-session name.
//
// `session` names it outright. Absent that, the thread the client opened is
// the right resume unit: a thread is what the user thinks of as "the task
// still running", and it is what they expect to find alive after the phone
// drops off the network. Clients that send neither keep the pre-resident
// behaviour: a fresh bridge session per connection, with nothing replayed.
func claudeGatewaySessionKey(req *http.Request) string {
	query := req.URL.Query()
	if raw := strings.TrimSpace(query.Get("session")); raw != "" {
		return sanitizedClaudeSessionKey(raw)
	}
	return sanitizedClaudeSessionKey(strings.TrimSpace(query.Get("thread_id")))
}

// claudeGatewayLastSeen 是 iOS 已完成本地投影的 turn 边界，不是 Go
// `WriteMessage` 成功的高水位。只有客户端确认过的 cursor 才能安全跳过帧。
func claudeGatewayLastSeen(req *http.Request) (uint64, bool) {
	raw := strings.TrimSpace(req.URL.Query().Get("last_seen"))
	if raw == "" {
		return 0, false
	}
	seq, err := strconv.ParseUint(raw, 10, 64)
	if err != nil {
		return 0, false
	}
	return seq, true
}

// sanitizedClaudeSessionKey drops anything that is not a short, plain
// identifier. The key is client-chosen and travels into the bridge's session
// registry and back out into logs, so it must carry no framing or control
// characters. Rejecting degrades to an unnamed session rather than failing the
// connection.
func sanitizedClaudeSessionKey(key string) string {
	if key == "" || len(key) > 128 {
		return ""
	}
	for _, c := range key {
		isSafe := c == '-' || c == '_' ||
			(c >= '0' && c <= '9') ||
			(c >= 'a' && c <= 'z') ||
			(c >= 'A' && c <= 'Z')
		if !isSafe {
			return ""
		}
	}
	return key
}

// attachClaudeBridgeSession performs the socket handshake that binds this
// connection to a named bridge session. A client-confirmed cursor is preferred;
// Go's write high-water mark is only an instance/upper-bound check.
type claudeBridgeAttachResult struct {
	resetClientCursor bool
}

func (r *Router) attachClaudeBridgeSession(
	reader *bufio.Reader,
	upstream io.Writer,
	mu *sync.Mutex,
	sessionKey string,
	clientCursor uint64,
	hasClientCursor bool,
) (claudeBridgeAttachResult, error) {
	result := claudeBridgeAttachResult{}
	params := map[string]any{"sessionKey": sessionKey}
	serverCursor, bridgeInstanceKnown := r.claudeBridge.resumeCursor(sessionKey)
	cursor, trustedClientCursor := uint64(0), false
	switch {
	case bridgeInstanceKnown && hasClientCursor && clientCursor <= serverCursor:
		// 客户端确认优先。serverCursor 只用来证明该序号属于当前 bridge
		// 实例，不能替代客户端确认。
		cursor, trustedClientCursor = clientCursor, true
	}
	// 命名 attach 永远明确 cursor。没有能被当前 bridge 实例证明的客户端
	// cursor 时从 0 开始；省略 lastSeen 会被 bridge 解释成“只看未来事件”，
	// 恰好漏掉 App 断线期间已经写入 ring 的后台结果。
	params["lastSeen"] = cursor
	log.Printf(
		"claude bridge attach session=%s cursor=%d trusted_client_cursor=%t bridge_instance_known=%t",
		sanitizeGatewayDiagnostic(sessionKey), cursor, trustedClientCursor, bridgeInstanceKnown,
	)
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
		return result, errors.New("Claude bridge attach 应答超出大小上限")
	}
	if err != nil && len(bytes.TrimSpace(line)) == 0 {
		return result, fmt.Errorf("读取 Claude bridge attach 应答失败：%w", err)
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
		return result, fmt.Errorf("解析 Claude bridge attach 应答失败：%w", err)
	}
	if ack.Method != claudeBridgeAttachedMethod {
		return result, fmt.Errorf("Claude bridge attach 应答方法异常：%s", sanitizeGatewayDiagnostic(ack.Method))
	}
	if ack.Params.Kind == "driftReload" {
		// The turn ran on past what the replay ring holds. Nothing is replayed,
		// so the client only sees events from here on and has to rehydrate the
		// thread itself — which it already does on every reconnect.
		log.Printf("claude bridge session drifted past replay window session=%s floor=%d",
			sanitizeGatewayDiagnostic(sessionKey), ack.Params.FloorSeq)
	}
	// Only "resumed" means the bridge is still counting in the sequence our
	// cursor came from. Anything else is a renumbered session, and keeping the
	// old cursor is worse than having none: the replay ring answers a cursor
	// above its current sequence with an empty slice and no error, so the next
	// attach would report "resumed" while silently skipping everything the new
	// session had produced.
	renumbered := ack.Params.Kind != "resumed" || ack.Params.CurrentSeq < cursor
	result.resetClientCursor = hasClientCursor && (!trustedClientCursor || renumbered)
	if (bridgeInstanceKnown || trustedClientCursor) && renumbered {
		log.Printf("claude bridge session renumbered; dropping resume cursor session=%s kind=%s cursor=%d current=%d",
			sanitizeGatewayDiagnostic(sessionKey), sanitizeGatewayDiagnostic(ack.Params.Kind), cursor, ack.Params.CurrentSeq)
		r.claudeBridge.forgetCursor(sessionKey)
	}
	return result, nil
}

func copyClientFramesToClaudeBridge(client *websocket.Conn, stdin io.Writer, clientWriteMu *sync.Mutex, stdinWriteMu *sync.Mutex, policy *appServerGatewayPolicy, monitor *relayGatewayConnMonitor) string {
	for {
		messageType, payload, err := client.ReadMessage()
		if err != nil {
			return gatewayCloseReason("client_read", err)
		}
		policyStart := time.Now()
		forwardPayload, policyErr := policy.validateClientFrame(messageType, payload)
		policyDuration := time.Since(policyStart)
		if policyErr != nil {
			if monitor != nil {
				monitor.recordPolicyError("client_to_upstream", policy.runtimeID, payload, policyErr, policyDuration)
			}
			if !writeGatewayPolicyError(client, clientWriteMu, policyErr) {
				return "client_policy_error_write_failed"
			}
			if policyErr.resetConnection {
				// 新连接用新的 policy；bridge 不会把旧连接的响应交给新连接，
				// 断线重放的旧响应也因没有在途请求认领而被丢弃。
				return appServerGatewayTrackingExhaustedReason
			}
			continue
		}
		compacted, err := compactJSONLine(forwardPayload)
		if err != nil {
			return gatewayCloseReason("bridge_stdin_encode", err)
		}
		requestID := ""
		if monitor != nil {
			requestID = monitor.beginRPCRequest(compacted, len(compacted))
		}
		writeStart := time.Now()
		err = writeStdioBridgeCompactedFrame(stdin, stdinWriteMu, compacted)
		if err != nil {
			if monitor != nil {
				monitor.cancelRPCRequest(requestID)
			}
			return gatewayCloseReason("bridge_stdin_write", err)
		}
		if monitor != nil {
			monitor.recordForward("client_to_upstream", len(payload), len(compacted), policyDuration, time.Since(writeStart), compacted)
		}
		// 与 Codex 网关同一触发点：首条成功写给 bridge 的 turn/start 消费新线程的
		// 标题资格。标题写回走 bridge 的独立匿名连接，这里只负责给发起会话的
		// 移动端补发 thread/name/updated。
		policy.router.scheduleAutoThreadTitleFromMessage(compacted, policy, autoThreadTitleClientNotifier(client, clientWriteMu))
	}
}

func copyClaudeBridgeFrames(ctx context.Context, reader *bufio.Reader, client *websocket.Conn, clientWriteMu *sync.Mutex, policy *appServerGatewayPolicy, monitor *relayGatewayConnMonitor, supervisor *claudeBridgeSupervisor, sessionKey string, bridgeCursorEpoch uint64) string {
	// bufio.Scanner 在单行超过 buffer 上限时会以 ErrTooLong 终止扫描，等于让一条超大
	// 帧（例如一次超大文件 Read 的 base64 输出）撕掉整条 WS 连接、触发客户端重连循环。
	// 改用有界逐行读取：超过上限的单帧只丢弃并记诊断，连接继续存活。上限沿用客户端
	// WS 读上限——比它更大的帧客户端本就无法接收，丢弃是唯一安全选择。
	maxLine := int(appServerGatewayReadLimit)
	for {
		select {
		case <-ctx.Done():
			return "context_done"
		default:
		}
		line, oversize, err := readBridgeStdoutLine(reader, maxLine)
		if oversize {
			log.Printf("claude bridge stdout line exceeded %d bytes; dropping frame to keep connection alive", maxLine)
			if monitor != nil {
				monitor.recordDropped("upstream_to_client", maxLine, 0)
			}
		} else if payload := bytes.TrimSpace(line); len(payload) > 0 {
			if reason, ok := forwardClaudeBridgeFrame(payload, client, clientWriteMu, policy, monitor); ok {
				return reason
			}
			// Only frames we finished handling advance the cursor, so whatever
			// died in flight when the socket broke gets replayed. Frames the
			// policy dropped count as handled: replaying them would only get
			// them dropped again.
			if sessionKey != "" {
				if seq, ok := claudeBridgeFrameSeq(payload); ok {
					supervisor.noteDelivered(sessionKey, seq, bridgeCursorEpoch)
				}
			}
		}
		if err != nil {
			if err == io.EOF {
				return "bridge_stdout_closed"
			}
			log.Printf("claude bridge stdout read error err=%v", err)
			return gatewayCloseReason("bridge_stdout_read", err)
		}
	}
}

// forwardClaudeBridgeFrame runs one upstream frame through the policy layer and
// forwards it to the client. It returns a non-empty close reason + true only
// when the caller must tear the connection down (client write failed).
func forwardClaudeBridgeFrame(payload []byte, client *websocket.Conn, clientWriteMu *sync.Mutex, policy *appServerGatewayPolicy, monitor *relayGatewayConnMonitor) (string, bool) {
	policyStart := time.Now()
	forwardPayload, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, payload)
	policyDuration := time.Since(policyStart)
	if policyErr != nil {
		if monitor != nil {
			monitor.recordPolicyError("upstream_to_client", policy.runtimeID, payload, policyErr, policyDuration)
		}
		if !writeGatewayPolicyError(client, clientWriteMu, policyErr) {
			return "upstream_policy_error_write_failed", true
		}
		return "", false
	}
	if !forward {
		if monitor != nil {
			monitor.recordDropped("upstream_to_client", len(payload), policyDuration)
		}
		return "", false
	}
	frame := append([]byte(nil), forwardPayload...)
	writeStart := time.Now()
	if err := writeWebSocketFrame(client, clientWriteMu, websocket.TextMessage, frame); err != nil {
		return gatewayCloseReason("client_write", err), true
	}
	if monitor != nil {
		monitor.recordForward("upstream_to_client", len(payload), len(frame), policyDuration, time.Since(writeStart), frame)
	}
	return "", false
}

// readBridgeStdoutLine reads one '\n'-terminated line from reader while bounding
// resident memory to ~max bytes. When a single line exceeds max the excess is
// drained to the newline and the function returns oversize=true with a nil line,
// so the caller can drop that one frame without tearing down the connection.
// The trailing io.EOF (line without a final newline) is returned alongside any
// bytes read so the caller can process the last frame before closing.
func readBridgeStdoutLine(reader *bufio.Reader, max int) ([]byte, bool, error) {
	var buf []byte
	oversize := false
	for {
		chunk, err := reader.ReadSlice('\n')
		if len(chunk) > 0 && !oversize {
			buf = append(buf, chunk...)
			if max > 0 && len(buf) > max {
				oversize = true
				buf = nil // release; an oversized frame is never forwarded
			}
		}
		if err == bufio.ErrBufferFull {
			continue
		}
		if oversize {
			return nil, true, err
		}
		return buf, false, err
	}
}

func writeStdioBridgeCompactedFrame(stdin io.Writer, mu *sync.Mutex, compacted []byte) error {
	if mu != nil {
		mu.Lock()
		defer mu.Unlock()
	}
	if _, err := stdin.Write(compacted); err != nil {
		return err
	}
	if _, err := stdin.Write([]byte("\n")); err != nil {
		return err
	}
	return nil
}

func compactJSONLine(payload []byte) ([]byte, error) {
	var value any
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.UseNumber()
	if err := decoder.Decode(&value); err != nil {
		return nil, fmt.Errorf("JSON-RPC frame 无效")
	}
	compacted, err := json.Marshal(value)
	if err != nil {
		return nil, fmt.Errorf("JSON-RPC frame 重编码失败：%w", err)
	}
	return compacted, nil
}

func pingClientGateway(ctx context.Context, client *websocket.Conn, clientWriteMu *sync.Mutex) {
	ticker := time.NewTicker(appServerGatewayPingPeriod)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := writeWebSocketControl(client, clientWriteMu, websocket.PingMessage, nil, appServerGatewayWriteWindow); err != nil {
				return
			}
		}
	}
}

// claudeAdapterLogLevelEnv 控制 SDK 适配器输出到 stderr 的日志级别。agentd 默认让它输出
// debug 行，由 captureClaudeBridgeStderr 决定是否落盘（只在详细记录窗口内）；用户在
// claude.env 里显式设置的级别优先。旧 Rust bridge 不认这个变量，没有影响。
const claudeAdapterLogLevelEnv = "MIMI_CLAUDE_ADAPTER_LOG"
const claudeAdapterTurnHintsEnv = "MIMI_CLAUDE_TURN_HINTS_ENABLED"

func claudeBridgeRuntimeEnv(cfg config.ClaudeConfig, isAdapter bool) map[string]string {
	env := make(map[string]string, len(cfg.Env)+1)
	for key, value := range cfg.Env {
		env[key] = value
	}
	if isAdapter {
		env[claudeAdapterTurnHintsEnv] = strconv.FormatBool(cfg.TurnHintsAreEnabled())
	}
	return env
}

func buildClaudeBridgeEnv(extra map[string]string) []string {
	environment := claudeenv.Build(extra)
	for _, entry := range environment {
		if strings.HasPrefix(entry, claudeAdapterLogLevelEnv+"=") {
			return environment
		}
	}
	return append(environment, claudeAdapterLogLevelEnv+"=debug")
}

// claudeBridgeDebugLine 识别适配器的 debug / trace 行（格式 "[mimi-claude-adapter] debug …"）。
func claudeBridgeDebugLine(line string) bool {
	_, rest, ok := strings.Cut(line, "] ")
	return ok && (strings.HasPrefix(rest, "debug ") || strings.HasPrefix(rest, "trace "))
}

// captureClaudeBridgeStderr 把 bridge 的 stderr 分流：详细记录窗口内全部写进本机调试日志；
// debug / trace 行只进调试日志，其余照旧进标准日志。
func captureClaudeBridgeStderr(stderr io.Reader, sensitiveValues []string) {
	scanner := bufio.NewScanner(stderr)
	scanner.Buffer(make([]byte, 0, 64<<10), 1<<20)
	for scanner.Scan() {
		line := sanitizeClaudeBridgeDiagnostic(scanner.Text(), sensitiveValues)
		if line == "" {
			continue
		}
		debuglog.Printf("claude-bridge", "%s", line)
		if !claudeBridgeDebugLine(line) {
			log.Printf("claude bridge stderr: %s", line)
		}
	}
	if err := scanner.Err(); err != nil {
		log.Printf("claude bridge stderr scanner error err=%v", err)
		// 超长行让 Scanner 停下后也要继续排空管道，否则 bridge 写 stderr 会被阻塞。
		_, _ = io.Copy(io.Discard, stderr)
	}
}

var diagnosticURLUserinfoPattern = regexp.MustCompile(`(?i)([a-z][a-z0-9+.-]*://)[^/@\s]+@`)

func sanitizeClaudeBridgeDiagnostic(value string, sensitiveValues []string) string {
	line := value
	for _, sensitive := range sensitiveValues {
		if sensitive != "" {
			line = strings.ReplaceAll(line, sensitive, "<redacted proxy>")
		}
	}
	line = diagnosticURLUserinfoPattern.ReplaceAllString(line, `${1}<redacted>@`)
	return sanitizeGatewayDiagnostic(line)
}

func sanitizeGatewayDiagnostic(value string) string {
	line := strings.TrimSpace(value)
	if line == "" {
		return ""
	}
	lower := strings.ToLower(line)
	for _, marker := range []string{"token", "secret", "password", "api_key", "apikey", "authorization", "bearer"} {
		if strings.Contains(lower, marker) {
			return "<redacted sensitive diagnostic>"
		}
	}
	return trimRelayString(line, 300)
}

func writeGatewayRuntimeError(conn *websocket.Conn, code string, message string) {
	writeGatewayRuntimeErrorWithData(conn, code, message, nil)
}

func writeGatewayRuntimeErrorWithData(conn *websocket.Conn, code string, message string, details map[string]any) {
	data := map[string]any{"code": code}
	for key, value := range details {
		if value == nil || value == "" {
			continue
		}
		data[key] = value
	}
	payload := map[string]any{
		"jsonrpc": "2.0",
		"id":      nil,
		"error": map[string]any{
			"code":    claudeBridgePolicyErrorCode,
			"message": code + ": " + message,
			"data":    data,
		},
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		return
	}
	_ = conn.SetWriteDeadline(time.Now().Add(appServerGatewayWriteWindow))
	_ = conn.WriteMessage(websocket.TextMessage, raw)
}

func gatewayProcessID(cmd *exec.Cmd) int {
	if cmd == nil || cmd.Process == nil {
		return 0
	}
	return cmd.Process.Pid
}
