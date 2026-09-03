package appserver

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

type ManagedWebSocketOptions struct {
	CodexBin       string
	Env            map[string]string
	Listen         string
	WSTokenFile    string
	EarlyExitGrace time.Duration
}

// ManagedWebSocketProcess is the Windows-local counterpart to SSHTransport.
// It owns exactly one loopback Codex App Server and exposes the same gateway
// contract without reintroducing the removed macOS Desktop IPC lifecycle.
type ManagedWebSocketProcess struct {
	cmd          *exec.Cmd
	listen       string
	wsTokenFile  string
	startedAt    time.Time
	waitCh       chan error
	doneCh       chan struct{}
	waitErrMu    sync.Mutex
	waitErr      error
	tailMu       sync.Mutex
	stderrTail   []string
	shutdownOnce sync.Once
}

const defaultManagedWebSocketEarlyExitGrace = 2 * time.Second

func CheckLocalCodex(ctx context.Context, configuredBin string) (string, error) {
	bin := strings.TrimSpace(configuredBin)
	if bin == "" {
		bin = "codex"
	}
	output, err := exec.CommandContext(ctx, bin, "--version").CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("Codex CLI 版本检查失败：%w", err)
	}
	version, ok := ParseCodexVersion(string(output))
	if !ok {
		return "", errors.New("Codex CLI 版本输出无法解析")
	}
	if CompareCodexVersions(version, MinimumCodexVersion) < 0 {
		return "", fmt.Errorf("Codex %s 低于最低兼容版本 %s", version, MinimumCodexVersion)
	}
	return version, nil
}

func StartManagedWebSocket(ctx context.Context, options ManagedWebSocketOptions) (*ManagedWebSocketProcess, error) {
	bin := strings.TrimSpace(options.CodexBin)
	if bin == "" {
		bin = "codex"
	}
	listen, err := normalizeManagedWebSocketListen(options.Listen)
	if err != nil {
		return nil, err
	}
	if _, err := CheckLocalCodex(ctx, bin); err != nil {
		return nil, fmt.Errorf("拒绝启动不兼容的 Codex app-server：%w", err)
	}
	tokenFile := strings.TrimSpace(options.WSTokenFile)
	if tokenFile == "" {
		return nil, errors.New("受管 app-server WebSocket 必须配置独立 capability token file")
	}
	cmd := exec.CommandContext(
		context.Background(),
		bin,
		"-c", "features.code_mode_host=true",
		"app-server", "--listen", listen,
		"--ws-auth", "capability-token", "--ws-token-file", tokenFile,
	)
	configureManagedCommand(cmd)
	cmd.Env = buildManagedEnv(options.Env)
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, fmt.Errorf("创建 app-server stderr 失败：%w", err)
	}
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("启动 codex app-server WebSocket 失败：%w", err)
	}
	process := &ManagedWebSocketProcess{
		cmd: cmd, listen: listen, wsTokenFile: tokenFile, startedAt: time.Now().UTC(),
		waitCh: make(chan error, 1), doneCh: make(chan struct{}),
	}
	go process.captureStderr(stderr)
	go func() {
		err := cmd.Wait()
		process.waitErrMu.Lock()
		process.waitErr = err
		process.waitErrMu.Unlock()
		process.waitCh <- err
		close(process.doneCh)
	}()
	grace := options.EarlyExitGrace
	if grace <= 0 {
		grace = defaultManagedWebSocketEarlyExitGrace
	}
	select {
	case err := <-process.waitCh:
		if err == nil {
			return nil, errors.New("codex app-server WebSocket 启动后立即正常退出")
		}
		return nil, fmt.Errorf("codex app-server WebSocket 启动后立即退出：%w", err)
	case <-ctx.Done():
		_ = process.Shutdown(context.Background())
		return nil, ctx.Err()
	case <-time.After(grace):
	}
	return process, nil
}

func (p *ManagedWebSocketProcess) WebSocketURL() (string, error) {
	if p == nil || strings.TrimSpace(p.listen) == "" {
		return "", errors.New("受管 app-server WebSocket 未初始化")
	}
	return p.listen, nil
}

func (p *ManagedWebSocketProcess) WebSocketDialer(timeout time.Duration) (websocket.Dialer, error) {
	if _, err := p.WebSocketURL(); err != nil {
		return websocket.Dialer{}, err
	}
	if timeout <= 0 {
		timeout = 4 * time.Second
	}
	return websocket.Dialer{HandshakeTimeout: timeout}, nil
}

func (p *ManagedWebSocketProcess) WebSocketHeaders() (http.Header, error) {
	if p == nil || strings.TrimSpace(p.wsTokenFile) == "" {
		return nil, errors.New("受管 app-server WebSocket token file 未配置")
	}
	raw, err := os.ReadFile(p.wsTokenFile)
	if err != nil {
		return nil, fmt.Errorf("读取 app-server WebSocket token file 失败：%w", err)
	}
	token := strings.TrimSpace(string(raw))
	if token == "" {
		return nil, errors.New("app-server WebSocket token file 为空")
	}
	headers := http.Header{}
	headers.Set("Authorization", "Bearer "+token)
	return headers, nil
}

func (p *ManagedWebSocketProcess) EnsureReady(ctx context.Context) error {
	upstreamURL, err := p.WebSocketURL()
	if err != nil {
		return err
	}
	dialer, err := p.WebSocketDialer(4 * time.Second)
	if err != nil {
		return err
	}
	headers, err := p.WebSocketHeaders()
	if err != nil {
		return err
	}
	conn, response, err := dialer.DialContext(ctx, upstreamURL, headers)
	if response != nil && response.Body != nil {
		_ = response.Body.Close()
	}
	if err != nil {
		return err
	}
	defer conn.Close()
	if deadline, ok := ctx.Deadline(); ok {
		_ = conn.SetReadDeadline(deadline)
		_ = conn.SetWriteDeadline(deadline)
	}
	return initializeWebSocket(ctx, conn)
}

func (p *ManagedWebSocketProcess) WaitReady(ctx context.Context) error {
	var lastErr error
	for {
		attemptCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
		lastErr = p.EnsureReady(attemptCtx)
		cancel()
		if lastErr == nil {
			return nil
		}
		select {
		case <-p.Done():
			if exitErr := p.ExitError(); exitErr != nil {
				return fmt.Errorf("codex app-server WebSocket 就绪前退出：%w", exitErr)
			}
			return errors.New("codex app-server WebSocket 就绪前退出")
		case <-ctx.Done():
			return fmt.Errorf("等待 codex app-server WebSocket 就绪失败：%w", lastErr)
		case <-time.After(200 * time.Millisecond):
		}
	}
}

func (p *ManagedWebSocketProcess) StartedAt() time.Time {
	if p == nil {
		return time.Time{}
	}
	return p.startedAt
}

func (p *ManagedWebSocketProcess) Done() <-chan struct{} {
	if p != nil {
		return p.doneCh
	}
	closed := make(chan struct{})
	close(closed)
	return closed
}

func (p *ManagedWebSocketProcess) ExitError() error {
	if p == nil {
		return nil
	}
	p.waitErrMu.Lock()
	defer p.waitErrMu.Unlock()
	return p.waitErr
}

func (p *ManagedWebSocketProcess) Shutdown(ctx context.Context) error {
	if p == nil {
		return nil
	}
	var shutdownErr error
	p.shutdownOnce.Do(func() {
		select {
		case err := <-p.waitCh:
			shutdownErr = ignoreKilledProcessError(err)
			return
		case <-ctx.Done():
		case <-time.After(300 * time.Millisecond):
		}
		terminateManagedProcess(p.cmd)
		select {
		case err := <-p.waitCh:
			shutdownErr = ignoreKilledProcessError(err)
		case <-ctx.Done():
			shutdownErr = ctx.Err()
		case <-time.After(2 * time.Second):
			shutdownErr = errors.New("等待 app-server WebSocket 退出超时")
		}
	})
	return shutdownErr
}

func (p *ManagedWebSocketProcess) captureStderr(stderr io.Reader) {
	scanner := bufio.NewScanner(stderr)
	scanner.Buffer(make([]byte, 1024), 1024*1024)
	for scanner.Scan() {
		line := sanitizeDiagnostic(scanner.Text())
		p.tailMu.Lock()
		p.stderrTail = append(p.stderrTail, line)
		if len(p.stderrTail) > 50 {
			p.stderrTail = p.stderrTail[len(p.stderrTail)-50:]
		}
		p.tailMu.Unlock()
	}
}

func normalizeManagedWebSocketListen(raw string) (string, error) {
	value := strings.TrimSpace(raw)
	if !strings.Contains(value, "://") {
		value = "ws://" + value
	}
	parsed, err := url.Parse(value)
	if err != nil || !strings.EqualFold(parsed.Scheme, "ws") || parsed.Port() == "" {
		return "", errors.New("app-server WebSocket 必须是有效的 ws:// loopback 地址")
	}
	host := parsed.Hostname()
	ip := net.ParseIP(host)
	if !strings.EqualFold(host, "localhost") && (ip == nil || !ip.IsLoopback()) {
		return "", errors.New("app-server WebSocket 只能监听 loopback")
	}
	return parsed.String(), nil
}
