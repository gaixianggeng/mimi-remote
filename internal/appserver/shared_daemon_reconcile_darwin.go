//go:build darwin

package appserver

import (
	"context"
	"fmt"
	"os"
	"strings"
	"time"
)

const (
	confirmedSharedDaemonDisableLockWaitTimeout  = 15 * time.Second
	confirmedSharedDaemonDisableOperationTimeout = 90 * time.Second
)

// RemoveSharedDaemonOwner 只移除 Mimi 安装的未来启动入口和迁移标记，不停止当前
// daemon；关闭共享时 Desktop 可能仍在完成退出，直接 stop 会破坏原生流程。
func RemoveSharedDaemonOwner(ctx context.Context) error {
	_, err := withSharedDaemonOperationLock(ctx, func() (LocalDaemonStatus, error) {
		return LocalDaemonStatus{}, removeSharedDaemonOwnerUnlocked(ctx)
	})
	return err
}

func disableSharedDaemonAfterDesktopExit(
	ctx context.Context,
	options LocalDaemonOptions,
	validate func() error,
	commit func() error,
) error {
	_, err := withConfirmedSharedDaemonDisableLock(
		ctx,
		confirmedSharedDaemonDisableLockWaitTimeout,
		confirmedSharedDaemonDisableOperationTimeout,
		func(operationCtx context.Context) (LocalDaemonStatus, error) {
			return disableSharedDaemonAfterDesktopExitUnlocked(
				operationCtx,
				options,
				validate,
				commit,
			)
		},
	)
	return err
}

// confirmed disable 先等待跨进程锁，再为真正的关闭事务创建新预算。两段若
// 共用同一个 deadline，锁竞争会吃掉官方 daemon graceful drain 的时间。
func withConfirmedSharedDaemonDisableLock(
	ctx context.Context,
	lockWaitTimeout time.Duration,
	operationTimeout time.Duration,
	operation func(context.Context) (LocalDaemonStatus, error),
) (LocalDaemonStatus, error) {
	lockCtx, cancelLockWait := context.WithTimeout(ctx, lockWaitTimeout)
	defer cancelLockWait()
	return withSharedDaemonOperationLock(lockCtx, func() (LocalDaemonStatus, error) {
		operationCtx, cancelOperation := context.WithTimeout(ctx, operationTimeout)
		defer cancelOperation()
		return operation(operationCtx)
	})
}

type confirmedSharedDaemonDisableHooks struct {
	requireDesktopStopped func(context.Context, string) error
	// desktopRunning 只供独立模式启动复核使用：它需要区分“Desktop 在跑”和
	// “探测失败”，前者是正常的等待态，后者必须 fail closed。
	desktopRunning func(context.Context) (bool, error)
	// validateListenerOwnership 证明当前 listener 确实由 Mimi 的签名 node
	// supervisor 启动。独立模式启动复核用它区分 Mimi daemon 与外部 app-server。
	validateListenerOwnership func(context.Context, LocalDaemonOptions, string) error
	inspectOwner              func(context.Context) (SharedDaemonOwnerStatus, error)
	socketAccepts             func(string) bool
	stageOwner                func(SharedDaemonOwnerStatus) error
	inspectListener           func(context.Context, string) (sharedDaemonListenerProcess, error)
	stopDaemon                func(context.Context, LocalDaemonOptions, SharedDaemonOwnerStatus) error
	waitForStopped            func(context.Context, string, ...sharedDaemonListenerProcess) error
	launchctl                 func(context.Context, ...string) (string, error)
	removeLaunchAgent         func(context.Context) error
	clearEnablePrepared       func() error
	clearMigration            func() error
	enablePrepared            func() (bool, error)
}

func defaultConfirmedSharedDaemonDisableHooks() confirmedSharedDaemonDisableHooks {
	return confirmedSharedDaemonDisableHooks{
		requireDesktopStopped: requireCodexDesktopStopped,
		desktopRunning:        sharedDaemonDesktopRunning,
		validateListenerOwnership: func(ctx context.Context, options LocalDaemonOptions, socketPath string) error {
			return sharedDaemonValidateSignedRuntime(ctx, options, socketPath)
		},
		inspectOwner:        InspectSharedDaemonOwner,
		socketAccepts:       sharedDaemonSocketAcceptsConnection,
		stageOwner:          stageSharedDaemonOwnerForConfirmedDisable,
		inspectListener:     inspectSharedDaemonListenerProcess,
		stopDaemon:          stopSharedDaemonForConfirmedDisable,
		waitForStopped:      waitForSharedDaemonStopped,
		launchctl:           sharedDaemonLaunchctl,
		removeLaunchAgent:   RemoveSharedDaemonLaunchAgent,
		clearEnablePrepared: clearSharedDaemonEnablePrepared,
		clearMigration:      clearSharedDaemonMigrationFlag,
		enablePrepared:      sharedDaemonEnablePrepared,
	}
}

func disableSharedDaemonAfterDesktopExitUnlocked(
	ctx context.Context,
	options LocalDaemonOptions,
	validate func() error,
	commit func() error,
) (LocalDaemonStatus, error) {
	return disableSharedDaemonAfterDesktopExitWithHooks(
		ctx,
		options,
		validate,
		commit,
		defaultConfirmedSharedDaemonDisableHooks(),
	)
}

func disableSharedDaemonAfterDesktopExitWithHooks(
	ctx context.Context,
	options LocalDaemonOptions,
	validate func() error,
	commit func() error,
	hooks confirmedSharedDaemonDisableHooks,
) (LocalDaemonStatus, error) {
	if validate == nil {
		return LocalDaemonStatus{}, fmt.Errorf("提交共享配置前的复核回调不能为空")
	}
	if commit == nil {
		return LocalDaemonStatus{}, fmt.Errorf("提交共享配置的回调不能为空")
	}
	if err := validateStableOwnerLease(options); err != nil {
		return LocalDaemonStatus{}, err
	}
	if err := validate(); err != nil {
		return LocalDaemonStatus{}, fmt.Errorf("共享配置快照已变化：%w", err)
	}
	if err := hooks.requireDesktopStopped(ctx, "关闭共享 daemon 前"); err != nil {
		return LocalDaemonStatus{}, err
	}
	socketPath, err := LocalDaemonSocketPath(options.Env)
	if err != nil {
		return LocalDaemonStatus{}, err
	}
	owner, err := hooks.inspectOwner(ctx)
	if err != nil {
		return LocalDaemonStatus{}, err
	}
	if owner.Installed && !owner.Secure {
		return LocalDaemonStatus{}, fmt.Errorf("共享 daemon LaunchAgent 权限不安全，拒绝关闭")
	}
	if hooks.socketAccepts(socketPath) && !sharedDaemonLoadedOwnerEvidence(owner) {
		return LocalDaemonStatus{}, fmt.Errorf("当前 Codex Unix backend 没有可确认的 Mimi stable owner，拒绝停止外部 daemon")
	}
	// 先把磁盘入口降为 manual 并保留 marker。后续任一停止、bootout、清理或
	// 配置 CAS 失败，都不能留下会在下次登录自动启动的旧 owner。
	if err := hooks.stageOwner(owner); err != nil {
		return LocalDaemonStatus{}, err
	}
	if err := validate(); err != nil {
		return LocalDaemonStatus{}, fmt.Errorf("共享配置快照已变化：%w", err)
	}
	if err := hooks.requireDesktopStopped(ctx, "停止共享 daemon 前"); err != nil {
		return LocalDaemonStatus{}, err
	}

	// stage 与停止之间 launchd 仍可能让已加载的旧 job 建立 socket，因此必须
	// 重新读取 owner 与 listener，而不能复用入口快照。
	owner, err = hooks.inspectOwner(ctx)
	if err != nil {
		return LocalDaemonStatus{}, err
	}
	if owner.Installed && !owner.Secure {
		return LocalDaemonStatus{}, fmt.Errorf("共享 daemon LaunchAgent 权限在关闭前发生变化")
	}
	var stoppedIdentities []sharedDaemonListenerProcess
	if hooks.socketAccepts(socketPath) {
		if !sharedDaemonLoadedOwnerEvidence(owner) {
			return LocalDaemonStatus{}, fmt.Errorf("当前 Codex Unix backend 没有可确认的 Mimi stable owner，拒绝停止外部 daemon")
		}
		identity, inspectErr := hooks.inspectListener(ctx, socketPath)
		if inspectErr != nil {
			return LocalDaemonStatus{}, fmt.Errorf("记录待关闭共享 daemon 身份失败：%w", inspectErr)
		}
		stoppedIdentities = append(stoppedIdentities, identity)
		if err := hooks.stopDaemon(ctx, options, owner); err != nil {
			return LocalDaemonStatus{}, err
		}
	}
	// 即使入口探测时没有 listener，也要经过稳定确认窗口。这样 loaded job 在
	// 检查后才建立 socket 时不会被直接 bootout 或与新 WS 配置并存。
	if err := hooks.waitForStopped(ctx, socketPath, stoppedIdentities...); err != nil {
		return LocalDaemonStatus{}, err
	}
	if err := hooks.requireDesktopStopped(ctx, "卸载共享 daemon owner 前"); err != nil {
		return LocalDaemonStatus{}, err
	}
	if hooks.socketAccepts(socketPath) {
		return LocalDaemonStatus{}, fmt.Errorf("共享 daemon socket 在卸载 owner 前重新出现")
	}
	owner, err = hooks.inspectOwner(ctx)
	if err != nil {
		return LocalDaemonStatus{}, err
	}
	if owner.Loaded {
		if !sharedDaemonLoadedOwnerEvidence(owner) {
			return LocalDaemonStatus{}, fmt.Errorf("已加载的共享 daemon owner 身份无法确认，拒绝卸载")
		}
		if _, bootoutErr := hooks.launchctl(ctx, "bootout", launchAgentServiceTarget()); bootoutErr != nil &&
			!isLaunchctlNotLoaded(bootoutErr) {
			return LocalDaemonStatus{}, fmt.Errorf("卸载共享 daemon owner 失败：%w", bootoutErr)
		}
	}
	confirmed, err := hooks.inspectOwner(ctx)
	if err != nil {
		return LocalDaemonStatus{}, fmt.Errorf("复核共享 daemon owner 卸载状态失败：%w", err)
	}
	if confirmed.Loaded {
		return LocalDaemonStatus{}, fmt.Errorf("共享 daemon owner 在 bootout 后仍处于 loaded 状态")
	}
	if err := hooks.removeLaunchAgent(ctx); err != nil {
		return LocalDaemonStatus{}, err
	}
	if err := hooks.clearEnablePrepared(); err != nil {
		return LocalDaemonStatus{}, fmt.Errorf("清理共享 daemon 启用事务失败：%w", err)
	}
	if err := hooks.clearMigration(); err != nil {
		return LocalDaemonStatus{}, fmt.Errorf("清理共享 daemon 迁移状态失败：%w", err)
	}

	// 最后一跳同时复核配置恢复权、Desktop、socket 与 owner。只有这些状态仍
	// 一致，才允许调用方把 shared Unix 原子替换为保存的独立 WS 配置。
	if err := validateStableOwnerLease(options); err != nil {
		return LocalDaemonStatus{}, err
	}
	if err := validate(); err != nil {
		return LocalDaemonStatus{}, fmt.Errorf("共享配置快照已变化：%w", err)
	}
	if err := hooks.requireDesktopStopped(ctx, "提交独立 App Server 配置前"); err != nil {
		return LocalDaemonStatus{}, err
	}
	if hooks.socketAccepts(socketPath) {
		return LocalDaemonStatus{}, fmt.Errorf("共享 daemon socket 在配置提交前重新出现")
	}
	confirmed, err = hooks.inspectOwner(ctx)
	if err != nil {
		return LocalDaemonStatus{}, fmt.Errorf("提交配置前复核共享 daemon owner 失败：%w", err)
	}
	prepared, err := hooks.enablePrepared()
	if err != nil {
		return LocalDaemonStatus{}, fmt.Errorf("提交配置前复核共享 daemon 启用事务失败：%w", err)
	}
	if confirmed.Installed || confirmed.Loaded || confirmed.MigrationRequired || prepared {
		return LocalDaemonStatus{}, fmt.Errorf("共享 daemon owner 未完全清理，拒绝提交独立 App Server 配置")
	}
	if err := commit(); err != nil {
		return LocalDaemonStatus{}, err
	}
	return LocalDaemonStatus{SocketPath: socketPath}, nil
}

func reconcileRunningSharedDaemonForIndependentMode(
	ctx context.Context,
	options LocalDaemonOptions,
	validate func() error,
) (SharedDaemonReconcileOutcome, error) {
	outcome := SharedDaemonReconcileNoop
	_, err := withSharedDaemonOperationLock(ctx, func() (LocalDaemonStatus, error) {
		if err := validateIndependentModeSharedDaemonCleanup(validate); err != nil {
			return LocalDaemonStatus{}, err
		}
		var runErr error
		outcome, runErr = reconcileRunningSharedDaemonForIndependentModeWithHooks(
			ctx,
			options,
			validate,
			defaultConfirmedSharedDaemonDisableHooks(),
		)
		return LocalDaemonStatus{}, runErr
	})
	if err != nil {
		return "", err
	}
	return outcome, nil
}

func reconcileRunningSharedDaemonForIndependentModeWithHooks(
	ctx context.Context,
	options LocalDaemonOptions,
	validate func() error,
	hooks confirmedSharedDaemonDisableHooks,
) (SharedDaemonReconcileOutcome, error) {
	socketPath, err := LocalDaemonSocketPath(options.Env)
	if err != nil {
		return "", err
	}
	if !hooks.socketAccepts(socketPath) {
		return SharedDaemonReconcileNoop, nil
	}
	owner, err := hooks.inspectOwner(ctx)
	if err != nil {
		return "", err
	}
	// Codex Desktop 自己拉起的 app-server 监听同一个 well-known socket。没有
	// stable owner 证据就绝不停止：那等于替用户杀掉 Desktop 的后端。权限不安全
	// 的 plist 同样不构成证据，会一并落到这里保持原样。
	if !sharedDaemonLoadedOwnerEvidence(owner) {
		return SharedDaemonReconcileForeign, nil
	}
	// launchd 入口归属不等于 listener 归属：Mimi 的 job 可能仍 loaded，而真正
	// 占着 well-known socket 的是 Codex Desktop 自己拉起的 app-server。必须先
	// 拿到签名 node supervisor 父链证据，才能进入任何会改动 owner 的步骤。
	if err := hooks.validateListenerOwnership(ctx, options, socketPath); err != nil {
		return "", fmt.Errorf("无法确认残留共享 daemon listener 归属，已保持原样：%w", err)
	}
	// 先只读判断 Desktop 是否在跑。stopDaemon 内部还会再次 fail-closed 复核；
	// 这里提前返回是为了在 Desktop 仍连着 daemon 时一个字节都不改，让调用方
	// 把“需要重启 Codex Desktop”原样告诉用户。
	desktopRunning, err := hooks.desktopRunning(ctx)
	if err != nil {
		return "", fmt.Errorf("确认 Codex Desktop 是否在运行失败：%w", err)
	}
	if desktopRunning {
		return SharedDaemonReconcilePendingDesktopExit, nil
	}
	// 首个副作用必须在 operation lock 内复核磁盘仍为独立模式。另一个
	// Mimi 进程切回 shared 时也使用同一把锁，旧 WS 进程不能清理新 owner。
	if err := validateIndependentModeSharedDaemonCleanup(validate); err != nil {
		return "", err
	}
	// 入口降为 manual 必须先于停止：后面任一步失败都不能留下会在下次登录
	// 自动拉起、并重新抢走 writer lock 的 owner。
	if err := hooks.stageOwner(owner); err != nil {
		return "", err
	}
	identity, err := hooks.inspectListener(ctx, socketPath)
	if err != nil {
		return "", fmt.Errorf("记录残留共享 daemon 身份失败：%w", err)
	}
	if err := hooks.stopDaemon(ctx, options, owner); err != nil {
		return "", err
	}
	if err := hooks.waitForStopped(ctx, socketPath, identity); err != nil {
		return "", err
	}
	// wait 返回只证明原 listener 已退出。Desktop 或其他进程可能在确认窗口后
	// 重新绑定 well-known socket；bootout 前必须再次同时确认 Desktop 和 socket。
	if err := hooks.requireDesktopStopped(ctx, "卸载残留共享 daemon owner 前"); err != nil {
		return "", err
	}
	if hooks.socketAccepts(socketPath) {
		return "", fmt.Errorf("共享 daemon socket 在卸载残留 owner 前重新出现")
	}
	// bootout/remove 是不可逆 owner 变更。等待期间即使有不遵守 Mimi 锁的
	// 外部配置写入，也必须在这里再次 fail closed。
	if err := validateIndependentModeSharedDaemonCleanup(validate); err != nil {
		return "", err
	}
	confirmed, err := hooks.inspectOwner(ctx)
	if err != nil {
		return "", fmt.Errorf("停止后复核共享 daemon owner 失败：%w", err)
	}
	if confirmed.Loaded {
		if !sharedDaemonLoadedOwnerEvidence(confirmed) {
			return "", fmt.Errorf("已加载的残留共享 daemon owner 身份无法确认，拒绝卸载")
		}
		if _, bootoutErr := hooks.launchctl(ctx, "bootout", launchAgentServiceTarget()); bootoutErr != nil &&
			!isLaunchctlNotLoaded(bootoutErr) {
			return "", fmt.Errorf("卸载残留共享 daemon owner 失败：%w", bootoutErr)
		}
		if confirmed, err = hooks.inspectOwner(ctx); err != nil {
			return "", fmt.Errorf("复核残留共享 daemon owner 卸载状态失败：%w", err)
		}
		if confirmed.Loaded {
			return "", fmt.Errorf("残留共享 daemon owner 在 bootout 后仍处于 loaded 状态")
		}
	}
	if err := hooks.removeLaunchAgent(ctx); err != nil {
		return "", err
	}
	if err := hooks.clearEnablePrepared(); err != nil {
		return "", fmt.Errorf("清理共享 daemon 启用事务失败：%w", err)
	}
	if err := hooks.clearMigration(); err != nil {
		return "", fmt.Errorf("清理共享 daemon 迁移状态失败：%w", err)
	}
	return SharedDaemonReconcileStopped, nil
}

func validateIndependentModeSharedDaemonCleanup(validate func() error) error {
	if validate == nil {
		return fmt.Errorf("独立模式共享 daemon 清理权复核回调不能为空")
	}
	if err := validate(); err != nil {
		return fmt.Errorf("独立模式共享 daemon 清理权已失效：%w", err)
	}
	return nil
}

func sharedDaemonLoadedOwnerEvidence(owner SharedDaemonOwnerStatus) bool {
	if !owner.Loaded || owner.Label != SharedDaemonLaunchAgentLabel {
		return false
	}
	// plist 缺失正是 orphan loaded job 的目标场景；精确 label 仍提供 owner
	// 证据。若 plist 存在，则权限必须安全，不能把可被其他用户修改的定义
	// 当成 Mimi stable owner。
	return !owner.Installed || owner.Secure
}

func stageSharedDaemonOwnerForConfirmedDisable(owner SharedDaemonOwnerStatus) error {
	if !owner.Installed {
		return nil
	}
	content, err := os.ReadFile(owner.Path)
	if err != nil {
		return fmt.Errorf("读取共享 daemon LaunchAgent 失败：%w", err)
	}
	if owner.RunAtLoad {
		manual, manualErr := sharedDaemonManualPlist(content)
		if manualErr != nil {
			return manualErr
		}
		if err := writeSharedDaemonPrivateFileAtomically(owner.Path, manual); err != nil {
			return fmt.Errorf("把共享 daemon owner 降为 manual 失败：%w", err)
		}
	}
	if !owner.MigrationRequired {
		if err := writeSharedDaemonMigrationFlag(); err != nil {
			return fmt.Errorf("记录共享 daemon manual 状态失败：%w", err)
		}
	}
	return nil
}

func stopSharedDaemonForConfirmedDisable(
	ctx context.Context,
	options LocalDaemonOptions,
	owner SharedDaemonOwnerStatus,
) error {
	socketPath, err := LocalDaemonSocketPath(options.Env)
	if err != nil {
		return err
	}
	lifecycle, err := InspectLocalDaemonLifecycle(ctx, options)
	if err != nil {
		return err
	}
	if handled, stopErr := stopLegacyPIDBackendWithoutReportedPID(
		ctx,
		options,
		owner,
		lifecycle,
		validateLegacyPIDBackendListener,
		stopManagedSharedDaemonCommand,
	); handled {
		return stopErr
	}
	if lifecycle.Backend != nil {
		listener, err := captureStableManagedSharedDaemonListenerIdentity(
			ctx,
			options,
			socketPath,
			lifecycle,
			nil,
			sharedDaemonCaptureSignedRuntimeIdentity,
			inspectSharedDaemonListenerProcess,
		)
		if err != nil {
			return err
		}
		return stopSharedDaemonWithExpectedIdentity(ctx, options, owner, &listener)
	}
	if !sharedDaemonLoadedOwnerEvidence(owner) {
		return fmt.Errorf("非 daemon 管理的 Codex app-server 没有已确认的 Mimi stable owner，拒绝停止")
	}
	probeCtx, cancelProbe := context.WithTimeout(ctx, localDaemonProbeTimeout)
	probe, err := ProbeLocalDaemonInfo(probeCtx, socketPath)
	cancelProbe()
	if err != nil {
		return fmt.Errorf("无法确认待关闭的 Codex app-server：%w", err)
	}
	if err := ValidateLocalDaemonLifecycle(lifecycle, socketPath); err != nil {
		return err
	}
	if err := ValidateLocalDaemonProbeVersion(lifecycle, probe.Version); err != nil {
		return err
	}
	confirmed, err := captureStableSignedSharedDaemonListenerIdentity(
		ctx,
		options,
		socketPath,
		sharedDaemonCaptureSignedRuntimeIdentity,
		inspectSharedDaemonListenerProcess,
	)
	if err != nil {
		return fmt.Errorf("确认共享 daemon listener 身份失败：%w", err)
	}
	if err := requireCodexDesktopStopped(ctx, "正常终止共享 daemon 前"); err != nil {
		return err
	}
	expectedCodexPath, err := resolveSharedDaemonCodexBin(options.CodexBin)
	if err != nil {
		return fmt.Errorf("解析共享 daemon Codex 可执行文件失败：%w", err)
	}
	return stopUnmanagedSharedDaemonWithExpectedIdentity(
		ctx,
		socketPath,
		expectedCodexPath,
		&confirmed,
		unmanagedSharedDaemonHooks{
			desktopRunning: sharedDaemonDesktopRunning,
			inspect:        inspectSharedDaemonListenerProcess,
			signalTERM:     signalSharedDaemonProcessTERM,
			currentUID:     os.Getuid,
		},
	)
}

type legacyPIDBackendValidateFunc func(
	context.Context,
	LocalDaemonOptions,
	LocalDaemonLifecycleStatus,
) error

type legacyPIDBackendStopFunc func(context.Context, LocalDaemonOptions) error

type sharedDaemonSignedRuntimeCaptureFunc func(
	context.Context,
	LocalDaemonOptions,
	string,
) (sharedDaemonListenerProcess, error)

type sharedDaemonListenerInspectFunc func(
	context.Context,
	string,
) (sharedDaemonListenerProcess, error)

// captureStableSignedSharedDaemonListenerIdentity 把动态签名/父链证明与调用方
// 看到的 socket owner 绑定。capture 返回它内部实际验签并稳定复核过的 identity；
// 前后两次 socket 取证必须都等于它，ABA 换主也不能把未验签进程混入停止目标。
func captureStableSignedSharedDaemonListenerIdentity(
	ctx context.Context,
	options LocalDaemonOptions,
	socketPath string,
	capture sharedDaemonSignedRuntimeCaptureFunc,
	inspect sharedDaemonListenerInspectFunc,
) (sharedDaemonListenerProcess, error) {
	if capture == nil || inspect == nil {
		return sharedDaemonListenerProcess{}, fmt.Errorf("共享 daemon listener 缺少安全取证实现")
	}
	before, err := inspect(ctx, socketPath)
	if err != nil {
		return sharedDaemonListenerProcess{}, fmt.Errorf("验签前识别 listener 失败：%w", err)
	}
	validated, err := capture(ctx, options, socketPath)
	if err != nil {
		return sharedDaemonListenerProcess{}, fmt.Errorf("listener 缺少签名 supervisor 父链：%w", err)
	}
	after, err := inspect(ctx, socketPath)
	if err != nil {
		return sharedDaemonListenerProcess{}, fmt.Errorf("验签后识别 listener 失败：%w", err)
	}
	if before != validated || after != validated {
		return sharedDaemonListenerProcess{}, fmt.Errorf("socket owner 与已验签 listener 身份不一致")
	}
	return validated, nil
}

// captureStableManagedSharedDaemonListenerIdentity 把官方 pid backend 报告的
// PID、调用方已确认的 identity，以及本次实际完成验签的 socket owner 绑定。
// official stop 不接收 expected identity，因此每次停止前都必须重新完成这组取证。
func captureStableManagedSharedDaemonListenerIdentity(
	ctx context.Context,
	options LocalDaemonOptions,
	socketPath string,
	lifecycle LocalDaemonLifecycleStatus,
	expected *sharedDaemonListenerProcess,
	capture sharedDaemonSignedRuntimeCaptureFunc,
	inspect sharedDaemonListenerInspectFunc,
) (sharedDaemonListenerProcess, error) {
	current, err := captureStableSignedSharedDaemonListenerIdentity(
		ctx,
		options,
		socketPath,
		capture,
		inspect,
	)
	if err != nil {
		return sharedDaemonListenerProcess{}, err
	}
	bound := current
	if expected != nil {
		bound = *expected
	}
	if err := validateManagedSharedDaemonListenerIdentity(lifecycle, bound, current); err != nil {
		return sharedDaemonListenerProcess{}, err
	}
	return current, nil
}

// 旧版 daemon version 会报告 backend=pid，但不返回 PID。此时不能进入依赖
// lifecycle.PID 的普通路径；先严格验证真实 socket peer，再继续调用官方 stop。
func stopLegacyPIDBackendWithoutReportedPID(
	ctx context.Context,
	options LocalDaemonOptions,
	owner SharedDaemonOwnerStatus,
	lifecycle LocalDaemonLifecycleStatus,
	validate legacyPIDBackendValidateFunc,
	stop legacyPIDBackendStopFunc,
) (bool, error) {
	if lifecycle.Backend == nil || lifecycle.PID != nil ||
		!strings.EqualFold(strings.TrimSpace(*lifecycle.Backend), "pid") {
		return false, nil
	}
	if !sharedDaemonLoadedOwnerEvidence(owner) {
		return true, fmt.Errorf("旧 pid backend 没有已确认的 Mimi stable owner，拒绝停止")
	}
	if validate == nil || stop == nil {
		return true, fmt.Errorf("旧 pid backend 缺少安全取证或官方停止实现")
	}
	if err := validate(ctx, options, lifecycle); err != nil {
		return true, err
	}
	return true, stop(ctx, options)
}

func validateLegacyPIDBackendListener(
	ctx context.Context,
	options LocalDaemonOptions,
	lifecycle LocalDaemonLifecycleStatus,
) error {
	socketPath, err := LocalDaemonSocketPath(options.Env)
	if err != nil {
		return err
	}
	probeCtx, cancelProbe := context.WithTimeout(ctx, localDaemonProbeTimeout)
	probe, err := ProbeLocalDaemonInfo(probeCtx, socketPath)
	cancelProbe()
	if err != nil {
		return fmt.Errorf("无法确认旧 pid backend：%w", err)
	}
	if err := ValidateLocalDaemonLifecycle(lifecycle, socketPath); err != nil {
		return err
	}
	if err := ValidateLocalDaemonProbeVersion(lifecycle, probe.Version); err != nil {
		return err
	}
	if err := validatePrivateSharedDaemonSocket(socketPath, os.Getuid()); err != nil {
		return err
	}
	listener, err := captureStableSignedSharedDaemonListenerIdentity(
		ctx,
		options,
		socketPath,
		sharedDaemonCaptureSignedRuntimeIdentity,
		inspectSharedDaemonListenerProcess,
	)
	if err != nil {
		return fmt.Errorf("确认旧 pid backend listener 身份失败：%w", err)
	}
	expectedCodexPath, err := resolveSharedDaemonCodexBin(options.CodexBin)
	if err != nil {
		return fmt.Errorf("解析旧 pid backend Codex 可执行文件失败：%w", err)
	}
	_, err = validateUnmanagedSharedDaemonWithExpectedIdentity(
		ctx,
		socketPath,
		expectedCodexPath,
		&listener,
		unmanagedSharedDaemonHooks{
			desktopRunning: sharedDaemonDesktopRunning,
			inspect:        inspectSharedDaemonListenerProcess,
			currentUID:     os.Getuid,
		},
	)
	return err
}
