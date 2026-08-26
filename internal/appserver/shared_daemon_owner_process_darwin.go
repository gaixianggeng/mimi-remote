//go:build darwin

package appserver

import (
	"bytes"
	"context"
	"encoding/binary"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"

	"golang.org/x/sys/unix"
)

// 本文件只负责从真实 Unix socket peer 取证外部 listener，并在 UID、路径、
// argv、启动时间与 Desktop 状态全部匹配时发送一次 graceful-only SIGHUP。owner 的安装、
// 两阶段迁移与 launchctl 编排仍保留在 shared_daemon_owner_darwin.go。

func stopUnmanagedSharedDaemon(
	ctx context.Context,
	options LocalDaemonOptions,
	lifecycle LocalDaemonLifecycleStatus,
) error {
	return stopUnmanagedSharedDaemonWithLifecycleIdentity(ctx, options, lifecycle, nil)
}

func stopUnmanagedSharedDaemonWithLifecycleIdentity(
	ctx context.Context,
	options LocalDaemonOptions,
	lifecycle LocalDaemonLifecycleStatus,
	expectedIdentity *sharedDaemonListenerProcess,
) error {
	socketPath, err := LocalDaemonSocketPath(options.Env)
	if err != nil {
		return err
	}
	probeCtx, cancelProbe := context.WithTimeout(ctx, localDaemonProbeTimeout)
	probe, err := ProbeLocalDaemonInfo(probeCtx, socketPath)
	cancelProbe()
	if err != nil {
		return fmt.Errorf("无法确认待接管的 Codex app-server：%w", err)
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

	return stopUnmanagedSharedDaemonWithExpectedIdentity(
		ctx,
		socketPath,
		lifecycle.ManagedCodexPath,
		expectedIdentity,
		unmanagedSharedDaemonHooks{
			desktopRunning: sharedDaemonDesktopRunning,
			inspect:        inspectSharedDaemonListenerProcess,
			requireIdle:    sharedDaemonRequireIdle,
			signalGraceful: sharedDaemonSignalGraceful,
			currentUID:     os.Getuid,
		},
	)
}

func stopUnmanagedSharedDaemonWithHooks(
	ctx context.Context,
	socketPath string,
	managedCodexPath string,
	hooks unmanagedSharedDaemonHooks,
) error {
	return stopUnmanagedSharedDaemonWithExpectedPath(
		ctx,
		socketPath,
		managedCodexPath,
		hooks,
	)
}

// stopUnmanagedSharedDaemonWithExpectedPath 执行严格的 listener 身份确认。
// 旧式 unmanaged SSH listener 由上层传入 lifecycle.ManagedCodexPath；只有
// 调用方已经完成 Mimi stable owner 与签名 supervisor 父链验证时，才允许传入
// 配置解析后的 CodexBin 路径。路径来源不在这里推断，避免把任意 listener
// executable 放宽成可停止对象。
func stopUnmanagedSharedDaemonWithExpectedPath(
	ctx context.Context,
	socketPath string,
	expectedCodexPath string,
	hooks unmanagedSharedDaemonHooks,
) error {
	return stopUnmanagedSharedDaemonWithExpectedIdentity(
		ctx,
		socketPath,
		expectedCodexPath,
		nil,
		hooks,
	)
}

// stopUnmanagedSharedDaemonWithExpectedIdentity 在发送 SIGHUP 前把当前 socket
// owner 与上层已经完成签名父链验证的 identity 绑定。expectedIdentity 为空时
// 表示旧式 unmanaged SSH listener，仍只按 lifecycle.ManagedCodexPath 校验；
// 非空时表示 stable owner 已完成动态签名与 supervisor 父链验证，因此允许
// executable 位于一次性 staging 目录，但仍严格绑定原始 argv 和完整进程身份。
func stopUnmanagedSharedDaemonWithExpectedIdentity(
	ctx context.Context,
	socketPath string,
	expectedCodexPath string,
	expectedIdentity *sharedDaemonListenerProcess,
	hooks unmanagedSharedDaemonHooks,
) error {
	listener, err := validateUnmanagedSharedDaemonWithExpectedIdentity(
		ctx,
		socketPath,
		expectedCodexPath,
		expectedIdentity,
		hooks,
	)
	if err != nil {
		return err
	}
	if hooks.requireIdle != nil {
		if err := hooks.requireIdle(ctx, socketPath); err != nil {
			return fmt.Errorf("停止非 daemon 管理的 Codex app-server 前活动检查失败：%w", err)
		}
		confirmed, validateErr := validateUnmanagedSharedDaemonWithExpectedIdentity(
			ctx,
			socketPath,
			expectedCodexPath,
			expectedIdentity,
			hooks,
		)
		if validateErr != nil {
			return validateErr
		}
		// 首轮取证完成后绑定同一完整进程身份。即使旧式 SSH listener
		// 没有上层 expected，活动检查期间替换进来的进程也不能收到信号。
		if confirmed != listener {
			return fmt.Errorf("Codex app-server owner 与活动检查前身份不一致，已停止迁移")
		}
		listener = confirmed
	}
	// validate 的最后一步是 Desktop 进程枚举。它也会产生调度窗口，必须在
	// 其后再从真实 socket 绑定一次 owner，避免向退出或被替换的旧 PID 发信号。
	finalListener, err := rebindSharedDaemonListenerAfterDesktop(
		ctx,
		socketPath,
		listener,
		hooks.inspect,
	)
	if err != nil {
		return fmt.Errorf("信号前最终确认 Codex app-server owner 失败：%w", err)
	}
	listener = finalListener
	if err := validateSharedDaemonSignalTargetPID(listener.PID); err != nil {
		return err
	}
	if hooks.signalGraceful == nil {
		return fmt.Errorf("停止非 daemon 管理的 Codex app-server 缺少优雅排空实现")
	}
	if err := hooks.signalGraceful(listener.PID); err != nil {
		return fmt.Errorf("请求旧 Codex app-server 优雅排空失败：%w", err)
	}
	return nil
}

// validateUnmanagedSharedDaemonWithExpectedIdentity 只完成最终 listener 取证，
// 不执行停止动作。旧 pid backend 和普通 unmanaged 路径都由上层对返回的
// 同一 PID 发送一次 SIGHUP。
func validateUnmanagedSharedDaemonWithExpectedIdentity(
	ctx context.Context,
	socketPath string,
	expectedCodexPath string,
	expectedIdentity *sharedDaemonListenerProcess,
	hooks unmanagedSharedDaemonHooks,
) (sharedDaemonListenerProcess, error) {
	running, err := hooks.desktopRunning(ctx)
	if err != nil {
		return sharedDaemonListenerProcess{}, fmt.Errorf("确认 Codex Desktop 已退出失败：%w", err)
	}
	if running {
		return sharedDaemonListenerProcess{}, fmt.Errorf("Codex Desktop 仍在运行，拒绝接管非 daemon 管理的 app-server")
	}

	listener, err := hooks.inspect(ctx, socketPath)
	if err != nil {
		return sharedDaemonListenerProcess{}, fmt.Errorf("识别非 daemon 管理的 Codex app-server 失败：%w", err)
	}
	if expectedIdentity != nil && listener != *expectedIdentity {
		return sharedDaemonListenerProcess{}, fmt.Errorf("Codex app-server owner 与已验证身份不一致，已停止迁移")
	}
	if expectedIdentity == nil {
		if err := validateSharedDaemonListenerProcess(listener, hooks.currentUID(), expectedCodexPath); err != nil {
			return sharedDaemonListenerProcess{}, err
		}
	} else {
		// 上层已经按 PID 验证 OpenAI 动态签名和 node supervisor 父链。这里不能
		// 再把真实 executable 与 Desktop bundle 路径比较，因为 MIM-170 会从
		// 只读临时 clone 执行 codex；改为复核原始 argv、UID 和同一完整 identity。
		if strings.TrimSpace(listener.Executable) == "" {
			return sharedDaemonListenerProcess{}, fmt.Errorf("已验证的共享 daemon listener 缺少 executable 身份")
		}
		if err := validateSignedSharedDaemonListenerProcess(
			listener,
			hooks.currentUID(),
			expectedCodexPath,
		); err != nil {
			return sharedDaemonListenerProcess{}, fmt.Errorf("已验证的共享 daemon listener 身份无效：%w", err)
		}
	}
	// PID 可能在检查命令行期间退出并被复用。发送信号前再次从 socket
	// 反查 owner；PID、UID、命令与可执行文件任一变化都停止迁移。
	confirmed, err := hooks.inspect(ctx, socketPath)
	if err != nil {
		return sharedDaemonListenerProcess{}, fmt.Errorf("再次确认 Codex app-server owner 失败：%w", err)
	}
	if confirmed != listener {
		return sharedDaemonListenerProcess{}, fmt.Errorf("Codex app-server owner 在接管前发生变化，已停止迁移")
	}
	// 用户可能在首次检查后从 Dock 重新打开 Desktop。读取失败也 fail closed。
	// 调用方会在这次进程枚举后再次绑定真实 socket owner，再发送信号。
	running, err = hooks.desktopRunning(ctx)
	if err != nil {
		return sharedDaemonListenerProcess{}, fmt.Errorf("信号前再次确认 Codex Desktop 已退出失败：%w", err)
	}
	if running {
		return sharedDaemonListenerProcess{}, fmt.Errorf("Codex Desktop 在迁移前被重新打开，已停止接管")
	}
	return listener, nil
}

func validateSharedDaemonListenerProcess(
	process sharedDaemonListenerProcess,
	currentUID int,
	managedCodexPath string,
) error {
	if process.PID <= 1 {
		return fmt.Errorf("Codex app-server socket owner PID 无效")
	}
	if process.UID != currentUID {
		return fmt.Errorf("Codex app-server socket owner 不属于当前用户，拒绝接管")
	}
	if strings.TrimSpace(process.Executable) == "" ||
		!sameCanonicalPath(process.Executable, managedCodexPath) {
		return fmt.Errorf("Codex app-server socket owner 不是官方 managed standalone，拒绝接管")
	}
	if !isDirectUnixAppServerCommand(process.Command) {
		return fmt.Errorf("Codex app-server socket owner 命令行不符合原生 SSH 启动模式，拒绝接管")
	}
	return nil
}

func isDirectUnixAppServerCommand(command string) bool {
	var fields []string
	if strings.Contains(command, "\x00") {
		for _, field := range strings.Split(command, "\x00") {
			if field != "" {
				fields = append(fields, field)
			}
		}
	} else {
		fields = strings.Fields(strings.TrimSpace(command))
	}
	if len(fields) < 3 {
		return false
	}
	appServerIndex := -1
	for index, field := range fields {
		if field == "app-server" {
			appServerIndex = index
			break
		}
	}
	if appServerIndex < 0 {
		return false
	}
	// `app-server daemon ...` 与 `app-server proxy ...` 都是另一种官方
	// 责任链，不能当成 SSH bootstrap 的直接 listener 接管。
	for _, field := range fields[appServerIndex+1:] {
		if field == "daemon" || field == "proxy" {
			return false
		}
	}
	for index := appServerIndex + 1; index < len(fields); index++ {
		switch {
		case fields[index] == "--listen" && index+1 < len(fields):
			return fields[index+1] == "unix://"
		case strings.HasPrefix(fields[index], "--listen="):
			return strings.TrimPrefix(fields[index], "--listen=") == "unix://"
		}
	}
	return false
}

func codexDesktopProcessRunning(ctx context.Context) (bool, error) {
	// Desktop 的当前 App 名与可执行文件名是 ChatGPT，历史名称却是
	// Codex。进程名不是稳定契约；LaunchServices bundle id 与 Swift 端
	// NSWorkspace 的识别方式一致，也能覆盖同 bundle 的多个实例。
	cmd := exec.CommandContext(ctx, "/usr/bin/lsappinfo", "find", "bundleid="+codexDesktopBundleID)
	configureManagedCommand(cmd)
	output, err := cmd.Output()
	if err != nil {
		return false, err
	}
	return strings.TrimSpace(string(output)) != "", nil
}

func inspectSharedDaemonListenerProcess(
	ctx context.Context,
	socketPath string,
) (sharedDaemonListenerProcess, error) {
	pid, peerUID, err := sharedDaemonSocketPeer(ctx, socketPath)
	if err != nil {
		return sharedDaemonListenerProcess{}, err
	}
	return inspectSharedDaemonProcessIdentity(pid, peerUID)
}

func inspectSharedDaemonProcessIdentity(pid int, expectedUID int) (sharedDaemonListenerProcess, error) {
	kinfo, err := unix.SysctlKinfoProc("kern.proc.pid", pid)
	if err != nil || int(kinfo.Proc.P_pid) != pid {
		return sharedDaemonListenerProcess{}, fmt.Errorf("读取共享 daemon 进程身份失败")
	}
	uid := int(kinfo.Eproc.Ucred.Uid)
	if uid != expectedUID {
		return sharedDaemonListenerProcess{}, fmt.Errorf("共享 daemon 进程 UID 与预期不一致")
	}
	executable, arguments, err := sharedDaemonProcessArguments(pid)
	if err != nil {
		return sharedDaemonListenerProcess{}, err
	}
	return sharedDaemonListenerProcess{
		PID:        pid,
		ParentPID:  int(kinfo.Eproc.Ppid),
		UID:        uid,
		StartSec:   kinfo.Proc.P_starttime.Sec,
		StartUsec:  kinfo.Proc.P_starttime.Usec,
		Command:    strings.Join(arguments, "\x00"),
		Executable: executable,
	}, nil
}

func sharedDaemonSocketPeer(ctx context.Context, socketPath string) (int, int, error) {
	dialer := net.Dialer{Timeout: localDaemonProbeTimeout}
	conn, err := dialer.DialContext(ctx, "unix", socketPath)
	if err != nil {
		return 0, 0, fmt.Errorf("连接 Codex app-server socket 失败：%w", err)
	}
	defer conn.Close()
	unixConn, ok := conn.(*net.UnixConn)
	if !ok {
		return 0, 0, fmt.Errorf("Codex app-server socket 不是 UnixConn")
	}
	raw, err := unixConn.SyscallConn()
	if err != nil {
		return 0, 0, fmt.Errorf("读取 Codex app-server socket fd 失败：%w", err)
	}
	var peerPID int
	var peerUID int
	var controlErr error
	if err := raw.Control(func(fd uintptr) {
		peerPID, controlErr = unix.GetsockoptInt(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERPID)
		if controlErr != nil {
			return
		}
		credentials, credentialsErr := unix.GetsockoptXucred(
			int(fd),
			unix.SOL_LOCAL,
			unix.LOCAL_PEERCRED,
		)
		if credentialsErr != nil {
			controlErr = credentialsErr
			return
		}
		peerUID = int(credentials.Uid)
	}); err != nil {
		return 0, 0, fmt.Errorf("读取 Codex app-server socket peer 失败：%w", err)
	}
	if controlErr != nil {
		return 0, 0, fmt.Errorf("读取 Codex app-server socket peer 身份失败：%w", controlErr)
	}
	if peerPID <= 1 || peerUID < 0 {
		return 0, 0, fmt.Errorf("Codex app-server socket peer 身份无效")
	}
	return peerPID, peerUID, nil
}

func sharedDaemonProcessArguments(pid int) (string, []string, error) {
	raw, err := unix.SysctlRaw("kern.procargs2", pid)
	if err != nil {
		return "", nil, fmt.Errorf("读取 socket owner 进程参数失败：%w", err)
	}
	if len(raw) < 5 {
		return "", nil, fmt.Errorf("socket owner 进程参数过短")
	}
	argc := int(binary.LittleEndian.Uint32(raw[:4]))
	if argc <= 0 || argc > 4096 {
		return "", nil, fmt.Errorf("socket owner argc 无效")
	}
	cursor := raw[4:]
	executableEnd := bytes.IndexByte(cursor, 0)
	if executableEnd <= 0 {
		return "", nil, fmt.Errorf("socket owner 缺少 executable path")
	}
	executable := string(cursor[:executableEnd])
	if !filepath.IsAbs(executable) {
		return "", nil, fmt.Errorf("socket owner executable path 不是绝对路径")
	}
	cursor = cursor[executableEnd+1:]
	for len(cursor) > 0 && cursor[0] == 0 {
		cursor = cursor[1:]
	}
	arguments := make([]string, 0, argc)
	for len(arguments) < argc {
		argumentEnd := bytes.IndexByte(cursor, 0)
		if argumentEnd < 0 {
			return "", nil, fmt.Errorf("socket owner argv 未完整终止")
		}
		arguments = append(arguments, string(cursor[:argumentEnd]))
		cursor = cursor[argumentEnd+1:]
	}
	return executable, arguments, nil
}

func validatePrivateSharedDaemonSocket(socketPath string, currentUID int) error {
	info, err := os.Lstat(socketPath)
	if err != nil {
		return fmt.Errorf("检查 Codex app-server socket 失败：%w", err)
	}
	if info.Mode()&os.ModeSocket == 0 {
		return fmt.Errorf("Codex app-server 路径不是 Unix socket")
	}
	if info.Mode().Perm() != 0o600 {
		return fmt.Errorf("Codex app-server socket 权限不是 0600，拒绝接管")
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || int(stat.Uid) != currentUID {
		return fmt.Errorf("Codex app-server socket 不属于当前用户，拒绝接管")
	}
	return nil
}

func signalSharedDaemonProcessGraceful(pid int) error {
	if err := validateSharedDaemonSignalTargetPID(pid); err != nil {
		return err
	}
	process, err := os.FindProcess(pid)
	if err != nil {
		return err
	}
	return process.Signal(syscall.SIGHUP)
}

func validateSharedDaemonSignalTargetPID(pid int) error {
	if pid <= 1 {
		return fmt.Errorf("Codex app-server listener PID %d 不可作为信号目标", pid)
	}
	return nil
}

func rebindSharedDaemonListenerAfterDesktop(
	ctx context.Context,
	socketPath string,
	expected sharedDaemonListenerProcess,
	inspect sharedDaemonListenerInspectFunc,
) (sharedDaemonListenerProcess, error) {
	if inspect == nil {
		return sharedDaemonListenerProcess{}, fmt.Errorf("缺少最终 listener 取证实现")
	}
	listener, err := inspect(ctx, socketPath)
	if err != nil {
		return sharedDaemonListenerProcess{}, err
	}
	if listener != expected {
		return sharedDaemonListenerProcess{}, fmt.Errorf("Codex app-server owner 在 Desktop 复核后发生变化")
	}
	return listener, nil
}
