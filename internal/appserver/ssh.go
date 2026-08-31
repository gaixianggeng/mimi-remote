package appserver

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"

	"github.com/gorilla/websocket"
)

const (
	// CodexAppServerWebSocketURL 是 codex app-server proxy 暴露给本地客户端的
	// 固定 URL。proxy 会把 Host/path 映射到远端 Unix App Server。
	CodexAppServerWebSocketURL = "ws://codex-app-server/rpc"
	MinimumCodexVersion        = "0.149.1"

	sshProxyRemoteCommand = "codex app-server proxy"
	// App Server 会为仍处于加载宽限期的 Thread 保留 session 和 MCP 文件描述符。
	// SSH 登录在 macOS 上默认只有 256，无法承载 Desktop 与 Mimi 的正常并发恢复。
	// 这里保证新 resident 至少有 8192；客户端仍必须按生命周期取消 Thread 订阅。
	sshAppServerOpenFileSoftLimit = 8192
	// SSH resident 只服务 Unix proxy。禁止它继承 Desktop 保存的 Remote Control
	// 身份，否则移动端请求可能进入第二个 App Server，并与官方进程争用 Thread writer。
	sshBootstrapRemoteCommand = `/bin/sh -c 'open_file_limit=$(ulimit -Sn); if test "$open_file_limit" != unlimited && test "$open_file_limit" -lt 8192; then ulimit -Sn 8192 || { printf "远端 open-file soft limit 无法提高到 8192\n" >&2; exit 72; }; fi; nohup env CODEX_INTERNAL_APP_SERVER_REMOTE_CONTROL_DISABLED=1 codex -c features.code_mode_host=true app-server --listen unix:// >/dev/null 2>&1 </dev/null &'`
	sshSocketStateCommand     = `if test -S "$HOME/.codex/app-server-control/app-server-control.sock"; then printf socket-present; else printf socket-missing; fi`

	defaultSSHReadyTimeout     = 12 * time.Second
	defaultSSHBootstrapTimeout = 8 * time.Second
	defaultSSHRetryInterval    = 150 * time.Millisecond
)

// SSHTransportOptions 只包含本地 SSH 可执行文件和目标。远端命令是固定常量，
// 避免把配置值拼入 login shell；target 会作为独立 exec 参数传递。
type SSHTransportOptions struct {
	Target string
	SSHBin string

	ReadyTimeout     time.Duration
	BootstrapTimeout time.Duration
	RetryInterval    time.Duration
}

// SSHTransport 负责把每个本地 WebSocket 连接映射到一个短生命周期 SSH proxy。
// 它不拥有远端 App Server；Close 只关闭本地 proxy，不会停止 resident Codex。
type SSHTransport struct {
	target string
	sshBin string

	readyTimeout     time.Duration
	bootstrapTimeout time.Duration
	retryInterval    time.Duration

	readyMu       sync.Mutex
	readyErr      error
	readyInFlight chan struct{}
}

// NewSSHTransport 构造 SSH transport。空 target 不在这里默默替换，调用方应先
// 使用配置默认值；这样显式空值和配置缺失都能在 doctor 中给出清晰原因。
func NewSSHTransport(options SSHTransportOptions) (*SSHTransport, error) {
	target := options.Target
	if err := ValidateSSHTarget(target); err != nil {
		return nil, err
	}
	sshBin := strings.TrimSpace(options.SSHBin)
	if sshBin == "" {
		sshBin = "ssh"
	}
	readyTimeout := options.ReadyTimeout
	if readyTimeout <= 0 {
		readyTimeout = defaultSSHReadyTimeout
	}
	bootstrapTimeout := options.BootstrapTimeout
	if bootstrapTimeout <= 0 {
		bootstrapTimeout = defaultSSHBootstrapTimeout
	}
	retryInterval := options.RetryInterval
	if retryInterval <= 0 {
		retryInterval = defaultSSHRetryInterval
	}
	return &SSHTransport{
		target:           target,
		sshBin:           sshBin,
		readyTimeout:     readyTimeout,
		bootstrapTimeout: bootstrapTimeout,
		retryInterval:    retryInterval,
	}, nil
}

// Target 返回已经校验过的 SSH target，供诊断提示使用。
func (t *SSHTransport) Target() string {
	if t == nil {
		return ""
	}
	return t.target
}

// SSHBinaryAvailable 检查本地 OpenSSH binary。它不建立网络连接。
func (t *SSHTransport) SSHBinaryAvailable() error {
	if t == nil {
		return errors.New("SSH transport 未初始化")
	}
	if _, err := exec.LookPath(t.sshBin); err != nil {
		return fmt.Errorf("未找到 OpenSSH binary %q：%w", t.sshBin, err)
	}
	return nil
}

// SSHCheckCommand 返回用户可以直接复制执行的 host/auth 检查命令。
func (t *SSHTransport) SSHCheckCommand() string {
	if t == nil {
		return "ssh <target> codex --version"
	}
	return "ssh " + t.target + " codex --version"
}

// CheckRemoteCodex 检查 SSH host/auth 和远端 Codex 版本。它不会启动 App Server。
func (t *SSHTransport) CheckRemoteCodex(ctx context.Context) (string, error) {
	if t == nil {
		return "", errors.New("SSH transport 未初始化")
	}
	if err := t.SSHBinaryAvailable(); err != nil {
		return "", fmt.Errorf("%w；请执行：%s", err, t.SSHCheckCommand())
	}
	checkCtx, cancel := context.WithTimeout(ctx, t.bootstrapTimeout)
	defer cancel()
	cmd := exec.CommandContext(checkCtx, t.sshBin, sshCommandArgs(t.target, "codex --version")...)
	cmd.Env = buildManagedEnv(nil)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("SSH host/auth 或远端 Codex 不可用；请执行：%s：%w", t.SSHCheckCommand(), err)
	}
	version, ok := ParseCodexVersion(string(output))
	if !ok {
		return "", fmt.Errorf("远端 codex --version 输出无法解析；请执行：%s", t.SSHCheckCommand())
	}
	if CompareCodexVersions(version, MinimumCodexVersion) < 0 {
		return "", fmt.Errorf("远端 Codex %s 低于最低兼容版本 %s；请升级后执行：%s", version, MinimumCodexVersion, t.SSHCheckCommand())
	}
	return version, nil
}

// EnsureReady 先通过真实 proxy WebSocket 完成 initialize/readiness；只有明确
// proxy 因远端控制 socket 不可用而退出时才执行一次后台 bootstrap。并发调用共享
// 同一轮结果，bootstrap 失败后不会反复启动第二个 resident App Server。
func (t *SSHTransport) EnsureReady(ctx context.Context) error {
	if t == nil {
		return errors.New("SSH transport 未初始化")
	}
	t.readyMu.Lock()
	if t.readyInFlight != nil {
		inFlight := t.readyInFlight
		t.readyMu.Unlock()
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-inFlight:
		}
		t.readyMu.Lock()
		err := t.readyErr
		t.readyMu.Unlock()
		return err
	}
	inFlight := make(chan struct{})
	t.readyInFlight = inFlight
	t.readyMu.Unlock()

	readyCtx, cancel := context.WithTimeout(ctx, t.readyTimeout)
	err := t.ensureReadyOnce(readyCtx)
	cancel()

	t.readyMu.Lock()
	t.readyErr = err
	t.readyInFlight = nil
	close(inFlight)
	t.readyMu.Unlock()
	return err
}

func (t *SSHTransport) ensureReadyOnce(ctx context.Context) error {
	err := t.probeProxy(ctx)
	if err == nil {
		return nil
	}
	missing, stateErr := t.defaultSocketMissing(ctx)
	if stateErr != nil {
		return fmt.Errorf("Codex app-server proxy 不可用，且无法确认默认 Unix Socket 状态：%w；proxy_error=%v；请执行：%s", stateErr, err, t.SSHCheckCommand())
	}
	if !missing {
		return fmt.Errorf("Codex app-server proxy 无法连接到仍存在的默认 Unix Socket：%w；请执行：%s", err, t.SSHCheckCommand())
	}
	// EnsureReady 自身已经把同一轮并发请求合并为 single-flight。不要把
	// bootstrap 失败永久缓存到整个 agentd 生命周期；远端 socket 可能在下一轮
	// readiness 前由 Desktop 或用户手动启动。
	if bootstrapErr := t.bootstrap(ctx); bootstrapErr != nil {
		return fmt.Errorf("启动共享 Codex App Server 失败：%w；请执行：%s", bootstrapErr, t.SSHCheckCommand())
	}
	for {
		if err := ctx.Err(); err != nil {
			return fmt.Errorf("等待共享 Codex App Server 就绪超时：%w", err)
		}
		if err := t.probeProxy(ctx); err == nil {
			return nil
		}
		timer := time.NewTimer(t.retryInterval)
		select {
		case <-ctx.Done():
			timer.Stop()
			return fmt.Errorf("等待共享 Codex App Server 就绪超时：%w", ctx.Err())
		case <-timer.C:
		}
	}
}

func (t *SSHTransport) defaultSocketMissing(ctx context.Context) (bool, error) {
	checkCtx, cancel := context.WithTimeout(ctx, t.bootstrapTimeout)
	defer cancel()
	cmd := exec.CommandContext(checkCtx, t.sshBin, sshCommandArgs(t.target, sshSocketStateCommand)...)
	cmd.Env = buildManagedEnv(nil)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return false, fmt.Errorf("SSH Socket 探测失败：%w", err)
	}
	switch strings.TrimSpace(string(output)) {
	case "socket-missing":
		return true, nil
	case "socket-present":
		return false, nil
	default:
		return false, fmt.Errorf("SSH Socket 探测返回未知结果")
	}
}

func (t *SSHTransport) bootstrap(ctx context.Context) error {
	bootstrapCtx, cancel := context.WithTimeout(ctx, t.bootstrapTimeout)
	defer cancel()
	cmd := exec.CommandContext(bootstrapCtx, t.sshBin, sshCommandArgs(t.target, sshBootstrapRemoteCommand)...)
	cmd.Env = buildManagedEnv(nil)
	output, err := cmd.CombinedOutput()
	if err != nil {
		if detail := strings.TrimSpace(string(output)); detail != "" {
			return fmt.Errorf("SSH bootstrap 失败：%s：%w", detail, err)
		}
		return err
	}
	return nil
}

// WebSocketDialer 返回 Gorilla WebSocket dialer。NetDialContext 每次建立一个
// SSH proxy 子进程；关闭返回的 WebSocket 会关闭其底层 proxy。
func (t *SSHTransport) WebSocketDialer(timeout time.Duration) (websocket.Dialer, error) {
	if t == nil {
		return websocket.Dialer{}, errors.New("SSH transport 未初始化")
	}
	if err := ValidateSSHTarget(t.target); err != nil {
		return websocket.Dialer{}, err
	}
	if timeout <= 0 {
		timeout = 4 * time.Second
	}
	dialer := websocket.Dialer{HandshakeTimeout: timeout}
	dialer.NetDialContext = func(ctx context.Context, _, _ string) (net.Conn, error) {
		return t.openProxy(ctx)
	}
	return dialer, nil
}

// DialWebSocket 是需要完整 readiness 门禁的便捷入口。Gateway 通常先由
// readyz/serve 调用 EnsureReady，再使用 WebSocketDialer 建立长期连接。
func (t *SSHTransport) DialWebSocket(ctx context.Context, headers http.Header) (*websocket.Conn, *http.Response, error) {
	if err := t.EnsureReady(ctx); err != nil {
		return nil, nil, err
	}
	dialer, err := t.WebSocketDialer(4 * time.Second)
	if err != nil {
		return nil, nil, err
	}
	conn, response, err := dialer.DialContext(ctx, CodexAppServerWebSocketURL, headers)
	if err != nil {
		if response != nil && response.Body != nil {
			_ = response.Body.Close()
		}
		return nil, response, err
	}
	return conn, response, nil
}

func (t *SSHTransport) probeProxy(ctx context.Context) error {
	conn, response, err := t.dialWebSocketRaw(ctx, nil)
	if response != nil && response.Body != nil {
		_ = response.Body.Close()
	}
	if err != nil {
		return err
	}
	defer conn.Close()
	return initializeWebSocket(ctx, conn)
}

func (t *SSHTransport) dialWebSocketRaw(ctx context.Context, headers http.Header) (*websocket.Conn, *http.Response, error) {
	var proxy *sshProxyConn
	dialer, err := t.WebSocketDialer(4 * time.Second)
	if err != nil {
		return nil, nil, err
	}
	baseDial := dialer.NetDialContext
	dialer.NetDialContext = func(dialCtx context.Context, network, address string) (net.Conn, error) {
		conn, err := baseDial(dialCtx, network, address)
		if typed, ok := conn.(*sshProxyConn); ok {
			proxy = typed
		}
		return conn, err
	}
	conn, response, err := dialer.DialContext(ctx, CodexAppServerWebSocketURL, headers)
	if err != nil {
		if proxy != nil {
			proxy.Close()
			return nil, response, proxy.dialError(err)
		}
		return nil, response, err
	}
	return conn, response, nil
}

func initializeWebSocket(ctx context.Context, conn *websocket.Conn) error {
	if conn == nil {
		return errors.New("WebSocket connection 为空")
	}
	if deadline, ok := ctx.Deadline(); ok {
		_ = conn.SetReadDeadline(deadline)
		_ = conn.SetWriteDeadline(deadline)
	}
	payload := map[string]any{
		"id":     1,
		"method": "initialize",
		"params": map[string]any{
			"clientInfo": map[string]any{
				"name":    "mimi_remote",
				"title":   "Mimi Remote",
				"version": "0.1.0",
			},
			"capabilities": map[string]any{
				"experimentalApi": true,
			},
		},
	}
	if err := conn.WriteJSON(payload); err != nil {
		return fmt.Errorf("发送 app-server initialize 失败：%w", err)
	}
	for {
		_, raw, err := conn.ReadMessage()
		if err != nil {
			return fmt.Errorf("读取 app-server initialize 响应失败：%w", err)
		}
		var frame struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
			Error  *RPCError       `json:"error,omitempty"`
		}
		if err := json.Unmarshal(raw, &frame); err != nil {
			continue
		}
		if frame.Method != "" || string(frame.ID) != "1" {
			continue
		}
		if frame.Error != nil {
			return fmt.Errorf("app-server initialize 被拒绝：%w", frame.Error)
		}
		break
	}
	if err := conn.WriteJSON(map[string]any{"method": "initialized", "params": map[string]any{}}); err != nil {
		return fmt.Errorf("发送 app-server initialized 失败：%w", err)
	}
	return nil
}

// ValidateSSHTarget 验证 OpenSSH target，避免空白、NUL 和 option injection。
func ValidateSSHTarget(target string) error {
	if target == "" {
		return errors.New("SSH target 不能为空")
	}
	if strings.HasPrefix(target, "-") {
		return errors.New("SSH target 不能以 - 开头")
	}
	for _, r := range target {
		if r == '\x00' {
			return errors.New("SSH target 不能包含 NUL")
		}
		if unicode.IsSpace(r) || unicode.IsControl(r) {
			return errors.New("SSH target 不能包含空白或控制字符")
		}
	}
	return nil
}

func sshCommandArgs(target, remoteCommand string) []string {
	return []string{
		"-T",
		"-o", "BatchMode=yes",
		"-o", "StrictHostKeyChecking=yes",
		"-o", "ConnectTimeout=10",
		"-o", "ServerAliveInterval=15",
		"-o", "ServerAliveCountMax=12",
		target,
		remoteCommand,
	}
}

// ParseCodexVersion extracts a semantic version from the common `codex --version`
// outputs (for example `codex-cli 0.149.1`).
func ParseCodexVersion(output string) (string, bool) {
	for _, field := range strings.Fields(output) {
		candidate := strings.Trim(field, "()[]{}:,;")
		candidate = strings.TrimPrefix(candidate, "v")
		if buildIndex := strings.IndexByte(candidate, '+'); buildIndex >= 0 {
			candidate = candidate[:buildIndex]
		}
		core := candidate
		prerelease := ""
		if prereleaseIndex := strings.IndexByte(candidate, '-'); prereleaseIndex >= 0 {
			core = candidate[:prereleaseIndex]
			prerelease = candidate[prereleaseIndex+1:]
		}
		parts := strings.Split(core, ".")
		if len(parts) != 3 {
			continue
		}
		valid := true
		for _, part := range parts {
			if part == "" {
				valid = false
				break
			}
			for _, r := range part {
				if r < '0' || r > '9' {
					valid = false
					break
				}
			}
		}
		if valid && validSemverPrerelease(prerelease) {
			return candidate, true
		}
	}
	return "", false
}

func CompareCodexVersions(left, right string) int {
	leftVersion := parseComparableVersion(left)
	rightVersion := parseComparableVersion(right)
	for index := range leftVersion.core {
		if leftVersion.core[index] < rightVersion.core[index] {
			return -1
		}
		if leftVersion.core[index] > rightVersion.core[index] {
			return 1
		}
	}
	return compareSemverPrerelease(leftVersion.prerelease, rightVersion.prerelease)
}

type comparableVersion struct {
	core       [3]int
	prerelease string
}

func parseComparableVersion(raw string) comparableVersion {
	raw = strings.TrimPrefix(raw, "v")
	if buildIndex := strings.IndexByte(raw, '+'); buildIndex >= 0 {
		raw = raw[:buildIndex]
	}
	core := raw
	prerelease := ""
	if prereleaseIndex := strings.IndexByte(raw, '-'); prereleaseIndex >= 0 {
		core = raw[:prereleaseIndex]
		prerelease = raw[prereleaseIndex+1:]
	}
	result := comparableVersion{prerelease: prerelease}
	for index, part := range strings.Split(core, ".") {
		if index >= len(result.core) {
			break
		}
		result.core[index], _ = strconv.Atoi(part)
	}
	return result
}

func validSemverPrerelease(value string) bool {
	if value == "" {
		return true
	}
	for _, identifier := range strings.Split(value, ".") {
		if identifier == "" {
			return false
		}
		for _, r := range identifier {
			if !unicode.IsLetter(r) && !unicode.IsDigit(r) && r != '-' {
				return false
			}
		}
	}
	return true
}

func compareSemverPrerelease(left, right string) int {
	if left == right {
		return 0
	}
	if left == "" {
		return 1
	}
	if right == "" {
		return -1
	}
	leftParts := strings.Split(left, ".")
	rightParts := strings.Split(right, ".")
	for index := 0; index < len(leftParts) && index < len(rightParts); index++ {
		leftNumber, leftNumeric := semverNumericIdentifier(leftParts[index])
		rightNumber, rightNumeric := semverNumericIdentifier(rightParts[index])
		switch {
		case leftNumeric && rightNumeric && leftNumber < rightNumber:
			return -1
		case leftNumeric && rightNumeric && leftNumber > rightNumber:
			return 1
		case leftNumeric && !rightNumeric:
			return -1
		case !leftNumeric && rightNumeric:
			return 1
		case leftParts[index] < rightParts[index]:
			return -1
		case leftParts[index] > rightParts[index]:
			return 1
		}
	}
	if len(leftParts) < len(rightParts) {
		return -1
	}
	return 1
}

func semverNumericIdentifier(value string) (int, bool) {
	if value == "" {
		return 0, false
	}
	for _, r := range value {
		if r < '0' || r > '9' {
			return 0, false
		}
	}
	number, err := strconv.Atoi(value)
	return number, err == nil
}

type SSHProxyError struct {
	StartError error
	ExitCode   int
	StderrTail []string
	Cause      error
}

func (e *SSHProxyError) Error() string {
	if e == nil {
		return ""
	}
	if e.StartError != nil {
		return "启动 SSH proxy 失败：" + e.StartError.Error()
	}
	if e.Cause != nil {
		return e.Cause.Error()
	}
	return "SSH proxy 已退出"
}

func (e *SSHProxyError) Unwrap() error {
	if e == nil {
		return nil
	}
	if e.Cause != nil {
		return e.Cause
	}
	return e.StartError
}

type sshProxyConn struct {
	stdin  io.WriteCloser
	stdout io.ReadCloser
	cmd    *exec.Cmd
	waitCh chan error
	doneCh chan struct{}

	stderrMu                sync.Mutex
	stderrTail              []string
	stateMu                 sync.Mutex
	closed                  bool
	readDeadlineTimer       *time.Timer
	writeDeadlineTimer      *time.Timer
	readDeadlineGeneration  uint64
	writeDeadlineGeneration uint64
	readDeadlineExpired     bool
	writeDeadlineExpired    bool
	closeOnce               sync.Once
}

func (t *SSHTransport) openProxy(_ context.Context) (net.Conn, error) {
	if err := t.SSHBinaryAvailable(); err != nil {
		return nil, &SSHProxyError{StartError: err, ExitCode: -1}
	}
	cmd := exec.Command(t.sshBin, sshCommandArgs(t.target, sshProxyRemoteCommand)...)
	configureManagedCommand(cmd)
	cmd.Env = buildManagedEnv(nil)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, &SSHProxyError{StartError: err, ExitCode: -1}
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		_ = stdin.Close()
		return nil, &SSHProxyError{StartError: err, ExitCode: -1}
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		_ = stdin.Close()
		_ = stdout.Close()
		return nil, &SSHProxyError{StartError: err, ExitCode: -1}
	}
	if err := cmd.Start(); err != nil {
		_ = stdin.Close()
		_ = stdout.Close()
		_ = stderr.Close()
		return nil, &SSHProxyError{StartError: err, ExitCode: -1}
	}
	proxy := &sshProxyConn{
		stdin:  stdin,
		stdout: stdout,
		cmd:    cmd,
		waitCh: make(chan error, 1),
		doneCh: make(chan struct{}),
	}
	go proxy.captureStderr(stderr)
	go func() {
		err := cmd.Wait()
		proxy.waitCh <- err
		close(proxy.doneCh)
	}()
	// Gorilla v1.5.3 会在 DialContext 返回时取消它为 HandshakeTimeout
	// 派生的 context。这里不能把该 context 当作连接生命周期；握手失败时
	// Gorilla 自己会关闭 net.Conn，握手超时则由它设置在连接上的 deadline 负责。
	// SSH proxy 只能由返回的 net.Conn.Close 结束。
	return proxy, nil
}

func (p *sshProxyConn) dialError(cause error) error {
	result := &SSHProxyError{Cause: cause, ExitCode: -1}
	p.stateMu.Lock()
	closed := p.closed
	p.stateMu.Unlock()
	if closed {
		select {
		case err := <-p.waitCh:
			if exitErr, ok := err.(*exec.ExitError); ok {
				result.ExitCode = exitErr.ExitCode()
			} else if err == nil {
				result.ExitCode = 0
			}
		default:
		}
	}
	p.stderrMu.Lock()
	result.StderrTail = append([]string(nil), p.stderrTail...)
	p.stderrMu.Unlock()
	return result
}

func (p *sshProxyConn) captureStderr(stderr io.ReadCloser) {
	defer stderr.Close()
	buffer := make([]byte, 1024)
	for {
		n, err := stderr.Read(buffer)
		if n > 0 {
			for _, line := range strings.Split(string(buffer[:n]), "\n") {
				line = strings.TrimSpace(line)
				if line == "" {
					continue
				}
				p.stderrMu.Lock()
				p.stderrTail = append(p.stderrTail, sanitizeDiagnostic(line))
				if len(p.stderrTail) > 20 {
					p.stderrTail = p.stderrTail[len(p.stderrTail)-20:]
				}
				p.stderrMu.Unlock()
			}
		}
		if err != nil {
			return
		}
	}
}

func (p *sshProxyConn) Read(data []byte) (int, error) {
	n, err := p.stdout.Read(data)
	if err != nil && p.pipeDeadlineExpired(true) {
		return n, os.ErrDeadlineExceeded
	}
	return n, err
}

func (p *sshProxyConn) Write(data []byte) (int, error) {
	n, err := p.stdin.Write(data)
	if err != nil && p.pipeDeadlineExpired(false) {
		return n, os.ErrDeadlineExceeded
	}
	return n, err
}

func (p *sshProxyConn) Close() error {
	if p == nil {
		return nil
	}
	var closeErr error
	p.closeOnce.Do(func() {
		p.stateMu.Lock()
		p.closed = true
		p.cancelFallbackDeadlineLocked(true, false)
		p.cancelFallbackDeadlineLocked(false, false)
		p.stateMu.Unlock()
		if err := p.stdin.Close(); err != nil && !errors.Is(err, os.ErrClosed) {
			closeErr = err
		}
		_ = p.stdout.Close()
		select {
		case <-p.doneCh:
		case <-time.After(200 * time.Millisecond):
			if p.cmd.Process != nil {
				_ = p.cmd.Process.Kill()
			}
			select {
			case <-p.doneCh:
			case <-time.After(time.Second):
			}
		}
	})
	return closeErr
}

func (p *sshProxyConn) LocalAddr() net.Addr                  { return sshProxyAddr("local") }
func (p *sshProxyConn) RemoteAddr() net.Addr                 { return sshProxyAddr("remote") }
func (p *sshProxyConn) SetDeadline(deadline time.Time) error { return p.setPipeDeadline(deadline) }
func (p *sshProxyConn) SetReadDeadline(deadline time.Time) error {
	if file, ok := p.stdout.(interface{ SetReadDeadline(time.Time) error }); ok {
		return p.applyPipeDeadline(true, deadline, file.SetReadDeadline)
	}
	if file, ok := p.stdout.(interface{ SetDeadline(time.Time) error }); ok {
		return p.applyPipeDeadline(true, deadline, file.SetDeadline)
	}
	return nil
}
func (p *sshProxyConn) SetWriteDeadline(deadline time.Time) error {
	if file, ok := p.stdin.(interface{ SetWriteDeadline(time.Time) error }); ok {
		return p.applyPipeDeadline(false, deadline, file.SetWriteDeadline)
	}
	if file, ok := p.stdin.(interface{ SetDeadline(time.Time) error }); ok {
		return p.applyPipeDeadline(false, deadline, file.SetDeadline)
	}
	return nil
}
func (p *sshProxyConn) setPipeDeadline(deadline time.Time) error {
	if err := p.SetReadDeadline(deadline); err != nil {
		return err
	}
	return p.SetWriteDeadline(deadline)
}

func (p *sshProxyConn) applyPipeDeadline(read bool, deadline time.Time, native func(time.Time) error) error {
	err := native(deadline)
	if err == nil {
		p.clearFallbackDeadline(read)
		return nil
	}
	if !errors.Is(err, os.ErrNoDeadline) {
		return err
	}
	// Windows 的 exec pipe 不支持 os.File deadline。用关闭对应 pipe 的 timer
	// 解除阻塞，并由 Read/Write 把关闭错误还原为标准 timeout 语义。
	p.armFallbackDeadline(read, deadline)
	return nil
}

func (p *sshProxyConn) armFallbackDeadline(read bool, deadline time.Time) {
	p.stateMu.Lock()
	p.cancelFallbackDeadlineLocked(read, true)
	if p.closed || deadline.IsZero() {
		p.stateMu.Unlock()
		return
	}
	var generation uint64
	if read {
		generation = p.readDeadlineGeneration
		p.readDeadlineTimer = time.AfterFunc(time.Until(deadline), func() {
			p.expireFallbackDeadline(true, generation)
		})
	} else {
		generation = p.writeDeadlineGeneration
		p.writeDeadlineTimer = time.AfterFunc(time.Until(deadline), func() {
			p.expireFallbackDeadline(false, generation)
		})
	}
	p.stateMu.Unlock()
}

func (p *sshProxyConn) clearFallbackDeadline(read bool) {
	p.stateMu.Lock()
	p.cancelFallbackDeadlineLocked(read, true)
	p.stateMu.Unlock()
}

func (p *sshProxyConn) cancelFallbackDeadlineLocked(read bool, resetExpired bool) {
	if read {
		p.readDeadlineGeneration++
		if p.readDeadlineTimer != nil {
			p.readDeadlineTimer.Stop()
			p.readDeadlineTimer = nil
		}
		if resetExpired {
			p.readDeadlineExpired = false
		}
		return
	}
	p.writeDeadlineGeneration++
	if p.writeDeadlineTimer != nil {
		p.writeDeadlineTimer.Stop()
		p.writeDeadlineTimer = nil
	}
	if resetExpired {
		p.writeDeadlineExpired = false
	}
}

func (p *sshProxyConn) expireFallbackDeadline(read bool, generation uint64) {
	p.stateMu.Lock()
	if p.closed {
		p.stateMu.Unlock()
		return
	}
	var pipe io.Closer
	if read {
		if generation != p.readDeadlineGeneration {
			p.stateMu.Unlock()
			return
		}
		p.readDeadlineTimer = nil
		p.readDeadlineExpired = true
		pipe = p.stdout
	} else {
		if generation != p.writeDeadlineGeneration {
			p.stateMu.Unlock()
			return
		}
		p.writeDeadlineTimer = nil
		p.writeDeadlineExpired = true
		pipe = p.stdin
	}
	// generation 校验与 Close 必须处于同一临界区。否则清零或延长 deadline
	// 可能在两者之间成功返回，旧 callback 随后仍会关闭已经恢复健康的 pipe。
	if pipe != nil {
		_ = pipe.Close()
	}
	p.stateMu.Unlock()
}

func (p *sshProxyConn) pipeDeadlineExpired(read bool) bool {
	p.stateMu.Lock()
	defer p.stateMu.Unlock()
	if read {
		return p.readDeadlineExpired
	}
	return p.writeDeadlineExpired
}

type sshProxyAddr string

func (a sshProxyAddr) Network() string { return "ssh" }
func (a sshProxyAddr) String() string  { return string(a) }
