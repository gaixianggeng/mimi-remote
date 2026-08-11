package appserver

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/gorilla/websocket"
)

const (
	// LocalDaemonListen 是 Codex 官方共享 app-server 的默认 Unix socket transport。
	// Desktop 会在 CODEX_APP_SERVER_USE_LOCAL_DAEMON=1 时连接同一个 socket。
	LocalDaemonListen           = "unix://"
	LocalDaemonEnvironmentKey   = "CODEX_APP_SERVER_USE_LOCAL_DAEMON"
	localDaemonSocketDir        = "app-server-control"
	localDaemonSocketName       = "app-server-control.sock"
	localDaemonHandshakeURL     = "ws://localhost/rpc"
	localDaemonStartTimeout     = 15 * time.Second
	localDaemonProbeTimeout     = 2 * time.Second
	minimumDesktopDaemonVersion = "0.141.0"
)

// initialize.userAgent 的 product 由发起 initialize 的 clientInfo 决定，并不固定为
// Codex Desktop。这里只解析首个 product/version，避免把括号中的系统版本误当成
// app-server 版本。
var localDaemonVersionPattern = regexp.MustCompile(`^[^/\r\n]+/([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?)(?:[[:space:](]|$)`)

var ErrLocalDaemonStandaloneMissing = errors.New("Codex standalone 安装缺失")

type LocalDaemonOptions struct {
	CodexBin string
	Env      map[string]string
}

type LocalDaemonStatus struct {
	SocketPath string
	StartedAt  time.Time
	Started    bool
	Version    string
}

type localDaemonHooks struct {
	probe func(context.Context, string) (LocalDaemonProbe, error)
	start func(context.Context, LocalDaemonOptions) error
	stat  func(string) (os.FileInfo, error)
}

type LocalDaemonProbe struct {
	Version   string
	CodexHome string
}

// LocalDaemonLifecycleStatus 来自官方 `daemon version`，用于区分“当前 socket
// 可连接”和“冷启动也有 standalone 安装可恢复”两个不同健康层级。
type LocalDaemonLifecycleStatus struct {
	Status              string  `json:"status"`
	ManagedCodexPath    string  `json:"managedCodexPath"`
	ManagedCodexVersion *string `json:"managedCodexVersion"`
	SocketPath          string  `json:"socketPath"`
	CLIVersion          string  `json:"cliVersion"`
	AppServerVersion    string  `json:"appServerVersion"`
}

// LocalDaemonSocketPath 必须与 Codex Desktop 和 `codex app-server daemon`
// 使用完全相同的 CODEX_HOME 解析规则，否则两个客户端会再次落到不同进程。
func LocalDaemonSocketPath(extraEnv map[string]string) (string, error) {
	// CODEX_HOME 是文件系统标识，不能 TrimSpace 或展开 `~`；Desktop 会原样
	// 拼接该值。这里若“友好修正”路径，反而会让两个进程指向不同 socket。
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
		return "", fmt.Errorf("共享 Codex daemon 要求 CODEX_HOME 使用绝对路径")
	}
	absolute := codexHome
	if !filepath.IsAbs(absolute) {
		var err error
		absolute, err = filepath.Abs(absolute)
		if err != nil {
			return "", fmt.Errorf("解析 CODEX_HOME 失败：%w", err)
		}
	}
	if info, statErr := os.Stat(absolute); statErr == nil {
		if !info.IsDir() {
			return "", fmt.Errorf("CODEX_HOME 不是目录")
		}
		if canonical, evalErr := filepath.EvalSymlinks(absolute); evalErr == nil {
			absolute = canonical
		}
	} else if explicit {
		return "", fmt.Errorf("CODEX_HOME 不存在或不可访问：%w", statErr)
	}
	path := filepath.Join(filepath.Clean(absolute), localDaemonSocketDir, localDaemonSocketName)
	// 各 Unix 平台 sockaddr_un.sun_path 都很短；按 Darwin 的 104 bytes 取保守交集，
	// 避免 daemon 启动后只留下模糊的 invalid argument。
	if runtime.GOOS != "windows" && len([]byte(path)) >= 104 {
		return "", fmt.Errorf("Codex local daemon socket 路径过长，请缩短 CODEX_HOME")
	}
	return path, nil
}

func LocalDaemonWebSocketDialer(socketPath string, timeout time.Duration) websocket.Dialer {
	if timeout <= 0 {
		timeout = localDaemonProbeTimeout
	}
	netDialer := &net.Dialer{Timeout: timeout}
	return websocket.Dialer{
		HandshakeTimeout: timeout,
		NetDialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return netDialer.DialContext(ctx, "unix", socketPath)
		},
	}
}

func LocalDaemonHandshakeURL() string {
	return localDaemonHandshakeURL
}

// EnsureLocalDaemon 复用 Codex 官方 daemon 生命周期。agentd 只负责确认 daemon
// 已运行并连接，不在退出时停止它；否则重启 Mimi 会把正在使用共享 daemon 的
// Codex Desktop 一并打断，违背共享服务的生命周期边界。
func EnsureLocalDaemon(ctx context.Context, options LocalDaemonOptions) (LocalDaemonStatus, error) {
	return ensureLocalDaemon(ctx, options, localDaemonHooks{
		probe: ProbeLocalDaemonInfo,
		start: startLocalDaemon,
		stat:  os.Stat,
	})
}

func ensureLocalDaemon(
	ctx context.Context,
	options LocalDaemonOptions,
	hooks localDaemonHooks,
) (LocalDaemonStatus, error) {
	socketPath, err := LocalDaemonSocketPath(options.Env)
	if err != nil {
		return LocalDaemonStatus{}, err
	}
	probeCtx, cancelProbe := context.WithTimeout(ctx, localDaemonProbeTimeout)
	probe, probeErr := hooks.probe(probeCtx, socketPath)
	cancelProbe()
	if probeErr == nil {
		return localDaemonStatus(socketPath, false, probe.Version, hooks.stat), nil
	}
	if err := validateExistingLocalDaemonSocket(socketPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		return LocalDaemonStatus{}, err
	}

	startCtx, cancelStart := context.WithTimeout(ctx, localDaemonStartTimeout)
	err = hooks.start(startCtx, options)
	cancelStart()
	if err != nil {
		return LocalDaemonStatus{}, err
	}

	deadline := time.Now().Add(localDaemonProbeTimeout)
	for {
		probeCtx, cancel := context.WithTimeout(ctx, localDaemonProbeTimeout)
		probe, probeErr = hooks.probe(probeCtx, socketPath)
		cancel()
		if probeErr == nil {
			return localDaemonStatus(socketPath, true, probe.Version, hooks.stat), nil
		}
		if ctx.Err() != nil {
			return LocalDaemonStatus{}, ctx.Err()
		}
		if time.Now().After(deadline) {
			return LocalDaemonStatus{}, fmt.Errorf("Codex local daemon 启动后未就绪：%w", probeErr)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func localDaemonStatus(
	socketPath string,
	started bool,
	version string,
	stat func(string) (os.FileInfo, error),
) LocalDaemonStatus {
	status := LocalDaemonStatus{SocketPath: socketPath, Started: started, Version: version}
	if started {
		if info, err := stat(socketPath); err == nil {
			status.StartedAt = info.ModTime().UTC()
		}
	}
	return status
}

func startLocalDaemon(ctx context.Context, options LocalDaemonOptions) error {
	bin := strings.TrimSpace(options.CodexBin)
	if bin == "" {
		bin = "codex"
	}
	cmd := exec.CommandContext(ctx, bin, "app-server", "daemon", "start")
	configureManagedCommand(cmd)
	cmd.Env = buildManagedEnv(options.Env)
	output, err := cmd.CombinedOutput()
	if err == nil {
		return nil
	}
	message := strings.TrimSpace(string(output))
	lower := strings.ToLower(message)
	if strings.Contains(lower, "managed standalone codex install not found") ||
		strings.Contains(lower, "requires the standalone install") {
		return fmt.Errorf("%w；请先使用 Codex 官方安装器安装命令行工具，再重启 Mimi Remote", ErrLocalDaemonStandaloneMissing)
	}
	if message == "" {
		return fmt.Errorf("启动 Codex local daemon 失败：%w", err)
	}
	return fmt.Errorf("启动 Codex local daemon 失败：%s", sanitizeDiagnostic(message))
}

// InspectLocalDaemonLifecycle 调用官方只读 version 子命令；不启动、不停止 daemon。
// managedCodexVersion 为空表示当前 socket 可能来自外部进程，虽然本次可共享，
// 但重启后缺少 daemon 自己管理的 standalone 恢复路径。
func InspectLocalDaemonLifecycle(
	ctx context.Context,
	options LocalDaemonOptions,
) (LocalDaemonLifecycleStatus, error) {
	bin := strings.TrimSpace(options.CodexBin)
	if bin == "" {
		bin = "codex"
	}
	cmd := exec.CommandContext(ctx, bin, "app-server", "daemon", "version")
	configureManagedCommand(cmd)
	cmd.Env = buildManagedEnv(options.Env)
	output, err := cmd.CombinedOutput()
	if err != nil {
		message := sanitizeDiagnostic(string(output))
		if message == "" {
			return LocalDaemonLifecycleStatus{}, fmt.Errorf("读取 Codex local daemon 状态失败：%w", err)
		}
		return LocalDaemonLifecycleStatus{}, fmt.Errorf("读取 Codex local daemon 状态失败：%s", message)
	}
	var status LocalDaemonLifecycleStatus
	if err := json.Unmarshal(output, &status); err != nil {
		return LocalDaemonLifecycleStatus{}, fmt.Errorf("解析 Codex local daemon 状态失败：%w", err)
	}
	if strings.TrimSpace(status.Status) == "" || strings.TrimSpace(status.SocketPath) == "" ||
		strings.TrimSpace(status.AppServerVersion) == "" {
		return LocalDaemonLifecycleStatus{}, fmt.Errorf("Codex local daemon 状态缺少必要字段")
	}
	return status, nil
}

// ValidateLocalDaemonLifecycle 确认当前可连接的 socket 也具备官方 daemon 的
// 冷启动恢复能力。只有 live probe 成功还不够：如果 standalone 已被删除，
// 本次登录看似可用，下一次 Mac 重启时 daemon start 会失败并让 agentd 重试。
func ValidateLocalDaemonLifecycle(status LocalDaemonLifecycleStatus, expectedSocket string) error {
	if !strings.EqualFold(strings.TrimSpace(status.Status), "running") {
		return fmt.Errorf("Codex local daemon 未处于 running 状态")
	}
	if strings.TrimSpace(status.SocketPath) == "" ||
		!sameCanonicalPath(status.SocketPath, expectedSocket) {
		return fmt.Errorf("Codex local daemon 使用了不同的 CODEX_HOME")
	}
	if !localDaemonVersionSupported(strings.TrimSpace(status.AppServerVersion)) {
		return fmt.Errorf("Codex local daemon 版本不兼容，需要 >= %s", minimumDesktopDaemonVersion)
	}
	if status.ManagedCodexVersion == nil || strings.TrimSpace(*status.ManagedCodexVersion) == "" {
		return fmt.Errorf("%w；当前 socket 可用，但 Mac 重启后无法由官方 daemon 恢复", ErrLocalDaemonStandaloneMissing)
	}
	managedPath := strings.TrimSpace(status.ManagedCodexPath)
	codexHome := filepath.Dir(filepath.Dir(filepath.Clean(expectedSocket)))
	expectedManagedPath := filepath.Join(codexHome, "packages", "standalone", "current", "codex")
	if managedPath == "" || !filepath.IsAbs(managedPath) || !sameCanonicalPath(managedPath, expectedManagedPath) {
		return fmt.Errorf("Codex daemon 使用了非官方 standalone 路径")
	}
	info, err := os.Stat(managedPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("%w；缺少 %s", ErrLocalDaemonStandaloneMissing, managedPath)
		}
		return fmt.Errorf("检查 Codex standalone 失败：%w", err)
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0o111 == 0 {
		return fmt.Errorf("%w；managed Codex 不是可执行的普通文件", ErrLocalDaemonStandaloneMissing)
	}
	return nil
}

// ValidateLocalDaemonProbeVersion 把当前 socket 的 initialize 结果与官方 daemon
// lifecycle 输出关联起来，避免把陈旧状态或另一个 CODEX_HOME 的控制命令误当成
// 当前正在提供服务的 daemon。
func ValidateLocalDaemonProbeVersion(status LocalDaemonLifecycleStatus, probedVersion string) error {
	live := strings.TrimSpace(probedVersion)
	reported := strings.TrimSpace(status.AppServerVersion)
	if live == "" || reported == "" || live != reported {
		return fmt.Errorf("Codex local daemon 实际版本与生命周期状态不一致")
	}
	return nil
}

// ProbeLocalDaemon 不只检查 socket 文件存在，还完成一次 WebSocket + initialize。
// 这样 stale socket、错误进程和协议不兼容都会在 agentd 接管前 fail closed。
func ProbeLocalDaemon(ctx context.Context, socketPath string) error {
	_, err := ProbeLocalDaemonInfo(ctx, socketPath)
	return err
}

func ProbeLocalDaemonInfo(ctx context.Context, socketPath string) (LocalDaemonProbe, error) {
	if err := validateExistingLocalDaemonSocket(socketPath); err != nil {
		return LocalDaemonProbe{}, err
	}
	dialer := LocalDaemonWebSocketDialer(socketPath, localDaemonProbeTimeout)
	conn, response, err := dialer.DialContext(ctx, localDaemonHandshakeURL, nil)
	if response != nil && response.Body != nil {
		_ = response.Body.Close()
	}
	if err != nil {
		return LocalDaemonProbe{}, err
	}
	defer conn.Close()
	if deadline, ok := ctx.Deadline(); ok {
		_ = conn.SetWriteDeadline(deadline)
		_ = conn.SetReadDeadline(deadline)
	}
	request := map[string]any{
		"id":     1,
		"method": "initialize",
		"params": map[string]any{
			"clientInfo": map[string]any{
				"name":    "mimi_remote_daemon_probe",
				"title":   "Mimi Remote Daemon Probe",
				"version": "1",
			},
			"capabilities": map[string]any{"experimentalApi": true},
		},
	}
	if err := conn.WriteJSON(request); err != nil {
		return LocalDaemonProbe{}, err
	}
	for {
		_, payload, err := conn.ReadMessage()
		if err != nil {
			return LocalDaemonProbe{}, err
		}
		var frame struct {
			ID     json.RawMessage `json:"id"`
			Result struct {
				UserAgent string `json:"userAgent"`
				CodexHome string `json:"codexHome"`
			} `json:"result"`
			Error json.RawMessage `json:"error"`
		}
		if err := json.Unmarshal(payload, &frame); err != nil || string(frame.ID) != "1" {
			continue
		}
		if len(frame.Error) > 0 && string(frame.Error) != "null" {
			return LocalDaemonProbe{}, fmt.Errorf("Codex local daemon initialize 被拒绝")
		}
		version, ok := localDaemonVersion(frame.Result.UserAgent)
		if !ok || !localDaemonVersionSupported(version) {
			return LocalDaemonProbe{}, fmt.Errorf("Codex local daemon 版本不兼容，需要 >= %s", minimumDesktopDaemonVersion)
		}
		expectedHome := filepath.Dir(filepath.Dir(socketPath))
		actualHome := strings.TrimSpace(frame.Result.CodexHome)
		if actualHome == "" || !sameCanonicalPath(expectedHome, actualHome) {
			return LocalDaemonProbe{}, fmt.Errorf("Codex local daemon 使用了不同的 CODEX_HOME")
		}
		// 遵循 app-server 正式握手：initialize 成功后发送 initialized，再主动关闭探针。
		_ = conn.WriteJSON(map[string]any{
			"method": "initialized",
			"params": map[string]any{},
		})
		return LocalDaemonProbe{Version: version, CodexHome: actualHome}, nil
	}
}

func localDaemonVersion(userAgent string) (string, bool) {
	match := localDaemonVersionPattern.FindStringSubmatch(strings.TrimSpace(userAgent))
	if len(match) != 2 {
		return "", false
	}
	return match[1], true
}

func localDaemonVersionSupported(version string) bool {
	left, leftPre, leftOK := daemonVersionParts(version)
	right, rightPre, rightOK := daemonVersionParts(minimumDesktopDaemonVersion)
	if !leftOK || !rightOK {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return left[index] > right[index]
		}
	}
	if leftPre == rightPre {
		return true
	}
	// 同一个 numeric 版本下，正式版高于预发布版。
	return rightPre || !leftPre
}

func daemonVersionParts(version string) ([3]int, bool, bool) {
	var result [3]int
	base, suffix, _ := strings.Cut(strings.TrimSpace(version), "-")
	parts := strings.Split(base, ".")
	if len(parts) != len(result) {
		return result, suffix != "", false
	}
	for index, part := range parts {
		value, err := strconv.Atoi(part)
		if err != nil || value < 0 {
			return result, suffix != "", false
		}
		result[index] = value
	}
	return result, suffix != "", true
}

func sameCanonicalPath(left string, right string) bool {
	canonical := func(path string) string {
		path = filepath.Clean(path)
		if resolved, err := filepath.EvalSymlinks(path); err == nil {
			return resolved
		}
		return path
	}
	return canonical(left) == canonical(right)
}

func validateExistingLocalDaemonSocket(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSocket == 0 {
		return fmt.Errorf("Codex local daemon 路径不是 Unix socket")
	}
	if runtime.GOOS != "windows" && info.Mode().Perm()&0o077 != 0 {
		return fmt.Errorf("Codex local daemon socket 权限过宽")
	}
	parent, err := os.Stat(filepath.Dir(path))
	if err != nil {
		return err
	}
	if !parent.IsDir() || (runtime.GOOS != "windows" && parent.Mode().Perm()&0o077 != 0) {
		return fmt.Errorf("Codex local daemon 目录必须仅当前用户可访问")
	}
	return nil
}
