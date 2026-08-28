package appserver

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"
)

type ManagedOptions struct {
	CodexBin             string
	Env                  map[string]string
	ClientInfo           ClientInfo
	Capabilities         map[string]any
	NotificationBuffer   int
	ServerRequestTimeout time.Duration
	OverloadRetries      int
	OverloadBackoff      time.Duration
	ServerRequestHandler ServerRequestHandler
}

type ManagedProcess struct {
	client *Client
	cmd    *exec.Cmd
	stdin  io.Closer

	waitCh chan error

	tailMu     sync.Mutex
	stderrTail []string

	shutdownOnce sync.Once
}

type ManagedWebSocketOptions struct {
	CodexBin       string
	Env            map[string]string
	Listen         string
	WSTokenFile    string
	EarlyExitGrace time.Duration
}

type ManagedWebSocketProcess struct {
	cmd       *exec.Cmd
	startedAt time.Time

	waitCh chan error
	doneCh chan struct{}

	waitErrMu sync.Mutex
	waitErr   error

	tailMu     sync.Mutex
	stderrTail []string

	shutdownOnce sync.Once
}

const defaultManagedWebSocketEarlyExitGrace = 2 * time.Second

func StartManaged(ctx context.Context, options ManagedOptions) (*ManagedProcess, InitializeResult, error) {
	bin := strings.TrimSpace(options.CodexBin)
	if bin == "" {
		bin = "codex"
	}
	if err := ctx.Err(); err != nil {
		return nil, InitializeResult{}, err
	}
	if err := validateManagedCodexRuntime(ctx, bin); err != nil {
		return nil, InitializeResult{}, fmt.Errorf("拒绝启动不安全的 Codex app-server：%w", err)
	}
	// 传入的 ctx 只约束 initialize 握手；子进程寿命由 Shutdown 统一管理。
	// 否则 startAppServerRuntime 返回时取消握手 ctx，会把托管 app-server 一起杀掉。
	cmd := exec.CommandContext(context.Background(), bin, "app-server", "--listen", "stdio://")
	configureManagedCommand(cmd)
	cmd.Env = buildManagedEnv(options.Env)

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, InitializeResult{}, fmt.Errorf("创建 app-server stdin 失败：%w", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, InitializeResult{}, fmt.Errorf("创建 app-server stdout 失败：%w", err)
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, InitializeResult{}, fmt.Errorf("创建 app-server stderr 失败：%w", err)
	}
	if err := cmd.Start(); err != nil {
		return nil, InitializeResult{}, fmt.Errorf("启动 codex app-server 失败：%w", err)
	}

	process := &ManagedProcess{cmd: cmd, stdin: stdin, waitCh: make(chan error, 1)}
	go process.captureStderr(stderr)
	go func() {
		process.waitCh <- cmd.Wait()
	}()

	client := NewClient(stdout, stdin, ClientOptions{
		ClientInfo:           options.ClientInfo,
		Capabilities:         options.Capabilities,
		NotificationBuffer:   options.NotificationBuffer,
		ServerRequestTimeout: options.ServerRequestTimeout,
		OverloadRetries:      options.OverloadRetries,
		OverloadBackoff:      options.OverloadBackoff,
		ServerRequestHandler: options.ServerRequestHandler,
	})
	process.client = client
	result, err := client.Initialize(ctx)
	if err != nil {
		_ = process.Shutdown(context.Background())
		return nil, InitializeResult{}, fmt.Errorf("初始化 codex app-server 失败：%w", err)
	}
	return process, result, nil
}

func StartManagedWebSocket(ctx context.Context, options ManagedWebSocketOptions) (*ManagedWebSocketProcess, error) {
	bin := strings.TrimSpace(options.CodexBin)
	if bin == "" {
		bin = "codex"
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if err := validateManagedCodexRuntime(ctx, bin); err != nil {
		return nil, fmt.Errorf("拒绝启动不安全的 Codex app-server WebSocket：%w", err)
	}
	listen, err := normalizeWebSocketListen(options.Listen)
	if err != nil {
		return nil, err
	}
	args := []string{"app-server", "--listen", listen}
	if tokenFile := strings.TrimSpace(options.WSTokenFile); tokenFile != "" {
		args = append(args, "--ws-auth", "capability-token", "--ws-token-file", tokenFile)
	}
	// WebSocket 模式只需要 agentd 负责进程寿命；JSON-RPC initialize 仍由 iPad direct 客户端完成。
	cmd := exec.CommandContext(context.Background(), bin, args...)
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
		cmd:       cmd,
		startedAt: time.Now().UTC(),
		waitCh:    make(chan error, 1),
		doneCh:    make(chan struct{}),
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
	// 启动失败通常会很快退出；给慢机器/CI 留一点窗口，避免把坏配置误判为启动成功。
	earlyExitGrace := options.EarlyExitGrace
	if earlyExitGrace <= 0 {
		earlyExitGrace = defaultManagedWebSocketEarlyExitGrace
	}
	select {
	case err := <-process.waitCh:
		if err == nil {
			return nil, fmt.Errorf("codex app-server WebSocket 启动后立即退出")
		}
		return nil, fmt.Errorf("codex app-server WebSocket 启动后立即退出：%w", err)
	case <-ctx.Done():
		_ = process.Shutdown(context.Background())
		return nil, ctx.Err()
	case <-time.After(earlyExitGrace):
	}
	return process, nil
}

func (p *ManagedProcess) Client() *Client {
	if p == nil {
		return nil
	}
	return p.client
}

func (p *ManagedProcess) Diagnostics() Diagnostics {
	if p == nil || p.client == nil {
		return Diagnostics{}
	}
	diag := p.client.Diagnostics()
	p.tailMu.Lock()
	diag.StderrTail = append([]string(nil), p.stderrTail...)
	p.tailMu.Unlock()
	return diag
}

func (p *ManagedWebSocketProcess) Diagnostics() Diagnostics {
	if p == nil {
		return Diagnostics{}
	}
	diag := Diagnostics{Running: true}
	select {
	case <-p.doneCh:
		diag.Running = false
	default:
	}
	p.tailMu.Lock()
	diag.StderrTail = append([]string(nil), p.stderrTail...)
	p.tailMu.Unlock()
	return diag
}

// StartedAt 返回当前 resident Codex app-server 的真实启动时间。
// 时间跟随子进程而不是 agentd HTTP 服务，运行时重启后不会沿用旧值。
func (p *ManagedWebSocketProcess) StartedAt() time.Time {
	if p == nil {
		return time.Time{}
	}
	return p.startedAt
}

func (p *ManagedWebSocketProcess) Done() <-chan struct{} {
	if p == nil {
		closed := make(chan struct{})
		close(closed)
		return closed
	}
	return p.doneCh
}

func (p *ManagedWebSocketProcess) ExitError() error {
	if p == nil {
		return nil
	}
	p.waitErrMu.Lock()
	defer p.waitErrMu.Unlock()
	return p.waitErr
}

func (p *ManagedProcess) Shutdown(ctx context.Context) error {
	if p == nil {
		return nil
	}
	var shutdownErr error
	p.shutdownOnce.Do(func() {
		if p.client != nil {
			_ = p.client.Close()
		}
		if p.stdin != nil {
			_ = p.stdin.Close()
		}
		select {
		case err := <-p.waitCh:
			shutdownErr = err
			return
		case <-ctx.Done():
		case <-time.After(300 * time.Millisecond):
		}
		if p.cmd != nil && p.cmd.Process != nil {
			terminateManagedProcess(p.cmd)
		}
		select {
		case err := <-p.waitCh:
			shutdownErr = ignoreKilledProcessError(err)
		case <-ctx.Done():
			shutdownErr = ctx.Err()
		case <-time.After(2 * time.Second):
			shutdownErr = fmt.Errorf("等待 app-server 退出超时")
		}
	})
	return shutdownErr
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
		if p.cmd != nil && p.cmd.Process != nil {
			terminateManagedProcess(p.cmd)
		}
		select {
		case err := <-p.waitCh:
			shutdownErr = ignoreKilledProcessError(err)
		case <-ctx.Done():
			shutdownErr = ctx.Err()
		case <-time.After(2 * time.Second):
			shutdownErr = fmt.Errorf("等待 app-server WebSocket 退出超时")
		}
	})
	return shutdownErr
}

func ignoreKilledProcessError(err error) error {
	if err == nil {
		return nil
	}
	if strings.Contains(err.Error(), "signal: killed") {
		return nil
	}
	return err
}

func (p *ManagedProcess) captureStderr(stderr io.Reader) {
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

func buildManagedEnv(extra map[string]string) []string {
	// 受管 App Server 必须保持独立。旧实验版本可能在 launchd 会话中留下
	// Desktop transport 环境；无论它来自继承环境还是 codex.env，都不能透传。
	filtered := map[string]struct{}{
		"CODEX_APP_SERVER_USE_LOCAL_DAEMON":         {},
		"CODEX_APP_SERVER_WS_URL":                   {},
		"MIMI_REMOTE_CODEX_DESKTOP_OWNERSHIP_EPOCH": {},
	}
	values := make(map[string]string, len(os.Environ())+len(extra))
	order := make([]string, 0, len(os.Environ())+len(extra))
	for _, entry := range os.Environ() {
		key, value, ok := strings.Cut(entry, "=")
		if !ok || strings.TrimSpace(key) == "" {
			continue
		}
		if _, blocked := filtered[key]; blocked {
			continue
		}
		if _, exists := values[key]; !exists {
			order = append(order, key)
		}
		values[key] = value
	}
	for k, v := range extra {
		if strings.TrimSpace(k) == "" {
			continue
		}
		if _, blocked := filtered[k]; blocked {
			continue
		}
		if _, exists := values[k]; !exists {
			order = append(order, k)
		}
		values[k] = v
	}
	env := make([]string, 0, len(order))
	for _, key := range order {
		env = append(env, key+"="+values[key])
	}
	return env
}

func sanitizeDiagnostic(value string) string {
	line := strings.TrimSpace(value)
	if line == "" {
		return ""
	}
	redactKeys := []string{"token", "secret", "password", "authorization", "bearer"}
	lower := strings.ToLower(line)
	for _, key := range redactKeys {
		if strings.Contains(lower, key) {
			return "[redacted sensitive app-server diagnostic]"
		}
	}
	return line
}

func normalizeWebSocketListen(raw string) (string, error) {
	value := strings.TrimSpace(raw)
	if value == "" {
		return "", fmt.Errorf("app-server WebSocket listen 不能为空")
	}
	if !strings.Contains(value, "://") {
		value = "ws://" + value
	}
	parsed, err := url.Parse(value)
	if err != nil {
		return "", fmt.Errorf("app-server WebSocket listen 无效：%w", err)
	}
	switch parsed.Scheme {
	case "ws", "wss":
	default:
		return "", fmt.Errorf("app-server WebSocket listen 只支持 ws/wss")
	}
	if parsed.Host == "" {
		return "", fmt.Errorf("app-server WebSocket listen 缺少 host")
	}
	return parsed.String(), nil
}
