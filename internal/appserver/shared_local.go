package appserver

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
)

const (
	sharedLocalSocketDir    = "app-server-control"
	sharedLocalSocketName   = "app-server-control.sock"
	sharedLocalHandshakeURL = "ws://localhost/rpc"
	sharedLocalStartGrace   = 250 * time.Millisecond
)

type SharedLocalOptions struct {
	CodexBin string
	Env      map[string]string
}

// SharedLocalTransport connects agentd to the same Codex control socket used by
// local terminal clients. It never owns or stops the resident App Server.
type SharedLocalTransport struct {
	codexBin  string
	env       map[string]string
	socket    string
	ensureMu  sync.Mutex
	startOnce func(context.Context, SharedLocalOptions) error
}

func NewSharedLocalTransport(options SharedLocalOptions) (*SharedLocalTransport, error) {
	if runtime.GOOS != "linux" {
		return nil, errors.New("共享本机 App Server 目前只支持 Linux")
	}
	socket, err := SharedLocalSocketPath(options.Env)
	if err != nil {
		return nil, err
	}
	return &SharedLocalTransport{
		codexBin:  strings.TrimSpace(options.CodexBin),
		env:       cloneStringMap(options.Env),
		socket:    socket,
		startOnce: startSharedLocalAppServer,
	}, nil
}

// SharedLocalSocketPath mirrors Codex's unix:// resolution: the control socket
// always lives below the effective CODEX_HOME.
func SharedLocalSocketPath(extraEnv map[string]string) (string, error) {
	codexHome := extraEnv["CODEX_HOME"]
	explicit := codexHome != ""
	if codexHome == "" {
		codexHome = os.Getenv("CODEX_HOME")
		explicit = codexHome != ""
	}
	if codexHome == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", fmt.Errorf("解析用户 Home 失败：%w", err)
		}
		codexHome = filepath.Join(home, ".codex")
	}
	if explicit && !filepath.IsAbs(codexHome) {
		return "", errors.New("共享本机 App Server 要求 CODEX_HOME 使用绝对路径")
	}
	absolute, err := filepath.Abs(codexHome)
	if err != nil {
		return "", fmt.Errorf("解析 CODEX_HOME 失败：%w", err)
	}
	if info, statErr := os.Stat(absolute); statErr == nil {
		if !info.IsDir() {
			return "", errors.New("CODEX_HOME 不是目录")
		}
		if canonical, evalErr := filepath.EvalSymlinks(absolute); evalErr == nil {
			absolute = canonical
		}
	} else if explicit {
		return "", fmt.Errorf("CODEX_HOME 不存在或不可访问：%w", statErr)
	}
	path := filepath.Join(filepath.Clean(absolute), sharedLocalSocketDir, sharedLocalSocketName)
	if len([]byte(path)) >= 104 {
		return "", errors.New("Codex control socket 路径过长，请缩短 CODEX_HOME")
	}
	return path, nil
}

func (t *SharedLocalTransport) SocketPath() string {
	if t == nil {
		return ""
	}
	return t.socket
}

func (t *SharedLocalTransport) WebSocketURL() (string, error) {
	if t == nil || strings.TrimSpace(t.socket) == "" {
		return "", errors.New("共享本机 App Server transport 未初始化")
	}
	return sharedLocalHandshakeURL, nil
}

func (t *SharedLocalTransport) WebSocketHeaders() (http.Header, error) {
	if _, err := t.WebSocketURL(); err != nil {
		return nil, err
	}
	return http.Header{}, nil
}

func (t *SharedLocalTransport) WebSocketDialer(timeout time.Duration) (websocket.Dialer, error) {
	if _, err := t.WebSocketURL(); err != nil {
		return websocket.Dialer{}, err
	}
	if timeout <= 0 {
		timeout = 4 * time.Second
	}
	netDialer := &net.Dialer{Timeout: timeout}
	return websocket.Dialer{
		HandshakeTimeout: timeout,
		NetDialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return netDialer.DialContext(ctx, "unix", t.socket)
		},
	}, nil
}

func (t *SharedLocalTransport) EnsureReady(ctx context.Context) error {
	if t == nil {
		return errors.New("共享本机 App Server transport 未初始化")
	}
	if ctx == nil {
		ctx = context.Background()
	}
	t.ensureMu.Lock()
	defer t.ensureMu.Unlock()

	probeErr := t.probe(ctx)
	if probeErr == nil {
		return nil
	}
	if info, err := os.Lstat(t.socket); err == nil {
		if info.Mode()&os.ModeSocket == 0 {
			return fmt.Errorf("Codex control socket 路径被非 socket 文件占用：%s", t.socket)
		}
		return fmt.Errorf("无法连接到仍存在的 Codex control socket %s：%w", t.socket, probeErr)
	} else if err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("检查 Codex control socket 失败：%w", err)
	}
	startErr := t.startOnce(ctx, SharedLocalOptions{CodexBin: t.codexBin, Env: t.env})
	if startErr != nil {
		// Another process may have won Codex's cross-process startup race after
		// our missing-socket check. Only continue when that winner has published
		// an actual socket; otherwise preserve the launcher error immediately.
		info, statErr := os.Lstat(t.socket)
		if statErr != nil || info.Mode()&os.ModeSocket == 0 {
			return startErr
		}
	}

	var lastErr error
	for {
		attemptCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
		lastErr = t.probe(attemptCtx)
		cancel()
		if lastErr == nil {
			return nil
		}
		select {
		case <-ctx.Done():
			if startErr != nil {
				return fmt.Errorf("等待其他进程启动共享本机 Codex App Server 失败：%v；launcher_error=%w", lastErr, startErr)
			}
			return fmt.Errorf("等待共享本机 Codex App Server 就绪失败：%w", lastErr)
		case <-time.After(100 * time.Millisecond):
		}
	}
}

func (t *SharedLocalTransport) probe(ctx context.Context) error {
	upstreamURL, err := t.WebSocketURL()
	if err != nil {
		return err
	}
	dialer, err := t.WebSocketDialer(4 * time.Second)
	if err != nil {
		return err
	}
	conn, response, err := dialer.DialContext(ctx, upstreamURL, nil)
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

var sharedLocalUnitCounter atomic.Uint64

func startSharedLocalAppServer(ctx context.Context, options SharedLocalOptions) error {
	if _, err := CheckLocalCodex(ctx, options.CodexBin); err != nil {
		return fmt.Errorf("拒绝启动不兼容的共享 Codex App Server：%w", err)
	}
	bin := strings.TrimSpace(options.CodexBin)
	if bin == "" {
		bin = "codex"
	}
	resolvedBin, err := exec.LookPath(bin)
	if err != nil {
		return fmt.Errorf("定位 Codex CLI 失败：%w", err)
	}
	env := cloneStringMap(options.Env)
	env["CODEX_INTERNAL_APP_SERVER_REMOTE_CONTROL_DISABLED"] = "1"
	workingDirectory, err := sharedLocalWorkingDirectory(env)
	if err != nil {
		return err
	}
	env["PWD"] = workingDirectory

	if systemdRun, lookupErr := exec.LookPath("systemd-run"); lookupErr == nil {
		socketPath, socketErr := SharedLocalSocketPath(env)
		if socketErr != nil {
			return socketErr
		}
		environmentFile, environmentErr := writeSystemdEnvironmentFile(
			filepath.Dir(socketPath),
			sharedLocalResidentEnvironment(env),
		)
		if environmentErr != nil {
			return environmentErr
		}
		unit := fmt.Sprintf(
			"mimi-codex-app-server-%d-%d.service",
			os.Getpid(),
			sharedLocalUnitCounter.Add(1),
		)
		args := systemdResidentCommandArgs(
			unit,
			workingDirectory,
			environmentFile,
			resolvedBin,
			[]string{"-c", "features.code_mode_host=true", "app-server", "--listen", "unix://"},
		)
		launchErr := runSystemdResidentCommand(
			ctx,
			systemdRun,
			args,
			workingDirectory,
			buildManagedEnv(env),
		)
		_ = os.Remove(environmentFile)
		if launchErr == nil {
			return nil
		}
	}
	return startResidentCommand(
		resolvedBin,
		[]string{"-c", "features.code_mode_host=true", "app-server", "--listen", "unix://"},
		env,
	)
}

func systemdResidentCommandArgs(
	unit string,
	workingDirectory string,
	environmentFile string,
	bin string,
	args []string,
) []string {
	command := []string{
		"--user",
		"--collect",
		"--quiet",
		"--service-type=exec",
		"--unit=" + unit,
		"--working-directory=" + workingDirectory,
		"--property=EnvironmentFile=" + environmentFile,
		"--property=StandardOutput=null",
		"--property=StandardError=null",
		bin,
	}
	return append(command, args...)
}

func runSystemdResidentCommand(
	ctx context.Context,
	bin string,
	args []string,
	workingDirectory string,
	env []string,
) error {
	cmd := exec.CommandContext(ctx, bin, args...)
	cmd.Dir = workingDirectory
	cmd.Env = env
	output, err := cmd.CombinedOutput()
	if err == nil {
		return nil
	}
	diagnostic := sanitizeDiagnostic(string(output))
	if len(diagnostic) > 2048 {
		diagnostic = diagnostic[:2048]
	}
	if diagnostic == "" {
		diagnostic = err.Error()
	}
	return fmt.Errorf("通过 systemd 启动共享 Codex App Server 失败：%s", diagnostic)
}

func sharedLocalResidentEnvironment(extraEnv map[string]string) []string {
	blocked := map[string]struct{}{
		"CREDENTIALS_DIRECTORY": {},
		"INVOCATION_ID":         {},
		"JOURNAL_STREAM":        {},
		"LISTEN_FDS":            {},
		"LISTEN_FDNAMES":        {},
		"LISTEN_PID":            {},
		"NOTIFY_SOCKET":         {},
		"SYSTEMD_EXEC_PID":      {},
		"WATCHDOG_PID":          {},
		"WATCHDOG_USEC":         {},
	}
	managed := buildManagedEnv(extraEnv)
	result := make([]string, 0, len(managed))
	for _, entry := range managed {
		key, _, ok := strings.Cut(entry, "=")
		if !ok || !validSystemdEnvironmentName(key) {
			continue
		}
		if _, excluded := blocked[key]; excluded {
			continue
		}
		result = append(result, entry)
	}
	return result
}

func writeSystemdEnvironmentFile(directory string, env []string) (path string, returnErr error) {
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return "", fmt.Errorf("创建共享 App Server control 目录失败：%w", err)
	}
	file, err := os.CreateTemp(directory, ".resident-env-")
	if err != nil {
		return "", fmt.Errorf("创建共享 App Server 临时环境文件失败：%w", err)
	}
	path = file.Name()
	defer func() {
		if closeErr := file.Close(); returnErr == nil && closeErr != nil {
			returnErr = fmt.Errorf("关闭共享 App Server 临时环境文件失败：%w", closeErr)
		}
		if returnErr != nil {
			_ = os.Remove(path)
		}
	}()
	for _, entry := range env {
		key, value, ok := strings.Cut(entry, "=")
		if !ok || !validSystemdEnvironmentName(key) {
			return "", fmt.Errorf("共享 App Server 环境变量名称无效：%q", key)
		}
		if strings.ContainsRune(value, '\x00') {
			return "", fmt.Errorf("共享 App Server 环境变量 %s 包含 NUL", key)
		}
		quoted := strings.NewReplacer(`\`, `\\`, `"`, `\"`).Replace(value)
		if _, err := fmt.Fprintf(file, "%s=\"%s\"\n", key, quoted); err != nil {
			return "", fmt.Errorf("写入共享 App Server 临时环境文件失败：%w", err)
		}
	}
	return path, nil
}

func validSystemdEnvironmentName(value string) bool {
	if value == "" {
		return false
	}
	for index, character := range value {
		if character == '_' ||
			character >= 'a' && character <= 'z' ||
			character >= 'A' && character <= 'Z' ||
			index > 0 && character >= '0' && character <= '9' {
			continue
		}
		return false
	}
	return true
}

func startResidentCommand(bin string, args []string, extraEnv map[string]string) error {
	workingDirectory, err := sharedLocalWorkingDirectory(extraEnv)
	if err != nil {
		return err
	}
	cmd := exec.CommandContext(context.Background(), bin, args...)
	configureSharedLocalCommand(cmd)
	// The installer may invoke agentd from a temporary extraction directory.
	// The resident server outlives that directory, and Codex needs a valid cwd
	// later when it resolves thread/list workspace filters.
	cmd.Dir = workingDirectory
	cmd.Env = buildManagedEnv(extraEnv)
	cmd.Stdout = io.Discard
	// resident outlives agentd. It must not retain a pipe whose reader
	// disappears on gateway restart, otherwise a later log write can hit EPIPE.
	cmd.Stderr = io.Discard
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("启动共享 Codex App Server 失败：%w", err)
	}
	waitCh := make(chan error, 1)
	go func() { waitCh <- cmd.Wait() }()
	select {
	case waitErr := <-waitCh:
		return fmt.Errorf("共享 Codex App Server 启动后立即退出：%v", waitErr)
	case <-time.After(sharedLocalStartGrace):
		return nil
	}
}

func sharedLocalWorkingDirectory(extraEnv map[string]string) (string, error) {
	home, overridden := extraEnv["HOME"]
	if !overridden {
		home = os.Getenv("HOME")
	}
	home = strings.TrimSpace(home)
	if home == "" {
		return "", errors.New("启动共享 Codex App Server 需要有效的 HOME")
	}
	if !filepath.IsAbs(home) {
		return "", errors.New("启动共享 Codex App Server 要求 HOME 使用绝对路径")
	}
	info, err := os.Stat(home)
	if err != nil {
		return "", fmt.Errorf("共享 Codex App Server 的 HOME 不存在或不可访问：%w", err)
	}
	if !info.IsDir() {
		return "", errors.New("共享 Codex App Server 的 HOME 不是目录")
	}
	if canonical, evalErr := filepath.EvalSymlinks(home); evalErr == nil {
		home = canonical
	}
	return filepath.Clean(home), nil
}

func cloneStringMap(source map[string]string) map[string]string {
	cloned := make(map[string]string, len(source)+1)
	for key, value := range source {
		cloned[key] = value
	}
	return cloned
}
