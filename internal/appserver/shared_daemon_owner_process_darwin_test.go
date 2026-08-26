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

func TestRequireManagedSharedDaemonIdleForStopChecksDesktop(t *testing.T) {
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
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			originalDesktop := sharedDaemonDesktopRunning
			originalRequireIdle := sharedDaemonRequireIdle
			sharedDaemonDesktopRunning = test.desktop
			sharedDaemonRequireIdle = func(context.Context, string) error { return nil }
			t.Cleanup(func() {
				sharedDaemonDesktopRunning = originalDesktop
				sharedDaemonRequireIdle = originalRequireIdle
			})

			err := requireManagedSharedDaemonIdleForStop(
				context.Background(),
				LocalDaemonOptions{},
				"/tmp/app.sock",
				LocalDaemonLifecycleStatus{},
				nil,
			)
			if err == nil || !strings.Contains(err.Error(), test.wantMessage) {
				t.Fatalf("优雅排空前必须 fail closed：%v", err)
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
	signalCalls := 0
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
			signalGraceful: func(int) error { signalCalls++; return nil },
			currentUID:     func() int { return 501 },
		},
	)
	if err == nil || !strings.Contains(err.Error(), "仍在运行") || signalCalls != 0 {
		t.Fatalf("Desktop 未退出必须 fail closed：err=%v signal=%d", err, signalCalls)
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
			signalGraceful: func(pid int) error { signaled = append(signaled, pid); return nil },
			currentUID:     func() int { return 501 },
		},
	)
	if err != nil {
		t.Fatalf("严格匹配的原生 SSH daemon 应允许一次 SIGHUP：%v", err)
	}
	if desktopChecks != 2 || inspectCalls != 3 || len(signaled) != 1 || signaled[0] != process.PID {
		t.Fatalf("接管必须两次确认 Desktop、最终确认 PID 且只 SIGHUP 一次：desktop=%d inspect=%d signaled=%v", desktopChecks, inspectCalls, signaled)
	}
}

func TestStopUnmanagedSharedDaemonRejectsSwapDuringFinalDesktopCheck(t *testing.T) {
	first := sharedDaemonListenerProcess{
		PID:        1234,
		UID:        501,
		StartSec:   1786522048,
		StartUsec:  123,
		Command:    "codex app-server --listen unix://",
		Executable: "/tmp/codex-real",
	}
	replacement := first
	replacement.PID = 5678
	replacement.StartUsec++
	swapped := false
	desktopChecks := 0
	inspectCalls := 0
	signalCalls := 0

	err := stopUnmanagedSharedDaemonWithHooks(
		context.Background(),
		"/tmp/app.sock",
		first.Executable,
		unmanagedSharedDaemonHooks{
			desktopRunning: func(context.Context) (bool, error) {
				desktopChecks++
				if desktopChecks == 2 {
					swapped = true
				}
				return false, nil
			},
			inspect: func(context.Context, string) (sharedDaemonListenerProcess, error) {
				inspectCalls++
				if swapped {
					return replacement, nil
				}
				return first, nil
			},
			signalGraceful: func(int) error { signalCalls++; return nil },
			currentUID:     func() int { return 501 },
		},
	)
	if err == nil || !strings.Contains(err.Error(), "Desktop 复核后") || signalCalls != 0 {
		t.Fatalf("Desktop 探测期间换主必须在 SIGHUP 前 fail closed：desktop=%d inspect=%d signal=%d err=%v", desktopChecks, inspectCalls, signalCalls, err)
	}
}

func TestStopUnmanagedSharedDaemonAcceptsStagedExecutableForSignedStableOwner(t *testing.T) {
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
	staged := writeFakeCodexBin(t, t.TempDir(), "staged-codex")
	process := sharedDaemonListenerProcess{
		PID:        1234,
		ParentPID:  9876,
		UID:        os.Getuid(),
		StartSec:   1786522048,
		StartUsec:  123,
		Command:    strings.Join([]string{expected, "app-server", "--listen", "unix://"}, "\x00"),
		Executable: staged,
	}

	inspectCalls := 0
	desktopChecks := 0
	signalCalls := 0
	// sharedDaemonValidateSignedRuntime 已在上层完成签名 node supervisor 父链
	// 验证；这里把同一完整 identity 绑定到最终 SIGHUP helper。
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
			signalGraceful: func(int) error { signalCalls++; return nil },
			currentUID:     func() int { return os.Getuid() },
		},
	)
	if err != nil {
		t.Fatalf("签名 stable owner 的 staged listener 应按原始 Codex argv 允许一次 SIGHUP：%v", err)
	}
	if desktopChecks != 2 || inspectCalls != 3 || signalCalls != 1 {
		t.Fatalf("停止必须保留 Desktop 双重检查、listener 最终确认和一次 SIGHUP：desktop=%d inspect=%d signal=%d", desktopChecks, inspectCalls, signalCalls)
	}

	// 同一 listener 若按 lifecycle 的 standalone 路径判断，必须继续拒绝；
	// 这保证旧式 unmanaged SSH listener 的路径边界没有被放宽。
	signalCalls = 0
	err = stopUnmanagedSharedDaemonWithHooks(
		context.Background(),
		"/tmp/app.sock",
		standalone,
		unmanagedSharedDaemonHooks{
			desktopRunning: func(context.Context) (bool, error) { return false, nil },
			inspect: func(context.Context, string) (sharedDaemonListenerProcess, error) {
				return process, nil
			},
			signalGraceful: func(int) error { signalCalls++; return nil },
			currentUID:     func() int { return os.Getuid() },
		},
	)
	if err == nil || !strings.Contains(err.Error(), "不是官方 managed standalone") || signalCalls != 0 {
		t.Fatalf("legacy unmanaged 路径必须继续要求 standalone executable：err=%v signal=%d", err, signalCalls)
	}
}

func TestStopUnmanagedSharedDaemonRejectsStagedListenerWithUnexpectedOriginalArgv(t *testing.T) {
	configured := writeFakeCodexBin(t, t.TempDir(), "configured-codex")
	foreign := writeFakeCodexBin(t, t.TempDir(), "foreign-codex")
	staged := writeFakeCodexBin(t, t.TempDir(), "staged-codex")
	process := sharedDaemonListenerProcess{
		PID:        1234,
		ParentPID:  9876,
		UID:        os.Getuid(),
		StartSec:   1786522048,
		StartUsec:  123,
		Command:    strings.Join([]string{foreign, "app-server", "--listen", "unix://"}, "\x00"),
		Executable: staged,
	}
	signalCalls := 0
	err := stopUnmanagedSharedDaemonWithExpectedIdentity(
		context.Background(),
		"/tmp/app.sock",
		configured,
		&process,
		unmanagedSharedDaemonHooks{
			desktopRunning: func(context.Context) (bool, error) { return false, nil },
			inspect: func(context.Context, string) (sharedDaemonListenerProcess, error) {
				return process, nil
			},
			signalGraceful: func(int) error { signalCalls++; return nil },
			currentUID:     func() int { return os.Getuid() },
		},
	)
	if err == nil || !strings.Contains(err.Error(), "listener 身份无效") || signalCalls != 0 {
		t.Fatalf("staged listener 的原始 argv 不匹配时必须拒绝 SIGHUP：err=%v signal=%d", err, signalCalls)
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
		Command:    strings.Join([]string{configured, "app-server", "--listen", "unix://"}, "\x00"),
		Executable: configured,
	}
	// 模拟 socket 在签名父链验证之后换成另一个 owner。它仍使用同一
	// configured executable、UID 和 argv，但父 PID 已变化；完整 identity
	// 绑定必须在任何 SIGHUP 前 fail closed。
	replacement := expected
	replacement.ParentPID = 9877
	signalCalls := 0
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
			signalGraceful: func(int) error { signalCalls++; return nil },
			currentUID:     func() int { return os.Getuid() },
		},
	)
	if err == nil || !strings.Contains(err.Error(), "与已验证身份不一致") || signalCalls != 0 {
		t.Fatalf("签名确认后 listener identity 变化必须拒绝 SIGHUP：err=%v signal=%d", err, signalCalls)
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
	signalCalls := 0
	err := stopUnmanagedSharedDaemonWithExpectedPath(
		context.Background(),
		"/tmp/app.sock",
		configured,
		unmanagedSharedDaemonHooks{
			desktopRunning: func(context.Context) (bool, error) { return false, nil },
			inspect: func(context.Context, string) (sharedDaemonListenerProcess, error) {
				return process, nil
			},
			signalGraceful: func(int) error { signalCalls++; return nil },
			currentUID:     func() int { return os.Getuid() },
		},
	)
	if err == nil || !strings.Contains(err.Error(), "不是官方 managed standalone") || signalCalls != 0 {
		t.Fatalf("configured CodexBin 之外的 executable 必须 fail closed：err=%v signal=%d", err, signalCalls)
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
	signalCalls := 0
	err := stopUnmanagedSharedDaemonWithHooks(
		context.Background(),
		"/tmp/app.sock",
		"/tmp/codex-real",
		unmanagedSharedDaemonHooks{
			desktopRunning: func(context.Context) (bool, error) {
				desktopChecks++
				return desktopChecks == 2, nil
			},
			inspect:        func(context.Context, string) (sharedDaemonListenerProcess, error) { return process, nil },
			signalGraceful: func(int) error { signalCalls++; return nil },
			currentUID:     func() int { return 501 },
		},
	)
	if err == nil || !strings.Contains(err.Error(), "重新打开") || desktopChecks != 2 || signalCalls != 0 {
		t.Fatalf("Desktop 在信号前重开时必须 fail closed：err=%v checks=%d signal=%d", err, desktopChecks, signalCalls)
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
	signalCalls := 0
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
			inspect:        func(context.Context, string) (sharedDaemonListenerProcess, error) { return process, nil },
			signalGraceful: func(int) error { signalCalls++; return nil },
			currentUID:     func() int { return 501 },
		},
	)
	if err == nil || !strings.Contains(err.Error(), "信号前再次确认") || signalCalls != 0 {
		t.Fatalf("Desktop 最终检查失败时必须 fail closed：err=%v signal=%d", err, signalCalls)
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
			signalCalls := 0
			err := stopUnmanagedSharedDaemonWithHooks(
				context.Background(),
				"/tmp/app.sock",
				"/tmp/codex-real",
				unmanagedSharedDaemonHooks{
					desktopRunning: func(context.Context) (bool, error) { return false, nil },
					inspect:        func(context.Context, string) (sharedDaemonListenerProcess, error) { return process, nil },
					signalGraceful: func(int) error { signalCalls++; return nil },
					currentUID:     func() int { return 501 },
				},
			)
			if err == nil || !strings.Contains(err.Error(), test.message) || signalCalls != 0 {
				t.Fatalf("不安全 listener 必须拒绝：err=%v signal=%d", err, signalCalls)
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
	signalCalls := 0
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
			signalGraceful: func(int) error { signalCalls++; return nil },
			currentUID:     func() int { return 501 },
		},
	)
	if err == nil || !strings.Contains(err.Error(), "发生变化") || signalCalls != 0 {
		t.Fatalf("PID/start-time 复用必须在 SIGHUP 前停止：err=%v signal=%d", err, signalCalls)
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
