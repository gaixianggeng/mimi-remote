package appserver

import (
	"context"
	"errors"
	"fmt"
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

// sharedLocalDefaultReadyTimeout 是调用方没有给 deadline 时 EnsureReady 的总上限。
// initializeWebSocket 只在 context 带 deadline 时才设置读写 deadline，没有这层兜底，
// 握手成功却不回应 initialize 的 socket 会让首次 probe 永远阻塞。
var sharedLocalDefaultReadyTimeout = 20 * time.Second

type SharedLocalOptions struct {
	CodexBin string
	Env      map[string]string
	// BackendCodexHome 为 Mac 前门指定独立 backend 身份目录，并供 ConnectOnly 校验实际连接身份。
	BackendCodexHome string
	// ConnectOnly 用于 Mac App 的 launchd 前门。前门不可用时不能由 agentd
	// 重新绑定标准 socket，否则 Desktop SSH 仍可参与启动权竞争。
	ConnectOnly bool
}

// SharedLocalTransport connects agentd to the same Codex control socket used by
// local terminal clients. It never owns or stops the resident App Server.
type SharedLocalTransport struct {
	codexBin            string
	env                 map[string]string
	socket              string
	expectedBackendHome string
	requireBackendHome  bool
	ensureMu            sync.Mutex
	startOnce           func(context.Context, SharedLocalOptions) error
}

// SupportsSharedLocalTransport reports whether this host can attach to Codex's
// standard Unix control socket directly. macOS and Linux share the same socket
// with local terminal clients and with Codex Desktop's SSH-host proxy.
func SupportsSharedLocalTransport() bool {
	return runtime.GOOS == "linux" || runtime.GOOS == "darwin"
}

func NewSharedLocalTransport(options SharedLocalOptions) (*SharedLocalTransport, error) {
	if !SupportsSharedLocalTransport() {
		return nil, errors.New("共享本机 App Server 只支持 macOS 与 Linux 本机宿主")
	}
	socket, err := SharedLocalSocketPath(options.Env)
	if err != nil {
		return nil, err
	}
	expectedBackendHome := ""
	requireBackendHome := false
	if runtime.GOOS == "darwin" && options.ConnectOnly {
		if options.BackendCodexHome != "" {
			expectedBackendHome, err = canonicalExistingDirectory(options.BackendCodexHome)
			if err != nil {
				return nil, fmt.Errorf("解析期望的 Codex backend CODEX_HOME 失败：%w", err)
			}
			requireBackendHome = true
		} else {
			// 空配置表示回退到公共 CODEX_HOME。旧 CLI 不报告 codexHome 时保持兼容；
			// 新 CLI 一旦报告就必须匹配，避免误连仍在运行的旧隔离前门。
			expectedBackendHome = filepath.Dir(filepath.Dir(socket))
		}
	}
	transport := &SharedLocalTransport{
		codexBin:            strings.TrimSpace(options.CodexBin),
		env:                 cloneStringMap(options.Env),
		socket:              socket,
		expectedBackendHome: expectedBackendHome,
		requireBackendHome:  requireBackendHome,
	}
	if !options.ConnectOnly {
		transport.startOnce = startSharedLocalAppServer
	}
	return transport, nil
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

func canonicalExistingDirectory(path string) (string, error) {
	if !filepath.IsAbs(path) {
		return "", errors.New("路径必须是绝对路径")
	}
	info, err := os.Stat(path)
	if err != nil {
		return "", fmt.Errorf("目录不存在或不可访问：%w", err)
	}
	if !info.IsDir() {
		return "", errors.New("路径不是目录")
	}
	canonical, err := filepath.EvalSymlinks(path)
	if err != nil {
		return "", fmt.Errorf("解析目录规范路径失败：%w", err)
	}
	return filepath.Clean(canonical), nil
}

func validateExpectedBackendCodexHome(expected, reported string, required bool) error {
	if expected == "" {
		return nil
	}
	if reported == "" && !required {
		return nil
	}
	reportedCanonical, err := canonicalExistingDirectory(reported)
	if err != nil || reportedCanonical != expected {
		return &SharedLocalSessionError{Kind: "backend_home", Err: errors.New("app-server 未报告期望的 CODEX_HOME")}
	}
	return nil
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
	dialer, err := t.rawWebSocketDialer(timeout)
	if err != nil {
		return websocket.Dialer{}, err
	}
	rawDial := dialer.NetDialContext
	dialer.NetDialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
		conn, err := rawDial(ctx, network, address)
		if err != nil {
			return nil, err
		}
		// startup 检查通过后，Desktop 仍可能重建 resident。业务连接必须验证
		// 自己实际连接的 owner，不能把 agentd 启动时的检查当作永久授权。
		if err := t.validateConnectionSession(ctx, conn); err != nil {
			_ = conn.Close()
			return nil, err
		}
		return conn, nil
	}
	return dialer, nil
}

// rawWebSocketDialer 仅供登录环境探针和显式修复使用，业务连接不得绕过校验。
func (t *SharedLocalTransport) rawWebSocketDialer(timeout time.Duration) (websocket.Dialer, error) {
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
	if _, hasDeadline := ctx.Deadline(); !hasDeadline {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, sharedLocalDefaultReadyTimeout)
		defer cancel()
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
	if t.startOnce == nil {
		return errors.New("共享 Codex 前门尚未就绪；请检查 Mimi Remote Mac 的后台项目和前门诊断")
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
	dialer, err := t.rawWebSocketDialer(4 * time.Second)
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
	initializeResult, err := initializeWebSocketResult(ctx, conn)
	if err != nil {
		return err
	}
	if err := validateExpectedBackendCodexHome(t.expectedBackendHome, initializeResult.CodexHome, t.requireBackendHome); err != nil {
		return err
	}
	return validateSharedLocalSession(ctx, conn)
}

var sharedLocalUnitCounter atomic.Uint64

func startSharedLocalAppServer(ctx context.Context, options SharedLocalOptions) error {
	return startSharedLocalAppServerListening(ctx, options, "unix://")
}

// startSharedLocalAppServerListening 以 Desktop 相同的参数启动 resident，只替换监听地址。
// 前门使用私有 backend socket；标准 control socket 由 launchd 持有。
func startSharedLocalAppServerListening(ctx context.Context, options SharedLocalOptions, listen string) error {
	if err := validateSharedLocalLaunchSession(ctx); err != nil {
		return err
	}
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
			[]string{"-c", "features.code_mode_host=true", "app-server", "--listen", listen},
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
		[]string{"-c", "features.code_mode_host=true", "app-server", "--listen", listen},
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
	launchBin, launchArgs := residentLaunchCommand(bin, args)
	cmd := exec.CommandContext(context.Background(), launchBin, launchArgs...)
	configureSharedLocalCommand(cmd)
	// The installer may invoke agentd from a temporary extraction directory.
	// The resident server outlives that directory, and Codex needs a valid cwd
	// later when it resolves thread/list workspace filters.
	cmd.Dir = workingDirectory
	cmd.Env = buildManagedEnv(extraEnv)
	// resident outlives agentd. os/exec turns any non-*os.File writer (including
	// io.Discard) into a pipe drained by a goroutine in this process, so a later
	// log write after agentd exits would hit EPIPE. nil connects the child to the
	// null device directly and keeps it independent of the launcher's lifetime.
	cmd.Stdout = nil
	cmd.Stderr = nil
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
