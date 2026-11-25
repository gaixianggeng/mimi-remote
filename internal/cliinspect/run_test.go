package cliinspect

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"testing"
	"testing/synctest"
	"time"
)

const helperFlag = "-test.run=^TestInspectionHelper$"

func TestInspectionHelper(t *testing.T) {
	args := os.Args
	if len(args) < 4 || args[1] != helperFlag || args[2] != "--" {
		return
	}
	mode := args[3]
	if mode == "--version" {
		for _, key := range args[4:] {
			if value, ok := os.LookupEnv(key); ok {
				fmt.Printf("%s=%s\n", key, value)
			}
		}
		os.Exit(0)
	}
	if mode == "child" {
		conn, err := net.Dial("tcp", args[4])
		if err != nil {
			t.Fatal(err)
		}
		ready, err := net.Dial("tcp", args[5])
		if err != nil {
			t.Fatal(err)
		}
		ready.Close()
		// The test closes its connection on failure so even a leaking child exits.
		io.Copy(io.Discard, conn)
		os.Exit(0)
	}
	ready, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	child := exec.Command(os.Args[0], helperFlag, "--", "child", args[4], ready.Addr().String())
	if mode == "inherited-output" {
		child.Stdout = os.Stdout
	}
	if err := child.Start(); err != nil {
		t.Fatal(err)
	}
	conn, err := ready.Accept()
	if err != nil {
		t.Fatal(err)
	}
	conn.Close()
	ready.Close()
	if mode == "timeout" {
		time.Sleep(time.Minute)
	}
	fmt.Println("codex-cli 0.155.0")
	os.Exit(0)
}

func TestVersionProbeEnvironment(t *testing.T) {
	home, path := t.TempDir(), t.TempDir()
	env := []string{
		"HOME=" + home, "PATH=" + path, "GORACE=atexit_sleep_ms=0",
		"NO_UPDATE_NOTIFIER=0", "NPM_CONFIG_LOGS_MAX=9",
		"NPM_CONFIG_UPDATE_NOTIFIER=true", "npm_config_logs-dir=" + home,
	}
	sink := os.DevNull
	if runtime.GOOS == "windows" {
		sink = `\\.\NUL`
	}
	want := []string{
		"HOME=" + home, "PATH=" + path,
		"NO_UPDATE_NOTIFIER=1", "NPM_CONFIG_UPDATE_NOTIFIER=false",
		"NPM_CONFIG_LOGS_MAX=9", "NPM_CONFIG_LOGS_DIR=" + sink,
		"NPM_CONFIG_TIMING=false", "NPM_CONFIG_AUDIT=false", "NPM_CONFIG_FUND=false",
		"NODE_DISABLE_COMPILE_CACHE=1",
	}
	args := []string{helperFlag, "--", "--version"}
	for _, entry := range want {
		key, _, _ := strings.Cut(entry, "=")
		args = append(args, key)
	}
	// npm also accepts mixed-case keys and dashes in its config environment.
	args = append(args, "npm_config_logs-dir")
	check := func(t *testing.T, output string, err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
		if expected := strings.Join(want, "\n") + "\n"; output != expected {
			t.Errorf("shim environment:\n%s\nwant:\n%s", output, expected)
		}
	}
	t.Run("Run with inherited environment", func(t *testing.T) {
		for _, entry := range env {
			key, value, _ := strings.Cut(entry, "=")
			t.Setenv(key, value)
		}
		output, err := Run(t.Context(), os.Args[0], nil, args...)
		check(t, output, err)
	})
	t.Run("Stdout with explicit environment", func(t *testing.T) {
		output, err := Stdout(t.Context(), os.Args[0], env, args...)
		check(t, string(output), err)
	})
	t.Run("default npm log retention", func(t *testing.T) {
		output, err := Stdout(t.Context(), os.Args[0], []string{"GORACE=atexit_sleep_ms=0"},
			helperFlag, "--", "--version", "NPM_CONFIG_LOGS_MAX")
		if err != nil || len(output) != 0 {
			t.Fatalf("probe changed npm's default retention: output %q, err %v", output, err)
		}
	})
}

func TestInspectionCleansDescendants(t *testing.T) {
	for _, mode := range []string{"closed-output", "inherited-output", "timeout"} {
		t.Run(mode, func(t *testing.T) {
			listener, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
			if err != nil {
				t.Fatal(err)
			}
			defer listener.Close()
			budget := 10 * time.Second
			if mode == "timeout" {
				budget = 4 * time.Second
			}
			ctx, cancel := context.WithTimeout(context.Background(), budget)
			defer cancel()
			deadline, _ := ctx.Deadline()
			listener.SetDeadline(deadline)
			done := make(chan error, 1)
			go func() {
				// Avoid the race detector's one-second exit delay in the helper.
				env := append(os.Environ(), "GORACE=atexit_sleep_ms=0")
				output, err := Run(ctx, os.Args[0], env, helperFlag, "--", mode, listener.Addr().String())
				if err == nil && strings.TrimSpace(output) != "codex-cli 0.155.0" {
					err = errors.New("missing shim version")
				}
				done <- err
			}()
			conn, err := listener.Accept()
			if err != nil {
				t.Fatal(err)
			}
			defer conn.Close()
			err = <-done
			if mode == "timeout" && !errors.Is(err, context.DeadlineExceeded) || mode != "timeout" && err != nil {
				t.Fatalf("inspection result: %v", err)
			}
			conn.SetReadDeadline(time.Now().Add(2 * time.Second))
			// Forced teardown can close the socket with EOF or a reset on Windows.
			n, err := conn.Read(make([]byte, 1))
			var netErr net.Error
			if n != 0 || err == nil || errors.As(err, &netErr) && netErr.Timeout() {
				t.Fatalf("child connection still open after cleanup: %v", err)
			}
		})
	}
}

func TestInspectionBoundsCommandStartup(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
		defer cancel()
		release := make(chan struct{})
		defer close(release)
		start := time.Now()
		_, _, err := Output(ctx, func() (*exec.Cmd, error) {
			<-release
			return nil, ctx.Err()
		}, 1024)
		if !errors.Is(err, context.DeadlineExceeded) || time.Since(start) != 4*time.Second {
			t.Fatalf("blocked startup: %v after %s", err, time.Since(start))
		}
	})
}
