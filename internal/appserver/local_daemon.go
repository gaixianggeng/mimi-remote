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
	CodexBin    string
	Env         map[string]string
	StableOwner bool
	// AttachOnly 用于用户或其他工具管理的 Unix backend。Mimi 只验证现有
	// socket，不启动、不安装 owner，也不改变它的生命周期。
	AttachOnly bool
}

type LocalDaemonStatus struct {
	SocketPath             string
	StartedAt              time.Time
	Started                bool
	Version                string
	OwnerInstalled         bool
	OwnerCreated           bool
	OwnerChanged           bool
	OwnerMigrationRequired bool
	OwnerRollback          *SharedDaemonOwnerRollback
	LifecycleValidated     bool
}

// SharedDaemonOwnerRollback 是配置提交前可使用的一次性回滚能力。令牌只驻留
// 当前进程内存，不序列化 plist 内容或其中可能存在的 MCP 环境变量。
type SharedDaemonOwnerRollback struct {
	rollbackUnlocked func(context.Context) error
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
	Status string `json:"status"`
	// Backend/PID 由新版官方 daemon version 在自身持有 pid backend 时返回。
	// 旧的 SSH 直启 socket 没有这两个字段，必须走显式、严格校验的接管流程。
	Backend             *string `json:"backend,omitempty"`
	PID                 *uint32 `json:"pid,omitempty"`
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
	if options.AttachOnly {
		return attachLocalDaemon(ctx, options)
	}
	if !options.StableOwner {
		return ensureLocalDaemon(ctx, options, localDaemonHooks{
			probe: ProbeLocalDaemonInfo,
			start: startLocalDaemon,
			stat:  os.Stat,
		})
	}
	return withSharedDaemonOperationLock(ctx, func() (LocalDaemonStatus, error) {
		return ensureLocalDaemonWithStableOwner(ctx, options)
	})
}

func ensureLocalDaemonWithStableOwner(
	ctx context.Context,
	options LocalDaemonOptions,
) (LocalDaemonStatus, error) {
	// 先判断 socket 是否已经由旧链路拉起。只有“owner 本次发生变化，且 daemon
	// 早已存在”时才需要一次显式迁移；全新冷启动由 launchd 直接创建，不应误报。
	socketPath, pathErr := LocalDaemonSocketPath(options.Env)
	if pathErr != nil {
		return LocalDaemonStatus{}, pathErr
	}
	probeCtx, cancelProbe := context.WithTimeout(ctx, localDaemonProbeTimeout)
	_, preexistingErr := ProbeLocalDaemonInfo(probeCtx, socketPath)
	cancelProbe()
	// 完整协议探测可能因为旧 daemon 正忙而超时；只要 Unix socket 仍真实监听，
	// 就必须按“已有 daemon”保守处理并留下显式迁移标记。否则一次瞬时超时会把
	// 旧责任链误判成全新冷启动，静默跳过用户确认。
	daemonPreexisting := localDaemonWasPreexisting(
		preexistingErr,
		sharedDaemonSocketAcceptsConnectionMust(options),
	)

	owner, err := EnsureSharedDaemonOwner(ctx, options, daemonPreexisting)
	if err != nil {
		return LocalDaemonStatus{}, err
	}
	startedByStableOwner := false
	status, err := ensureLocalDaemon(ctx, options, localDaemonHooks{
		probe: ProbeLocalDaemonInfo,
		start: func(startCtx context.Context, startOptions LocalDaemonOptions) error {
			var startErr error
			startedByStableOwner, startErr = startLocalDaemonWithStableOwnerTracked(startCtx, startOptions)
			return startErr
		},
		stat: os.Stat,
	})
	if err != nil {
		if rollbackErr := rollbackSharedDaemonOwnerChangeUnlocked(context.Background(), owner.Rollback); rollbackErr != nil {
			return LocalDaemonStatus{}, fmt.Errorf("%w；恢复原 daemon owner 也失败：%v", err, rollbackErr)
		}
		return LocalDaemonStatus{}, err
	}
	lifecycle, err := InspectLocalDaemonLifecycle(ctx, options)
	if err == nil {
		err = reconcileStableOwnerLifecycle(
			lifecycle,
			status,
			&owner,
			startedByStableOwner,
			markSharedDaemonMigrationRequired,
		)
	}
	if err != nil {
		if rollbackErr := rollbackSharedDaemonOwnerChangeUnlocked(context.Background(), owner.Rollback); rollbackErr != nil {
			return LocalDaemonStatus{}, fmt.Errorf("%w；恢复原 daemon owner 也失败：%v", err, rollbackErr)
		}
		return LocalDaemonStatus{}, err
	}
	// owner 已经稳定安装、旧 marker 仍存在且本次确实由稳定启动链创建了
	// daemon 时，完整握手/生命周期/版本校验就是可清理 marker 的充分证据。
	// owner 本次也发生变化时仍保留 marker，避免破坏配置事务的回滚令牌。
	if err := finalizeRecoveredSharedDaemonMigration(&status, &owner, startedByStableOwner); err != nil {
		return LocalDaemonStatus{}, err
	}
	status.OwnerInstalled = owner.Installed
	status.OwnerCreated = owner.Created
	status.OwnerChanged = owner.Changed
	status.OwnerMigrationRequired = owner.MigrationRequired
	status.OwnerRollback = owner.Rollback
	status.LifecycleValidated = true
	return status, nil
}

// reconcileStableOwnerLifecycle 区分“当前可连接”与“已由稳定 owner
// 管理”。已安装的 LaunchAgent 不代表它一定赢得了本次 socket
// 竞争：Codex 原生 SSH bootstrap 仍可能先启动直接 listener。这时
// agentd 应保持 attach 与移动端可用，同时重建待迁移标记；绝不在
// 日常启动路径终止该进程。
func reconcileStableOwnerLifecycle(
	lifecycle LocalDaemonLifecycleStatus,
	status LocalDaemonStatus,
	owner *SharedDaemonOwnerStatus,
	startedByStableOwner bool,
	markMigrationRequired func() error,
) error {
	if err := ValidateLocalDaemonLifecycle(lifecycle, status.SocketPath); err != nil {
		return err
	}
	if err := ValidateLocalDaemonProbeVersion(lifecycle, status.Version); err != nil {
		return err
	}

	// 任何已声明的 backend 都必须是官方 pid。未知的未来 backend
	// 不能借旧 marker 绕过校验。
	if lifecycle.Backend != nil {
		return ValidateManagedLocalDaemonLifecycle(lifecycle, status.SocketPath)
	}
	// 本次明确执行了稳定 owner kickstart，却仍看不到 backend，说明
	// 启动结果不能归因给该 owner，必须 fail closed。
	if startedByStableOwner {
		return ValidateManagedLocalDaemonLifecycle(lifecycle, status.SocketPath)
	}
	if owner == nil || !owner.Installed || !owner.Loaded || !owner.Secure {
		return fmt.Errorf("非 daemon 管理的 Codex app-server 缺少安全稳定 owner")
	}
	if owner.MigrationRequired {
		return nil
	}
	if markMigrationRequired == nil {
		return fmt.Errorf("检测到非 daemon 管理的 Codex app-server，但无法记录待迁移状态")
	}
	if err := markMigrationRequired(); err != nil {
		return fmt.Errorf("检测到非 daemon 管理的 Codex app-server，但记录待迁移状态失败：%w", err)
	}
	owner.MigrationRequired = true
	return nil
}

func localDaemonWasPreexisting(probeErr error, socketAcceptsConnection bool) bool {
	return probeErr == nil || socketAcceptsConnection
}

func finalizeRecoveredSharedDaemonMigration(
	status *LocalDaemonStatus,
	owner *SharedDaemonOwnerStatus,
	startedByStableOwner bool,
) error {
	if status == nil || owner == nil || !status.Started || !startedByStableOwner ||
		!owner.MigrationRequired || owner.Changed {
		return nil
	}
	if err := clearSharedDaemonMigrationFlag(); err != nil {
		return fmt.Errorf("共享 daemon 已恢复，但清除旧迁移状态失败：%w", err)
	}
	owner.MigrationRequired = false
	return nil
}

func rollbackSharedDaemonOwnerChangeUnlocked(
	ctx context.Context,
	rollback *SharedDaemonOwnerRollback,
) error {
	if rollback == nil || rollback.rollbackUnlocked == nil {
		return nil
	}
	return rollback.rollbackUnlocked(ctx)
}

func attachLocalDaemon(ctx context.Context, options LocalDaemonOptions) (LocalDaemonStatus, error) {
	socketPath, err := LocalDaemonSocketPath(options.Env)
	if err != nil {
		return LocalDaemonStatus{}, err
	}
	probeCtx, cancel := context.WithTimeout(ctx, localDaemonProbeTimeout)
	probe, err := ProbeLocalDaemonInfo(probeCtx, socketPath)
	cancel()
	if err != nil {
		return LocalDaemonStatus{}, fmt.Errorf(
			"外部管理的 Codex Unix backend 未就绪；Mimi 不会启动或接管它：%w",
			err,
		)
	}
	return localDaemonStatus(socketPath, false, probe.Version, os.Stat), nil
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

	startTimeout := localDaemonStartTimeout
	if options.StableOwner && sharedDaemonStartTimeoutForLocalEnsure > startTimeout {
		startTimeout = sharedDaemonStartTimeoutForLocalEnsure
	}
	startCtx, cancelStart := context.WithTimeout(ctx, startTimeout)
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

// startLocalDaemon 不再由 agentd 直接创建 daemon 进程。macOS 的 TCC responsible
// process 在进程创建时从父进程继承：agentd 一旦成为共享 daemon 的父进程，Desktop
// 后续经由该 daemon 发起的文件访问就会被归因到 Mimi，且 Mimi 升级或移动后还会留下
// 指向旧 App 路径的 stale responsibility（MIM-157）。因此启动动作交给平台上稳定的
// 服务管理器；非 macOS 平台没有 TCC，继续沿用直接 exec。
func startLocalDaemon(ctx context.Context, options LocalDaemonOptions) error {
	if options.StableOwner {
		return startLocalDaemonWithStableOwner(ctx, options)
	}
	return startLocalDaemonDirect(ctx, options)
}

func startLocalDaemonDirect(ctx context.Context, options LocalDaemonOptions) error {
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

// ValidateManagedLocalDaemonLifecycle 在通用冷启动校验上进一步证明当前 socket
// 已由官方 pid backend 管理。旧 SSH 直启进程的 version 输出没有 backend；它只
// 能在 migration marker 存在时短暂 attach，不能被当成稳定迁移已经完成。
func ValidateManagedLocalDaemonLifecycle(
	status LocalDaemonLifecycleStatus,
	expectedSocket string,
) error {
	if err := ValidateLocalDaemonLifecycle(status, expectedSocket); err != nil {
		return err
	}
	if status.Backend == nil || !strings.EqualFold(strings.TrimSpace(*status.Backend), "pid") {
		return fmt.Errorf("Codex app-server 尚未由官方 pid daemon 管理")
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
