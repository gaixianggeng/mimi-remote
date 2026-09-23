//go:build darwin || linux

package sshbridge

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

func bridgeFixture(t *testing.T) (string, Options) {
	t.Helper()
	// macOS Unix socket 限制为 104 字节，系统默认测试目录可能超过该限制。
	dir, err := os.MkdirTemp("/tmp", "mimi-ssh-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	return filepath.Join(dir, "bridge.sock"), Options{Shell: "/bin/sh", Home: dir,
		Env: []string{"PATH=/usr/bin:/bin", "HOME=" + dir}}
}

func startBridgeFixture(t *testing.T) (string, *Server) {
	t.Helper()
	path, options := bridgeFixture(t)
	server, err := Listen(path, options)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = server.Close() })
	return path, server
}

func TestBridgeStreamsBinaryAndPreservesStderrAndExit(t *testing.T) {
	path, _ := startBridgeFixture(t)
	input := bytes.Repeat([]byte{0, 1, 10, 13, 255, 128}, 200000)
	var output, stderr bytes.Buffer
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	code, err := Run(ctx, path, "cat; printf 'command-error\\n' >&2; exit 23", bytes.NewReader(input), &output, &stderr)
	if err != nil || code != 23 {
		t.Fatalf("code=%d err=%v", code, err)
	}
	if !bytes.Equal(output.Bytes(), input) {
		t.Fatalf("binary stream changed: got=%d want=%d", output.Len(), len(input))
	}
	if stderr.String() != "command-error\n" {
		t.Fatalf("stderr=%q", stderr.String())
	}
}

func TestBridgeConcurrentClients(t *testing.T) {
	path, _ := startBridgeFixture(t)
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			var out bytes.Buffer
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			code, err := Run(ctx, path, "cat", strings.NewReader("own-connection"), &out, io.Discard)
			if err != nil || code != 0 || out.String() != "own-connection" {
				t.Errorf("code=%d out=%q err=%v", code, out.String(), err)
			}
		}()
	}
	wg.Wait()
}

func TestBridgeDisconnectAndServerShutdownCancelOnlyOwnCommand(t *testing.T) {
	for _, stopServer := range []bool{false, true} {
		t.Run(strconv.FormatBool(stopServer), func(t *testing.T) {
			path, server := startBridgeFixture(t)
			pidFile := filepath.Join(filepath.Dir(path), "command.pid")
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			stdin, input := io.Pipe()
			defer stdin.Close()
			defer input.Close()
			done := make(chan error, 1)
			go func() {
				_, err := Run(ctx, path, "echo $$ > "+pidFile+"; exec sleep 30", stdin, io.Discard, io.Discard)
				done <- err
			}()
			var pid int
			waitBridgeCondition(t, func() bool {
				raw, err := os.ReadFile(pidFile)
				if err != nil {
					return false
				}
				pid, _ = strconv.Atoi(strings.TrimSpace(string(raw)))
				return pid > 1
			})
			if stopServer {
				_ = server.Close()
			} else {
				cancel()
			}
			select {
			case err := <-done:
				if err == nil {
					t.Fatal("disconnected client reported success")
				}
			case <-time.After(5 * time.Second):
				t.Fatal("client did not stop")
			}
			waitBridgeCondition(t, func() bool { return errors.Is(syscall.Kill(pid, 0), syscall.ESRCH) })
		})
	}
}

func TestBridgeKeepsNohupBackgroundProcessOnDisconnect(t *testing.T) {
	path, server := startBridgeFixture(t)
	pidFile := filepath.Join(filepath.Dir(path), "resident.pid")
	command := "nohup sh -c 'echo $$ > " + pidFile + "; exec sleep 30' </dev/null >/dev/null 2>&1 &"
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	code, err := Run(ctx, path, command, strings.NewReader(""), io.Discard, io.Discard)
	if err != nil || code != 0 {
		t.Fatalf("background command code=%d err=%v", code, err)
	}
	var pid int
	waitBridgeCondition(t, func() bool {
		raw, err := os.ReadFile(pidFile)
		if err != nil {
			return false
		}
		pid, _ = strconv.Atoi(strings.TrimSpace(string(raw)))
		return pid > 1
	})
	defer syscall.Kill(pid, syscall.SIGTERM)
	_ = server.Close()
	if err := syscall.Kill(pid, 0); err != nil {
		t.Fatalf("Desktop nohup resident stopped with SSH bridge: %v", err)
	}
}

func waitBridgeCondition(t *testing.T, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !condition() {
		if time.Now().After(deadline) {
			t.Fatal("timed out waiting for fixture")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestBridgeDoesNotReplaceLiveOwnerOrForeignFiles(t *testing.T) {
	path, options := bridgeFixture(t)
	server, err := Listen(path, options)
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	if _, err := Listen(path, options); err == nil {
		t.Fatal("second owner acquired socket")
	}
	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("socket permissions: %v %v", info, err)
	}
	_ = server.Close()
	if err := os.WriteFile(path, []byte("preserve"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Listen(path, options); err == nil {
		t.Fatal("replaced non-socket file")
	}
	raw, err := os.ReadFile(path)
	if err != nil || string(raw) != "preserve" {
		t.Fatal("occupied file changed")
	}
}

func TestBridgeRecoversOnlyOwnedStaleSocket(t *testing.T) {
	path, options := bridgeFixture(t)
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	listener.SetUnlinkOnClose(false)
	_ = listener.Close()
	server, err := Listen(path, options)
	if err != nil {
		t.Fatal(err)
	}
	_ = server.Close()
	if _, err := os.Lstat(path); !os.IsNotExist(err) {
		t.Fatalf("socket not removed: %v", err)
	}
	if _, err := os.Lstat(path + ".lock"); err != nil {
		t.Fatal("lock file must remain", err)
	}
}

func TestBridgeRejectsPublicDirectoryAndSymlinkLock(t *testing.T) {
	path, options := bridgeFixture(t)
	if err := os.Chmod(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := Listen(path, options); err == nil {
		t.Fatal("accepted shared directory")
	}
	if err := os.Chmod(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(filepath.Dir(path), "keep")
	if err := os.WriteFile(target, []byte("keep"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, path+".lock"); err != nil {
		t.Fatal(err)
	}
	if _, err := Listen(path, options); err == nil {
		t.Fatal("accepted symlink lock")
	}
	raw, _ := os.ReadFile(target)
	if string(raw) != "keep" {
		t.Fatal("symlink target changed")
	}
}

func TestBridgeMalformedCommandNeverStartsProcess(t *testing.T) {
	path, _ := startBridgeFixture(t)
	for _, kind := range []byte{frameInput, frameCommand} {
		conn, err := net.Dial("unix", path)
		if err != nil {
			t.Fatal(err)
		}
		_ = conn.SetDeadline(time.Now().Add(3 * time.Second))
		var header [5]byte
		header[0] = kind
		binary.BigEndian.PutUint32(header[1:], maxFrame+1)
		_, _ = conn.Write(header[:])
		if _, _, err := readFrame(conn); err == nil {
			t.Fatal("accepted oversized command")
		}
		_ = conn.Close()
	}
	for _, command := range []string{"", "  ", "echo\x00bad"} {
		if _, err := Run(context.Background(), path, command, strings.NewReader(""), io.Discard, io.Discard); err == nil {
			t.Fatal("accepted invalid command")
		}
	}
}

func TestBridgeRejectsNonUnixPeer(t *testing.T) {
	left, right := net.Pipe()
	defer left.Close()
	defer right.Close()
	if err := validatePeer(left); err == nil {
		t.Fatal("accepted unverified peer")
	}
}

func TestBridgeDetachedHelper(t *testing.T) {
	pidFile := os.Getenv("MIMI_SSH_TEST_DETACHED_PID")
	if pidFile == "" {
		return
	}
	child := exec.Command("/bin/sleep", "20")
	child.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := child.Start(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(pidFile, []byte(strconv.Itoa(child.Process.Pid)), 0o600); err != nil {
		t.Fatal(err)
	}
	_ = child.Process.Release()
}

func TestBridgeDetachedResidentDoesNotKeepOwnershipLock(t *testing.T) {
	path, options := bridgeFixture(t)
	pidFile := filepath.Join(options.Home, "detached.pid")
	options.Env = append(options.Env, "MIMI_SSH_TEST_DETACHED_PID="+pidFile)
	server, err := Listen(path, options)
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	command := "'" + strings.ReplaceAll(os.Args[0], "'", "'\"'\"'") + "' -test.run=^TestBridgeDetachedHelper$"
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	code, err := Run(ctx, path, command, strings.NewReader(""), io.Discard, io.Discard)
	if err != nil || code != 0 {
		t.Fatalf("helper code=%d err=%v", code, err)
	}
	raw, err := os.ReadFile(pidFile)
	if err != nil {
		t.Fatal(err)
	}
	pid, err := strconv.Atoi(string(raw))
	if err != nil || pid <= 1 {
		t.Fatal("invalid helper pid")
	}
	defer syscall.Kill(pid, syscall.SIGTERM)
	_ = server.Close()
	if err := syscall.Kill(pid, 0); err != nil {
		t.Fatal("detached resident stopped with bridge")
	}
	restarted, err := Listen(path, options)
	if err != nil {
		t.Fatalf("resident inherited bridge ownership: %v", err)
	}
	_ = restarted.Close()
}
