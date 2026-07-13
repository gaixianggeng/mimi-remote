package httpapi

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/gorilla/websocket"
)

const claudeBridgePolicyErrorCode = -32081
const claudeBridgeProbeCacheTTL = 5 * time.Second

type appServerBridgeProbe struct {
	Status    string
	Path      string
	Version   string
	Healthy   bool
	Error     string
	CheckedAt time.Time
}

func (r *Router) refreshClaudeBridgeProbe(full bool) appServerBridgeProbe {
	probe := appServerBridgeProbe{
		Status:    "disabled",
		CheckedAt: time.Now().UTC(),
	}
	if !r.cfg.Claude.Enabled {
		r.setClaudeBridgeProbe(probe)
		return probe
	}
	bin := strings.TrimSpace(r.cfg.Claude.BridgeBin)
	if bin == "" {
		probe.Status = "invalid"
		probe.Error = "claude.bridge_bin 未配置"
		r.setClaudeBridgeProbe(probe)
		return probe
	}
	path, ok := resolveCommandPath(bin)
	if !ok {
		probe.Status = "missing_command"
		probe.Path = bin
		probe.Error = "找不到 Claude bridge，可配置绝对路径"
		r.setClaudeBridgeProbe(probe)
		return probe
	}
	probe.Status = "ready"
	probe.Path = path
	probe.Healthy = true
	if full {
		probe.Version = probeClaudeBridgeVersion(path, r.cfg.Claude.Args, r.cfg.Claude.Env)
	}
	r.setClaudeBridgeProbe(probe)
	return probe
}

func (r *Router) setClaudeBridgeProbe(probe appServerBridgeProbe) {
	r.claudeMu.Lock()
	r.claudeProbe = probe
	r.claudeMu.Unlock()
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

func resolveCommandPath(command string) (string, bool) {
	command = strings.TrimSpace(command)
	if command == "" {
		return "", false
	}
	if filepath.IsAbs(command) || strings.ContainsAny(command, `/\`) {
		info, err := os.Stat(command)
		if err != nil || info.IsDir() || info.Mode().Perm()&0o111 == 0 {
			return command, false
		}
		return command, true
	}
	path, err := exec.LookPath(command)
	if err != nil {
		return command, false
	}
	return path, true
}

func probeClaudeBridgeVersion(path string, args []string, env map[string]string) string {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, path, append(args, "--version")...)
	cmd.Env = buildClaudeBridgeEnv(env)
	output, err := cmd.Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(bytes.TrimSpace(output)))
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
		writeGatewayRuntimeError(client, "CLAUDE_BRIDGE_UNAVAILABLE", firstNonEmpty(probe.Error, "Claude bridge 不可用"))
		return
	}
	if !r.acquireClaudeBridgeSlot() {
		writeGatewayRuntimeError(client, "CLAUDE_BRIDGE_LIMIT_EXCEEDED", "Claude bridge 并发数已达上限，请稍后重试")
		return
	}
	defer r.releaseClaudeBridgeSlot()

	ctx, cancel := context.WithCancel(req.Context())
	defer cancel()
	bin := firstNonEmpty(probe.Path, strings.TrimSpace(r.cfg.Claude.BridgeBin))
	start := time.Now()
	cmd := exec.Command(bin, r.cfg.Claude.Args...)
	cmd.Env = buildClaudeBridgeEnv(r.cfg.Claude.Env)
	configureGatewayCommandProcessGroup(cmd)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		writeGatewayRuntimeError(client, "CLAUDE_BRIDGE_STDIN_FAILED", "创建 Claude bridge stdin 失败")
		return
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		writeGatewayRuntimeError(client, "CLAUDE_BRIDGE_STDOUT_FAILED", "创建 Claude bridge stdout 失败")
		return
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		writeGatewayRuntimeError(client, "CLAUDE_BRIDGE_STDERR_FAILED", "创建 Claude bridge stderr 失败")
		return
	}
	if err := cmd.Start(); err != nil {
		writeGatewayRuntimeError(client, "CLAUDE_BRIDGE_START_FAILED", "启动 Claude bridge 失败")
		return
	}
	waitCh := make(chan error, 1)
	go func() { waitCh <- cmd.Wait() }()

	monitor := r.monitor.startGatewayConnection(requestRemoteHost(req), req.Host, "claude:"+filepath.Base(bin), time.Since(start))
	done := make(chan string, 3)
	var clientWriteMu sync.Mutex
	var stdinWriteMu sync.Mutex
	configureGatewayReadConn(client)
	policy := &appServerGatewayPolicy{
		router:                r,
		runtimeID:             "claude",
		pendingThreads:        map[string]appServerGatewayPendingThreadRequest{},
		pendingClientRequests: map[string]appServerGatewayPendingClientRequest{},
		pendingServerRequests: map[string]appServerGatewayPendingServerRequest{},
		allowedThreads:        map[string]appServerGatewayAllowedThread{},
	}
	defer policy.close()

	go func() {
		captureClaudeBridgeStderr(stderr)
	}()
	go func() {
		done <- copyClientFramesToClaudeBridge(client, stdin, &clientWriteMu, &stdinWriteMu, policy, monitor)
	}()
	go func() {
		done <- copyClaudeBridgeFrames(ctx, stdout, client, &clientWriteMu, policy, monitor)
	}()
	go func() {
		pingClientGateway(ctx, client, &clientWriteMu)
		done <- "ping_failed_or_context_done"
	}()

	reason := ""
	commandExited := false
	select {
	case reason = <-done:
	case err := <-waitCh:
		commandExited = true
		reason = "bridge_exit"
		if err != nil {
			reason += ": " + trimRelayString(err.Error(), 120)
		}
		writeGatewayRuntimeError(client, "CLAUDE_BRIDGE_EXITED", "Claude bridge 已退出，本轮连接已中断")
	}
	cancel()
	_ = stdin.Close()
	_ = client.Close()
	shutdownGatewayCommand(cmd, waitCh, commandExited)
	if monitor != nil {
		monitor.finish(reason)
	}
}

func (r *Router) acquireClaudeBridgeSlot() bool {
	limit := r.cfg.Claude.MaxConcurrentBridges
	if limit <= 0 {
		limit = 3
	}
	r.claudeMu.Lock()
	defer r.claudeMu.Unlock()
	if r.activeClaudeBridge >= limit {
		return false
	}
	r.activeClaudeBridge++
	return true
}

func (r *Router) releaseClaudeBridgeSlot() {
	r.claudeMu.Lock()
	if r.activeClaudeBridge > 0 {
		r.activeClaudeBridge--
	}
	r.claudeMu.Unlock()
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
				monitor.recordPolicyError("client_to_upstream", len(payload), policyDuration)
			}
			if !writeGatewayPolicyError(client, clientWriteMu, policyErr) {
				return "client_policy_error_write_failed"
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
	}
}

func copyClaudeBridgeFrames(ctx context.Context, stdout io.Reader, client *websocket.Conn, clientWriteMu *sync.Mutex, policy *appServerGatewayPolicy, monitor *relayGatewayConnMonitor) string {
	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 4096), int(appServerGatewayReadLimit))
	for scanner.Scan() {
		select {
		case <-ctx.Done():
			return "context_done"
		default:
		}
		payload := bytes.TrimSpace(scanner.Bytes())
		if len(payload) == 0 {
			continue
		}
		policyStart := time.Now()
		forwardPayload, forward, policyErr := policy.observeUpstreamFrame(websocket.TextMessage, payload)
		policyDuration := time.Since(policyStart)
		if policyErr != nil {
			if monitor != nil {
				monitor.recordPolicyError("upstream_to_client", len(payload), policyDuration)
			}
			if !writeGatewayPolicyError(client, clientWriteMu, policyErr) {
				return "upstream_policy_error_write_failed"
			}
			continue
		}
		if !forward {
			if monitor != nil {
				monitor.recordDropped("upstream_to_client", len(payload), policyDuration)
			}
			continue
		}
		frame := append([]byte(nil), forwardPayload...)
		if rewritten, ok := rewriteClaudeModelListResponse(policy, frame); ok {
			frame = rewritten
		}
		writeStart := time.Now()
		if err := writeWebSocketFrame(client, clientWriteMu, websocket.TextMessage, frame); err != nil {
			return gatewayCloseReason("client_write", err)
		}
		if monitor != nil {
			monitor.recordForward("upstream_to_client", len(payload), len(frame), policyDuration, time.Since(writeStart), frame)
		}
	}
	if err := scanner.Err(); err != nil {
		log.Printf("claude bridge stdout scanner error err=%v", err)
		return gatewayCloseReason("bridge_stdout_scan", err)
	}
	return "bridge_stdout_closed"
}

func writeStdioBridgeFrame(stdin io.Writer, mu *sync.Mutex, payload []byte) ([]byte, error) {
	compacted, err := compactJSONLine(payload)
	if err != nil {
		return nil, err
	}
	if err := writeStdioBridgeCompactedFrame(stdin, mu, compacted); err != nil {
		return nil, err
	}
	return compacted, nil
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

func rewriteClaudeModelListResponse(policy *appServerGatewayPolicy, payload []byte) ([]byte, bool) {
	if policy == nil {
		return nil, false
	}
	var frame appServerGatewayFrame
	if err := json.Unmarshal(payload, &frame); err != nil || !gatewayFrameIsResponse(&frame) {
		return nil, false
	}
	pending, ok := policy.consumePendingClientRequest(frame.ID)
	if !ok || pending.method != "model/list" || len(frame.Error) > 0 {
		return nil, false
	}
	var object map[string]any
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.UseNumber()
	if err := decoder.Decode(&object); err != nil {
		return nil, false
	}
	object["result"] = map[string]any{
		"data":       claudeCurrentModelList(),
		"nextCursor": nil,
	}
	delete(object, "error")
	rewritten, err := json.Marshal(object)
	if err != nil {
		return nil, false
	}
	return rewritten, true
}

func claudeCurrentModelList() []map[string]any {
	// Claude CLI 的具体模型 ID 会比产品命名更频繁变化；这里用 CLI alias 作为真正发送的
	// model，避免新名字尚未进入本机 metadata 时触发 fallback warning。展示名仍表达当前推荐代际。
	return []map[string]any{
		claudeModelOption(
			"opus",
			"Claude Opus 4.8",
			"Alias resolved by the Claude CLI to the latest available Opus model; best for complex agentic coding and deep reasoning.",
			false,
			"high",
		),
		claudeModelOption(
			"sonnet",
			"Claude Sonnet 5",
			"Alias resolved by the Claude CLI to the latest available Sonnet model; default balanced model for everyday coding work.",
			true,
			"high",
		),
		claudeModelOption(
			"haiku",
			"Claude Haiku 4.5",
			"Alias resolved by the Claude CLI to the latest available Haiku model; fastest choice for quick edits and small tasks.",
			false,
			"minimal",
		),
	}
}

func claudeModelOption(modelID string, displayName string, description string, isDefault bool, defaultEffort string) map[string]any {
	return map[string]any{
		"id":                        modelID,
		"model":                     modelID,
		"displayName":               displayName,
		"description":               description,
		"hidden":                    false,
		"supportedReasoningEfforts": claudeReasoningEffortOptions(),
		"defaultReasoningEffort":    defaultEffort,
		"inputModalities":           []string{"text", "image"},
		"supportsPersonality":       false,
		"additionalSpeedTiers":      []any{},
		"serviceTiers":              []map[string]string{{"id": "standard", "name": "Standard", "description": "Default bridge service tier"}},
		"isDefault":                 isDefault,
	}
}

func claudeReasoningEffortOptions() []map[string]string {
	return []map[string]string{
		{"reasoningEffort": "minimal", "description": "Lowest latency, no extended thinking"},
		{"reasoningEffort": "low", "description": "Brief reasoning"},
		{"reasoningEffort": "medium", "description": "Default depth of reasoning"},
		{"reasoningEffort": "high", "description": "Maximum reasoning effort"},
	}
}

func pingClientGateway(ctx context.Context, client *websocket.Conn, clientWriteMu *sync.Mutex) {
	ticker := time.NewTicker(appServerGatewayPingPeriod)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			deadline := time.Now().Add(appServerGatewayWriteWindow)
			if err := writeWebSocketControl(client, clientWriteMu, websocket.PingMessage, nil, deadline); err != nil {
				return
			}
		}
	}
}

func buildClaudeBridgeEnv(extra map[string]string) []string {
	keys := []string{"HOME", "PATH", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "TERM"}
	out := make([]string, 0, len(keys)+len(extra))
	seen := map[string]struct{}{}
	for _, key := range keys {
		value := os.Getenv(key)
		if value == "" {
			continue
		}
		out = append(out, key+"="+value)
		seen[key] = struct{}{}
	}
	for key, value := range extra {
		key = strings.TrimSpace(key)
		if key == "" || strings.Contains(key, "=") {
			continue
		}
		if _, ok := seen[key]; ok {
			for i, item := range out {
				if strings.HasPrefix(item, key+"=") {
					out[i] = key + "=" + value
					break
				}
			}
			continue
		}
		out = append(out, key+"="+value)
	}
	return out
}

func captureClaudeBridgeStderr(stderr io.Reader) {
	scanner := bufio.NewScanner(stderr)
	for scanner.Scan() {
		line := sanitizeGatewayDiagnostic(scanner.Text())
		if line == "" {
			continue
		}
		log.Printf("claude bridge stderr: %s", line)
	}
	if err := scanner.Err(); err != nil {
		log.Printf("claude bridge stderr scanner error err=%v", err)
	}
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
	payload := map[string]any{
		"jsonrpc": "2.0",
		"id":      nil,
		"error": map[string]any{
			"code":    claudeBridgePolicyErrorCode,
			"message": code + ": " + message,
			"data": map[string]any{
				"code": code,
			},
		},
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		return
	}
	_ = conn.SetWriteDeadline(time.Now().Add(appServerGatewayWriteWindow))
	_ = conn.WriteMessage(websocket.TextMessage, raw)
}

func configureGatewayCommandProcessGroup(cmd *exec.Cmd) {
	if cmd == nil {
		return
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
}

func shutdownGatewayCommand(cmd *exec.Cmd, waitCh <-chan error, alreadyExited bool) {
	if cmd == nil {
		return
	}
	// Claude bridge 可能再拉起 Claude Code 子进程；断线时必须按进程组收口，
	// 不能只 kill bridge leader，否则会留下继续执行的孤儿任务。
	terminateGatewayProcessGroup(cmd, syscall.SIGTERM)
	if alreadyExited {
		terminateGatewayProcessGroup(cmd, syscall.SIGKILL)
		return
	}
	select {
	case <-waitCh:
		terminateGatewayProcessGroup(cmd, syscall.SIGKILL)
	case <-time.After(300 * time.Millisecond):
		terminateGatewayProcessGroup(cmd, syscall.SIGKILL)
		select {
		case <-waitCh:
		case <-time.After(2 * time.Second):
			log.Printf("claude bridge process did not exit after SIGKILL pid=%d", gatewayProcessID(cmd))
		}
	}
}

func terminateGatewayProcessGroup(cmd *exec.Cmd, signal syscall.Signal) {
	pid := gatewayProcessID(cmd)
	if pid <= 0 {
		return
	}
	if err := syscall.Kill(-pid, signal); err != nil && err != syscall.ESRCH {
		_ = syscall.Kill(pid, signal)
	}
}

func gatewayProcessID(cmd *exec.Cmd) int {
	if cmd == nil || cmd.Process == nil {
		return 0
	}
	return cmd.Process.Pid
}
