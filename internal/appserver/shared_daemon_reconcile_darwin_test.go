//go:build darwin

package appserver

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestConfirmedSharedDaemonDisableRefreshesDeadlineAfterLockWait(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)

	lockHeld := make(chan struct{})
	releaseLock := make(chan struct{})
	holderDone := make(chan error, 1)
	go func() {
		_, err := withSharedDaemonOperationLock(
			context.Background(),
			func() (LocalDaemonStatus, error) {
				close(lockHeld)
				<-releaseLock
				return LocalDaemonStatus{}, nil
			},
		)
		holderDone <- err
	}()
	<-lockHeld

	timer := time.AfterFunc(100*time.Millisecond, func() { close(releaseLock) })
	defer timer.Stop()
	started := time.Now()
	var operationStarted time.Time
	var operationDeadline time.Time
	_, err := withConfirmedSharedDaemonDisableLock(
		context.Background(),
		time.Second,
		500*time.Millisecond,
		func(ctx context.Context) (LocalDaemonStatus, error) {
			operationStarted = time.Now()
			var ok bool
			operationDeadline, ok = ctx.Deadline()
			if !ok {
				t.Fatal("关闭事务必须有独立 deadline")
			}
			return LocalDaemonStatus{}, nil
		},
	)
	if err != nil {
		t.Fatalf("等待锁后执行关闭事务失败: %v", err)
	}
	if err := <-holderDone; err != nil {
		t.Fatalf("释放测试锁失败: %v", err)
	}
	if waited := operationStarted.Sub(started); waited < 80*time.Millisecond {
		t.Fatalf("测试未制造出有效锁等待: %s", waited)
	}
	if remaining := operationDeadline.Sub(operationStarted); remaining < 400*time.Millisecond {
		t.Fatalf("锁等待侵蚀了关闭事务预算: %s", remaining)
	}
}

func TestConfirmedSharedDaemonDisableStopsUnloadsCleansThenCommits(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	options := LocalDaemonOptions{
		Env: map[string]string{"CODEX_HOME": filepath.Join(home, ".codex")},
	}
	leaseChecks := 0
	options.ValidateStableOwner = func() error {
		leaseChecks++
		return nil
	}

	owner := SharedDaemonOwnerStatus{
		Installed: true,
		Loaded:    true,
		Secure:    true,
		RunAtLoad: true,
		Path:      filepath.Join(home, "owner.plist"),
		Label:     SharedDaemonLaunchAgentLabel,
	}
	socketActive := true
	prepared := true
	validateCalls := 0
	desktopChecks := 0
	events := make([]string, 0, 8)
	listener := sharedDaemonListenerProcess{PID: 123, UID: os.Getuid(), StartSec: 456}
	hooks := confirmedSharedDaemonDisableHooks{
		requireDesktopStopped: func(context.Context, string) error {
			desktopChecks++
			return nil
		},
		inspectOwner: func(context.Context) (SharedDaemonOwnerStatus, error) {
			return owner, nil
		},
		socketAccepts: func(string) bool { return socketActive },
		stageOwner: func(SharedDaemonOwnerStatus) error {
			events = append(events, "stage")
			owner.RunAtLoad = false
			owner.MigrationRequired = true
			return nil
		},
		inspectListener: func(context.Context, string) (sharedDaemonListenerProcess, error) {
			return listener, nil
		},
		stopDaemon: func(context.Context, LocalDaemonOptions, SharedDaemonOwnerStatus) error {
			events = append(events, "stop")
			socketActive = false
			return nil
		},
		waitForStopped: func(_ context.Context, _ string, identities ...sharedDaemonListenerProcess) error {
			events = append(events, "wait")
			if len(identities) != 1 || identities[0] != listener {
				t.Fatalf("停止确认必须绑定原 listener 身份：%+v", identities)
			}
			return nil
		},
		launchctl: func(_ context.Context, arguments ...string) (string, error) {
			if len(arguments) == 0 || arguments[0] != "bootout" {
				return "", fmt.Errorf("unexpected launchctl command: %v", arguments)
			}
			events = append(events, "bootout")
			owner.Loaded = false
			return "", nil
		},
		removeLaunchAgent: func(context.Context) error {
			events = append(events, "remove")
			owner.Installed = false
			return nil
		},
		clearEnablePrepared: func() error {
			events = append(events, "clear-enable")
			prepared = false
			return nil
		},
		clearMigration: func() error {
			events = append(events, "clear-marker")
			owner.MigrationRequired = false
			return nil
		},
		enablePrepared: func() (bool, error) { return prepared, nil },
	}

	_, err := disableSharedDaemonAfterDesktopExitWithHooks(
		context.Background(),
		options,
		func() error {
			validateCalls++
			return nil
		},
		func() error {
			events = append(events, "commit")
			return nil
		},
		hooks,
	)
	if err != nil {
		t.Fatal(err)
	}
	wantEvents := []string{"stage", "stop", "wait", "bootout", "remove", "clear-enable", "clear-marker", "commit"}
	if strings.Join(events, ",") != strings.Join(wantEvents, ",") {
		t.Fatalf("确认禁用副作用顺序错误：got=%v want=%v", events, wantEvents)
	}
	if validateCalls != 3 || leaseChecks != 2 || desktopChecks != 4 {
		t.Fatalf("确认禁用必须持续复核租约与 Desktop：validate=%d lease=%d desktop=%d", validateCalls, leaseChecks, desktopChecks)
	}
}

func TestConfirmedSharedDaemonDisableRefusesMutationWhileDesktopRuns(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	wantErr := errors.New("desktop still running")
	mutated := false
	hooks := confirmedSharedDaemonDisableHooks{
		requireDesktopStopped: func(context.Context, string) error { return wantErr },
		inspectOwner: func(context.Context) (SharedDaemonOwnerStatus, error) {
			mutated = true
			return SharedDaemonOwnerStatus{}, nil
		},
		socketAccepts: func(string) bool { mutated = true; return false },
		stageOwner:    func(SharedDaemonOwnerStatus) error { mutated = true; return nil },
		inspectListener: func(context.Context, string) (sharedDaemonListenerProcess, error) {
			mutated = true
			return sharedDaemonListenerProcess{}, nil
		},
		stopDaemon:          func(context.Context, LocalDaemonOptions, SharedDaemonOwnerStatus) error { mutated = true; return nil },
		waitForStopped:      func(context.Context, string, ...sharedDaemonListenerProcess) error { mutated = true; return nil },
		launchctl:           func(context.Context, ...string) (string, error) { mutated = true; return "", nil },
		removeLaunchAgent:   func(context.Context) error { mutated = true; return nil },
		clearEnablePrepared: func() error { mutated = true; return nil },
		clearMigration:      func() error { mutated = true; return nil },
		enablePrepared:      func() (bool, error) { mutated = true; return false, nil },
	}
	committed := false
	_, err := disableSharedDaemonAfterDesktopExitWithHooks(
		context.Background(),
		LocalDaemonOptions{Env: map[string]string{"CODEX_HOME": filepath.Join(home, ".codex")}},
		func() error { return nil },
		func() error { committed = true; return nil },
		hooks,
	)
	if !errors.Is(err, wantErr) || mutated || committed {
		t.Fatalf("Desktop 运行时必须在任何 owner mutation 前失败：err=%v mutated=%t committed=%t", err, mutated, committed)
	}
}

func TestConfirmedSharedDaemonDisableBootoutFailureDoesNotCommit(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	wantErr := errors.New("bootout denied")
	owner := SharedDaemonOwnerStatus{
		Installed:         true,
		Loaded:            true,
		Secure:            true,
		MigrationRequired: true,
		Label:             SharedDaemonLaunchAgentLabel,
	}
	removed := false
	committed := false
	hooks := confirmedSharedDaemonDisableHooks{
		requireDesktopStopped: func(context.Context, string) error { return nil },
		inspectOwner:          func(context.Context) (SharedDaemonOwnerStatus, error) { return owner, nil },
		socketAccepts:         func(string) bool { return false },
		stageOwner:            func(SharedDaemonOwnerStatus) error { return nil },
		inspectListener: func(context.Context, string) (sharedDaemonListenerProcess, error) {
			return sharedDaemonListenerProcess{}, nil
		},
		stopDaemon:          func(context.Context, LocalDaemonOptions, SharedDaemonOwnerStatus) error { return nil },
		waitForStopped:      func(context.Context, string, ...sharedDaemonListenerProcess) error { return nil },
		launchctl:           func(context.Context, ...string) (string, error) { return "", wantErr },
		removeLaunchAgent:   func(context.Context) error { removed = true; return nil },
		clearEnablePrepared: func() error { return nil },
		clearMigration:      func() error { return nil },
		enablePrepared:      func() (bool, error) { return false, nil },
	}
	_, err := disableSharedDaemonAfterDesktopExitWithHooks(
		context.Background(),
		LocalDaemonOptions{Env: map[string]string{"CODEX_HOME": filepath.Join(home, ".codex")}},
		func() error { return nil },
		func() error { committed = true; return nil },
		hooks,
	)
	if !errors.Is(err, wantErr) || removed || committed {
		t.Fatalf("bootout 失败后必须保留 shared 配置与 owner 文件：err=%v removed=%t committed=%t", err, removed, committed)
	}
}

func TestConfirmedSharedDaemonDisableCleansOrphanLoadedJobForExistingWS(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	owner := SharedDaemonOwnerStatus{
		Loaded:            true,
		MigrationRequired: true,
		Label:             SharedDaemonLaunchAgentLabel,
	}
	bootoutCalls := 0
	commitCalls := 0
	hooks := confirmedSharedDaemonDisableHooks{
		requireDesktopStopped: func(context.Context, string) error { return nil },
		inspectOwner:          func(context.Context) (SharedDaemonOwnerStatus, error) { return owner, nil },
		socketAccepts:         func(string) bool { return false },
		stageOwner:            func(SharedDaemonOwnerStatus) error { return nil },
		inspectListener: func(context.Context, string) (sharedDaemonListenerProcess, error) {
			return sharedDaemonListenerProcess{}, nil
		},
		stopDaemon:     func(context.Context, LocalDaemonOptions, SharedDaemonOwnerStatus) error { return nil },
		waitForStopped: func(context.Context, string, ...sharedDaemonListenerProcess) error { return nil },
		launchctl: func(context.Context, ...string) (string, error) {
			bootoutCalls++
			owner.Loaded = false
			return "", nil
		},
		removeLaunchAgent:   func(context.Context) error { return nil },
		clearEnablePrepared: func() error { return nil },
		clearMigration: func() error {
			owner.MigrationRequired = false
			return nil
		},
		enablePrepared: func() (bool, error) { return false, nil },
	}
	_, err := disableSharedDaemonAfterDesktopExitWithHooks(
		context.Background(),
		LocalDaemonOptions{Env: map[string]string{"CODEX_HOME": filepath.Join(home, ".codex")}},
		func() error { return nil },
		func() error { commitCalls++; return nil },
		hooks,
	)
	if err != nil || bootoutCalls != 1 || commitCalls != 1 {
		t.Fatalf("WS 配置下的孤立 Mimi loaded job 应幂等清理：err=%v bootout=%d commit=%d", err, bootoutCalls, commitCalls)
	}
}

// independentModeReconcileHooks 构造一个“Mimi 共享 daemon 仍在监听”的现场，
// 并记录每一步真实副作用，用于断言独立模式启动只在证据充分时才动它。
func independentModeReconcileHooks(
	t *testing.T,
	owner *SharedDaemonOwnerStatus,
	desktopRunning bool,
	events *[]string,
) confirmedSharedDaemonDisableHooks {
	t.Helper()
	socketActive := true
	listener := sharedDaemonListenerProcess{PID: 4321, UID: os.Getuid(), StartSec: 99}
	return confirmedSharedDaemonDisableHooks{
		requireDesktopStopped: func(context.Context, string) error {
			if desktopRunning {
				return errors.New("Codex Desktop 仍在运行")
			}
			return nil
		},
		desktopRunning: func(context.Context) (bool, error) { return desktopRunning, nil },
		validateListenerOwnership: func(context.Context, LocalDaemonOptions, string) error {
			return nil
		},
		inspectOwner:  func(context.Context) (SharedDaemonOwnerStatus, error) { return *owner, nil },
		socketAccepts: func(string) bool { return socketActive },
		stageOwner: func(SharedDaemonOwnerStatus) error {
			*events = append(*events, "stage")
			owner.RunAtLoad = false
			owner.MigrationRequired = true
			return nil
		},
		inspectListener: func(context.Context, string) (sharedDaemonListenerProcess, error) {
			return listener, nil
		},
		stopDaemon: func(context.Context, LocalDaemonOptions, SharedDaemonOwnerStatus) error {
			*events = append(*events, "stop")
			socketActive = false
			return nil
		},
		waitForStopped: func(_ context.Context, _ string, identities ...sharedDaemonListenerProcess) error {
			*events = append(*events, "wait")
			if len(identities) != 1 || identities[0] != listener {
				t.Fatalf("停止确认必须绑定原 listener 身份：%+v", identities)
			}
			return nil
		},
		launchctl: func(_ context.Context, arguments ...string) (string, error) {
			if len(arguments) == 0 || arguments[0] != "bootout" {
				return "", fmt.Errorf("unexpected launchctl command: %v", arguments)
			}
			*events = append(*events, "bootout")
			owner.Loaded = false
			return "", nil
		},
		removeLaunchAgent: func(context.Context) error {
			*events = append(*events, "remove")
			owner.Installed = false
			return nil
		},
		clearEnablePrepared: func() error {
			*events = append(*events, "clear-enable")
			return nil
		},
		clearMigration: func() error {
			*events = append(*events, "clear-marker")
			owner.MigrationRequired = false
			return nil
		},
	}
}

func TestIndependentModeReconcileStopsLeftoverMimiSharedDaemon(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	options := LocalDaemonOptions{Env: map[string]string{"CODEX_HOME": filepath.Join(home, ".codex")}}
	owner := SharedDaemonOwnerStatus{
		Installed: true,
		Loaded:    true,
		Secure:    true,
		RunAtLoad: true,
		Path:      filepath.Join(home, "owner.plist"),
		Label:     SharedDaemonLaunchAgentLabel,
	}
	events := make([]string, 0, 8)
	hooks := independentModeReconcileHooks(t, &owner, false, &events)

	outcome, err := reconcileRunningSharedDaemonForIndependentModeWithHooks(
		context.Background(),
		options,
		func() error { return nil },
		hooks,
	)
	if err != nil {
		t.Fatal(err)
	}
	if outcome != SharedDaemonReconcileStopped {
		t.Fatalf("Desktop 已退出且 owner 可确认时必须真正停止 daemon：%s", outcome)
	}
	wantEvents := []string{"stage", "stop", "wait", "bootout", "remove", "clear-enable", "clear-marker"}
	if strings.Join(events, ",") != strings.Join(wantEvents, ",") {
		t.Fatalf("独立模式清理副作用顺序错误：got=%v want=%v", events, wantEvents)
	}
}

func TestIndependentModeReconcileOwnershipChangeHasNoSideEffects(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	options := LocalDaemonOptions{Env: map[string]string{"CODEX_HOME": filepath.Join(home, ".codex")}}
	owner := SharedDaemonOwnerStatus{
		Installed: true,
		Loaded:    true,
		Secure:    true,
		RunAtLoad: true,
		Path:      filepath.Join(home, "owner.plist"),
		Label:     SharedDaemonLaunchAgentLabel,
	}
	events := make([]string, 0, 4)
	hooks := independentModeReconcileHooks(t, &owner, false, &events)

	outcome, err := reconcileRunningSharedDaemonForIndependentModeWithHooks(
		context.Background(),
		options,
		func() error { return errors.New("当前配置已经启用 Mimi 共享 daemon") },
		hooks,
	)
	if err == nil || !strings.Contains(err.Error(), "清理权已失效") || outcome != "" {
		t.Fatalf("并发切回共享时必须 fail closed：outcome=%s err=%v", outcome, err)
	}
	if len(events) != 0 {
		t.Fatalf("配置所有权失效后不得产生任何副作用：%v", events)
	}
	if !owner.RunAtLoad || owner.MigrationRequired {
		t.Fatalf("配置所有权失效后不得修改 owner：%+v", owner)
	}
}

func TestIndependentModeReconcileRefusesBootoutWhenDesktopReopensAfterWait(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	options := LocalDaemonOptions{Env: map[string]string{"CODEX_HOME": filepath.Join(home, ".codex")}}
	owner := SharedDaemonOwnerStatus{
		Installed: true,
		Loaded:    true,
		Secure:    true,
		RunAtLoad: true,
		Path:      filepath.Join(home, "owner.plist"),
		Label:     SharedDaemonLaunchAgentLabel,
	}
	events := make([]string, 0, 4)
	hooks := independentModeReconcileHooks(t, &owner, false, &events)
	hooks.requireDesktopStopped = func(context.Context, string) error {
		return errors.New("Codex Desktop 已重新打开")
	}

	outcome, err := reconcileRunningSharedDaemonForIndependentModeWithHooks(
		context.Background(),
		options,
		func() error { return nil },
		hooks,
	)
	if err == nil || !strings.Contains(err.Error(), "重新打开") || outcome != "" {
		t.Fatalf("Desktop 在 wait 后重开时必须拒绝 bootout：outcome=%s err=%v", outcome, err)
	}
	if strings.Contains(strings.Join(events, ","), "bootout") {
		t.Fatalf("Desktop 重开后不得 bootout：%v", events)
	}
}

func TestIndependentModeReconcileRefusesBootoutWhenSocketReappearsAfterWait(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	options := LocalDaemonOptions{Env: map[string]string{"CODEX_HOME": filepath.Join(home, ".codex")}}
	owner := SharedDaemonOwnerStatus{
		Installed: true,
		Loaded:    true,
		Secure:    true,
		RunAtLoad: true,
		Path:      filepath.Join(home, "owner.plist"),
		Label:     SharedDaemonLaunchAgentLabel,
	}
	events := make([]string, 0, 4)
	hooks := independentModeReconcileHooks(t, &owner, false, &events)
	socketChecks := 0
	hooks.socketAccepts = func(string) bool {
		socketChecks++
		return true
	}

	outcome, err := reconcileRunningSharedDaemonForIndependentModeWithHooks(
		context.Background(),
		options,
		func() error { return nil },
		hooks,
	)
	if err == nil || !strings.Contains(err.Error(), "重新出现") || outcome != "" {
		t.Fatalf("socket 在 wait 后重现时必须拒绝 bootout：outcome=%s err=%v", outcome, err)
	}
	if socketChecks < 2 {
		t.Fatalf("停止前后都必须复核 socket：checks=%d", socketChecks)
	}
	if strings.Contains(strings.Join(events, ","), "bootout") {
		t.Fatalf("socket 重现后不得 bootout：%v", events)
	}
}

func TestIndependentModeReconcileWaitsForCodexDesktopExit(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	options := LocalDaemonOptions{Env: map[string]string{"CODEX_HOME": filepath.Join(home, ".codex")}}
	owner := SharedDaemonOwnerStatus{
		Installed: true,
		Loaded:    true,
		Secure:    true,
		RunAtLoad: true,
		Path:      filepath.Join(home, "owner.plist"),
		Label:     SharedDaemonLaunchAgentLabel,
	}
	events := make([]string, 0, 4)
	hooks := independentModeReconcileHooks(t, &owner, true, &events)

	outcome, err := reconcileRunningSharedDaemonForIndependentModeWithHooks(
		context.Background(),
		options,
		func() error { return nil },
		hooks,
	)
	if err != nil {
		t.Fatal(err)
	}
	if outcome != SharedDaemonReconcilePendingDesktopExit {
		t.Fatalf("Desktop 仍在运行时只能上报待处理状态：%s", outcome)
	}
	// Desktop 还连着这个 daemon，停止会打断它正在跑的会话；此时一个字节都不能改。
	if len(events) != 0 {
		t.Fatalf("Desktop 仍在运行时不得产生任何副作用：%v", events)
	}
	if !owner.RunAtLoad || !owner.Loaded || !owner.Installed {
		t.Fatalf("Desktop 仍在运行时不得改动 owner：%+v", owner)
	}
}

func TestIndependentModeReconcileLeavesForeignDaemonUntouched(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	options := LocalDaemonOptions{Env: map[string]string{"CODEX_HOME": filepath.Join(home, ".codex")}}
	// Codex Desktop 自己拉起的 app-server 监听同一个 well-known socket，但没有
	// 已加载的 Mimi LaunchAgent 作为归属证据。
	owner := SharedDaemonOwnerStatus{Loaded: false, Label: SharedDaemonLaunchAgentLabel}
	events := make([]string, 0, 4)
	hooks := independentModeReconcileHooks(t, &owner, false, &events)
	hooks.desktopRunning = func(context.Context) (bool, error) {
		t.Fatal("归属无法确认时不应继续探测 Desktop 状态")
		return false, nil
	}

	outcome, err := reconcileRunningSharedDaemonForIndependentModeWithHooks(
		context.Background(),
		options,
		func() error { return nil },
		hooks,
	)
	if err != nil {
		t.Fatal(err)
	}
	if outcome != SharedDaemonReconcileForeign {
		t.Fatalf("外部 daemon 必须原样保留：%s", outcome)
	}
	if len(events) != 0 {
		t.Fatalf("外部 daemon 不得产生任何副作用：%v", events)
	}
}

func TestIndependentModeReconcileNoopWithoutListener(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	options := LocalDaemonOptions{Env: map[string]string{"CODEX_HOME": filepath.Join(home, ".codex")}}
	owner := SharedDaemonOwnerStatus{
		Installed: true,
		Loaded:    true,
		Secure:    true,
		Label:     SharedDaemonLaunchAgentLabel,
	}
	events := make([]string, 0, 4)
	hooks := independentModeReconcileHooks(t, &owner, false, &events)
	hooks.socketAccepts = func(string) bool { return false }

	outcome, err := reconcileRunningSharedDaemonForIndependentModeWithHooks(
		context.Background(),
		options,
		func() error { return nil },
		hooks,
	)
	if err != nil {
		t.Fatal(err)
	}
	if outcome != SharedDaemonReconcileNoop {
		t.Fatalf("没有 listener 时无需停止任何进程：%s", outcome)
	}
	if len(events) != 0 {
		t.Fatalf("没有 listener 时不得产生副作用：%v", events)
	}
}

func TestIndependentModeReconcileTreatsInsecureLeftoverOwnerAsForeign(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	options := LocalDaemonOptions{Env: map[string]string{"CODEX_HOME": filepath.Join(home, ".codex")}}
	// 可被其他用户改写的 plist 不构成 Mimi owner 证据；此时既不停止进程，
	// 也不改动 owner，把现场原样留给显式的关闭事务去处理。
	owner := SharedDaemonOwnerStatus{
		Installed: true,
		Loaded:    true,
		Secure:    false,
		RunAtLoad: true,
		Label:     SharedDaemonLaunchAgentLabel,
	}
	events := make([]string, 0, 4)
	hooks := independentModeReconcileHooks(t, &owner, false, &events)

	outcome, err := reconcileRunningSharedDaemonForIndependentModeWithHooks(
		context.Background(),
		options,
		func() error { return nil },
		hooks,
	)
	if err != nil {
		t.Fatal(err)
	}
	if outcome != SharedDaemonReconcileForeign {
		t.Fatalf("权限不安全的残留 owner 不得被当成可停止的 Mimi daemon：%s", outcome)
	}
	if len(events) != 0 {
		t.Fatalf("拒绝停止时不得产生副作用：%v", events)
	}
	if !owner.RunAtLoad || !owner.Loaded || !owner.Installed {
		t.Fatalf("拒绝停止时不得改动 owner：%+v", owner)
	}
}

func TestIndependentModeReconcileWarnsWhenListenerOwnershipCannotBeConfirmed(t *testing.T) {
	home := sharedDaemonTestHome(t)
	t.Setenv("HOME", home)
	options := LocalDaemonOptions{Env: map[string]string{"CODEX_HOME": filepath.Join(home, ".codex")}}
	// 真实回归场景：Mimi 的 LaunchAgent 仍 loaded，但占着 well-known socket 的
	// 是 Codex Desktop 自己拉起的 app-server。入口归属不能被当成 listener 归属，
	// 否则会因为一个外部进程把 Mimi 的 owner 降级。
	owner := SharedDaemonOwnerStatus{
		Installed: true,
		Loaded:    true,
		Secure:    true,
		RunAtLoad: true,
		Path:      filepath.Join(home, "owner.plist"),
		Label:     SharedDaemonLaunchAgentLabel,
	}
	events := make([]string, 0, 4)
	hooks := independentModeReconcileHooks(t, &owner, false, &events)
	hooks.validateListenerOwnership = func(context.Context, LocalDaemonOptions, string) error {
		return errors.New("listener lacks signed node supervisor parent chain")
	}

	outcome, err := reconcileRunningSharedDaemonForIndependentModeWithHooks(
		context.Background(),
		options,
		func() error { return nil },
		hooks,
	)
	if err == nil || !strings.Contains(err.Error(), "无法确认") || outcome != "" {
		t.Fatalf("listener 归属无法证明时必须保留现场并返回可诊断错误：outcome=%s err=%v", outcome, err)
	}
	if len(events) != 0 {
		t.Fatalf("listener 归属无法证明时不得产生副作用：%v", events)
	}
	if !owner.RunAtLoad || owner.MigrationRequired {
		t.Fatalf("绝不能因为外部 listener 把 Mimi owner 降为 manual：%+v", owner)
	}
}

func TestStopLegacyPIDBackendWithoutReportedPIDUsesStrictFallback(t *testing.T) {
	backend := "pid"
	lifecycle := LocalDaemonLifecycleStatus{Backend: &backend}
	owner := SharedDaemonOwnerStatus{
		Installed: true,
		Loaded:    true,
		Secure:    true,
		Label:     SharedDaemonLaunchAgentLabel,
	}
	signalCalls := 0
	validateCalls := 0
	listener := sharedDaemonListenerProcess{PID: 4321}
	handled, err := stopLegacyPIDBackendWithoutReportedPID(
		context.Background(),
		LocalDaemonOptions{},
		owner,
		lifecycle,
		func(context.Context, LocalDaemonOptions, LocalDaemonLifecycleStatus) (sharedDaemonListenerProcess, error) {
			validateCalls++
			return listener, nil
		},
		func(pid int) error {
			signalCalls++
			if pid != listener.PID {
				t.Fatalf("优雅排空目标 PID 错误：%d", pid)
			}
			return nil
		},
	)
	if err != nil || !handled || validateCalls != 1 || signalCalls != 1 {
		t.Fatalf("旧 pid backend 应严格取证后只发送一次 SIGHUP：handled=%t validate=%d signal=%d err=%v", handled, validateCalls, signalCalls, err)
	}

	owner.Loaded = false
	handled, err = stopLegacyPIDBackendWithoutReportedPID(
		context.Background(),
		LocalDaemonOptions{},
		owner,
		lifecycle,
		func(context.Context, LocalDaemonOptions, LocalDaemonLifecycleStatus) (sharedDaemonListenerProcess, error) {
			validateCalls++
			return listener, nil
		},
		func(int) error {
			signalCalls++
			return nil
		},
	)
	if !handled || err == nil || validateCalls != 1 || signalCalls != 1 {
		t.Fatalf("缺少 stable owner 时必须 fail closed：handled=%t validate=%d signal=%d err=%v", handled, validateCalls, signalCalls, err)
	}
}

func TestStopLegacyPIDBackendWithoutReportedPIDRejectsUnsafeSignalPID(t *testing.T) {
	backend := "pid"
	lifecycle := LocalDaemonLifecycleStatus{Backend: &backend}
	owner := SharedDaemonOwnerStatus{
		Installed: true,
		Loaded:    true,
		Secure:    true,
		Label:     SharedDaemonLaunchAgentLabel,
	}
	signalCalls := 0

	handled, err := stopLegacyPIDBackendWithoutReportedPID(
		context.Background(),
		LocalDaemonOptions{},
		owner,
		lifecycle,
		func(context.Context, LocalDaemonOptions, LocalDaemonLifecycleStatus) (sharedDaemonListenerProcess, error) {
			return sharedDaemonListenerProcess{PID: 1}, nil
		},
		func(int) error {
			signalCalls++
			return nil
		},
	)
	if !handled || err == nil || signalCalls != 0 {
		t.Fatalf("旧 pid backend 必须在发信号前拒绝 PID 1：handled=%t signal=%d err=%v", handled, signalCalls, err)
	}
}

func TestStopLegacyPIDBackendWithoutReportedPIDRejectsFinalDesktopSwap(t *testing.T) {
	backend := "pid"
	lifecycle := LocalDaemonLifecycleStatus{Backend: &backend}
	owner := SharedDaemonOwnerStatus{
		Installed: true,
		Loaded:    true,
		Secure:    true,
		Label:     SharedDaemonLaunchAgentLabel,
	}
	first := sharedDaemonListenerProcess{PID: 4321, UID: 501, StartSec: 10}
	replacement := first
	replacement.PID++
	replacement.StartSec++
	signalCalls := 0

	handled, err := stopLegacyPIDBackendWithoutReportedPID(
		context.Background(),
		LocalDaemonOptions{},
		owner,
		lifecycle,
		func(ctx context.Context, _ LocalDaemonOptions, _ LocalDaemonLifecycleStatus) (sharedDaemonListenerProcess, error) {
			return rebindSharedDaemonListenerAfterDesktop(
				ctx,
				"/tmp/app.sock",
				first,
				func(context.Context, string) (sharedDaemonListenerProcess, error) {
					return replacement, nil
				},
			)
		},
		func(int) error {
			signalCalls++
			return nil
		},
	)
	if !handled || err == nil || !strings.Contains(err.Error(), "Desktop 复核后") || signalCalls != 0 {
		t.Fatalf("旧 pid backend 在最终 Desktop 探测期间换主时不得发送 SIGHUP：handled=%t signal=%d err=%v", handled, signalCalls, err)
	}
}

func TestStopLegacyPIDBackendWithoutReportedPIDRejectsABASwapAroundSignedIdentity(t *testing.T) {
	backend := "pid"
	lifecycle := LocalDaemonLifecycleStatus{Backend: &backend}
	owner := SharedDaemonOwnerStatus{
		Installed: true,
		Loaded:    true,
		Secure:    true,
		Label:     SharedDaemonLaunchAgentLabel,
	}
	a := sharedDaemonListenerProcess{
		PID:        101,
		ParentPID:  201,
		UID:        os.Getuid(),
		StartSec:   301,
		Executable: "/private/tmp/a/codex",
	}
	b := a
	b.PID = 102
	b.ParentPID = 202
	b.Executable = "/private/tmp/b/codex"
	captureCalls := 0
	inspectCalls := 0
	signalCalls := 0

	handled, err := stopLegacyPIDBackendWithoutReportedPID(
		context.Background(),
		LocalDaemonOptions{},
		owner,
		lifecycle,
		func(ctx context.Context, options LocalDaemonOptions, _ LocalDaemonLifecycleStatus) (sharedDaemonListenerProcess, error) {
			return captureStableSignedSharedDaemonListenerIdentity(
				ctx,
				options,
				"/tmp/app.sock",
				func(context.Context, LocalDaemonOptions, string) (sharedDaemonListenerProcess, error) {
					captureCalls++
					// 验签函数只认可 A；模拟 socket 在它前后都由未验签 B 占用，
					// 中间短暂切回 A 完成验签的 ABA 序列。
					return a, nil
				},
				func(context.Context, string) (sharedDaemonListenerProcess, error) {
					inspectCalls++
					return b, nil
				},
			)
		},
		func(int) error {
			signalCalls++
			return nil
		},
	)
	if !handled || err == nil || !strings.Contains(err.Error(), "socket owner 与已验签 listener 身份不一致") {
		t.Fatalf("ABA 换主时必须 fail closed：handled=%t err=%v", handled, err)
	}
	if captureCalls != 1 || inspectCalls != 2 || signalCalls != 0 {
		t.Fatalf("ABA 换主后不得发送信号：capture=%d inspect=%d signal=%d", captureCalls, inspectCalls, signalCalls)
	}
}

func TestCaptureStableSignedSharedDaemonListenerIdentityReturnsBoundIdentity(t *testing.T) {
	expected := sharedDaemonListenerProcess{
		PID:        101,
		ParentPID:  201,
		UID:        os.Getuid(),
		StartSec:   301,
		Executable: "/private/tmp/staged/codex",
	}
	inspectCalls := 0
	got, err := captureStableSignedSharedDaemonListenerIdentity(
		context.Background(),
		LocalDaemonOptions{},
		"/tmp/app.sock",
		func(context.Context, LocalDaemonOptions, string) (sharedDaemonListenerProcess, error) {
			return expected, nil
		},
		func(context.Context, string) (sharedDaemonListenerProcess, error) {
			inspectCalls++
			return expected, nil
		},
	)
	if err != nil || got != expected || inspectCalls != 2 {
		t.Fatalf("稳定且已验签的 listener 应返回同一 identity：got=%+v inspect=%d err=%v", got, inspectCalls, err)
	}
}

func TestCaptureStableManagedSharedDaemonListenerIdentityRejectsABASwap(t *testing.T) {
	a := sharedDaemonListenerProcess{
		PID:        101,
		ParentPID:  201,
		UID:        os.Getuid(),
		StartSec:   301,
		Executable: "/private/tmp/a/codex",
	}
	b := a
	b.PID = 102
	b.ParentPID = 202
	b.Executable = "/private/tmp/b/codex"
	pid := uint32(b.PID)
	lifecycle := LocalDaemonLifecycleStatus{PID: &pid}
	expected := b
	inspectCalls := 0

	_, err := captureStableManagedSharedDaemonListenerIdentity(
		context.Background(),
		LocalDaemonOptions{},
		"/tmp/app.sock",
		lifecycle,
		&expected,
		func(context.Context, LocalDaemonOptions, string) (sharedDaemonListenerProcess, error) {
			// 正常 pid backend 过去只保留外层 inspect 到的 B，丢弃这里验签的 A。
			return a, nil
		},
		func(context.Context, string) (sharedDaemonListenerProcess, error) {
			inspectCalls++
			return b, nil
		},
	)
	if err == nil || !strings.Contains(err.Error(), "socket owner 与已验签 listener 身份不一致") {
		t.Fatalf("正常 pid backend 的 B→A→B 换主必须 fail closed：%v", err)
	}
	if inspectCalls != 2 {
		t.Fatalf("必须在验签前后绑定 socket owner：inspect=%d", inspectCalls)
	}
}

func TestValidateManagedSharedDaemonListenerIdentity(t *testing.T) {
	pid := uint32(4321)
	lifecycle := LocalDaemonLifecycleStatus{PID: &pid}
	expected := sharedDaemonListenerProcess{PID: 4321, UID: os.Getuid(), StartSec: 99}
	if err := validateManagedSharedDaemonListenerIdentity(lifecycle, expected, expected); err != nil {
		t.Fatalf("一致的 pid listener 身份应通过：%v", err)
	}

	withoutPID := lifecycle
	withoutPID.PID = nil
	if err := validateManagedSharedDaemonListenerIdentity(withoutPID, expected, expected); err == nil {
		t.Fatal("官方 backend 未报告 PID 时必须 fail closed")
	}

	otherPID := uint32(9876)
	wrongLifecycle := lifecycle
	wrongLifecycle.PID = &otherPID
	if err := validateManagedSharedDaemonListenerIdentity(wrongLifecycle, expected, expected); err == nil {
		t.Fatal("lifecycle PID 与 listener 不一致时必须 fail closed")
	}

	replaced := expected
	replaced.StartSec++
	if err := validateManagedSharedDaemonListenerIdentity(lifecycle, expected, replaced); err == nil {
		t.Fatal("listener 启动身份变化时必须 fail closed")
	}
}
