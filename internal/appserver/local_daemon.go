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

var (
	ErrLocalDaemonStandaloneMissing = errors.New("Codex standalone 安装缺失")
	// ErrSharedDaemonMigrationPending 表示稳定 owner 已进入人工迁移状态。
	// 日常启动、gateway recovery 和登录恢复都必须保留该状态，不能把一次
	// 显式迁移失败悄悄变成后台重试。
	ErrSharedDaemonMigrationPending = errors.New("Codex 共享 daemon 正在等待用户再次确认迁移")
)

type LocalDaemonOptions struct {
	CodexBin    string
	Env         map[string]string
	StableOwner bool
	// ValidateStableOwner 在 shared-daemon 跨进程锁内复核调用方仍拥有恢复权。
	// 旧 agentd Router 会在这里重新读取磁盘配置，避免禁用完成后用启动时的
	// 旧配置重新安装 plist。nil 表示调用方不是长期缓存配置的恢复任务。
	ValidateStableOwner func() error
	// RollbackOwnerOnFailure 只供“尚未提交配置”的同步设置事务使用。
	// agentd 启动、gateway recovery 等日常路径必须保持 false：一旦 owner
	// 已进入 pending/manual 状态，瞬时 socket 或 lifecycle 错误也不能把它
	// 回滚成 RunAtLoad=true，绕过下一次用户确认。
	RollbackOwnerOnFailure bool
	// PrepareOwnerForConfigCommit 只供“从非共享配置切换到 shared unix”的
	// 两阶段事务使用。准备阶段始终把 owner 落成 RunAtLoad=false，并只允许
	// 在确认没有旧 daemon 时显式启动一次；配置提交后仍等待用户确认，绝不
	// 通过冷启动结果自动提升为登录自启。
	PrepareOwnerForConfigCommit bool
	// AttachOnly 用于用户或其他工具管理的 Unix backend。Mimi 只验证现有
	// socket，不启动、不安装 owner，也不改变它的生命周期。
	AttachOnly bool
}

type LocalDaemonStatus struct {
	SocketPath string
	StartedAt  time.Time
	Started    bool
	// StartedByStableOwner 只有本次确实由 stable owner 执行 kickstart 时为 true。
	// 通用 Started 也会在 start hook 期间外部 listener 抢先出现时为 true，不能
	// 用它作为清除 migration marker 或提升 RunAtLoad 的归因证据。
	StartedByStableOwner bool
	// DaemonPreexisting 记录两阶段启用准备前已有 listener；此状态必须保持
	// manual marker 等用户确认，不能在配置提交后自动 kickstart/提升。
	DaemonPreexisting bool
	// ConfigCommitted 表示两阶段 enable 的配置 rename 已完成。提交后的启动/
	// 握手失败不能再作为普通 error 丢给上层，否则 Mac App 不会 reload，也看不到
	// durable manual marker；setup 需要把它转换成可恢复的 pending 成功结果。
	ConfigCommitted        bool
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
	if err := validateStableOwnerLease(options); err != nil {
		return LocalDaemonStatus{}, err
	}
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
	prepared, preparedErr := sharedDaemonEnablePrepared()
	if preparedErr != nil {
		return LocalDaemonStatus{}, preparedErr
	}

	bootstrapLogOffset := sharedDaemonLaunchAgentLogSize()
	owner, err := ensureSharedDaemonOwner(
		ctx,
		options,
		daemonPreexisting,
		options.PrepareOwnerForConfigCommit || prepared,
	)
	if err != nil {
		return LocalDaemonStatus{}, err
	}
	// RunAtLoad=true 的新/重载 owner 已由 bootstrap 异步触发 supervisor。launchd
	// 状态与 socket 建立之间仍有短窗口，不能再 kickstart 第二套 supervisor；
	// 这里记住第一次 ensure 的启动事实并只等待。
	ownerBootstrapped := owner.Changed && owner.RunAtLoad && !daemonPreexisting
	if owner.MigrationRequired && !sharedDaemonSocketAcceptsConnectionMust(options) {
		if prepared && options.ValidateStableOwner != nil && !options.PrepareOwnerForConfigCommit {
			// 上一次 fresh enable 可能在“shared 配置已 rename、manual owner 已
			// 落盘”后掉电。锁内恢复权复核已经证明磁盘仍是同一 shared 身份，
			// 因此可继续提交后启动；WS 配置或旧快照不会进入这里。
			return startPreparedSharedDaemonAfterConfigCommit(ctx, options)
		}
		if options.PrepareOwnerForConfigCommit && !daemonPreexisting {
			// 两阶段启用的 owner 此时故意是 manual。没有旧 listener 时允许
			// 由这个已加载 job 启动一次做冷启动验证；它仍不会在登录时自启。
		} else {
			// pending 时磁盘 plist 为 RunAtLoad=false。socket 已不可连只能等待用户
			// 再次显式确认，不能让普通 ensure 走到 kickstart，也不能把刚落盘的
			// manual owner/marker 回滚成可自动启动状态。
			return LocalDaemonStatus{}, stableOwnerEnsureFailure(options, owner, ErrSharedDaemonMigrationPending)
		}
	}
	startedByStableOwner := false
	status, err := ensureLocalDaemon(ctx, options, localDaemonHooks{
		probe: ProbeLocalDaemonInfo,
		start: func(startCtx context.Context, startOptions LocalDaemonOptions) error {
			if ownerBootstrapped {
				startedByStableOwner = true
				return waitForSharedDaemonSocket(startCtx, startOptions, bootstrapLogOffset)
			}
			var startErr error
			if startOptions.PrepareOwnerForConfigCommit {
				startedByStableOwner, startErr = startPreparedSharedDaemonWithStableOwnerTracked(startCtx, startOptions)
			} else {
				startedByStableOwner, startErr = startLocalDaemonWithStableOwnerTracked(startCtx, startOptions)
			}
			return startErr
		},
		stat: os.Stat,
	})
	if err != nil {
		return LocalDaemonStatus{}, stableOwnerEnsureFailure(options, owner, err)
	}
	lifecycle, err := InspectLocalDaemonLifecycle(ctx, options)
	signedSupervisorValidated := false
	if err == nil {
		signedRuntimeErr := sharedDaemonValidateSignedRuntime(ctx, options, status.SocketPath)
		signedSupervisorValidated = signedRuntimeErr == nil
		err = reconcileStableOwnerLifecycleWithSignedRuntime(
			lifecycle,
			status,
			&owner,
			startedByStableOwner,
			signedSupervisorValidated,
			func() error {
				// 现有 SSH bootstrap 重新抢到 socket 时，不只写 marker；还要把
				// 登录启动持久化为 manual，保证下次登录不会绕过用户确认。
				updated, ensureErr := ensureSharedDaemonOwner(ctx, options, true, true)
				if ensureErr == nil {
					owner = updated
				}
				return ensureErr
			},
		)
	}
	if err != nil {
		return LocalDaemonStatus{}, stableOwnerEnsureFailure(options, owner, err)
	}
	status.OwnerInstalled = owner.Installed
	status.OwnerCreated = owner.Created
	status.OwnerChanged = owner.Changed
	status.OwnerMigrationRequired = owner.MigrationRequired
	status.OwnerRollback = owner.Rollback
	status.StartedByStableOwner = startedByStableOwner
	status.LifecycleValidated = true
	if prepared && (lifecycle.Backend != nil || signedSupervisorValidated) {
		// 上次进程可能在 manual kickstart 已成功、但 post-commit helper 尚未
		// 消费 intent 时崩溃。本次普通 Ensure 已在同一 operation lock 内完成
		// managed lifecycle + probe 校验，必须在返回前消费这份“一次性恢复权”；
		// marker/manual 继续保留，daemon 再掉线只能等用户重新确认。
		if clearErr := clearSharedDaemonEnablePrepared(); clearErr != nil {
			return LocalDaemonStatus{}, clearErr
		}
	}
	return status, nil
}

func validateStableOwnerLease(options LocalDaemonOptions) error {
	if options.ValidateStableOwner == nil {
		return nil
	}
	if err := options.ValidateStableOwner(); err != nil {
		return fmt.Errorf("共享 daemon 恢复权已失效：%w", err)
	}
	return nil
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
	return reconcileStableOwnerLifecycleWithSignedRuntime(
		lifecycle,
		status,
		owner,
		startedByStableOwner,
		false,
		markMigrationRequired,
	)
}

func reconcileStableOwnerLifecycleWithSignedRuntime(
	lifecycle LocalDaemonLifecycleStatus,
	status LocalDaemonStatus,
	owner *SharedDaemonOwnerStatus,
	startedByStableOwner bool,
	signedSupervisorValidated bool,
	markMigrationRequired func() error,
) error {
	if err := ValidateLocalDaemonLifecycle(lifecycle, status.SocketPath); err != nil {
		return err
	}
	if err := ValidateLocalDaemonProbeVersion(lifecycle, status.Version); err != nil {
		return err
	}
	// foreground app-server 不使用官方 pid backend。只有从真实 socket peer 反查
	// 到 listener -> OpenAI node supervisor 的完整父链后，才把 Backend=nil 认作
	// Mimi 的稳定 owner；单凭 plist 或本次 kickstart 都不够。
	if signedSupervisorValidated {
		return nil
	}
	// 任何已声明的 backend 都必须先通过官方 pid 校验。它仍属于旧 runtime：
	// Browser 需要的签名 node 父链并不存在，所以日常路径只保持 attach 并恢复
	// pending，不能把“官方 daemon”误当成新的 stable supervisor。
	if lifecycle.Backend != nil {
		if err := ValidateManagedLocalDaemonLifecycle(lifecycle, status.SocketPath); err != nil {
			return err
		}
		if startedByStableOwner {
			return fmt.Errorf("稳定 owner 启动后得到旧 pid backend，签名 supervisor 未生效")
		}
		return reconcileSharedDaemonMigrationMarker(owner, markMigrationRequired)
	}
	// 本次明确执行了稳定 owner kickstart，却仍看不到 backend，说明
	// 启动结果不能归因给该 owner，必须 fail closed。
	if startedByStableOwner {
		return ValidateManagedLocalDaemonLifecycle(lifecycle, status.SocketPath)
	}
	return reconcileSharedDaemonMigrationMarker(owner, markMigrationRequired)
}

func reconcileSharedDaemonMigrationMarker(
	owner *SharedDaemonOwnerStatus,
	markMigrationRequired func() error,
) error {
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

func stableOwnerEnsureFailure(
	options LocalDaemonOptions,
	owner SharedDaemonOwnerStatus,
	cause error,
) error {
	if !options.RollbackOwnerOnFailure {
		return cause
	}
	if rollbackErr := rollbackSharedDaemonOwnerChangeUnlocked(context.Background(), owner.Rollback); rollbackErr != nil {
		return fmt.Errorf("%w；恢复原 daemon owner 也失败：%v", cause, rollbackErr)
	}
	return cause
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

// CommitSharedDaemonEnable 把 manual owner 准备、daemon 冷启动验证和配置提交
// 放进同一把跨进程锁。配置提交前后磁盘 owner 都保持
// RunAtLoad=false；进程在任意准备步骤退出都不会让非共享配置留下自动启动入口。
func CommitSharedDaemonEnable(
	ctx context.Context,
	options LocalDaemonOptions,
	validate func() error,
	commit func() error,
) (LocalDaemonStatus, error) {
	options.StableOwner = true
	options.PrepareOwnerForConfigCommit = true
	options.RollbackOwnerOnFailure = false
	return withSharedDaemonOperationLock(ctx, func() (LocalDaemonStatus, error) {
		if validate == nil {
			return LocalDaemonStatus{}, fmt.Errorf("提交共享配置前的复核回调不能为空")
		}
		if err := validate(); err != nil {
			return LocalDaemonStatus{}, fmt.Errorf("共享配置快照已变化：%w", err)
		}
		if commit == nil {
			return LocalDaemonStatus{}, fmt.Errorf("提交共享配置的回调不能为空")
		}

		status, err := prepareSharedDaemonOwnerForConfigCommit(ctx, options)
		if err != nil {
			// 此时磁盘配置仍是非共享；失败清理必须收敛到“无 Mimi owner”，
			// 不能恢复一个历史 RunAtLoad=true 残留。
			if cleanupErr := removeSharedDaemonOwnerUnlocked(context.Background()); cleanupErr != nil {
				return LocalDaemonStatus{}, fmt.Errorf("%w；清理未提交的共享 daemon owner 也失败：%v", err, cleanupErr)
			}
			return LocalDaemonStatus{}, err
		}
		if !status.DaemonPreexisting {
			if err := markSharedDaemonEnablePrepared(); err != nil {
				if cleanupErr := removeSharedDaemonOwnerUnlocked(context.Background()); cleanupErr != nil {
					return LocalDaemonStatus{}, fmt.Errorf("%w；清理未提交的共享 daemon owner 也失败：%v", err, cleanupErr)
				}
				return LocalDaemonStatus{}, err
			}
		}
		if err := commit(); err != nil {
			if cleanupErr := removeSharedDaemonOwnerUnlocked(context.Background()); cleanupErr != nil {
				return LocalDaemonStatus{}, fmt.Errorf("%w；清理未提交的共享 daemon owner 也失败：%v", err, cleanupErr)
			}
			return LocalDaemonStatus{}, err
		}
		status.ConfigCommitted = true

		// 此刻配置已经是 shared，硬崩溃只会留下 shared+manual owner；日常
		// Ensure 会保持 pending，不会回退到独立 WS。没有旧 listener 时才由
		// prepared owner 显式启动并完整握手，但仍保持 manual+marker；已有
		// listener 同样等待用户确认。只有 Desktop 正常退出后的显式迁移入口
		// 才能提升 auto，避免把启动窗口内抢占 socket 的进程误归因给 owner。
		if !status.DaemonPreexisting {
			started, startErr := startPreparedSharedDaemonAfterConfigCommit(ctx, options)
			if startErr != nil {
				status.OwnerMigrationRequired = true
				return status, fmt.Errorf("共享配置已提交，但 Codex daemon 启动失败：%w", startErr)
			}
			status = started
			status.ConfigCommitted = true
		}
		status.OwnerRollback = nil
		return status, nil
	})
}

func prepareSharedDaemonOwnerForConfigCommit(
	ctx context.Context,
	options LocalDaemonOptions,
) (LocalDaemonStatus, error) {
	if err := validateStableOwnerLease(options); err != nil {
		return LocalDaemonStatus{}, err
	}
	socketPath, err := LocalDaemonSocketPath(options.Env)
	if err != nil {
		return LocalDaemonStatus{}, err
	}
	probeCtx, cancel := context.WithTimeout(ctx, localDaemonProbeTimeout)
	probe, probeErr := ProbeLocalDaemonInfo(probeCtx, socketPath)
	cancel()
	preexisting := localDaemonWasPreexisting(
		probeErr,
		sharedDaemonSocketAcceptsConnectionMust(options),
	)
	if preexisting && probeErr != nil {
		// 仅能建立 Unix 连接不等于可共享。旧 daemon 忙死、协议不兼容或伪造
		// listener 都必须在配置提交前失败；否则会把 WS 配置切到一个 reload
		// 后无法 initialize 的 backend。
		return LocalDaemonStatus{}, fmt.Errorf("Codex daemon socket 已存在但完整握手失败：%w", probeErr)
	}
	owner, err := ensureSharedDaemonOwner(ctx, options, preexisting, true)
	if err != nil {
		return LocalDaemonStatus{}, err
	}
	lifecycle, err := InspectLocalDaemonLifecycle(ctx, options)
	if err != nil {
		return LocalDaemonStatus{}, fmt.Errorf("确认 Codex daemon 冷启动能力失败：%w", err)
	}
	if err := ValidateLocalDaemonStandaloneCapability(lifecycle, socketPath); err != nil {
		return LocalDaemonStatus{}, err
	}
	status := LocalDaemonStatus{
		SocketPath:             socketPath,
		OwnerInstalled:         owner.Installed,
		OwnerCreated:           owner.Created,
		OwnerChanged:           owner.Changed,
		OwnerMigrationRequired: owner.MigrationRequired,
		OwnerRollback:          owner.Rollback,
		DaemonPreexisting:      preexisting,
	}
	if probeErr == nil {
		status.Version = probe.Version
		if err := ValidateLocalDaemonLifecycle(lifecycle, socketPath); err != nil {
			return LocalDaemonStatus{}, err
		}
		if err := ValidateLocalDaemonProbeVersion(lifecycle, probe.Version); err != nil {
			return LocalDaemonStatus{}, err
		}
		status.LifecycleValidated = true
	}
	return status, nil
}

func commitConfigWithSharedDaemonLock(
	ctx context.Context,
	removeOwner func(context.Context) error,
	validate func() error,
	commit func() error,
) error {
	_, err := withSharedDaemonOperationLock(ctx, func() (LocalDaemonStatus, error) {
		if validate == nil {
			return LocalDaemonStatus{}, fmt.Errorf("提交配置前的复核回调不能为空")
		}
		if err := validate(); err != nil {
			return LocalDaemonStatus{}, fmt.Errorf("配置快照已变化：%w", err)
		}
		if commit == nil {
			return LocalDaemonStatus{}, fmt.Errorf("配置提交回调不能为空")
		}
		if removeOwner != nil {
			if err := removeOwner(ctx); err != nil {
				return LocalDaemonStatus{}, err
			}
		}
		if err := commit(); err != nil {
			// commit 里的最后一次 CAS 可能因为不遵守 Mimi 锁的外部编辑器
			// 已经写成 WS 而失败。此时恢复旧 auto owner 会制造“WS + 登录自启
			// Unix daemon”的危险组合；shared+无 owner 与 WS+无 owner 都是可恢复
			// 的 fail-closed 状态，因此提交失败后统一保持 owner 已移除。
			return LocalDaemonStatus{}, err
		}
		return LocalDaemonStatus{}, nil
	})
	return err
}

// CommitConfigWithSharedDaemonLock 供 setup --force 这类通用配置写入者使用。
// 它不假定当前配置拥有 Mimi 的 stable owner，只负责与 enable/disable/recovery
// 共用同一把锁，避免在 shared 配置已经提交、owner 尚未提升的窗口插入写入。
func CommitConfigWithSharedDaemonLock(
	ctx context.Context,
	validate func() error,
	commit func() error,
) error {
	return commitConfigWithSharedDaemonLock(ctx, nil, validate, commit)
}

// CommitConfigReplacingSharedDaemon 供 setup --force 使用。setup 的结果不带
// Mimi shared_fallback，因此只要磁盘仍有 Mimi plist/marker/enable intent，就必须
// 在同一 operation lock 内先移除未来启动入口；没有任何 artifact 时不查询
// launchctl，避免把测试 Home 或从未启用共享的机器误判成残缺 job。
func CommitConfigReplacingSharedDaemon(
	ctx context.Context,
	validate func() error,
	commit func() error,
) error {
	removeIfPresent := func(removeCtx context.Context) error {
		present, err := SharedDaemonOwnerArtifactsPresent()
		if err != nil {
			return err
		}
		if !present {
			return nil
		}
		_, err = removeSharedDaemonOwnerForTransactionUnlocked(removeCtx)
		return err
	}
	return commitConfigWithSharedDaemonLock(ctx, removeIfPresent, validate, commit)
}

// CommitConfigRepairingSharedDaemonIdentity 供 Doctor 更新 codex.bin 使用。
// auto owner 可以移除后由新 agentd 按新身份重建；manual/marker/enable intent
// 则代表用户尚未确认迁移，必须原样保留。这样 Repair 不会把 pending 擦掉，
// 也不会让下一次普通 Ensure 把 owner 误升为 RunAtLoad=true。
func CommitConfigRepairingSharedDaemonIdentity(
	ctx context.Context,
	validate func() error,
	commit func() error,
) error {
	removeUnlessPending := func(removeCtx context.Context) error {
		owner, err := InspectSharedDaemonOwner(removeCtx)
		if err != nil {
			return err
		}
		prepared, err := sharedDaemonEnablePrepared()
		if err != nil {
			return err
		}
		if owner.MigrationRequired || (owner.Installed && !owner.RunAtLoad) || prepared {
			return nil
		}
		present, err := SharedDaemonOwnerArtifactsPresent()
		if err != nil {
			return err
		}
		if !present {
			return nil
		}
		_, err = removeSharedDaemonOwnerForTransactionUnlocked(removeCtx)
		return err
	}
	return commitConfigWithSharedDaemonLock(ctx, removeUnlessPending, validate, commit)
}

// CommitSharedDaemonDisable 先移除 owner，再提交非共享配置。崩溃在
// 两步之间只会留下“shared 配置 + 无 owner”，下次正常 shared 启动可自动修复；
// 绝不会出现“WS 配置 + RunAtLoad=true owner”的危险方向。
func CommitSharedDaemonDisable(
	ctx context.Context,
	validate func() error,
	commit func() error,
) error {
	removeOwner := func(removeCtx context.Context) error {
		_, err := removeSharedDaemonOwnerForTransactionUnlocked(removeCtx)
		return err
	}
	return commitConfigWithSharedDaemonLock(ctx, removeOwner, validate, commit)
}

// ReconcileDisabledSharedDaemonOwner 供非 shared 的 agentd 启动路径清理上次
// 两阶段启用在进程退出后留下的 manual owner。复核与清理同锁执行，不能误删
// 已由另一个进程成功提交的新 shared owner。
func ReconcileDisabledSharedDaemonOwner(ctx context.Context, validate func() error) error {
	return CommitSharedDaemonDisable(ctx, validate, func() error { return nil })
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
	return ValidateLocalDaemonStandaloneCapability(status, expectedSocket)
}

// ValidateLocalDaemonStandaloneCapability 只验证官方 daemon 的冷启动材料，
// 不要求 socket 当前已经 running。fresh enable 在配置仍是 WS 时必须先做这个
// 只读检查，再提交 shared 配置；绝不能为了验证而提前 kickstart 第二个 backend。
func ValidateLocalDaemonStandaloneCapability(status LocalDaemonLifecycleStatus, expectedSocket string) error {
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
