//go:build darwin

package appserver

import (
	"context"
	"fmt"
	"strings"
)

func stopSharedDaemon(
	ctx context.Context,
	options LocalDaemonOptions,
	owner SharedDaemonOwnerStatus,
) error {
	return stopSharedDaemonWithExpectedIdentity(ctx, options, owner, nil)
}

func stopSharedDaemonWithExpectedIdentity(
	ctx context.Context,
	options LocalDaemonOptions,
	owner SharedDaemonOwnerStatus,
	expected *sharedDaemonListenerProcess,
) error {
	socketPath, pathErr := LocalDaemonSocketPath(options.Env)
	if pathErr != nil {
		return pathErr
	}
	// 上一次显式迁移可能已发出 SIGHUP，但旧 server 在等待活动 Turn
	// 完成后才退出。稍后重试时不再向已经断开的 listener 重复发信号。
	if !sharedDaemonSocketAcceptsConnection(socketPath) {
		return nil
	}
	lifecycle, lifecycleErr := InspectLocalDaemonLifecycle(ctx, options)
	if lifecycleErr != nil {
		return lifecycleErr
	}
	if lifecycle.Backend == nil {
		if !owner.Installed || !owner.Loaded || !owner.Secure || !owner.MigrationRequired {
			return fmt.Errorf("非 daemon 管理的 Codex app-server 缺少已确认的稳定 owner 迁移状态，拒绝接管")
		}
		return stopUnmanagedSharedDaemonWithLifecycleIdentity(ctx, options, lifecycle, expected)
	}
	backend := strings.ToLower(strings.TrimSpace(*lifecycle.Backend))
	if backend != "pid" {
		return fmt.Errorf("Codex app-server 使用未知 lifecycle backend %q，拒绝迁移", *lifecycle.Backend)
	}
	if lifecycle.PID == nil {
		validate := validateLegacyPIDBackendListener
		if expected != nil {
			validate = func(
				ctx context.Context,
				options LocalDaemonOptions,
				lifecycle LocalDaemonLifecycleStatus,
			) (sharedDaemonListenerProcess, error) {
				listener, err := validateLegacyPIDBackendListener(ctx, options, lifecycle)
				if err == nil && listener != *expected {
					return sharedDaemonListenerProcess{}, fmt.Errorf("旧 pid backend listener 与已验证身份不一致，拒绝停止")
				}
				return listener, err
			}
		}
		_, err := stopLegacyPIDBackendWithoutReportedPID(
			ctx,
			options,
			owner,
			lifecycle,
			validate,
			sharedDaemonSignalGraceful,
		)
		return err
	}
	if !localDaemonVersionSupported(strings.TrimSpace(lifecycle.AppServerVersion)) {
		return fmt.Errorf("Codex local daemon 版本不兼容，需要 >= %s", minimumDesktopDaemonVersion)
	}
	listener, err := captureStableManagedSharedDaemonListenerIdentity(
		ctx,
		options,
		socketPath,
		lifecycle,
		expected,
		sharedDaemonCaptureSignedRuntimeIdentity,
		inspectSharedDaemonListenerProcess,
	)
	if err != nil {
		return fmt.Errorf("停止官方 Codex daemon 前签名父链复核失败：%w", err)
	}
	expected = &listener
	if err := requireCodexDesktopStopped(ctx, "停止官方 Codex daemon 前"); err != nil {
		return err
	}
	// Desktop 探测本身也会产生调度窗口。发送优雅排空信号前再绑定一次 PID、
	// 启动时间和签名父链，避免向刚替换进来的 listener 发信号。
	if _, err := captureStableManagedSharedDaemonListenerIdentity(
		ctx,
		options,
		socketPath,
		lifecycle,
		expected,
		sharedDaemonCaptureSignedRuntimeIdentity,
		inspectSharedDaemonListenerProcess,
	); err != nil {
		return fmt.Errorf("执行优雅排空前签名父链复核失败：%w", err)
	}
	if err := requireCodexDesktopStopped(ctx, "执行优雅排空前"); err != nil {
		return err
	}
	if err := requireManagedSharedDaemonIdleForStop(ctx, options, socketPath, lifecycle, expected); err != nil {
		return err
	}
	// Codex >= 0.141 把 SIGHUP 定义为 graceful-only：有活动 Turn 时继续排空并等待，
	// Turn 归零后才关闭传输；它不会像官方 daemon stop 那样在 60 秒后强制终止。
	return requestSharedDaemonGracefulDrain(*expected)
}

func requestSharedDaemonGracefulDrain(listener sharedDaemonListenerProcess) error {
	if err := validateSharedDaemonSignalTargetPID(listener.PID); err != nil {
		return err
	}
	if err := sharedDaemonSignalGraceful(listener.PID); err != nil {
		return fmt.Errorf("请求 Codex app-server 优雅排空失败：%w", err)
	}
	return nil
}

func validateManagedSharedDaemonListenerIdentity(
	lifecycle LocalDaemonLifecycleStatus,
	expected sharedDaemonListenerProcess,
	current sharedDaemonListenerProcess,
) error {
	if lifecycle.PID == nil {
		return fmt.Errorf("官方 Codex daemon 未报告 pid backend 身份，拒绝停止")
	}
	if int(*lifecycle.PID) != expected.PID {
		return fmt.Errorf("官方 Codex daemon PID 与已确认 listener 不一致，拒绝停止")
	}
	if current != expected {
		return fmt.Errorf("共享 daemon listener 在优雅排空前发生变化，拒绝停止")
	}
	return nil
}
