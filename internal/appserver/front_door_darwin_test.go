//go:build darwin

package appserver

import (
	"bufio"
	"context"
	"encoding/binary"
	"errors"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func newTestFrontDoor(t *testing.T) *FrontDoor {
	t.Helper()
	home := shortSharedLocalCodexHome(t)
	door, err := NewFrontDoor(SharedLocalOptions{Env: map[string]string{"CODEX_HOME": home}}, t.Logf)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(door.PublicSocketPath()), 0o700); err != nil {
		t.Fatal(err)
	}
	// 单元测试不能扫描或给用户正在运行的 Codex 进程发信号。
	door.orphans.listCodex = func() ([]sharedLocalRepairProcess, error) { return nil, nil }
	return door
}

func TestFrontDoorUsesSeparateBackendCodexHome(t *testing.T) {
	publicHome := shortSharedLocalCodexHome(t)
	backendHome := shortSharedLocalCodexHome(t)
	env := map[string]string{"CODEX_HOME": publicHome, "MIMI_TEST_MARKER": "kept"}
	door, err := NewFrontDoor(SharedLocalOptions{Env: env, BackendCodexHome: backendHome}, t.Logf)
	if err != nil {
		t.Fatal(err)
	}
	door.orphans.listCodex = func() ([]sharedLocalRepairProcess, error) { return nil, nil }
	if got, want := door.PublicSocketPath(), filepath.Join(publicHome, sharedLocalSocketDir, sharedLocalSocketName); got != want {
		t.Fatalf("public socket=%q want %q", got, want)
	}
	if got, want := door.BackendSocketPath(), filepath.Join(backendHome, sharedLocalSocketDir, sharedLocalBackendSocketName); got != want {
		t.Fatalf("backend socket=%q want %q", got, want)
	}
	if door.BackendCodexHome() != backendHome {
		t.Fatalf("backend home=%q want %q", door.BackendCodexHome(), backendHome)
	}
	if door.lockPath != filepath.Join(backendHome, sharedLocalSocketDir, sharedLocalBackendLockName) {
		t.Fatalf("backend 启动锁未放在独立 home：%q", door.lockPath)
	}
	if door.migrationLockPath != filepath.Join(publicHome, sharedLocalSocketDir, frontDoorMigrationLockName) {
		t.Fatalf("迁移锁必须保留在公共 home：%q", door.migrationLockPath)
	}
	if err := os.MkdirAll(filepath.Dir(door.PublicSocketPath()), 0o700); err != nil {
		t.Fatal(err)
	}
	env["MIMI_TEST_MARKER"] = "changed-after-construction"
	var launched SharedLocalOptions
	var stop func()
	door.launch = func(_ context.Context, options SharedLocalOptions, _ string) error {
		launched = options
		stop = echoBackend(t, door.BackendSocketPath())
		return nil
	}
	t.Cleanup(func() {
		if stop != nil {
			stop()
		}
	})
	conn, err := door.DialBackend(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	_ = conn.Close()
	if launched.Env["CODEX_HOME"] != backendHome || launched.Env["MIMI_TEST_MARKER"] != "kept" {
		t.Fatalf("backend 启动环境错误：%v", launched.Env)
	}
	if env["CODEX_HOME"] != publicHome || door.options.Env["CODEX_HOME"] != publicHome || door.options.Env["MIMI_TEST_MARKER"] != "kept" {
		t.Fatalf("启动 backend 不得修改公共环境：input=%v stored=%v", env, door.options.Env)
	}
	restarted, err := NewFrontDoor(door.options, t.Logf)
	if err != nil {
		t.Fatal(err)
	}
	if restarted.PublicSocketPath() != door.PublicSocketPath() || restarted.BackendSocketPath() != door.BackendSocketPath() {
		t.Fatalf("重建前门改变了 socket：public=%q backend=%q", restarted.PublicSocketPath(), restarted.BackendSocketPath())
	}
}

func TestFrontDoorDefaultBackendPathsRemainPublic(t *testing.T) {
	publicHome := shortSharedLocalCodexHome(t)
	door, err := NewFrontDoor(SharedLocalOptions{Env: map[string]string{"CODEX_HOME": publicHome}}, t.Logf)
	if err != nil {
		t.Fatal(err)
	}
	if door.BackendCodexHome() != publicHome {
		t.Fatalf("默认 backend home=%q want %q", door.BackendCodexHome(), publicHome)
	}
	if filepath.Dir(door.PublicSocketPath()) != filepath.Dir(door.BackendSocketPath()) ||
		door.lockPath != filepath.Join(filepath.Dir(door.PublicSocketPath()), sharedLocalBackendLockName) {
		t.Fatal("默认 backend socket 与启动锁路径必须保持不变")
	}
}

func TestFrontDoorRejectsInvalidSeparateBackendHomes(t *testing.T) {
	publicHome := shortSharedLocalCodexHome(t)
	child := filepath.Join(publicHome, "child")
	if err := os.Mkdir(child, 0o700); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(filepath.Dir(publicHome), "not-a-directory")
	if err := os.WriteFile(file, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	alias := filepath.Join(filepath.Dir(publicHome), "public-alias")
	if err := os.Symlink(publicHome, alias); err != nil {
		t.Fatal(err)
	}
	tests := map[string]string{
		"relative":       "relative-home",
		"missing":        filepath.Join(filepath.Dir(publicHome), "missing"),
		"file":           file,
		"same":           publicHome,
		"canonical same": alias,
		"backend child":  child,
		"backend parent": filepath.Dir(publicHome),
	}
	for name, backendHome := range tests {
		t.Run(name, func(t *testing.T) {
			_, err := NewFrontDoor(SharedLocalOptions{
				Env:              map[string]string{"CODEX_HOME": publicHome},
				BackendCodexHome: backendHome,
			}, t.Logf)
			if err == nil {
				t.Fatalf("必须拒绝 backend home %q", backendHome)
			}
		})
	}
}

func TestFrontDoorRejectsCaseInsensitiveBackendAlias(t *testing.T) {
	publicHome := shortSharedLocalCodexHome(t)
	caseAlias := filepath.Join(filepath.Dir(publicHome), strings.ToUpper(filepath.Base(publicHome)))
	publicInfo, publicErr := os.Stat(publicHome)
	aliasInfo, aliasErr := os.Stat(caseAlias)
	if publicErr != nil || aliasErr != nil || !os.SameFile(publicInfo, aliasInfo) {
		t.Skip("当前测试文件系统区分路径大小写")
	}
	_, err := NewFrontDoor(SharedLocalOptions{
		Env:              map[string]string{"CODEX_HOME": publicHome},
		BackendCodexHome: caseAlias,
	}, t.Logf)
	if err == nil {
		t.Fatal("大小写别名指向同一目录时必须拒绝隔离")
	}
}

func TestFrontDoorGenerationsSharePublicMigrationLock(t *testing.T) {
	publicHome := shortSharedLocalCodexHome(t)
	firstBackend := shortSharedLocalCodexHome(t)
	secondBackend := shortSharedLocalCodexHome(t)
	first, err := NewFrontDoor(SharedLocalOptions{Env: map[string]string{"CODEX_HOME": publicHome}, BackendCodexHome: firstBackend}, t.Logf)
	if err != nil {
		t.Fatal(err)
	}
	second, err := NewFrontDoor(SharedLocalOptions{Env: map[string]string{"CODEX_HOME": publicHome}, BackendCodexHome: secondBackend}, t.Logf)
	if err != nil {
		t.Fatal(err)
	}
	if first.migrationLockPath != second.migrationLockPath || first.lockPath == second.lockPath {
		t.Fatalf("两代前门锁路径错误：migration=%q/%q backend=%q/%q", first.migrationLockPath, second.migrationLockPath, first.lockPath, second.lockPath)
	}
	if err := os.MkdirAll(filepath.Dir(first.migrationLockPath), 0o700); err != nil {
		t.Fatal(err)
	}
	unlock, err := first.LockMigration(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	if secondUnlock, err := second.LockMigration(ctx); err == nil {
		secondUnlock()
		t.Fatal("不同 backend home 的前门代际必须在公共迁移锁上互斥")
	}
}

// echoBackend 模拟 Codex backend：逐行回显，关闭时删除 socket。
func echoBackend(t *testing.T, path string) func() {
	t.Helper()
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				reader := bufio.NewReader(conn)
				for {
					line, err := reader.ReadString('\n')
					if err != nil {
						return
					}
					if _, err := conn.Write([]byte("echo:" + line)); err != nil {
						return
					}
				}
			}()
		}
	}()
	return func() { _ = listener.Close() }
}

func TestFrontDoorLaunchesBackendOnceForConcurrentConnections(t *testing.T) {
	door := newTestFrontDoor(t)
	var launches atomic.Int32
	var stop func()
	door.launch = func(_ context.Context, _ SharedLocalOptions, listen string) error {
		if listen != "unix://"+door.BackendSocketPath() {
			t.Errorf("前门必须让 Codex 监听私有 backend socket，实际 %q", listen)
		}
		launches.Add(1)
		time.Sleep(50 * time.Millisecond)
		stop = echoBackend(t, door.BackendSocketPath())
		return nil
	}
	t.Cleanup(func() {
		if stop != nil {
			stop()
		}
	})

	var wg sync.WaitGroup
	for index := 0; index < 8; index++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			conn, err := door.DialBackend(ctx)
			if err != nil {
				t.Error(err)
				return
			}
			_ = conn.Close()
		}()
	}
	wg.Wait()
	if got := launches.Load(); got != 1 {
		t.Fatalf("并发连接应只启动一次 backend，实际 %d 次", got)
	}
}

func TestFrontDoorProxiesBytesAndHalfClose(t *testing.T) {
	door := newTestFrontDoor(t)
	stop := echoBackend(t, door.BackendSocketPath())
	defer stop()
	door.launch = func(context.Context, SharedLocalOptions, string) error {
		t.Fatal("backend 已存在时不能再次启动")
		return nil
	}
	publicListener, err := net.Listen("unix", door.PublicSocketPath())
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _ = door.Serve(ctx, publicListener) }()

	conn, err := net.Dial("unix", door.PublicSocketPath())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err := conn.Write([]byte("hello\n")); err != nil {
		t.Fatal(err)
	}
	reply, err := bufio.NewReader(conn).ReadString('\n')
	if err != nil || reply != "echo:hello\n" {
		t.Fatalf("reply=%q err=%v", reply, err)
	}
	if err := conn.(*net.UnixConn).CloseWrite(); err != nil {
		t.Fatal(err)
	}
	if _, err := bufio.NewReader(conn).ReadString('\n'); err == nil {
		t.Fatal("客户端半关闭后 backend 应结束连接")
	}
}

func TestFrontDoorReportsLaunchFailureWithinDeadline(t *testing.T) {
	door := newTestFrontDoor(t)
	door.launch = func(context.Context, SharedLocalOptions, string) error {
		return os.ErrPermission
	}
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	if _, err := door.DialBackend(ctx); err == nil {
		t.Fatal("backend 无法启动时必须返回错误")
	}
}

func TestFrontDoorMigrationLockWaitsForActiveClient(t *testing.T) {
	door := newTestFrontDoor(t)
	stop := echoBackend(t, door.BackendSocketPath())
	defer stop()
	client, err := door.DialBackend(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Millisecond)
	defer cancel()
	if unlock, err := door.LockMigration(ctx); err == nil {
		unlock()
		_ = client.Close()
		t.Fatal("客户端仍连接时不能换代前门")
	}
	if err := client.Close(); err != nil {
		t.Fatal(err)
	}
	unlock, err := door.LockMigration(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	unlock()
}

func TestFrontDoorReleasesOnlyIdlePublicListeners(t *testing.T) {
	door := newTestFrontDoor(t)
	idle := sharedLocalRepairProcess{PID: 101, UID: 501, StartSec: 1, Name: "codex"}
	busy := sharedLocalRepairProcess{PID: 102, UID: 501, StartSec: 2, Name: "codex"}
	proxy := sharedLocalRepairProcess{PID: 103, UID: 501, StartSec: 3, Name: "codex"}
	backend := sharedLocalRepairProcess{PID: 104, UID: 501, StartSec: 4, Name: "codex"}
	argv := map[int][]string{
		101: {"codex", "-c", "features.code_mode_host=true", "app-server", "--listen", "unix://"},
		102: {"codex", "app-server", "--listen", "unix://"},
		103: {"codex", "app-server", "proxy"},
		104: {"codex", "app-server", "--listen", "unix://" + door.BackendSocketPath()},
	}
	names := map[int]int{101: 1, 102: 3, 103: 1, 104: 0}
	var signaled []int
	door.orphans = frontDoorOrphanOps{
		listCodex: func() ([]sharedLocalRepairProcess, error) {
			return []sharedLocalRepairProcess{idle, busy, proxy, backend}, nil
		},
		args: func(pid int) ([]string, error) { return argv[pid], nil },
		socketNames: func(_ context.Context, pid int, socket string) (int, error) {
			if socket != door.PublicSocketPath() {
				t.Errorf("孤儿检查只能匹配标准 socket，实际 %q", socket)
			}
			return names[pid], nil
		},
		process: func(pid int) (sharedLocalRepairProcess, bool, error) {
			for _, candidate := range []sharedLocalRepairProcess{idle, busy} {
				if candidate.PID == pid {
					return candidate, true, nil
				}
			}
			return sharedLocalRepairProcess{}, false, nil
		},
		canDrain: func(context.Context, sharedLocalRepairProcess) error { return nil },
		signalHUP: func(pid int) error {
			signaled = append(signaled, pid)
			return nil
		},
		signaledMu: &sync.Mutex{},
		signaled:   map[sharedLocalRepairProcess]struct{}{},
	}

	first, err := door.ReleaseIdleOrphans(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	want := []FrontDoorOrphan{{PID: 101, Clients: 0, Signaled: true}, {PID: 102, Clients: 2}}
	if !reflect.DeepEqual(first, want) {
		t.Fatalf("orphans=%+v want %+v", first, want)
	}
	if _, err := door.ReleaseIdleOrphans(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(signaled, []int{101}) {
		t.Fatalf("同一前门只应向空闲孤儿发送一次 SIGHUP，实际 %v", signaled)
	}
}

func TestFrontDoorBlocksBackendUntilBusyOrphanExits(t *testing.T) {
	door := newTestFrontDoor(t)
	old := sharedLocalRepairProcess{PID: 101, UID: 501, StartSec: 1, Name: "codex"}
	var alive atomic.Bool
	alive.Store(true)
	door.orphans.listCodex = func() ([]sharedLocalRepairProcess, error) {
		if alive.Load() {
			return []sharedLocalRepairProcess{old}, nil
		}
		return nil, nil
	}
	door.orphans.args = func(int) ([]string, error) {
		return []string{"codex", "app-server", "--listen", "unix://"}, nil
	}
	door.orphans.socketNames = func(context.Context, int, string) (int, error) { return 2, nil }
	door.orphans.canDrain = func(context.Context, sharedLocalRepairProcess) error {
		t.Fatal("旧实例仍有客户端时不能发退出信号")
		return nil
	}
	var launches atomic.Int32
	door.launch = func(context.Context, SharedLocalOptions, string) error {
		launches.Add(1)
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Millisecond)
	defer cancel()
	if _, err := door.DialBackend(ctx); err == nil {
		t.Fatal("旧实例仍有客户端时必须阻断新 backend")
	}
	if launches.Load() != 0 {
		t.Fatal("迁移受阻时不应启动 backend")
	}
	alive.Store(false)
	stop := echoBackend(t, door.BackendSocketPath())
	defer stop()
	conn, err := door.DialBackend(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	_ = conn.Close()
}

func TestFrontDoorWaitsForGracefulOrphanDrain(t *testing.T) {
	door := newTestFrontDoor(t)
	old := sharedLocalRepairProcess{PID: 101, UID: uint32(os.Getuid()), StartSec: 1, Name: "codex"}
	var alive atomic.Bool
	alive.Store(true)
	var signals atomic.Int32
	signalSeen := make(chan struct{}, 1)
	door.orphans.listCodex = func() ([]sharedLocalRepairProcess, error) {
		if alive.Load() {
			return []sharedLocalRepairProcess{old}, nil
		}
		return nil, nil
	}
	door.orphans.args = func(int) ([]string, error) {
		return []string{"codex", "app-server", "--listen", "unix://"}, nil
	}
	door.orphans.socketNames = func(context.Context, int, string) (int, error) { return 1, nil }
	door.orphans.process = func(int) (sharedLocalRepairProcess, bool, error) { return old, alive.Load(), nil }
	door.orphans.canDrain = func(context.Context, sharedLocalRepairProcess) error { return nil }
	door.orphans.signalHUP = func(int) error {
		signals.Add(1)
		signalSeen <- struct{}{}
		return nil
	}
	stop := echoBackend(t, door.BackendSocketPath())
	defer stop()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	finished := make(chan error, 1)
	go func() {
		conn, err := door.DialBackend(ctx)
		if err == nil {
			_ = conn.Close()
		}
		finished <- err
	}()
	select {
	case <-signalSeen:
	case <-ctx.Done():
		t.Fatal("前门没有请求旧实例 drain")
	}
	if signals.Load() != 1 {
		t.Fatalf("应向空闲旧实例发送一次 SIGHUP，实际 %d", signals.Load())
	}
	select {
	case err := <-finished:
		t.Fatalf("旧实例仍在 drain 时不应接入 backend：%v", err)
	default:
	}
	alive.Store(false)
	if err := <-finished; err != nil {
		t.Fatal(err)
	}
}

func TestFrontDoorRestartWaitsForDrainingProcessAfterSocketCloses(t *testing.T) {
	door := newTestFrontDoor(t)
	old := sharedLocalRepairProcess{PID: 101, UID: uint32(os.Getuid()), StartSec: 1, Name: "codex"}
	var alive atomic.Bool
	alive.Store(true)
	var references atomic.Int32
	references.Store(1)
	var signals atomic.Int32
	configure := func(target *FrontDoor) {
		target.orphans.listCodex = func() ([]sharedLocalRepairProcess, error) {
			if alive.Load() {
				return []sharedLocalRepairProcess{old}, nil
			}
			return nil, nil
		}
		target.orphans.args = func(int) ([]string, error) {
			return []string{"codex", "app-server", "--listen", "unix://"}, nil
		}
		target.orphans.socketNames = func(context.Context, int, string) (int, error) { return int(references.Load()), nil }
		target.orphans.process = func(int) (sharedLocalRepairProcess, bool, error) { return old, alive.Load(), nil }
		target.orphans.canDrain = func(context.Context, sharedLocalRepairProcess) error { return nil }
		target.orphans.signalHUP = func(int) error { signals.Add(1); return nil }
	}
	configure(door)
	if _, err := door.ReleaseIdleOrphans(context.Background()); err != nil {
		t.Fatal(err)
	}
	references.Store(0)
	if orphans, err := door.ReleaseIdleOrphans(context.Background()); err != nil || len(orphans) != 1 {
		t.Fatalf("socket 已关闭但进程仍在 drain 时必须保留阻断：%+v, %v", orphans, err)
	}
	restarted, err := NewFrontDoor(door.options, t.Logf)
	if err != nil {
		t.Fatal(err)
	}
	configure(restarted)
	var launches atomic.Int32
	restarted.launch = func(context.Context, SharedLocalOptions, string) error {
		launches.Add(1)
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Millisecond)
	defer cancel()
	if _, err := restarted.DialBackend(ctx); err == nil || launches.Load() != 0 {
		t.Fatalf("前门重启后不得越过仍在 drain 的旧进程：err=%v launches=%d", err, launches.Load())
	}
	if signals.Load() != 2 {
		t.Fatalf("前门重启后应安全补发一次 SIGHUP，实际 %d", signals.Load())
	}
	transferCtx, transferCancel := context.WithTimeout(context.Background(), 150*time.Millisecond)
	defer transferCancel()
	if err := restarted.WaitForOrphans(transferCtx); err == nil {
		t.Fatal("永久移交 Homebrew 也必须等待旧 resident 退出")
	}
	alive.Store(false)
	if err := restarted.WaitForOrphans(context.Background()); err != nil {
		t.Fatal(err)
	}
	stop := echoBackend(t, restarted.BackendSocketPath())
	defer stop()
	conn, err := restarted.DialBackend(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	_ = conn.Close()
}

func TestFrontDoorRestartUsesGracefulSignalAndRejectsUnknownVersion(t *testing.T) {
	old := sharedLocalRepairProcess{PID: 101, UID: 501, StartSec: 1, Name: "codex"}
	var signals atomic.Int32
	newDoor := func() *FrontDoor {
		door := newTestFrontDoor(t)
		door.orphans.listCodex = func() ([]sharedLocalRepairProcess, error) {
			return []sharedLocalRepairProcess{old}, nil
		}
		door.orphans.args = func(int) ([]string, error) {
			return []string{"codex", "app-server", "--listen", "unix://"}, nil
		}
		door.orphans.socketNames = func(context.Context, int, string) (int, error) { return 1, nil }
		door.orphans.process = func(int) (sharedLocalRepairProcess, bool, error) { return old, true, nil }
		door.orphans.canDrain = func(context.Context, sharedLocalRepairProcess) error { return nil }
		door.orphans.signalHUP = func(int) error { signals.Add(1); return nil }
		return door
	}
	for range 2 {
		if _, err := newDoor().ReleaseIdleOrphans(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	if signals.Load() != 2 {
		t.Fatalf("前门重启后仍只能使用可重复的 SIGHUP，实际 %d", signals.Load())
	}
	blocked := newDoor()
	blocked.orphans.canDrain = func(context.Context, sharedLocalRepairProcess) error {
		return errors.New("unsupported version")
	}
	if _, err := blocked.ReleaseIdleOrphans(context.Background()); err == nil {
		t.Fatal("无法确认旧版本退出语义时必须拒绝自动迁移")
	}
	if signals.Load() != 2 {
		t.Fatal("未知版本不能收到退出信号")
	}
}

func TestParseDarwinProcArgs(t *testing.T) {
	raw := make([]byte, 4)
	binary.LittleEndian.PutUint32(raw, 3)
	raw = append(raw, []byte("/usr/local/bin/codex\x00\x00\x00codex\x00app-server\x00--listen\x00HOME=/x\x00")...)
	got, err := parseDarwinProcArgs(raw)
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"codex", "app-server", "--listen"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("args=%v want %v", got, want)
	}
	if _, err := parseDarwinProcArgs(raw[:3]); err == nil {
		t.Fatal("过短的 procargs2 必须报错")
	}
}

func TestFrontDoorCodexBinPrefersDesktopInstallDir(t *testing.T) {
	home := t.TempDir()
	env := map[string]string{"HOME": home}
	if got := FrontDoorCodexBin("/configured/codex", env); got != "/configured/codex" {
		t.Fatalf("缺少 Desktop 安装目录时应沿用配置，实际 %q", got)
	}
	installed := filepath.Join(home, ".local", "bin", "codex")
	if err := os.MkdirAll(filepath.Dir(installed), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(installed, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if got := FrontDoorCodexBin("/configured/codex", env); got != installed {
		t.Fatalf("应优先使用 Desktop 的安装目录，实际 %q", got)
	}
	custom := filepath.Join(home, "custom")
	env["CODEX_INSTALL_DIR"] = custom
	if got := FrontDoorCodexBin("/configured/codex", env); got != "/configured/codex" {
		t.Fatalf("CODEX_INSTALL_DIR 下没有 codex 时应回退配置，实际 %q", got)
	}
}
