//go:build darwin

package appserver

import (
	"bufio"
	"context"
	"encoding/binary"
	"net"
	"os"
	"path/filepath"
	"reflect"
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
	if err := os.MkdirAll(filepath.Dir(door.BackendSocketPath()), 0o700); err != nil {
		t.Fatal(err)
	}
	return door
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
		signalTERM: func(pid int) error {
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
		t.Fatalf("只应向空闲孤儿发送一次 SIGTERM，实际 %v", signaled)
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
