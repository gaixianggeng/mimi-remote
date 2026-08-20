//go:build darwin

package appserver

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

func TestSharedDaemonProcessIdentityStillAliveHandlesDarwinExitEIO(t *testing.T) {
	previousKinfo := sharedDaemonStoppedKinfoProc
	previousSignalZero := sharedDaemonSignalZero
	t.Cleanup(func() {
		sharedDaemonStoppedKinfoProc = previousKinfo
		sharedDaemonSignalZero = previousSignalZero
	})
	sharedDaemonStoppedKinfoProc = func(string, ...int) (*unix.KinfoProc, error) {
		return nil, unix.EIO
	}
	identity := sharedDaemonListenerProcess{PID: 4242, UID: os.Getuid()}

	sharedDaemonSignalZero = func(int) error { return unix.ESRCH }
	alive, err := sharedDaemonProcessIdentityStillAlive(identity)
	if err != nil || alive {
		t.Fatalf("kinfo=EIO 且 signal0=ESRCH 应确认旧 PID 已退出：alive=%t err=%v", alive, err)
	}

	sharedDaemonSignalZero = func(int) error { return nil }
	if alive, err := sharedDaemonProcessIdentityStillAlive(identity); err != nil || !alive {
		t.Fatalf("kinfo=EIO 但 PID 仍存在时应继续等待：alive=%t err=%v", alive, err)
	}
}

func TestWaitForSharedDaemonStoppedRetriesTransientDarwinExitEIO(t *testing.T) {
	previousKinfo := sharedDaemonStoppedKinfoProc
	previousSignalZero := sharedDaemonSignalZero
	t.Cleanup(func() {
		sharedDaemonStoppedKinfoProc = previousKinfo
		sharedDaemonSignalZero = previousSignalZero
	})

	kinfoCalls := 0
	sharedDaemonStoppedKinfoProc = func(string, ...int) (*unix.KinfoProc, error) {
		kinfoCalls++
		if kinfoCalls == 1 {
			return nil, unix.EIO
		}
		return nil, unix.ESRCH
	}
	sharedDaemonSignalZero = func(int) error { return nil }

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	identity := sharedDaemonListenerProcess{PID: 4242, UID: os.Getuid()}
	if err := waitForSharedDaemonStopped(ctx, filepath.Join(t.TempDir(), "missing.sock"), identity); err != nil {
		t.Fatalf("瞬时 EIO 后应继续轮询直到确认旧 PID 退出：%v", err)
	}
	if kinfoCalls < 2 {
		t.Fatalf("瞬时 EIO 后没有继续复核进程身份：calls=%d", kinfoCalls)
	}
}

func TestStopSharedDaemonManagedBackendChecksDesktopBeforeOfficialStop(t *testing.T) {
	home := sharedDaemonTestHome(t)
	codexHome := filepath.Join(home, ".codex")
	socketPath, err := LocalDaemonSocketPath(map[string]string{"CODEX_HOME": codexHome})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(socketPath), 0o700); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })

	stopMarker := filepath.Join(t.TempDir(), "official-stop-called")
	bin := filepath.Join(t.TempDir(), "codex")
	lifecycleJSON := fmt.Sprintf(
		`{"status":"running","backend":"pid","socketPath":%q,"appServerVersion":"0.147.0"}`,
		socketPath,
	)
	script := fmt.Sprintf(`#!/bin/sh
if [ "$3" = "version" ]; then
  printf '%%s\n' '%s'
  exit 0
fi
if [ "$3" = "stop" ]; then
  touch '%s'
  exit 0
fi
exit 2
`, lifecycleJSON, stopMarker)
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	options := LocalDaemonOptions{
		CodexBin: bin,
		Env:      map[string]string{"CODEX_HOME": codexHome},
	}
	owner := SharedDaemonOwnerStatus{
		Installed: true,
		Loaded:    true,
		Secure:    true,
	}

	tests := []struct {
		name        string
		desktop     func(context.Context) (bool, error)
		wantMessage string
	}{
		{
			name:        "desktop reopened",
			desktop:     func(context.Context) (bool, error) { return true, nil },
			wantMessage: "重新打开",
		},
		{
			name:        "desktop query failed",
			desktop:     func(context.Context) (bool, error) { return false, errors.New("query failed") },
			wantMessage: "确认 Codex Desktop 已退出失败",
		},
		{
			name: "desktop reopened before command",
			desktop: func() func(context.Context) (bool, error) {
				checks := 0
				return func(context.Context) (bool, error) {
					checks++
					return checks == 2, nil
				}
			}(),
			wantMessage: "重新打开",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_ = os.Remove(stopMarker)
			originalDesktop := sharedDaemonDesktopRunning
			sharedDaemonDesktopRunning = test.desktop
			t.Cleanup(func() { sharedDaemonDesktopRunning = originalDesktop })

			err := stopSharedDaemon(context.Background(), options, owner)
			if err == nil || !strings.Contains(err.Error(), test.wantMessage) {
				t.Fatalf("官方 stop 前必须 fail closed：%v", err)
			}
			if _, statErr := os.Stat(stopMarker); !os.IsNotExist(statErr) {
				t.Fatalf("Desktop guard 失败时不能执行官方 stop：%v", statErr)
			}
		})
	}
}

func TestWaitForSharedDaemonStoppedResetsConfirmationAfterReconnect(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "mimi-stop-flap-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	socketPath := filepath.Join(dir, "app.sock")
	ready := make(chan error, 1)
	done := make(chan struct{})
	go func() {
		defer close(done)
		// 先给 wait loop 一个短暂不可连窗口，但尚未达到
		// 500 ms 的稳定确认条件。
		time.Sleep(200 * time.Millisecond)
		listener, listenErr := net.Listen("unix", socketPath)
		ready <- listenErr
		if listenErr != nil {
			return
		}
		time.Sleep(300 * time.Millisecond)
		_ = listener.Close()
	}()

	started := time.Now()
	if err := waitForSharedDaemonStopped(context.Background(), socketPath); err != nil {
		t.Fatalf("断开抖动确认失败：%v", err)
	}
	listenErr := <-ready
	<-done
	if listenErr != nil {
		t.Fatalf("创建中途恢复 listener 失败：%v", listenErr)
	}
	// 200 ms 后重连、300 ms 后再断开，之后还必须重新
	// 等满 500 ms。如果没有重置 disconnectedSince，会在约 500 ms 时错误返回。
	if elapsed := time.Since(started); elapsed < 850*time.Millisecond {
		t.Fatalf("中途重连后必须重新计算稳定断开窗口：elapsed=%s", elapsed)
	}
}

func TestStopUnmanagedSharedDaemonRequiresDesktopStopped(t *testing.T) {
	termCalls := 0
	err := stopUnmanagedSharedDaemonWithHooks(
		context.Background(),
		"/tmp/app.sock",
		"/tmp/codex",
		unmanagedSharedDaemonHooks{
			desktopRunning: func(context.Context) (bool, error) { return true, nil },
			inspect: func(context.Context, string) (sharedDaemonListenerProcess, error) {
				t.Fatal("Desktop 运行时不应读取或终止 socket owner")
				return sharedDaemonListenerProcess{}, nil
			},
			signalTERM: func(int) error { termCalls++; return nil },
			currentUID: func() int { return 501 },
		},
	)
	if err == nil || !strings.Contains(err.Error(), "仍在运行") || termCalls != 0 {
		t.Fatalf("Desktop 未退出必须 fail closed：err=%v term=%d", err, termCalls)
	}
}

func TestStopUnmanagedSharedDaemonSignalsOneStrictlyMatchedProcess(t *testing.T) {
	process := sharedDaemonListenerProcess{
		PID:        1234,
		UID:        501,
		StartSec:   1786522048,
		StartUsec:  123,
		Command:    "codex -c features.code_mode_host=true app-server --listen unix://",
		Executable: "/tmp/codex-real",
	}
	inspectCalls := 0
	desktopChecks := 0
	var signaled []int
	err := stopUnmanagedSharedDaemonWithHooks(
		context.Background(),
		"/tmp/app.sock",
		"/tmp/codex-real",
		unmanagedSharedDaemonHooks{
			desktopRunning: func(context.Context) (bool, error) { desktopChecks++; return false, nil },
			inspect: func(context.Context, string) (sharedDaemonListenerProcess, error) {
				inspectCalls++
				return process, nil
			},
			signalTERM: func(pid int) error { signaled = append(signaled, pid); return nil },
			currentUID: func() int { return 501 },
		},
	)
	if err != nil {
		t.Fatalf("严格匹配的原生 SSH daemon 应允许一次 TERM：%v", err)
	}
	if desktopChecks != 2 || inspectCalls != 2 || len(signaled) != 1 || signaled[0] != process.PID {
		t.Fatalf("接管必须两次确认 Desktop、双重确认 PID 且只 TERM 一次：desktop=%d inspect=%d signaled=%v", desktopChecks, inspectCalls, signaled)
	}
}

func TestStopUnmanagedSharedDaemonUsesConfiguredCodexPathForSignedStableOwner(t *testing.T) {
	configured := writeFakeCodexBin(t, t.TempDir(), "configured-codex")
	configuredLink := filepath.Join(t.TempDir(), "codex-current")
	if err := os.Symlink(configured, configuredLink); err != nil {
		t.Fatal(err)
	}
	expected, err := resolveSharedDaemonCodexBin(configuredLink)
	if err != nil {
		t.Fatalf("解析配置 Codex 路径失败：%v", err)
	}
	standalone := writeFakeCodexBin(t, t.TempDir(), "standalone-codex")
	process := sharedDaemonListenerProcess{
		PID:        1234,
		ParentPID:  9876,
		UID:        os.Getuid(),
		StartSec:   1786522048,
		StartUsec:  123,
		Command:    "codex app-server --listen unix://",
		Executable: configured,
	}

	inspectCalls := 0
	desktopChecks := 0
	termCalls := 0
	// sharedDaemonValidateSignedRuntime 已在上层完成签名 node supervisor 父链
	// 验证；这里把同一完整 identity 绑定到最终 TERM helper。
	err = stopUnmanagedSharedDaemonWithExpectedIdentity(
		context.Background(),
		"/tmp/app.sock",
		expected,
		&process,
		unmanagedSharedDaemonHooks{
			desktopRunning: func(context.Context) (bool, error) {
				desktopChecks++
				return false, nil
			},
			inspect: func(context.Context, string) (sharedDaemonListenerProcess, error) {
				inspectCalls++
				return process, nil
			},
			signalTERM: func(int) error { termCalls++; return nil },
			currentUID: func() int { return os.Getuid() },
		},
	)
	if err != nil {
		t.Fatalf("签名 stable owner listener 应按 configured CodexBin 允许一次 TERM：%v", err)
	}
	if desktopChecks != 2 || inspectCalls != 2 || termCalls != 1 {
		t.Fatalf("停止必须保留 Desktop 双重检查、listener 双重确认和一次 TERM：desktop=%d inspect=%d term=%d", desktopChecks, inspectCalls, termCalls)
	}

	// 同一 listener 若按 lifecycle 的 standalone 路径判断，必须继续拒绝；
	// 这保证旧式 unmanaged SSH listener 的路径边界没有被放宽。
	termCalls = 0
	err = stopUnmanagedSharedDaemonWithHooks(
		context.Background(),
		"/tmp/app.sock",
		standalone,
		unmanagedSharedDaemonHooks{
			desktopRunning: func(context.Context) (bool, error) { return false, nil },
			inspect: func(context.Context, string) (sharedDaemonListenerProcess, error) {
				return process, nil
			},
			signalTERM: func(int) error { termCalls++; return nil },
			currentUID: func() int { return os.Getuid() },
		},
	)
	if err == nil || !strings.Contains(err.Error(), "不是官方 managed standalone") || termCalls != 0 {
		t.Fatalf("legacy unmanaged 路径必须继续要求 standalone executable：err=%v term=%d", err, termCalls)
	}
}

func TestStopUnmanagedSharedDaemonRejectsListenerChangedAfterSignedIdentityConfirmation(t *testing.T) {
	configured := writeFakeCodexBin(t, t.TempDir(), "configured-codex")
	expected := sharedDaemonListenerProcess{
		PID:        1234,
		ParentPID:  9876,
		UID:        os.Getuid(),
		StartSec:   1786522048,
		StartUsec:  123,
		Command:    "codex app-server --listen unix://",
		Executable: configured,
	}
	// 模拟 socket 在签名父链验证之后换成另一个 owner。它仍使用同一
	// configured executable、UID 和 argv，但父 PID 已变化；完整 identity
	// 绑定必须在任何 TERM 前 fail closed。
	replacement := expected
	replacement.ParentPID = 9877
	termCalls := 0
	err := stopUnmanagedSharedDaemonWithExpectedIdentity(
		context.Background(),
		"/tmp/app.sock",
		configured,
		&expected,
		unmanagedSharedDaemonHooks{
			desktopRunning: func(context.Context) (bool, error) { return false, nil },
			inspect: func(context.Context, string) (sharedDaemonListenerProcess, error) {
				return replacement, nil
			},
			signalTERM: func(int) error { termCalls++; return nil },
			currentUID: func() int { return os.Getuid() },
		},
	)
	if err == nil || !strings.Contains(err.Error(), "与已验证身份不一致") || termCalls != 0 {
		t.Fatalf("签名确认后 listener identity 变化必须拒绝 TERM：err=%v term=%d", err, termCalls)
	}
}

func TestStopUnmanagedSharedDaemonRejectsExecutableDifferentFromConfiguredCodexPath(t *testing.T) {
	configured := writeFakeCodexBin(t, t.TempDir(), "configured-codex")
	foreign := writeFakeCodexBin(t, t.TempDir(), "foreign-codex")
	process := sharedDaemonListenerProcess{
		PID:        1234,
		UID:        os.Getuid(),
		StartSec:   1786522048,
		Command:    "codex app-server --listen unix://",
		Executable: foreign,
	}
	termCalls := 0
	err := stopUnmanagedSharedDaemonWithExpectedPath(
		context.Background(),
		"/tmp/app.sock",
		configured,
		unmanagedSharedDaemonHooks{
			desktopRunning: func(context.Context) (bool, error) { return false, nil },
			inspect: func(context.Context, string) (sharedDaemonListenerProcess, error) {
				return process, nil
			},
			signalTERM: func(int) error { termCalls++; return nil },
			currentUID: func() int { return os.Getuid() },
		},
	)
	if err == nil || !strings.Contains(err.Error(), "不是官方 managed standalone") || termCalls != 0 {
		t.Fatalf("configured CodexBin 之外的 executable 必须 fail closed：err=%v term=%d", err, termCalls)
	}
}

func TestStopUnmanagedSharedDaemonRejectsDesktopReopenedBeforeSignal(t *testing.T) {
	process := sharedDaemonListenerProcess{
		PID:        1234,
		UID:        501,
		StartSec:   1786522048,
		StartUsec:  123,
		Command:    "codex app-server --listen unix://",
		Executable: "/tmp/codex-real",
	}
	desktopChecks := 0
	termCalls := 0
	err := stopUnmanagedSharedDaemonWithHooks(
		context.Background(),
		"/tmp/app.sock",
		"/tmp/codex-real",
		unmanagedSharedDaemonHooks{
			desktopRunning: func(context.Context) (bool, error) {
				desktopChecks++
				return desktopChecks == 2, nil
			},
			inspect:    func(context.Context, string) (sharedDaemonListenerProcess, error) { return process, nil },
			signalTERM: func(int) error { termCalls++; return nil },
			currentUID: func() int { return 501 },
		},
	)
	if err == nil || !strings.Contains(err.Error(), "重新打开") || desktopChecks != 2 || termCalls != 0 {
		t.Fatalf("Desktop 在信号前重开时必须 fail closed：err=%v checks=%d term=%d", err, desktopChecks, termCalls)
	}
}

func TestStopUnmanagedSharedDaemonRejectsFinalDesktopCheckFailure(t *testing.T) {
	process := sharedDaemonListenerProcess{
		PID:        1234,
		UID:        501,
		StartSec:   1786522048,
		StartUsec:  123,
		Command:    "codex app-server --listen unix://",
		Executable: "/tmp/codex-real",
	}
	desktopChecks := 0
	termCalls := 0
	err := stopUnmanagedSharedDaemonWithHooks(
		context.Background(),
		"/tmp/app.sock",
		"/tmp/codex-real",
		unmanagedSharedDaemonHooks{
			desktopRunning: func(context.Context) (bool, error) {
				desktopChecks++
				if desktopChecks == 2 {
					return false, fmt.Errorf("查询失败")
				}
				return false, nil
			},
			inspect:    func(context.Context, string) (sharedDaemonListenerProcess, error) { return process, nil },
			signalTERM: func(int) error { termCalls++; return nil },
			currentUID: func() int { return 501 },
		},
	)
	if err == nil || !strings.Contains(err.Error(), "信号前再次确认") || termCalls != 0 {
		t.Fatalf("Desktop 最终检查失败时必须 fail closed：err=%v term=%d", err, termCalls)
	}
}

func TestStopUnmanagedSharedDaemonRejectsUnsafeListener(t *testing.T) {
	base := sharedDaemonListenerProcess{
		PID:        1234,
		UID:        501,
		StartSec:   1786522048,
		StartUsec:  123,
		Command:    "codex -c features.code_mode_host=true app-server --listen unix://",
		Executable: "/tmp/codex-real",
	}
	tests := []struct {
		name    string
		mutate  func(*sharedDaemonListenerProcess)
		message string
	}{
		{name: "wrong uid", mutate: func(p *sharedDaemonListenerProcess) { p.UID = 502 }, message: "不属于当前用户"},
		{name: "wrong executable", mutate: func(p *sharedDaemonListenerProcess) { p.Executable = "/tmp/foreign" }, message: "不是官方 managed standalone"},
		{name: "wrong argv", mutate: func(p *sharedDaemonListenerProcess) { p.Command = "codex app-server --listen ws://127.0.0.1:4222" }, message: "命令行不符合"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			process := base
			test.mutate(&process)
			termCalls := 0
			err := stopUnmanagedSharedDaemonWithHooks(
				context.Background(),
				"/tmp/app.sock",
				"/tmp/codex-real",
				unmanagedSharedDaemonHooks{
					desktopRunning: func(context.Context) (bool, error) { return false, nil },
					inspect:        func(context.Context, string) (sharedDaemonListenerProcess, error) { return process, nil },
					signalTERM:     func(int) error { termCalls++; return nil },
					currentUID:     func() int { return 501 },
				},
			)
			if err == nil || !strings.Contains(err.Error(), test.message) || termCalls != 0 {
				t.Fatalf("不安全 listener 必须拒绝：err=%v term=%d", err, termCalls)
			}
		})
	}
}

func TestStopUnmanagedSharedDaemonRejectsPIDReuseBeforeSignal(t *testing.T) {
	first := sharedDaemonListenerProcess{
		PID:        1234,
		UID:        501,
		StartSec:   1786522048,
		StartUsec:  123,
		Command:    "codex app-server --listen unix://",
		Executable: "/tmp/codex-real",
	}
	second := first
	second.StartSec++
	inspectCalls := 0
	termCalls := 0
	err := stopUnmanagedSharedDaemonWithHooks(
		context.Background(),
		"/tmp/app.sock",
		"/tmp/codex-real",
		unmanagedSharedDaemonHooks{
			desktopRunning: func(context.Context) (bool, error) { return false, nil },
			inspect: func(context.Context, string) (sharedDaemonListenerProcess, error) {
				inspectCalls++
				if inspectCalls == 1 {
					return first, nil
				}
				return second, nil
			},
			signalTERM: func(int) error { termCalls++; return nil },
			currentUID: func() int { return 501 },
		},
	)
	if err == nil || !strings.Contains(err.Error(), "发生变化") || termCalls != 0 {
		t.Fatalf("PID/start-time 复用必须在 TERM 前停止：err=%v term=%d", err, termCalls)
	}
}

func TestDirectUnixAppServerCommandAcceptsNativeNULSeparatedArgv(t *testing.T) {
	command := strings.Join([]string{
		"codex",
		"-c",
		"features.code_mode_host=true",
		"app-server",
		"--listen",
		"unix://",
	}, "\x00")
	if !isDirectUnixAppServerCommand(command) {
		t.Fatal("原生 procargs2 argv 应识别为直接 Unix app-server")
	}
	if isDirectUnixAppServerCommand(strings.Replace(command, "unix://", "ws://127.0.0.1:4222", 1)) {
		t.Fatal("非 Unix transport 必须拒绝")
	}
	if isDirectUnixAppServerCommand("codex app-server daemon start --listen unix://") {
		t.Fatal("官方 daemon 控制命令不能当成 SSH 直接 listener 接管")
	}
	if isDirectUnixAppServerCommand("codex app-server proxy --listen unix://") {
		t.Fatal("官方 proxy 不能当成 SSH 直接 listener 接管")
	}
}

func TestSharedDaemonSocketPeerAndProcIdentityUseNativeDarwinMetadata(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "mimi-peer-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	socketPath := filepath.Join(dir, "app.sock")
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	accepted := make(chan net.Conn, 1)
	acceptErr := make(chan error, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			acceptErr <- err
			return
		}
		accepted <- conn
	}()

	pid, uid, err := sharedDaemonSocketPeer(context.Background(), socketPath)
	if err != nil {
		t.Fatalf("读取本机 Unix peer 失败：%v", err)
	}
	select {
	case conn := <-accepted:
		conn.Close()
	case err := <-acceptErr:
		t.Fatalf("接受测试连接失败：%v", err)
	case <-time.After(time.Second):
		t.Fatal("测试 listener 未收到连接")
	}
	if pid != os.Getpid() || uid != os.Getuid() {
		t.Fatalf("peer 身份不匹配：pid=%d/%d uid=%d/%d", pid, os.Getpid(), uid, os.Getuid())
	}
	executable, arguments, err := sharedDaemonProcessArguments(pid)
	if err != nil {
		t.Fatalf("读取原生 procargs2 失败：%v", err)
	}
	if !filepath.IsAbs(executable) || len(arguments) == 0 {
		t.Fatalf("进程身份缺少绝对 executable 或 argv：exe=%q argv=%v", executable, arguments)
	}
}

func TestValidatePrivateSharedDaemonSocketRequiresModeAndOwner(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "mimi-private-sock-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	socketPath := filepath.Join(dir, "app.sock")
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	if err := os.Chmod(socketPath, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := validatePrivateSharedDaemonSocket(socketPath, os.Getuid()); err != nil {
		t.Fatalf("当前用户私有 socket 应通过：%v", err)
	}
	if err := os.Chmod(socketPath, 0o666); err != nil {
		t.Fatal(err)
	}
	if err := validatePrivateSharedDaemonSocket(socketPath, os.Getuid()); err == nil {
		t.Fatal("公开 socket 必须拒绝接管")
	}
}

func TestLiveSharedDaemonListenerIdentity(t *testing.T) {
	socketPath := strings.TrimSpace(os.Getenv("MIMI_LIVE_SHARED_DAEMON_SOCKET"))
	if socketPath == "" {
		t.Skip("仅在显式提供真实共享 socket 时运行")
	}
	process, err := inspectSharedDaemonListenerProcess(context.Background(), socketPath)
	if err != nil {
		t.Fatalf("读取真实共享 daemon 身份失败：%v", err)
	}
	if process.PID <= 1 || process.UID != os.Getuid() || process.StartSec <= 0 ||
		!filepath.IsAbs(process.Executable) || !isDirectUnixAppServerCommand(process.Command) {
		t.Fatalf("真实共享 daemon 身份不完整或不是直接 Unix app-server：%+v", process)
	}
}
